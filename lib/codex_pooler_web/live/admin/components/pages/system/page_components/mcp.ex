defmodule CodexPoolerWeb.Admin.SystemPageComponents.MCP do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :card_statuses, :map, required: true
  attr :mcp_key_count, :integer, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <FormControls.settings_card
      :if={@selected_tab == "mcp"}
      group="mcp"
      form={@forms["mcp"]}
      status={@card_statuses["mcp"]}
      autosave
    >
      <.inputs_for :let={mcp_form} field={@forms["mcp"][:mcp]}>
        <FormControls.settings_group
          id="instance-settings-mcp"
          eyebrow={gettext("MCP")}
          title={gettext("MCP service")}
          description={gettext("Controls whether operator MCP bearer tokens can use the metadata-only /mcp endpoint.")}
          hint={gettext("This setting never creates or exposes tokens.")}
        >
          <:hint_content>
            <.link
              id="instance-settings-mcp-account-settings-link"
              navigate={~p"/admin/settings?tab=account"}
              class="font-medium text-primary underline-offset-2 hover:underline"
            >
              {gettext("Manage your own MCP keys in account settings.")}
            </.link>
            {mcp_key_count_label(@mcp_key_count)}
          </:hint_content>
          <div class="w-full">
            <FormControls.toggle_input
              id="instance-settings-mcp-enabled"
              field={mcp_form[:enabled]}
              label={gettext("Enabled")}
              hint={gettext("When off, existing MCP tokens are rejected.")}
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>
    """
  end

  defp mcp_key_count_label(0), do: gettext("No MCP keys exist in this system.")

  defp mcp_key_count_label(count),
    do: ngettext("%{count} MCP key exists in this system.", "%{count} MCP keys exist in this system.", count, count: count)
end
