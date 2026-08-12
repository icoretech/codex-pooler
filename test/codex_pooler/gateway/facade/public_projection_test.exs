defmodule CodexPooler.Gateway.Facade.PublicProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.{HeaderPolicy, PublicProjection}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesWebsocket
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec

  @hidden_model "gpt-5.6-sol-hidden-sentinel"
  @hidden_provider "provider-hidden-sentinel"
  @hidden_account "account-hidden-sentinel"
  @hidden_assignment "assignment-hidden-sentinel"

  test "projects known Responses identity fields without rewriting assistant text or tool data" do
    preserved_text =
      "Explain #{@hidden_model}, #{@hidden_provider}, and #{@hidden_account} literally."

    preserved_arguments =
      Jason.encode!(%{
        "model" => @hidden_model,
        "provider" => @hidden_provider,
        "assignment" => @hidden_assignment
      })

    source = %{
      "id" => "resp_public_projection",
      "object" => "response",
      "model" => @hidden_model,
      "provider" => @hidden_provider,
      "account_id" => @hidden_account,
      "assignment_id" => @hidden_assignment,
      "upstream_endpoint" => "https://#{@hidden_provider}.invalid",
      "request_id" => "request-hidden-sentinel",
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => preserved_text}]
        },
        %{
          "type" => "function_call",
          "name" => "inspect_fixture",
          "arguments" => preserved_arguments
        },
        %{"type" => "image_generation_call", "model" => @hidden_model}
      ]
    }

    projected = PublicProjection.openai_response(source)

    assert projected["model"] == "gemma3"
    refute Map.has_key?(projected, "provider")
    refute Map.has_key?(projected, "account_id")
    refute Map.has_key?(projected, "assignment_id")
    refute Map.has_key?(projected, "upstream_endpoint")
    refute Map.has_key?(projected, "request_id")

    assert get_in(projected, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             preserved_text

    assert get_in(projected, ["output", Access.at(1), "arguments"]) == preserved_arguments
    assert get_in(projected, ["output", Access.at(2), "model"]) == "gemma3"
  end

  test "projects Responses SSE and websocket envelopes at known identity locations" do
    event = %{
      "type" => "response.created",
      "model" => @hidden_model,
      "provider" => @hidden_provider,
      "response" => %{
        "id" => "resp_projection_event",
        "object" => "response",
        "model" => @hidden_model,
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "literal #{@hidden_model} stays"}
            ]
          }
        ]
      }
    }

    projected = PublicProjection.responses_event(event)
    assert projected["model"] == "gemma3"
    assert get_in(projected, ["response", "model"]) == "gemma3"
    refute Map.has_key?(projected, "provider")

    assert get_in(projected, ["response", "output", Access.at(0), "content", Access.at(0), "text"]) ==
             "literal #{@hidden_model} stays"

    sse = "event: response.created\ndata: #{Jason.encode!(event)}\n\n"
    projected_sse = PublicProjection.sse_block(sse) |> IO.iodata_to_binary()
    assert projected_sse =~ ~s("model":"gemma3")
    refute projected_sse =~ @hidden_provider

    state = PublicResponsesWebsocket.new_state()

    assert {:push, websocket_json, _state} =
             PublicResponsesWebsocket.normalize(Jason.encode!(event), state)

    websocket_event = Jason.decode!(websocket_json)
    assert get_in(websocket_event, ["response", "model"]) == "gemma3"
    refute websocket_json =~ @hidden_provider
  end

  test "projects native Codex SSE, native websocket JSON, and collected websocket results" do
    assistant_text = "literal #{@hidden_model} and #{@hidden_provider} stays"

    event = %{
      "type" => "response.completed",
      "provider" => @hidden_provider,
      "response" => %{
        "id" => "resp_native_projection",
        "object" => "response",
        "model" => @hidden_model,
        "account_id" => @hidden_account,
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => assistant_text}]
          }
        ]
      }
    }

    native_json =
      event
      |> Jason.encode!()
      |> StreamProtocol.canonicalize_native_codex_responses_json_message()

    native_event = Jason.decode!(native_json)
    assert get_in(native_event, ["response", "model"]) == "gemma3"
    refute Map.has_key?(native_event, "provider")
    refute Map.has_key?(native_event["response"], "account_id")

    assert get_in(native_event, [
             "response",
             "output",
             Access.at(0),
             "content",
             Access.at(0),
             "text"
           ]) ==
             assistant_text

    native_sse =
      "event: response.completed\ndata: #{Jason.encode!(event)}"
      |> StreamProtocol.normalize_codex_responses_sse_block()
      |> IO.iodata_to_binary()

    assert native_sse =~ ~s("model":"gemma3")
    assert native_sse =~ assistant_text

    native_sse_event =
      native_sse |> StreamProtocol.sse_field("data") |> Jason.decode!()

    refute Map.has_key?(native_sse_event, "provider")
    refute Map.has_key?(native_sse_event["response"], "account_id")

    assert :ok =
             WebsocketCodec.deliver_result(%{body: event}, fn frame ->
               send(self(), {:projected_frame, frame})
             end)

    assert_receive {:projected_frame, projected_frame}
    projected_event = Jason.decode!(projected_frame)
    assert get_in(projected_event, ["response", "model"]) == "gemma3"
    refute Map.has_key?(projected_event, "provider")
    refute Map.has_key?(projected_event["response"], "account_id")

    assert get_in(projected_event, [
             "response",
             "output",
             Access.at(0),
             "content",
             Access.at(0),
             "text"
           ]) ==
             assistant_text
  end

  test "projects provider-shaped errors to a stable facade error" do
    projected =
      PublicProjection.error_body(:openai, 502, %{
        code: "provider_#{@hidden_model}",
        message:
          "#{@hidden_provider} #{@hidden_account} #{@hidden_assignment} failed at upstream.invalid",
        param: @hidden_model
      })

    serialized = Jason.encode!(projected)
    assert projected["error"]["param"] == nil

    for hidden <- [
          @hidden_model,
          @hidden_provider,
          @hidden_account,
          @hidden_assignment,
          "upstream.invalid"
        ] do
      refute serialized =~ hidden
    end
  end

  test "header policy retains only protocol-safe response headers" do
    headers = [
      {"Content-Type", "text/event-stream; charset=utf-8"},
      {"cache-control", "no-cache"},
      {"connection", "keep-alive"},
      {"x-request-id", "provider-request-hidden"},
      {"x-openai-model", @hidden_model},
      {"x-provider-account", @hidden_account},
      {"x-ratelimit-remaining-requests", "42"},
      {"x-codex-turn-state", "safe-local-turn-state"},
      {"x-models-etag", "safe-local-models-etag"}
    ]

    assert HeaderPolicy.result_headers(:openai, headers) == [
             {"content-type", "text/event-stream"},
             {"cache-control", "no-cache"},
             {"connection", "keep-alive"}
           ]

    assert HeaderPolicy.result_headers(:codex, headers) == [
             {"content-type", "text/event-stream"},
             {"cache-control", "no-cache"},
             {"connection", "keep-alive"},
             {"x-codex-turn-state", "safe-local-turn-state"},
             {"x-models-etag", "safe-local-models-etag"}
           ]
  end
end
