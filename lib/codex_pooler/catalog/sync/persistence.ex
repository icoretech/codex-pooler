defmodule CodexPooler.Catalog.Sync.Persistence do
  @moduledoc """
  Catalog sync-run persistence, model aggregation, and failure sanitization.
  """

  import Ecto.Query

  alias CodexPooler.Catalog.{Model, SyncRun}
  alias CodexPooler.Catalog.Sync.PreservedSources
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias Ecto.Multi

  @active "active"
  @failed "failed"
  @stale "stale"
  @succeeded "succeeded"
  @suppressed "suppressed"

  @spec persist_catalog(SyncRun.t(), [map()], [map()]) :: {:ok, map()} | {:error, term()}
  def persist_catalog(%SyncRun{} = run, assignments, discovered) do
    timestamp = now()
    grouped = aggregate_models(discovered)
    seen_exposed_ids = Map.keys(grouped)

    Multi.new()
    |> then(fn multi ->
      Enum.reduce(grouped, multi, fn {_exposed_id, aggregate}, multi ->
        # Reason: per-model Multi step preserves aggregate-specific rollback context.
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        Multi.run(multi, {:model, aggregate.exposed_model_id}, fn repo, _changes ->
          upsert_model(repo, run, aggregate, assignments, timestamp)
        end)
      end)
    end)
    |> Multi.run(:stale_marked_count, fn repo, _changes ->
      mark_missing_models_stale(repo, run, seen_exposed_ids, timestamp)
    end)
    |> Multi.update_all(
      :assignment_sync_timestamps,
      from(assignment in PoolUpstreamAssignment,
        where: assignment.id in ^Enum.map(assignments, & &1.assignment.id)
      ),
      set: [last_successful_sync_at: timestamp, updated_at: timestamp]
    )
    |> Multi.run(:sync_run, fn repo, changes ->
      upserted_count = count_model_changes(changes)
      stale_marked_count = Map.fetch!(changes, :stale_marked_count)

      run
      |> SyncRun.changeset(%{
        status: @succeeded,
        finished_at: timestamp,
        discovered_model_count: map_size(grouped),
        upserted_model_count: upserted_count,
        stale_marked_count: stale_marked_count,
        retired_count: 0,
        stats: %{"source_assignment_count" => length(assignments)}
      })
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        models =
          changes
          |> Map.values()
          |> Enum.filter(&match?(%Model{}, &1))

        {:ok, %{sync_run: changes.sync_run, models: models}}

      {:error, _operation, reason, _changes} ->
        fail_sync_run(run, reason)
    end
  end

  @spec fail_sync_run(SyncRun.t(), term()) ::
          {:error, SyncRun.t(), map()} | {:error, Ecto.Changeset.t()}
  def fail_sync_run(%SyncRun{} = run, reason) do
    run
    |> SyncRun.changeset(%{
      status: @failed,
      finished_at: now(),
      error_message: sanitize_sync_error(reason)
    })
    |> Repo.update()
    |> case do
      {:ok, sync_run} ->
        {:error, sync_run, catalog_error(:catalog_sync_failed, sync_run.error_message)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp upsert_model(repo, run, aggregate, assignments, timestamp) do
    existing = get_model_by_exposed_id(run.pool_id, aggregate.exposed_model_id)
    source_assignments = PreservedSources.assignment_attrs(existing, aggregate, assignments, run)

    attrs = %{
      pool_id: run.pool_id,
      upstream_model_id: aggregate.upstream_model_id,
      exposed_model_id: aggregate.exposed_model_id,
      display_name: aggregate.display_name,
      status: if(match?(%Model{status: @suppressed}, existing), do: @suppressed, else: @active),
      supports_responses: aggregate.supports_responses,
      supports_streaming: aggregate.supports_streaming,
      supports_tools: aggregate.supports_tools,
      supports_reasoning: aggregate.supports_reasoning,
      pricing_ref: aggregate.pricing_ref,
      source_assignment_count: length(source_assignments.source_assignment_ids),
      first_seen_at: if(existing, do: existing.first_seen_at, else: timestamp),
      last_seen_at: timestamp,
      stale_at:
        if(match?(%Model{status: @suppressed}, existing), do: existing.stale_at, else: nil),
      retired_at:
        if(match?(%Model{status: @suppressed}, existing), do: existing.retired_at, else: nil),
      suppressed_at:
        if(match?(%Model{status: @suppressed}, existing), do: existing.suppressed_at, else: nil),
      last_sync_run_id: run.id,
      metadata: %{
        "owned_by" => aggregate.owned_by,
        "source_assignment_ids" => source_assignments.source_assignment_ids,
        "source_assignment_models" => source_assignments.source_assignment_models,
        PreservedSources.missing_sync_metadata_key() =>
          source_assignments.missing_source_assignment_syncs,
        "capabilities" => aggregate.capabilities,
        "upstream_model" => aggregate.upstream_model
      }
    }

    (existing || %Model{})
    |> Model.changeset(attrs)
    |> repo.insert_or_update()
  end

  defp mark_missing_models_stale(repo, run, seen_exposed_ids, timestamp) do
    lower_seen = Enum.map(seen_exposed_ids, &String.downcase/1)

    query =
      from model in Model,
        where:
          model.pool_id == ^run.pool_id and model.status == ^@active and
            is_nil(model.suppressed_at) and
            fragment(
              "coalesce(?->>'manual_smoke_provisioned', 'false') != 'true'",
              model.metadata
            ) and
            fragment("lower(?)", model.exposed_model_id) not in ^lower_seen

    {count, _rows} =
      repo.update_all(query,
        set: [status: @stale, stale_at: timestamp, last_sync_run_id: run.id]
      )

    {:ok, count}
  end

  defp aggregate_models(discovered) do
    discovered
    |> Enum.reject(&blank?(&1.upstream_model_id))
    |> Enum.group_by(&String.downcase(&1.exposed_model_id))
    |> Map.new(fn {exposed_id, models} -> {exposed_id, merge_model_group(models)} end)
  end

  defp merge_model_group([first | _rest] = models) do
    source_assignment_ids =
      models
      |> Enum.map(& &1.source.assignment.id)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      upstream_model_id: first.upstream_model_id,
      exposed_model_id: first.exposed_model_id,
      display_name: first.display_name,
      supports_responses: Enum.any?(models, & &1.supports_responses),
      supports_streaming: Enum.any?(models, & &1.supports_streaming),
      supports_tools: Enum.any?(models, & &1.supports_tools),
      supports_reasoning: Enum.any?(models, & &1.supports_reasoning),
      pricing_ref: first.pricing_ref,
      owned_by: first.owned_by,
      source_assignment_ids: source_assignment_ids,
      source_assignment_models: source_assignment_models(models),
      capabilities: %{
        "responses" => Enum.any?(models, & &1.supports_responses),
        "streaming" => Enum.any?(models, & &1.supports_streaming),
        "tools" => Enum.any?(models, & &1.supports_tools),
        "reasoning" => Enum.any?(models, & &1.supports_reasoning)
      },
      upstream_model: merge_upstream_models(models)
    }
  end

  defp merge_upstream_models(models) do
    Enum.reduce(models, %{}, fn model, metadata ->
      merge_upstream_model_metadata(metadata, model.upstream_model)
    end)
  end

  defp source_assignment_models(models) do
    Map.new(models, fn model ->
      {model.source.assignment.id, model.upstream_model}
    end)
  end

  defp merge_upstream_model_metadata(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      merge_upstream_model_metadata(left_value, right_value)
    end)
  end

  defp merge_upstream_model_metadata(left, right) when is_list(left) and is_list(right),
    do: Enum.uniq(left ++ right)

  defp merge_upstream_model_metadata(left, right) when is_boolean(left) and is_boolean(right),
    do: left or right

  defp merge_upstream_model_metadata(nil, right), do: right
  defp merge_upstream_model_metadata(left, nil), do: left
  defp merge_upstream_model_metadata(left, _right), do: left

  defp count_model_changes(changes) do
    Enum.count(changes, fn
      {{:model, _exposed_id}, %Model{}} -> true
      _change -> false
    end)
  end

  defp sanitize_sync_error(%{message: message}), do: sanitize_sync_error(message)
  defp sanitize_sync_error(%{code: _code}), do: "model catalog sync failed"

  defp sanitize_sync_error(message) when is_binary(message) do
    sensitive_markers = [
      "Authorization:",
      "Bearer",
      "access_token",
      "refresh_token",
      "api_key",
      "cookie",
      "chatgpt-account-id",
      "x-codex",
      "token="
    ]

    if Enum.any?(sensitive_markers, &String.contains?(message, &1)) do
      "model catalog sync failed"
    else
      message
    end
  end

  defp sanitize_sync_error(_reason), do: "model catalog sync failed"

  defp get_model_by_exposed_id(pool_id, exposed_model_id) when is_binary(exposed_model_id) do
    Repo.one(
      from model in Model,
        where:
          model.pool_id == ^pool_id and
            fragment("lower(?)", model.exposed_model_id) ==
              ^String.downcase(String.trim(exposed_model_id)),
        limit: 1
    )
  end

  defp get_model_by_exposed_id(_pool_id, _exposed_model_id), do: nil

  defp catalog_error(code, message), do: %{code: code, message: message}
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
