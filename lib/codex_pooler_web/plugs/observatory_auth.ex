defmodule CodexPoolerWeb.Plugs.ObservatoryAuth do
  @moduledoc """
  Authenticates the Observatory browser cookie at the request boundary.

  The LiveView handoff stores only the dashboard-session row identifier in the
  signed Phoenix session. The raw browser token never enters assigns or
  rendered UI.
  """

  import Plug.Conn

  alias CodexPooler.Access

  @cookie_name "_codex_pooler_observatory_token"
  @handoff_key "observatory_handoff"
  @login_path "/observatory/login"

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn = conn |> fetch_cookies() |> delete_session(@handoff_key)

    case Map.get(get_cookies(conn), @cookie_name) do
      token when is_binary(token) -> authenticate(conn, token)
      _missing_cookie -> redirect_to_login(conn)
    end
  end

  defp authenticate(conn, token) do
    with {:ok, principal} <- Access.authenticate_dashboard_session(token),
         handoff when is_map(handoff) <- Access.dashboard_session_handoff(token) do
      conn
      |> put_session(@handoff_key, handoff)
      |> assign(:dashboard_principal, principal)
    else
      _invalid_session -> redirect_to_login(conn)
    end
  end

  defp redirect_to_login(conn) do
    conn
    |> Phoenix.Controller.redirect(to: @login_path)
    |> halt()
  end
end
