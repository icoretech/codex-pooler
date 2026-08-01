import assert from "node:assert/strict";
import test from "node:test";

import {
	attachChartWheelScroll,
	chartWheelDeltas,
	findScrollableAncestor,
	forwardWheelDeltas,
} from "./chart_wheel_scroll.mjs";

const makeScrollable = (name, dimensions, style = {}) => ({
	name,
	...dimensions,
	style,
	scrollCalls: [],
	scrollBy(options) {
		this.scrollCalls.push(options);
	},
});

const makeEvent = ({ deltaX = 0, deltaY = 0, cancelable = true } = {}) => ({
	deltaX,
	deltaY,
	cancelable,
	preventDefaultCalled: false,
	stopPropagationCalled: false,
	preventDefault() {
		this.preventDefaultCalled = true;
	},
	stopPropagation() {
		this.stopPropagationCalled = true;
	},
});

test("normalizes only finite wheel deltas", () => {
	assert.deepEqual(chartWheelDeltas({ deltaX: 12, deltaY: -48 }), {
		deltaX: 12,
		deltaY: -48,
	});
	assert.deepEqual(chartWheelDeltas({ deltaX: Number.NaN, deltaY: Infinity }), {
		deltaX: 0,
		deltaY: 0,
	});
});

test("forwards vertical and horizontal deltas to their normal scroll containers", () => {
	const horizontalScroller = makeScrollable(
		"chart-scroll-region",
		{
			clientWidth: 320,
			scrollWidth: 640,
			clientHeight: 320,
			scrollHeight: 320,
			scrollLeft: 0,
		},
		{ overflowX: "auto" },
	);
	const verticalScroller = makeScrollable(
		"admin-shell-scroll-region",
		{
			clientWidth: 1024,
			scrollWidth: 1024,
			clientHeight: 650,
			scrollHeight: 1600,
			scrollTop: 400,
		},
		{ overflowY: "auto" },
	);

	const event = makeEvent({ deltaX: 24, deltaY: 96 });

	assert.equal(
		forwardWheelDeltas({
			event,
			horizontalScroller,
			verticalScroller,
		}),
		true,
	);
	assert.deepEqual(horizontalScroller.scrollCalls, [
		{ left: 24, top: 0, behavior: "auto" },
	]);
	assert.deepEqual(verticalScroller.scrollCalls, [
		{ left: 0, top: 96, behavior: "auto" },
	]);
});

test("does not forward zero, invalid, or unhandled deltas", () => {
	const scroller = makeScrollable(
		"admin-shell-scroll-region",
		{
			clientWidth: 1024,
			scrollWidth: 1024,
			clientHeight: 650,
			scrollHeight: 1600,
			scrollTop: 400,
		},
		{ overflowY: "auto" },
	);

	assert.equal(
		forwardWheelDeltas({ event: makeEvent(), verticalScroller: scroller }),
		false,
	);
	assert.equal(
		forwardWheelDeltas({
			event: makeEvent({ deltaY: Number.NaN }),
			verticalScroller: scroller,
		}),
		false,
	);
	assert.equal(
		forwardWheelDeltas({
			event: makeEvent({ deltaY: 96 }),
			verticalScroller: null,
		}),
		false,
	);
	assert.deepEqual(scroller.scrollCalls, []);
});

test("captures scoped chart wheel input before child handlers and cleans up once", () => {
	const pageScroller = makeScrollable(
		"admin-shell-scroll-region",
		{
			clientWidth: 1024,
			scrollWidth: 1024,
			clientHeight: 650,
			scrollHeight: 1600,
			scrollTop: 400,
		},
		{ overflowY: "auto" },
	);
	const chartScrollRegion = makeScrollable(
		"chart-scroll-region",
		{
			clientWidth: 320,
			scrollWidth: 320,
			clientHeight: 320,
			scrollHeight: 320,
		},
		{ overflowX: "auto" },
	);
	chartScrollRegion.parentElement = pageScroller;

	const listeners = [];
	const element = {
		dataset: { chartWheelScroll: "page" },
		parentElement: chartScrollRegion,
		addEventListener(type, handler, options) {
			listeners.push({ type, handler, options });
		},
		removeEventListener(type, handler, options) {
			listeners.push({ type, handler, options, removed: true });
		},
	};

	const cleanup = attachChartWheelScroll(element);

	assert.equal(listeners.length, 1);
	assert.equal(listeners[0].type, "wheel");
	assert.deepEqual(listeners[0].options, { capture: true, passive: false });

	const event = makeEvent({ deltaY: 96 });
	listeners[0].handler(event);

	assert.equal(event.stopPropagationCalled, true);
	assert.equal(event.preventDefaultCalled, true);
	assert.deepEqual(pageScroller.scrollCalls, [
		{ left: 0, top: 96, behavior: "auto" },
	]);

	cleanup();
	cleanup();

	assert.equal(listeners.filter((listener) => listener.removed).length, 1);
	assert.deepEqual(listeners.at(-1).options, { capture: true });
});

test("does not attach the forwarding listener to shared non-Stats charts", () => {
	const listeners = [];
	const element = {
		dataset: {},
		addEventListener(...args) {
			listeners.push(args);
		},
	};

	assert.equal(attachChartWheelScroll(element), null);
	assert.deepEqual(listeners, []);
});

test("finds the scrollable ancestor in the wheel direction", () => {
	const chart = { parentElement: null };
	const nonScrollable = makeScrollable(
		"chart-wrapper",
		{
			clientWidth: 320,
			scrollWidth: 320,
			clientHeight: 320,
			scrollHeight: 320,
			scrollTop: 0,
		},
		{ overflowY: "auto" },
	);
	const shell = makeScrollable(
		"admin-shell-scroll-region",
		{
			clientWidth: 1024,
			scrollWidth: 1024,
			clientHeight: 650,
			scrollHeight: 1600,
			scrollTop: 400,
		},
		{ overflowY: "auto" },
	);
	chart.parentElement = nonScrollable;
	nonScrollable.parentElement = shell;

	assert.equal(findScrollableAncestor(chart, "y", 96), shell);
});
