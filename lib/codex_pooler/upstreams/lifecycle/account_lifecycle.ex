defmodule CodexPooler.Upstreams.Lifecycle.AccountLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Lifecycle.{AccountAudit, CredentialFencing}
  alias CodexPooler.Upstreams.Secrets

  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @active UpstreamIdentity.active_status()
  @paused UpstreamIdentity.paused_status()
  @refresh_due UpstreamIdentity.refresh_due_status()
  @refreshing UpstreamIdentity.refreshing_status()
  @refresh_failed UpstreamIdentity.refresh_failed_status()
  @reauth_required UpstreamIdentity.reauth_required_status()
  @deleted UpstreamIdentity.deleted_status()
  @assignment_pending PoolUpstreamAssignment.pending_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_paused PoolUpstreamAssignment.paused_status()
  @assignment_refresh_due PoolUpstreamAssignment.refresh_due_status()
  @assignment_refresh_failed PoolUpstreamAssignment.refresh_failed_status()
  @assignment_deleted PoolUpstreamAssignment.deleted_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @ineligible PoolUpstreamAssignment.ineligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @health_disabled PoolUpstreamAssignment.disabled_health_status()
  @reactivatable_statuses [@active, @paused, @refresh_due, @refresh_failed]
  @reactivatable_assignment_statuses [
    @assignment_pending,
    @assignment_active,
    @assignment_paused,
    @assignment_refresh_due,
    @assignment_refresh_failed
  ]

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type lifecycle_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()

  @spec rename_account(identity_ref(), map()) :: lifecycle_result()
  defp rename_account(identity_or_id, attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        timestamp = Map.get(attrs, :renamed_at, now())

        identity
        |> UpstreamIdentity.changeset(%{
          account_label: rename_label_attr(attrs, identity.account_label),
          updated_at: timestamp
        })
        |> Repo.update()
        |> case do
          {:ok, renamed_identity} -> {:ok, lifecycle_result(:renamed, renamed_identity)}
          {:error, changeset} -> {:error, changeset}
        end
        |> tap_upstream_change("upstream_account_renamed")

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  @spec rename_account_for_scope(Scope.t(), identity_ref(), map()) :: lifecycle_result()
  def rename_account_for_scope(%Scope{} = scope, identity_or_id, attrs) when is_map(attrs) do
    with {:ok, identity} <- authorize(scope, identity_or_id) do
      rename_account(identity, attrs)
      |> AccountAudit.record_change(scope, "upstream_account.rename",
        previous_label: identity.account_label,
        previous_status: identity.status
      )
    end
  end

  def rename_account_for_scope(_scope, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "user scope is required")}

  @spec pause_account(identity_ref(), map()) :: lifecycle_result()
  defp pause_account(identity_or_id, attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        attrs = atomize_attrs(attrs)
        timestamp = Map.get(attrs, :paused_at, now())

        Repo.transaction(fn ->
          locked_identity = CredentialFencing.lock_credential_replacement(identity.id)

          paused_identity =
            locked_identity
            |> UpstreamIdentity.changeset(%{
              status: @paused,
              disabled_at: timestamp,
              updated_at: timestamp,
              metadata:
                locked_identity
                |> CredentialFencing.advance_credential_epoch()
                |> lifecycle_metadata("paused", attrs, timestamp)
            })
            |> Repo.update!()

          update_assignments_for_identity(locked_identity.id, %{
            status: @paused,
            health_status: @health_disabled,
            eligibility_status: @ineligible,
            disabled_at: timestamp,
            updated_at: timestamp
          })

          lifecycle_result(:paused, paused_identity)
        end)
        |> tap_upstream_change("upstream_account_paused")

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  @spec pause_account_for_scope(Scope.t(), identity_ref(), map()) :: lifecycle_result()
  def pause_account_for_scope(%Scope{} = scope, identity_or_id, attrs) when is_map(attrs) do
    with {:ok, identity} <- authorize(scope, identity_or_id) do
      pause_account(identity, attrs)
      |> AccountAudit.record_change(scope, "upstream_account.pause",
        previous_status: identity.status
      )
    end
  end

  def pause_account_for_scope(_scope, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "user scope is required")}

  @spec reactivate_account(identity_ref(), map()) :: lifecycle_result()
  defp reactivate_account(identity_or_id, attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        attrs = atomize_attrs(attrs)
        timestamp = Map.get(attrs, :reactivated_at, now())

        Repo.transaction(fn -> reactivate_locked_account(identity.id, attrs, timestamp) end)
        |> tap_upstream_change("upstream_account_reactivated")

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp reactivate_locked_account(identity_id, attrs, timestamp) do
    identity = CredentialFencing.lock_credential_replacement(identity_id)

    with %UpstreamIdentity{} = identity <- identity,
         :ok <- ensure_reactivatable_identity(identity),
         :ok <- ensure_reactivation_secret(identity),
         [_ | _] = assignments <- reactivatable_assignments(identity) do
      active_identity =
        identity
        |> UpstreamIdentity.changeset(%{
          status: @active,
          auth_verified_at: Map.get(attrs, :auth_verified_at, timestamp),
          auth_fresh_at: Map.get(attrs, :auth_fresh_at, timestamp),
          disabled_at: nil,
          updated_at: timestamp,
          metadata:
            identity
            |> CredentialFencing.advance_credential_epoch()
            |> lifecycle_metadata("reactivated", attrs, timestamp)
        })
        |> Repo.update!()

      assignment_ids = Enum.map(assignments, & &1.id)

      Repo.update_all(
        from(assignment in PoolUpstreamAssignment, where: assignment.id in ^assignment_ids),
        set: [
          status: @active,
          health_status: @health_active,
          eligibility_status: @eligible,
          cooldown_until: nil,
          disabled_at: nil,
          updated_at: timestamp
        ]
      )

      lifecycle_result(:active, active_identity)
    else
      nil ->
        Repo.rollback(
          lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")
        )

      [] ->
        Repo.rollback(
          lifecycle_error(
            :upstream_assignment_not_reactivatable,
            "at least one preserved assignment is required before reactivation"
          )
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @spec reactivate_account_for_scope(Scope.t(), identity_ref(), map()) ::
          lifecycle_result()
  def reactivate_account_for_scope(%Scope{} = scope, identity_or_id, attrs) when is_map(attrs) do
    with {:ok, identity} <- authorize(scope, identity_or_id) do
      reactivate_account(identity, attrs)
      |> AccountAudit.record_change(scope, "upstream_account.reactivate",
        previous_status: identity.status
      )
    end
  end

  def reactivate_account_for_scope(_scope, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "user scope is required")}

  @spec soft_delete_account(identity_ref(), map()) :: lifecycle_result()
  defp soft_delete_account(identity_or_id, attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        attrs = atomize_attrs(attrs)
        timestamp = Map.get(attrs, :deleted_at, now())

        Repo.transaction(fn ->
          deleted_identity =
            identity
            |> UpstreamIdentity.changeset(%{
              status: @deleted,
              disabled_at: timestamp,
              updated_at: timestamp,
              metadata: lifecycle_metadata(identity.metadata, "deleted", attrs, timestamp)
            })
            |> Repo.update!()

          Secrets.revoke_active_secrets(identity.id, timestamp)

          update_assignments_for_identity(identity.id, %{
            status: @assignment_deleted,
            health_status: @health_disabled,
            eligibility_status: @ineligible,
            disabled_at: timestamp,
            updated_at: timestamp
          })

          lifecycle_result(:deleted, deleted_identity)
        end)
        |> tap_upstream_change("upstream_account_deleted")

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  @spec soft_delete_account_for_scope(Scope.t(), identity_ref(), map()) ::
          lifecycle_result()
  def soft_delete_account_for_scope(%Scope{} = scope, identity_or_id, attrs) when is_map(attrs) do
    with {:ok, identity} <- authorize(scope, identity_or_id) do
      soft_delete_account(identity, attrs)
      |> AccountAudit.record_change(scope, "upstream_account.delete",
        previous_status: identity.status
      )
    end
  end

  def soft_delete_account_for_scope(_scope, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "user scope is required")}

  @spec authorize(Scope.t(), identity_ref()) ::
          {:ok, UpstreamIdentity.t()} | {:error, lifecycle_error()}
  def authorize(%Scope{} = scope, identity_or_id) do
    with %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id),
         {:ok, pool_ids} <- lifecycle_pool_ids(identity),
         :ok <- require_lifecycle_pool_access(scope, pool_ids) do
      {:ok, identity}
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      {:error, _reason} = error ->
        error
    end
  end

  defp lifecycle_result(status, %UpstreamIdentity{} = identity) do
    identity = Repo.reload!(identity)

    %{
      status: status,
      identity: identity,
      assignments: assignments_for_identity(identity.id),
      secret_status: Secrets.secret_status(identity)
    }
  end

  defp lifecycle_metadata(metadata, event, attrs, timestamp) do
    metadata = metadata || %{}

    lifecycle = %{
      "event" => event,
      "at" => DateTime.to_iso8601(timestamp)
    }

    lifecycle =
      case Map.get(attrs, :reason) do
        reason when is_binary(reason) and reason != "" -> Map.put(lifecycle, "reason", reason)
        _reason -> lifecycle
      end

    Map.put(metadata, "last_lifecycle_transition", lifecycle)
  end

  defp lifecycle_pool_ids(%UpstreamIdentity{} = identity) do
    pool_ids =
      identity.id
      |> assignments_for_identity()
      |> Enum.reject(&(&1.status == @deleted))
      |> Enum.map(& &1.pool_id)
      |> Enum.uniq()

    case pool_ids do
      [] -> {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}
      pool_ids -> {:ok, pool_ids}
    end
  end

  defp require_any_pool_operate(%Scope{} = scope, pool_ids) when is_list(pool_ids) do
    Enum.reduce_while(pool_ids, nil, fn pool_id, _last_error ->
      case Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool_id) do
        {:ok, _decision} -> {:halt, :ok}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end) || {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}
  end

  defp require_all_pool_operate(%Scope{} = scope, pool_ids) when is_list(pool_ids) do
    Enum.reduce_while(pool_ids, :ok, fn pool_id, :ok ->
      case Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool_id) do
        {:ok, _decision} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_lifecycle_pool_access(%Scope{} = scope, pool_ids) do
    if Pools.owner?(scope) do
      require_any_pool_operate(scope, pool_ids)
    else
      require_all_pool_operate(scope, pool_ids)
    end
  end

  defp update_assignments_for_identity(identity_id, set) do
    Repo.update_all(
      from(assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status != ^@assignment_deleted
      ),
      set: Map.to_list(set)
    )
  end

  defp assignments_for_identity(identity_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.upstream_identity_id == ^identity_id,
        order_by: [asc: assignment.created_at, asc: assignment.id]
    )
  end

  defp tap_upstream_change({:ok, result} = ok, reason) do
    broadcast_upstream_change(result, reason)
    ok
  end

  defp tap_upstream_change(result, _reason), do: result

  defp broadcast_upstream_change(%{assignments: assignments} = result, reason)
       when is_list(assignments) do
    identity = Map.get(result, :identity)
    Enum.each(assignments, &broadcast_upstream_assignment(&1, identity, reason))
  end

  defp broadcast_upstream_change(%{identity: %UpstreamIdentity{} = identity}, reason) do
    identity.id
    |> assignments_for_identity()
    |> Enum.each(&broadcast_upstream_assignment(&1, identity, reason))
  end

  defp broadcast_upstream_change(_result, _reason), do: :ok

  defp broadcast_upstream_assignment(%PoolUpstreamAssignment{} = assignment, identity, reason) do
    Events.broadcast_upstreams(assignment.pool_id, reason, %{
      assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      upstream_status: identity && identity.status,
      assignment_status: assignment.status
    })
  end

  defp reactivatable_assignments(%UpstreamIdentity{id: identity_id}) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status in ^@reactivatable_assignment_statuses,
        order_by: [asc: assignment.created_at, asc: assignment.id]
    )
  end

  defp ensure_reactivatable_identity(%UpstreamIdentity{status: status})
       when status in @reactivatable_statuses,
       do: :ok

  defp ensure_reactivatable_identity(%UpstreamIdentity{status: @refreshing}) do
    {:error,
     lifecycle_error(
       :upstream_identity_refreshing,
       "refreshing upstream identities must finish before reactivation"
     )}
  end

  defp ensure_reactivatable_identity(%UpstreamIdentity{status: status})
       when status in [@reauth_required, @deleted] do
    {:error,
     lifecycle_error(
       :upstream_identity_not_reactivatable,
       "#{status} upstream identities cannot be reactivated without reconnecting/importing again"
     )}
  end

  defp ensure_reactivatable_identity(%UpstreamIdentity{}) do
    {:error,
     lifecycle_error(
       :upstream_identity_not_reactivatable,
       "upstream identity is not in a locally reactivatable state"
     )}
  end

  defp ensure_reactivation_secret(%UpstreamIdentity{} = identity) do
    case Secrets.secret_status(identity) do
      :present ->
        :ok

      status ->
        {:error,
         lifecycle_error(
           :upstream_secret_not_routable,
           "upstream access token is #{status}"
         )}
    end
  end

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp rename_label_attr(attrs, fallback) do
    case Map.fetch(attrs, :account_label) do
      {:ok, nil} -> ""
      {:ok, value} -> value
      :error -> string_rename_label_attr(attrs, fallback)
    end
  end

  defp string_rename_label_attr(attrs, fallback) do
    case Map.fetch(attrs, "account_label") do
      {:ok, nil} -> ""
      {:ok, value} -> value
      :error -> fallback
    end
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
