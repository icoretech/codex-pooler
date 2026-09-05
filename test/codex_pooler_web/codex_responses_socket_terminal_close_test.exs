defmodule CodexPoolerWeb.CodexResponsesSocketTerminalCloseTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPoolerWeb.CodexResponsesSocket

  @detection_timeout 15_000

  defmodule Endpoint do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn
      |> WebSockAdapter.upgrade(__MODULE__.Socket, Map.new(opts), compress: false)
      |> halt()
    end

    defmodule Socket do
      @moduledoc false
      @behaviour WebSock

      @impl WebSock
      def init(%{parent: parent, registry: registry, order: order} = config) do
        socket = self()

        {:ok, task} =
          ResponseTask.start(
            socket,
            :proxy,
            fn task ->
              send(parent, {:callback_ready, socket, task})

              receive do
                {:deliver, type} ->
                  data =
                    Jason.encode!(%{
                      "type" => type,
                      "response" => %{"id" => "resp_terminal_close"}
                    })

                  send(socket, {:codex_response_chunk, task, data})
              end

              if order in [:terminal_first, :active_callback, :failed_callback, :error_callback] do
                receive do
                  :finish_callback -> :ok
                end
              end

              if order == :failed_callback, do: raise("synthetic callback failure")
              send(parent, :callback_finished)

              if order == :error_callback,
                do: {:response_task_failure, {:error, :websocket_response_task_failed}},
                else: :ok
            end,
            fn _task, _reason -> :ok end,
            activity_registry: registry
          )

        state = %{
          auth: nil,
          opts: RequestOptions.for_websocket(%{}),
          codex_session: nil,
          upstream_websocket_session: nil,
          request_response_work_started?: true,
          tasks: MapSet.new([task]),
          task_monitors: %{task => Process.monitor(task)},
          queued_response_payloads: :queue.new(),
          response_task_activity_registry: registry
        }

        {:ok, %{config: config, task: task, socket_state: state}}
      end

      @impl WebSock
      def handle_in(_frame, state), do: {:ok, state}

      @impl WebSock
      def handle_info(
            {:codex_response_chunk, _, _} = message,
            %{config: %{order: :result_first}} = state
          ) do
        {:ok, Map.put(state, :held_terminal, message)}
      end

      def handle_info({:codex_response_done, _, _} = message, state) do
        {:ok, socket_state} = CodexResponsesSocket.handle_info(message, state.socket_state)
        if Map.has_key?(state, :held_terminal), do: send(self(), :release_terminal)
        {:ok, %{state | socket_state: socket_state}}
      end

      def handle_info(:release_terminal, %{held_terminal: message} = state) do
        {:push, frame, socket_state} =
          CodexResponsesSocket.handle_info(message, state.socket_state)

        send(state.config.parent, :result_before_terminal_push)
        {:push, frame, %{state | socket_state: socket_state}}
      end

      def handle_info({:websocket_response_delivery_complete, _, _} = message, state) do
        send(state.config.parent, :delivery_ack_held)
        {:ok, Map.put(state, :held_ack, message)}
      end

      def handle_info(:release_ack, %{held_ack: message} = state) do
        {:ok, socket_state} = CodexResponsesSocket.handle_info(message, state.socket_state)
        send(state.config.parent, :delivery_ack_processed)
        {:ok, %{state | socket_state: socket_state}}
      end

      def handle_info(:queue_terminal, state) do
        message = {:codex_response_chunk, state.task, completed_terminal()}
        send(state.config.parent, :unaccepted_terminal_queued)
        {:ok, Map.put(state, :queued_terminal, message)}
      end

      def handle_info(:stale_terminal, state) do
        message = {:codex_response_chunk, state.config.parent, completed_terminal()}
        {:ok, socket_state} = CodexResponsesSocket.handle_info(message, state.socket_state)
        send(state.config.parent, :stale_terminal_dropped)
        {:ok, %{state | socket_state: socket_state}}
      end

      def handle_info({:websocket_response_activity_cancelled, _, _, _}, state) do
        send(state.config.parent, :cancellation_pending)
        {:ok, state}
      end

      def handle_info(message, state) do
        case CodexResponsesSocket.handle_info(message, state.socket_state) do
          {:ok, socket_state} -> {:ok, %{state | socket_state: socket_state}}
          {:push, frame, socket_state} -> {:push, frame, %{state | socket_state: socket_state}}
        end
      end

      @impl WebSock
      def terminate(reason, state) do
        unless state.config.order == :active_callback, do: send(state.task, :finish_callback)
        :ok = CodexResponsesSocket.terminate(reason, state.socket_state)
        send(state.config.parent, {:socket_terminated, reason})
      end

      defp completed_terminal do
        Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_stale"}})
      end
    end
  end

  test "client close after terminal delivery preserves completion before queued delivery ack" do
    assert_close_outcome(:result_first, "response.completed", false, :completed)
  end

  test "client close after terminal preserves callback completion during cleanup" do
    assert_close_outcome(:terminal_first, "response.completed", false, :completed)
  end

  test "client close after processed terminal acknowledgement stays completed" do
    assert_close_outcome(:result_first, "response.completed", true, :completed)
  end

  test "client close after nonterminal data remains aborted" do
    assert_close_outcome(:result_first, "response.created", false, :aborted)
  end

  test "client close after failed terminal does not claim successful completion" do
    assert_close_outcome(:terminal_first, "response.failed", false, :aborted)
  end

  test "queued unaccepted terminal cannot complete another active activity" do
    assert_close_outcome(:result_first, "response.created", :queue_terminal, :aborted)
  end

  test "stale task terminal cannot complete the current activity" do
    assert_close_outcome(:result_first, "response.created", :stale_terminal, :aborted)
  end

  test "completed terminal cannot complete an unsettled callback" do
    assert_close_outcome(:active_callback, "response.completed", false, :failed)
  end

  test "pending cancellation prevents cleanup from declaring natural completion" do
    assert_close_outcome(:result_first, "response.completed", :cancel, :aborted)
  end

  test "completed terminal cannot convert a failed callback into completion" do
    assert_close_outcome(:failed_callback, "response.completed", false, :aborted)
  end

  test "completed terminal cannot convert a returned callback error into completion" do
    assert_close_outcome(:error_callback, "response.completed", false, :aborted)
  end

  defp assert_close_outcome(order, type, release_ack?, expected) do
    registry = start_supervised!({ActivityRegistry, name: nil})

    server =
      start_supervised!(
        {Bandit,
         plug: {Endpoint, parent: self(), registry: registry, order: order},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {conn, websocket, ref} = connect(port)
    assert_receive {:callback_ready, socket, task}, @detection_timeout
    monitor = Process.monitor(task)

    {_epoch, [%{token: token, kind: :proxy}]} = ActivityRegistry.begin_drain(name: registry)
    send(task, {:deliver, type})
    {conn, types} = receive_frames(conn, websocket, ref)
    assert types == [type]

    if type == "response.completed" and order == :result_first do
      assert_receive :result_before_terminal_push, @detection_timeout
      assert_receive :delivery_ack_held, @detection_timeout
      assert_receive :callback_finished, @detection_timeout
    end

    apply_close_control(release_ack?, socket, task, monitor, registry, token)

    assert {:ok, _closed} = Mint.HTTP.close(conn)
    assert_receive {:socket_terminated, {:error, :closed}}, @detection_timeout

    unless release_ack? == true do
      if order == :active_callback do
        assert_receive {:DOWN, ^monitor, :process, ^task, {:shutdown, :websocket_terminated}},
                       @detection_timeout
      else
        assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, @detection_timeout
      end
    end

    assert ActivityRegistry.status(token, name: registry) == {:finished, expected}
    assert ActivityRegistry.activities(name: registry) == []
  end

  defp apply_close_control(:cancel, _socket, _task, _monitor, registry, token) do
    :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)
    assert_receive :cancellation_pending, @detection_timeout
  end

  defp apply_close_control(true, socket, task, monitor, _registry, _token) do
    send(socket, :release_ack)
    assert_receive :delivery_ack_processed, @detection_timeout
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, @detection_timeout
  end

  defp apply_close_control(:queue_terminal, socket, _task, _monitor, _registry, _token) do
    send(socket, :queue_terminal)
    assert_receive :unaccepted_terminal_queued, @detection_timeout
  end

  defp apply_close_control(:stale_terminal, socket, _task, _monitor, _registry, _token) do
    send(socket, :stale_terminal)
    assert_receive :stale_terminal_dropped, @detection_timeout
  end

  defp apply_close_control(false, _socket, _task, _monitor, _registry, _token), do: :ok

  defp connect(port) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/terminal-close", [])
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @detection_timeout)
    assert {:status, ref, 101} in responses
    {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
    {conn, websocket, ref}
  end

  defp receive_frames(conn, websocket, ref) do
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, @detection_timeout)

    {websocket, frames} =
      Enum.reduce(responses, {websocket, []}, fn
        {:data, ^ref, data}, {websocket, frames} ->
          {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
          {websocket, frames ++ decoded}

        _response, acc ->
          acc
      end)

    if frames == [] do
      receive_frames(conn, websocket, ref)
    else
      {conn, Enum.map(frames, fn {:text, data} -> Jason.decode!(data)["type"] end)}
    end
  end
end
