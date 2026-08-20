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
      gateway_setup: 2,
      native_text_input: 1,
      pricing_config: 1,
      pricing_snapshot!: 2,
      public_websocket_connect!: 4,
      public_websocket_send_text!: 4,
      start_public_endpoint_with_server!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.OpenAICompatibility.Responses, as: ResponsesCompat
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Transports.Streaming.{RetainedBody, WebsocketBridgeStream}
  alias CodexPooler.Gateway.Transports.Websocket.{RolloutDrain, WebsocketOwnerContract}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPoolerWeb.CodexResponsesSocket

  @api_key_revocation_close {:close, 1008, "api key is no longer active"}
  @websocket_frame_timeout 5_000
  @websocket_transport_barrier_payload "public-v1-api-key-barrier"

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

  defp completed_event(id, output \\ []) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => id,
         "output" => output,
         "usage" => %{"input_tokens" => 12, "output_tokens" => 5, "total_tokens" => 17}
       }
     }}
  end

  defp created_event(id) do
    {"response.created",
     %{"type" => "response.created", "response" => %{"id" => id, "status" => "in_progress"}}}
  end

  defp event_types(body) do
    Enum.map(event_payloads(body), & &1["type"])
  end

  defp event_payloads(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      with [_line, data] <- Regex.run(~r/^data: (.+)$/m, block),
           {:ok, %{"type" => _type} = decoded} <- Jason.decode(data) do
        [decoded]
      else
        _no_event -> []
      end
    end)
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
      with ["error"] <- Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first),
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
           } = connection = upstream_connection(attempt)

    assert Map.take(
             attempt.response_metadata,
             ~w(upstream_transport upstream_websocket_bridge upstream_websocket_connection)
           ) == %{
             "upstream_transport" => "websocket",
             "upstream_websocket_bridge" => true,
             "upstream_websocket_connection" => connection
           }

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

  test "public websocket drains one admitted turn then drops queued work and closes without a synthetic error" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [completed_event("resp_public_api_key_drain")],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    scope = api_key_owner_scope(setup)
    {server, port} = start_public_endpoint_with_server!()

    {conn, websocket, ref} =
      public_websocket_connect!(port, setup, "", "/v1/responses")

    stream_id = "public-api-key-drain"

    first_payload =
      public_websocket_payload(setup, "admitted public turn", %{"stream_id" => stream_id})

    queued_payload = public_websocket_payload(setup, "queued public turn")

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, first_payload)
      assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref}, 1_000

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, queued_payload)
      {conn, websocket} = public_websocket_transport_barrier!(conn, websocket, ref)
      assert_public_websocket_queue_length!(server, 1)

      assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
      assert paused_key.runtime_revocation_epoch == setup.api_key.runtime_revocation_epoch + 1

      assert_public_websocket_queue_length!(server, 0)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

      {_conn, _websocket, frames} =
        receive_public_websocket_frames_until_close!(conn, websocket, ref)

      assert List.last(frames) == @api_key_revocation_close

      public_frames =
        for {:text, frame} <- frames,
            decoded = Jason.decode!(frame),
            decoded["type"] != "codex.response.metadata",
            do: decoded

      assert Enum.count(public_frames, &(&1["type"] == "response.completed")) == 1
      assert Enum.all?(public_frames, &(&1["stream_id"] == stream_id))
      refute Enum.any?(public_frames, &(&1["type"] in ["response.failed", "error"]))
      assert FakeUpstream.count(upstream) == 1

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1
    after
      Mint.HTTP.close(conn)
    end
  end

  test "an idle public websocket closes with 1008 only after its API key is paused" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)
    scope = api_key_owner_scope(setup)
    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "", "/v1/responses")

    try do
      assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
      assert paused_key.status == "paused"

      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          public_websocket_payload(setup, "post-pause public turn")
        )

      {_conn, _websocket, frames} =
        receive_public_websocket_frames_until_close!(conn, websocket, ref)

      assert frames == [@api_key_revocation_close]
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    after
      Mint.HTTP.close(conn)
    end
  end

  test "owner-forwarded generic errors echo the accepted public stream id" do
    task_pid = self()
    state = owner_forwarded_public_state(task_pid, "lane-owner-error")

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:owner_unavailable, nil)

    owner_frame =
      {:websocket_owner_frame, "corr-owner-error", 7, task_pid,
       {:error, :owner_unavailable, safe_payload}}

    assert {:push, {:text, payload}, ^state} =
             CodexResponsesSocket.handle_info(owner_frame, state)

    assert Jason.decode!(payload)["stream_id"] == "lane-owner-error"
    refute Map.has_key?(safe_payload, "stream_id")
    refute Map.has_key?(state.websocket_owner_downstream, :stream_id)
    assert tuple_size(owner_frame) == 5
  end

  test "direct and owner-forwarded normal and terminal frames share stream attribution without owner lane state" do
    task_pid = self()
    stream_id = "lane-owner-parity"
    direct_state = direct_public_state(task_pid, stream_id)
    owner_state = owner_forwarded_public_state(task_pid, stream_id)

    delta =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "synthetic visible output"
      })

    owner_delta_frame =
      {:websocket_owner_frame, "corr-owner-error", 7, task_pid, {:data, delta}}

    assert {:push, {:text, direct_delta}, direct_delta_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, delta},
               direct_state
             )

    assert {:push, {:text, owner_delta}, owner_delta_state} =
             CodexResponsesSocket.handle_info(owner_delta_frame, owner_state)

    assert Jason.decode!(direct_delta) == Jason.decode!(owner_delta)
    assert Jason.decode!(owner_delta)["stream_id"] == stream_id
    refute Map.has_key?(Jason.decode!(delta), "stream_id")
    refute Map.has_key?(owner_delta_state.websocket_owner_downstream, :stream_id)

    stale_turn_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(stale_turn_pid, :stop) end)

    stale_frame =
      {:websocket_owner_frame, "corr-owner-error", 7, stale_turn_pid, {:data, delta}}

    assert {:ok, ^owner_delta_state} =
             CodexResponsesSocket.handle_info(stale_frame, owner_delta_state)

    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_owner_parity", "status" => "completed"}
      })

    assert {:push, {:text, direct_terminal}, direct_terminal_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, terminal},
               direct_delta_state
             )

    owner_terminal_frame =
      {:websocket_owner_frame, "corr-owner-error", 7, task_pid, {:data, terminal}}

    assert {:push, {:text, owner_terminal}, owner_terminal_state} =
             CodexResponsesSocket.handle_info(owner_terminal_frame, owner_delta_state)

    assert Jason.decode!(direct_terminal) == Jason.decode!(owner_terminal)
    assert Jason.decode!(owner_terminal)["stream_id"] == stream_id
    assert direct_terminal_state.public_responses_websocket_state.terminal_latched?
    assert owner_terminal_state.public_responses_websocket_state.terminal_latched?
  end

  test "owner-forwarded upstream stream errors echo the active accepted stream id" do
    task_pid = self()
    state = owner_forwarded_public_state(task_pid, "lane-owner-upstream")

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:upstream_stream_error, nil)

    owner_frame =
      {:websocket_owner_frame, "corr-owner-error", 7, task_pid,
       {:error, :upstream_stream_error, safe_payload}}

    {_result, log} =
      with_log(fn ->
        assert {:push, {:text, payload}, ^state} =
                 CodexResponsesSocket.handle_info(owner_frame, state)

        assert Jason.decode!(payload)["stream_id"] == "lane-owner-upstream"
      end)

    refute log =~ "lane-owner-upstream"
    refute Map.has_key?(safe_payload, "stream_id")
  end

  test "owner drain echoes the active accepted stream id and clears queued turn state" do
    task_pid = owner_turn_pid()
    state = owner_forwarded_public_state(task_pid, "lane-owner-drain")

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

    owner_frame =
      {:websocket_owner_frame, "corr-owner-error", 7, task_pid,
       {:error, :owner_drained, safe_payload}}

    {_result, log} =
      with_log(fn ->
        assert {:push, {:text, payload}, aborted_state} =
                 CodexResponsesSocket.handle_info(owner_frame, state)

        assert Jason.decode!(payload)["stream_id"] == "lane-owner-drain"
        assert aborted_state.public_turn_aborted?
        assert aborted_state.public_response_stream_id == nil
        assert aborted_state.public_responses_websocket_state == nil
        assert :queue.is_empty(aborted_state.queued_response_payloads)
      end)

    refute log =~ "lane-owner-drain"
    refute Map.has_key?(safe_payload, "stream_id")
  end

  test "owner retarget failure echoes its accepted stream id before the queued next turn" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("should_not_dispatch")]))

    retarget_payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => "gpt-test",
        "input" => "synthetic stale retarget",
        "previous_response_id" => "resp_missing_owner",
        "stream_id" => "lane-owner-retarget"
      })

    next_payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => "gpt-test",
        "input" => "synthetic queued next turn"
      })

    state = owner_forwarded_idle_state()

    assert {:ok, active_state} =
             CodexResponsesSocket.handle_in({retarget_payload, [opcode: :text]}, state)

    retarget_task_pid = active_state.public_response_task_pid
    assert is_pid(retarget_task_pid)
    assert active_state.public_response_stream_id == "lane-owner-retarget"

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in({next_payload, [opcode: :text]}, active_state)

    assert :queue.to_list(queued_state.queued_response_payloads) == [next_payload]
    assert_receive {:codex_response_done, ^retarget_task_pid, {:error, reason}}, 1_000

    {_result, log} =
      with_log(fn ->
        assert {:push, {:text, retarget_frame}, next_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, retarget_task_pid, {:error, reason}},
                   queued_state
                 )

        assert Jason.decode!(retarget_frame)["stream_id"] == "lane-owner-retarget"
        assert next_state.public_response_stream_id == nil
        assert is_pid(next_state.public_response_task_pid)
        assert next_state.public_response_task_pid != retarget_task_pid
        refute Map.has_key?(next_state.public_responses_websocket_state, :stream_id)
        assert :queue.is_empty(next_state.queued_response_payloads)
        cleanup_response_task(next_state, next_state.public_response_task_pid)
      end)

    refute log =~ "lane-owner-retarget"
    assert FakeUpstream.count(upstream) == 0
  end

  test "synthetic JSON-frame bridge remains a single successful terminal", %{conn: conn} do
    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_bridge_stateful_sse_regression",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        }
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([completed]))
    setup = gateway_setup(upstream)
    session = "stateful-sse-bridge-#{System.unique_integer([:positive])}"

    response = post_stream(conn, setup, session, stream_payload(setup, "bridge regression"))

    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_bridge_stateful_sse_regression"
    assert event_types(response.resp_body) == ["response.created", "response.completed"]
    assert Enum.count(event_types(response.resp_body), &(&1 == "response.completed")) == 1

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"
    assert settlement_count(request) == 1
  end

  test "the owner-forwarded bridge preserves a function-only namespace and exact typed choice", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_bridge_namespace")]))
    setup = gateway_setup(upstream)
    session = "bridge-namespace-#{System.unique_integer([:positive])}"

    namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic function namespace",
      "tools" => [
        %{
          "type" => "function",
          "name" => "bridge_function_fixture",
          "description" => "Synthetic bridge function",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }

    tool_choice = %{"type" => "function", "name" => "bridge_function_fixture"}

    response =
      post_stream(
        conn,
        setup,
        session,
        stream_payload(setup, "function namespace bridge characterization")
        |> Map.merge(%{"tools" => [namespace_tool], "tool_choice" => tool_choice})
      )

    assert response.status == 200
    assert completed_id(response.resp_body) == "resp_bridge_namespace"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [namespace_tool]
    assert captured.json["tool_choice"] == tool_choice
  end

  test "the owner-forwarded bridge sends a mixed namespaced custom tool and exact choice", %{
    conn: conn
  } do
    upstream =
      start_upstream(FakeUpstream.sse_stream([completed_event("resp_bridge_namespace_custom")]))

    setup = gateway_setup(upstream)
    session = "bridge-namespace-custom-#{System.unique_integer([:positive])}"
    prompt_marker = "synthetic bridge namespaced custom prompt marker"
    description_marker = "synthetic bridge namespaced custom description marker"
    custom_input_marker = "synthetic_bridge_namespaced_custom_input_marker"
    grammar_marker = ~s(start: "#{custom_input_marker}")

    namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic mixed namespace",
      "tools" => [
        %{
          "type" => "function",
          "name" => "bridge_namespaced_function_fixture",
          "description" => "Synthetic adjacent function",
          "parameters" => %{"type" => "object", "properties" => %{}}
        },
        %{
          "type" => "custom",
          "name" => "bridge_namespaced_custom_fixture",
          "description" => description_marker,
          "format" => %{
            "type" => "grammar",
            "definition" => grammar_marker,
            "syntax" => "lark"
          }
        }
      ]
    }

    tool_choice = %{"type" => "custom", "name" => "bridge_namespaced_custom_fixture"}

    response =
      post_stream(
        conn,
        setup,
        session,
        stream_payload(setup, prompt_marker)
        |> Map.merge(%{"tools" => [namespace_tool], "tool_choice" => tool_choice})
      )

    assert response.status == 200
    assert event_types(response.resp_body) == ["response.created", "response.completed"]
    assert completed_id(response.resp_body) == "resp_bridge_namespace_custom"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [namespace_tool]
    assert captured.json["tool_choice"] == tool_choice

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "websocket"

    assert [%CodexTurn{codex_session_id: codex_session_id, status: "succeeded"}] =
             Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(codex_session_id)
    assert Process.alive?(owner_pid)

    persistence_text =
      inspect({
        request.request_metadata,
        attempt.response_metadata,
        RequestLogs.list(setup.pool, filters: %{request_id: request.id})
      })

    for marker <- [prompt_marker, description_marker, grammar_marker, custom_input_marker] do
      refute persistence_text =~ marker
    end

    owner_ref = Process.monitor(owner_pid)
    assert :ok = GenServer.stop(owner_pid, :shutdown, 1_000)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :shutdown}, 1_000
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(codex_session_id)
  end

  test "the owner-forwarded bridge restores null and omitted declared custom namespaces", %{
    conn: conn
  } do
    name = "bridge_restored_custom_fixture"

    null_namespace_call = %{
      "type" => "custom_tool_call",
      "name" => name,
      "namespace" => nil,
      "call_id" => "call_bridge_restored",
      "input" => "bridge_restored"
    }

    omitted_namespace_call = %{
      "type" => "custom_tool_call",
      "name" => name,
      "call_id" => "call_bridge_restored_omitted",
      "input" => "bridge_restored_omitted"
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          completed_event("resp_bridge_restored_custom_namespace", [
            null_namespace_call,
            omitted_namespace_call
          ])
        ])
      )

    setup = gateway_setup(upstream)
    session = "bridge-namespace-restoration-#{System.unique_integer([:positive])}"

    response =
      post_stream(
        conn,
        setup,
        session,
        stream_payload(setup, "synthetic bridge namespace restoration")
        |> Map.put("tools", [
          %{
            "type" => "namespace",
            "name" => "functions",
            "description" => "Synthetic bridge namespace",
            "tools" => [%{"type" => "custom", "name" => name}]
          }
        ])
      )

    assert response.status == 200

    assert %{"response" => %{"output" => restored}} =
             response.resp_body
             |> event_payloads()
             |> Enum.find(&(&1["type"] == "response.completed"))

    assert Enum.map(restored, & &1["namespace"]) == ["functions", "functions"]
  end

  test "the owner-forwarded bridge rejects malformed nested custom tools before forwarding", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("should_not_forward")]))
    setup = gateway_setup(upstream)
    session = "bridge-malformed-custom-#{System.unique_integer([:positive])}"

    malformed_namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic malformed namespace",
      "tools" => [
        %{
          "type" => "custom",
          "name" => "bridge_malformed_custom_fixture",
          "format" => %{
            "type" => "grammar",
            "definition" => 42,
            "syntax" => "lark"
          }
        }
      ]
    }

    response =
      post_stream(
        conn,
        setup,
        session,
        stream_payload(setup, "synthetic malformed nested custom request")
        |> Map.merge(%{"tools" => [malformed_namespace_tool]})
      )

    assert %{"error" => %{"code" => "invalid_request", "param" => "tools"}} =
             json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert Repo.aggregate(CodexSession, :count) == 0
    assert Repo.aggregate(CodexTurn, :count) == 0
    assert %{items: [], total: 0} = RequestLogs.list(setup.pool)
  end

  test "a bridged attempt records payload compression metadata for the websocket envelope", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event("resp_compression")]))
    setup = gateway_setup(upstream, exposed_model_id: "gpt-4o", upstream_model_id: "gpt-4o")
    enable_request_compression!(setup.pool)
    session = "compression-session-#{System.unique_integer([:positive])}"
    schema_bound_output = Jason.encode!(%{"rows" => Enum.to_list(1..160)}, pretty: true)
    unbound_output = Jason.encode!(%{"rows" => Enum.to_list(161..320)}, pretty: true)

    assert byte_size(schema_bound_output) > 512
    assert byte_size(unbound_output) > 512

    payload = %{
      "model" => setup.model.exposed_model_id,
      "tools" => [
        %{
          "type" => "function",
          "name" => "schema_bound_public_bridge_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "output_schema" => %{"type" => "object"}
        },
        %{
          "type" => "function",
          "name" => "unbound_public_bridge_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ],
      "input" => [
        %{
          "type" => "function_call",
          "call_id" => "call_bridge_schema_bound",
          "name" => "schema_bound_public_bridge_fixture",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call",
          "call_id" => "call_bridge_unbound",
          "name" => "unbound_public_bridge_fixture",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_bridge_schema_bound",
          "output" => schema_bound_output
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_bridge_unbound",
          "output" => unbound_output
        }
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

    request = latest_request(setup.pool)
    assert [attempt] = attempts_for(request)
    assert attempt.response_metadata["payload_compression"]["status"] == "compressed"

    schema_bound_item =
      Enum.find(captured.json["input"], fn item ->
        item["type"] == "function_call_output" and
          item["call_id"] == "call_bridge_schema_bound"
      end)

    unbound_item =
      Enum.find(captured.json["input"], fn item ->
        item["type"] == "function_call_output" and item["call_id"] == "call_bridge_unbound"
      end)

    assert schema_bound_item["output"] == schema_bound_output
    assert Jason.decode!(schema_bound_item["output"]) == Jason.decode!(schema_bound_output)
    assert unbound_item["output"] != unbound_output
    assert Jason.decode!(unbound_item["output"]) == Jason.decode!(unbound_output)

    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true

    # transport "websocket" and the exact byte count of the captured frame tie
    # the recorded compression pass to the websocket envelope, not to the
    # downstream HTTP payload the turn arrived on.
    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "compressed",
             "transport" => "websocket",
             "original_bytes" => original_bytes,
             "candidate_count" => 1,
             "compressed_count" => 1,
             "protected_tool_output_skipped_count" => 1
           } = metadata = attempt.response_metadata["payload_compression"]

    assert original_bytes > byte_size(captured.body)

    refute inspect(metadata) =~ "call_bridge_schema_bound"
    refute inspect(metadata) =~ "call_bridge_unbound"
  end

  @tag :prompt_cache_adaptation
  test "the bridge carries second-serialization prompt cache state and compression metadata" do
    cases = [
      %{
        label: "false-to-true",
        input: [
          %{
            "type" => "input_text",
            "text" => "fixture-text",
            "content" => nil,
            "encrypted_content" => "fixture-encrypted-content",
            "prompt_cache_breakpoint" => %{"mode" => "explicit"}
          }
        ],
        expected_websocket_input_count: 1
      },
      %{
        label: "true-to-false",
        input: [
          %{
            "type" => "agent_message",
            "content" => [
              %{
                "type" => "input_text",
                "text" => "fixture-text",
                "prompt_cache_breakpoint" => %{"mode" => "explicit"}
              },
              %{
                "type" => "encrypted_content",
                "encrypted_content" => "fixture-encrypted-content"
              }
            ]
          }
        ],
        expected_websocket_input_count: 0
      }
    ]

    propagated_states =
      for scenario <- cases do
        response_id = "resp_bridge_prompt_cache_#{scenario.label}"
        upstream = start_upstream(FakeUpstream.sse_stream([completed_event(response_id)]))
        setup = gateway_setup(upstream)
        enable_request_compression!(setup.pool)
        session = "prompt-cache-#{scenario.label}-#{System.unique_integer([:positive])}"

        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

        {:ok, %{endpoint: endpoint, payload: payload, request_options: request_options}} =
          ResponsesCompat.coerce(stream_payload(setup, "fixture turn"), %{
            session_header: session,
            session_header_source: "x-session-id",
            upstream_endpoint: "/backend-api/codex/responses",
            public_openai_responses_stream: true
          })

        payload = Map.put(payload, "input", scenario.input)

        assert {:ok, %{stream: stream}} =
                 RuntimeGateway.execute(auth, endpoint, payload, request_options)

        stream_conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        assert {:ok, stream_conn} = stream.(stream_conn)
        assert completed_id(stream_conn.resp_body) == response_id

        assert [captured] = FakeUpstream.requests(upstream)
        assert captured.method == "WEBSOCKET"
        assert length(captured.json["input"]) == scenario.expected_websocket_input_count
        refute inspect(captured.json) =~ "prompt_cache_breakpoint"

        request = latest_request(setup.pool)
        assert [attempt] = attempts_for(request)
        assert attempt.transport == "websocket"

        assert %{
                 "enabled" => true,
                 "attempted" => true,
                 "transport" => "websocket",
                 "original_bytes" => original_bytes
               } = attempt.response_metadata["payload_compression"]

        assert original_bytes == byte_size(captured.body)

        {scenario.label, attempt.response_metadata["prompt_cache_controls_downgraded"] == true}
      end

    assert propagated_states == [{"false-to-true", true}, {"true-to-false", false}]
  end

  @tag :v1_websocket_bridge_usage
  test "HTTP SSE over an upstream websocket settles usage before a retained large tail", %{
    conn: conn
  } do
    sentinel = "task-6-known-tail-#{System.unique_integer([:positive])}"
    completed_frame = oversized_completed_frame("resp_bridge_usage_known", sentinel, true)
    completed_event = WebsocketBridgeStream.sse_block(IO.iodata_to_binary(completed_frame))

    assert byte_size(completed_event) > RetainedBody.max_bytes()

    retained_suffix =
      RetainedBody.empty() |> RetainedBody.append(completed_event) |> RetainedBody.read()

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
    assert settlement.cached_input_tokens == 0
    assert settlement.output_tokens == 5
    assert settlement.reasoning_tokens == 4
    assert settlement.total_tokens == 21
    assert settlement.pricing_snapshot_id == flex_pricing.id
    assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(570))
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

  @tag :prompt_cache_adaptation
  test "HTTP Responses streaming bridge removes prompt cache controls before its upstream websocket serialization" do
    upstream =
      start_upstream(FakeUpstream.sse_stream([completed_event("resp_bridge_prompt_cache")]))

    setup = gateway_setup(upstream)
    session = "prompt-cache-http-bridge-#{System.unique_integer([:positive])}"

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, %{endpoint: endpoint, payload: payload, request_options: request_options}} =
      ResponsesCompat.coerce(stream_payload(setup, "bridge prompt cache seed"), %{
        session_header: session,
        session_header_source: "x-session-id",
        upstream_endpoint: "/backend-api/codex/responses",
        public_openai_responses_stream: true
      })

    payload =
      Map.merge(payload, %{
        "prompt_cache_key" => "bridge-cache-key",
        "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"},
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{
                "type" => "input_text",
                "text" => "bridge prompt cache content",
                "prompt_cache_breakpoint" => %{"mode" => "explicit"}
              }
            ]
          }
        ]
      })

    assert {:ok, %{stream: stream}} =
             RuntimeGateway.execute(auth, endpoint, payload, request_options)

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert completed_id(stream_conn.resp_body) == "resp_bridge_prompt_cache"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.json["prompt_cache_key"] == "bridge-cache-key"
    refute Map.has_key?(captured.json, "prompt_cache_options")
    refute inspect(captured.json) =~ "prompt_cache_breakpoint"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["prompt_cache_controls_downgraded"] == true
    refute Map.has_key?(request.request_metadata, "prompt_cache_controls_downgraded")
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
             "lifecycle_id" => lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(attempt)

    assert is_binary(lifecycle_id)

    assert settlement_count(request) == 1
  end

  @tag :opencode_1011_negative_regression
  test "a reused public bridge closed with 1011 after visible reasoning fails once and recovers only explicitly",
       %{conn: conn} do
    private_close_reason = "private-close-reason-#{System.unique_integer([:positive])}"
    request_input_sentinel = "synthetic-request-input-#{System.unique_integer([:positive])}"
    reasoning_frame_sentinel = "raw-reasoning-frame-#{System.unique_integer([:positive])}"

    reasoning_event =
      {"response.reasoning",
       %{
         "type" => "response.reasoning",
         "response_id" => "resp_opencode_1011",
         "output_index" => 0,
         "item_id" => "reasoning_opencode_1011",
         "summary" => reasoning_frame_sentinel
       }}

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([completed_event("resp_opencode_established")]),
           FakeUpstream.websocket_sse_then_close([reasoning_event],
             code: 1011,
             reason: private_close_reason
           ),
           FakeUpstream.sse_stream([completed_event("resp_opencode_recovered")])
         ]}
      )

    setup = gateway_setup(upstream)
    session = "opencode-1011-session-#{System.unique_integer([:positive])}"

    established =
      post_stream(conn, setup, session, stream_payload(setup, "establish public bridge"))

    assert established.status == 200
    assert completed_id(established.resp_body) == "resp_opencode_established"
    assert [initial_connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    failed =
      post_stream(
        conn,
        setup,
        session,
        stream_payload(setup, request_input_sentinel)
      )

    assert failed.status == 200
    assert event_types(failed.resp_body) == ["response.reasoning", "error"]
    assert failed.resp_body =~ reasoning_frame_sentinel

    data = response_failed_data(failed.resp_body)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(code error message param sequence_number type)

    assert Map.keys(data["error"]) |> Enum.sort() == ~w(code message param type)

    assert %{
             "type" => "error",
             "code" => "server_error",
             "message" => message,
             "param" => nil,
             "sequence_number" => sequence_number,
             "error" => %{
               "type" => "server_error",
               "code" => "server_error",
               "message" => message,
               "param" => nil
             }
           } = data

    assert is_integer(sequence_number)

    assert message ==
             "upstream request failed: stream interrupted before terminal response event"

    assert Enum.count(event_types(failed.resp_body), &(&1 == "error")) == 1
    refute failed.resp_body =~ private_close_reason
    refute failed.resp_body =~ "previous_response_not_found"
    refute failed.resp_body =~ "previous_response_generation_mismatch"

    failed_request = latest_request(setup.pool)
    assert failed_request.status == "failed"
    assert failed_request.transport == "http_sse"
    assert failed_request.last_error_code == "upstream_stream_error"

    assert get_in(failed_request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/responses"

    assert [failed_attempt] = attempts_for(failed_request)
    assert failed_attempt.status == "failed"
    assert failed_attempt.transport == "websocket"
    assert failed_attempt.network_error_code == "upstream_stream_error"

    assert %{
             "generation" => 1,
             "reused" => true,
             "reconnected" => false,
             "lifecycle_id" => lifecycle_id
           } = upstream_connection(failed_attempt)

    transport_failure = failed_attempt.response_metadata["transport_failure"]

    assert Map.take(transport_failure, [
             "termination_source",
             "peer_close_code",
             "peer_close_reason_present",
             "last_upstream_event_type",
             "last_upstream_event_class",
             "terminal_candidate_seen",
             "text_frame_count",
             "connection_use",
             "upstream_committed"
           ]) == %{
             "termination_source" => "peer_close_frame",
             "peer_close_code" => 1011,
             "peer_close_reason_present" => true,
             "last_upstream_event_type" => "response.reasoning",
             "last_upstream_event_class" => "response_event",
             "terminal_candidate_seen" => false,
             "text_frame_count" => 1,
             "connection_use" => "reused",
             "upstream_committed" => true
           }

    reason_bytes = transport_failure["peer_close_reason_bytes"]

    assert reason_bytes == byte_size(private_close_reason)
    refute Map.has_key?(transport_failure, "terminal_candidate_type")
    refute Map.has_key?(transport_failure, "terminal_candidate_class")
    refute Map.has_key?(transport_failure, "terminal_candidate_rejection")
    refute transport_failure["termination_source"] == "continuation_generation_guard"
    refute inspect(failed_request) =~ private_close_reason
    refute inspect(failed_attempt) =~ private_close_reason
    assert settlement_count(failed_request) == 1

    assert [establish_request, failed_upstream_request] = FakeUpstream.requests(upstream)
    assert establish_request.method == "WEBSOCKET"
    assert failed_upstream_request.method == "WEBSOCKET"
    assert inspect(failed_upstream_request.json["input"]) =~ request_input_sentinel
    refute Map.has_key?(failed_upstream_request.json, "previous_response_id")
    assert FakeUpstream.http_request_count(upstream) == 0

    recovered =
      post_stream(conn, setup, session, stream_payload(setup, "explicit later client request"))

    assert recovered.status == 200
    assert completed_id(recovered.resp_body) == "resp_opencode_recovered"

    recovered_request = latest_request(setup.pool)
    assert recovered_request.id != failed_request.id
    assert recovered_request.status == "succeeded"
    assert [recovered_attempt] = attempts_for(recovered_request)

    assert %{
             "generation" => 2,
             "reused" => false,
             "reconnected" => false,
             "lifecycle_id" => ^lifecycle_id
           } = upstream_connection(recovered_attempt)

    assert [^initial_connection_id, replacement_connection_id] =
             FakeUpstream.websocket_connection_ids(upstream)

    assert replacement_connection_id != initial_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
    assert FakeUpstream.http_request_count(upstream) == 0
    assert length(FakeUpstream.requests(upstream)) == 3
    assert settlement_count(recovered_request) == 1

    persisted =
      inspect({
        failed_request.request_metadata,
        failed_attempt.response_metadata,
        RequestLogs.list(setup.pool, filters: %{request_id: failed_request.id})
      })

    refute persisted =~ private_close_reason
    refute persisted =~ request_input_sentinel
    refute persisted =~ reasoning_frame_sentinel
    refute persisted =~ "previous_response_not_found"
    refute persisted =~ "continuation_generation_guard"
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
             "error"
           ]

    assert response.resp_body =~ "visible before rollout drain"

    data = response_failed_data(response.resp_body)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(code error message param sequence_number type)

    assert Map.keys(data["error"]) |> Enum.sort() == ~w(code message param type)

    assert %{
             "type" => "error",
             "code" => "server_error",
             "message" => message,
             "param" => nil,
             "sequence_number" => sequence_number,
             "error" => %{
               "type" => "server_error",
               "code" => "server_error",
               "message" => message,
               "param" => nil
             }
           } = data

    assert is_integer(sequence_number)

    assert message ==
             "upstream request failed: stream interrupted before terminal response event"

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

  test "websocket bridge drops malformed and non-object provider frames before completion", %{
    conn: conn
  } do
    sentinel = "BRIDGE_INVALID_FRAME_SENTINEL"

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_bridge_after_invalid", "status" => "completed"}
      })

    invalid_frames = [
      ~s({"private":"#{sentinel}"),
      Jason.encode!(sentinel),
      Jason.encode!([sentinel]),
      Jason.encode!(42),
      "null"
    ]

    upstream =
      start_upstream(FakeUpstream.websocket_text_frames(invalid_frames ++ [completed]))

    setup = gateway_setup(upstream)
    session = "bridge-invalid-provider-#{System.unique_integer([:positive])}"

    response =
      post_stream(conn, setup, session, stream_payload(setup, "bridge invalid provider frames"))

    assert response.status == 200
    assert event_types(response.resp_body) == ["response.created", "response.completed"]
    refute response.resp_body =~ sentinel

    assert response.resp_body
           |> event_payloads()
           |> Enum.map(& &1["sequence_number"]) == [0, 1]

    request = latest_request(setup.pool)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert is_nil(request.last_error_code)

    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    assert is_nil(attempt.network_error_code)
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
    assert event_types(response.resp_body) == ["error"]
    refute response.resp_body =~ "resp_timeout_fallback"

    request = latest_request(setup.pool)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "upstream_stream_error"
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
             "lifecycle_id" => lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(attempt)

    assert is_binary(lifecycle_id)
    assert settlement_count(request) == 1

    # The owner session must not stay wedged on the interrupted turn: caller
    # cancellation closes that abandoned upstream socket, so the next turn
    # bridges again on the same lifecycle's next generation.
    second =
      Phoenix.ConnTest.build_conn()
      |> auth(setup)
      |> put_req_header("x-session-id", session)
      |> post("/v1/responses", stream_payload(setup, "disconnect follow-up"))

    assert second.status == 200
    assert completed_id(second.resp_body) == "resp_disconnect_t2"
    assert FakeUpstream.websocket_connection_count(upstream) == 2

    assert [^disconnect_connection_id, reconnect_connection_id] =
             FakeUpstream.websocket_connection_ids(upstream)

    assert is_reference(reconnect_connection_id)
    refute reconnect_connection_id == disconnect_connection_id

    second_request = latest_request(setup.pool)
    assert second_request.id != request.id
    assert second_request.status == "succeeded"
    assert [second_attempt] = attempts_for(second_request)
    assert second_attempt.transport == "websocket"

    assert %{
             "lifecycle_id" => ^lifecycle_id,
             "generation" => 2,
             "reused" => false,
             "reconnected" => false
           } = upstream_connection(second_attempt)

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

  defp oversized_completed_frame(response_id, sentinel, include_usage?) do
    usage =
      if include_usage? do
        ~s(,"service_tier":"flex","usage":{"input_tokens":16,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":4},"total_tokens":21})
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

  defp direct_public_state(task_pid, stream_id) when is_pid(task_pid) do
    public_turn_state(task_pid, stream_id, %{})
  end

  defp owner_forwarded_public_state(task_pid, stream_id) when is_pid(task_pid) do
    public_turn_state(task_pid, stream_id, %{
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 7,
        correlation_id: "corr-owner-error",
        active_turn_reconnect?: false
      }
    })
  end

  defp owner_forwarded_idle_state do
    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    %{
      auth: nil,
      opts: opts,
      tasks: MapSet.new(),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: nil,
      public_response_stream_id: nil,
      public_response_start_error_ref: nil,
      public_responses_websocket_state: nil,
      public_turn_task_done?: false,
      public_turn_owner_complete?: false,
      public_owner_retarget_error?: false,
      public_turn_aborted?: false,
      public_turn_output_committed?: false,
      native_turn_output_task_pids: MapSet.new(),
      firewall_revoked?: false,
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 7,
        correlation_id: "corr-owner-error",
        active_turn_reconnect?: false
      }
    }
  end

  defp public_turn_state(task_pid, stream_id, overrides) when is_pid(task_pid) do
    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    Map.merge(
      %{
        opts: opts,
        tasks: MapSet.new([task_pid]),
        task_monitors: %{},
        queued_response_payloads: :queue.new(),
        public_response_task_pid: task_pid,
        public_response_stream_id: stream_id,
        public_response_start_error_ref: nil,
        public_responses_websocket_state: nil,
        public_turn_task_done?: false,
        public_turn_owner_complete?: false,
        public_owner_retarget_error?: false,
        public_turn_aborted?: false,
        public_turn_output_committed?: false,
        native_turn_output_task_pids: MapSet.new(),
        firewall_revoked?: false
      },
      overrides
    )
  end

  defp owner_turn_pid do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp cleanup_response_task(state, task_pid) when is_pid(task_pid) do
    if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)

    case Map.get(state.task_monitors, task_pid) do
      monitor when is_reference(monitor) -> Process.demonitor(monitor, [:flush])
      _missing -> :ok
    end
  end

  defp public_websocket_payload(setup, text, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input(text),
          "stream" => true,
          "generate" => true
        },
        extra
      )
    )
  end

  defp api_key_owner_scope(setup) do
    setup.api_key.created_by_user_id
    |> then(&Repo.get!(User, &1))
    |> Scope.for_user(["instance_owner"])
  end

  defp assert_public_websocket_queue_length!(server, expected_length) do
    assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
    {_socket, handler_state} = :sys.get_state(connection_pid)
    websock_state = handler_state.connection.websock_state
    assert :queue.len(websock_state.queued_response_payloads) == expected_length
  end

  defp public_websocket_transport_barrier!(conn, websocket, ref) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:ping, @websocket_transport_barrier_payload})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    await_public_websocket_transport_barrier!(
      conn,
      websocket,
      ref,
      System.monotonic_time(:millisecond) + @websocket_frame_timeout
    )
  end

  defp await_public_websocket_transport_barrier!(conn, websocket, ref, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_public_websocket_transport_barrier!(conn, websocket, ref, deadline)

          {:ok, conn, responses} ->
            {websocket, pong?} =
              Enum.reduce(responses, {websocket, false}, fn
                {:data, ^ref, response_data}, {websocket, pong?} ->
                  assert {:ok, websocket, frames} =
                           Mint.WebSocket.decode(websocket, response_data)

                  unexpected_frames =
                    Enum.reject(frames, fn
                      {:pong, @websocket_transport_barrier_payload} -> true
                      {:text, frame} -> public_metadata_frame?(frame)
                      _frame -> false
                    end)

                  assert unexpected_frames == []

                  {websocket,
                   pong? or
                     Enum.any?(
                       frames,
                       &match?({:pong, @websocket_transport_barrier_payload}, &1)
                     )}

                _response, acc ->
                  acc
              end)

            if pong? do
              {conn, websocket}
            else
              await_public_websocket_transport_barrier!(conn, websocket, ref, deadline)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket transport barrier failed: #{inspect(reason)}")
        end
    after
      timeout -> flunk("timed out waiting for websocket transport barrier")
    end
  end

  defp receive_public_websocket_frames_until_close!(conn, websocket, ref, frames \\ []) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, frames, closed?} =
              Enum.reduce(responses, {websocket, frames, false}, fn
                {:data, ^ref, data}, {websocket, frames, closed?} ->
                  assert {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
                  frames = frames ++ decoded
                  closed? = closed? or Enum.any?(decoded, &match?({:close, _, _}, &1))
                  {websocket, frames, closed?}

                _response, acc ->
                  acc
              end)

            if closed? do
              {conn, websocket, frames}
            else
              receive_public_websocket_frames_until_close!(conn, websocket, ref, frames)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket frame receive failed: #{inspect(reason)}")

          :unknown ->
            receive_public_websocket_frames_until_close!(conn, websocket, ref, frames)
        end
    after
      @websocket_frame_timeout -> flunk("timed out waiting for websocket close")
    end
  end

  defp public_metadata_frame?(frame) when is_binary(frame) do
    match?({:ok, %{"type" => "codex.response.metadata"}}, Jason.decode(frame))
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
