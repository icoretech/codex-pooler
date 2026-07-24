defmodule CodexPooler.Gateway.Transports.BoundedResponseBodyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.BoundedResponseBody

  # This test has no response-duration behavior under test: each timeout only
  # detects a stalled local TCP/Req exchange. Keep it well above the loaded
  # suite's scheduling delays.
  @detection_timeout_ms 15_000

  test "collects response chunks until finalized" do
    collect = BoundedResponseBody.collector(16)
    request = Req.new()
    response = Req.Response.new(status: 200)

    assert {:cont, {^request, response}} = collect.({:data, "hello"}, {request, response})
    assert {:cont, {^request, response}} = collect.({:data, " world"}, {request, response})

    response = BoundedResponseBody.finalize(response)

    assert response.body == "hello world"
    refute BoundedResponseBody.exceeded?(response)
    assert BoundedResponseBody.metadata(response) == %{}
  end

  test "halts and drops retained chunks when streamed bytes exceed the limit" do
    collect = BoundedResponseBody.collector(8)
    request = Req.new()
    response = Req.Response.new(status: 200)

    assert {:cont, {^request, response}} = collect.({:data, "12345"}, {request, response})
    assert {:halt, {^request, response}} = collect.({:data, "6789"}, {request, response})

    assert BoundedResponseBody.exceeded?(response)
    assert BoundedResponseBody.finalize(response).body == ""

    assert BoundedResponseBody.metadata(response) == %{
             "response_body_limit_exceeded" => true,
             "response_body_limit_bytes" => 8,
             "response_body_seen_bytes" => 9
           }
  end

  test "halts on oversized content-length before retaining the first chunk" do
    collect = BoundedResponseBody.collector(8)
    request = Req.new()

    response =
      Req.Response.new(status: 200)
      |> Req.Response.put_header("content-length", "9")

    assert {:halt, {^request, response}} = collect.({:data, "1"}, {request, response})

    assert BoundedResponseBody.exceeded?(response)
    assert BoundedResponseBody.finalize(response).body == ""

    assert BoundedResponseBody.metadata(response) == %{
             "response_body_content_length" => 9,
             "response_body_limit_exceeded" => true,
             "response_body_limit_bytes" => 8,
             "response_body_seen_bytes" => 1
           }
  end

  test "collector receives partial chunked data before declared HTTP/1 chunk completes" do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen_socket)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, @detection_timeout_ms)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n7FFFFFFF\r\nhello"
          )

        receive do
          :close -> :ok
        after
          @detection_timeout_ms -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      send(server, :close)
      :gen_tcp.close(listen_socket)
    end)

    assert {:ok, response} =
             Req.get("http://127.0.0.1:#{port}/",
               decode_body: false,
               retry: false,
               receive_timeout: @detection_timeout_ms,
               into: BoundedResponseBody.collector(4)
             )

    response = BoundedResponseBody.finalize(response)

    assert response.status == 200
    assert response.body == ""
    assert BoundedResponseBody.exceeded?(response)

    assert BoundedResponseBody.metadata(response) == %{
             "response_body_limit_exceeded" => true,
             "response_body_limit_bytes" => 4,
             "response_body_seen_bytes" => 5
           }
  end
end
