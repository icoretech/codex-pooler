defmodule CodexPoolerWeb.Admin.StatsPresentation.Leaderboard do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format

  @limit 10
  @podium_place_base "grid min-w-0 text-center"
  @podium_step_base "grid place-items-center rounded-t-lg border border-b-0"
  @podium_medallion_base "grid size-9 shrink-0 place-items-center rounded-full border"

  attr :rows, :list, required: true
  attr :sort, :atom, default: :tokens, values: [:tokens, :cost]
  attr :window_label, :string, default: nil

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ranked = ranking(assigns.rows, assigns.sort)

    assigns =
      assigns
      |> assign(:podium, Enum.take(ranked, 3))
      |> assign(:runners, Enum.drop(ranked, 3))

    ~H"""
    <AdminComponents.admin_surface
      id="stats-api-key-surface"
      title="Leaderboard"
      description={description(@sort, @window_label)}
    >
      <:header_actions>
        <div
          class="flex shrink-0 items-center gap-0.5 rounded-full border border-base-300 bg-base-200/60 p-0.5"
          role="group"
          aria-label="Leaderboard ranking"
        >
          <button
            :for={{label, sort} <- [{"Tokens", :tokens}, {"Cost", :cost}]}
            id={"stats-api-key-sort-#{sort}"}
            type="button"
            class={sort_button_class(@sort == sort)}
            aria-pressed={to_string(@sort == sort)}
            phx-click="set_leaderboard_sort"
            phx-value-sort={Atom.to_string(sort)}
          >
            {label}
          </button>
        </div>
      </:header_actions>
      <p
        :if={@rows == []}
        id="stats-api-key-empty-card"
        class="px-4 py-10 text-center text-sm text-base-content/60"
      >
        No settled API-key usage for this period.
      </p>

      <ol
        :if={@podium != []}
        id="stats-api-key-podium"
        class="grid list-none gap-2 p-3 sm:grid-cols-3 sm:items-end sm:gap-3 sm:p-4"
      >
        <li
          :for={{row, index} <- Enum.with_index(@podium)}
          id={"stats-api-key-podium-#{index + 1}"}
          data-role="leaderboard-podium-place"
          class={place_class(index + 1)}
        >
          <div class="grid min-w-0 gap-2 p-3">
            <div class="flex justify-center">
              <span class={medallion_class(index + 1)} aria-label={"Rank #{index + 1}"}>
                <.icon :if={index == 0} name="hero-trophy" class="size-4" />
                <span :if={index > 0} class="text-sm font-bold">{index + 1}</span>
              </span>
            </div>
            <div class="min-w-0">
              <p class="truncate text-sm font-semibold text-base-content" title={row.display_name}>
                {row.display_name || "API key not recorded"}
              </p>
              <p class="truncate text-xs text-base-content/55">
                {row.pool_name || "Pool not available"}
              </p>
            </div>
            <p class="text-lg font-bold tabular-nums leading-tight text-base-content">
              <%= if @sort == :cost do %>
                {format_micros(row.settled_cost_micros)}
              <% else %>
                {Format.token_count(row.total_tokens)}
                <span class="text-xs font-medium text-base-content/50">tokens</span>
              <% end %>
            </p>
            <p class="text-[11px] leading-4 text-base-content/55">
              <%= if @sort == :cost do %>
                {Format.integer(row.requests)} req · {Format.token_count(row.total_tokens)} tokens
              <% else %>
                {Format.integer(row.requests)} req · {format_micros(row.settled_cost_micros)}
              <% end %>
            </p>
          </div>
          <div class={step_class(index + 1)} aria-hidden="true">
            <span class="text-2xl font-extrabold opacity-25">{index + 1}</span>
          </div>
          <div class="h-1.5 rounded-b-sm bg-base-300" aria-hidden="true"></div>
        </li>
      </ol>

      <ol
        :if={@runners != []}
        id="stats-api-key-runners"
        class="list-none divide-y divide-base-300/70 border-t border-base-300/70"
      >
        <li
          :for={{row, index} <- Enum.with_index(@runners)}
          id={"stats-api-key-row-#{index + 3}"}
          data-role="leaderboard-runner-row"
          class="flex min-w-0 items-center gap-3 px-4 py-2.5"
        >
          <span class="grid size-6 shrink-0 place-items-center rounded-full bg-base-200 font-mono text-xs font-semibold tabular-nums text-base-content/60">
            {index + 4}
          </span>
          <div class="grid min-w-0 flex-1">
            <p class="truncate text-sm font-medium text-base-content">
              {row.display_name || "API key not recorded"}
            </p>
            <p class="truncate text-xs text-base-content/50">
              {row.pool_name || "Pool not available"}
            </p>
          </div>
          <div class="grid shrink-0 justify-items-end gap-0.5 text-right">
            <span class="font-mono text-sm font-semibold tabular-nums text-base-content">
              <%= if @sort == :cost do %>
                {format_micros(row.settled_cost_micros)}
              <% else %>
                {Format.token_count(row.total_tokens)}
                <span class="text-[11px] font-medium text-base-content/50">tokens</span>
              <% end %>
            </span>
            <span class="text-[11px] leading-4 tabular-nums text-base-content/50">
              <%= if @sort == :cost do %>
                {Format.integer(row.requests)} req · {Format.token_count(row.total_tokens)} tokens
              <% else %>
                {Format.integer(row.requests)} req · {format_micros(row.settled_cost_micros)}
              <% end %>
            </span>
          </div>
        </li>
      </ol>
    </AdminComponents.admin_surface>
    """
  end

  defp ranking(rows, :cost),
    do:
      rows |> Enum.sort_by(&{&1.settled_cost_micros, &1.total_tokens}, :desc) |> Enum.take(@limit)

  defp ranking(rows, _sort),
    do: rows |> Enum.sort_by(&{&1.total_tokens, &1.requests}, :desc) |> Enum.take(@limit)

  defp description(sort, window_label),
    do: "#{ranking_label(sort)} in the #{window_label(window_label)}"

  defp ranking_label(:cost), do: "Top API keys by settled cost"
  defp ranking_label(_sort), do: "Top API keys by token usage"

  defp window_label(label) when is_binary(label) and label != "", do: String.downcase(label)
  defp window_label(_label), do: "selected window"

  defp sort_button_class(active?) do
    [
      "cursor-pointer rounded-full border px-2.5 py-0.5 text-[11px] font-medium leading-4 transition-colors",
      "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
      if(active?,
        do: "border-base-300 bg-base-100 text-base-content",
        else: "border-transparent text-base-content/45 hover:text-base-content/75"
      )
    ]
  end

  defp place_class(1), do: [@podium_place_base, "sm:order-2"]
  defp place_class(2), do: [@podium_place_base, "sm:order-1"]
  defp place_class(3), do: [@podium_place_base, "sm:order-3"]

  defp step_class(1),
    do: [
      @podium_step_base,
      "h-21 border-(--codex-rank-gold)/45 bg-(--codex-rank-gold)/10 text-(--codex-rank-gold-ink)"
    ]

  defp step_class(2),
    do: [@podium_step_base, "h-14 border-base-300 bg-base-content/4 text-base-content"]

  defp step_class(3),
    do: [
      @podium_step_base,
      "h-9 border-(--codex-rank-bronze)/45 bg-(--codex-rank-bronze)/8 text-(--codex-rank-bronze-ink)"
    ]

  defp medallion_class(1),
    do: [
      @podium_medallion_base,
      "border-(--codex-rank-gold)/60 bg-(--codex-rank-gold)/20 text-(--codex-rank-gold-ink)"
    ]

  defp medallion_class(2),
    do: [@podium_medallion_base, "border-base-300 bg-base-200 text-base-content/60"]

  defp medallion_class(3),
    do: [
      @podium_medallion_base,
      "border-(--codex-rank-bronze)/50 bg-(--codex-rank-bronze)/16 text-(--codex-rank-bronze-ink)"
    ]

  defp format_micros(nil), do: "unavailable"
  defp format_micros(micros), do: Format.money_precise_from_micros(micros)
end
