defmodule CodexPooler.Gateway.Transports.PublicResponsesEventHeadersTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Gateway.Websocket.Adapter

  # findings#239: the public normalisers drop provider event header objects
  # (`headers`, `response.headers`) from every relayed event.

  @created %{
    "type" => "response.created",
    "headers" => %{"openai-model" => "gpt-event-header-sentinel"},
    "response" => %{
      "id" => "resp_public_event_headers",
      "status" => "in_progress",
      "headers" => %{"openai-model" => "gpt-nested-header-sentinel"}
    }
  }

  @metadata %{
    "type" => "codex.response.metadata",
    "headers" => %{"x-models-etag" => ~s(W/"owner-public-etag")}
  }

  # findings#254 row 254-14: the public /v1 websocket relays only the public
  # Responses vocabulary, so the owner-forwarded `codex.response.metadata`
  # ETag event, which only Codex clients on /backend-api consume, is dropped
  # before it takes a sequence number.
  test "the public websocket normaliser drops codex.response.metadata and strips header objects from public events" do
    state = Adapter.public_responses_turn_state()

    assert {:drop, state} =
             Adapter.downstream_response_chunk(CodexPooler.JSON.encode!(@metadata), state)

    assert {:push, created_frame, _state} =
             Adapter.downstream_response_chunk(CodexPooler.JSON.encode!(@created), state)

    assert CodexPooler.JSON.decode!(created_frame) == %{
             "type" => "response.created",
             "response" => %{"id" => "resp_public_event_headers", "status" => "in_progress"},
             "sequence_number" => 0
           }

    refute created_frame =~ ~s("headers")
    refute created_frame =~ "-sentinel"
  end

  test "the public SSE normaliser drops event header objects on every relayed block" do
    delta = %{
      "type" => "response.output_text.delta",
      "delta" => "hello",
      "headers" => %{"x-reasoning-included" => "delta-header-sentinel"}
    }

    blocks =
      Enum.map_join([@created, delta], fn event ->
        "event: #{event["type"]}\ndata: #{CodexPooler.JSON.encode!(event)}\n\n"
      end)

    {bytes, _state} = PublicResponses.normalize_data(blocks, PublicResponses.new_state())

    assert bytes =~ "event: response.created\n"
    assert bytes =~ "event: response.output_text.delta\n"
    refute bytes =~ ~s("headers")
    refute bytes =~ "-sentinel"
  end
end
