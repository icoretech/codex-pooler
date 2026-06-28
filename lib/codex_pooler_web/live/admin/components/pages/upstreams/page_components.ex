defmodule CodexPoolerWeb.Admin.UpstreamPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.UpstreamFilterForm
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AuthJsonDialog
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents

  @oauth_docs_url "https://docs.codex-pooler.com/operators/upstreams/#openai-oauth-upstream-linking"
  @saved_reset_docs_url "https://docs.codex-pooler.com/operators/upstreams/#saved-resets"

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
  attr :oauth_link_mode, :atom, default: :link, values: [:link, :relink]
  attr :oauth_link_target_account, :map, default: nil
  attr :oauth_link_form, :any, required: true
  attr :oauth_link_flow, :map, default: nil
  attr :oauth_link_authorization_url, :string, default: nil
  attr :oauth_link_result, :map, default: nil
  attr :oauth_link_error, :map, default: nil
  attr :renaming_account, :map, default: nil
  attr :rename_account_form, :any, default: nil
  attr :editing_saved_reset_policy, :map, default: nil
  attr :saved_reset_policy_form, :any, required: true
  attr :confirming_saved_reset_redemption, :map, default: nil
  attr :upstream_accounts, :list, required: true
  attr :uploads, :map, required: true
  attr :datetime_preferences, :map, required: true

  def upstreams_page(assigns) do
    ~H"""
    <section id="admin-upstreams-live" class="grid min-w-0 gap-6">
      <AdminComponents.page_header
        id="upstream-account-page-header"
        title="Upstreams"
        description="Link upstream accounts, monitor routing capacity, and manage credential, quota, and saved-reset recovery."
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
      />

      <.rename_account_dialog account={@renaming_account} form={@rename_account_form} />
      <.saved_reset_policy_dialog
        account={@editing_saved_reset_policy}
        form={@saved_reset_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        datetime_preferences={@datetime_preferences}
      />

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
  attr :oauth_link_mode, :atom, default: :link, values: [:link, :relink]
  attr :oauth_link_target_account, :map, default: nil
  attr :oauth_link_form, :any, required: true
  attr :oauth_link_flow, :map, default: nil
  attr :oauth_link_authorization_url, :string, default: nil
  attr :oauth_link_result, :map, default: nil
  attr :oauth_link_error, :map, default: nil
  attr :pool_options, :list, required: true

  defp oauth_link_dialog(assigns) do
    assigns =
      assigns
      |> assign(:oauth_docs_url, @oauth_docs_url)
      |> assign(:oauth_dialog_title, oauth_dialog_title(assigns.oauth_link_mode))
      |> assign(
        :oauth_dialog_description,
        oauth_dialog_description(assigns.oauth_link_mode, assigns.oauth_link_target_account)
      )
      |> assign(
        :oauth_callback_submit_label,
        oauth_callback_submit_label(assigns.oauth_link_mode)
      )

    ~H"""
    <dialog :if={@oauth_linking} id="oauth-link-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            OpenAI OAuth
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">{@oauth_dialog_title}</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            {@oauth_dialog_description}
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
            <div
              :if={oauth_relink_mode?(@oauth_link_mode)}
              id="oauth-link-relink-target"
              class="rounded-lg border border-base-300 bg-base-200/40 p-4 text-sm text-base-content"
            >
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Account
              </p>
              <p class="mt-1 font-medium">{oauth_target_label(@oauth_link_target_account)}</p>
            </div>

            <div :if={!oauth_relink_mode?(@oauth_link_mode)} class="grid gap-2">
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
                label={@oauth_callback_submit_label}
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

  attr :account, :map, default: nil
  attr :form, :any, default: nil
  attr :confirming_saved_reset_redemption, :map, default: nil
  attr :datetime_preferences, :map, required: true

  defp saved_reset_policy_dialog(assigns) do
    assigns = assign(assigns, :saved_reset_docs_url, @saved_reset_docs_url)

    ~H"""
    <dialog :if={@account && @form} id="saved-reset-policy-dialog" class="modal" open>
      <div
        id="saved-reset-policy-dialog-panel"
        class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl"
      >
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Codex saved resets
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Manage saved reset bank</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            A saved reset is a banked reset credit for this account. Choose when the account may spend saved resets and redeem one manually when needed.
          </p>
        </div>

        <div
          :if={@account.saved_resets.available?}
          id="saved-reset-expiration-summary"
          class="grid gap-3 border-b border-base-300 bg-base-200/30 px-6 py-4"
        >
          <div class="grid gap-1">
            <h3 class="text-sm font-semibold text-base-content">Banked reset expirations</h3>
            <p class="text-xs leading-5 text-base-content/60">
              {@account.saved_resets.label} currently available. Expiration dates are shown when the upstream source reports them.
            </p>
          </div>
          <SavedResetComponents.saved_reset_expiration_table
            id="saved-reset-expiration"
            saved_resets={@account.saved_resets}
            datetime_preferences={@datetime_preferences}
            empty_label="No expiration dates reported for the available saved resets yet."
          />
        </div>

        <div class="grid gap-5 p-6">
          <.form
            id="saved-reset-policy-form"
            for={@form}
            phx-change="validate_saved_reset_policy"
            phx-submit="save_saved_reset_policy"
            autocomplete="off"
            class="grid gap-4"
          >
            <div class="grid gap-1">
              <.input
                field={@form[:auto_redeem_enabled]}
                type="checkbox"
                id="saved-reset-policy-auto-redeem-enabled"
                name="saved_reset_policy[auto_redeem_enabled]"
                label="Auto redeem saved resets"
              />
            </div>

            <div class="grid gap-4 md:grid-cols-[minmax(0,1.1fr)_minmax(9rem,0.9fr)]">
              <div class="grid gap-1">
                <.input
                  field={@form[:trigger_mode]}
                  type="select"
                  id="saved-reset-policy-trigger-mode"
                  name="saved_reset_policy[trigger_mode]"
                  label="When automatic redemption can start"
                  options={[
                    {"After block or near expiry", "blocked"},
                    {"Before work stops near the quota limit", "threshold"}
                  ]}
                />
                <p class="text-xs leading-5 text-base-content/65">
                  Blocked mode waits for weekly quota exhaustion, except a known reset expiring within 24 hours may be rescued early after this account has weekly usage. Near-limit mode waits until every eligible account in the Pool is also near the configured weekly quota limit.
                </p>
              </div>

              <div class="grid gap-1">
                <.input
                  field={@form[:quota_threshold_percent]}
                  type="number"
                  id="saved-reset-policy-quota-threshold-percent"
                  name="saved_reset_policy[quota_threshold_percent]"
                  label="Near-limit threshold"
                  min="1"
                  max="100"
                  step="1"
                />
                <p class="text-xs leading-5 text-base-content/65">
                  Used only by near-limit mode. 95 means redeem when every eligible account has fresh weekly quota evidence at or above 95% used.
                </p>
              </div>
            </div>

            <div class="grid gap-1">
              <.input
                field={@form[:min_blocked_minutes]}
                type="number"
                id="saved-reset-policy-min-blocked-minutes"
                name="saved_reset_policy[min_blocked_minutes]"
                label="Natural reset buffer"
                min="0"
              />
              <p class="text-xs leading-5 text-base-content/65">
                Do not spend a saved reset when the weekly quota will reset naturally within this many minutes. Set 0 to allow automatic redemption even when the natural reset is close.
              </p>
            </div>

            <div class="grid gap-1">
              <.input
                field={@form[:keep_credits]}
                type="number"
                id="saved-reset-policy-keep-credits"
                name="saved_reset_policy[keep_credits]"
                label="Resets to keep in bank"
                min="0"
              />
              <p class="text-xs leading-5 text-base-content/65">
                Automatic redemption stops when the available reset count is at or below this reserve.
              </p>
            </div>
          </.form>

          <section
            id="saved-reset-manual-redemption"
            class="grid gap-3 rounded-lg border border-base-300 bg-base-200/30 p-4"
          >
            <div class="grid gap-1">
              <h3 class="text-sm font-semibold text-base-content">Redeem one banked reset now</h3>
              <p class="text-sm leading-6 text-base-content/70">
                Spend one saved reset now for this account. Policy changes only control future automatic redemption.
              </p>
            </div>

            <div
              :if={@confirming_saved_reset_redemption != @account}
              class="flex flex-wrap items-center gap-3"
            >
              <AdminComponents.action_button
                id="saved-reset-redemption-open-confirmation"
                icon="hero-battery-100"
                label="Redeem one saved reset"
                phx-click="open_saved_reset_redemption_confirmation"
                phx-value-id={@account.identity.id}
                disabled={!@account.saved_reset_redemption_action.available?}
                variant={:secondary}
              />
              <p
                :if={!@account.saved_reset_redemption_action.available?}
                id="saved-reset-redemption-disabled-reason"
                class="text-xs leading-5 text-base-content/60"
              >
                {@account.saved_reset_redemption_action.reason}
              </p>
            </div>

            <div
              :if={@confirming_saved_reset_redemption == @account}
              id="saved-reset-redemption-confirmation"
              class="grid gap-3 rounded-lg border border-warning/30 bg-warning/10 p-3"
            >
              <p class="text-sm leading-6 text-base-content/80">
                Confirm that this account should spend one saved reset now. The action is queued separately from the policy form.
              </p>
              <div class="flex flex-wrap items-center gap-2">
                <AdminComponents.action_button
                  id="saved-reset-redemption-confirm"
                  icon="hero-check"
                  label="Confirm redemption"
                  phx-click="redeem_saved_reset"
                  phx-value-id={@account.identity.id}
                  variant={:primary}
                />
                <AdminComponents.action_button
                  id="saved-reset-redemption-cancel"
                  icon="hero-x-mark"
                  label="Keep reset in bank"
                  phx-click="cancel_saved_reset_redemption"
                />
              </div>
            </div>
          </section>
        </div>

        <AdminComponents.dialog_footer
          id="saved-reset-policy-dialog-footer"
          docs_url={@saved_reset_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="saved-reset-policy-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_saved_reset_policy"
            />
            <AdminComponents.action_button
              id="saved-reset-policy-submit"
              icon="hero-check"
              label="Save policy"
              type="submit"
              form="saved-reset-policy-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_saved_reset_policy">close</button>
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
      <AccountCard.account_card
        :for={{account, account_index} <- Enum.with_index(@accounts)}
        account={account}
        account_index={account_index}
        datetime_preferences={@datetime_preferences}
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

  defp oauth_dialog_title(:relink), do: "Relink OpenAI account"
  defp oauth_dialog_title(_mode), do: "Link OpenAI account"

  defp oauth_dialog_description(:relink, account) do
    "Finish the OpenAI authorization flow to relink #{oauth_target_label(account)}."
  end

  defp oauth_dialog_description(_mode, _account),
    do: "Choose a Pool and finish the OpenAI authorization flow."

  defp oauth_callback_submit_label(:relink), do: "Complete relink"
  defp oauth_callback_submit_label(_mode), do: "Complete link"

  defp oauth_relink_mode?(:relink), do: true
  defp oauth_relink_mode?(_mode), do: false

  defp oauth_target_label(%{label: label}) when is_binary(label) and label != "", do: label

  defp oauth_target_label(%{identity: %{account_label: label}})
       when is_binary(label) and label != "",
       do: label

  defp oauth_target_label(%{identity: %{chatgpt_account_id: account_id}})
       when is_binary(account_id) and account_id != "",
       do: account_id

  defp oauth_target_label(_account), do: "selected account"
end
