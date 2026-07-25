defmodule CodexPooler.Jobs.ReadModel.Explorer do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Jobs.{HealthPolicy, ReadModel.FailurePresentation, ReadModel.Query}
  alias CodexPooler.Repo

  @explorer_page_size 20
  @completed_state "completed"

  def list(filters, opts \\ []) do
    filters = Query.normalize_explorer_filters(filters)
    limit = @explorer_page_size
    offset = Query.explorer_offset(filters.page, limit)

    query =
      Oban.Job
      |> apply_explorer_filters(filters)
      |> Query.maybe_filter_resolved_failure_visibility(filters, opts)

    if filters.attention do
      attention_filtered_page(query, filters.attention, limit, offset, opts)
    else
      total = Repo.aggregate(query, :count, :id)

      items =
        query
        |> Query.job_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> FailurePresentation.sanitize_jobs()
        |> Query.with_attention(opts)

      %{items: items, total: total, limit: limit, offset: offset}
    end
  end

  def filter_values do
    %{
      workers:
        Query.filter_option_values(
          Query.configured_worker_values(),
          Query.distinct_job_field_values(:worker)
        )
    }
  end

  def empty_filter_values, do: %{workers: []}

  def empty_page(filters) do
    limit = @explorer_page_size

    offset =
      filters
      |> Query.normalize_explorer_filters()
      |> Map.fetch!(:page)
      |> Query.explorer_offset(limit)

    %{items: [], total: 0, limit: limit, offset: offset}
  end

  defp apply_explorer_filters(queryable, filters) do
    queryable
    |> maybe_filter_completed_visibility(filters)
    |> maybe_filter_state(filters.state)
    |> Query.maybe_filter_explorer_worker(filters.worker)
    |> Query.maybe_filter_explorer_target(filters.target_kind, filters.target_id)
  end

  defp maybe_filter_completed_visibility(queryable, %{show_completed: true}), do: queryable
  defp maybe_filter_completed_visibility(queryable, %{state: @completed_state}), do: queryable

  defp maybe_filter_completed_visibility(queryable, _filters) do
    from job in queryable, where: job.state != @completed_state
  end

  defp maybe_filter_state(queryable, nil), do: queryable

  defp maybe_filter_state(queryable, state) do
    from job in queryable, where: job.state == ^state
  end

  defp attention_filtered_page(queryable, attention, limit, offset, opts) do
    now = Query.attention_now(opts)

    {:ok, {total, items}} =
      Repo.transaction(fn ->
        queryable
        |> Query.job_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> Repo.stream()
        |> Enum.reduce({0, []}, fn job, {total, items} ->
          collect_attention_item({total, items}, job, attention, now, limit, offset)
        end)
      end)

    %{
      items: items |> Enum.reverse() |> FailurePresentation.sanitize_jobs(),
      total: total,
      limit: limit,
      offset: offset
    }
  end

  defp collect_attention_item({total, items}, job, attention, now, limit, offset) do
    job = HealthPolicy.put_attention(job, now: now)

    if Atom.to_string(job.attention_state) == attention do
      {total + 1, maybe_collect_item(items, job, total, limit, offset)}
    else
      {total, items}
    end
  end

  defp maybe_collect_item(items, job, total, limit, offset) do
    if total >= offset and length(items) < limit, do: [job | items], else: items
  end
end
