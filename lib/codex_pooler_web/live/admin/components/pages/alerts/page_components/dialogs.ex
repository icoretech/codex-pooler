defmodule CodexPoolerWeb.Admin.AlertsPageComponents.Dialogs do
  @moduledoc """
  The two alert delete confirmations.

  They were written inline in `AlertsLive.render/1`, which is why they were the
  last two dialogs in the admin with no way to be reviewed next to the others:
  a dev gallery can render a function component, not a fragment of a LiveView.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :rule, :any, default: nil
  attr :form, :any, required: true

  @spec rule_delete_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def rule_delete_dialog(assigns) do
    ~H"""
    <dialog
      :if={@rule}
      id="alert-rule-delete-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">{gettext("Alert rule")}</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">{gettext("Delete %{name}?", name: @rule.display_name)}</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            {gettext("The condition stops being evaluated. Incidents it already raised stay available, and the rule can be created again later.")}
          </p>
        </div>

        <.form
          id="alert-rule-delete-form"
          for={@form}
          phx-submit="confirm_delete_rule"
          autocomplete="off"
        >
          <.input field={@form[:id]} type="hidden" />
        </.form>

        <AdminComponents.dialog_footer id="alert-rule-delete-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="alert-rule-delete-cancel"
              label={gettext("Cancel")}
              variant={:ghost}
              phx-click="cancel_delete_rule"
            />
            <AdminComponents.action_button
              id="alert-rule-delete-submit"
              icon="hero-trash"
              label={gettext("Delete")}
              type="submit"
              form="alert-rule-delete-form"
              variant={:danger}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_rule">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr :channel, :any, default: nil
  attr :form, :any, required: true

  @spec channel_delete_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def channel_delete_dialog(assigns) do
    ~H"""
    <dialog
      :if={@channel}
      id="alert-channel-delete-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">{gettext("Alert channel")}</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">{gettext("Delete %{name}?", name: @channel.display_name)}</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            {gettext("Rules pointing at it stop delivering there. Delivery attempts already made stay available.")}
          </p>
        </div>

        <.form
          id="alert-channel-delete-form"
          for={@form}
          phx-submit="confirm_delete_channel"
          autocomplete="off"
        >
          <.input field={@form[:id]} type="hidden" />
        </.form>

        <AdminComponents.dialog_footer id="alert-channel-delete-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="alert-channel-delete-cancel"
              label={gettext("Cancel")}
              variant={:ghost}
              phx-click="cancel_delete_channel"
            />
            <AdminComponents.action_button
              id="alert-channel-delete-submit"
              icon="hero-trash"
              label={gettext("Delete")}
              type="submit"
              form="alert-channel-delete-form"
              variant={:danger}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_channel">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end
end
