defmodule CodexPoolerWeb.Admin.SettingsPageComponents.MCP do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.MCP.ProtocolVersions
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

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

  def panel(assigns) do
    ~H"""
    <section
      id="settings-mcp-panel"
      class="grid gap-4 rounded-box border border-base-300 bg-base-100 p-5"
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
                  Preferred protocol
                </p>
                <code
                  id="settings-mcp-protocol"
                  class="mt-1 block rounded-field bg-base-200 px-2 py-1 font-mono text-sm"
                >
                  {ProtocolVersions.current()}
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

  def mcp_created_token_dialog(assigns) do
    ~H"""
    <dialog
      id="settings-mcp-created-token-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">MCP token</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Copy this token before closing</h2>
          <p
            id="settings-mcp-created-token-alert"
            class="mt-2 text-sm leading-6 text-base-content/70"
          >
            It is shown once. Afterwards only the prefix
            <span class="font-semibold text-base-content">{@created_secret.key.key_prefix}</span>
            identifies it.
          </p>
        </div>
        <div class="grid gap-5 p-5 sm:p-6">
          <AdminComponents.one_time_secret
            value={@created_secret.raw_token}
            value_id="settings-mcp-created-token-value"
            copy_id="settings-mcp-created-token-copy"
            copy_label="Copy token"
            copy_aria_label="Copy MCP token"
          />
        </div>

        <AdminComponents.dialog_footer id="settings-mcp-created-token-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="settings-mcp-created-token-close"
              icon="hero-check"
              label="Done"
              phx-click="close_mcp_created_token"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_mcp_created_token">close</button>
      </form>
    </dialog>
    """
  end

  attr :key, :any, required: true
  attr :form, :any, required: true

  def mcp_delete_dialog(assigns) do
    ~H"""
    <dialog
      id="settings-mcp-delete-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">MCP key</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Delete {@key.label}?</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Clients authenticating with prefix
            <span class="font-semibold text-base-content">{@key.key_prefix}</span>
            start failing immediately. This cannot be undone.
          </p>
        </div>
        <.form
          id="settings-mcp-delete-form"
          for={@form}
          phx-submit="confirm_delete_mcp_key"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
        >
          <.input field={@form[:id]} type="hidden" />
        </.form>

        <AdminComponents.dialog_footer id="settings-mcp-delete-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="settings-mcp-delete-cancel"
              label="Cancel"
              variant={:ghost}
              phx-click="cancel_delete_mcp_key"
            />
            <AdminComponents.action_button
              id="settings-mcp-delete-submit"
              icon="hero-trash"
              label="Delete"
              type="submit"
              form="settings-mcp-delete-form"
              variant={:danger}
            />
          </:actions>
        </AdminComponents.dialog_footer>
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

  defp datetime_label(datetime, preferences) do
    DateTimeDisplay.format_datetime(datetime, preferences, missing_label: "not yet")
  end
end
