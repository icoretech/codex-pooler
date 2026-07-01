defmodule CodexPooler.Accounting.RequestLogs do
  @moduledoc """
  Request-log read model and safe error shaping for admin reporting.

  The list projection intentionally keeps the legacy request-log contract stable:
  totals count the exact filtered visible request rows before pagination, rows are
  ordered by `requests.admitted_at DESC, requests.id DESC`, offset pagination is
  preserved, upstream filters apply to the latest attempt only, latest attempts
  are selected by highest `attempt_number`, and settlement presentation uses the
  newest recorded settlement by `occurred_at`, `created_at`, then `id`.
  """

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request, RequestLogFact}

  alias CodexPooler.Accounting.RequestLogs.{
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

  @spec get_for_scope(CodexPooler.Accounts.Scope.t(), Ecto.UUID.t()) :: map() | nil
  def get_for_scope(%CodexPooler.Accounts.Scope{} = scope, request_id)
      when is_binary(request_id) do
    visible_pool_ids = scope |> Pools.list_log_filter_pools() |> Enum.map(& &1.id)

    request_log_query()
    |> maybe_filter_request_log_visible_pools(visible_pool_ids)
    |> where([request, ...], request.id == ^request_id)
    |> request_log_rows(1, 0)
    |> request_log_items()
    |> List.first()
  end

  @spec list_models(term(), keyword()) :: [String.t()]
  def list_models(pool_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)
    visible_pool_ids = Keyword.get(opts, :visible_pool_ids)

    Request
    |> maybe_filter_request_model_visible_pools(visible_pool_ids)
    |> maybe_filter_request_model_pool(pool_id)
    |> where([request], not is_nil(request.requested_model) and request.requested_model != "")
    |> where([request], not like(request.requested_model, "/%"))
    |> distinct(true)
    |> select([request], request.requested_model)
    |> Repo.all()
    |> Enum.sort_by(&String.downcase/1)
  end

  @spec list_models_for_scope(CodexPooler.Accounts.Scope.t()) :: [String.t()]
  def list_models_for_scope(%CodexPooler.Accounts.Scope{} = scope) do
    visible_pool_ids = scope |> Pools.list_log_filter_pools() |> Enum.map(& &1.id)
    list_models(nil, visible_pool_ids: visible_pool_ids)
  end

  defp list_for_pool_filter(pool_id, opts) do
    %{limit: limit, offset: offset, filters: filters, visible_pool_ids: visible_pool_ids} =
      request_log_options(opts)

    query =
      request_log_query()
      |> maybe_filter_request_log_visible_pools(visible_pool_ids)
      |> maybe_filter_request_log_pool(pool_id)
      |> apply_request_log_filters(filters)

    total = Repo.aggregate(query, :count, :id)
    rows = request_log_rows(query, limit, offset)

    %{items: request_log_items(rows), total: total, limit: limit, offset: offset}
  end

  defp request_log_options(opts) do
    %{
      limit: opts |> Keyword.get(:limit, 50) |> clamp_limit(),
      offset: max(Keyword.get(opts, :offset, 0), 0),
      filters: Keyword.get(opts, :filters, []),
      visible_pool_ids: Keyword.get(opts, :visible_pool_ids)
    }
  end

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

  defp request_log_items(rows) do
    attempts_by_request =
      request_log_attempts_by_request(
        Enum.map(rows, fn {request, _, _, _, _, _, _} -> request.id end)
      )

    turns_by_request =
      rows
      |> Enum.map(fn {request, _, _, _, _, _, _} -> request.id end)
      |> SessionReadModel.request_turns_by_request_ids()

    Enum.map(rows, fn row -> request_log_item(row, attempts_by_request, turns_by_request) end)
  end

  defp request_log_item(
         {request, pool, key, latest, assignment, identity, settlement},
         attempts,
         turns_by_request
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
      reasoning_effort: request.reasoning_effort,
      applied_reasoning_effort: reasoning_metadata_field(reasoning_metadata, "applied_effort"),
      effective_reasoning_effort:
        reasoning_metadata_field(reasoning_metadata, "effective_effort"),
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
      token_counts: SettlementPresentation.token_counts(settlement),
      cost: SettlementPresentation.cost(settlement),
      payload_compression: PayloadCompressionProjection.build(metadata),
      errors: ErrorSummaries.build(request, metadata, request_attempts),
      debug: DebugProjection.build(request, metadata, turn, request_attempts),
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

  defp apply_request_log_filters(query, filters) do
    filters = Map.new(filters)

    query
    |> maybe_filter_request_log_status(Map.get(filters, :status))
    |> maybe_filter_request_log_upstream(Map.get(filters, :upstream_identity_id))
    |> maybe_filter_request_log_model(Map.get(filters, :model))
    |> maybe_filter_request_log_request_id(Map.get(filters, :request_id))
    |> maybe_filter_request_log_date_from(Map.get(filters, :date_from))
    |> maybe_filter_request_log_date_to(Map.get(filters, :date_to))
  end

  defp maybe_filter_request_log_pool(query, nil), do: query

  defp maybe_filter_request_log_pool(query, pool_id),
    do: from([request, ...] in query, where: request.pool_id == ^pool_id)

  defp maybe_filter_request_log_visible_pools(query, nil), do: query

  defp maybe_filter_request_log_visible_pools(query, pool_ids) when is_list(pool_ids),
    do: from([request, ...] in query, where: request.pool_id in ^pool_ids)

  defp maybe_filter_request_model_pool(query, nil), do: query

  defp maybe_filter_request_model_pool(query, pool_id),
    do: from(request in query, where: request.pool_id == ^pool_id)

  defp maybe_filter_request_model_visible_pools(query, nil), do: query

  defp maybe_filter_request_model_visible_pools(query, pool_ids) when is_list(pool_ids),
    do: from(request in query, where: request.pool_id in ^pool_ids)

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
    pattern = "%#{request_id}%"

    from([request, ...] in query,
      where:
        fragment("?::text ILIKE ?", request.id, ^pattern) or
          ilike(request.correlation_id, ^pattern) or
          fragment("?->>? ILIKE ?", request.request_metadata, "request_id", ^pattern) or
          fragment("?->>? ILIKE ?", request.request_metadata, "client_request_id", ^pattern)
    )
  end

  defp maybe_filter_request_log_date_from(query, nil), do: query

  defp maybe_filter_request_log_date_from(query, date_from),
    do: from([request, ...] in query, where: request.admitted_at >= ^date_from)

  defp maybe_filter_request_log_date_to(query, nil), do: query

  defp maybe_filter_request_log_date_to(query, date_to),
    do: from([request, ...] in query, where: request.admitted_at <= ^date_to)

  defp request_log_attempts_by_request([]), do: %{}

  defp request_log_attempts_by_request(request_ids) do
    Attempt
    |> where([attempt], attempt.request_id in ^request_ids)
    |> order_by([attempt], asc: attempt.request_id, asc: attempt.attempt_number)
    |> Repo.all()
    |> Enum.group_by(& &1.request_id)
  end

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
