defmodule CodexPooler.Accounting.RequestLogs.ModelHistory do
  @moduledoc "Attempt-based model observations within a bounded retained-history window."

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, ModelObservation, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type result :: %{from: DateTime.t(), until: DateTime.t(), counts: map(), groups: [map()], attempts: [map()], pools: [Pool.t()], filters: map(), timeline: [map()], bucket_seconds: pos_integer(), models: [String.t()], model_pairs: [map()]}

  @spec for_scope(Scope.t(), map(), keyword()) :: result()
  def for_scope(%Scope{} = scope, params \\ %{}, opts \\ []) do
    pools = Pools.list_log_filter_pools(scope)
    filters = normalize_filters(params)
    until = Keyword.get(opts, :now, DateTime.utc_now())
    from = DateTime.add(until, -hours(filters["window"]) * 3600, :second)
    query = query(Enum.map(pools, & &1.id), from, until, filters)

    counts = query |> counts_query() |> Repo.one(timeout: 15_000, telemetry_options: [reporting_projection: :lens_model_history])
    bucket_seconds = bucket_seconds(filters["window"])
    timeline = timeline(query, from, until, bucket_seconds, counts)

    groups =
      query
      |> evidence_filter("signals")
      |> group_by([a, r, p, i], [r.pool_id, p.name, a.upstream_identity_id, i.account_label, a.upstream_model_id])
      |> counts_query()
      |> select_merge([a, r, p, i], %{pool_id: r.pool_id, pool_name: p.name, upstream_identity_id: a.upstream_identity_id, upstream_label: i.account_label, sent_model: a.upstream_model_id})
      |> order_by([a, r], desc: count(a.id), asc: r.pool_id, asc: a.upstream_identity_id, asc: a.upstream_model_id)
      |> limit(100)
      |> Repo.all(timeout: 15_000)

    attempts =
      query
      |> evidence_filter(filters["evidence"])
      |> order_by([a], desc: a.started_at, desc: a.id)
      |> limit(100)
      |> select([a, r, p, i], %{id: a.id, request_id: r.id, attempt_number: a.attempt_number, started_at: a.started_at, status: a.status, pool_name: p.name, upstream_label: i.account_label, sent_model: a.upstream_model_id, served_model: a.served_model, model_observation: a.model_observation})
      |> Repo.all(timeout: 15_000)
      |> Enum.map(fn attempt -> Map.update!(attempt, :model_observation, &ModelObservation.normalize(&1, attempt.served_model)) end)

    models =
      query(Enum.map(pools, & &1.id), from, until, Map.put(filters, "sent_model", ""))
      |> where([a], not is_nil(a.upstream_model_id) and a.upstream_model_id != "")
      |> select([a], a.upstream_model_id)
      |> distinct(true)
      |> order_by([a], a.upstream_model_id)
      |> limit(200)
      |> Repo.all(timeout: 15_000)

    model_pairs =
      query
      |> evidence_filter("signals")
      |> group_by([a], [a.upstream_model_id, a.served_model, fragment("?->>'first_conflicting_model'", a.model_observation)])
      |> counts_query()
      |> select_merge([a], %{sent_model: a.upstream_model_id, first_model: a.served_model, conflicting_model: fragment("?->>'first_conflicting_model'", a.model_observation)})
      |> order_by([a], desc: count(a.id), asc: a.upstream_model_id, asc: a.served_model, asc: fragment("?->>'first_conflicting_model'", a.model_observation))
      |> limit(8)
      |> Repo.all(timeout: 15_000)

    %{from: from, until: until, counts: counts, groups: groups, attempts: attempts, pools: pools, filters: filters, timeline: timeline, bucket_seconds: bucket_seconds, models: models, model_pairs: model_pairs}
  end

  defp timeline(query, from_time, until_time, seconds, counts) do
    # Aggregate the same scoped attempt relation as the counters. A retry stays
    # a separate attempt, and the evidence-list filter cannot erase coverage.
    rows =
      query
      |> group_by([a], selected_as(:bucket_index))
      |> counts_query()
      |> select_merge([a], %{bucket_index: selected_as(fragment("floor(extract(epoch from (? - ?::timestamp)) / ?)::integer", a.started_at, type(^from_time, :utc_datetime_usec), ^seconds), :bucket_index)})
      |> Repo.all(timeout: 15_000)
      |> Map.new(&{&1.bucket_index, Map.delete(&1, :bucket_index)})

    empty = Map.new(counts, fn {key, _value} -> {key, 0} end)
    bucket_count = div(DateTime.diff(until_time, from_time, :second), seconds)

    for index <- 0..(bucket_count - 1) do
      Map.put(Map.get(rows, index, empty), :bucket, DateTime.add(from_time, index * seconds, :second))
    end
  end

  defp bucket_seconds("1h"), do: 300
  defp bucket_seconds("7d"), do: 21_600
  defp bucket_seconds(_window), do: 3_600

  @spec normalize_filters(map()) :: map()
  def normalize_filters(params) do
    %{
      "window" => if(params["window"] in ~w(1h 24h 7d), do: params["window"], else: "24h"),
      "pool_id" => filter_string(params["pool_id"], 36),
      "upstream_identity_id" => filter_string(params["upstream_identity_id"], 36),
      "sent_model" => filter_string(params["sent_model"], 80),
      "evidence" => if(params["evidence"] in ~w(all signals conflict mismatch missing uncollected partial), do: params["evidence"], else: "signals")
    }
  end

  @spec query([Ecto.UUID.t()], DateTime.t(), DateTime.t(), map()) :: Ecto.Query.t()
  def query(pool_ids, from_time, until_time, filters) do
    # Keep history out of the open-attempt recovery index family. Both disjoint
    # branches state their partial-index predicates literally for generic plans.
    closed = from(a in Attempt, where: fragment("? NOT IN ('queued', 'in_progress')", a.status) and a.started_at >= ^from_time and a.started_at < ^until_time)
    open = from(a in Attempt, where: fragment("? IN ('queued', 'in_progress')", a.status) and a.started_at >= ^from_time and a.started_at < ^until_time)
    attempts = union_all(closed, ^open)

    from(a in subquery(attempts), join: r in Request, on: r.id == a.request_id, join: p in Pool, on: p.id == r.pool_id, left_join: i in UpstreamIdentity, on: i.id == a.upstream_identity_id, where: r.pool_id in ^pool_ids)
    |> filter_uuid(:pool, filters["pool_id"])
    |> filter_uuid(:upstream, filters["upstream_identity_id"])
    |> filter_model(filters["sent_model"])
  end

  # A mismatch and a declaration conflict overlap. Neither is a partition of
  # total attempts; old rows are excluded from the new-observer denominator.
  defp counts_query(query) do
    select(query, [a], %{
      total: count(a.id),
      collected: filter(count(a.id), fragment("?->>'version' = '1'", a.model_observation)),
      observed: filter(count(a.id), fragment("?->>'version' = '1' AND ?->>'conflict' IN ('true', 'false')", a.model_observation, a.model_observation) and not is_nil(a.served_model)),
      missing: filter(count(a.id), fragment("?->>'version' = '1'", a.model_observation) and is_nil(a.served_model)),
      uncollected: filter(count(a.id), fragment("(?->>'version') IS DISTINCT FROM '1'", a.model_observation)),
      comparable: filter(count(a.id), not is_nil(a.served_model) and not is_nil(a.upstream_model_id)),
      mismatches: filter(count(a.id), not is_nil(a.served_model) and not is_nil(a.upstream_model_id) and fragment("lower(?) <> lower(?)", a.served_model, a.upstream_model_id)),
      conflicts: filter(count(a.id), fragment("?->>'version' = '1' AND ?->>'conflict' = 'true'", a.model_observation, a.model_observation) and not is_nil(a.served_model)),
      partial: filter(count(a.id), fragment("?->>'version' = '1' AND ?->>'coverage' = 'partial'", a.model_observation, a.model_observation)),
      without_terminal: filter(count(a.id), fragment("?->>'version' = '1' AND ?->>'terminal_status' IS NULL", a.model_observation, a.model_observation))
    })
  end

  defp evidence_filter(query, "signals"), do: where(query, [a], (not is_nil(a.served_model) and not is_nil(a.upstream_model_id) and fragment("lower(?) <> lower(?)", a.served_model, a.upstream_model_id)) or fragment("?->>'version' = '1' AND ?->>'conflict' = 'true'", a.model_observation, a.model_observation))
  defp evidence_filter(query, "conflict"), do: where(query, [a], fragment("?->>'version' = '1' AND ?->>'conflict' = 'true'", a.model_observation, a.model_observation))
  defp evidence_filter(query, "mismatch"), do: where(query, [a], not is_nil(a.served_model) and not is_nil(a.upstream_model_id) and fragment("lower(?) <> lower(?)", a.served_model, a.upstream_model_id))
  defp evidence_filter(query, "missing"), do: where(query, [a], fragment("?->>'version' = '1'", a.model_observation) and is_nil(a.served_model))
  defp evidence_filter(query, "uncollected"), do: where(query, [a], fragment("(?->>'version') IS DISTINCT FROM '1'", a.model_observation))
  defp evidence_filter(query, "partial"), do: where(query, [a], fragment("?->>'version' = '1' AND ?->>'coverage' = 'partial'", a.model_observation, a.model_observation))
  defp evidence_filter(query, _all), do: query

  defp filter_uuid(query, _kind, ""), do: query

  defp filter_uuid(query, kind, value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} when kind == :pool -> where(query, [_a, r], r.pool_id == ^id)
      {:ok, id} -> where(query, [a], a.upstream_identity_id == ^id)
      :error -> where(query, false)
    end
  end

  defp filter_model(query, ""), do: query
  defp filter_model(query, model), do: where(query, [a], a.upstream_model_id == ^model)
  defp hours("1h"), do: 1
  defp hours("7d"), do: 168
  defp hours(_window), do: 24
  defp filter_string(value, max) when is_binary(value) and byte_size(value) <= max, do: String.trim(value)
  defp filter_string(_value, _max), do: ""
end
