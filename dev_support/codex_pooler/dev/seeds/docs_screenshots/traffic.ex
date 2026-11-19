defmodule CodexPooler.Dev.Seeds.DocsScreenshots.Traffic do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogFact, RequestLogFacts}
  alias CodexPooler.Repo

  @clients [
    {"codex_cli_rs/0.1.0", "websocket", nil},
    {"opencode/2.0.0", "http_sse", "/v1/responses"},
    {"hermes-cli/1.0.0", "http_sse", "/v1/chat/completions"},
    {"omp/1.0.0", "http_sse", "/v1/responses"},
    {"OpenAI/Python 1.0.0", "http_sse", "/v1/responses"},
    {"goose/1.0.0", "http_sse", "/v1/chat/completions"}
  ]
  @cache_hit_rates [9580, 9730, 9860, 9920, 9670, 9810, 9950]
  # The synthetic mix uses Astra for Ultrafast examples. Tiers are dealt per
  # model in recency order so the first rows show normal, Fast and Ultrafast.
  @ultrafast_model "gpt-6.2-astra"
  @ultrafast_cycle ["ultrafast", "default", "priority", "default"]
  @priority_cycle ["default", "priority", "default", "default"]
  @tier_cost_multipliers %{"default" => 1, "priority" => 2, "ultrafast" => 6}
  @demand_profiles [
    {4, [{8.0, 3.4, 13}, {18.0, 3.1, 8}]},
    {3, [{11.0, 4.4, 15}, {20.0, 2.8, 5}]},
    {4, [{7.0, 3.8, 9}, {16.0, 4.0, 10}]},
    {3, [{6.0, 2.6, 7}, {16.0, 4.2, 16}]},
    {4, [{12.0, 5.2, 18}]},
    {2, [{8.0, 3.1, 5}, {18.0, 3.7, 8}]}
  ]

  @spec seed!(map()) :: [Request.t()]
  def seed!(result) do
    timestamp = DateTime.utc_now()

    rows =
      result.pools
      |> Enum.with_index()
      |> Enum.flat_map(fn {pool, index} -> pool_rows(result, pool, index, timestamp) end)
      # Clients rotate by recency rank, newest first, so any six consecutive
      # request-log rows show every client. Rotating by Pool and sequence let the
      # current-hour cap reorder the newest rows during an hour's first seconds,
      # which pushed the websocket client off the first page.
      |> Enum.sort_by(&started_at/1, {:desc, DateTime})
      |> then(&Enum.zip(&1, service_tiers(&1)))
      |> Enum.with_index(fn {spec, tier}, rank -> traffic_row(spec, Enum.at(@clients, rem(rank, length(@clients))), tier) end)

    insert_rows!(rows)

    pool_ids = Enum.map(result.pools, & &1.id)
    identities = Map.new(result.upstream_identities, &{&1.id, &1})
    refresh_legacy_projections!(pool_ids, identities)
    Repo.all(from request in Request, where: request.pool_id in ^pool_ids)
  end

  @doc false
  def insert_rows!(rows) do
    Repo.insert_all(Request, Enum.map(rows, & &1.request))
    Repo.insert_all(Attempt, Enum.map(rows, & &1.attempt))
    Repo.insert_all(LedgerEntry, Enum.map(rows, & &1.entry))
    Repo.insert_all(RequestLogFact, Enum.map(rows, & &1.fact))
    :ok
  end

  @doc false
  def clients, do: @clients

  @doc "The service tier dealt to the `ordinal`-th request of a model, in the cycle the request-log speed mix uses."
  @spec service_tier(String.t(), non_neg_integer()) :: String.t()
  def service_tier(exposed_model_id, ordinal) do
    cycle = if exposed_model_id == @ultrafast_model, do: @ultrafast_cycle, else: @priority_cycle
    Enum.at(cycle, rem(ordinal, length(cycle)))
  end

  defp pool_rows(result, pool, index, timestamp) do
    assignments = Enum.filter(result.assignments, &(&1.pool_id == pool.id and &1.status == "active" and &1.health_status == "active"))
    models = result.models |> Enum.filter(&(&1.pool_id == pool.id and &1.status == "active")) |> Enum.sort_by(& &1.exposed_model_id)
    key = Enum.find(result.api_keys, &(&1.pool_id == pool.id and &1.status == "active"))

    for hour <- 23..0//-1,
        sequence <- 1..round(traffic_shape(index, hour)),
        occurred_at = occurred_at(timestamp, hour, sequence),
        pool.status != "disabled" or hour >= 2 do
      assignment = Enum.at(assignments, rem(hour + sequence, length(assignments)))
      identity = Enum.find(result.upstream_identities, &(&1.id == assignment.upstream_identity_id))
      model = Enum.at(models, rem(index + hour + sequence, length(models)))
      {pool, key, model, assignment, identity, {index, hour, sequence, occurred_at}}
    end
  end

  defp occurred_at(timestamp, 0, sequence), do: DateTime.add(timestamp, -min(timestamp.minute * 60 + timestamp.second, sequence * 5), :second)

  defp occurred_at(timestamp, hour, sequence) do
    timestamp |> DateTime.add(-timestamp.minute * 60 - timestamp.second, :second) |> DateTime.add(-hour * 3600 + 900 + sequence * 40, :second)
  end

  defp started_at({_pool, _key, _model, _assignment, _identity, {index, hour, sequence, occurred_at}}),
    do: DateTime.add(occurred_at, -latency_ms(index, output_tokens(index, hour, sequence)), :millisecond)

  @doc false
  def output_tokens(index, hour, sequence), do: 600 + rem(hour * 61 + index * 181 + sequence * 79, 1600)

  @doc false
  def latency_ms(index, output), do: 4500 + div(output * 1000, 65 + index * 5)

  defp service_tiers(specs) do
    {tiers, _seen} =
      Enum.map_reduce(specs, %{}, fn {_pool, _key, model, _assignment, _identity, _slot}, seen ->
        ordinal = Map.get(seen, model.exposed_model_id, 0)
        {service_tier(model.exposed_model_id, ordinal), Map.put(seen, model.exposed_model_id, ordinal + 1)}
      end)

    tiers
  end

  @doc false
  def traffic_row({pool, key, model, assignment, identity, {index, hour, sequence, occurred_at}}, {user_agent, transport, source_endpoint}, service_tier) do
    request_id = Ecto.UUID.generate()
    attempt_id = Ecto.UUID.generate()
    shape = traffic_shape(index, hour)
    input = round(40_000 + index * 8000 + shape * 650 + 2200 * :math.sin(sequence * 1.7 + hour * 0.4))
    output = output_tokens(index, hour, sequence)
    cached = div(input * Enum.at(@cache_hit_rates, rem(hour + index + sequence, length(@cache_hit_rates))), 10_000)
    total = input + output
    cost = Decimal.new(((input - cached) * 2 + cached + output * 8) * Map.fetch!(@tier_cost_multipliers, service_tier))
    latency = latency_ms(index, output)
    started_at = DateTime.add(occurred_at, -latency, :millisecond)
    metadata = %{"dev_seed" => "codex_pooler_dev_seed", "docs_screenshot" => true}

    request_metadata =
      if source_endpoint do
        Map.put(metadata, "openai_compatibility", %{"surface" => "openai_v1", "source_endpoint" => source_endpoint, "translated_endpoint" => "/backend-api/codex/responses"})
      else
        metadata
      end

    request = %{
      id: request_id,
      pool_id: pool.id,
      api_key_id: key.id,
      model_id: model.id,
      requested_model: model.exposed_model_id,
      endpoint: "/backend-api/codex/responses",
      transport: transport,
      status: "succeeded",
      usage_status: "usage_known",
      correlation_id: "docs-#{pool.slug}-#{hour}-#{sequence}",
      user_agent: user_agent,
      request_metadata: request_metadata,
      admitted_at: started_at,
      completed_at: occurred_at,
      response_status_code: 200,
      retry_count: 0,
      upstream_account_label: identity.account_label,
      upstream_account_plan_family: identity.plan_family,
      upstream_account_plan_label: identity.plan_label,
      reasoning_effort: Enum.at(["medium", "high", "xhigh"], rem(hour + index, 3)),
      service_tier: service_tier,
      requested_service_tier: if(service_tier == "default", do: "auto", else: service_tier),
      actual_service_tier: service_tier
    }

    attempt = %{
      id: attempt_id,
      request_id: request_id,
      attempt_number: 1,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      model_id: model.id,
      upstream_model_id: model.upstream_model_id,
      transport: transport,
      status: "succeeded",
      started_at: started_at,
      completed_at: occurred_at,
      upstream_status_code: 200,
      retryable: false,
      latency_ms: latency,
      usage_status: "usage_known",
      response_metadata: metadata
    }

    entry = %{
      id: Ecto.UUID.generate(),
      request_id: request_id,
      attempt_id: attempt_id,
      pool_id: pool.id,
      api_key_id: key.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      model_id: model.id,
      entry_kind: "settlement",
      amount_status: "recorded",
      usage_status: "usage_known",
      transport: transport,
      currency_code: "USD",
      input_tokens: input,
      cached_input_tokens: cached,
      output_tokens: output,
      reasoning_tokens: div(output, 3),
      total_tokens: total,
      request_count: 1,
      estimated_cost_micros: cost,
      settled_cost_micros: cost,
      occurred_at: occurred_at,
      created_at: occurred_at,
      details: Map.merge(metadata, %{"pricing_status" => "priced", "settled_cost_micros" => Decimal.to_string(cost, :normal)})
    }

    # Batch the synthetic projection with its source rows. Tests exercise the real
    # request-log and chart readers, so a projection-contract change cannot hide.
    fact = %{
      request_id: request_id,
      latest_attempt_id: attempt_id,
      latest_attempt_number: 1,
      latest_attempt_status: "succeeded",
      latest_attempt_retryable: false,
      latest_upstream_status_code: 200,
      latest_pool_upstream_assignment_id: assignment.id,
      latest_upstream_identity_id: identity.id,
      latest_latency_ms: latency,
      latest_settlement_entry_id: entry.id,
      latest_settlement_usage_status: "usage_known",
      latest_settlement_pricing_status: "priced",
      latest_input_tokens: input,
      latest_cached_input_tokens: cached,
      latest_output_tokens: output,
      latest_reasoning_tokens: entry.reasoning_tokens,
      latest_total_tokens: total,
      latest_settled_cost_micros: Decimal.to_integer(cost),
      latest_estimated_cost_micros: Decimal.to_integer(cost),
      latest_settlement_occurred_at: occurred_at,
      latest_settlement_created_at: occurred_at,
      inserted_at: occurred_at,
      updated_at: occurred_at
    }

    %{request: request, attempt: attempt, entry: entry, fact: fact}
  end

  @doc false
  def traffic_shape(index, hour) do
    {baseline, peaks} = Enum.at(@demand_profiles, index)
    position = 23 - hour

    demand =
      Enum.reduce(peaks, baseline, fn {center, width, height}, total ->
        total + height * :math.exp(-:math.pow((position - center) / width, 2) / 2)
      end)

    # Low-amplitude variation keeps each workload organic without introducing
    # the alternating hourly spikes of a modulo-based request count.
    demand * (1 + 0.035 * :math.sin(position * 1.3 + index))
  end

  defp refresh_legacy_projections!(pool_ids, identities) do
    requests = Repo.all(from request in Request, where: request.pool_id in ^pool_ids and fragment("COALESCE(?->>'docs_screenshot', 'false') != 'true'", request.request_metadata))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from attempt in Attempt, where: attempt.request_id in ^request_ids)
    assignments_by_request = Map.new(attempts, &{&1.request_id, &1.upstream_identity_id})

    requests =
      Enum.map(requests, fn request ->
        identity = identities[assignments_by_request[request.id]]
        request = request |> Ecto.Changeset.change(upstream_account_label: identity.account_label) |> Repo.update!()
        :ok = RequestLogFacts.record_request_created!(request)
        request
      end)

    Enum.each(attempts, &RequestLogFacts.record_attempt_written!/1)

    Repo.all(from entry in LedgerEntry, where: entry.request_id in ^request_ids and entry.entry_kind == "settlement")
    |> Enum.each(&record_settlement!/1)

    requests
  end

  defp record_settlement!(entry) do
    output =
      cond do
        entry.input_tokens + entry.output_tokens == entry.total_tokens -> entry.output_tokens
        entry.input_tokens + entry.output_tokens + entry.reasoning_tokens == entry.total_tokens -> entry.output_tokens + entry.reasoning_tokens
        true -> raise "synthetic screenshot settlement has inconsistent token totals"
      end

    details = Map.put(entry.details || %{}, "settled_cost_micros", Decimal.to_string(entry.settled_cost_micros, :normal))
    entry = entry |> Ecto.Changeset.change(output_tokens: output, details: details) |> Repo.update!()
    :ok = RequestLogFacts.record_settlement_written!(entry)
  end
end
