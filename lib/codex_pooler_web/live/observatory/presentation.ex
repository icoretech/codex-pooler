defmodule CodexPoolerWeb.Observatory.Presentation do
  @moduledoc """
  Builds the bounded, holder-facing render model for the API Key Observatory.
  """

  alias CodexPoolerWeb.Observatory.Presentation.Safety

  @endpoint_classes ["responses", "chat_completions", "completions", "embeddings"]
  @windows [{"1h", "1h"}, {"5h", "5h"}, {"24h", "24h"}, {"7d", "7d"}]
  def window_options, do: @windows
  def valid_window?(key), do: Enum.any?(@windows, fn {window, _} -> window == key end)

  def build(value) do
    p = map(value)
    totals = map(get(p, :totals))
    requests = map(get(totals, :requests))
    tokens = map(get(totals, :tokens))
    total = non_negative(get(requests, :total))

    %{
      window: window(get(p, :window)),
      state: state(get(get(p, :accounting), :status), total),
      overview:
        overview(
          requests,
          tokens,
          map(get(totals, :cost)),
          map(get(p, :performance)),
          map(get(p, :trends))
        ),
      models: models(get(p, :models), non_negative(get(tokens, :total))),
      outcomes: outcomes(get(p, :outcomes)),
      traffic: traffic(get(p, :buckets), tokens, total)
    }
  end

  defp window(value) do
    value = map(value)
    key = if valid_window?(get(value, :key)), do: get(value, :key), else: "24h"
    %{key: key}
  end

  defp state("complete", requests) when requests > 0, do: :ready
  defp state("partial", _requests), do: :partial
  defp state(_, _requests), do: :empty

  defp overview(requests, tokens, cost, performance, trends) do
    total = non_negative(get(requests, :total))
    succeeded = non_negative(get(requests, :succeeded))
    input = non_negative(get(tokens, :input))
    cached = min(non_negative(get(tokens, :cached_input)), input)
    settled = cost(get(cost, :settled), "settled")
    estimated = cost(get(cost, :estimated), "estimated")

    %{
      success_rate:
        rate(
          succeeded,
          total,
          "#{grouped_integer(succeeded)} succeeded · #{grouped_integer(non_negative(get(requests, :failed)))} failed",
          Safety.trend(get(trends, :success_rate), :percentage_points)
        ),
      cache_rate:
        rate(
          cached,
          input,
          cache_detail(cached, input),
          Safety.trend(get(trends, :cache_rate), :percentage_points)
        ),
      cost: %{
        settled: settled,
        estimated: estimated,
        detail: cost_detail(estimated),
        confidence: confidence(get(cost, :confidence), total)
      },
      throughput: throughput(performance, Safety.trend(get(trends, :throughput), :percent)),
      latency: latency(performance)
    }
  end

  defp cache_detail(cached, input),
    do: "#{token_label(cached)} of #{token_label(input)} input tokens served from cache"

  defp rate(part, total, detail, trend) do
    percent = percentage(part, total)

    %{
      percent: percent,
      label: percent_label(percent),
      detail: if(percent, do: detail, else: "not available"),
      minibar: percent || 0.0,
      trend: trend
    }
  end

  defp throughput(performance, trend) do
    values = map(get(performance, :throughput_tokens_per_second))
    %{p50_label: rate_label(get(values, :p50)), trend: trend}
  end

  defp latency(performance) do
    values = map(get(performance, :latency_ms))
    mean = nullable_integer(get(values, :mean))
    p50 = nullable_integer(get(values, :p50))
    p95 = nullable_integer(get(values, :p95))
    max = nullable_integer(get(values, :max))

    %{
      p50_label: integer_label(p50),
      p95_label: integer_label(p95),
      detail: latency_detail(mean, max)
    }
  end

  defp latency_detail(mean, max) when is_integer(mean) and is_integer(max),
    do: "Mean #{mean} ms · slowest settled #{max} ms"

  defp latency_detail(_mean, _max), do: "not available"

  defp traffic(value, tokens, requests) do
    rows = buckets(value)
    categories = Enum.map(rows, & &1.label)
    fresh = Enum.map(rows, & &1.fresh)
    cached = Enum.map(rows, & &1.cached)
    input = non_negative(get(tokens, :input))

    %{
      categories: categories,
      chart: chart(categories, fresh, cached),
      total_label: traffic_label(input, requests),
      fallback: %{
        total_label: traffic_label(input, requests),
        rows: rows
      }
    }
  end

  defp chart(categories, fresh, cached) do
    units = List.duplicate("tokens", length(categories))

    Map.new(
      categories: Jason.encode!(categories),
      series: Jason.encode!([series("Fresh input", fresh), series("Cached input", cached)]),
      units: Jason.encode!(units),
      value_kinds: Jason.encode!(units),
      yaxis:
        "[{\"seriesName\":[\"Fresh input\",\"Cached input\"],\"title\":\"tokens\",\"valueKind\":\"tokens\"}]",
      colors: Jason.encode!(["var(--color-primary)", "var(--color-info)"])
    )
  end

  defp series(name, data), do: %{"name" => name, "type" => "column", "data" => data}
  defp buckets(value) when is_list(value), do: Enum.take(value, 200) |> Enum.map(&bucket/1)
  defp buckets(_value), do: []

  defp bucket(row) do
    row = map(row)
    tokens = map(get(row, :tokens))
    input = non_negative(get(tokens, :input))
    cached = min(non_negative(get(tokens, :cached_input)), input)
    fresh = max(input - cached, 0)
    requests = non_negative(get(get(row, :requests), :total))

    %{
      label: category(get(row, :started_at)),
      fresh: fresh,
      fresh_label: token_label(fresh),
      cached: cached,
      cached_label: token_label(cached),
      total: input,
      total_label: token_label(input),
      requests: requests,
      requests_label: grouped_integer(requests)
    }
  end

  defp models(value, _total_tokens) when is_list(value) do
    rows = Enum.take(value, 12)
    max_tokens = Enum.max(Enum.map(rows, &non_negative(get(map(&1), :total_tokens))), fn -> 0 end)

    Enum.with_index(rows)
    |> Enum.map(fn {value, index} ->
      row = map(value)
      tokens = non_negative(get(row, :total_tokens))

      %{
        label: Safety.sanitize_text(get(row, :label), "Unknown model"),
        token_label: token_label(tokens),
        bar_percent: bar_percent(tokens, max_tokens),
        tone: Enum.at([:primary, :info, :success, :neutral], rem(index, 4))
      }
    end)
  end

  defp models(_value, _total_tokens), do: []
  defp outcomes(value) when is_list(value), do: Enum.take(value, 12) |> Enum.map(&outcome/1)
  defp outcomes(_value), do: []

  defp outcome(value) do
    row = map(value)
    latency = nullable_integer(get(row, :latency_ms))
    tokens = non_negative(get(row, :total_tokens))
    code = Safety.sanitize_code(get(row, :code))

    %{
      code: code,
      cost: cost(get(row, :cost), ["settled", "estimated"]),
      endpoint: endpoint(get(row, :endpoint_class)),
      latency: %{ms: latency, label: integer_label(latency)},
      model: Safety.sanitize_text(get(row, :model), "Unknown model"),
      status: status(get(row, :status), code),
      timestamp: datetime(get(row, :timestamp)),
      tokens: %{total: tokens, label: token_label(tokens)}
    }
  end

  defp status(value, code) do
    status = status(value)
    %{status | label: status_label(status.label, code)}
  end

  defp status("succeeded"), do: %{data_status: "ok", tone: :success, label: "Succeeded"}
  defp status("failed"), do: %{data_status: "err", tone: :error, label: "Failed"}

  defp status("in_progress"), do: %{data_status: "warn", tone: :warning, label: "In progress"}

  defp status("cancelled"),
    do: %{data_status: "neutral", tone: :neutral, label: "Cancelled"}

  defp status(_value), do: %{data_status: "neutral", tone: :neutral, label: "Unknown"}

  defp endpoint(value), do: if(value in @endpoint_classes, do: value, else: "other")

  defp cost(value, expected) do
    value = map(value)
    status = get(value, :status)
    micros = non_negative(get(value, :micros))

    if if(is_list(expected), do: status in expected, else: status == expected),
      do: %{status: status, micros: micros, label: money_label(micros)},
      else: %{status: "unavailable", micros: 0, label: "—"}
  end

  defp cost_detail(%{status: "estimated", label: label}),
    do: "+ #{label} estimated, awaiting settlement"

  defp cost_detail(_estimated), do: "not available"

  defp status_label(label, nil), do: label
  defp status_label(label, code), do: "#{label} · #{Safety.failure_label(code)}"

  defp confidence(value, _total) when value in ["settled", "estimated", "partial", "unavailable"],
    do: value

  defp confidence(_value, 0), do: "unavailable"
  defp confidence(_value, _total), do: "settled"
  defp percentage(_part, 0), do: nil
  defp percentage(part, total), do: Float.round(non_negative(part) * 100 / total, 1)
  defp percent_label(nil), do: "not available"
  defp percent_label(value), do: "#{value}%"
  defp traffic_label(tokens, 1), do: "#{token_label(tokens)} tokens · 1 request"

  defp traffic_label(tokens, requests),
    do: "#{token_label(tokens)} tokens · #{grouped_integer(requests)} requests"

  defp grouped_integer(value),
    do: Regex.replace(~r/\d(?=(\d{3})+$)/, Integer.to_string(value), &(&1 <> ","))

  defp token_label(value) when value < 1_000, do: "#{value}"
  defp token_label(value) when value < 999_950, do: "#{Float.round(value / 1_000, 1)}K"
  defp token_label(value) when value < 999_950_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  defp token_label(value), do: "#{Float.round(value / 1_000_000_000, 1)}B"
  defp bar_percent(_value, 0), do: 0.0

  defp bar_percent(value, total),
    do: min(Float.round(non_negative(value) * 100 / total, 1), 100.0)

  defp rate_label(nil), do: "not available"
  defp rate_label(value) when is_float(value), do: "#{Float.round(value, 2)} tok/s"
  defp rate_label(value), do: "#{integer(value) * 1.0} tok/s"
  defp integer_label(nil), do: "not available"
  defp integer_label(value), do: "#{value} ms"

  defp money_label(micros),
    do: :io_lib.format("$~.2f", [micros / 1_000_000]) |> IO.iodata_to_binary()

  defp category(%DateTime{} = value), do: Calendar.strftime(value, "%m-%d %H:%M")
  defp category(_value), do: ""
  defp datetime(%DateTime{} = value), do: value
  defp datetime(_value), do: nil

  defp nullable_integer(nil), do: nil
  defp nullable_integer(value), do: integer(value)
  defp non_negative(value), do: max(integer(value), 0)
  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(%Decimal{} = value), do: Decimal.round(value, 0) |> Decimal.to_integer()
  defp integer(_value), do: 0
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp get(value, key, default \\ nil), do: Map.get(map(value), key, default)
end
