defmodule CodexPooler.Accounting.Usage.Observatory.QueryScope do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Request, RequestLogFact}
  alias CodexPooler.Catalog.Model

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

  defmacrop settled_cost(status, pricing_status, value) do
    quote do
      type(
        fragment(
          "CASE WHEN ? = ? AND COALESCE(?, '') = 'priced' THEN ROUND(COALESCE(?, 0), 0)::bigint ELSE 0 END",
          unquote(status),
          unquote(@usage_known),
          unquote(pricing_status),
          unquote(value)
        ),
        :integer
      )
    end
  end

  defmacrop settled_cost_available(status, pricing_status) do
    quote do
      fragment(
        "CASE WHEN ? = ? AND COALESCE(?, '') = 'priced' THEN 1 ELSE 0 END",
        unquote(status),
        unquote(@usage_known),
        unquote(pricing_status)
      )
    end
  end

  defmacrop estimated_cost(status, pricing_status, value) do
    quote do
      type(
        fragment(
          "CASE WHEN NOT (? = ? AND COALESCE(?, '') = 'priced') AND COALESCE(?, 0) > 0 THEN ROUND(?, 0)::bigint ELSE 0 END",
          unquote(status),
          unquote(@usage_known),
          unquote(pricing_status),
          unquote(value),
          unquote(value)
        ),
        :integer
      )
    end
  end

  defmacrop estimated_cost_available(status, pricing_status, value) do
    quote do
      fragment(
        "CASE WHEN NOT (? = ? AND COALESCE(?, '') = 'priced') AND COALESCE(?, 0) > 0 THEN 1 ELSE 0 END",
        unquote(status),
        unquote(@usage_known),
        unquote(pricing_status),
        unquote(value)
      )
    end
  end

  defmacrop cost_unavailable(status, pricing_status, value) do
    quote do
      fragment(
        "CASE WHEN (? = ? AND COALESCE(?, '') = 'priced') OR (NOT (? = ? AND COALESCE(?, '') = 'priced') AND COALESCE(?, 0) > 0) THEN 0 ELSE 1 END",
        unquote(status),
        unquote(@usage_known),
        unquote(pricing_status),
        unquote(status),
        unquote(@usage_known),
        unquote(pricing_status),
        unquote(value)
      )
    end
  end

  defmacrop bucket_index(admitted_at, started_at, bucket_seconds) do
    quote do
      type(
        fragment(
          "FLOOR(EXTRACT(EPOCH FROM (? - ?)) / ?)::integer",
          unquote(admitted_at),
          unquote(started_at),
          unquote(bucket_seconds)
        ),
        :integer
      )
    end
  end

  defmacrop model_label(exposed_model_id) do
    quote do
      fragment(
        "CASE WHEN ? ~ ? THEN ? ELSE 'Unknown model' END",
        unquote(exposed_model_id),
        unquote(@safe_model_pattern),
        unquote(exposed_model_id)
      )
    end
  end

  defmacrop endpoint_class(endpoint) do
    quote do
      fragment(
        "CASE WHEN ? LIKE '%responses%' THEN 'responses' WHEN ? LIKE '%files%' THEN 'files' WHEN ? LIKE '%audio%' OR ? LIKE '%transcribe%' THEN 'audio' WHEN ? LIKE '%models%' THEN 'models' WHEN ? LIKE '%usage%' OR ? LIKE '%wham%' THEN 'usage' ELSE 'other' END",
        unquote(endpoint),
        unquote(endpoint),
        unquote(endpoint),
        unquote(endpoint),
        unquote(endpoint),
        unquote(endpoint),
        unquote(endpoint)
      )
    end
  end

  defmacrop safe_code(last_error_code) do
    quote do
      fragment(
        "CASE WHEN ? IS NULL THEN NULL WHEN ? ~* '(rate|quota)' THEN 'rate_limited' WHEN ? ~* '(auth|unauthor|forbidden)' THEN 'authentication' WHEN ? ~* 'timeout' THEN 'timeout' WHEN ? ~* '(network|connect|upstream)' THEN 'service_unavailable' WHEN ? ~* '(schema|invalid)' THEN 'invalid_request' ELSE 'request_failed' END",
        unquote(last_error_code),
        unquote(last_error_code),
        unquote(last_error_code),
        unquote(last_error_code),
        unquote(last_error_code),
        unquote(last_error_code)
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

  @doc """
  Aggregation-facing rows for the scoped key/pool/window.

  Tokens and cost read from the request's denormalized fact
  (`request_log_facts`) typed columns, so the aggregate queries never join
  `ledger_entries` or dig through settlement JSONB. The fact is a 1:1 projection
  keyed by `request_id`, so the join is one primary-key lookup per scoped
  request. Token/settled reads stay gated on `latest_settlement_usage_status`
  (backfilled facts store raw usage columns, live facts store them pre-gated, so
  the SQL gate keeps both identical to the old ledger read); estimated cost is
  stored ungated and gated here to non-priced rows.
  """
  def scoped_facts(identity, window) do
    from request in Request,
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
        bucket_index:
          bucket_index(request.admitted_at, ^window.started_at, ^window.bucket_seconds),
        model_label: model_label(model.exposed_model_id),
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
        has_settlement:
          fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", fact.latest_settlement_entry_id),
        unknown_usage:
          fragment(
            "CASE WHEN ? IS NOT NULL AND ? <> ? THEN 1 ELSE 0 END",
            fact.latest_settlement_entry_id,
            fact.latest_settlement_usage_status,
            ^@usage_known
          ),
        input_tokens: known_usage(fact.latest_settlement_usage_status, fact.latest_input_tokens),
        cached_input_tokens:
          known_usage(fact.latest_settlement_usage_status, fact.latest_cached_input_tokens),
        output_tokens:
          known_usage(fact.latest_settlement_usage_status, fact.latest_output_tokens),
        reasoning_tokens:
          known_usage(fact.latest_settlement_usage_status, fact.latest_reasoning_tokens),
        total_tokens: known_usage(fact.latest_settlement_usage_status, fact.latest_total_tokens),
        settled_cost_micros:
          settled_cost(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_settled_cost_micros
          ),
        settled_cost_available:
          settled_cost_available(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status
          ),
        estimated_cost_micros:
          estimated_cost(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_estimated_cost_micros
          ),
        estimated_cost_available:
          estimated_cost_available(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_estimated_cost_micros
          ),
        cost_unavailable:
          cost_unavailable(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_estimated_cost_micros
          )
      }
  end

  @doc """
  The twelve most recent scoped outcomes.

  This is a dedicated query rather than a slice of `scoped_facts/2` so the
  endpoint/error-code regex classification runs over only the twelve rows the
  limit keeps, not the whole window. `requests_api_key_pool_admitted_id_idx`
  yields the scoped rows in the requested deterministic order, so the limit
  stops early and the fact/model joins are twelve primary-key lookups.
  """
  def recent_outcomes(identity, window) do
    from request in Request,
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
      order_by: [desc: request.admitted_at, desc: request.id],
      limit: 12,
      select: %{
        timestamp: request.admitted_at,
        model: model_label(model.exposed_model_id),
        endpoint_class: endpoint_class(request.endpoint),
        status: request.status,
        code: safe_code(request.last_error_code),
        response_status_code: request.response_status_code,
        total_tokens: known_usage(fact.latest_settlement_usage_status, fact.latest_total_tokens),
        settled_cost_micros:
          settled_cost(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_settled_cost_micros
          ),
        settled_cost_available:
          settled_cost_available(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status
          ),
        estimated_cost_micros:
          estimated_cost(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_estimated_cost_micros
          ),
        estimated_cost_available:
          estimated_cost_available(
            fact.latest_settlement_usage_status,
            fact.latest_settlement_pricing_status,
            fact.latest_estimated_cost_micros
          )
      }
  end
end
