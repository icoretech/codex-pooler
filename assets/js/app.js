// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
import "cally";
// Establish Phoenix Socket and LiveView configuration.
import ApexCharts from "apexcharts";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/codex_pooler";
import topbar from "topbar";
import { renderSVG } from "uqr";
import { cumulativeChartSeries } from "./chart_series.mjs";
import { attachChartWheelScroll } from "./chart_wheel_scroll.mjs";
import { classifyLiveSocketConnection } from "./live_socket_connection.mjs";
import {
	ObservatoryRefresh,
	observatoryRefreshConnectParams,
} from "./observatory_refresh.mjs";
import {
	connectionActionLabel,
	connectionFooterParts,
	connectionHint,
	connectionTimelineSteps,
	initialConnectionHistory,
	recordRoundTrip,
	recordSocketError,
	trackConnectionTransition,
} from "./ws_state_timeline.mjs";

const csrfToken = document
	.querySelector("meta[name='csrf-token']")
	.getAttribute("content");
const resolveCssColor = (root, color) => {
	const probe = document.createElement("span");
	probe.style.color = color;
	probe.style.position = "absolute";
	probe.style.pointerEvents = "none";
	probe.style.visibility = "hidden";
	root.appendChild(probe);
	const resolved = window.getComputedStyle(probe).color;
	probe.remove();

	return resolved || color;
};
const parseChartJSON = (value, fallback) => {
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
const formatChartValue = (value, kind) => {
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
const escapeChartHTML = (value) =>
	String(value ?? "")
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#39;");
const buildChartTooltip = ({
	categories,
	series,
	unit,
	units,
	valueKinds,
	safeTooltip,
	colors,
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

				return `${formattedValue} ${units[seriesIndex] || unit}`;
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
					: ` ${units[index] || unit}`;

				return {
					name: item.name || `Series ${index + 1}`,
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
const ClipboardCopy = {
	mounted() {
		this.el.addEventListener("click", async () => {
			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			window.clearTimeout(this.timeout);
			await navigator.clipboard.writeText(this.el.dataset.copyText);

			if (label) {
				label.textContent = this.el.dataset.copiedLabel || "Copied";
			}

			icon?.classList.remove("hero-clipboard-document");
			icon?.classList.add("hero-check");
			this.el.classList.add("btn-success");

			this.timeout = window.setTimeout(() => {
				icon?.classList.remove("hero-check");
				icon?.classList.add("hero-clipboard-document");
				this.el.classList.remove("btn-success");

				if (label) {
					label.textContent = this.el.dataset.copyLabel || "Copy";
				}
			}, 1400);
		});
	},
	destroyed() {
		window.clearTimeout(this.timeout);
	},
};
const WorkerFailureMarker = {
	mounted() {
		this.handleClick = (event) => {
			if (
				event.button !== 0 ||
				event.metaKey ||
				event.ctrlKey ||
				event.shiftKey ||
				event.altKey
			) {
				return;
			}

			event.preventDefault();
			event.stopImmediatePropagation();
			event.stopPropagation();
			this.pushEvent("toggle_worker_failure", {
				"job-id": this.el.dataset.jobId,
			});
		};

		this.el.addEventListener("click", this.handleClick);
	},
	destroyed() {
		this.el.removeEventListener("click", this.handleClick);
	},
};
const TotpSetupTools = {
	mounted() {
		this.renderQr();
	},
	updated() {
		this.renderQr();
	},
	renderQr() {
		const target = this.el.querySelector("[data-totp-qr]");
		const uri = this.el.dataset.otpauthUri;

		if (!target || !uri) return;

		try {
			const size = Number.parseInt(target.dataset.qrSize || "176", 10);
			const svg = renderSVG(uri, { border: 1 })
				.replaceAll('fill="white"', 'fill="#f7f7f7"')
				.replaceAll('fill="black"', 'fill="#0e0e0e"');

			target.innerHTML = svg;

			const rendered = target.querySelector("svg");
			rendered?.setAttribute("width", size.toString());
			rendered?.setAttribute("height", size.toString());
			rendered?.setAttribute("role", "img");
			rendered?.setAttribute("aria-label", "Authenticator app QR code");
		} catch (_error) {
			target.replaceWith(
				Object.assign(document.createElement("p"), {
					className: "text-sm text-error",
					textContent: "QR code could not be rendered",
				}),
			);
		}
	},
};
const CallyDatePicker = {
	mounted() {
		this.input = this.el.querySelector("input[type='hidden']");
		this.calendar = this.el.querySelector("calendar-date");
		this.label = this.el.querySelector("[data-role='cally-date-label']");
		this.popover = this.el.querySelector("[popover]");
		this.placeholder = this.el.dataset.placeholder || "dd/mm/yyyy";
		this.handleChange = (event) => this.selectDate(event.target.value);
		this.handleClear = () => this.selectDate("");
		this.handleCancel = () => this.close();

		this.calendar?.addEventListener("change", this.handleChange);
		this.el
			.querySelector("[data-role='cally-clear']")
			?.addEventListener("click", this.handleClear);
		this.el
			.querySelector("[data-role='cally-cancel']")
			?.addEventListener("click", this.handleCancel);
		this.sync();
	},
	updated() {
		this.sync();
	},
	destroyed() {
		this.calendar?.removeEventListener("change", this.handleChange);
		this.el
			.querySelector("[data-role='cally-clear']")
			?.removeEventListener("click", this.handleClear);
		this.el
			.querySelector("[data-role='cally-cancel']")
			?.removeEventListener("click", this.handleCancel);
	},
	selectDate(value) {
		if (!this.input) return;

		this.input.value = value || "";
		this.sync();
		this.input.dispatchEvent(new Event("input", { bubbles: true }));
		this.input.dispatchEvent(new Event("change", { bubbles: true }));
		this.close();
	},
	sync() {
		const value = this.input?.value || "";

		if (this.calendar && this.calendar.value !== value) {
			this.calendar.value = value;
		}

		if (this.label) {
			this.label.textContent = value
				? this.formatDate(value)
				: this.placeholder;
		}
	},
	close() {
		this.popover?.hidePopover?.();
	},
	formatDate(value) {
		const [year, month, day] = value.split("-").map(Number);

		if (!year || !month || !day) return value;

		return new Intl.DateTimeFormat("en-GB", {
			day: "2-digit",
			month: "2-digit",
			year: "numeric",
		}).format(new Date(year, month - 1, day));
	},
};
const closeFilterDropdowns = (root, except = null) => {
	root.querySelectorAll("details.dropdown[open]").forEach((details) => {
		if (details !== except) details.removeAttribute("open");
	});
};
const AdminFilterDropdowns = {
	mounted() {
		this.handleToggle = (event) => {
			const details = event.target;

			if (!(details instanceof HTMLDetailsElement)) return;
			if (!details.matches("details.dropdown") || !details.open) return;

			closeFilterDropdowns(this.el, details);
		};

		this.handleKeydown = (event) => {
			if (event.key !== "Escape") return;

			const openDropdowns = Array.from(
				this.el.querySelectorAll("details.dropdown[open]"),
			);
			if (openDropdowns.length === 0) return;

			event.preventDefault();
			event.stopPropagation();
			closeFilterDropdowns(this.el);

			const activeDropdown =
				document.activeElement?.closest?.("details.dropdown");
			const focusTarget =
				activeDropdown && this.el.contains(activeDropdown)
					? activeDropdown
					: openDropdowns.at(-1);
			focusTarget?.querySelector("summary")?.focus();
		};

		this.el.addEventListener("toggle", this.handleToggle, true);
		this.el.addEventListener("keydown", this.handleKeydown);
	},
	destroyed() {
		this.el.removeEventListener("toggle", this.handleToggle, true);
		this.el.removeEventListener("keydown", this.handleKeydown);
	},
};
const QuotaPressureChart = {
	mounted() {
		this.renderChart();
	},
	updated() {
		this.renderChart();
	},
	destroyed() {
		this.chart?.destroy();
		this.chart = null;
	},
	renderChart() {
		const value = Number.parseFloat(this.el.dataset.value || "0");
		const boundedValue = Number.isFinite(value)
			? Math.max(0, Math.min(100, value))
			: 0;
		const label = this.el.dataset.label || "remaining";
		const color = resolveCssColor(
			this.el,
			this.el.dataset.color || "var(--color-success)",
		);
		const trackColor = resolveCssColor(
			this.el,
			this.el.dataset.trackColor || "var(--color-base-300)",
		);
		const options = {
			chart: {
				type: "radialBar",
				height: 96,
				width: 96,
				sparkline: { enabled: true },
				animations: { enabled: false },
			},
			colors: [color],
			labels: [label],
			series: [boundedValue],
			stroke: { lineCap: "round" },
			plotOptions: {
				radialBar: {
					hollow: {
						margin: 0,
						size: "58%",
						background: "transparent",
					},
					track: {
						background: trackColor,
						strokeWidth: "100%",
						margin: 0,
					},
					dataLabels: {
						show: false,
					},
				},
			},
			states: {
				hover: { filter: { type: "none" } },
				active: { filter: { type: "none" } },
			},
			tooltip: { enabled: false },
		};

		if (this.chart) {
			this.chart.updateOptions(options, false, true);
			return;
		}

		this.chart = new ApexCharts(this.el, options);
		this.chart.render();
	},
};
function chartAxisLabels({ compact, axisColor, valueKind }) {
	return {
		show: !compact,
		style: { colors: axisColor, fontSize: "11px", fontFamily: "inherit" },
		formatter: (value) => formatChartValue(value, valueKind),
	};
}

function buildChartYaxis({
	compact,
	axisColor,
	units,
	valueKinds,
	yaxisConfig,
}) {
	const axisLabels = chartAxisLabels({
		compact,
		axisColor,
		valueKind: valueKinds[0] || units[0],
	});

	if (Array.isArray(yaxisConfig)) {
		return yaxisConfig.map((axis, index) => {
			const valueKind = axis.valueKind || valueKinds[index] || units[index];

			return {
				seriesName: axis.seriesName,
				opposite: axis.opposite === true,
				show: !compact,
				labels: chartAxisLabels({ compact, axisColor, valueKind }),
				title: {
					text: compact ? undefined : axis.title || units[index],
					style: {
						color: axisColor,
						fontSize: "11px",
						fontFamily: "inherit",
						fontWeight: 600,
					},
				},
			};
		});
	}

	return {
		labels: axisLabels,
	};
}
const ApexTimeSeriesChart = {
	mounted() {
		this.chartMode = "interval";
		this.handleChartMode = (event) => {
			this.setChartMode(event.detail?.mode);
		};
		this.el.addEventListener("chart:set-mode", this.handleChartMode);
		this.syncChartWheelListener();
		this.renderChart();
	},
	updated() {
		this.syncChartWheelListener();
		this.renderChart();
	},
	destroyed() {
		this.removeChartWheelListener?.();
		this.removeChartWheelListener = null;
		this.el.removeEventListener("chart:set-mode", this.handleChartMode);
		this.chart?.destroy();
		this.chart = null;
	},
	syncChartWheelListener() {
		const shouldForwardWheel = this.el.dataset.chartWheelScroll === "page";

		if (shouldForwardWheel && !this.removeChartWheelListener) {
			this.removeChartWheelListener = attachChartWheelScroll(this.el);
		} else if (!shouldForwardWheel && this.removeChartWheelListener) {
			this.removeChartWheelListener();
			this.removeChartWheelListener = null;
		}
	},
	setChartMode(mode) {
		if (mode !== "interval" && mode !== "cumulative") return;

		this.chartMode = mode;
		this.renderChart();
	},
	syncChartMode() {
		const control = document.getElementById(this.el.dataset.chartModeControl);

		control?.querySelectorAll("[data-chart-mode]").forEach((button) => {
			button.setAttribute(
				"aria-pressed",
				`${button.dataset.chartMode === this.chartMode}`,
			);
		});

		const description = document.getElementById(
			this.el.dataset.chartModeDescription,
		);

		if (description) {
			description.textContent =
				this.chartMode === "cumulative"
					? "Showing cumulative running totals through each time bucket."
					: "Showing interval values for each time bucket.";
		}
	},
	renderChart() {
		const categories = parseChartJSON(this.el.dataset.chartCategories, []);
		const intervalSeries = parseChartJSON(this.el.dataset.chartSeries, [
			{ name: "Value", data: [] },
		]).map((item) => ({
			...item,
			type: item.type || "column",
		}));
		const series =
			this.chartMode === "cumulative"
				? cumulativeChartSeries(intervalSeries)
				: intervalSeries;
		const unit = this.el.dataset.chartUnit || "value";
		const sourceUnits = parseChartJSON(
			this.el.dataset.chartUnits,
			series.map(() => unit),
		);
		const sourceValueKinds = parseChartJSON(
			this.el.dataset.chartValueKinds,
			sourceUnits,
		);
		const yaxisConfig = parseChartJSON(this.el.dataset.chartYaxis, null);
		const compact = this.el.dataset.chartCompact === "true";
		const stacked = this.el.dataset.chartStacked === "true";
		const zoomEnabled = this.el.dataset.chartZoom !== "false";
		const safeTooltip = this.el.dataset.chartSafeTooltip === "true";
		const legendMode = this.el.dataset.chartLegend;
		const showLegend = legendMode ? legendMode !== "false" : !compact;
		const showLabels = this.el.dataset.chartLabels === "true";
		const height = Number.parseInt(this.el.dataset.chartHeight || "260", 10);
		const configuredBarRadius = Number.parseInt(
			this.el.dataset.chartBarRadius || `${compact ? 2 : 4}`,
			10,
		);
		const barRadius = Number.isFinite(configuredBarRadius)
			? Math.max(configuredBarRadius, 0)
			: 0;
		const sourceColors = parseChartJSON(this.el.dataset.chartColors, [
			this.el.dataset.chartColor || "var(--color-primary)",
		]).map((color) => resolveCssColor(this.el, color));
		const axisColor = resolveCssColor(
			this.el,
			"color-mix(in oklab, var(--color-base-content) 62%, transparent)",
		);
		const gridColor = resolveCssColor(
			this.el,
			"color-mix(in oklab, var(--color-base-content) 12%, transparent)",
		);
		const seriesTypes = series.map((item) => item.type || "column");
		const yaxis = buildChartYaxis({
			compact,
			axisColor,
			units: sourceUnits,
			valueKinds: sourceValueKinds,
			yaxisConfig,
		});

		this.syncChartMode();

		if (!categories.length || !series.length) {
			this.chart?.destroy();
			this.chart = null;
			this.el.replaceChildren();
			return;
		}

		const options = {
			chart: {
				type: "line",
				height,
				toolbar: { show: false },
				sparkline: { enabled: compact },
				animations: { enabled: false },
				stacked,
				stackOnlyBar: stacked,
				zoom: { enabled: zoomEnabled, allowMouseWheelZoom: zoomEnabled },
			},
			colors: sourceColors,
			dataLabels: { enabled: false },
			fill: {
				opacity: seriesTypes.map((type) => (type === "line" ? 1 : 0.88)),
			},
			grid: {
				show: !compact,
				borderColor: gridColor,
				strokeDashArray: 4,
				padding: {
					left: compact ? -8 : 0,
					right: compact ? -8 : 8,
				},
			},
			plotOptions: {
				bar: {
					borderRadius: barRadius,
					borderRadiusApplication: "end",
					borderRadiusWhenStacked: "last",
					columnWidth: compact ? "72%" : "58%",
				},
			},
			legend: {
				show: showLegend,
				showForSingleSeries: legendMode === "always",
				position: "bottom",
				horizontalAlign: "center",
				fontSize: "12px",
				fontFamily: "inherit",
				fontWeight: 500,
				labels: { colors: axisColor, useSeriesColors: false },
				markers: { size: 5, shape: "square", strokeWidth: 0, offsetX: -2 },
				itemMargin: { horizontal: 10, vertical: 2 },
				onItemHover: { highlightDataSeries: true },
				clusterGroupedSeries: false,
			},
			markers: {
				size: 0,
				hover: { size: compact ? 3 : 4 },
			},
			series,
			states: {
				hover: { filter: { type: "lighten", value: 0.08 } },
				active: { filter: { type: "none" } },
			},
			stroke: {
				curve: "smooth",
				lineCap: "round",
				width: seriesTypes.map((type) =>
					type === "line" ? (compact ? 1.4 : 2) : 0,
				),
			},
			tooltip: buildChartTooltip({
				categories,
				series,
				unit,
				units: sourceUnits,
				valueKinds: sourceValueKinds,
				safeTooltip,
				colors: sourceColors,
			}),
			xaxis: {
				tooltip: { enabled: false },
				categories,
				tickAmount: compact
					? undefined
					: Math.min(Math.max(categories.length - 1, 1), 8),
				axisBorder: { show: !compact, color: gridColor },
				axisTicks: { show: false },
				labels: {
					show: showLabels && !compact,
					rotate: -45,
					style: { colors: axisColor, fontSize: "11px", fontFamily: "inherit" },
					trim: true,
				},
			},
			yaxis,
		};

		if (this.chart) {
			this.chart.updateOptions(options, false, true);
			return;
		}

		this.chart = new ApexCharts(this.el, options);
		this.chart.render();
	},
};
const ApexBarChart = ApexTimeSeriesChart;
const FlashAutoDismiss = {
	mounted() {
		if (this.el.hasAttribute("hidden")) return;

		const timeout = this.el.dataset.flashKind === "error" ? 7000 : 4200;
		this.timer = window.setTimeout(() => {
			this.dismiss();
		}, timeout);
	},
	dismiss() {
		if (this.dismissing) return;

		this.dismissing = true;
		this.el.classList.add(
			"opacity-0",
			"translate-y-2",
			"scale-95",
			"transition-all",
			"duration-200",
			"ease-in",
		);

		window.setTimeout(() => {
			this.pushEvent("lv:clear-flash", { key: this.el.dataset.flashKind });
			this.el.remove();
		}, 200);
	},
	destroyed() {
		window.clearTimeout(this.timer);
	},
};
const OtpInput = {
	mounted() {
		this.hiddenInput = this.el.querySelector("[data-otp-value]");
		this.slots = Array.from(this.el.querySelectorAll("[data-otp-slot]"));
		this.length = Number.parseInt(
			this.el.dataset.otpLength || this.slots.length.toString(),
			10,
		);

		this.slots.forEach((slot, index) => {
			slot.addEventListener("input", () => this.handleInput(index));
			slot.addEventListener("keydown", (event) =>
				this.handleKeydown(event, index),
			);
			slot.addEventListener("paste", (event) => this.handlePaste(event, index));
			slot.addEventListener("focus", () => slot.select());
		});

		this.syncSlotsFromValue();
	},
	handleInput(index) {
		const slot = this.slots[index];
		const digits = this.onlyDigits(slot.value);

		if (digits.length > 1) {
			this.fillFrom(index, digits);
			return;
		}

		slot.value = digits;
		this.syncValueFromSlots();

		if (digits && index < this.slots.length - 1) {
			this.focusSlot(index + 1);
		}
	},
	handleKeydown(event, index) {
		if (event.metaKey || event.ctrlKey || event.altKey) return;

		if (event.key === "Backspace") {
			if (this.slots[index].value === "" && index > 0) {
				event.preventDefault();
				this.focusSlot(index - 1);
				this.slots[index - 1].value = "";
				this.syncValueFromSlots();
			}

			return;
		}

		if (event.key === "Delete") {
			this.slots[index].value = "";
			this.syncValueFromSlots();
			return;
		}

		if (event.key === "ArrowLeft" && index > 0) {
			event.preventDefault();
			this.focusSlot(index - 1);
			return;
		}

		if (event.key === "ArrowRight" && index < this.slots.length - 1) {
			event.preventDefault();
			this.focusSlot(index + 1);
			return;
		}

		if (event.key.length === 1 && !/\d/.test(event.key)) {
			event.preventDefault();
		}
	},
	handlePaste(event, index) {
		const digits = this.onlyDigits(event.clipboardData?.getData("text") || "");

		if (!digits) return;

		event.preventDefault();
		this.fillFrom(index, digits);
	},
	fillFrom(index, digits) {
		digits
			.slice(0, this.slots.length - index)
			.split("")
			.forEach((digit, offset) => {
				this.slots[index + offset].value = digit;
			});

		this.syncValueFromSlots();
		this.focusSlot(Math.min(index + digits.length, this.slots.length - 1));
	},
	syncSlotsFromValue() {
		const digits = this.onlyDigits(this.hiddenInput?.value || "").slice(
			0,
			this.length,
		);

		this.slots.forEach((slot, index) => {
			slot.value = digits[index] || "";
		});

		this.syncValueFromSlots();
	},
	syncValueFromSlots() {
		if (!this.hiddenInput) return;

		this.hiddenInput.value = this.slots
			.map((slot) => slot.value)
			.join("")
			.slice(0, this.length);
		this.hiddenInput.dispatchEvent(new Event("input", { bubbles: true }));
		this.hiddenInput.dispatchEvent(new Event("change", { bubbles: true }));
	},
	focusSlot(index) {
		const slot = this.slots[index];

		if (slot) {
			slot.focus();
			slot.select();
		}
	},
	onlyDigits(value) {
		return value.replace(/\D/g, "");
	},
};
const CONNECTION_VISUAL_STATES = {
	connecting: {
		dataState: "connecting",
		icon: "hero-wifi",
		toneClass: "text-base-content/45",
		buttonToneClass: "text-base-content/60",
		label: "Live updates: syncing",
		stateText: "Syncing",
	},
	websocketConnected: {
		dataState: "connected",
		icon: "hero-wifi",
		toneClass: "text-success",
		buttonToneClass: "text-success",
		label: "Live updates: live",
		stateText: "Live",
	},
	longPollFallback: {
		dataState: "fallback",
		icon: "hero-exclamation-triangle",
		toneClass: "text-warning",
		buttonToneClass: "text-warning",
		label: "Live updates: fallback connection",
		stateText: "Fallback",
	},
	disconnected: {
		dataState: "disconnected",
		icon: "hero-x-circle",
		toneClass: "text-error",
		buttonToneClass: "text-error",
		label: "Live updates: offline",
		stateText: "Offline",
	},
};
const CONNECTION_TONE_CLASSES = Object.values(CONNECTION_VISUAL_STATES).flatMap(
	(state) => [state.toneClass, state.buttonToneClass],
);
const CONNECTION_ICON_CLASSES = Object.values(CONNECTION_VISUAL_STATES).map(
	(state) => state.icon,
);

const connectionIndicator = {
	history: initialConnectionHistory(),
	lastRoot: null,
	lastStepsSignature: null,
};

const setAttributeIfChanged = (el, name, value) => {
	if (el.getAttribute(name) !== value) el.setAttribute(name, value);
};

const setTextIfChanged = (el, value) => {
	if (el.textContent !== value) el.textContent = value;
};

const renderConnectionTimeline = (popover, steps) => {
	const list = popover.querySelector("[data-ws-timeline]");
	if (!list) return;

	const signature = JSON.stringify(steps);
	if (signature === connectionIndicator.lastStepsSignature) return;
	connectionIndicator.lastStepsSignature = signature;

	list.replaceChildren(
		...steps.map((step) => {
			const item = document.createElement("li");
			item.className = "ws-step";
			item.dataset.tone = step.tone;
			if (step.emphasis) item.dataset.emphasis = "";

			const dot = document.createElement("span");
			dot.className = "ws-step-dot";
			dot.setAttribute("aria-hidden", "true");

			const text = document.createElement("span");
			text.className = "ws-step-text";
			text.textContent = step.text;

			const time = document.createElement("span");
			time.className = "ws-step-time";
			time.textContent = step.time;

			item.append(dot, text, time);
			return item;
		}),
	);
};

const applyConnectionVisualState = (root, popover, visualState, transportKey) => {
	const button = root.querySelector("[data-ws-button]");
	const icon = root.querySelector("[data-ws-icon] span");
	const label = root.querySelector("[data-ws-label]");

	setAttributeIfChanged(root, "data-state", visualState.dataState);
	setAttributeIfChanged(root, "data-transport", transportKey);
	setAttributeIfChanged(popover, "data-state", visualState.dataState);
	setAttributeIfChanged(popover, "data-transport", transportKey);

	if (button && !button.classList.contains(visualState.buttonToneClass)) {
		button.classList.remove(...CONNECTION_TONE_CLASSES);
		button.classList.add(visualState.buttonToneClass);
	}
	if (button) setAttributeIfChanged(button, "aria-label", visualState.label);

	// Guard on glyph AND tone: connecting and connected share the wifi glyph,
	// so the glyph alone would skip the green repaint after the first join.
	if (
		icon &&
		!(
			icon.classList.contains(visualState.icon) &&
			icon.classList.contains(visualState.toneClass)
		)
	) {
		icon.classList.remove(
			...CONNECTION_ICON_CLASSES,
			...CONNECTION_TONE_CLASSES,
		);
		icon.classList.add(visualState.icon, visualState.toneClass);
	}

	if (label) setTextIfChanged(label, visualState.label);
};

const updateConnectionIndicator = () => {
	const root = document.getElementById("topbar-connection-indicator");
	const popover = document.getElementById("admin-websocket-state-popover");
	if (!root || !popover) return;

	// Live navigation swaps the shell DOM for a fresh server render; force a
	// full timeline repaint on the new nodes.
	if (root !== connectionIndicator.lastRoot) {
		connectionIndicator.lastRoot = root;
		connectionIndicator.lastStepsSignature = null;
	}

	const liveSocket = window.liveSocket;
	const socket = liveSocket?.socket;
	const connection = classifyLiveSocketConnection(liveSocket, socket);
	const visualState = CONNECTION_VISUAL_STATES[connection.visualState];

	connectionIndicator.history = trackConnectionTransition(
		connectionIndicator.history,
		connection.visualState,
	);

	applyConnectionVisualState(
		root,
		popover,
		visualState,
		connection.transportKey,
	);
	renderConnectionTimeline(
		popover,
		connectionTimelineSteps(connection.visualState, connectionIndicator.history),
	);

	const hint = connectionHint(connection.visualState);
	const hintEl = popover.querySelector("[data-ws-hint]");
	if (hintEl) {
		setTextIfChanged(hintEl, hint || "");
		if (hintEl.hidden === Boolean(hint)) hintEl.hidden = !hint;
	}

	const footer = connectionFooterParts(connection.visualState, {
		endPoint: socket?.endPoint,
		heartbeatIntervalMs: socket?.heartbeatIntervalMs,
		online: navigator.onLine,
	});
	const actionLabel = connectionActionLabel(connection.visualState);

	const metaEl = popover.querySelector("[data-ws-meta]");
	if (metaEl) setTextIfChanged(metaEl, footer.meta);

	// The right slot holds one thing: the action when there is one, the
	// keepalive detail otherwise.
	const detail = actionLabel ? null : footer.detail;
	const detailEl = popover.querySelector("[data-ws-detail]");
	if (detailEl) {
		setTextIfChanged(detailEl, detail || "");
		if (detailEl.hidden === Boolean(detail)) detailEl.hidden = !detail;
	}

	const actionEl = popover.querySelector("[data-ws-action]");
	if (actionEl) {
		setTextIfChanged(actionEl, actionLabel || "");
		if (actionEl.hidden === Boolean(actionLabel)) actionEl.hidden = !actionLabel;
	}
};

const pingConnectionIndicator = () => {
	const socket = window.liveSocket?.socket;
	if (socket?.isConnected?.() && typeof socket.ping === "function") {
		socket.ping((rtt) => {
			connectionIndicator.history = recordRoundTrip(
				connectionIndicator.history,
				rtt,
			);
		});
	}
};

const handleConnectionIndicatorAction = () => {
	const liveSocket = window.liveSocket;
	if (!liveSocket) return;

	if (connectionIndicator.history.prevVisual === "longPollFallback") {
		// connect() alone would reopen long polling: once Phoenix has fallen
		// back, the socket transport stays LongPoll for the page session, so
		// the websocket must be restored as primary before reconnecting.
		forgetMemorizedLongPollFallback();
		liveSocket.replaceTransport(window.WebSocket);
		return;
	}

	// Cycle the raw socket rather than LiveSocket.disconnect, which would
	// permanently drop LiveView's server-close reload handler.
	liveSocket.socket.disconnect(() => liveSocket.socket.connect());
};

const initConnectionIndicator = () => {
	window.liveSocket?.socket?.onError?.(() => {
		connectionIndicator.history = recordSocketError(
			connectionIndicator.history,
		);
	});

	document.addEventListener("click", (event) => {
		if (!(event.target instanceof Element)) return;
		if (
			!event.target.closest("#admin-websocket-state-popover [data-ws-action]")
		) {
			return;
		}

		handleConnectionIndicatorAction();
	});

	// Live navigation replaces the topbar with the server's grey "syncing"
	// template; repaint as soon as the new page lands instead of waiting for
	// the next interval tick.
	window.addEventListener("phx:page-loading-stop", updateConnectionIndicator);

	updateConnectionIndicator();
	window.setInterval(updateConnectionIndicator, 1000);
	window.setInterval(pingConnectionIndicator, 10000);
	pingConnectionIndicator();
};

const forgetMemorizedLongPollFallback = () => {
	try {
		window.sessionStorage?.removeItem("phx:fallback:LongPoll");
	} catch (_error) {
		return;
	}
};
const dismissAdminDialogFromKeyboard = (event) => {
	const dialog = event.target;

	if (
		!(dialog instanceof HTMLDialogElement) ||
		!dialog.classList.contains("modal")
	)
		return;

	if (dismissAdminDialog(dialog)) event.preventDefault();
};
const dismissAdminDialog = (dialog) => {
	const dismissButton = dialog.querySelector(
		"[data-role='dialog-dismiss'], .modal-backdrop button",
	);
	if (!dismissButton) return;

	dismissButton.click();

	return true;
};
const dismissTopAdminDialogFromEscape = (event) => {
	if (event.key !== "Escape") return;

	const openDialogs = Array.from(
		document.querySelectorAll("dialog.modal[open]"),
	);
	const dialog = openDialogs.at(-1);
	if (!dialog) return;

	if (!dismissAdminDialog(dialog)) return;

	event.preventDefault();
	event.stopPropagation();
};

forgetMemorizedLongPollFallback();
document.addEventListener("cancel", dismissAdminDialogFromKeyboard, true);
document.addEventListener("keydown", dismissTopAdminDialogFromEscape, true);

const liveSocket = new LiveSocket("/live", Socket, {
	longPollFallbackMs: 8000,
	params: () => ({
		_csrf_token: csrfToken,
		...observatoryRefreshConnectParams(),
	}),
	dom: {
		// Client-toggled disclosure state lives only in the DOM; without this,
		// any LiveView patch of the surrounding card would fold the element
		// shut again.
		onBeforeElUpdated(from, to) {
			if (
				from.hasAttribute("data-preserve-open") &&
				from.hasAttribute("open")
			) {
				to.setAttribute("open", "");
			}
		},
	},
	hooks: {
		...colocatedHooks,
		AdminFilterDropdowns,
		ApexBarChart,
		ApexTimeSeriesChart,
		CallyDatePicker,
		ClipboardCopy,
		FlashAutoDismiss,
		OtpInput,
		ObservatoryRefresh,
		QuotaPressureChart,
		TotpSetupTools,
		WorkerFailureMarker,
	},
});

topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

liveSocket.connect();

window.liveSocket = liveSocket;

initConnectionIndicator();

if (process.env.NODE_ENV === "development") {
	window.addEventListener(
		"phx:live_reload:attached",
		({ detail: reloader }) => {
			reloader.enableServerLogs();

			let keyDown;
			window.addEventListener("keydown", (e) => (keyDown = e.key));
			window.addEventListener("keyup", (_e) => (keyDown = null));
			window.addEventListener(
				"click",
				(e) => {
					if (keyDown === "c") {
						e.preventDefault();
						e.stopImmediatePropagation();
						reloader.openEditorAtCaller(e.target);
					} else if (keyDown === "d") {
						e.preventDefault();
						e.stopImmediatePropagation();
						reloader.openEditorAtDef(e.target);
					}
				},
				true,
			);

			window.liveReloader = reloader;
		},
	);
}
