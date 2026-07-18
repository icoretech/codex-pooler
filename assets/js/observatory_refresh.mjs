const REFRESH_INTERVAL_MS = 30_000;
const FRESHNESS_REPAINT_MS = 1_000;
let observatoryPaused = false;

export const observatoryRefreshConnectParams = () => ({
	observatory_paused: observatoryPaused,
});

const defaultClock = {
	now: () => Date.now(),
	setTimeout: (callback, delay) => globalThis.setTimeout(callback, delay),
	clearTimeout: (timer) => globalThis.clearTimeout(timer),
};

const parseNumber = (value) => {
	if (value === null || value === undefined || value === "") return null;
	const number = Number(value);
	return Number.isFinite(number) ? number : null;
};

const statusFor = ({ connected, now, paused, receiptAt, visible }) => {
	if (!connected) {
		return {
			ariaLabel: "Refresh disconnected",
			kind: "disconnected",
			label: "Connection interrupted",
			spoken: "Disconnected",
		};
	}
	if (paused) {
		return {
			ariaLabel: "Refresh paused",
			kind: "paused",
			label: "Updates paused",
			spoken: "Paused",
		};
	}
	if (!visible) {
		return {
			ariaLabel: "Refresh paused while tab hidden",
			kind: "hidden",
			label: "Updates paused while hidden",
			spoken: "Paused while hidden",
		};
	}
	if (receiptAt === null) {
		return {
			ariaLabel: "Refresh live",
			kind: "live",
			label: "Updating usage",
			spoken: "Live",
		};
	}

	const seconds = Math.max(0, Math.floor((now - receiptAt) / 1_000));
	return {
		ariaLabel: "Refresh live",
		kind: "live",
		label: `Updated ${seconds}s ago`,
		spoken: "Live",
	};
};

export const createObservatoryRefreshController = ({
	clock = defaultClock,
	documentTarget,
	initiallyPaused = false,
	lastAppliedAtMs = null,
	freshnessGeneration = null,
	onRefresh,
	onStatus,
}) => {
	let active = false;
	let lastFreshnessGeneration = parseNumber(freshnessGeneration);
	let receiptAt = parseNumber(lastAppliedAtMs) === null ? null : clock.now();
	let connected = true;
	let destroyed = false;
	let lastRequestGeneration = null;
	let nextRefreshAt = clock.now() + REFRESH_INTERVAL_MS;
	let paused = initiallyPaused;
	let started = false;
	let timer = null;
	let visible = documentTarget.visibilityState === "visible";

	const clearTimer = () => {
		if (timer === null) return;
		clock.clearTimeout(timer);
		timer = null;
	};
	const isActive = () => connected && visible && !paused;
	const repaint = () => {
		onStatus(
			statusFor({ connected, now: clock.now(), paused, receiptAt, visible }),
		);
	};
	const requestRefresh = (reason) => {
		nextRefreshAt = clock.now() + REFRESH_INTERVAL_MS;
		onRefresh(reason);
	};
	const schedule = () => {
		clearTimer();
		if (!started || destroyed || !active) return;
		const untilRefresh = Math.max(0, nextRefreshAt - clock.now());
		const delay = Math.min(FRESHNESS_REPAINT_MS, untilRefresh);
		timer = clock.setTimeout(tick, delay);
	};
	const reconcile = (activationReason) => {
		const wasActive = active;
		active = isActive();
		clearTimer();
		if (active && !wasActive && activationReason)
			requestRefresh(activationReason);
		repaint();
		schedule();
	};
	const tick = () => {
		timer = null;
		if (!active || destroyed) return;
		if (clock.now() >= nextRefreshAt) requestRefresh("periodic");
		repaint();
		schedule();
	};
	const visibilityChanged = () => {
		visible = documentTarget.visibilityState === "visible";
		reconcile(visible ? "visibility" : null);
	};

	return {
		start() {
			if (started || destroyed) return;
			started = true;
			documentTarget.addEventListener("visibilitychange", visibilityChanged);
			reconcile("initial");
		},
		pause() {
			if (paused || destroyed) return;
			paused = true;
			reconcile(null);
		},
		resume() {
			if (!paused || destroyed) return;
			paused = false;
			reconcile("resume");
		},
		disconnect() {
			if (!connected || destroyed) return;
			connected = false;
			reconcile(null);
		},
		reconnect() {
			if (connected || destroyed) return;
			connected = true;
			reconcile("reconnect");
		},
		syncPaused(value) {
			if (value === paused || destroyed) return;
			paused = value;
			reconcile(value ? null : "resume");
		},
		syncAppliedAt(value, freshnessGeneration) {
			const nextAppliedAt = parseNumber(value);
			const nextFreshnessGeneration = parseNumber(freshnessGeneration);
			if (
				destroyed ||
				nextAppliedAt === null ||
				nextFreshnessGeneration === null
			)
				return;
			if (nextFreshnessGeneration === lastFreshnessGeneration) {
				return;
			}
			lastFreshnessGeneration = nextFreshnessGeneration;
			receiptAt = clock.now();
			repaint();
		},
		markRequested(generation) {
			if (generation === lastRequestGeneration || destroyed) return;
			lastRequestGeneration = generation;
			nextRefreshAt = clock.now() + REFRESH_INTERVAL_MS;
			schedule();
		},
		destroy() {
			if (destroyed) return;
			destroyed = true;
			clearTimer();
			documentTarget.removeEventListener("visibilitychange", visibilityChanged);
		},
	};
};

const renderStatus = (root, status) => {
	const freshness = root.querySelector("#observatory-freshness");
	const label = root.querySelector("[data-role='observatory-freshness-label']");
	const spoken = root.querySelector("[data-role='observatory-refresh-status']");
	if (!freshness || !label || !spoken) return;

	freshness.dataset.refreshState = status.kind;
	freshness.classList.toggle("is-paused", status.kind !== "live");
	freshness.setAttribute("aria-label", status.ariaLabel);
	label.textContent = status.label;
	spoken.textContent = status.spoken;
};

const replacementRefreshAction = (action) => {
	if (action === "pause") return "resume";
	if (action === "resume") return "pause";
	return null;
};

export const createObservatoryRefreshHook = (options = {}) => ({
	mounted() {
		const documentTarget = options.documentTarget ?? globalThis.document;
		const initiallyPaused = this.el.dataset.paused === "true";
		observatoryPaused = initiallyPaused;
		this.observatoryRefreshFocusAction = null;
		const controller = createObservatoryRefreshController({
			clock: options.clock ?? defaultClock,
			documentTarget,
			initiallyPaused,
			lastAppliedAtMs: this.el.dataset.lastAppliedAtMs,
			freshnessGeneration: this.el.dataset.freshnessGeneration,
			onRefresh: (reason) => {
				const event =
					reason === "resume" ? "resume-refresh" : "observatory-refresh";
				this.pushEvent(event, { reason }, () => {});
			},
			onStatus: (status) => renderStatus(this.el, status),
		});
		const clickListener = (event) => {
			const action = event.target?.closest?.(
				"[data-observatory-refresh-action]",
			);
			if (!action || !this.el.contains(action)) return;
			event.preventDefault();
			const refreshAction = action.dataset.observatoryRefreshAction;
			if (documentTarget.activeElement === action) {
				this.observatoryRefreshFocusAction =
					replacementRefreshAction(refreshAction);
			}
			if (refreshAction === "pause") {
				observatoryPaused = true;
				controller.pause();
				this.pushEvent("pause-refresh", {}, () => {});
			} else if (refreshAction === "resume") {
				observatoryPaused = false;
				controller.resume();
			}
		};

		this.observatoryRefreshController = controller;
		this.observatoryRefreshClickListener = clickListener;
		this.el.addEventListener("click", clickListener);
		controller.markRequested(parseNumber(this.el.dataset.requestGeneration));
		controller.start();
	},
	updated() {
		const paused = this.el.dataset.paused === "true";
		observatoryPaused = paused;
		this.observatoryRefreshController.syncPaused(paused);
		this.observatoryRefreshController.syncAppliedAt(
			this.el.dataset.lastAppliedAtMs,
			this.el.dataset.freshnessGeneration,
		);
		this.observatoryRefreshController.markRequested(
			parseNumber(this.el.dataset.requestGeneration),
		);
		const replacement = this.observatoryRefreshFocusAction
			? this.el.querySelector(
					`[data-observatory-refresh-action='${this.observatoryRefreshFocusAction}']`,
			  )
			: null;
		if (replacement) {
			this.observatoryRefreshFocusAction = null;
			replacement.focus({ preventScroll: true });
		}
	},
	disconnected() {
		this.observatoryRefreshController.disconnect();
	},
	reconnected() {
		this.observatoryRefreshController.reconnect();
	},
	destroyed() {
		observatoryPaused = false;
		this.el.removeEventListener("click", this.observatoryRefreshClickListener);
		this.observatoryRefreshController.destroy();
	},
});

export const ObservatoryRefresh = createObservatoryRefreshHook();
