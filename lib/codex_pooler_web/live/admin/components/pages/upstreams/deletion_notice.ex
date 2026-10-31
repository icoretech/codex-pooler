defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.DeletionNotice do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :paused, :boolean, default: false
  attr :surface, :atom, default: :card, values: [:card, :cockpit]

  @spec deletion_notice(map()) :: Phoenix.LiveView.Rendered.t()
  def deletion_notice(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="upstream-deletion-notice"
      data-updates-paused={to_string(@paused)}
      role="status"
      aria-live="polite"
      aria-atomic="true"
      class="grid justify-items-center gap-2 rounded-box border border-base-300 bg-base-100/95 p-4 text-center"
    >
      <.icon
        name={if @paused, do: "hero-pause-circle", else: "hero-arrow-path"}
        class={["size-8 text-base-content/60", !@paused && "admin-loading-icon"]}
      />
      <p class="text-base font-semibold leading-5 text-base-content">
        <span aria-hidden="true">{gettext("Deleting account")}</span><span class="sr-only">{gettext("Deleting account: %{label}", label: @label)}</span>
      </p>
      <p class="max-w-xs text-sm leading-5 text-base-content/70">
        {gettext("Cleanup continues in the background.")}
        <%= if @surface == :card do %>
          {gettext("This card disappears when complete.")}
        <% else %>
          {gettext("You will return to the account list when complete.")}
        <% end %>
      </p>
      <p :if={@paused} data-role="upstream-deletion-paused" class="text-xs leading-5 text-base-content/70">
        {gettext("Live updates are paused. Resume updates to see the current deletion status.")}
      </p>
    </div>
    """
  end
end
