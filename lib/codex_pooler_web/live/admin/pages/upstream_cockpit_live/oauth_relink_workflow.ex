defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive.OAuthRelinkWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.OAuthCallback
  alias CodexPooler.Upstreams.Schemas.OAuthFlow

  @reason "admin_upstream_cockpit"

  @spec form(String.t()) :: Phoenix.HTML.Form.t()
  def form(callback_url \\ "") do
    to_form(%{"callback_url" => callback_url}, as: :oauth_relink)
  end

  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket) do
    assign(socket, oauth_relinking: true, oauth_relink_form: form())
  end

  @spec start_browser(Phoenix.LiveView.Socket.t(), map() | nil, (Phoenix.LiveView.Socket.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def start_browser(socket, pool, refresh_fun) do
    start_oauth_relink(socket, pool, :browser, refresh_fun)
  end

  @spec start_device(Phoenix.LiveView.Socket.t(), map() | nil, (Phoenix.LiveView.Socket.t() ->
                                                                  Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def start_device(socket, pool, refresh_fun) do
    start_oauth_relink(socket, pool, :device, refresh_fun)
  end

  @spec submit_callback(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                               Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def submit_callback(socket, oauth_params, refresh_fun) do
    callback_url = Map.get(oauth_params, "callback_url", "")

    case socket.assigns.oauth_relink_flow do
      %OAuthFlow{id: flow_id} ->
        case Upstreams.complete_browser_oauth(
               socket.assigns.current_scope,
               flow_id,
               callback_url
             ) do
          {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
            complete(socket, flow, refresh_fun)

          {:ok, %{flow: %OAuthFlow{} = flow}} ->
            assign(socket,
              oauth_relink_flow: flow,
              oauth_relink_form: form()
            )

          {:error, reason} ->
            socket
            |> assign_error(reason)
            |> refresh_fun.()
        end

      nil ->
        assign_error(socket, OAuthCallback.safe_error(:flow_not_pending))
    end
  end

  @spec cancel(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                               Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def cancel(socket, refresh_fun) do
    socket = cancel_poll_timer(socket)

    case socket.assigns.oauth_relink_flow do
      %OAuthFlow{id: flow_id, status: "pending"} ->
        case Upstreams.cancel_oauth_flow(socket.assigns.current_scope, flow_id) do
          {:ok, _flow} ->
            socket |> close() |> refresh_fun.()

          {:error, reason} ->
            assign_error(socket, reason)
        end

      _flow ->
        close(socket)
    end
  end

  @spec poll_device(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def poll_device(socket, flow_id, refresh_fun) do
    socket = assign(socket, :oauth_relink_poll_timer, nil)

    if flow_id?(socket.assigns.oauth_relink_flow, flow_id) do
      do_poll_device(socket, flow_id, refresh_fun)
    else
      socket
    end
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> cancel_poll_timer()
    |> assign(
      oauth_relinking: false,
      oauth_relink_form: form(),
      oauth_relink_flow: nil,
      oauth_relink_authorization_url: nil,
      oauth_relink_result: nil,
      oauth_relink_error: nil
    )
  end

  @spec cancel_poll_timer(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel_poll_timer(socket) do
    if is_reference(socket.assigns[:oauth_relink_poll_timer]) do
      Process.cancel_timer(socket.assigns.oauth_relink_poll_timer, async: false, info: false)
    end

    assign(socket, :oauth_relink_poll_timer, nil)
  end

  @spec flow_id?(OAuthFlow.t() | nil, Ecto.UUID.t()) :: boolean()
  def flow_id?(%OAuthFlow{id: id}, id), do: true
  def flow_id?(_flow, _id), do: false

  defp start_oauth_relink(socket, nil, _mode, _refresh_fun) do
    assign_error(socket, OAuthCallback.safe_error(:unauthorized_pool))
  end

  defp start_oauth_relink(socket, pool, mode, refresh_fun) do
    case do_start_oauth_relink(socket, pool, mode) do
      {:ok, result} ->
        socket
        |> assign_started(mode, result)
        |> refresh_fun.()

      {:error, reason} ->
        assign_error(socket, reason)
    end
  end

  defp do_start_oauth_relink(socket, pool, :browser) do
    Upstreams.start_browser_oauth(socket.assigns.current_scope, pool, start_opts(socket))
  end

  defp do_start_oauth_relink(socket, pool, :device) do
    Upstreams.start_device_oauth(socket.assigns.current_scope, pool, start_opts(socket))
  end

  defp start_opts(socket) do
    [
      upstream_identity_id: socket.assigns.cockpit.identity.id,
      metadata: %{"source" => @reason}
    ]
  end

  defp assign_started(socket, :browser, result), do: assign_browser_started(socket, result)
  defp assign_started(socket, :device, result), do: assign_device_started(socket, result)

  defp assign_browser_started(
         socket,
         %{flow: %OAuthFlow{} = flow, authorization_url: authorization_url}
       ) do
    socket
    |> cancel_poll_timer()
    |> assign_pending(flow, "Browser authorization pending", authorization_url)
  end

  defp assign_device_started(socket, %{flow: %OAuthFlow{} = flow}) do
    socket
    |> assign_pending(flow, "Device authorization pending", nil)
    |> schedule_device_poll(flow)
  end

  defp do_poll_device(socket, flow_id, refresh_fun) do
    case Upstreams.poll_device_oauth(socket.assigns.current_scope, flow_id) do
      {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
        complete(socket, flow, refresh_fun)

      {:ok, %{status: :pending, flow: %OAuthFlow{} = flow}} ->
        socket
        |> assign_pending(flow, "Device authorization pending", nil)
        |> refresh_fun.()
        |> schedule_device_poll(flow)

      {:ok, %{flow: %OAuthFlow{} = flow}} ->
        assign(socket, oauth_relink_flow: flow, oauth_relink_form: form())

      {:error, reason} ->
        socket
        |> assign_error(reason)
        |> refresh_fun.()
    end
  end

  defp complete(socket, %OAuthFlow{} = flow, refresh_fun) do
    socket
    |> cancel_poll_timer()
    |> assign(
      oauth_relink_flow: flow,
      oauth_relink_authorization_url: nil,
      oauth_relink_result: %{message: "OpenAI account relinked"},
      oauth_relink_error: nil,
      oauth_relink_form: form()
    )
    |> refresh_fun.()
  end

  defp assign_pending(socket, %OAuthFlow{} = flow, message, authorization_url) do
    assign(socket,
      oauth_relink_flow: flow,
      oauth_relink_authorization_url: authorization_url,
      oauth_relink_result: %{message: message},
      oauth_relink_error: nil,
      oauth_relink_form: form()
    )
  end

  defp schedule_device_poll(
         socket,
         %OAuthFlow{flow_kind: "device", status: "pending", interval_seconds: interval_seconds} =
           flow
       ) do
    socket = cancel_poll_timer(socket)
    delay_ms = max(positive_integer(interval_seconds, 5) * 1_000, 1_000)
    timer = Process.send_after(self(), {:poll_oauth_relink_device, flow.id}, delay_ms)
    assign(socket, :oauth_relink_poll_timer, timer)
  end

  defp schedule_device_poll(socket, _flow), do: socket

  defp assign_error(socket, reason) do
    assign(socket,
      oauth_relink_error: %{message: error_message(reason)},
      oauth_relink_result: nil,
      oauth_relink_form: form()
    )
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"
end
