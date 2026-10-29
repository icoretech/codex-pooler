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
  #
  # The queue can only be read while the port is open, and the port exits with
  # the peer's close: the released Codex client closes right after reading a
  # content-filter terminal (findings#303 row 303-4), so the callback that
  # confirms the terminal, and `terminate/2` itself, can run after the port is
  # gone, where `:erlang.port_info/2` answers `:undefined` and nothing would ever
  # be confirmed again. So the queue is also read right after every successful
  # write (`[:thousand_island, :connection, :send]`, in the same process) and
  # remembered: a closed port answers with that last observation, which is
  # exactly whether the latest frame was in the kernel when the client could
  # first have read it. A queue never observed counts as not empty, and so does
  # the queue of a write whose port was already gone when it was read: an
  # earlier write's observation says nothing about the latest frame.
  #
  # That reading runs after the write returned, and the client can read the
  # frame and close before it does: a socket descheduled in between finds the
  # port gone (findings#315, traced on a natural failure with Drone 1815's and
  # 1839's receipt; on loopback the client read a content-filter terminal
  # about 30 µs after its write). Such a write stays unconfirmed. The watch
  # reports it as a fact of its own (`closed_before_latest_write_read?/0`)
  # when the driver queue was read empty right before it, so the frame went to
  # the kernel directly; it cannot tell a whole write from one a full send
  # buffer cut short, and only the socket's content-filter terminal relies on
  # it.

  @event [:thousand_island, :connection, :send_error]
  @sent_event [:thousand_island, :connection, :send]
  @handler_id {__MODULE__, :send_error}
  @sent_handler_id {__MODULE__, :send}
  @watch_key {__MODULE__, :watch}
  @failure_key {__MODULE__, :failure}
  @failed_at_key {__MODULE__, :failed_at}
  @confirmed_key {__MODULE__, :confirmed}
  @port_key {__MODULE__, :port}
  @queue_empty_key {__MODULE__, :queue_empty}
  @closed_before_read_key {__MODULE__, :closed_before_read}
  @failures ~w(timeout closed other)

  @spec attach() :: :ok
  def attach do
    :ok = attach_handler(@handler_id, @event)
    attach_handler(@sent_handler_id, @sent_event)
  end

  defp attach_handler(handler_id, event) do
    case :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, :ok) do
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

  def handle_event(@sent_event, _measurements, _metadata, _config) do
    if Process.get(@watch_key) == true, do: observe_written_queue(Process.get(@port_key))
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
    if is_nil(failure()) and queue_empty?(), do: Process.put(@confirmed_key, evidence)
    :ok
  end

  @doc "Whether all preceding writes reached the connection without a write failure."
  @spec writes_confirmed?() :: boolean()
  def writes_confirmed?, do: is_nil(failure()) and queue_empty?()

  @doc "The evidence last confirmed as written, or `nil`."
  @spec confirmed() :: term()
  def confirmed, do: Process.get(@confirmed_key)

  @doc """
  Whether the latest successful write of this connection could not be read
  because its port had already exited, after the driver queue was read empty
  right before it, while no write has failed. Such a write went to the kernel
  directly but stays unconfirmed: only a full send buffer could have cut it
  short, which this cannot tell.
  """
  @spec closed_before_latest_write_read?() :: boolean()
  def closed_before_latest_write_read?, do: is_nil(failure()) and Process.get(@closed_before_read_key) == true

  defp connection_port do
    case Process.info(self(), :links) do
      {:links, links} -> Enum.find(links, &tcp_port?/1)
      nil -> nil
    end
  end

  defp tcp_port?(link), do: is_port(link) and Port.info(link, :name) == {:name, ~c"tcp_inet"}

  defp queue_empty? do
    case Process.get(@port_key) do
      nil -> true
      port -> port |> :erlang.port_info(:queue_size) |> remember_queue()
    end
  end

  defp remember_queue({:queue_size, size}) do
    _previous = Process.put(@queue_empty_key, size == 0)
    size == 0
  end

  defp remember_queue(:undefined), do: Process.get(@queue_empty_key, false)

  # Right after a successful write: whether everything written so far is in the kernel. A port already gone cannot tell, so the latest frame then counts as not written, whatever an earlier read found; whether that earlier read found the queue empty is kept apart for `closed_before_latest_write_read?/0`.
  defp observe_written_queue(nil), do: :ok

  defp observe_written_queue(port) do
    reading = :erlang.port_info(port, :queue_size)
    _previous = Process.put(@closed_before_read_key, reading == :undefined and Process.get(@queue_empty_key) == true)
    _previous = Process.put(@queue_empty_key, reading == {:queue_size, 0})
    :ok
  end

  defp failure_class(%{error: :timeout}), do: "timeout"
  defp failure_class(%{error: :closed}), do: "closed"
  defp failure_class(_measurements), do: "other"
end
