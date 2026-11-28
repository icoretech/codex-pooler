defmodule CodexPoolerWeb.Runtime.NativeCompactionPendingClient do
  @moduledoc false

  use GenServer, restart: :temporary

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [public_websocket_send_text!: 4]
  import ExUnit.Assertions, only: [flunk: 1]

  @spec start_link({pid(), (-> tuple()), boolean()}) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec send_request!(pid(), map()) :: :ok
  def send_request!(pid, request), do: GenServer.call(pid, {:send, CodexPooler.JSON.encode!(request)})

  @spec next_text!(pid(), timeout()) :: map()
  def next_text!(pid, timeout) do
    receive do
      {^pid, {:text, text}} -> CodexPooler.JSON.decode!(text)
      {^pid, {:close, code}} -> flunk("socket closed before terminal: #{code}")
      {^pid, :transport_closed} -> flunk("transport closed before terminal")
    after
      timeout -> flunk("text-only client watchdog expired")
    end
  end

  @impl true
  def init({listener, connect, answer_pings?}) do
    {conn, websocket, ref, _headers} = connect.()
    {:ok, %{conn: conn, websocket: websocket, ref: ref, listener: listener, answer_pings?: answer_pings?}}
  end

  @impl true
  def handle_call({:send, text}, _from, state) do
    {conn, websocket} = public_websocket_send_text!(state.conn, state.websocket, state.ref, text)
    {:reply, :ok, %{state | conn: conn, websocket: websocket}}
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2)}

      {:error, conn, _reason, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &response/2)
        send(state.listener, {self(), :transport_closed})
        {:stop, :normal, state}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: Mint.HTTP.close(state.conn)

  defp response({:data, ref, data}, %{ref: ref} = state) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)
    Enum.reduce(frames, %{state | websocket: websocket}, &frame/2)
  end

  defp response(_response, state), do: state

  # Control frames stay on the socket owner. Only text, close or transport failure
  # reaches the consumer, so a Pong never extends its text-only watchdog.
  defp frame({:ping, data}, %{answer_pings?: true} = state) do
    {:ok, websocket, encoded} = Mint.WebSocket.encode(state.websocket, {:pong, data})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, encoded)
    %{state | conn: conn, websocket: websocket}
  end

  defp frame({:text, _text} = event, state), do: relay(event, state)
  defp frame({:close, code, _reason}, state), do: relay({:close, code}, state)
  defp frame({:ping, _data}, state), do: state
  defp frame({:pong, _data}, state), do: state

  defp relay(event, state) do
    send(state.listener, {self(), event})
    state
  end
end
