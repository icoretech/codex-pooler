defmodule CodexPoolerWeb.CodexResponsesSocketTaskFailureCleanupTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.AccountingTestSupport
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, LedgerEntry}
  alias CodexPooler.Gateway.Payloads.{RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  @moduletag capture_log: true

  test "delivery cleanup preserves a failed task after database finalization recovers" do
    fixture = fixture()
    {context, token, state} = cleanup_fixture(fixture)
    send(context.task, :fail_finalization)
    assert_receive {:finalization_failed, task}, 15_000
    assert Repo.reload!(fixture.request).status == "in_progress"

    error = %{status: 500, code: :websocket_request_failed, message: "request failed", param: nil}

    assert {:push, {:text, _frame}, state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task, {:response_task_failure, {:error, error}}},
               state
             )

    assert_receive {:websocket_response_delivery_complete, _, ^token} = delivery
    assert {:ok, state} = CodexResponsesSocket.handle_info(delivery, state)
    assert state.tasks == MapSet.new()
    assert {:ok, %ClientRetry.SuccessorClaim{}} = claim(fixture)
    assert Repo.reload!(fixture.request).last_error_code == "owner_task_exception"
    assert Repo.reload!(fixture.attempt).network_error_code == "owner_task_exception"
    assert {:error, _} = claim(fixture)

    assert Repo.aggregate(
             from(e in LedgerEntry,
               where: e.request_id == ^fixture.request.id and e.entry_kind == "settlement"
             ),
             :count
           ) == 1
  end

  test "ordinary cancellation stays terminal and cannot claim a successor" do
    fixture = fixture()
    {context, token, state} = cleanup_fixture(fixture)

    assert {:ok, _state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_delivery_complete, context.task, token},
               state
             )

    assert Repo.reload!(fixture.request).last_error_code == "client_disconnected"
    assert {:error, _} = claim(fixture)
  end

  test "a prior durable terminal is not rewritten by delayed task failure cleanup" do
    fixture = fixture()
    {context, token, state} = cleanup_fixture(fixture)
    assert :ok = DirectCleanup.interrupt(fixture.receipt, "client_disconnected")
    before = Repo.reload!(fixture.request)
    state = Map.put(state, :response_task_cleanup_results, %{context.task => :task_exception})

    assert {:ok, _state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_delivery_complete, context.task, token},
               state
             )

    assert Repo.reload!(fixture.request) == before
    assert {:error, _} = claim(fixture)

    assert Repo.aggregate(
             from(e in LedgerEntry,
               where: e.request_id == ^fixture.request.id and e.entry_kind == "settlement"
             ),
             :count
           ) == 1
  end

  test "failed cleanup releases socket tracking without rewriting the request" do
    fixture = fixture()
    {context, token, state} = cleanup_fixture(fixture)

    state =
      state
      |> Map.put(:response_task_cleanup_results, %{context.task => :task_exception})
      |> Map.delete(:direct_cleanup_receipts)

    {_, logs} =
      ExUnit.CaptureLog.with_log(fn ->
        Repo.transaction(fn ->
          Repo.query!("ALTER TABLE requests RENAME TO task_failure_unavailable_requests")

          assert {:ok, cleaned} =
                   CodexResponsesSocket.handle_info(
                     {:websocket_response_delivery_complete, context.task, token},
                     state
                   )

          assert cleaned.tasks == MapSet.new()
          assert cleaned.direct_cleanup_contexts == %{}
          Repo.rollback(:injected_failure)
        end)
      end)

    assert logs =~ "websocket response task exception finalization failed"
    assert logs =~ "reason_code=owner_task_exception"
    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.reload!(fixture.request).last_error_code == nil
  end

  for opts_kind <- [:normalized, :plain_map] do
    test "socket termination retains the verified task exception cause with #{opts_kind} options" do
      fixture = fixture()
      {context, _token, state} = cleanup_fixture(fixture)
      state = if unquote(opts_kind) == :plain_map, do: %{state | opts: %{}}, else: state
      send(context.task, :fail_finalization)
      assert_receive {:finalization_failed, task}, 15_000
      state = Map.put(state, :response_task_cleanup_results, %{task => :task_exception})
      monitor = Process.monitor(task)
      # The fixture obeys the real delivery acknowledgement instead of waiting
      # for the socket's cancellation budget to kill an unresponsive fake task.
      # The exception cause is written by the session cleanup, which can
      # outlast terminate/2.
      assert :ok = WebsocketCleanupFence.terminate_and_await!(:normal, state)
      assert_receive {:cleanup_delivery_acknowledged, ^task}, 15_000
      assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 15_000
      assert Repo.reload!(fixture.request).last_error_code == "owner_task_exception"
      assert {:ok, %ClientRetry.SuccessorClaim{}} = claim(fixture)
    end
  end

  defp cleanup_fixture(fixture) do
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    task =
      start_supervised!({Task,
       fn ->
         context = %DirectCleanup{
           registry: registry,
           task: self(),
           parent: parent,
           ref: make_ref(),
           session_id: fixture.session.id
         }

         {:ok, token} =
           ActivityRegistry.register(:direct, self(),
             name: registry,
             direct_cleanup_ref: context.ref,
             direct_cleanup_parent: parent
           )

         :ok = ActivityRegistry.admit(token, name: registry)
         :ok = ActivityRegistry.begin_direct_cleanup(context)
         :ok = DirectCleanup.bind(context, fixture.request)
         :ok = DirectCleanup.attempt_callback(context, fixture.request).(fixture.attempt)
         :ok = ActivityRegistry.ready_direct_cleanup(context)
         send(parent, {:cleanup_ready, context, token})

         receive do
           :fail_finalization ->
             # The transaction restores the relation even when finalization raises.
             assert_raise Postgrex.Error, fn ->
               Repo.transaction(fn ->
                 Repo.query!("ALTER TABLE requests RENAME TO task_failure_unavailable_requests")
                 DirectCleanup.fail_task_exception(context, "owner_task_exception")
               end)
             end

             send(parent, {:finalization_failed, self()})
         end

         receive do
           {:websocket_response_delivery_ack, ^token, :aborted} ->
             send(parent, {:cleanup_delivery_acknowledged, self()})

           :stop ->
             :ok
         end
       end})

    assert_receive {:cleanup_ready, context, token}, 15_000

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      codex_session: fixture.session,
      tasks: MapSet.new([task]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      response_task_activities: %{task => token},
      response_task_activity_registry: registry,
      native_turn_output_task_pids: MapSet.new(),
      direct_cleanup_contexts: %{task => context},
      direct_cleanup_receipts: %{task => fixture.receipt}
    }

    {context, token, state}
  end

  defp fixture(claim_kind \\ :turn) do
    setup = accounting_setup()

    {:ok, session} =
      Gateway.start_codex_session(setup.auth, %{
        accepted_turn_state: "task-exception-#{System.unique_integer([:positive])}"
      })

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [],
      "client_metadata" => %{"turn_id" => "task-exception-turn"}
    }

    {:ok, identity} = WebsocketTurnIdentity.resolve(payload, session.id)

    claim =
      if claim_kind == :request,
        do: WebsocketTurnIdentity.request_claim_key(identity.semantic_turn_key, payload),
        else: identity.turn_claim_key

    replay_claim_digest = :crypto.strong_rand_bytes(32)

    witness =
      ClientRetry.original_witness!(replay_claim_digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: claimed}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: claim,
        native_client_retry_witness: witness
      })

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, payload, %{
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        correlation_id: claim,
        turn_claim: claimed
      })

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    options =
      RequestOptions.for_websocket(%{request_id: claim})
      |> RequestOptions.put_continuity(semantic_turn_key: identity.semantic_turn_key)

    {:ok, turn} = SessionContinuity.start_codex_turn(session, reserved.request, options)
    :ok = SessionContinuity.mark_codex_turn_visible(reserved.request)

    receipt = %{
      session_id: session.id,
      request_id: reserved.request.id,
      correlation_id: claim,
      api_key_id: setup.api_key.id,
      owner_binding: nil,
      attempt_id: attempt.id,
      replay_generation: attempt.replay_generation
    }

    session = Repo.get!(CodexSession, session.id)

    %{
      setup: setup,
      session: session,
      request: reserved.request,
      attempt: attempt,
      turn: turn,
      payload: payload,
      receipt: receipt,
      # The successor claim carries the owner-idle validation the gateway
      # performs against the live owner before claiming.
      opts: %{
        endpoint: "/backend-api/codex/responses",
        requested_model: setup.model.exposed_model_id,
        runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
        codex_session: session,
        semantic_turn_digest: identity.semantic_turn_key,
        original_request_claim: claim,
        replay_claim_digest: replay_claim_digest,
        owner_idle_validated?: true,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id
      }
    }
  end

  defp claim(fixture) do
    Accounting.claim_client_retry_successor(
      fixture.setup.auth,
      fixture.setup.model,
      fixture.payload,
      fixture.opts
    )
  end
end
