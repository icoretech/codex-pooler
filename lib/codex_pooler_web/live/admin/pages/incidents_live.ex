defmodule CodexPoolerWeb.Admin.IncidentsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Status.Events, as: StatusEvents
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.IncidentsPageComponents
  alias CodexPoolerWeb.Admin.OpenAIIncidentsReadModel
  alias CodexPoolerWeb.DateTimeDisplay

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: OpenAIStatus.subscribe()

    socket =
      socket
      |> assign(
        page_title: "OpenAI incidents",
        incidents_page: OpenAIIncidentsReadModel.load(),
        datetime_preferences:
          DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)
      )
      |> Phoenix.LiveView.attach_hook(
        :openai_incidents_refresh,
        :handle_info,
        &handle_status_event/2
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({:openai_status_updated, _metadata}, socket) do
    {:noreply, assign(socket, :incidents_page, OpenAIIncidentsReadModel.load())}
  end

  def handle_info(:openai_incidents_status_refresh, socket) do
    {:noreply, assign(socket, :incidents_page, OpenAIIncidentsReadModel.load())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp handle_status_event({:openai_status_updated, payload}, socket) do
    case StatusEvents.decode(payload) do
      {:ok, _event} -> {:halt, assign(socket, :incidents_page, OpenAIIncidentsReadModel.load())}
      :ignore -> {:cont, socket}
    end
  end

  defp handle_status_event(_message, socket), do: {:cont, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:incidents}
      alert_notification_center={@alert_notification_center}
      openai_status_aggregate={@openai_status_aggregate}
    >
      <section id="admin-incidents-page" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="admin-incidents-page-header"
          title="OpenAI incidents"
          description="Current and recent incidents reported by the public OpenAI status feed."
        />
        <IncidentsPageComponents.incidents_content
          page={@incidents_page}
          datetime_preferences={@datetime_preferences}
        />
      </section>
    </AdminComponents.admin_shell>
    """
  end
end
