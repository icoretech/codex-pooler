defmodule CodexPoolerWeb.Admin.StatsPresentation.TrafficDistribution do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.UpstreamNaming

  attr :rows, :list, required: true
  attr :scope_label, :string, required: true
  attr :window_label, :string, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-upstream-surface"
      title="Traffic distribution"
      description={description(@scope_label, @window_label)}
    >
      <ol
        :if={@rows != []}
        id="stats-upstream-lanes"
        class="list-none divide-y divide-base-300/70"
      >
        <li
          :for={{row, rank} <- Enum.with_index(@rows, 1)}
          id={"stats-upstream-lane-#{rank}"}
          data-role="upstream-traffic-lane"
          data-leader={(rank == 1 and row.requests > 0) && "true"}
          class={[
            "grid min-w-0 gap-3 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center",
            (rank == 1 and row.requests > 0) && "bg-primary/5"
          ]}
        >
          <div class="grid min-w-0 gap-2">
            <div class="flex min-w-0 items-baseline justify-between gap-3">
              <h3
                class="min-w-0 truncate text-sm font-semibold text-base-content"
                title={upstream_label(row)}
              >
                {upstream_label(row)}
              </h3>
              <span
                data-role="upstream-traffic-share"
                class={[
                  "shrink-0 text-xs font-semibold tabular-nums text-base-content/70",
                  (rank == 1 and row.requests > 0) && "text-primary"
                ]}
              >
                {format_share(row.traffic_share_percent)}
              </span>
            </div>
            <progress
              id={"stats-upstream-rail-#{rank}"}
              data-role="upstream-traffic-rail"
              class={[
                "progress h-1.5 w-full",
                (rank == 1 and row.requests > 0) && "progress-primary"
              ]}
              max="100"
              value={format_share_value(row.traffic_share_percent)}
              aria-label={"#{upstream_label(row)} traffic share"}
              aria-valuetext={"#{format_share(row.traffic_share_percent)} of accounted requests"}
            >
              {format_share(row.traffic_share_percent)}
            </progress>
          </div>

          <dl class="grid grid-cols-3 gap-3 text-right text-xs sm:min-w-64">
            <div class="min-w-0">
              <dt class="text-base-content/50">Requests</dt>
              <dd
                data-role="upstream-requests"
                class="truncate font-semibold tabular-nums text-base-content"
              >
                {Format.integer(row.requests)}
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="text-base-content/50">Tokens</dt>
              <dd
                data-role="upstream-tokens"
                class="truncate font-semibold tabular-nums text-base-content"
              >
                {Format.token_count(row.total_tokens)}
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="truncate text-base-content/50">Settled cost</dt>
              <dd
                data-role="upstream-settled-cost"
                class="truncate font-semibold tabular-nums text-base-content"
              >
                {format_micros(row.settled_cost_micros)}
              </dd>
            </div>
          </dl>
        </li>
      </ol>

      <div :if={@rows == []} class="p-4">
        <AdminComponents.empty_state
          id="stats-upstream-empty-state"
          title="No upstream identities"
          description="No upstream identities are visible in this scope."
          icon="hero-server-stack"
        />
      </div>
    </AdminComponents.admin_surface>
    """
  end

  defp description(scope_label, window_label),
    do:
      "Share of accounted requests across #{scope_label} in the #{String.downcase(window_label)}."

  defp upstream_label(row), do: UpstreamNaming.account_name(%{account_label: row.upstream_label})

  defp format_share(value), do: "#{format_share_value(value)}%"

  defp format_share_value(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp format_micros(nil), do: "unavailable"
  defp format_micros(micros), do: Format.money_precise_from_micros(micros)
end
