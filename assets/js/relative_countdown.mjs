const REPAINT_INTERVAL_MS = 30_000;
const MINUTE_SECONDS = 60;
const HOUR_SECONDS = 60 * MINUTE_SECONDS;
const DAY_SECONDS = 24 * HOUR_SECONDS;

const defaultClock = {
	now: () => Date.now(),
	setTimeout: (callback, delay) => globalThis.setTimeout(callback, delay),
	clearTimeout: (timer) => globalThis.clearTimeout(timer),
};

const durationParts = (parts) =>
	parts
		.filter(([value]) => value > 0)
		.map(([value, unit]) => `${value}${unit}`)
		.join(" ");

export const formatRelativeCountdown = (resetAt, now = Date.now()) => {
	const resetAtMs = Date.parse(resetAt);
	if (!Number.isFinite(resetAtMs)) return null;

	const seconds = Math.ceil((resetAtMs - now) / 1_000);
	if (seconds <= 0) return "due";

	if (seconds >= DAY_SECONDS) {
		const days = Math.floor(seconds / DAY_SECONDS);
		const hours = Math.floor((seconds % DAY_SECONDS) / HOUR_SECONDS);
		return durationParts([
			[days, "d"],
			[hours, "h"],
		]);
	}

	if (seconds >= HOUR_SECONDS) {
		const totalMinutes = Math.ceil(seconds / MINUTE_SECONDS);
		const hours = Math.floor(totalMinutes / MINUTE_SECONDS);
		const minutes = totalMinutes % MINUTE_SECONDS;
		return durationParts([
			[hours, "h"],
			[minutes, "m"],
		]);
	}

	if (seconds >= MINUTE_SECONDS) {
		return `${Math.ceil(seconds / MINUTE_SECONDS)}m`;
	}

	return "<1m";
};

export const createRelativeCountdownController = ({
	clock = defaultClock,
	onLabel,
	resetAt,
}) => {
	let destroyed = false;
	let started = false;
	let timer = null;
	let target = resetAt;

	const clearTimer = () => {
		if (timer === null) return;
		clock.clearTimeout(timer);
		timer = null;
	};

	const repaint = () => {
		const label = formatRelativeCountdown(target, clock.now());
		if (label === null) return false;

		onLabel(label);
		return label !== "due";
	};

	const schedule = () => {
		clearTimer();
		if (!started || destroyed || !repaint()) return;

		const resetAtMs = Date.parse(target);
		const remainingMs = Math.max(0, resetAtMs - clock.now());
		timer = clock.setTimeout(tick, Math.min(REPAINT_INTERVAL_MS, remainingMs));
	};

	const tick = () => {
		timer = null;
		schedule();
	};

	return {
		start() {
			if (started || destroyed) return;
			started = true;
			schedule();
		},
		sync(nextResetAt) {
			if (destroyed) return;
			target = nextResetAt;
			schedule();
		},
		destroy() {
			destroyed = true;
			clearTimer();
		},
	};
};

export const createRelativeCountdownHook = () => ({
	mounted() {
		this.value = this.el.querySelector("[data-role='relative-countdown-value']");
		this.controller = createRelativeCountdownController({
			onLabel: (label) => {
				if (this.value) this.value.textContent = label;
			},
			resetAt: this.el.dataset.countdownAt,
		});
		this.controller.start();
	},
	updated() {
		this.value = this.el.querySelector("[data-role='relative-countdown-value']");
		this.controller.sync(this.el.dataset.countdownAt);
	},
	destroyed() {
		this.controller.destroy();
	},
});

export const RelativeCountdown = createRelativeCountdownHook();
