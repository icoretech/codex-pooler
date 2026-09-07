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
        class="modal-box w-full sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl"
      >
        <header class="border-b border-base-300 px-5 py-4">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">{@limit.label}</p>
          <h2 id={"#{@id}-title"} class="mt-1 text-xl font-bold text-base-content">
            Quota observations
          </h2>
          <p id={"#{@id}-description"} class="mt-1 text-xs leading-5 text-base-content/60">
            Latest retained values by source, not a complete history.
          </p>
        </header>
        <div class="grid gap-4 px-5 py-4">
          <p :if={Map.get(@limit, :burning_credits, false)} class="text-[11px] text-base-content/60">
            Credit balance in use. Source percentages below describe included quota.
          </p>
          <div>
            <p class="mb-3 flex justify-between gap-2 text-[11px] text-base-content/60">
              <span class="font-semibold uppercase tracking-wide">Latest observations</span><span>Newest first</span>
            </p>
            <ul class="grid divide-y divide-base-300" aria-label="Source observations, newest first">
              <li
                :for={observation <- @limit.observations}
                data-role="quota-observation"
                data-selected={to_string(observation.selected?)}
                class="grid gap-1.5 py-3 first:pt-0 last:pb-0 text-xs"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <strong>{observation.source}</strong>
                  <span class="tabular-nums font-medium" title="Remaining quota">{observation.remaining}</span>
                </div>
                <progress
                  data-role="quota-observation-progress"
                  class={["progress h-1.5 w-full", observation_tone(observation)]}
                  value={observation.remaining_value}
                  max="100"
                  aria-label={"#{observation.source}: #{observation.remaining} remaining, #{observation.freshness}#{if observation.selected?, do: ", selected for display", else: ", not selected"}"}
                >{observation.remaining}</progress>
                <div class="flex flex-wrap justify-between gap-x-3 gap-y-0.5 text-[11px] leading-4 text-base-content/60">
                  <span class="min-w-0 truncate" title={"observed #{observation.observed_at}"}>
                    observed {observation.observed_at}
                  </span>
                  <span>{observation.freshness}</span>
                </div>
              </li>
            </ul>
          </div>
        </div>
        <footer class="flex justify-end border-t border-base-300 px-5 py-2">
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
    |> JS.set_attribute({"open", ""}, to: "##{id}")
    |> JS.focus(to: "##{id}-close")
  end

  @spec close(String.t()) :: command()
  def close(id), do: JS.remove_attribute("open", to: "##{id}") |> JS.pop_focus()

  defp observation_tone(%{remaining_value: nil}),
    do: "progress-neutral admin-static-unknown-progress"

  defp observation_tone(%{selected?: false}),
    do: "progress-neutral opacity-50"

  defp observation_tone(%{remaining_value: value}) when value >= 70, do: "progress-success"
  defp observation_tone(%{remaining_value: value}) when value >= 30, do: "progress-warning"
  defp observation_tone(_observation), do: "progress-error"
end
