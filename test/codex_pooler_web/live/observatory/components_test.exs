defmodule CodexPoolerWeb.Observatory.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.{Activity, Telemetry, Toolbar}

  test "toolbar exposes the safe principal, exact windows, freshness, pause, and logout" do
    html =
      render_component(&Toolbar.toolbar/1, %{
        display_name: "safe display",
        selected_window: "24h",
        freshness: "8s ago",
        paused: true
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "#observatory-toolbar") != []
    assert LazyHTML.query(fragment, "#observatory-toolbar-identity") != []
    assert LazyHTML.query(fragment, "#observatory-toolbar-controls") != []
    assert LazyHTML.query(fragment, "#observatory-wordmark") != []
    assert LazyHTML.query(fragment, "#observatory-key-chip") != []
    assert LazyHTML.query(fragment, "#observatory-principal") != []
    assert LazyHTML.query(fragment, "#observatory-key-prefix") |> Enum.empty?()
    assert html =~ "safe display"
    refute html =~ "safe-prefix"
    assert html =~ "8s ago"
    assert html =~ "Paused"
    assert LazyHTML.query(fragment, "#observatory-resume[aria-label='Resume auto-refresh']") != []

    for {key, label} <- [{"1h", "1h"}, {"5h", "5h"}, {"24h", "24h"}, {"7d", "7d"}] do
      selector = "#observatory-window-#{key}[aria-pressed='#{key == "24h"}']"
      assert LazyHTML.query(fragment, selector) != []

      assert LazyHTML.query(fragment, "#observatory-window-#{key}[phx-click='select-window']") !=
               []

      assert html =~ label
    end

    assert LazyHTML.query(fragment, "#observatory-freshness") != []
    assert LazyHTML.query(fragment, "#observatory-freshness .observatory-live-dot") != []
    assert LazyHTML.query(fragment, "#observatory-resume svg") != []

    assert LazyHTML.query(
             fragment,
             "#observatory-logout-form[action='/observatory/logout'][method='post']"
           ) != []

    assert LazyHTML.query(
             fragment,
             "#observatory-logout-form input[name='_method'][value='delete']"
           ) != []

    assert LazyHTML.query(fragment, "#observatory-logout-form input[name='_csrf_token']") != []
    assert LazyHTML.query(fragment, "#observatory-logout-form button.btn-ghost") != []
    refute html =~ ~r/\b(admin|Pool|upstream|operator)\b/i
  end

  test "telemetry renders stacked facts and direct-labeled model rows" do
    html =
      render_component(&Telemetry.telemetry/1, %{
        overview: overview(),
        models: models(),
        window: "7d"
      })

    fragment = LazyHTML.from_fragment(html)

    assert LazyHTML.query(fragment, "#observatory-overview.observatory-card") != []
    assert LazyHTML.query(fragment, "#observatory-overview-facts") != []
    assert LazyHTML.query(fragment, "#observatory-fact-success") != []
    assert LazyHTML.query(fragment, "#observatory-success-minibar[role='progressbar']") != []
    assert LazyHTML.query(fragment, "#observatory-fact-cache") != []
    assert LazyHTML.query(fragment, "#observatory-fact-cost") != []
    assert LazyHTML.query(fragment, "#observatory-cost-settled") |> Enum.empty?()
    assert LazyHTML.query(fragment, "#observatory-fact-tokens") != []
    assert html =~ "42 requests"
    assert LazyHTML.query(fragment, "#observatory-fact-throughput") |> Enum.empty?()
    assert LazyHTML.query(fragment, "#observatory-fact-latency") |> Enum.empty?()
    assert LazyHTML.query(fragment, "#observatory-models") != []
    # the selected window trails the section title
    assert LazyHTML.query(fragment, "#observatory-models-title") |> LazyHTML.text() =~ "7d"
    assert LazyHTML.query(fragment, "[data-role='observatory-model-row']") |> Enum.count() == 3
    assert LazyHTML.query(fragment, "[data-role='observatory-model-bar']") |> Enum.count() == 3

    assert LazyHTML.query(fragment, "[data-role='observatory-model-bar'] .saved-reset-life-fill") !=
             []

    assert html =~ "alpha-model"
    assert html =~ "9,441 reqs"
    assert html =~ "78.5%"
    # tokens/cost split the amount (tinted) from the unit/currency (neutral)
    model_one = LazyHTML.query(fragment, "#observatory-model-1") |> LazyHTML.text()
    assert model_one =~ "1k tks"
    assert model_one =~ "$79.62"
    # the top model's value + bar carry its chart color inline; metrics are not mono
    assert LazyHTML.query(fragment, "#observatory-model-1 [style*='var(--color-primary)']") != []

    assert LazyHTML.query(fragment, "#observatory-model-1 .observatory-metric.font-mono")
           |> Enum.empty?()

    refute html =~ ~r/\b(admin|Pool|upstream|operator)\b/i
  end

  test "activity renders the Apex contract and matching table fallback" do
    html =
      render_component(&Activity.activity/1, %{
        traffic: traffic(),
        outcomes: outcomes(),
        window: "7d"
      })

    fragment = LazyHTML.from_fragment(html)

    assert LazyHTML.query(fragment, "#observatory-traffic") != []
    assert LazyHTML.query(fragment, "#observatory-traffic-heading") |> LazyHTML.text() =~ "7d"
    assert LazyHTML.query(fragment, "#observatory-traffic-mode-control[role='group']") != []

    assert LazyHTML.query(
             fragment,
             "#observatory-traffic-mode-interval[aria-pressed='true'][phx-click*='chart:set-mode']"
           ) != []

    assert LazyHTML.query(
             fragment,
             "#observatory-traffic-mode-cumulative[aria-pressed='false'][phx-click*='chart:set-mode']"
           ) != []

    assert LazyHTML.query(
             fragment,
             "#observatory-traffic-scroll[data-role='chart-scroll-region']"
           ) != []

    plot = "#observatory-traffic-plot[phx-hook='ApexTimeSeriesChart'][phx-update='ignore']"
    assert LazyHTML.query(fragment, plot) != []

    assert LazyHTML.query(
             fragment,
             "#{plot}[data-chart-stacked='true'][data-chart-safe-tooltip='true'][data-chart-zoom='false']"
           ) != []

    assert LazyHTML.query(
             fragment,
             "#{plot}[data-chart-unit='tokens'][data-chart-height='264'][data-chart-bar-radius='0']"
           ) != []

    assert LazyHTML.query(
             fragment,
             "#{plot}[data-chart-wheel-scroll='page'][data-chart-legend='always']"
           ) != []

    assert LazyHTML.query(
             fragment,
             "#observatory-traffic-interval-values[data-chart-source='interval']"
           ) != []

    assert LazyHTML.query(fragment, "#observatory-traffic-table-fallback") != []
    assert LazyHTML.query(fragment, "#observatory-traffic-fallback-total") != []
    assert LazyHTML.query(fragment, "#observatory-outcomes") != []

    assert LazyHTML.query(fragment, "#observatory-outcomes-sanitized") |> Enum.empty?()

    assert LazyHTML.query(fragment, "#observatory-outcomes-scroll.overflow-x-auto") != []
    assert LazyHTML.query(fragment, "#observatory-outcomes-table.table-sm") != []
    assert LazyHTML.query(fragment, "[data-role='observatory-outcome-row']") |> Enum.count() == 3
    assert LazyHTML.query(fragment, "[data-status='ok']") != []
    assert LazyHTML.query(fragment, "[data-status='warn']") != []
    assert LazyHTML.query(fragment, "[data-status='err']") != []

    assert LazyHTML.query(fragment, "[data-role='outcome-status'][class*='badge']")
           |> Enum.empty?()

    assert LazyHTML.query(fragment, "[data-role='outcome-status'].inline-flex.rounded-full") != []

    for {data_status, tone} <- [
          {"ok", "text-success"},
          {"warn", "text-warning"},
          {"err", "text-error"}
        ] do
      selector = "[data-role='outcome-status'][data-status='#{data_status}'][class*='#{tone}']"
      assert LazyHTML.query(fragment, selector) != []
    end

    refute html =~ "metadata only"
    assert html =~ "Recent outcomes"
    assert html =~ "Total: 80 tokens · $1.20"
    assert html =~ "Succeeded"
    assert html =~ "In progress"
    assert html =~ "Failed"
    refute LazyHTML.text(fragment) =~ ~r/\b(admin|Pool|upstream|operator)\b/i
  end

  defp overview do
    %{
      success_rate: %{
        measure: %{value: "90.0", unit: "%"},
        detail: "9 succeeded · 1 failed",
        minibar: 90.0
      },
      cache_rate: %{
        measure: %{value: "25.0", unit: "%"},
        detail: "20 of 80 input tokens served from cache"
      },
      cost: %{
        settled: %{label: "$1.25"},
        estimated: %{label: "$0.30"},
        confidence: "estimated",
        detail: "+ $0.30 estimated, awaiting settlement"
      },
      tokens: %{value: "130", detail: "42 requests"}
    }
  end

  defp models do
    for {label, color, percent, tokens, requests, cost} <- [
          {"alpha-model", "var(--color-primary)", 78.5, "1k", "9,441 reqs", "79.62"},
          {"beta-model", "var(--color-info)", 40.0, "400", "512 reqs", "12.40"},
          {"gamma-model", "var(--color-warning)", 10.0, "100", "88 reqs", "1.20"}
        ] do
      %{
        label: label,
        color: color,
        bar_percent: percent,
        token_label: tokens,
        share_label: "#{percent}%",
        requests_label: requests,
        cost_label: cost,
        shine_delay: 0.4
      }
    end
  end

  defp traffic do
    %{
      total_label: "130 tokens · $2.40",
      chart: %{
        categories: "[\"07-17 11:00\",\"07-17 12:00\"]",
        series:
          Jason.encode!([
            %{"name" => "alpha-model", "type" => "column", "data" => [45, 15]},
            %{"name" => "Cost", "type" => "line", "data" => [1.0, 0.5]}
          ]),
        units: "[\"tokens\",\"USD\"]",
        value_kinds: "[\"tokens\",\"usd\"]",
        yaxis: "[]",
        colors: "[\"var(--color-primary)\",\"var(--color-success)\"]"
      },
      fallback: %{
        rows: [
          %{label: "07-17 11:00", total: 60, total_label: "60", cost_label: "$0.90"},
          %{label: "07-17 12:00", total: 20, total_label: "20", cost_label: "$0.30"}
        ],
        total_label: "80 tokens · $1.20"
      }
    }
  end

  defp outcomes do
    [
      outcome("ok", :success, "alpha-model", "Succeeded"),
      outcome("warn", :warning, "beta-model", "In progress"),
      outcome("err", :error, "gamma-model", "Failed")
    ]
  end

  defp outcome(data_status, tone, model, label) do
    %{
      timestamp: "07-17 11:59",
      model: model,
      endpoint: "responses",
      status: %{label: label, tone: tone, data_status: data_status},
      tokens: %{label: "10"},
      cost: %{label: "$0.02"}
    }
  end
end
