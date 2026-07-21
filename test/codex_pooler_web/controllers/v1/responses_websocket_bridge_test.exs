defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeTest do
  use CodexPoolerWeb.ConnCase, async: false

  defmodule ClosedChunkAdapter do
    def chunk(_payload, _chunk), do: {:error, :closed}
  end

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      start_upstream: 1
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.OpenAICompatibility.Responses, as: ResponsesCompat
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
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

  defp await_upstream_requests(upstream, expected_count, attempts \\ 100)

  defp await_upstream_requests(upstream, expected_count, attempts) when attempts > 0 do
    requests = FakeUpstream.requests(upstream)

    if length(requests) == expected_count do
      requests
    else
      yield_once({:await_upstream_requests, expected_count, attempts})
      await_upstream_requests(upstream, expected_count, attempts - 1)
    end
  end

  defp await_upstream_requests(upstream, _expected_count, 0),
    do: FakeUpstream.requests(upstream)

  defp yield_once(message) do
    send(self(), message)

    receive do
      ^message -> :ok
    end
  end

  defp settlement_count(request) do
    Repo.aggregate(
      from(l in LedgerEntry,
        where: l.request_id == ^request.id and l.entry_kind == "settlement"
      ),
      :count
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

  test "bridges sessioned turns through reuse and transparent reconnect metadata", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([completed_event("resp_bridge_t1")]),
           FakeUpstream.sse_stream([completed_event("resp_bridge_t2")]),
           FakeUpstream.websocket_sse_then_close([]),
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

    assert [^first_connection_id, second_connection_id] =
             FakeUpstream.websocket_connection_ids(upstream)

    assert is_reference(second_connection_id)
    refute second_connection_id == first_connection_id

    third_request = latest_request(setup.pool)
    assert third_request.id not in [request.id, second_request.id]
    assert third_request.transport == "http_sse"
    assert [third_attempt] = attempts_for(third_request)
    assert third_attempt.transport == "websocket"

    assert %{
             "lifecycle_id" => ^lifecycle_id,
             "generation" => 2,
             "reused" => false,
             "reconnected" => true
           } = upstream_connection(third_attempt)

    assert settlement_count(third_request) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 2
    assert length(FakeUpstream.requests(upstream)) == 4

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
    assert length(FakeUpstream.requests(upstream)) == 1
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

  test "an internal-only event followed by websocket death falls back to HTTP pre-visible", %{
    conn: conn
  } do
    # The only frame before the websocket dies is a codex.* event the public
    # normalization filters out: nothing became visible downstream, so the
    # turn must retry over HTTP on the same attempt with a single settlement
    # instead of committing to the doomed websocket stream.
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
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_previsible_t1"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    assert_no_upstream_websocket_metadata(attempt)
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert is_reference(connection_id)

    assert [websocket_request, http_fallback_request] = await_upstream_requests(upstream, 2)
    assert websocket_request.method == "WEBSOCKET"
    assert websocket_request.path == "/backend-api/codex/responses"
    assert http_fallback_request.method == "POST"
    assert http_fallback_request.path == "/backend-api/codex/responses"

    assert settlement_count(request) == 1
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

  test "a websocket bridge completion before public data falls back on the same attempt", %{
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
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_complete_fallback"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    refute Map.has_key?(attempt.response_metadata, "upstream_websocket_bridge")
    refute Map.has_key?(attempt.response_metadata, "upstream_transport")
    refute Map.has_key?(attempt.response_metadata, "upstream_websocket_connection")
    assert settlement_count(request) == 1
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

  test "a websocket bridge preflight timeout before public data falls back on the same attempt",
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
    assert completed_id(response.resp_body) == "resp_timeout_fallback"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    refute Map.has_key?(attempt.response_metadata, "upstream_websocket_bridge")
    refute Map.has_key?(attempt.response_metadata, "upstream_transport")
    refute Map.has_key?(attempt.response_metadata, "upstream_websocket_connection")
    assert settlement_count(request) == 1
  end

  test "a failure-coded incomplete websocket terminal falls back to HTTP pre-visible", %{
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
    assert completed_id(response.resp_body) == "resp_incomplete_fallback"
    refute response.resp_body =~ "resp_failed_incomplete"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "http_sse"
    refute attempt.response_metadata["upstream_websocket_bridge"]
    refute attempt.response_metadata["upstream_websocket_connection"]
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
end
