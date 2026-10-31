import test from "node:test"
import assert from "node:assert/strict"

import {
  connectionActionLabel,
  connectionFooterParts,
  connectionHint,
  connectionTimelineSteps,
  connectionVisualLabel,
  displayEndpoint,
  initialConnectionHistory,
  recordRoundTrip,
  recordSocketError,
  trackConnectionTransition,
  wsRelativeTime,
} from "./ws_state_timeline.mjs"

const T0 = 1_750_000_000_000
const SECONDS = 1000
const MINUTES = 60 * SECONDS
const HOURS = 60 * MINUTES
const DAYS = 24 * HOURS

test("relative time buckets: now, seconds, minutes, hours, days", () => {
  assert.equal(wsRelativeTime(null, T0), "")
  assert.equal(wsRelativeTime(T0 - 2 * SECONDS, T0), "now")
  assert.equal(wsRelativeTime(T0 - 42 * SECONDS, T0), "42s ago")
  assert.equal(wsRelativeTime(T0 - 12 * MINUTES, T0), "12m ago")
  assert.equal(wsRelativeTime(T0 - (2 * HOURS + 14 * MINUTES), T0), "2h 14m ago")
  assert.equal(wsRelativeTime(T0 - (3 * DAYS + 5 * HOURS), T0), "3d 5h ago")
})

test("relative time omits zero remainders and never goes negative", () => {
  assert.equal(wsRelativeTime(T0 - 1 * HOURS, T0), "1h ago")
  assert.equal(wsRelativeTime(T0 - 2 * DAYS, T0), "2d ago")
  assert.equal(wsRelativeTime(T0 + 30 * SECONDS, T0), "now")
})

test("initial connect: connecting stamps nothing, connected stamps and resets attempts", () => {
  let history = initialConnectionHistory()

  history = trackConnectionTransition(history, "connecting", T0)
  assert.equal(history.attempts, 0)
  assert.equal(history.prevVisual, "connecting")
  assert.equal(history.lastConnectedAt, null)

  history = recordSocketError(history)
  assert.equal(history.attempts, 1)

  history = trackConnectionTransition(history, "websocketConnected", T0 + SECONDS)
  assert.equal(history.attempts, 0)
  assert.equal(history.lastConnectedAt, T0 + SECONDS)
  assert.equal(history.lastClosedAt, null)
})

test("repeated same state is a no-op and returns the same history object", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "websocketConnected", T0)

  const again = trackConnectionTransition(history, "websocketConnected", T0 + MINUTES)
  assert.equal(again, history)
})

test("losing the connection stamps lastClosedAt, its transport kind, and clears the round trip", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "websocketConnected", T0)
  history = recordRoundTrip(history, 46.4, T0 + SECONDS)
  assert.equal(history.lastRttMs, 46)

  history = trackConnectionTransition(history, "connecting", T0 + MINUTES)
  assert.equal(history.lastClosedAt, T0 + MINUTES)
  assert.equal(history.closedKind, "websocket")
  assert.equal(history.lastRttMs, null)
  assert.equal(history.lastRttAt, null)
})

test("socket errors accumulate during an outage until reconnect resets them", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "websocketConnected", T0)
  history = trackConnectionTransition(history, "connecting", T0 + 1 * SECONDS)
  history = recordSocketError(history)
  history = trackConnectionTransition(history, "disconnected", T0 + 2 * SECONDS)
  history = recordSocketError(history)
  history = trackConnectionTransition(history, "connecting", T0 + 5 * SECONDS)
  history = recordSocketError(history)
  assert.equal(history.attempts, 3)

  history = trackConnectionTransition(history, "websocketConnected", T0 + 13 * SECONDS)
  assert.equal(history.attempts, 0)
  assert.equal(history.lastConnectedAt, T0 + 13 * SECONDS)
})

test("a direct connected-to-connected transport switch stamps the closure and drops stale RTT", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "websocketConnected", T0)
  history = recordRoundTrip(history, 46, T0 + SECONDS)

  history = trackConnectionTransition(history, "longPollFallback", T0 + 2 * SECONDS)
  assert.equal(history.lastClosedAt, T0 + 2 * SECONDS)
  assert.equal(history.closedKind, "websocket")
  assert.equal(history.lastRttMs, null)
  assert.equal(history.lastConnectedAt, T0 + 2 * SECONDS)
})

test("round trips clamp to at least one millisecond", () => {
  const history = recordRoundTrip(initialConnectionHistory(), 0.2, T0)
  assert.equal(history.lastRttMs, 1)
  assert.equal(history.lastRttAt, T0)
})

test("healthy websocket renders connected step plus heartbeat when measured", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "websocketConnected", T0 - 10 * SECONDS)

  const bare = connectionTimelineSteps("websocketConnected", history, T0)
  assert.deepEqual(bare.map((step) => step.text), ["WebSocket connected"])
  assert.equal(bare[0].tone, "ok")
  assert.equal(bare[0].emphasis, true)
  assert.equal(bare[0].time, "10s ago")

  history = recordRoundTrip(history, 55, T0 - 5 * SECONDS)
  const withPing = connectionTimelineSteps("websocketConnected", history, T0)
  assert.deepEqual(
    withPing.map((step) => step.text),
    ["WebSocket connected", "Heartbeat healthy · 55ms"],
  )
  assert.equal(withPing[1].tone, "ok")
})

test("fallback always names the websocket failure, timed when observed this session", () => {
  let bootFallback = initialConnectionHistory()
  bootFallback = trackConnectionTransition(bootFallback, "longPollFallback", T0)

  const bootSteps = connectionTimelineSteps("longPollFallback", bootFallback, T0)
  assert.deepEqual(
    bootSteps.map((step) => step.text),
    ["WebSocket failed", "Long polling active"],
  )
  assert.equal(bootSteps[0].tone, "bad")
  assert.equal(bootSteps[0].time, "")
  assert.equal(bootSteps[1].tone, "now")

  let failed = initialConnectionHistory()
  failed = trackConnectionTransition(failed, "websocketConnected", T0 - 40 * MINUTES)
  failed = trackConnectionTransition(failed, "connecting", T0 - 38 * MINUTES)
  failed = trackConnectionTransition(failed, "longPollFallback", T0 - 37 * MINUTES)
  failed = recordRoundTrip(failed, 184, T0 - 10 * SECONDS)

  const failedSteps = connectionTimelineSteps("longPollFallback", failed, T0)
  assert.deepEqual(
    failedSteps.map((step) => step.text),
    ["WebSocket failed", "Long polling active · 184ms"],
  )
  assert.equal(failedSteps[0].time, "38m ago")
})

test("first connect shows connecting copy, mid-outage retries say reconnecting with attempt", () => {
  let fresh = initialConnectionHistory()
  fresh = trackConnectionTransition(fresh, "connecting", T0)

  const freshSteps = connectionTimelineSteps("connecting", fresh, T0)
  assert.deepEqual(freshSteps.map((step) => step.text), ["Connecting to live updates"])

  let outage = initialConnectionHistory()
  outage = trackConnectionTransition(outage, "websocketConnected", T0 - 5 * MINUTES)
  outage = trackConnectionTransition(outage, "connecting", T0 - 42 * SECONDS)

  const firstRetry = connectionTimelineSteps("connecting", outage, T0)
  assert.deepEqual(
    firstRetry.map((step) => step.text),
    ["WebSocket closed", "Reconnecting · attempt 1"],
  )

  outage = recordSocketError(outage)
  outage = trackConnectionTransition(outage, "disconnected", T0 - 30 * SECONDS)
  outage = trackConnectionTransition(outage, "connecting", T0 - 2 * SECONDS)

  const secondAttempt = connectionTimelineSteps("connecting", outage, T0)
  assert.deepEqual(
    secondAttempt.map((step) => step.text),
    ["WebSocket closed", "1 retry failed", "Reconnecting · attempt 2"],
  )
  assert.equal(secondAttempt[2].tone, "now")
})

test("offline renders the outage summary with pluralized retries", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "websocketConnected", T0 - 10 * MINUTES)
  history = trackConnectionTransition(history, "connecting", T0 - 6 * MINUTES)
  history = recordSocketError(history)
  history = trackConnectionTransition(history, "disconnected", T0 - 5 * MINUTES)
  history = trackConnectionTransition(history, "connecting", T0 - 3 * MINUTES)
  history = recordSocketError(history)
  history = trackConnectionTransition(history, "disconnected", T0 - 2 * MINUTES)

  const steps = connectionTimelineSteps("disconnected", history, T0)
  assert.deepEqual(
    steps.map((step) => step.text),
    ["WebSocket closed", "2 retries failed", "Offline · data may be stale"],
  )
  assert.equal(steps[2].tone, "bad")
  assert.equal(steps[2].emphasis, true)
})

test("longpoll drops are named as long polling, not websocket", () => {
  let history = initialConnectionHistory()
  history = trackConnectionTransition(history, "longPollFallback", T0 - 10 * MINUTES)
  history = trackConnectionTransition(history, "disconnected", T0 - 2 * MINUTES)

  const steps = connectionTimelineSteps("disconnected", history, T0)
  assert.equal(steps[0].text, "Long polling dropped")
})

test("offline before any connection still renders the offline step", () => {
  const steps = connectionTimelineSteps("disconnected", initialConnectionHistory(), T0)
  assert.deepEqual(steps.map((step) => step.text), ["Offline · data may be stale"])
})

test("hints exist only for fallback and connecting", () => {
  assert.match(connectionHint("longPollFallback"), /polling/)
  assert.match(connectionHint("connecting"), /still shown/)
  assert.equal(connectionHint("websocketConnected"), null)
  assert.equal(connectionHint("disconnected"), null)
})

test("footer splits endpoint and keepalive when connected, network-only otherwise", () => {
  const connected = connectionFooterParts("websocketConnected", {
    endPoint: "/live/websocket",
    heartbeatIntervalMs: 30000,
    online: true,
  })
  assert.deepEqual(connected, {meta: "/live", detail: "keepalive 30s"})

  const fallback = connectionFooterParts("longPollFallback", {
    endPoint: "/live/longpoll",
    heartbeatIntervalMs: null,
    online: true,
  })
  assert.deepEqual(fallback, {meta: "/live", detail: "keepalive default"})

  assert.deepEqual(
    connectionFooterParts("disconnected", {endPoint: null, online: true}),
    {meta: "network: online", detail: null},
  )
  assert.deepEqual(
    connectionFooterParts("connecting", {endPoint: null, online: false}),
    {meta: "network: offline", detail: null},
  )
})

test("endpoint display strips only the transport suffix", () => {
  assert.equal(displayEndpoint("/live/websocket"), "/live")
  assert.equal(displayEndpoint("/live/longpoll"), "/live")
  assert.equal(displayEndpoint("/live"), "/live")
  assert.equal(displayEndpoint(null), "/live")
  assert.equal(displayEndpoint("/socket/websocket/live"), "/socket/websocket/live")
})

test("the action matches the state: retry on fallback, reconnect when down, none when live", () => {
  assert.equal(connectionActionLabel("longPollFallback"), "Retry WebSocket")
  assert.equal(connectionActionLabel("connecting"), "Reconnect now")
  assert.equal(connectionActionLabel("disconnected"), "Reconnect now")
  assert.equal(connectionActionLabel("websocketConnected"), null)
})

test("translated relative time retains the compact Latin duration units", () => {
  const labels = {now: "现在", ago: "%{duration} 前"}
  assert.equal(wsRelativeTime(T0, T0, labels), "现在")
  assert.equal(wsRelativeTime(T0 - 42 * SECONDS, T0, labels), "42s 前")
  assert.equal(wsRelativeTime(T0 - 12 * MINUTES, T0, labels), "12m 前")
  assert.equal(wsRelativeTime(T0 - (2 * HOURS + 14 * MINUTES), T0, labels), "2h 14m 前")
  assert.equal(wsRelativeTime(T0 - (3 * DAYS + 5 * HOURS), T0, labels), "3d 5h 前")
})

test("translated timeline labels interpolate heartbeat and separate retry plural templates", () => {
  const labels = {
    now: "现在", ago: "%{duration} 前",
    websocketConnected: "WebSocket 已连接",
    heartbeatHealthy: "心跳正常 · %{milliseconds}ms",
    websocketClosed: "WebSocket 已关闭",
    longPollingDropped: "长轮询已断开",
    websocketFailed: "WebSocket 连接失败",
    longPollingActive: "长轮询已启用",
    longPollingActiveRtt: "长轮询已启用 · %{milliseconds}ms",
    retriesOne: "%{retries} 次重试失败（单次）",
    retriesOther: "%{retries} 次重试失败（多次）",
    reconnecting: "正在重新连接 · 第 %{attempt} 次尝试",
    connecting: "正在连接实时更新",
    offlineStale: "离线 · 数据可能已过期",
  }
  let history = trackConnectionTransition(initialConnectionHistory(), "websocketConnected", T0 - 10 * SECONDS)
  history = recordRoundTrip(history, 55, T0 - 5 * SECONDS)
  assert.deepEqual(connectionTimelineSteps("websocketConnected", history, T0, labels).map(({text, time}) => [text, time]), [
    ["WebSocket 已连接", "10s 前"], ["心跳正常 · 55ms", "5s 前"],
  ])

  history = trackConnectionTransition(history, "connecting", T0 - 3 * SECONDS)
  history = recordSocketError(history)
  assert.deepEqual(connectionTimelineSteps("connecting", history, T0, labels).map(({text}) => text), [
    "WebSocket 已关闭", "1 次重试失败（单次）", "正在重新连接 · 第 2 次尝试",
  ])
  history = recordSocketError(history)
  assert.deepEqual(connectionTimelineSteps("disconnected", history, T0, labels).map(({text}) => text), [
    "WebSocket 已关闭", "2 次重试失败（多次）", "离线 · 数据可能已过期",
  ])
  history = trackConnectionTransition(history, "longPollFallback", T0)
  assert.deepEqual(connectionTimelineSteps("longPollFallback", history, T0, labels).map(({text}) => text), [
    "WebSocket 连接失败", "长轮询已启用",
  ])
  history = recordRoundTrip(history, 184, T0)
  assert.equal(connectionTimelineSteps("longPollFallback", history, T0, labels)[1].text, "长轮询已启用 · 184ms")
  history = trackConnectionTransition(history, "disconnected", T0)
  assert.equal(connectionTimelineSteps("disconnected", history, T0, labels)[0].text, "长轮询已断开")
  assert.equal(connectionTimelineSteps("connecting", initialConnectionHistory(), T0, labels)[0].text, "正在连接实时更新")
})

test("translated indicator names, hints, footer and actions keep transport state unchanged", () => {
  const labels = {
    connectingLabel: "实时更新：正在同步", connectedLabel: "实时更新：实时",
    fallbackLabel: "实时更新：备用连接", disconnectedLabel: "实时更新：离线",
    fallbackHint: "通过轮询接收更新。", connectingHint: "重新连接后继续刷新。",
    keepalive: "连接保活 %{seconds}s", keepaliveDefault: "默认连接保活",
    networkOnline: "网络：在线", networkOffline: "网络：离线",
    retryWebsocket: "重试 WebSocket", reconnectNow: "立即重新连接",
  }
  for (const [visual, fallback, translated] of [
    ["connecting", "Live updates: syncing", "实时更新：正在同步"],
    ["websocketConnected", "Live updates: live", "实时更新：实时"],
    ["longPollFallback", "Live updates: fallback connection", "实时更新：备用连接"],
    ["disconnected", "Live updates: offline", "实时更新：离线"],
  ]) {
    assert.equal(connectionVisualLabel(visual), fallback)
    assert.equal(connectionVisualLabel(visual, labels), translated)
  }
  assert.equal(connectionHint("longPollFallback", labels), "通过轮询接收更新。")
  assert.equal(connectionHint("connecting", labels), "重新连接后继续刷新。")
  assert.equal(connectionHint("websocketConnected", labels), null)
  assert.deepEqual(connectionFooterParts("websocketConnected", {endPoint: "/live/websocket", heartbeatIntervalMs: 30000}, labels), {meta: "/live", detail: "连接保活 30s"})
  assert.equal(connectionFooterParts("longPollFallback", {}, labels).detail, "默认连接保活")
  assert.equal(connectionFooterParts("disconnected", {online: true}, labels).meta, "网络：在线")
  assert.equal(connectionFooterParts("disconnected", {online: false}, labels).meta, "网络：离线")
  assert.equal(connectionActionLabel("longPollFallback", labels), "重试 WebSocket")
  assert.equal(connectionActionLabel("connecting", labels), "立即重新连接")
  assert.equal(connectionActionLabel("websocketConnected", labels), null)
})
