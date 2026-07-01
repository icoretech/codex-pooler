defmodule CodexPoolerWeb.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CodexPoolerWeb.Endpoint

  @codex_desktop_in_app_browser_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

  describe "maybe_live_reloader/2" do
    test "skips Phoenix LiveReloader for the Codex Desktop browser" do
      conn =
        conn(:get, "/login")
        |> put_req_header(
          "user-agent",
          "Mozilla/5.0 Codex/26.519.81530 Chrome/148.0.7778.97 Electron/42.1.0 Safari/537.36"
        )

      conn = Endpoint.maybe_live_reloader(conn, [])

      refute conn.private[:phoenix_live_reload]
    end

    test "skips Phoenix LiveReloader for local Codex Desktop in-app browser sessions" do
      conn =
        conn(:get, "/login")
        |> Map.put(:host, "localhost")
        |> put_req_header("user-agent", @codex_desktop_in_app_browser_user_agent)

      conn = Endpoint.maybe_live_reloader(conn, [])

      refute conn.private[:phoenix_live_reload]
    end
  end
end
