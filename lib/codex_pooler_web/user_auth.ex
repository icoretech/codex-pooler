defmodule CodexPoolerWeb.UserAuth do
  @moduledoc false
  use CodexPoolerWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{Scope, SessionNotifier}

  @session_key :user_token

  def log_in_user(conn, user, token) when is_binary(token) do
    user_return_to = get_session(conn, :user_return_to)

    redirect_to =
      if password_change_required?(user),
        do: ~p"/password/change-required",
        else: safe_return_to_path(user_return_to) || signed_in_path(user)

    conn
    |> put_user_session(user, token)
    |> redirect(to: redirect_to)
  end

  def replace_user_session(conn, user, token) when is_binary(token) do
    put_user_session(conn, user, token)
  end

  def log_out_user(conn) do
    token = get_session(conn, @session_key)

    if token do
      if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
        Accounts.logout_user(token, conn.assigns.current_scope.user, request_metadata(conn))
      else
        Accounts.delete_user_session_token(token)
      end

      CodexPoolerWeb.Endpoint.broadcast(
        SessionNotifier.user_session_topic(token),
        "disconnect",
        %{}
      )
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  def fetch_current_scope_for_user(conn, _opts) do
    if token = get_session(conn, @session_key) do
      case Accounts.authenticate_session_token(token) do
        {user, _session_inserted_at} ->
          assign(conn, :current_scope, Scope.for_user(user))

        nil ->
          assign(conn, :current_scope, Scope.for_user(nil))
      end
    else
      assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn token ->
      CodexPoolerWeb.Endpoint.broadcast(
        SessionNotifier.user_session_topic(token),
        "disconnect",
        %{}
      )
    end)
  end

  def disconnect_user_sessions(user_id, opts \\ []) when is_binary(user_id) do
    SessionNotifier.disconnect_user_sessions(user_id, opts)
  end

  def disconnect_user_session(user_id, session_id)
      when is_binary(user_id) and is_binary(session_id) do
    SessionNotifier.disconnect_user_session(user_id, session_id)
  end

  def user_sessions_topic(user_id), do: SessionNotifier.user_sessions_topic(user_id)

  def live_socket_id_for_token(token), do: SessionNotifier.live_socket_id_for_token(token)

  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  def on_mount(:require_authenticated_password_current, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    cond do
      is_nil(socket.assigns.current_scope) or is_nil(socket.assigns.current_scope.user) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: ~p"/login")

        {:halt, socket}

      password_change_required?(socket.assigns.current_scope.user) ->
        socket = Phoenix.LiveView.redirect(socket, to: ~p"/password/change-required")
        {:halt, socket}

      true ->
        {:cont, socket}
    end
  end

  def signed_in_path(_user), do: ~p"/admin/pools"

  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def request_metadata(conn) do
    %{
      ip_address: remote_ip(conn),
      request_id: List.first(get_resp_header(conn, "x-request-id")),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    }
  end

  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        with token when is_binary(token) <- session[Atom.to_string(@session_key)],
             {user, _session_inserted_at} <- Accounts.authenticate_session_token(token) do
          Scope.for_user(user)
        else
          _ -> Scope.for_user(nil)
        end
      end)

    mount_user_session_disconnect(socket, session)
  end

  defp mount_user_session_disconnect(socket, session) do
    case {session[Atom.to_string(@session_key)], socket.assigns} do
      {token, %{current_scope: %{user: %{id: user_id}}}} when is_binary(token) ->
        subscribe_user_session_disconnect(socket, token, user_id)

      _other ->
        socket
    end
  end

  defp subscribe_user_session_disconnect(socket, token, user_id) do
    socket =
      Phoenix.Component.assign(
        socket,
        user_live_socket_id: SessionNotifier.user_session_topic(token),
        user_session_id: Accounts.session_id_for_token(token)
      )

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(CodexPooler.PubSub, SessionNotifier.user_sessions_topic(user_id))
      attach_user_session_disconnect_hook(socket, user_id)
    else
      socket
    end
  end

  defp attach_user_session_disconnect_hook(socket, user_id) do
    Phoenix.LiveView.attach_hook(socket, :user_session_revocation, :handle_info, fn
      {:disconnect_user_sessions,
       %{user_id: ^user_id, except_live_socket_id: except_live_socket_id}},
      socket ->
        disconnect_or_keep_user_session(socket, except_live_socket_id)

      {:disconnect_user_sessions, %{user_id: ^user_id, session_id: session_id}}, socket ->
        disconnect_or_keep_user_session_by_id(socket, session_id)

      {:disconnect_user_sessions, _payload}, socket ->
        {:halt, socket}

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp disconnect_or_keep_user_session(socket, except_live_socket_id) do
    if socket.assigns.user_live_socket_id == except_live_socket_id do
      {:halt, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp disconnect_or_keep_user_session_by_id(socket, session_id) do
    if socket.assigns.user_session_id == session_id do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    else
      {:halt, socket}
    end
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_user_session(conn, user, token) do
    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, SessionNotifier.user_session_topic(token))
    |> assign(:current_scope, Scope.for_user(user))
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  defp safe_return_to_path(return_to) when is_binary(return_to) do
    if String.starts_with?(return_to, "/") and not String.starts_with?(return_to, "//") do
      return_to
    end
  end

  defp safe_return_to_path(_return_to), do: nil

  defp password_change_required?(%{password_change_required: true}), do: true
  defp password_change_required?(_user), do: false

  defp remote_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
