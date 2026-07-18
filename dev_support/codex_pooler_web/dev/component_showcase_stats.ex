defmodule CodexPoolerWeb.Dev.ComponentShowcaseStats do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.StatsPresentation.Charts
  alias CodexPoolerWeb.Dev.ComponentShowcaseCatalog

  @contract_id "stats-traffic-charts"
  @traffic_charts_export {Charts, :traffic_charts, 1}
  @showcase_export {__MODULE__, :stats_traffic_charts, 1}
  @entries [
    %{
      id: "5.12-segmented-control",
      section: "### 5.12 Segmented pill control",
      source: "traffic_charts/1 (public composition of private chart_mode_control/1)",
      selectors: [
        "#stats-traffic-chart-mode-control",
        "#stats-traffic-chart-mode-interval",
        "#stats-traffic-chart-mode-cumulative"
      ]
    },
    %{
      id: "5.13-time-series-chart",
      section: "### 5.13 Time-series chart surface",
      source: "traffic_charts/1",
      selectors: [
        "#stats-traffic-chart",
        "#stats-traffic-chart-scroll[data-role='chart-scroll-region']",
        "#stats-traffic-chart-plot[phx-hook='ApexTimeSeriesChart']"
      ]
    }
  ]

  def contract do
    %{
      id: @contract_id,
      exports: [@traffic_charts_export, @showcase_export],
      export_identity: export_identity(@traffic_charts_export),
      root_selector: root_selector(),
      entries: @entries
    }
  end

  def catalog_entries do
    contract = contract()

    Enum.map(contract.entries, fn entry ->
      ComponentShowcaseCatalog.entry(
        entry.id,
        entry.section,
        entry.source,
        Charts,
        :traffic_charts,
        exports: [@showcase_export],
        selectors: entry.selectors,
        scope_selector: contract.root_selector,
        render_contract: contract.id
      )
    end)
  end

  def stats_traffic_charts(assigns) do
    chart = apply_export(@traffic_charts_export, Map.merge(assigns, chart_fixture()))

    assigns =
      assigns
      |> assign(:chart, chart)
      |> assign(:contract_id, @contract_id)
      |> assign(:export_identity, export_identity(@traffic_charts_export))

    ~H"""
    <section
      id="showcase-stats-traffic-charts"
      data-showcase-contract={@contract_id}
      data-component-export={@export_identity}
    >
      {@chart}
    </section>
    """
  end

  defp apply_export({module, function, 1}, assigns), do: apply(module, function, [assigns])

  defp root_selector do
    "#showcase-stats-traffic-charts[data-showcase-contract='#{@contract_id}']" <>
      "[data-component-export='#{export_identity(@traffic_charts_export)}']"
  end

  defp export_identity({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  defp chart_fixture do
    %{
      requests: [
        %{bucket: "2026-07-17T11:00:00Z", requests: 9},
        %{bucket: "2026-07-17T12:00:00Z", requests: 7}
      ],
      tokens: [
        %{
          bucket: "2026-07-17T11:00:00Z",
          uncached_input_tokens: 5_000,
          cached_input_tokens: 2_000,
          output_tokens: 1_500,
          reasoning_tokens: 500,
          total_tokens: 9_000
        },
        %{
          bucket: "2026-07-17T12:00:00Z",
          uncached_input_tokens: 4_000,
          cached_input_tokens: 1_000,
          output_tokens: 1_250,
          reasoning_tokens: 250,
          total_tokens: 6_500
        }
      ],
      costs: [
        %{bucket: "2026-07-17T11:00:00Z", settled_cost_micros: 650_000},
        %{bucket: "2026-07-17T12:00:00Z", settled_cost_micros: 600_000}
      ],
      model_usage: [
        %{bucket: "2026-07-17T11:00:00Z", model_code: "alpha-model", total_tokens: 9_000},
        %{bucket: "2026-07-17T12:00:00Z", model_code: "beta-model", total_tokens: 6_500}
      ]
    }
  end
end
