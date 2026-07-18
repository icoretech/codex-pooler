defmodule CodexPoolerWeb.ObservatoryReconnectTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.ObservatoryControllerTestHelpers

  @observatory_path "/observatory"
  @reader_owner_env :observatory_reconnect_test_owner

  defmodule ProbeReader do
    @owner_env :observatory_reconnect_test_owner

    def read(_principal, window) do
      owner = Application.fetch_env!(:codex_pooler, @owner_env)
      send(owner, {:observatory_read_started, self(), window})
      {:error, :probe_result}
    end
  end

  setup do
    previous_reader = Application.fetch_env(:codex_pooler, :observatory_reader)
    previous_owner = Application.fetch_env(:codex_pooler, @reader_owner_env)
    Application.put_env(:codex_pooler, :observatory_reader, ProbeReader)
    Application.put_env(:codex_pooler, @reader_owner_env, self())

    on_exit(fn ->
      restore_env(:observatory_reader, previous_reader)
      restore_env(@reader_owner_env, previous_owner)
    end)
  end

  test "connected mount waits for exactly one active client refresh", %{conn: conn} do
    view = conn |> authenticated_conn() |> live_with_paused(false)

    refute_reader_started()
    render_hook(view, "observatory-refresh", %{"reason" => "initial"})

    assert_one_reader_started(view, "24h")
  end

  test "paused remount suppresses periodic and reconnect reads until resume", %{conn: conn} do
    view = conn |> authenticated_conn() |> live_with_paused(true)

    assert has_element?(view, "#observatory-page[data-paused='true']")
    assert has_element?(view, "[data-role='observatory-freshness-label']", "Updates paused")
    refute_reader_started()

    render_hook(view, "observatory-refresh", %{"reason" => "periodic"})
    render_hook(view, "observatory-refresh", %{"reason" => "reconnect"})
    refute_reader_started()

    render_click(view, "resume-refresh")
    assert_one_reader_started(view, "24h")
  end

  test "window changes read once while paused and invalid windows remain ignored", %{conn: conn} do
    view = conn |> authenticated_conn() |> live_with_paused(true)
    refute_reader_started()

    render_click(view, "select-window", %{"window" => "1h"})
    assert_one_reader_started(view, "1h")

    render_click(view, "select-window", %{"window" => "invalid"})
    refute_reader_started()
  end

  defp authenticated_conn(conn) do
    pool = pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    ObservatoryControllerTestHelpers.enable_dashboard_access!(api_key)

    ObservatoryControllerTestHelpers.post_login(conn, CodexPoolerWeb.Endpoint, %{
      "observatory" => %{"api_key" => raw_key}
    })
  end

  defp live_with_paused(conn, paused) do
    conn = get(conn, @observatory_path)

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"observatory_paused" => paused})
      |> live()

    view
  end

  defp assert_one_reader_started(view, window) do
    assert_receive {:observatory_read_started, task, ^window}
    assert task != view.pid
    render_async(view)
    refute_reader_started()
  end

  defp refute_reader_started do
    refute_receive {:observatory_read_started, _task, _window}, 50
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:codex_pooler, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:codex_pooler, key)
end
