defmodule CodexPoolerWeb.Admin.LensFilterForm do
  @moduledoc false

  alias CodexPooler.Accounting.RequestLogs.ModelHistory

  @type option :: %{value: String.t(), label: String.t(), icon: String.t(), icon_class: String.t()}

  @spec values(map()) :: map()
  defdelegate values(params), to: ModelHistory, as: :normalize_filters

  @spec window_options() :: [option()]
  def window_options do
    for {value, label} <- [{"1h", "Last hour"}, {"24h", "Last 24 hours"}, {"7d", "Last 7 days"}],
        do: option(value, label, "hero-clock", "text-base-content/60")
  end

  @spec evidence_options() :: [option()]
  def evidence_options do
    [
      option("signals", "Model differences", "hero-magnifying-glass", "text-warning"),
      option("all", "All attempts", "hero-funnel", "text-base-content/60"),
      option("mismatch", "Different from sent", "hero-arrows-right-left", "text-warning"),
      option("conflict", "Name changed in response", "hero-exclamation-triangle", "text-error"),
      option("missing", "No model reported (info)", "hero-question-mark-circle", "text-base-content/60"),
      option("uncollected", "Not collected", "hero-eye-slash", "text-base-content/50"),
      option("partial", "Incomplete recording", "hero-chart-pie", "text-info")
    ]
  end

  @spec model_options([String.t()], String.t()) :: [option()]
  def model_options(models, selected) do
    models = [selected | models] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort_by(&String.downcase/1)
    [option("", "Any sent model", "hero-cpu-chip", "text-base-content/60") | Enum.map(models, &option(&1, &1, "hero-cpu-chip", "text-info"))]
  end

  @spec selected([option()], String.t()) :: option()
  def selected(options, value), do: Enum.find(options, &(&1.value == value)) || hd(options)

  defp option(value, label, icon, icon_class), do: %{value: value, label: label, icon: icon, icon_class: icon_class}
end
