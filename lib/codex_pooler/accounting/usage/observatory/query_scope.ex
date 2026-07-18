defmodule CodexPooler.Accounting.Usage.Observatory.QueryScope do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.Catalog.Model

  @settlement "settlement"
  @recorded "recorded"
  @usage_known "usage_known"
  @safe_model_pattern "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}$"

  defmacrop known_usage(status, value) do
    quote do
      type(
        fragment(
          "CASE WHEN ? = ? THEN COALESCE(?, 0) ELSE 0 END",
          unquote(status),
          unquote(@usage_known),
          unquote(value)
        ),
        :integer
      )
    end
  end

  defmacrop settled_cost(status, details, value) do
    quote do
      type(
        fragment(
          "CASE WHEN ? = ? AND COALESCE(?->>'pricing_status', '') = 'priced' THEN ROUND(COALESCE(?, 0), 0)::bigint ELSE 0 END",
          unquote(status),
          unquote(@usage_known),
          unquote(details),
          unquote(value)
        ),
        :integer
      )
    end
  end

  defmacrop settled_cost_available(status, details) do
    quote do
      fragment(
        "CASE WHEN ? = ? AND COALESCE(?->>'pricing_status', '') = 'priced' THEN 1 ELSE 0 END",
        unquote(status),
        unquote(@usage_known),
        unquote(details)
      )
    end
  end

  defmacrop estimated_cost(status, details, value) do
    quote do
      type(
        fragment(
          "CASE WHEN NOT (? = ? AND COALESCE(?->>'pricing_status', '') = 'priced') AND COALESCE(?, 0) > 0 THEN ROUND(?, 0)::bigint ELSE 0 END",
          unquote(status),
          unquote(@usage_known),
          unquote(details),
          unquote(value),
          unquote(value)
        ),
        :integer
      )
    end
  end

  defmacrop estimated_cost_available(status, details, value) do
    quote do
      fragment(
        "CASE WHEN NOT (? = ? AND COALESCE(?->>'pricing_status', '') = 'priced') AND COALESCE(?, 0) > 0 THEN 1 ELSE 0 END",
        unquote(status),
        unquote(@usage_known),
        unquote(details),
        unquote(value)
      )
    end
  end

  defmacrop cost_unavailable(status, details, value) do
    quote do
      fragment(
        "CASE WHEN (? = ? AND COALESCE(?->>'pricing_status', '') = 'priced') OR (NOT (? = ? AND COALESCE(?->>'pricing_status', '') = 'priced') AND COALESCE(?, 0) > 0) THEN 0 ELSE 1 END",
        unquote(status),
        unquote(@usage_known),
        unquote(details),
        unquote(status),
        unquote(@usage_known),
        unquote(details),
        unquote(value)
      )
    end
  end

  defmacrop request_scope(request, pool_id, api_key_id, started_at, ended_at) do
    quote do
      unquote(request).pool_id == unquote(pool_id) and
        unquote(request).api_key_id == unquote(api_key_id) and
        unquote(request).admitted_at >= unquote(started_at) and
        unquote(request).admitted_at < unquote(ended_at)
    end
  end

  def scoped_facts(identity, window) do
    # Join the settlement per request through the unique
    # (request_id) WHERE settlement/recorded index. The request is already
    # scoped to this key/pool/window by `request_scope`, so pool_id, api_key_id,
    # and an occurred_at window on the settlement are redundant — and adding them
    # makes the planner fetch every settlement in the window and nested-loop
    # request_id across it (O(requests × settlements)), which times the read out
    # for high-volume keys. Matching only on request_id keeps it one indexed
    # lookup per request and also stops dropping the cost of requests that settle
    # just after the window closes.
    from request in Request,
      left_join: settlement in LedgerEntry,
      on:
        settlement.request_id == request.id and
          settlement.entry_kind == ^@settlement and settlement.amount_status == ^@recorded,
      left_join: fact in RequestLogFact,
      on: fact.request_id == request.id,
      left_join: model in Model,
      on: model.id == request.model_id and model.pool_id == request.pool_id,
      where:
        request_scope(
          request,
          ^identity.pool_id,
          ^identity.api_key_id,
          ^window.started_at,
          ^window.ended_at
        ),
      select: %{
        request_id: request.id,
        timestamp: request.admitted_at,
        bucket_index:
          type(
            fragment(
              "FLOOR(EXTRACT(EPOCH FROM (? - ?)) / ?)::integer",
              request.admitted_at,
              ^window.started_at,
              ^window.bucket_seconds
            ),
            :integer
          ),
        model_label:
          fragment(
            "CASE WHEN ? ~ ? THEN ? ELSE 'Unknown model' END",
            model.exposed_model_id,
            ^@safe_model_pattern,
            model.exposed_model_id
          ),
        endpoint_class:
          fragment(
            "CASE WHEN ? LIKE '%responses%' THEN 'responses' WHEN ? LIKE '%files%' THEN 'files' WHEN ? LIKE '%audio%' OR ? LIKE '%transcribe%' THEN 'audio' WHEN ? LIKE '%models%' THEN 'models' WHEN ? LIKE '%usage%' OR ? LIKE '%wham%' THEN 'usage' ELSE 'other' END",
            request.endpoint,
            request.endpoint,
            request.endpoint,
            request.endpoint,
            request.endpoint,
            request.endpoint,
            request.endpoint
          ),
        status: request.status,
        safe_code:
          fragment(
            "CASE WHEN ? IS NULL THEN NULL WHEN ? ~* '(rate|quota)' THEN 'rate_limited' WHEN ? ~* '(auth|unauthor|forbidden)' THEN 'authentication' WHEN ? ~* 'timeout' THEN 'timeout' WHEN ? ~* '(network|connect|upstream)' THEN 'service_unavailable' WHEN ? ~* '(schema|invalid)' THEN 'invalid_request' ELSE 'request_failed' END",
            request.last_error_code,
            request.last_error_code,
            request.last_error_code,
            request.last_error_code,
            request.last_error_code,
            request.last_error_code
          ),
        response_status_code: request.response_status_code,
        succeeded: fragment("CASE WHEN ? = 'succeeded' THEN 1 ELSE 0 END", request.status),
        failed:
          fragment(
            "CASE WHEN ? IN ('failed', 'rejected', 'cancelled') THEN 1 ELSE 0 END",
            request.status
          ),
        in_progress:
          fragment(
            "CASE WHEN ? IN ('accepted', 'in_progress') THEN 1 ELSE 0 END",
            request.status
          ),
        has_settlement: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", settlement.id),
        unknown_usage:
          fragment(
            "CASE WHEN ? IS NOT NULL AND ? <> ? THEN 1 ELSE 0 END",
            settlement.id,
            settlement.usage_status,
            ^@usage_known
          ),
        input_tokens: known_usage(settlement.usage_status, settlement.input_tokens),
        cached_input_tokens: known_usage(settlement.usage_status, settlement.cached_input_tokens),
        output_tokens: known_usage(settlement.usage_status, settlement.output_tokens),
        reasoning_tokens: known_usage(settlement.usage_status, settlement.reasoning_tokens),
        total_tokens: known_usage(settlement.usage_status, settlement.total_tokens),
        settled_cost_micros:
          settled_cost(
            settlement.usage_status,
            settlement.details,
            settlement.settled_cost_micros
          ),
        settled_cost_available:
          settled_cost_available(settlement.usage_status, settlement.details),
        estimated_cost_micros:
          estimated_cost(
            settlement.usage_status,
            settlement.details,
            settlement.estimated_cost_micros
          ),
        estimated_cost_available:
          estimated_cost_available(
            settlement.usage_status,
            settlement.details,
            settlement.estimated_cost_micros
          ),
        cost_unavailable:
          cost_unavailable(
            settlement.usage_status,
            settlement.details,
            settlement.estimated_cost_micros
          ),
        latency_ms: fact.latest_latency_ms,
        throughput_tokens_per_second:
          type(
            fragment(
              "CASE WHEN ? = ? AND COALESCE(?, 0) > 0 AND COALESCE(?, 0) > 0 THEN (COALESCE(?, 0)::double precision * 1000.0) / ? ELSE NULL END",
              settlement.usage_status,
              ^@usage_known,
              settlement.total_tokens,
              fact.latest_latency_ms,
              settlement.total_tokens,
              fact.latest_latency_ms
            ),
            :float
          )
      }
  end
end
