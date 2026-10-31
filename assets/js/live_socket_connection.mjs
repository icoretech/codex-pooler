import {hookLabel} from "./hook_labels.mjs"

export const classifyLiveSocketConnection = (liveSocket, socket, labels = {}) => {
  if (!liveSocket || !socket) {
    return {transportKey: "pending", transportLabel: hookLabel(labels, "transportPending", "Pending"), visualState: "connecting"}
  }

  const state = socket?.connectionState?.() || readyStateLabel(socket?.conn?.readyState)
  const connected = liveSocket?.isConnected?.() || socket?.isConnected?.() || state === "open"
  const transport = normalizeLiveSocketTransport(socket, labels)

  if (connected && transport.transportKey === "longpoll") {
    return {...transport, visualState: "longPollFallback"}
  }

  if (connected) {
    return {...transport, visualState: "websocketConnected"}
  }

  if (state === "connecting") {
    return {...transport, visualState: "connecting"}
  }

  return {...transport, visualState: "disconnected"}
}

export const normalizeLiveSocketTransport = (socket, labels = {}) => {
  const transportName = phoenixTransportName(socket) || connectionTransportName(socket)

  if (!transportName) {
    return {transportKey: "unknown", transportLabel: hookLabel(labels, "transportUnknown", "Unknown")}
  }

  const normalized = transportName.toString().replace(/[_\s-]+/g, "").toLowerCase()

  if (normalized.includes("longpoll")) {
    return {transportKey: "longpoll", transportLabel: hookLabel(labels, "transportLongPolling", "Long polling")}
  }

  if (normalized.includes("websocket")) {
    return {transportKey: "websocket", transportLabel: hookLabel(labels, "transportWebsocket", "WebSocket")}
  }

  return {transportKey: "unknown", transportLabel: hookLabel(labels, "transportUnknown", "Unknown")}
}

const phoenixTransportName = (socket) => {
  if (typeof socket?.transportName !== "function" || !socket?.transport) return null

  const name = socket.transportName(socket.transport)
  return saneTransportName(name) ? name : null
}

const connectionTransportName = (socket) => {
  if (isBrowserWebSocket(socket?.conn)) return "websocket"
  if (looksLikeLongPoll(socket?.conn)) return "longpoll"

  const name = socket?.transport?.name || socket?.transport?.constructor?.name
  return saneTransportName(name) ? name : null
}

const saneTransportName = (name) => {
  if (typeof name !== "string") return false

  const normalized = name.replace(/[_\s-]+/g, "").toLowerCase()
  return normalized.includes("longpoll") || normalized.includes("websocket")
}

const isBrowserWebSocket = (conn) => {
  if (typeof WebSocket !== "undefined" && conn instanceof WebSocket) return true

  return conn?.constructor?.name === "WebSocket"
}

const looksLikeLongPoll = (conn) => {
  return Boolean(conn && typeof conn.poll === "function" && typeof conn.closeAndRetry === "function")
}

const readyStateLabel = (readyState) => {
  if (typeof WebSocket === "undefined") return null

  switch (readyState) {
    case WebSocket.CONNECTING:
      return "connecting"
    case WebSocket.OPEN:
      return "open"
    case WebSocket.CLOSING:
      return "closing"
    case WebSocket.CLOSED:
      return "closed"
    default:
      return null
  }
}
