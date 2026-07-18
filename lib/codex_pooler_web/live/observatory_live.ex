defmodule CodexPoolerWeb.ObservatoryLive do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Accounting.Usage.Observatory, as: UsageObservatory
  alias CodexPooler.Events
  alias CodexPoolerWeb.Observatory.Components.{Activity, States, Telemetry, Toolbar}
  alias CodexPoolerWeb.Observatory.Presentation
  alias CodexPoolerWeb.ObservatoryAuth

  @default_window "24h"
  @login_path "/observatory/login"

  @impl true
  def mount(_params, _session, socket) do
    paused =
      connected?(socket) and
        Phoenix.LiveView.get_connect_params(socket)["observatory_paused"] == true

    {:ok,
     socket
     |> assign(:selected_window, @default_window)
     |> assign(:traffic_mode, :interval)
     |> assign(:paused, paused)
     |> assign(:freshness, if(paused, do: "Updates paused", else: "Updating usage"))
     |> assign(:loading, not paused)
     |> assign(:observatory_state, if(paused, do: :stale, else: :loading))
     |> assign(:observatory_report, nil)
     |> assign(:request_generation, 0)
     |> assign(:applied_generation, 0)
     |> assign(:freshness_generation, 0)
     |> assign(:last_applied_at_ms, nil)}
  end

  @impl true
  def handle_event("select-window", %{"window" => window}, socket) do
    if Presentation.valid_window?(window) do
      {:noreply, socket |> assign(:selected_window, window) |> request_refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select-window", _params, socket), do: {:noreply, socket}

  def handle_event("select-traffic-mode", %{"mode" => mode}, socket)
      when mode in ["interval", "cumulative"] do
    {:noreply, assign(socket, :traffic_mode, String.to_existing_atom(mode))}
  end

  def handle_event("select-traffic-mode", _params, socket), do: {:noreply, socket}

  def handle_event("pause-refresh", _params, socket) do
    {:noreply,
     assign(socket, paused: true, observatory_state: :stale, freshness: "Updates paused")}
  end

  def handle_event("resume-refresh", _params, socket) do
    {:noreply, socket |> assign(:paused, false) |> request_refresh()}
  end

  def handle_event(
        "observatory-refresh",
        %{"reason" => reason},
        %{assigns: %{paused: true}} = socket
      )
      when reason in ["periodic", "reconnect"] do
    {:noreply, socket}
  end

  def handle_event("observatory-refresh", _params, socket) do
    {:noreply, request_refresh(socket)}
  end

  @impl true
  def handle_async({:observatory_refresh, generation}, result, socket) do
    if generation == socket.assigns.request_generation do
      case ObservatoryAuth.revalidate(socket) do
        {:ok, socket} -> {:noreply, apply_refresh_result(socket, generation, result)}
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({Events, %Events.Event{topics: ["dashboard_sessions"]}}, socket) do
    {:noreply, Phoenix.LiveView.redirect(socket, to: @login_path)}
  end

  @impl true
  def handle_info(message, socket) do
    if message == ObservatoryAuth.revalidation_message() do
      case ObservatoryAuth.revalidate(socket) do
        {:ok, socket} -> {:noreply, socket}
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={:observatory}>
      <section
        id="observatory-page"
        class="min-w-0 px-4 pb-10 sm:px-5"
        phx-hook="ObservatoryRefresh"
        data-paused={to_string(@paused)}
        data-request-generation={@request_generation}
        data-freshness-generation={@freshness_generation}
        data-last-applied-at-ms={@last_applied_at_ms}
      >
        <Toolbar.toolbar
          display_name={principal_label(@dashboard_principal)}
          key_prefix={@dashboard_principal.key_prefix}
          selected_window={@selected_window}
          freshness={@freshness}
          paused={@paused}
        />

        <div
          :if={@loading or @observatory_state in [:error, :empty, :stale]}
          id="observatory-notices"
          class="grid gap-3 py-4"
        >
          <div :if={@loading}><States.state state={:loading} /></div>
          <div :if={@observatory_state == :error}><States.state state={:error} /></div>
          <div :if={@observatory_state == :empty}><States.state state={:empty} /></div>
          <div :if={@observatory_state == :stale}><States.state state={:stale} /></div>
        </div>

        <div
          :if={@observatory_report && @observatory_state in [:ready, :partial, :stale]}
          id="observatory-widgets"
          class="grid min-w-0 gap-4 observatory-split:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]"
        >
          <aside
            id="observatory-left-rail"
            class="min-w-0 observatory-split:sticky observatory-split:top-16 observatory-split:self-start"
          >
            <Telemetry.telemetry
              overview={@observatory_report.overview}
              models={@observatory_report.models}
            />
          </aside>

          <div id="observatory-right-rail" class="min-w-0">
            <Activity.activity
              traffic={@observatory_report.traffic}
              outcomes={@observatory_report.outcomes}
              traffic_mode={@traffic_mode}
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp request_refresh(socket) do
    generation = socket.assigns.request_generation + 1
    socket = assign(socket, :request_generation, generation)

    case ObservatoryAuth.revalidate(socket) do
      {:ok, socket} ->
        principal = socket.assigns.dashboard_principal
        reader = reader_module()
        window = socket.assigns.selected_window

        socket
        |> assign(:loading, is_nil(socket.assigns.observatory_report))
        |> start_async({:observatory_refresh, generation}, fn ->
          reader.read(principal, window)
        end)

      {:error, socket} ->
        socket
    end
  end

  defp apply_refresh_result(socket, generation, {:ok, {:ok, report}}) do
    presentation = Presentation.build(report)

    assign(socket,
      applied_generation: generation,
      freshness_generation: generation,
      freshness: "Updated 0s ago",
      last_applied_at_ms: System.system_time(:millisecond),
      loading: false,
      observatory_report: presentation,
      observatory_state: presentation.state
    )
  end

  defp apply_refresh_result(socket, generation, _error) do
    assign(socket,
      applied_generation: generation,
      freshness: "Update unavailable",
      loading: false,
      observatory_report: nil,
      observatory_state: :error
    )
  end

  defp reader_module,
    do: Application.get_env(:codex_pooler, :observatory_reader, UsageObservatory)

  defp principal_label(principal), do: principal.display_name
end
