defmodule CodexPoolerWeb.ObservatoryAuth do
  @moduledoc """
  LiveView authentication for the dedicated Observatory browser session.
  """

  use CodexPoolerWeb, :live_view

  alias CodexPooler.Access
  alias CodexPooler.Events

  @handoff_key "observatory_handoff"
  @handoff_private_key :codex_pooler_observatory_handoff
  @revalidation_timer_private_key :codex_pooler_observatory_revalidation_timer
  @revalidation_message :codex_pooler_observatory_revalidate
  # PostgreSQL NOTIFY is advisory; this bounded canonical check closes missed-relay gaps.
  @revalidation_interval_ms 30_000
  @login_path "/observatory/login"

  @spec revalidation_message() :: atom()
  def revalidation_message, do: @revalidation_message

  @spec live_session(Plug.Conn.t()) :: map()
  def live_session(conn) do
    case Plug.Conn.get_session(conn, @handoff_key) do
      %{dashboard_session_id: dashboard_session_id} = handoff
      when map_size(handoff) == 1 and is_binary(dashboard_session_id) ->
        %{@handoff_key => handoff}

      _missing_or_invalid_handoff ->
        %{}
    end
  end

  @spec on_mount(:require_authenticated, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_authenticated, _params, session, socket) do
    handoff = Map.get(session, @handoff_key)

    with {:ok, principal} <-
           Access.authenticate_dashboard_session_handoff(handoff),
         :ok <- subscribe_if_connected(socket, principal.api_key_id) do
      socket =
        socket
        |> assign(:dashboard_principal, principal)
        |> Phoenix.LiveView.put_private(@handoff_private_key, handoff)
        |> schedule_revalidation()

      {:cont, socket}
    else
      _invalid_session -> {:halt, Phoenix.LiveView.redirect(socket, to: @login_path)}
    end
  end

  @spec revalidate(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def revalidate(socket) do
    case Access.authenticate_dashboard_session_handoff(socket.private[@handoff_private_key]) do
      {:ok, principal} ->
        {:ok,
         socket
         |> assign(:dashboard_principal, principal)
         |> schedule_revalidation()}

      {:error, _reason} ->
        {:error, Phoenix.LiveView.redirect(socket, to: @login_path)}
    end
  end

  defp subscribe_if_connected(socket, api_key_id) do
    if connected?(socket), do: Events.subscribe_dashboard_sessions(api_key_id), else: :ok
  end

  defp schedule_revalidation(socket) do
    if connected?(socket) do
      socket
      |> cancel_revalidation_timer()
      |> Phoenix.LiveView.put_private(
        @revalidation_timer_private_key,
        Process.send_after(self(), @revalidation_message, @revalidation_interval_ms)
      )
    else
      socket
    end
  end

  defp cancel_revalidation_timer(socket) do
    case socket.private[@revalidation_timer_private_key] do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      _missing_timer -> :ok
    end

    Phoenix.LiveView.put_private(socket, @revalidation_timer_private_key, nil)
  end
end
