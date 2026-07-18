defmodule CodexPoolerWeb.Observatory.LoginController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Access

  import Phoenix.Component, only: [to_form: 2]

  @cookie_name "_codex_pooler_observatory_token"
  @cookie_max_age 14 * 24 * 60 * 60
  @login_path "/observatory/login"
  @invalid_copy "The API key is invalid or unavailable."

  def new(conn, _params) do
    render_login(conn)
  end

  def create(%Plug.Conn{body_params: body_params, query_string: query_string} = conn, _params) do
    raw_api_key = exchange_candidate(body_params, query_string)

    case Access.issue_dashboard_session(raw_api_key) do
      {:ok, %{token: token}} ->
        conn
        |> delete_session(:user_token)
        |> delete_session(:live_socket_id)
        |> configure_session(renew: true)
        |> discard_params()
        |> put_resp_cookie(@cookie_name, token,
          http_only: true,
          same_site: "Lax",
          max_age: @cookie_max_age,
          path: "/",
          secure: conn.scheme == :https
        )
        |> redirect(to: "/observatory")

      _error ->
        render_login(conn, :unprocessable_entity)
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn = fetch_cookies(conn)
    :ok = Access.delete_dashboard_session(Map.get(get_cookies(conn), @cookie_name))

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> discard_params()
    |> delete_resp_cookie(@cookie_name,
      http_only: true,
      same_site: "Lax",
      path: "/",
      secure: conn.scheme == :https
    )
    |> redirect(to: @login_path)
  end

  defp observatory_api_key(%{"observatory" => %{"api_key" => raw_api_key}} = params)
       when is_binary(raw_api_key) and raw_api_key != "" do
    nested_params = Map.fetch!(params, "observatory")
    unexpected_params = Map.keys(params) -- ["observatory", "_csrf_token"]

    if Map.keys(nested_params) == ["api_key"] and unexpected_params == [] do
      {:ok, raw_api_key}
    else
      :error
    end
  end

  defp observatory_api_key(_params), do: :error

  defp exchange_candidate(body_params, "") do
    case observatory_api_key(body_params) do
      {:ok, raw_api_key} -> raw_api_key
      :error -> nil
    end
  end

  defp exchange_candidate(_body_params, _query_string), do: nil

  defp render_login(conn, status \\ :ok) do
    conn
    |> put_status(status)
    |> render(:new,
      page_title: "Observatory",
      form: to_form(%{}, as: :observatory),
      error: if(status == :ok, do: nil, else: @invalid_copy)
    )
  end

  defp discard_params(conn) do
    %{conn | params: %{}, body_params: %{}, query_params: %{}}
  end
end
