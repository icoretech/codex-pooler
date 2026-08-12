defmodule CodexPooler.Gateway.Facade.Anthropic.ResponseTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Anthropic.Response

  test "projects collected Responses output into one local gemma3 message" do
    decoded = %{
      "id" => "provider-response-id",
      "model" => "provider-hidden-model",
      "provider" => "provider-hidden-name",
      "assignment_id" => "provider-assignment-id",
      "status" => "completed",
      "output" => [
        %{
          "type" => "reasoning",
          "id" => "provider-reasoning-id",
          "encrypted_content" => "provider-encrypted-reasoning",
          "summary" => [
            %{"type" => "summary_text", "text" => "Checked the result safely."}
          ]
        },
        %{
          "type" => "message",
          "id" => "provider-message-id",
          "content" => [
            %{"type" => "output_text", "text" => "Forecast: cloudy<END>private tail"}
          ]
        },
        %{
          "type" => "function_call",
          "id" => "provider-function-id",
          "call_id" => "provider-call-id",
          "name" => "lookup_weather",
          "arguments" => ~s({"city":"London"})
        }
      ],
      "usage" => %{
        "input_tokens" => 10,
        "input_tokens_details" => %{"cached_tokens" => 3},
        "output_tokens" => 5,
        "total_tokens" => 15,
        "provider_private_tokens" => 99
      }
    }

    response =
      Response.message(decoded, %{
        stream?: false,
        think?: true,
        stops: ["<END>"],
        max_tokens: 96
      })

    assert %{
             "id" => message_id,
             "type" => "message",
             "role" => "assistant",
             "model" => "gemma3",
             "content" => [
               %{
                 "type" => "thinking",
                 "thinking" => "Checked the result safely.",
                 "signature" => signature
               },
               %{"type" => "text", "text" => "Forecast: cloudy"},
               %{
                 "type" => "tool_use",
                 "id" => tool_id,
                 "name" => "lookup_weather",
                 "input" => %{"city" => "London"}
               }
             ],
             "stop_reason" => "stop_sequence",
             "stop_sequence" => "<END>",
             "usage" => %{
               "input_tokens" => 7,
               "cache_creation_input_tokens" => 0,
               "cache_read_input_tokens" => 3,
               "output_tokens" => 5
             }
           } = response

    assert String.starts_with?(message_id, "msg_")
    assert String.starts_with?(signature, "sig_")
    assert String.starts_with?(tool_id, "toolu_")

    assert Map.keys(response) |> Enum.sort() ==
             ~w(content id model role stop_reason stop_sequence type usage)

    encoded = Jason.encode!(response)

    for hidden <- [
          "provider-response-id",
          "provider-hidden-model",
          "provider-hidden-name",
          "provider-assignment-id",
          "provider-reasoning-id",
          "provider-encrypted-reasoning",
          "provider-message-id",
          "provider-function-id",
          "provider-call-id",
          "private tail",
          "provider_private_tokens"
        ] do
      refute encoded =~ hidden
    end
  end

  test "maps canonical completion, tool, output-limit, and local-stop outcomes" do
    cases = [
      {%{"status" => "completed", "output" => []}, %{think?: false, stops: []},
       {"end_turn", nil}},
      {%{
         "status" => "completed",
         "output" => [
           %{"type" => "function_call", "name" => "lookup", "arguments" => "{}"}
         ]
       }, %{think?: false, stops: []}, {"tool_use", nil}},
      {%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "max_output_tokens"},
         "output" => []
       }, %{think?: false, stops: []}, {"max_tokens", nil}},
      {%{
         "status" => "completed",
         "output" => [
           %{
             "type" => "message",
             "content" => [%{"type" => "output_text", "text" => "kept::stop::hidden"}]
           }
         ]
       }, %{think?: false, stops: ["::stop::"]}, {"stop_sequence", "::stop::"}}
    ]

    for {decoded, formatting, {reason, sequence}} <- cases do
      response =
        Response.message(decoded, Map.merge(%{stream?: false, max_tokens: 32}, formatting))

      assert response["stop_reason"] == reason
      assert response["stop_sequence"] == sequence
    end
  end

  test "bounds malformed usage and invalid tool JSON to safe local values" do
    response =
      Response.message(
        %{
          "status" => "completed",
          "output" => [
            %{"type" => "function_call", "name" => "unsafe", "arguments" => "private{"}
          ],
          "usage" => %{
            "input_tokens" => 4,
            "input_tokens_details" => %{"cached_tokens" => 100},
            "cache_creation_input_tokens" => -7,
            "output_tokens" => "provider-private"
          }
        },
        %{stream?: false, think?: false, stops: [], max_tokens: 32}
      )

    assert response["usage"] == %{
             "input_tokens" => 0,
             "cache_creation_input_tokens" => 0,
             "cache_read_input_tokens" => 4,
             "output_tokens" => 0
           }

    assert [%{"type" => "tool_use", "input" => %{}}] = response["content"]
    refute Jason.encode!(response) =~ "provider-private"
  end
end
