defmodule CodexPooler.Accounts.OperatorAssignments do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo

  @status_active "active"
  @status_revoked "revoked"

  @type summary :: %{
          required(:previous_pool_ids) => [Ecto.UUID.t()],
          required(:assigned_pool_ids) => [Ecto.UUID.t()],
          required(:added_pool_ids) => [Ecto.UUID.t()],
          required(:removed_pool_ids) => [Ecto.UUID.t()]
        }

  @spec normalize_pool_ids(term()) :: {:ok, [Ecto.UUID.t()]} | {:error, :invalid_pool_assignment}
  def normalize_pool_ids(nil), do: {:ok, []}

  def normalize_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reduce_while({:ok, []}, fn pool_id, {:ok, acc} ->
      case Ecto.UUID.cast(pool_id) do
        {:ok, normalized_pool_id} -> {:cont, {:ok, [normalized_pool_id | acc]}}
        :error -> {:halt, {:error, :invalid_pool_assignment}}
      end
    end)
    |> case do
      {:ok, normalized_pool_ids} -> {:ok, normalized_pool_ids |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_pool_ids(pool_id) when is_binary(pool_id), do: normalize_pool_ids([pool_id])
  def normalize_pool_ids(_pool_ids), do: {:error, :invalid_pool_assignment}

  @spec role_pool_ids(String.t(), [Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def role_pool_ids(role, pool_ids) do
    if role == Pools.role(:instance_admin), do: pool_ids, else: []
  end

  @spec ensure_pool_ids_exist([Ecto.UUID.t()]) :: :ok | {:error, :invalid_pool_assignment}
  def ensure_pool_ids_exist([]), do: :ok

  def ensure_pool_ids_exist(pool_ids) do
    found_count =
      Repo.aggregate(
        from(pool in Pool, where: pool.id in ^pool_ids),
        :count,
        :id
      )

    if found_count == length(pool_ids), do: :ok, else: {:error, :invalid_pool_assignment}
  end

  @spec replace_in_transaction(Scope.t() | User.t(), User.t(), String.t(), [Ecto.UUID.t()]) ::
          {:ok, summary()} | {:error, Ecto.Changeset.t()}
  def replace_in_transaction(actor, %User{} = operator, role, desired_pool_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    desired_pool_ids = role_pool_ids(role, desired_pool_ids)
    assignments = lock_active_assignments_for_user(operator.id)
    previous_pool_ids = Enum.map(assignments, & &1.pool_id)
    desired_pool_id_set = MapSet.new(desired_pool_ids)

    with {:ok, removed_pool_ids} <-
           revoke_removed_assignments(assignments, desired_pool_id_set, now),
         {:ok, added_pool_ids} <-
           create_missing_assignments(
             actor,
             operator,
             desired_pool_ids,
             MapSet.new(previous_pool_ids),
             now
           ) do
      {:ok,
       %{
         previous_pool_ids: previous_pool_ids,
         assigned_pool_ids: desired_pool_ids,
         added_pool_ids: added_pool_ids,
         removed_pool_ids: removed_pool_ids
       }}
    end
  end

  @spec current_pool_ids(User.t()) :: [Ecto.UUID.t()]
  def current_pool_ids(%User{id: user_id}) do
    Repo.all(
      from assignment in OperatorPoolAssignment,
        where: assignment.user_id == ^user_id and assignment.status == ^@status_active,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        select: assignment.pool_id
    )
  end

  defp lock_active_assignments_for_user(user_id) do
    Repo.all(
      from assignment in OperatorPoolAssignment,
        where: assignment.user_id == ^user_id and assignment.status == ^@status_active,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        lock: "FOR UPDATE"
    )
  end

  defp revoke_removed_assignments(assignments, desired_pool_id_set, now) do
    assignments
    |> Enum.reject(&MapSet.member?(desired_pool_id_set, &1.pool_id))
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, removed_pool_ids} ->
      case assignment
           |> OperatorPoolAssignment.changeset(%{
             status: @status_revoked,
             revoked_at: now,
             updated_at: now
           })
           |> Repo.update() do
        {:ok, revoked_assignment} ->
          {:cont, {:ok, [revoked_assignment.pool_id | removed_pool_ids]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, removed_pool_ids} -> {:ok, Enum.reverse(removed_pool_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_missing_assignments(actor, operator, desired_pool_ids, previous_pool_id_set, now) do
    desired_pool_ids
    |> Enum.reject(&MapSet.member?(previous_pool_id_set, &1))
    |> Enum.reduce_while({:ok, []}, fn pool_id, {:ok, added_pool_ids} ->
      case %OperatorPoolAssignment{}
           |> OperatorPoolAssignment.changeset(%{
             user_id: operator.id,
             pool_id: pool_id,
             status: @status_active,
             created_by_user_id: actor_user_id(actor),
             created_at: now,
             updated_at: now
           })
           |> Repo.insert() do
        {:ok, assignment} -> {:cont, {:ok, [assignment.pool_id | added_pool_ids]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, added_pool_ids} -> {:ok, Enum.reverse(added_pool_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp actor_user_id(%Scope{user: %User{id: user_id}}), do: user_id
  defp actor_user_id(%User{id: user_id}), do: user_id
  defp actor_user_id(_actor), do: nil
end
