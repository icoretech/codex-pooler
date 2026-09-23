defmodule CodexPoolerWeb.WebsocketDownstreamWriteWatch do
  @moduledoc false

  # Bandit writes every frame a WebSock callback pushes after the callback
  # returned and discards the write's result (`Bandit.WebSocket.Socket.send_frame/3`
  # in Bandit 1.12), so a socket cannot see that a frame it pushed never reached
  # the connection. A client that stops reading makes the kernel buffers fill,
  # the next write blocks for the 30 s send timeout and the connection is
  # closed; every later push, the terminal included, fails at once. Measured
  # (findings#232 P42): 70 of 4005 frames reached the peer and the receipt still
  # read `delivered`, so a resend of a turn the client never saw complete was
  # refused.
  #
  # ThousandIsland reports each failed write as
  # `[:thousand_island, :connection, :send_error]`, synchronously in the
  # connection process that also runs the WebSock callbacks. This handler keeps
  # the first failure of a watched connection in that process's dictionary; the
  # socket reads it back in the same process. A failed write leaves the byte
  # stream broken (a partly written frame, then a closed connection), so nothing
  # pushed from that write on can have reached the client. A successful write
  # only means the frame entered the port's driver queue, though: frames still
  # queued there when a later write times out are lost with the connection
  # (measured: one frame too many was counted). So the socket confirms its
  # evidence (`confirm/1`, at every callback entry) only while no write has
  # failed and the connection's driver queue is empty, when everything pushed
  # so far is in the kernel; after a failure the confirmed evidence is at most
  # what reached the connection, never more. Only the failure's class is kept,
  # from a fixed vocabulary, with the moment the failure was reported; the
  # frame data in the measurements is never read. That moment is when the
  # client-retry window of a turn cut by the failure starts (findings#232 row
  # 232-261): a client that stops reading without closing is noticed only
  # when a write times out, 30 s later by default, so its resend always came
  # after a window measured from the provider's completion.

  @event [:thousand_island, :connection, :send_error]
  @handler_id {__MODULE__, :send_error}
  @watch_key {__MODULE__, :watch}
  @failure_key {__MODULE__, :failure}
  @failed_at_key {__MODULE__, :failed_at}
  @confirmed_key {__MODULE__, :confirmed}
  @port_key {__MODULE__, :port}
  @failures ~w(timeout closed other)

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, :ok) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Every value `failure/0` can answer."
  @spec failures() :: [String.t()]
  def failures, do: @failures

  @doc """
  Watches the calling connection process from now on, and remembers the TCP
  port it owns (none for a TLS or `socket`-backend connection, whose queue is
  not read: its evidence is confirmed at every callback until a write fails).
  """
  @spec watch() :: :ok
  def watch do
    _previous = Process.put(@watch_key, true)
    _previous = Process.put(@port_key, connection_port())
    :ok
  end

  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(@event, measurements, _metadata, _config) do
    if Process.get(@watch_key) == true and is_nil(Process.get(@failure_key)) do
      _previous = Process.put(@failure_key, failure_class(measurements))
      _previous = Process.put(@failed_at_key, DateTime.utc_now())
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc "The class of the first failed write of this connection, or `nil`."
  @spec failure() :: String.t() | nil
  def failure, do: Process.get(@failure_key)

  @doc "When the first failed write of this connection was reported, or `nil`."
  @spec failed_at() :: DateTime.t() | nil
  def failed_at, do: Process.get(@failed_at_key)

  @doc """
  Records `evidence` as written: called when no write has failed yet, every
  frame pushed before this point reached the connection. Ignored once a write
  failed, so the last confirmed evidence stays the one from before it.
  """
  @spec confirm(term()) :: :ok
  def confirm(evidence) do
    if is_nil(failure()) and driver_queue_empty?(Process.get(@port_key)), do: Process.put(@confirmed_key, evidence)
    :ok
  end

  @doc "The evidence last confirmed as written, or `nil`."
  @spec confirmed() :: term()
  def confirmed, do: Process.get(@confirmed_key)

  defp connection_port do
    case Process.info(self(), :links) do
      {:links, links} -> Enum.find(links, &tcp_port?/1)
      nil -> nil
    end
  end

  defp tcp_port?(link), do: is_port(link) and Port.info(link, :name) == {:name, ~c"tcp_inet"}

  defp driver_queue_empty?(nil), do: true
  defp driver_queue_empty?(port), do: :erlang.port_info(port, :queue_size) == {:queue_size, 0}

  defp failure_class(%{error: :timeout}), do: "timeout"
  defp failure_class(%{error: :closed}), do: "closed"
  defp failure_class(_measurements), do: "other"
end
