defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Dialogs do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamOAuthDialogComponents

  @oauth_docs_url "https://docs.codex-pooler.com/operators/upstreams/#openai-oauth-upstream-linking"
  @upstream_actions_docs_url "https://docs.codex-pooler.com/operators/upstreams/#card-action-menu"

  def oauth_relink_dialog(assigns) do
    assigns = assign(assigns, :oauth_docs_url, @oauth_docs_url)

    ~H"""
    <dialog :if={@oauth_relinking} id="oauth-relink-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">
            OpenAI OAuth
          </p>
          <h2 class="mt-1 text-xl font-bold text-base-content sm:text-2xl">
            Relink OpenAI account
          </h2>
          <p class="mt-1.5 max-w-xl text-sm leading-5 text-base-content/65">
            {oauth_relink_description(@oauth_relink_flow)}
          </p>
        </div>

        <div class="grid gap-5 p-5 sm:p-6">
          <div
            :if={@oauth_relink_result && oauth_relink_pending?(@oauth_relink_flow)}
            id="oauth-relink-status"
            data-role="oauth-pending-status"
            role="status"
            class="flex items-center gap-2 text-sm font-medium text-base-content/65"
          >
            <.icon name="hero-clock" class="size-4 shrink-0 text-base-content/45" />
            <span>{@oauth_relink_result.message}</span>
          </div>

          <div
            :if={@oauth_relink_result && !oauth_relink_pending?(@oauth_relink_flow)}
            id="oauth-relink-status"
            class="alert alert-success"
          >
            <.icon name="hero-check-circle" class="size-5" />
            <span>{@oauth_relink_result.message}</span>
          </div>

          <div :if={@oauth_relink_error} id="oauth-relink-error" class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>{@oauth_relink_error.message}</span>
          </div>

          <div :if={oauth_relink_start_visible?(@oauth_relink_flow)} class="flex flex-wrap gap-2">
            <AdminComponents.action_button
              id="oauth-relink-browser-start"
              icon="hero-arrow-top-right-on-square"
              label="Browser"
              phx-click="start_oauth_relink_browser"
              variant={:primary}
            />
            <AdminComponents.action_button
              id="oauth-relink-device-start"
              icon="hero-device-phone-mobile"
              label="Device code"
              phx-click="start_oauth_relink_device"
            />
          </div>

          <section :if={
            oauth_relink_browser_flow?(@oauth_relink_flow, @oauth_relink_authorization_url)
          }>
            <UpstreamOAuthDialogComponents.browser_authorization_step
              id_prefix="oauth-relink"
              authorization_url={@oauth_relink_authorization_url}
              form={@oauth_relink_form}
              submit_event="submit_oauth_relink_callback"
              submit_label="Complete relink"
            />
          </section>

          <section
            :if={oauth_relink_device_flow?(@oauth_relink_flow)}
            id="oauth-relink-device-code"
            class="grid gap-3 rounded-lg border border-base-300 bg-base-200/40 p-4"
          >
            <div class="grid gap-1">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Device code
              </p>
              <div class="flex min-w-0 items-center gap-2">
                <p class="min-w-0 flex-1 break-all font-mono text-2xl font-bold tracking-widest text-base-content">
                  {@oauth_relink_flow.device_user_code}
                </p>
                <AdminComponents.clipboard_button
                  id="oauth-relink-device-code-copy"
                  copy_text={@oauth_relink_flow.device_user_code}
                  aria_label="Copy device code"
                />
              </div>
            </div>
            <div
              :if={@oauth_relink_flow.verification_uri}
              class="flex min-w-0 items-stretch gap-2"
            >
              <a
                id="oauth-relink-device-verification-url"
                href={@oauth_relink_flow.verification_uri}
                target="_blank"
                rel="noopener noreferrer"
                title={@oauth_relink_flow.verification_uri}
                class="link link-primary min-w-0 flex-1 self-center truncate text-sm"
              >
                {@oauth_relink_flow.verification_uri}
              </a>
              <AdminComponents.clipboard_button
                id="oauth-relink-device-verification-url-copy"
                copy_text={@oauth_relink_flow.verification_uri}
                aria_label="Copy device verification URL"
              />
            </div>
          </section>
        </div>

        <AdminComponents.dialog_footer id="oauth-relink-dialog-footer" docs_url={@oauth_docs_url}>
          <:actions>
            <AdminComponents.action_button
              id="oauth-relink-cancel"
              icon="hero-x-mark"
              label={oauth_relink_dialog_dismiss_label(@oauth_relink_flow)}
              phx-click="cancel_oauth_relink"
              variant={:ghost}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_oauth_relink">close</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, default: nil

  def rename_account_dialog(assigns) do
    assigns = assign(assigns, :upstream_actions_docs_url, @upstream_actions_docs_url)

    ~H"""
    <dialog :if={@account && @form} id="cockpit-rename-upstream-account-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">Upstream account</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Rename upstream account</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Update the operator label shown on this page and on the upstream account list.
          </p>
        </div>
        <.form
          id="cockpit-rename-upstream-account-form"
          for={@form}
          phx-change="validate_rename_account"
          phx-submit="rename_account"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@form[:account_label]} type="text" label="Label" required />
        </.form>

        <AdminComponents.dialog_footer
          id="cockpit-rename-upstream-account-dialog-footer"
          docs_url={@upstream_actions_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="cockpit-rename-upstream-account-cancel"
              label="Cancel"
              variant={:ghost}
              phx-click="cancel_rename_account"
            />
            <AdminComponents.action_button
              id="cockpit-rename-upstream-account-submit"
              icon="hero-pencil-square"
              label="Rename"
              type="submit"
              form="cockpit-rename-upstream-account-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_rename_account">close</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, required: true

  def delete_account_dialog(assigns) do
    assigns = assign(assigns, :upstream_actions_docs_url, @upstream_actions_docs_url)

    ~H"""
    <dialog :if={@account} id="cockpit-delete-upstream-account-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-error/30 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-error/20 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">
            Delete upstream account
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Confirm upstream account deletion</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Type the account label exactly to remove this upstream account from operator routing surfaces.
          </p>
        </div>
        <.form
          id="cockpit-delete-upstream-account-form"
          for={@form}
          phx-submit="confirm_delete_account"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@form[:id]} type="hidden" />
          <p class="rounded-box border border-base-300 bg-base-200/60 p-3 text-sm text-base-content/70">
            Confirmation label: <span class="font-semibold text-base-content">{@account.label}</span>
          </p>
          <.input
            field={@form[:confirmation_label]}
            type="text"
            label="Account label confirmation"
            placeholder={@account.label}
            required
          />
        </.form>

        <AdminComponents.dialog_footer
          id="cockpit-delete-upstream-account-dialog-footer"
          docs_url={@upstream_actions_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="cockpit-delete-upstream-account-cancel"
              label="Cancel"
              variant={:ghost}
              phx-click="cancel_delete_account"
            />
            <AdminComponents.action_button
              id="cockpit-delete-upstream-account-submit"
              icon="hero-trash"
              label="Delete"
              type="submit"
              form="cockpit-delete-upstream-account-form"
              variant={:danger}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_account">close</button>
      </form>
    </dialog>
    """
  end

  defp oauth_relink_start_visible?(nil), do: true
  defp oauth_relink_start_visible?(%{status: "pending"}), do: false
  defp oauth_relink_start_visible?(%{status: "completed"}), do: false
  defp oauth_relink_start_visible?(_flow), do: true

  defp oauth_relink_browser_flow?(%{flow_kind: "browser", status: "pending"}, authorization_url)
       when is_binary(authorization_url),
       do: String.trim(authorization_url) != ""

  defp oauth_relink_browser_flow?(_flow, _authorization_url), do: false

  defp oauth_relink_device_flow?(%{flow_kind: "device", status: "pending"}), do: true
  defp oauth_relink_device_flow?(_flow), do: false

  defp oauth_relink_pending?(%{status: "pending"}), do: true
  defp oauth_relink_pending?(_flow), do: false

  defp oauth_relink_description(%{flow_kind: "browser", status: "pending"}) do
    "Authorize with OpenAI, then paste the returned callback URL to finish."
  end

  defp oauth_relink_description(%{flow_kind: "device", status: "pending"}) do
    "Finish the device authorization in your browser. This dialog updates when the account is ready."
  end

  defp oauth_relink_description(_flow) do
    "Reconnect this upstream identity with browser authorization or a device code."
  end

  defp oauth_relink_dialog_dismiss_label(%{status: "completed"}), do: "Close"
  defp oauth_relink_dialog_dismiss_label(_flow), do: "Cancel"
end
