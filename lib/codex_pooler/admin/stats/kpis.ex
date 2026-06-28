defmodule CodexPooler.Admin.Stats.Kpis do
  @moduledoc false

  alias CodexPooler.Admin.Stats.Aggregates

  @succeeded "succeeded"
  @failed_statuses ~w(failed rejected interrupted cancelled)

  @spec request_kpi([map()]) :: map()
  def request_kpi(requests) do
    %{
      value: length(requests),
      succeeded: Enum.count(requests, &(&1.status == @succeeded)),
      failed: Enum.count(requests, &(&1.status in @failed_statuses)),
      in_progress: Enum.count(requests, &(&1.status == "in_progress"))
    }
  end

  @spec success_rate_kpi([map()]) :: map()
  def success_rate_kpi([]), do: %{value: nil, unit: "percent"}

  def success_rate_kpi(requests) do
    succeeded = Enum.count(requests, &(&1.status == @succeeded))
    %{value: Aggregates.percentage(succeeded, length(requests)), unit: "percent"}
  end

  @spec token_kpi([map()]) :: map()
  def token_kpi(settlements) do
    %{
      input_tokens: Aggregates.sum_integer(settlements, :input_tokens),
      cached_input_tokens: Aggregates.sum_integer(settlements, :cached_input_tokens),
      output_tokens: Aggregates.sum_integer(settlements, :output_tokens),
      reasoning_tokens: Aggregates.sum_integer(settlements, :reasoning_tokens),
      total_tokens: Aggregates.sum_integer(settlements, :total_tokens)
    }
  end

  @spec tokens_per_second_kpi([map()], [map()]) :: map()
  def tokens_per_second_kpi(settlements, attempts) do
    total_tokens = Aggregates.sum_integer(settlements, :total_tokens)
    latency_ms = Aggregates.sum_integer(Enum.filter(attempts, & &1.latency_ms), :latency_ms)

    value =
      if total_tokens > 0 and latency_ms > 0 do
        Float.round(total_tokens / (latency_ms / 1000), 2)
      end

    %{value: value, unit: "tokens/second"}
  end

  @spec settled_cost_kpi([map()]) :: map()
  def settled_cost_kpi([]), do: %{status: "unavailable", micros: 0, usd: nil}

  def settled_cost_kpi(settlements) do
    micros = Aggregates.sum_decimal_integer(settlements, :settled_cost_micros)

    %{
      status: if(micros > 0, do: "settled", else: "unpriced"),
      micros: micros,
      usd: Aggregates.micros_to_usd_decimal(micros)
    }
  end

  @spec average_latency_kpi([map()]) :: map()
  def average_latency_kpi(attempts) do
    latencies = attempts |> Enum.map(& &1.latency_ms) |> Enum.filter(&is_integer/1)

    value =
      case latencies do
        [] -> nil
        _latencies -> round(Enum.sum(latencies) / length(latencies))
      end

    %{value: value, unit: "ms"}
  end

  @spec turn_kpi([map()]) :: map()
  def turn_kpi(turns) do
    %{
      value: length(turns),
      succeeded: Enum.count(turns, &(&1.status == @succeeded)),
      failed: Enum.count(turns, &(&1.status in @failed_statuses)),
      in_progress: Enum.count(turns, &(&1.status == "in_progress"))
    }
  end
end
