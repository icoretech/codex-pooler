defmodule CodexPoolerWeb.ObservatoryControllerTestHelpers do
  @moduledoc """
  Shared request helpers for the Observatory controller tests.
  """

  import ExUnit.Assertions

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Repo

  @login_path "/observatory/login"
  @logout_path "/observatory/logout"
  @cookie_name "_codex_pooler_observatory_token"

  def post_login(conn, endpoint, body) do
    conn = Phoenix.ConnTest.dispatch(conn, endpoint, :get, @login_path)

    Phoenix.ConnTest.dispatch(
      conn,
      endpoint,
      :post,
      @login_path,
      Map.put(body, "_csrf_token", csrf_token_from(conn.resp_body))
    )
  end

  def logout(conn, endpoint) do
    conn = Phoenix.ConnTest.dispatch(conn, endpoint, :get, @login_path)

    Phoenix.ConnTest.dispatch(
      conn,
      endpoint,
      :delete,
      @logout_path,
      %{"_csrf_token" => csrf_token_from(conn.resp_body)}
    )
  end

  def csrf_token_from(html) do
    [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, html)
    token
  end

  def flash_error(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

  def assert_empty_api_key_input!(html) do
    [input] = Regex.run(~r/<input[^>]*id="observatory-api-key"[^>]*>/, html)
    refute input =~ "value="
  end

  def assert_cleared_observatory_cookie!(conn) do
    cookie = Plug.Conn.get_resp_cookies(conn)[@cookie_name]

    assert cookie[:max_age] == 0
    assert cookie[:http_only]
    assert cookie[:same_site] == "Lax"
    assert cookie[:path] == "/"
    assert Map.get(cookie, :secure, false) == (conn.scheme == :https)
  end

  def enable_dashboard_access!(%APIKey{} = api_key) do
    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  def capture_log_and_result(fun) do
    parent = self()

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        send(parent, {:observatory_result, fun.()})
      end)

    result =
      receive do
        {:observatory_result, result} -> result
      after
        5_000 -> flunk("timed out waiting for Observatory controller result")
      end

    {result, logs}
  end
end
