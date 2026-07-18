defmodule CodexPoolerWeb.ObservatoryRefreshGenerationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.ObservatoryControllerTestHelpers

  @observatory_path "/observatory"
  @reader_owner_env :observatory_refresh_test_owner

  defmodule ControlledReader do
    def read(_principal, _window) do
      owner = Application.fetch_env!(:codex_pooler, :observatory_refresh_test_owner)
      reference = make_ref()
      send(owner, {:observatory_read_started, self(), reference})

      receive do
        {:complete_observatory_read, ^reference, result} -> result
      after
        5_000 -> {:error, :controlled_reader_timeout}
      end
    end
  end

  test "renders the scheduler lifecycle contract", %{conn: conn} do
    view = authenticated_view(conn)
    render_hook(view, "observatory-refresh", %{"reason" => "initial"})
    render_async(view)

    assert has_element?(
             view,
             "#observatory-page[phx-hook='ObservatoryRefresh'][data-paused='false'][data-request-generation][data-last-applied-at-ms]" <>
               "[data-freshness-generation='1']"
           )

    assert has_element?(
             view,
             "#observatory-pause[data-observatory-refresh-action='pause']:not([phx-click])"
           )

    assert has_element?(view, "[data-role='observatory-freshness-label']", "Updated 0s ago")
    assert has_element?(view, "[data-role='observatory-refresh-status']", "Live")
  end

  test "a newer success cannot be overwritten by an older success", %{conn: conn} do
    view = authenticated_view(conn)
    install_controlled_reader()
    older = start_refresh(view)
    newer = start_refresh(view)

    complete_read(newer, {:ok, report(222)})
    assert has_element?(view, "#observatory-traffic-fallback-total", "222 tokens · 1 request")
    assert has_element?(view, "#observatory-page[data-freshness-generation='2']")

    complete_read(older, {:ok, report(111)})
    assert has_element?(view, "#observatory-traffic-fallback-total", "222 tokens · 1 request")
    refute has_element?(view, "#observatory-traffic-fallback-total", "111 tokens · 1 request")
  end

  test "a stale error cannot replace a newer success", %{conn: conn} do
    view = authenticated_view(conn)
    install_controlled_reader()
    older = start_refresh(view)
    newer = start_refresh(view)

    complete_read(newer, {:ok, report(333)})
    complete_read(older, {:error, :older_failure})

    assert has_element?(view, "#observatory-traffic-fallback-total", "333 tokens · 1 request")
    refute has_element?(view, "#observatory-state-error")
  end

  test "the current generation applies the safe error state", %{conn: conn} do
    view = authenticated_view(conn)
    install_controlled_reader()
    current = start_refresh(view)

    complete_read(current, {:error, :current_failure})

    assert has_element?(view, "#observatory-state-error[role='status']")
    refute has_element?(view, "#observatory-widgets")
  end

  test "a failed refresh preserves the success freshness generation", %{conn: conn} do
    view = authenticated_view(conn)
    install_controlled_reader()
    success = start_refresh(view)

    complete_read(success, {:ok, report(444)})
    assert has_element?(view, "#observatory-page[data-freshness-generation='1']")
    assert has_element?(view, "[data-role='observatory-freshness-label']", "Updated 0s ago")

    failure = start_refresh(view)
    complete_read(failure, {:error, :current_failure})

    assert has_element?(view, "#observatory-page[data-freshness-generation='1']")
    assert has_element?(view, "[data-role='observatory-freshness-label']", "Update unavailable")
  end

  defp authenticated_view(conn) do
    pool = pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    ObservatoryControllerTestHelpers.enable_dashboard_access!(api_key)

    conn =
      ObservatoryControllerTestHelpers.post_login(conn, CodexPoolerWeb.Endpoint, %{
        "observatory" => %{"api_key" => raw_key}
      })

    {:ok, view, _html} = live(conn, @observatory_path)
    render_async(view)
    view
  end

  defp install_controlled_reader do
    previous_reader = Application.fetch_env(:codex_pooler, :observatory_reader)
    previous_owner = Application.fetch_env(:codex_pooler, @reader_owner_env)
    Application.put_env(:codex_pooler, :observatory_reader, ControlledReader)
    Application.put_env(:codex_pooler, @reader_owner_env, self())

    on_exit(fn ->
      restore_env(:observatory_reader, previous_reader)
      restore_env(@reader_owner_env, previous_owner)
    end)
  end

  defp start_refresh(view) do
    render_hook(view, "observatory-refresh", %{"reason" => "manual"})
    assert_receive {:observatory_read_started, task, reference}
    {task, reference, Process.monitor(task)}
  end

  defp complete_read({task, reference, monitor}, result) do
    send(task, {:complete_observatory_read, reference, result})
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
  end

  defp report(tokens) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      accounting: %{status: "complete"},
      buckets: [],
      models: [],
      outcomes: [],
      performance: %{},
      totals: %{
        cost: %{},
        requests: %{failed: 0, succeeded: 1, total: 1},
        tokens: %{cached_input: 0, input: tokens, total: tokens}
      },
      trends: %{},
      window: %{ended_at: now, key: "24h", started_at: DateTime.add(now, -86_400)}
    }
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:codex_pooler, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:codex_pooler, key)
end
