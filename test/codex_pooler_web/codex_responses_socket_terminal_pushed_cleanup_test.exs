defmodule CodexPoolerWeb.CodexResponsesSocketTerminalPushedCleanupTest do
  # Owner forwarding off: the socket pushed a turn's terminal (a provider
  # refusal the client displayed; Codex closes the connection right after it)
  # while the direct task was still settling that turn. The closing socket's
  # cleanup interrupted it as `499 client_disconnected`, so a refusal the client
  # had received lost its settlement and rejection fields whenever the
  # settlement took longer than the 250 ms drain (findings#254 row 254-131,
  # measured with a delayed settlement; the forwarding-off form of row
  # 254-110). The cleanup now leaves such a task to settle its own turn during
  # the post-cleanup drain.
  #
  # The direct task is a fake bound to a real request through the real
  # activity registry and direct cleanup; it settles only once the socket's
  # cleanup ran, which is exactly the slow settlement's ordering.
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

  @moduletag capture_log: true
  @timeout_ms 15_000

  @tag slow: "the socket's 250 ms pre-cleanup drain, its cleanup, then the task's own settlement inside the post-cleanup drain"
  test "a direct task whose terminal the socket already pushed settles its own turn when the socket closes" do
    fixture = fixture()
    {task, state} = cleanup_fixture(fixture)
    monitor = Process.monitor(task)
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    # The socket's cleanup runs in a supervised task that reports when it is
    # done; only then does the fake settle, so an interrupt of the cleanup
    # would have landed first.
    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
        fn _event, _measurements, %{caller: caller}, _config -> if caller == test_pid, do: send(task, :settle) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, @timeout_ms

    request = Repo.reload!(fixture.request)
    assert {request.status, request.last_error_code} == {"failed", "owner_task_exception"}

    assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^fixture.request.id and e.entry_kind == "settlement" and e.amount_status == "recorded"), :count) == 1
  end

  defp cleanup_fixture(fixture) do
    registry = start_supervised!({ActivityRegistry, name: nil})
    parent = self()

    task =
      start_supervised!({Task,
       fn ->
         context = %DirectCleanup{registry: registry, task: self(), parent: parent, ref: make_ref(), session_id: fixture.session.id}
         {:ok, token} = ActivityRegistry.register(:direct, self(), name: registry, direct_cleanup_ref: context.ref, direct_cleanup_parent: parent)
         :ok = ActivityRegistry.admit(token, name: registry)
         :ok = ActivityRegistry.begin_direct_cleanup(context)
         :ok = DirectCleanup.bind(context, fixture.request)
         :ok = DirectCleanup.attempt_callback(context, fixture.request).(fixture.attempt)
         :ok = ActivityRegistry.ready_direct_cleanup(context)
         send(parent, {:cleanup_ready, context, token})

         # Its own settlement: a terminal failure the task records itself.
         receive do
           :settle -> :ok = DirectCleanup.fail_task_exception(context, "owner_task_exception")
         end

         error = %{status: 500, code: :websocket_request_failed, message: "request failed", param: nil}
         send(parent, {:codex_response_done, self(), {:response_task_failure, {:error, error}}})

         receive do
           {:websocket_response_delivery_ack, ^token, _outcome} -> :ok
         after
           @timeout_ms -> :ok
         end
       end})

    assert_receive {:cleanup_ready, context, token}, @timeout_ms

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      codex_session: fixture.session,
      request_response_work_started?: true,
      tasks: MapSet.new([task]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      response_task_activities: %{task => token},
      response_task_activity_registry: registry,
      native_turn_output_task_pids: MapSet.new([task]),
      native_turn_client_output_task_pids: MapSet.new([task]),
      direct_cleanup_contexts: %{task => context},
      direct_cleanup_receipts: %{task => fixture.receipt},
      # provenance: observed findings#254 row 254-131 (the refusal frame reached the client before the task settled)
      downstream_delivery_evidence: %{
        task => %{frames: 2, terminal_class: "response.failed", pushed_at: DateTime.utc_now(), skipped?: false, highest_class: "terminal"}
      }
    }

    {task, state}
  end

  defp fixture do
    setup = accounting_setup()
    {:ok, session} = Gateway.start_codex_session(setup.auth, %{accepted_turn_state: "terminal-pushed-#{System.unique_integer([:positive])}"})
    payload = %{"model" => setup.model.exposed_model_id, "input" => [], "client_metadata" => %{"turn_id" => "terminal-pushed-turn"}}
    {:ok, identity} = WebsocketTurnIdentity.resolve(payload, session.id)
    witness = ClientRetry.original_witness!(:crypto.strong_rand_bytes(32), setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: claimed}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{endpoint: "/backend-api/codex/responses", correlation_id: identity.turn_claim_key, native_client_retry_witness: witness})

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, payload, %{endpoint: "/backend-api/codex/responses", transport: "websocket", correlation_id: identity.turn_claim_key, turn_claim: claimed})

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    options = RequestOptions.for_websocket(%{request_id: identity.turn_claim_key}) |> RequestOptions.put_continuity(semantic_turn_key: identity.semantic_turn_key)
    {:ok, _turn} = SessionContinuity.start_codex_turn(session, reserved.request, options)
    :ok = SessionContinuity.mark_codex_turn_visible(reserved.request)

    receipt = %{
      session_id: session.id,
      request_id: reserved.request.id,
      correlation_id: identity.turn_claim_key,
      api_key_id: setup.api_key.id,
      owner_binding: nil,
      attempt_id: attempt.id,
      replay_generation: attempt.replay_generation
    }

    %{setup: setup, session: Repo.get!(CodexSession, session.id), request: reserved.request, attempt: attempt, receipt: receipt}
  end
end
