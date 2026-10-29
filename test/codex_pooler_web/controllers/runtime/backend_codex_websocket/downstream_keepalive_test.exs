defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.DownstreamKeepaliveTest do
  # The downstream idle bound is Bandit's read timeout, which only bytes from
  # the client re-arm, and the released client sends nothing while a response
  # streams: a turn streaming longer than `websocket_idle_timeout_ms` was closed
  # in the middle (close 1002) and settled `client_disconnected` (findings#302).
  # The first delivered frame triggers a Ping immediately; subsequent progress
  # pings at every third of the bound. The client's Pong re-arms the timer; a
  # turn that stops delivering gets no further ping and is closed by the bound.
  #
  # Topology: the real public listener and a Mint client, FakeUpstream pacing
  # the provider's frames on the upstream websocket, the Pool's default mode
  # (Full), owner forwarding off and on (the owner on this node). The bound is
  # one second through the test-only settings override; the behaviour is a
  # timer's, so each arm spends up to about two and a half seconds of real
  # time. The bound also covers the turn's setup before its first frame, which
  # the client's request frame starts; the peer module's half-second bound was
  # shorter than that setup on a shared CI node (Drone 1809).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, register_unboxed_pool_cleanup!: 1, start_upstream: 1]
  import CodexPoolerWeb.Runtime.DownstreamKeepaliveScenario
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestOutcome}
  alias CodexPooler.Events
  alias CodexPooler.Events.OutboxDispatcher
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true

  @idle_timeout_ms 1_000
  @frame_interval_ms 100

  setup %{forwarding: forwarding?} = context do
    # request_finalized is published after commit; a shared sandbox rolls its
    # outer transaction back and cannot exercise this consumer.
    CodexPooler.DataCase.stop_sandbox(context.sandbox_owner, context.sandbox_settings_cache)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok = Sandbox.mode(Repo, :auto)
    put_settings!([websocket_idle_timeout_ms: @idle_timeout_ms], forwarding?)
    start_supervised!({OutboxDispatcher, enabled: true, name: nil})
    :ok
  end

  for forwarding? <- [false, true], mode <- ["full", "lite"] do
    topology = if forwarding?, do: "local owner", else: "direct"

    @tag forwarding: forwarding?
    @tag late_first_progress: true
    @tag slow: "two actual empty keepalive ticks precede late first progress and a client Pong delayed by 50 ms"
    test "#{topology} #{mode}: late first progress keeps the responsive client open" do
      assert_late_start!(unquote(forwarding?), unquote(mode))
    end
  end

  defp assert_late_start!(forwarding?, mode) do
    put_settings!([websocket_idle_timeout_ms: 1_500, upstream_receive_timeout_ms: 1_000], forwarding?)
    scope = model_serving_scope()
    upstream = start_upstream(FakeUpstream.delayed_sse_stream(stream_events("resp_late_first_progress", 3), interval_ms: @frame_interval_ms))
    setup = committed_gateway_setup!(upstream)
    set_model_serving_mode!(scope, setup, mode)
    %{turn: turn, request: request} = assert_late_start_completed!(setup)
    assert is_nil(turn.client.owner)

    if forwarding? do
      assert %{"owner_instance_id" => owner, "proxy_instance_id" => proxy} = request.request_metadata["websocket_owner_forwarding"]
      assert owner == proxy
    else
      refute Map.has_key?(request.request_metadata, "websocket_owner_forwarding")
    end

    assert FakeUpstream.count(upstream) == 1
    FakeUpstream.verify!(upstream)
  end

  for forwarding? <- [false, true] do
    topology = if forwarding?, do: "owner forwarding on", else: "owner forwarding off"

    @tag forwarding: forwarding?
    @tag slow: "the idle bound is a real timer: the turn must stream for two bounds to show the pings keep it open"
    test "#{topology}: a turn streaming two idle bounds long completes for a client that answers pings" do
      # Twenty-two frames 100 ms apart: the turn streams for about 2.2 s
      # against a 1 s bound.
      deltas = 18
      upstream = start_upstream(FakeUpstream.delayed_sse_stream(stream_events("resp_keepalive_long", deltas), interval_ms: @frame_interval_ms))
      setup = committed_gateway_setup!(upstream)

      {turn, log} = with_log(fn -> setup |> start_turn!() |> read_turn!(answer_pings?: true) end)

      assert turn.end == {:terminal, "response.completed"}, "the turn " <> describe_turn(turn)
      assert Enum.count(turn.events, &(&1["type"] == "response.output_text.delta")) == deltas
      assert turn.pings >= 1, "the turn " <> describe_turn(turn)
      assert turn.elapsed_ms >= 2 * @idle_timeout_ms, "the turn " <> describe_turn(turn)
      request = assert_committed_request_settled!(setup, "succeeded", nil)
      refute Map.has_key?(request.request_metadata, "downstream_interruption")
      refute log =~ WebsocketConnectionLogger.downstream_idle_timeout_message()
      assert [%{method: "WEBSOCKET", path: "/backend-api/codex/responses"}] = FakeUpstream.requests(upstream)
      :ok = close_client!(turn.client)
    end

    @tag forwarding: forwarding?
    @tag slow: "observes the real one-second outbox poll after the peer closes its turn"
    test "#{topology}: an ordinary peer close retains client cancellation without idle attribution" do
      hold = make_ref()
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(FakeUpstream.barrier_websocket_frames(encoded_events("resp_peer_close", 1), notify: self(), release_ref: hold))]))
      setup = committed_gateway_setup!(upstream)
      client = start_turn!(setup)
      assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^hold}, detection_timeout_ms()
      :ok = FakeUpstream.release_frame(upstream, hold)
      {conn, websocket, _frame} = BackendCodexTestSupport.public_websocket_receive_text!(client.conn, client.websocket, client.ref)
      :ok = close_client!(%{client | conn: conn, websocket: websocket})
      request = assert_committed_request_settled!(setup, "failed", "client_disconnected")
      assert RequestOutcome.client_cancelled?(request)
      refute Map.has_key?(request.request_metadata, "downstream_interruption")
      :ok = FakeUpstream.release_remaining_frames(upstream, hold)
    end

    @tag forwarding: forwarding?
    @tag slow: "the idle bound is a real timer: the cut lands one bound after the request frame"
    test "#{topology}: a client that never answers pings is still cut at the idle bound" do
      # Twenty-two frames 100 ms apart: the stream outlasts the 1 s bound.
      upstream = start_upstream(FakeUpstream.delayed_sse_stream(stream_events("resp_keepalive_silent_client", 18), interval_ms: @frame_interval_ms))
      setup = committed_gateway_setup!(upstream)

      {turn, log} = with_log(fn -> setup |> start_turn!() |> read_turn!(answer_pings?: false) end)

      assert turn.end in [{:close, 1002}, :socket_closed], "the turn " <> describe_turn(turn)
      refute Enum.any?(turn.events, &(&1["type"] in terminal_types()))
      assert turn.pings >= 1, "the turn " <> describe_turn(turn)
      request = assert_committed_request_settled!(setup, "failed", "client_disconnected")
      assert_idle_attribution!(request, "unknown")
      assert log =~ "#{WebsocketConnectionLogger.downstream_idle_timeout_message()} tracked_tasks=1 idle_timeout_ms=#{@idle_timeout_ms}"
      :ok = close_client!(turn.client)
    end

    @tag forwarding: forwarding?
    @tag slow: "the idle bound is a real timer: the close lands one bound after the last pong"
    test "#{topology}: a turn that stops delivering frames gets no more pings and is closed by the idle bound" do
      hold = make_ref()
      # provenance: synthetic_adversarial
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(FakeUpstream.barrier_websocket_frames(encoded_events("resp_keepalive_stalled", 1), notify: self(), release_ref: hold))]))
      setup = committed_gateway_setup!(upstream)

      {turn, log} =
        with_log(fn ->
          client = start_turn!(setup) |> await_initial_provider_barrier!(hold)

          # Readiness traffic stops before these two frames and their stall.
          :ok = FakeUpstream.release_frame(upstream, hold)
          assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^hold}, detection_timeout_ms()
          :ok = FakeUpstream.release_frame(upstream, hold)

          assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^hold}, detection_timeout_ms()
          read_turn!(client, answer_pings?: true)
        end)

      # The client answered every ping, so the close proves the pings stopped
      # with the frames: only the ticks that saw the two frames pinged (one,
      # or two when a tick fell between them).
      assert turn.end in [{:close, 1002}, :socket_closed], "the turn " <> describe_turn(turn)
      assert Enum.map(turn.events, & &1["type"]) -- ["codex.response.metadata"] == ["response.created", "response.output_item.added"]
      assert turn.pings <= 2, "the turn " <> describe_turn(turn)
      request = assert_committed_request_settled!(setup, "failed", "client_disconnected")
      assert_idle_attribution!(request, if(turn.pings > 0, do: "pong_observed", else: "unknown"))
      assert log =~ "#{WebsocketConnectionLogger.downstream_idle_timeout_message()} tracked_tasks=1"
      :ok = FakeUpstream.release_remaining_frames(upstream, hold)
      :ok = close_client!(turn.client)
    end
  end

  defp committed_gateway_setup!(upstream) do
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    setup
  end

  defp assert_committed_request_settled!(setup, status, last_error_code) do
    assert_receive {Events, %{reason: "request_reserved", payload: %{"request_id" => request_id}}}, detection_timeout_ms()
    assert_receive {Events, %{reason: "request_finalized", payload: %{"request_id" => ^request_id, "status" => ^status}}}, detection_timeout_ms()
    assert [%Request{id: ^request_id, status: ^status, last_error_code: ^last_error_code, transport: "websocket"} = request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^request_id and entry.entry_kind == "settlement"), :count) == 1
    request
  end
end
