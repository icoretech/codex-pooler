defmodule CodexPoolerWeb.Admin.SystemPageComponents.MCP do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :card_statuses, :map, required: true
  attr :mcp_key_count, :integer, required: true

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
          eyebrow="MCP"
          title="MCP service"
          description="Controls whether operator MCP bearer tokens can use the metadata-only /mcp endpoint."
          hint="This setting never creates or exposes tokens."
        >
          <:hint_content>
            Manage your own MCP keys in <.link
              id="instance-settings-mcp-account-settings-link"
              navigate={~p"/admin/settings?tab=account"}
              class="font-medium text-primary underline-offset-2 hover:underline"
            >
                account settings
              </.link>. {mcp_key_count_label(@mcp_key_count)}
          </:hint_content>
          <div class="w-full">
            <FormControls.toggle_input
              id="instance-settings-mcp-enabled"
              field={mcp_form[:enabled]}
              label="Enabled"
              hint="When off, existing MCP tokens are rejected."
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>
    """
  end

  defp mcp_key_count_label(0), do: "No MCP keys exist in this system."
  defp mcp_key_count_label(1), do: "1 MCP key exists in this system."
  defp mcp_key_count_label(count), do: "#{count} MCP keys exist in this system."
end
