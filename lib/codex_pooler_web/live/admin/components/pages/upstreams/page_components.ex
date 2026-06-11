defmodule CodexPoolerWeb.Admin.UpstreamPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountCard
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonDialog
  alias CodexPoolerWeb.Admin.UpstreamFilterForm

  @oauth_docs_url "https://docs.codex-pooler.com/operators/upstreams/#openai-oauth-upstream-linking"

  attr :pools, :list, required: true
  attr :pool_options, :list, required: true
  attr :dialog_pool_options, :list, required: true
  attr :filter_form, :any, required: true
  attr :filter_values, :map, required: true
  attr :pool_filter_options, :list, required: true
  attr :status_options, :list, required: true
  attr :auth_json_form, :any, required: true
  attr :auth_json_upload_limit_label, :string, required: true
  attr :importing_auth_json, :boolean, required: true
  attr :oauth_linking, :boolean, required: true
  attr :oauth_link_form, :any, required: true
  attr :oauth_link_flow, :map, default: nil
  attr :oauth_link_authorization_url, :string, default: nil
  attr :oauth_link_result, :map, default: nil
  attr :oauth_link_error, :map, default: nil
  attr :renaming_account, :map, default: nil
  attr :rename_account_form, :any, default: nil
  attr :upstream_accounts, :list, required: true
  attr :uploads, :map, required: true
  attr :datetime_preferences, :map, required: true

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

      <.oauth_link_dialog
        oauth_linking={@oauth_linking}
        oauth_link_form={@oauth_link_form}
        oauth_link_flow={@oauth_link_flow}
        oauth_link_authorization_url={@oauth_link_authorization_url}
        oauth_link_result={@oauth_link_result}
        oauth_link_error={@oauth_link_error}
        pool_options={@dialog_pool_options}
      />

      <.rename_account_dialog account={@renaming_account} form={@rename_account_form} />

      <section id="upstream-account-surface" class="grid min-w-0 gap-4">
        <.upstream_filter_form
          form={@filter_form}
          filter_values={@filter_values}
          pool_filter_options={@pool_filter_options}
          status_options={@status_options}
        />

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

        <.upstream_account_grid
          accounts={@upstream_accounts}
          datetime_preferences={@datetime_preferences}
        />
      </section>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :filter_values, :map, required: true
  attr :pool_filter_options, :list, required: true
  attr :status_options, :list, required: true

  defp upstream_filter_form(assigns) do
    ~H"""
    <AdminComponents.filter_form
      id="upstream-filter-form"
      for={@form}
      phx-change="filter"
      phx-submit="filter"
      autocomplete="off"
    >
      <.upstream_query_filter_input field={@form[:query]} />
      <PoolFilterComponents.pool_filter_dropdown
        id="upstream-pool-filter"
        hidden_id="filters_pool_id"
        selected_value={@filter_values["pool_id"]}
        options={@pool_filter_options}
      />
      <.upstream_status_filter_dropdown
        selected_value={@filter_values["status"]}
        selected={UpstreamFilterForm.selected_status_option(@filter_values["status"])}
        options={@status_options}
      />
    </AdminComponents.filter_form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp upstream_query_filter_input(assigns) do
    assigns = assign(assigns, :value, assigns.field.value || "")

    ~H"""
    <div id="upstream-query-filter" class="grid gap-2">
      <label for={@field.id} class="sr-only">Search</label>
      <div class="input input-bordered flex min-h-10 w-full items-center gap-2">
        <input
          id={@field.id}
          name={@field.name}
          type="text"
          value={@value}
          placeholder="Search upstreams..."
          class="peer grow text-sm font-normal"
        />
        <button
          id="upstream-filter-query-clear"
          type="button"
          class="grid size-6 shrink-0 place-items-center rounded-full text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary peer-placeholder-shown:hidden"
          phx-click="clear_upstream_query_filter"
          aria-label="Clear upstream search"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :selected_value, :string, required: true
  attr :selected, :map, required: true
  attr :options, :list, required: true

  defp upstream_status_filter_dropdown(assigns) do
    ~H"""
    <div class="grid gap-2">
      <input type="hidden" id="filters_status" name="filters[status]" value={@selected_value} />
      <details
        id="upstream-status-filter"
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "#upstream-status-filter")}
      >
        <summary
          data-role="status-filter-trigger"
          aria-label="Status"
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.status_filter_icon option={@selected} />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role="status-filter-menu"
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- @options}>
            <button
              type="button"
              phx-click="select_status_filter"
              phx-value-status={option.value}
              data-role="status-filter-option"
              data-status={option.value}
              class={["flex items-center gap-2 text-sm", option.value == @selected_value && "active"]}
              aria-current={option.value == @selected_value && "true"}
            >
              <.status_filter_icon option={option} />
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :option, :map, required: true

  defp status_filter_icon(assigns) do
    ~H"""
    <span class={status_filter_icon_class(@option.tone)}>
      <.icon name={@option.icon} class="size-4" />
    </span>
    """
  end

  defp status_filter_icon_class(:success), do: "shrink-0 text-success"
  defp status_filter_icon_class(:warning), do: "shrink-0 text-warning"
  defp status_filter_icon_class(:error), do: "shrink-0 text-error"
  defp status_filter_icon_class(:primary), do: "shrink-0 text-primary"
  defp status_filter_icon_class(_tone), do: "shrink-0 text-base-content/60"

  defp upstream_page_actions(assigns) do
    ~H"""
    <div
      id="upstream-page-actions"
      class="grid w-full grid-cols-1 gap-2 sm:grid-cols-3 lg:flex lg:w-auto lg:flex-wrap lg:justify-end"
    >
      <button
        id="upstream-page-oauth-link-action"
        type="button"
        phx-click="open_oauth_link"
        aria-label="Link OpenAI account"
        class="btn btn-primary min-w-0 justify-center gap-2 px-4"
      >
        <.icon name="hero-link" class="size-4 shrink-0" />
        <span class="truncate">Link</span>
      </button>
      <.link
        id="upstream-page-create-invite-action"
        navigate={~p"/admin/invites?create=1"}
        aria-label="Invite account"
        class="btn btn-secondary min-w-0 justify-center gap-2 px-4"
      >
        <.icon name="hero-user-plus" class="size-4 shrink-0" />
        <span class="truncate">Invite</span>
      </.link>
      <button
        id="upstream-page-import-auth-json-action"
        type="button"
        phx-click="open_import_auth_json"
        aria-label="Import auth.json"
        class="btn btn-accent min-w-0 justify-center gap-2 px-4"
      >
        <.icon name="hero-document-arrow-up" class="size-4 shrink-0" />
        <span class="truncate">Import</span>
      </button>
    </div>
    """
  end

  attr :oauth_linking, :boolean, required: true
  attr :oauth_link_form, :any, required: true
  attr :oauth_link_flow, :map, default: nil
  attr :oauth_link_authorization_url, :string, default: nil
  attr :oauth_link_result, :map, default: nil
  attr :oauth_link_error, :map, default: nil
  attr :pool_options, :list, required: true

  defp oauth_link_dialog(assigns) do
    assigns = assign(assigns, :oauth_docs_url, @oauth_docs_url)

    ~H"""
    <dialog :if={@oauth_linking} id="oauth-link-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            OpenAI OAuth
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Link OpenAI account</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Choose a Pool and finish the OpenAI authorization flow.
          </p>
        </div>

        <div class="grid gap-5 p-6">
          <div :if={@oauth_link_result} id="oauth-link-status" class="alert alert-success">
            <.icon name="hero-check-circle" class="size-5" />
            <span>{@oauth_link_result.message}</span>
          </div>

          <div :if={@oauth_link_error} id="oauth-link-error" class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>{@oauth_link_error.message}</span>
          </div>

          <.form
            :if={oauth_start_form_visible?(@oauth_link_flow)}
            id="oauth-link-start-form"
            for={@oauth_link_form}
            phx-change="validate_oauth_link_pool"
            autocomplete="off"
            class="grid gap-4"
          >
            <div class="grid gap-2">
              <label
                for="oauth_link_pool_id"
                class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
              >
                Pool
              </label>
              <select
                id="oauth_link_pool_id"
                name={@oauth_link_form[:pool_id].name}
                class="select select-bordered w-full"
              >
                <option value="" selected={oauth_pool_selected?(@oauth_link_form, "")}>
                  Select Pool
                </option>
                <option
                  :for={{label, value} <- @pool_options}
                  value={value}
                  selected={oauth_pool_selected?(@oauth_link_form, value)}
                >
                  {label}
                </option>
              </select>
            </div>

            <div class="flex flex-wrap gap-2">
              <AdminComponents.action_button
                id="oauth-link-browser-start"
                icon="hero-arrow-top-right-on-square"
                label="Browser"
                phx-click="start_oauth_browser"
                variant={:primary}
              />
              <AdminComponents.action_button
                id="oauth-link-device-start"
                icon="hero-device-phone-mobile"
                label="Device code"
                phx-click="start_oauth_device"
              />
            </div>
          </.form>

          <section
            :if={oauth_browser_flow?(@oauth_link_flow, @oauth_link_authorization_url)}
            class="grid gap-4 rounded-lg border border-base-300 bg-base-200/40 p-4"
          >
            <a
              id="oauth-link-authorization-url"
              href={@oauth_link_authorization_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-primary w-full justify-start gap-2 text-left"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 shrink-0" />
              <span class="truncate">Open OpenAI authorization</span>
            </a>

            <.form
              id="oauth-link-callback-form"
              for={@oauth_link_form}
              phx-submit="submit_oauth_callback"
              autocomplete="off"
              class="grid gap-3"
            >
              <div class="grid gap-2">
                <label
                  for="oauth-link-callback-url"
                  class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
                >
                  Callback URL
                </label>
                <input
                  id="oauth-link-callback-url"
                  name={@oauth_link_form[:callback_url].name}
                  value=""
                  type="url"
                  autocomplete="off"
                  class="input input-bordered w-full"
                />
              </div>

              <AdminComponents.action_button
                id="oauth-link-submit-callback"
                icon="hero-check"
                label="Complete link"
                type="submit"
                variant={:primary}
              />
            </.form>
          </section>

          <section
            :if={oauth_device_flow?(@oauth_link_flow)}
            id="oauth-link-device-code"
            class="grid gap-3 rounded-lg border border-base-300 bg-base-200/40 p-4"
          >
            <div class="grid gap-1">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Device code
              </p>
              <p class="font-mono text-2xl font-bold tracking-widest text-base-content">
                {@oauth_link_flow.device_user_code}
              </p>
            </div>
            <a
              :if={@oauth_link_flow.verification_uri}
              href={@oauth_link_flow.verification_uri}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-primary break-all text-sm"
            >
              {@oauth_link_flow.verification_uri}
            </a>
          </section>
        </div>

        <AdminComponents.dialog_footer id="oauth-link-dialog-footer" docs_url={@oauth_docs_url}>
          <:actions>
            <AdminComponents.action_button
              id="oauth-link-cancel"
              icon="hero-x-mark"
              label={oauth_dialog_dismiss_label(@oauth_link_flow)}
              phx-click="cancel_oauth_link"
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_oauth_link">close</button>
      </form>
    </dialog>
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
        </.form>

        <AdminComponents.dialog_footer id="rename-upstream-account-dialog-footer">
          <:actions>
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
              form="rename-upstream-account-form"
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

  attr :accounts, :list, required: true
  attr :datetime_preferences, :map, required: true

  defp upstream_account_grid(assigns) do
    ~H"""
    <div
      :if={@accounts != []}
      id="upstream-account-grid"
      class="grid min-w-0 items-start gap-3 lg:grid-cols-2 2xl:grid-cols-3 [@media(width>=112rem)]:grid-cols-4"
    >
      <UpstreamAccountCard.account_card
        :for={{account, account_index} <- Enum.with_index(@accounts)}
        account={account}
        account_index={account_index}
      />
    </div>
    """
  end

  defp oauth_start_form_visible?(nil), do: true
  defp oauth_start_form_visible?(%{status: "pending"}), do: false
  defp oauth_start_form_visible?(%{status: "completed"}), do: false
  defp oauth_start_form_visible?(_flow), do: true

  defp oauth_pool_selected?(form, value) do
    to_string(form[:pool_id].value || "") == to_string(value || "")
  end

  defp oauth_browser_flow?(%{flow_kind: "browser", status: "pending"}, authorization_url)
       when is_binary(authorization_url),
       do: String.trim(authorization_url) != ""

  defp oauth_browser_flow?(_flow, _authorization_url), do: false

  defp oauth_device_flow?(%{flow_kind: "device", status: "pending"}), do: true
  defp oauth_device_flow?(_flow), do: false

  defp oauth_dialog_dismiss_label(%{status: "completed"}), do: "Close"
  defp oauth_dialog_dismiss_label(_flow), do: "Cancel"
end
