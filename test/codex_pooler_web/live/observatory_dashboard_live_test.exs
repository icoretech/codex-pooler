defmodule CodexPoolerWeb.ObservatoryDashboardLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.Repo
  alias CodexPoolerWeb.ObservatoryLive

  @login_path "/observatory/login"
  @observatory_path "/observatory"
  @cookie_name "_codex_pooler_observatory_token"

  defmodule ErrorReader do
    @backend_detail_marker "observatory-backend-detail-#{System.unique_integer([:positive])}"

    def backend_detail_marker, do: @backend_detail_marker

    def read(_principal, _window) do
      {:error, %{kind: :backend_failure, detail: @backend_detail_marker}}
    end
  end

  test "observatory shell defaults and narrow-phone rules stay scoped" do
    root_source = File.read!("lib/codex_pooler_web/components/layouts/root.html.heex")
    css_source = File.read!("assets/css/app.css")
    [_, toolbar_rules] = Regex.run(~r/\.observatory-toolbar \{(.*?)\n\}/s, css_source)

    assert root_source =~ "const storedTheme = localStorage.getItem(\"phx:theme\");"
    assert root_source =~ "window.location.pathname === \"/observatory\""
    assert root_source =~ "window.location.pathname.startsWith(\"/observatory/\")"
    assert root_source =~ "document.documentElement.setAttribute(\"data-theme\", \"dark\")"
    assert root_source =~ "setTheme(\"system\")"
    assert root_source =~ "if (storedTheme) {\n            setTheme(storedTheme);"
    assert root_source =~ "phx:set-theme"
    assert toolbar_rules =~ "background: var(--color-base-100);"
    refute toolbar_rules =~ "backdrop-filter"
    refute toolbar_rules =~ "blur("
    assert css_source =~ "@media (width <= 23.4375rem)"
    assert css_source =~ ".observatory-wordmark small {\n    display: none;"
  end

  test "disconnected mount keeps the loading state before the initial read" do
    {:ok, socket} = ObservatoryLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    assert socket.assigns.loading
    assert socket.assigns.observatory_state == :loading
    assert socket.assigns.observatory_report == nil
  end

  test "empty usage renders the authenticated safe boundary", %{conn: conn} do
    %{conn: conn, pool: pool, api_key: api_key, raw_key: raw_key} = authenticated_conn(conn)
    cookie_value = response_cookie_value(conn)

    {:ok, view, _html} = live(conn, @observatory_path)
    activate_initial_refresh(view)
    html = render(view)

    principal = :sys.get_state(view.pid).socket.assigns.dashboard_principal
    assert {:ok, _report} = Observatory.read(principal, "24h")
    assert :empty == :sys.get_state(view.pid).socket.assigns.observatory_state
    assert has_element?(view, "#observatory-toolbar")
    assert has_element?(view, "#observatory-principal", api_key.display_name)
    assert has_element?(view, "#observatory-key-prefix", api_key.key_prefix)
    assert has_element?(view, "#observatory-toolbar-controls")
    assert has_element?(view, "#observatory-window-24h[aria-pressed='true']")

    for window <- ~w(1h 5h 7d) do
      assert has_element?(view, "#observatory-window-#{window}[aria-pressed='false']")
    end

    assert has_element?(view, "#observatory-state-empty[role='status'][aria-live='polite']")
    assert has_element?(view, "#observatory-disconnected.hidden #observatory-state-disconnected")
    assert html =~ "phx-disconnected:block"
    refute has_element?(view, "#observatory-widgets")
    refute_sensitive_or_forbidden(html, raw_key, cookie_value, api_key, pool)
  end

  test "seeded usage renders the dashboard and keeps controls coherent", %{conn: conn} do
    %{conn: conn, pool: pool, api_key: api_key, raw_key: raw_key} = authenticated_conn(conn)
    cookie_value = response_cookie_value(conn)

    model =
      model_fixture(pool, %{
        exposed_model_id: "safe-observatory-model",
        display_name: "safe-observatory-model"
      })

    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-1, :second)
      |> DateTime.truncate(:microsecond)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: "safe-observatory-model",
        status: "succeeded",
        completed_at: observed_at
      })
      |> Ecto.Changeset.change(%{admitted_at: observed_at, completed_at: observed_at})
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      model_id: model.id,
      input_tokens: 100,
      cached_input_tokens: 20,
      output_tokens: 40,
      total_tokens: 160,
      settled_cost_micros: 1_250_000,
      occurred_at: observed_at
    })

    {:ok, view, _html} = live(conn, @observatory_path)
    activate_initial_refresh(view)
    html = render(view)
    expected_total_label = "100 tokens · 1 request"
    state = :sys.get_state(view.pid)
    traffic = state.socket.assigns.observatory_report.traffic
    chart_series = Jason.decode!(traffic.chart.series)
    fallback_rows = traffic.fallback.rows

    assert :ready == state.socket.assigns.observatory_state
    assert has_element?(view, "#observatory-widgets")

    for selector <-
          ~w(#observatory-fact-success #observatory-fact-cache #observatory-fact-cost #observatory-cost-settled #observatory-fact-throughput #observatory-fact-latency #observatory-models #observatory-traffic #observatory-outcomes) do
      assert has_element?(view, selector)
    end

    assert has_element?(view, "[data-role='observatory-model-row']", "safe-observatory-model")
    assert has_element?(view, "#observatory-traffic-plot[phx-hook='ApexTimeSeriesChart']")
    assert traffic.total_label == expected_total_label
    assert traffic.fallback.total_label == expected_total_label
    assert traffic.total_label == traffic.fallback.total_label
    assert has_element?(view, "#observatory-traffic", expected_total_label)

    assert has_element?(
             view,
             "#observatory-traffic-fallback-total",
             "Total: #{expected_total_label}"
           )

    assert Enum.map(chart_series, & &1["data"]) == [
             Enum.map(fallback_rows, & &1.fresh),
             Enum.map(fallback_rows, & &1.cached)
           ]

    assert Enum.sum(Enum.map(fallback_rows, & &1.fresh)) == 80
    assert Enum.sum(Enum.map(fallback_rows, & &1.cached)) == 20
    assert Enum.sum(Enum.map(fallback_rows, & &1.total)) == 100
    assert Enum.sum(Enum.map(fallback_rows, & &1.requests)) == 1

    assert has_element?(
             view,
             "[data-role='observatory-outcome-row'][data-status='ok']",
             "safe-observatory-model"
           )

    assert has_element?(view, "[data-role='outcome-status'][data-status='ok']", "Succeeded")

    refute_sensitive_or_forbidden(html, raw_key, cookie_value, api_key, pool)

    for window <- ~w(1h 5h 24h 7d) do
      render_click(view, "select-window", %{"window" => window})
      render_async(view)
      assert has_element?(view, "#observatory-window-#{window}[aria-pressed='true']")
    end

    render_click(view, "select-window", %{"window" => "invalid"})
    assert has_element?(view, "#observatory-window-7d[aria-pressed='true']")

    render_click(view, "pause-refresh")
    assert has_element?(view, "#observatory-state-stale")
    assert has_element?(view, "#observatory-resume[aria-label='Resume auto-refresh']")

    render_click(view, "resume-refresh")
    render_async(view)
    assert has_element?(view, "#observatory-widgets")
    refute has_element?(view, "#observatory-state-stale")
    assert has_element?(view, "#observatory-pause[aria-label='Pause auto-refresh']")

    assert has_element?(
             view,
             "#observatory-traffic-mode-interval[aria-pressed='true'][phx-click*='chart:set-mode']"
           )

    assert has_element?(
             view,
             "#observatory-traffic-mode-cumulative[aria-pressed='false'][phx-click*='chart:set-mode']"
           )
  end

  test "reader errors render generic state copy", %{conn: conn} do
    %{conn: conn} = authenticated_conn(conn)
    previous = Application.fetch_env(:codex_pooler, :observatory_reader)
    Application.put_env(:codex_pooler, :observatory_reader, ErrorReader)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :observatory_reader, value)
        :error -> Application.delete_env(:codex_pooler, :observatory_reader)
      end
    end)

    {:ok, view, _html} = live(conn, @observatory_path)
    activate_initial_refresh(view)
    html = render(view)

    assert has_element?(view, "#observatory-state-error[role='status'][aria-live='polite']")
    assert html =~ "temporarily unavailable"
    refute html =~ ErrorReader.backend_detail_marker()
  end

  defp activate_initial_refresh(view) do
    render_hook(view, "observatory-refresh", %{"reason" => "initial"})
    render_async(view)
  end

  defp authenticated_conn(conn, pool \\ nil) do
    pool = pool || pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    api_key = enable_dashboard_access!(api_key)
    conn = get(conn, @login_path)

    conn =
      post(conn, @login_path, %{
        "observatory" => %{"api_key" => raw_key},
        "_csrf_token" => csrf_token_from(conn.resp_body)
      })

    %{conn: conn, pool: pool, api_key: api_key, raw_key: raw_key}
  end

  defp enable_dashboard_access!(api_key) do
    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp response_cookie_value(conn), do: get_resp_cookies(conn)[@cookie_name][:value]

  defp csrf_token_from(html) do
    [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, html)
    token
  end

  defp refute_sensitive_or_forbidden(html, raw_key, cookie_value, api_key, pool) do
    refute html =~ raw_key
    refute html =~ cookie_value
    refute html =~ to_string(api_key.id)
    refute html =~ to_string(pool.id)

    visible_text = html |> LazyHTML.from_fragment() |> LazyHTML.text()
    refute visible_text =~ ~r/\b(admin|Pool|upstream|operator)\b/i
  end
end
