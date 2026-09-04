defmodule CodexPooler.RequestReplayFixtures do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Accounting.{Attempt, DailyRollup, LedgerEntry, RequestReplayEntitlement}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Transports.Websocket.{RemoteReconnectControlV2, WebsocketOwnerSession}
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo

  def replay_fixture(opts \\ []) do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = pool_fixture(%{created_by_user_id: owner.id})

    %{api_key: api_key, raw_key: raw_key} =
      active_api_key_fixture(pool, %{created_by_user_id: owner.id})

    assert {:ok, auth} = CodexPooler.Access.authenticate_api_key(raw_key)
    %{assignment: assignment, identity: identity} = upstream_assignment_fixture(pool)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-replay-foundation",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    assert {:ok, %CodexSession{} = session} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    request =
      request_fixture(auth, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil
      })

    semantic_digest = <<1::256>>
    replay_claim_digest = <<2::256>>

    request_options =
      RequestOptions.for_websocket(%{})
      |> RequestOptions.put_continuity(semantic_turn_key: semantic_digest)

    assert {:ok, turn} = SessionContinuity.start_codex_turn(session, request, request_options)

    attempt =
      attempt_fixture(request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })

    attempt = attempt |> Ecto.Changeset.change(%{model_id: model.id}) |> Repo.update!()

    session = Repo.reload!(session)
    owner_lease_token = session.owner_lease_token

    if Keyword.get(opts, :reservation?, false) do
      reservation =
        ledger_entry_fixture(request, %{
          entry_kind: "reservation",
          amount_status: "recorded",
          usage_status: "usage_pending",
          attempt_id: nil,
          pool_upstream_assignment_id: assignment.id,
          upstream_identity_id: assignment.upstream_identity_id,
          model_id: model.id
        })

      reservation
      |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
      |> Repo.update!()
    end

    preflight = %{
      codex_session_id: session.id,
      api_key_id: api_key.id,
      api_key_runtime_epoch: api_key.runtime_revocation_epoch,
      pool_id: pool.id,
      model_id: model.id,
      model_identifier: model.exposed_model_id,
      semantic_turn_digest: semantic_digest,
      replay_claim_digest: replay_claim_digest
    }

    %{
      api_key: api_key,
      auth: auth,
      assignment: assignment,
      attempt: attempt,
      identity: identity,
      model: model,
      owner_lease_token: owner_lease_token,
      pool: pool,
      preflight: preflight,
      replay_claim_digest: replay_claim_digest,
      request: request,
      scope: scope,
      semantic_digest: semantic_digest,
      session: session,
      turn: turn
    }
  end

  def arm_input(fixture) do
    %{
      api_key_id: fixture.api_key.id,
      pool_id: fixture.pool.id,
      codex_session_id: fixture.session.id,
      request_id: fixture.request.id,
      codex_turn_id: fixture.turn.id,
      eligible_attempt_id: fixture.attempt.id,
      api_key_runtime_epoch: fixture.api_key.runtime_revocation_epoch,
      model_id: fixture.model.id,
      model_identifier: fixture.model.exposed_model_id,
      endpoint: fixture.request.endpoint,
      semantic_turn_digest: fixture.semantic_digest,
      replay_claim_digest: fixture.replay_claim_digest,
      owner_instance_id: fixture.session.owner_instance_id,
      owner_lease_token: fixture.owner_lease_token,
      predecessor_epoch: 1,
      failure_reason: :client_disconnected,
      pre_visible_output: true
    }
  end

  def consume_input(fixture, armed, token, timeout_ms \\ 5_000) do
    consume_input = %{
      auth: fixture.auth,
      entitlement_id: armed.entitlement_id,
      request_id: fixture.request.id,
      codex_turn_id: fixture.turn.id,
      eligible_attempt_id: fixture.attempt.id,
      replay_generation: 1,
      provisional_token: token,
      owner_lease_token: fixture.owner_lease_token,
      reserve_timeout_ms: timeout_ms,
      owner_forwarder_opts: [],
      downstream_epoch: 2,
      owner_process_generation: 1
    }

    put_reserve_receipt(consume_input, timeout_ms, fixture, armed)
  end

  def put_reserve_receipt(input, timeout_ms, fixture, armed) do
    owner = install_reserved_replay_owner(fixture, armed, input.provisional_token, timeout_ms)

    {:ok, :consume_reserved, ^timeout_ms, receipt, digest} =
      WebsocketOwnerSession.reconnect_control_v2(
        owner,
        reserve_control(fixture, input.provisional_token)
      )

    input
    |> Map.put(:reserve_timeout_ms, timeout_ms)
    |> Map.put(:reserve_receipt, receipt)
    |> Map.put(:reserve_receipt_digest, digest)
    |> Map.delete(:reserve_owner)
    |> Map.put(:owner_process_generation, :sys.get_state(owner).process_generation)
  end

  def install_reserved_replay_owner(fixture, armed, token, timeout_ms) do
    stop_replay_owner(fixture.session.id)

    {:ok, owner} =
      WebsocketOwnerSession.start_owner(
        codex_session_id: fixture.session.id,
        owner_lease_token: fixture.owner_lease_token,
        owner_instance_id: fixture.session.owner_instance_id,
        owner_renewal_ms: 60_000,
        handoff_absolute_timeout_ms: 60_000,
        monotonic_now_ms: fn -> 10_000 end,
        upstream: replay_owner_upstream(),
        persistence: replay_owner_persistence()
      )

    downstream = %{pid: self(), epoch: 2, correlation_id: "request-replay-reserve"}
    owner_state = :sys.get_state(owner)

    :sys.replace_state(owner, fn state ->
      suspended = %{
        semantic_turn_digest: fixture.semantic_digest,
        replay_claim_digest: fixture.replay_claim_digest,
        authorization_snapshot: %{},
        replay_generation: 1,
        downstream: downstream,
        predecessor_epoch: 1,
        owner_process_generation: owner_state.process_generation,
        provisional_token: token,
        provisional_status: :provisional,
        deadline_ms: 10_000 + timeout_ms,
        consume_binding: nil,
        reserve_timeout_ms: nil,
        reserve_receipt: nil,
        reserve_receipt_digest: nil,
        reserve_receipt_used?: false,
        consume_fence: nil,
        consume_pid: nil,
        consume_monitor: nil,
        reconciliation_timer_ref: nil,
        reconciliation_token: nil,
        lifecycle: %{
          entitlement_id: armed.entitlement_id,
          request_id: fixture.request.id,
          codex_turn_id: fixture.turn.id,
          eligible_attempt_id: fixture.attempt.id,
          owner_lease_digest: armed.owner_lease_digest
        }
      }

      %{state | downstream: downstream, downstream_epoch: 2, suspended_replay: suspended}
    end)

    on_exit(fn -> stop_replay_owner(fixture.session.id) end)
    owner
  end

  def reserve_control(fixture, token) do
    {:ok, control} =
      RemoteReconnectControlV2.new(%{
        version: 2,
        action: :provisional_reserve,
        intent: :suspended_replay,
        codex_session_id: fixture.session.id,
        downstream: %{pid: self(), epoch: 2, correlation_id: "request-replay-reserve"},
        semantic_turn_digest: fixture.semantic_digest,
        replay_claim_digest: fixture.replay_claim_digest,
        provisional_token: token,
        replay_generation: 1,
        owner_lease_token: fixture.owner_lease_token,
        control_ref: make_ref(),
        authorization_binding: nil,
        consume_binding: nil
      })

    control
  end

  def replay_owner_upstream do
    %{
      start: fn -> Agent.start_link(fn -> 0 end) end,
      send: fn pid, _request, _writer ->
        Agent.update(pid, &(&1 + 1))
        {:error, :unexpected_send}
      end,
      close: fn pid -> Agent.stop(pid, :normal) end
    }
  end

  def replay_owner_persistence do
    %{
      renew_owner_token: fn _, token, _ ->
        {:ok, %{owner_lease_token: token, owner_instance_id: Atom.to_string(node())}}
      end,
      release_owner_lease: fn _, _, _, _ -> :ok end,
      interrupt_codex_session: fn _, _ -> :ok end
    }
  end

  def stop_replay_owner(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner} ->
        monitor = Process.monitor(owner)
        GenServer.stop(owner, :normal, 15_000)
        assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}, 15_000

      {:error, :owner_unavailable} ->
        :ok
    end
  end

  def insert_entitlement!(fixture, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture.attempt
    |> Ecto.Changeset.change(%{
      status: "retryable_failed",
      completed_at: now,
      upstream_status_code: nil,
      retryable: true,
      network_error_code: "client_disconnected",
      usage_status: "usage_unknown"
    })
    |> Repo.update!()

    base = %{
      request_id: fixture.request.id,
      codex_turn_id: fixture.turn.id,
      eligible_attempt_id: fixture.attempt.id,
      api_key_id: fixture.api_key.id,
      api_key_runtime_epoch: fixture.api_key.runtime_revocation_epoch,
      pool_id: fixture.pool.id,
      model_id: fixture.model.id,
      model_identifier: fixture.model.exposed_model_id,
      semantic_turn_digest: fixture.semantic_digest,
      replay_claim_digest: fixture.replay_claim_digest,
      replay_generation: 1,
      owner_lease_digest: <<3::256>>,
      owner_lease_key_version: "test-v1",
      predecessor_epoch: 1,
      status: "armed",
      armed_at: now,
      expires_at: DateTime.add(now, 30, :second)
    }

    %RequestReplayEntitlement{}
    |> RequestReplayEntitlement.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  def set_replay_db_now!(%DateTime{} = now) do
    timestamp = DateTime.to_iso8601(now)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.request_replay_db_now()
    RETURNS timestamp with time zone
    LANGUAGE sql
    STABLE
    AS 'SELECT ''#{timestamp}''::timestamp with time zone'
    """)
  end

  def counts do
    %{
      entitlements: Repo.aggregate(RequestReplayEntitlement, :count),
      requests: Repo.aggregate(CodexPooler.Accounting.Request, :count),
      attempts: Repo.aggregate(CodexPooler.Accounting.Attempt, :count),
      turns: Repo.aggregate(CodexPooler.Gateway.Persistence.CodexTurn, :count)
    }
  end

  def request_attempt_count(request_id) do
    Repo.aggregate(from(row in Attempt, where: row.request_id == ^request_id), :count)
  end

  def terminal_ledger_count(request_id, kind) do
    Repo.aggregate(
      from(row in LedgerEntry, where: row.request_id == ^request_id and row.entry_kind == ^kind),
      :count
    )
  end

  def rollup_request_count(request) do
    Repo.one!(
      from rollup in DailyRollup,
        where:
          rollup.dimension_kind == "pool" and rollup.pool_id == ^request.pool_id and
            rollup.rollup_date == ^DateTime.to_date(request.admitted_at),
        select: rollup.request_count
    )
  end
end
