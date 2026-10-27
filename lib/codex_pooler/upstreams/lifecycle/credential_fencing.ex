defmodule CodexPooler.Upstreams.Lifecycle.CredentialFencing do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.Lifecycle.IdentitySlotLock
  alias CodexPooler.Upstreams.Quota.{AccountAvailabilityStore, CapacityFactsStore, CreditBalanceStore}
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @credential_epoch_key "credential_epoch"
  @credential_lineage_key "credential_lineage"
  @probe_sequence_key "usage_probe_sequence"
  @applied_sequence_key "usage_probe_applied_sequence"
  @completed_sequence_key "usage_probe_completed_sequence"
  @provider_auth_recovery_key "provider_auth_recovery"
  @assignment_deleted AssignmentStatus.deleted_status()
  @assignment_health_active AssignmentStatus.active_health_status()
  @assignment_disabled AssignmentStatus.disabled_health_status()
  @assignment_eligible AssignmentStatus.eligible_status()
  @assignment_ineligible AssignmentStatus.ineligible_status()
  @secret_active "active"
  @active IdentityStatus.active_status()
  @pending IdentityStatus.pending_status()
  @refreshing IdentityStatus.refreshing_status()
  @refresh_failed IdentityStatus.refresh_failed_status()
  @reauth_required IdentityStatus.reauth_required_status()
  @deleted IdentityStatus.deleted_status()
  @paused IdentityStatus.paused_status()

  @type fence :: %{
          required(:credential_epoch) => pos_integer(),
          required(:usage_probe_sequence) => pos_integer()
        }
  @type guarded_result :: :applied | :superseded
  @type probe_completion_mode :: :active_only | :auth_failure

  @spec active_token_refresh?(UpstreamIdentity.t(), DateTime.t()) :: boolean()
  def active_token_refresh?(%UpstreamIdentity{} = identity, %DateTime{} = timestamp) do
    with %{} = metadata <- (identity.metadata || %{})["token_refresh"],
         "refreshing" <- metadata["status"],
         attempt_id when is_binary(attempt_id) <- metadata["attempt_id"],
         generation when is_integer(generation) and generation >= 0 <- metadata["generation"],
         started_at when is_binary(started_at) <- metadata["started_at"],
         stale_after_ms when is_integer(stale_after_ms) and stale_after_ms > 0 <- metadata["stale_after_ms"],
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started_at),
         true <- DateTime.diff(timestamp, started_at, :millisecond) < stale_after_ms do
      true
    else
      _value -> false
    end
  end

  @spec initialize_metadata(map() | nil) :: map()
  def initialize_metadata(metadata) do
    metadata
    |> normalize_metadata()
    |> Map.put_new(@credential_epoch_key, 1)
    |> Map.put_new(@probe_sequence_key, 0)
    |> Map.put_new(@applied_sequence_key, 0)
    |> Map.put_new(@completed_sequence_key, 0)
  end

  # Every credential epoch advance records the identity's credential lineage
  # (findings#330): `since_epoch` is the epoch at which the credential the
  # identity holds was put in place, `credential_epoch` the epoch the marker was
  # written for, in the same identity-locked write that advances the epoch. A
  # token refresh renews the access of the credential in place and keeps
  # `since_epoch`; every other advance (an operator link, import or relink, a
  # pause or a reactivation) starts a new lineage at its own epoch. The marker
  # holds a version and two integers, never a secret or a provider id.
  @spec advance_credential_epoch(UpstreamIdentity.t()) :: map()
  def advance_credential_epoch(%UpstreamIdentity{} = identity) do
    metadata = initialize_metadata(identity.metadata)
    epoch = metadata[@credential_epoch_key] + 1

    metadata
    |> Map.put(@credential_epoch_key, epoch)
    |> put_credential_lineage(epoch, epoch)
    |> preserve_terminal_provider_auth_rejection()
  end

  @spec invalidate_provider_auth_recovery(map() | nil) :: map()
  def invalidate_provider_auth_recovery(metadata) do
    metadata
    |> normalize_metadata()
    |> Map.delete(@provider_auth_recovery_key)
  end

  @doc """
  The metadata of a credential replacement (an operator link, import or relink
  storing new tokens) and its credential epoch. The replaced credential's
  lineage ends: the new one starts at that epoch.
  """
  @spec prepare_replacement_metadata(UpstreamIdentity.t()) ::
          {:ok, map(), pos_integer()} | {:error, %{code: atom(), message: String.t()}}
  def prepare_replacement_metadata(%UpstreamIdentity{} = identity),
    do: prepare_epoch_metadata(identity, fn epoch -> epoch end)

  @doc """
  The metadata of a successful token refresh and its credential epoch: exactly
  what `prepare_replacement_metadata/1` writes, except that the credential's
  lineage goes on and the account's quota evidence goes with it. A refresh
  exchanges the refresh token the identity holds for the access of the same
  provider account, so the credential in place keeps the epoch it was put in
  place at, or, without a trusted lineage, the epoch the refresh started at
  (findings#330). The provider's availability, the capacity facts and their
  retained blockers, and the credit balance describe that account, so the
  ones current at the epoch the refresh started at move to its new epoch in
  this same write, with `observed_at` untouched (findings#334); their readers
  stay strict, so a replacement, which carries nothing, still drops them.
  """
  @spec prepare_refresh_metadata(UpstreamIdentity.t()) ::
          {:ok, map(), pos_integer()} | {:error, %{code: atom(), message: String.t()}}
  def prepare_refresh_metadata(%UpstreamIdentity{} = identity) do
    with {:ok, metadata, epoch} <- prepare_epoch_metadata(identity, fn _epoch -> credential_lineage_since(identity) end) do
      {:ok, carry_account_evidence(metadata, initialize_metadata(identity.metadata)[@credential_epoch_key], epoch), epoch}
    end
  end

  defp carry_account_evidence(metadata, epoch, epoch), do: metadata

  defp carry_account_evidence(metadata, from_epoch, to_epoch) do
    metadata
    |> AccountAvailabilityStore.carry_forward(from_epoch, to_epoch)
    |> CapacityFactsStore.carry_forward(from_epoch, to_epoch)
    |> CreditBalanceStore.carry_forward(from_epoch, to_epoch)
  end

  defp prepare_epoch_metadata(%UpstreamIdentity{metadata: %{"permanent_deletion_requested_at" => _}}, _since) do
    {:error, %{code: :upstream_account_deleting, message: "upstream account is being deleted"}}
  end

  defp prepare_epoch_metadata(%UpstreamIdentity{} = identity, since) do
    metadata = normalize_metadata(identity.metadata)

    case replacement_epoch(identity.status, Map.fetch(metadata, @credential_epoch_key)) do
      {:ok, epoch} ->
        metadata =
          metadata
          |> initialize_metadata()
          |> Map.put(@credential_epoch_key, epoch)
          |> put_credential_lineage(since.(epoch), epoch)
          |> preserve_terminal_provider_auth_rejection()

        {:ok, metadata, epoch}

      :error ->
        {:error, %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}}
    end
  end

  @doc """
  True when the identity still holds the credential it held at credential
  epoch `epoch`: its epoch is `epoch`, or every advance since then was a token
  refresh of that credential (findings#330). The lineage marker is trusted only
  when written for the identity's current epoch: a missing marker, or one an
  epoch advance left behind (a release that predates the marker), reads as a
  new credential at the current epoch. Its start only ever moves forward, so
  once a replacement happened after `epoch` no later refresh makes this true.
  """
  @spec same_credential_since?(UpstreamIdentity.t(), term()) :: boolean()
  def same_credential_since?(%UpstreamIdentity{} = identity, epoch) when is_integer(epoch) and epoch > 0 do
    case credential_epoch(identity) do
      current when is_integer(current) and current >= epoch -> credential_lineage_since(identity) <= epoch
      _invalid_or_older -> false
    end
  end

  def same_credential_since?(_identity, _epoch), do: false

  defp credential_lineage_since(%UpstreamIdentity{} = identity) do
    metadata = initialize_metadata(identity.metadata)
    current = metadata[@credential_epoch_key]

    case metadata[@credential_lineage_key] do
      %{"version" => 1, "since_epoch" => since, "credential_epoch" => ^current} = marker
      when map_size(marker) == 3 and is_integer(since) and since > 0 and is_integer(current) and since <= current ->
        since

      _missing_or_stale ->
        current
    end
  end

  defp put_credential_lineage(metadata, since, epoch),
    do: Map.put(metadata, @credential_lineage_key, %{"version" => 1, "since_epoch" => since, "credential_epoch" => epoch})

  @spec advance_credential_epoch_preserving_expiry(UpstreamIdentity.t()) :: map()
  def advance_credential_epoch_preserving_expiry(%UpstreamIdentity{} = identity) do
    old_metadata = normalize_metadata(identity.metadata)
    advanced = advance_credential_epoch(identity)

    TokenRefreshMetadata.rebind_access_token_expiry(
      advanced,
      old_metadata,
      advanced[@credential_epoch_key]
    )
  end

  @spec current_credential_epoch?(UpstreamIdentity.t() | Ecto.UUID.t(), pos_integer()) ::
          boolean()
  def current_credential_epoch?(identity_or_id, credential_epoch)
      when is_integer(credential_epoch) and credential_epoch > 0 do
    credential_epoch(identity_or_id) == credential_epoch
  end

  def current_credential_epoch?(_identity_or_id, _credential_epoch), do: false

  @spec credential_epoch(UpstreamIdentity.t() | Ecto.UUID.t()) :: pos_integer() | nil
  def credential_epoch(%UpstreamIdentity{} = identity) do
    initialize_metadata(identity.metadata)[@credential_epoch_key]
  end

  def credential_epoch(identity_id) when is_binary(identity_id) do
    case Repo.get(UpstreamIdentity, identity_id) do
      %UpstreamIdentity{} = identity -> credential_epoch(identity)
      nil -> nil
    end
  end

  def credential_epoch(_identity), do: nil

  @spec validate_current_credential_epoch(UpstreamIdentity.t()) ::
          {:ok, pos_integer()} | {:error, %{code: atom(), message: String.t()}}
  def validate_current_credential_epoch(%UpstreamIdentity{} = identity) do
    identity.metadata
    |> normalize_metadata()
    |> Map.fetch(@credential_epoch_key)
    |> case do
      :error ->
        {:ok, 1}

      {:ok, epoch} when is_integer(epoch) and epoch > 0 ->
        {:ok, epoch}

      _invalid ->
        {:error, %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}}
    end
  end

  @spec awaiting_provider_auth_recovery?(UpstreamIdentity.t() | Ecto.UUID.t()) :: boolean()
  def awaiting_provider_auth_recovery?(%UpstreamIdentity{} = identity) do
    provider_auth_recovery_status(identity.metadata) == "awaiting_fresh_quota"
  end

  def awaiting_provider_auth_recovery?(identity_id) when is_binary(identity_id) do
    case Repo.get(UpstreamIdentity, identity_id) do
      %UpstreamIdentity{} = identity -> awaiting_provider_auth_recovery?(identity)
      nil -> false
    end
  end

  def awaiting_provider_auth_recovery?(_identity), do: false

  @spec allocate_usage_probe(UpstreamIdentity.t() | Ecto.UUID.t()) ::
          {:ok, UpstreamIdentity.t(), fence()} | {:error, :upstream_identity_not_found}
  def allocate_usage_probe(identity_or_id) do
    Repo.transaction(fn ->
      case lock_identity(identity_id(identity_or_id)) do
        %UpstreamIdentity{} = identity ->
          metadata = initialize_metadata(identity.metadata)
          sequence = metadata[@probe_sequence_key] + 1
          metadata = Map.put(metadata, @probe_sequence_key, sequence)

          identity =
            identity
            |> UpstreamIdentity.changeset(%{metadata: metadata, updated_at: now()})
            |> Repo.update!()

          {identity,
           %{
             credential_epoch: metadata[@credential_epoch_key],
             usage_probe_sequence: sequence
           }}

        nil ->
          Repo.rollback(:upstream_identity_not_found)
      end
    end)
    |> case do
      {:ok, {identity, fence}} -> {:ok, identity, fence}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec lock_credential_replacement(UpstreamIdentity.t() | Ecto.UUID.t()) ::
          UpstreamIdentity.t() | nil
  def lock_credential_replacement(identity_or_id) do
    identity_or_id
    |> List.wrap()
    |> lock_credential_replacements()
    |> List.first()
  end

  @spec lock_credential_replacements([UpstreamIdentity.t() | Ecto.UUID.t()]) ::
          [UpstreamIdentity.t()]
  def lock_credential_replacements(identity_refs) when is_list(identity_refs) do
    identity_refs
    |> IdentitySlotLock.lock_identity_rows!()
    |> Map.fetch!(:identities)
  end

  @spec lock_credential_replacement_after_identity(UpstreamIdentity.t()) :: UpstreamIdentity.t()
  def lock_credential_replacement_after_identity(%UpstreamIdentity{} = identity) do
    lock_assignments(identity.id)
    lock_active_secrets(identity.id)
    identity
  end

  @spec mark_definitive_rejection(UpstreamIdentity.t() | Ecto.UUID.t(), fence()) ::
          {:ok, guarded_result(), UpstreamIdentity.t()} | {:error, term()}
  def mark_definitive_rejection(identity_or_id, fence) do
    identity_or_id
    |> definitive_rejection_transaction(fence)
    |> finalize_definitive_rejection()
  end

  defp definitive_rejection_transaction(identity_or_id, fence) do
    Repo.transaction(fn ->
      identity_or_id
      |> lock_credential_replacement()
      |> apply_definitive_rejection(fence)
    end)
  end

  defp apply_definitive_rejection(nil, _fence), do: Repo.rollback(:upstream_identity_not_found)

  defp apply_definitive_rejection(identity, fence) do
    if definitive_rejection_superseded?(identity, fence) do
      {:superseded, identity}
    else
      timestamp = now()
      assignments = provider_auth_rejection_assignments(identity.id)

      metadata =
        identity.metadata
        |> applied_metadata(fence)
        |> provider_rejection_metadata(timestamp)
        |> put_provider_auth_recovery_probe_ceiling()
        |> put_provider_auth_recovery("terminal", timestamp)
        |> put_provider_auth_recovery_assignment_ids(assignments)

      identity =
        identity
        |> UpstreamIdentity.changeset(%{
          status: @reauth_required,
          disabled_at: timestamp,
          updated_at: timestamp,
          metadata: metadata
        })
        |> Repo.update!()

      demote_assignments_for_provider_auth_rejection!(assignments, timestamp)

      {:applied, identity}
    end
  end

  defp definitive_rejection_superseded?(identity, fence) do
    Map.has_key?(identity.metadata || %{}, "permanent_deletion_requested_at") or
      not current_fence?(identity, fence) or not definitive_rejection_applicable?(identity)
  end

  defp finalize_definitive_rejection(transaction_result) do
    case transaction_result do
      {:ok, {:applied, identity}} ->
        identity = Repo.reload!(identity)
        broadcast_upstream_change(identity, "upstream_account_reauth_required")
        {:ok, :applied, identity}

      {:ok, {:superseded, identity}} ->
        {:ok, :superseded, Repo.reload!(identity)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec apply_usage_success(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          fence(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def apply_usage_success(identity_or_id, fence, persist) when is_function(persist, 1) do
    Repo.transaction(fn ->
      identity = lock_credential_replacement(identity_or_id)

      cond do
        is_nil(identity) ->
          Repo.rollback(:upstream_identity_not_found)

        not usage_success_applicable?(identity, fence) ->
          {:superseded, identity, nil}

        true ->
          persist_usage_success(identity, fence, persist)
      end
    end)
    |> case do
      {:ok, {:applied, identity, value}} ->
        identity = Repo.reload!(identity)
        broadcast_upstream_change(identity, "upstream_quota_windows_updated")
        {:ok, :applied, identity, value}

      {:ok, {:superseded, identity, nil}} ->
        {:ok, :superseded, Repo.reload!(identity), nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec guard_active_usage_probe_completion(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          fence(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_active_usage_probe_completion(identity_or_id, fence, apply)
      when is_function(apply, 1) do
    guard_active_usage_probe_completion(identity_or_id, fence, :active_only, apply)
  end

  @spec guard_active_usage_probe_completion(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          fence(),
          probe_completion_mode(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_active_usage_probe_completion(identity_or_id, fence, mode, apply)
      when mode in [:active_only, :auth_failure] and is_function(apply, 1) do
    Repo.transaction(fn ->
      identity_or_id
      |> lock_credential_replacement()
      |> guard_active_probe_completion(fence, mode, apply)
    end)
    |> normalize_guarded_probe_completion()
  end

  @spec guard_current_usage_probe_completion(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          fence(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_current_usage_probe_completion(identity_or_id, fence, apply)
      when is_function(apply, 1) do
    guard_current_usage_probe_completion(identity_or_id, fence, :active_only, apply)
  end

  @spec guard_current_usage_probe_completion(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          fence(),
          probe_completion_mode(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_current_usage_probe_completion(identity_or_id, fence, mode, apply)
      when mode in [:active_only, :auth_failure] and is_function(apply, 1) do
    Repo.transaction(fn ->
      identity_or_id
      |> lock_credential_replacement()
      |> guard_current_probe_completion(fence, mode, apply)
    end)
    |> normalize_guarded_probe_completion()
  end

  @spec guard_active_reconciliation(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_active_reconciliation(identity_or_id, apply) when is_function(apply, 1) do
    guard_active_reconciliation(identity_or_id, :active_only, apply)
  end

  @spec guard_active_reconciliation(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          probe_completion_mode(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_active_reconciliation(identity_or_id, mode, apply)
      when mode in [:active_only, :auth_failure] and is_function(apply, 1) do
    Repo.transaction(fn ->
      case lock_credential_replacement(identity_or_id) do
        nil ->
          Repo.rollback(:upstream_identity_not_found)

        %UpstreamIdentity{status: @active} = identity ->
          apply_guarded_completion(identity, apply)

        %UpstreamIdentity{status: @refresh_failed} = identity when mode == :auth_failure ->
          apply_guarded_completion(identity, apply)

        identity ->
          {:superseded, identity, nil}
      end
    end)
    |> normalize_guarded_probe_completion()
  end

  @spec guard_active_reconciliation_epoch(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          non_neg_integer(),
          (UpstreamIdentity.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, guarded_result(), UpstreamIdentity.t(), term() | nil} | {:error, term()}
  def guard_active_reconciliation_epoch(identity_or_id, expected_credential_epoch, apply)
      when is_integer(expected_credential_epoch) and is_function(apply, 1) do
    Repo.transaction(fn ->
      case lock_credential_replacement(identity_or_id) do
        nil ->
          Repo.rollback(:upstream_identity_not_found)

        %UpstreamIdentity{status: @active} = identity ->
          apply_guarded_epoch_completion(identity, expected_credential_epoch, apply)

        identity ->
          {:superseded, identity, nil}
      end
    end)
    |> normalize_guarded_probe_completion()
  end

  defp apply_guarded_epoch_completion(identity, expected_credential_epoch, apply) do
    if current_credential_epoch?(identity, expected_credential_epoch) do
      apply_guarded_completion(identity, apply)
    else
      {:superseded, identity, nil}
    end
  end

  defp guard_active_probe_completion(nil, _fence, _mode, _apply),
    do: Repo.rollback(:upstream_identity_not_found)

  defp guard_active_probe_completion(identity, fence, mode, apply) do
    case completion_fence_position(identity, fence) do
      position when position in [:advance, :continue] ->
        if probe_completion_status_allowed?(identity, fence, mode) do
          apply_guarded_probe_completion(identity, fence, position, apply)
        else
          {:superseded, identity, nil}
        end

      _position ->
        {:superseded, identity, nil}
    end
  end

  defp guard_current_probe_completion(nil, _fence, _mode, _apply),
    do: Repo.rollback(:upstream_identity_not_found)

  defp guard_current_probe_completion(identity, fence, mode, apply) do
    if current_completion_fence?(identity, fence) and
         probe_completion_status_allowed?(identity, fence, mode) do
      apply_guarded_completion(identity, apply)
    else
      {:superseded, identity, nil}
    end
  end

  defp probe_completion_status_allowed?(%UpstreamIdentity{status: @active}, _fence, _mode),
    do: true

  defp probe_completion_status_allowed?(
         %UpstreamIdentity{status: @refresh_failed},
         _fence,
         :auth_failure
       ),
       do: true

  defp probe_completion_status_allowed?(
         %UpstreamIdentity{status: @reauth_required} = identity,
         fence,
         :auth_failure
       ) do
    metadata = initialize_metadata(identity.metadata)

    metadata[@credential_epoch_key] == fence.credential_epoch and
      (provider_auth_recovery_status(metadata) != "terminal" or
         metadata[@applied_sequence_key] == fence.usage_probe_sequence)
  end

  defp probe_completion_status_allowed?(_identity, _fence, _mode), do: false

  defp apply_guarded_probe_completion(identity, fence, _position, apply) do
    case apply.(identity) do
      {:ok, value} ->
        identity = identity |> Repo.reload!() |> persist_probe_completion!(fence)
        {:applied, identity, value}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_guarded_completion(identity, apply) do
    case apply.(identity) do
      {:ok, value} -> {:applied, Repo.reload!(identity), value}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp completion_fence_position(identity, fence) do
    metadata = initialize_metadata(identity.metadata)
    sequence = fence.usage_probe_sequence

    cond do
      metadata[@credential_epoch_key] != fence.credential_epoch -> :superseded
      sequence <= metadata[@completed_sequence_key] -> :superseded
      sequence < metadata[@applied_sequence_key] -> :superseded
      sequence == metadata[@applied_sequence_key] -> :continue
      true -> :advance
    end
  end

  defp persist_probe_completion!(identity, fence) do
    metadata = initialize_metadata(identity.metadata)

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(metadata, @completed_sequence_key, fence.usage_probe_sequence),
      updated_at: now()
    })
    |> Repo.update!()
  end

  defp current_completion_fence?(identity, fence) do
    metadata = initialize_metadata(identity.metadata)
    sequence = fence.usage_probe_sequence

    metadata[@credential_epoch_key] == fence.credential_epoch and
      metadata[@completed_sequence_key] == sequence and
      metadata[@applied_sequence_key] <= sequence
  end

  defp normalize_guarded_probe_completion({:ok, {:applied, identity, value}}),
    do: {:ok, :applied, Repo.reload!(identity), value}

  defp normalize_guarded_probe_completion({:ok, {:superseded, identity, nil}}),
    do: {:ok, :superseded, Repo.reload!(identity), nil}

  defp normalize_guarded_probe_completion({:error, reason}), do: {:error, reason}

  defp persist_usage_success(identity, fence, persist) do
    case persist.(identity) do
      {:ok, value} ->
        recovery_assignment_ids = pending_provider_auth_recovery_assignment_ids(identity.metadata)
        identity = identity |> Repo.reload!() |> persist_usage_success_state!(fence)
        recover_assignments_after_provider_auth_relink!(identity, recovery_assignment_ids)
        {:applied, identity, value}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp persist_usage_success_state!(identity, fence) do
    timestamp = now()

    identity
    |> UpstreamIdentity.changeset(%{
      status: usage_success_status(identity, timestamp),
      disabled_at: usage_success_disabled_at(identity),
      metadata:
        identity.metadata
        |> applied_metadata(fence)
        |> mark_provider_auth_recovered(timestamp),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp usage_success_status_allowed?(%UpstreamIdentity{status: @deleted}, _fence), do: false

  defp usage_success_status_allowed?(%UpstreamIdentity{status: @reauth_required} = identity, fence) do
    metadata = initialize_metadata(identity.metadata)
    recovery = Map.get(metadata, @provider_auth_recovery_key, %{})

    metadata[@credential_epoch_key] == fence.credential_epoch and
      (provider_auth_recovery_status(metadata) in ["awaiting_fresh_quota", "recovered"] or
         (provider_auth_recovery_status(metadata) == "terminal" and
            recovery["max_pre_rejection_credential_epoch"] == fence.credential_epoch and
            is_integer(recovery["max_pre_rejection_probe_sequence"]) and
            fence.usage_probe_sequence <= recovery["max_pre_rejection_probe_sequence"]))
  end

  defp usage_success_status_allowed?(_identity, _fence), do: true

  defp definitive_rejection_applicable?(%UpstreamIdentity{status: @reauth_required} = identity) do
    provider_auth_recovery_status(initialize_metadata(identity.metadata)) in [
      "terminal",
      "awaiting_fresh_quota",
      "recovered"
    ]
  end

  defp definitive_rejection_applicable?(_identity), do: true

  defp usage_success_applicable?(identity, fence) do
    not Map.has_key?(identity.metadata || %{}, "permanent_deletion_requested_at") and
      current_fence?(identity, fence) and usage_success_status_allowed?(identity, fence)
  end

  defp usage_success_status(%UpstreamIdentity{status: @paused}, _timestamp), do: @paused
  defp usage_success_status(%UpstreamIdentity{status: @refresh_failed}, _timestamp), do: @refresh_failed

  defp usage_success_status(identity, timestamp) do
    if active_token_refresh?(identity, timestamp), do: @refreshing, else: @active
  end

  defp usage_success_disabled_at(%UpstreamIdentity{status: status, disabled_at: disabled_at})
       when status in [@paused, @refresh_failed],
       do: disabled_at

  defp usage_success_disabled_at(_identity), do: nil

  defp provider_auth_rejection_assignments(identity_id) do
    Repo.all(
      from(assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status != ^@assignment_deleted,
        order_by: [asc: assignment.id]
      )
    )
  end

  defp demote_assignments_for_provider_auth_rejection!(assignments, timestamp) do
    Enum.each(assignments, fn assignment ->
      assignment
      |> PoolUpstreamAssignment.changeset(%{
        health_status: @assignment_disabled,
        eligibility_status: @assignment_ineligible,
        disabled_at: timestamp,
        updated_at: timestamp
      })
      |> Repo.update!()
    end)
  end

  defp recover_assignments_after_provider_auth_relink!(identity, recovery_assignment_ids) do
    if provider_auth_recovery_status(identity.metadata) == "recovered" and
         recovery_assignment_ids != [] do
      timestamp = now()

      Repo.all(
        from(assignment in PoolUpstreamAssignment,
          where:
            assignment.upstream_identity_id == ^identity.id and
              assignment.status == ^PoolUpstreamAssignment.active_status() and
              assignment.id in ^recovery_assignment_ids,
          order_by: [asc: assignment.id]
        )
      )
      |> Enum.each(fn assignment ->
        assignment
        |> PoolUpstreamAssignment.changeset(%{
          health_status: @assignment_health_active,
          eligibility_status: @assignment_eligible,
          cooldown_until: nil,
          disabled_at: nil,
          updated_at: timestamp
        })
        |> Repo.update!()
      end)
    end

    :ok
  end

  defp pending_provider_auth_recovery_assignment_ids(%{} = metadata) do
    case Map.get(metadata, @provider_auth_recovery_key) do
      %{
        "status" => status,
        "demoted_assignment_ids" => assignment_ids
      }
      when status in ["terminal", "awaiting_fresh_quota"] and is_list(assignment_ids) ->
        Enum.filter(assignment_ids, &is_binary/1)

      _recovery ->
        []
    end
  end

  defp pending_provider_auth_recovery_assignment_ids(_metadata), do: []

  defp current_fence?(identity, fence) do
    metadata = initialize_metadata(identity.metadata)

    metadata[@credential_epoch_key] == fence.credential_epoch and
      fence.usage_probe_sequence > metadata[@applied_sequence_key]
  end

  defp applied_metadata(metadata, fence) do
    metadata
    |> initialize_metadata()
    |> Map.put(@applied_sequence_key, fence.usage_probe_sequence)
  end

  defp provider_rejection_metadata(metadata, timestamp) do
    replacement = %{
      "status" => "reauth_required",
      "trigger_kind" => "account_reconciliation",
      "completed_at" => DateTime.to_iso8601(timestamp),
      "reason" => %{
        "code" => "provider_usage_auth_rejected",
        "message" => "provider usage authentication was rejected"
      }
    }

    Map.put(
      metadata,
      "token_refresh",
      TokenRefreshMetadata.preserve_access_token_expiry(metadata, replacement)
    )
  end

  defp preserve_terminal_provider_auth_rejection(metadata) do
    case provider_auth_recovery_status(metadata) do
      "terminal" -> put_provider_auth_recovery(metadata, "awaiting_fresh_quota", now())
      _status -> metadata
    end
  end

  defp mark_provider_auth_recovered(metadata, timestamp) do
    case provider_auth_recovery_status(metadata) do
      status when status in ["terminal", "awaiting_fresh_quota"] ->
        put_provider_auth_recovery(metadata, "recovered", timestamp)

      _status ->
        metadata
    end
  end

  defp put_provider_auth_recovery(metadata, status, timestamp) do
    recovery =
      metadata
      |> Map.get(@provider_auth_recovery_key, %{})
      |> Map.put("status", status)
      |> Map.put("updated_at", DateTime.to_iso8601(timestamp))
      |> maybe_put_terminal_provider_auth_rejection(metadata)

    Map.put(metadata, @provider_auth_recovery_key, recovery)
  end

  defp put_provider_auth_recovery_assignment_ids(metadata, assignments) do
    assignment_ids = Enum.map(assignments, & &1.id)

    Map.update!(metadata, @provider_auth_recovery_key, fn recovery ->
      Map.put(recovery, "demoted_assignment_ids", assignment_ids)
    end)
  end

  defp put_provider_auth_recovery_probe_ceiling(metadata) do
    recovery = Map.get(metadata, @provider_auth_recovery_key, %{})
    current_sequence = initialize_metadata(metadata)[@probe_sequence_key]
    current_epoch = initialize_metadata(metadata)[@credential_epoch_key]
    previous_ceiling = recovery["max_pre_rejection_probe_sequence"]
    previous_epoch = recovery["max_pre_rejection_credential_epoch"]
    previous_status = recovery["status"]

    ceiling =
      if previous_status == "terminal" and previous_epoch == current_epoch and is_integer(previous_ceiling),
        do: min(previous_ceiling, current_sequence),
        else: current_sequence

    recovery =
      recovery
      |> Map.put("max_pre_rejection_credential_epoch", current_epoch)
      |> Map.put("max_pre_rejection_probe_sequence", ceiling)

    Map.put(metadata, @provider_auth_recovery_key, recovery)
  end

  defp maybe_put_terminal_provider_auth_rejection(recovery, metadata) do
    case Map.get(metadata, "token_refresh") do
      %{"status" => "reauth_required"} = terminal -> Map.put(recovery, "last_terminal", terminal)
      _token_refresh -> recovery
    end
  end

  defp provider_auth_recovery_status(%{} = metadata) do
    case Map.get(metadata, @provider_auth_recovery_key) do
      %{"status" => status} when is_binary(status) -> status
      _recovery -> nil
    end
  end

  defp provider_auth_recovery_status(_metadata), do: nil

  defp lock_identity(identity_id) when is_binary(identity_id) do
    Repo.one(
      from(identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_identity(_identity_id), do: nil

  defp lock_assignments(identity_id) do
    Repo.all(
      from(assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status != ^@assignment_deleted,
        order_by: [asc: assignment.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_active_secrets(identity_id) do
    Repo.all(
      from(secret in EncryptedSecret,
        where: secret.upstream_identity_id == ^identity_id and secret.status == ^@secret_active,
        order_by: [asc: secret.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp broadcast_upstream_change(%UpstreamIdentity{} = identity, reason) do
    identity.id
    |> assignments_for_identity()
    |> Enum.each(fn assignment ->
      Events.broadcast_upstreams_after_commit(assignment.pool_id, reason, %{
        assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        upstream_status: identity.status,
        assignment_status: assignment.status
      })
    end)
  end

  defp assignments_for_identity(identity_id) do
    Repo.all(
      from(assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status != ^@assignment_deleted,
        order_by: [asc: assignment.created_at, asc: assignment.id]
      )
    )
  end

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp replacement_epoch(status, :error) when status == @pending, do: {:ok, 1}
  defp replacement_epoch(status, :error) when status != @pending, do: {:ok, 2}

  defp replacement_epoch(@pending, {:ok, epoch}) when is_integer(epoch) and epoch > 0,
    do: {:ok, epoch}

  defp replacement_epoch(_status, {:ok, epoch}) when is_integer(epoch) and epoch > 0,
    do: {:ok, epoch + 1}

  defp replacement_epoch(_status, _epoch), do: :error

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_identity), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
