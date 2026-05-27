defmodule CodexPoolerWeb.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CodexPoolerWeb.Endpoint

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
  end
end
