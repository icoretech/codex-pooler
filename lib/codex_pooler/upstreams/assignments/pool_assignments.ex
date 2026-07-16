defmodule CodexPooler.Upstreams.Assignments.PoolAssignments do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @active UpstreamIdentity.active_status()
  @deleted UpstreamIdentity.deleted_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_deleted PoolUpstreamAssignment.deleted_status()
  @assignment_disabled PoolUpstreamAssignment.disabled_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @ineligible PoolUpstreamAssignment.ineligible_status()
  @health_unknown PoolUpstreamAssignment.unknown_health_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @health_cooldown PoolUpstreamAssignment.cooldown_health_status()
  @health_disabled PoolUpstreamAssignment.disabled_health_status()
  @pending PoolUpstreamAssignment.pending_status()

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type lifecycle_result :: {:ok, map()} | {:error, lifecycle_error()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type assignment_ref :: PoolUpstreamAssignment.t() | Ecto.UUID.t()
  @type assignment_result ::
          {:ok, PoolUpstreamAssignment.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec create_pool_assignment(Pool.t(), identity_ref(), map()) :: assignment_result()
  def create_pool_assignment(pool, identity_or_id, attrs \\ %{})

  def create_pool_assignment(%Pool{} = pool, identity_or_id, attrs) when is_map(attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        now = now()
        attrs = atomize_attrs(attrs)

        result =
          attrs
          |> Map.merge(%{pool_id: pool.id, upstream_identity_id: identity.id})
          |> put_default(:assignment_label, identity.account_label)
          |> put_default(:status, @pending)
          |> put_default(:health_status, @health_unknown)
          |> put_default(:eligibility_status, @eligible)
          |> put_default(:metadata, %{})
          |> put_default(:created_at, now)
          |> put_default(:updated_at, now)
          |> then(&PoolUpstreamAssignment.changeset(%PoolUpstreamAssignment{}, &1))
          |> Repo.insert()

        result

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  def create_pool_assignment(_pool, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:pool_not_found, "pool was not found")}

  @doc """
  Assigns an already-linked upstream identity to a Pool as an operational
  assignment.

  `create_pool_assignment/3` intentionally defaults to `pending` for
  onboarding. The admin "Assign to Pool" workflow must instead create an
  active assignment and restore an older pending/deleted row when one already
  occupies the Pool/identity slot.
  """
  @spec assign_pool_assignment(Pool.t(), identity_ref(), map()) :: assignment_result()
  def assign_pool_assignment(pool, identity_or_id, attrs \\ %{})

  def assign_pool_assignment(%Pool{} = pool, identity_or_id, attrs) when is_map(attrs) do
    case identity_id(identity_or_id) do
      identity_id when is_binary(identity_id) ->
        assign_pool_assignment_transaction(pool, identity_id, attrs)

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  def assign_pool_assignment(_pool, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:pool_not_found, "pool was not found")}

  @spec sync_pool_assignments_for_pool_edit(Pool.t(), [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, term()}
  def sync_pool_assignments_for_pool_edit(pool, selected_ids, opts \\ [])

  def sync_pool_assignments_for_pool_edit(%Pool{} = pool, selected_ids, opts)
      when is_list(selected_ids) and is_list(opts) do
    case Keyword.get(opts, :select_by, :assignment_id) do
      :upstream_identity_id ->
        sync_pool_assignments_by_identity(pool, selected_ids, opts)

      :assignment_id ->
        sync_existing_pool_assignments(pool, selected_ids, opts)

      _select_by ->
        {:error, lifecycle_error(:invalid_request, "unsupported pool assignment selection mode")}
    end
  end

  def sync_pool_assignments_for_pool_edit(_pool, _selected_ids, _opts),
    do: {:error, lifecycle_error(:pool_not_found, "pool was not found")}

  @spec update_pool_assignment(PoolUpstreamAssignment.t(), map()) :: assignment_result()
  def update_pool_assignment(%PoolUpstreamAssignment{} = assignment, attrs) when is_map(attrs) do
    attrs = attrs |> atomize_attrs() |> Map.put(:updated_at, now())

    assignment
    |> PoolUpstreamAssignment.changeset(attrs)
    |> Repo.update()
  end

  @spec activate_pool_assignment(assignment_ref(), map()) :: assignment_result()
  def activate_pool_assignment(assignment_or_id, attrs \\ %{}) do
    case normalize_assignment(assignment_or_id) do
      %PoolUpstreamAssignment{} = assignment ->
        attrs = atomize_attrs(attrs)

        result =
          update_pool_assignment(
            assignment,
            attrs
            |> Map.drop([:skip_quota_priming])
            |> Map.merge(%{
              status: @assignment_active,
              health_status: Map.get(attrs, :health_status, @health_active),
              eligibility_status: Map.get(attrs, :eligibility_status, @eligible),
              disabled_at: nil
            })
          )

        result

      nil ->
        {:error,
         lifecycle_error(:pool_upstream_assignment_not_found, "pool assignment was not found")}
    end
  end

  @spec disable_pool_assignment(assignment_ref()) :: assignment_result()
  def disable_pool_assignment(assignment_or_id) do
    case normalize_assignment(assignment_or_id) do
      %PoolUpstreamAssignment{} = assignment ->
        update_pool_assignment(assignment, %{
          status: @assignment_disabled,
          health_status: @health_disabled,
          eligibility_status: @ineligible,
          disabled_at: now()
        })

      nil ->
        {:error,
         lifecycle_error(:pool_upstream_assignment_not_found, "pool assignment was not found")}
    end
  end

  @spec delete_pool_assignment(Pool.t() | Ecto.UUID.t(), assignment_ref()) :: lifecycle_result()
  def delete_pool_assignment(pool_or_id, assignment_or_id) do
    pool_id = pool_id(pool_or_id)
    assignment_id = assignment_id(assignment_or_id)

    cond do
      is_nil(pool_id) ->
        {:error, lifecycle_error(:pool_not_found, "pool was not found")}

      is_nil(assignment_id) ->
        {:error,
         lifecycle_error(:pool_upstream_assignment_not_found, "pool assignment was not found")}

      true ->
        Repo.transaction(fn ->
          # Reason: transaction branch preserves lock and already-deleted outcomes together.
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case lock_pool_assignment(pool_id, assignment_id) do
            %PoolUpstreamAssignment{} = assignment ->
              soft_delete_locked_pool_assignment(assignment)

            nil ->
              %{
                status: :already_deleted,
                assignment: nil,
                identity: nil,
                identity_deleted?: false,
                remaining_assignment_count: 0
              }
          end
        end)
    end
  end

  @spec put_assignment_cooldown(assignment_ref(), DateTime.t(), map()) :: assignment_result()
  def put_assignment_cooldown(assignment_or_id, cooldown_until, attrs \\ %{}) do
    case normalize_assignment(assignment_or_id) do
      %PoolUpstreamAssignment{} = assignment ->
        attrs = atomize_attrs(attrs)

        update_pool_assignment(
          assignment,
          Map.merge(attrs, %{
            health_status: @health_cooldown,
            eligibility_status: @ineligible,
            cooldown_until: cooldown_until,
            last_healthcheck_at: Map.get(attrs, :last_healthcheck_at, now())
          })
        )

      nil ->
        {:error,
         lifecycle_error(:pool_upstream_assignment_not_found, "pool assignment was not found")}
    end
  end

  @spec list_pool_assignments(Pool.t() | Ecto.UUID.t()) :: [PoolUpstreamAssignment.t()]
  def list_pool_assignments(%Pool{} = pool), do: list_pool_assignments(pool.id)

  def list_pool_assignments(pool_id) when is_binary(pool_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.pool_id == ^pool_id,
        order_by: [asc: assignment.created_at]
    )
  end

  def list_pool_assignments(_pool_id), do: []

  @spec count_pool_assignments_by_pool_ids([Ecto.UUID.t()]) ::
          %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def count_pool_assignments_by_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    counts =
      case pool_ids do
        [] ->
          %{}

        _ ->
          Repo.all(
            from assignment in PoolUpstreamAssignment,
              join: identity in UpstreamIdentity,
              on: identity.id == assignment.upstream_identity_id,
              where: assignment.pool_id in ^pool_ids,
              where: assignment.status != ^@assignment_deleted,
              where: identity.status != ^@deleted,
              group_by: assignment.pool_id,
              select: {assignment.pool_id, count(assignment.id)}
          )
          |> Map.new()
      end

    Enum.into(pool_ids, %{}, fn pool_id ->
      {pool_id, Map.get(counts, pool_id, 0)}
    end)
  end

  def count_pool_assignments_by_pool_ids(_pool_ids), do: %{}

  @spec list_active_pool_assignments(Pool.t() | Ecto.UUID.t()) :: [
          PoolUpstreamAssignment.t()
        ]
  def list_active_pool_assignments(pool_or_id) do
    case pool_id(pool_or_id) do
      nil ->
        []

      pool_id ->
        Repo.all(
          from assignment in PoolUpstreamAssignment,
            join: identity in UpstreamIdentity,
            on: identity.id == assignment.upstream_identity_id,
            where:
              assignment.pool_id == ^pool_id and assignment.status == ^@assignment_active and
                identity.status == ^@active,
            order_by: [asc: assignment.created_at, asc: assignment.id],
            select: assignment
        )
    end
  end

  @spec list_canonical_active_assignments_for_pools([Pool.t() | Ecto.UUID.t()]) :: [
          PoolUpstreamAssignment.t()
        ]
  def list_canonical_active_assignments_for_pools(pool_refs) when is_list(pool_refs) do
    pool_ids =
      pool_refs
      |> Enum.map(&pool_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if pool_ids == [] do
      []
    else
      ranked_query =
        from assignment in PoolUpstreamAssignment,
          join: identity in UpstreamIdentity,
          on: identity.id == assignment.upstream_identity_id,
          where:
            assignment.pool_id in ^pool_ids and assignment.status == ^@assignment_active and
              identity.status == ^@active,
          windows: [
            identity_partition: [
              partition_by: assignment.upstream_identity_id,
              order_by: [asc: assignment.created_at, asc: assignment.id]
            ]
          ],
          select: %{
            id: assignment.id,
            row_number: over(row_number(), :identity_partition)
          }

      Repo.all(
        from assignment in PoolUpstreamAssignment,
          join: ranked_assignment in subquery(ranked_query),
          on: ranked_assignment.id == assignment.id,
          where: ranked_assignment.row_number == 1,
          order_by: [asc: assignment.created_at, asc: assignment.id],
          select: assignment
      )
    end
  end

  def list_canonical_active_assignments_for_pools(_pool_refs), do: []

  @spec list_pool_assignments_for_identity(identity_ref()) :: [PoolUpstreamAssignment.t()]
  def list_pool_assignments_for_identity(identity_or_id) do
    case identity_id(identity_or_id) do
      nil ->
        []

      identity_id ->
        Repo.all(
          from assignment in PoolUpstreamAssignment,
            where: assignment.upstream_identity_id == ^identity_id,
            order_by: [asc: assignment.created_at, asc: assignment.id]
        )
    end
  end

  @spec list_eligible_pool_assignments(Pool.t() | Ecto.UUID.t(), keyword()) ::
          [PoolUpstreamAssignment.t()]
  def list_eligible_pool_assignments(pool_or_id, opts \\ []) do
    case pool_id(pool_or_id) do
      nil ->
        []

      pool_id ->
        timestamp = Keyword.get(opts, :at, now())

        Repo.all(
          from assignment in PoolUpstreamAssignment,
            join: identity in UpstreamIdentity,
            on: identity.id == assignment.upstream_identity_id,
            where:
              assignment.pool_id == ^pool_id and assignment.status == ^@assignment_active and
                assignment.eligibility_status == ^@eligible and
                assignment.health_status == ^@health_active and
                (is_nil(assignment.cooldown_until) or assignment.cooldown_until <= ^timestamp) and
                identity.status == ^@active,
            order_by: [asc: assignment.last_successful_sync_at, asc: assignment.created_at],
            select: assignment
        )
    end
  end

  defp sync_pool_assignments_by_identity(%Pool{} = pool, upstream_identity_ids, opts) do
    upstream_identity_ids =
      upstream_identity_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> MapSet.new()

    Repo.transaction(fn ->
      assignment_lookup =
        pool
        |> list_pool_assignments()
        |> Map.new(&{&1.upstream_identity_id, &1})

      with :ok <-
             retain_or_create_selected_pool_assignments(
               pool,
               assignment_lookup,
               upstream_identity_ids,
               opts
             ),
           :ok <-
             soft_delete_deselected_pool_assignments(assignment_lookup, upstream_identity_ids) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_sync_transaction_result()
  end

  defp retain_or_create_selected_pool_assignments(
         pool,
         assignment_lookup,
         upstream_identity_ids,
         opts
       ) do
    Enum.reduce_while(upstream_identity_ids, :ok, fn upstream_identity_id, :ok ->
      case Map.get(assignment_lookup, upstream_identity_id) do
        %PoolUpstreamAssignment{status: @assignment_deleted} = assignment ->
          continue_with_pool_assignment_reactivation(assignment, opts)

        %PoolUpstreamAssignment{} ->
          {:cont, :ok}

        nil ->
          continue_with_pool_assignment_create(pool, upstream_identity_id, opts)
      end
    end)
  end

  defp continue_with_pool_assignment_reactivation(assignment, opts) do
    case activate_pool_assignment(assignment, %{
           skip_quota_priming: Keyword.get(opts, :skip_quota_priming, false)
         }) do
      {:ok, _assignment} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp continue_with_pool_assignment_create(pool, upstream_identity_id, opts) do
    case create_pool_assignment(pool, upstream_identity_id, %{
           status: @assignment_active,
           health_status: @health_active,
           eligibility_status: @eligible,
           skip_quota_priming: Keyword.get(opts, :skip_quota_priming, false)
         }) do
      {:ok, _assignment} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp soft_delete_deselected_pool_assignments(assignment_lookup, upstream_identity_ids) do
    Enum.reduce_while(assignment_lookup, :ok, fn {identity_id, assignment}, :ok ->
      if retain_pool_assignment?(assignment, upstream_identity_ids, identity_id) do
        {:cont, :ok}
      else
        continue_with_pool_assignment_soft_delete(assignment)
      end
    end)
  end

  defp retain_pool_assignment?(assignment, upstream_identity_ids, identity_id) do
    MapSet.member?(upstream_identity_ids, identity_id) or assignment.status == @assignment_deleted
  end

  defp continue_with_pool_assignment_soft_delete(assignment) do
    case soft_delete_assignment(assignment) do
      {:ok, _assignment} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp sync_existing_pool_assignments(%Pool{} = pool, selected_assignment_ids, opts) do
    assignment_lookup = pool |> list_pool_assignments() |> Map.new(&{&1.id, &1})
    selected_assignment_ids = MapSet.new(selected_assignment_ids)

    if known_assignment_ids?(assignment_lookup, selected_assignment_ids) do
      update_known_pool_assignments(pool, assignment_lookup, selected_assignment_ids, opts)
    else
      {:error,
       lifecycle_error(
         :invalid_assignment_selection,
         "selected assignments are not available for this Pool"
       )}
    end
  end

  defp known_assignment_ids?(assignment_lookup, selected_assignment_ids) do
    known_assignment_ids = assignment_lookup |> Map.keys() |> MapSet.new()

    MapSet.subset?(selected_assignment_ids, known_assignment_ids)
  end

  defp update_known_pool_assignments(pool, assignment_lookup, selected_assignment_ids, opts) do
    Enum.reduce_while(assignment_lookup, :ok, fn {assignment_id, assignment}, :ok ->
      selected? = MapSet.member?(selected_assignment_ids, assignment_id)

      case update_pool_assignment_state(pool, assignment, selected?, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_pool_assignment_state(_pool, assignment, true, opts) do
    if assignment.status == @assignment_deleted do
      case activate_pool_assignment(assignment, %{
             skip_quota_priming: Keyword.get(opts, :skip_quota_priming, false)
           }) do
        {:ok, _assignment} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp update_pool_assignment_state(pool, assignment, false, _opts) do
    if assignment.status == @assignment_deleted do
      :ok
    else
      case delete_pool_assignment(pool, assignment) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp lock_pool_assignment(pool_id, assignment_id) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.id == ^assignment_id and assignment.pool_id == ^pool_id and
            assignment.status != ^@assignment_deleted,
        lock: "FOR UPDATE"
    )
  end

  defp soft_delete_locked_pool_assignment(%PoolUpstreamAssignment{} = assignment) do
    deleted_assignment = soft_delete_assignment!(assignment)

    remaining_assignment_count =
      Repo.aggregate(
        from(remaining in PoolUpstreamAssignment,
          where:
            remaining.upstream_identity_id == ^assignment.upstream_identity_id and
              remaining.status != ^@assignment_deleted
        ),
        :count,
        :id
      )

    identity = Repo.get(UpstreamIdentity, assignment.upstream_identity_id)

    %{
      status: :assignment_deleted,
      assignment: deleted_assignment,
      identity: identity,
      identity_deleted?: false,
      remaining_assignment_count: remaining_assignment_count
    }
  end

  defp soft_delete_assignment(%PoolUpstreamAssignment{} = assignment) do
    assignment
    |> PoolUpstreamAssignment.changeset(soft_delete_assignment_attrs())
    |> Repo.update()
  end

  defp soft_delete_assignment!(%PoolUpstreamAssignment{} = assignment) do
    assignment
    |> PoolUpstreamAssignment.changeset(soft_delete_assignment_attrs())
    |> Repo.update!()
  end

  defp soft_delete_assignment_attrs do
    %{
      status: @assignment_deleted,
      health_status: @health_disabled,
      eligibility_status: @ineligible,
      disabled_at: now(),
      updated_at: now()
    }
  end

  defp normalize_sync_transaction_result({:ok, :ok}), do: :ok
  defp normalize_sync_transaction_result({:error, reason}), do: {:error, reason}
  defp normalize_sync_transaction_result({:ok, other}), do: other

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp normalize_assignment(%PoolUpstreamAssignment{} = assignment), do: assignment
  defp normalize_assignment(id) when is_binary(id), do: Repo.get(PoolUpstreamAssignment, id)
  defp normalize_assignment(_id), do: nil

  defp assignment_id(%PoolUpstreamAssignment{id: id}), do: id
  defp assignment_id(id) when is_binary(id), do: id
  defp assignment_id(_id), do: nil

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil

  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp pool_id(_id), do: nil

  defp assignment_for_pool_identity(pool_id, identity_id) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.pool_id == ^pool_id and
            assignment.upstream_identity_id == ^identity_id,
        lock: "FOR UPDATE"
    )
  end

  defp assign_pool_assignment_transaction(pool, identity_id, attrs) do
    Repo.transaction(fn ->
      identity_id
      |> lock_upstream_identity()
      |> assign_locked_identity(pool, attrs)
      |> case do
        {:ok, assignment} -> assignment
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_upstream_identity(identity_id) do
    Repo.one(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR UPDATE"
    )
  end

  defp assign_locked_identity(nil, _pool, _attrs) do
    {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
  end

  defp assign_locked_identity(%UpstreamIdentity{status: @deleted}, _pool, _attrs) do
    {:error,
     lifecycle_error(
       :upstream_identity_not_assignable,
       "deleted upstream identities cannot be assigned"
     )}
  end

  defp assign_locked_identity(%UpstreamIdentity{} = identity, pool, attrs) do
    assignment_attrs =
      attrs
      |> atomize_attrs()
      |> Map.merge(%{
        status: @assignment_active,
        health_status: @health_active,
        eligibility_status: @eligible,
        cooldown_until: nil,
        disabled_at: nil
      })

    case assignment_for_pool_identity(pool.id, identity.id) do
      %PoolUpstreamAssignment{status: status} = assignment
      when status in [@pending, @assignment_deleted] ->
        update_pool_assignment(assignment, assignment_attrs)

      %PoolUpstreamAssignment{} = assignment ->
        {:ok, assignment}

      nil ->
        create_pool_assignment(pool, identity, assignment_attrs)
    end
  end

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
