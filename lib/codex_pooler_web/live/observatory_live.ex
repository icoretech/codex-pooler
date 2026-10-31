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
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    paused =
      connected?(socket) and
        Phoenix.LiveView.get_connect_params(socket)["observatory_paused"] == true

    {:ok,
     socket
     |> assign(:page_title, gettext("Observatory"))
     |> assign(:selected_window, @default_window)
     |> assign(:traffic_mode, :interval)
     |> assign(:paused, paused)
     |> assign(:freshness, if(paused, do: gettext("Updates paused"), else: gettext("Updating usage")))
     |> assign(:loading, not paused)
     |> assign(:observatory_state, if(paused, do: :stale, else: :loading))
     |> assign(:observatory_report, nil)
     |> assign(:outcomes_page, nil)
     |> assign(:loading_outcomes, false)
     |> assign(:outcomes_load_error, false)
     |> assign(:refreshing, false)
     |> assign(:request_generation, 0)
     |> assign(:applied_generation, 0)
     |> assign(:freshness_generation, 0)
     |> assign(:last_applied_at_ms, nil)}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("select-window", %{"window" => window}, socket) do
    if Presentation.valid_window?(window) do
      # Show the switching indicator only when a dashboard is already on screen;
      # the first load has its own loading state, and the periodic auto-refresh
      # stays silent so the panel does not flicker every 30s.
      {:noreply,
       socket
       |> assign(:selected_window, window)
       |> assign(:refreshing, not is_nil(socket.assigns.observatory_report))
       |> request_refresh()}
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
    {:noreply, assign(socket, paused: true, observatory_state: :stale, freshness: gettext("Updates paused"))}
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

  def handle_event("load-more-outcomes", _params, %{assigns: %{loading_outcomes: false, refreshing: false, outcomes_page: %{has_more: true} = page}} = socket) do
    case ObservatoryAuth.revalidate(socket) do
      {:ok, socket} ->
        principal = socket.assigns.dashboard_principal
        generation = socket.assigns.request_generation
        reader = reader_module()
        locale = Gettext.get_locale()

        {:noreply,
         socket
         |> assign(loading_outcomes: true, outcomes_load_error: false)
         |> start_async({:observatory_outcomes, generation}, fn ->
           Gettext.with_locale(locale, fn ->
             reader.read_outcomes(principal, as_of: page.as_of, before: page.next_cursor)
           end)
         end)}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("load-more-outcomes", _params, socket), do: {:noreply, socket}

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

  def handle_async({:observatory_outcomes, generation}, result, socket) do
    if generation == socket.assigns.request_generation do
      case ObservatoryAuth.revalidate(socket) do
        {:ok, socket} -> {:noreply, apply_outcomes_result(socket, result)}
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
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} locale_preference={@locale_preference} chrome={:observatory}>
      <section
        id="observatory-page"
        class="min-w-0 px-4 pb-10 sm:px-5"
        phx-hook="ObservatoryRefresh"
        data-refresh-labels={refresh_labels()}
        data-paused={to_string(@paused)}
        data-request-generation={@request_generation}
        data-freshness-generation={@freshness_generation}
        data-last-applied-at-ms={@last_applied_at_ms}
      >
        <Toolbar.toolbar
          display_name={principal_label(@dashboard_principal)}
          locale={@locale}
          locale_preference={@locale_preference}
          selected_window={@selected_window}
          freshness={@freshness}
          paused={@paused}
          refreshing={@refreshing}
        />

        <div :if={@refreshing} id="observatory-refreshing" class="sr-only" aria-live="polite">
          {gettext("Updating %{window}…", window: @selected_window)}
        </div>

        <div
          :if={@loading or @observatory_state in [:error, :empty, :stale]}
          id="observatory-notices"
          class={["grid gap-3 py-4", @refreshing && "opacity-40 transition-opacity"]}
        >
          <div :if={@loading}><States.state state={:loading} /></div>
          <div :if={@observatory_state == :error}><States.state state={:error} /></div>
          <div :if={@observatory_state == :empty}><States.state state={:empty} /></div>
          <div :if={@observatory_state == :stale}><States.state state={:stale} /></div>
        </div>

        <div
          :if={@observatory_report && @observatory_state in [:ready, :partial, :stale]}
          id="observatory-widgets"
          class={[
            "mt-4 grid min-w-0 gap-6",
            @refreshing && "opacity-40 transition-opacity"
          ]}
          aria-busy={to_string(@refreshing)}
        >
          <Telemetry.overview_strip overview={@observatory_report.overview} />

          <div
            id="observatory-main-row"
            class="grid min-w-0 items-start gap-6 observatory-split:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]"
          >
            <Activity.traffic_panel
              traffic={@observatory_report.traffic}
              traffic_mode={@traffic_mode}
              window={@observatory_report.window.key}
            />
            <Telemetry.model_distribution
              models={@observatory_report.models}
              window={@observatory_report.window.key}
            />
          </div>

          <Activity.outcomes_panel
            outcomes={@observatory_report.outcomes}
            has_more={!@refreshing && @outcomes_page != nil && @outcomes_page.has_more}
            loading_more={@loading_outcomes}
            load_error={@outcomes_load_error}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp request_refresh(socket) do
    generation = socket.assigns.request_generation + 1
    socket = assign(socket, request_generation: generation, outcomes_page: nil, loading_outcomes: false, outcomes_load_error: false)

    case ObservatoryAuth.revalidate(socket) do
      {:ok, socket} ->
        principal = socket.assigns.dashboard_principal
        reader = reader_module()
        window = socket.assigns.selected_window
        locale = Gettext.get_locale()

        socket
        |> assign(:loading, is_nil(socket.assigns.observatory_report))
        |> start_async({:observatory_refresh, generation}, fn ->
          read_refresh(reader, locale, principal, window)
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
      freshness: gettext("0s ago"),
      last_applied_at_ms: System.system_time(:millisecond),
      loading: false,
      refreshing: false,
      observatory_report: presentation,
      outcomes_page: Map.get(report, :outcomes_page),
      observatory_state: presentation.state
    )
  end

  defp apply_refresh_result(socket, generation, _error) do
    assign(socket,
      applied_generation: generation,
      freshness: gettext("Update unavailable"),
      loading: false,
      refreshing: false,
      observatory_report: nil,
      outcomes_page: nil,
      observatory_state: :error
    )
  end

  defp apply_outcomes_result(socket, {:ok, {:ok, %{outcomes: outcomes, outcomes_page: page}}}) do
    report = socket.assigns.observatory_report
    report = %{report | outcomes: report.outcomes ++ Presentation.build_outcomes(outcomes, report.model_colors)}
    assign(socket, observatory_report: report, outcomes_page: page, loading_outcomes: false, outcomes_load_error: false)
  end

  defp apply_outcomes_result(socket, _error), do: assign(socket, loading_outcomes: false, outcomes_load_error: true)

  defp refresh_labels do
    CodexPooler.JSON.encode!(%{
      disconnectedAria: gettext("Refresh disconnected"),
      disconnectedLabel: gettext("Connection interrupted"),
      disconnectedSpoken: gettext("Disconnected"),
      pausedAria: gettext("Refresh paused"),
      pausedLabel: gettext("Updates paused"),
      pausedSpoken: gettext("Paused"),
      hiddenAria: gettext("Refresh paused while tab hidden"),
      hiddenLabel: gettext("Updates paused while hidden"),
      hiddenSpoken: gettext("Paused while hidden"),
      liveAria: gettext("Refresh live"),
      updatingLabel: gettext("Updating usage"),
      liveSpoken: gettext("Live"),
      secondsAgo: gettext("%{seconds}s ago", seconds: "%{seconds}")
    })
  end

  defp reader_module,
    do: Application.get_env(:codex_pooler, :observatory_reader, UsageObservatory)

  defp read_refresh(reader, locale, principal, window) do
    Gettext.with_locale(locale, fn -> reader.read(principal, window) end)
  end

  defp principal_label(principal), do: principal.display_name
end
