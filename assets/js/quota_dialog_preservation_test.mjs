import assert from "node:assert/strict";
import test from "node:test";

import { createQuotaDialogPreservation } from "./quota_dialog_preservation.js";

// A DOM fixture drives the public callbacks; real native dialog/browser coverage
// belongs to the viewport acceptance scenario.
class Element {
	constructor(tagName, id = "", attributes = {}) {
		this.tagName = tagName.toUpperCase();
		this.id = id;
		this.attributes = new Map(Object.entries(attributes));
		this.children = [];
		this.scrollTop = 0;
		this.scrollLeft = 0;
		this.visible = true;
		this.focusCalls = [];
	}
	append(child) {
		child.parentElement = this;
		child.ownerDocument = this.ownerDocument;
		this.children.push(child);
		return child;
	}
	hasAttribute(name) { return this.attributes.has(name); }
	getAttribute(name) { return this.attributes.get(name) ?? null; }
	setAttribute(name, value) { this.attributes.set(name, value); }
	removeAttribute(name) { this.attributes.delete(name); }
	matches(selector) {
		const match = selector.match(/^(\w+)?\[([^\]=]+)(?:=['"]?([^'"\]]+)['"]?)?\]$/);
		return Boolean(match && (!match[1] || this.tagName === match[1].toUpperCase()) && this.hasAttribute(match[2]) && (!match[3] || this.getAttribute(match[2]) === match[3]));
	}
	querySelectorAll(selector) {
		return this.children.flatMap(child => [
			...(child.matches(selector) ? [child] : []),
			...child.querySelectorAll(selector),
		]);
	}
	querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
	contains(child) { return this === child || this.children.some(node => node.contains(child)); }
	closest(selector) {
		return selector.split(", ").some(part => this.matches(part)) ? this : this.parentElement?.closest(selector) ?? null;
	}
	get isConnected() { return this.ownerDocument.root.contains(this); }
	getClientRects() { return this.checkVisibility() ? [{}] : []; }
	checkVisibility() { return this.visible && (!this.parentElement || this.parentElement.checkVisibility()); }
	focus(options) {
		this.focusCalls.push(options);
		this.ownerDocument.activeElement = this;
	}
}

const fixture = () => {
	const root = new Element("section", "page");
	const document = {
		root,
		activeElement: null,
		getElementById(id) {
			const walk = element => element.id === id ? element : element.children.map(walk).find(Boolean);
			return walk(root) ?? null;
		},
	};
	root.ownerDocument = document;
	const dialog = root.append(new Element("dialog", "quota-dialog", {"open": "", "data-preserve-open": "", "data-quota-dialog-preserve": ""}));
	const heading = dialog.append(new Element("h2", "quota-heading", {"data-dialog-focus-fallback": ""}));
	const scroll = dialog.append(new Element("div", "quota-scroll", {"data-preserve-scroll": ""}));
	const details = scroll.append(new Element("details", "retained-source", {"open": "", "data-preserve-open": ""}));
	const summary = details.append(new Element("summary", "retained-summary"));
	const close = dialog.append(new Element("button", "quota-close", {"data-role": "dialog-dismiss"}));
	const opener = root.append(new Element("button", "quota-opener"));
	scroll.scrollTop = 137;
	scroll.scrollLeft = 4;
	summary.focus();
	return {root, document, dialog, heading, scroll, details, summary, close, opener, callbacks: createQuotaDialogPreservation()};
};

test("patch retains open native dialog, expanded surviving source, focus and scroll while values change", () => {
	const f = fixture();
	f.callbacks.onPatchStart(f.root);
	const nextDialog = new Element("dialog", "quota-dialog", {"data-preserve-open": "", "data-quota-dialog-preserve": ""});
	f.callbacks.onBeforeElUpdated(f.dialog, nextDialog);
	assert.equal(nextDialog.hasAttribute("open"), true);
	const nextDetails = new Element("details", "retained-source", {"data-preserve-open": ""});
	f.callbacks.onBeforeElUpdated(f.details, nextDetails);
	assert.equal(nextDetails.hasAttribute("open"), true);
	f.summary.textContent = "Usage API 68% remaining; evidence as of updated time";
	f.scroll.scrollTop = 0;
	f.scroll.scrollLeft = 0;
	f.callbacks.onPatchEnd(f.root);
	assert.equal(f.document.activeElement, f.summary);
	assert.equal(f.summary.focusCalls.length, 1, "surviving focused control is never refocused");
	assert.equal(f.scroll.scrollTop, 137);
	assert.equal(f.scroll.scrollLeft, 4);
	assert.match(f.summary.textContent, /68%/);
});

test("client-collapsed source stays collapsed when a new candidate requests default expansion", () => {
	const f = fixture();
	f.details.removeAttribute("open");
	const next = new Element("details", f.details.id, {"data-preserve-open": "", "open": ""});
	f.callbacks.onBeforeElUpdated(f.details, next);
	assert.equal(next.hasAttribute("open"), false);
});

test("subtree patches restore a replaced surviving control by stable id", () => {
	const f = fixture();
	f.callbacks.onPatchStart(f.scroll);
	const replacement = new Element("summary", f.summary.id);
	f.details.children = [];
	f.details.append(replacement);
	f.document.activeElement = null;
	f.scroll.scrollTop = 0;
	f.callbacks.onPatchEnd(f.scroll);
	assert.equal(f.document.activeElement, replacement);
	assert.deepEqual(replacement.focusCalls, [{preventScroll: true}]);
	assert.equal(f.scroll.scrollTop, 137);
});

test("each patch captures current user scroll and discards its snapshot after completion", () => {
	const f = fixture();
	for (const position of [137, 251]) {
		f.scroll.scrollTop = position;
		f.callbacks.onPatchStart(f.root);
		f.scroll.scrollTop = 0;
		f.callbacks.onPatchEnd(f.root);
		assert.equal(f.scroll.scrollTop, position);
	}
	f.scroll.scrollTop = 33;
	f.opener.focus();
	f.callbacks.onPatchEnd(f.root);
	assert.equal(f.scroll.scrollTop, 33);
	assert.equal(f.document.activeElement, f.opener);
});

for (const change of ["removed", "hidden", "disabled"]) {
	test(`${change} selected source/control moves focus to the visible heading without resetting scroll`, () => {
		const f = fixture();
		f.callbacks.onPatchStart(f.root);
		if (change === "removed") f.scroll.children = [];
		if (change === "hidden") f.details.visible = false;
		if (change === "disabled") f.summary.setAttribute("disabled", "");
		f.scroll.scrollTop = 0;
		f.callbacks.onPatchEnd(f.root);
		assert.equal(f.document.activeElement, f.heading);
		assert.deepEqual(f.heading.focusCalls, [{preventScroll: true}]);
		assert.equal(f.scroll.scrollTop, 137);
		if (change === "removed") assert.equal(f.document.getElementById(f.summary.id), null);
	});
}

test("hidden heading falls back to the close control", () => {
	const f = fixture();
	f.callbacks.onPatchStart(f.root);
	f.scroll.children = [];
	f.heading.visible = false;
	f.callbacks.onPatchEnd(f.root);
	assert.equal(f.document.activeElement, f.close);
});

test("closed/removed dialog and completed callbacks never revive stale focus or open state", () => {
	for (const change of ["closed", "removed"]) {
		const f = fixture();
		f.callbacks.onPatchStart(f.root);
		if (change === "closed") f.dialog.removeAttribute("open");
		if (change === "removed") f.root.children = [f.opener];
		f.opener.focus();
		f.callbacks.onPatchEnd(f.root);
		f.callbacks.onPatchEnd(f.root);
		assert.equal(f.document.activeElement, f.opener);
		assert.equal(f.opener.focusCalls.length, 1);
	}
});

test("unrelated patches and controls outside the dialog never move focus", () => {
	const f = fixture();
	f.opener.focus();
	f.callbacks.onPatchStart(f.scroll);
	f.callbacks.onPatchEnd(f.scroll);
	assert.equal(f.document.activeElement, f.opener);
	assert.equal(f.heading.focusCalls.length, 0);
});

test("removed preservation opt-in cannot be copied back and unaffected disclosures retain the existing behavior", () => {
	const f = fixture();
	const removedOptIn = new Element("dialog", f.dialog.id);
	f.callbacks.onBeforeElUpdated(f.dialog, removedOptIn);
	assert.equal(removedOptIn.hasAttribute("open"), false);
	const generic = new Element("details", "generic", {"open": "", "data-preserve-open": ""});
	const nextGeneric = new Element("details", "generic", {"data-preserve-open": ""});
	f.callbacks.onBeforeElUpdated(generic, nextGeneric);
	assert.equal(nextGeneric.hasAttribute("open"), true);
});

test("quota dialog patch preservation leaves translated headings and source labels server-owned", () => {
	const f = fixture();
	f.heading.textContent = "配额证据";
	f.summary.textContent = "Usage API 剩余 68%";
	f.close.setAttribute("aria-label", "关闭配额证据");
	f.callbacks.onPatchStart(f.root);
	f.summary.textContent = "Usage API 剩余 65%";
	f.callbacks.onPatchEnd(f.root);
	assert.equal(f.heading.textContent, "配额证据");
	assert.equal(f.summary.textContent, "Usage API 剩余 65%");
	assert.equal(f.close.getAttribute("aria-label"), "关闭配额证据");
	assert.equal(f.document.activeElement, f.summary);
	assert.equal(f.scroll.scrollTop, 137);
});
