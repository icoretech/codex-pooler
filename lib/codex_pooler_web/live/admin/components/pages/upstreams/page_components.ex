defmodule CodexPoolerWeb.Admin.UpstreamPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountCard
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonDialog

  attr :pools, :list, required: true
  attr :pool_options, :list, required: true
  attr :dialog_pool_options, :list, required: true
  attr :auth_json_form, :any, required: true
  attr :auth_json_upload_limit_label, :string, required: true
  attr :importing_auth_json, :boolean, required: true
  attr :renaming_account, :map, default: nil
  attr :rename_account_form, :any, default: nil
  attr :upstream_accounts, :list, required: true
  attr :uploads, :map, required: true

  def upstreams_page(assigns) do
    ~H"""
    <section id="admin-upstreams-live" class="grid min-w-0 gap-6">
      <AdminComponents.page_header
        id="upstream-account-page-header"
        title="Upstreams"
        description="Import Codex auth.json, check readiness, and keep account access current."
      >
        <:actions>
          <AdminComponents.action_button
            :if={@pools == []}
            id="upstream-account-page-create-pool"
            icon="hero-server-stack"
            label="Create Pool"
            navigate={~p"/admin/pools"}
            size={:md}
            variant={:primary}
          />
          <.upstream_page_actions :if={@pools != []} />
        </:actions>
      </AdminComponents.page_header>

      <UpstreamAuthJsonDialog.auth_json_import_dialog
        auth_json_form={@auth_json_form}
        importing_auth_json={@importing_auth_json}
        pool_options={@dialog_pool_options}
        upload={@uploads.auth_json}
        upload_limit_label={@auth_json_upload_limit_label}
      />

      <.rename_account_dialog account={@renaming_account} form={@rename_account_form} />

      <section id="upstream-account-surface" class="grid min-w-0 gap-4">
        <AdminComponents.empty_state
          :if={@upstream_accounts == []}
          id="upstream-account-empty-state"
          title={if @pools == [], do: "No Pools Found", else: "No upstream accounts"}
          description={
            if @pools == [],
              do: "Create a Pool before importing upstream auth.json.",
              else: "Import upstream auth.json to connect an account to a Pool."
          }
          icon="hero-cloud-arrow-up"
        >
          <:actions :if={@pools == []}>
            <AdminComponents.action_button
              id="upstream-empty-create-pool"
              icon="hero-server-stack"
              label="Create Pool"
              navigate={~p"/admin/pools"}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.empty_state>

        <.upstream_account_grid accounts={@upstream_accounts} />
      </section>
    </section>
    """
  end

  defp upstream_page_actions(assigns) do
    ~H"""
    <div id="upstream-page-actions" class="join w-full sm:w-auto">
      <button
        id="upstream-page-import-auth-json-action"
        type="button"
        class="btn btn-primary join-item min-w-0 flex-1 gap-2 px-5 sm:flex-none"
        phx-click="open_import_auth_json"
      >
        <.icon name="hero-document-arrow-up" class="size-4 shrink-0" />
        <span class="truncate">Import auth.json</span>
      </button>
      <details class="dropdown dropdown-end join-item">
        <summary
          id="upstream-page-actions-menu"
          class="btn btn-primary btn-square join-item list-none"
          aria-label="More upstream actions"
        >
          <.icon name="hero-chevron-down" class="size-4" />
        </summary>
        <ul
          id="upstream-page-actions-menu-items"
          tabindex="0"
          class="menu dropdown-content z-20 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 text-left shadow-xl"
        >
          <li>
            <AdminComponents.dropdown_action_item
              id="upstream-page-create-invite-action"
              icon="hero-user-plus"
              label="Invite account"
              navigate={~p"/admin/invites?create=1"}
            />
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, default: nil

  defp rename_account_dialog(assigns) do
    ~H"""
    <dialog :if={@account && @form} id="rename-upstream-account-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Upstream account
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Rename upstream account</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Update the operator label shown for this upstream account.
          </p>
        </div>

        <.form
          id="rename-upstream-account-form"
          for={@form}
          phx-change="validate_rename_account"
          phx-submit="rename_account"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input
            field={@form[:account_label]}
            type="text"
            label="Label"
            placeholder="Account label"
            required
          />

          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="rename-upstream-account-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_rename_account"
            />
            <AdminComponents.action_button
              id="rename-upstream-account-submit"
              icon="hero-pencil-square"
              label="Rename"
              type="submit"
              variant={:primary}
            />
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_rename_account">close</button>
      </form>
    </dialog>
    """
  end

  attr :accounts, :list, required: true

  defp upstream_account_grid(assigns) do
    ~H"""
    <div
      :if={@accounts != []}
      id="upstream-account-grid"
      class="grid min-w-0 items-start gap-3 lg:grid-cols-2 2xl:grid-cols-3"
    >
      <UpstreamAccountCard.account_card
        :for={{account, account_index} <- Enum.with_index(@accounts)}
        account={account}
        account_index={account_index}
      />
    </div>
    """
  end
end
