import assert from "node:assert/strict";
import test from "node:test";

import {
	adminEscapeTarget,
	shouldDismissOpenPopoverFromPointer,
} from "./admin_overlay_dismissal.mjs";

test("Escape stays with an open popover instead of dismissing its admin dialog", () => {
	assert.equal(
		adminEscapeTarget({
			key: "Escape",
			hasOpenPopover: true,
			hasOpenDialog: true,
		}),
		"popover",
	);
});

test("Escape dismisses the admin dialog when no popover is open", () => {
	assert.equal(
		adminEscapeTarget({
			key: "Escape",
			hasOpenPopover: false,
			hasOpenDialog: true,
		}),
		"dialog",
	);
});

test("non-Escape keys never dismiss the admin dialog", () => {
	assert.equal(
		adminEscapeTarget({
			key: "Enter",
			hasOpenPopover: false,
			hasOpenDialog: true,
		}),
		"none",
	);
});

test("Escape does nothing when neither a popover nor an admin dialog is open", () => {
	assert.equal(
		adminEscapeTarget({
			key: "Escape",
			hasOpenPopover: false,
			hasOpenDialog: false,
		}),
		"none",
	);
});

test("pointerdown outside an open popover and its invoker dismisses the popover", () => {
	assert.equal(
		shouldDismissOpenPopoverFromPointer({
			hasOpenPopover: true,
			targetInsidePopover: false,
			targetInsideInvoker: false,
		}),
		true,
	);
});

test("pointerdown inside the popover or its invoker preserves the popover", () => {
	assert.equal(
		shouldDismissOpenPopoverFromPointer({
			hasOpenPopover: true,
			targetInsidePopover: true,
			targetInsideInvoker: false,
		}),
		false,
	);

	assert.equal(
		shouldDismissOpenPopoverFromPointer({
			hasOpenPopover: true,
			targetInsidePopover: false,
			targetInsideInvoker: true,
		}),
		false,
	);
});
