import assert from "node:assert/strict";
import test from "node:test";

import * as ObservatoryRefreshModule from "./observatory_refresh.mjs";

const { createObservatoryRefreshController, createObservatoryRefreshHook } =
	ObservatoryRefreshModule;

class FakeClock {
	constructor(now = 0) {
		this.nowMs = now;
		this.nextId = 1;
		this.timers = new Map();
	}

	now = () => this.nowMs;

	setTimeout = (callback, delay) => {
		const id = this.nextId++;
		this.timers.set(id, { callback, dueAt: this.nowMs + delay });
		return id;
	};

	clearTimeout = (id) => this.timers.delete(id);

	advanceBy(milliseconds) {
		const target = this.nowMs + milliseconds;

		while (true) {
			const pending = [...this.timers.entries()]
				.filter(([, timer]) => timer.dueAt <= target)
				.sort((left, right) => left[1].dueAt - right[1].dueAt)[0];
			if (!pending) break;

			const [id, timer] = pending;
			this.timers.delete(id);
			this.nowMs = timer.dueAt;
			timer.callback();
		}

		this.nowMs = target;
	}

	get pendingCount() {
		return this.timers.size;
	}
}

class FakeEventTarget {
	constructor() {
		this.listeners = new Map();
	}

	addEventListener(name, listener) {
		const listeners = this.listeners.get(name) ?? new Set();
		listeners.add(listener);
		this.listeners.set(name, listeners);
	}

	removeEventListener(name, listener) {
		this.listeners.get(name)?.delete(listener);
	}

	dispatch(name, event = {}) {
		for (const listener of this.listeners.get(name) ?? []) listener(event);
	}

	listenerCount(name) {
		return this.listeners.get(name)?.size ?? 0;
	}
}

class FakeDocument extends FakeEventTarget {
	visibilityState = "visible";
	body = { id: "body" };
	activeElement = this.body;

	setVisibility(state) {
		this.visibilityState = state;
		this.dispatch("visibilitychange");
	}
}

const buildStatusRoot = (dataset) => {
	const root = new FakeEventTarget();
	const freshness = {
		dataset: {},
		classList: { toggle() {} },
		attrs: {},
		setAttribute(name, value) { this.attrs[name] = value; },
	};
	const label = { textContent: "" };
	const spoken = { textContent: "" };

	root.dataset = dataset;
	root.contains = () => true;
	root.querySelector = (selector) => {
		if (selector === "#observatory-freshness") return freshness;
		if (selector === "[data-role='observatory-freshness-label']") return label;
		if (selector === "[data-role='observatory-refresh-status']") return spoken;
		return null;
	};

	return { freshness, label, root, spoken };
};

const buildController = ({
	now = 0,
	paused = false,
	appliedAt = null,
	freshnessGeneration = appliedAt === null ? 0 : 1,
	visible = true,
} = {}) => {
	const clock = new FakeClock(now);
	const documentTarget = new FakeDocument();
	documentTarget.visibilityState = visible ? "visible" : "hidden";
	const refreshes = [];
	const statuses = [];
	const controller = createObservatoryRefreshController({
		clock,
		documentTarget,
		initiallyPaused: paused,
		lastAppliedAtMs: appliedAt,
		freshnessGeneration,
		onRefresh: (reason) => refreshes.push(reason),
		onStatus: (status) => statuses.push(status),
	});

	controller.start();
	return { clock, controller, documentTarget, refreshes, statuses };
};
const assertPushedEvents = (pushed, expected) =>
	assert.deepEqual(
		pushed.map(({ event }) => event),
		expected,
	);

test("pushes one initial refresh and runs one recursive timer", () => {
	const { clock, controller, documentTarget, refreshes } = buildController();

	controller.start();
	assert.deepEqual(refreshes, ["initial"]);
	assert.equal(documentTarget.listenerCount("visibilitychange"), 1);
	assert.equal(clock.pendingCount, 1);
	clock.advanceBy(29_999);
	assert.deepEqual(refreshes, ["initial"]);
	assert.equal(clock.pendingCount, 1);
	clock.advanceBy(1);
	assert.deepEqual(refreshes, ["initial", "periodic"]);
	assert.equal(clock.pendingCount, 1);
	clock.advanceBy(30_000);
	assert.deepEqual(refreshes, ["initial", "periodic", "periodic"]);
	assert.equal(clock.pendingCount, 1);
});

test("starts hidden or paused without a refresh or timer", () => {
	const hidden = buildController({ visible: false });
	const paused = buildController({ paused: true });

	assert.deepEqual(hidden.refreshes, []);
	assert.equal(hidden.clock.pendingCount, 0);
	assert.deepEqual(paused.refreshes, []);
	assert.equal(paused.clock.pendingCount, 0);
});

test("suppresses inactive reconnects and coalesces activation signals", () => {
	const { clock, controller, documentTarget, refreshes, statuses } =
		buildController();

	assert.deepEqual(refreshes, ["initial"]);
	controller.disconnect();
	documentTarget.setVisibility("hidden");
	assert.equal(statuses.at(-1).label, "Connection interrupted");
	controller.reconnect();
	assert.equal(statuses.at(-1).label, "Updates paused while hidden");
	clock.advanceBy(60_000);
	assert.deepEqual(refreshes, ["initial"]);
	assert.equal(clock.pendingCount, 0);

	documentTarget.setVisibility("visible");
	assert.deepEqual(refreshes, ["initial", "visibility"]);

	controller.pause();
	controller.disconnect();
	controller.reconnect();
	assert.equal(statuses.at(-1).label, "Updates paused");
	clock.advanceBy(60_000);
	assert.deepEqual(refreshes, ["initial", "visibility"]);
	controller.resume();
	controller.resume();
	assert.deepEqual(refreshes, ["initial", "visibility", "resume"]);

	controller.disconnect();
	controller.reconnect();
	controller.reconnect();
	assert.deepEqual(refreshes, ["initial", "visibility", "resume", "reconnect"]);
});

test("repaints freshness from the last applied result", () => {
	const { clock, controller, statuses } = buildController({
		now: 10_000,
		appliedAt: 5_000,
	});

	assert.equal(statuses.at(-1).label, "0s ago");
	controller.markRequested(1);
	clock.advanceBy(2_000);
	assert.equal(statuses.at(-1).label, "2s ago");
	controller.syncAppliedAt(12_000, 2);
	assert.equal(statuses.at(-1).label, "0s ago");
});

test("ignores positive and negative server clock skew", () => {
	for (const serverSkew of [86_400_000, -86_400_000]) {
		const { clock, controller, statuses } = buildController({
			now: 1_000_000,
			appliedAt: 1_000_000 + serverSkew,
		});

		assert.equal(statuses.at(-1).label, "0s ago");
		clock.advanceBy(2_500);
		assert.equal(statuses.at(-1).label, "2s ago");
		controller.destroy();
	}
});

test("resets freshness only when the applied generation changes", () => {
	const serverAppliedAt = 42_000;
	const { clock, controller, statuses } = buildController({
		now: 100_000,
		appliedAt: serverAppliedAt,
		freshnessGeneration: 1,
	});

	clock.advanceBy(4_000);
	controller.syncAppliedAt(serverAppliedAt, 1);
	assert.equal(statuses.at(-1).label, "4s ago");
	controller.syncAppliedAt(serverAppliedAt + 1, 1);
	assert.equal(statuses.at(-1).label, "4s ago");

	controller.syncAppliedAt(serverAppliedAt, 2);
	assert.equal(statuses.at(-1).label, "0s ago");
	clock.advanceBy(3_000);
	controller.syncAppliedAt(serverAppliedAt, 2);
	assert.equal(statuses.at(-1).label, "3s ago");
});

test("does not overwrite a server error for an unchanged freshness generation", () => {
	const clock = new FakeClock(100_000);
	const documentTarget = new FakeDocument();
	const { label, root } = buildStatusRoot({
		freshnessGeneration: "1",
		lastAppliedAtMs: "42000",
		paused: "false",
		requestGeneration: "1",
	});
	const pushed = [];
	const context = {
		el: root,
		pushEvent: (event, payload) => pushed.push({ event, payload }),
	};
	const hook = createObservatoryRefreshHook({ clock, documentTarget });

	hook.mounted.call(context);
	clock.advanceBy(4_000);
	assert.equal(label.textContent, "4s ago");

	label.textContent = "Update unavailable";
	hook.updated.call(context);
	assert.equal(label.textContent, "Update unavailable");

	hook.destroyed.call(context);
});

test("destroy clears the timer and visibility listener", () => {
	const { clock, controller, documentTarget, refreshes } = buildController();

	controller.destroy();
	assert.equal(clock.pendingCount, 0);
	assert.equal(documentTarget.listenerCount("visibilitychange"), 0);
	documentTarget.setVisibility("hidden");
	documentTarget.setVisibility("visible");
	clock.advanceBy(60_000);
	assert.deepEqual(refreshes, ["initial"]);
});

test("hook avoids duplicate pushes across update and reconnect", () => {
	const clock = new FakeClock();
	const documentTarget = new FakeDocument();
	const root = new FakeEventTarget();
	root.dataset = {
		freshnessGeneration: "0",
		lastAppliedAtMs: "",
		paused: "false",
		requestGeneration: "0",
	};
	root.contains = () => true;
	root.querySelector = () => null;
	const pushed = [];
	const context = {
		el: root,
		pushEvent: (event, payload) => pushed.push({ event, payload }),
	};
	const hook = createObservatoryRefreshHook({ clock, documentTarget });

	hook.mounted.call(context);
	hook.updated.call(context);
	assert.equal(root.listenerCount("click"), 1);
	assertPushedEvents(pushed, ["observatory-refresh"]);

	hook.disconnected.call(context);
	hook.updated.call(context);
	hook.reconnected.call(context);
	assertPushedEvents(pushed, ["observatory-refresh", "observatory-refresh"]);

	hook.destroyed.call(context);
});

test("hook projects pause dynamically and resets it on destroy", () => {
	const clock = new FakeClock();
	const documentTarget = new FakeDocument();
	const root = new FakeEventTarget();
	root.dataset = {
		freshnessGeneration: "0",
		lastAppliedAtMs: "",
		paused: "false",
		requestGeneration: "0",
	};
	root.contains = () => true;
	root.querySelector = () => null;
	const pushed = [];
	const context = {
		el: root,
		pushEvent: (event, payload) => pushed.push({ event, payload }),
	};
	const hook = createObservatoryRefreshHook({ clock, documentTarget });

	hook.mounted.call(context);
	root.dispatch("click", {
		preventDefault() {},
		target: {
			closest: () => ({ dataset: { observatoryRefreshAction: "pause" } }),
		},
	});
	assert.deepEqual(ObservatoryRefreshModule.observatoryRefreshConnectParams(), {
		observatory_paused: true,
	});

	hook.disconnected.call(context);
	hook.reconnected.call(context);
	assertPushedEvents(pushed, ["observatory-refresh", "pause-refresh"]);

	root.dispatch("click", {
		preventDefault() {},
		target: {
			closest: () => ({ dataset: { observatoryRefreshAction: "resume" } }),
		},
	});
	assert.deepEqual(ObservatoryRefreshModule.observatoryRefreshConnectParams(), {
		observatory_paused: false,
	});
	assertPushedEvents(pushed, [
		"observatory-refresh",
		"pause-refresh",
		"resume-refresh",
	]);

	root.dispatch("click", {
		preventDefault() {},
		target: {
			closest: () => ({ dataset: { observatoryRefreshAction: "pause" } }),
		},
	});

	hook.destroyed.call(context);
	assert.deepEqual(ObservatoryRefreshModule.observatoryRefreshConnectParams(), {
		observatory_paused: false,
	});
	assert.equal(root.listenerCount("click"), 0);
	assert.equal(documentTarget.listenerCount("visibilitychange"), 0);
	assert.equal(clock.pendingCount, 0);
});

test(
	"restores keyboard focus to the replacement Pause or Resume control after a LiveView patch",
	() => {
		const clock = new FakeClock();
		const documentTarget = new FakeDocument();
		const pause = {
			id: "observatory-pause",
			dataset: { observatoryRefreshAction: "pause" },
			focus() {
				documentTarget.activeElement = this;
			},
		};
		const resume = {
			id: "observatory-resume",
			dataset: { observatoryRefreshAction: "resume" },
			focus() {
				documentTarget.activeElement = this;
			},
		};
		const root = new FakeEventTarget();
		root.dataset = {
			freshnessGeneration: "0",
			lastAppliedAtMs: "",
			paused: "false",
			requestGeneration: "0",
		};
		root.contains = (element) => element === pause || element === resume;
		let replacement = pause;
		root.querySelector = (selector) => {
			if (selector === "[data-observatory-refresh-action='pause']")
				return replacement === pause ? pause : null;
			if (selector === "[data-observatory-refresh-action='resume']")
				return replacement === resume ? resume : null;
			return null;
		};
		const pushed = [];
		const context = {
			el: root,
			pushEvent: (event, payload) => pushed.push({ event, payload }),
		};
		const hook = createObservatoryRefreshHook({ clock, documentTarget });

		hook.mounted.call(context);

		pause.focus();
		root.dispatch("click", {
			detail: 0,
			preventDefault() {},
			target: { closest: () => pause },
		});
		replacement = resume;
		root.dataset.paused = "true";
		documentTarget.activeElement = documentTarget.body;
		hook.updated.call(context);
		assert.equal(documentTarget.activeElement, resume);

		resume.focus();
		root.dispatch("click", {
			detail: 0,
			preventDefault() {},
			target: { closest: () => resume },
		});
		replacement = pause;
		root.dataset.paused = "false";
		documentTarget.activeElement = documentTarget.body;
		hook.updated.call(context);
		assert.equal(documentTarget.activeElement, pause);

		hook.destroyed.call(context);
		assertPushedEvents(pushed, [
			"observatory-refresh",
			"pause-refresh",
			"resume-refresh",
		]);
	},
);

test("refresh hook reads translated status, spoken labels and aria names from data attributes", () => {
	const clock = new FakeClock(10_000);
	const documentTarget = new FakeDocument();
	const refreshLabels = {
		disconnectedAria: "刷新已断开", disconnectedLabel: "连接中断", disconnectedSpoken: "已断开连接",
		pausedAria: "刷新已暂停", pausedLabel: "更新已暂停", pausedSpoken: "已暂停",
		hiddenAria: "标签页隐藏时暂停刷新", hiddenLabel: "隐藏时暂停更新", hiddenSpoken: "隐藏时已暂停",
		liveAria: "实时刷新", updatingLabel: "正在更新用量", liveSpoken: "实时",
		secondsAgo: "%{seconds}s 前",
	};
	const { freshness, label, root, spoken } = buildStatusRoot({
		freshnessGeneration: "0", lastAppliedAtMs: "", paused: "false", requestGeneration: "0",
		refreshLabels: JSON.stringify(refreshLabels),
	});
	const context = { el: root, pushEvent() {} };
	const hook = createObservatoryRefreshHook({ clock, documentTarget });
	hook.mounted.call(context);
	assert.equal(label.textContent, "正在更新用量");
	assert.equal(freshness.attrs["aria-label"], "实时刷新");
	assert.equal(spoken.textContent, "实时");
	root.dataset.freshnessGeneration = "1";
	root.dataset.lastAppliedAtMs = "5000";
	hook.updated.call(context);
	clock.advanceBy(4_000);
	assert.equal(label.textContent, "4s 前");
	root.dataset.paused = "true";
	hook.updated.call(context);
	assert.equal(label.textContent, "更新已暂停");
	assert.equal(freshness.attrs["aria-label"], "刷新已暂停");
	assert.equal(spoken.textContent, "已暂停");
	root.dataset.paused = "false";
	hook.updated.call(context);
	documentTarget.setVisibility("hidden");
	assert.equal(label.textContent, "隐藏时暂停更新");
	assert.equal(freshness.attrs["aria-label"], "标签页隐藏时暂停刷新");
	assert.equal(spoken.textContent, "隐藏时已暂停");
	hook.disconnected.call(context);
	assert.equal(label.textContent, "连接中断");
	assert.equal(freshness.attrs["aria-label"], "刷新已断开");
	assert.equal(spoken.textContent, "已断开连接");
	hook.destroyed.call(context);
});

test("refresh hook keeps English for malformed labels and consumes changed translations after a patch", () => {
	const clock = new FakeClock();
	const documentTarget = new FakeDocument();
	const { label, root, spoken } = buildStatusRoot({
		freshnessGeneration: "0", lastAppliedAtMs: "", paused: "false", requestGeneration: "0",
		refreshLabels: "invalid-json",
	});
	const context = { el: root, pushEvent() {} };
	const hook = createObservatoryRefreshHook({ clock, documentTarget });
	hook.mounted.call(context);
	assert.equal(label.textContent, "Updating usage");
	assert.equal(spoken.textContent, "Live");
	root.dataset.refreshLabels = JSON.stringify({ updatingLabel: "正在更新用量", liveSpoken: "实时" });
	hook.updated.call(context);
	assert.equal(label.textContent, "正在更新用量");
	assert.equal(spoken.textContent, "实时");
	hook.destroyed.call(context);
});
