defmodule CodexPooler.Accounting.RequestLogs do
  @moduledoc """
  Request-log read model and safe error shaping for admin reporting.

  The list projection intentionally keeps the legacy request-log contract stable:
  totals count the exact filtered visible request rows before pagination (at most
  `:count_limit` of them when a reader bounds the count), rows are
  ordered by `requests.admitted_at DESC, requests.id DESC`, offset pagination is
  preserved, upstream filters apply to the latest attempt only, latest attempts
  are selected by highest `attempt_number`, and settlement presentation uses the
  newest recorded settlement by `occurred_at`, `created_at`, then `id`.

  Two cursor filters bound a page in the list's own sort key rather than in time
  alone: `:at_or_before` selects rows at or behind an `{admitted_at, id}` cursor
  and `:after` selects rows ahead of it. They exist because `admitted_at` is the
  transaction timestamp, so rows admitted together share it exactly and only
  `id` orders them.
  """

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogFact}

  alias CodexPooler.Accounting.RequestLogs.{
    CompactionBridgeProjection,
    DebugProjection,
    ErrorSummaries,
    PayloadCompressionProjection,
    SettlementPresentation
  }

  alias CodexPooler.Gateway.Persistence.SessionReadModel
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @proxy_control_route_class RouteClass.proxy_control()
  @usage_known "usage_known"
  @doc """
  One page of request logs and the number of rows that match.

  `total` is exact unless `:count_limit` is given: then at most that many rows
  are counted, and when more match `total` is `count_limit` and `total_exact?`
  is `false`, so a reader can say "more than" instead of a wrong number.
  """
  @spec list(term(), keyword()) :: map()
  def list(pool_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)
    list_for_pool_filter(pool_id, opts)
  end

  @spec list_for_scope(CodexPooler.Accounts.Scope.t(), keyword()) :: map()
  def list_for_scope(%CodexPooler.Accounts.Scope{} = scope, opts \\ []) do
    visible_pool_ids = scope |> Pools.list_log_filter_pools() |> Enum.map(& &1.id)
    list_for_pool_filter(nil, Keyword.put(opts, :visible_pool_ids, visible_pool_ids))
  end

  @spec get_for_scope(CodexPooler.Accounts.Scope.t(), Ecto.UUID.t(), keyword()) :: map() | nil
  def get_for_scope(%CodexPooler.Accounts.Scope{} = scope, request_id, opts \\ [])
      when is_binary(request_id) do
    visible_pool_ids = scope |> Pools.list_log_filter_pools() |> Enum.map(& &1.id)

    item =
      request_log_query()
      |> maybe_filter_request_log_visible_pools(visible_pool_ids)
      |> where([request, ...], request.id == ^request_id)
      |> request_log_rows(1, 0)
      |> request_log_items(request_log_surface(Keyword.get(opts, :surface)))
      |> List.first()

    enrich_detail_settlement(item)
  end

  # Every requested model a Pool's request history holds, read as a loose index
  # scan over `requests_pool_listed_model_idx`: each step asks the index for the
  # first model after the previous one, so the work grows with the number of
  # distinct models per Pool, not with the history. A plain `DISTINCT` read the
  # whole table on every request-log load (findings#206 row 206-373).
  # Blank models and endpoint paths recorded as the model of a metadata request
  # (`/backend-api/...`) are not models. The index is partial on exactly that
  # row condition, so every step repeats it word for word: without it PostgreSQL
  # cannot prove the step's rows are in the index and falls back to reading the
  # Pool's history. The partial index is also what keeps it away from queries
  # that filter by Pool alone, such as the Observatory aggregate (row 206-389).
  @request_models_sql """
  WITH RECURSIVE models(pool_id, requested_model) AS (
    SELECT pool.id,
           (SELECT r.requested_model FROM requests r
             WHERE r.pool_id = pool.id
               AND r.requested_model > '' AND r.requested_model NOT LIKE '/%'
             ORDER BY r.requested_model LIMIT 1)
      FROM unnest($1::uuid[]) AS pool(id)
    UNION ALL
    SELECT models.pool_id,
           (SELECT r.requested_model FROM requests r
             WHERE r.pool_id = models.pool_id AND r.requested_model > models.requested_model
               AND r.requested_model > '' AND r.requested_model NOT LIKE '/%'
             ORDER BY r.requested_model LIMIT 1)
      FROM models
     WHERE models.requested_model IS NOT NULL
  )
  SELECT DISTINCT requested_model FROM models
   WHERE requested_model IS NOT NULL
  """

  @spec list_models(term(), keyword()) :: [String.t()]
  def list_models(pool_or_id, opts \\ []) do
    case request_model_pool_ids(id_for(pool_or_id), Keyword.get(opts, :visible_pool_ids)) do
      [] ->
        []

      pool_ids ->
        %{rows: rows} = Repo.query!(@request_models_sql, [Enum.map(pool_ids, &Ecto.UUID.dump!/1)])

        rows
        |> Enum.map(fn [model] -> model end)
        |> Enum.sort_by(&String.downcase/1)
    end
  end

  @spec list_models_for_scope(CodexPooler.Accounts.Scope.t()) :: [String.t()]
  def list_models_for_scope(%CodexPooler.Accounts.Scope{} = scope) do
    visible_pool_ids = scope |> Pools.list_log_filter_pools() |> Enum.map(& &1.id)
    list_models(nil, visible_pool_ids: visible_pool_ids)
  end

  defp list_for_pool_filter(pool_id, opts) do
    %{
      limit: limit,
      offset: offset,
      filters: filters,
      visible_pool_ids: visible_pool_ids,
      surface: surface
    } =
      request_log_options(opts)

    query =
      request_log_query()
      |> maybe_filter_request_log_visible_pools(visible_pool_ids)
      |> maybe_filter_request_log_pool(pool_id)
      |> apply_request_log_filters(filters)

    {total, total_exact?} = count_request_log_rows(query, Keyword.get(opts, :count_limit))
    rows = request_log_rows(query, limit, offset)

    %{items: request_log_items(rows, surface), total: total, total_exact?: total_exact?, limit: limit, offset: offset}
  end

  # The exact total reads every matching row: for an all-Pools page that is the
  # whole `requests` history through an index-only scan, 600 loads cost 10M
  # blocks on production (findings#206 row 206-385). With a `count_limit` the
  # count stops one row past the limit, so a reader learns either the exact
  # total or that more than `count_limit` rows match, and never pays for more.
  # The count selects only the request id, so the planner drops every unused
  # left join (facts, key, assignment, identity) as it does for the exact count.
  defp count_request_log_rows(query, nil), do: {Repo.aggregate(query, :count, :id), true}

  defp count_request_log_rows(query, count_limit) when is_integer(count_limit) and count_limit > 0 do
    bounded = from([request, ...] in query, select: %{id: request.id}, limit: ^(count_limit + 1))
    counted = Repo.one(from(row in subquery(bounded), select: count()))

    if counted > count_limit, do: {count_limit, false}, else: {counted, true}
  end

  defp request_log_options(opts) do
    %{
      limit: opts |> Keyword.get(:limit, 50) |> clamp_limit(),
      offset: max(Keyword.get(opts, :offset, 0), 0),
      filters: Keyword.get(opts, :filters, []),
      visible_pool_ids: Keyword.get(opts, :visible_pool_ids),
      surface: request_log_surface(Keyword.get(opts, :surface))
    }
  end

  @spec request_log_surface(term()) :: DebugProjection.surface()
  defp request_log_surface(:admin), do: :admin
  defp request_log_surface(_surface), do: :default

  defp request_log_query do
    from r in Request,
      join: pool in Pool,
      on: pool.id == r.pool_id,
      left_join: key in CodexPooler.Access.APIKey,
      on: key.id == r.api_key_id,
      left_join: latest in subquery(projected_latest_attempt_query()),
      on: latest.request_id == r.id,
      left_join: assignment in PoolUpstreamAssignment,
      on: assignment.id == latest.pool_upstream_assignment_id,
      left_join: identity in UpstreamIdentity,
      on: identity.id == latest.upstream_identity_id,
      left_join: settlement in subquery(projected_latest_settlement_query()),
      on: settlement.request_id == r.id
  end

  defp request_log_rows(query, limit, offset) do
    Repo.all(
      from [r, pool, key, latest, assignment, identity, settlement] in query,
        order_by: [desc: r.admitted_at, desc: r.id],
        limit: ^limit,
        offset: ^offset,
        select: {r, pool, key, latest, assignment, identity, settlement}
    )
  end

  defp request_log_items(rows, surface) do
    attempts_by_request =
      request_log_attempts_by_request(Enum.map(rows, fn {request, _, _, _, _, _, _} -> request.id end))

    turns_by_request =
      rows
      |> Enum.map(fn {request, _, _, _, _, _, _} -> request.id end)
      |> SessionReadModel.request_turns_by_request_ids()

    Enum.map(rows, fn row ->
      request_log_item(row, attempts_by_request, turns_by_request, surface)
    end)
  end

  defp request_log_item(
         {request, pool, key, latest, assignment, identity, settlement},
         attempts,
         turns_by_request,
         surface
       ) do
    request_attempts = Map.get(attempts, request.id, [])
    turn = Map.get(turns_by_request, request.id)
    metadata = safe_request_log_metadata(request.request_metadata || %{}, request_attempts)
    reasoning_metadata = latest_attempt_reasoning_metadata(request_attempts)

    %{
      id: request.id,
      pool_id: pool.id,
      pool_name: pool.name,
      pool_slug: pool.slug,
      api_key_id: request.api_key_id,
      api_key_display_name: maybe_field(key, :display_name),
      api_key_prefix: maybe_field(key, :key_prefix),
      pool_upstream_assignment_id: maybe_field(latest, :pool_upstream_assignment_id),
      assignment_label: maybe_field(assignment, :assignment_label),
      upstream_identity_id: maybe_field(latest, :upstream_identity_id),
      upstream_identity_label: maybe_field(identity, :account_label),
      upstream_account_label: request.upstream_account_label,
      upstream_account_email: request.upstream_account_email,
      upstream_account_plan_label: request.upstream_account_plan_label,
      upstream_account_plan_family: request.upstream_account_plan_family,
      requested_model: request.requested_model,
      upstream_model: latest_attempt_model(request_attempts, :upstream_model_id),
      served_model: latest_attempt_model(request_attempts, :served_model),
      reasoning_effort: request.reasoning_effort,
      applied_reasoning_effort: reasoning_metadata_field(reasoning_metadata, "applied_effort"),
      effective_reasoning_effort: reasoning_metadata_field(reasoning_metadata, "effective_effort"),
      reasoning_effort_source: reasoning_metadata_field(reasoning_metadata, "source"),
      reasoning_effort_rewrite: reasoning_metadata_field(reasoning_metadata, "rewrite"),
      service_tier: request.service_tier,
      requested_service_tier: request.requested_service_tier,
      actual_service_tier: request.actual_service_tier,
      endpoint: request.endpoint,
      transport: request.transport,
      user_agent: request.user_agent,
      status: request.status,
      usage_status: request.usage_status,
      correlation_id: request.correlation_id,
      response_status_code: request.response_status_code,
      retry_count: request.retry_count,
      denial_reason: request.last_error_code || maybe_field(latest, :network_error_code),
      latency_ms: maybe_field(latest, :latency_ms),
      settlement_entry_id: maybe_field(settlement, :settlement_entry_id),
      token_counts: SettlementPresentation.token_counts(settlement),
      cost: SettlementPresentation.cost(settlement),
      compaction_bridge: CompactionBridgeProjection.build(metadata),
      payload_compression: PayloadCompressionProjection.build(metadata),
      errors: ErrorSummaries.build(request, metadata, request_attempts),
      debug: DebugProjection.build(request, metadata, turn, request_attempts, surface),
      admitted_at: request.admitted_at,
      completed_at: request.completed_at,
      metadata: metadata
    }
  end

  defp safe_request_log_metadata(metadata, attempts) do
    metadata
    |> Accounting.sanitize_metadata()
    |> PayloadCompressionProjection.normalize_metadata(attempts)
    |> control_plane_metadata_only()
  end

  defp control_plane_metadata_only(%{"routing" => %{"route_class" => route_class}} = metadata)
       when route_class == @proxy_control_route_class do
    metadata
    |> Map.take(["endpoint"])
    |> maybe_put_map("routing", control_plane_routing_metadata(Map.get(metadata, "routing")))
    |> maybe_put_map("request", control_plane_request_metadata(Map.get(metadata, "request")))
  end

  defp control_plane_metadata_only(metadata), do: metadata

  defp control_plane_routing_metadata(routing) when is_map(routing) do
    routing
    |> Map.take(["route_class", "selected_assignment_id", "upstream_identity_id"])
    |> reject_blank_values()
  end

  defp control_plane_routing_metadata(_routing), do: %{}

  defp control_plane_request_metadata(request) when is_map(request) do
    request
    |> Map.take(["body_bytes", "content_type"])
    |> reject_blank_values()
  end

  defp control_plane_request_metadata(_request), do: %{}

  defp maybe_put_map(metadata, _key, value) when value == %{}, do: metadata
  defp maybe_put_map(metadata, key, value), do: Map.put(metadata, key, value)

  defp reject_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp projected_latest_attempt_query do
    from fact in RequestLogFact,
      select: %{
        request_id: fact.request_id,
        attempt_number: fact.latest_attempt_number,
        status: fact.latest_attempt_status,
        retryable: fact.latest_attempt_retryable,
        upstream_status_code: fact.latest_upstream_status_code,
        pool_upstream_assignment_id: fact.latest_pool_upstream_assignment_id,
        upstream_identity_id: fact.latest_upstream_identity_id,
        network_error_code: fact.latest_network_error_code,
        latency_ms: fact.latest_latency_ms
      }
  end

  defp projected_latest_settlement_query do
    from fact in RequestLogFact,
      where: not is_nil(fact.latest_settlement_entry_id),
      select: %{
        request_id: fact.request_id,
        settlement_entry_id: fact.latest_settlement_entry_id,
        usage_status: fact.latest_settlement_usage_status,
        pricing_status: fact.latest_settlement_pricing_status,
        input_tokens:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_input_tokens
            ),
            :integer
          ),
        cached_input_tokens:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_cached_input_tokens
            ),
            :integer
          ),
        cache_write_tokens:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_cache_write_tokens
            ),
            :integer
          ),
        output_tokens:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_output_tokens
            ),
            :integer
          ),
        reasoning_tokens:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_reasoning_tokens
            ),
            :integer
          ),
        total_tokens:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_total_tokens
            ),
            :integer
          ),
        settled_cost_micros:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_settled_cost_micros
            ),
            :integer
          ),
        cached_input_token_micros:
          type(
            fragment(
              "CASE WHEN ? = ? THEN ?::numeric ELSE NULL END",
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_cached_input_token_micros
            ),
            :decimal
          ),
        details:
          type(
            fragment(
              "CASE WHEN ? IS NULL THEN NULL WHEN ? = 'priced' THEN jsonb_strip_nulls(jsonb_build_object('pricing_status', ?, 'settled_cost_micros', CASE WHEN ? = ? THEN (?::bigint)::text ELSE NULL END, 'cached_input_cost_micros', CASE WHEN ? = ? THEN (?::bigint)::text ELSE NULL END)) ELSE jsonb_build_object('pricing_status', COALESCE(?, 'unpriced')) END",
              fact.latest_settlement_pricing_status,
              fact.latest_settlement_pricing_status,
              fact.latest_settlement_pricing_status,
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_settled_cost_micros,
              fact.latest_settlement_usage_status,
              ^@usage_known,
              fact.latest_cached_input_cost_micros,
              fact.latest_settlement_pricing_status
            ),
            :map
          )
      }
  end

  defp enrich_detail_settlement(nil), do: nil

  defp enrich_detail_settlement(%{settlement_entry_id: nil} = item) do
    item
    |> Map.update!(:token_counts, &SettlementPresentation.with_component_cost(&1, nil))
    |> Map.delete(:settlement_entry_id)
  end

  defp enrich_detail_settlement(item) do
    details =
      LedgerEntry
      |> where([entry], entry.id == ^item.settlement_entry_id)
      |> select([entry], entry.details)
      |> Repo.one()

    item
    |> Map.update!(:token_counts, &SettlementPresentation.with_component_cost(&1, details))
    |> Map.delete(:settlement_entry_id)
  end

  defp apply_request_log_filters(query, filters) do
    filters = Map.new(filters)

    query
    |> maybe_filter_request_log_status(Map.get(filters, :status))
    |> maybe_filter_request_log_upstream(Map.get(filters, :upstream_identity_id))
    |> maybe_filter_request_log_model(Map.get(filters, :model))
    |> maybe_filter_request_log_request_id(Map.get(filters, :request_id))
    |> maybe_filter_request_log_date_from(Map.get(filters, :date_from))
    |> maybe_filter_request_log_date_to(Map.get(filters, :date_to))
    |> maybe_filter_request_log_at_or_before(Map.get(filters, :at_or_before))
    |> maybe_filter_request_log_after(Map.get(filters, :after))
  end

  defp maybe_filter_request_log_pool(query, nil), do: query

  defp maybe_filter_request_log_pool(query, pool_id),
    do: from([request, ...] in query, where: request.pool_id == ^pool_id)

  defp maybe_filter_request_log_visible_pools(query, nil), do: query

  defp maybe_filter_request_log_visible_pools(query, pool_ids) when is_list(pool_ids),
    do: from([request, ...] in query, where: request.pool_id in ^pool_ids)

  # The Pools whose history the model list reads: the selected Pool, only when
  # the viewer can see it, else every visible Pool, else every Pool.
  defp request_model_pool_ids(nil, nil), do: Repo.all(from(pool in Pool, select: pool.id))
  defp request_model_pool_ids(nil, visible_pool_ids) when is_list(visible_pool_ids), do: Enum.uniq(visible_pool_ids)
  defp request_model_pool_ids(pool_id, nil), do: [pool_id]

  defp request_model_pool_ids(pool_id, visible_pool_ids) when is_list(visible_pool_ids),
    do: if(pool_id in visible_pool_ids, do: [pool_id], else: [])

  defp maybe_filter_request_log_status(query, nil), do: query

  defp maybe_filter_request_log_status(query, status),
    do: from([request, ...] in query, where: request.status == ^status)

  defp maybe_filter_request_log_upstream(query, nil), do: query

  defp maybe_filter_request_log_upstream(query, upstream_identity_id) do
    from([_request, _pool, _key, latest, _assignment, identity, _settlement] in query,
      where:
        latest.upstream_identity_id == ^upstream_identity_id or
          identity.id == ^upstream_identity_id
    )
  end

  defp maybe_filter_request_log_model(query, nil), do: query

  defp maybe_filter_request_log_model(query, model) do
    pattern = "%#{model}%"

    from([request, ...] in query,
      where: ilike(request.requested_model, ^pattern)
    )
  end

  defp maybe_filter_request_log_request_id(query, nil), do: query

  defp maybe_filter_request_log_request_id(query, request_id) do
    trimmed = String.trim(request_id)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} ->
        # A full UUID is an exact reference: two index lookups instead of a
        # sequential scan with per-row casts and JSONB extraction.
        from([request, ...] in query,
          where: request.id == ^uuid or request.correlation_id == ^trimmed
        )

      :error ->
        pattern = "%#{trimmed}%"

        from([request, ...] in query,
          where:
            fragment("?::text ILIKE ?", request.id, ^pattern) or
              ilike(request.correlation_id, ^pattern) or
              fragment("?->>? ILIKE ?", request.request_metadata, "request_id", ^pattern) or
              fragment("?->>? ILIKE ?", request.request_metadata, "client_request_id", ^pattern)
        )
    end
  end

  defp maybe_filter_request_log_date_from(query, nil), do: query

  defp maybe_filter_request_log_date_from(query, date_from),
    do: from([request, ...] in query, where: request.admitted_at >= ^date_from)

  defp maybe_filter_request_log_date_to(query, nil), do: query

  defp maybe_filter_request_log_date_to(query, date_to),
    do: from([request, ...] in query, where: request.admitted_at <= ^date_to)

  # Cursor bounds are expressed in the list's own sort key, not in time alone.
  # `admitted_at` is the transaction timestamp, so two requests admitted in one
  # transaction carry the same value and `id DESC` is what separates them: a
  # bound of `admitted_at <= t` would admit a row inserted after the cursor and
  # sorting above it, which is precisely the drift a cursor exists to prevent.
  defp maybe_filter_request_log_at_or_before(query, nil), do: query

  defp maybe_filter_request_log_at_or_before(query, {admitted_at, id}) do
    from([request, ...] in query,
      where:
        request.admitted_at < ^admitted_at or
          (request.admitted_at == ^admitted_at and request.id <= ^id)
    )
  end

  defp maybe_filter_request_log_after(query, nil), do: query

  defp maybe_filter_request_log_after(query, {admitted_at, id}) do
    from([request, ...] in query,
      where:
        request.admitted_at > ^admitted_at or
          (request.admitted_at == ^admitted_at and request.id > ^id)
    )
  end

  defp request_log_attempts_by_request([]), do: %{}

  defp request_log_attempts_by_request(request_ids) do
    Attempt
    |> where([attempt], attempt.request_id in ^request_ids)
    |> order_by([attempt], asc: attempt.request_id, asc: attempt.attempt_number)
    |> Repo.all()
    |> Enum.group_by(& &1.request_id)
  end

  # The model the latest attempt sent upstream and the one the provider
  # declared on its response object; a difference is a provider-side
  # substitution, which `requested_model` alone cannot show.
  defp latest_attempt_model(attempts, field) do
    case List.last(attempts) do
      %Attempt{} = attempt -> attempt |> Map.get(field) |> present_string()
      _attempt -> nil
    end
  end

  defp present_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp present_string(_value), do: nil

  defp latest_attempt_reasoning_metadata(attempts) do
    case List.last(attempts) do
      %{response_metadata: %{"reasoning" => metadata}} when is_map(metadata) -> metadata
      _attempt -> %{}
    end
  end

  defp reasoning_metadata_field(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      _value -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil

  defp maybe_field(nil, _field), do: nil
  defp maybe_field(struct, field), do: Map.get(struct, field)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 and limit <= 200, do: limit
  defp clamp_limit(_limit), do: 50
end
