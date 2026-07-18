defmodule CodexPooler.Accounting.Usage.Observatory.Queries do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.Usage.Observatory.QueryScope
  alias CodexPooler.Repo

  def summary(identity, window) do
    identity
    |> QueryScope.scoped_facts(window)
    |> then(fn facts ->
      Repo.one(
        from(fact in subquery(facts),
          select: %{
            request_count: count(fact.request_id),
            succeeded: sum(fact.succeeded),
            failed: sum(fact.failed),
            in_progress: sum(fact.in_progress),
            settlement_count: sum(fact.has_settlement),
            unknown_usage_count: sum(fact.unknown_usage),
            input_tokens: sum(fact.input_tokens),
            cached_input_tokens: sum(fact.cached_input_tokens),
            output_tokens: sum(fact.output_tokens),
            reasoning_tokens: sum(fact.reasoning_tokens),
            total_tokens: sum(fact.total_tokens),
            settled_cost_micros: sum(fact.settled_cost_micros),
            settled_cost_count: sum(fact.settled_cost_available),
            estimated_cost_micros: sum(fact.estimated_cost_micros),
            estimated_cost_count: sum(fact.estimated_cost_available),
            unavailable_cost_count: sum(fact.cost_unavailable)
          }
        ),
        telemetry_options: [reporting_projection: :observatory_summary]
      )
    end)
  end

  def buckets(identity, window) do
    identity
    |> QueryScope.scoped_facts(window)
    |> then(fn facts ->
      Repo.all(
        from(fact in subquery(facts),
          group_by: fact.bucket_index,
          order_by: fact.bucket_index,
          select: %{
            bucket_index: fact.bucket_index,
            request_count: count(fact.request_id),
            succeeded: sum(fact.succeeded),
            failed: sum(fact.failed),
            in_progress: sum(fact.in_progress),
            input_tokens: sum(fact.input_tokens),
            cached_input_tokens: sum(fact.cached_input_tokens),
            output_tokens: sum(fact.output_tokens),
            reasoning_tokens: sum(fact.reasoning_tokens),
            total_tokens: sum(fact.total_tokens),
            settled_cost_micros: sum(fact.settled_cost_micros),
            settled_cost_count: sum(fact.settled_cost_available),
            estimated_cost_micros: sum(fact.estimated_cost_micros),
            estimated_cost_count: sum(fact.estimated_cost_available),
            unavailable_cost_count: sum(fact.cost_unavailable)
          }
        ),
        telemetry_options: [reporting_projection: :observatory_buckets]
      )
    end)
  end

  def models(identity, window) do
    identity
    |> QueryScope.scoped_facts(window)
    |> then(fn facts ->
      Repo.all(
        from(fact in subquery(facts),
          group_by: fact.model_label,
          order_by: [
            desc: sum(fact.total_tokens),
            desc: count(fact.request_id),
            asc: fact.model_label
          ],
          limit: 12,
          select: %{
            label: fact.model_label,
            request_count: count(fact.request_id),
            total_tokens: sum(fact.total_tokens),
            settled_cost_micros: sum(fact.settled_cost_micros),
            estimated_cost_micros: sum(fact.estimated_cost_micros)
          }
        ),
        telemetry_options: [reporting_projection: :observatory_models]
      )
    end)
  end

  def model_buckets(identity, window) do
    identity
    |> QueryScope.scoped_facts(window)
    |> then(fn facts ->
      Repo.all(
        from(fact in subquery(facts),
          group_by: [fact.bucket_index, fact.model_label],
          order_by: [fact.bucket_index, fact.model_label],
          select: %{
            bucket_index: fact.bucket_index,
            model_label: fact.model_label,
            total_tokens: sum(fact.total_tokens)
          }
        ),
        telemetry_options: [reporting_projection: :observatory_model_buckets]
      )
    end)
  end

  def outcomes(identity, window) do
    identity
    |> QueryScope.scoped_facts(window)
    |> then(fn facts ->
      Repo.all(
        from(fact in subquery(facts),
          order_by: [desc: fact.timestamp, desc: fact.request_id],
          limit: 12,
          select: %{
            timestamp: fact.timestamp,
            model: fact.model_label,
            endpoint_class: fact.endpoint_class,
            status: fact.status,
            code: fact.safe_code,
            response_status_code: fact.response_status_code,
            total_tokens: fact.total_tokens,
            settled_cost_micros: fact.settled_cost_micros,
            settled_cost_available: fact.settled_cost_available,
            estimated_cost_micros: fact.estimated_cost_micros,
            estimated_cost_available: fact.estimated_cost_available
          }
        ),
        telemetry_options: [reporting_projection: :observatory_outcomes]
      )
    end)
  end
end
