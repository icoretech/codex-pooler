defmodule CodexPooler.Accounting.RequestLogs do
  @moduledoc """
  Request-log read model and safe error shaping for admin reporting.
  """

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLogs.{ErrorSummaries, SettlementPresentation}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @entry_settlement "settlement"
  @proxy_control_route_class RouteClass.proxy_control()
  @bounded_detail_attempts 10

  @spec list(term(), keyword()) :: map()
  def list(pool_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)
    list_for_pool_filter(pool_id, opts)
  end

  @spec list_for_scope(CodexPooler.Accounts.Scope.t(), keyword()) :: map()
  def list_for_scope(%CodexPooler.Accounts.Scope{} = scope, opts \\ []) do
    visible_pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)
    list_for_pool_filter(nil, Keyword.put(opts, :visible_pool_ids, visible_pool_ids))
  end

  @spec get_for_scope(CodexPooler.Accounts.Scope.t(), Ecto.UUID.t()) :: map() | nil
  def get_for_scope(%CodexPooler.Accounts.Scope{} = scope, request_id)
      when is_binary(request_id) do
    visible_pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)

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
    visible_pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)
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
      left_join: latest in subquery(latest_attempt_query()),
      on: latest.request_id == r.id,
      left_join: assignment in PoolUpstreamAssignment,
      on: assignment.id == latest.pool_upstream_assignment_id,
      left_join: identity in UpstreamIdentity,
      on: identity.id == latest.upstream_identity_id,
      left_join: settlement in subquery(latest_settlement_query()),
      on: settlement.request_id == r.id,
      left_join: turn in CodexTurn,
      on: turn.request_id == r.id
  end

  defp request_log_rows(query, limit, offset) do
    Repo.all(
      from [r, pool, key, latest, assignment, identity, settlement, turn] in query,
        order_by: [desc: r.admitted_at, desc: r.id],
        limit: ^limit,
        offset: ^offset,
        select: {r, pool, key, latest, assignment, identity, settlement, turn}
    )
  end

  defp request_log_items(rows) do
    attempts_by_request =
      request_log_attempts_by_request(
        Enum.map(rows, fn {request, _, _, _, _, _, _, _} -> request.id end)
      )

    Enum.map(rows, fn row -> request_log_item(row, attempts_by_request) end)
  end

  defp request_log_item(
         {request, pool, key, latest, assignment, identity, settlement, turn},
         attempts
       ) do
    metadata = safe_request_log_metadata(request.request_metadata || %{})
    request_attempts = Map.get(attempts, request.id, [])

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
      errors: ErrorSummaries.build(request, metadata, request_attempts),
      debug: debug_projection(request, metadata, turn, request_attempts),
      admitted_at: request.admitted_at,
      completed_at: request.completed_at,
      metadata: metadata
    }
  end

  @spec debug_projection(Request.t(), map(), CodexTurn.t() | nil, [Attempt.t()]) :: map()
  defp debug_projection(%Request{} = request, metadata, turn, attempts) do
    attempts = Enum.sort_by(attempts, & &1.attempt_number)
    latest_attempt = List.last(attempts)
    continuity = continuity_projection(request, metadata, turn)

    %{
      continuity: continuity,
      failure: failure_projection(request, turn, latest_attempt),
      attempt: attempt_projection(latest_attempt, attempts),
      terminal_state: terminal_state_projection(request, turn, latest_attempt, continuity),
      turn: turn_projection(request, turn, attempts),
      attempts: detail_attempts(request, turn, attempts)
    }
  end

  defp continuity_projection(request, metadata, turn) do
    {metadata_session_id, session_shape} = metadata_session_id(metadata)
    session_id = metadata_session_id || maybe_field(turn, :codex_session_id)
    turn_status = maybe_field(turn, :status)
    terminal = terminal_state(request, turn, latest_attempt: nil, session_shape: session_shape)

    %{
      status: continuity_status(terminal.state, session_shape, session_id, turn),
      session_ref: ref(:session, session_id),
      session_source: if(present?(session_id), do: "continuity"),
      turn_ref: ref(:turn, maybe_field(turn, :id)),
      turn_status: turn_status,
      turn_status_source: if(present?(turn_status), do: "turn_state"),
      has_open_turn: has_open_turn(turn_status),
      terminal_state: terminal.state,
      terminal_state_source: terminal.source
    }
  end

  defp continuity_status("mismatch", _session_shape, _session_id, _turn), do: "mismatch"
  defp continuity_status(_state, :malformed, _session_id, nil), do: "unknown"

  defp continuity_status(_state, _session_shape, session_id, turn) do
    if present?(session_id) or present?(maybe_field(turn, :id)) do
      "available"
    else
      "not_applicable"
    end
  end

  defp terminal_state_projection(request, turn, latest_attempt, continuity) do
    terminal =
      terminal_state(request, turn,
        latest_attempt: latest_attempt,
        session_shape: continuity_status_to_session_shape(continuity.status)
      )

    %{
      state: terminal.state,
      mismatch: terminal.state == "mismatch",
      sources: state_sources(request, turn, latest_attempt)
    }
  end

  defp terminal_state(request, turn, opts) do
    latest_attempt = Keyword.get(opts, :latest_attempt)
    session_shape = Keyword.get(opts, :session_shape, :missing)
    turn_status = maybe_field(turn, :status)
    request_status = request.status

    turn_terminal_state(request_status, turn_status) ||
      session_terminal_state(session_shape) ||
      request_terminal_state(request_status) ||
      attempt_terminal_state(latest_attempt) ||
      %{state: "unknown", source: nil}
  end

  defp turn_terminal_state(request_status, "in_progress") do
    if terminal_request_status?(request_status) do
      %{state: "mismatch", source: "turn_state"}
    else
      %{state: "in_progress", source: "turn_state"}
    end
  end

  defp turn_terminal_state(_request_status, turn_status) do
    if terminal_status?(turn_status), do: %{state: "terminal", source: "turn_state"}
  end

  defp session_terminal_state(:malformed), do: %{state: "unknown", source: nil}
  defp session_terminal_state(_session_shape), do: nil

  defp request_terminal_state("in_progress"), do: %{state: "in_progress", source: "request_state"}
  defp request_terminal_state("rejected"), do: %{state: "not_applicable", source: nil}

  defp request_terminal_state(request_status) do
    if terminal_request_status?(request_status), do: %{state: "terminal", source: "request_state"}
  end

  defp attempt_terminal_state(latest_attempt) do
    if terminal_status?(maybe_field(latest_attempt, :status)),
      do: %{state: "terminal", source: "attempt_state"}
  end

  defp continuity_status_to_session_shape("unknown"), do: :malformed
  defp continuity_status_to_session_shape(_status), do: :missing

  defp state_sources(request, turn, latest_attempt) do
    [
      %{source: "request_state", status: request.status, error_code: request.last_error_code},
      source_for_turn(turn),
      source_for_attempt(latest_attempt)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp source_for_turn(nil), do: nil

  defp source_for_turn(turn) do
    %{source: "turn_state", status: turn.status, error_code: turn.error_code}
  end

  defp source_for_attempt(nil), do: nil

  defp source_for_attempt(attempt) do
    %{source: "attempt_state", status: attempt.status, error_code: attempt.network_error_code}
  end

  defp failure_projection(request, turn, latest_attempt) do
    cond do
      terminal_status?(maybe_field(turn, :status)) and present?(maybe_field(turn, :error_code)) ->
        %{error_code: turn.error_code, error_source: "turn_error"}

      present?(request.last_error_code) ->
        %{error_code: request.last_error_code, error_source: "request_error"}

      present?(maybe_field(latest_attempt, :network_error_code)) ->
        %{error_code: latest_attempt.network_error_code, error_source: "attempt_error"}

      present?(maybe_field(turn, :error_code)) ->
        %{error_code: turn.error_code, error_source: "turn_error"}

      true ->
        %{error_code: nil, error_source: nil}
    end
  end

  defp attempt_projection(latest_attempt, attempts) do
    %{
      latest_attempt_number: maybe_field(latest_attempt, :attempt_number),
      latest_attempt_status: maybe_field(latest_attempt, :status),
      latest_attempt_retryable: maybe_field(latest_attempt, :retryable),
      latest_upstream_status_code: maybe_field(latest_attempt, :upstream_status_code),
      attempt_count: length(attempts)
    }
  end

  defp turn_projection(_request, nil, _attempts) do
    %{
      turn_ref: nil,
      status: nil,
      error_code: nil,
      final_attempt_ref: nil,
      inserted_at: nil,
      updated_at: nil,
      completed_at: nil
    }
  end

  defp turn_projection(request, turn, attempts) do
    %{
      turn_ref: ref(:turn, turn.id),
      status: turn.status,
      error_code: turn.error_code,
      final_attempt_ref: final_attempt_ref(request, turn, attempts),
      inserted_at: iso8601(turn.created_at),
      updated_at: iso8601(turn.updated_at),
      completed_at: iso8601(turn.completed_at)
    }
  end

  defp final_attempt_ref(request, turn, attempts) do
    attempts
    |> Enum.find(&(&1.id == turn.final_attempt_id))
    |> case do
      nil -> nil
      attempt -> attempt_ref(request.id, attempt.attempt_number)
    end
  end

  defp detail_attempts(request, turn, attempts) do
    attempts
    |> Enum.sort_by(& &1.attempt_number, :desc)
    |> Enum.take(@bounded_detail_attempts)
    |> Enum.sort_by(& &1.attempt_number)
    |> Enum.map(&detail_attempt(request.id, turn, &1))
  end

  defp detail_attempt(request_id, turn, attempt) do
    %{
      attempt_ref: attempt_ref(request_id, attempt.attempt_number),
      attempt_number: attempt.attempt_number,
      status: attempt.status,
      retryable: attempt.retryable,
      upstream_status_code: attempt.upstream_status_code,
      network_error_code: attempt.network_error_code,
      latency_ms: attempt.latency_ms,
      final: maybe_field(turn, :final_attempt_id) == attempt.id
    }
  end

  defp metadata_session_id(metadata) when is_map(metadata) do
    case Map.fetch(metadata, "codex_session_id") do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {nil, :malformed}, else: {value, :valid}

      {:ok, nil} ->
        {nil, :missing}

      {:ok, _value} ->
        {nil, :malformed}

      :error ->
        {nil, :missing}
    end
  end

  defp ref(_kind, value) when not is_binary(value), do: nil
  defp ref(_kind, ""), do: nil
  defp ref(:session, value), do: "session_" <> short_hash("codex_session:" <> value)
  defp ref(:turn, value), do: "turn_" <> short_hash("codex_turn:" <> value)

  defp attempt_ref(request_id, attempt_number) do
    "attempt_" <> short_hash("request_attempt:#{request_id}:#{attempt_number}")
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp terminal_status?(status)
       when status in ["succeeded", "failed", "interrupted", "cancelled"],
       do: true

  defp terminal_status?(_status), do: false

  defp terminal_request_status?(status) when status in ["succeeded", "failed"], do: true
  defp terminal_request_status?(_status), do: false

  defp has_open_turn("in_progress"), do: true
  defp has_open_turn(status) when is_binary(status), do: false
  defp has_open_turn(_status), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil

  defp maybe_field(nil, _field), do: nil
  defp maybe_field(struct, field), do: Map.get(struct, field)

  defp safe_request_log_metadata(metadata) do
    metadata
    |> Accounting.sanitize_metadata()
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

  defp latest_attempt_query do
    from a in Attempt,
      distinct: a.request_id,
      order_by: [asc: a.request_id, desc: a.attempt_number],
      select: %{
        request_id: a.request_id,
        attempt_number: a.attempt_number,
        pool_upstream_assignment_id: a.pool_upstream_assignment_id,
        upstream_identity_id: a.upstream_identity_id,
        network_error_code: a.network_error_code,
        latency_ms: a.latency_ms,
        response_metadata: a.response_metadata
      }
  end

  defp latest_settlement_query do
    from entry in LedgerEntry,
      left_join: pricing in PricingSnapshot,
      on: pricing.id == entry.pricing_snapshot_id,
      where: entry.entry_kind == @entry_settlement,
      distinct: entry.request_id,
      order_by: [asc: entry.request_id, desc: entry.occurred_at, desc: entry.created_at],
      select: %{
        request_id: entry.request_id,
        usage_status: entry.usage_status,
        input_tokens: entry.input_tokens,
        cached_input_tokens: entry.cached_input_tokens,
        output_tokens: entry.output_tokens,
        reasoning_tokens: entry.reasoning_tokens,
        total_tokens: entry.total_tokens,
        settled_cost_micros: entry.settled_cost_micros,
        cached_input_token_micros: pricing.cached_input_token_micros,
        details: entry.details
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
    from([_request, _pool, _key, latest, _assignment, identity, _settlement, _turn] in query,
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

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 and limit <= 200, do: limit
  defp clamp_limit(_limit), do: 50
end
