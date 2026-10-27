// Car screen: the thruster readout while driving and the control panel, plus the generated thruster sounds. client_ui.lua sends
//   { utils, resourceName }              until the page answers, to load lc_utils' translations (nui/lang/*.js) and the post route
//   { setup }                            once loaded: default keys, enabled features, the nozzle layout and the driver's readout choices
//   { hud: state }                       when the readout changes (false: the player isn't driving a car with thrusters)
//   { panel: { open, vehicle, plate } }  to open or close the panel
//   { hudVisible }                       when the driver hides or shows the readout with its key
// and client_fx.lua sends { sounds } every 100 ms with every vehicle to hear.

const SVG_NS = "http://www.w3.org/2000/svg";
const KEY_NAMES = { LSHIFT: "Shift", RSHIFT: "Shift", LCONTROL: "Ctrl", RCONTROL: "Ctrl", LMENU: "Alt", RMENU: "Alt", SPACE: "Space" };
const LOW_TANK = 35;                    // % under which the tank shows amber (under the assist reserve: red)
const GAUGE_LENGTH = 2 * Math.PI * 52;  // Circumference of the panel gauge
const PENDING_TIME = 800;               // ms a switch the driver flipped ignores the readout, until Lua has applied it
const HINT_TIME = 8000;                 // ms the "F7 Control panel" hint shows after the readout appears

// Panel switches: assists are the driver's choice (remembered by client_ui.lua), the fan is the vehicle's state
const SETTINGS = [
	{ key: "stabilityControl", label: "stability", desc: "stability_desc", event: "setAssist" },
	{ key: "landingAssist", label: "landing", desc: "landing_desc", event: "setAssist" },
	{ key: "stunts", label: "stunts", desc: "stunts_desc", event: "setAssist" },
	{ key: "fan", label: "fan", desc: "fan_desc", event: "setFan" },
];
const CHIPS = [
	{ key: "stabilityControl", label: "chip_stability" },
	{ key: "landingAssist", label: "chip_landing" },
	{ key: "fan", label: "chip_fan" },
];
const HUD_POSITIONS = ["top-left", "top-right", "bottom-left", "bottom-right"];

let setup = null;
let lastState = null;
let hudVisible = true;  // The driver's choice (F9 or the panel)
let hintTimer = null;
let readoutDesc = null; // Description of the readout switch, which names its key
let early = {};         // Messages that arrived before the setup, applied once it's built
const cars = [];        // Car pictures with their nozzle effects: [{ nozzles: [{ element, plume, glow }] }]
const switches = {};    // [key] = { input, pendingUntil }
const chips = {};       // [key] = element

// Not "$": that is jQuery, which lc_utils uses
const byId = (id) => document.getElementById(id);

function svg(tag, attributes, parent) {
	const element = document.createElementNS(SVG_NS, tag);
	for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
	if (parent) parent.appendChild(element);
	return element;
}

function keyName(key) {
	return KEY_NAMES[key] || key;
}

// -----------------------------------------------------------------------------------------------------------------------------------
// Build (once the setup arrives)
// -----------------------------------------------------------------------------------------------------------------------------------

// The car picture (images/car-top.png) and the nozzle effects share a 140 x 200 frame, nose up. These sizes match the body in the
// picture (measured from its transparent edges), the nozzle positions are fractions of them, from NOZZLES in Lua. Replacing the
// picture means measuring these again
const CAR_HALF_WIDTH = 44;
const CAR_HALF_LENGTH = 88;
const CAR_CENTER_Y = -3.5;
const FRONT_NOZZLE_HALF_WIDTH = 38;     // The body narrows at the nose: the front nozzles sit on the fenders
const REAR_NOZZLE_HALF_WIDTH = 32;      // The 4 rear outlets in the picture sit inside the body edges, above the rear bumper
const REAR_NOZZLE_HALF_LENGTH = 84.5;

// Draws the nozzle effects over the car picture of a readout or the panel
function buildCar(container, id) {
	const element = container.querySelector(".car-effects");
	element.innerHTML = `
		<defs>
			<linearGradient id="${id}-plume" x1="0" y1="0" x2="0" y2="1">
				<stop offset="0" stop-color="#ffffff" stop-opacity="0.95"/>
				<stop offset="0.35" stop-color="#dce7ff" stop-opacity="0.5"/>
				<stop offset="1" stop-color="#9fb6ff" stop-opacity="0"/>
			</linearGradient>
			<radialGradient id="${id}-glow">
				<stop offset="0" stop-color="#ffffff" stop-opacity="0.9"/>
				<stop offset="1" stop-color="#9fb6ff" stop-opacity="0"/>
			</radialGradient>
		</defs>`;
	const car = { nozzles: [] };
	for (const nozzle of setup.nozzles) {
		const rear = nozzle.group === "rear";
		const halfWidth = rear ? REAR_NOZZLE_HALF_WIDTH : nozzle.y > 0 ? FRONT_NOZZLE_HALF_WIDTH : CAR_HALF_WIDTH;
		const x = nozzle.x * halfWidth;
		const y = CAR_CENTER_Y - nozzle.y * (rear ? REAR_NOZZLE_HALF_LENGTH : CAR_HALF_LENGTH);
		const group = svg("g", { class: "nozzle" }, element);
		let plume = null;
		let glow = null;
		if (nozzle.ex === 0 && nozzle.ey === 0) {
			glow = svg("circle", { class: "glow", cx: x, cy: y, r: 13, fill: `url(#${id}-glow)` }, group);
		} else {
			// Rotate the plume (drawn pointing down) to the exhaust direction, in the picture's axes (y down)
			const angle = Math.atan2(-nozzle.ex, -nozzle.ey) * 180 / Math.PI;
			const holder = svg("g", { transform: `translate(${x} ${y}) rotate(${angle})` }, group);
			plume = svg("path", { class: "plume", d: "M-1.5 0 L1.5 0 C2 8 5 17 5.5 26 Q0 29 -5.5 26 C-5 17 -2 8 -1.5 0 Z", fill: `url(#${id}-plume)` }, holder);
		}
		svg("circle", { class: "nozzle-dot", cx: x, cy: y, r: 1.9 }, group);
		car.nozzles.push({ element: group, plume, glow });
	}
	cars.push(car);
}

function buildSettings() {
	const container = byId("panel-settings");
	for (const setting of SETTINGS) {
		if (!setup.features[setting.key]) continue;
		const row = document.createElement("label");
		row.className = "setting";
		row.innerHTML = `<div class="setting-text"><span class="setting-title"></span><span class="setting-desc"></span></div>
			<input type="checkbox" class="switch">`;
		row.querySelector(".setting-title").textContent = Utils.translate(setting.label);
		row.querySelector(".setting-desc").textContent = Utils.translate(setting.desc);
		const input = row.querySelector("input");
		const entry = { input, pendingUntil: 0 };
		input.addEventListener("change", () => {
			entry.pendingUntil = Date.now() + PENDING_TIME;
			Utils.post(setting.event, { key: setting.key, value: input.checked });
		});
		switches[setting.key] = entry;
		container.appendChild(row);
	}
}

function buildChips() {
	const container = byId("hud-chips");
	for (const chip of CHIPS) {
		if (!setup.features[chip.key]) continue;
		const element = document.createElement("span");
		element.className = "chip";
		element.textContent = Utils.translate(chip.label);
		chips[chip.key] = element;
		container.appendChild(element);
	}
}

// Readout rows of the panel: show or hide it, and the corner it appears in
function buildReadoutSettings() {
	if (!setup.hud) return;
	const container = byId("panel-settings");

	const visibleRow = document.createElement("label");
	visibleRow.className = "setting";
	visibleRow.innerHTML = `<div class="setting-text"><span class="setting-title"></span><span class="setting-desc"></span></div>
		<input type="checkbox" class="switch">`;
	visibleRow.querySelector(".setting-title").textContent = Utils.translate("readout");
	readoutDesc = visibleRow.querySelector(".setting-desc");
	const input = visibleRow.querySelector("input");
	input.checked = hudVisible;
	input.addEventListener("change", () => {
		setHudVisible(input.checked);
		Utils.post("setHudVisible", { value: input.checked });
	});
	switches.hudVisible = { input, pendingUntil: Infinity };     // Not driven by the readout state
	container.appendChild(visibleRow);

	const positionRow = document.createElement("div");
	positionRow.className = "setting";
	positionRow.innerHTML = `<div class="setting-text"><span class="setting-title"></span><span class="setting-desc"></span></div>
		<div class="positions"></div>`;
	positionRow.querySelector(".setting-title").textContent = Utils.translate("position");
	positionRow.querySelector(".setting-desc").textContent = Utils.translate("position_desc");
	const picker = positionRow.querySelector(".positions");
	for (const position of HUD_POSITIONS) {
		const button = document.createElement("button");
		button.type = "button";
		button.className = "position " + position;
		button.dataset.position = position;
		button.addEventListener("click", () => {
			setHudPosition(position);
			Utils.post("setHudPosition", { value: position });
		});
		picker.appendChild(button);
	}
	container.appendChild(positionRow);
}

function setHudPosition(position) {
	if (!HUD_POSITIONS.includes(position)) position = "bottom-right";
	const hud = byId("hud");
	hud.classList.remove(...HUD_POSITIONS);
	hud.classList.add(position);
	document.querySelectorAll(".position").forEach((button) => button.classList.toggle("selected", button.dataset.position === position));
}

function setHudVisible(visible) {
	hudVisible = visible;
	if (switches.hudVisible) switches.hudVisible.input.checked = visible;
	render(lastState);
}

// Shows the player's keys: in the legend, the readout switch and the readout hint. Called again when the panel opens, in case they
// were rebound in the FiveM settings
function setKeys(keys) {
	setup.keys = keys;
	if (readoutDesc) readoutDesc.textContent = Utils.translate("readout_desc").format(keyName(keys.hud));
	byId("hud-hint").firstChild.textContent = keyName(keys.panel);
	buildControls();
}

function buildControls() {
	const controls = [];
	if (setup.features.boost) controls.push([[keyName(setup.keys.boost)], "boost"]);
	if (setup.features.flight) controls.push([[keyName(setup.keys.lift)], "lift"]);
	if (setup.features.fan) controls.push([[keyName(setup.keys.fan)], "fan"]);
	if (setup.features.stunts) controls.push([["A", "D"], "roll"], [["W", "S"], "pitch"]);
	controls.push([[keyName(setup.keys.panel)], "panel"]);
	if (setup.hud) controls.push([[keyName(setup.keys.hud)], "readout"]);

	const container = byId("panel-controls");
	container.textContent = "";
	for (const [keys, label] of controls) {
		const control = document.createElement("span");
		control.className = "control";
		for (const key of keys) {
			const cap = document.createElement("span");
			cap.className = "key";
			cap.textContent = key;
			control.appendChild(cap);
		}
		control.appendChild(document.createTextNode(Utils.translate(label)));
		container.appendChild(control);
	}
}

function build(data) {
	setup = data;
	document.querySelectorAll("[data-label]").forEach((element) => {
		element.textContent = Utils.translate(element.dataset.label);
	});
	buildCar(byId("hud-car"), "hud");
	buildCar(byId("panel-car"), "panel");
	buildSettings();
	buildReadoutSettings();
	buildChips();
	hudVisible = setup.hudVisible;
	setHudPosition(setup.hudPosition);
	byId("hud-hint").innerHTML = `<span class="key"></span><span></span>`;
	byId("hud-hint").lastChild.textContent = Utils.translate("hint");
	setKeys(setup.keys);

	const reserve = setup.reserve;
	document.querySelector("#hud-tank-bar .bar-reserve").style.left = `${reserve}%`;
	// Reserve tick across the gauge ring (the ring starts at the top: the svg is turned -90 degrees)
	const angle = reserve / 100 * 2 * Math.PI;
	const tick = byId("panel-gauge-tick");
	tick.setAttribute("x1", 60 + 47 * Math.cos(angle));
	tick.setAttribute("y1", 60 + 47 * Math.sin(angle));
	tick.setAttribute("x2", 60 + 57 * Math.cos(angle));
	tick.setAttribute("y2", 60 + 57 * Math.sin(angle));
	byId("hud-boost").classList.toggle("collapsed", !setup.features.boost);
	byId("panel-boost-stat").style.display = setup.features.boost ? "" : "none";
	byId("panel-climb-stat").style.display = setup.features.flight ? "" : "none";

	if (early.hudVisible !== undefined) hudVisible = early.hudVisible;
	if (early.hud !== undefined) render(early.hud);
	if (early.panel) setPanel(early.panel);
	early = {};
}

// -----------------------------------------------------------------------------------------------------------------------------------
// Render
// -----------------------------------------------------------------------------------------------------------------------------------

function tankLevelClass(tank) {
	if (tank <= setup.reserve) return "critical";
	if (tank < LOW_TANK) return "low";
	return "";
}

function setBar(bar, percent, className) {
	bar.querySelector(".bar-fill").style.width = `${Math.max(0, Math.min(100, percent))}%`;
	bar.classList.remove("low", "critical", "cooling");
	if (className) bar.classList.add(className);
}

function renderCars(throttles) {
	for (const car of cars) {
		car.nozzles.forEach((nozzle, index) => {
			const throttle = throttles[index] || 0;
			nozzle.element.classList.toggle("firing", throttle > 0);
			const opacity = throttle > 0 ? 0.35 + 0.65 * throttle : 0;
			if (nozzle.plume) {
				nozzle.plume.style.opacity = opacity;
				nozzle.plume.setAttribute("transform", `scale(${0.6 + 0.4 * throttle} ${0.35 + 0.65 * throttle})`);
			} else {
				nozzle.glow.style.opacity = opacity;
				nozzle.glow.setAttribute("r", 6 + 9 * throttle);
			}
		});
	}
}

function render(state) {
	const wasShown = !byId("hud").classList.contains("hidden");
	lastState = state;
	const shown = !!state && setup.hud && hudVisible;
	byId("hud").classList.toggle("hidden", !shown);
	if (shown && !wasShown) showHint();
	if (!state) return;

	// Tank
	const tank = state.tank;
	const level = tankLevelClass(tank);
	byId("hud-tank").textContent = Math.round(tank);
	setBar(byId("hud-tank-bar"), tank, level);
	byId("panel-tank").textContent = Math.round(tank);
	byId("panel-gauge-fill").style.strokeDasharray = `${GAUGE_LENGTH * tank / 100} 999`;
	document.querySelector(".gauge").className = `gauge ${level}`;

	// Boost: ready, charging back or overheated
	if (setup.features.boost) {
		const boostText = state.overheated ? Utils.translate("cooling") : state.boost >= 100 ? Utils.translate("ready") : `${state.boost}%`;
		const boostState = byId("hud-boost-state");
		boostState.textContent = boostText;
		boostState.className = `state ${state.overheated ? "cooling" : state.boost >= 100 ? "ready" : ""}`;
		setBar(document.querySelector("#hud-boost .bar"), state.boost, state.overheated ? "cooling" : "");
		byId("panel-boost").textContent = boostText;
		byId("panel-boost").classList.toggle("cooling", !!state.overheated);
	}

	// Climb time: shown while it's being used
	if (setup.features.flight) {
		byId("hud-climb").classList.toggle("collapsed", !(state.inAir || state.climb < 100));
		byId("hud-climb-state").textContent = `${state.climb}%`;
		setBar(document.querySelector("#hud-climb .bar"), state.climb, state.climb <= 0 ? "critical" : "");
		byId("panel-climb").textContent = `${state.climb}%`;
	}

	// In the air: altitude above the ground and vertical speed
	byId("hud-flight").classList.toggle("collapsed", !state.inAir);
	if (state.inAir) {
		byId("hud-altitude").textContent = state.altitude !== undefined ? state.altitude.toFixed(1) : "—";
		const speed = state.verticalSpeed || 0;
		byId("hud-vs").textContent = `${speed > 0.2 ? "▲" : speed < -0.2 ? "▼" : "■"} ${Math.abs(speed).toFixed(1)} m/s`;
	}

	// Assists and fan
	for (const [key, element] of Object.entries(chips)) {
		element.classList.toggle("on", !!state[key]);
	}
	const now = Date.now();
	for (const [key, entry] of Object.entries(switches)) {
		if (now >= entry.pendingUntil) entry.input.checked = !!state[key];
	}

	renderCars(state.throttles || []);
}

// The hint shows for a few seconds each time the readout appears
function showHint() {
	const hint = byId("hud-hint");
	hint.classList.remove("faded");
	clearTimeout(hintTimer);
	hintTimer = setTimeout(() => hint.classList.add("faded"), HINT_TIME);
}

function setPanel(panel) {
	byId("panel-backdrop").classList.toggle("hidden", !panel.open);
	if (panel.open) {
		if (panel.keys) setKeys(panel.keys);
		byId("panel-vehicle").textContent = [panel.vehicle, panel.plate && panel.plate.trim()].filter(Boolean).join("  ·  ");
	}
}

// -----------------------------------------------------------------------------------------------------------------------------------
// Sound: generated with the Web Audio API from filtered white noise, so the resource needs no sound files. A vehicle missing from an
// update fades out and its nodes are released
// -----------------------------------------------------------------------------------------------------------------------------------

const FADE = 0.08;              // s, time constant that smooths volume and pan between updates
const THRUST_CUTOFF = 1800;     // Hz, high-pass for the hiss of the gas jets
const FAN_CUTOFF = 350;         // Hz, low-pass for the whir of the underbody fan

const audioContext = new AudioContext();
const noise = createNoiseBuffer(2);
const channels = new Map();     // vehicle -> { panner, thrust, fan }

function createNoiseBuffer(seconds) {
	const buffer = audioContext.createBuffer(1, audioContext.sampleRate * seconds, audioContext.sampleRate);
	const data = buffer.getChannelData(0);
	for (let i = 0; i < data.length; i++) {
		data[i] = Math.random() * 2 - 1;
	}
	return buffer;
}

function createVoice(type, frequency, output) {
	const source = new AudioBufferSourceNode(audioContext, { buffer: noise, loop: true });
	const filter = new BiquadFilterNode(audioContext, { type, frequency });
	const gain = new GainNode(audioContext, { gain: 0 });
	source.connect(filter).connect(gain).connect(output);
	// Each voice starts at a random point of the buffer, so two vehicles don't sound like one
	source.start(0, Math.random() * noise.duration);
	return { source, gain };
}

function createChannel() {
	const panner = new StereoPannerNode(audioContext);
	panner.connect(audioContext.destination);
	return {
		panner,
		thrust: createVoice("highpass", THRUST_CUTOFF, panner),
		fan: createVoice("lowpass", FAN_CUTOFF, panner),
	};
}

function clamp(value, min, max) {
	return typeof value === "number" && isFinite(value) ? Math.min(max, Math.max(min, value)) : 0;
}

function playSounds(sounds) {
	if (audioContext.state === "suspended") audioContext.resume();

	const now = audioContext.currentTime;
	const heard = new Set();
	for (const [id, sound] of Object.entries(sounds)) {
		heard.add(id);
		let channel = channels.get(id);
		if (!channel) {
			channel = createChannel();
			channels.set(id, channel);
		}
		channel.thrust.gain.gain.setTargetAtTime(clamp(sound.thrust, 0, 1), now, FADE);
		channel.fan.gain.gain.setTargetAtTime(clamp(sound.fan, 0, 1), now, FADE);
		channel.panner.pan.setTargetAtTime(clamp(sound.pan, -1, 1), now, FADE);
	}

	for (const [id, channel] of channels) {
		if (heard.has(id)) continue;
		channel.thrust.gain.gain.setTargetAtTime(0, now, FADE);
		channel.fan.gain.gain.setTargetAtTime(0, now, FADE);
		channel.thrust.source.stop(now + FADE * 6);
		channel.fan.source.stop(now + FADE * 6);
		channels.delete(id);
	}
}

// -----------------------------------------------------------------------------------------------------------------------------------
// Messages
// -----------------------------------------------------------------------------------------------------------------------------------

window.addEventListener("message", async (event) => {
	const item = event.data;
	if (!item) return;
	if (item.resourceName) {
		Utils.setResourceName(item.resourceName);
	}
	if (item.utils) {
		await Utils.loadLanguageModules(item.utils);
		Utils.post("setNuiVariablesLoaded", null, "setNuiVariablesLoaded");
	}
	if (item.setup && !setup) {
		build(item.setup);
	}
	if (item.sounds) {
		playSounds(item.sounds);
	}
	if (!setup) {
		if (item.hud !== undefined) early.hud = item.hud || null;
		if (item.panel) early.panel = item.panel;
		if (item.hudVisible !== undefined) early.hudVisible = item.hudVisible;
		return;
	}
	if (item.hud !== undefined) render(item.hud || null);
	if (item.panel) setPanel(item.panel);
	if (item.hudVisible !== undefined) setHudVisible(item.hudVisible);
});

byId("panel-close").addEventListener("click", () => Utils.post("close"));
document.addEventListener("keydown", (event) => {
	if (event.key === "Escape" && !byId("panel-backdrop").classList.contains("hidden")) Utils.post("close");
});
