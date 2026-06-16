defmodule CodexPoolerWeb.Admin.SettingsPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SettingsPageComponents.{Account, MCP, Security}

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
      <Account.profile_panel
        account_form={@account_form}
        datetime_format_options={@datetime_format_options}
        timezone_options={@timezone_options}
      />
      <MCP.panel
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

  attr :totp_enabled?, :boolean, required: true
  attr :totp_setup, :map, default: nil
  attr :current_scope, :any, required: true
  attr :datetime_preferences, :map, required: true
  attr :password_form, :any, required: true
  attr :browser_sessions, :list, required: true

  def security_panel(assigns) do
    ~H"""
    <Security.panel
      current_scope={@current_scope}
      totp_enabled?={@totp_enabled?}
      totp_setup={@totp_setup}
      password_form={@password_form}
      browser_sessions={@browser_sessions}
      datetime_preferences={@datetime_preferences}
    />
    """
  end

  defp tab_query_params(tab), do: %{"tab" => tab}
end
