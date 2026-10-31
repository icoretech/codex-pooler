import assert from "node:assert/strict";
import test from "node:test";

import {
	buildChartTooltip,
	chartDisplayUnits,
	chartIntervalSeries,
	chartModeDescription,
	formatChartValue,
	quotaPressureLabel,
} from "./chart_presentation.mjs";

const chart = (options = {}) => ({
	categories: ["12:00"],
	series: [{ name: "", data: [1500] }, { name: "请求数", data: [3] }],
	unit: "value",
	units: ["tokens", "requests"],
	valueKinds: ["tokens", "integer"],
	colors: ["orange", "blue"],
	...options,
});

test("chart mode descriptions retain exact English and accept complete translated sentences", () => {
	assert.equal(chartModeDescription("interval"), "Showing interval values for each time bucket.");
	assert.equal(chartModeDescription("cumulative"), "Showing cumulative running totals through each time bucket.");
	const labels = {
		chartIntervalDescription: "显示各时间段的区间值。",
		chartCumulativeDescription: "显示截至各时间段的累计总数。",
	};
	assert.equal(chartModeDescription("interval", labels), "显示各时间段的区间值。");
	assert.equal(chartModeDescription("cumulative", labels), "显示截至各时间段的累计总数。");
});

test("translated display units never replace chart formatter identifiers", () => {
	const units = ["tokens", "requests"];
	const unitLabels = chartDisplayUnits({ chartUnitLabels: '["Token","请求"]' }, units, "value");
	assert.deepEqual(unitLabels, ["Token", "请求"]);
	assert.deepEqual(units, ["tokens", "requests"]);
	const tooltip = buildChartTooltip(chart({ unitLabels }));
	assert.equal(tooltip.y.formatter(1500, { seriesIndex: 0 }), "1.5k Token");
	assert.equal(tooltip.y.formatter(3.3, { seriesIndex: 1 }), "3 请求");
	assert.equal(formatChartValue(1500, "tokens"), "1.5k");
	assert.equal(formatChartValue(3.3, "integer"), "3");
});

test("missing unit labels preserve old tooltip suffixes and single-unit labels apply to each series", () => {
	for (const dataset of [{}, { chartUnitLabels: "invalid" }, { chartUnitLabels: "null" }]) {
		assert.deepEqual(chartDisplayUnits(dataset, ["tokens", "requests"], "value"), ["tokens", "requests"]);
	}
	assert.deepEqual(chartDisplayUnits({ chartUnitLabel: "次尝试" }, ["attempts", "attempts"], "attempts"), ["次尝试", "次尝试"]);
	const tooltip = buildChartTooltip(chart());
	assert.equal(tooltip.y.formatter(1500, { seriesIndex: 0 }), "1.5k tokens");
	assert.equal(tooltip.y.formatter(3, { seriesIndex: 1 }), "3 requests");
});

test("safe tooltip translates fallback series names, escapes translated labels and preserves numeric formatting", () => {
	const tooltip = buildChartTooltip(chart({
		unitLabels: ["Token", "<请求>"],
		labels: { chartSeriesLabel: "第 %{index} 个系列 <默认>" },
		safeTooltip: true,
	}));
	const html = tooltip.custom({ series: [[1500], [3]], dataPointIndex: 0 });
	assert.match(html, /第 1 个系列 &lt;默认&gt;/);
	assert.match(html, /1\.5k Token/);
	assert.match(html, /3 &lt;请求&gt;/);
	assert.doesNotMatch(html, /<默认>|<请求>/);
	const fallback = buildChartTooltip(chart({ safeTooltip: true }));
	assert.match(fallback.custom({ series: [[1500], [0]], dataPointIndex: 0 }), /Series 1/);
});

test("money formatting ignores display-unit suffixes in both tooltip paths", () => {
	for (const safeTooltip of [false, true]) {
		const tooltip = buildChartTooltip(chart({
			units: ["usd"], valueKinds: ["money"], unitLabels: ["美元"],
			series: [{ name: "费用", data: [2.5] }], safeTooltip,
		}));
		assert.equal(tooltip.y.formatter(2.5, { seriesIndex: 0 }), "$2.50");
		if (safeTooltip) {
			const html = tooltip.custom({ series: [[2.5]], dataPointIndex: 0 });
			assert.match(html, /\$2\.50/);
			assert.doesNotMatch(html, /美元/);
		}
	}
});

test("missing chart series uses translated Value fallback and preserves server series names", () => {
	assert.deepEqual(chartIntervalSeries(), [{ name: "Value", data: [], type: "column" }]);
	assert.deepEqual(chartIntervalSeries({ chartSeries: "invalid-json", chartDefaultSeriesLabel: "数值" }), [{ name: "数值", data: [], type: "column" }]);
	assert.deepEqual(chartIntervalSeries({ chartSeries: '[{"name":"请求","data":[3],"type":"line"}]', chartDefaultSeriesLabel: "数值" }), [{ name: "请求", data: [3], type: "line" }]);
});

test("quota pressure label keeps English fallback and accepts translated data-label", () => {
	assert.equal(quotaPressureLabel(), "remaining");
	assert.equal(quotaPressureLabel({ label: "" }), "remaining");
	assert.equal(quotaPressureLabel({ label: "剩余" }), "剩余");
});
