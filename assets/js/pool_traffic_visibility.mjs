export const POOL_TRAFFIC_VIEWPORT_ROOT_MARGIN = "200px 0px";

const disclosureSelector = "[data-role='pool-traffic-disclosure']";

const poolIdFor = (element) => element?.dataset?.poolId || null;

const createPoolTrafficVisibilityController = ({
	Observer,
	activityRoot,
	onTransition,
}) => {
	let destroyed = false;
	let disclosure = null;
	let disclosureVisible = null;
	let poolId = poolIdFor(activityRoot);
	let viewportVisible = null;

	const emit = (reason, visible) => {
		if (destroyed || !poolId) return;
		onTransition({ poolId, reason, visible });
	};
	const syncDisclosure = () => {
		const nextDisclosure = activityRoot.querySelector?.(disclosureSelector) ?? null;
		const nextVisible = nextDisclosure?.open === true;

		if (nextDisclosure === disclosure) {
			if (disclosureVisible === null || nextVisible === disclosureVisible) return;

			disclosureVisible = nextVisible;
			emit("disclosure", nextVisible);
			return;
		}

		disclosure?.removeEventListener("toggle", handleDisclosureToggle);
		disclosure = nextDisclosure;
		const previousVisible = disclosureVisible;
		disclosureVisible = nextVisible;
		disclosure?.addEventListener("toggle", handleDisclosureToggle);

		if (previousVisible !== null && previousVisible !== disclosureVisible) {
			emit("disclosure", disclosureVisible);
		} else if (disclosureVisible) {
			emit("disclosure", true);
		}
	};
	const handleDisclosureToggle = () => {
		const visible = disclosure?.open === true;
		if (destroyed || visible === disclosureVisible) return;

		disclosureVisible = visible;
		emit("disclosure", visible);
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
					emit("viewport", visible);
				}
			}, {
				rootMargin: POOL_TRAFFIC_VIEWPORT_ROOT_MARGIN,
				threshold: 0,
			})
			: null;

	syncDisclosure();
	observer?.observe(activityRoot);

	return {
		sync() {
			if (destroyed) return;
			const nextPoolId = poolIdFor(activityRoot);
			const poolChanged = nextPoolId !== poolId;
			poolId = nextPoolId;
			syncDisclosure();

			if (!poolChanged) return;
			if (viewportVisible !== null) emit("viewport", viewportVisible);
			if (disclosureVisible === true) emit("disclosure", true);
		},
		destroy() {
			if (destroyed) return;
			destroyed = true;
			observer?.disconnect();
			disclosure?.removeEventListener("toggle", handleDisclosureToggle);
		},
	};
};

export const createPoolTrafficVisibilityHook = (options = {}) => ({
	mounted() {
		const Observer = options.IntersectionObserver ?? globalThis.IntersectionObserver;
		this.poolTrafficVisibilityController = createPoolTrafficVisibilityController({
			Observer,
			activityRoot: this.el,
			onTransition: ({ poolId, reason, visible }) => {
				this.pushEvent("set_pool_traffic_visibility", {
					pool_id: poolId,
					reason,
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
