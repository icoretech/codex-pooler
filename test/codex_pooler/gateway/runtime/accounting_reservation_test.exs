defmodule CodexPooler.Gateway.Runtime.AccountingReservationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  import CodexPooler.AccountsFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.Accounting.RequestLifecycle.Reservation
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint "/backend-api/codex/responses"

  test "baseline explicit websocket claim reserves and settles one request once" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_baseline123456789"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = websocket_payload(setup.model.exposed_model_id, "baseline accepted work")

    assert {:ok, result} =
             Service.execute(
               auth,
               @endpoint,
               payload,
               request_options(auth, payload, setup.model.exposed_model_id, "baseline-turn")
             )

    assert result.status == 200
    request = Repo.one!(Request)
    assert request.status == "succeeded"
    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.aggregate(LedgerEntry, :count) == 3
    request_id = request.id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert FakeUpstream.count(upstream) == 1
  end

  test "prepare_replay_intent returns fresh without consuming the prepared frame or creating work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    session_opts = request_options(auth, %{}, setup.model.exposed_model_id, "intent-session")
    assert {:ok, %CodexSession{} = session} = Websocket.start_codex_session(auth, session_opts)

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "turn_id" => "intent-fresh-turn",
      "input" => []
    }

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "intent-fresh")
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    counts = runtime_counts()

    {result, events} =
      capture_query_order(fn -> Service.prepare_replay_intent(auth, prepared) end)

    assert {:ok,
            %{
              intent: :fresh,
              authorization_binding: %{
                api_key_id: api_key_id,
                api_key_runtime_epoch: 0,
                pool_id: pool_id,
                codex_session_id: session_id,
                model_identifier: model_identifier
              },
              lifecycle: nil
            }} = result

    assert api_key_id == auth.api_key.id
    assert pool_id == auth.pool.id
    assert session_id == session.id
    assert model_identifier == setup.model.exposed_model_id
    assert runtime_counts() == counts
    assert FakeUpstream.count(upstream) == 0

    assert :ok =
             WebsocketCodec.validate_prepared_frame(prepared)

    session_lock_index =
      Enum.find_index(events, &(&1.source == "codex_sessions" and &1.for_update?))

    api_key_lock_index =
      Enum.find_index(events, &(&1.source == "api_keys" and &1.for_update?))

    replay_query_index =
      Enum.find_index(events, &(&1.source == "codex_turns" and not &1.for_update?))

    assert session_lock_index < api_key_lock_index
    assert api_key_lock_index < replay_query_index
  end

  test "prepare_replay_intent classifies active and suspended lifecycle and rejects changed claims" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    session_opts =
      request_options(auth, %{}, setup.model.exposed_model_id, "intent-existing-session")

    assert {:ok, %CodexSession{} = session} = Websocket.start_codex_session(auth, session_opts)

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "turn_id" => "intent-existing-turn",
      "input" => []
    }

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "intent-existing")
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    request =
      CodexPooler.PoolerFixtures.request_fixture(auth, %{
        model_id: setup.model.id,
        requested_model: setup.model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil
      })

    assert {:ok, turn} =
             SessionContinuity.start_codex_turn(
               session,
               request,
               prepared.request_options
             )

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(request, setup.assignment, %{
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })

    assert {:ok, %{intent: :active_reattach, lifecycle: active}} =
             Service.prepare_replay_intent(auth, prepared)

    assert active.request_id == request.id

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attempt
    |> Ecto.Changeset.change(%{
      status: "retryable_failed",
      completed_at: now,
      retryable: true,
      network_error_code: "client_disconnected",
      usage_status: "usage_unknown"
    })
    |> Repo.update!()

    entitlement =
      %RequestReplayEntitlement{}
      |> RequestReplayEntitlement.changeset(%{
        request_id: request.id,
        codex_turn_id: turn.id,
        eligible_attempt_id: attempt.id,
        api_key_id: auth.api_key.id,
        api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch,
        pool_id: auth.pool.id,
        model_id: setup.model.id,
        model_identifier: setup.model.exposed_model_id,
        semantic_turn_digest: prepared.semantic_turn_key,
        replay_claim_digest: prepared.replay_claim_digest,
        replay_generation: 1,
        owner_lease_digest: <<3::256>>,
        owner_lease_key_version: "test-v1",
        predecessor_epoch: 1,
        status: "armed",
        armed_at: now,
        expires_at: DateTime.add(now, 30, :second)
      })
      |> Repo.insert!()

    assert {:ok, %{intent: :suspended_replay, lifecycle: %{entitlement_id: entitlement_id}}} =
             Service.prepare_replay_intent(auth, prepared)

    assert entitlement_id == entitlement.id

    changed_payload = Map.put(payload, "instructions", "changed replay claim")

    assert {:ok, changed} =
             Service.prepare_websocket_response(
               Jason.encode!(changed_payload),
               opts,
               fn _frame -> :ok end
             )

    assert {:error, %{status: 409, code: "duplicate_turn"}} =
             Service.prepare_replay_intent(auth, changed)

    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.aggregate(RequestReplayEntitlement, :count) == 1
    assert FakeUpstream.count(upstream) == 0
  end

  test "prepare_replay_intent rejects stale epoch and swapped principal before mutation or dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "turn_id" => "intent-stale-turn",
      "input" => []
    }

    stale_opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "intent-stale")
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.put_runtime_context(api_key_runtime_epoch: 1)

    assert {:ok, stale_prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), stale_opts, fn _frame ->
               :ok
             end)

    counts = runtime_counts()

    assert {:error, %{code: :api_key_runtime_epoch_stale}} =
             Service.prepare_replay_intent(auth, stale_prepared)

    %{api_key: other_key} = CodexPooler.PoolerFixtures.active_api_key_fixture(auth.pool)
    swapped_auth = %{auth | api_key: other_key, api_key_id: other_key.id}

    assert {:error, %{status: 409, code: "duplicate_turn"}} =
             Service.prepare_replay_intent(swapped_auth, stale_prepared)

    other_pool = CodexPooler.PoolerFixtures.pool_fixture()
    swapped_pool_auth = %{auth | pool: other_pool, pool_id: other_pool.id}

    assert {:error, %{status: 409, code: "duplicate_turn"}} =
             Service.prepare_replay_intent(swapped_pool_auth, stale_prepared)

    assert runtime_counts() == counts
    assert FakeUpstream.count(upstream) == 0
  end

  test "prepare_replay_intent rejects epoch and session tampering before database work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "turn_id" => "intent-tamper-turn",
      "input" => []
    }

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "intent-tamper")
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    tampered_epoch =
      update_in(prepared.request_options.runtime.api_key_runtime_epoch, fn _epoch -> 1 end)

    other_session = %{session | id: Ecto.UUID.generate()}

    tampered_session =
      put_in(prepared.request_options.continuity.codex_session, other_session)

    counts = runtime_counts()

    for tampered <- [tampered_epoch, tampered_session] do
      {result, events} =
        capture_query_order(fn -> Service.prepare_replay_intent(auth, tampered) end)

      assert {:error, %{status: 400, code: "invalid_request"}} = result
      assert events == []
    end

    assert runtime_counts() == counts
    assert FakeUpstream.count(upstream) == 0
  end

  test "prepare_replay_intent rejects a currently locked API key moved outside the session Pool" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "turn_id" => "intent-key-pool-mismatch",
      "input" => []
    }

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "intent-key-pool-mismatch")
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    other_pool = CodexPooler.PoolerFixtures.pool_fixture()

    auth.api_key
    |> Ecto.Changeset.change(%{pool_id: other_pool.id})
    |> Repo.update!()

    counts = runtime_counts()

    assert {:error, %{status: 409, code: "duplicate_turn"}} =
             Service.prepare_replay_intent(auth, prepared)

    assert runtime_counts() == counts
    assert FakeUpstream.count(upstream) == 0

    assert :ok =
             WebsocketCodec.validate_prepared_frame(prepared)
  end

  test "concurrent replay intent preparation remains read-only and leaves capability reusable" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "turn_id" => "intent-concurrent-turn",
      "input" => []
    }

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "intent-concurrent")
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    parent = self()
    release_ref = make_ref()
    counts = runtime_counts()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:replay_intent_ready, self()})

          receive do
            {:prepare_replay_intent, ^release_ref} ->
              Service.prepare_replay_intent(auth, prepared)
          end
        end)
      end

    pids =
      for _index <- 1..2 do
        assert_receive {:replay_intent_ready, pid}
        Sandbox.allow(Repo, self(), pid)
        pid
      end

    Enum.each(pids, &send(&1, {:prepare_replay_intent, release_ref}))
    results = Enum.map(tasks, &Task.await(&1, 15_000))

    assert Enum.all?(results, fn
             {:ok, %{intent: :fresh, lifecycle: nil, authorization_binding: binding}} ->
               binding == expected_binding(auth, session, setup.model)

             _other ->
               false
           end)

    assert runtime_counts() == counts
    assert FakeUpstream.count(upstream) == 0

    assert :ok =
             WebsocketCodec.validate_prepared_frame(prepared)
  end

  test "manually forged admission carrier fails before claim reservation or upstream work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_forged_admission"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = websocket_payload(setup.model.exposed_model_id, "forged admission")

    options =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "forged-admission-turn")
      |> then(fn options ->
        %{
          options
          | native_compaction_admission: %RequestOptions.NativeCompactionAdmission{
              capability: :forged,
              owner: :forged,
              expected_connection_lifecycle: :forged
            }
        }
      end)

    assert {:error, %{code: "invalid_runtime_admission"}} =
             Service.execute(auth, @endpoint, payload, options)

    assert_runtime_counts(%{requests: 0, attempts: 0, ledger: 0, turns: 0, sessions: 0})
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :replacement_turn_lock_order
  test "replacement reservation locks its session before API key authorization" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_lock_order123456789"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = websocket_payload(setup.model.exposed_model_id, "replacement lock order")

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "replacement-lock-order")
      |> RequestOptions.put_continuity(
        accepted_turn_state:
          "replacement-lock-order-#{System.unique_integer([:positive, :monotonic])}"
      )

    assert {:ok, %CodexSession{} = session} = Websocket.start_codex_session(auth, opts)
    opts = RequestOptions.put_continuity(opts, codex_session: session)

    {result, events} =
      capture_query_order(fn -> Service.execute(auth, @endpoint, payload, opts) end)

    assert {:ok, %{status: 200}} = result

    session_lock_index =
      Enum.find_index(events, fn event ->
        event.source == "codex_sessions" and event.operation == "SELECT" and
          event.for_update?
      end)

    api_key_lock_index =
      events
      |> Enum.with_index()
      |> Enum.filter(fn {event, _index} ->
        event.source == "api_keys" and event.operation == "SELECT" and event.for_update?
      end)
      |> List.last()
      |> then(fn {_, index} -> index end)

    assert is_integer(session_lock_index)
    assert is_integer(api_key_lock_index)
    assert session_lock_index < api_key_lock_index
    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(CodexTurn, :count) == 1
  end

  test "pause before websocket claim creates no runtime or accounting work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    scope = instance_owner_scope()
    payload = websocket_payload(setup.model.exposed_model_id, "pause before claim")
    ref = make_ref()

    task =
      start_gateway_task(auth, setup.model, payload, upstream, ref, {:claim, :before})

    assert_receive {:runtime_authorization_barrier, ^ref, :claim, :before, task_pid}
    assert task_pid == task.pid
    assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
    assert paused_key.runtime_revocation_epoch == 1
    send(task.pid, {:runtime_authorization_release, ref})

    assert {:error, %{code: :api_key_paused, disabling_epoch: 1}} = Task.await(task, 15_000)
    assert_runtime_counts(%{requests: 0, attempts: 0, ledger: 0, turns: 0, sessions: 0})
    assert FakeUpstream.count(upstream) == 0
  end

  test "captured epoch mismatch remains an internal zero-work disposition" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = websocket_payload(setup.model.exposed_model_id, "stale captured epoch")

    opts =
      auth
      |> request_options(payload, setup.model.exposed_model_id, "stale-epoch-turn")
      |> RequestOptions.put_runtime_context(api_key_runtime_epoch: 1)

    assert {:error, %{code: :api_key_runtime_epoch_stale, disabling_epoch: 0} = error} =
             Service.execute(auth, @endpoint, payload, opts)

    refute Map.has_key?(error, :status)
    refute Map.has_key?(error, :param)
    assert_runtime_counts(%{requests: 0, attempts: 0, ledger: 0, turns: 0, sessions: 0})
    assert FakeUpstream.count(upstream) == 0
  end

  test "websocket session creation rechecks the captured API key epoch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    scope = instance_owner_scope()
    payload = websocket_payload(setup.model.exposed_model_id, "session defense")

    opts =
      request_options(auth, payload, setup.model.exposed_model_id, "session-defense")
      |> RequestOptions.put_continuity(session_key: "session-defense")
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert opts.runtime.api_key_runtime_epoch == 0
    assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
    assert paused_key.runtime_revocation_epoch == 1

    assert {:error, %{code: :api_key_paused, disabling_epoch: 1}} =
             Websocket.start_codex_session(auth, opts)

    assert Repo.aggregate(CodexSession, :count) == 0
    assert FakeUpstream.count(upstream) == 0
  end

  test "pause after websocket claim terminalizes that claim without downstream work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    scope = instance_owner_scope()
    payload = websocket_payload(setup.model.exposed_model_id, "pause before reservation")
    ref = make_ref()

    task =
      start_gateway_task(auth, setup.model, payload, upstream, ref, {:reserve, :before})

    assert_receive {:runtime_authorization_barrier, ^ref, :reserve, :before, task_pid}
    assert task_pid == task.pid
    assert [%Request{status: "accepted"} = claim] = Repo.all(Request)
    assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
    assert paused_key.runtime_revocation_epoch == 1
    send(task.pid, {:runtime_authorization_release, ref})

    assert {:error, %{code: :api_key_paused, disabling_epoch: 1}} = Task.await(task, 15_000)

    assert %Request{
             id: claim_id,
             status: "rejected",
             usage_status: "not_applicable",
             last_error_code: "api_key_paused"
           } = Repo.one!(Request)

    assert claim_id == claim.id
    assert_runtime_counts(%{requests: 1, attempts: 0, ledger: 0, turns: 0, sessions: 0})
    assert FakeUpstream.count(upstream) == 0
  end

  test "a reservation that wins the API key lock completes once before pause" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_admitted123456789"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    scope = instance_owner_scope()
    payload = websocket_payload(setup.model.exposed_model_id, "pre-admitted work")
    ref = make_ref()

    task =
      start_gateway_task(auth, setup.model, payload, upstream, ref, {:reserve, :after})

    assert_receive {:runtime_authorization_barrier, ^ref, :reserve, :after, task_pid}
    assert task_pid == task.pid

    send(task.pid, {:runtime_authorization_release, ref})

    assert {:ok, result} = Task.await(task, 15_000)
    assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
    assert paused_key.runtime_revocation_epoch == 1
    assert result.status == 200
    request = Repo.one!(Request)
    assert request.status == "succeeded"
    assert_runtime_counts(%{requests: 1, attempts: 1, ledger: 3, turns: 0, sessions: 0})
    request_id = request.id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert FakeUpstream.count(upstream) == 1
  end

  for {failure_reason, status, retryable} <- [
        {:rollback, 503, true},
        {:invalid_transition, 500, false}
      ] do
    @tag failure_reason: failure_reason, failure_status: status, failure_retryable: retryable
    test "session-routable execution rejects a claimed turn after a #{failure_reason} rollback",
         %{failure_reason: failure_reason, failure_status: status, failure_retryable: retryable} do
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "pre-attempt rollback regression"}]
          }
        ],
        "stream" => true
      }

      request_options = request_options(auth, payload, setup.model.exposed_model_id)

      assert {:ok, prepared} =
               PreDispatch.prepare(auth, @endpoint, payload, request_options, setup.model)

      claim_attrs =
        AccountingReservation.attrs(
          auth,
          payload,
          @endpoint,
          prepared.request_options,
          prepared.route_state
        )

      assert {:ok, %{request: turn_claim}} =
               Accounting.claim_websocket_turn(auth, setup.model, claim_attrs)

      reserve_and_start_turn = fn
        received_auth,
        received_model,
        received_payload,
        received_endpoint,
        received_request_options,
        received_route_state,
        received_turn_claim,
        received_authorized_correlation_id ->
          assert received_auth == auth
          assert received_model.id == setup.model.id
          assert received_payload == payload
          assert received_endpoint == @endpoint
          assert received_request_options.transport.transport == "websocket"
          assert received_route_state == prepared.route_state
          assert received_turn_claim.id == turn_claim.id
          assert received_authorized_correlation_id == nil

          Repo.transaction(fn -> Repo.rollback(failure_reason) end)
      end

      log =
        capture_log(fn ->
          assert {:error,
                  %{
                    status: status,
                    code: "gateway_reservation_failed",
                    message: "gateway request reservation failed",
                    retryable: retryable
                  }} ==
                   Service.execute_session_routable_model(
                     %{
                       auth: auth,
                       endpoint: @endpoint,
                       payload: payload,
                       request_options: prepared.request_options,
                       model: setup.model,
                       candidates: prepared.candidates,
                       route_state: prepared.route_state,
                       turn_claim: turn_claim
                     },
                     reserve_and_start_turn
                   )
        end)

      assert log =~ "gateway pre-attempt reservation failed"
      assert log =~ "phase=pre_attempt"
      assert log =~ "operation=reserve_and_start_turn"
      assert log =~ "failure_code=gateway_reservation_failed"
      assert log =~ "status=#{status}"
      assert log =~ "request_id=pre-attempt-rollback"
      assert log =~ "failure_reason=#{failure_reason}"
      assert log =~ "retryable=#{retryable}"
      refute log =~ "finalization"
      refute log =~ "attempt_id=unknown"

      assert %Request{
               status: "rejected",
               response_status_code: ^status,
               last_error_code: "gateway_reservation_failed"
             } = Repo.reload!(turn_claim)

      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end
  end

  test "unknown pre-attempt failures stay non-retryable" do
    payload = %{"model" => "gpt-test"}

    request_options =
      RequestOptions.build(%{request_id: "pre-attempt-unknown"}, @endpoint, payload)

    capture_log(fn ->
      assert %{
               status: 500,
               code: "gateway_reservation_failed",
               message: "gateway request reservation failed",
               retryable: false
             } =
               AccountingReservation.pre_attempt_failure(
                 :unexpected_reservation_failure,
                 request_options
               )
    end)
  end

  test "pre-attempt reservation logs sanitize client-controlled request correlators" do
    payload = %{"model" => "gpt-test"}

    request_options =
      RequestOptions.build(%{request_id: "Bearer secret\nforged_field=value"}, @endpoint, payload)

    log =
      capture_log(fn ->
        assert %{code: "gateway_reservation_failed"} =
                 AccountingReservation.pre_attempt_failure(:rollback, request_options)
      end)

    assert log =~ "request_id=redacted"
    refute log =~ "Bearer secret"
    refute log =~ "forged_field=value"
  end

  defp request_options(auth, payload, model, request_id \\ "pre-attempt-rollback") do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    turn_claim_key =
      "codex-turn:" <>
        (:crypto.hash(:sha256, request_id) |> Base.url_encode64(padding: false))

    %{
      request_id: request_id,
      upstream_endpoint: @endpoint,
      transport: "websocket",
      turn_claim_key: turn_claim_key,
      request_claim_key: turn_claim_key
    }
    |> RequestOptions.build(@endpoint, payload)
    |> RequestOptions.put_routing(
      requested_model: model,
      effective_model: model,
      api_key_policy: policy
    )
  end

  defp websocket_payload(model, text) do
    %{
      "model" => model,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => text}]
        }
      ],
      "stream" => false
    }
  end

  defp start_gateway_task(auth, model, payload, _upstream, ref, phase) do
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Process.put({Reservation, :runtime_authorization_barrier}, {parent, ref, phase})
        Process.put({Service, :runtime_authorization_barrier}, {parent, ref, phase})

        Service.execute(
          auth,
          @endpoint,
          payload,
          request_options(auth, payload, model.exposed_model_id, "race-#{inspect(ref)}")
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)
    task
  end

  defp capture_query_order(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, :query_order, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and self() == parent do
            query = Map.get(metadata, :query, "")

            send(parent, {
              handler_id,
              %{
                source: metadata[:source],
                operation: query_operation(query),
                for_update?: String.contains?(String.upcase(query), "FOR UPDATE")
              }
            })
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_query_order(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_order(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_query_order(handler_id, events ++ [event])
    after
      0 -> events
    end
  end

  defp query_operation(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.upcase()
  end

  defp instance_owner_scope do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(owner, ["instance_owner"])
  end

  defp assert_runtime_counts(expected) do
    assert %{
             requests: Repo.aggregate(Request, :count),
             attempts: Repo.aggregate(Attempt, :count),
             ledger: Repo.aggregate(LedgerEntry, :count),
             turns: Repo.aggregate(CodexTurn, :count),
             sessions: Repo.aggregate(CodexSession, :count)
           } == expected
  end

  defp runtime_counts do
    %{
      requests: Repo.aggregate(Request, :count),
      attempts: Repo.aggregate(Attempt, :count),
      ledger: Repo.aggregate(LedgerEntry, :count),
      turns: Repo.aggregate(CodexTurn, :count),
      sessions: Repo.aggregate(CodexSession, :count),
      entitlements: Repo.aggregate(RequestReplayEntitlement, :count)
    }
  end

  defp expected_binding(auth, session, model) do
    %{
      api_key_id: auth.api_key.id,
      api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch,
      pool_id: auth.pool.id,
      codex_session_id: session.id,
      model_identifier: model.exposed_model_id
    }
  end
end
