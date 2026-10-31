defmodule CodexPoolerWeb.Admin.UpstreamPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: ResetFormatting
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.Admin.UpstreamFilterForm
  alias CodexPoolerWeb.Admin.UpstreamOAuthDialogComponents
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AuthJsonDialog
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.ProviderCreditsComponents
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents
  alias CodexPoolerWeb.RelativeTime
  alias Phoenix.HTML.Form

  @oauth_docs_url "https://www.codex-pooler.com/docs/operators/upstreams/#openai-oauth-upstream-linking"
  @upstream_actions_docs_url "https://www.codex-pooler.com/docs/operators/upstreams/#card-action-menu"
  @saved_reset_docs_url "https://www.codex-pooler.com/docs/operators/upstreams/#saved-resets"

  attr :pools, :list, required: true
  attr :can_manage_pools?, :boolean, required: true
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
  attr :oauth_link_mode, :atom, default: :link, values: [:link, :relink]
  attr :oauth_link_target_account, :map, default: nil
  attr :oauth_link_form, :any, required: true
  attr :oauth_link_flow, :map, default: nil
  attr :oauth_link_authorization_url, :string, default: nil
  attr :oauth_link_result, :map, default: nil
  attr :oauth_link_error, :map, default: nil
  attr :renaming_account, :map, default: nil
  attr :rename_account_form, :any, default: nil
  attr :deleting_account, :map, default: nil
  attr :delete_account_form, :any, required: true
  attr :editing_saved_reset_policy, :map, default: nil
  attr :saved_reset_policy_form, :any, required: true
  attr :editing_provider_credits_policy, :map, default: nil
  attr :provider_credits_policy_form, :any, default: nil
  attr :confirming_saved_reset_redemption, :map, default: nil
  attr :account_panel_views, :map, required: true
  attr :upstream_accounts, :list, required: true
  attr :uploads, :map, required: true
  attr :datetime_preferences, :map, required: true

  @spec upstreams_page(map()) :: Phoenix.LiveView.Rendered.t()
  def upstreams_page(assigns) do
    ~H"""
    <section id="admin-upstreams-live" phx-hook="SavedResetConnection" class="grid min-w-0 gap-6">
      <AdminComponents.saved_reset_connection_notice id="saved-reset-connection-list" in_flight={Enum.any?(@upstream_accounts, &saved_reset_open?/1)} />
      <AdminComponents.page_header
        id="upstream-account-page-header"
        title={gettext("Upstreams")}
        description={gettext("The accounts your Pools serve from: token health, quota windows, and the saved-reset bank.")}
      >
        <:actions>
          <AdminComponents.action_button
            :if={@pools == []}
            id="upstream-account-page-create-pool"
            icon="hero-server-stack"
            label={gettext("Create Pool")}
            navigate={~p"/admin/pools"}
            size={:md}
            variant={:primary}
          />
          <.upstream_page_actions :if={@pools != []} filter_values={@filter_values} />
        </:actions>
      </AdminComponents.page_header>

      <AuthJsonDialog.auth_json_import_dialog
        auth_json_form={@auth_json_form}
        importing_auth_json={@importing_auth_json}
        pool_options={@dialog_pool_options}
        upload={@uploads.auth_json}
        upload_limit_label={@auth_json_upload_limit_label}
      />

      <.oauth_link_dialog
        oauth_linking={@oauth_linking}
        oauth_link_mode={@oauth_link_mode}
        oauth_link_target_account={@oauth_link_target_account}
        oauth_link_form={@oauth_link_form}
        oauth_link_flow={@oauth_link_flow}
        oauth_link_authorization_url={@oauth_link_authorization_url}
        oauth_link_result={@oauth_link_result}
        oauth_link_error={@oauth_link_error}
        pool_options={@dialog_pool_options}
        datetime_preferences={@datetime_preferences}
      />

      <.rename_account_dialog account={@renaming_account} form={@rename_account_form} />
      <.delete_account_dialog account={@deleting_account} form={@delete_account_form} />
      <.saved_reset_policy_dialog
        account={@editing_saved_reset_policy}
        form={@saved_reset_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        datetime_preferences={@datetime_preferences}
      />
      <.provider_credits_policy_dialog account={@editing_provider_credits_policy} account_label={@editing_provider_credits_policy && @editing_provider_credits_policy.label} form={@provider_credits_policy_form} />

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
          title={if @pools == [], do: gettext("No Pools Found"), else: gettext("No upstream accounts")}
          description={
            if @pools == [],
              do: gettext("Create a Pool before importing upstream auth.json."),
              else: gettext("Import upstream auth.json to connect an account to a Pool.")
          }
          icon="hero-cloud-arrow-up"
        >
          <:actions :if={@pools == []}>
            <AdminComponents.action_button
              id="upstream-empty-create-pool"
              icon="hero-server-stack"
              label={gettext("Create Pool")}
              navigate={~p"/admin/pools"}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.empty_state>

        <.upstream_account_grid
          accounts={@upstream_accounts}
          account_panel_views={@account_panel_views}
          datetime_preferences={@datetime_preferences}
          can_manage_pools?={@can_manage_pools?}
          filter_values={@filter_values}
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
      fields_class="upstream-filter-fields"
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
    <div id="upstream-query-filter" class="upstream-filter-query grid gap-2">
      <label for={@field.id} class="sr-only">{gettext("Search")}</label>
      <div class="input input-bordered flex min-h-10 w-full items-center gap-2">
        <input
          id={@field.id}
          name={@field.name}
          type="text"
          value={@value}
          placeholder={gettext("Search upstreams...")}
          class="peer grow text-sm font-normal"
        />
        <button
          id="upstream-filter-query-clear"
          type="button"
          class="grid size-6 shrink-0 place-items-center rounded-full text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary peer-placeholder-shown:hidden"
          phx-click="clear_upstream_query_filter"
          aria-label={gettext("Clear upstream search")}
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
          aria-label={gettext("Status")}
          class="select flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
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

  attr :filter_values, :map, required: true

  defp upstream_page_actions(assigns) do
    assigns =
      assign(
        assigns,
        :invite_path,
        upstreams_dialog_path(assigns.filter_values, %{"create_invite" => "1"})
      )

    ~H"""
    <div
      id="upstream-page-actions"
      class="grid w-full grid-cols-1 gap-2 sm:grid-cols-3 lg:flex lg:w-auto lg:flex-wrap lg:justify-end"
    >
      <button
        id="upstream-page-oauth-link-action"
        type="button"
        phx-click="open_oauth_link"
        aria-label={gettext("Link OpenAI account")}
        class="btn btn-primary min-w-0 justify-center gap-2 px-4"
      >
        <.icon name="hero-link" class="size-4 shrink-0" />
        <span class="truncate">{gettext("Link")}</span>
      </button>
      <.link
        id="upstream-page-create-invite-action"
        patch={@invite_path}
        aria-label={gettext("Invite account")}
        class="btn btn-secondary min-w-0 justify-center gap-2 px-4"
      >
        <.icon name="hero-user-plus" class="size-4 shrink-0" />
        <span class="truncate">{gettext("Invite")}</span>
      </.link>
      <button
        id="upstream-page-import-auth-json-action"
        type="button"
        phx-click="open_import_auth_json"
        aria-label={gettext("Import auth.json")}
        class="btn btn-accent min-w-0 justify-center gap-2 px-4"
      >
        <.icon name="hero-document-arrow-up" class="size-4 shrink-0" />
        <span class="truncate">{gettext("Import")}</span>
      </button>
    </div>
    """
  end

  attr :oauth_linking, :boolean, required: true
  attr :oauth_link_mode, :atom, default: :link, values: [:link, :relink]
  attr :oauth_link_target_account, :map, default: nil
  attr :oauth_link_form, :any, required: true
  attr :oauth_link_flow, :map, default: nil
  attr :oauth_link_authorization_url, :string, default: nil
  attr :oauth_link_result, :map, default: nil
  attr :oauth_link_error, :map, default: nil
  attr :pool_options, :list, required: true
  attr :datetime_preferences, :map, default: %{}

  @spec oauth_link_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def oauth_link_dialog(assigns) do
    assigns =
      assigns
      |> assign(:oauth_docs_url, @oauth_docs_url)
      |> assign(
        :oauth_dialog_title,
        oauth_dialog_title(
          assigns.oauth_link_mode,
          assigns.oauth_link_target_account,
          assigns.oauth_link_form,
          assigns.pool_options,
          assigns.oauth_link_flow
        )
      )
      |> assign(
        :oauth_dialog_description,
        oauth_dialog_description(
          assigns.oauth_link_mode,
          assigns.oauth_link_target_account,
          assigns.oauth_link_flow
        )
      )
      |> assign(
        :oauth_callback_submit_label,
        oauth_callback_submit_label(assigns.oauth_link_mode)
      )
      |> assign(:oauth_cockpit_path, oauth_cockpit_path(assigns.oauth_link_flow))

    ~H"""
    <dialog
      :if={@oauth_linking}
      id="oauth-link-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">
            OpenAI OAuth
          </p>
          <h2 class="mt-1 text-xl font-bold text-base-content sm:text-2xl">{@oauth_dialog_title}</h2>
          <p class="mt-1.5 max-w-xl text-sm leading-5 text-base-content/65">
            {@oauth_dialog_description}
          </p>
        </div>

        <div class="grid gap-5 p-5 sm:p-6">
          <div
            :if={@oauth_link_result && !oauth_pending_flow?(@oauth_link_flow)}
            id="oauth-link-status"
            class="alert alert-success"
          >
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
            <div :if={!oauth_relink_mode?(@oauth_link_mode)} class="grid gap-2">
              <label
                for="oauth_link_pool_id"
                class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
              >
                {gettext("Pool")}
              </label>
              <select
                id="oauth_link_pool_id"
                name={@oauth_link_form[:pool_id].name}
                class="select w-full"
              >
                <option value="" selected={oauth_pool_selected?(@oauth_link_form, "")}>
                  {gettext("Select Pool")}
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

            <UpstreamOAuthDialogComponents.method_doors
              id_prefix="oauth-link"
              browser_event="start_oauth_browser"
              device_event="start_oauth_device"
            />
          </.form>

          <section :if={oauth_browser_flow?(@oauth_link_flow, @oauth_link_authorization_url)}>
            <UpstreamOAuthDialogComponents.browser_authorization_step
              id_prefix="oauth-link"
              authorization_url={@oauth_link_authorization_url}
              form={@oauth_link_form}
              submit_event="submit_oauth_callback"
              submit_label={@oauth_callback_submit_label}
            />
          </section>

          <UpstreamOAuthDialogComponents.device_authorization_step
            :if={oauth_device_flow?(@oauth_link_flow)}
            id_prefix="oauth-link"
            user_code={@oauth_link_flow.device_user_code}
            verification_uri={@oauth_link_flow.verification_uri}
            interval_seconds={Map.get(@oauth_link_flow, :interval_seconds)}
            expires_at={Map.get(@oauth_link_flow, :expires_at)}
            datetime_preferences={@datetime_preferences}
            status={oauth_pending_status(@oauth_link_result, @oauth_link_flow)}
          />
        </div>

        <AdminComponents.dialog_footer id="oauth-link-dialog-footer" docs_url={@oauth_docs_url}>
          <:actions>
            <AdminComponents.action_button
              id="oauth-link-cancel"
              label={oauth_dialog_dismiss_label(@oauth_link_flow)}
              phx-click="cancel_oauth_link"
              variant={:ghost}
            />
            <AdminComponents.action_button
              :if={oauth_browser_flow?(@oauth_link_flow, @oauth_link_authorization_url)}
              id={UpstreamOAuthDialogComponents.callback_submit_id("oauth-link")}
              icon="hero-check"
              label={@oauth_callback_submit_label}
              type="submit"
              form={UpstreamOAuthDialogComponents.callback_form_id("oauth-link")}
              variant={:primary}
            />
            <AdminComponents.action_button
              :if={@oauth_cockpit_path}
              id="oauth-link-open-cockpit"
              icon="hero-cloud-arrow-up"
              label={gettext("Open cockpit")}
              navigate={@oauth_cockpit_path}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_oauth_link">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, default: nil

  @spec rename_account_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def rename_account_dialog(assigns) do
    assigns = assign(assigns, :upstream_actions_docs_url, @upstream_actions_docs_url)

    ~H"""
    <dialog
      :if={@account && @form}
      id="rename-upstream-account-dialog"
      aria-labelledby="rename-upstream-account-dialog-title rename-upstream-account-dialog-eyebrow"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p id="rename-upstream-account-dialog-eyebrow" class="break-words text-xs font-semibold uppercase tracking-wide text-primary">
            {gettext("Upstream account · %{label}", label: @account.label)}
          </p>
          <h2 id="rename-upstream-account-dialog-title" class="mt-1 text-2xl font-bold text-base-content">{gettext("Rename upstream account")}</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            {gettext("Update the operator label shown for this upstream account.")}
          </p>
        </div>

        <.form
          id="rename-upstream-account-form"
          for={@form}
          phx-change="validate_rename_account"
          phx-submit="rename_account"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
        >
          <.input
            field={@form[:account_label]}
            type="text"
            label={gettext("Label")}
            placeholder={gettext("Account label")}
            required
          />
        </.form>

        <AdminComponents.dialog_footer
          id="rename-upstream-account-dialog-footer"
          docs_url={@upstream_actions_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="rename-upstream-account-cancel"
              label={gettext("Cancel")}
              variant={:ghost}
              phx-click="cancel_rename_account"
            />
            <AdminComponents.action_button
              id="rename-upstream-account-submit"
              icon="hero-pencil-square"
              label={gettext("Rename")}
              type="submit"
              form="rename-upstream-account-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_rename_account">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, required: true

  @spec delete_account_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_account_dialog(assigns) do
    assigns = assign(assigns, :upstream_actions_docs_url, @upstream_actions_docs_url)

    ~H"""
    <dialog
      :if={@account}
      id="delete-upstream-account-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">{gettext("Upstream account")}</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">{gettext("Delete %{label}?", label: @account.label)}</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            {gettext("This permanently removes the account, credentials, quotas, Pool assignments, and account-specific statistics from the database. Shared request accounting remains without an account association. This cannot be undone.")}
          </p>
        </div>
        <.form
          id="delete-upstream-account-form"
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
              <span class="font-semibold text-base-content">{gettext("Type %{label} to confirm", label: @account.label)}</span>
            </:label_content>
          </.input>
        </.form>

        <AdminComponents.dialog_footer
          id="delete-upstream-account-dialog-footer"
          docs_url={@upstream_actions_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="delete-upstream-account-cancel"
              label={gettext("Cancel")}
              variant={:ghost}
              phx-click="cancel_delete_account"
            />
            <AdminComponents.action_button
              id="delete-upstream-account-submit"
              icon="hero-trash"
              label={gettext("Delete")}
              type="submit"
              form="delete-upstream-account-form"
              variant={:danger}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_account">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, default: nil

  attr :account_label, :string, required: true

  @spec provider_credits_policy_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_credits_policy_dialog(assigns) do
    ~H"""
    <dialog :if={@account && @form} id="provider-credits-policy-dialog" class="modal modal-bottom overflow-x-hidden sm:modal-middle" aria-labelledby="provider-credits-policy-dialog-title provider-credits-policy-dialog-eyebrow" aria-modal="true" phx-window-keydown="cancel_provider_credits_policy" phx-key="escape" phx-remove={JS.pop_focus()} open>
      <.focus_wrap id="provider-credits-policy-dialog-panel" class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl" phx-mounted={JS.focus(to: "#provider-credits-enabled")}>
        <div class="border-b border-base-300 px-5 py-4">
          <p id="provider-credits-policy-dialog-eyebrow" class="break-words text-xs font-semibold uppercase tracking-wide text-primary">{gettext("Upstream account · %{label}", label: @account_label)}</p>
          <h2 id="provider-credits-policy-dialog-title" class="mt-1 text-xl font-bold text-base-content">{gettext("Provider credits")}</h2>
          <p class="mt-1 text-xs leading-5 text-base-content/60">{gettext("Balance and admission policy for every Pool using this upstream.")}</p>
        </div>
        <div class="grid gap-4 p-5">
          <ProviderCreditsComponents.provider_credits_policy_form form={@form} />
          <details :if={Map.has_key?(@account, :provider_credits_summary)} id="provider-credits-observation-details" class="group border-t border-base-300 pt-4" data-preserve-open>
            <summary class="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-semibold text-base-content transition-colors hover:bg-base-200/50 [&::-webkit-details-marker]:hidden">
              {gettext("Balance and availability")} <.icon name="hero-chevron-right" class="size-4 text-base-content/50 transition-transform group-open:rotate-90" />
            </summary>
            <div class="pt-4">
              <ProviderCreditsComponents.provider_credits_details summary={@account.provider_credits_summary} />
            </div>
          </details>
        </div>
        <AdminComponents.dialog_footer id="provider-credits-policy-dialog-footer">
          <:actions>
            <AdminComponents.action_button id="provider-credits-policy-cancel" label={gettext("Cancel")} variant={:ghost} phx-click="cancel_provider_credits_policy" />
            <AdminComponents.action_button id="provider-credits-save" label={gettext("Save policy")} icon="hero-check" type="submit" form="provider-credits-policy-form" variant={:primary} phx-disable-with={gettext("Saving…")} />
          </:actions>
        </AdminComponents.dialog_footer>
      </.focus_wrap>
      <form method="dialog" class="modal-backdrop">
        <button id="provider-credits-policy-backdrop" type="button" phx-click="cancel_provider_credits_policy">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, default: nil
  attr :confirming_saved_reset_redemption, :map, default: nil
  attr :datetime_preferences, :map, required: true

  @spec saved_reset_policy_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def saved_reset_policy_dialog(assigns) do
    assigns =
      assigns
      |> assign(:saved_reset_docs_url, @saved_reset_docs_url)
      |> assign_saved_reset_summary()

    ~H"""
    <dialog
      :if={@account && @form}
      id="saved-reset-policy-dialog"
      aria-labelledby="saved-reset-policy-dialog-title saved-reset-policy-dialog-eyebrow"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div
        id="saved-reset-policy-dialog-panel"
        class="modal-box sm:max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl"
      >
        <div class="border-b border-base-300 px-5 py-4">
          <p id="saved-reset-policy-dialog-eyebrow" class="break-words text-xs font-semibold uppercase tracking-wide text-primary">
            {gettext("Codex saved resets · %{label}", label: @account.label)}
          </p>
          <h2 id="saved-reset-policy-dialog-title" class="mt-1 text-xl font-bold text-base-content">{gettext("Saved reset bank")}</h2>
          <p class="mt-1 text-xs leading-5 text-base-content/60">
            {gettext("Account-level quota recovery capacity: spent automatically by policy or through one queued manual attempt.")}
          </p>
        </div>

        <AdminComponents.saved_reset_connection_notice id="saved-reset-connection-bank" class="border-b border-base-300 px-5 py-3" in_flight={saved_reset_open?(@account)} />
        <.form
          id="saved-reset-policy-form"
          data-saved-reset-form
          data-saved-reset-identity={@account.identity.id}
          for={@form}
          phx-change="validate_saved_reset_policy"
          phx-submit="save_saved_reset_policy"
          autocomplete="off"
        >
          <div id="saved-reset-redemption-control" class="grid gap-3 px-5 py-4">
            <div class="flex flex-wrap items-center gap-3.5">
              <span
                id="saved-reset-bank-count"
                class="text-[15px] font-semibold tabular-nums text-(--color-reset-bank)"
              >
                ×{@bank_count}
              </span>
              <span
                id="saved-reset-bank-meter"
                role="meter"
                aria-valuenow={min(@bank_count, 5)}
                aria-valuemin="0"
                aria-valuemax="5"
                aria-label={ngettext("%{count} saved reset", "%{count} saved resets", @bank_count)}
                class="flex w-24 items-center gap-1"
              >
                <span
                  :for={segment <- 1..5}
                  class={[
                    "h-1.5 flex-1 rounded-full",
                    if(segment <= min(@bank_count, 5),
                      do: "bg-(--color-reset-bank)/80",
                      else: "bg-base-300/70"
                    )
                  ]}
                ></span>
              </span>
              <span
                :if={@next_expires_in}
                id="saved-reset-next-expiry"
                class="inline-flex items-center gap-1 text-xs leading-4 text-base-content/60"
                title={@account.saved_resets.next_expires_title}
              >
                <.icon name="hero-clock" class="size-3 shrink-0" />
                <span>{gettext("next expires in %{duration}", duration: @next_expires_in)}</span>
              </span>
              <span class="ml-auto flex items-center gap-2.5">
                <label
                  id="saved-reset-policy-auto-redeem-control"
                  for="saved-reset-policy-auto-redeem-enabled"
                  class="flex cursor-pointer items-center gap-2"
                >
                  <span class="text-xs font-medium text-base-content/60">{gettext("Auto redeem")}</span>
                  <input
                    type="hidden"
                    name="saved_reset_policy[auto_redeem_enabled]"
                    value="false"
                  />
                  <input
                    id="saved-reset-policy-auto-redeem-enabled"
                    type="checkbox"
                    name="saved_reset_policy[auto_redeem_enabled]"
                    value="true"
                    checked={form_checkbox_checked?(@form[:auto_redeem_enabled])}
                    class="toggle toggle-primary toggle-md shrink-0"
                  />
                </label>
                <button
                  :if={
                    !confirming_saved_reset_redemption?(
                      @confirming_saved_reset_redemption,
                      @account.identity.id
                    )
                  }
                  id="saved-reset-redemption-action"
                  data-role="saved-reset-redemption-action"
                  data-saved-reset-action="open-redemption"
                  data-server-disabled={to_string(!@account.saved_reset_redemption_action.available?)}
                  type="button"
                  class="btn btn-secondary btn-sm gap-2"
                  phx-click="open_saved_reset_redemption_confirmation"
                  phx-value-id={@account.identity.id}
                  disabled={!@account.saved_reset_redemption_action.available?}
                  title={saved_reset_redemption_title(@account.saved_reset_redemption_action)}
                >
                  <.icon name="hero-bolt" class="size-4" />
                  <span>{gettext("Redeem")}</span>
                </button>
              </span>
            </div>
            <AdminComponents.saved_reset_confirmation
              :if={
                confirming_saved_reset_redemption?(
                  @confirming_saved_reset_redemption,
                  @account.identity.id
                )
              }
              id="saved-reset-redemption-confirmation"
              identity_id={@account.identity.id}
              surface={:bank}
              confirm_id="saved-reset-redemption-confirm"
              cancel_id="saved-reset-redemption-cancel"
              disabled={!@account.saved_reset_redemption_action.available?}
            />
            <AdminComponents.saved_reset_operation
              identity_id={@account.identity.id}
              surface={:bank}
              operation={@account.saved_reset_operation}
              refreshing={Map.get(@account, :saved_reset_status_refreshing?, false)}
            />
            <%!-- A status hold is already explained by the receipt above; the
            line names the account or bank reason the receipt cannot. --%>
            <p
              :if={
                !@account.saved_reset_redemption_action.available? &&
                  @account.saved_reset_redemption_action.reason &&
                  is_nil(SavedResetProjection.status_hold(@account.saved_reset_operation))
              }
              id="saved-reset-redemption-unavailable-reason"
              class="text-xs leading-5 text-base-content/55"
            >
              {@account.saved_reset_redemption_action.reason}
            </p>
            <SavedResetComponents.saved_reset_last_auto_redemption_cause
              id="saved-reset-last-auto-redemption-cause"
              cause={@account.saved_resets.last_auto_redemption_cause}
            />
          </div>

          <details
            :if={@account.saved_resets.available?}
            id="saved-reset-expirations-disclosure"
            class="group border-t border-base-300/60"
            data-preserve-open
            open
          >
            <summary class="flex cursor-pointer items-center justify-between gap-3 px-5 py-3 text-sm font-semibold text-base-content transition-colors hover:bg-base-200/50 [&::-webkit-details-marker]:hidden">
              <span>{gettext("All expirations")}</span>
              <.icon
                name="hero-chevron-right"
                class="size-4 text-base-content/50 transition-transform group-open:rotate-90"
              />
            </summary>
            <div
              id="saved-reset-expiration-summary"
              class="grid gap-3 border-t border-base-300/50 bg-base-200/30 px-5 py-4"
            >
              <SavedResetComponents.saved_reset_expiration_table
                id="saved-reset-expiration"
                saved_resets={@account.saved_resets}
                calendar_path={~p"/admin/upstreams/#{@account.identity.id}/saved-reset-expirations.ics"}
                datetime_preferences={@datetime_preferences}
                empty_label={gettext("No expiration dates reported for the available saved resets yet.")}
              />
            </div>
          </details>

          <details
            id="saved-reset-policy-advanced-disclosure"
            class="group border-t border-base-300/60"
            data-preserve-open
          >
            <summary class="flex cursor-pointer items-center justify-between gap-3 px-5 py-3 text-sm font-semibold text-base-content transition-colors hover:bg-base-200/50 [&::-webkit-details-marker]:hidden">
              <span>{gettext("Advanced policy settings")}</span>
              <.icon
                name="hero-chevron-right"
                class="size-4 text-base-content/50 transition-transform group-open:rotate-90"
              />
            </summary>
            <div
              id="saved-reset-policy-advanced-fields"
              class="grid gap-4 border-t border-base-300/50 px-5 py-4"
            >
              <SavedResetComponents.saved_reset_policy_fields form={@form} />
            </div>
          </details>
        </.form>

        <AdminComponents.dialog_footer
          id="saved-reset-policy-dialog-footer"
          docs_url={@saved_reset_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="saved-reset-policy-cancel"
              label={gettext("Close")}
              variant={:ghost}
              phx-click="cancel_saved_reset_policy"
            />
            <AdminComponents.action_button
              id="saved-reset-policy-submit"
              data-saved-reset-action="save-policy"
              data-server-disabled="false"
              icon="hero-check"
              label={gettext("Save policy")}
              type="submit"
              form="saved-reset-policy-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_saved_reset_policy">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  defp assign_saved_reset_summary(%{account: nil} = assigns) do
    assign(assigns, bank_count: 0, next_expires_in: nil)
  end

  defp assign_saved_reset_summary(%{account: account} = assigns) do
    assign(assigns,
      bank_count: account.saved_resets.available_count || 0,
      next_expires_in: next_expires_in(account.saved_resets)
    )
  end

  defp next_expires_in(%{next_expires_at: value}) do
    now = DateTime.utc_now()

    with %DateTime{} = expires_at <- ResetFormatting.parse_datetime(value),
         :gt <- DateTime.compare(expires_at, now) do
      expires_at
      |> RelativeTime.seconds_until(now)
      |> ResetFormatting.format_reset_duration()
    else
      _missing_or_expired -> nil
    end
  end

  defp next_expires_in(_saved_resets), do: nil

  defp confirming_saved_reset_redemption?(%{identity_id: identity_id}, identity_id), do: true
  defp confirming_saved_reset_redemption?(_confirmation, _identity_id), do: false

  defp saved_reset_open?(account), do: match?(%{saved_reset_operation: %{open?: true}}, account)

  defp saved_reset_redemption_title(%{available?: true}), do: gettext("Queue manual redemption")

  defp saved_reset_redemption_title(%{reason: reason}) when is_binary(reason),
    do: reason

  defp saved_reset_redemption_title(_action), do: gettext("Saved reset redemption unavailable")

  attr :accounts, :list, required: true
  attr :account_panel_views, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :can_manage_pools?, :boolean, required: true
  attr :filter_values, :map, required: true

  defp upstream_account_grid(assigns) do
    ~H"""
    <div
      :if={@accounts != []}
      id="upstream-account-grid"
      class="grid min-w-0 items-start gap-3 min-[700px]:grid-cols-2 2xl:grid-cols-3 [@media(width>=112rem)]:grid-cols-4"
    >
      <AccountCard.account_card
        :for={{account, account_index} <- Enum.with_index(@accounts)}
        account={account}
        account_index={account_index}
        panel_view={account_panel_view(@account_panel_views, account)}
        datetime_preferences={@datetime_preferences}
        can_manage_pools?={@can_manage_pools?}
        pool_editor_query_params={UpstreamFilterForm.query_params(@filter_values)}
      />
    </div>
    """
  end

  defp account_panel_view(panel_views, %{identity: %{id: identity_id}})
       when is_map(panel_views) do
    Map.get(panel_views, identity_id, :usage)
  end

  defp account_panel_view(_panel_views, _account), do: :usage

  defp upstreams_dialog_path(filter_values, extra_params) do
    params =
      filter_values
      |> UpstreamFilterForm.query_params()
      |> Map.merge(extra_params)

    ~p"/admin/upstreams?#{params}"
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

  defp oauth_pending_flow?(%{status: "pending"}), do: true
  defp oauth_pending_flow?(_flow), do: false

  defp oauth_dialog_dismiss_label(%{status: "completed"}), do: gettext("Close")
  defp oauth_dialog_dismiss_label(_flow), do: gettext("Cancel")

  # The eyebrow already names the provider, so the title spends its words on the
  # thing the operator cannot otherwise see once the flow starts: where this
  # account is going. The Pool survives every step - `OAuthWorkflow` rebuilds the
  # form from `oauth_link_pool_id` each time - so the title keeps answering
  # "which Pool was this again?" long after the select is gone.
  #
  # Once the flow is done the header stops asking for anything. An imperative
  # title standing over a success banner reads as a step still owed, so the
  # completed screen gets the declarative twin of the same sentence: same
  # subject, same Pool, stated as fact.
  defp oauth_dialog_title(:relink, account, _form, _pool_options, %{status: "completed"}),
    do: gettext("%{label} reauthorized", label: oauth_target_label(account))

  defp oauth_dialog_title(:relink, account, _form, _pool_options, _flow),
    do: gettext("Relink %{label}", label: oauth_target_label(account))

  defp oauth_dialog_title(_mode, _account, form, pool_options, %{status: "completed"}) do
    case oauth_selected_pool_label(form, pool_options) do
      nil -> gettext("Account added")
      pool -> gettext("Added to %{pool}", pool: pool)
    end
  end

  defp oauth_dialog_title(_mode, _account, form, pool_options, _flow) do
    case oauth_selected_pool_label(form, pool_options) do
      nil -> gettext("Link an account")
      pool -> gettext("Link an account to %{pool}", pool: pool)
    end
  end

  defp oauth_selected_pool_label(form, pool_options) do
    selected = to_string(form[:pool_id].value || "")

    Enum.find_value(pool_options, fn {label, value} ->
      to_string(value) == selected && selected != "" && label
    end)
  end

  # The completed clause comes first: a finished relink would otherwise fall into
  # the relink clause below and keep telling the operator to approve again.
  defp oauth_dialog_description(_mode, _account, %{status: "completed"}) do
    gettext("Routing, quota, and health for this account live on its cockpit.")
  end

  defp oauth_dialog_description(_mode, _account, %{flow_kind: "browser", status: "pending"}) do
    gettext("Approve in the tab that opened, then paste the callback URL back here.")
  end

  defp oauth_dialog_description(_mode, _account, %{flow_kind: "device", status: "pending"}) do
    gettext("Enter the code below to approve. This dialog updates when the account is ready.")
  end

  defp oauth_dialog_description(:relink, _account, _flow),
    do: gettext("Approve again to refresh this account's authorization.")

  defp oauth_dialog_description(_mode, _account, _flow),
    do: gettext("Choose a Pool, then approve the account.")

  defp oauth_callback_submit_label(:relink), do: gettext("Complete relink")
  defp oauth_callback_submit_label(_mode), do: gettext("Complete link")

  # A pending message describes the flow that is running, so it renders inside
  # that flow's own section rather than floating above the dialog body.
  defp oauth_pending_status(%{message: message}, %{status: "pending"})
       when is_binary(message) and message != "",
       do: message

  defp oauth_pending_status(_result, _flow), do: nil

  defp oauth_relink_mode?(:relink), do: true
  defp oauth_relink_mode?(_mode), do: false

  # `mark_oauth_flow_completed/4` stamps the linked identity onto the flow row, so
  # the completed flow the LiveView already holds is enough to reach the cockpit -
  # no extra assign, query, or reload lookup. `Map.get/2` because the dev showcase
  # renders this dialog from plain fixture maps rather than `OAuthFlow` structs.
  defp oauth_cockpit_path(%{status: "completed"} = flow) do
    case Map.get(flow, :result_upstream_identity_id) do
      identity_id when is_binary(identity_id) and identity_id != "" ->
        ~p"/admin/upstreams/#{identity_id}"

      _absent ->
        nil
    end
  end

  defp oauth_cockpit_path(_flow), do: nil

  defp form_checkbox_checked?(field) do
    Form.normalize_value("checkbox", field.value)
  end

  defp oauth_target_label(%{label: label}) when is_binary(label) and label != "", do: label

  defp oauth_target_label(%{identity: %{account_label: label}})
       when is_binary(label) and label != "",
       do: label

  defp oauth_target_label(%{identity: %{chatgpt_account_id: account_id}})
       when is_binary(account_id) and account_id != "",
       do: account_id

  defp oauth_target_label(_account), do: gettext("selected account")
end
