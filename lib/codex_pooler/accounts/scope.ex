defmodule CodexPooler.Accounts.Scope do
  @moduledoc """
  Caller scope passed through context APIs for authorization, audit, and
  pool-scoped UI invalidation.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.User
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment}
  alias CodexPooler.Repo

  @active_status "active"

  defstruct user: nil, roles: [], assigned_pool_ids: []

  @type t :: %__MODULE__{
          user: User.t() | nil,
          roles: [String.t()],
          assigned_pool_ids: [Ecto.UUID.t()]
        }

  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user) do
    %__MODULE__{
      user: user,
      roles: roles_for_user(user.id),
      assigned_pool_ids: assigned_pool_ids_for_user(user.id)
    }
  end

  def for_user(nil), do: nil

  @spec for_user(User.t() | nil, [String.t()]) :: t() | nil
  def for_user(user, roles)

  def for_user(%User{} = user, roles) do
    %__MODULE__{
      user: user,
      roles: Enum.filter(roles, &is_binary/1),
      assigned_pool_ids: assigned_pool_ids_for_user(user.id)
    }
  end

  def for_user(nil, _roles), do: nil

  defp roles_for_user(user_id) do
    Repo.all(
      from membership in Membership,
        where: membership.user_id == ^user_id and membership.status == ^@active_status,
        order_by: [asc: membership.role],
        select: membership.role
    )
  end

  defp assigned_pool_ids_for_user(user_id) do
    Repo.all(
      from assignment in OperatorPoolAssignment,
        where: assignment.user_id == ^user_id and assignment.status == ^@active_status,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        select: assignment.pool_id
    )
  end
end
