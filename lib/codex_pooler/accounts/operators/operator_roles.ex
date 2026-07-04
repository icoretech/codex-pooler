defmodule CodexPooler.Accounts.OperatorRoles do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  @status_active "active"
  @status_revoked "revoked"

  @type summary :: %{
          required(:previous_role) => String.t() | nil,
          required(:role) => String.t(),
          required(:revoked_roles) => [String.t()]
        }

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_operator_role}
  def normalize(role) when is_binary(role) do
    if role in Pools.role_values(), do: {:ok, role}, else: {:error, :invalid_operator_role}
  end

  def normalize(_role), do: {:error, :invalid_operator_role}

  @spec default() :: String.t()
  def default, do: Pools.role(:instance_admin)

  @spec current(User.t()) :: String.t() | nil
  def current(%User{id: user_id}) do
    user_id
    |> active_memberships_for_user()
    |> strongest_role_from_memberships()
  end

  @spec ensure_in_transaction(Scope.t() | User.t(), User.t(), String.t()) ::
          {:ok, summary()} | {:error, Ecto.Changeset.t() | :last_active_owner}
  def ensure_in_transaction(actor, %User{} = operator, role) when is_binary(role) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    memberships = lock_active_memberships_for_user(operator.id)
    previous_role = strongest_role_from_memberships(memberships)

    with :ok <- ensure_role_change_preserves_owner_authority(operator, memberships, role),
         {:ok, revoked_roles} <- revoke_non_target_memberships(memberships, role, now),
         {:ok, membership} <- ensure_target_membership(actor, operator, memberships, role, now) do
      {:ok,
       %{
         previous_role: previous_role,
         role: membership.role,
         revoked_roles: revoked_roles
       }}
    end
  end

  @spec final_active_owner?(User.t()) :: boolean()
  def final_active_owner?(%User{id: user_id, status: "active"}) do
    active_owner_user_ids_for_update() == [user_id]
  end

  def final_active_owner?(_user), do: false

  defp lock_active_memberships_for_user(user_id) do
    Repo.all(
      from membership in Membership,
        where: membership.user_id == ^user_id and membership.status == ^@status_active,
        order_by: [asc: membership.created_at, asc: membership.id],
        lock: "FOR UPDATE"
    )
  end

  defp active_memberships_for_user(user_id) do
    Repo.all(
      from membership in Membership,
        where: membership.user_id == ^user_id and membership.status == ^@status_active,
        order_by: [asc: membership.created_at, asc: membership.id]
    )
  end

  defp strongest_role_from_memberships(memberships) do
    roles = Enum.map(memberships, & &1.role)
    owner_role = Pools.role(:instance_owner)
    admin_role = Pools.role(:instance_admin)

    Enum.find(roles, &(&1 == owner_role)) ||
      Enum.find(roles, &(&1 == admin_role))
  end

  defp ensure_role_change_preserves_owner_authority(operator, memberships, replacement_role) do
    owner_role = Pools.role(:instance_owner)

    if replacement_role != owner_role and Enum.any?(memberships, &(&1.role == owner_role)) do
      ensure_not_final_active_owner(operator.id)
    else
      :ok
    end
  end

  defp ensure_not_final_active_owner(user_id) do
    active_owner_user_ids = active_owner_user_ids_for_update()

    if active_owner_user_ids == [user_id], do: {:error, :last_active_owner}, else: :ok
  end

  defp active_owner_user_ids_for_update do
    owner_role = Pools.role(:instance_owner)

    Repo.all(
      from membership in Membership,
        join: user in User,
        on: user.id == membership.user_id,
        where:
          membership.role == ^owner_role and membership.status == @status_active and
            user.status == @status_active and is_nil(user.deleted_at),
        order_by: [asc: membership.user_id],
        lock: "FOR UPDATE",
        select: membership.user_id
    )
    |> Enum.map(&normalize_uuid/1)
    |> Enum.uniq()
  end

  defp revoke_non_target_memberships(memberships, role, now) do
    memberships
    |> Enum.reject(&(&1.role == role))
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, revoked_roles} ->
      case membership
           |> Membership.changeset(%{status: @status_revoked, revoked_at: now})
           |> Repo.update() do
        {:ok, revoked_membership} -> {:cont, {:ok, [revoked_membership.role | revoked_roles]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, revoked_roles} -> {:ok, Enum.reverse(revoked_roles)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_target_membership(actor, operator, memberships, role, now) do
    case Enum.find(memberships, &(&1.role == role)) do
      %Membership{} = membership ->
        {:ok, membership}

      nil ->
        %Membership{}
        |> Membership.changeset(%{
          user_id: operator.id,
          role: role,
          status: @status_active,
          created_by_user_id: actor_user_id(actor),
          created_at: now
        })
        |> Repo.insert()
    end
  end

  defp actor_user_id(%Scope{user: %User{id: user_id}}), do: user_id
  defp actor_user_id(%User{id: user_id}), do: user_id
  defp actor_user_id(_actor), do: nil

  defp normalize_uuid(<<_::128>> = raw_uuid), do: Ecto.UUID.load!(raw_uuid)
  defp normalize_uuid(uuid), do: uuid
end
