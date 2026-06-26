defmodule CodexPooler.Accounting.UsageReadModel do
  @moduledoc """
  Usage read-model builders for local API-key usage and Codex usage responses.
  """

  import Ecto.Query

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.{DailyRollup, LedgerEntry, Request, UsageResponses}
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Accounting.UsageReadModel.UpstreamUsage
  alias CodexPooler.Repo

  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_known "usage_known"

  @type accounting_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec list_api_key_usage_summaries([term()]) :: map()
  def list_api_key_usage_summaries(api_key_ids) when is_list(api_key_ids) do
    api_key_ids =
      api_key_ids
      |> Enum.map(&id_for/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if api_key_ids == [] do
      %{}
    else
      Repo.all(
        from entry in LedgerEntry,
          where:
            entry.api_key_id in ^api_key_ids and entry.entry_kind == @entry_settlement and
              entry.amount_status == @amount_recorded,
          group_by: entry.api_key_id,
          select: {
            entry.api_key_id,
            sum(entry.request_count),
            sum(
              fragment(
                "CASE WHEN ? = ? THEN COALESCE(?, 0) ELSE 0 END",
                entry.usage_status,
                ^@usage_known,
                entry.input_tokens
              )
            ),
            sum(
              fragment(
                "CASE WHEN ? = ? THEN COALESCE(?, 0) ELSE 0 END",
                entry.usage_status,
                ^@usage_known,
                entry.cached_input_tokens
              )
            ),
            sum(
              fragment(
                "CASE WHEN ? = ? THEN COALESCE(?, 0) ELSE 0 END",
                entry.usage_status,
                ^@usage_known,
                entry.output_tokens
              )
            ),
            sum(
              fragment(
                "CASE WHEN ? = ? THEN COALESCE(?, 0) ELSE 0 END",
                entry.usage_status,
                ^@usage_known,
                entry.reasoning_tokens
              )
            ),
            sum(
              fragment(
                "CASE WHEN ? = ? THEN COALESCE(?, 0) ELSE 0 END",
                entry.usage_status,
                ^@usage_known,
                entry.total_tokens
              )
            ),
            sum(
              fragment(
                "CASE WHEN ? = ? THEN COALESCE(?, 0::numeric) ELSE 0::numeric END",
                entry.usage_status,
                ^@usage_known,
                entry.settled_cost_micros
              )
            )
          }
      )
      |> Map.new(&api_key_usage_summary_from_row/1)
    end
  end

  @spec build_api_key_self_usage(term(), term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  def build_api_key_self_usage(pool_or_id, api_key_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)
    api_key_id = id_for(api_key_or_id)
    as_of = Keyword.get(opts, :as_of, now())

    if is_binary(pool_id) and is_binary(api_key_id) do
      rolling = rolling_api_key_summary(pool_id, api_key_id, as_of)
      cost_summary = rolling_api_key_cost_summary(pool_id, api_key_id, as_of)
      daily = daily_api_key_summary(pool_id, api_key_id, as_of)

      window_usages =
        LedgerEntries.window_usages(api_key_id,
          weekly: DateTime.add(as_of, -7, :day),
          minute: DateTime.add(as_of, -60, :second)
        )

      weekly = window_usages.weekly
      minute = window_usages.minute

      bindings =
        Repo.all(
          from b in APIKeyPolicyBinding,
            where: b.api_key_id == ^api_key_id and b.status == "active"
        )

      {:ok,
       %{
         request_count: rolling.request_count,
         total_tokens: rolling.total_tokens,
         cached_input_tokens: rolling.cached_input_tokens,
         total_cost_usd:
           if(cost_summary.priced_settlement_count > 0,
             do: decimal_micros_to_usd(cost_summary.priced_settled_cost_micros),
             else: nil
           ),
         total_cost_status:
           if(cost_summary.priced_settlement_count > 0, do: "priced", else: "unpriced"),
         limits:
           UsageResponses.self_usage_limits(
             bindings,
             minute.effective_request_count,
             daily.total_tokens,
             weekly.effective_total_tokens,
             as_of
           )
       }}
    else
      {:error, accounting_error(:invalid_request, "pool_id and api_key_id are required")}
    end
  end

  @spec build_codex_usage_for_api_key(term(), term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  def build_codex_usage_for_api_key(pool_or_id, api_key_or_id, opts \\ []) do
    case build_codex_usage_for_pool(pool_or_id, opts) do
      {:ok, usage} ->
        {:ok, usage}

      {:error, %{code: :no_upstream_usage}} ->
        build_local_codex_usage_for_api_key(pool_or_id, api_key_or_id, opts)
    end
  end

  @spec build_v1_usage_for_api_key(term(), term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  def build_v1_usage_for_api_key(pool_or_id, api_key_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)
    as_of = Keyword.get(opts, :as_of, now())

    with {:ok, usage} <- build_api_key_self_usage(pool_or_id, api_key_or_id, opts) do
      {:ok,
       %{
         request_count: usage.request_count,
         total_tokens: usage.total_tokens,
         cached_input_tokens: usage.cached_input_tokens,
         total_cost_usd: v1_total_cost_usd(usage),
         total_cost_status: usage.total_cost_status,
         limits: Enum.map(usage.limits, &normalize_v1_limit/1),
         upstream_limits: v1_upstream_limits_for_pool(pool_id, as_of, opts)
       }}
    end
  end

  @spec build_codex_usage_for_pool(term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_pool(pool_or_id, opts \\ []), to: UpstreamUsage

  @spec build_codex_usage_for_chatgpt_account(term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_chatgpt_account(chatgpt_account_id, opts \\ []),
    to: UpstreamUsage

  @spec build_codex_usage_for_upstream_identity(
          CodexPooler.Upstreams.Schemas.UpstreamIdentity.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_upstream_identity(identity, opts \\ []), to: UpstreamUsage

  defp build_local_codex_usage_for_api_key(pool_or_id, api_key_or_id, opts) do
    with {:ok, usage} <- build_api_key_self_usage(pool_or_id, api_key_or_id, opts) do
      primary =
        Enum.find(
          usage.limits,
          &(&1.limit_type == "credits" and &1.limit_window == "daily" and is_nil(&1.model_filter))
        )

      {:ok,
       %{
         plan_type: "api_key",
         rate_limit: UsageResponses.codex_rate_limit(primary, nil),
         credits: UsageResponses.codex_credits(primary, nil)
       }}
    end
  end

  defp rolling_api_key_summary(pool_id, api_key_id, as_of) do
    start_date = as_of |> DateTime.add(-27, :day) |> DateTime.to_date()
    end_date = DateTime.to_date(as_of)

    summarize_rollups(
      from r in DailyRollup,
        where:
          r.pool_id == ^pool_id and r.api_key_id == ^api_key_id and r.dimension_kind == "api_key" and
            r.rollup_date >= ^start_date and r.rollup_date <= ^end_date
    )
  end

  defp daily_api_key_summary(pool_id, api_key_id, as_of) do
    date = DateTime.to_date(as_of)

    summarize_rollups(
      from r in DailyRollup,
        where:
          r.pool_id == ^pool_id and r.api_key_id == ^api_key_id and r.dimension_kind == "api_key" and
            r.rollup_date == ^date
    )
  end

  defp summarize_rollups(query) do
    rows = Repo.all(query)

    Enum.reduce(rows, empty_summary(), fn row, acc ->
      %{
        request_count: acc.request_count + row.request_count,
        success_count: acc.success_count + row.success_count,
        failure_count: acc.failure_count + row.failure_count,
        retry_count: acc.retry_count + row.retry_count,
        input_tokens: acc.input_tokens + row.input_tokens,
        cached_input_tokens: acc.cached_input_tokens + row.cached_input_tokens,
        output_tokens: acc.output_tokens + row.output_tokens,
        reasoning_tokens: acc.reasoning_tokens + row.reasoning_tokens,
        total_tokens: acc.total_tokens + row.total_tokens,
        estimated_cost_micros: Decimal.add(acc.estimated_cost_micros, row.estimated_cost_micros),
        settled_cost_micros: Decimal.add(acc.settled_cost_micros, row.settled_cost_micros)
      }
    end)
  end

  defp empty_summary do
    %{
      request_count: 0,
      success_count: 0,
      failure_count: 0,
      retry_count: 0,
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0,
      estimated_cost_micros: Decimal.new(0),
      settled_cost_micros: Decimal.new(0)
    }
  end

  defp api_key_usage_summary_from_row(
         {api_key_id, request_count, input_tokens, cached_input_tokens, output_tokens,
          reasoning_tokens, total_tokens, settled_cost_micros}
       ) do
    input_tokens = decimal_to_integer(input_tokens)
    cached_input_tokens = min(decimal_to_integer(cached_input_tokens), input_tokens)

    component_total =
      input_tokens + decimal_to_integer(output_tokens) + decimal_to_integer(reasoning_tokens)

    settled_cost_micros = settled_cost_micros || Decimal.new(0)

    {api_key_id,
     %{
       request_count: decimal_to_integer(request_count),
       total_tokens: max(decimal_to_integer(total_tokens), component_total),
       cached_input_tokens: max(cached_input_tokens, 0),
       total_cost_usd: decimal_micros_to_usd(settled_cost_micros),
       total_cost_status:
         if(Decimal.compare(settled_cost_micros, Decimal.new(0)) == :gt,
           do: "priced",
           else: "unpriced"
         )
     }}
  end

  defp v1_upstream_limits_for_pool(pool_id, as_of, opts) when is_binary(pool_id) do
    UpstreamUsage.v1_upstream_limits_for_pool(pool_id, as_of, opts)
  end

  defp v1_upstream_limits_for_pool(_pool_id, _as_of, _opts), do: []

  defp normalize_v1_limit(limit) when is_map(limit) do
    %{
      limit_type: Map.get(limit, :limit_type),
      limit_window: Map.get(limit, :limit_window),
      max_value: Map.get(limit, :max_value),
      current_value: Map.get(limit, :current_value),
      remaining_value: Map.get(limit, :remaining_value),
      model_filter: Map.get(limit, :model_filter),
      reset_at: Map.get(limit, :reset_at),
      source: Map.get(limit, :source)
    }
  end

  defp v1_total_cost_usd(%{total_cost_usd: %Decimal{} = value}), do: Decimal.to_float(value)
  defp v1_total_cost_usd(_usage), do: 0.0

  defp rolling_api_key_cost_summary(pool_id, api_key_id, as_of) do
    start_date = as_of |> DateTime.add(-27, :day) |> DateTime.to_date()
    end_date = DateTime.to_date(as_of)

    rows =
      Repo.all(
        from entry in LedgerEntry,
          join: request in Request,
          on: request.id == entry.request_id,
          where:
            request.pool_id == ^pool_id and entry.api_key_id == ^api_key_id and
              entry.entry_kind == ^@entry_settlement and entry.usage_status == ^@usage_known and
              fragment("?::date", entry.occurred_at) >= ^start_date and
              fragment("?::date", entry.occurred_at) <= ^end_date and
              not is_nil(fragment("?->>?", entry.details, "settled_cost_micros")),
          select: entry.settled_cost_micros
      )

    Enum.reduce(
      rows,
      %{priced_settlement_count: 0, priced_settled_cost_micros: Decimal.new(0)},
      fn cost, acc ->
        %{
          priced_settlement_count: acc.priced_settlement_count + 1,
          priced_settled_cost_micros:
            Decimal.add(acc.priced_settled_cost_micros, cost || Decimal.new(0))
        }
      end
    )
  end

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp decimal_to_integer(nil), do: 0

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp decimal_to_integer(value) when is_integer(value), do: value

  defp decimal_micros_to_usd(%Decimal{} = micros),
    do: micros |> Decimal.div(Decimal.new(1_000_000)) |> Decimal.round(6)

  defp decimal_micros_to_usd(value),
    do: Decimal.new(value || 0) |> Decimal.div(Decimal.new(1_000_000)) |> Decimal.round(6)

  defp accounting_error(code, message), do: %{code: code, message: message}
end
