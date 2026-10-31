import assert from "node:assert/strict";
import test from "node:test";

import { initLanguageDropdowns } from "./language_dropdown.mjs";

const fixture = () => {
	const root = new EventTarget();
	root.menus = [];
	root.activeElement = null;
	root.querySelectorAll = () => root.menus.filter((menu) => menu.open);
	initLanguageDropdowns(root);

	const createMenu = () => {
		const summary = { focus: () => { root.activeElement = summary; } };
		const option = {};
		const menu = {
			open: true,
			contains: (target) => [menu, summary, option].includes(target),
			removeAttribute: (name) => { if (name === "open") menu.open = false; },
			querySelector: () => summary,
		};
		root.menus.push(menu);
		return { menu, summary, option };
	};

	const dispatch = (type, target, key) => {
		const event = new Event(type, { cancelable: true });
		Object.defineProperty(event, "target", { value: target });
		Object.defineProperty(event, "key", { value: key });
		root.dispatchEvent(event);
		return event;
	};

	return { root, createMenu, dispatch };
};

test("outside clicks close the language menu without cancelling the clicked action", () => {
	const { createMenu, dispatch } = fixture();
	const { menu, summary, option } = createMenu();

	dispatch("click", summary);
	assert.equal(menu.open, true);
	assert.equal(dispatch("click", option).defaultPrevented, false);
	assert.equal(menu.open, true);
	assert.equal(dispatch("click", {}).defaultPrevented, false);
	assert.equal(menu.open, false);
});

test("delegated dismissal handles menus replaced by navigation", () => {
	const { root, createMenu, dispatch } = fixture();
	createMenu();
	root.menus = [];
	const { menu } = createMenu();

	dispatch("click", {});
	assert.equal(menu.open, false);
});

test("Escape closes the active language menu, restores trigger focus and does not dismiss a parent overlay", () => {
	const { root, createMenu, dispatch } = fixture();
	const first = createMenu();
	const active = createMenu();
	root.activeElement = active.option;
	let parentDismissed = false;
	root.addEventListener("keydown", () => { parentDismissed = true; });

	const event = dispatch("keydown", active.option, "Escape");
	assert.equal(first.menu.open, false);
	assert.equal(active.menu.open, false);
	assert.equal(root.activeElement, active.summary);
	assert.equal(event.defaultPrevented, true);
	assert.equal(parentDismissed, false);
});

test("other keys and Escape without an open language menu keep their normal behavior", () => {
	const { createMenu, dispatch } = fixture();
	const { menu, option } = createMenu();
	assert.equal(dispatch("keydown", option, "Enter").defaultPrevented, false);
	assert.equal(menu.open, true);
	menu.open = false;
	assert.equal(dispatch("keydown", option, "Escape").defaultPrevented, false);
});
