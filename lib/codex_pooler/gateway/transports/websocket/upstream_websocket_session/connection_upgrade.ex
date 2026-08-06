defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade do
  @moduledoc false

  @type request_caller :: {pid(), reference()} | nil
  @connect_ready_tag :upstream_websocket_connect_ready
  @connect_result_tag :upstream_websocket_connect_result
  @connect_task_shutdown_timeout_ms 1_000

  @spec connect_state(map(), term(), binary(), Mint.Types.headers(), map(), request_caller()) ::
          {:ok, map()} | {:error, term(), map()}
  def connect_state(state, key, url, headers, timeouts, request_caller) do
    if request_caller_down?(request_caller) do
      {:error, :client_disconnected, state}
    else
      do_connect_state(state, key, url, headers, timeouts, request_caller)
    end
  end

  defp do_connect_state(state, key, url, headers, timeouts, request_caller) do
    with {:ok, target} <- websocket_target(url),
         {:ok, conn} <- connect_websocket(target, timeouts, request_caller),
         {:ok, conn, ref} <- upgrade_websocket(conn, target, headers, request_caller),
         {:ok, conn, response_headers} <- await_upgrade(conn, ref, timeouts, request_caller) do
      finish_connection(state, key, conn, ref, response_headers)
    else
      {:error, conn, :client_disconnected} ->
        {:ok, _conn} = Mint.HTTP.close(conn)
        {:error, :client_disconnected, state}

      {:error, reason} ->
        {:error, reason, state}

      {:error, conn, reason} ->
        {:error, reason, Map.put(state, :conn, conn)}
    end
  end

  defp connect_websocket(%{connect_scheme: :http} = target, timeouts, request_caller) do
    connect_in_task(target, timeouts, request_caller)
  end

  defp connect_websocket(%{connect_scheme: :https} = target, timeouts, request_caller) do
    raw_target = %{target | connect_scheme: :http}

    with {:ok, raw_conn} <- connect_in_task(raw_target, timeouts, request_caller) do
      upgrade_tls_connection(raw_conn, target, timeouts, request_caller)
    end
  end

  defp connect_in_task(target, timeouts, request_caller) do
    parent = self()

    {:ok, connect_pid} =
      Task.start(fn ->
        parent_monitor = Process.monitor(parent)

        result =
          Mint.HTTP.connect(target.connect_scheme, target.host, target.port,
            protocols: [:http1],
            transport_opts: websocket_transport_opts(target, timeouts)
          )

        send(parent, {@connect_ready_tag, self(), result})

        receive do
          {:accept_upstream_websocket_connection, ^parent} ->
            Process.demonitor(parent_monitor, [:flush])
            result = transfer_connection(result, parent)
            send(parent, {@connect_result_tag, self(), result})

          {:reject_upstream_websocket_connection, ^parent} ->
            Process.demonitor(parent_monitor, [:flush])
            close_connection(result)

          {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
            close_connection(result)
        end
      end)

    connect_monitor = Process.monitor(connect_pid)
    await_connect(connect_pid, connect_monitor, timeouts, request_caller)
  end

  defp upgrade_tls_connection(raw_conn, target, timeouts, request_caller) do
    watcher = start_tls_upgrade_caller_watcher(raw_conn, request_caller)

    result =
      Mint.HTTP.upgrade(
        :http,
        Mint.HTTP.get_socket(raw_conn),
        :https,
        target.host,
        target.port,
        protocols: [:http1],
        transport_opts: websocket_transport_opts(target, timeouts)
      )

    stop_tls_upgrade_caller_watcher(watcher)
    caller_down? = request_caller_down?(request_caller)

    case result do
      {:ok, conn} when caller_down? ->
        {:ok, _conn} = Mint.HTTP.close(conn)
        {:error, :client_disconnected}

      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:ok, _conn} = Mint.HTTP.close(raw_conn)
        if caller_down?, do: {:error, :client_disconnected}, else: {:error, reason}
    end
  end

  defp start_tls_upgrade_caller_watcher(
         raw_conn,
         {request_caller_pid, _request_caller_monitor}
       )
       when is_pid(request_caller_pid) do
    parent = self()

    spawn(fn ->
      caller_monitor = Process.monitor(request_caller_pid)
      parent_monitor = Process.monitor(parent)

      receive do
        :upstream_websocket_tls_upgrade_complete ->
          Process.demonitor(caller_monitor, [:flush])
          Process.demonitor(parent_monitor, [:flush])

        {:DOWN, ^caller_monitor, :process, ^request_caller_pid, _reason} ->
          Mint.HTTP.close(raw_conn)

        {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
          Mint.HTTP.close(raw_conn)
      end
    end)
  end

  defp start_tls_upgrade_caller_watcher(_raw_conn, _request_caller), do: nil

  defp stop_tls_upgrade_caller_watcher(watcher) when is_pid(watcher) do
    send(watcher, :upstream_websocket_tls_upgrade_complete)
    :ok
  end

  defp stop_tls_upgrade_caller_watcher(_watcher), do: :ok

  defp transfer_connection({:ok, conn}, parent) do
    case Mint.HTTP.controlling_process(conn, parent) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:ok, _conn} = Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp transfer_connection({:error, reason}, _parent), do: {:error, reason}

  defp close_connection({:ok, conn}) do
    {:ok, _conn} = Mint.HTTP.close(conn)
    :ok
  end

  defp close_connection({:error, _reason}), do: :ok

  defp await_connect(connect_pid, connect_monitor, timeouts, request_caller) do
    request_caller_pid = request_caller_pid(request_caller)
    request_caller_monitor = request_caller_monitor(request_caller)

    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason}
      when is_reference(request_caller_monitor) and is_pid(request_caller_pid) ->
        stop_connect_task(connect_pid, connect_monitor)
        {:error, :client_disconnected}

      {@connect_ready_tag, ^connect_pid, {:ok, _conn}} ->
        if request_caller_down?(request_caller) do
          stop_connect_task(connect_pid, connect_monitor)
          {:error, :client_disconnected}
        else
          send(connect_pid, {:accept_upstream_websocket_connection, self()})
          await_transferred_connection(connect_pid, connect_monitor, request_caller)
        end

      {@connect_ready_tag, ^connect_pid, {:error, reason}} ->
        send(connect_pid, {:reject_upstream_websocket_connection, self()})
        Process.demonitor(connect_monitor, [:flush])
        {:error, reason}

      {:DOWN, ^connect_monitor, :process, ^connect_pid, _reason} ->
        {:error, :upstream_websocket_connect_task_exited}
    after
      timeouts.connect_timeout_ms ->
        stop_connect_task(connect_pid, connect_monitor)
        {:error, :upstream_websocket_connect_timeout}
    end
  end

  defp await_transferred_connection(connect_pid, connect_monitor, request_caller) do
    request_caller_pid = request_caller_pid(request_caller)
    request_caller_monitor = request_caller_monitor(request_caller)

    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason}
      when is_reference(request_caller_monitor) and is_pid(request_caller_pid) ->
        close_transferred_connection(connect_pid, connect_monitor)
        {:error, :client_disconnected}

      {@connect_result_tag, ^connect_pid, {:ok, conn}} ->
        Process.demonitor(connect_monitor, [:flush])

        if request_caller_down?(request_caller) do
          {:ok, _conn} = Mint.HTTP.close(conn)
          {:error, :client_disconnected}
        else
          {:ok, conn}
        end

      {@connect_result_tag, ^connect_pid, {:error, reason}} ->
        Process.demonitor(connect_monitor, [:flush])

        if request_caller_down?(request_caller) do
          {:error, :client_disconnected}
        else
          {:error, reason}
        end

      {:DOWN, ^connect_monitor, :process, ^connect_pid, _reason} ->
        {:error, :upstream_websocket_connect_task_exited}
    end
  end

  defp close_transferred_connection(connect_pid, connect_monitor) do
    receive do
      {@connect_result_tag, ^connect_pid, {:ok, conn}} ->
        {:ok, _conn} = Mint.HTTP.close(conn)
        Process.demonitor(connect_monitor, [:flush])

      {@connect_result_tag, ^connect_pid, {:error, _reason}} ->
        Process.demonitor(connect_monitor, [:flush])

      {:DOWN, ^connect_monitor, :process, ^connect_pid, _reason} ->
        :ok
    end
  end

  defp stop_connect_task(connect_pid, connect_monitor) do
    if Process.alive?(connect_pid), do: Process.exit(connect_pid, :kill)

    receive do
      {:DOWN, ^connect_monitor, :process, ^connect_pid, _reason} -> :ok
    after
      @connect_task_shutdown_timeout_ms -> Process.demonitor(connect_monitor, [:flush])
    end
  end

  defp upgrade_websocket(conn, target, headers, request_caller) do
    if request_caller_down?(request_caller) do
      {:error, conn, :client_disconnected}
    else
      case Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, headers) do
        {:ok, conn, ref} -> {:ok, conn, ref}
        {:error, conn, reason} -> {:error, conn, reason}
      end
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
          headers: response_headers,
          connection_started_at_monotonic_ms: System.monotonic_time(:millisecond),
          connection_request_count: 0,
          last_request_completed_at_monotonic_ms: nil
        }

        state =
          state
          |> Map.merge(connection_state)
          |> Map.update!(:generation, &(&1 + 1))
          |> Map.delete(:reconnect_pending?)

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

  defp await_upgrade(conn, ref, timeouts, request_caller) do
    socket = mint_socket(conn)
    request_caller_pid = request_caller_pid(request_caller)
    request_caller_monitor = request_caller_monitor(request_caller)

    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason}
      when is_reference(request_caller_monitor) and is_pid(request_caller_pid) ->
        {:error, conn, :client_disconnected}

      {:tcp, ^socket, _data} = message ->
        handle_upgrade_message(conn, ref, timeouts, request_caller, message)

      {:ssl, ^socket, _data} = message ->
        handle_upgrade_message(conn, ref, timeouts, request_caller, message)

      {:tcp_closed, ^socket} = message ->
        handle_upgrade_message(conn, ref, timeouts, request_caller, message)

      {:ssl_closed, ^socket} = message ->
        handle_upgrade_message(conn, ref, timeouts, request_caller, message)

      {:tcp_error, ^socket, _reason} = message ->
        handle_upgrade_message(conn, ref, timeouts, request_caller, message)

      {:ssl_error, ^socket, _reason} = message ->
        handle_upgrade_message(conn, ref, timeouts, request_caller, message)
    after
      timeouts.connect_timeout_ms -> {:error, :upstream_websocket_upgrade_timeout}
    end
  end

  defp handle_upgrade_message(conn, ref, timeouts, request_caller, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> upgrade_response(conn, ref, responses, timeouts, request_caller)
      {:error, conn, reason, _responses} -> {:error, conn, reason}
      :unknown -> await_upgrade(conn, ref, timeouts, request_caller)
    end
  end

  defp upgrade_response(conn, ref, responses, timeouts, request_caller) do
    status = response_status(responses, ref)
    headers = response_headers(responses, ref)
    done? = Enum.any?(responses, &match?({:done, ^ref}, &1))

    cond do
      done? and status == 101 -> {:ok, conn, headers}
      done? and is_integer(status) -> {:error, conn, {:websocket_upgrade_failed, status, headers}}
      done? -> {:error, conn, :invalid_upstream_websocket_upgrade}
      true -> await_upgrade(conn, ref, timeouts, request_caller)
    end
  end

  defp request_caller_down?({request_caller_pid, request_caller_monitor})
       when is_pid(request_caller_pid) and is_reference(request_caller_monitor) do
    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp request_caller_down?(_request_caller), do: false

  defp request_caller_pid({request_caller_pid, _request_caller_monitor}), do: request_caller_pid
  defp request_caller_pid(_request_caller), do: nil

  defp request_caller_monitor({_request_caller_pid, request_caller_monitor}),
    do: request_caller_monitor

  defp request_caller_monitor(_request_caller), do: nil

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
