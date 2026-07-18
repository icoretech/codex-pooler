defmodule CodexPoolerWeb.Observatory.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.{Activity, Telemetry, Toolbar}

  test "toolbar exposes the safe principal, exact windows, freshness, pause, and logout" do
    html =
      render_component(&Toolbar.toolbar/1, %{
        display_name: "safe display",
        key_prefix: "safe-prefix",
        selected_window: "24h",
        freshness: "Updated 8s ago",
        paused: true
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "#observatory-toolbar") != []
    assert LazyHTML.query(fragment, "#observatory-toolbar-identity") != []
    assert LazyHTML.query(fragment, "#observatory-toolbar-controls") != []
    assert LazyHTML.query(fragment, "#observatory-wordmark") != []
    assert LazyHTML.query(fragment, "#observatory-key-chip") != []
    assert LazyHTML.query(fragment, "#observatory-principal") != []
    assert LazyHTML.query(fragment, "#observatory-key-prefix.hidden") != []
    assert html =~ "safe display"
    assert html =~ "safe-prefix"
    assert length(:binary.matches(html, "safe-prefix")) == 1
    assert html =~ "Updated 8s ago"
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
    html = render_component(&Telemetry.telemetry/1, %{overview: overview(), models: models()})
    fragment = LazyHTML.from_fragment(html)

    assert LazyHTML.query(fragment, "#observatory-overview.observatory-card") != []
    assert LazyHTML.query(fragment, "#observatory-overview-facts") != []
    assert LazyHTML.query(fragment, "#observatory-fact-success") != []
    assert LazyHTML.query(fragment, "#observatory-success-minibar[role='progressbar']") != []
    assert LazyHTML.query(fragment, "#observatory-fact-cache") != []
    assert LazyHTML.query(fragment, "#observatory-fact-cost") != []
    assert LazyHTML.query(fragment, "#observatory-cost-settled") != []
    assert LazyHTML.query(fragment, "#observatory-cost-settled[class*='badge']") |> Enum.empty?()

    assert LazyHTML.query(fragment, "#observatory-cost-settled[class*='text-base-content/70']") !=
             []

    assert LazyHTML.query(fragment, "#observatory-fact-throughput") != []
    assert LazyHTML.query(fragment, "#observatory-fact-latency") != []
    assert LazyHTML.query(fragment, "#observatory-models") != []
    assert LazyHTML.query(fragment, "[data-role='observatory-model-row']") |> Enum.count() == 3
    assert LazyHTML.query(fragment, "[data-role='observatory-model-bar']") |> Enum.count() == 3
    assert html =~ "alpha-model"
    assert html =~ "120 ms"
    refute html =~ ~r/\b(admin|Pool|upstream|operator)\b/i
  end

  test "activity renders the Apex contract and matching table fallback" do
    html = render_component(&Activity.activity/1, %{traffic: traffic(), outcomes: outcomes()})
    fragment = LazyHTML.from_fragment(html)

    assert LazyHTML.query(fragment, "#observatory-traffic") != []
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
             "#{plot}[data-chart-unit='tokens'][data-chart-height='232'][data-chart-bar-radius='0']"
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

    assert LazyHTML.query(fragment, "#observatory-outcomes-sanitized[class*='badge']")
           |> Enum.empty?()

    assert LazyHTML.query(
             fragment,
             "#observatory-outcomes-sanitized[class*='text-base-content/70']"
           ) != []

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

    assert html =~ "metadata only"
    assert html =~ "130 tokens / 10 requests"
    assert html =~ "Total: 80 tokens / 10 requests"
    assert html =~ "Succeeded"
    assert html =~ "In progress"
    assert html =~ "Failed"
    refute LazyHTML.text(fragment) =~ ~r/\b(admin|Pool|upstream|operator)\b/i
  end

  defp overview do
    %{
      success_rate: %{label: "90.0%", detail: "9 succeeded · 1 failed", minibar: 90.0},
      cache_rate: %{label: "25.0%", detail: "20 of 80 input tokens served from cache"},
      cost: %{
        settled: %{label: "$1.25"},
        estimated: %{label: "$0.30"},
        confidence: "estimated",
        detail: "+ $0.30 estimated, awaiting settlement"
      },
      throughput: %{p50_label: "125.5 tok/s"},
      latency: %{
        p50_label: "120 ms",
        p95_label: "200 ms",
        detail: "Mean 160 ms · slowest settled 240 ms"
      }
    }
  end

  defp models do
    for {label, tone, percent, tokens} <- [
          {"alpha-model", :primary, 100.0, "1k"},
          {"beta-model", :info, 40.0, "400"},
          {"gamma-model", :success, 10.0, "100"}
        ] do
      %{label: label, tone: tone, bar_percent: percent, token_label: tokens}
    end
  end

  defp traffic do
    %{
      total_label: "130 tokens / 10 requests",
      chart: %{
        categories: "[\"07-17 11:00\",\"07-17 12:00\"]",
        series:
          Jason.encode!([
            %{"name" => "Fresh input", "type" => "column", "data" => [45, 15]},
            %{"name" => "Cached input", "type" => "column", "data" => [15, 5]}
          ]),
        units: "[\"tokens\",\"tokens\"]",
        value_kinds: "[\"tokens\",\"tokens\"]",
        yaxis: "[]",
        colors: "[\"var(--color-primary)\",\"var(--color-info)\"]"
      },
      fallback: %{
        rows: [
          %{
            label: "07-17 11:00",
            fresh: 45,
            fresh_label: "45",
            cached: 15,
            cached_label: "15",
            total: 60,
            total_label: "60",
            requests: 6,
            requests_label: "6"
          },
          %{
            label: "07-17 12:00",
            fresh: 15,
            fresh_label: "15",
            cached: 5,
            cached_label: "5",
            total: 20,
            total_label: "20",
            requests: 4,
            requests_label: "4"
          }
        ],
        total_label: "80 tokens / 10 requests"
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
      latency: %{label: "120 ms"},
      tokens: %{label: "10"},
      cost: %{label: "$0.02"}
    }
  end
end
