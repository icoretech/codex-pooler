export const wsRelativeTime = (timestamp, now = Date.now()) => {
  if (!timestamp) return ""

  const seconds = Math.max(0, Math.round((now - timestamp) / 1000))
  if (seconds < 5) return "now"
  if (seconds < 60) return `${seconds}s ago`

  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`

  const hours = Math.floor(minutes / 60)
  const restMinutes = minutes % 60

  if (hours < 24) {
    return restMinutes > 0 ? `${hours}h ${restMinutes}m ago` : `${hours}h ago`
  }

  const days = Math.floor(hours / 24)
  const restHours = hours % 24
  return restHours > 0 ? `${days}d ${restHours}h ago` : `${days}d ago`
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

const closureText = (closedKind) =>
  closedKind === "longpoll" ? "Long polling dropped" : "WebSocket closed"

const retriesText = (count) =>
  `${count} ${count === 1 ? "retry" : "retries"} failed`

export const connectionTimelineSteps = (visual, history, now = Date.now()) => {
  const {lastConnectedAt, lastClosedAt, closedKind, attempts, lastRttMs, lastRttAt} = history
  const rttLabel = lastRttMs ? ` · ${lastRttMs}ms` : ""
  const steps = []

  switch (visual) {
    case "websocketConnected":
      steps.push({
        tone: "ok",
        emphasis: true,
        text: "WebSocket connected",
        time: wsRelativeTime(lastConnectedAt, now) || "now",
      })
      if (lastRttMs) {
        steps.push({
          tone: "ok",
          text: `Heartbeat healthy · ${lastRttMs}ms`,
          time: wsRelativeTime(lastRttAt, now),
        })
      }
      break

    case "longPollFallback":
      // Fallback always follows a real websocket failure: the memorized
      // sessionStorage shortcut is cleared on every boot, so even when the
      // failure predates this page's timers it happened.
      steps.push({
        tone: "bad",
        text: "WebSocket failed",
        time: wsRelativeTime(lastClosedAt, now),
      })
      steps.push({
        tone: "now",
        emphasis: true,
        text: `Long polling active${rttLabel}`,
        time: "now",
      })
      break

    case "connecting":
      if (lastClosedAt) {
        steps.push({
          tone: "done",
          text: closureText(closedKind),
          time: wsRelativeTime(lastClosedAt, now),
        })
      }
      if (attempts > 0) {
        steps.push({tone: "done", text: retriesText(attempts), time: ""})
      }
      steps.push({
        tone: "now",
        emphasis: true,
        text: lastClosedAt
          ? `Reconnecting · attempt ${attempts + 1}`
          : "Connecting to live updates",
        time: "now",
      })
      break

    default:
      if (lastClosedAt) {
        steps.push({
          tone: "done",
          text: closureText(closedKind),
          time: wsRelativeTime(lastClosedAt, now),
        })
      }
      if (attempts > 0) {
        steps.push({tone: "bad", text: retriesText(attempts), time: ""})
      }
      steps.push({
        tone: "bad",
        emphasis: true,
        text: "Offline · data may be stale",
        time: "now",
      })
  }

  return steps
}

export const connectionHint = (visual) => {
  switch (visual) {
    case "longPollFallback":
      return "Updates arrive by polling — slightly slower but complete."
    case "connecting":
      return "Page data is still shown; refreshes resume once the socket is back."
    default:
      return null
  }
}

export const displayEndpoint = (endPoint) =>
  (endPoint || "/live").replace(/\/(websocket|longpoll)$/, "")

export const connectionFooterMeta = (visual, {endPoint, heartbeatIntervalMs, online}) => {
  if (connectedVisual(visual)) {
    const heartbeat = heartbeatIntervalMs
      ? `heartbeat ${Math.round(heartbeatIntervalMs / 1000)}s`
      : "heartbeat default"
    return `${displayEndpoint(endPoint)} · ${heartbeat}`
  }

  return `network: ${online ? "online" : "offline"}`
}

export const connectionActionLabel = (visual) => {
  switch (visual) {
    case "longPollFallback":
      return "Retry WebSocket"
    case "connecting":
    case "disconnected":
      return "Reconnect now"
    default:
      return null
  }
}
