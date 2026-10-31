import {hookLabel} from "./hook_labels.mjs"

export const wsRelativeTime = (timestamp, now = Date.now(), labels = {}) => {
  if (!timestamp) return ""

  const seconds = Math.max(0, Math.round((now - timestamp) / 1000))
  if (seconds < 5) return hookLabel(labels, "now", "now")

  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  const days = Math.floor(hours / 24)
  let duration

  if (seconds < 60) duration = `${seconds}s`
  else if (minutes < 60) duration = `${minutes}m`
  else if (hours < 24) {
    const restMinutes = minutes % 60
    duration = restMinutes > 0 ? `${hours}h ${restMinutes}m` : `${hours}h`
  } else {
    const restHours = hours % 24
    duration = restHours > 0 ? `${days}d ${restHours}h` : `${days}d`
  }

  return hookLabel(labels, "ago", "%{duration} ago", {duration})
}

export const initialConnectionHistory = () => ({
  prevVisual: null,
  lastConnectedAt: null,
  lastClosedAt: null,
  closedKind: null,
  attempts: 0,
  lastRttMs: null,
  lastRttAt: null,
})

const connectedVisual = (visual) =>
  visual === "websocketConnected" || visual === "longPollFallback"

const closedKindFor = (visual) =>
  visual === "longPollFallback" ? "longpoll" : "websocket"

export const trackConnectionTransition = (history, visual, now = Date.now()) => {
  if (visual === history.prevVisual) return history

  const next = {...history, prevVisual: visual}
  const wasConnected = connectedVisual(history.prevVisual)
  const isConnected = connectedVisual(visual)

  if (isConnected) {
    next.lastConnectedAt = now
    next.attempts = 0
  }

  if (wasConnected && !isConnected) {
    next.lastClosedAt = now
    next.closedKind = closedKindFor(history.prevVisual)
    next.attempts = 0
    next.lastRttMs = null
    next.lastRttAt = null
  }

  // A direct connected-to-connected switch means the previous transport
  // dropped between samples: stamp the closure and drop its round trip.
  if (wasConnected && isConnected) {
    next.lastClosedAt = now
    next.closedKind = closedKindFor(history.prevVisual)
    next.lastRttMs = null
    next.lastRttAt = null
  }

  return next
}

// Attempts are counted from socket error callbacks (precise), not from the
// sampled visual transitions, which miss fast retry cycles.
export const recordSocketError = (history) => ({
  ...history,
  attempts: history.attempts + 1,
})

export const recordRoundTrip = (history, rttMs, now = Date.now()) => ({
  ...history,
  lastRttMs: Math.max(1, Math.round(rttMs)),
  lastRttAt: now,
})

const closureText = (closedKind, labels) =>
  closedKind === "longpoll"
    ? hookLabel(labels, "longPollingDropped", "Long polling dropped")
    : hookLabel(labels, "websocketClosed", "WebSocket closed")

const retriesText = (count, labels) =>
  hookLabel(labels, count === 1 ? "retriesOne" : "retriesOther",
    count === 1 ? "%{retries} retry failed" : "%{retries} retries failed", {retries: count})

export const connectionTimelineSteps = (visual, history, now = Date.now(), labels = {}) => {
  const {lastConnectedAt, lastClosedAt, closedKind, attempts, lastRttMs, lastRttAt} = history
  const steps = []

  switch (visual) {
    case "websocketConnected":
      steps.push({
        tone: "ok",
        emphasis: true,
        text: hookLabel(labels, "websocketConnected", "WebSocket connected"),
        time: wsRelativeTime(lastConnectedAt, now, labels) || hookLabel(labels, "now", "now"),
      })
      if (lastRttMs) {
        steps.push({
          tone: "ok",
          text: hookLabel(labels, "heartbeatHealthy", "Heartbeat healthy · %{milliseconds}ms", {milliseconds: lastRttMs}),
          time: wsRelativeTime(lastRttAt, now, labels),
        })
      }
      break

    case "longPollFallback":
      // Fallback always follows a real websocket failure: the memorized
      // sessionStorage shortcut is cleared on every boot, so even when the
      // failure predates this page's timers it happened.
      steps.push({
        tone: "bad",
        text: hookLabel(labels, "websocketFailed", "WebSocket failed"),
        time: wsRelativeTime(lastClosedAt, now, labels),
      })
      steps.push({
        tone: "now",
        emphasis: true,
        text: lastRttMs
          ? hookLabel(labels, "longPollingActiveRtt", "Long polling active · %{milliseconds}ms", {milliseconds: lastRttMs})
          : hookLabel(labels, "longPollingActive", "Long polling active"),
        time: hookLabel(labels, "now", "now"),
      })
      break

    case "connecting":
      if (lastClosedAt) {
        steps.push({
          tone: "done",
          text: closureText(closedKind, labels),
          time: wsRelativeTime(lastClosedAt, now, labels),
        })
      }
      if (attempts > 0) {
        steps.push({tone: "done", text: retriesText(attempts, labels), time: ""})
      }
      steps.push({
        tone: "now",
        emphasis: true,
        text: lastClosedAt
          ? hookLabel(labels, "reconnecting", "Reconnecting · attempt %{attempt}", {attempt: attempts + 1})
          : hookLabel(labels, "connecting", "Connecting to live updates"),
        time: hookLabel(labels, "now", "now"),
      })
      break

    default:
      if (lastClosedAt) {
        steps.push({
          tone: "done",
          text: closureText(closedKind, labels),
          time: wsRelativeTime(lastClosedAt, now, labels),
        })
      }
      if (attempts > 0) {
        steps.push({tone: "bad", text: retriesText(attempts, labels), time: ""})
      }
      steps.push({
        tone: "bad",
        emphasis: true,
        text: hookLabel(labels, "offlineStale", "Offline · data may be stale"),
        time: hookLabel(labels, "now", "now"),
      })
  }

  return steps
}

export const connectionHint = (visual, labels = {}) => {
  switch (visual) {
    case "longPollFallback":
      return hookLabel(labels, "fallbackHint", "Updates arrive by polling — slightly slower but complete.")
    case "connecting":
      return hookLabel(labels, "connectingHint", "Page data is still shown; refreshes resume once the socket is back.")
    default:
      return null
  }
}

export const displayEndpoint = (endPoint) =>
  (endPoint || "/live").replace(/\/(websocket|longpoll)$/, "")

export const connectionFooterParts = (visual, {endPoint, heartbeatIntervalMs, online}, labels = {}) => {
  if (connectedVisual(visual)) {
    // "keepalive", not "heartbeat": this is Phoenix's idle keepalive
    // interval, distinct from the measured heartbeat RTT in the timeline.
    return {
      meta: displayEndpoint(endPoint),
      detail: heartbeatIntervalMs
        ? hookLabel(labels, "keepalive", "keepalive %{seconds}s", {seconds: Math.round(heartbeatIntervalMs / 1000)})
        : hookLabel(labels, "keepaliveDefault", "keepalive default"),
    }
  }

  return {meta: online
    ? hookLabel(labels, "networkOnline", "network: online")
    : hookLabel(labels, "networkOffline", "network: offline"), detail: null}
}

export const connectionActionLabel = (visual, labels = {}) => {
  switch (visual) {
    case "longPollFallback":
      return hookLabel(labels, "retryWebsocket", "Retry WebSocket")
    case "connecting":
    case "disconnected":
      return hookLabel(labels, "reconnectNow", "Reconnect now")
    default:
      return null
  }
}

export const connectionVisualLabel = (visual, labels = {}) => {
  switch (visual) {
    case "websocketConnected":
      return hookLabel(labels, "connectedLabel", "Live updates: live")
    case "longPollFallback":
      return hookLabel(labels, "fallbackLabel", "Live updates: fallback connection")
    case "disconnected":
      return hookLabel(labels, "disconnectedLabel", "Live updates: offline")
    default:
      return hookLabel(labels, "connectingLabel", "Live updates: syncing")
  }
}
