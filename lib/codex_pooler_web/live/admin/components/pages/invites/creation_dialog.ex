defmodule CodexPoolerWeb.Admin.InviteCreationDialog do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolInviteForm

  @invite_docs_url "https://www.codex-pooler.com/docs/operators/invites/#create-pool-invite"

  attr :creating_invite, :boolean, required: true
  attr :invite_form, :any, required: true
  attr :invite_form_valid?, :boolean, required: true
  attr :last_invite, :any, required: true
  attr :mailer_configured?, :boolean, required: true
  attr :pool_options, :list, required: true
  attr :invite_locale_source, :atom, default: :default

  @spec pool_invite_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def pool_invite_dialog(assigns) do
    assigns = assign(assigns, :invite_docs_url, @invite_docs_url)

    ~H"""
    <dialog
      :if={@creating_invite}
      id="pool-invite-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            {gettext("Pool invite")}
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">
            {invite_dialog_title(@last_invite)}
          </h2>
          <p class="mt-2 max-w-prose text-sm leading-6 text-base-content/70">
            {invite_dialog_description(@last_invite)}
          </p>
        </div>

        <div
          :if={@last_invite}
          id="pool-onboarding-invite-ready"
          class="grid gap-5 p-6 text-base-content"
        >
          <div id="pool-invite-created" class="grid gap-3">
            <div class="flex items-start gap-3 rounded-box border border-success/25 bg-success/10 p-4">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0 text-success" />
              <div class="grid min-w-0 gap-1">
                <p class="font-semibold">{gettext("Not stored in admin history")}</p>
                <p class="text-sm leading-6 text-base-content/70">
                  {gettext("This is the only place the URL appears. Nothing here can show it again.")}
                </p>
                <p :if={@last_invite.emailed?} id="pool-invite-email-status" class="text-sm">
                  {gettext("Email sent to %{email}.", email: @last_invite.invited_email)}
                </p>
                <p
                  :if={@last_invite.email_error?}
                  id="pool-invite-email-status"
                  class="text-sm text-warning"
                >
                  {gettext("Email could not be sent. Share the URL manually.")}
                </p>
              </div>
            </div>

            <dl class="grid gap-3 text-sm sm:grid-cols-2">
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  {gettext("Target Pool")}
                </dt>
                <dd id="pool-invite-target" class="mt-1 text-base-content">
                  {@last_invite.pool_name}
                </dd>
              </div>
              <div :if={@last_invite.invited_email}>
                <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  {gettext("Codex Account Email")}
                </dt>
                <dd class="mt-1 break-all text-base-content">{@last_invite.invited_email}</dd>
              </div>
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  {gettext("Invitation email language")}
                </dt>
                <dd id="pool-invite-created-locale" class="mt-1 text-base-content">
                  {PoolInviteForm.locale_label(@last_invite.locale)}
                </dd>
              </div>
            </dl>

            <div class="min-w-0">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                {gettext("Invite URL")}
              </p>
              <div id="pool-invite-url-control" class="join mt-1 flex w-full min-w-0 max-w-full">
                <code
                  id="invite-url"
                  class="join-item min-h-10 min-w-0 flex-1 overflow-hidden truncate whitespace-nowrap border border-base-300 bg-base-100 px-3 py-2.5 font-mono text-xs text-base-content"
                  title={@last_invite.url}
                >
                  {@last_invite.url}
                </code>
                <button
                  id="pool-invite-copy-url"
                  type="button"
                  class="btn btn-neutral join-item min-h-10 shrink-0"
                  phx-hook="ClipboardCopy"
                  phx-update="ignore"
                  data-copy-text={@last_invite.url}
                  data-copy-label={gettext("Copy")}
                  data-copied-label={gettext("Copied")}
                  aria-label={gettext("Copy invite URL")}
                >
                  <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                  <span data-copy-label>{gettext("Copy")}</span>
                </button>
              </div>
            </div>
          </div>
        </div>

        <AdminComponents.dialog_footer
          :if={@last_invite}
          id="pool-invite-ready-dialog-footer"
          docs_url={@invite_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="pool-invite-dialog-close"
              icon="hero-check"
              label={gettext("Done")}
              phx-click="cancel_create_invite"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>

        <.form
          :if={!@last_invite}
          id="pool-invite-form"
          for={@invite_form}
          phx-change="validate_invite"
          phx-submit="create_invite"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <.input
              field={@invite_form[:pool_id]}
              type="select"
              label={gettext("Target Pool")}
              options={@pool_options}
            />
            <.input
              field={@invite_form[:invited_email]}
              type="email"
              label={gettext("Codex Account Email")}
              placeholder="codex-user@example.com"
              required
            />
            <div class="md:col-span-2">
              <.input
                field={@invite_form[:locale]}
                type="select"
                label={gettext("Invitation email language")}
                options={PoolInviteForm.locale_options()}
              />
              <p id="pool-invite-locale-default" class="-mt-1 text-xs text-base-content/60">
                {PoolInviteForm.locale_hint(@invite_locale_source)}
              </p>
            </div>
            <div class="md:col-span-2">
              <.input
                field={@invite_form[:send_email]}
                type="checkbox"
                label={gettext("Send invite email")}
                disabled={!@mailer_configured?}
              />
              <p
                :if={!@mailer_configured?}
                id="pool-invite-email-unavailable"
                class="-mt-1 text-xs text-base-content/60"
              >
                {gettext("Email delivery is unavailable until SMTP is configured.")}
              </p>
            </div>
          </div>
        </.form>

        <AdminComponents.dialog_footer
          :if={!@last_invite}
          id="pool-invite-dialog-footer"
          docs_url={@invite_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="pool-invite-cancel"
              label={gettext("Cancel")}
              variant={:ghost}
              phx-click="cancel_create_invite"
            />
            <AdminComponents.action_button
              id="pool-invite-submit"
              icon="hero-user-plus"
              label={gettext("Create Pool invite")}
              type="submit"
              form="pool-invite-form"
              variant={:primary}
              disabled={!@invite_form_valid?}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form id="pool-invite-dialog-backdrop" method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_create_invite">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  # The header follows the flow: once `last_invite` exists the invite does too,
  # and "create a one-time invite link" describes a step already taken.
  defp invite_dialog_title(nil), do: gettext("Create Pool invite")
  defp invite_dialog_title(_invite), do: gettext("Share this link before closing")

  defp invite_dialog_description(nil),
    do: gettext("Create a one-time invite link for a Codex account and assign it to a Pool.")

  defp invite_dialog_description(invite),
    do: gettext("It is shown once, and joins %{pool}.", pool: invite.pool_name)
end
