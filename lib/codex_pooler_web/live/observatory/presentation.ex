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
          map(get(p, :trends))
        ),
      models: models(get(p, :models), non_negative(get(tokens, :total))),
      outcomes: outcomes(get(p, :outcomes)),
      traffic: traffic(get(p, :buckets), get(p, :model_buckets), get(p, :models), tokens)
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

  defp overview(requests, tokens, cost, trends) do
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
      tokens: %{
        value: token_label(non_negative(get(tokens, :total))),
        detail: request_detail(total)
      }
    }
  end

  defp request_detail(1), do: "1 request"
  defp request_detail(count), do: "#{grouped_integer(count)} requests"

  defp cache_detail(cached, input),
    do: "#{token_label(cached)} of #{token_label(input)} input tokens served from cache"

  defp rate(part, total, detail, trend) do
    percent = percentage(part, total)

    %{
      percent: percent,
      measure: percent_measure(percent),
      detail: if(percent, do: detail, else: "not available"),
      minibar: percent || 0.0,
      trend: trend
    }
  end

  defp percent_measure(nil), do: %{value: "not available", unit: nil}
  defp percent_measure(percent), do: %{value: "#{percent}", unit: "%"}

  # Cost is the green line; keep green out of the model columns so the two
  # never collide (mirrors the admin tokens-vs-cost chart palette).
  @chart_model_colors [
    "var(--color-primary)",
    "var(--color-info)",
    "var(--color-warning)",
    "var(--color-accent)",
    "var(--color-secondary)"
  ]
  @chart_other_color "color-mix(in oklab, var(--color-base-content) 40%, transparent)"
  @chart_cost_color "var(--color-success)"
  @max_chart_models 5

  defp traffic(buckets_value, model_buckets_value, models_value, tokens) do
    rows = buckets(buckets_value)
    total = non_negative(get(tokens, :total))
    cost_micros = Enum.sum(Enum.map(rows, & &1.cost_micros))

    %{
      categories: Enum.map(rows, & &1.label),
      chart: chart(rows, model_buckets_value, models_value),
      total_label: traffic_label(total, cost_micros),
      fallback: %{
        total_label: traffic_label(total, cost_micros),
        rows: rows
      }
    }
  end

  # Stacked token columns broken down by model (top models plus a folded
  # "Other" so the columns sum to total tokens per bucket) with a requests
  # line on a second axis, mirroring the admin "Traffic over time" chart.
  defp chart(rows, model_buckets_value, models_value) do
    totals = Enum.map(rows, & &1.total)
    cost_values = Enum.map(rows, & &1.cost_usd)

    model_series = model_series(models_value, model_buckets_value, totals, length(rows))
    column_series = Enum.map(model_series, fn s -> series(s.name, s.data) end)
    series_names = Enum.map(model_series, & &1.name)
    token_kinds = List.duplicate("tokens", length(column_series))

    Map.new(
      categories: Jason.encode!(Enum.map(rows, & &1.label)),
      series:
        Jason.encode!(
          column_series ++ [%{"name" => "Cost", "type" => "line", "data" => cost_values}]
        ),
      units: Jason.encode!(token_kinds ++ ["USD"]),
      value_kinds: Jason.encode!(token_kinds ++ ["usd"]),
      yaxis:
        Jason.encode!([
          %{seriesName: series_names, title: "tokens", valueKind: "tokens"},
          %{seriesName: "Cost", title: "cost", opposite: true, valueKind: "usd"}
        ]),
      colors: Jason.encode!(chart_colors(model_series) ++ [@chart_cost_color])
    )
  end

  defp model_series(models_value, model_buckets_value, totals, bucket_count) do
    index = model_bucket_index(model_buckets_value)

    base =
      models_value
      |> chart_models()
      |> Enum.map(fn %{raw: raw, name: name} ->
        %{name: name, data: Enum.map(0..(bucket_count - 1)//1, &Map.get(index, {&1, raw}, 0))}
      end)
      |> Enum.reject(fn %{data: data} -> Enum.sum(data) == 0 end)

    case base do
      [] -> [%{name: "Tokens", data: totals}]
      series -> append_other(series, totals)
    end
  end

  defp append_other(series, totals) do
    other =
      totals
      |> Enum.with_index()
      |> Enum.map(fn {total, position} ->
        covered =
          Enum.reduce(series, 0, fn %{data: data}, acc -> acc + Enum.at(data, position, 0) end)

        max(total - covered, 0)
      end)

    if Enum.sum(other) > 0, do: series ++ [%{name: "Other", data: other}], else: series
  end

  defp chart_models(models) when is_list(models) do
    models
    |> Enum.take(@max_chart_models)
    |> Enum.map(fn model ->
      raw = get(map(model), :label)
      %{raw: raw, name: Safety.sanitize_text(raw, "Unknown model")}
    end)
  end

  defp chart_models(_models), do: []

  defp model_bucket_index(rows) when is_list(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      row = map(row)

      Map.put(
        acc,
        {integer(get(row, :bucket_index)), get(row, :label)},
        non_negative(get(row, :total_tokens))
      )
    end)
  end

  defp model_bucket_index(_rows), do: %{}

  defp chart_colors(model_series) do
    model_series
    |> Enum.with_index()
    |> Enum.map(fn {%{name: name}, position} ->
      if name == "Other",
        do: @chart_other_color,
        else: Enum.at(@chart_model_colors, position, @chart_other_color)
    end)
  end

  defp series(name, data), do: %{"name" => name, "type" => "column", "data" => data}
  defp buckets(value) when is_list(value), do: Enum.take(value, 200) |> Enum.map(&bucket/1)
  defp buckets(_value), do: []

  defp bucket(row) do
    row = map(row)
    tokens = map(get(row, :tokens))
    total = non_negative(get(tokens, :total))
    cost = map(get(row, :cost))

    cost_micros =
      non_negative(get(map(get(cost, :settled)), :micros)) +
        non_negative(get(map(get(cost, :estimated)), :micros))

    %{
      label: category(get(row, :started_at)),
      total: total,
      total_label: token_label(total),
      cost_micros: cost_micros,
      cost_usd: Float.round(cost_micros / 1_000_000, 4),
      cost_label: money_label(cost_micros)
    }
  end

  defp models(value, _total_tokens) when is_list(value) do
    rows =
      value
      |> Enum.reject(&(non_negative(get(map(&1), :total_tokens)) == 0))
      |> Enum.take(12)

    Enum.with_index(rows)
    |> Enum.map(fn {value, index} ->
      row = map(value)
      share = get(row, :share_percent)

      %{
        label: Safety.sanitize_text(get(row, :label), "Unknown model"),
        requests_label: request_short(non_negative(get(row, :request_count))),
        share_label: model_share_label(share),
        token_label: token_label(non_negative(get(row, :total_tokens))),
        cost_label: money_amount(non_negative(get(row, :cost_micros))),
        bar_percent: model_bar_percent(share),
        # Same palette + rank order as the traffic chart columns, so a model's
        # card tint matches its bar/line in the chart (top-5 colored, rest folded
        # into the muted "Other" color).
        color: Enum.at(@chart_model_colors, index, @chart_other_color),
        shine_delay: shine_delay(index)
      }
    end)
  end

  defp models(_value, _total_tokens), do: []

  defp request_short(1), do: "1 req"
  defp request_short(count), do: "#{grouped_integer(count)} reqs"

  defp model_share_label(value) when is_number(value), do: "#{value}%"
  defp model_share_label(_value), do: "—"

  defp model_bar_percent(value) when is_number(value), do: min(max(value * 1.0, 0.0), 100.0)
  defp model_bar_percent(_value), do: 0.0

  # Stagger the gloss sweep so the model bars shimmer out of phase, matching the
  # banked-reset life bars in the upstream cockpit.
  defp shine_delay(index), do: Float.round(rem(index, 6) * 0.4, 2)

  defp outcomes(value) when is_list(value), do: Enum.take(value, 12) |> Enum.map(&outcome/1)
  defp outcomes(_value), do: []

  defp outcome(value) do
    row = map(value)
    tokens = non_negative(get(row, :total_tokens))
    code = Safety.sanitize_code(get(row, :code))

    %{
      code: code,
      cost: cost(get(row, :cost), ["settled", "estimated"]),
      endpoint: endpoint(get(row, :endpoint_class)),
      model: Safety.sanitize_text(get(row, :model), "Unknown model"),
      status: status(get(row, :status), code),
      timestamp: outcome_timestamp(get(row, :timestamp)),
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

  defp traffic_label(tokens, cost_micros),
    do: "#{token_label(tokens)} tokens · #{money_label(cost_micros)}"

  defp grouped_integer(value),
    do: Regex.replace(~r/\d(?=(\d{3})+$)/, Integer.to_string(value), &(&1 <> ","))

  defp token_label(value) when value < 1_000, do: "#{value}"
  defp token_label(value) when value < 999_950, do: "#{Float.round(value / 1_000, 1)}K"
  defp token_label(value) when value < 999_950_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  defp token_label(value), do: "#{Float.round(value / 1_000_000_000, 1)}B"

  defp money_label(micros),
    do: :io_lib.format("$~.2f", [micros / 1_000_000]) |> IO.iodata_to_binary()

  # Money without the currency glyph, so the model card can tint the amount but
  # leave the "$" a neutral color to keep it legible.
  defp money_amount(micros),
    do: :io_lib.format("~.2f", [micros / 1_000_000]) |> IO.iodata_to_binary()

  defp category(%DateTime{} = value), do: Calendar.strftime(value, "%m-%d %H:%M")
  defp category(_value), do: ""
  defp outcome_timestamp(%DateTime{} = value), do: Calendar.strftime(value, "%b %d, %H:%M:%S")
  defp outcome_timestamp(_value), do: "not recorded"

  defp non_negative(value), do: max(integer(value), 0)
  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(%Decimal{} = value), do: Decimal.round(value, 0) |> Decimal.to_integer()
  defp integer(_value), do: 0
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp get(value, key, default \\ nil), do: Map.get(map(value), key, default)
end
