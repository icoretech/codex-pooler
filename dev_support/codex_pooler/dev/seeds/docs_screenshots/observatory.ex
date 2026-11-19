defmodule CodexPooler.Dev.Seeds.DocsScreenshots.Observatory do
  @moduledoc false

  # "Build automation" is the key the Observatory documentation images sign in with. It gets a known synthetic secret (only
  # its hash is stored) and a week of traffic, so the 7d window shows a weekday rhythm, a weekend dip, a success rate in the
  # Good tier and a few client cancellations.
  #
  # The history is older than 25 hours, so every 24-hour view keeps its numbers, and every row is detached from the
  # upstream accounts (see `detach/1`), so the account pages keep theirs too. The handful of rows near the present are
  # placed in the gap between the key's newest requests (the generated traffic) and its older ones (the full seed's own
  # rows), behind a dozen newer requests of every Pool, so the first page of the request log is unchanged and the key's
  # recent outcomes show every case the Observatory documents: speed tiers, effort, cached input, a failure and a run of
  # requests without a model. The result lists every request of the Pools again, the ones added here included.

  import Ecto.Query

  alias CodexPooler.Access.APIKeys.Material
  alias CodexPooler.Accounting.{Attempt, Request, RequestLogFacts}
  alias CodexPooler.Dev.Seeds.DocsScreenshots.Traffic
  alias CodexPooler.Repo

  @seed_key "codex_pooler_dev_seed"
  @key_prefix "sk-cxp-docs00000001"
  @secret "docs-observatory-sample-secret"
  @weekend_factor 0.45
  @model_mix ~w(gpt-6-luna gpt-6-luna gpt-6-luna gpt-6-luna gpt-6-luna gpt-6.2-sol gpt-6.2-sol gpt-6.2-sol gpt-6.2-astra gpt-6.2-astra)

  # {status, response status, error code, attempt network error code}; the roll picks one per failed request.
  @failures [
    {"failed", 429, "quota_exhausted", "quota_limit"},
    {"failed", 429, "quota_exhausted", "quota_limit"},
    {"failed", 429, "quota_exhausted", "quota_limit"},
    {"failed", 429, "quota_exhausted", "quota_limit"},
    {"failed", 429, "quota_exhausted", "quota_limit"},
    {"failed", 502, "upstream_unavailable", "upstream_unavailable"},
    {"failed", 502, "upstream_unavailable", "upstream_unavailable"},
    {"failed", 504, "upstream_timeout", "timeout"},
    {"failed", 504, "upstream_timeout", "timeout"},
    {"rejected", 400, "invalid_request", nil}
  ]
  @cancellation {"failed", 499, "client_disconnected", "client_disconnected"}

  @doc "The raw key that signs in to the Observatory as the seeded key. Synthetic and meaningful only in the screenshot database."
  @spec raw_key() :: String.t()
  def raw_key, do: "#{@key_prefix}-#{@secret}"

  @spec apply!(map()) :: map()
  def apply!(result) do
    now = DateTime.utc_now()
    pool = Enum.find(result.pools, &(&1.name == "Example Production")) || raise "documentation screenshot seed is missing Example Production"
    key = Enum.find(result.api_keys, &(&1.key_prefix == @key_prefix)) || raise "documentation screenshot seed is missing #{@key_prefix}"

    context = %{
      pool: pool,
      index: Enum.find_index(result.pools, &(&1.id == pool.id)),
      key: key,
      models: result.models |> Enum.filter(&(&1.pool_id == pool.id and &1.status == "active")) |> Enum.sort_by(& &1.exposed_model_id),
      assignments: Enum.filter(result.assignments, &(&1.pool_id == pool.id and &1.status == "active" and &1.health_status == "active")),
      identities: Map.new(result.upstream_identities, &{&1.id, &1})
    }

    key |> Ecto.Changeset.change(key_hash: Material.hash_secret(@secret)) |> Repo.update!()
    history!(context, now)
    recent!(context, now)

    pool_ids = Enum.map(result.pools, & &1.id)
    %{result | request_logs: Repo.all(from(r in Request, where: r.pool_id in ^pool_ids))}
  end

  # --- A week of history, oldest first ----------------------------------------------------------------------------

  defp history!(context, now) do
    hour_start = %{now | minute: 0, second: 0, microsecond: {0, 6}}

    specs =
      for hours_ago <- 167..25//-1, sequence <- 1..history_count(context, hour_start, hours_ago) do
        {hours_ago, sequence, DateTime.add(hour_start, -hours_ago * 3600 + 900 + sequence * 40, :second)}
      end

    {rows, _ordinals} =
      Enum.map_reduce(specs, %{}, fn {hours_ago, sequence, admitted_at}, ordinals ->
        model = history_model(context, hours_ago, sequence)
        ordinal = Map.get(ordinals, model.exposed_model_id, 0)
        row = priced_row(context, model, {hours_ago, sequence}, admitted_at, Traffic.service_tier(model.exposed_model_id, ordinal), :erlang.phash2({hours_ago, sequence}, length(Traffic.clients())))
        {outcome(row, history_roll(hours_ago, sequence)), Map.put(ordinals, model.exposed_model_id, ordinal + 1)}
      end)

    {priced, failed} = Enum.split_with(rows, &(&1.kind == :priced))
    Traffic.insert_rows!(Enum.map(priced, & &1.row))
    Enum.each(failed, &insert_failure!/1)
  end

  # The Production profile of the generated traffic, repeated for each earlier day with a quieter weekend.
  defp history_count(context, hour_start, hours_ago) do
    weekday = hour_start |> DateTime.add(-hours_ago * 3600) |> DateTime.to_date() |> Date.day_of_week()
    factor = if weekday in [6, 7], do: @weekend_factor, else: 1.0
    wobble = 1 + 0.06 * :math.sin(hours_ago * 2.3)
    max(round(Traffic.traffic_shape(context.index, rem(hours_ago, 24)) * factor * wobble), 1)
  end

  defp history_model(context, hours_ago, sequence) do
    exposed = Enum.at(@model_mix, :erlang.phash2({hours_ago, sequence, :model}, length(@model_mix)))
    Enum.find(context.models, &(&1.exposed_model_id == exposed)) || Enum.at(context.models, rem(hours_ago + sequence, length(context.models)))
  end

  # About three requests in a hundred fail and a few in a thousand are cancelled by the client.
  defp history_roll(hours_ago, sequence) do
    case :erlang.phash2({hours_ago, sequence, :outcome}, 1000) do
      roll when roll < 30 -> {:failure, Enum.at(@failures, :erlang.phash2({hours_ago, sequence, :kind}, length(@failures)))}
      roll when roll < 34 -> {:failure, @cancellation}
      _roll -> :succeeded
    end
  end

  defp outcome(row, :succeeded), do: %{kind: :priced, row: row}
  defp outcome(row, {:failure, failure}), do: %{kind: :failure, row: row, failure: failure}

  # A generated request of the key, admitted at the given instant (the generated traffic is keyed by its completion).
  defp priced_row(context, model, {hour_key, sequence}, admitted_at, tier, client_slot) do
    assignment = Enum.at(context.assignments, rem(hour_key + sequence, length(context.assignments)))
    identity = Map.fetch!(context.identities, assignment.upstream_identity_id)
    hour = rem(hour_key, 24)
    latency = Traffic.latency_ms(context.index, Traffic.output_tokens(context.index, hour, sequence))
    occurred_at = DateTime.add(admitted_at, latency, :millisecond)
    row = Traffic.traffic_row({context.pool, context.key, model, assignment, identity, {context.index, hour, sequence, occurred_at}}, Enum.at(Traffic.clients(), client_slot), tier)
    row |> detach() |> then(&put_in(&1.request.correlation_id, "docs-obs-#{hour_key}-#{sequence}"))
  end

  # These rows keep the account label of the request log but name no assignment and no upstream identity, like traffic whose
  # account was removed later. The account pages (routing lanes, request health, seven-day counts, token burn) then keep
  # counting only the generated traffic, and only the Observatory and the Pool's own totals see these requests.
  defp detach(row) do
    row
    |> put_in([:attempt, :pool_upstream_assignment_id], nil)
    |> put_in([:attempt, :upstream_identity_id], nil)
    |> put_in([:entry, :pool_upstream_assignment_id], nil)
    |> put_in([:entry, :upstream_identity_id], nil)
    |> put_in([:fact, :latest_pool_upstream_assignment_id], nil)
    |> put_in([:fact, :latest_upstream_identity_id], nil)
  end

  # A request that failed or was rejected keeps its model and carries no usage: an upstream failure has one failed
  # attempt, a rejection is answered before any attempt exists.
  defp insert_failure!(%{row: %{request: request, attempt: attempt}, failure: {status, response_status, error_code, network_error_code}}) do
    usage_status = if status == "rejected", do: "not_applicable", else: "usage_unknown"
    request = Repo.insert!(struct!(Request, Map.merge(request, %{status: status, usage_status: usage_status, response_status_code: response_status, last_error_code: error_code})))
    :ok = RequestLogFacts.record_request_created!(request)

    if status != "rejected" do
      attempt = Repo.insert!(struct!(Attempt, Map.merge(attempt, %{status: "failed", upstream_status_code: response_status, retryable: false, network_error_code: network_error_code, usage_status: "usage_unknown"})))
      :ok = RequestLogFacts.record_attempt_written!(attempt)
    end

    :ok
  end

  # --- The key's newest requests ------------------------------------------------------------------------------------

  # Newest first: a priority request, five requests that name no model (a client listing models), an ultrafast request,
  # a second priority request and a request that ran into the usage limit.
  defp recent!(context, now) do
    times = gap(context, now, 8)
    models = Map.new(context.models, &{&1.exposed_model_id, &1})
    model = &Map.fetch!(models, &1)

    [priority_a, listing_1, listing_2, listing_3, listing_4, ultrafast, priority_b, limited] = times

    priced!(context, model.("gpt-6.2-sol"), 1, priority_a, "priority", "high")
    Enum.each([listing_1, listing_2, listing_3, listing_4], &listing!(context, &1))
    priced!(context, model.("gpt-6.2-astra"), 2, ultrafast, "ultrafast", "xhigh")
    priced!(context, model.("gpt-6-luna"), 3, priority_b, "priority", "medium")
    limited!(context, model.("gpt-6-luna"), 4, limited)
  end

  defp priced!(context, model, slot, admitted_at, tier, effort) do
    row = priced_row(context, model, {1_000 + slot, slot}, admitted_at, tier, slot)
    Traffic.insert_rows!([put_in(row.request.reasoning_effort, effort)])
  end

  defp limited!(context, model, slot, admitted_at) do
    row = priced_row(context, model, {1_000 + slot, slot}, admitted_at, "default", 0)
    insert_failure!(%{row: put_in(row.request.reasoning_effort, "high"), failure: Enum.at(@failures, 0)})
  end

  defp listing!(context, admitted_at) do
    request =
      Repo.insert!(%Request{
        pool_id: context.pool.id,
        api_key_id: context.key.id,
        requested_model: "/v1/models",
        endpoint: "/v1/models",
        transport: "http_json",
        status: "succeeded",
        usage_status: "not_applicable",
        correlation_id: "docs-obs-models-#{DateTime.to_unix(admitted_at, :microsecond)}",
        user_agent: "hermes-cli/1.0.0",
        request_metadata: %{"dev_seed" => @seed_key, "docs_screenshot" => true},
        admitted_at: admitted_at,
        completed_at: DateTime.add(admitted_at, 40, :millisecond),
        response_status_code: 200,
        retry_count: 0
      })

    :ok = RequestLogFacts.record_request_created!(request)
  end

  # `count` instants, newest first, between the oldest request of the generated traffic's current hour and the newest of
  # the full seed's own rows. That gap is a few seconds wide at least, and every Pool has a dozen requests newer than it,
  # so the first request-log page is untouched.
  defp gap(context, now, count) do
    key_id = context.key.id

    older =
      Repo.one(from(r in Request, where: r.api_key_id == ^key_id and fragment("?->>'docs_screenshot' IS NULL", r.request_metadata), select: max(r.admitted_at))) ||
        DateTime.add(now, -600, :second)

    newer =
      Repo.one(from(r in Request, where: r.api_key_id == ^key_id and r.admitted_at > ^older and fragment("?->>'docs_screenshot' = 'true'", r.request_metadata), select: min(r.admitted_at))) || now

    span = DateTime.diff(newer, older, :microsecond)
    if span < 4_000_000, do: raise("the full seed's newest rows sit too close to the generated traffic to place #{count} requests between them")

    step = div(span, count + 1)
    for position <- count..1//-1, do: DateTime.add(older, position * step, :microsecond)
  end
end
