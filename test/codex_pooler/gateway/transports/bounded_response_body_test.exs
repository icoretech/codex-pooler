defmodule CodexPooler.Gateway.Transports.BoundedResponseBodyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.BoundedResponseBody

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
end
