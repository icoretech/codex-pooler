export const POOL_TRAFFIC_VIEWPORT_ROOT_MARGIN = "200px 0px";

const poolIdFor = (element) => element?.dataset?.poolId || null;

const createPoolTrafficVisibilityController = ({
	Observer,
	activityRoot,
	onTransition,
}) => {
	let destroyed = false;
	let poolId = poolIdFor(activityRoot);
	let viewportVisible = null;

	const emit = (visible) => {
		if (destroyed || !poolId) return;
		onTransition({ poolId, visible });
	};
	// Preload a card shortly before it enters the viewport without eagerly
	// serializing charts for every Pool on a long operator page.
	const observer =
		typeof Observer === "function"
			? new Observer((entries) => {
				if (destroyed) return;

				for (const entry of entries) {
					if (entry.target !== activityRoot) continue;
					const visible = entry.isIntersecting === true;
					if (visible === viewportVisible) continue;

					viewportVisible = visible;
					emit(visible);
				}
			}, {
				rootMargin: POOL_TRAFFIC_VIEWPORT_ROOT_MARGIN,
				threshold: 0,
			})
			: null;

	observer?.observe(activityRoot);

	return {
		sync() {
			if (destroyed) return;
			const nextPoolId = poolIdFor(activityRoot);
			const poolChanged = nextPoolId !== poolId;
			poolId = nextPoolId;

			if (!poolChanged) return;
			if (viewportVisible !== null) emit(viewportVisible);
		},
		destroy() {
			if (destroyed) return;
			destroyed = true;
			observer?.disconnect();
		},
	};
};

export const createPoolTrafficVisibilityHook = (options = {}) => ({
	mounted() {
		const Observer = options.IntersectionObserver ?? globalThis.IntersectionObserver;
		this.poolTrafficVisibilityController = createPoolTrafficVisibilityController({
			Observer,
			activityRoot: this.el,
			onTransition: ({ poolId, visible }) => {
				this.pushEvent("set_pool_traffic_visibility", {
					pool_id: poolId,
					visible,
				});
			},
		});
	},
	updated() {
		this.poolTrafficVisibilityController?.sync();
	},
	destroyed() {
		this.poolTrafficVisibilityController?.destroy();
		this.poolTrafficVisibilityController = null;
	},
});

export const PoolTrafficVisibility = createPoolTrafficVisibilityHook();
