import { hookLabel } from "./hook_labels.mjs";

export const createTotpSetupToolsHook = (renderSVG) => ({
	mounted() {
		this.renderQr();
	},
	updated() {
		this.renderQr();
	},
	renderQr() {
		const target = this.el.querySelector("[data-totp-qr]");
		const uri = this.el.dataset.otpauthUri;
		if (!target || !uri) return;

		try {
			const size = Number.parseInt(target.dataset.qrSize || "176", 10);
			const svg = renderSVG(uri, { border: 1 })
				.replaceAll('fill="white"', 'fill="#f7f7f7"')
				.replaceAll('fill="black"', 'fill="#0e0e0e"');
			target.innerHTML = svg;
			const rendered = target.querySelector("svg");
			rendered?.setAttribute("width", size.toString());
			rendered?.setAttribute("height", size.toString());
			rendered?.setAttribute("role", "img");
			rendered?.setAttribute("aria-label", hookLabel(this.el.dataset, "qrLabel", "Authenticator app QR code"));
		} catch (_error) {
			target.replaceWith(
				Object.assign(this.el.ownerDocument.createElement("p"), {
					className: "text-sm text-error",
					textContent: hookLabel(this.el.dataset, "qrErrorLabel", "QR code could not be rendered"),
				}),
			);
		}
	},
});

export const CallyDatePicker = {
	mounted() {
		this.input = this.el.querySelector("input[type='hidden']");
		this.calendar = this.el.querySelector("calendar-date");
		this.label = this.el.querySelector("[data-role='cally-date-label']");
		this.popover = this.el.querySelector("[popover]");
		this.handleChange = (event) => this.selectDate(event.target.value);
		this.handleClear = () => this.selectDate("");
		this.handleCancel = () => this.close();

		this.calendar?.addEventListener("change", this.handleChange);
		this.el.querySelector("[data-role='cally-clear']")?.addEventListener("click", this.handleClear);
		this.el.querySelector("[data-role='cally-cancel']")?.addEventListener("click", this.handleCancel);
		this.sync();
	},
	updated() {
		this.sync();
	},
	destroyed() {
		this.calendar?.removeEventListener("change", this.handleChange);
		this.el.querySelector("[data-role='cally-clear']")?.removeEventListener("click", this.handleClear);
		this.el.querySelector("[data-role='cally-cancel']")?.removeEventListener("click", this.handleCancel);
	},
	selectDate(value) {
		if (!this.input) return;
		this.input.value = value || "";
		this.sync();
		this.input.dispatchEvent(new Event("input", { bubbles: true }));
		this.input.dispatchEvent(new Event("change", { bubbles: true }));
		this.close();
	},
	sync() {
		const value = this.input?.value || "";
		if (this.calendar && this.calendar.value !== value) this.calendar.value = value;
		if (this.label) {
			this.label.textContent = value
				? this.formatDate(value)
				: hookLabel(this.el.dataset, "placeholder", "dd/mm/yyyy");
		}
	},
	close() {
		this.popover?.hidePopover?.();
	},
	formatDate(value) {
		const [year, month, day] = value.split("-").map(Number);
		if (!year || !month || !day) return value;
		return new Intl.DateTimeFormat(this.el.dataset.locale || "en-GB", {
			day: "2-digit",
			month: "2-digit",
			year: "numeric",
		}).format(new Date(year, month - 1, day));
	},
};
