import { hookLabel } from "./hook_labels.mjs";

export const parseChartJSON = (value, fallback) => {
	try {
		return JSON.parse(value || "");
	} catch (_error) {
		return fallback;
	}
};

const formatChartNumber = (value) => {
	const number = Number(value || 0);
	if (!Number.isFinite(number)) return "0";
	return new Intl.NumberFormat(undefined, {
		maximumFractionDigits: Number.isInteger(number) ? 0 : 1,
	}).format(number);
};

const compactNumberScales = [
	{ value: 1_000_000_000, suffix: "B" },
	{ value: 1_000_000, suffix: "M" },
	{ value: 1_000, suffix: "k" },
];

const formatCompactNumber = (value) => {
	const number = Number(value || 0);
	if (!Number.isFinite(number)) return "0";
	const sign = number < 0 ? "-" : "";
	const absolute = Math.abs(number);
	const scale = compactNumberScales.find((item) => absolute >= item.value);
	if (!scale) return `${sign}${formatChartNumber(absolute)}`;
	const scaled = (absolute / scale.value).toFixed(1).replace(/\.0$/, "");
	return `${sign}${scaled}${scale.suffix}`;
};

const formatMoneyNumber = (value) => {
	const number = Number(value || 0);
	if (!Number.isFinite(number)) return "$0.00";
	const sign = number < 0 ? "-" : "";
	const formatted = new Intl.NumberFormat(undefined, {
		minimumFractionDigits: 2,
		maximumFractionDigits: 2,
	}).format(Math.abs(number));
	return `${sign}$${formatted}`;
};

export const formatChartValue = (value, kind) => {
	switch (kind) {
		case "money":
		case "usd":
			return formatMoneyNumber(value);
		case "token":
		case "tokens":
			return formatCompactNumber(value);
		case "integer":
			return formatChartNumber(Math.round(Number(value || 0)));
		default:
			return formatChartNumber(value);
	}
};

export const chartIntervalSeries = (dataset = {}) =>
	parseChartJSON(dataset.chartSeries, [
		{ name: hookLabel(dataset, "chartDefaultSeriesLabel", "Value"), data: [] },
	]).map((item) => ({ ...item, type: item.type || "column" }));

export const quotaPressureLabel = (dataset = {}) =>
	hookLabel(dataset, "label", "remaining");

export const chartModeDescription = (mode, dataset = {}) =>
	mode === "cumulative"
		? hookLabel(dataset, "chartCumulativeDescription", "Showing cumulative running totals through each time bucket.")
		: hookLabel(dataset, "chartIntervalDescription", "Showing interval values for each time bucket.");

export const chartDisplayUnits = (dataset, units, unit) => {
	const labels = parseChartJSON(dataset.chartUnitLabels, []);
	const unitLabel = hookLabel(dataset, "chartUnitLabel", unit);
	return units.map((value, index) =>
		hookLabel(Array.isArray(labels) ? labels : {}, index, value === unit ? unitLabel : value),
	);
};

const escapeChartHTML = (value) =>
	String(value ?? "")
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#39;");

export const buildChartTooltip = ({
	categories,
	series,
	unit,
	units,
	unitLabels = units,
	valueKinds,
	safeTooltip,
	colors,
	labels = {},
}) => {
	const tooltip = {
		shared: true,
		intersect: false,
		x: { show: true },
		y: {
			formatter: (value, { seriesIndex }) => {
				const valueKind = valueKinds[seriesIndex] || units[seriesIndex] || unit;
				const formattedValue = formatChartValue(value, valueKind);
				if (["money", "usd"].includes(valueKind)) return formattedValue;
				return `${formattedValue} ${unitLabels[seriesIndex] || unit}`;
			},
			title: { formatter: (seriesName) => `${seriesName}: ` },
		},
	};

	if (!safeTooltip) return tooltip;

	return {
		...tooltip,
		custom: ({ series: values, dataPointIndex, w }) => {
			const configSeries = w?.config?.series || series;
			const rows = configSeries.map((item, index) => {
				const value = Number(values?.[index]?.[dataPointIndex] || 0);
				const valueKind = valueKinds[index] || units[index] || unit;
				const formattedValue = formatChartValue(value, valueKind);
				const suffix = ["money", "usd"].includes(valueKind)
					? ""
					: ` ${unitLabels[index] || unit}`;

				return {
					name: item.name || hookLabel(labels, "chartSeriesLabel", "Series %{index}", { index: index + 1 }),
					value,
					label: `${formattedValue}${suffix}`,
					color: colors[index] || "",
				};
			});
			const visibleRows = rows.filter((row) => row.value !== 0);
			const renderedRows = visibleRows.length ? visibleRows : rows;
			const title = categories[dataPointIndex] || "";

			return `
        <div class="px-3 py-2 text-xs">
          <div class="mb-1 font-semibold">${escapeChartHTML(title)}</div>
          ${renderedRows
						.map(
							(row) => `
            <div class="flex items-center justify-between gap-4">
              <span class="flex min-w-0 items-center gap-2">
                <span aria-hidden="true" class="inline-block h-2.5 w-2.5 shrink-0 rounded-sm" style="background-color: ${escapeChartHTML(row.color)}"></span>
                <span class="truncate">${escapeChartHTML(row.name)}</span>
              </span>
              <span class="font-semibold">${escapeChartHTML(row.label)}</span>
            </div>
          `,
						)
						.join("")}
        </div>
      `;
		},
	};
};
