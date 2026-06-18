defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting

  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true

  def quota_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="quota-health-chart"
      title="Quota health"
      description="Assignment-scoped quota evidence rendered as deterministic bars."
      count={quota_chart_count(@cockpit.charts.quota_health)}
    >
      <.quota_health_chart
        chart={@cockpit.charts.quota_health}
        datetime_preferences={@datetime_preferences}
      />
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true

  def request_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="request-health-chart"
      title="Request health"
      description="Target-upstream request outcomes over the last seven days."
      count={request_chart_count(@cockpit.charts.request_health)}
    >
      <.request_health_chart chart={@cockpit.charts.request_health} />
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true

  def pool_contribution_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="pool-contribution-chart"
      title="Pool contribution"
      description="Successful request share across assigned Pools."
      count={pool_contribution_count(@cockpit.charts.pool_contribution)}
    >
      <.pool_contribution_chart chart={@cockpit.charts.pool_contribution} />
    </AdminComponents.admin_surface>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp kpi_value(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/55">{@label}</p>
      <p class="mt-1 font-mono text-xl font-semibold tabular-nums text-base-content">{@value}</p>
    </div>
    """
  end

  attr :chart, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp quota_health_chart(assigns) do
    assigns =
      assign(
        assigns,
        :model,
        quota_health_chart_model(assigns.chart, assigns.datetime_preferences)
      )

    ~H"""
    <div class="grid gap-4 p-4">
      <p class="text-sm leading-6 text-base-content/70">
        {quota_chart_description(@chart)}
      </p>
      <p id="quota-health-chart-summary" class="sr-only" data-role="chart-sr-summary">
        {@model.summary}
      </p>
      <div class="grid gap-2 sm:grid-cols-3">
        <.kpi_value label="Routing usable" value={@chart.kpis.routing_usable_count} />
        <.kpi_value label="Stale or missing" value={@chart.kpis.stale_or_missing_count} />
        <.kpi_value label="Exhausted" value={@chart.kpis.exhausted_count} />
      </div>
      <div
        id="quota-health-chart-bars"
        data-chart="quota-health"
        data-chart-state={@chart.state}
        data-chart-total={@chart.kpis.assignment_count}
        data-chart-routing-usable={@chart.kpis.routing_usable_count}
        data-chart-degraded={@chart.degraded?}
        data-chart-colors={@model.colors}
        class="grid gap-3"
        role="list"
        aria-describedby="quota-health-chart-summary"
      >
        <article
          :for={item <- @model.items}
          id={"quota-health-chart-item-#{item.assignment_id}"}
          data-role="chart-bar-row"
          data-chart-value={item.bar_value}
          data-chart-state={item.state}
          class="grid gap-2 rounded-box border border-base-300 bg-base-200/45 p-3"
          role="listitem"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="min-w-0">
              <h3 class="break-words text-sm font-semibold text-base-content">
                {item.assignment_label}
              </h3>
              <p class="break-words text-xs leading-5 text-base-content/60">{item.pool_label}</p>
            </div>
            <span class={Formatting.assignment_status_class(item.state)}>{item.state_label}</span>
          </div>
          <progress
            id={"quota-health-chart-item-#{item.assignment_id}-bar"}
            class={quota_chart_progress_class(item.state)}
            value={item.bar_value}
            max="100"
            aria-label={item.aria_label}
          >
            {item.bar_label}
          </progress>
          <p class="text-xs leading-5 text-base-content/65">{item.supporting_label}</p>
        </article>
        <p :if={@model.items == []} class="text-sm leading-6 text-base-content/65">
          No Pool assignments are available for quota charting.
        </p>
      </div>
    </div>
    """
  end

  attr :chart, :map, required: true

  defp request_health_chart(assigns) do
    assigns = assign(assigns, :model, request_health_chart_model(assigns.chart))

    ~H"""
    <div class="grid gap-4 p-4">
      <p class="text-sm leading-6 text-base-content/70">
        {request_chart_description(@chart)}
      </p>
      <div class="grid gap-2 sm:grid-cols-4">
        <.kpi_value label="24h requests" value={@chart.kpis.total_requests_24h} />
        <.kpi_value label="24h failed" value={@chart.kpis.failed_requests_24h} />
        <.kpi_value label="Failure rate" value={@model.failure_rate_label} />
        <.kpi_value label="7d requests" value={@chart.kpis.total_requests_7d} />
      </div>
      <div
        id="request-health-chart-plot"
        class="admin-apex-bar-chart min-h-56 w-full"
        phx-hook="ApexTimeSeriesChart"
        phx-update="ignore"
        role="img"
        aria-labelledby="request-health-chart-title request-health-chart-summary"
        data-chart="request-health"
        data-chart-state={@chart.state}
        data-chart-total={@chart.kpis.total_requests_7d}
        data-chart-categories={@model.categories}
        data-chart-series={@model.series}
        data-chart-unit="requests"
        data-chart-units={@model.units}
        data-chart-yaxis={@model.yaxis}
        data-chart-height="220"
        data-chart-colors={@model.colors}
        data-chart-labels="true"
      >
      </div>
      <p id="request-health-chart-title" class="sr-only">Request health</p>
      <p id="request-health-chart-summary" class="sr-only" data-role="chart-sr-summary">
        {@model.summary}
      </p>
      <ul class="sr-only">
        <li :for={point <- @model.points}>
          {point.label}: {point.success_count} succeeded, {point.failure_count} failed, {point.total_count} total requests
        </li>
      </ul>
      <p class="text-xs leading-5 text-base-content/60">
        Failure rate {@model.failure_rate_label} across the last 24h; seven-day total {@model.total_label}.
      </p>
      <p class="text-xs leading-5 text-base-content/60">
        Request health, recent events, and contribution metrics refresh only when this cockpit is reloaded.
      </p>
    </div>
    """
  end

  attr :chart, :map, required: true

  defp pool_contribution_chart(assigns) do
    assigns = assign(assigns, :model, pool_contribution_chart_model(assigns.chart))

    ~H"""
    <div class="grid gap-4 p-4">
      <p class="text-sm leading-6 text-base-content/70">
        {pool_contribution_description(@chart)}
      </p>
      <p id="pool-contribution-chart-summary" class="sr-only" data-role="chart-sr-summary">
        {@model.summary}
      </p>
      <div class="grid gap-2 sm:grid-cols-4">
        <.kpi_value label="Assignments" value={@chart.kpis.assignment_count} />
        <.kpi_value label="Active" value={@chart.kpis.active_assignment_count} />
        <.kpi_value label="Disabled" value={@chart.kpis.disabled_assignment_count} />
        <.kpi_value label="7d successes" value={@chart.kpis.successful_requests_7d} />
      </div>
      <div
        id="pool-contribution-chart-bars"
        data-chart="pool-contribution"
        data-chart-state={@chart.state}
        data-chart-total={@chart.kpis.successful_requests_7d}
        data-chart-active={@chart.kpis.active_assignment_count}
        data-chart-disabled={@chart.kpis.disabled_assignment_count}
        data-chart-colors={@model.colors}
        class="grid gap-3"
        role="list"
        aria-describedby="pool-contribution-chart-summary"
      >
        <article
          :for={item <- @model.items}
          id={"pool-contribution-chart-item-#{item.assignment_id}"}
          data-role="chart-bar-row"
          data-chart-value={item.bar_value}
          data-chart-state={item.assignment_state}
          class="grid gap-2 rounded-box border border-base-300 bg-base-200/45 p-3"
          role="listitem"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="min-w-0">
              <h3 class="break-words text-sm font-semibold text-base-content">{item.pool_label}</h3>
              <p class="break-words text-xs leading-5 text-base-content/60">
                {item.assignment_label}
              </p>
            </div>
            <span class={Formatting.assignment_status_class(item.assignment_state)}>
              {item.assignment_state_label}
            </span>
          </div>
          <progress
            id={"pool-contribution-chart-item-#{item.assignment_id}-bar"}
            class={pool_contribution_progress_class(item.assignment_state)}
            value={item.bar_value}
            max="100"
            aria-label={item.aria_label}
          >
            {item.share_label}
          </progress>
          <p class="text-xs leading-5 text-base-content/65">{item.supporting_label}</p>
        </article>
        <p :if={@model.items == []} class="text-sm leading-6 text-base-content/65">
          No Pool assignments are available for contribution charting.
        </p>
      </div>
    </div>
    """
  end

  defp quota_chart_count(%{kpis: kpis}),
    do: Formatting.pluralize_count(kpis.assignment_count, "assignment", "assignments")

  defp quota_chart_description(%{state: "missing_evidence"}) do
    "Quota evidence is missing for this upstream assignment."
  end

  defp quota_chart_description(%{state: state, kpis: kpis}) do
    "Quota projection is #{Formatting.humanize_state(state)} across #{Formatting.pluralize_count(kpis.assignment_count, "assignment", "assignments")}."
  end

  defp request_chart_count(%{kpis: kpis}),
    do: Formatting.pluralize_count(kpis.total_requests_7d, "request", "requests")

  defp request_chart_description(%{state: "empty"}) do
    "No request traffic has reached this upstream in the last 7 days."
  end

  defp request_chart_description(%{state: state, kpis: kpis}) do
    "Request posture is #{Formatting.humanize_state(state)} with #{Formatting.pluralize_count(kpis.total_requests_7d, "request", "requests")} in the last 7 days."
  end

  defp pool_contribution_count(%{kpis: kpis}),
    do: Formatting.pluralize_count(kpis.assignment_count, "Pool", "Pools")

  defp pool_contribution_description(%{state: "no_successful_requests"}) do
    "No successful request contribution is recorded for assigned Pools in the last 7 days."
  end

  defp pool_contribution_description(%{state: state, kpis: kpis}) do
    "Pool contribution is #{Formatting.humanize_state(state)} with #{Formatting.pluralize_count(kpis.successful_requests_7d, "successful request", "successful requests")} in the last 7 days."
  end

  defp quota_health_chart_model(chart, datetime_preferences) do
    items = Enum.map(chart.items, &quota_health_chart_item(&1, datetime_preferences))

    %{
      items: items,
      colors:
        Jason.encode!(["var(--color-success)", "var(--color-warning)", "var(--color-error)"]),
      summary:
        "#{Formatting.pluralize_count(chart.kpis.assignment_count, "assignment", "assignments")}; #{chart.kpis.routing_usable_count} routing usable; #{chart.kpis.stale_or_missing_count} stale or missing; #{chart.kpis.exhausted_count} exhausted."
    }
  end

  defp quota_health_chart_item(item, datetime_preferences) do
    bar_value = chart_value(item.bar_value)

    item
    |> Map.put(:bar_value, chart_value_label(bar_value))
    |> Map.put(:bar_label, percent_label(bar_value))
    |> Map.put(:aria_label, quota_item_aria_label(item, bar_value))
    |> Map.put(:supporting_label, quota_item_supporting_label(item, datetime_preferences))
  end

  defp quota_item_aria_label(item, bar_value) do
    "#{item.assignment_label}: #{item.state_label}, #{percent_label(bar_value)} available"
  end

  defp quota_item_supporting_label(%{state: "missing_evidence"}, _datetime_preferences),
    do: "No current quota evidence"

  defp quota_item_supporting_label(
         %{routing_usable?: false, reset_at: %DateTime{} = reset_at} = item,
         datetime_preferences
       )
       when item.routing_readiness_state != "quota_blocked" do
    [
      item.routing_readiness_label,
      item.remaining_percent_value && "#{percent_label(item.remaining_percent_value)} remaining",
      item.used_percent_value && "#{percent_label(item.used_percent_value)} used",
      "resets #{Formatting.format_reset_at(reset_at, datetime_preferences)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp quota_item_supporting_label(
         %{reset_at: %DateTime{} = reset_at} = item,
         datetime_preferences
       ) do
    [
      item.remaining_percent_value && "#{percent_label(item.remaining_percent_value)} remaining",
      item.used_percent_value && "#{percent_label(item.used_percent_value)} used",
      "resets #{Formatting.format_reset_at(reset_at, datetime_preferences)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp quota_item_supporting_label(item, _datetime_preferences) do
    item.reason_codes
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "Quota pressure unknown"
      reason_codes -> "Reasons: #{Enum.join(reason_codes, ", ")}"
    end
  end

  defp request_health_chart_model(chart) do
    points = Enum.map(chart.items, &request_health_point/1)
    success_values = Enum.map(points, & &1.success_count)
    failure_values = Enum.map(points, & &1.failure_count)

    %{
      points: points,
      categories: Jason.encode!(Enum.map(points, & &1.label)),
      series:
        Jason.encode!([
          %{name: "Succeeded", type: "column", data: success_values},
          %{name: "Failed", type: "column", data: failure_values}
        ]),
      units: Jason.encode!(["requests", "failures"]),
      yaxis: Jason.encode!([%{seriesName: "Succeeded", title: "requests"}]),
      colors: Jason.encode!(["var(--color-success)", "var(--color-error)"]),
      failure_rate_label: rate_percent_label(chart.kpis.failure_rate_24h),
      total_label:
        Formatting.pluralize_count(chart.kpis.total_requests_7d, "request", "requests"),
      summary:
        "#{Formatting.pluralize_count(chart.kpis.total_requests_7d, "request", "requests")} over seven days; #{chart.kpis.total_requests_7d} total requests; #{chart.kpis.failed_requests_24h} failed in the last 24h; failure rate #{rate_percent_label(chart.kpis.failure_rate_24h)}."
    }
  end

  defp request_health_point(item) do
    %{
      label: chart_date_label(item.date),
      success_count: item.success_count,
      failure_count: item.failure_count,
      total_count: item.total_count
    }
  end

  defp pool_contribution_chart_model(chart) do
    items = Enum.map(chart.items, &pool_contribution_chart_item/1)

    %{
      items: items,
      colors: Jason.encode!(["var(--color-primary)", "var(--color-base-300)"]),
      summary:
        "#{Formatting.pluralize_count(chart.kpis.successful_requests_7d, "successful request", "successful requests")} over seven days across #{Formatting.pluralize_count(chart.kpis.assignment_count, "assignment", "assignments")}."
    }
  end

  defp pool_contribution_chart_item(item) do
    bar_value = chart_value(item.bar_value)
    success_count = item.successful_request_count_7d

    item
    |> Map.put(:bar_value, chart_value_label(bar_value))
    |> Map.put(:share_label, percent_label(bar_value))
    |> Map.put(
      :supporting_label,
      pool_contribution_supporting_label(item, success_count, bar_value)
    )
    |> Map.put(
      :aria_label,
      "#{item.pool_label}: #{Formatting.pluralize_count(success_count, "success", "successes")}, #{percent_label(bar_value)} share"
    )
  end

  defp pool_contribution_supporting_label(
         %{routing_usable?: false} = item,
         success_count,
         bar_value
       ) do
    "#{item.routing_readiness_label} · #{Formatting.pluralize_count(success_count, "success", "successes")} · #{percent_label(bar_value)} of target-upstream successes"
  end

  defp pool_contribution_supporting_label(_item, success_count, bar_value) do
    "#{Formatting.pluralize_count(success_count, "success", "successes")} · #{percent_label(bar_value)} of target-upstream successes"
  end

  defp quota_chart_progress_class("fresh"),
    do: "progress progress-success w-full admin-live-progress"

  defp quota_chart_progress_class("weekly_only"),
    do: "progress progress-info w-full admin-live-progress"

  defp quota_chart_progress_class("exhausted"),
    do: "progress progress-error w-full admin-live-progress"

  defp quota_chart_progress_class(_state),
    do: "progress progress-warning w-full admin-live-progress"

  defp pool_contribution_progress_class("active"),
    do: "progress progress-primary w-full admin-live-progress"

  defp pool_contribution_progress_class(_state),
    do: "progress w-full admin-live-progress"

  defp chart_value(nil), do: 0.0
  defp chart_value(value) when is_integer(value), do: chart_value(value * 1.0)
  defp chart_value(value) when is_float(value), do: value |> max(0.0) |> min(100.0)

  defp chart_value_label(value), do: value |> compact_float() |> String.replace_suffix(".0", "")

  defp rate_percent_label(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1) <> "%"

  defp rate_percent_label(value) when is_integer(value), do: rate_percent_label(value * 1.0)

  defp percent_label(nil), do: "0%"
  defp percent_label(value) when is_integer(value), do: percent_label(value * 1.0)
  defp percent_label(value) when is_float(value), do: "#{compact_float(value)}%"

  defp chart_date_label(
         <<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>
       ),
       do: month <> "-" <> day

  defp chart_date_label(date), do: to_string(date)

  defp compact_float(value) when is_float(value) do
    decimals = if value < 10 and value != Float.round(value, 0), do: 2, else: 1

    value
    |> Float.round(decimals)
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
