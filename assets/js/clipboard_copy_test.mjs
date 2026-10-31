import assert from "node:assert/strict";
import test from "node:test";

import { createClipboardCopyHook } from "./clipboard_copy.mjs";

const build = (dataset = {}, withLabel = true) => {
	const listeners = new Map();
	const classes = new Set();
	const iconClasses = new Set(["hero-clipboard-document"]);
	const label = { textContent: "" };
	const copied = [];
	const timers = new Map();
	const classList = (set) => ({ add: (value) => set.add(value), remove: (value) => set.delete(value) });
	const el = {
		dataset: { copyText: "synthetic-copy-value", ...dataset },
		classList: classList(classes),
		querySelector: (selector) => selector === ".copy-icon"
			? { classList: classList(iconClasses) }
			: withLabel ? label : null,
		addEventListener: (name, listener) => listeners.set(name, listener),
		removeEventListener: (name, listener) => {
			if (listeners.get(name) === listener) listeners.delete(name);
		},
	};
	const hook = createClipboardCopyHook({
		clipboard: () => ({ writeText: async (text) => copied.push(text) }),
		timers: {
			setTimeout: (callback, delay) => { timers.set(1, { callback, delay }); return 1; },
			clearTimeout: (id) => timers.delete(id),
		},
	});
	const context = { el };
	hook.mounted.call(context);
	return { classes, context, copied, hook, iconClasses, label, listeners, timers };
};

for (const [description, dataset, copiedLabel, copyLabel] of [
	["English fallback", {}, "Copied", "Copy"],
	["translated labels", { copiedLabel: "已复制", copyLabel: "复制密钥" }, "已复制", "复制密钥"],
]) {
	test(`clipboard confirmation and reset use ${description}`, async () => {
		const f = build(dataset);
		await f.listeners.get("click")();
		assert.deepEqual(f.copied, ["synthetic-copy-value"]);
		assert.equal(f.label.textContent, copiedLabel);
		assert.equal(f.classes.has("btn-success"), true);
		assert.equal(f.iconClasses.has("hero-check"), true);
		assert.equal(f.timers.get(1).delay, 1400);
		f.timers.get(1).callback();
		assert.equal(f.label.textContent, copyLabel);
		assert.equal(f.classes.has("btn-success"), false);
		assert.equal(f.iconClasses.has("hero-clipboard-document"), true);
		f.hook.destroyed.call(f.context);
		assert.equal(f.listeners.size, 0);
		assert.equal(f.timers.size, 0);
	});
}

test("icon-only copy retains its server-owned accessible name and creates no text", async () => {
	const f = build({ copyLabel: "复制", copiedLabel: "已复制" }, false);
	f.context.el.ariaLabel = "复制设备代码";
	await f.listeners.get("click")();
	f.timers.get(1).callback();
	assert.equal(f.label.textContent, "");
	assert.equal(f.context.el.ariaLabel, "复制设备代码");
	f.hook.destroyed.call(f.context);
});
