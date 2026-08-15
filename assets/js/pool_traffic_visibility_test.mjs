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

const buildHook = ({ poolId = "pool-a", observer = FakeObserver } = {}) => {
	FakeObserver.instances = [];
	const events = [];
	const element = { dataset: { poolId } };
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
			payload: { pool_id: "pool-a", visible: true },
		},
		{
			event: "set_pool_traffic_visibility",
			payload: { pool_id: "pool-a", visible: false },
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
			payload: { pool_id: "pool-b", visible: true },
		},
	]);
});

test("unsupported observers remain inert", () => {
	// Given: a browser without IntersectionObserver.
	const { events } = buildHook({ observer: null });

	// When: the viewport-only hook mounts without an observer implementation.
	assert.deepEqual(events, []);
});

test("destroy tears down observer callbacks", () => {
	// Given: a mounted activity root with viewport observation.
	const { bound, element, events } = buildHook();
	const observer = FakeObserver.instances[0];

	// When: LiveView destroys the root and stale browser callbacks arrive.
	bound.destroyed();
	observer.emit(element, true);

	// Then: no stale callback reaches the server.
	assert.equal(observer.disconnected, true);
	assert.deepEqual(events, []);
});
