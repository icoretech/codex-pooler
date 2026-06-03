defmodule CodexPoolerWeb.Admin.SettingsPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

  attr :tabs, :list, required: true
  attr :selected_tab, :string, required: true

  def tab_picker(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
          Operator settings
        </p>
        <h2 class="text-lg font-semibold text-base-content">Choose what to configure</h2>
      </div>
      <div id="settings-tabs" class="tabs tabs-border" role="tablist">
        <.link
          :for={tab <- @tabs}
          id={"settings-tab-#{tab.id}"}
          patch={~p"/admin/settings?#{tab_query_params(tab.id)}"}
          role="tab"
          aria-selected={to_string(@selected_tab == tab.id)}
          class={["tab", @selected_tab == tab.id && "tab-active"]}
        >
          {tab.label}
        </.link>
      </div>
    </div>
    """
  end

  def appearance_panel(assigns) do
    ~H"""
    <section
      id="settings-appearance-panel"
      class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
    >
      <div class="grid gap-5 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
        <div class="grid gap-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            Theme
          </p>
          <h3 class="text-xl font-semibold text-base-content">Admin appearance</h3>
          <p class="text-sm leading-6 text-base-content/65">
            Choose system, light, or dark mode for this browser. The preference stays local to this device.
          </p>
        </div>
        <Layouts.theme_toggle
          id="settings-theme-toggle"
          class="relative flex h-10 w-40 flex-row items-center rounded-full border border-base-300 bg-base-300 md:justify-self-end"
        />
      </div>
    </section>
    """
  end

  attr :account_form, :any, required: true
  attr :datetime_preferences, :map, required: true
  attr :datetime_format_options, :list, required: true
  attr :timezone_options, :list, required: true
  attr :mcp_global_enabled?, :boolean, required: true
  attr :mcp_account_enabled?, :boolean, required: true
  attr :mcp_toggle_form, :any, required: true
  attr :mcp_key_form, :any, required: true
  attr :mcp_keys, :list, required: true
  attr :mcp_rename_forms, :map, required: true
  attr :mcp_created_secret, :map, default: nil
  attr :mcp_delete_key, :any, default: nil
  attr :mcp_delete_form, :any, required: true

  def account_panel(assigns) do
    ~H"""
    <section id="settings-account-panel" class="grid gap-4">
      <section
        id="settings-account-profile-panel"
        class="grid gap-4 rounded-box border border-base-300 bg-base-100 p-5 shadow-sm lg:grid-cols-[16rem_minmax(0,1fr)]"
      >
        <div class="border-base-300 lg:border-r lg:pr-5">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            Identity
          </p>
          <h3 class="mt-1 text-xl font-semibold text-base-content">Operator profile</h3>
          <p class="mt-2 text-sm leading-6 text-base-content/65">
            Update the account details shown in this admin session.
          </p>
        </div>
        <.form
          id="settings-account-form"
          for={@account_form}
          phx-submit="save_account"
          autocomplete="off"
          class="grid min-w-0 gap-4"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <.input
              id="settings-account-email"
              field={@account_form[:email]}
              type="email"
              label="Email"
              required
            />
            <.input
              id="settings-account-display-name"
              field={@account_form[:display_name]}
              type="text"
              label="Display name"
            />
          </div>
          <div class="grid gap-4 md:grid-cols-2">
            <.input
              id="settings-account-datetime-format"
              field={@account_form[:datetime_format]}
              type="select"
              label="Time format"
              options={@datetime_format_options}
              required
            />
            <.input
              id="settings-account-timezone"
              field={@account_form[:timezone]}
              type="select"
              label="Timezone"
              options={@timezone_options}
              required
            />
          </div>
          <div class="flex justify-end">
            <AdminComponents.action_button
              id="settings-account-submit"
              icon="hero-check"
              label="Save account"
              type="submit"
              variant={:primary}
            />
          </div>
        </.form>
      </section>

      <.mcp_panel
        global_enabled?={@mcp_global_enabled?}
        account_enabled?={@mcp_account_enabled?}
        toggle_form={@mcp_toggle_form}
        key_form={@mcp_key_form}
        keys={@mcp_keys}
        rename_forms={@mcp_rename_forms}
        datetime_preferences={@datetime_preferences}
        created_secret={@mcp_created_secret}
        delete_key={@mcp_delete_key}
        delete_form={@mcp_delete_form}
      />
    </section>
    """
  end

  attr :global_enabled?, :boolean, required: true
  attr :account_enabled?, :boolean, required: true
  attr :toggle_form, :any, required: true
  attr :key_form, :any, required: true
  attr :keys, :list, required: true
  attr :rename_forms, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :created_secret, :map, default: nil
  attr :delete_key, :any, default: nil
  attr :delete_form, :any, required: true

  defp mcp_panel(assigns) do
    ~H"""
    <section
      id="settings-mcp-panel"
      class="grid gap-4 rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
    >
      <div class="grid gap-4 lg:grid-cols-[16rem_minmax(0,1fr)]">
        <div class="border-base-300 lg:border-r lg:pr-5">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            MCP access
          </p>
          <h3 class="mt-1 text-xl font-semibold text-base-content">Operator MCP keys</h3>
          <p class="mt-2 text-sm leading-6 text-base-content/65">
            Enable metadata-only MCP access for this operator account and manage labeled bearer tokens.
          </p>
        </div>

        <div class="grid min-w-0 gap-5">
          <div class="grid gap-3 md:grid-cols-2">
            <div class="rounded-box border border-base-300 bg-base-200 p-4">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                Global gate
              </p>
              <p id="settings-mcp-global-status" class={mcp_gate_status_class(@global_enabled?)}>
                {mcp_global_status(@global_enabled?)}
              </p>
              <p class="mt-2 text-sm leading-6 text-base-content/65">
                {mcp_global_copy(@global_enabled?)}
              </p>
              <.link
                id="settings-mcp-global-settings-link"
                navigate={~p"/admin/system"}
                class="btn btn-secondary btn-sm mt-3 gap-2"
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" />
                <span>Open system settings</span>
              </.link>
            </div>

            <div class="rounded-box border border-base-300 bg-base-200 p-4">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                Account gate
              </p>
              <p id="settings-mcp-account-status" class={mcp_gate_status_class(@account_enabled?)}>
                {mcp_account_status(@account_enabled?)}
              </p>
              <p class="mt-2 text-sm leading-6 text-base-content/65">
                Disabling this operator account gate preserves keys, but existing MCP clients fail immediately.
              </p>
            </div>
          </div>

          <.form
            id="settings-mcp-toggle-form"
            for={@toggle_form}
            phx-submit="toggle_operator_mcp"
            autocomplete="off"
            class="grid gap-3 rounded-box border border-base-300 p-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-end"
          >
            <input type="hidden" name="mcp_account[enabled]" value="false" />
            <.input
              id="settings-mcp-enabled-toggle"
              field={@toggle_form[:enabled]}
              type="checkbox"
              label="Enable MCP for my operator account"
            />
            <AdminComponents.action_button
              id="settings-mcp-toggle-submit"
              icon="hero-power"
              label="Save MCP account gate"
              type="submit"
              variant={:primary}
            />
          </.form>

          <div
            id="settings-mcp-setup-instructions"
            class="grid gap-3 rounded-box border border-base-300 p-4"
          >
            <div class="grid gap-2 md:grid-cols-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  Endpoint
                </p>
                <code
                  id="settings-mcp-endpoint"
                  class="mt-1 block rounded-field bg-base-200 px-2 py-1 font-mono text-sm"
                >
                  /mcp
                </code>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  Protocol
                </p>
                <code
                  id="settings-mcp-protocol"
                  class="mt-1 block rounded-field bg-base-200 px-2 py-1 font-mono text-sm"
                >
                  2025-11-25
                </code>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  Authorization
                </p>
                <code
                  id="settings-mcp-auth-shape"
                  class="mt-1 block rounded-field bg-base-200 px-2 py-1 font-mono text-sm"
                >
                  Authorization: Bearer &lt;MCP token&gt;
                </code>
              </div>
            </div>
            <p id="settings-mcp-origin-policy" class="text-sm leading-6 text-base-content/70">
              Absent Origin headers from CLI clients are accepted. Present browser Origin headers must be trusted by the service policy; wildcard browser access is not allowed.
            </p>
            <div id="settings-mcp-usage-warning" class="alert alert-warning items-start">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <div class="grid gap-1">
                <p class="font-semibold">MCP hosts can read admin metadata.</p>
                <p class="text-sm">
                  Use a separate labeled key for each trusted client. Usage is not tracked per key.
                </p>
              </div>
            </div>
          </div>

          <.form
            id="settings-mcp-create-form"
            for={@key_form}
            phx-submit="create_mcp_key"
            autocomplete="off"
            class="grid gap-3 rounded-box border border-base-300 p-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-end"
          >
            <.input
              id="settings-mcp-create-label"
              field={@key_form[:label]}
              type="text"
              label="New key label"
              placeholder="Desktop client"
              required
            />
            <AdminComponents.action_button
              id="settings-mcp-create-submit"
              icon="hero-key"
              label="Create MCP key"
              type="submit"
              variant={:primary}
            />
          </.form>

          <div id="settings-mcp-key-list" class="grid gap-3">
            <AdminComponents.empty_state
              :if={@keys == []}
              id="settings-mcp-key-empty"
              title="No MCP keys"
              description="Create a labeled key for each trusted MCP host. Raw tokens are shown once."
              icon="hero-key"
            />

            <div
              :for={key <- @keys}
              id={"settings-mcp-key-row-#{key.id}"}
              class="grid gap-3 rounded-box border border-base-300 p-4 xl:grid-cols-[minmax(0,1fr)_minmax(18rem,22rem)_auto] xl:items-end"
            >
              <div class="grid min-w-0 gap-1">
                <p class="truncate font-semibold text-base-content">{key.label}</p>
                <p class="text-xs text-base-content/55">
                  Prefix <code class="font-mono">{key.key_prefix}</code>
                  · Created {datetime_label(key.inserted_at, @datetime_preferences)}
                </p>
              </div>

              <.form
                id={"settings-mcp-key-#{key.id}-rename-form"}
                for={Map.fetch!(@rename_forms, key.id)}
                phx-submit="rename_mcp_key"
                autocomplete="off"
                class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"
              >
                <.input field={Map.fetch!(@rename_forms, key.id)[:id]} type="hidden" />
                <.input
                  id={"settings-mcp-key-#{key.id}-label"}
                  field={Map.fetch!(@rename_forms, key.id)[:label]}
                  type="text"
                  label="Label"
                  required
                />
                <AdminComponents.action_button
                  id={"settings-mcp-key-#{key.id}-rename-submit"}
                  icon="hero-pencil-square"
                  label="Rename"
                  type="submit"
                />
              </.form>

              <AdminComponents.action_button
                id={"settings-mcp-key-#{key.id}-delete"}
                icon="hero-trash"
                label="Delete"
                phx-click="open_delete_mcp_key"
                phx-value-id={key.id}
                variant={:danger}
              />
            </div>
          </div>
        </div>
      </div>

      <.mcp_created_token_dialog :if={@created_secret} created_secret={@created_secret} />
      <.mcp_delete_dialog :if={@delete_key} key={@delete_key} form={@delete_form} />
    </section>
    """
  end

  attr :created_secret, :map, required: true

  defp mcp_created_token_dialog(assigns) do
    ~H"""
    <dialog id="settings-mcp-created-token-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">MCP token</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Copy this MCP token now</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            This raw token is shown once. Future views only show prefix {@created_secret.key.key_prefix}.
          </p>
        </div>
        <div class="grid gap-5 p-6">
          <div id="settings-mcp-created-token-alert" class="alert alert-success items-start">
            <.icon name="hero-key" class="size-5" />
            <div class="grid gap-1">
              <p class="font-semibold">Copy this MCP token before closing the dialog.</p>
              <p class="text-sm">It will not be shown again.</p>
            </div>
          </div>
          <div class="grid gap-2 rounded-box border border-base-300 bg-base-200 p-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              one-time MCP token
            </p>
            <div class="join w-full">
              <code
                id="settings-mcp-created-token-value"
                class="join-item min-h-10 flex-1 break-all border border-base-300 bg-base-100 px-3 py-2.5 font-mono text-sm text-base-content"
              >
                {@created_secret.raw_token}
              </code>
              <button
                id="settings-mcp-created-token-copy"
                type="button"
                class="btn btn-neutral join-item min-h-10"
                phx-hook="ClipboardCopy"
                phx-update="ignore"
                data-copy-text={@created_secret.raw_token}
                data-copy-label="Copy"
                data-copied-label="Copied"
                aria-label="Copy MCP token"
              >
                <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                <span data-copy-label>Copy</span>
              </button>
            </div>
          </div>
          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="settings-mcp-created-token-close"
              icon="hero-check"
              label="Close"
              phx-click="close_mcp_created_token"
              variant={:primary}
            />
          </div>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_mcp_created_token">close</button>
      </form>
    </dialog>
    """
  end

  attr :key, :any, required: true
  attr :form, :any, required: true

  defp mcp_delete_dialog(assigns) do
    ~H"""
    <dialog id="settings-mcp-delete-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">Permanent delete</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Delete MCP key</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Deleting this MCP key is permanent. Existing clients using it will fail immediately. Usage is not tracked per key
          </p>
        </div>
        <.form
          id="settings-mcp-delete-form"
          for={@form}
          phx-submit="confirm_delete_mcp_key"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@form[:id]} type="hidden" />
          <div class="alert alert-warning items-start">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div class="grid gap-1">
              <p class="font-semibold">
                Deleting this MCP key is permanent. Existing clients using it will fail immediately. Usage is not tracked per key
              </p>
              <p class="text-sm">This removes {@key.label} permanently.</p>
              <p class="text-sm">
                Clients using prefix {@key.key_prefix} stop authenticating immediately.
              </p>
            </div>
          </div>
          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="settings-mcp-delete-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_delete_mcp_key"
            />
            <AdminComponents.action_button
              id="settings-mcp-delete-submit"
              icon="hero-trash"
              label="Delete MCP key"
              type="submit"
              variant={:danger}
            />
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_mcp_key">close</button>
      </form>
    </dialog>
    """
  end

  defp mcp_global_status(true), do: "Global MCP service enabled"
  defp mcp_global_status(false), do: "Global MCP service disabled"
  defp mcp_account_status(true), do: "Enabled for this operator"
  defp mcp_account_status(false), do: "Disabled for this operator"

  defp mcp_global_copy(true), do: "The instance gate currently allows authenticated MCP clients."

  defp mcp_global_copy(false) do
    "Client requests fail until the global MCP service is enabled in system settings."
  end

  defp mcp_gate_status_class(true),
    do:
      "mt-2 inline-flex rounded-full border border-success/20 bg-success/10 px-2.5 py-1 text-xs font-semibold text-success"

  defp mcp_gate_status_class(false),
    do:
      "mt-2 inline-flex rounded-full border border-warning/20 bg-warning/10 px-2.5 py-1 text-xs font-semibold text-warning"

  attr :totp_enabled?, :boolean, required: true
  attr :totp_setup, :map, default: nil
  attr :current_scope, :any, required: true
  attr :datetime_preferences, :map, required: true
  attr :password_form, :any, required: true
  attr :browser_sessions, :list, required: true

  def security_panel(assigns) do
    ~H"""
    <section id="settings-security-panel" class="grid gap-4">
      <.totp_panel
        current_scope={@current_scope}
        totp_enabled?={@totp_enabled?}
        totp_setup={@totp_setup}
      />
      <.password_panel password_form={@password_form} />
      <.browser_sessions_panel
        browser_sessions={@browser_sessions}
        datetime_preferences={@datetime_preferences}
      />
    </section>
    """
  end

  attr :totp_enabled?, :boolean, required: true
  attr :totp_setup, :map, default: nil
  attr :current_scope, :any, required: true

  defp totp_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="grid gap-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            Second factor
          </p>
          <h3 class="text-xl font-semibold text-base-content">Authenticator app</h3>
          <p id="settings-totp-status" class="text-sm leading-6 text-base-content/65">
            {if @totp_enabled?,
              do: "TOTP enabled",
              else: "TOTP not set up"}
          </p>
        </div>
        <AdminComponents.action_button
          :if={!@totp_enabled?}
          id="settings-enable-totp"
          icon="hero-shield-check"
          label="Set up TOTP"
          phx-click="enable_totp"
          variant={:primary}
        />
      </div>

      <div
        :if={@totp_setup}
        id="settings-totp-setup-result"
        class="mt-5 grid gap-4 rounded-box border border-warning/25 bg-warning/10 p-4 lg:grid-cols-[13rem_minmax(0,1fr)]"
      >
        <div
          id="settings-totp-setup-tools"
          class="grid content-start gap-3"
          phx-hook="TotpSetupTools"
          data-otpauth-uri={totp_otpauth_uri(@totp_setup, @current_scope.user)}
        >
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <div
              id="settings-totp-qr"
              data-totp-qr
              data-qr-size="176"
              class="size-44"
            >
            </div>
          </div>
          <button
            id="settings-totp-secret-copy"
            type="button"
            class="btn btn-secondary btn-sm gap-2"
            phx-hook="ClipboardCopy"
            data-copy-text={@totp_setup.secret}
            data-copy-label="Copy secret"
            data-copied-label="Copied"
          >
            <.icon name="hero-clipboard-document" class="copy-icon size-4" />
            <span data-copy-label>Copy secret</span>
          </button>
        </div>
        <div class="grid min-w-0 gap-4">
          <div class="grid gap-1">
            <p class="font-semibold text-base-content">Save these details now</p>
            <p class="text-sm leading-6 text-base-content/70">
              Scan the QR code, copy the secret if scanning is not available, then download the recovery codes.
            </p>
          </div>
          <code
            id="settings-totp-secret"
            class="break-all rounded-box border border-base-300 bg-base-100 p-3 font-mono text-sm"
          >
            {@totp_setup.secret}
          </code>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              Recovery codes
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                id="settings-totp-recovery-copy"
                type="button"
                class="btn btn-secondary btn-sm gap-2"
                phx-hook="ClipboardCopy"
                data-copy-text={recovery_codes_text(@totp_setup)}
                data-copy-label="Copy codes"
                data-copied-label="Copied"
              >
                <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                <span data-copy-label>Copy codes</span>
              </button>
              <a
                id="settings-totp-recovery-download"
                class="btn btn-secondary btn-sm gap-2"
                href={recovery_codes_data_uri(@totp_setup)}
                download="codex-pooler-recovery-codes.txt"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />
                <span>Download</span>
              </a>
            </div>
          </div>
          <ul id="settings-totp-recovery-codes" class="grid gap-1 sm:grid-cols-2">
            <li
              :for={code <- @totp_setup.recovery_codes}
              class="rounded border border-base-300 bg-base-100 px-3 py-2 font-mono text-xs"
            >
              {code}
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :password_form, :any, required: true

  defp password_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
      <.form
        id="settings-password-form"
        for={@password_form}
        phx-submit="save_password"
        autocomplete="off"
        class="grid gap-4"
      >
        <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Password
            </p>
            <h3 class="mt-1 text-xl font-semibold text-base-content">Change password</h3>
            <p class="mt-1 text-sm leading-6 text-base-content/65">
              Enter your current password and choose the password you will use next.
            </p>
          </div>
          <div class="grid gap-4 md:grid-cols-3">
            <.input
              id="settings-current-password"
              field={@password_form[:current_password]}
              type="password"
              label="Current password"
              autocomplete="current-password"
              required
            />
            <.input
              id="settings-new-password"
              field={@password_form[:new_password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
            />
            <.input
              id="settings-new-password-confirmation"
              field={@password_form[:new_password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
            />
          </div>
        </div>
        <div class="flex justify-end border-t border-base-300 pt-4">
          <AdminComponents.action_button
            id="settings-password-submit"
            icon="hero-lock-closed"
            label="Update password"
            type="submit"
            variant={:primary}
          />
        </div>
      </.form>
    </div>
    """
  end

  attr :browser_sessions, :list, required: true
  attr :datetime_preferences, :map, required: true

  defp browser_sessions_panel(assigns) do
    ~H"""
    <div
      id="settings-session-panel"
      class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
    >
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="grid gap-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            Sessions
          </p>
          <h3 class="text-xl font-semibold text-base-content">Browser sessions</h3>
          <p class="text-sm leading-6 text-base-content/65">
            Review active browser sessions for this operator account.
          </p>
        </div>
        <AdminComponents.action_button
          id="settings-logout-other-sessions"
          icon="hero-arrow-left-start-on-rectangle"
          label="Log out other sessions"
          phx-click="logout_other_sessions"
          disabled={other_session_count(@browser_sessions) == 0}
          variant={:secondary}
        />
      </div>

      <ul id="settings-session-list" class="mt-5 grid gap-2">
        <li
          :for={session <- @browser_sessions}
          id={"settings-session-#{session.id}"}
          data-session-device={session_device(session)}
          class="grid min-w-0 gap-3 rounded-box border border-base-300 bg-base-100 p-4 md:grid-cols-[12rem_minmax(0,1fr)_auto]"
        >
          <div class="flex min-w-0 items-center gap-3">
            <span class="grid size-9 shrink-0 place-items-center rounded-field bg-base-200 text-base-content/70">
              <.icon name={session_icon(session)} class="size-5" />
            </span>
            <div class="min-w-0">
              <p class="truncate font-semibold leading-5 text-base-content">
                {session_title(session)}
              </p>
              <span
                :if={session.current?}
                id="settings-current-session-badge"
                class="badge badge-primary badge-sm mt-1"
              >
                This session
              </span>
            </div>
          </div>
          <div class="grid min-w-0 content-center gap-1">
            <p
              id={"settings-session-user-agent-#{session.id}"}
              class="truncate text-sm leading-5 text-base-content/65"
            >
              {user_agent_label(session.user_agent)}
            </p>
            <p class="text-xs leading-5 text-base-content/50">
              IP {ip_address_label(session.ip_address)} · Created {datetime_label(
                session.created_at,
                @datetime_preferences
              )} · Last seen {datetime_label(session.last_seen_at, @datetime_preferences)} · Expires {datetime_label(
                session.expires_at,
                @datetime_preferences
              )}
            </p>
          </div>
          <button
            id={"settings-session-revoke-#{session.id}"}
            type="button"
            class="btn btn-secondary btn-sm gap-2 md:self-center"
            phx-click="logout_session"
            phx-value-id={session.id}
          >
            <.icon name="hero-arrow-left-start-on-rectangle" class="size-4" />
            <span>Sign out</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp totp_otpauth_uri(%{secret: secret}, user) when is_binary(secret) do
    label =
      ["Codex Pooler", user.email || "operator"]
      |> Enum.join(":")
      |> URI.encode(&URI.char_unreserved?/1)

    query =
      URI.encode_query(%{
        secret: secret,
        issuer: "Codex Pooler",
        algorithm: "SHA1",
        digits: "6",
        period: "30"
      })

    "otpauth://totp/#{label}?#{query}"
  end

  defp recovery_codes_text(%{recovery_codes: codes}) when is_list(codes) do
    Enum.join(codes, "\n") <> "\n"
  end

  defp recovery_codes_data_uri(setup) do
    "data:text/plain;charset=utf-8,#{URI.encode(recovery_codes_text(setup))}"
  end

  defp other_session_count(sessions), do: Enum.count(sessions, &(not &1.current?))

  defp session_icon(session) do
    case session_device(session) do
      "mobile" -> "hero-device-phone-mobile"
      "tablet" -> "hero-device-tablet"
      _device -> "hero-computer-desktop"
    end
  end

  defp session_device(%{user_agent: user_agent}) when is_binary(user_agent) do
    user_agent = String.downcase(user_agent)

    cond do
      String.contains?(user_agent, ["ipad", "tablet"]) -> "tablet"
      String.contains?(user_agent, ["mobile", "iphone", "android"]) -> "mobile"
      true -> "desktop"
    end
  end

  defp session_device(_session), do: "desktop"

  defp session_title(%{current?: true}), do: "Current browser"
  defp session_title(_session), do: "Browser session"

  defp user_agent_label(user_agent) when is_binary(user_agent) and user_agent != "",
    do: user_agent

  defp user_agent_label(_user_agent), do: "Unknown browser"

  defp ip_address_label(ip_address) when is_binary(ip_address) and ip_address != "",
    do: ip_address

  defp ip_address_label(_ip_address), do: "not recorded"

  defp datetime_label(datetime, preferences) do
    DateTimeDisplay.format_datetime(datetime, preferences, missing_label: "not yet")
  end

  defp tab_query_params(tab), do: %{"tab" => tab}
end
