defmodule CodexPoolerWeb.Admin.SystemPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.{Development, Gateway, MCP, Metrics, SMTP}

  attr :tabs, :list, required: true
  attr :selected_tab, :string, required: true

  def system_tab_picker(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
          Instance system
        </p>
        <h2 class="text-lg font-semibold text-base-content">Choose what to configure</h2>
      </div>
      <div id="system-tabs" class="tabs tabs-border" role="tablist">
        <.link
          :for={tab <- @tabs}
          id={"system-tab-#{tab.id}"}
          patch={~p"/admin/system?#{%{"tab" => tab.id}}"}
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

  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :mcp_key_count, :integer, required: true
  attr :card_statuses, :map, required: true
  attr :selected_tab, :string, required: true
  attr :development_action_status, :map, default: nil
  attr :smtp_test_status, :map, default: nil
  attr :development_helpers_available?, :boolean, required: true
  attr :datetime_preferences, :map, required: true

  def instance_settings_panel(assigns) do
    ~H"""
    <section id="system-settings-panel" class="grid gap-4" data-selected-tab={@selected_tab}>
      <Gateway.cards
        selected_tab={@selected_tab}
        forms={@forms}
        form_params={@form_params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      <Development.card
        selected_tab={@selected_tab}
        forms={@forms}
        settings={@settings}
        card_statuses={@card_statuses}
        development_action_status={@development_action_status}
        development_helpers_available?={@development_helpers_available?}
      />
      <MCP.card
        selected_tab={@selected_tab}
        forms={@forms}
        card_statuses={@card_statuses}
        mcp_key_count={@mcp_key_count}
      />
      <Metrics.card
        selected_tab={@selected_tab}
        forms={@forms}
        form_params={@form_params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      <SMTP.card
        selected_tab={@selected_tab}
        forms={@forms}
        form_params={@form_params}
        settings={@settings}
        card_statuses={@card_statuses}
        smtp_test_status={@smtp_test_status}
      />
    </section>
    """
  end
end
