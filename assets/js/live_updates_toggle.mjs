// Pausing auto-refresh belongs to the reading session, not to the account: a
// second tab stays live, a new tab starts live, and the choice survives moving
// between admin pages. sessionStorage is exactly that scope.
export const LIVE_UPDATES_KEY = "codexPooler.liveUpdatesPaused";

export const readPaused = (storage) => {
	try {
		return storage.getItem(LIVE_UPDATES_KEY) === "true";
	} catch {
		// Private modes and embedded browsers can refuse storage. Live is the safe
		// default: an operator who cannot pause still sees fresh data.
		return false;
	}
};

export const writePaused = (storage, paused) => {
	try {
		storage.setItem(LIVE_UPDATES_KEY, paused ? "true" : "false");
	} catch {
		/* the toggle still works for this page; it just is not remembered */
	}
};

// The accessible name stays put and only the pressed state flips. Naming the
// button for what the next click does, while also reporting pressed, announces
// a contradiction: "Resume live updates, pressed".
export const applyState = (el, paused) => {
	el.dataset.paused = paused ? "true" : "false";
	el.setAttribute("aria-pressed", paused ? "true" : "false");

	el.querySelector('[data-role="live-updates-live"]')?.classList.toggle(
		"hidden",
		paused,
	);
	el.querySelector('[data-role="live-updates-paused"]')?.classList.toggle(
		"hidden",
		!paused,
	);
};

export const buildLiveUpdatesToggle = (storage) => ({
	mounted() {
		this.paused = readPaused(storage);
		this.apply();
		this.report();

		this.handleClick = () => {
			this.paused = !this.paused;
			writePaused(storage, this.paused);
			this.apply();
			this.report();
		};

		this.el.addEventListener("click", this.handleClick);
	},

	// A rejoin is a new LiveView process: mount and every on_mount run again, so
	// the server has forgotten the pause while the button still shows it. Without
	// this the list silently resumes after any network blip or deploy, and the
	// only way out is toggling twice.
	reconnected() {
		this.report();
	},

	// phx-update="ignore" does not protect data-* attributes — LiveView merges
	// those onto ignored elements too — so the state marker has to be reasserted
	// after a patch rather than trusted to survive one.
	updated() {
		this.apply();
	},

	destroyed() {
		this.el?.removeEventListener("click", this.handleClick);
	},

	apply() {
		applyState(this.el, this.paused);
	},

	report() {
		this.pushEvent("set_live_updates", { paused: this.paused });
	},
});

export const LiveUpdatesToggle = buildLiveUpdatesToggle(
	typeof sessionStorage === "undefined" ? null : sessionStorage,
);
