defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Dialogs do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamOAuthDialogComponents

  @oauth_docs_url "https://docs.codex-pooler.com/operators/upstreams/#openai-oauth-upstream-linking"
  @upstream_actions_docs_url "https://docs.codex-pooler.com/operators/upstreams/#card-action-menu"

  attr :account_label, :string, required: true
  attr :oauth_relinking, :boolean, required: true
  attr :oauth_relink_form, :any, required: true
  attr :oauth_relink_flow, :map, default: nil
  attr :oauth_relink_authorization_url, :string, default: nil
  attr :oauth_relink_result, :map, default: nil
  attr :oauth_relink_error, :map, default: nil
  attr :datetime_preferences, :map, default: %{}

  def oauth_relink_dialog(assigns) do
    assigns = assign(assigns, :oauth_docs_url, @oauth_docs_url)

    ~H"""
    <dialog
      :if={@oauth_relinking}
      id="oauth-relink-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">
            OpenAI OAuth
          </p>
          <h2 class="mt-1 text-xl font-bold text-base-content sm:text-2xl">
            {oauth_relink_title(@account_label, @oauth_relink_flow)}
          </h2>
          <p class="mt-1.5 max-w-xl text-sm leading-5 text-base-content/65">
            {oauth_relink_description(@oauth_relink_flow)}
          </p>
        </div>

        <div class="grid gap-5 p-5 sm:p-6">
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

          <UpstreamOAuthDialogComponents.method_doors
            :if={oauth_relink_start_visible?(@oauth_relink_flow)}
            id_prefix="oauth-relink"
            browser_event="start_oauth_relink_browser"
            device_event="start_oauth_relink_device"
          />

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

          <UpstreamOAuthDialogComponents.device_authorization_step
            :if={oauth_relink_device_flow?(@oauth_relink_flow)}
            id_prefix="oauth-relink"
            user_code={@oauth_relink_flow.device_user_code}
            verification_uri={@oauth_relink_flow.verification_uri}
            interval_seconds={Map.get(@oauth_relink_flow, :interval_seconds)}
            expires_at={Map.get(@oauth_relink_flow, :expires_at)}
            datetime_preferences={@datetime_preferences}
            status={oauth_relink_pending_status(@oauth_relink_result, @oauth_relink_flow)}
          />
        </div>

        <AdminComponents.dialog_footer id="oauth-relink-dialog-footer" docs_url={@oauth_docs_url}>
          <:actions>
            <AdminComponents.action_button
              id="oauth-relink-cancel"
              label={oauth_relink_dialog_dismiss_label(@oauth_relink_flow)}
              phx-click="cancel_oauth_relink"
              variant={:ghost}
            />
            <AdminComponents.action_button
              :if={oauth_relink_browser_flow?(@oauth_relink_flow, @oauth_relink_authorization_url)}
              id={UpstreamOAuthDialogComponents.callback_submit_id("oauth-relink")}
              icon="hero-check"
              label="Complete relink"
              type="submit"
              form={UpstreamOAuthDialogComponents.callback_form_id("oauth-relink")}
              variant={:primary}
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
    <dialog
      :if={@account && @form}
      id="cockpit-rename-upstream-account-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
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
          class="grid gap-5 p-5 sm:p-6"
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
    <dialog
      :if={@account}
      id="cockpit-delete-upstream-account-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">Upstream account</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Delete {@account.label}?</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            It stops serving traffic immediately and leaves every routing surface with it.
            This cannot be undone.
          </p>
        </div>
        <.form
          id="cockpit-delete-upstream-account-form"
          for={@form}
          phx-submit="confirm_delete_account"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
        >
          <.input field={@form[:id]} type="hidden" />
          <.input
            field={@form[:confirmation_label]}
            type="text"
            pattern={Regex.escape(@account.label)}
            placeholder={@account.label}
            required
          >
            <:label_content>
              Type <span class="font-semibold text-base-content">{@account.label}</span> to confirm
            </:label_content>
          </.input>
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

  # The pending message belongs to the running flow, so it renders inside that
  # flow's section instead of floating above the dialog body.
  defp oauth_relink_pending_status(%{message: message}, %{status: "pending"})
       when is_binary(message) and message != "",
       do: message

  defp oauth_relink_pending_status(_result, _flow), do: nil

  defp oauth_relink_pending?(%{status: "pending"}), do: true
  defp oauth_relink_pending?(_flow), do: false

  # Mirrors the link dialog: once the flow completes the header states the
  # outcome instead of repeating the instructions. This dialog needs no cockpit
  # link of its own - `OAuthRelinkWorkflow.complete/3` refreshes the page already
  # underneath it.
  defp oauth_relink_title(account_label, %{status: "completed"}),
    do: "#{account_label} reauthorized"

  defp oauth_relink_title(account_label, _flow), do: "Relink #{account_label}"

  defp oauth_relink_description(%{status: "completed"}) do
    "This page already shows the refreshed authorization."
  end

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
