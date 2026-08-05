import assert from "node:assert/strict";
import test from "node:test";

import {
	applyState,
	buildLiveUpdatesToggle,
	LIVE_UPDATES_KEY,
	readPaused,
	writePaused,
} from "./live_updates_toggle.mjs";

const memoryStorage = () => {
	const store = new Map();
	return {
		getItem: (key) => (store.has(key) ? store.get(key) : null),
		setItem: (key, value) => store.set(key, value),
	};
};

const stubElement = () => {
	const span = () => {
		const node = { hidden: false };
		node.classList = { toggle: (_class, on) => { node.hidden = on; } };
		return node;
	};
	const spans = {
		"live-updates-live": span(),
		"live-updates-paused": span(),
	};

	return {
		dataset: {},
		attrs: {},
		listeners: {},
		spans,
		setAttribute(name, value) { this.attrs[name] = value; },
		querySelector(selector) {
			const role = selector.match(/data-role="([^"]+)"/)?.[1];
			return spans[role] || null;
		},
		addEventListener(name, fn) { this.listeners[name] = fn; },
		removeEventListener(name) { delete this.listeners[name]; },
	};
};

const mountHook = (storage) => {
	const hook = buildLiveUpdatesToggle(storage);
	const el = stubElement();
	const pushed = [];
	const context = { el, pushEvent: (event, payload) => pushed.push([event, payload]) };
	const bound = Object.create(hook);
	Object.assign(bound, context);
	bound.mounted();
	return { hook: bound, el, pushed };
};

test("storage falls open to live when it throws", () => {
	assert.equal(readPaused({ getItem() { throw new Error("denied"); } }), false);
	assert.doesNotThrow(() => writePaused({ setItem() { throw new Error("denied"); } }, true));
});

test("the paused state round-trips through storage", () => {
	const storage = memoryStorage();
	writePaused(storage, true);
	assert.equal(storage.getItem(LIVE_UPDATES_KEY), "true");
	assert.equal(readPaused(storage), true);
});

test("applyState flips only the pressed state, never the accessible name", () => {
	const el = stubElement();

	applyState(el, true);
	assert.equal(el.dataset.paused, "true");
	assert.equal(el.attrs["aria-pressed"], "true");
	assert.equal(el.attrs["aria-label"], undefined, "the name is server-rendered and stays put");
	assert.equal(el.spans["live-updates-live"].hidden, true);
	assert.equal(el.spans["live-updates-paused"].hidden, false);

	applyState(el, false);
	assert.equal(el.dataset.paused, "false");
	assert.equal(el.attrs["aria-pressed"], "false");
});

test("mounting reports the stored state to the server", () => {
	const storage = memoryStorage();
	writePaused(storage, true);

	const { pushed, el } = mountHook(storage);

	assert.deepEqual(pushed, [["set_live_updates", { paused: true }]]);
	assert.equal(el.dataset.paused, "true");
});

test("a rejoin re-reports, because the server forgot on remount", () => {
	const { hook, pushed } = mountHook(memoryStorage());
	pushed.length = 0;

	hook.reconnected();

	assert.deepEqual(pushed, [["set_live_updates", { paused: false }]]);
});

test("a patch reasserts data-paused, which LiveView merges away", () => {
	const storage = memoryStorage();
	writePaused(storage, true);
	const { hook, el } = mountHook(storage);

	el.dataset.paused = "false"; // what a server-driven patch leaves behind
	hook.updated();

	assert.equal(el.dataset.paused, "true");
});

test("clicking toggles, persists and reports", () => {
	const storage = memoryStorage();
	const { el, pushed } = mountHook(storage);
	pushed.length = 0;

	el.listeners.click();

	assert.equal(readPaused(storage), true);
	assert.equal(el.dataset.paused, "true");
	assert.deepEqual(pushed, [["set_live_updates", { paused: true }]]);
});
