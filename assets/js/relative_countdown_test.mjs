import assert from "node:assert/strict";
import test from "node:test";

import {
	createRelativeCountdownController,
	formatRelativeCountdown,
} from "./relative_countdown.mjs";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

class FakeClock {
	constructor(now) {
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
}

test("formats the compact quota countdown", () => {
	const now = Date.parse("2026-07-23T12:00:00Z");

	assert.equal(
		formatRelativeCountdown(new Date(now + 6 * DAY + 23 * HOUR).toISOString(), now),
		"6d 23h",
	);
	assert.equal(
		formatRelativeCountdown(new Date(now + HOUR + 30 * MINUTE).toISOString(), now),
		"1h 30m",
	);
	assert.equal(
		formatRelativeCountdown(new Date(now + 42 * MINUTE).toISOString(), now),
		"42m",
	);
	assert.equal(
		formatRelativeCountdown(new Date(now + 30_000).toISOString(), now),
		"<1m",
	);
	assert.equal(formatRelativeCountdown(new Date(now).toISOString(), now), "due");
	assert.equal(formatRelativeCountdown("not-a-date", now), null);
});

test("repaints until the reset is due and then stops", () => {
	const now = Date.parse("2026-07-23T12:00:00Z");
	const clock = new FakeClock(now);
	const labels = [];
	const controller = createRelativeCountdownController({
		clock,
		onLabel: (label) => labels.push(label),
		resetAt: new Date(now + 61_000).toISOString(),
	});

	controller.start();
	assert.deepEqual(labels, ["2m"]);

	clock.advanceBy(31_000);
	assert.equal(labels.at(-1), "<1m");

	clock.advanceBy(30_000);
	assert.equal(labels.at(-1), "due");
	assert.equal(clock.timers.size, 0);
});
