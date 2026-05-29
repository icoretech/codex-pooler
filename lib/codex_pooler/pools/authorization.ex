defmodule CodexPooler.Pools.Authorization do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo

  @role_instance_owner "instance_owner"
  @role_instance_admin "instance_admin"
  @status_active "active"

  @capability_pool_manage "pool.manage"
  @capability_pool_api_key_manage "pool_api_key.manage"
  @capability_pool_operate "pool.operate"
  @owner_only_capabilities [@capability_pool_manage]
  @pool_scoped_capabilities [@capability_pool_api_key_manage, @capability_pool_operate]

  @type capability_key :: :pool_manage | :pool_api_key_manage | :pool_operate
  @type role_key :: :instance_owner | :instance_admin
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type pool_status :: String.t()
  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type capability_decision :: %{
          required(:actor_role) => String.t(),
          required(:capability) => String.t(),
          required(:pool_id) => Ecto.UUID.t() | nil
        }

  @spec capability(capability_key()) :: String.t()
  def capability(:pool_manage), do: @capability_pool_manage
  def capability(:pool_api_key_manage), do: @capability_pool_api_key_manage
  def capability(:pool_operate), do: @capability_pool_operate

  @spec role(role_key()) :: String.t()
  def role(:instance_owner), do: @role_instance_owner
  def role(:instance_admin), do: @role_instance_admin

  @spec role_values() :: [String.t()]
  def role_values, do: [@role_instance_owner, @role_instance_admin]

  @spec owner?(Scope.t() | term()) :: boolean()
  def owner?(%Scope{user: %{id: user_id}}) when is_binary(user_id), do: active_owner?(user_id)
  def owner?(_scope), do: false

  @spec assigned_pool?(Scope.t() | term(), pool_ref() | term()) :: boolean()
  def assigned_pool?(%Scope{user: %{id: user_id}}, pool_or_id) when is_binary(user_id) do
    with true <- active_admin?(user_id),
         pool_id when is_binary(pool_id) <- pool_id(pool_or_id) do
      active_assignment?(user_id, pool_id)
    else
      _not_assigned -> false
    end
  end

  def assigned_pool?(_scope, _pool_or_id), do: false

  @spec list_assigned_pool_ids(Scope.t() | term()) :: [Ecto.UUID.t()]
  def list_assigned_pool_ids(%Scope{user: %{id: user_id}}) when is_binary(user_id) do
    if active_admin?(user_id), do: list_active_assignment_pool_ids(user_id), else: []
  end

  def list_assigned_pool_ids(_scope), do: []

  @spec list_pools_for_capability(Scope.t(), String.t(), [pool_status()]) ::
          {:ok, [Pool.t()]} | {:error, access_error()}
  def list_pools_for_capability(%Scope{user: %{id: user_id}}, capability, statuses)
      when is_binary(user_id) and is_list(statuses) do
    actor_role = strongest_role_for_user(user_id)
    statuses = normalize_statuses(statuses)

    cond do
      is_nil(actor_role) ->
        {:error, access_error(:capability_denied, "only node admins can perform this capability")}

      actor_role == @role_instance_owner and role_can?(actor_role, capability) ->
        {:ok, list_pools_by_status(statuses)}

      actor_role == @role_instance_admin and pool_scoped_capability?(capability) ->
        {:ok, list_assigned_pools_by_status(user_id, statuses)}

      true ->
        {:error,
         access_error(
           :capability_denied,
           "the actor role cannot perform this capability in the requested scope"
         )}
    end
  end

  def list_pools_for_capability(_scope, _capability, _statuses),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec require_capability(Scope.t(), String.t(), keyword()) ::
          {:ok, capability_decision()} | {:error, access_error()}
  def require_capability(scope, capability, opts \\ [])

  def require_capability(%Scope{user: %{id: user_id}}, capability, opts)
      when is_binary(user_id) do
    pool_id = Keyword.get(opts, :pool_id)
    actor_role = strongest_role_for_user(user_id)

    case actor_role do
      nil ->
        {:error, access_error(:capability_denied, "only node admins can perform this capability")}

      @role_instance_owner ->
        require_owner_capability(capability, pool_id)

      @role_instance_admin ->
        require_admin_capability(user_id, capability, pool_id)

      _role ->
        denied_for_role()
    end
  end

  def require_capability(_scope, _capability, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec role_can?(String.t(), String.t()) :: boolean()
  def role_can?(@role_instance_owner, capability)
      when capability in [
             @capability_pool_manage,
             @capability_pool_api_key_manage,
             @capability_pool_operate
           ],
      do: true

  def role_can?(@role_instance_admin, capability)
      when capability in [@capability_pool_api_key_manage, @capability_pool_operate],
      do: true

  def role_can?(_role, _capability), do: false

  @spec access_error(atom(), String.t()) :: access_error()
  def access_error(code, message), do: %{code: code, message: message}

  defp require_owner_capability(capability, nil) when capability in @owner_only_capabilities,
    do: {:ok, decision(capability, @role_instance_owner, nil)}

  defp require_owner_capability(capability, nil) do
    if capability == @capability_pool_operate do
      {:ok, decision(capability, @role_instance_owner, nil)}
    else
      {:error,
       access_error(
         :capability_denied,
         "this capability requires a Pool scope"
       )}
    end
  end

  defp require_owner_capability(capability, pool_id) do
    cond do
      not role_can?(@role_instance_owner, capability) ->
        denied_for_role()

      not active_pool?(pool_id) ->
        {:error, access_error(:pool_not_found, "pool was not found")}

      true ->
        {:ok, decision(capability, @role_instance_owner, pool_id)}
    end
  end

  defp require_admin_capability(_user_id, capability, nil)
       when capability in @owner_only_capabilities do
    {:error,
     access_error(
       :capability_denied,
       "only the instance owner can perform this global capability"
     )}
  end

  defp require_admin_capability(_user_id, capability, nil)
       when capability in @pool_scoped_capabilities do
    {:error,
     access_error(
       :capability_denied,
       "assigned-pool admin capabilities require a Pool scope"
     )}
  end

  defp require_admin_capability(user_id, capability, pool_id) do
    cond do
      not pool_scoped_capability?(capability) ->
        denied_for_role()

      not active_pool?(pool_id) ->
        {:error, access_error(:pool_not_found, "pool was not found")}

      not active_assignment?(user_id, pool_id) ->
        {:error,
         access_error(
           :capability_denied,
           "the assigned-pool admin cannot access the requested Pool"
         )}

      true ->
        {:ok, decision(capability, @role_instance_admin, pool_id)}
    end
  end

  defp denied_for_role do
    {:error,
     access_error(
       :capability_denied,
       "the actor role cannot perform this capability in the requested scope"
     )}
  end

  defp strongest_role_for_user(user_id) do
    roles = user_id |> list_active_memberships_for_user() |> Enum.map(& &1.role)

    Enum.find(roles, &(&1 == @role_instance_owner)) ||
      Enum.find(roles, &(&1 == @role_instance_admin))
  end

  defp list_active_memberships_for_user(user_id) do
    Repo.all(
      from membership in Membership,
        join: user in User,
        on: user.id == membership.user_id,
        where:
          membership.user_id == ^user_id and membership.status == ^@status_active and
            user.status == ^@status_active and is_nil(user.deleted_at),
        order_by: [asc: membership.created_at]
    )
  end

  defp active_pool?(pool_id) do
    Repo.exists?(
      from pool in Pool,
        where: pool.id == ^pool_id and pool.status == ^@status_active
    )
  end

  defp active_owner?(user_id) do
    active_membership?(user_id, @role_instance_owner)
  end

  defp active_admin?(user_id) do
    active_membership?(user_id, @role_instance_admin)
  end

  defp active_membership?(user_id, role) do
    Repo.exists?(
      from membership in Membership,
        join: user in User,
        on: user.id == membership.user_id,
        where:
          membership.user_id == ^user_id and membership.role == ^role and
            membership.status == ^@status_active and user.status == ^@status_active and
            is_nil(user.deleted_at)
    )
  end

  defp active_assignment?(user_id, pool_id) do
    Repo.exists?(
      from assignment in OperatorPoolAssignment,
        where:
          assignment.user_id == ^user_id and assignment.pool_id == ^pool_id and
            assignment.status == ^@status_active
    )
  end

  defp list_active_assignment_pool_ids(user_id) do
    Repo.all(
      from assignment in OperatorPoolAssignment,
        where: assignment.user_id == ^user_id and assignment.status == ^@status_active,
        select: assignment.pool_id,
        order_by: [asc: assignment.created_at, asc: assignment.id]
    )
  end

  defp list_pools_by_status(statuses) do
    Repo.all(
      from pool in Pool,
        where: pool.status in ^statuses,
        order_by: [asc: pool.created_at, asc: pool.id]
    )
  end

  defp list_assigned_pools_by_status(user_id, statuses) do
    Repo.all(
      from pool in Pool,
        join: assignment in OperatorPoolAssignment,
        on: assignment.pool_id == pool.id,
        where:
          assignment.user_id == ^user_id and assignment.status == ^@status_active and
            pool.status in ^statuses,
        order_by: [asc: pool.created_at, asc: pool.id],
        distinct: true,
        select: pool
    )
  end

  defp normalize_statuses(statuses) do
    statuses
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp pool_id(_pool_or_id), do: nil

  defp pool_scoped_capability?(capability), do: capability in @pool_scoped_capabilities

  defp decision(capability, role, pool_id),
    do: %{capability: capability, actor_role: role, pool_id: pool_id}
end
