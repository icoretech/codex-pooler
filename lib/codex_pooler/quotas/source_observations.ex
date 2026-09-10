defmodule CodexPooler.Quotas.SourceObservations do
  @moduledoc "Pure retained quota grouping shared by source evidence dialogs and metrics."

  alias CodexPooler.Quotas.AdditionalMeterIdentity
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @spec group_key(AccountQuotaWindow.t()) :: String.t()
  def group_key(%AccountQuotaWindow{window_kind: "primary", window_minutes: 10_080} = window),
    do: group_key(%{window | window_kind: "secondary"})

  def group_key(window) do
    {WindowSelector.logical_key(window), AdditionalMeterIdentity.token(window)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def groups(raw_windows, as_of) do
    raw_windows
    |> Enum.reject(&future_observation?(&1, as_of))
    |> Enum.group_by(&group_key/1)
  end

  defp future_observation?(%{observed_at: %DateTime{} = observed_at}, as_of),
    do: DateTime.compare(observed_at, as_of) == :gt

  defp future_observation?(_window, _as_of), do: false
end
