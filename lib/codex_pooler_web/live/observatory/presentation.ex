defmodule CodexPoolerWeb.Observatory.Presentation do
  @moduledoc """
  Builds the bounded, holder-facing render model for the API Key Observatory.
  """

  use Gettext, backend: CodexPoolerWeb.Gettext
  alias CodexPooler.Accounting.ClientIdentity
  alias CodexPoolerWeb.Admin.RequestLogsDisplay
  alias CodexPoolerWeb.Observatory.Presentation.Safety

  @endpoint_classes ["responses", "chat_completions", "completions", "embeddings", "compaction", "models", "usage", "files", "audio"]
  @windows [{"1h", "1h"}, {"5h", "5h"}, {"24h", "24h"}, {"7d", "7d"}]
  @spec window_options() :: [{String.t(), String.t()}]
  def window_options, do: @windows
  @spec valid_window?(term()) :: boolean()
  def valid_window?(key), do: Enum.any?(@windows, fn {window, _} -> window == key end)

  @spec build(term()) :: map()
  def build(value) do
    p = map(value)
    totals = map(get(p, :totals))
    requests = map(get(totals, :requests))
    tokens = map(get(totals, :tokens))
    total = non_negative(get(requests, :total))
    model_colors = model_colors(get(p, :models))

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
      outcomes: build_outcomes(get(p, :outcomes), model_colors),
      model_colors: model_colors,
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
    cancelled = non_negative(get(requests, :client_cancelled))
    input = non_negative(get(tokens, :input))
    cached = min(non_negative(get(tokens, :cached_input)), input)
    settled = cost(get(cost, :settled), "settled")
    estimated = cost(get(cost, :estimated), "estimated")
    success_detail = success_detail(succeeded, non_negative(get(requests, :failed)), cancelled)

    %{
      # A request the client cancelled is neither a success nor a failure, so the
      # rate leaves it out of its base and the detail names it.
      success_rate:
        rate(
          succeeded,
          max(total - cancelled, 0),
          success_detail,
          Safety.trend(get(trends, :success_rate), :percentage_points),
          if(cancelled > 0, do: success_detail, else: gettext("not available"))
        )
        |> with_grade(:success),
      cache_rate:
        rate(
          cached,
          input,
          cache_detail(cached, input),
          Safety.trend(get(trends, :cache_rate), :percentage_points)
        )
        |> with_grade(:cache),
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

  # Qualitative tiers for the two rate cards. The cut-offs are generic reading
  # aids, not service levels: a request log that fails one in ten is poor for
  # anyone, while a low cache rate only says the prompts share little prefix.
  defp success_tiers, do: [{99.0, gettext("Excellent"), :success}, {95.0, gettext("Good"), :info}, {90.0, gettext("Fair"), :warning}]
  defp cache_tiers, do: [{80.0, gettext("Excellent"), :success}, {50.0, gettext("Good"), :info}, {25.0, gettext("Fair"), :warning}]

  defp with_grade(%{percent: percent} = rate, kind), do: Map.put(rate, :grade, grade(kind, percent))

  defp grade(_kind, nil), do: nil
  defp grade(:success, percent), do: tier(percent, success_tiers(), {gettext("Poor"), :error})
  defp grade(:cache, percent), do: tier(percent, cache_tiers(), {gettext("Low"), :neutral})

  defp tier(percent, tiers, {label, tone}) do
    case Enum.find(tiers, fn {floor, _label, _tone} -> percent >= floor end) do
      {_floor, label, tone} -> %{label: label, tone: tone}
      nil -> %{label: label, tone: tone}
    end
  end

  defp request_detail(count), do: ngettext("%{requests} request", "%{requests} requests", count, requests: grouped_integer(count))

  defp cache_detail(cached, input),
    do: gettext("%{cached} of %{input} input tokens served from cache", cached: token_label(cached), input: token_label(input))

  defp rate(part, total, detail, trend, unavailable_detail \\ nil) do
    percent = percentage(part, total)

    %{
      percent: percent,
      measure: percent_measure(percent),
      detail: if(percent, do: detail, else: unavailable_detail || gettext("not available")),
      minibar: percent || 0.0,
      trend: trend
    }
  end

  defp success_detail(succeeded, failed, cancelled) do
    if cancelled > 0 do
      gettext("%{succeeded} succeeded · %{failed} failed · %{cancelled} client cancelled", succeeded: grouped_integer(succeeded), failed: grouped_integer(failed), cancelled: grouped_integer(cancelled))
    else
      gettext("%{succeeded} succeeded · %{failed} failed", succeeded: grouped_integer(succeeded), failed: grouped_integer(failed))
    end
  end

  defp percent_measure(nil), do: %{value: gettext("not available"), unit: nil}
  defp percent_measure(percent), do: %{value: "#{percent}", unit: "%"}

  @chart_model_colors ["var(--color-primary)", "var(--color-info)", "var(--color-warning)", "var(--color-reset-bank)", "var(--admin-chart-requests)"]
  @chart_other_color "var(--admin-chart-other-models)"
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
      categories: CodexPooler.JSON.encode!(Enum.map(rows, & &1.label)),
      series: CodexPooler.JSON.encode!(column_series ++ [%{"name" => gettext("Cost"), "type" => "line", "data" => cost_values}]),
      units: CodexPooler.JSON.encode!(token_kinds ++ ["USD"]),
      value_kinds: CodexPooler.JSON.encode!(token_kinds ++ ["usd"]),
      unit_labels: CodexPooler.JSON.encode!(List.duplicate(gettext("tokens"), length(column_series)) ++ ["USD"]),
      yaxis:
        CodexPooler.JSON.encode!([
          %{seriesName: series_names, title: gettext("tokens"), valueKind: "tokens"},
          %{seriesName: gettext("Cost"), title: gettext("cost"), opposite: true, valueKind: "usd"}
        ]),
      colors: CodexPooler.JSON.encode!(chart_colors(model_series) ++ [@chart_cost_color])
    )
  end

  defp model_series(models_value, model_buckets_value, totals, bucket_count) do
    index = model_bucket_index(model_buckets_value)

    base =
      models_value
      |> chart_models()
      |> Enum.with_index()
      |> Enum.map(fn {%{raw: raw, name: name}, index_position} ->
        %{name: name, color: Enum.at(@chart_model_colors, index_position, @chart_other_color), data: Enum.map(0..(bucket_count - 1)//1, &Map.get(index, {&1, raw}, 0))}
      end)
      |> Enum.reject(fn %{data: data} -> Enum.sum(data) == 0 end)

    case base do
      [] -> [%{name: gettext("Tokens"), color: @chart_other_color, data: totals}]
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

    if Enum.sum(other) > 0, do: series ++ [%{name: gettext("Other"), color: @chart_other_color, data: other}], else: series
  end

  defp chart_models(models) when is_list(models) do
    models
    |> Enum.take(@max_chart_models)
    |> Enum.map(fn model ->
      raw = get(map(model), :label)
      %{raw: raw, name: display_model_name(get(map(model), :display_name), raw)}
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
    Enum.map(model_series, & &1.color)
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
        label: display_model_name(get(row, :display_name), get(row, :label)),
        requests_label: request_short(non_negative(get(row, :request_count))),
        share_label: model_share_label(share),
        token_label: token_label(non_negative(get(row, :total_tokens))),
        cost_label: money_amount(non_negative(get(row, :cost_micros))),
        bar_percent: model_bar_percent(share),
        color: Enum.at(@chart_model_colors, index, @chart_other_color),
        shine_delay: shine_delay(index)
      }
    end)
  end

  defp models(_value, _total_tokens), do: []

  defp request_short(count), do: ngettext("%{requests} req", "%{requests} reqs", count, requests: grouped_integer(count))

  defp model_share_label(value) when is_number(value), do: "#{value}%"
  defp model_share_label(_value), do: "—"

  defp model_bar_percent(value) when is_number(value), do: min(max(value * 1.0, 0.0), 100.0)
  defp model_bar_percent(_value), do: 0.0

  # Stagger the gloss sweep so the model bars shimmer out of phase, matching the
  # banked-reset life bars in the upstream cockpit.
  defp shine_delay(index), do: Float.round(rem(index, 6) * 0.4, 2)

  @doc "Builds one bounded page of safe holder-facing outcomes."
  @spec build_outcomes(term(), map()) :: [map()]
  def build_outcomes(value, colors \\ %{})
  def build_outcomes(value, colors) when is_list(value), do: Enum.take(value, 200) |> Enum.map(&outcome(&1, colors))
  def build_outcomes(_value, _colors), do: []

  defp model_colors(models) when is_list(models) do
    models
    |> Enum.reject(&(non_negative(get(map(&1), :total_tokens)) == 0))
    |> Enum.take(12)
    |> Enum.with_index()
    |> Map.new(fn {model, index} -> {get(map(model), :label), Enum.at(@chart_model_colors, index, @chart_other_color)} end)
  end

  defp model_colors(_models), do: %{}

  defp outcome(value, colors) do
    row = map(value)
    tokens = non_negative(get(row, :total_tokens))
    code = Safety.sanitize_code(get(row, :code))
    cost = cost(get(row, :cost), ["settled", "estimated"])
    endpoint = endpoint(get(row, :endpoint_class))
    model_applicable? = endpoint not in ["models", "usage", "files"]

    %{
      client: outcome_client(get(row, :client)),
      code: code,
      cost: cost,
      effort: if(model_applicable?, do: Safety.sanitize_text(get(row, :reasoning_effort), nil)),
      endpoint: endpoint,
      model: if(model_applicable?, do: display_model_name(get(row, :model_display_name), get(row, :model)), else: gettext("Not applicable")),
      model_color: if(model_applicable?, do: outcome_model_color(get(row, :model), colors)),
      speed_level: if(model_applicable?, do: speed_level(row, cost)),
      status: status(get(row, :status), code),
      timestamp: outcome_timestamp(get(row, :timestamp)),
      tokens: tokens(row, tokens)
    }
  end

  # The admin request log's speed rule, fed from the same recorded tiers: a
  # priced request counts at the tier it was priced at, an unpriced one at the
  # tier the pricing rule would use.
  defp speed_level(row, cost) do
    RequestLogsDisplay.speed_level(%{
      cost: %{pricing_availability: if(cost.status == "settled", do: "priced", else: "unpriced")},
      service_tier: get(row, :service_tier),
      requested_service_tier: get(row, :requested_service_tier),
      actual_service_tier: get(row, :actual_service_tier),
      metadata: nil
    })
  end

  defp display_model_name(name, code), do: Safety.sanitize_text(name, Safety.sanitize_text(code, gettext("Unknown model")))

  defp outcome_client(value) do
    identity = ClientIdentity.from_kind(get(value, :kind))

    if identity.kind == "unknown" do
      %{identity | label: ClientIdentity.compact_user_agent(get(value, :label)) || gettext("Unknown client")}
    else
      identity
    end
  end

  defp outcome_model_color(code, colors) do
    case Safety.sanitize_text(code, nil) do
      nil -> nil
      "Unknown model" -> nil
      model -> Map.get(colors, model, @chart_other_color)
    end
  end

  defp tokens(row, total) do
    input = get(row, :input_tokens)
    cached = get(row, :cached_input_tokens)
    output = get(row, :output_tokens)
    base = %{total: total, label: outcome_token_label(total), cache_percentage_label: nil}

    if valid_token_counts?([get(row, :total_tokens), input, cached, output]) and total > 0 and input + output == total and cached <= input do
      %{base | cache_percentage_label: cache_percentage_label(cached, input)}
    else
      base
    end
  end

  defp valid_token_counts?(counts), do: Enum.all?(counts, &(is_integer(&1) and &1 >= 0))

  defp cache_percentage_label(0, input) when input > 0, do: "0%"

  defp cache_percentage_label(cached, input) when input > 0 do
    rate = Float.round(cached / input * 100, 1)
    "#{rate}%"
  end

  defp cache_percentage_label(_cached, _input), do: nil

  # A client cancellation (`RequestOutcome`) is not a failure: it names no reason.
  defp status("client_cancelled", _code), do: status("client_cancelled")

  defp status(value, code) do
    status = status(value)
    %{status | label: status_label(status.label, code)}
  end

  defp status("succeeded"), do: %{data_status: "ok", tone: :success, label: gettext("Succeeded")}
  defp status("failed"), do: %{data_status: "err", tone: :error, label: gettext("Failed")}
  defp status("rejected"), do: %{data_status: "err", tone: :error, label: gettext("Rejected")}

  defp status("accepted"), do: %{data_status: "warn", tone: :warning, label: gettext("Accepted")}
  defp status("in_progress"), do: %{data_status: "warn", tone: :warning, label: gettext("In progress")}

  defp status("client_cancelled"), do: %{data_status: "warn", tone: :warning, label: gettext("Client cancelled")}

  defp status(_value), do: %{data_status: "neutral", tone: :neutral, label: gettext("Unknown")}

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
    do: gettext("+ %{label} estimated, awaiting settlement", label: label)

  defp cost_detail(_estimated), do: gettext("not available")

  defp status_label(label, nil), do: label
  defp status_label(label, code), do: gettext("%{status} · %{reason}", status: label, reason: Safety.failure_label(code))

  defp confidence(value, _total) when value in ["settled", "estimated", "partial", "unavailable"],
    do: value

  defp confidence(_value, 0), do: "unavailable"
  defp confidence(_value, _total), do: "settled"
  defp percentage(_part, 0), do: nil
  defp percentage(part, total), do: Float.round(non_negative(part) * 100 / total, 1)

  defp traffic_label(tokens, cost_micros),
    do: ngettext("%{tokens} token · %{cost}", "%{tokens} tokens · %{cost}", tokens, tokens: token_label(tokens), cost: money_label(cost_micros))

  defp grouped_integer(value),
    do: Regex.replace(~r/\d(?=(\d{3})+$)/, Integer.to_string(value), &(&1 <> ","))

  defp token_label(value) when value < 1_000, do: "#{value}"
  defp token_label(value) when value < 999_950, do: "#{Float.round(value / 1_000, 1)}K"
  defp token_label(value) when value < 999_950_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  defp token_label(value), do: "#{Float.round(value / 1_000_000_000, 1)}B"

  defp outcome_token_label(value), do: value |> token_label() |> String.replace("K", "k")

  defp money_label(micros),
    do: :io_lib.format("$~.2f", [micros / 1_000_000]) |> IO.iodata_to_binary()

  # Money without the currency glyph, so the model row can mute the unit.
  defp money_amount(micros),
    do: :io_lib.format("~.2f", [micros / 1_000_000]) |> IO.iodata_to_binary()

  defp category(%DateTime{} = value), do: Calendar.strftime(value, "%m-%d %H:%M")
  defp category(_value), do: ""

  defp outcome_timestamp(%DateTime{} = value) do
    pattern = if Gettext.get_locale() == "zh_CN", do: "%m月%d日 %H:%M:%S", else: "%b %d, %H:%M:%S"
    Calendar.strftime(value, pattern)
  end

  defp outcome_timestamp(_value), do: gettext("not recorded")

  defp non_negative(value), do: max(integer(value), 0)
  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(%Decimal{} = value), do: Decimal.round(value, 0) |> Decimal.to_integer()
  defp integer(_value), do: 0
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp get(value, key, default \\ nil), do: Map.get(map(value), key, default)
end
