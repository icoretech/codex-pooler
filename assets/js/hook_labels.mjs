export const readHookLabels = (value) => {
	try {
		const labels = JSON.parse(value || "{}");
		return labels && typeof labels === "object" && !Array.isArray(labels)
			? labels
			: {};
	} catch {
		return {};
	}
};

export const interpolateLabel = (template, bindings = {}) =>
	template.replace(/%\{([^}]+)\}/g, (placeholder, name) =>
		Object.hasOwn(bindings, name) ? String(bindings[name]) : placeholder,
	);

export const hookLabel = (labels, key, fallback, bindings = {}) => {
	const value = labels?.[key];
	const template = typeof value === "string" && value !== "" ? value : fallback;
	return interpolateLabel(template, bindings);
};
