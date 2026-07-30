defmodule CodexPooler.Catalog.Sync do
  @moduledoc """
  Catalog synchronization orchestration.
  """

  import Ecto.Query

  alias CodexPooler.Catalog.Sync.{Discovery, Persistence}
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Events
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @assignment_active AssignmentStatus.active_status()
  @assignment_eligible AssignmentStatus.eligible_status()
  @identity_active IdentityStatus.active_status()
  @secret_active "active"
  @secret_kind "access_token"
  @cancelled "cancelled"
  @failed "failed"
  @running "running"
  @stale_sync_run_after_seconds 15 * 60

  @type catalog_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type catalog_result ::
          {:ok, map()}
          | {:error, catalog_error() | Ecto.Changeset.t() | term()}
          | {:error, term(), catalog_error() | Ecto.Changeset.t() | term()}
  @type pool_ref :: Pool.t() | Ecto.UUID.t()

  @spec sync_pool_catalog(pool_ref(), keyword()) :: catalog_result()
  def sync_pool_catalog(pool_or_id, opts \\ [])

  def sync_pool_catalog(%Pool{} = pool, opts), do: sync_pool_catalog(pool.id, opts)

  def sync_pool_catalog(pool_id, opts) when is_binary(pool_id) do
    trigger_kind = Keyword.get(opts, :trigger_kind, "manual")
    fetcher = Keyword.get(opts, :fetcher, &Discovery.fetch_models_for_assignment/1)

    assignments = list_catalog_sync_assignments(pool_id)

    result =
      if assignments == [] do
        {:ok, %{sync_runs: [], models: [], skipped?: true}}
      else
        run_catalog_sync(pool_id, trigger_kind, assignments, fetcher)
      end

    broadcast_model_sync_result(pool_id, result, trigger_kind)
    result
  end

  def sync_pool_catalog(_pool_id, _opts),
    do: {:error, catalog_error(:pool_not_found, "pool was not found")}

  @spec list_catalog_sync_assignments(pool_ref()) :: [map()]
  def list_catalog_sync_assignments(pool_or_id) do
    pool_id = pool_id(pool_or_id)

    PoolUpstreamAssignment
    |> join(:inner, [assignment], identity in UpstreamIdentity,
      on: identity.id == assignment.upstream_identity_id
    )
    |> join(:inner, [_assignment, identity], secret in EncryptedSecret,
      on:
        secret.upstream_identity_id == identity.id and secret.secret_kind == ^@secret_kind and
          secret.status == ^@secret_active
    )
    |> where(
      [assignment, identity, _secret],
      assignment.pool_id == ^pool_id and assignment.status == ^@assignment_active and
        assignment.eligibility_status == ^@assignment_eligible and
        identity.status == ^@identity_active
    )
    |> order_by([assignment, _identity, _secret], asc: assignment.created_at)
    |> select([assignment, identity, _secret], %{assignment: assignment, identity: identity})
    |> Repo.all()
  end

  @spec cleanup_stale_sync_runs(DateTime.t()) ::
          {:ok, %{required(:stale_catalog_sync_runs_failed) => non_neg_integer()}}
  def cleanup_stale_sync_runs(now) do
    now = DateTime.truncate(now, :microsecond)
    cutoff = DateTime.add(now, -@stale_sync_run_after_seconds, :second)

    {count, _rows} =
      SyncRun
      |> where([run], run.status == ^@running and run.started_at <= ^cutoff)
      |> Repo.update_all(
        set: [
          status: @failed,
          finished_at: now,
          error_message: "catalog sync timed out before completion"
        ]
      )

    {:ok, %{stale_catalog_sync_runs_failed: count}}
  end

  defp broadcast_model_sync_result(pool_id, {:ok, result}, trigger_kind) do
    Events.broadcast_model_sync(pool_id, "model_sync_completed", %{
      trigger_kind: trigger_kind,
      status: "succeeded",
      partial?: Map.get(result, :partial?, false),
      model_count: length(Map.get(result, :models, []))
    })
  end

  defp broadcast_model_sync_result(pool_id, {:error, _sync_run, reason}, trigger_kind) do
    Events.broadcast_model_sync(pool_id, "model_sync_failed", %{
      trigger_kind: trigger_kind,
      status: "failed",
      code: error_code(reason)
    })
  end

  defp broadcast_model_sync_result(pool_id, {:error, reason}, trigger_kind) do
    Events.broadcast_model_sync(pool_id, "model_sync_failed", %{
      trigger_kind: trigger_kind,
      status: "failed",
      code: error_code(reason)
    })
  end

  defp error_code(%{code: code}), do: to_string(code)
  defp error_code(_reason), do: "model_sync_failed"

  defp run_catalog_sync(pool_id, trigger_kind, assignments, fetcher) do
    started_at = now()
    {:ok, _summary} = cleanup_stale_sync_runs(started_at)

    with :ok <- ensure_no_running_sync(pool_id, trigger_kind, started_at),
         {:ok, run} <- create_sync_run(pool_id, trigger_kind, started_at) do
      discover_and_persist_catalog(run, assignments, fetcher)
    end
  end

  defp ensure_no_running_sync(pool_id, trigger_kind, started_at) do
    if Repo.exists?(running_sync_query(pool_id)) do
      pool_id
      |> create_final_sync_run(trigger_kind, @cancelled, started_at, %{
        error_message: "catalog sync already running"
      })
      |> catalog_sync_in_progress_error()
    else
      :ok
    end
  end

  defp running_sync_query(pool_id) do
    from run in SyncRun,
      where: run.pool_id == ^pool_id and run.status == ^@running
  end

  defp catalog_sync_in_progress_error({:ok, run}),
    do: {:error, catalog_error(:catalog_sync_in_progress, run.error_message)}

  defp catalog_sync_in_progress_error({:error, reason}), do: {:error, reason}

  defp discover_and_persist_catalog(run, assignments, fetcher) do
    case Discovery.discover_models(assignments, fetcher) do
      {:ok, successful_assignments, failed_sources, discovered} ->
        Persistence.persist_catalog(
          run,
          assignments,
          successful_assignments,
          failed_sources,
          discovered
        )

      {:error, reason} ->
        Persistence.fail_sync_run(run, reason)
    end
  end

  defp create_sync_run(pool_id, trigger_kind, started_at) do
    %SyncRun{}
    |> SyncRun.changeset(%{
      pool_id: pool_id,
      trigger_kind: trigger_kind,
      status: @running,
      started_at: started_at,
      discovered_model_count: 0,
      upserted_model_count: 0,
      stale_marked_count: 0,
      retired_count: 0,
      stats: %{}
    })
    |> Repo.insert()
  end

  defp create_final_sync_run(pool_id, trigger_kind, status, started_at, attrs) do
    %SyncRun{}
    |> SyncRun.changeset(
      Map.merge(
        %{
          pool_id: pool_id,
          trigger_kind: trigger_kind,
          status: status,
          started_at: started_at,
          finished_at: now(),
          discovered_model_count: 0,
          upserted_model_count: 0,
          stale_marked_count: 0,
          retired_count: 0,
          stats: %{}
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  defp catalog_error(code, message), do: %{code: code, message: message}
  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp pool_id(_id), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
