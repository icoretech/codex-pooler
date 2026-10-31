import test from "node:test"
import assert from "node:assert/strict"

import {classifyLiveSocketConnection, normalizeLiveSocketTransport} from "./live_socket_connection.mjs"

test("normalizes Phoenix longpoll transport through transportName instead of minified constructor name", () => {
  const socket = {
    transport: function At() {},
    transportName: () => "LongPoll",
  }

  assert.deepEqual(normalizeLiveSocketTransport(socket), {
    transportKey: "longpoll",
    transportLabel: "Long polling",
  })
})

test("normalizes websocket transport through Phoenix transportName", () => {
  const socket = {
    transport: function wt() {},
    transportName: () => "WebSocket",
  }

  assert.deepEqual(normalizeLiveSocketTransport(socket), {
    transportKey: "websocket",
    transportLabel: "WebSocket",
  })
})

test("never exposes minified unknown transport names to operators", () => {
  const socket = {transport: function At() {}}

  assert.deepEqual(normalizeLiveSocketTransport(socket), {
    transportKey: "unknown",
    transportLabel: "Unknown",
  })
})

test("classifies connected browser admin websocket separately from Codex protocol websocket", () => {
  const liveSocket = {isConnected: () => true}
  const socket = {
    transport: function wt() {},
    transportName: () => "WebSocket",
    connectionState: () => "open",
  }

  assert.deepEqual(classifyLiveSocketConnection(liveSocket, socket), {
    transportKey: "websocket",
    transportLabel: "WebSocket",
    visualState: "websocketConnected",
  })
})

test("classifies connected longpoll as browser admin fallback", () => {
  const liveSocket = {isConnected: () => true}
  const socket = {
    transport: function At() {},
    transportName: () => "LongPoll",
    connectionState: () => "open",
  }

  assert.deepEqual(classifyLiveSocketConnection(liveSocket, socket), {
    transportKey: "longpoll",
    transportLabel: "Long polling",
    visualState: "longPollFallback",
  })
})

test("transport labels accept translated copy without changing transport keys", () => {
  const labels = {transportPending: "待连接", transportUnknown: "未知", transportLongPolling: "长轮询", transportWebsocket: "WebSocket"}
  assert.deepEqual(classifyLiveSocketConnection(null, null, labels), {transportKey: "pending", transportLabel: "待连接", visualState: "connecting"})
  assert.deepEqual(normalizeLiveSocketTransport({}, labels), {transportKey: "unknown", transportLabel: "未知"})
  const longpoll = {transport: function At() {}, transportName: () => "LongPoll", connectionState: () => "open"}
  assert.deepEqual(classifyLiveSocketConnection({isConnected: () => true}, longpoll, labels), {transportKey: "longpoll", transportLabel: "长轮询", visualState: "longPollFallback"})
  const websocket = {transport: function wt() {}, transportName: () => "WebSocket", connectionState: () => "open"}
  assert.equal(normalizeLiveSocketTransport(websocket, labels).transportKey, "websocket")
})
