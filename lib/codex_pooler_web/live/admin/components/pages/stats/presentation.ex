defmodule CodexPoolerWeb.Admin.StatsPresentation do
  @moduledoc """
  Presentation components for the admin stats dashboard.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.StatsPresentation.{KpiStrip, Leaderboard, TrafficDistribution}

  attr :id, :string, required: true
  attr :dashboard, :map, required: true

  def kpi_strip(assigns), do: KpiStrip.render(assigns)

  attr :rows, :list, required: true
  attr :sort, :atom, default: :tokens, values: [:tokens, :cost]
  attr :window_label, :string, default: nil

  def top_api_keys_table(assigns), do: Leaderboard.render(assigns)

  attr :rows, :list, required: true
  attr :scope_label, :string, required: true
  attr :window_label, :string, required: true

  def upstream_traffic_distribution(assigns), do: TrafficDistribution.render(assigns)
end
