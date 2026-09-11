defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.DispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestLifecycle.Reservation
  alias CodexPooler.AgentV2ContractFixture
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias Ecto.Adapters.SQL.Sandbox

  @handoff_detection_timeout_ms 15_000
  @reasoning_denial_message "reasoning effort is not available for this API key"

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      TurnBudgetNodeClient.reset()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  for order <- [:terminal_first, :result_first] do
    test "completed-only owner arbitration settles once with #{order}" do
      assert_completed_only_arbitration(unquote(order))
    end
  end

  defp assert_completed_only_arbitration(order) do
    terminal =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_completed_only_arbitration",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        }
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, socket} = owner_socket(auth, "ws-completed-only-#{order}", "completed-only-#{order}")
    {:ok, owner} = WebsocketOwnerSession.lookup(socket.codex_session.id)
    parent = self()
    barrier = make_ref()

    :sys.install(
      owner,
      {fn debug_state, event, _name ->
         case event do
           {:noreply, %{active_turn: %{pending_result: result, terminal_forwarded?: forwarded}}}
           when not is_nil(result) ->
             send(parent, {:arbitration_pending, barrier, forwarded})

           _ ->
             :ok
         end

         debug_state
       end, nil}
    )

    :sys.replace_state(owner, fn state ->
      real_sender = state.callbacks.upstream_sender

      sender = completed_only_arbitration_sender(real_sender, order, parent, barrier)

      %{state | callbacks: %{state.callbacks | upstream_sender: sender}}
    end)

    {:ok, socket} =
      CodexResponsesSocket.handle_in(
        {websocket_payload(setup, "completed only"), [opcode: :text]},
        socket
      )

    assert_receive {:arbitration_result, ^barrier, sender}, @handoff_detection_timeout_ms

    socket =
      case order do
        :terminal_first ->
          next = receive_completed_only_arbitration_terminal(socket, terminal)

          assert :sys.get_state(owner).active_turn.terminal_forwarded?
          send(sender, {:arbitration_release, barrier})
          next

        :result_first ->
          assert_receive {:arbitration_frame, ^barrier, deliver}, @handoff_detection_timeout_ms
          send(sender, {:arbitration_release, barrier})
          assert_receive {:arbitration_pending, ^barrier, false}, @handoff_detection_timeout_ms
          deliver.()

          receive_completed_only_arbitration_terminal(socket, terminal)
      end

    assert {:ok, socket} = receive_owner_socket_complete(socket)
    socket = drain_completed_only_arbitration(socket)
    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert_forwarding_cardinality!(request, socket.codex_session.id, "succeeded")
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    refute_received {:websocket_owner_frame, _, _, _, {:data, ^terminal}}
    CodexResponsesSocket.terminate(:closed, socket)
  end

  defp completed_only_arbitration_sender(real_sender, order, parent, barrier) do
    fn upstream_pid, payload, writer ->
      observed_writer = completed_only_arbitration_writer(writer, order, parent, barrier)
      result = real_sender.(upstream_pid, payload, observed_writer)
      send(parent, {:arbitration_result, barrier, self()})

      receive do
        {:arbitration_release, ^barrier} -> result
      after
        @handoff_detection_timeout_ms -> {:error, :barrier_timeout}
      end
    end
  end

  defp completed_only_arbitration_writer(writer, order, parent, barrier) do
    fn frame, discriminator ->
      case {order, TerminalDiscriminator.terminal?(discriminator)} do
        {:terminal_first, _} ->
          writer.(frame, discriminator)

        {:result_first, false} ->
          writer.(frame, discriminator)

        {:result_first, true} ->
          hold_completed_only_arbitration_frame(parent, barrier, writer, frame, discriminator)
      end
    end
  end

  defp hold_completed_only_arbitration_frame(parent, barrier, writer, frame, discriminator) do
    send(parent, {:arbitration_frame, barrier, fn -> writer.(frame, discriminator) end})
  end

  defp receive_completed_only_arbitration_terminal(socket, terminal) do
    assert {:push, {:text, frame}, socket} = receive_owner_socket_raw_push(socket)

    if frame == terminal do
      socket
    else
      assert CodexPooler.JSON.decode!(frame)["type"] == "codex.response.metadata"
      receive_completed_only_arbitration_terminal(socket, terminal)
    end
  end

  defp drain_completed_only_arbitration(socket) do
    if MapSet.size(socket.tasks) == 0 do
      socket
    else
      receive do
        {:websocket_response_activity, _, _} = message ->
          assert {:ok, socket} = CodexResponsesSocket.handle_info(message, socket)
          drain_completed_only_arbitration(socket)

        {:codex_response_done, _, result} = message ->
          assert result == {:socket_response_result, :owner_completion_pending, :ok}
          assert {:ok, socket} = CodexResponsesSocket.handle_info(message, socket)
          drain_completed_only_arbitration(socket)

        {:websocket_response_delivery_complete, _, _} = message ->
          assert {:ok, socket} = CodexResponsesSocket.handle_info(message, socket)
          drain_completed_only_arbitration(socket)
      after
        @handoff_detection_timeout_ms -> flunk("expected terminal arbitration task cleanup")
      end
    end
  end

  @tag :owner_forwarding_catalog_token
  test "owner-forwarding-enabled Mint upgrades keep one catalog token across backend aliases",
       %{conn: conn} do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    models_conn =
      conn
      |> auth(setup)
      |> get("/backend-api/codex/models")

    assert [models_etag] = get_resp_header(models_conn, "etag")
    models_accounting_count = Repo.aggregate(Request, :count)
    port = start_public_endpoint!()

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)

    {local_conn, _websocket, _ref, local_headers} =
      public_websocket_connect_with_headers!(port, setup, "")

    local_token =
      try do
        assert Repo.aggregate(Request, :count) == models_accounting_count
        assert {"x-models-etag", token} = List.keyfind(local_headers, "x-models-etag", 0)
        assert token == models_etag
        token
      after
        Mint.HTTP.close(local_conn)
      end

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    alias_tokens =
      for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
        {mint_conn, _websocket, _ref, response_headers} =
          public_websocket_connect_with_headers!(port, setup, "", path)

        try do
          assert Application.fetch_env!(:codex_pooler, :websocket_owner_forwarding_enabled)
          assert Repo.aggregate(Request, :count) == models_accounting_count
          assert {"x-models-etag", token} = List.keyfind(response_headers, "x-models-etag", 0)
          assert token == models_etag
          token
        after
          Mint.HTTP.close(mint_conn)
        end
      end

    assert alias_tokens == [local_token, local_token]
    assert Repo.aggregate(Request, :count) == models_accounting_count
  end

  @tag :strict_fake_upstream
  test "owner-forwarded websocket turns reuse one upstream websocket connection" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_owner_response("resp_owner_first", 1),
          strict_owner_response("resp_owner_second", 1)
        ])
      )

    setup = gateway_setup(upstream)
    residency = "ws-owner-region-#{System.unique_integer([:positive])}"
    access_token = synthetic_access_token(residency)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "access_token",
               plaintext: access_token
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-forwarding",
          accepted_turn_state: "stable-ws-owner-forwarding",
          client_ip: "127.0.0.1"
        }
      })

    try do
      handoff = AgentV2ContractFixture.handoff!(:spawn_agent)
      first_payload = websocket_input_payload(setup, [handoff])

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_first"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      second_payload = websocket_payload(setup, "second")

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_second"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.websocket_connection_count(upstream) == 1
      assert [opaque_connection_id] = FakeUpstream.websocket_connection_ids(upstream)
      assert is_reference(opaque_connection_id)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert first_request.json["input"] == [handoff]

      for captured <- [first_request, second_request] do
        assert header_values(captured.headers, "x-openai-internal-codex-residency") == [
                 residency
               ]

        assert header_values(captured.headers, "chatgpt-account-id") == [
                 setup.identity.chatgpt_account_id
               ]
      end

      assert [first_request_log, second_request_log] =
               Repo.all(
                 from(r in Request,
                   where: r.pool_id == ^setup.pool.id,
                   order_by: [asc: r.admitted_at, asc: r.id]
                 )
               )

      assert first_request_log.transport == "websocket"
      assert second_request_log.transport == "websocket"

      assert [first_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^first_request_log.id))

      assert [second_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^second_request_log.id))

      assert first_attempt.transport == "websocket"
      assert second_attempt.transport == "websocket"

      first_connection = first_attempt.response_metadata["upstream_websocket_connection"]
      second_connection = second_attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id, "generation" => generation} = first_connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)
      assert generation == 1

      assert first_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => generation,
               "reused" => false,
               "reconnected" => false
             }

      assert second_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => generation,
               "reused" => true,
               "reconnected" => false
             }

      for {request_log, attempt} <- [
            {first_request_log, first_attempt},
            {second_request_log, second_attempt}
          ] do
        assert [settlement] =
                 Repo.all(
                   from(entry in LedgerEntry,
                     where:
                       entry.request_id == ^request_log.id and
                         entry.entry_kind == "settlement"
                   )
                 )

        assert settlement.attempt_id == attempt.id
        assert settlement.transport == "websocket"
      end

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("stable-ws-owner-forwarding")
        )

      refute_raw_turn_state_session_key!(setup.pool.id, "stable-ws-owner-forwarding")
      assert session.owner_instance_id == Atom.to_string(node())
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert_owner_websocket_values_not_persisted!(setup, [residency, access_token], "")
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded websocket reasoning denial cannot bypass pre-dispatch policy" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    setup.api_key
    |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
    |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reasoning-denial", "owner-reasoning-denial")

    try do
      payload =
        websocket_payload(setup, "synthetic owner policy denial", %{"reasoning_effort" => "high"})

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, error_frame}, state} = receive_socket_done(state)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "reasoning_effort_not_allowed",
                 "message" => @reasoning_denial_message,
                 "param" => "reasoning.effort"
               }
             } = CodexPooler.JSON.decode!(error_frame)

      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      assert FakeUpstream.count(upstream) == 0
      assert [request] = request_logs(setup.pool.id)
      assert request.status == "rejected"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) ==
               0

      assert get_in(request.request_metadata, ["gateway_denial", "reasoning_policy"]) == %{
               "policy_mode" => "allow_up_to",
               "configured_effort" => "medium",
               "requested_effort" => "high",
               "applied_effort" => nil
             }
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "a paused key stops a remote-owner-shaped turn at reservation without dispatch or recovery" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-api-key-fence", "owner-api-key-fence")
    remote_node = :"codex_pooler@remote-owner-api-key-fence.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(state, remote_node, node_opts)

    opts = owner_response_options(remote_state, node_opts)
    barrier_ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        Process.put(
          {Reservation, :runtime_authorization_barrier},
          {parent, barrier_ref, {:reserve, :before}}
        )

        Process.put(
          {Service, :runtime_authorization_barrier},
          {parent, barrier_ref, {:reserve, :before}}
        )

        Gateway.run_websocket_response_for_socket(
          auth,
          websocket_payload(setup, "remote owner durable fence"),
          opts,
          fn _frame -> :ok end
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)

    try do
      assert remote_state.codex_session.owner_instance_id == Atom.to_string(remote_node)

      assert_receive {:runtime_authorization_barrier, ^barrier_ref, :reserve, :before, task_pid},
                     1_000

      assert task_pid == task.pid
      assert request_logs(setup.pool.id) == []

      assert {:ok, paused_key} = Access.pause_api_key(model_serving_scope(), setup.api_key)
      assert paused_key.status == "paused"
      send(task.pid, {:runtime_authorization_release, barrier_ref})

      assert {:socket_response_result, :local_complete,
              {:error, %{code: :api_key_paused, disabling_epoch: disabling_epoch}}} =
               Task.await(task, 15_000)

      assert disabling_epoch == paused_key.runtime_revocation_epoch

      assert [%Request{status: "rejected", last_error_code: "api_key_paused"}] =
               request_logs(setup.pool.id)

      assert pool_attempts(setup.pool.id) == []
      assert pool_ledger_entries(setup.pool.id) == []
      assert Repo.aggregate(CodexTurn, :count) == 0
      assert FakeUpstream.count(upstream) == 0
      refute_received {:websocket_owner_harness_node_call, _call}
      refute_received {:websocket_owner_frame, _, _, _}
      refute_received {:websocket_owner_frame, _, _, _, _}
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  test "owner forwarding does not acquire a second proxy websocket admission slot" do
    with_single_proxy_websocket_slot(fn ->
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_admission"}))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, state} =
        CodexResponsesSocket.init(%{
          auth: auth,
          opts: %{
            request_id: "ws-owner-admission",
            accepted_turn_state: "stable-ws-owner-admission",
            client_ip: "127.0.0.1"
          }
        })

      try do
        payload = websocket_payload(setup, "single admission owner turn")

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
        assert %{"id" => "resp_owner_admission"} = CodexPooler.JSON.decode!(frame)
        assert {:ok, _state} = receive_socket_done(state)

        assert [_request] = FakeUpstream.requests(upstream)
        assert [request_log] = request_logs(setup.pool.id)
        assert request_log.status == "succeeded"
        assert request_log.transport == "websocket"
      after
        CodexResponsesSocket.terminate(:closed, state)
      end
    end)
  end

  test "owner-forwarded websocket terminal usage settles priced gpt-5.5 request logs" do
    terminal_usage = %{
      "input_tokens" => 123,
      "input_tokens_details" => %{"cached_tokens" => 17},
      "output_tokens" => 45,
      "reasoning_tokens" => 6,
      "total_tokens" => 168
    }

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_priced_gpt55",
          "object" => "response",
          "usage" => terminal_usage
        })
      )

    setup = gateway_setup(upstream)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: "gpt-5.5",
        upstream_model_id: "gpt-5.5",
        pricing_ref: "gpt-5.5",
        metadata:
          put_in(
            setup.model.metadata,
            ["source_assignment_models", setup.assignment.id, "slug"],
            "gpt-5.5"
          )
      })
      |> Repo.update!()

    pricing_snapshot!(model, %{
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30)
    })

    setup = %{setup | model: model}
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-priced-gpt55", "owner-priced-gpt55")

    try do
      payload = websocket_payload(setup, "owner priced usage")

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_priced_gpt55"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end

    assert [request] = request_logs(setup.pool.id)
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert request.requested_model == "gpt-5.5"

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 123
    assert settlement.cached_input_tokens == 17
    assert settlement.output_tokens == 45
    assert settlement.reasoning_tokens == 6
    assert settlement.total_tokens == 168
    assert settlement.pricing_snapshot_id
    assert Decimal.positive?(settlement.settled_cost_micros)
    assert settlement.details["pricing_status"] == "priced"
    assert is_binary(settlement.details["settled_cost_micros"])

    assert %{items: [log], total: 1} =
             Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})

    assert log.usage_status == "usage_known"
    assert log.token_counts.total_tokens == 168
    assert log.cost.status == "priced"
    assert %Decimal{} = log.cost.usd
    assert Decimal.positive?(log.cost.usd)
  end

  @tag :findings116
  test "owner request reservation is finalized when socket closes during upstream work" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-close-during-request", "close-during-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "close while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert state.request_response_work_started?
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, state)
        end)

      refute logs =~ WebsocketConnectionLogger.closed_message()
      refute logs =~ WebsocketConnectionLogger.init_failed_message()
      refute logs =~ "websocket owner detach failed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession, session_key: turn_state_session_key("close-during-request"))

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "client_disconnected"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "client_disconnected"
      assert turn.status == "interrupted"
      assert turn.error_code == "client_disconnected"
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  defp with_single_proxy_websocket_slot(fun) do
    with_proxy_websocket_bulkhead(0, 1_000, fun)
  end
end
