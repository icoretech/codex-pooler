defmodule CodexPooler.Pools do
  @moduledoc """
  Pool lifecycle, routing, membership, and upstream assignment APIs.
  """

  import Ecto.Query

  alias CodexPooler.Access.DashboardSessions
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Alerts
  alias CodexPooler.Audit
  alias CodexPooler.Events

  alias CodexPooler.Pools.{
    Authorization,
    Deletion,
    Membership,
    ModelServingModes,
    OperatorPoolAssignment,
    Pool,
    Routing,
    RoutingSettings
  }

  alias CodexPooler.Repo

  @status_active "active"
  @status_revoked "revoked"
  @status_disabled "disabled"
  @status_archived "archived"
  @management_pool_statuses [@status_active, @status_disabled, @status_archived]
  @reporting_pool_statuses [@status_active, @status_disabled]

  @type capability_key :: Authorization.capability_key()
  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type pools_result :: {:ok, [Pool.t()]} | {:error, access_error()}
  @type pool_result :: {:ok, Pool.t()} | {:error, Ecto.Changeset.t() | access_error()}
  @type membership_result ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t() | access_error() | atom()}
  @type routing_settings_result ::
          {:ok, RoutingSettings.t()} | {:error, Ecto.Changeset.t() | access_error()}
  @type capability_decision :: %{
          required(:actor_role) => String.t(),
          required(:capability) => String.t(),
          required(:pool_id) => Ecto.UUID.t() | nil
        }

  @spec capability(capability_key()) :: String.t()
  defdelegate capability(capability_key), to: Authorization

  @spec role(Authorization.role_key()) :: String.t()
  defdelegate role(role_key), to: Authorization

  @spec role_values() :: [String.t()]
  defdelegate role_values(), to: Authorization

  @spec list_pools(term()) :: pools_result()
  def list_pools(%Scope{} = scope) do
    Authorization.list_pools_for_capability(scope, capability(:pool_operate), [@status_active])
  end

  def list_pools(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_visible_pools(term()) :: [Pool.t()]
  def list_visible_pools(scope) do
    case list_pools(scope) do
      {:ok, pools} -> pools
      {:error, _reason} -> []
    end
  end

  @spec list_log_filter_pools(term()) :: [Pool.t()]
  def list_log_filter_pools(%Scope{} = scope) do
    statuses = if owner?(scope), do: @management_pool_statuses, else: @reporting_pool_statuses

    case Authorization.list_pools_for_capability(scope, capability(:pool_operate), statuses) do
      {:ok, pools} ->
        pools

      {:error, _reason} ->
        []
    end
  end

  def list_log_filter_pools(_scope), do: []

  @spec list_reporting_pools(term()) :: {:ok, [Pool.t()]} | {:error, access_error()}
  def list_reporting_pools(%Scope{} = scope) do
    Authorization.list_pools_for_capability(
      scope,
      capability(:pool_operate),
      @reporting_pool_statuses
    )
  end

  def list_reporting_pools(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_pools_for_management(Scope.t()) :: {:ok, [Pool.t()]} | {:error, access_error()}
  def list_pools_for_management(%Scope{} = scope) do
    case require_capability(scope, capability(:pool_manage)) do
      {:ok, _decision} ->
        {:ok, Repo.all(from p in Pool, order_by: [asc: p.created_at])}

      {:error, %{code: :capability_denied}} ->
        Authorization.list_pools_for_capability(scope, capability(:pool_operate), [@status_active])

      {:error, _reason} = error ->
        error
    end
  end

  def list_pools_for_management(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec model_serving_modes_snapshot(Scope.t(), pool_ref()) ::
          {:ok, ModelServingModes.snapshot()} | {:error, access_error()}
  defdelegate model_serving_modes_snapshot(scope, pool_or_id),
    to: ModelServingModes,
    as: :snapshot

  @spec model_serving_modes_by_pool_ids([Ecto.UUID.t() | nil]) :: map()
  defdelegate model_serving_modes_by_pool_ids(pool_ids), to: ModelServingModes, as: :by_pool_ids

  @spec update_model_serving_modes(Scope.t(), pool_ref(), [map()], String.t()) ::
          {:ok, ModelServingModes.update_result()} | {:error, access_error()}
  defdelegate update_model_serving_modes(scope, pool_or_id, submitted_rows, expected_revision),
    to: ModelServingModes,
    as: :update

  @spec can_manage_pools?(Scope.t()) :: boolean()
  def can_manage_pools?(%Scope{} = scope) do
    match?({:ok, _decision}, require_capability(scope, capability(:pool_manage)))
  end

  def can_manage_pools?(_scope), do: false

  @spec can_operate_pools?(Scope.t()) :: boolean()
  def can_operate_pools?(%Scope{} = scope) do
    match?({:ok, _pools}, list_pools(scope))
  end

  def can_operate_pools?(_scope), do: false

  @spec owner?(term()) :: boolean()
  defdelegate owner?(scope), to: Authorization

  @spec assigned_pool?(term(), term()) :: boolean()
  defdelegate assigned_pool?(scope, pool_or_id), to: Authorization

  @spec list_assigned_pool_ids(term()) :: [Ecto.UUID.t()]
  defdelegate list_assigned_pool_ids(scope), to: Authorization

  @spec list_pool_operator_ids(pool_ref()) :: [Ecto.UUID.t()]
  defdelegate list_pool_operator_ids(pool_or_id), to: Authorization

  @spec list_active_pools() :: [Pool.t()]
  def list_active_pools do
    Repo.all(from p in Pool, where: p.status == ^@status_active, order_by: [asc: p.created_at])
  end

  @spec get_pool(term()) :: Pool.t() | nil
  def get_pool(id) when is_binary(id), do: Repo.get(Pool, id)
  def get_pool(_id), do: nil

  @spec get_active_pool(term()) :: Pool.t() | nil
  def get_active_pool(id) when is_binary(id) do
    Repo.one(from p in Pool, where: p.id == ^id and p.status == ^@status_active)
  end

  def get_active_pool(_id), do: nil

  @spec get_routing_settings(pool_ref()) :: RoutingSettings.t() | nil
  defdelegate get_routing_settings(pool_or_id), to: Routing

  @spec routing_settings_with_defaults(pool_ref()) :: RoutingSettings.t() | nil
  defdelegate routing_settings_with_defaults(pool_or_id), to: Routing

  @spec v1_compatibility_enabled?(pool_ref()) :: boolean()
  defdelegate v1_compatibility_enabled?(pool_or_id), to: Routing

  @spec allow_image_generation?(pool_ref()) :: boolean()
  defdelegate allow_image_generation?(pool_or_id), to: Routing

  @spec ensure_routing_settings(pool_ref()) :: RoutingSettings.t() | nil
  defdelegate ensure_routing_settings(pool_or_id), to: Routing

  @spec routing_settings_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => RoutingSettings.t()
        }
  defdelegate routing_settings_by_pool_ids(pool_ids), to: Routing

  @spec update_routing_settings(Scope.t(), Pool.t(), map(), keyword()) ::
          routing_settings_result()
  defdelegate update_routing_settings(scope, pool, attrs, opts \\ []), to: Routing

  @spec create_pool(Scope.t(), map(), keyword()) :: pool_result()
  def create_pool(scope, attrs, opts \\ [])

  def create_pool(%Scope{} = scope, attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)) do
      now = now()

      %Pool{}
      |> Pool.changeset(%{
        slug: Map.get(attrs, :slug) || Map.get(attrs, "slug"),
        name: Map.get(attrs, :name) || Map.get(attrs, "name"),
        status: Map.get(attrs, :status) || Map.get(attrs, "status") || @status_active,
        created_by_user_id: scope.user.id,
        created_at: now,
        updated_at: now
      })
      |> Repo.insert()
      |> tap(fn
        {:ok, pool} ->
          record_pool_audit_event(scope, "pool.create", pool)

          maybe_broadcast_pool_change(opts, pool, "pool_created")
          maybe_invalidate_notifications_after_status_change(opts, nil, pool)

        _result ->
          :ok
      end)
    end
  end

  def create_pool(_scope, _attrs, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec update_pool(Scope.t(), pool_ref(), map(), keyword()) :: pool_result()
  def update_pool(scope, pool_or_id, attrs, opts \\ [])

  def update_pool(%Scope{} = scope, pool_or_id, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, update_attrs} <- pool_update_attrs(attrs),
         {:ok, _decision} <- require_pool_update_capability(scope, pool, update_attrs) do
      now = now()
      previous_status = pool.status

      update_pool_and_revoke_archived_assignments(
        pool,
        Map.put(update_attrs, :updated_at, now),
        now
      )
      |> tap(fn
        {:ok, pool} ->
          record_pool_audit_event(scope, "pool.update", pool, %{
            changed_fields: Map.keys(update_attrs) |> Enum.map(&to_string/1) |> Enum.sort(),
            name: pool.name,
            status: pool.status
          })

          maybe_broadcast_pool_change(opts, pool, "pool_updated")
          maybe_invalidate_notifications_after_status_change(opts, previous_status, pool)

        _result ->
          :ok
      end)
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def update_pool(_scope, _pool_or_id, _attrs, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec change_pool_status(Scope.t(), pool_ref(), String.t()) :: pool_result()
  def change_pool_status(%Scope{} = scope, pool_or_id, status) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)),
         %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, status} <- normalize_pool_status(status) do
      now = now()
      previous_status = pool.status

      update_pool_and_revoke_archived_assignments(
        pool,
        %{
          status: status,
          disabled_at: pool_status_disabled_at(status),
          updated_at: now
        },
        now
      )
      |> tap(fn
        {:ok, pool} ->
          record_pool_audit_event(scope, "pool.status_update", pool, %{
            previous_status: previous_status,
            status: pool.status
          })

          Events.broadcast_pools(pool.id, "pool_status_updated", %{
            pool_id: pool.id,
            status: pool.status
          })

          invalidate_notifications_after_status_change(previous_status, pool)

        _result ->
          :ok
      end)
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def change_pool_status(_scope, _pool_or_id, _status),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @doc """
  Deletes an archived Pool after an exact slug confirmation. A Pool with little history is deleted
  at once (`{:ok, pool}`); a larger one is handed to a background deletion job (`{:deleting, pool}`)
  and disappears when its history is gone. Either way the `pool.delete` audit event is written in
  the transaction that deletes the Pool row (findings#206 rows 206-550 and 206-551).
  """
  @spec delete_archived_pool(Scope.t(), pool_ref(), String.t() | nil) ::
          pool_result() | {:deleting, Pool.t()}
  def delete_archived_pool(%Scope{} = scope, pool_or_id, confirmation_slug) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)),
         %Pool{} = pool <- normalize_pool(pool_or_id),
         :ok <- ensure_archived_pool(pool),
         :ok <- ensure_confirmation_slug(pool, confirmation_slug) do
      # The Pool's alert incident targets go with it by database cascade.
      Alerts.invalidate_notifications_after_cascade({:pool, pool.id}, fn -> request_deletion(scope, pool) end)
      |> case do
        {:ok, deleted_pool} ->
          broadcast_pool_deleted(deleted_pool)
          {:ok, deleted_pool}

        {:error, {:deleting, pool}} ->
          Events.broadcast_pools(pool.id, "pool_deletion_started", %{pool_id: pool.id})
          {:deleting, pool}

        {:error, _reason} = error ->
          error
      end
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def delete_archived_pool(_scope, _pool_or_id, _confirmation_slug),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  # A scheduled deletion deleted nothing yet, so it leaves the notification centers alone.
  defp request_deletion(scope, pool) do
    case Deletion.request(scope_user(scope), pool) do
      {:deleting, pool} -> {:error, {:deleting, pool}}
      {:error, reason} -> {:error, deletion_error(reason)}
      {:ok, _deleted} = deleted -> deleted
    end
  end

  @doc """
  Continues a scheduled Pool deletion for `CodexPooler.Jobs.PoolDeletionWorker`: deletes history
  batches until `deadline` (monotonic milliseconds), then the Pool row with its audit event.
  Returns `:more` while history is left, `:deleted` when the Pool is gone, `:gone` when there was
  nothing to delete, `{:cancel, reason}` when the Pool is no longer archived.
  """
  @spec continue_pool_deletion(Ecto.UUID.t(), Ecto.UUID.t() | nil, integer()) ::
          :more | :deleted | :gone | {:cancel, :pool_not_archived} | {:error, term()}
  def continue_pool_deletion(pool_id, requested_by_user_id, deadline) when is_binary(pool_id) do
    case Repo.get(Pool, pool_id) do
      nil ->
        :gone

      %Pool{status: @status_archived} ->
        with :done <- Deletion.purge_history(pool_id, deadline) do
          finish_pool_deletion(pool_id, requested_by_user_id)
        end

      %Pool{} ->
        {:cancel, :pool_not_archived}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  defp finish_pool_deletion(pool_id, requested_by_user_id) do
    Alerts.invalidate_notifications_after_cascade({:pool, pool_id}, fn -> Deletion.finish(pool_id, requested_by_user_id) end)
    |> case do
      {:ok, deleted_pool} ->
        broadcast_pool_deleted(deleted_pool)
        :deleted

      {:error, :pool_not_found} ->
        :gone

      {:error, :pool_not_archived} ->
        {:cancel, :pool_not_archived}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Tells open admin pages that a Pool's deletion job gave up; the Pool stays archived."
  @spec broadcast_pool_deletion_failed(Ecto.UUID.t()) :: term()
  def broadcast_pool_deletion_failed(pool_id) when is_binary(pool_id),
    do: Events.broadcast_pools(pool_id, "pool_deletion_failed", %{pool_id: pool_id})

  @doc """
  The deletion state of each listed Pool that has one: `:in_progress` while a deletion job owns
  it, `:failed` when its last deletion job gave up and the Pool is still archived.
  """
  @spec pool_deletion_states([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => Deletion.state()}
  defdelegate pool_deletion_states(pool_ids), to: Deletion, as: :states

  defp broadcast_pool_deleted(%Pool{} = deleted_pool) do
    Events.broadcast_pools(deleted_pool.id, "pool_deleted", %{
      pool_id: deleted_pool.id,
      status: deleted_pool.status
    })
  end

  defp scope_user(%Scope{user: %User{} = user}), do: user
  defp scope_user(%Scope{}), do: nil

  defp deletion_error(:pool_not_found), do: access_error(:pool_not_found, "pool was not found")
  defp deletion_error(:pool_not_archived), do: access_error(:pool_not_archived, "pool must be archived before deletion")
  defp deletion_error(reason), do: reason

  @doc """
  Invalidates the notification centers after a committed Pool status change,
  and does nothing when the status did not change: a notification center shows
  only active Pools' incidents, so a status change changes which ones a viewer
  sees (findings#206 row 206-308). A created Pool had no status (`nil`): its
  operators' open pages subscribe to it, or its first incident would miss them.
  A workflow that creates or updates a Pool with `broadcast?: false` inside
  its transaction calls this after the commit.
  """
  @spec invalidate_notifications_after_status_change(String.t() | nil, Pool.t()) :: :ok
  def invalidate_notifications_after_status_change(status, %Pool{status: status}), do: :ok

  def invalidate_notifications_after_status_change(_previous_status, %Pool{id: pool_id}) do
    _ = Alerts.invalidate_notifications_after_pool_status_change(pool_id)
    :ok
  end

  @spec create_membership(Scope.t(), map()) :: membership_result()
  def create_membership(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)) do
      now = now()

      %Membership{}
      |> Membership.changeset(%{
        user_id: Map.get(attrs, :user_id) || Map.get(attrs, "user_id"),
        role: Map.get(attrs, :role) || Map.get(attrs, "role"),
        status: Map.get(attrs, :status) || Map.get(attrs, "status") || @status_active,
        created_by_user_id: scope.user.id,
        created_at: now
      })
      |> Repo.insert()
    end
  end

  def create_membership(_scope, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec create_instance_admin_membership(Scope.t() | User.t(), User.t()) :: membership_result()
  def create_instance_admin_membership(%Scope{} = scope, %User{} = user) do
    create_membership(scope, %{user_id: user.id, role: role(:instance_admin)})
  end

  def create_instance_admin_membership(%User{} = actor, %User{} = user) do
    actor
    |> Scope.for_user()
    |> create_instance_admin_membership(user)
  end

  def create_instance_admin_membership(_actor, _user),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec create_instance_owner_membership(Scope.t() | User.t(), User.t()) :: membership_result()
  def create_instance_owner_membership(%Scope{} = scope, %User{} = user) do
    create_membership(scope, %{user_id: user.id, role: role(:instance_owner)})
  end

  def create_instance_owner_membership(%User{} = actor, %User{} = user) do
    actor
    |> Scope.for_user()
    |> create_instance_owner_membership(user)
  end

  def create_instance_owner_membership(_actor, _user),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_active_memberships_for_user(term()) :: [Membership.t()]
  def list_active_memberships_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id and m.status == ^@status_active,
        order_by: [asc: m.created_at]
    )
  end

  def list_active_memberships_for_user(_user_id), do: []

  @spec require_capability(Scope.t(), String.t(), keyword()) ::
          {:ok, capability_decision()} | {:error, access_error()}
  defdelegate require_capability(scope, capability, opts \\ []), to: Authorization

  @spec role_can?(String.t(), String.t()) :: boolean()
  defdelegate role_can?(role, capability), to: Authorization

  @spec access_error(atom(), String.t()) :: access_error()
  defdelegate access_error(code, message), to: Authorization

  defp normalize_pool(%Pool{} = pool), do: pool

  defp normalize_pool(id) when is_binary(id), do: Repo.get(Pool, id)

  defp normalize_pool(_id), do: nil

  defp require_pool_update_capability(scope, pool, update_attrs) do
    capability =
      if Map.has_key?(update_attrs, :status),
        do: capability(:pool_manage),
        else: capability(:pool_operate)

    require_capability(scope, capability, pool_id: pool.id)
  end

  defp pool_update_attrs(attrs) do
    with {:ok, status} <-
           normalize_optional_pool_status(Map.get(attrs, :status) || Map.get(attrs, "status")) do
      update_attrs =
        %{}
        |> maybe_put(:name, Map.get(attrs, :name) || Map.get(attrs, "name"))
        |> maybe_put(:status, status)

      update_attrs =
        case status do
          nil -> update_attrs
          _ -> Map.put(update_attrs, :disabled_at, pool_status_disabled_at(status))
        end

      {:ok, update_attrs}
    end
  end

  defp normalize_optional_pool_status(nil), do: {:ok, nil}

  defp normalize_optional_pool_status(status), do: normalize_pool_status(status)

  defp normalize_pool_status(status) when status in @management_pool_statuses,
    do: {:ok, status}

  defp normalize_pool_status(_status) do
    {:error, access_error(:invalid_status, "status must be active, disabled, or archived")}
  end

  defp pool_status_disabled_at(@status_active), do: nil
  defp pool_status_disabled_at(_status), do: now()

  @spec update_pool_and_revoke_archived_assignments(Pool.t(), map(), DateTime.t()) ::
          pool_result()
  defp update_pool_and_revoke_archived_assignments(%Pool{} = pool, attrs, now) do
    Repo.transaction(fn ->
      with :ok <- ensure_not_being_deleted(pool, Map.get(attrs, :status)),
           {:ok, pool} <-
             pool
             |> Pool.changeset(attrs)
             |> Repo.update(),
           {:ok, _revoked_count} <-
             revoke_active_operator_pool_assignments(pool, Map.get(attrs, :status), now),
           invalidated_api_keys <-
             delete_dashboard_sessions_for_inactive_pool(pool, Map.get(attrs, :status)) do
        {pool, invalidated_api_keys}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_pool_lifecycle_transaction()
  end

  # A deletion job removes an archived Pool's history in batches; the Pool must not come back
  # half-deleted. The Pool row lock orders this check against `Deletion.schedule/2`.
  defp ensure_not_being_deleted(%Pool{id: pool_id, status: @status_archived}, status)
       when is_binary(status) and status != @status_archived do
    _locked = Repo.one(from pool in Pool, where: pool.id == ^pool_id, lock: "FOR UPDATE", select: pool.id)

    if Deletion.pending?(pool_id),
      do: {:error, access_error(:pool_deletion_in_progress, "the Pool is being deleted")},
      else: :ok
  end

  defp ensure_not_being_deleted(%Pool{}, _status), do: :ok

  defp delete_dashboard_sessions_for_inactive_pool(%Pool{}, nil), do: []
  defp delete_dashboard_sessions_for_inactive_pool(%Pool{}, @status_active), do: []

  defp delete_dashboard_sessions_for_inactive_pool(%Pool{} = pool, _inactive_status) do
    DashboardSessions.delete_all_for_pool(pool.id)
  end

  defp normalize_pool_lifecycle_transaction({:ok, {%Pool{} = pool, invalidated_api_keys}}) do
    Enum.each(invalidated_api_keys, fn api_key ->
      DashboardSessions.broadcast_invalidation(api_key, "pool_status_updated")
    end)

    {:ok, pool}
  end

  defp normalize_pool_lifecycle_transaction({:error, reason}), do: {:error, reason}

  @spec revoke_active_operator_pool_assignments(Pool.t(), String.t() | nil, DateTime.t()) ::
          {:ok, non_neg_integer()}
  defp revoke_active_operator_pool_assignments(%Pool{} = pool, @status_archived, now) do
    {revoked_count, _rows} =
      Repo.update_all(
        from(assignment in OperatorPoolAssignment,
          where: assignment.pool_id == ^pool.id and assignment.status == ^@status_active
        ),
        set: [status: @status_revoked, revoked_at: now, updated_at: now]
      )

    {:ok, revoked_count}
  end

  defp revoke_active_operator_pool_assignments(%Pool{}, _status, _now), do: {:ok, 0}

  defp ensure_archived_pool(%Pool{status: @status_archived}), do: :ok

  defp ensure_archived_pool(%Pool{}),
    do: {:error, access_error(:pool_not_archived, "pool must be archived before deletion")}

  defp ensure_confirmation_slug(%Pool{slug: slug}, slug), do: :ok

  defp ensure_confirmation_slug(%Pool{}, _confirmation_slug),
    do: {:error, access_error(:confirmation_mismatch, "confirmation slug did not match pool slug")}

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A caller that passes `broadcast?: false` runs inside its own transaction
  # and invalidates after the commit.
  defp maybe_invalidate_notifications_after_status_change(opts, previous_status, %Pool{} = pool) do
    if Keyword.get(opts, :broadcast?, true),
      do: invalidate_notifications_after_status_change(previous_status, pool),
      else: :ok
  end

  defp maybe_broadcast_pool_change(opts, %Pool{} = pool, reason) do
    if Keyword.get(opts, :broadcast?, true) do
      Events.broadcast_pools(pool.id, reason, %{
        pool_id: pool.id,
        status: pool.status
      })
    end
  end

  defp record_pool_audit_event(scope, action, pool, details \\ %{})

  defp record_pool_audit_event(
         %Scope{user: %User{} = user},
         action,
         %Pool{} = pool,
         details
       ) do
    Audit.record_user_event(user, %{
      pool_id: pool.id,
      action: action,
      target_type: "pool",
      target_id: pool.id,
      details: Map.merge(pool_audit_details(pool), details)
    })
  end

  defp record_pool_audit_event(_scope, _action, _pool, _details), do: :ok

  defp pool_audit_details(%Pool{} = pool) do
    %{
      pool_id: pool.id,
      slug: pool.slug,
      name: pool.name,
      status: pool.status
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
