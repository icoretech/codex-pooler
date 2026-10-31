import assert from "node:assert/strict";
import test from "node:test";

import {
	createRelativeCountdownController,
	createRelativeCountdownHook,
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
		formatRelativeCountdown(
			new Date(now + 6 * DAY + 23 * HOUR).toISOString(),
			now,
		),
		"6d 23h",
	);
	assert.equal(
		formatRelativeCountdown(
			new Date(now + HOUR + 30 * MINUTE).toISOString(),
			now,
		),
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
	assert.equal(
		formatRelativeCountdown(new Date(now).toISOString(), now),
		"due",
	);
	assert.equal(formatRelativeCountdown("not-a-date", now), null);
});

test("equivalent ISO offsets preserve the same instant countdown across DST", () => {
	const now = Date.parse("2026-10-25T00:30:00Z");
	const targets = [
		"2026-10-25T02:30:00Z",
		"2026-10-25T04:30:00+02:00",
		"2026-10-24T22:30:00-04:00",
	];

	assert.deepEqual(
		targets.map((target) => formatRelativeCountdown(target, now)),
		["2h", "2h", "2h"],
	);
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

test("start is idempotent and destroy prevents later repaints", () => {
	const clock = new FakeClock(Date.parse("2026-07-23T12:00:00Z"));
	const labels = [];
	const controller = createRelativeCountdownController({
		clock,
		onLabel: (label) => labels.push(label),
		resetAt: new Date(clock.nowMs + HOUR).toISOString(),
	});
	controller.start();
	controller.start();
	assert.equal(clock.timers.size, 1);
	controller.destroy();
	assert.equal(clock.timers.size, 0);
	const count = labels.length;
	clock.advanceBy(HOUR);
	assert.equal(labels.length, count);
});

test("countdown labels interpolate translated sentences without translating compact units", () => {
	const now = Date.parse("2026-07-23T12:00:00Z");
	const labels = { countdownLabel: "将在 %{duration} 后到期。", countdownDueLabel: "已到期" };
	assert.equal(formatRelativeCountdown(new Date(now + HOUR + 30 * MINUTE).toISOString(), now, labels), "将在 1h 30m 后到期。");
	assert.equal(formatRelativeCountdown(new Date(now).toISOString(), now, labels), "将在 已到期 后到期。");
	assert.equal(formatRelativeCountdown(new Date(now).toISOString(), now, { countdownDueLabel: "已到期" }), "已到期");
});

test("translated due labels still stop scheduling and updated labels are used after patching", () => {
	const now = Date.parse("2026-07-23T12:00:00Z");
	const clock = new FakeClock(now);
	const labels = [];
	const controller = createRelativeCountdownController({
		clock,
		onLabel: (label) => labels.push(label),
		resetAt: new Date(now + 1_000).toISOString(),
		labels: { countdownDueLabel: "已到期" },
	});
	controller.start();
	clock.advanceBy(1_000);
	assert.deepEqual(labels, ["<1m", "已到期"]);
	assert.equal(clock.timers.size, 0);
	controller.sync(new Date(clock.now() + HOUR).toISOString(), { countdownLabel: "剩余 %{duration}", countdownDueLabel: "已到期" });
	assert.equal(labels.at(-1), "剩余 1h");
	controller.destroy();
});

test("countdown hook reads translated data labels on mount and on LiveView updates", () => {
	const now = Date.parse("2026-07-23T12:00:00Z");
	const clock = new FakeClock(now);
	const value = { textContent: "" };
	const context = {
		el: {
			dataset: { countdownAt: new Date(now + HOUR).toISOString() },
			querySelector: () => value,
		},
	};
	const hook = createRelativeCountdownHook({ clock });
	hook.mounted.call(context);
	assert.equal(value.textContent, "1h");
	context.el.dataset = {
		countdownAt: new Date(now + HOUR).toISOString(),
		countdownLabel: "剩余 %{duration}", countdownDueLabel: "已到期",
	};
	hook.updated.call(context);
	assert.equal(value.textContent, "剩余 1h");
	hook.destroyed.call(context);
	assert.equal(clock.timers.size, 0);
});
