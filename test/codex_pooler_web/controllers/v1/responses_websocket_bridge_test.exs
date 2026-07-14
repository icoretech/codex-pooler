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
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo

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

  defp enable_bridge!(pool) do
    pool
    |> PoolRouting.ensure_routing_settings()
    |> Ecto.Changeset.change(upstream_websocket_bridge_enabled: true)
    |> Repo.update!()
  end

  defp enable_request_compression!(pool) do
    pool
    |> PoolRouting.ensure_routing_settings()
    |> Ecto.Changeset.change(request_compression_enabled: true)
    |> Repo.update!()
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

  defp settled_count(request) do
    Repo.aggregate(
      from(l in LedgerEntry,
        where:
          l.request_id == ^request.id and l.entry_kind == "settlement" and
            l.usage_status == "usage_known"
      ),
      :count
    )
  end

  test "bridges sessioned public streaming turns over one reused upstream websocket", %{
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
    enable_bridge!(setup.pool)
    session = "bridge-session-#{System.unique_integer([:positive])}"

    first = post_stream(conn, setup, session, stream_payload(setup, "turn one"))
    assert first.status == 200
    assert completed_id(first.resp_body) == "resp_bridge_t1"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"
    assert settled_count(request) == 1

    second = post_stream(conn, setup, session, stream_payload(setup, "turn two"))
    assert second.status == 200
    assert completed_id(second.resp_body) == "resp_bridge_t2"

    third = post_stream(conn, setup, session, stream_payload(setup, "turn three"))
    assert third.status == 200
    assert completed_id(third.resp_body) == "resp_bridge_t3"

    # The whole point of the bridge: follow-up turns reuse the SAME upstream
    # websocket connection instead of dispatching per-request over HTTP.
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    requests = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert length(requests) == 3
    assert Enum.all?(requests, &(&1.status == "succeeded"))
  end

  test "bridged turns produce the same downstream SSE as HTTP dispatch", %{conn: conn} do
    events = fn -> [created_event("resp_parity"), completed_event("resp_parity")] end

    bodies =
      for bridge? <- [false, true] do
        upstream = start_upstream(FakeUpstream.sse_stream(events.()))
        setup = gateway_setup(upstream)
        if bridge?, do: enable_bridge!(setup.pool)
        session = "parity-session-#{System.unique_integer([:positive])}"

        response = post_stream(conn, setup, session, stream_payload(setup, "parity turn"))
        assert response.status == 200
        assert completed_id(response.resp_body) == "resp_parity"

        expected_ws_connections = if bridge?, do: 1, else: 0
        assert FakeUpstream.websocket_connection_count(upstream) == expected_ws_connections

        response.resp_body
      end

    assert [http_body, bridged_body] = bodies
    assert bridged_body == http_body
  end

  test "a bridged attempt records payload compression metadata for the websocket envelope", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_compression")]))
    setup = gateway_setup(upstream)
    enable_bridge!(setup.pool)
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
    enable_bridge!(setup.pool)
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
    enable_bridge!(setup.pool)
    session = "fallback-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "fallback turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_fallback_t1"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "http_sse"
    refute attempt.response_metadata["upstream_websocket_bridge"]
    assert settled_count(request) == 1
  end

  test "keeps HTTP dispatch when the pool toggle is off", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_off_t1")]))
    setup = gateway_setup(upstream)
    session = "off-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "off turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_off_t1"
    assert FakeUpstream.websocket_connection_count(upstream) == 0
  end

  test "a bridged stream dying after visible output finalizes as a failed request", %{conn: conn} do
    created_event =
      {"response.created",
       %{"type" => "response.created", "response" => %{"id" => "resp_dead_t1"}}}

    upstream = start_upstream(FakeUpstream.websocket_sse_then_close([created_event]))
    setup = gateway_setup(upstream)
    enable_bridge!(setup.pool)
    session = "dead-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "dead turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == nil

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert length(attempts_for(request)) == 1
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
    enable_bridge!(setup.pool)
    session = "previsible-session-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "previsible turn"))
    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_previsible_t1"

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    refute attempt.response_metadata["upstream_websocket_bridge"]
    assert settled_count(request) == 1
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
    enable_bridge!(setup.pool)
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
    assert settled_count(request) == 1
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
    enable_bridge!(setup.pool)
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

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert [attempt] = attempts_for(request)
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.network_error_code == "client_disconnected"

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

    second_request = latest_request(setup.pool)
    assert second_request.id != request.id
    assert second_request.status == "succeeded"
    assert [second_attempt] = attempts_for(second_request)
    assert second_attempt.transport == "websocket"
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
