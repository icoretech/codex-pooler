import assert from "node:assert/strict";
import test from "node:test";

import { CallyDatePicker, createTotpSetupToolsHook } from "./browser_tools.mjs";

const qrFixture = (dataset = {}) => {
	const attrs = {};
	let replacement;
	const target = {
		dataset: {},
		innerHTML: "",
		querySelector: () => ({ setAttribute: (name, value) => { attrs[name] = value; } }),
		replaceWith: (element) => { replacement = element; },
	};
	const context = {
		el: {
			dataset: { otpauthUri: "otpauth://totp/synthetic-only", ...dataset },
			querySelector: () => target,
			ownerDocument: { createElement: (tagName) => ({ tagName }) },
		},
	};
	return { attrs, context, target, replacement: () => replacement };
};

test("TOTP QR accessible label keeps English fallback and accepts translated data label", () => {
	for (const [dataset, expected] of [[{}, "Authenticator app QR code"], [{ qrLabel: "身份验证器应用二维码" }, "身份验证器应用二维码"]]) {
		const f = qrFixture(dataset);
		const hook = createTotpSetupToolsHook(() => '<svg fill="black"></svg>');
		hook.renderQr.call(f.context);
		assert.equal(f.attrs["aria-label"], expected);
		assert.equal(f.attrs.role, "img");
		assert.equal(f.attrs.width, "176");
		assert.match(f.target.innerHTML, /#0e0e0e/);
	}
});

test("TOTP QR failure renders translated text as text rather than HTML", () => {
	for (const [dataset, expected] of [[{}, "QR code could not be rendered"], [{ qrErrorLabel: "无法显示二维码 <重试>" }, "无法显示二维码 <重试>"]]) {
		const f = qrFixture(dataset);
		const hook = createTotpSetupToolsHook(() => { throw new Error("synthetic render failure"); });
		hook.renderQr.call(f.context);
		assert.equal(f.replacement().tagName, "p");
		assert.equal(f.replacement().textContent, expected);
		assert.equal(f.replacement().innerHTML, undefined);
	}
});

test("calendar preserves English numeric dates and formats Chinese with its server locale", () => {
	for (const [locale, placeholder, expected] of [[undefined, undefined, "dd/mm/yyyy"], ["zh-CN", "日/月/年", "日/月/年"]]) {
		const label = { textContent: "" };
		const context = {
			el: { dataset: { locale, placeholder } },
			input: { value: "" }, calendar: { value: "" }, label,
			formatDate: CallyDatePicker.formatDate,
		};
		CallyDatePicker.sync.call(context);
		assert.equal(label.textContent, expected);
		context.input.value = "2026-10-30";
		CallyDatePicker.sync.call(context);
		const formatted = new Intl.DateTimeFormat(locale || "en-GB", { day: "2-digit", month: "2-digit", year: "numeric" }).format(new Date(2026, 9, 30));
		assert.equal(label.textContent, formatted);
		assert.equal(context.calendar.value, "2026-10-30");
		if (!locale) assert.equal(label.textContent, "30/10/2026");
	}
});
