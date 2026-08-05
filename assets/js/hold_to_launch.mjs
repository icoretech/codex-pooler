const HOLD_MS = 1000;
const DRAIN_MS = 150;
export const HOLD_RING_CIRCUMFERENCE = 75.4;

const defaultFrames = {
	now: () => performance.now(),
	request: (callback) => globalThis.requestAnimationFrame(callback),
	cancel: (id) => globalThis.cancelAnimationFrame(id),
};

// Press-and-hold confirmation: progress runs 0..1 over holdMs while pressed.
// Releasing at 1 launches; releasing earlier drains the progress back to 0.
// The launch fires from release() — in the hook that is a pointerup handler,
// a genuine user gesture, so window.open is not popup-blocked.
export const createHoldToLaunchController = ({
	frames = defaultFrames,
	holdMs = HOLD_MS,
	drainMs = DRAIN_MS,
	onProgress,
	onState,
	onLaunch,
}) => {
	let destroyed = false;
	let holding = false;
	let armed = false;
	let frame = null;
	let pressedAt = 0;
	let progress = 0;

	const cancelFrame = () => {
		if (frame === null) return;
		frames.cancel(frame);
		frame = null;
	};

	const paint = (value) => {
		progress = value;
		onProgress(value);
	};

	const fillTick = () => {
		frame = null;
		if (destroyed || !holding) return;
		paint(Math.min(1, (frames.now() - pressedAt) / holdMs));
		if (progress >= 1) {
			if (!armed) {
				armed = true;
				onState("armed");
			}
			return;
		}
		frame = frames.request(fillTick);
	};

	const drainFrom = (start) => {
		const drainedAt = frames.now();
		const drainTick = () => {
			frame = null;
			if (destroyed || holding) return;
			const remaining = start * (1 - (frames.now() - drainedAt) / drainMs);
			paint(Math.max(0, remaining));
			if (progress > 0) {
				frame = frames.request(drainTick);
			} else {
				onState("idle");
			}
		};
		frame = frames.request(drainTick);
	};

	return {
		press() {
			if (destroyed || holding) return;
			holding = true;
			armed = false;
			cancelFrame();
			pressedAt = frames.now();
			paint(0);
			onState("holding");
			frame = frames.request(fillTick);
		},
		release() {
			if (destroyed || !holding) return;
			holding = false;
			cancelFrame();
			if (armed) {
				armed = false;
				paint(0);
				onState("launched");
				onLaunch();
			} else {
				drainFrom(progress);
			}
		},
		cancel() {
			if (destroyed || !holding) return;
			holding = false;
			armed = false;
			cancelFrame();
			drainFrom(progress);
		},
		destroy() {
			destroyed = true;
			cancelFrame();
		},
	};
};

export const createHoldToLaunchHook = () => ({
	mounted() {
		const fill = this.el.querySelector(
			"[data-role='admin-nav-hold-ring-fill']",
		);

		this.holdController = createHoldToLaunchController({
			onProgress: (progress) => {
				if (fill) {
					fill.style.strokeDashoffset = String(
						HOLD_RING_CIRCUMFERENCE * (1 - progress),
					);
				}
			},
			onState: (state) => {
				if (state === "idle") {
					delete this.el.dataset.holdState;
				} else {
					this.el.dataset.holdState = state;
				}
				if (state === "launched") {
					globalThis.setTimeout(() => {
						if (this.el.dataset.holdState === "launched") {
							delete this.el.dataset.holdState;
						}
					}, 400);
				}
			},
			onLaunch: () => {
				globalThis.open(this.el.href, "_blank", "noopener,noreferrer");
			},
		});

		this.holdAbort = new AbortController();
		const { signal } = this.holdAbort;

		this.el.addEventListener(
			"pointerdown",
			(event) => {
				if (event.button !== 0) return;
				event.preventDefault();
				try {
					this.el.setPointerCapture(event.pointerId);
				} catch {
					// pointer capture is best-effort; the hold works without it
				}
				this.holdController.press();
			},
			{ signal },
		);
		this.el.addEventListener(
			"pointerup",
			() => this.holdController.release(),
			{ signal },
		);
		this.el.addEventListener(
			"pointercancel",
			() => this.holdController.cancel(),
			{ signal },
		);
		// A plain left click is owned by the hold flow; modified clicks and
		// middle-click keep their native open-in-new-tab behavior, and keyboard
		// activation never reaches "click" with these modifiers so Enter still
		// follows target="_blank" directly.
		this.el.addEventListener(
			"click",
			(event) => {
				if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
					return;
				}
				if (event.detail === 0) return;
				event.preventDefault();
			},
			{ signal },
		);
		// A long-press must not summon the context menu mid-hold.
		this.el.addEventListener(
			"contextmenu",
			(event) => event.preventDefault(),
			{ signal },
		);
	},
	destroyed() {
		this.holdAbort?.abort();
		this.holdController?.destroy();
	},
});

export const HoldToLaunch = createHoldToLaunchHook();
