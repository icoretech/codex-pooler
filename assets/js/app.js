// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import "cally"
// Establish Phoenix Socket and LiveView configuration.
import ApexCharts from "apexcharts"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/codex_pooler"
import {renderSVG} from "uqr"
import topbar from "topbar"
import {classifyLiveSocketConnection} from "./live_socket_connection.mjs"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const resolveCssColor = (root, color) => {
  const probe = document.createElement("span")
  probe.style.color = color
  probe.style.position = "absolute"
  probe.style.pointerEvents = "none"
  probe.style.visibility = "hidden"
  root.appendChild(probe)
  const resolved = window.getComputedStyle(probe).color
  probe.remove()

  return resolved || color
}
const parseChartJSON = (value, fallback) => {
  try {
    return JSON.parse(value || "")
  } catch (_error) {
    return fallback
  }
}
const formatChartNumber = value => {
  const number = Number(value || 0)

  if (!Number.isFinite(number)) return "0"

  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: Number.isInteger(number) ? 0 : 1,
  }).format(number)
}
const compactNumberScales = [
  {value: 1_000_000_000, suffix: "B"},
  {value: 1_000_000, suffix: "M"},
  {value: 1_000, suffix: "k"},
]
const formatCompactNumber = value => {
  const number = Number(value || 0)

  if (!Number.isFinite(number)) return "0"

  const sign = number < 0 ? "-" : ""
  const absolute = Math.abs(number)
  const scale = compactNumberScales.find(item => absolute >= item.value)

  if (!scale) return `${sign}${formatChartNumber(absolute)}`

  const scaled = (absolute / scale.value)
    .toFixed(1)
    .replace(/\.0$/, "")

  return `${sign}${scaled}${scale.suffix}`
}
const formatMoneyNumber = value => {
  const number = Number(value || 0)

  if (!Number.isFinite(number)) return "$0.00"

  const sign = number < 0 ? "-" : ""
  const formatted = new Intl.NumberFormat(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Math.abs(number))

  return `${sign}$${formatted}`
}
const formatChartValue = (value, kind) => {
  switch (kind) {
    case "money":
    case "usd":
      return formatMoneyNumber(value)
    case "token":
    case "tokens":
      return formatCompactNumber(value)
    case "integer":
      return formatChartNumber(Math.round(Number(value || 0)))
    default:
      return formatChartNumber(value)
  }
}
const ClipboardCopy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const icon = this.el.querySelector(".copy-icon")
      const label = this.el.querySelector("[data-copy-label]")
      window.clearTimeout(this.timeout)
      await navigator.clipboard.writeText(this.el.dataset.copyText)

      if (label) {
        label.textContent = this.el.dataset.copiedLabel || "Copied"
      }

      icon?.classList.remove("hero-clipboard-document")
      icon?.classList.add("hero-check")
      this.el.classList.add("btn-success")

      this.timeout = window.setTimeout(() => {
        icon?.classList.remove("hero-check")
        icon?.classList.add("hero-clipboard-document")
        this.el.classList.remove("btn-success")

        if (label) {
          label.textContent = this.el.dataset.copyLabel || "Copy"
        }
      }, 1400)
    })
  },
  destroyed() {
    window.clearTimeout(this.timeout)
  },
}
const TotpSetupTools = {
  mounted() {
    this.renderQr()
  },
  updated() {
    this.renderQr()
  },
  renderQr() {
    const target = this.el.querySelector("[data-totp-qr]")
    const uri = this.el.dataset.otpauthUri

    if (!target || !uri) return

    try {
      const size = Number.parseInt(target.dataset.qrSize || "176", 10)
      const svg = renderSVG(uri, {border: 1})
        .replaceAll('fill="white"', 'fill="#f7f7f7"')
        .replaceAll('fill="black"', 'fill="#0e0e0e"')

      target.innerHTML = svg

      const rendered = target.querySelector("svg")
      rendered?.setAttribute("width", size.toString())
      rendered?.setAttribute("height", size.toString())
      rendered?.setAttribute("role", "img")
      rendered?.setAttribute("aria-label", "Authenticator app QR code")
    } catch (_error) {
      target.replaceWith(Object.assign(document.createElement("p"), {
        className: "text-sm text-error",
        textContent: "QR code could not be rendered",
      }))
    }
  },
}
const CallyDatePicker = {
  mounted() {
    this.input = this.el.querySelector("input[type='hidden']")
    this.calendar = this.el.querySelector("calendar-date")
    this.label = this.el.querySelector("[data-role='cally-date-label']")
    this.popover = this.el.querySelector("[popover]")
    this.placeholder = this.el.dataset.placeholder || "dd/mm/yyyy"
    this.handleChange = event => this.selectDate(event.target.value)
    this.handleClear = () => this.selectDate("")
    this.handleCancel = () => this.close()

    this.calendar?.addEventListener("change", this.handleChange)
    this.el.querySelector("[data-role='cally-clear']")?.addEventListener("click", this.handleClear)
    this.el.querySelector("[data-role='cally-cancel']")?.addEventListener("click", this.handleCancel)
    this.sync()
  },
  updated() {
    this.sync()
  },
  destroyed() {
    this.calendar?.removeEventListener("change", this.handleChange)
    this.el.querySelector("[data-role='cally-clear']")?.removeEventListener("click", this.handleClear)
    this.el.querySelector("[data-role='cally-cancel']")?.removeEventListener("click", this.handleCancel)
  },
  selectDate(value) {
    if (!this.input) return

    this.input.value = value || ""
    this.sync()
    this.input.dispatchEvent(new Event("input", {bubbles: true}))
    this.input.dispatchEvent(new Event("change", {bubbles: true}))
    this.close()
  },
  sync() {
    const value = this.input?.value || ""

    if (this.calendar && this.calendar.value !== value) {
      this.calendar.value = value
    }

    if (this.label) {
      this.label.textContent = value ? this.formatDate(value) : this.placeholder
    }
  },
  close() {
    this.popover?.hidePopover?.()
  },
  formatDate(value) {
    const [year, month, day] = value.split("-").map(Number)

    if (!year || !month || !day) return value

    return new Intl.DateTimeFormat("en-GB", {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
    }).format(new Date(year, month - 1, day))
  },
}
const QuotaPressureChart = {
  mounted() {
    this.renderChart()
  },
  updated() {
    this.renderChart()
  },
  destroyed() {
    this.chart?.destroy()
    this.chart = null
  },
  renderChart() {
    const value = Number.parseFloat(this.el.dataset.value || "0")
    const boundedValue = Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : 0
    const label = this.el.dataset.label || "remaining"
    const color = resolveCssColor(this.el, this.el.dataset.color || "var(--color-success)")
    const trackColor = resolveCssColor(this.el, this.el.dataset.trackColor || "var(--color-base-300)")
    const options = {
      chart: {
        type: "radialBar",
        height: 96,
        width: 96,
        sparkline: {enabled: true},
        animations: {enabled: false},
      },
      colors: [color],
      labels: [label],
      series: [boundedValue],
      stroke: {lineCap: "round"},
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
        hover: {filter: {type: "none"}},
        active: {filter: {type: "none"}},
      },
      tooltip: {enabled: false},
    }

    if (this.chart) {
      this.chart.updateOptions(options, false, true)
      return
    }

    this.chart = new ApexCharts(this.el, options)
    this.chart.render()
  },
}
function chartAxisLabels({compact, axisColor, valueKind}) {
  return {
    show: !compact,
    style: {colors: axisColor, fontSize: "11px", fontFamily: "inherit"},
    formatter: value => formatChartValue(value, valueKind),
  }
}

function buildChartYaxis({compact, axisColor, units, valueKinds, yaxisConfig}) {
  const axisLabels = chartAxisLabels({compact, axisColor, valueKind: valueKinds[0] || units[0]})

  if (Array.isArray(yaxisConfig)) {
    return yaxisConfig.map((axis, index) => {
      const valueKind = axis.valueKind || valueKinds[index] || units[index]

      return {
        seriesName: axis.seriesName,
        opposite: axis.opposite === true,
        show: !compact,
        labels: chartAxisLabels({compact, axisColor, valueKind}),
        title: {
          text: compact ? undefined : axis.title || units[index],
          style: {color: axisColor, fontSize: "11px", fontFamily: "inherit", fontWeight: 600},
        },
      }
    })
  }

  return {
    labels: axisLabels,
  }
}
const ApexTimeSeriesChart = {
  mounted() {
    this.renderChart()
  },
  updated() {
    this.renderChart()
  },
  destroyed() {
    this.chart?.destroy()
    this.chart = null
  },
  renderChart() {
    const categories = parseChartJSON(this.el.dataset.chartCategories, [])
    const series = parseChartJSON(this.el.dataset.chartSeries, [{name: "Value", data: []}])
      .map(item => ({...item, type: item.type || "column"}))
    const unit = this.el.dataset.chartUnit || "value"
    const units = parseChartJSON(this.el.dataset.chartUnits, series.map(() => unit))
    const valueKinds = parseChartJSON(this.el.dataset.chartValueKinds, units)
    const yaxisConfig = parseChartJSON(this.el.dataset.chartYaxis, null)
    const compact = this.el.dataset.chartCompact === "true"
    const stacked = this.el.dataset.chartStacked === "true"
    const showLegend = this.el.dataset.chartLegend
      ? this.el.dataset.chartLegend !== "false"
      : !compact
    const showLabels = this.el.dataset.chartLabels === "true"
    const height = Number.parseInt(this.el.dataset.chartHeight || "260", 10)
    const configuredBarRadius = Number.parseInt(
      this.el.dataset.chartBarRadius || `${compact ? 2 : 4}`,
      10
    )
    const barRadius = Number.isFinite(configuredBarRadius) ? Math.max(configuredBarRadius, 0) : 0
    const colors = parseChartJSON(this.el.dataset.chartColors, [this.el.dataset.chartColor || "var(--color-primary)"])
      .map(color => resolveCssColor(this.el, color))
    const axisColor = resolveCssColor(this.el, "color-mix(in oklab, var(--color-base-content) 62%, transparent)")
    const gridColor = resolveCssColor(this.el, "color-mix(in oklab, var(--color-base-content) 12%, transparent)")
    const seriesTypes = series.map(item => item.type || "column")
    const yaxis = buildChartYaxis({compact, axisColor, units, valueKinds, yaxisConfig})
    const options = {
      chart: {
        type: "line",
        height,
        toolbar: {show: false},
        sparkline: {enabled: compact},
        animations: {enabled: false},
        stacked,
        stackOnlyBar: stacked,
      },
      colors,
      dataLabels: {enabled: false},
      fill: {
        opacity: seriesTypes.map(type => type === "line" ? 1 : 0.88),
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
      legend: {show: showLegend},
      markers: {
        size: 0,
        hover: {size: compact ? 3 : 4},
      },
      series,
      states: {
        hover: {filter: {type: "lighten", value: 0.08}},
        active: {filter: {type: "none"}},
      },
      stroke: {
        curve: "smooth",
        lineCap: "round",
        width: seriesTypes.map(type => type === "line" ? (compact ? 1.4 : 2) : 0),
      },
      tooltip: {
        shared: true,
        intersect: false,
        x: {show: true},
        y: {
          formatter: (value, {seriesIndex}) => {
            const valueKind = valueKinds[seriesIndex] || units[seriesIndex] || unit
            const formattedValue = formatChartValue(value, valueKind)

            if (["money", "usd"].includes(valueKind)) return formattedValue

            return `${formattedValue} ${units[seriesIndex] || unit}`
          },
          title: {formatter: seriesName => `${seriesName}: `},
        },
      },
      xaxis: {
        categories,
        tickAmount: compact ? undefined : Math.min(Math.max(categories.length - 1, 1), 8),
        axisBorder: {show: !compact, color: gridColor},
        axisTicks: {show: false},
        labels: {
          show: showLabels && !compact,
          rotate: -45,
          style: {colors: axisColor, fontSize: "11px", fontFamily: "inherit"},
          trim: true,
        },
      },
      yaxis,
    }

    if (this.chart) {
      this.chart.updateOptions(options, false, true)
      return
    }

    this.chart = new ApexCharts(this.el, options)
    this.chart.render()
  },
}
const ApexBarChart = ApexTimeSeriesChart
const FlashAutoDismiss = {
  mounted() {
    if (this.el.hasAttribute("hidden")) return

    const timeout = this.el.dataset.flashKind === "error" ? 7000 : 4200
    this.timer = window.setTimeout(() => {
      this.dismiss()
    }, timeout)
  },
  dismiss() {
    if (this.dismissing) return

    this.dismissing = true
    this.el.classList.add(
      "opacity-0",
      "translate-y-2",
      "scale-95",
      "transition-all",
      "duration-200",
      "ease-in"
    )

    window.setTimeout(() => {
      this.pushEvent("lv:clear-flash", {key: this.el.dataset.flashKind})
      this.el.remove()
    }, 200)
  },
  destroyed() {
    window.clearTimeout(this.timer)
  },
}
const OtpInput = {
  mounted() {
    this.hiddenInput = this.el.querySelector("[data-otp-value]")
    this.slots = Array.from(this.el.querySelectorAll("[data-otp-slot]"))
    this.length = Number.parseInt(this.el.dataset.otpLength || this.slots.length.toString(), 10)

    this.slots.forEach((slot, index) => {
      slot.addEventListener("input", () => this.handleInput(index))
      slot.addEventListener("keydown", event => this.handleKeydown(event, index))
      slot.addEventListener("paste", event => this.handlePaste(event, index))
      slot.addEventListener("focus", () => slot.select())
    })

    this.syncSlotsFromValue()
  },
  handleInput(index) {
    const slot = this.slots[index]
    const digits = this.onlyDigits(slot.value)

    if (digits.length > 1) {
      this.fillFrom(index, digits)
      return
    }

    slot.value = digits
    this.syncValueFromSlots()

    if (digits && index < this.slots.length - 1) {
      this.focusSlot(index + 1)
    }
  },
  handleKeydown(event, index) {
    if (event.metaKey || event.ctrlKey || event.altKey) return

    if (event.key === "Backspace") {
      if (this.slots[index].value === "" && index > 0) {
        event.preventDefault()
        this.focusSlot(index - 1)
        this.slots[index - 1].value = ""
        this.syncValueFromSlots()
      }

      return
    }

    if (event.key === "Delete") {
      this.slots[index].value = ""
      this.syncValueFromSlots()
      return
    }

    if (event.key === "ArrowLeft" && index > 0) {
      event.preventDefault()
      this.focusSlot(index - 1)
      return
    }

    if (event.key === "ArrowRight" && index < this.slots.length - 1) {
      event.preventDefault()
      this.focusSlot(index + 1)
      return
    }

    if (event.key.length === 1 && !/\d/.test(event.key)) {
      event.preventDefault()
    }
  },
  handlePaste(event, index) {
    const digits = this.onlyDigits(event.clipboardData?.getData("text") || "")

    if (!digits) return

    event.preventDefault()
    this.fillFrom(index, digits)
  },
  fillFrom(index, digits) {
    digits
      .slice(0, this.slots.length - index)
      .split("")
      .forEach((digit, offset) => {
        this.slots[index + offset].value = digit
      })

    this.syncValueFromSlots()
    this.focusSlot(Math.min(index + digits.length, this.slots.length - 1))
  },
  syncSlotsFromValue() {
    const digits = this.onlyDigits(this.hiddenInput?.value || "").slice(0, this.length)

    this.slots.forEach((slot, index) => {
      slot.value = digits[index] || ""
    })

    this.syncValueFromSlots()
  },
  syncValueFromSlots() {
    if (!this.hiddenInput) return

    this.hiddenInput.value = this.slots.map(slot => slot.value).join("").slice(0, this.length)
    this.hiddenInput.dispatchEvent(new Event("input", {bubbles: true}))
    this.hiddenInput.dispatchEvent(new Event("change", {bubbles: true}))
  },
  focusSlot(index) {
    const slot = this.slots[index]

    if (slot) {
      slot.focus()
      slot.select()
    }
  },
  onlyDigits(value) {
    return value.replace(/\D/g, "")
  },
}
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
}
const CONNECTION_TONE_CLASSES = Object.values(CONNECTION_VISUAL_STATES).flatMap(state => [
  state.toneClass,
  state.buttonToneClass,
])
const CONNECTION_ICON_CLASSES = Object.values(CONNECTION_VISUAL_STATES).map(state => state.icon)

const WebSocketState = {
  mounted() {
    this.updateState()
    this.interval = window.setInterval(() => this.updateState(), 1000)
  },
  destroyed() {
    window.clearInterval(this.interval)
  },
  updateState() {
    const liveSocket = window.liveSocket
    const socket = liveSocket?.socket
    const connection = classifyLiveSocketConnection(liveSocket, socket)
    const visualState = CONNECTION_VISUAL_STATES[connection.visualState]
    const endpoint = socket?.endPoint || "/live"
    const heartbeat = socket?.heartbeatIntervalMs ? `${socket.heartbeatIntervalMs}ms` : "default"

    this.applyVisualState(visualState, connection.transportKey)
    this.setText("[data-ws-state]", visualState.stateText)
    this.setTone("[data-ws-state]", visualState.toneClass)
    this.setText("[data-ws-transport]", connection.transportLabel)
    this.setText("[data-ws-endpoint]", endpoint)
    this.setText("[data-ws-heartbeat]", heartbeat)
  },
  applyVisualState(visualState, transportKey) {
    const indicator = document.getElementById("topbar-connection-indicator")
    const button = indicator?.querySelector("[data-ws-button]")
    const icon = indicator?.querySelector("[data-ws-icon] span")
    const label = indicator?.querySelector("[data-ws-label]")

    indicator?.setAttribute("data-state", visualState.dataState)
    indicator?.setAttribute("data-transport", transportKey)
    this.el.setAttribute("data-state", visualState.dataState)
    this.el.setAttribute("data-transport", transportKey)

    if (button) {
      button.classList.remove(...CONNECTION_TONE_CLASSES)
      button.classList.add(visualState.buttonToneClass)
      button.setAttribute("aria-label", visualState.label)
    }

    if (icon) {
      icon.classList.remove(...CONNECTION_ICON_CLASSES, ...CONNECTION_TONE_CLASSES)
      icon.classList.add(visualState.icon, visualState.toneClass)
    }

    if (label) label.textContent = visualState.label
  },
  setText(selector, text) {
    const target = this.el.querySelector(selector)
    if (target) target.textContent = text
  },
  setTone(selector, toneClass) {
    const target = this.el.querySelector(selector)
    if (!target) return

    target.classList.remove(...CONNECTION_TONE_CLASSES)
    target.classList.add(toneClass)
  },
}

const forgetMemorizedLongPollFallback = () => {
  try {
    window.sessionStorage?.removeItem("phx:fallback:LongPoll")
  } catch (_error) {
    return
  }
}

forgetMemorizedLongPollFallback()

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 8000,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    ApexBarChart,
    ApexTimeSeriesChart,
    CallyDatePicker,
    ClipboardCopy,
    FlashAutoDismiss,
    OtpInput,
    QuotaPressureChart,
    TotpSetupTools,
    WebSocketState,
  },
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
