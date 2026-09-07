defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservations do
  @moduledoc """
  Operator evidence view. It never selects a routing window or updates evidence.

  Different future resets do not prove rollover. Keep competing source reports,
  with their original timestamps and current TTL state, until their windows end.
  Even a fresh report is an observation, not independently verified capacity.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector

  def key(%AccountQuotaWindow{window_kind: "primary", window_minutes: 10_080} = window),
    do: key(%{window | window_kind: "secondary"})

  def key(window) do
    {WindowSelector.logical_key(window), Evidence.additional_meter_token(window)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, "quota-observation-group-v1:" <> &1))
    |> Base.encode16(case: :lower)
  end

  def attach(rows, raw_windows, as_of) do
    groups =
      raw_windows
      |> Enum.reject(&future_observation?(&1, as_of))
      |> Enum.group_by(&key/1)

    Enum.map(rows, &attach_row(&1, groups, as_of))
  end

  defp attach_row(row, groups, as_of) do
    windows = Map.get(groups, Map.get(row, :evidence_key), [])
    disagreement? = disagreement?(windows, as_of, :usage)
    reset_disagreement? = disagreement?(windows, as_of, :reset)

    row
    |> Map.put(:observations, observations(windows, as_of))
    |> Map.put(:source_disagreement, disagreement?)
    |> Map.put(:reset_disagreement, reset_disagreement?)
    |> Map.put(:selected_percent_label, row.percent_label)
    |> Map.update!(:label, &scope_label(row.key, &1))
    |> mark_disagreement(disagreement?)
    |> mark_reset_disagreement(reset_disagreement?)
  end

  defp scope_label(:weekly, label), do: "Account #{label}"

  defp scope_label(_key, label), do: label

  defp mark_disagreement(row, false), do: row

  defp mark_disagreement(row, true) do
    Map.merge(row, %{
      percent: nil,
      percent_value: 0,
      percent_label: "sources differ",
      meter_state: :unknown
    })
  end

  defp mark_reset_disagreement(row, false), do: row

  defp mark_reset_disagreement(row, true) do
    Map.merge(row, %{
      reset_at: nil,
      reset_label: nil,
      reset_title: nil,
      reset_semantics: :unknown,
      reset_display_state: :absent
    })
  end

  defp observations(windows, as_of) do
    windows
    |> Enum.sort_by(&{&1.source || "", iso8601(&1.observed_at), iso8601(&1.reset_at)})
    |> Enum.map(fn window ->
      %{
        source: window.source || "source not reported",
        observed_at: iso8601(window.observed_at),
        reset_at: iso8601(window.reset_at),
        freshness: Evidence.current_freshness_state(window, as_of),
        elapsed: Evidence.expired?(window, as_of),
        used: percent(window.used_percent),
        remaining: remaining(window.used_percent),
        descriptor: descriptor(window)
      }
    end)
  end

  defp disagreement?(windows, as_of, dimension) do
    current =
      Enum.filter(windows, fn window ->
        not Evidence.expired?(window, as_of) and match?(%Decimal{}, window.used_percent)
      end)

    current
    |> Enum.any?(fn left ->
      Enum.any?(current, fn right ->
        left.source != right.source and
          different_report?(left, right, dimension)
      end)
    end)
  end

  defp different_report?(left, right, :usage),
    do: not Decimal.equal?(left.used_percent, right.used_percent)

  defp different_report?(left, right, :reset), do: left.reset_at != right.reset_at

  defp descriptor(window) do
    [
      window.model,
      window.upstream_model,
      Map.get(window.metadata || %{}, "normal_model_slug")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp future_observation?(%{observed_at: %DateTime{} = observed_at}, as_of),
    do: DateTime.compare(observed_at, as_of) == :gt

  defp future_observation?(_window, _as_of), do: false

  defp percent(%Decimal{} = value), do: "#{Decimal.to_string(value, :normal)}%"
  defp percent(_value), do: "not reported"
  defp remaining(%Decimal{} = used), do: percent(Decimal.sub(100, used))
  defp remaining(_used), do: "not reported"
  defp iso8601(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp iso8601(_time), do: "not reported"
end
