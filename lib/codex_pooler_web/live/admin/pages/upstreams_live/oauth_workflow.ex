defmodule CodexPoolerWeb.Admin.UpstreamsLive.OAuthWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.OAuthCallback
  alias CodexPooler.Upstreams.Schemas.OAuthFlow
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @spec form(String.t(), String.t()) :: Phoenix.HTML.Form.t()
  def form(pool_id \\ "", callback_url \\ "") do
    to_form(
      %{
        "pool_id" => pool_id,
        "callback_url" => callback_url
      },
      as: :oauth_link
    )
  end

  @spec open_link(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                         Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def open_link(socket, params, close_workflows_fun) do
    pool_id = link_pool_id_for_open(socket.assigns.pools, params)

    {:noreply,
     socket
     |> close_workflows_fun.()
     |> assign(
       oauth_linking: true,
       oauth_link_mode: :link,
       oauth_link_target_account: nil,
       oauth_link_form: form(pool_id),
       oauth_link_pool_id: pool_id
     )}
  end

  @spec open_relink(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def open_relink(socket, identity_id, close_workflows_fun) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      account ->
        case relink_pool_id(account) do
          {:ok, pool_id} ->
            {:noreply,
             socket
             |> close_workflows_fun.()
             |> assign(
               oauth_linking: true,
               oauth_link_mode: :relink,
               oauth_link_target_account: account,
               oauth_link_form: form(pool_id),
               oauth_link_pool_id: pool_id
             )}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  @spec validate_pool(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def validate_pool(socket, oauth_params) do
    if relink_mode?(socket) do
      {:noreply, socket}
    else
      pool_id = Map.get(oauth_params, "pool_id", "")

      {:noreply,
       assign(socket,
         oauth_link_pool_id: pool_id,
         oauth_link_form: form(pool_id),
         oauth_link_error: nil
       )}
    end
  end

  @spec start_browser(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def start_browser(socket, params) do
    begin_link(socket, params, &Upstreams.start_browser_oauth/3, &assign_browser_started/3)
  end

  @spec start_device(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def start_device(socket, params) do
    begin_link(socket, params, &Upstreams.start_device_oauth/3, &assign_device_started/3)
  end

  @spec submit_callback(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                               Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def submit_callback(socket, oauth_params, reload_fun) do
    callback_url = Map.get(oauth_params, "callback_url", "")

    case socket.assigns.oauth_link_flow do
      %OAuthFlow{id: flow_id} ->
        case Upstreams.complete_browser_oauth(
               socket.assigns.current_scope,
               flow_id,
               callback_url
             ) do
          {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
            {:noreply, complete_link(socket, flow, reload_fun)}

          {:ok, %{flow: %OAuthFlow{} = flow}} ->
            {:noreply,
             assign(socket,
               oauth_link_flow: flow,
               oauth_link_form: form(socket.assigns.oauth_link_pool_id)
             )}

          {:error, reason} ->
            {:noreply, assign_error(socket, reason)}
        end

      nil ->
        {:noreply, assign_error(socket, OAuthCallback.safe_error(:flow_not_pending))}
    end
  end

  @spec cancel(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def cancel(socket) do
    socket = cancel_poll_timer(socket)

    case socket.assigns.oauth_link_flow do
      %OAuthFlow{id: flow_id, status: "pending"} ->
        case Upstreams.cancel_oauth_flow(socket.assigns.current_scope, flow_id) do
          {:ok, _flow} ->
            {:noreply, close(socket)}

          {:error, reason} ->
            {:noreply, assign_error(socket, reason)}
        end

      _flow ->
        {:noreply, close(socket)}
    end
  end

  @spec poll_device(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def poll_device(socket, flow_id, reload_fun) do
    socket = assign(socket, oauth_link_poll_timer: nil)

    if flow_id?(socket.assigns.oauth_link_flow, flow_id) do
      do_poll_device(socket, flow_id, reload_fun)
    else
      {:noreply, socket}
    end
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> cancel_poll_timer()
    |> assign(
      oauth_linking: false,
      oauth_link_mode: :link,
      oauth_link_target_account: nil,
      oauth_link_form: form(),
      oauth_link_pool_id: "",
      oauth_link_flow: nil,
      oauth_link_authorization_url: nil,
      oauth_link_result: nil,
      oauth_link_error: nil
    )
  end

  defp begin_link(socket, params, start_oauth, assign_started) do
    case selected_oauth_pool(socket, params) do
      nil ->
        {:noreply, assign_error(socket, OAuthCallback.safe_error(:unauthorized_pool))}

      pool ->
        case start_oauth.(socket.assigns.current_scope, pool, start_opts(socket)) do
          {:ok, result} ->
            {:noreply, assign_started.(socket, pool, result)}

          {:error, reason} ->
            {:noreply, assign_error(socket, reason)}
        end
    end
  end

  defp assign_browser_started(
         socket,
         pool,
         %{flow: %OAuthFlow{} = flow, authorization_url: authorization_url}
       ) do
    socket
    |> cancel_poll_timer()
    |> assign_pending(pool.id, flow, "Browser authorization pending", authorization_url)
  end

  defp assign_device_started(socket, pool, %{flow: %OAuthFlow{} = flow}) do
    socket
    |> assign_pending(pool.id, flow, "Device authorization pending", nil)
    |> schedule_device_poll(flow)
  end

  defp do_poll_device(socket, flow_id, reload_fun) do
    case Upstreams.poll_device_oauth(socket.assigns.current_scope, flow_id) do
      {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
        {:noreply, complete_link(socket, flow, reload_fun)}

      {:ok, %{status: :pending, flow: %OAuthFlow{} = flow}} ->
        {:noreply,
         socket
         |> assign_pending(
           socket.assigns.oauth_link_pool_id,
           flow,
           "Device authorization pending",
           nil
         )
         |> schedule_device_poll(flow)}

      {:ok, %{flow: %OAuthFlow{} = flow}} ->
        {:noreply,
         assign(socket,
           oauth_link_flow: flow,
           oauth_link_form: form(socket.assigns.oauth_link_pool_id)
         )}

      {:error, reason} ->
        {:noreply, assign_error(socket, reason)}
    end
  end

  defp complete_link(socket, %OAuthFlow{} = flow, reload_fun) do
    socket
    |> cancel_poll_timer()
    |> assign_completed(flow)
    |> reload_fun.()
  end

  defp assign_pending(socket, pool_id, %OAuthFlow{} = flow, message, authorization_url) do
    assign(socket,
      oauth_link_flow: flow,
      oauth_link_authorization_url: authorization_url,
      oauth_link_result: %{message: message},
      oauth_link_error: nil,
      oauth_link_pool_id: pool_id,
      oauth_link_form: form(pool_id)
    )
  end

  defp assign_completed(socket, %OAuthFlow{} = flow) do
    assign(socket,
      oauth_link_flow: flow,
      oauth_link_authorization_url: nil,
      oauth_link_result: %{message: complete_message(socket)},
      oauth_link_error: nil,
      oauth_link_form: form(socket.assigns.oauth_link_pool_id)
    )
  end

  defp complete_message(socket) do
    if relink_mode?(socket), do: "OpenAI account relinked", else: "OpenAI account linked"
  end

  defp schedule_device_poll(
         socket,
         %OAuthFlow{flow_kind: "device", status: "pending", interval_seconds: interval_seconds} =
           flow
       ) do
    socket = cancel_poll_timer(socket)
    delay_ms = max(positive_integer(interval_seconds, 5) * 1_000, 1_000)
    timer = Process.send_after(self(), {:poll_oauth_device, flow.id}, delay_ms)
    assign(socket, :oauth_link_poll_timer, timer)
  end

  defp schedule_device_poll(socket, _flow), do: socket

  defp cancel_poll_timer(socket) do
    if is_reference(socket.assigns[:oauth_link_poll_timer]) do
      Process.cancel_timer(socket.assigns.oauth_link_poll_timer, async: false, info: false)
    end

    assign(socket, :oauth_link_poll_timer, nil)
  end

  defp selected_oauth_pool(socket, params) do
    if relink_mode?(socket) do
      selected_pool(socket.assigns.pools, socket.assigns.oauth_link_pool_id)
    else
      selected_link_pool(socket, params)
    end
  end

  defp selected_link_pool(socket, params) do
    pool_id = link_pool_id_from_params(params) || socket.assigns.oauth_link_pool_id
    selected_pool(socket.assigns.pools, pool_id)
  end

  defp start_opts(socket) do
    opts = [metadata: %{"source" => "admin_upstreams"}]

    case socket.assigns.oauth_link_target_account do
      %{identity: %{id: identity_id}} when is_binary(identity_id) ->
        Keyword.put(opts, :upstream_identity_id, identity_id)

      _account ->
        opts
    end
  end

  defp relink_pool_id(%{identity: %{status: "deleted"}}),
    do: {:error, "OAuth relink is not available: deleted accounts cannot be relinked"}

  defp relink_pool_id(%{assignments: [%{pool_id: pool_id} | _assignments]})
       when is_binary(pool_id),
       do: {:ok, pool_id}

  defp relink_pool_id(_account),
    do: {:error, "OAuth relink is not available: assign this account to a visible Pool first"}

  defp relink_mode?(%{assigns: %{oauth_link_mode: :relink}}), do: true
  defp relink_mode?(_socket), do: false

  defp link_pool_id_from_params(%{"oauth_link" => %{"pool_id" => pool_id}})
       when is_binary(pool_id),
       do: pool_id

  defp link_pool_id_from_params(%{"pool-id" => pool_id}) when is_binary(pool_id), do: pool_id
  defp link_pool_id_from_params(_params), do: nil

  defp link_pool_id_for_open(pools, %{"pool-id" => pool_id}) do
    case selected_pool(pools, pool_id) do
      nil -> ""
      _pool -> pool_id
    end
  end

  defp link_pool_id_for_open(_pools, _params), do: ""

  defp assign_error(socket, reason) do
    assign(socket,
      oauth_link_error: %{message: WorkflowError.message(reason)},
      oauth_link_result: nil,
      oauth_link_form: form(socket.assigns.oauth_link_pool_id)
    )
  end

  defp flow_id?(%OAuthFlow{id: id}, id), do: true
  defp flow_id?(_flow, _id), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  defp selected_pool(_pools, _pool_id), do: nil

  defp find_account(accounts, identity_id) do
    Enum.find(accounts, &(&1.identity.id == identity_id))
  end
end
