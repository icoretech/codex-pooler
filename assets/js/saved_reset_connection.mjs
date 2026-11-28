const policyFields = new Set([
	"auto_redeem_enabled",
	"trigger_mode",
	"quota_threshold_percent",
	"min_blocked_minutes",
	"keep_credits",
]);

// A reconnect carries editable bank state only. The server resolves the account
// against its current scope before restoring this draft; it never saves it.
export const savedResetConnectParams = (root = document) => {
	const form = root.querySelector(
		"#admin-upstreams-live #saved-reset-policy-form",
	);
	const id = form?.dataset.savedResetIdentity;
	if (!id) return {};
	const policy = {};
	for (const input of form.querySelectorAll("input, select")) {
		const key = input.name?.match(/^saved_reset_policy\[([^\]]+)\]$/)?.[1];
		if (
			!policyFields.has(key) ||
			typeof input.value !== "string" ||
			input.value.length > 256
		)
			continue;
		if (["checkbox", "radio"].includes(input.type) && !input.checked) continue;
		policy[key] = input.value;
	}
	return { saved_reset_policy_recovery: { id, policy } };
};

// The list can replace a card while a bank is open. Retain the control's id,
// then resolve the current node after the server removes the dialog.
const bankOpeners = new WeakMap();

export const SavedResetBankDialog = {
	mounted() {
		const list = this.el.closest("#admin-upstreams-live");
		this.returnFocusId =
			bankOpeners.get(list) || this.el.dataset.bankReturnFocus;
		bankOpeners.delete(list);

		// The server renders an open, nonmodal dialog. Promote it to the native
		// top layer so background controls are inert for the entire interaction.
		this.el.close();
		this.el.showModal();
		this.el.querySelector("#saved-reset-policy-dialog-title").focus();
	},
	destroyed() {
		const document = this.el.ownerDocument;
		document.getElementById(this.returnFocusId)?.focus({ preventScroll: true });
	},
};

export const SavedResetConnection = {
	mounted() {
		this.ready = true;
		this.guard = (event) => {
			if (event.type === "click") {
				const opener = event.target.closest?.(
					'[aria-controls="saved-reset-policy-dialog"]',
				);
				if (opener?.id)
					bankOpeners.set(this.el, opener.dataset.bankReturnFocus || opener.id);
			}
			if (event.type === "keydown" && !["Enter", " "].includes(event.key))
				return;
			const target = event.target.closest?.(
				"[data-saved-reset-action], form[data-saved-reset-form]",
			);
			if (!target || !this.el.contains(target)) return;
			// Editing remains local and available. Only activation/submission is gated.
			if (event.type !== "submit" && target.tagName === "FORM") return;
			if (this.ready && this.liveSocket.isConnected()) return;
			this.disconnected();
			event.preventDefault();
			event.stopImmediatePropagation();
		};
		for (const name of ["click", "keydown", "submit"])
			this.el.addEventListener(name, this.guard, true);
		this.sync();
	},
	disconnected() {
		this.ready = false;
		this.sync();
	},
	// Phoenix invokes this after the rejoin mount/params read and join patch.
	// Do not unlock when the transport alone opens or during intervening patches.
	reconnected() {
		this.ready = true;
		this.sync();
	},
	updated() {
		this.sync();
	},
	destroyed() {
		for (const name of ["click", "keydown", "submit"])
			this.el.removeEventListener(name, this.guard, true);
	},
	sync() {
		this.el.dataset.savedResetConnectionState = this.ready
			? "current"
			: "disconnected";
		for (const notice of this.el.querySelectorAll(
			"[data-saved-reset-connection-notice]",
		))
			notice.hidden = this.ready;
		for (const action of this.el.querySelectorAll(
			"[data-saved-reset-action]",
		)) {
			action.disabled =
				!this.ready || action.dataset.serverDisabled !== "false";
			action.setAttribute("aria-disabled", String(action.disabled));
		}
	},
};
