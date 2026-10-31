import { hookLabel } from "./hook_labels.mjs";

export const createClipboardCopyHook = ({
	clipboard = () => globalThis.navigator.clipboard,
	timers = globalThis,
} = {}) => ({
	mounted() {
		this.handleCopy = async () => {
			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			timers.clearTimeout(this.timeout);
			await clipboard().writeText(this.el.dataset.copyText);

			if (label) {
				label.textContent = hookLabel(this.el.dataset, "copiedLabel", "Copied");
			}

			icon?.classList.remove("hero-clipboard-document");
			icon?.classList.add("hero-check");
			this.el.classList.add("btn-success");

			this.timeout = timers.setTimeout(() => {
				icon?.classList.remove("hero-check");
				icon?.classList.add("hero-clipboard-document");
				this.el.classList.remove("btn-success");

				if (label) {
					label.textContent = hookLabel(this.el.dataset, "copyLabel", "Copy");
				}
			}, 1400);
		};
		this.el.addEventListener("click", this.handleCopy);
	},
	destroyed() {
		this.el.removeEventListener("click", this.handleCopy);
		timers.clearTimeout(this.timeout);
	},
});

export const ClipboardCopy = createClipboardCopyHook();
