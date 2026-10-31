defmodule CodexPoolerWeb.Admin.AlertsPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :selected_tab, :string, required: true

  @spec workspace_header(map()) :: Phoenix.LiveView.Rendered.t()
  def workspace_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
          {gettext("Alert management")}
        </p>
        <h2 class="text-lg font-semibold text-base-content">
          {workspace_title(@selected_tab)}
        </h2>
      </div>
      <div id="alerts-tabs" class="tabs tabs-border" role="tablist">
        <.link
          :for={tab <- alert_tabs()}
          id={"alerts-tab-#{tab.id}"}
          patch={~p"/admin/alerts?#{%{"tab" => tab.id}}"}
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

  defp alert_tabs do
    [
      %{id: "rules", label: gettext("Rules")},
      %{id: "channels", label: gettext("Channels")},
      %{id: "incidents", label: gettext("Incidents")}
    ]
  end

  defp workspace_title("channels"), do: gettext("Channels")
  defp workspace_title("incidents"), do: gettext("Incidents")
  defp workspace_title(_tab), do: gettext("Rules")
end
