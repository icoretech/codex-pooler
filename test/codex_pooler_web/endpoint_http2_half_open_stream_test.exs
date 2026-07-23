defmodule CodexPoolerWeb.EndpointHttp2HalfOpenStreamTest do
  # Transport-level evidence that a mid-stream Plug crash leaves an HTTP/2
  # stream half-open.
  #
  # Bandit switches to the HTTP/2 handler for any cleartext connection that
  # opens with the HTTP/2 prior-knowledge preface
  # (deps/bandit/lib/bandit/initial_handler.ex), and HTTP/2 is enabled unless
  # `http_2_options: [enabled: false]` is set (deps/bandit/lib/bandit.ex:295).
  #
  # When a Plug raises after `Plug.Conn.send_chunked/2`,
  # deps/bandit/lib/bandit/pipeline.ex:240 routes the exception to
  # `send_on_error/2`, which lands on deps/bandit/lib/bandit/http2/stream.ex:543
  # and calls `maybe_send_error/2`. That helper
  # (deps/bandit/lib/bandit/http2/stream.ex:555-563) finds the
  # `{:plug_conn, :sent}` marker already in the mailbox — `send_chunked/2` put
  # it there — takes the silent branch, and emits no frame at all. The stream is
  # moved to `:local_closed` locally and dropped from the connection's stream
  # collection (deps/bandit/lib/bandit/http2/connection.ex:424-426) without
  # END_STREAM and without RST_STREAM, so the peer sees a stream that simply
  # stops producing frames and waits for its own timeout.
  #
  # These tests drive a real Bandit listener over raw TCP so the transport under
  # test is the one that ships. Only frame headers are inspected; no request or
  # response payload beyond a synthetic marker is involved.
  use ExUnit.Case, async: true

  import Bitwise

  @moduletag :capture_log

  # RFC9113§6 frame types and §11.2 flags.
  @data 0x0
  @headers 0x1
  @rst_stream 0x3
  @settings 0x4
  @goaway 0x7

  @end_stream 0x1
  @end_headers 0x4
  @ack 0x1

  # RFC9113§3.4.
  @connection_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @aborted_stream_id 1
  @barrier_stream_id 3
  # The default `assert_receive` window is far too tight for a listener start
  # plus a TCP round trip while the rest of the suite is running.
  @recv_timeout 5_000

  defmodule RaiseAfterChunkPlug do
    @moduledoc false
    # Reproduces the shape of the gateway streaming path: headers and a first
    # chunk go out, then the request process dies with an uncaught exception.
    @behaviour Plug

    @chunk_payload "data: partial\n\n"

    @spec chunk_payload() :: binary()
    def chunk_payload, do: @chunk_payload

    @impl Plug
    def init(test_pid), do: test_pid

    @impl Plug
    def call(%Plug.Conn{path_info: ["stream-then-raise"]} = conn, test_pid) do
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, _conn} = Plug.Conn.chunk(conn, @chunk_payload)
      send(test_pid, {:streaming, self()})

      raise "mid-stream failure"
    end

    def call(%Plug.Conn{path_info: ["barrier"]} = conn, _test_pid) do
      Plug.Conn.send_resp(conn, 200, "barrier")
    end
  end

  describe "cleartext HTTP/2 (h2c)" do
    test "a mid-stream crash closes the stream without END_STREAM or RST_STREAM" do
      port = start_listener()
      socket = connect_h2c(port)

      send_request(socket, @aborted_stream_id, "/stream-then-raise", port)

      # The request process has written headers and one chunk and is about to
      # raise; wait for it to die so Bandit's error path has already run and any
      # frame it would emit is queued ahead of what we ask for next.
      assert_receive {:streaming, stream_pid}, @recv_timeout
      monitor_ref = Process.monitor(stream_pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^stream_pid, _reason}, @recv_timeout

      # A second, healthy request acts as an ordered barrier: once its response
      # has fully arrived, everything the connection had to send for the aborted
      # stream has arrived too.
      send_request(socket, @barrier_stream_id, "/barrier", port)
      frames = collect_until_end_of_stream(socket, @barrier_stream_id)

      :ok = :gen_tcp.close(socket)

      aborted = Enum.filter(frames, &(&1.stream_id == @aborted_stream_id))

      assert Enum.any?(aborted, &(&1.type == @headers)),
             "expected response headers on the aborted stream"

      assert Enum.any?(
               aborted,
               &(&1.type == @data and &1.payload == RaiseAfterChunkPlug.chunk_payload())
             ),
             "expected the first chunk to reach the peer before the crash"

      refute Enum.any?(aborted, &flag?(&1, @end_stream)),
             "aborted stream was terminated with END_STREAM: #{summarize(aborted)}"

      refute Enum.any?(aborted, &(&1.type == @rst_stream)),
             "aborted stream was reset with RST_STREAM: #{summarize(aborted)}"

      refute Enum.any?(frames, &(&1.type == @goaway)),
             "connection was closed with GOAWAY: #{summarize(frames)}"

      # The barrier proves the connection is still healthy and still serving:
      # the peer has no signal at all that the first stream is over.
      assert Enum.any?(
               frames,
               &(&1.stream_id == @barrier_stream_id and &1.type == @data and
                   &1.payload == "barrier")
             )
    end

    test "the only backstop is the connection idle timeout, which tears down every stream" do
      # Thousand Island's `read_timeout` (60s by default,
      # deps/thousand_island/lib/thousand_island/server_config.ex:39) is the sole
      # bound on the abandoned stream, and it is connection scoped: Bandit answers
      # it with GOAWAY (deps/bandit/lib/bandit/http2/handler.ex:56-63). Any
      # multiplexed traffic on the same connection keeps resetting that timer, so
      # it is not a per-stream remedy.
      port = start_listener(thousand_island_options: [read_timeout: 1_000])
      socket = connect_h2c(port)

      send_request(socket, @aborted_stream_id, "/stream-then-raise", port)

      assert_receive {:streaming, stream_pid}, @recv_timeout
      monitor_ref = Process.monitor(stream_pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^stream_pid, _reason}, @recv_timeout

      frames = collect_until_closed(socket)

      assert Enum.any?(frames, &(&1.type == @goaway)),
             "expected the idle connection to be closed with GOAWAY: #{summarize(frames)}"

      refute frames
             |> Enum.filter(&(&1.stream_id == @aborted_stream_id))
             |> Enum.any?(&flag?(&1, @end_stream)),
             "aborted stream was terminated with END_STREAM: #{summarize(frames)}"
    end
  end

  describe "HTTP/1.1" do
    test "a mid-stream crash truncates the response and closes the connection" do
      port = start_listener()

      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true])

      :ok =
        :gen_tcp.send(socket, [
          "GET /stream-then-raise HTTP/1.1\r\n",
          "host: 127.0.0.1:#{port}\r\n",
          "\r\n"
        ])

      assert_receive {:streaming, _pid}, @recv_timeout

      response = read_until_closed(socket, [])

      assert response =~ "HTTP/1.1 200 OK"
      assert response =~ "transfer-encoding: chunked"
      assert response =~ RaiseAfterChunkPlug.chunk_payload()

      # The terminating zero-length chunk never arrives and the connection is
      # closed, so the peer observes an aborted response instead of hanging.
      refute String.ends_with?(response, "0\r\n\r\n")
    end
  end

  describe "endpoint configuration" do
    test "the shipped listener does not disable HTTP/2" do
      http_options =
        :codex_pooler
        |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
        |> Keyword.fetch!(:http)

      refute get_in(http_options, [:http_2_options, :enabled]) == false,
             "HTTP/2 was disabled on the endpoint; revisit the half-open stream coverage above"
    end
  end

  defp start_listener(extra_options \\ []) do
    options =
      Keyword.merge(
        [plug: {RaiseAfterChunkPlug, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false],
        extra_options
      )

    server = start_supervised!({Bandit, options})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp connect_h2c(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true])

    :ok = :gen_tcp.send(socket, [@connection_preface, frame(@settings, 0, 0, "")])
    socket
  end

  defp send_request(socket, stream_id, path, port) do
    block = [
      header_field(":method", "GET"),
      header_field(":scheme", "http"),
      header_field(":authority", "127.0.0.1:#{port}"),
      header_field(":path", path)
    ]

    :ok =
      :gen_tcp.send(socket, frame(@headers, @end_headers ||| @end_stream, stream_id, block))
  end

  # HPACK literal header field, never indexed, new name, without Huffman coding
  # (RFC7541§6.2.3). Hand-encoded so the client stays free of an HPACK library;
  # every name and value used here is well under the 126-byte prefix limit.
  defp header_field(name, value) do
    <<0x10, 0::1, byte_size(name)::7, name::binary, 0::1, byte_size(value)::7, value::binary>>
  end

  defp frame(type, flags, stream_id, payload) do
    payload = IO.iodata_to_binary(payload)
    <<byte_size(payload)::24, type::8, flags::8, 0::1, stream_id::31, payload::binary>>
  end

  defp collect_until_end_of_stream(socket, stream_id, acc \\ []) do
    {:ok, frame} = recv_frame(socket)
    acc = [frame | acc]

    cond do
      settings_to_ack?(frame) ->
        :ok = :gen_tcp.send(socket, frame(@settings, @ack, 0, ""))
        collect_until_end_of_stream(socket, stream_id, acc)

      frame.stream_id == stream_id and flag?(frame, @end_stream) ->
        Enum.reverse(acc)

      true ->
        collect_until_end_of_stream(socket, stream_id, acc)
    end
  end

  defp collect_until_closed(socket, acc \\ []) do
    case recv_frame(socket) do
      {:ok, frame} ->
        if settings_to_ack?(frame), do: :gen_tcp.send(socket, frame(@settings, @ack, 0, ""))
        collect_until_closed(socket, [frame | acc])

      {:error, :closed} ->
        Enum.reverse(acc)
    end
  end

  defp recv_frame(socket) do
    with {:ok, <<length::24, type::8, flags::8, _reserved::1, stream_id::31>>} <-
           :gen_tcp.recv(socket, 9, @recv_timeout),
         {:ok, payload} <- recv_payload(socket, length) do
      {:ok, %{type: type, flags: flags, stream_id: stream_id, payload: payload}}
    end
  end

  defp recv_payload(_socket, 0), do: {:ok, ""}
  defp recv_payload(socket, length), do: :gen_tcp.recv(socket, length, @recv_timeout)

  defp settings_to_ack?(frame), do: frame.type == @settings and not flag?(frame, @ack)

  defp flag?(%{flags: flags}, flag), do: (flags &&& flag) == flag

  defp read_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> read_until_closed(socket, [acc, data])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp summarize(frames) do
    frames
    |> Enum.map(&Map.take(&1, [:type, :flags, :stream_id]))
    |> inspect()
  end
end
