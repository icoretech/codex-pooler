import assert from "node:assert/strict";
import test from "node:test";

import { createHoldToLaunchController } from "./hold_to_launch.mjs";

class FakeFrames {
	constructor() {
		this.nowMs = 0;
		this.nextId = 1;
		this.callbacks = new Map();
	}

	now = () => this.nowMs;

	request = (callback) => {
		const id = this.nextId++;
		this.callbacks.set(id, callback);
		return id;
	};

	cancel = (id) => this.callbacks.delete(id);

	advanceBy(milliseconds, step = 16) {
		const target = this.nowMs + milliseconds;
		while (this.nowMs < target) {
			this.nowMs = Math.min(target, this.nowMs + step);
			this.flush();
		}
	}

	flush() {
		const due = [...this.callbacks.entries()];
		this.callbacks.clear();
		for (const [, callback] of due) callback(this.nowMs);
	}

	get pending() {
		return this.callbacks.size;
	}
}

const build = (overrides = {}) => {
	const frames = new FakeFrames();
	const events = [];
	const controller = createHoldToLaunchController({
		frames,
		holdMs: 1000,
		drainMs: 150,
		onProgress: (progress) => events.push(["progress", progress]),
		onState: (state) => events.push(["state", state]),
		onLaunch: () => events.push(["launch"]),
		...overrides,
	});
	return { frames, events, controller };
};

const states = (events) =>
	events.filter(([kind]) => kind === "state").map(([, state]) => state);

const launches = (events) =>
	events.filter(([kind]) => kind === "launch").length;

const lastProgress = (events) => {
	const values = events
		.filter(([kind]) => kind === "progress")
		.map(([, value]) => value);
	return values.at(-1);
};

test("holding to completion arms once and launches on release", () => {
	const { frames, events, controller } = build();

	controller.press();
	frames.advanceBy(1100);

	assert.deepEqual(states(events), ["holding", "armed"]);
	assert.equal(lastProgress(events), 1);
	assert.equal(launches(events), 0);

	controller.release();
	assert.deepEqual(states(events), ["holding", "armed", "launched"]);
	assert.equal(launches(events), 1);
	assert.equal(lastProgress(events), 0);
	assert.equal(frames.pending, 0);
});

test("an early release never launches and drains back to zero", () => {
	const { frames, events, controller } = build();

	controller.press();
	frames.advanceBy(400);
	assert.ok(lastProgress(events) < 1);

	controller.release();
	frames.advanceBy(300);

	assert.equal(launches(events), 0);
	assert.equal(lastProgress(events), 0);
	assert.deepEqual(states(events), ["holding", "idle"]);
	assert.equal(frames.pending, 0);
});

test("pointercancel while armed drains without launching", () => {
	const { frames, events, controller } = build();

	controller.press();
	frames.advanceBy(1100);
	assert.deepEqual(states(events), ["holding", "armed"]);

	controller.cancel();
	frames.advanceBy(300);

	assert.equal(launches(events), 0);
	assert.equal(lastProgress(events), 0);
	assert.equal(states(events).at(-1), "idle");
});

test("pressing again mid-drain restarts the fill from zero", () => {
	const { frames, events, controller } = build();

	controller.press();
	frames.advanceBy(600);
	controller.release();
	frames.advanceBy(30);

	controller.press();
	assert.equal(lastProgress(events), 0);
	frames.advanceBy(1100);
	controller.release();

	assert.equal(launches(events), 1);
});

test("destroy cancels pending frames and ignores later input", () => {
	const { frames, events, controller } = build();

	controller.press();
	frames.advanceBy(200);
	controller.destroy();

	assert.equal(frames.pending, 0);
	const seen = events.length;
	controller.press();
	controller.release();
	frames.advanceBy(2000);
	assert.equal(events.length, seen);
	assert.equal(launches(events), 0);
});
