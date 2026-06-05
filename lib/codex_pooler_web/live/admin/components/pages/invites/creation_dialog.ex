defmodule CodexPoolerWeb.Admin.InviteCreationDialog do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :creating_invite, :boolean, required: true
  attr :invite_form, :any, required: true
  attr :invite_form_valid?, :boolean, required: true
  attr :last_invite, :any, required: true
  attr :mailer_configured?, :boolean, required: true
  attr :pool_options, :list, required: true

  def pool_invite_dialog(assigns) do
    ~H"""
    <dialog :if={@creating_invite} id="pool-invite-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Pool onboarding
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Create Pool invite</h2>
          <p class="mt-2 max-w-prose text-sm leading-6 text-base-content/70">
            Create a one-time invite link for a Codex account and assign it to a Pool.
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
                <p class="font-semibold">Pool onboarding invite ready</p>
                <p class="text-sm leading-6 text-base-content/70">
                  Share this URL now. It is shown only for this create result and is not stored in admin history.
                </p>
                <p :if={@last_invite.emailed?} id="pool-invite-email-status" class="text-sm">
                  Email sent to {@last_invite.invited_email}.
                </p>
                <p
                  :if={@last_invite.email_error?}
                  id="pool-invite-email-status"
                  class="text-sm text-warning"
                >
                  Email could not be sent. Share the URL manually.
                </p>
              </div>
            </div>

            <dl class="grid gap-3 text-sm sm:grid-cols-2">
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  Target Pool
                </dt>
                <dd id="pool-invite-target" class="mt-1 text-base-content">
                  {@last_invite.pool_name}
                </dd>
              </div>
              <div :if={@last_invite.invited_email}>
                <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  Codex Account Email
                </dt>
                <dd class="mt-1 break-all text-base-content">{@last_invite.invited_email}</dd>
              </div>
            </dl>

            <div class="min-w-0">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                Invite URL
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
                  data-copy-label="Copy"
                  data-copied-label="Copied"
                  aria-label="Copy invite URL"
                >
                  <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                  <span data-copy-label>Copy</span>
                </button>
              </div>
            </div>
          </div>
        </div>

        <AdminComponents.dialog_footer :if={@last_invite} id="pool-invite-ready-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="pool-invite-dialog-close"
              icon="hero-check"
              label="Done"
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
          class="grid gap-5 p-6"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <.input
              field={@invite_form[:pool_id]}
              type="select"
              label="Target Pool"
              options={@pool_options}
            />
            <.input
              field={@invite_form[:invited_email]}
              type="email"
              label="Codex Account Email"
              placeholder="codex-user@example.com"
              required
            />
            <div class="md:col-span-2">
              <.input
                field={@invite_form[:send_email]}
                type="checkbox"
                label="Send invite email"
                disabled={!@mailer_configured?}
              />
              <p
                :if={!@mailer_configured?}
                id="pool-invite-email-unavailable"
                class="-mt-1 text-xs text-base-content/60"
              >
                Email delivery is unavailable until SMTP is configured.
              </p>
            </div>
          </div>
        </.form>

        <AdminComponents.dialog_footer :if={!@last_invite} id="pool-invite-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="pool-invite-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_create_invite"
            />
            <AdminComponents.action_button
              id="pool-invite-submit"
              icon="hero-user-plus"
              label="Create Pool invite"
              type="submit"
              form="pool-invite-form"
              variant={:primary}
              disabled={!@invite_form_valid?}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_create_invite">close</button>
      </form>
    </dialog>
    """
  end
end
