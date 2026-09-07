defmodule CodexPooler.Gateway.OpenAICompatibility.ImageObservationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.ImageObservation

  test "HTTP JSON errors retain safe code type and param before body disposal" do
    body =
      CodexPooler.JSON.encode!(%{
        "error" => %{
          "code" => "unsupported_parameter",
          "type" => "invalid_request_error",
          "param" => "tool_choice",
          "message" => "private-message"
        }
      })

    {:ok, upstream} =
      CodexPooler.FakeUpstream.start_link(
        {:raw_body, 400, body, [{"content-type", "application/json"}]}
      )

    on_exit(fn -> CodexPooler.FakeUpstream.stop(upstream) end)
    response = Req.post!(CodexPooler.FakeUpstream.url(upstream), retry: false, decode_body: false)

    assert ImageObservation.from_http(response.status, response.body) == %{
             http_status: 400,
             body_format: "json",
             error_code: "unsupported_parameter",
             error_type: "invalid_request_error",
             error_param: "tool_choice"
           }
  end

  test "malformed JSON error identifiers become fingerprints and arbitrary fields drop" do
    body =
      CodexPooler.JSON.encode!(%{
        "error" => %{
          "code" => "private\ncode",
          "type" => ["private"],
          "param" => String.duplicate("x", 81),
          "message" => "private-message"
        }
      })

    result = ImageObservation.from_http(400, body)
    assert result.error_type == nil
    assert result.error_code != "private\ncode"
    assert is_binary(result.error_code)
    assert is_binary(result.error_param)
    refute inspect(result) =~ "private-message"
  end

  test "classifies missing, failed, empty, invalid and usable image results without content" do
    for {output, expected} <- [
          {[%{"type" => "message", "content" => "private-content"}], "no_image_item"},
          {[%{"type" => "image_generation_call", "status" => "failed"}], "failed_image_item"},
          {[%{"type" => "image_generation_call", "result" => ""}], "empty_image_result"},
          {[%{"type" => "image_generation_call", "result" => 42}], "nonstring_image_result"},
          {[%{"type" => "image_generation_call", "result" => "private-content"}],
           "usable_image_result"}
        ] do
      body =
        "data: " <>
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{"output" => output}
          }) <>
          "\n\n"

      observation = ImageObservation.from_sse(body)
      assert observation.outcome == expected
      refute inspect(observation) =~ "private-content"
      assert observation.terminal == "completed"
    end
  end

  test "retains only fixed type counters for a tool-only response" do
    body =
      "data: " <>
        CodexPooler.JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "output" => [
              %{
                "type" => "custom_tool_call",
                "name" => "private-tool",
                "input" => "private-input"
              },
              %{"type" => "unknown-private-type"}
            ]
          }
        }) <> "\n\n"

    assert ImageObservation.from_sse(body) == %{
             outcome: "no_image_item",
             terminal: "completed",
             image_items: 0,
             messages: 0,
             tool_calls: 1,
             other_items: 1,
             refusals: 0,
             error_code: nil
           }
  end

  test "counts refusals and caps duplicate observations without retaining refusal text" do
    event =
      "data: " <>
        CodexPooler.JSON.encode!(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "refusal", "refusal" => "private-refusal"}]
          }
        }) <> "\n\n"

    observation = ImageObservation.from_sse(String.duplicate(event, 1001))
    assert observation.messages == 1000
    assert observation.refusals == 1000
    assert observation.terminal == "absent"
    refute inspect(observation) =~ "private-refusal"
  end
end
