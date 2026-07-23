defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeTest do
  use CodexPoolerWeb.ConnCase, async: false

  defmodule ClosedChunkAdapter do
    def chunk(_payload, _chunk), do: {:error, :closed}
  end

  import Ecto.Query
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      pricing_config: 1,
      pricing_snapshot!: 2,
      start_upstream: 1
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.OpenAICompatibility.Responses, as: ResponsesCompat
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Transports.Streaming.{RetainedBody, WebsocketBridgeStream}
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  # Bridged turns start owner sessions that would otherwise outlive the test
  # (idle shutdown is minutes away) and log stale lease renewals into later
  # tests' output. Stop them the way the owner forwarding suite does.
  defp cleanup_local_owner_sessions do
    _logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn codex_session_id ->
          try do
            with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
              _result = GenServer.stop(owner_pid, :shutdown, 1_000)
            end
          catch
            :exit, _reason -> :ok
          end
        end)
      end)

    :ok
  end

  defp enable_request_compression!(pool) do
    pool
    |> PoolRouting.ensure_routing_settings()
    |> Ecto.Changeset.change(request_compression_enabled: true)
    |> Repo.update!()
  end

  defp set_upstream_receive_timeout!(timeout_ms) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])
    settings = %{OperationalSettings.current() | upstream_receive_timeout_ms: timeout_ms}

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: settings,
      use_instance_settings?: false
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp completed_event(id) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => id,
         "usage" => %{"input_tokens" => 12, "output_tokens" => 5, "total_tokens" => 17}
       }
     }}
  end

  defp created_event(id) do
    {"response.created",
     %{"type" => "response.created", "response" => %{"id" => id, "status" => "in_progress"}}}
  end

  defp event_types(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(&block_event_type/1)
  end

  defp block_event_type(block) do
    with [_line, data] <- Regex.run(~r/^data: (.+)$/m, block),
         {:ok, %{"type" => type}} <- Jason.decode(data) do
      [type]
    else
      _no_event -> []
    end
  end

  defp stream_payload(setup, input) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true
    }
  end

  defp post_stream(conn, setup, session, payload) do
    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("x-session-id", session)
    |> post("/v1/responses", payload)
  end

  defp completed_id(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^data: (.+)$/m, block) do
        [_line, data] -> [Jason.decode!(data)]
        _no_data -> []
      end
    end)
    |> Enum.find_value(fn
      %{"type" => "response.completed", "response" => %{"id" => id}} -> id
      _event -> nil
    end)
  end

  defp latest_request(pool) do
    Repo.one!(
      from r in Request,
        where: r.pool_id == ^pool.id,
        order_by: [desc: r.admitted_at],
        limit: 1
    )
  end

  defp attempts_for(request) do
    Repo.all(from a in Attempt, where: a.request_id == ^request.id)
  end

  defp settlement_count(request) do
    Repo.aggregate(
      from(l in LedgerEntry,
        where: l.request_id == ^request.id and l.entry_kind == "settlement"
      ),
      :count
    )
  end

  defp settlements_for(request) do
    Repo.all(
      from l in LedgerEntry,
        where: l.request_id == ^request.id and l.entry_kind == "settlement"
    )
  end

  defp await_rate_limit_window(identity, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.find(&(&1.source == "codex_rate_limit_event" and &1.window_kind == "primary"))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_rate_limit_window(identity, deadline)
          end
        else
          flunk("expected codex.rate_limits quota window for primary")
        end

      window ->
        window
    end
  end

  defp upstream_connection(%Attempt{} = attempt) do
    assert %{
             "lifecycle_id" => lifecycle_id,
             "generation" => generation,
             "reused" => reused,
             "reconnected" => reconnected
           } = connection = attempt.response_metadata["upstream_websocket_connection"]

    assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)
    assert is_integer(generation) and generation > 0
    assert is_boolean(reused)
    assert is_boolean(reconnected)
    assert Map.keys(connection) |> Enum.sort() == ~w(generation lifecycle_id reconnected reused)

    connection
  end

  defp assert_no_upstream_websocket_metadata(%Attempt{response_metadata: metadata}) do
    assert Map.take(
             metadata,
             ~w(upstream_transport upstream_websocket_bridge upstream_websocket_connection)
           ) ==
             %{}
  end

  defp response_failed_data(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.find_value(fn block ->
      with ["response.failed"] <- Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first),
           [data] <- Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first) do
        Jason.decode!(data)
      else
        _missing -> nil
      end
    end)
  end

  defp await_visible_turn(pool_id, attempts_left \\ 1_000)

  defp await_visible_turn(_pool_id, 0), do: flunk("expected committed public bridge turn")

  defp await_visible_turn(pool_id, attempts_left) do
    turn =
      Repo.one(
        from turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where: request.pool_id == ^pool_id,
          order_by: [desc: turn.started_at],
          limit: 1
      )

    case turn do
      %CodexTurn{first_visible_output_at: %DateTime{}} ->
        turn

      _pending ->
        receive do
        after
          1 -> await_visible_turn(pool_id, attempts_left - 1)
        end
    end
  end

  test "three healthy sessioned turns reuse one websocket lifecycle and generation", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([completed_event("resp_bridge_t1")]),
           FakeUpstream.sse_stream([completed_event("resp_bridge_t2")]),
           FakeUpstream.sse_stream([completed_event("resp_bridge_t3")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "bridge-session-#{System.unique_integer([:positive])}"

    first = post_stream(conn, setup, session, stream_payload(setup, "turn one"))
    assert first.status == 200
    assert completed_id(first.resp_body) == "resp_bridge_t1"
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [first_connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert is_reference(first_connection_id)

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"

    assert %{
             "lifecycle_id" => lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(attempt)

    assert settlement_count(request) == 1

    second = post_stream(conn, setup, session, stream_payload(setup, "turn two"))
    assert second.status == 200
    assert completed_id(second.resp_body) == "resp_bridge_t2"
    assert [^first_connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    second_request = latest_request(setup.pool)
    assert second_request.id != request.id
    assert second_request.transport == "http_sse"
    assert [second_attempt] = attempts_for(second_request)
    assert second_attempt.transport == "websocket"

    assert %{
             "lifecycle_id" => ^lifecycle_id,
             "generation" => 1,
             "reused" => true,
             "reconnected" => false
           } = upstream_connection(second_attempt)

    assert settlement_count(second_request) == 1

    third = post_stream(conn, setup, session, stream_payload(setup, "turn three"))
    assert third.status == 200
    assert completed_id(third.resp_body) == "resp_bridge_t3"

    assert [^first_connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    third_request = latest_request(setup.pool)
    assert third_request.id not in [request.id, second_request.id]
    assert third_request.transport == "http_sse"
    assert [third_attempt] = attempts_for(third_request)
    assert third_attempt.transport == "websocket"

    assert %{
             "lifecycle_id" => ^lifecycle_id,
             "generation" => 1,
             "reused" => true,
             "reconnected" => false
           } = upstream_connection(third_attempt)

    assert settlement_count(third_request) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert length(FakeUpstream.requests(upstream)) == 3

    requests = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert length(requests) == 3
    assert Enum.all?(requests, &(&1.status == "succeeded"))
    assert Enum.all?(requests, &(&1.transport == "http_sse"))
  end

  test "bridged turns preserve the downstream SSE", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([created_event("resp_parity"), completed_event("resp_parity")])
      )

    setup = gateway_setup(upstream)
    session = "parity-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "parity turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_parity"
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert event_types(response.resp_body) == ["response.created", "response.completed"]
  end

  test "a bridged attempt records payload compression metadata for the websocket envelope", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_compression")]))
    setup = gateway_setup(upstream)
    enable_request_compression!(setup.pool)
    session = "compression-session-#{System.unique_integer([:positive])}"
    omitted_sentinel = "bridged compression omitted marker"
    original_output = compression_log_fixture(omitted_sentinel)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{"role" => "tool", "tool_call_id" => "call_bridge_tool", "content" => original_output}
      ],
      "stream" => true
    }

    response = post_stream(conn, setup, session, payload)
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_compression"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    # The protected tool output must reach the upstream websocket envelope
    # untouched: the compression pass ran on the envelope that was actually
    # sent, and its decision is what the metadata below has to describe.
    assert [captured] = FakeUpstream.requests(upstream)

    assert [%{"type" => "function_call_output", "call_id" => "call_bridge_tool"} = tool_output] =
             captured.json["input"]

    assert tool_output["output"] == original_output

    request = latest_request(setup.pool)
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true

    # transport "websocket" and the exact byte count of the captured frame tie
    # the recorded compression pass to the websocket envelope, not to the
    # downstream HTTP payload the turn arrived on.
    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "skipped",
             "transport" => "websocket",
             "original_bytes" => original_bytes,
             "compressed_count" => 0
           } = metadata = attempt.response_metadata["payload_compression"]

    assert original_bytes == byte_size(captured.body)

    refute inspect(metadata) =~ omitted_sentinel
    refute inspect(metadata) =~ "call_bridge_tool"
  end

  @tag :v1_websocket_bridge_usage
  test "HTTP SSE over an upstream websocket settles usage before a retained large tail", %{
    conn: conn
  } do
    sentinel = "task-6-known-tail-#{System.unique_integer([:positive])}"
    completed_frame = oversized_completed_frame("resp_bridge_usage_known", sentinel, true)
    completed_event = WebsocketBridgeStream.sse_block(IO.iodata_to_binary(completed_frame))

    assert byte_size(completed_event) > RetainedBody.max_bytes()

    retained_suffix = RetainedBody.append(RetainedBody.empty(), completed_event)
    assert byte_size(retained_suffix) == RetainedBody.max_bytes()
    refute retained_suffix =~ ~s("usage")

    assert ResponseUsage.from_sse(retained_suffix) == %{
             status: "usage_unknown",
             source: "sse_usage_missing"
           }

    upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame]))
    setup = gateway_setup(upstream)

    flex_pricing =
      pricing_snapshot!(setup.model, %{
        config: pricing_config(%{"service_tier" => "flex"}),
        input_token_micros: Decimal.new(25),
        output_token_micros: Decimal.new(50)
      })

    session = "usage-known-session-#{System.unique_integer([:positive])}"

    {{response, telemetry_events}, log} =
      with_log(fn ->
        capture_truncation_telemetry(fn ->
          post_stream(conn, setup, session, stream_payload(setup, "known usage turn"))
        end)
      end)

    assert response.status == 200
    assert response.resp_body =~ sentinel
    assert completed_id(response.resp_body) == "resp_bridge_usage_known"
    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"
    assert upstream_request.path == "/backend-api/codex/responses"

    request = latest_request(setup.pool)

    assert %{
             endpoint: "/backend-api/codex/responses",
             transport: "http_sse",
             status: "succeeded",
             response_status_code: 200,
             usage_status: "usage_known"
           } = request

    assert [attempt] = attempts_for(request)

    assert %{
             transport: "websocket",
             status: "succeeded",
             upstream_status_code: 200,
             usage_status: "usage_known"
           } = attempt

    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"
    assert attempt.response_metadata["bridge_committed"] == true

    assert %{
             "terminal_seen" => true,
             "terminal_kind" => "completed",
             "terminal_status" => "completed",
             "synthetic_terminal_sent" => false
           } = attempt.response_metadata["public_openai_responses_stream"]

    assert [settlement] = settlements_for(request)
    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 16
    assert settlement.cached_input_tokens == nil
    assert settlement.output_tokens == 5
    assert settlement.reasoning_tokens == nil
    assert settlement.total_tokens == 21
    assert settlement.pricing_snapshot_id == flex_pricing.id
    assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(650))
    assert settlement.details["usage_source"] == "upstream_usage"

    assert_stream_finalization_event!(telemetry_events, %{
      usage_status: "usage_known",
      usage_source: "upstream_usage",
      downstream_transport: "http_sse",
      upstream_transport: "websocket"
    })

    assert_bridge_tail_private!(
      setup,
      request,
      attempt,
      settlement,
      telemetry_events,
      log,
      sentinel
    )
  end

  @tag :v1_websocket_bridge_usage
  test "HTTP SSE over an upstream websocket keeps omitted large-tail usage unknown", %{
    conn: conn
  } do
    sentinel = "task-6-omitted-tail-#{System.unique_integer([:positive])}"
    completed_frame = oversized_completed_frame("resp_bridge_usage_missing", sentinel, false)
    completed_event = WebsocketBridgeStream.sse_block(IO.iodata_to_binary(completed_frame))

    assert byte_size(completed_event) > RetainedBody.max_bytes()
    assert ResponseUsage.from_sse(completed_event).source == "sse_usage_missing"

    upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame]))
    setup = gateway_setup(upstream)
    session = "usage-missing-session-#{System.unique_integer([:positive])}"

    {{response, telemetry_events}, log} =
      with_log(fn ->
        capture_truncation_telemetry(fn ->
          post_stream(conn, setup, session, stream_payload(setup, "missing usage turn"))
        end)
      end)

    assert response.status == 200
    assert response.resp_body =~ sentinel
    assert completed_id(response.resp_body) == "resp_bridge_usage_missing"
    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"
    assert upstream_request.path == "/backend-api/codex/responses"

    request = latest_request(setup.pool)

    assert %{
             endpoint: "/backend-api/codex/responses",
             transport: "http_sse",
             status: "succeeded",
             response_status_code: 200,
             usage_status: "usage_unknown"
           } = request

    assert [attempt] = attempts_for(request)

    assert %{
             transport: "websocket",
             status: "succeeded",
             upstream_status_code: 200,
             usage_status: "usage_unknown"
           } = attempt

    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"
    assert attempt.response_metadata["bridge_committed"] == true

    assert %{
             "terminal_seen" => true,
             "terminal_kind" => "completed",
             "terminal_status" => "completed",
             "synthetic_terminal_sent" => false
           } = attempt.response_metadata["public_openai_responses_stream"]

    assert [settlement] = settlements_for(request)
    assert settlement.usage_status == "usage_unknown"
    assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(0))
    assert settlement.details["usage_source"] == "sse_usage_missing"
    assert settlement.details["estimated_from_reserve"] == true

    assert_stream_finalization_event!(telemetry_events, %{
      usage_status: "usage_unknown",
      usage_source: "unknown",
      downstream_transport: "http_sse",
      upstream_transport: "websocket"
    })

    assert_bridge_tail_private!(
      setup,
      request,
      attempt,
      settlement,
      telemetry_events,
      log,
      sentinel
    )
  end

  test "a bridged multi-event stream delivers every event, not just the terminal", %{conn: conn} do
    # Guards the preflight against reordering the first event behind the
    # terminal marker: the non-terminal response.created must survive.
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([created_event("resp_multi"), completed_event("resp_multi")])
      )

    setup = gateway_setup(upstream)
    session = "multi-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "multi turn"))

    assert response.status == 200
    assert event_types(response.resp_body) == ["response.created", "response.completed"]
    assert FakeUpstream.websocket_connection_count(upstream) == 1
  end

  test "falls back to HTTP on the same attempt when the websocket bridge cannot start", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "bad_gateway"}},
             status: 502
           ),
           FakeUpstream.sse_stream([completed_event("resp_fallback_t1")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "fallback-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "fallback turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_fallback_t1"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    assert_no_upstream_websocket_metadata(attempt)
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert FakeUpstream.websocket_connection_ids(upstream) == []
    assert FakeUpstream.http_request_count(upstream) == 1
    assert length(FakeUpstream.requests(upstream)) == 1
    assert settlement_count(request) == 1
  end

  @tag :rollout_drain_t3
  test "T3 marker makes the websocket bridge fall back to plain HTTP", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_marker_fallback")]))
    setup = gateway_setup(upstream)
    session = "marker-fallback-#{System.unique_integer([:positive])}"
    _marker_path = WebsocketRolloutDrainSupport.configure_drain_marker!()

    response = post_stream(conn, setup, session, stream_payload(setup, "marker fallback"))

    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_marker_fallback"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    assert_no_upstream_websocket_metadata(attempt)
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert FakeUpstream.http_request_count(upstream) == 1
    assert settlement_count(request) == 1
  end

  test "uses the websocket bridge without a Pool toggle", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_off_t1")]))
    setup = gateway_setup(upstream)
    session = "off-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "off turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_off_t1"
    assert FakeUpstream.websocket_connection_count(upstream) == 1
  end

  test "a bridged stream dying after visible output finalizes as a failed request", %{conn: conn} do
    created_event =
      {"response.created",
       %{"type" => "response.created", "response" => %{"id" => "resp_dead_t1"}}}

    visible_event =
      {"response.output_text.delta",
       %{
         "type" => "response.output_text.delta",
         "response_id" => "resp_dead_t1",
         "output_index" => 0,
         "content_index" => 0,
         "delta" => "visible output"
       }}

    upstream =
      start_upstream(FakeUpstream.websocket_sse_then_close([created_event, visible_event]))

    setup = gateway_setup(upstream)
    session = "dead-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "dead turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == nil

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true

    assert %{
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(attempt)

    assert settlement_count(request) == 1
  end

  @tag :owner_drained_terminal_state
  test "a post-budget owner drain emits the public owner_drained terminal", %{conn: conn} do
    release_ref = make_ref()

    visible_event =
      {"response.output_text.delta",
       %{
         "type" => "response.output_text.delta",
         "response_id" => "resp_owner_drained",
         "output_index" => 0,
         "content_index" => 0,
         "delta" => "visible before rollout drain"
       }}

    upstream =
      start_upstream(
        FakeUpstream.delayed_terminal_sse_stream(
          [created_event("resp_owner_drained"), visible_event],
          completed_event("resp_owner_drained"),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    session = "owner-drained-session-#{System.unique_integer([:positive])}"
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        post_stream(conn, setup, session, stream_payload(setup, "owner drain turn"))
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   1_000

    assert %CodexTurn{first_visible_output_at: %DateTime{}} =
             turn =
             await_visible_turn(setup.pool.id)

    harness = start_rollout_drain_harness()
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, 10}
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)

    response = Task.await(request_task, 2_000)
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 2_000)

    assert response.status == 200

    assert event_types(response.resp_body) == [
             "response.created",
             "response.output_text.delta",
             "response.failed"
           ]

    assert response.resp_body =~ "visible before rollout drain"

    assert %{
             "type" => "response.failed",
             "error" => %{
               "code" => "owner_drained",
               "message" => "websocket owner is draining"
             },
             "response" => %{
               "id" => "resp_owner_drained",
               "status" => "failed",
               "error" => %{
                 "code" => "owner_drained",
                 "message" => "websocket owner is draining"
               }
             }
           } = response_failed_data(response.resp_body)

    refute response.resp_body =~ "upstream_stream_error"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert request.response_status_code == 499
    assert request.last_error_code == "owner_drained"

    assert [attempt] = attempts_for(request)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.network_error_code == "owner_drained"

    assert %CodexTurn{
             status: "interrupted",
             error_code: "owner_drained",
             first_visible_output_at: %DateTime{}
           } = Repo.reload!(turn)

    assert settlement_count(request) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
  end

  # Deliberately reversed by the bridged-pre-content-retry work: a peer close
  # before any client-rendered content now keeps the pre-commit HTTP fallback
  # instead of surfacing a fatal synthetic (locally-declared timeouts still
  # pin the fatal contract below).
  test "an internal-only event followed by websocket death falls back to plain HTTP", %{
    conn: conn
  } do
    rate_limits_event =
      {"codex.rate_limits",
       %{
         "type" => "codex.rate_limits",
         "rate_limits" => %{"primary" => %{"used_percent" => 12.5}}
       }}

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close([rate_limits_event]),
           FakeUpstream.sse_stream([completed_event("resp_previsible_t1")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "previsible-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "previsible turn"))

    assert [websocket_request | _rest] = FakeUpstream.requests(upstream)
    assert websocket_request.method == "WEBSOCKET"
    assert websocket_request.path == "/backend-api/codex/responses"

    assert_precontent_fallback_success(response, upstream, setup, "resp_previsible_t1")
  end

  test "a failed transparent reconnect persists only a scrubbed HTTP fallback failure", %{
    conn: conn
  } do
    close_reason = "synthetic websocket close reason"
    upgrade_reason = "synthetic reconnect upgrade reason"

    failed_terminal =
      {"response.failed",
       %{
         "type" => "response.failed",
         "error" => %{
           "type" => "server_error",
           "code" => "internal_error",
           "message" => "synthetic fallback failure"
         },
         "response" => %{
           "id" => "resp_failed_reconnect_fallback",
           "status" => "failed"
         }
       }}

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([completed_event("resp_reconnect_initial")]),
           FakeUpstream.websocket_sse_then_close([], reason: close_reason),
           FakeUpstream.websocket_upgrade_error(
             %{
               "error" => %{
                 "code" => "reconnect_rejected",
                 "message" => upgrade_reason
               }
             },
             status: 503
           ),
           FakeUpstream.sse_stream([failed_terminal])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "failed-reconnect-session-#{System.unique_integer([:positive])}"

    initial = post_stream(conn, setup, session, stream_payload(setup, "initial turn"))
    assert initial.status == 200
    assert completed_id(initial.resp_body) == "resp_reconnect_initial"

    initial_request = latest_request(setup.pool)
    assert initial_request.status == "succeeded"
    assert [initial_attempt] = attempts_for(initial_request)
    assert initial_attempt.transport == "websocket"

    assert %{
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(initial_attempt)

    assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert is_reference(connection_id)

    response = post_stream(conn, setup, session, stream_payload(setup, "failed reconnect"))
    assert response.status == 200
    assert event_types(response.resp_body) == ["response.failed"]
    refute response.resp_body =~ close_reason
    refute response.resp_body =~ upgrade_reason
    refute response.resp_body =~ "synthetic fallback failure"

    request = latest_request(setup.pool)

    assert %{
             status: "failed",
             transport: "http_sse",
             response_status_code: 200,
             last_error_code: "internal_error"
           } = request

    assert [attempt] = attempts_for(request)

    assert %{
             status: "failed",
             transport: "http_sse",
             upstream_status_code: 200,
             network_error_code: "internal_error",
             error_message: "upstream stream returned terminal event internal_error"
           } = attempt

    assert_no_upstream_websocket_metadata(attempt)
    assert byte_size(attempt.error_message) <= 256
    refute inspect(request) =~ close_reason
    refute inspect(request) =~ upgrade_reason
    refute inspect(attempt) =~ close_reason
    refute inspect(attempt) =~ upgrade_reason
    refute attempt.response_metadata["upstream_websocket_bridge"]
    refute attempt.response_metadata["upstream_transport"]
    refute Map.has_key?(attempt.response_metadata, "upstream_websocket_connection")

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [^connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert length(FakeUpstream.requests(upstream)) == 3
    assert settlement_count(request) == 1
  end

  # Deliberately reversed by the bridged-pre-content-retry work: a peer close
  # with zero delivered frames is a pre-content peer-close death and falls
  # back to plain HTTP on the same attempt.
  test "a websocket close before any frame falls back to plain HTTP", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close([]),
           FakeUpstream.sse_stream([completed_event("resp_complete_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "completion-fallback-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "completion fallback"))

    assert [websocket_request | _rest] = FakeUpstream.requests(upstream)
    assert websocket_request.method == "WEBSOCKET"

    assert_precontent_fallback_success(response, upstream, setup, "resp_complete_fallback")
  end

  @tag :task_9b_codex_buffering
  test "buffers codex rate limits until websocket commit and preserves compact accounting", %{
    conn: conn
  } do
    reset_at = ~U[2030-01-01 00:00:00Z]

    rate_limits_event = %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => 12.5,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }

    compact_completed =
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_codex_buffered",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "buffered answer"}]
             }
           ],
           "usage" => %{"input_tokens" => 12, "output_tokens" => 5, "total_tokens" => 17}
         }
       }}

    created = created_event("resp_codex_buffered")

    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          Jason.encode!(rate_limits_event),
          Jason.encode!(elem(created, 1)),
          Jason.encode!(elem(compact_completed, 1))
        ])
      )

    setup = gateway_setup(upstream)
    session = "codex-buffered-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "codex buffering"))

    assert response.status == 200

    assert event_types(response.resp_body) == [
             "response.created",
             "response.output_text.delta",
             "response.completed"
           ]

    assert response.resp_body =~ "buffered answer"
    refute response.resp_body =~ "codex.rate_limits"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert request.usage_status == "usage_known"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"

    assert %{
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(attempt)

    assert window = await_rate_limit_window(setup.identity)
    assert window.source == "codex_rate_limit_event"
    assert window.window_kind == "primary"
    assert window.window_minutes == 300
    assert Decimal.equal?(window.used_percent, Decimal.new("12.5"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq

    settlement =
      Repo.get_by!(LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.request_id == request.id
    assert settlement.attempt_id == attempt.id
    assert settlement.transport == "http_sse"
    assert settlement.usage_status == "usage_known"
    assert settlement.details["usage_source"] == "upstream_usage"
    assert settlement_count(request) == 1
  end

  test "a websocket bridge preflight timeout before public data fails without HTTP replay",
       %{conn: conn} do
    set_upstream_receive_timeout!(25)

    internal_event =
      Jason.encode!(%{
        "type" => "codex.rate_limits",
        "rate_limits" => %{"primary" => %{"used_percent" => 12.5}}
      })

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_text_frames([internal_event]),
           FakeUpstream.sse_stream([completed_event("resp_timeout_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "timeout-fallback-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "timeout fallback"))
    assert response.status == 200
    assert event_types(response.resp_body) == ["response.failed"]
    refute response.resp_body =~ "resp_timeout_fallback"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true

    assert [websocket_request] = FakeUpstream.requests(upstream)
    assert websocket_request.method == "WEBSOCKET"
    assert FakeUpstream.http_request_count(upstream) == 0
    assert settlement_count(request) == 1
  end

  test "a failure-coded incomplete websocket terminal is preserved without HTTP replay", %{
    conn: conn
  } do
    failed_incomplete =
      {"response.incomplete",
       %{
         "type" => "response.incomplete",
         "response" => %{
           "id" => "resp_failed_incomplete",
           "status" => "incomplete",
           "incomplete_details" => %{"reason" => "context_length_exceeded"}
         }
       }}

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([failed_incomplete]),
           FakeUpstream.sse_stream([completed_event("resp_incomplete_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "incomplete-fallback-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "fallback incomplete"))

    assert response.status == 200
    assert event_types(response.resp_body) == ["response.failed"]
    assert response.resp_body =~ "resp_failed_incomplete"
    refute response.resp_body =~ "resp_incomplete_fallback"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert [websocket_request] = FakeUpstream.requests(upstream)
    assert websocket_request.method == "WEBSOCKET"
    assert FakeUpstream.http_request_count(upstream) == 0
    assert settlement_count(request) == 1
  end

  test "a compact completed-only turn bridges with the synthesized visible prefix", %{conn: conn} do
    # Compact shape: the whole turn arrives as one response.completed event
    # carrying the output text. The bridge must commit on the terminal (it is
    # downstream-visible) and the public normalization synthesizes the
    # created/delta prefix exactly as it does for HTTP dispatch.
    compact_completed =
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_compact_t1",
           "usage" => %{"input_tokens" => 12, "output_tokens" => 5, "total_tokens" => 17},
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "compact answer"}]
             }
           ]
         }
       }}

    upstream = start_upstream(FakeUpstream.sse_stream([compact_completed]))
    setup = gateway_setup(upstream)
    session = "compact-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "compact turn"))

    assert response.status == 200

    assert event_types(response.resp_body) ==
             ["response.created", "response.output_text.delta", "response.completed"]

    assert completed_id(response.resp_body) == "resp_compact_t1"
    assert response.resp_body =~ "compact answer"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert %{"generation" => 1} = upstream_connection(attempt)
    assert settlement_count(request) == 1
  end

  test "a downstream disconnect during a bridged turn finalizes as client_disconnected and frees the owner",
       %{conn: _conn} do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([
             created_event("resp_disconnect_t1"),
             completed_event("resp_disconnect_t1")
           ]),
           FakeUpstream.sse_stream([completed_event("resp_disconnect_t2")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "disconnect-session-#{System.unique_integer([:positive])}"

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, %{endpoint: endpoint, payload: payload, request_options: request_options}} =
      ResponsesCompat.coerce(stream_payload(setup, "disconnect turn"), %{
        session_header: session,
        session_header_source: "x-session-id",
        upstream_endpoint: "/backend-api/codex/responses",
        public_openai_responses_stream: true
      })

    assert {:ok, %{stream: stream}} =
             RuntimeGateway.execute(auth, endpoint, payload, request_options)

    # The client goes away before the first chunk can be written downstream.
    closed_conn = %{
      Phoenix.ConnTest.build_conn()
      | adapter: {ClosedChunkAdapter, nil},
        state: :chunked
    }

    assert {:ok, _conn} = stream.(closed_conn)
    assert [disconnect_connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert is_reference(disconnect_connection_id)

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.network_error_code == "client_disconnected"

    assert %{
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(attempt)

    assert settlement_count(request) == 1

    # The owner session must not stay wedged on the interrupted turn: the next
    # turn on the same session bridges again over the SAME upstream websocket.
    second =
      Phoenix.ConnTest.build_conn()
      |> auth(setup)
      |> put_req_header("x-session-id", session)
      |> post("/v1/responses", stream_payload(setup, "disconnect follow-up"))

    assert second.status == 200
    assert completed_id(second.resp_body) == "resp_disconnect_t2"
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [^disconnect_connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    second_request = latest_request(setup.pool)
    assert second_request.id != request.id
    assert second_request.status == "succeeded"
    assert [second_attempt] = attempts_for(second_request)
    assert second_attempt.transport == "websocket"

    assert %{
             "lifecycle_id" => lifecycle_id,
             "generation" => 1,
             "reused" => true,
             "reconnected" => false
           } = upstream_connection(second_attempt)

    assert is_binary(lifecycle_id)
    assert settlement_count(second_request) == 1
  end

  # ── Pre-content retry family (bridged-pre-content-retry plan) ──
  #
  # A bridged turn whose upstream channel is killed by the peer before any
  # client-rendered content falls back to plain HTTP on the same attempt;
  # content commits the bridge; locally-declared timeouts stay fatal.

  defp output_item_added_event(response_id, item_type) do
    {"response.output_item.added",
     %{
       "type" => "response.output_item.added",
       "response_id" => response_id,
       "output_index" => 0,
       "item" => %{"type" => item_type, "id" => "item_#{item_type}"}
     }}
  end

  defp content_part_added_event(response_id) do
    {"response.content_part.added",
     %{
       "type" => "response.content_part.added",
       "response_id" => response_id,
       "output_index" => 0,
       "content_index" => 0,
       "part" => %{"type" => "output_text", "text" => ""}
     }}
  end

  defp codex_marker_event do
    {"codex.event_marker", %{"type" => "codex.event_marker", "detail" => %{"count" => 1}}}
  end

  defp assert_precontent_fallback_success(response, upstream, setup, fallback_id) do
    assert response.status == 200
    assert completed_id(response.resp_body) == fallback_id
    refute "response.failed" in event_types(response.resp_body)

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    assert_no_upstream_websocket_metadata(attempt)
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 1
    assert settlement_count(request) == 1
  end

  test "envelope frames followed by a peer close fall back to plain HTTP", %{conn: conn} do
    events = [
      created_event("resp_precontent_ws"),
      output_item_added_event("resp_precontent_ws", "reasoning"),
      codex_marker_event()
    ]

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close(events),
           FakeUpstream.sse_stream([completed_event("resp_precontent_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "precontent-close-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "precontent close turn"))

    assert_precontent_fallback_success(response, upstream, setup, "resp_precontent_fallback")
  end

  test "multi-item envelopes without content still fall back on a peer close", %{conn: conn} do
    events = [
      created_event("resp_multi_item_ws"),
      output_item_added_event("resp_multi_item_ws", "reasoning"),
      output_item_added_event("resp_multi_item_ws", "message"),
      content_part_added_event("resp_multi_item_ws")
    ]

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close(events),
           FakeUpstream.sse_stream([completed_event("resp_multi_item_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "precontent-multi-item-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "multi item turn"))

    assert_precontent_fallback_success(response, upstream, setup, "resp_multi_item_fallback")
  end

  test "a reasoning summary delta commits the bridge so a later close stays fatal", %{conn: conn} do
    events = [
      created_event("resp_reasoning_commit"),
      output_item_added_event("resp_reasoning_commit", "reasoning"),
      {"response.reasoning_summary_text.delta",
       %{
         "type" => "response.reasoning_summary_text.delta",
         "response_id" => "resp_reasoning_commit",
         "output_index" => 0,
         "summary_index" => 0,
         "delta" => "thinking out loud"
       }}
    ]

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close(events),
           FakeUpstream.sse_stream([completed_event("resp_reasoning_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "reasoning-commit-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "reasoning commit turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == nil
    refute response.resp_body =~ "resp_reasoning_fallback"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert FakeUpstream.http_request_count(upstream) == 0
    assert settlement_count(request) == 1
  end

  test "an unknown event type commits the bridge so a later close stays fatal", %{conn: conn} do
    events = [
      created_event("resp_unknown_commit"),
      {"response.entirely_new_event",
       %{"type" => "response.entirely_new_event", "response_id" => "resp_unknown_commit"}}
    ]

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close(events),
           FakeUpstream.sse_stream([completed_event("resp_unknown_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "unknown-commit-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "unknown commit turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == nil
    refute response.resp_body =~ "resp_unknown_fallback"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "websocket"
    assert FakeUpstream.http_request_count(upstream) == 0
    assert settlement_count(request) == 1
  end

  test "pre-content buffer overflow commits so a later close stays fatal", %{conn: conn} do
    markers = List.duplicate(codex_marker_event(), 65)

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_sse_then_close([created_event("resp_overflow_ws") | markers]),
           FakeUpstream.sse_stream([completed_event("resp_overflow_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "precontent-overflow-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "overflow turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == nil
    refute response.resp_body =~ "resp_overflow_fallback"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "websocket"
    assert FakeUpstream.http_request_count(upstream) == 0
    assert settlement_count(request) == 1
  end

  @tag :rollout_drain_precontent_fallback
  test "a pre-content drain cut falls back to plain HTTP instead of owner_drained", %{conn: conn} do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_close_without_terminal_barrier(
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.sse_stream([completed_event("resp_drain_precontent_fallback")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "drain-precontent-#{System.unique_integer([:positive])}"
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        post_stream(conn, setup, session, stream_payload(setup, "drain precontent turn"))
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, barrier_pid, ^release_ref},
                   1_000

    harness = start_rollout_drain_harness()
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, 10}
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)

    response = Task.await(request_task, 2_000)
    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})
    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 2_000)

    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_drain_precontent_fallback"
    refute response.resp_body =~ "owner_drained"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    assert FakeUpstream.http_request_count(upstream) == 1
    assert settlement_count(request) == 1
  end

  defp compression_log_fixture(omitted_sentinel) do
    middle =
      1..96
      |> Enum.map(fn
        48 -> "ordinary build line 48 #{omitted_sentinel}"
        index -> "ordinary build line #{index}"
      end)

    [
      "command started",
      "context before first",
      "error: first failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final failure",
      "context after final"
    ])
    |> Enum.join("\n")
  end

  defp oversized_completed_frame(response_id, sentinel, include_usage?) do
    usage =
      if include_usage? do
        ~s(,"service_tier":"flex","usage":{"input_tokens":16,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"reasoning_tokens":0,"total_tokens":21})
      else
        ""
      end

    [
      ~s({"type":"response.completed","response":{"id":"#{response_id}","status":"completed"),
      usage,
      ~s(,"output":[{"type":"message","content":[{"type":"output_text","text":"),
      sentinel,
      String.duplicate("x", RetainedBody.max_bytes() + 1_024),
      ~s("}]}]}})
    ]
  end

  defp capture_truncation_telemetry(fun) do
    parent = self()
    handler_id = "v1-websocket-bridge-usage-#{System.unique_integer([:positive])}"

    events = [
      [:codex_pooler, :gateway, :stream_buffer, :truncated],
      [:codex_pooler, :gateway, :stream, :finalization]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(parent, {handler_id, event, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_telemetry_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_telemetry_events(handler_id, events) do
    receive do
      {^handler_id, event, measurements, metadata} ->
        drain_telemetry_events(handler_id, [{event, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp assert_stream_finalization_event!(telemetry_events, expected_metadata) do
    assert [
             {[:codex_pooler, :gateway, :stream, :finalization], %{count: 1}, ^expected_metadata}
           ] =
             Enum.filter(
               telemetry_events,
               &match?({[:codex_pooler, :gateway, :stream, :finalization], _, _}, &1)
             )
  end

  defp assert_bridge_tail_private!(
         setup,
         request,
         attempt,
         settlement,
         telemetry_events,
         log,
         sentinel
       ) do
    assert telemetry_events != []

    persisted =
      inspect({
        request.request_metadata,
        attempt.response_metadata,
        settlement.details,
        RequestLogs.list(setup.pool, filters: %{request_id: request.id})
      })

    refute persisted =~ sentinel
    refute log =~ sentinel
    refute inspect(telemetry_events) =~ sentinel
  end
end
