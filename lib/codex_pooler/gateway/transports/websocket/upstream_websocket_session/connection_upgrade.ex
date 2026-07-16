defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade do
  @moduledoc false

  @spec connect_state(map(), term(), binary(), Mint.Types.headers(), map()) ::
          {:ok, map()} | {:error, term(), map()}
  def connect_state(state, key, url, headers, timeouts) do
    with {:ok, target} <- websocket_target(url),
         {:ok, conn} <- connect_websocket(target, timeouts),
         {:ok, conn, ref} <- upgrade_websocket(conn, target, headers),
         {:ok, conn, response_headers} <- await_upgrade(conn, ref, timeouts) do
      finish_connection(state, key, conn, ref, response_headers)
    else
      {:error, reason} -> {:error, reason, state}
      {:error, conn, reason} -> {:error, reason, Map.put(state, :conn, conn)}
    end
  end

  defp connect_websocket(target, timeouts) do
    Mint.HTTP.connect(target.connect_scheme, target.host, target.port,
      protocols: [:http1],
      transport_opts: websocket_transport_opts(target, timeouts)
    )
  end

  defp upgrade_websocket(conn, target, headers) do
    case Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, headers) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, conn, reason} -> {:error, conn, reason}
    end
  end

  @spec new_websocket(
          Mint.HTTP.t(),
          Mint.Types.request_ref(),
          Mint.Types.headers()
        ) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t()} | {:error, Mint.HTTP.t(), term()}
  # Mint's Dialyzer contract narrows a status-101 websocket creation to success,
  # but the runtime boundary can still reject mismatched refs, headers, or state.
  @dialyzer {:no_match, new_websocket: 3}
  defp new_websocket(conn, ref, response_headers) do
    case Mint.WebSocket.new(conn, ref, 101, response_headers) do
      {:ok, conn, websocket} -> {:ok, conn, websocket}
      {:error, conn, reason} -> {:error, conn, reason}
    end
  end

  # Keep the defensive error branch paired with new_websocket/3 even though
  # Dialyzer inherits Mint's narrowed status-101 success type.
  @dialyzer {:no_match, finish_connection: 5}
  defp finish_connection(state, key, conn, ref, response_headers) do
    case new_websocket(conn, ref, response_headers) do
      {:ok, conn, websocket} ->
        connection_state = %{
          key: key,
          conn: conn,
          ref: ref,
          websocket: websocket,
          headers: response_headers
        }

        state =
          state
          |> Map.merge(connection_state)
          |> Map.update!(:generation, &(&1 + 1))

        {:ok, state}

      {:error, conn, reason} ->
        {:error, reason, Map.put(state, :conn, conn)}
    end
  end

  defp websocket_target(url) do
    uri = URI.parse(url)

    with scheme when scheme in ["http", "https"] <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host do
      connect_scheme = if scheme == "https", do: :https, else: :http
      ws_scheme = if scheme == "https", do: :wss, else: :ws
      port = uri.port || if(scheme == "https", do: 443, else: 80)
      path = websocket_path(uri)

      {:ok,
       %{connect_scheme: connect_scheme, ws_scheme: ws_scheme, host: host, port: port, path: path}}
    else
      _invalid -> {:error, :invalid_upstream_websocket_url}
    end
  end

  defp websocket_path(uri) do
    path = uri.path || "/"

    case uri.query do
      nil -> path
      query -> path <> "?" <> query
    end
  end

  defp websocket_transport_opts(%{connect_scheme: :https, host: host}, timeouts) do
    [timeout: timeouts.connect_timeout_ms, server_name_indication: String.to_charlist(host)]
  end

  defp websocket_transport_opts(_target, timeouts), do: [timeout: timeouts.connect_timeout_ms]

  defp await_upgrade(conn, ref, timeouts) do
    socket = mint_socket(conn)

    receive do
      {:tcp, ^socket, _data} = message ->
        handle_upgrade_message(conn, ref, timeouts, message)

      {:ssl, ^socket, _data} = message ->
        handle_upgrade_message(conn, ref, timeouts, message)

      {:tcp_closed, ^socket} = message ->
        handle_upgrade_message(conn, ref, timeouts, message)

      {:ssl_closed, ^socket} = message ->
        handle_upgrade_message(conn, ref, timeouts, message)

      {:tcp_error, ^socket, _reason} = message ->
        handle_upgrade_message(conn, ref, timeouts, message)

      {:ssl_error, ^socket, _reason} = message ->
        handle_upgrade_message(conn, ref, timeouts, message)
    after
      timeouts.connect_timeout_ms -> {:error, :upstream_websocket_upgrade_timeout}
    end
  end

  defp handle_upgrade_message(conn, ref, timeouts, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> upgrade_response(conn, ref, responses, timeouts)
      {:error, conn, reason, _responses} -> {:error, conn, reason}
      :unknown -> await_upgrade(conn, ref, timeouts)
    end
  end

  defp upgrade_response(conn, ref, responses, timeouts) do
    status = response_status(responses, ref)
    headers = response_headers(responses, ref)
    done? = Enum.any?(responses, &match?({:done, ^ref}, &1))

    cond do
      done? and status == 101 -> {:ok, conn, headers}
      done? and is_integer(status) -> {:error, conn, {:websocket_upgrade_failed, status, headers}}
      done? -> {:error, conn, :invalid_upstream_websocket_upgrade}
      true -> await_upgrade(conn, ref, timeouts)
    end
  end

  @spec response_status([Mint.Types.response()], Mint.Types.request_ref()) ::
          Mint.Types.status() | nil
  defp response_status(responses, ref) do
    Enum.find_value(responses, fn
      {:status, ^ref, status} -> status
      _part -> nil
    end)
  end

  @spec response_headers([Mint.Types.response()], Mint.Types.request_ref()) ::
          Mint.Types.headers()
  defp response_headers(responses, ref) do
    responses
    |> Enum.find_value([], fn
      {:headers, ^ref, headers} -> headers
      _part -> nil
    end)
    |> Enum.filter(fn
      {name, value} when is_binary(name) and is_binary(value) -> true
      _header -> false
    end)
  end

  defp mint_socket(conn), do: Mint.HTTP.get_socket(conn)
end
