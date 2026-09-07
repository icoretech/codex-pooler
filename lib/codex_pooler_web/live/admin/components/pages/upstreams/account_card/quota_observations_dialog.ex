defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaObservationsDialog do
  @moduledoc false
  use CodexPoolerWeb, :html

  @type command :: %Phoenix.LiveView.JS{}

  attr :id, :string, required: true
  attr :limit, :map, required: true

  def dialog(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      aria-labelledby={"#{@id}-title"}
      aria-describedby={"#{@id}-description"}
      aria-modal="true"
    >
      <.focus_wrap
        id={"#{@id}-panel"}
        class="modal-box flex max-h-[85dvh] w-full flex-col overflow-hidden sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl"
      >
        <header class="shrink-0 border-b border-base-300 px-5 py-4">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">{@limit.label}</p>
          <h2 id={"#{@id}-title"} class="mt-1 text-xl font-bold text-base-content">
            Quota evidence
          </h2>
          <p id={"#{@id}-description"} class="mt-1 text-xs leading-5 text-base-content/60">
            Retained quota state, not a history of provider responses. Values may be reconciled across multiple reports.
          </p>
        </header>
        <div class="grid min-h-0 gap-4 overflow-y-auto px-5 py-4">
          <p :if={Map.get(@limit, :burning_credits, false)} class="text-[11px] text-base-content/60">
            Credit balance in use. Source percentages below describe included quota.
          </p>
          <div>
            <p class="mb-3 flex justify-between gap-2 text-[11px] text-base-content/60">
              <span class="font-semibold uppercase tracking-wide">{length(@limit.observations)} retained records</span><span>Selected first, then newest</span>
            </p>
            <ul
              class="grid divide-y divide-base-300"
              aria-label="Retained quota evidence, selected first then newest"
            >
              <li
                :for={{observation, index} <- Enum.with_index(@limit.observations)}
                data-role="quota-observation"
                data-selected={to_string(observation.selected?)}
                class={["py-3 first:pt-0 last:pb-0 text-xs", index >= 5 && "hidden"]}
                data-extra-evidence={to_string(index >= 5)}
              >
                <details id={"#{@id}-observation-#{observation.key}"} data-preserve-open class="group">
                  <summary class="grid gap-1.5 cursor-pointer list-none rounded transition-colors hover:bg-base-200/50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary [&::-webkit-details-marker]:hidden">
                    <div class="flex items-baseline justify-between gap-3">
                      <p class="min-w-0 truncate text-sm font-semibold leading-5 text-base-content">
                        {observation.source}
                        <span
                          class="ml-0.5 text-xs font-normal text-base-content/55"
                          title="Original provider window slot, not selection priority"
                        >{observation.slot}</span>
                      </p>
                      <span
                        class={[
                          "shrink-0 text-xs font-medium leading-4 tabular-nums",
                          observation_percent_tone(observation)
                        ]}
                        title="Remaining quota"
                      ><span :if={observation.freshness == "stale"} class="font-normal">last known </span>{observation.remaining}</span>
                    </div>
                    <progress
                      data-role="quota-observation-progress"
                      class={["progress -mt-px h-1.5 w-full", observation_tone(observation)]}
                      value={observation.remaining_value}
                      max="100"
                      aria-label={"#{observation.source}: #{observation.remaining} remaining, #{observation.freshness}#{if observation.selected?, do: ", selected for display", else: ", not selected"}"}
                    >{observation.remaining}</progress>
                    <div class="flex flex-wrap justify-between gap-x-3 gap-y-0.5 text-[11px] leading-4 text-base-content/60">
                      <span
                        class="min-w-0 truncate"
                        title="Timestamp of the retained evidence; values may include earlier reports"
                      >
                        evidence as of {observation.observed_at}
                      </span>
                      <span>{observation.freshness}</span>
                    </div>
                  </summary>
                  <dl class="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 rounded bg-base-200/50 p-3 text-[11px] leading-4">
                    <div :for={{label, value} <- observation.details} class="grid min-w-0 gap-0.5">
                      <dt class="text-base-content/60">{label}</dt>
                      <dd class="min-w-0 break-words font-medium tabular-nums">{value}</dd>
                    </div>
                  </dl>
                </details>
              </li>
            </ul>
            <button
              :if={length(@limit.observations) > 5}
              id={"#{@id}-show-all"}
              type="button"
              class="btn btn-ghost btn-sm mt-2 w-full"
              phx-click={
                JS.remove_class("hidden", to: "##{@id} [data-extra-evidence='true']")
                |> JS.hide(to: "##{@id}-show-all")
              }
            >Show all {length(@limit.observations)} records</button>
          </div>
        </div>
        <footer class="flex shrink-0 justify-end border-t border-base-300 px-5 py-2">
          <button
            id={"#{@id}-close"}
            type="button"
            class="btn btn-ghost btn-sm"
            data-role="dialog-dismiss"
            phx-click={close(@id)}
          >Close</button>
        </footer>
      </.focus_wrap>
      <form method="dialog" class="modal-backdrop">
        <button id={"#{@id}-backdrop"} type="button" phx-click={close(@id)}>Close quota observations</button>
      </form>
    </dialog>
    """
  end

  @spec open(String.t()) :: command()
  def open(id) do
    JS.push_focus()
    |> JS.push("open_quota_observations")
    |> JS.set_attribute({"open", ""}, to: "##{id}")
    |> JS.focus(to: "##{id}-close")
  end

  @spec close(String.t()) :: command()
  def close(id),
    do:
      JS.remove_attribute("open", to: "##{id}")
      |> JS.pop_focus()
      |> JS.push("close_quota_observations")

  defp observation_tone(%{remaining_value: nil}),
    do: "progress-neutral admin-static-unknown-progress"

  defp observation_tone(%{selected?: false}),
    do:
      "text-base-content/50 bg-base-content/10 [&::-webkit-progress-value]:bg-current [&::-moz-progress-bar]:bg-current"

  defp observation_tone(%{remaining_value: value}) when value >= 70, do: "progress-success"
  defp observation_tone(%{remaining_value: value}) when value >= 30, do: "progress-warning"
  defp observation_tone(_observation), do: "progress-error"

  defp observation_percent_tone(observation) do
    case observation_tone(observation) do
      "progress-success" -> "text-success"
      "progress-warning" -> "text-warning"
      "progress-error" -> "text-error"
      _neutral -> "text-base-content/50"
    end
  end
end
