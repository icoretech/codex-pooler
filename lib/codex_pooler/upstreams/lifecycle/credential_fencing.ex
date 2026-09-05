defmodule CodexPooler.Upstreams.Lifecycle.CredentialFencing do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.Lifecycle.IdentitySlotLock
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @credential_epoch_key "credential_epoch"
  @probe_sequence_key "usage_probe_sequence"
  @applied_sequence_key "usage_probe_applied_sequence"
  @completed_sequence_key "usage_probe_completed_sequence"
  @provider_auth_recovery_key "provider_auth_recovery"
  @assignment_deleted AssignmentStatus.deleted_status()
  @assignment_health_active AssignmentStatus.active_health_status()
  @assignment_disabled AssignmentStatus.disabled_health_status()
  @assignment_eligible AssignmentStatus.eligible_status()
  @assignment_ineligible AssignmentStatus.ineligible_status()
  @active IdentityStatus.active_status()
  @pending IdentityStatus.pending_status()
  @refresh_failed IdentityStatus.refresh_failed_status()
  @reauth_required IdentityStatus.reauth_required_status()

  @type fence :: %{
          required(:credential_epoch) => pos_integer(),
          required(:usage_probe_sequence) => pos_integer()
        }
  @type guarded_result :: :applied | :superseded
  @type probe_completion_mode :: :active_only | :auth_failure

  @spec initialize_metadata(map() | nil) :: map()
  def initialize_metadata(metadata) do
    metadata
    |> normalize_metadata()
    |> Map.put_new(@credential_epoch_key, 1)
    |> Map.put_new(@probe_sequence_key, 0)
    |> Map.put_new(@applied_sequence_key, 0)
    |> Map.put_new(@completed_sequence_key, 0)
  end

  @spec advance_credential_epoch(UpstreamIdentity.t()) :: map()
  def advance_credential_epoch(%UpstreamIdentity{} = identity) do
    metadata = initialize_metadata(identity.metadata)

    metadata
    |> Map.put(@credential_epoch_key, metadata[@credential_epoch_key] + 1)
    |> preserve_terminal_provider_auth_rejection()
  end

  @spec prepare_replacement_metadata(UpstreamIdentity.t()) ::
          {:ok, map(), pos_integer()} | {:error, %{code: atom(), message: String.t()}}
  def prepare_replacement_metadata(%UpstreamIdentity{} = identity) do
    metadata = normalize_metadata(identity.metadata)

    case replacement_epoch(identity.status, Map.fetch(metadata, @credential_epoch_key)) do
      {:ok, epoch} ->
        metadata =
          metadata
          |> initialize_metadata()
          |> Map.put(@credential_epoch_key, epoch)
          |> preserve_terminal_provider_auth_rejection()

        {:ok, metadata, epoch}

      :error ->
        {:error, %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}}
    end
  end

  @spec advance_credential_epoch_preserving_expiry(UpstreamIdentity.t()) :: map()
  def advance_credential_epoch_preserving_expiry(%UpstreamIdentity{} = identity) do
    old_metadata = normalize_metadata(identity.metadata)
    old_epoch = old_metadata[@credential_epoch_key]
    advanced = advance_credential_epoch(identity)

    TokenRefreshMetadata.rebind_access_token_expiry(
      advanced,
      old_epoch,
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
    Secrets.lock_encrypted_secrets(identity.id)
    identity
  end

  @spec mark_definitive_rejection(UpstreamIdentity.t() | Ecto.UUID.t(), fence()) ::
          {:ok, guarded_result(), UpstreamIdentity.t()} | {:error, term()}
  def mark_definitive_rejection(identity_or_id, fence) do
    Repo.transaction(fn ->
      identity = lock_credential_replacement(identity_or_id)

      cond do
        is_nil(identity) ->
          Repo.rollback(:upstream_identity_not_found)

        not current_fence?(identity, fence) ->
          {:superseded, identity}

        true ->
          timestamp = now()
          assignments = provider_auth_rejection_assignments(identity.id)

          metadata =
            identity.metadata
            |> applied_metadata(fence)
            |> provider_rejection_metadata(timestamp)
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
    end)
    |> case do
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

        not current_fence?(identity, fence) ->
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
      status: @active,
      disabled_at: nil,
      metadata:
        identity.metadata
        |> applied_metadata(fence)
        |> mark_provider_auth_recovered(timestamp),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

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
