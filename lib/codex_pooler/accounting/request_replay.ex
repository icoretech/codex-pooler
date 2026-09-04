defmodule CodexPooler.Accounting.RequestReplay do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}

  alias CodexPooler.Accounting.{
    Attempt,
    LedgerEntry,
    Request,
    RequestLifecycle,
    RequestReplayEntitlement
  }

  alias CodexPooler.Accounting.RequestLifecycle.ReferenceLocks
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @digest_bytes 32
  @entitlement_seconds 30
  @cleanup_batch_size 100
  @owner_witness_timeout_ms 100

  @type arm_input :: map()
  @type consume_input :: map()

  @spec arm(arm_input()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def arm(input) when is_map(input) do
    with :ok <- validate_arm_input(input) do
      Repo.transaction(fn -> arm_locked(input) end)
    end
  rescue
    Ecto.ConstraintError -> {:error, :already_armed}
    Ecto.NoResultsError -> {:error, :ineligible}
  end

  def arm(_input), do: {:error, :invalid_input}

  @spec consume(consume_input()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def consume(input) when is_map(input) do
    with :ok <- validate_consume_input(input),
         %CodexSession{} = session <- reserve_session_snapshot(input),
         {:ok, consume_fence} <- consume_owner_reserve(session, input) do
      finish_consume(input, session, consume_fence)
    else
      nil -> {:error, :owner_unavailable}
      error -> error
    end
  end

  def consume(_input), do: {:error, :invalid_input}

  defp finish_consume(input, session, consume_fence) do
    :ok = maybe_wait_after_owner_reserve()

    case validate_owner_reserve(session, input, consume_fence) do
      :ok ->
        consume_transaction(input, session, consume_fence)

      {:error, _reason} = error ->
        _release = release_owner_reserve(session, input, consume_fence)
        error
    end
  end

  if Mix.env() == :test do
    defp maybe_wait_after_owner_reserve do
      case Application.get_env(:codex_pooler, :request_replay_consume_test_barrier) do
        {test_pid, barrier_ref} when is_pid(test_pid) and is_reference(barrier_ref) ->
          send(test_pid, {:request_replay_owner_reserve_redeemed, self(), barrier_ref})

          receive do
            {:release_request_replay_consume, ^barrier_ref} -> :ok
          end

        _no_barrier ->
          :ok
      end
    end
  else
    defp maybe_wait_after_owner_reserve, do: :ok
  end

  @spec mark_started(provisional_reference()) ::
          {:ok, RequestReplayEntitlement.t()} | {:error, atom()}
  def mark_started(reference) when is_map(reference) do
    with :ok <- validate_provisional_reference(reference) do
      Repo.transaction(fn -> mark_started_locked(reference) end)
    end
  end

  def mark_started(_reference), do: {:error, :invalid_input}

  @spec compensate_no_send(provisional_reference()) :: {:ok, map()} | {:error, atom()}
  def compensate_no_send(reference) when is_map(reference) do
    with :ok <- validate_provisional_reference(reference) do
      Repo.transaction(fn -> compensate_no_send_locked(reference) end)
    end
  end

  def compensate_no_send(_reference), do: {:error, :invalid_input}

  @type close_reason ::
          :expired | :revoked | :deleted | :abandoned | :owner_unavailable | :owner_shutdown

  @type owner_snapshot :: %{
          required(:owner_instance_id) => String.t(),
          required(:owner_lease_token) => Ecto.UUID.t(),
          required(:owner_lease_expires_at) => DateTime.t()
        }

  @spec close(Ecto.UUID.t(), close_reason()) :: {:ok, :closed | :noop} | {:error, term()}
  def close(request_id, reason)
      when is_binary(request_id) and
             reason in [
               :expired,
               :revoked,
               :deleted,
               :abandoned,
               :owner_unavailable,
               :owner_shutdown
             ] do
    Repo.transaction(fn -> close_locked(request_id, reason) end)
  end

  def close(_request_id, _reason), do: {:error, :invalid_input}

  @doc false
  @spec close(Ecto.UUID.t(), close_reason(), DateTime.t()) ::
          {:ok, :closed | :noop} | {:error, term()}
  def close(request_id, reason, %DateTime{} = witness_now)
      when is_binary(request_id) and reason in [:abandoned, :owner_unavailable] do
    Repo.transaction(fn -> close_locked(request_id, reason, witness_now) end)
  end

  @spec touch_liveness(provisional_reference()) ::
          {:ok, RequestReplayEntitlement.t()} | {:error, :binding_mismatch}
  def touch_liveness(reference) when is_map(reference) do
    case validate_provisional_reference(reference) do
      :ok -> Repo.transaction(fn -> touch_liveness_locked(reference) end)
      {:error, _reason} -> {:error, :binding_mismatch}
    end
  end

  def touch_liveness(_reference), do: {:error, :binding_mismatch}

  @spec cleanup_due() :: {:ok, map()} | {:error, term()}
  def cleanup_due do
    started_at = System.monotonic_time(:millisecond)
    now = db_now()
    candidates = due_candidates(now)

    summary = %{
      replay_entitlements_selected: length(candidates),
      replay_entitlements_closed: 0,
      replay_entitlements_noop: 0,
      replay_entitlements_deferred: 0,
      replay_cleanup_batch_full: length(candidates) == @cleanup_batch_size
    }

    Enum.reduce_while(candidates, {:ok, summary}, &cleanup_next(&1, &2, started_at))
  end

  defp cleanup_next({request_id, reason}, {:ok, summary}, started_at) do
    if System.monotonic_time(:millisecond) - started_at >= 30_000 do
      {:halt, {:ok, Map.put(summary, :replay_cleanup_budget_exhausted, true)}}
    else
      reason = cleanup_close_reason(request_id, reason)
      accumulate_cleanup(cleanup_candidate(request_id, reason), summary)
    end
  end

  defp accumulate_cleanup({:ok, disposition}, summary) do
    key =
      case disposition do
        :closed -> :replay_entitlements_closed
        :noop -> :replay_entitlements_noop
        :deferred -> :replay_entitlements_deferred
      end

    {:cont, {:ok, Map.update!(summary, key, &(&1 + 1))}}
  end

  defp accumulate_cleanup({:error, reason}, _summary), do: {:halt, {:error, reason}}

  defp cleanup_candidate(request_id, reason) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '100ms'", [])
      close_locked(request_id, reason, nil, true)
    end)
  rescue
    exception in Postgrex.Error ->
      if exception.postgres[:code] == :lock_not_available,
        do: {:ok, :deferred},
        else: reraise(exception, __STACKTRACE__)
  end

  @spec close_for_session(Ecto.UUID.t(), Ecto.UUID.t() | owner_snapshot(), close_reason()) ::
          {:ok, map() | :stale_owner} | {:error, term()}
  def close_for_session(session_id, owner_snapshot, reason)
      when is_binary(session_id) and is_map(owner_snapshot) and
             reason in [:abandoned, :owner_unavailable, :owner_shutdown] do
    Repo.transaction(fn ->
      close_session_replays_locked(session_id, owner_snapshot, reason)
    end)
  end

  def close_for_session(session_id, owner_lease_token, reason)
      when is_binary(session_id) and is_binary(owner_lease_token) and
             reason in [:abandoned, :owner_unavailable, :owner_shutdown] do
    Repo.transaction(fn ->
      close_session_replays_locked(
        session_id,
        %{owner_lease_token: owner_lease_token},
        reason
      )
    end)
  end

  def close_for_session(_session_id, _owner_lease_token, _reason),
    do: {:error, :invalid_input}

  @spec request_ids_for_api_key(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def request_ids_for_api_key(api_key_id) when is_binary(api_key_id) do
    Repo.all(
      from entitlement in RequestReplayEntitlement,
        where: entitlement.api_key_id == ^api_key_id and is_nil(entitlement.closed_at),
        order_by: [asc: entitlement.request_id],
        select: entitlement.request_id
    )
  end

  def request_ids_for_api_key(_api_key_id), do: []

  @spec dispatch_lifecycle(provisional_reference()) :: {:ok, map()} | {:error, atom()}
  def dispatch_lifecycle(reference) when is_map(reference) do
    with :ok <- validate_provisional_reference(reference) do
      Repo.transaction(fn -> dispatch_lifecycle_locked(reference) end)
      |> case do
        {:ok, lifecycle} -> {:ok, lifecycle}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def dispatch_lifecycle(_reference), do: {:error, :invalid_input}

  defp dispatch_lifecycle_locked(reference) do
    request_snapshot = request_snapshot!(reference.request_id)
    session = lock_session!(request_session_id!(request_snapshot))
    api_key = lock_api_key!(request_snapshot.api_key_id)
    turn = lock_turn!(reference.codex_turn_id)
    request = lock_request!(reference.request_id)
    attempt = lock_latest_attempt!(reference.request_id)
    entitlement = lock_entitlement(reference.request_id)
    ledger = lock_ledger!(reference.request_id)

    reservation =
      Enum.find(ledger, &(&1.source_event_id == "request:#{reference.request_id}:reservation")) ||
        Repo.rollback(:ineligible)

    %{assignment: assignment} =
      ReferenceLocks.lock_and_validate!(
        attempt.upstream_identity_id,
        attempt.pool_upstream_assignment_id
      )

    now = db_now()

    if current_replay_authorization?(api_key, entitlement) and
         future?(entitlement.abandon_at, now) and live_owner_binding?(session, entitlement, now) and
         dispatch_lifecycle_matches?(session, turn, request, assignment) and
         attempt_assignment_matches?(attempt, assignment, request.model_id) and
         open_consumed_reference?(entitlement, reference) and
         live_replay_attempt?(attempt, reference) do
      %{
        request: request,
        codex_turn: turn,
        attempt: attempt,
        reservation: reservation,
        assignment: assignment,
        entitlement: entitlement,
        consume_binding: reference
      }
    else
      Repo.rollback(:ineligible)
    end
  end

  defp dispatch_lifecycle_matches?(session, turn, request, assignment) do
    session.id == turn.codex_session_id and request.id == turn.request_id and
      assignment.pool_id == request.pool_id
  end

  @type preflight_input :: %{
          required(:codex_session_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:api_key_runtime_epoch) => non_neg_integer(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:model_id) => Ecto.UUID.t(),
          required(:model_identifier) => String.t(),
          required(:semantic_turn_digest) => <<_::256>>,
          required(:replay_claim_digest) => <<_::256>>
        }

  @type provisional_reference :: %{
          required(:request_id) => Ecto.UUID.t(),
          required(:codex_turn_id) => Ecto.UUID.t(),
          required(:eligible_attempt_id) => Ecto.UUID.t(),
          required(:replay_attempt_id) => Ecto.UUID.t() | nil,
          required(:replay_generation) => 1,
          required(:provisional_binding_digest) => <<_::256>> | nil,
          required(:owner_lease_digest) => <<_::256>>
        }

  @spec preflight_snapshot(preflight_input()) ::
          :none
          | {:active_generation_zero, map()}
          | {:armed_generation_one, map()}
          | {:error,
             :invalid_input
             | :replay_claim_mismatch
             | :authorization_binding_mismatch
             | :lifecycle_conflict}
  def preflight_snapshot(input) when is_map(input) do
    with :ok <- validate_preflight_input(input) do
      input
      |> active_semantic_lifecycle()
      |> classify_preflight(input)
    end
  end

  def preflight_snapshot(_input), do: {:error, :invalid_input}

  @spec provisional_binding_status(provisional_reference()) ::
          :armed
          | {:consumed, map(), :committed_not_started | :started, DateTime.t()}
          | :terminal
          | :absent
          | {:error, :invalid_input | :binding_mismatch}
  def provisional_binding_status(reference) when is_map(reference) do
    with :ok <- validate_provisional_reference(reference) do
      reference.request_id
      |> entitlement_by_request_id()
      |> classify_provisional(reference)
    end
  end

  def provisional_binding_status(_reference), do: {:error, :invalid_input}

  @spec provisional_token_status(map()) ::
          :armed
          | {:consumed, map(), atom(), DateTime.t()}
          | :terminal
          | :absent
          | {:error, atom()}
  def provisional_token_status(%{
        request_id: request_id,
        codex_turn_id: codex_turn_id,
        eligible_attempt_id: eligible_attempt_id,
        replay_generation: 1,
        owner_lease_digest: owner_lease_digest,
        provisional_token: provisional_token
      })
      when is_binary(provisional_token) and byte_size(provisional_token) == @digest_bytes do
    case entitlement_by_request_id(request_id) do
      nil ->
        :absent

      entitlement ->
        reference = %{
          request_id: request_id,
          codex_turn_id: codex_turn_id,
          eligible_attempt_id: eligible_attempt_id,
          replay_attempt_id: entitlement.replay_attempt_id,
          replay_generation: 1,
          provisional_binding_digest: entitlement.provisional_binding_digest,
          owner_lease_digest: owner_lease_digest
        }

        classify_token(entitlement, reference, provisional_token)
    end
  end

  def provisional_token_status(_reference), do: {:error, :invalid_input}

  defp classify_token(entitlement, reference, provisional_token) do
    cond do
      not provisional_identity_match?(entitlement, reference) ->
        {:error, :binding_mismatch}

      entitlement.status == "armed" ->
        :armed

      entitlement.status == "consumed" and
          RequestReplayEntitlement.verify_provisional_binding(
            provisional_token,
            entitlement.owner_lease_key_version,
            entitlement.provisional_binding_digest
          ) ->
        consumed_status(entitlement, reference)

      entitlement.status in ["expired", "revoked"] ->
        :terminal

      true ->
        {:error, :binding_mismatch}
    end
  end

  defp arm_locked(input) do
    session = lock_session!(input.codex_session_id)
    api_key = lock_api_key!(input.api_key_id)
    turn = lock_turn!(input.codex_turn_id)
    request = lock_request!(input.request_id)
    attempt = lock_latest_attempt!(input.request_id)
    existing = lock_entitlement(input.request_id)
    _ledger = lock_ledger!(input.request_id)

    %{assignment: assignment} =
      ReferenceLocks.lock_and_validate!(
        attempt.upstream_identity_id,
        attempt.pool_upstream_assignment_id
      )

    if existing, do: Repo.rollback(:already_armed)

    if assignment.pool_id != request.pool_id or attempt.model_id != request.model_id,
      do: Repo.rollback(:ineligible)

    owner_lease = lock_active_owner_lease!(session.id)
    now = db_now()

    with :ok <-
           validate_arm_rows(input, session, api_key, turn, request, attempt, owner_lease, now),
         {:ok, owner_lease_digest} <-
           RequestReplayEntitlement.owner_lease_digest(input.owner_lease_token) do
      attempt =
        attempt
        |> Ecto.Changeset.change(%{
          status: "retryable_failed",
          completed_at: now,
          upstream_status_code: nil,
          retryable: true,
          network_error_code: "client_disconnected",
          usage_status: "usage_unknown"
        })
        |> Repo.update!()

      {:ok, owner_lease_key_version} = configured_key_version()

      entitlement =
        %RequestReplayEntitlement{}
        |> RequestReplayEntitlement.changeset(%{
          request_id: request.id,
          codex_turn_id: turn.id,
          eligible_attempt_id: attempt.id,
          api_key_id: api_key.id,
          api_key_runtime_epoch: api_key.runtime_revocation_epoch,
          pool_id: request.pool_id,
          model_id: request.model_id,
          model_identifier: request.requested_model,
          semantic_turn_digest: turn.semantic_turn_digest,
          replay_claim_digest: input.replay_claim_digest,
          replay_generation: 1,
          owner_lease_digest: owner_lease_digest,
          owner_lease_key_version: owner_lease_key_version,
          predecessor_epoch: input.predecessor_epoch,
          status: "armed",
          armed_at: now,
          expires_at: DateTime.add(now, @entitlement_seconds, :second)
        })
        |> Repo.insert!()

      entitlement_snapshot(entitlement)
    else
      {:error, :terminal_won} -> Repo.rollback(:terminal_won)
      {:error, _reason} -> Repo.rollback(:ineligible)
    end
  end

  defp consume_transaction(input, reserved_session, consume_fence) do
    case Repo.transaction(fn -> consume_locked(input, reserved_session, consume_fence) end) do
      {:ok, result} ->
        {:ok, result}

      {:error, _reason} = error ->
        _release = release_owner_reserve(reserved_session, input, consume_fence)
        error
    end
  rescue
    Ecto.NoResultsError ->
      _release = release_owner_reserve(reserved_session, input, consume_fence)
      {:error, :ineligible}
  end

  defp consume_locked(input, reserved_session, consume_fence) do
    session = lock_session!(request_session_id!(input.request_id))
    api_key = lock_api_key!(input.auth.api_key.id)
    turn = lock_turn!(input.codex_turn_id)
    request = lock_request!(input.request_id)
    attempt = lock_latest_attempt!(input.request_id)
    entitlement = lock_entitlement(input.request_id)
    _ledger = lock_ledger!(input.request_id)
    owner_lease = lock_active_owner_lease!(session.id)
    pool = lock_pool!(input.auth.pool.id)
    _policy_bindings = lock_api_key_policy_bindings!(api_key.id)
    now = db_now()

    with :ok <-
           validate_consume_rows(
             input,
             %{
               session: session,
               api_key: api_key,
               turn: turn,
               request: request,
               attempt: attempt,
               entitlement: entitlement,
               owner_lease: owner_lease,
               pool: pool
             },
             now
           ),
         {:ok, provisional_digest} <-
           RequestReplayEntitlement.provisional_binding_digest(input.provisional_token),
         {:ok, reserve_receipt_digest} <-
           RequestReplayEntitlement.reserve_receipt_digest(
             input.provisional_token,
             input.reserve_receipt,
             input.reserve_timeout_ms
           ),
         true <- secure_digest_match?(reserve_receipt_digest, input.reserve_receipt_digest),
         :ok <- validate_owner_reserve_snapshot(session, reserved_session, consume_fence),
         %Model{} = model <- lock_model(input.auth.pool.id, entitlement.model_id),
         %{
           assignment: %PoolUpstreamAssignment{} = assignment,
           identity: %UpstreamIdentity{} = identity
         } <-
           ReferenceLocks.lock_and_validate!(
             attempt.upstream_identity_id,
             attempt.pool_upstream_assignment_id
           ),
         :ok <-
           authorize_exact_assignment(
             api_key,
             request,
             attempt,
             assignment,
             identity,
             model
           ),
         now <- db_now(),
         true <- future?(entitlement.expires_at, now),
         true <- future?(session.owner_lease_expires_at, now),
         true <- future?(owner_lease.expires_at, now) do
      replay_attempt = insert_replay_attempt!(request, attempt, provisional_digest, now)

      entitlement =
        entitlement
        |> RequestReplayEntitlement.changeset(%{
          status: "consumed",
          replay_attempt_id: replay_attempt.id,
          provisional_binding_digest: provisional_digest,
          consumed_at: now,
          abandon_at: DateTime.add(now, input.reserve_timeout_ms, :millisecond)
        })
        |> Repo.update!()

      %{
        request: request,
        turn: turn,
        attempt: replay_attempt,
        entitlement: entitlement,
        assignment: assignment,
        consume_binding: consume_binding(entitlement),
        downstream_epoch: input.downstream_epoch,
        owner_process_generation: input.owner_process_generation
      }
    else
      {:error, reason} -> Repo.rollback(reason)
      nil -> Repo.rollback(:ineligible)
      false -> Repo.rollback(:ineligible)
    end
  end

  defp mark_started_locked(reference) do
    liveness_grace_ms = replay_liveness_grace_ms()

    request_snapshot = request_snapshot!(reference.request_id)
    session = lock_session!(request_session_id!(reference.request_id))
    api_key = lock_api_key!(request_snapshot.api_key_id)
    _turn = lock_turn!(reference.codex_turn_id)
    _request = lock_request!(reference.request_id)
    attempt = lock_latest_attempt!(reference.request_id)
    entitlement = lock_entitlement(reference.request_id)
    _ledger = lock_ledger!(reference.request_id)
    now = db_now()

    if current_replay_authorization?(api_key, entitlement) and
         consumed_binding_matches?(entitlement, reference) and
         future?(entitlement.abandon_at, now) and live_owner_binding?(session, entitlement, now) and
         live_replay_attempt?(attempt, reference) and is_nil(attempt.completed_at) do
      if entitlement.started_at do
        entitlement
      else
        entitlement
        |> RequestReplayEntitlement.changeset(%{
          started_at: now,
          last_liveness_at: now,
          abandon_at: DateTime.add(now, liveness_grace_ms, :millisecond)
        })
        |> Repo.update!()
      end
    else
      Repo.rollback(:binding_mismatch)
    end
  end

  defp compensate_no_send_locked(reference) do
    request_snapshot = request_snapshot!(reference.request_id)
    _session = lock_session!(request_session_id!(reference.request_id))
    _api_key = lock_api_key!(request_snapshot.api_key_id)
    turn = lock_turn!(reference.codex_turn_id)
    request = lock_request!(reference.request_id)
    attempt = lock_latest_attempt!(reference.request_id)
    entitlement = lock_entitlement(reference.request_id)
    _ledger = lock_ledger!(reference.request_id)
    now = db_now()

    if consumed_binding_matches?(entitlement, reference) and is_nil(entitlement.started_at) do
      case RequestLifecycle.finalize_request_with_disposition(request, attempt, %{
             request_status: "failed",
             attempt_status: "failed",
             response_status_code: 499,
             last_error_code: "websocket_replay_abandoned",
             usage: %{status: "usage_unknown", source: "websocket_replay_abandoned"},
             now: now
           }) do
        {:ok, result} ->
          close_turn!(turn, attempt.id, "websocket_replay_abandoned", now)
          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      Repo.rollback(:binding_mismatch)
    end
  end

  defp close_locked(request_id, reason) do
    close_locked(request_id, reason, nil)
  end

  defp close_locked(request_id, reason, witness_now, cleanup? \\ false) do
    case request_snapshot(request_id) do
      nil ->
        :noop

      request_snapshot ->
        session = lock_session!(request_session_id!(request_id))
        api_key = lock_api_key!(request_snapshot.api_key_id)
        turn = lock_turn_by_request!(request_id)
        request = lock_request!(request_id)
        attempt = lock_latest_attempt!(request_id)
        entitlement = lock_entitlement(request_id)
        _ledger = lock_ledger!(request_id)
        now = witness_now || db_now()

        result =
          close_replay_lifecycle(
            session,
            api_key,
            turn,
            request,
            attempt,
            entitlement,
            reason,
            now
          )

        if (cleanup? and result == :noop and entitlement) && is_nil(entitlement.closed_at) do
          entitlement
          |> RequestReplayEntitlement.changeset(%{cleanup_checked_at: now})
          |> Repo.update!()
        end

        result
    end
  end

  defp close_replay_lifecycle(_session, _api_key, _turn, _request, _attempt, nil, _reason, _now),
    do: :noop

  defp close_replay_lifecycle(session, api_key, turn, request, attempt, entitlement, reason, now) do
    case close_kind(session, entitlement, api_key, reason, now) do
      {:armed, terminal_status, error_code} ->
        finalize_close!(
          {session, turn, request, attempt, entitlement},
          terminal_status,
          error_code,
          now,
          preserve_attempt?: true
        )

      {:consumed, error_code} ->
        finalize_close!({session, turn, request, attempt, entitlement}, nil, error_code, now,
          preserve_attempt?: false
        )

      :noop ->
        :noop
    end
  end

  defp close_kind(
         _session,
         %RequestReplayEntitlement{closed_at: %DateTime{}},
         _api_key,
         _reason,
         _now
       ),
       do: :noop

  defp close_kind(_session, %RequestReplayEntitlement{status: status}, _api_key, _reason, _now)
       when status in ["expired", "revoked"],
       do: :noop

  defp close_kind(
         _session,
         %RequestReplayEntitlement{status: "armed"} = entitlement,
         _api_key,
         :expired,
         now
       ) do
    if DateTime.compare(entitlement.expires_at, now) != :gt,
      do: {:armed, "expired", "websocket_replay_expired"},
      else: :noop
  end

  defp close_kind(_session, %RequestReplayEntitlement{status: "armed"}, _api_key, :deleted, _now),
    do: {:armed, "revoked", "websocket_replay_revoked"}

  defp close_kind(
         _session,
         %RequestReplayEntitlement{status: "armed"},
         _api_key,
         :owner_shutdown,
         _now
       ),
       do: {:armed, "revoked", "websocket_replay_revoked"}

  defp close_kind(
         _session,
         %RequestReplayEntitlement{status: "consumed"},
         _api_key,
         :deleted,
         _now
       ),
       do: {:consumed, "websocket_replay_owner_unavailable"}

  defp close_kind(
         _session,
         %RequestReplayEntitlement{status: "consumed"},
         _api_key,
         :owner_shutdown,
         _now
       ),
       do: {:consumed, "websocket_replay_owner_unavailable"}

  defp close_kind(
         _session,
         %RequestReplayEntitlement{status: "armed"} = entitlement,
         api_key,
         :revoked,
         _now
       ) do
    if api_key.status != "active" or
         api_key.runtime_revocation_epoch != entitlement.api_key_runtime_epoch,
       do: {:armed, "revoked", "websocket_replay_revoked"},
       else: :noop
  end

  defp close_kind(
         session,
         %RequestReplayEntitlement{status: "consumed"} = entitlement,
         _api_key,
         reason,
         now
       )
       when reason in [:abandoned, :owner_unavailable] do
    if consumed_close_due?(session, entitlement, reason, now) do
      error_code =
        if reason == :owner_unavailable,
          do: "websocket_replay_owner_unavailable",
          else: "websocket_replay_abandoned"

      {:consumed, error_code}
    else
      :noop
    end
  end

  defp close_kind(_session, _entitlement, _api_key, _reason, _now), do: :noop

  defp consumed_close_due?(_session, %{abandon_at: abandon_at}, _reason, _now)
       when not is_struct(abandon_at, DateTime),
       do: false

  defp consumed_close_due?(session, entitlement, reason, now) do
    due? = DateTime.compare(entitlement.abandon_at, now) != :gt

    if is_nil(entitlement.started_at) do
      due?
    else
      due? and
        (reason == :owner_unavailable or not live_owner_binding?(session, entitlement, now))
    end
  end

  defp finalize_close!(
         {session, turn, request, attempt, entitlement},
         terminal_status,
         error_code,
         now,
         preserve_attempt?: preserve_attempt?
       ) do
    valid? =
      close_lifecycle_open?(session, turn, request) and
        replay_close_attempt?(attempt, entitlement, preserve_attempt?)

    if valid? do
      attrs = %{
        request_status: "failed",
        attempt_status: "failed",
        response_status_code: 499,
        last_error_code: error_code,
        retryable: false,
        usage: %{status: "usage_unknown", source: error_code},
        now: now,
        preserve_replay_attempt: preserve_attempt?,
        replay_entitlement_close_status: terminal_status
      }

      case RequestLifecycle.finalize_request_with_disposition(request, attempt, attrs) do
        {:ok, %{finalization_disposition: :inserted}} ->
          close_turn!(turn, attempt.id, error_code, now)
          :closed

        {:ok, %{finalization_disposition: disposition}}
        when disposition in [:reused, :replaced] ->
          close_turn!(turn, attempt.id, error_code, now)
          :noop

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      :noop
    end
  end

  defp close_lifecycle_open?(session, turn, request) do
    turn.codex_session_id == session.id and turn.request_id == request.id and
      request.status == "in_progress" and request.usage_status == "usage_pending" and
      is_nil(request.completed_at) and turn.status == "in_progress" and is_nil(turn.completed_at)
  end

  defp replay_close_attempt?(attempt, entitlement, true) do
    entitlement.status == "armed" and entitlement.eligible_attempt_id == attempt.id and
      attempt.replay_generation == 0 and attempt.status == "retryable_failed" and
      attempt.retryable == true and attempt.network_error_code == "client_disconnected" and
      attempt.usage_status == "usage_unknown" and not is_nil(attempt.completed_at)
  end

  defp replay_close_attempt?(attempt, entitlement, false) do
    entitlement.status == "consumed" and entitlement.replay_attempt_id == attempt.id and
      attempt.replay_generation == 1 and attempt.status == "in_progress" and
      attempt.usage_status == "usage_pending" and is_nil(attempt.completed_at)
  end

  defp close_turn!(turn, attempt_id, error_code, now) do
    if turn.status == "in_progress" and is_nil(turn.completed_at) do
      turn
      |> Ecto.Changeset.change(%{
        status: "failed",
        error_code: error_code,
        final_attempt_id: attempt_id,
        completed_at: now,
        updated_at: now
      })
      |> Repo.update!()
    end

    :ok
  end

  defp touch_liveness_locked(reference) do
    request_snapshot = request_snapshot!(reference.request_id)
    session = lock_session!(request_session_id!(reference.request_id))
    api_key = lock_api_key!(request_snapshot.api_key_id)
    _turn = lock_turn!(reference.codex_turn_id)
    _request = lock_request!(reference.request_id)
    attempt = lock_latest_attempt!(reference.request_id)
    entitlement = lock_entitlement(reference.request_id)
    _ledger = lock_ledger!(reference.request_id)
    now = db_now()

    if current_replay_authorization?(api_key, entitlement) and
         consumed_binding_matches?(entitlement, reference) and not is_nil(entitlement.started_at) and
         live_replay_attempt?(attempt, reference) and
         live_owner_binding?(session, entitlement, now) do
      entitlement
      |> RequestReplayEntitlement.changeset(%{
        last_liveness_at: now,
        abandon_at: DateTime.add(now, replay_liveness_grace_ms(), :millisecond)
      })
      |> Repo.update!()
    else
      Repo.rollback(:binding_mismatch)
    end
  end

  defp live_owner_binding?(session, entitlement, now) do
    with owner_lease_token when is_binary(owner_lease_token) <- session.owner_lease_token,
         true <- future?(session.owner_lease_expires_at, now),
         true <-
           RequestReplayEntitlement.verify_owner_lease_digest(
             owner_lease_token,
             entitlement.owner_lease_key_version,
             entitlement.owner_lease_digest
           ),
         %BridgeOwnerLease{} <-
           Repo.one(
             from row in BridgeOwnerLease,
               where:
                 row.codex_session_id == ^session.id and row.status == "active" and
                   row.lease_token == ^owner_lease_token and row.expires_at > ^now
           ) do
      true
    else
      _invalid -> false
    end
  end

  defp due_candidates(now) do
    Repo.all(
      from entitlement in RequestReplayEntitlement,
        join: api_key in APIKey,
        on: api_key.id == entitlement.api_key_id,
        where:
          is_nil(entitlement.closed_at) and
            ((entitlement.status == "armed" and entitlement.expires_at <= ^now) or
               (entitlement.status == "armed" and
                  (api_key.status != "active" or
                     api_key.runtime_revocation_epoch != entitlement.api_key_runtime_epoch)) or
               (entitlement.status == "consumed" and entitlement.abandon_at <= ^now)),
        order_by: [
          asc_nulls_first: entitlement.cleanup_checked_at,
          asc: entitlement.expires_at,
          asc: entitlement.abandon_at,
          asc: entitlement.id
        ],
        limit: @cleanup_batch_size,
        select:
          {entitlement.request_id,
           fragment(
             "CASE WHEN ? = 'armed' AND (? <> 'active' OR ? <> ?) THEN 'revoked' WHEN ? = 'armed' THEN 'expired' ELSE 'abandoned' END",
             entitlement.status,
             api_key.status,
             api_key.runtime_revocation_epoch,
             entitlement.api_key_runtime_epoch,
             entitlement.status
           )}
    )
    |> Enum.map(fn
      {request_id, "revoked"} -> {request_id, :revoked}
      {request_id, "expired"} -> {request_id, :expired}
      {request_id, "abandoned"} -> {request_id, :abandoned}
    end)
  end

  defp cleanup_close_reason(request_id, :abandoned) do
    case started_owner_witness(request_id) do
      %{session: session, reference: reference} ->
        case WebsocketOwnerForwarder.touch_replay_liveness(session, reference,
               timeout: @owner_witness_timeout_ms
             ) do
          :ok -> :abandoned
          {:error, _reason} -> :owner_unavailable
        end

      nil ->
        :abandoned
    end
  catch
    :exit, _reason -> :owner_unavailable
  end

  defp cleanup_close_reason(_request_id, reason), do: reason

  defp started_owner_witness(request_id) do
    Repo.one(
      from entitlement in RequestReplayEntitlement,
        join: turn in CodexTurn,
        on: turn.id == entitlement.codex_turn_id,
        join: session in CodexSession,
        on: session.id == turn.codex_session_id,
        where:
          entitlement.request_id == ^request_id and entitlement.status == "consumed" and
            not is_nil(entitlement.started_at) and is_nil(entitlement.closed_at),
        select: %{
          session: session,
          reference: %{
            request_id: entitlement.request_id,
            codex_turn_id: entitlement.codex_turn_id,
            eligible_attempt_id: entitlement.eligible_attempt_id,
            replay_attempt_id: entitlement.replay_attempt_id,
            replay_generation: entitlement.replay_generation,
            provisional_binding_digest: entitlement.provisional_binding_digest,
            owner_lease_digest: entitlement.owner_lease_digest
          }
        }
    )
  end

  defp close_session_replays_locked(session_id, owner_snapshot, reason) do
    session = lock_session(session_id)
    now = db_now()

    cond do
      owner_snapshot_matches?(session, owner_snapshot) ->
        close_matching_session_replays(session, session_id, reason, now)

      is_nil(session) and legacy_owner_token_snapshot?(owner_snapshot) ->
        %{closed: 0, noop: 0}

      true ->
        :stale_owner
    end
  end

  defp close_matching_session_replays(session, session_id, reason, now) do
    request_ids =
      Repo.all(
        from entitlement in RequestReplayEntitlement,
          join: turn in CodexTurn,
          on: turn.id == entitlement.codex_turn_id,
          where:
            turn.codex_session_id == ^session_id and
              entitlement.status in ["armed", "consumed"] and
              is_nil(entitlement.closed_at),
          order_by: [asc: entitlement.request_id],
          select: entitlement.request_id
      )

    Enum.reduce(request_ids, %{closed: 0, noop: 0}, fn request_id, summary ->
      case close_session_request_locked(session, request_id, reason, now) do
        :closed -> Map.update!(summary, :closed, &(&1 + 1))
        :noop -> Repo.rollback(:request_replay_close_conflict)
      end
    end)
  end

  defp legacy_owner_token_snapshot?(owner_snapshot) do
    match?(%{owner_lease_token: token} when is_binary(token), owner_snapshot) and
      map_size(owner_snapshot) == 1
  end

  defp owner_snapshot_matches?(
         %CodexSession{} = session,
         %{
           owner_instance_id: owner_instance_id,
           owner_lease_token: owner_lease_token,
           owner_lease_expires_at: owner_lease_expires_at
         }
       )
       when is_binary(owner_instance_id) and is_binary(owner_lease_token) and
              is_struct(owner_lease_expires_at, DateTime) do
    session.owner_instance_id == owner_instance_id and
      session.owner_lease_token == owner_lease_token and
      session.owner_lease_expires_at == owner_lease_expires_at
  end

  defp owner_snapshot_matches?(%CodexSession{} = session, %{owner_lease_token: owner_lease_token})
       when is_binary(owner_lease_token) do
    session.owner_lease_token == owner_lease_token
  end

  defp owner_snapshot_matches?(_session, _owner_snapshot), do: false

  defp close_session_request_locked(session, request_id, reason, now) do
    case request_snapshot(request_id) do
      nil ->
        :noop

      request_snapshot ->
        api_key = lock_api_key!(request_snapshot.api_key_id)
        turn = lock_turn_by_request!(request_id)
        request = lock_request!(request_id)
        attempt = lock_latest_attempt!(request_id)
        entitlement = lock_entitlement(request_id)
        _ledger = lock_ledger!(request_id)
        now = max_db_time(now)

        close_replay_lifecycle(
          session,
          api_key,
          turn,
          request,
          attempt,
          entitlement,
          reason,
          now
        )
    end
  end

  defp active_semantic_lifecycle(input) do
    Repo.one(
      from turn in CodexTurn,
        join: request in Request,
        on: request.id == turn.request_id,
        join: api_key in APIKey,
        on: api_key.id == request.api_key_id,
        left_join: entitlement in RequestReplayEntitlement,
        on: entitlement.request_id == request.id,
        where:
          turn.codex_session_id == ^input.codex_session_id and
            turn.semantic_turn_digest == ^input.semantic_turn_digest and
            turn.status == "in_progress",
        order_by: [desc: turn.turn_sequence],
        limit: 1,
        select: %{
          turn: turn,
          request: request,
          api_key: api_key,
          entitlement: entitlement,
          db_now: type(fragment("request_replay_db_now()"), :utc_datetime_usec)
        }
    )
  end

  defp classify_preflight(nil, _input), do: :none

  defp classify_preflight(
         %{turn: turn, request: request, api_key: api_key, entitlement: nil},
         input
       ) do
    with :ok <- compare_active_authorization(turn, request, api_key, input),
         true <- open_turn?(turn),
         true <- open_request?(request),
         %Attempt{} = attempt <- latest_attempt(request.id),
         true <- live_generation_zero_attempt?(attempt) do
      {:active_generation_zero, active_snapshot(turn, request, attempt)}
    else
      {:error, _reason} = error -> error
      _closed_or_absent -> {:error, :lifecycle_conflict}
    end
  end

  defp classify_preflight(
         %{turn: turn, request: request, entitlement: entitlement, db_now: db_now},
         input
       ) do
    with :ok <- compare_entitlement_authorization(entitlement, input),
         :ok <- compare_replay_claim(entitlement, input),
         "armed" <- entitlement.status,
         true <- open_turn?(turn),
         true <- open_request?(request),
         %Attempt{} = attempt <- latest_attempt(request.id),
         true <- coherent_armed_attempt?(attempt, entitlement),
         true <- DateTime.compare(entitlement.expires_at, db_now) == :gt do
      {:armed_generation_one, entitlement_snapshot(entitlement)}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :lifecycle_conflict}
    end
  end

  defp latest_attempt(request_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id,
        order_by: [desc: attempt.attempt_number],
        limit: 1
    )
  end

  defp entitlement_by_request_id(request_id) do
    Repo.get_by(RequestReplayEntitlement, request_id: request_id)
  end

  defp classify_provisional(nil, _reference), do: :absent

  defp classify_provisional(entitlement, reference) do
    if provisional_identity_match?(entitlement, reference),
      do: classify_matching_provisional(entitlement, reference),
      else: {:error, :binding_mismatch}
  end

  defp classify_matching_provisional(%{status: "armed"}, reference),
    do: if(is_nil(reference.replay_attempt_id), do: :armed, else: {:error, :binding_mismatch})

  defp classify_matching_provisional(%{status: "consumed"} = entitlement, reference),
    do: consumed_status(entitlement, reference)

  defp classify_matching_provisional(%{status: status} = entitlement, reference)
       when status in ["expired", "revoked"],
       do: terminal_unconsumed_status(entitlement, reference)

  defp consumed_status(entitlement, reference) do
    if entitlement.replay_attempt_id == reference.replay_attempt_id and
         secure_digest_match?(
           entitlement.provisional_binding_digest,
           reference.provisional_binding_digest
         ),
       do: consumed_phase(entitlement),
       else: {:error, :binding_mismatch}
  end

  defp consumed_phase(%{closed_at: %DateTime{}}), do: :terminal

  defp consumed_phase(entitlement) do
    phase = if is_nil(entitlement.started_at), do: :committed_not_started, else: :started
    {:consumed, consume_binding(entitlement), phase, entitlement.abandon_at}
  end

  defp terminal_unconsumed_status(entitlement, reference) do
    if is_nil(reference.replay_attempt_id) and is_nil(reference.provisional_binding_digest) and
         is_nil(entitlement.replay_attempt_id) and
         is_nil(entitlement.provisional_binding_digest) do
      :terminal
    else
      {:error, :binding_mismatch}
    end
  end

  defp open_request?(%Request{
         status: "in_progress",
         usage_status: "usage_pending",
         completed_at: nil,
         response_status_code: nil
       }),
       do: true

  defp open_request?(%Request{}), do: false

  defp open_turn?(%CodexTurn{
         status: "in_progress",
         first_visible_output_at: nil,
         final_attempt_id: nil,
         completed_at: nil
       }),
       do: true

  defp open_turn?(%CodexTurn{}), do: false

  defp live_generation_zero_attempt?(%Attempt{
         replay_generation: 0,
         status: "in_progress",
         usage_status: "usage_pending",
         completed_at: nil
       }),
       do: true

  defp live_generation_zero_attempt?(%Attempt{}), do: false

  defp coherent_armed_attempt?(
         %Attempt{
           id: attempt_id,
           replay_generation: 0,
           status: "retryable_failed",
           usage_status: "usage_unknown",
           retryable: true,
           network_error_code: "client_disconnected",
           completed_at: %DateTime{}
         },
         %RequestReplayEntitlement{eligible_attempt_id: attempt_id}
       ),
       do: true

  defp coherent_armed_attempt?(%Attempt{}, %RequestReplayEntitlement{}), do: false

  defp compare_active_authorization(turn, request, api_key, input) do
    if turn.codex_session_id == input.codex_session_id and request.api_key_id == input.api_key_id and
         api_key.runtime_revocation_epoch == input.api_key_runtime_epoch and
         request.pool_id == input.pool_id and request.model_id == input.model_id and
         secure_text_match?(request.requested_model, input.model_identifier) do
      :ok
    else
      {:error, :authorization_binding_mismatch}
    end
  end

  defp compare_entitlement_authorization(entitlement, input) do
    if entitlement.api_key_id == input.api_key_id and
         entitlement.api_key_runtime_epoch == input.api_key_runtime_epoch and
         entitlement.pool_id == input.pool_id and entitlement.model_id == input.model_id and
         secure_text_match?(entitlement.model_identifier, input.model_identifier) and
         secure_digest_match?(entitlement.semantic_turn_digest, input.semantic_turn_digest) do
      :ok
    else
      {:error, :authorization_binding_mismatch}
    end
  end

  defp compare_replay_claim(entitlement, input) do
    if secure_digest_match?(entitlement.replay_claim_digest, input.replay_claim_digest),
      do: :ok,
      else: {:error, :replay_claim_mismatch}
  end

  defp open_consumed_reference?(
         %RequestReplayEntitlement{status: "consumed", closed_at: nil} = entitlement,
         reference
       ) do
    provisional_identity_match?(entitlement, reference) and
      entitlement.replay_attempt_id == reference.replay_attempt_id
  end

  defp open_consumed_reference?(_entitlement, _reference), do: false

  defp consumed_binding_matches?(entitlement, reference) do
    open_consumed_reference?(entitlement, reference) and
      secure_digest_match?(
        entitlement.provisional_binding_digest,
        reference.provisional_binding_digest
      )
  end

  defp live_replay_attempt?(
         %Attempt{id: id, replay_generation: 1, status: "in_progress"},
         reference
       ),
       do: id == reference.replay_attempt_id

  defp live_replay_attempt?(_attempt, _reference), do: false

  defp provisional_identity_match?(entitlement, reference) do
    entitlement.request_id == reference.request_id and
      entitlement.codex_turn_id == reference.codex_turn_id and
      entitlement.eligible_attempt_id == reference.eligible_attempt_id and
      entitlement.replay_generation == reference.replay_generation and
      secure_digest_match?(entitlement.owner_lease_digest, reference.owner_lease_digest)
  end

  defp active_snapshot(turn, request, attempt) do
    %{
      request_id: request.id,
      codex_turn_id: turn.id,
      eligible_attempt_id: attempt.id,
      replay_generation: attempt.replay_generation,
      first_visible_output_at: turn.first_visible_output_at,
      request_status: request.status,
      turn_status: turn.status,
      attempt_status: attempt.status
    }
  end

  defp entitlement_snapshot(entitlement) do
    %{
      entitlement_id: entitlement.id,
      request_id: entitlement.request_id,
      codex_turn_id: entitlement.codex_turn_id,
      eligible_attempt_id: entitlement.eligible_attempt_id,
      replay_attempt_id: entitlement.replay_attempt_id,
      replay_generation: entitlement.replay_generation,
      predecessor_epoch: entitlement.predecessor_epoch,
      owner_lease_digest: entitlement.owner_lease_digest,
      status: entitlement.status,
      armed_at: entitlement.armed_at,
      expires_at: entitlement.expires_at
    }
  end

  defp consume_binding(entitlement) do
    %{
      request_id: entitlement.request_id,
      codex_turn_id: entitlement.codex_turn_id,
      eligible_attempt_id: entitlement.eligible_attempt_id,
      replay_attempt_id: entitlement.replay_attempt_id,
      replay_generation: entitlement.replay_generation,
      provisional_binding_digest: entitlement.provisional_binding_digest,
      owner_lease_digest: entitlement.owner_lease_digest
    }
  end

  defp validate_arm_input(input) do
    required = [
      :api_key_id,
      :pool_id,
      :codex_session_id,
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :api_key_runtime_epoch,
      :model_id,
      :model_identifier,
      :endpoint,
      :semantic_turn_digest,
      :replay_claim_digest,
      :owner_instance_id,
      :owner_lease_token,
      :predecessor_epoch,
      :failure_reason,
      :pre_visible_output
    ]

    if Enum.all?(required, &Map.has_key?(input, &1)) and
         Enum.all?(
           [
             :api_key_id,
             :pool_id,
             :codex_session_id,
             :request_id,
             :codex_turn_id,
             :eligible_attempt_id,
             :model_id
           ],
           &uuid?(input[&1])
         ) and arm_input_proof?(input) and arm_input_labels?(input) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp arm_input_proof?(input) do
    uuid?(input.owner_lease_token) and digest?(input.semantic_turn_digest) and
      digest?(input.replay_claim_digest) and input.failure_reason == :client_disconnected and
      input.pre_visible_output == true and positive?(input.predecessor_epoch)
  end

  defp arm_input_labels?(input) do
    is_integer(input.api_key_runtime_epoch) and input.api_key_runtime_epoch >= 0 and
      is_binary(input.model_identifier) and is_binary(input.endpoint) and
      is_binary(input.owner_instance_id)
  end

  defp validate_consume_input(input) do
    required = [
      :auth,
      :entitlement_id,
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :replay_generation,
      :provisional_token,
      :owner_lease_token,
      :reserve_timeout_ms,
      :reserve_receipt,
      :reserve_receipt_digest,
      :owner_forwarder_opts,
      :downstream_epoch,
      :owner_process_generation
    ]

    if Enum.all?(required, &Map.has_key?(input, &1)) and
         match?(%{api_key: %{id: _}, pool: %{id: _}}, input.auth) and
         Enum.all?(
           [:entitlement_id, :request_id, :codex_turn_id, :eligible_attempt_id],
           &uuid?(input[&1])
         ) and consume_input_proof?(input) and consume_input_options?(input) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp consume_input_proof?(input) do
    uuid?(input.owner_lease_token) and input.replay_generation == 1 and
      digest?(input.provisional_token) and digest?(input.reserve_receipt) and
      digest?(input.reserve_receipt_digest)
  end

  defp consume_input_options?(input) do
    positive?(input.downstream_epoch) and positive?(input.owner_process_generation) and
      is_list(input.owner_forwarder_opts) and is_integer(input.reserve_timeout_ms) and
      input.reserve_timeout_ms in 1..60_000
  end

  defp reserve_session_snapshot(input) do
    Repo.one(
      from session in CodexSession,
        join: turn in CodexTurn,
        on: turn.codex_session_id == session.id,
        where:
          turn.id == ^input.codex_turn_id and turn.request_id == ^input.request_id and
            session.owner_lease_token == ^input.owner_lease_token,
        select: session
    )
  end

  defp consume_owner_reserve(%CodexSession{} = session, input) do
    proof = reserve_receipt_proof(input)

    WebsocketOwnerForwarder.consume_replay_reserve(
      session,
      input.owner_lease_token,
      proof,
      input.owner_forwarder_opts
    )
  end

  defp release_owner_reserve(session, input, consume_fence) do
    WebsocketOwnerForwarder.release_replay_reserve(
      session,
      input.owner_lease_token,
      reserve_receipt_proof(input),
      consume_fence,
      input.owner_forwarder_opts
    )
  end

  defp validate_owner_reserve(session, input, consume_fence) do
    WebsocketOwnerForwarder.validate_replay_reserve(
      session,
      input.owner_lease_token,
      reserve_receipt_proof(input),
      consume_fence,
      input.owner_forwarder_opts
    )
  end

  defp validate_owner_reserve_snapshot(session, reserved_session, consume_fence)
       when is_reference(consume_fence) do
    if session.id == reserved_session.id and
         session.owner_instance_id == reserved_session.owner_instance_id and
         session.owner_lease_token == reserved_session.owner_lease_token do
      :ok
    else
      {:error, :owner_unavailable}
    end
  end

  defp reserve_receipt_proof(input) do
    %{
      request_id: input.request_id,
      codex_turn_id: input.codex_turn_id,
      eligible_attempt_id: input.eligible_attempt_id,
      entitlement_id: input.entitlement_id,
      owner_lease_token: input.owner_lease_token,
      owner_process_generation: input.owner_process_generation,
      downstream_epoch: input.downstream_epoch,
      reserve_receipt_digest: input.reserve_receipt_digest,
      consumer_pid: self()
    }
  end

  defp validate_arm_rows(input, session, api_key, turn, request, attempt, owner_lease, now) do
    valid? =
      arm_session_matches?(input, session, owner_lease, now) and
        arm_key_matches?(input, api_key) and arm_turn_matches?(input, session, request, turn) and
        arm_request_matches?(input, api_key, request) and
        arm_attempt_matches?(input, request, attempt) and no_terminal_ledger?(request.id)

    cond do
      valid? -> :ok
      terminal_lifecycle?(turn, request, attempt) -> {:error, :terminal_won}
      true -> {:error, :ineligible}
    end
  end

  defp arm_session_matches?(input, session, owner_lease, now) do
    session.id == input.codex_session_id and session.pool_id == input.pool_id and
      session.api_key_id == input.api_key_id and
      session.owner_instance_id == input.owner_instance_id and
      owner_lease.owner_instance_id == input.owner_instance_id and
      live_lease_matches?(session, owner_lease, input.owner_lease_token, now)
  end

  defp live_lease_matches?(session, owner_lease, token, now) do
    session.owner_lease_token == token and owner_lease.lease_token == token and
      future?(session.owner_lease_expires_at, now) and future?(owner_lease.expires_at, now)
  end

  defp arm_key_matches?(input, api_key) do
    api_key.id == input.api_key_id and api_key.pool_id == input.pool_id and
      api_key.status == "active" and
      api_key.runtime_revocation_epoch == input.api_key_runtime_epoch
  end

  defp arm_turn_matches?(input, session, request, turn) do
    turn.id == input.codex_turn_id and turn.codex_session_id == session.id and
      turn.request_id == request.id and open_turn?(turn) and
      secure_digest_match?(turn.semantic_turn_digest, input.semantic_turn_digest)
  end

  defp arm_request_matches?(input, api_key, request) do
    request.id == input.request_id and open_request?(request) and request.api_key_id == api_key.id and
      request.pool_id == input.pool_id and request.model_id == input.model_id and
      request.transport == "websocket" and arm_request_labels_match?(input, request)
  end

  defp arm_request_labels_match?(input, request) do
    secure_text_match?(request.requested_model, input.model_identifier) and
      secure_text_match?(request.endpoint, input.endpoint)
  end

  defp arm_attempt_matches?(input, request, attempt) do
    attempt.id == input.eligible_attempt_id and attempt.request_id == request.id and
      live_generation_zero_attempt?(attempt)
  end

  defp terminal_lifecycle?(turn, request, attempt) do
    request.status != "in_progress" or not is_nil(request.completed_at) or
      turn.status != "in_progress" or not is_nil(turn.completed_at) or
      attempt.status != "in_progress" or not is_nil(attempt.completed_at)
  end

  defp validate_consume_rows(input, rows, now) do
    %{
      session: session,
      api_key: api_key,
      turn: turn,
      request: request,
      attempt: attempt,
      entitlement: entitlement,
      owner_lease: owner_lease,
      pool: pool
    } = rows

    valid? =
      consume_entitlement_matches?(input, request, turn, entitlement, now) and
        consume_owner_matches?(input, session, turn, owner_lease, now) and
        consume_key_matches?(input, api_key, pool, entitlement) and
        consume_lifecycle_open?(request, turn, attempt, entitlement) and
        no_terminal_ledger?(request.id)

    cond do
      match?(%RequestReplayEntitlement{status: "consumed"}, entitlement) ->
        {:error, :already_consumed}

      valid? ->
        :ok

      true ->
        {:error, :ineligible}
    end
  end

  defp consume_lifecycle_open?(request, turn, attempt, entitlement),
    do:
      open_request?(request) and consume_turn_open?(turn) and
        coherent_armed_attempt?(attempt, entitlement)

  defp consume_entitlement_matches?(
         input,
         request,
         turn,
         %RequestReplayEntitlement{status: "armed"} = entitlement,
         now
       ) do
    entitlement.id == input.entitlement_id and entitlement.request_id == request.id and
      entitlement.codex_turn_id == turn.id and
      entitlement.eligible_attempt_id == input.eligible_attempt_id and
      entitlement.replay_generation == input.replay_generation and
      future?(entitlement.expires_at, now) and
      RequestReplayEntitlement.verify_owner_lease_digest(
        input.owner_lease_token,
        entitlement.owner_lease_key_version,
        entitlement.owner_lease_digest
      )
  end

  defp consume_entitlement_matches?(_input, _request, _turn, _entitlement, _now), do: false

  defp consume_owner_matches?(input, session, turn, owner_lease, now) do
    session.id == turn.codex_session_id and session.pool_id == input.auth.pool.id and
      session.api_key_id == input.auth.api_key.id and owner_lease.status == "active" and
      live_lease_matches?(session, owner_lease, input.owner_lease_token, now)
  end

  defp consume_key_matches?(input, api_key, pool, entitlement) do
    pool.status == "active" and api_key.id == input.auth.api_key.id and
      api_key.pool_id == input.auth.pool.id and
      current_replay_authorization?(api_key, entitlement) and
      model_policy_allows?(api_key, entitlement.model_identifier)
  end

  defp consume_turn_open?(turn),
    do:
      turn.status == "in_progress" and is_nil(turn.first_visible_output_at) and
        is_nil(turn.completed_at)

  defp insert_replay_attempt!(request, eligible_attempt, _provisional_digest, now) do
    %Attempt{
      request_id: request.id,
      attempt_number: eligible_attempt.attempt_number + 1,
      pool_upstream_assignment_id: eligible_attempt.pool_upstream_assignment_id,
      upstream_identity_id: eligible_attempt.upstream_identity_id,
      pricing_snapshot_id: eligible_attempt.pricing_snapshot_id,
      model_id: eligible_attempt.model_id || request.model_id,
      upstream_model_id: eligible_attempt.upstream_model_id,
      transport: eligible_attempt.transport,
      status: "in_progress",
      started_at: now,
      retryable: false,
      usage_status: "usage_pending",
      response_metadata: %{},
      replay_generation: 1
    }
    |> Repo.insert!()
  end

  defp lock_session!(session_id),
    do: Repo.one!(from row in CodexSession, where: row.id == ^session_id, lock: "FOR UPDATE")

  defp lock_session(session_id),
    do: Repo.one(from row in CodexSession, where: row.id == ^session_id, lock: "FOR UPDATE")

  defp lock_api_key!(api_key_id),
    do: Repo.one!(from row in APIKey, where: row.id == ^api_key_id, lock: "FOR UPDATE")

  defp lock_turn!(turn_id),
    do: Repo.one!(from row in CodexTurn, where: row.id == ^turn_id, lock: "FOR UPDATE")

  defp lock_turn_by_request!(request_id),
    do: Repo.one!(from row in CodexTurn, where: row.request_id == ^request_id, lock: "FOR UPDATE")

  defp lock_request!(request_id),
    do: Repo.one!(from row in Request, where: row.id == ^request_id, lock: "FOR UPDATE")

  defp lock_latest_attempt!(request_id),
    do:
      Repo.one!(
        from row in Attempt,
          where: row.request_id == ^request_id,
          order_by: [desc: row.attempt_number],
          limit: 1,
          lock: "FOR UPDATE"
      )

  defp lock_entitlement(request_id),
    do:
      Repo.one(
        from row in RequestReplayEntitlement,
          where: row.request_id == ^request_id,
          lock: "FOR UPDATE"
      )

  defp lock_active_owner_lease!(session_id),
    do:
      Repo.one!(
        from row in BridgeOwnerLease,
          where: row.codex_session_id == ^session_id and row.status == "active",
          lock: "FOR UPDATE"
      )

  defp lock_ledger!(request_id),
    do:
      Repo.all(from row in LedgerEntry, where: row.request_id == ^request_id, lock: "FOR UPDATE")

  defp no_terminal_ledger?(request_id) do
    not Repo.exists?(
      from row in LedgerEntry,
        where: row.request_id == ^request_id and row.entry_kind in ["settlement", "release"]
    )
  end

  defp lock_pool!(pool_id),
    do:
      Repo.one!(from row in CodexPooler.Pools.Pool, where: row.id == ^pool_id, lock: "FOR UPDATE")

  defp lock_api_key_policy_bindings!(api_key_id),
    do:
      Repo.all(
        from binding in APIKeyPolicyBinding,
          where: binding.api_key_id == ^api_key_id,
          order_by: [asc: binding.binding_scope, asc: binding.model_identifier],
          lock: "FOR SHARE"
      )

  defp lock_model(pool_id, model_id),
    do:
      Repo.one(
        from model in Model,
          where: model.id == ^model_id and model.pool_id == ^pool_id,
          lock: "FOR SHARE"
      )

  defp model_policy_allows?(api_key, model_identifier) do
    match?(
      {:ok, _policy},
      Access.authorize_api_key_policy(api_key, %{model_identifier: model_identifier})
    )
  end

  defp authorize_exact_assignment(api_key, request, attempt, assignment, identity, model) do
    valid? =
      eligible_assignment?(assignment, identity, request.pool_id) and
        exact_model_matches?(model, request, assignment.id) and
        attempt_assignment_matches?(attempt, assignment, model.id) and
        model_policy_allows?(api_key, model.exposed_model_id)

    if valid?, do: :ok, else: {:error, :ineligible}
  end

  defp eligible_assignment?(assignment, identity, pool_id) do
    assignment.pool_id == pool_id and assignment.status == "active" and
      assignment.eligibility_status == "eligible" and assignment.health_status == "active" and
      identity.id == assignment.upstream_identity_id and
      identity.status in ["active", "refreshing"]
  end

  defp exact_model_matches?(model, request, assignment_id) do
    model.id == request.model_id and model.pool_id == request.pool_id and model.status == "active" and
      secure_text_match?(model.exposed_model_id, request.requested_model) and
      ModelMetadata.assignment_source?(model, assignment_id)
  end

  defp attempt_assignment_matches?(attempt, assignment, model_id) do
    attempt.pool_upstream_assignment_id == assignment.id and
      attempt.upstream_identity_id == assignment.upstream_identity_id and
      attempt.model_id == model_id
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT request_replay_db_now()", [])
    DateTime.from_naive!(now, "Etc/UTC")
  end

  defp max_db_time(witness) do
    current = db_now()
    if DateTime.compare(current, witness) == :gt, do: current, else: witness
  end

  defp configured_key_version do
    case AppSecretCrypto.key_version() do
      version when is_binary(version) and version != "" -> {:ok, version}
      _invalid -> {:error, :invalid_key_version}
    end
  end

  defp replay_liveness_grace_ms do
    settings = OperationalSettings.current()

    settings.websocket_owner_idle_timeout_ms
    |> max(settings.bridge_owner_lease_renewal_seconds * 3 * 1_000)
    |> min(3_660_000)
    |> max(60_000)
  end

  defp current_replay_authorization?(
         %APIKey{} = api_key,
         %RequestReplayEntitlement{} = entitlement
       ),
       do:
         api_key.status == "active" and
           api_key.runtime_revocation_epoch == entitlement.api_key_runtime_epoch

  defp current_replay_authorization?(_api_key, _entitlement), do: false

  defp future?(%DateTime{} = value, %DateTime{} = now), do: DateTime.compare(value, now) == :gt
  defp future?(_value, _now), do: false
  defp positive?(value), do: is_integer(value) and value > 0

  defp request_snapshot!(request_id),
    do: Repo.get(Request, request_id) || Repo.rollback(:ineligible)

  defp request_snapshot(request_id), do: Repo.get(Request, request_id)

  defp request_session_id!(request_id) when is_binary(request_id),
    do:
      Repo.one(
        from turn in CodexTurn,
          where: turn.request_id == ^request_id,
          select: turn.codex_session_id
      ) || Repo.rollback(:ineligible)

  defp request_session_id!(%Request{request_metadata: %{"codex_session_id" => session_id}})
       when is_binary(session_id),
       do: session_id

  defp request_session_id!(%Request{}), do: Repo.rollback(:ineligible)

  defp validate_preflight_input(input) do
    required = [
      :codex_session_id,
      :api_key_id,
      :api_key_runtime_epoch,
      :pool_id,
      :model_id,
      :model_identifier,
      :semantic_turn_digest,
      :replay_claim_digest
    ]

    if Map.keys(input) |> Enum.sort() == Enum.sort(required) and
         Enum.all?([:codex_session_id, :api_key_id, :pool_id, :model_id], &uuid?(input[&1])) and
         is_integer(input.api_key_runtime_epoch) and input.api_key_runtime_epoch >= 0 and
         is_binary(input.model_identifier) and byte_size(input.model_identifier) in 1..255 and
         digest?(input.semantic_turn_digest) and digest?(input.replay_claim_digest) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp validate_provisional_reference(reference) do
    required = [
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :replay_attempt_id,
      :replay_generation,
      :provisional_binding_digest,
      :owner_lease_digest
    ]

    if Map.keys(reference) |> Enum.sort() == Enum.sort(required) and
         Enum.all?([:request_id, :codex_turn_id, :eligible_attempt_id], &uuid?(reference[&1])) and
         (is_nil(reference.replay_attempt_id) or uuid?(reference.replay_attempt_id)) and
         reference.replay_generation == 1 and
         optional_digest?(reference.provisional_binding_digest) and
         digest?(reference.owner_lease_digest) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp uuid?(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp digest?(value), do: is_binary(value) and byte_size(value) == @digest_bytes
  defp optional_digest?(nil), do: true
  defp optional_digest?(value), do: digest?(value)

  defp secure_digest_match?(left, right)
       when is_binary(left) and byte_size(left) == @digest_bytes and is_binary(right) and
              byte_size(right) == @digest_bytes,
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_digest_match?(_left, _right), do: false

  defp secure_text_match?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_text_match?(_left, _right), do: false
end
