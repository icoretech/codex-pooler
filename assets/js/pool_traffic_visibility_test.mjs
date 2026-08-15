import assert from "node:assert/strict";
import test from "node:test";

import {
	POOL_TRAFFIC_VIEWPORT_ROOT_MARGIN,
	createPoolTrafficVisibilityHook,
} from "./pool_traffic_visibility.mjs";

class FakeObserver {
	static instances = [];

	constructor(callback, options) {
		this.callback = callback;
		this.options = options;
		this.disconnected = false;
		this.observed = [];
		FakeObserver.instances.push(this);
	}

	observe(element) {
		this.observed.push(element);
	}

	disconnect() {
		this.disconnected = true;
	}

	emit(element, isIntersecting) {
		this.callback([{ target: element, isIntersecting }]);
	}
}

class FakeDisclosure {
	constructor(open = false) {
		this.open = open;
		this.listeners = new Map();
	}

	addEventListener(name, listener) {
		this.listeners.set(name, listener);
	}

	removeEventListener(name, listener) {
		if (this.listeners.get(name) === listener) this.listeners.delete(name);
	}

	toggle(open) {
		this.open = open;
		this.listeners.get("toggle")?.();
	}

	get listenerCount() {
		return this.listeners.size;
	}
}

const buildHook = ({ disclosure = null, poolId = "pool-a", observer = FakeObserver } = {}) => {
	FakeObserver.instances = [];
	const events = [];
	const element = {
		dataset: { poolId },
		querySelector: (selector) =>
			selector === "[data-role='pool-traffic-disclosure']" ? disclosure : null,
	};
	const hook = createPoolTrafficVisibilityHook({ IntersectionObserver: observer });
	const bound = Object.assign(Object.create(hook), {
		el: element,
		pushEvent: (event, payload) => events.push({ event, payload }),
	});

	bound.mounted();
	return { bound, element, events };
};

test("viewport samples emit one enter and one leave transition", () => {
	// Given: one observed Pool traffic activity root.
	const { element, events } = buildHook();
	const observer = FakeObserver.instances[0];

	// When: the browser repeats each viewport sample.
	observer.emit(element, true);
	observer.emit(element, true);
	observer.emit(element, false);
	observer.emit(element, false);

	// Then: the server receives only ordered state transitions.
	assert.equal(observer.options.rootMargin, POOL_TRAFFIC_VIEWPORT_ROOT_MARGIN);
	assert.deepEqual(events, [
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", reason: "viewport", visible: true },
		},
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", reason: "viewport", visible: false },
		},
	]);
});

test("a native disclosure emits independent expansion transitions", () => {
	// Given: an offscreen Pool with a closed accessible disclosure.
	const disclosure = new FakeDisclosure(false);
	const { events } = buildHook({ disclosure });

	// When: the operator opens then closes it without viewport observation.
	disclosure.toggle(true);
	disclosure.toggle(true);
	disclosure.toggle(false);

	// Then: expansion transitions are preserved independently of viewport state.
	assert.deepEqual(events, [
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", reason: "disclosure", visible: true },
		},
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", reason: "disclosure", visible: false },
		},
	]);
});

test("updates reuse the observer and resynchronize an active Pool id", () => {
	// Given: a visible activity root already observed for one Pool.
	const { bound, element, events } = buildHook();
	const observer = FakeObserver.instances[0];
	observer.emit(element, true);
	events.length = 0;

	// When: a LiveView patch reuses the root for a new Pool id.
	element.dataset.poolId = "pool-b";
	bound.updated();

	// Then: no observer is replaced and the active state is replayed for the new id.
	assert.equal(FakeObserver.instances.length, 1);
	assert.deepEqual(events, [
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-b", reason: "viewport", visible: true },
		},
	]);
});

test("an update reports a server-synchronized disclosure close", () => {
	// Given: an open disclosure whose browser state was already reported.
	const disclosure = new FakeDisclosure(true);
	const { bound, events } = buildHook({ disclosure });
	events.length = 0;

	// When: a LiveView patch updates the native disclosure state in place.
	disclosure.open = false;
	bound.updated();

	// Then: the server receives the distinct collapsed transition.
	assert.deepEqual(events, [
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", reason: "disclosure", visible: false },
		},
	]);
});

test("unsupported observers leave loading to the explicit disclosure", () => {
	// Given: a browser without IntersectionObserver.
	const disclosure = new FakeDisclosure(false);
	const { events } = buildHook({ disclosure, observer: null });

	// When: the hook mounts before the operator acts.
	assert.deepEqual(events, []);

	// Then: only an explicit disclosure open activates traffic work.
	disclosure.toggle(true);
	assert.deepEqual(events, [
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", reason: "disclosure", visible: true },
		},
	]);
});

test("destroy tears down observer and disclosure callbacks", () => {
	// Given: a mounted activity root with both browser integrations.
	const disclosure = new FakeDisclosure(false);
	const { bound, element, events } = buildHook({ disclosure });
	const observer = FakeObserver.instances[0];

	// When: LiveView destroys the root and stale browser callbacks arrive.
	bound.destroyed();
	observer.emit(element, true);
	disclosure.toggle(true);

	// Then: neither stale callback reaches the server.
	assert.equal(observer.disconnected, true);
	assert.equal(disclosure.listenerCount, 0);
	assert.deepEqual(events, []);
});
