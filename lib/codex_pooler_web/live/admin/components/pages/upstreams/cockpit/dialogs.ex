defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Dialogs do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @oauth_docs_url "https://docs.codex-pooler.com/operators/upstreams/#openai-oauth-upstream-linking"
  @upstream_actions_docs_url "https://docs.codex-pooler.com/operators/upstreams/#card-action-menu"

  def oauth_relink_dialog(assigns) do
    assigns = assign(assigns, :oauth_docs_url, @oauth_docs_url)

    ~H"""
    <dialog :if={@oauth_relinking} id="oauth-relink-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            OpenAI OAuth
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Relink OpenAI account</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Reconnect this upstream identity with browser authorization or a device code.
          </p>
        </div>

        <div class="grid gap-5 p-6">
          <div :if={@oauth_relink_result} id="oauth-relink-status" class="alert alert-success">
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

          <section
            :if={oauth_relink_browser_flow?(@oauth_relink_flow, @oauth_relink_authorization_url)}
            class="grid gap-4 rounded-lg border border-base-300 bg-base-200/40 p-4"
          >
            <a
              id="oauth-relink-authorization-url"
              href={@oauth_relink_authorization_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-primary w-full justify-start gap-2 text-left"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 shrink-0" />
              <span class="truncate">Open OpenAI authorization</span>
            </a>

            <.form
              id="oauth-relink-callback-form"
              for={@oauth_relink_form}
              phx-submit="submit_oauth_relink_callback"
              autocomplete="off"
              class="grid gap-3"
            >
              <div class="grid gap-2">
                <label
                  for="oauth-relink-callback-url"
                  class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
                >
                  Callback URL
                </label>
                <input
                  id="oauth-relink-callback-url"
                  name={@oauth_relink_form[:callback_url].name}
                  value=""
                  type="url"
                  autocomplete="off"
                  class="input input-bordered w-full"
                />
              </div>

              <AdminComponents.action_button
                id="oauth-relink-submit-callback"
                icon="hero-check"
                label="Complete relink"
                type="submit"
                variant={:primary}
              />
            </.form>
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
              <p class="font-mono text-2xl font-bold tracking-widest text-base-content">
                {@oauth_relink_flow.device_user_code}
              </p>
            </div>
            <a
              :if={@oauth_relink_flow.verification_uri}
              href={@oauth_relink_flow.verification_uri}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-primary break-all text-sm"
            >
              {@oauth_relink_flow.verification_uri}
            </a>
          </section>
        </div>

        <AdminComponents.dialog_footer id="oauth-relink-dialog-footer" docs_url={@oauth_docs_url}>
          <:actions>
            <AdminComponents.action_button
              id="oauth-relink-cancel"
              icon="hero-x-mark"
              label={oauth_relink_dialog_dismiss_label(@oauth_relink_flow)}
              phx-click="cancel_oauth_relink"
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
              icon="hero-x-mark"
              label="Cancel"
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
              icon="hero-x-mark"
              label="Cancel"
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

  defp oauth_relink_dialog_dismiss_label(%{status: "completed"}), do: "Close"
  defp oauth_relink_dialog_dismiss_label(_flow), do: "Cancel"
end
