defmodule CodexPoolerWeb.Observatory.Components.States do
  @moduledoc """
  Renders the loading, usage, refresh, connection, and error states for Observatory.
  """

  use Phoenix.Component

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.CoreComponents

  attr :state, :atom, required: true

  def state(%{state: state} = assigns)
      when state in [:loading, :empty, :stale, :error] do
    assigns = assign(assigns, :state_id, state_id(state))

    ~H"""
    <div
      id={"observatory-state-#{@state_id}"}
      class="observatory-state text-sm"
      data-state={@state_id}
      role="status"
      aria-live="polite"
    >
      <%= case @state do %>
        <% :loading -> %>
          <div
            data-role="loading-progress"
            class="flex items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-3"
          >
            <CoreComponents.icon
              name="hero-arrow-path"
              class="size-5 shrink-0 text-primary motion-safe:animate-spin"
            />
            <div class="grid gap-0.5">
              <p class="font-semibold text-base-content">Loading usage</p>
              <p class="text-base-content/65">Collecting the selected window.</p>
            </div>
          </div>
        <% :empty -> %>
          <AdminComponents.empty_state
            id="observatory-state-empty-anatomy"
            icon="hero-chart-bar-square"
            title="No usage in this window"
            description="Choose another window or wait for new usage to arrive."
          />
        <% :stale -> %>
          <div
            data-role="paused-state"
            class="flex items-start gap-3 rounded-box border border-warning/30 bg-warning/10 px-4 py-3"
          >
            <CoreComponents.icon name="hero-pause" class="mt-0.5 size-5 shrink-0 text-warning" />
            <div class="grid gap-0.5">
              <p class="font-semibold text-base-content">Updates paused</p>
              <p class="text-base-content/70">Showing the last known usage.</p>
            </div>
          </div>
        <% :error -> %>
          <div
            data-role="error-state"
            class="flex items-start gap-3 rounded-box border border-error/25 bg-error/10 px-4 py-3"
          >
            <CoreComponents.icon
              name="hero-exclamation-triangle"
              class="mt-0.5 size-5 shrink-0 text-error"
            />
            <div class="grid gap-0.5">
              <p class="font-semibold text-base-content">Usage is temporarily unavailable</p>
              <p class="text-base-content/70">Try again shortly.</p>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp state_id(state), do: Atom.to_string(state)
end
