defmodule CodexPooler.Gateway.Runtime.Finalization.ResponseUsageTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  describe "from_json/1" do
    test "extracts flat usage from JSON responses" do
      body =
        Jason.encode!(%{
          "service_tier" => "priority",
          "usage" => %{
            "input_tokens" => 10,
            "input_tokens_details" => %{"cached_tokens" => 4},
            "output_tokens" => "7",
            "reasoning_tokens" => nil,
            "total_tokens" => 17
          }
        })

      assert ResponseUsage.from_json(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 10,
               cached_input_tokens: 4,
               output_tokens: 7,
               reasoning_tokens: 0,
               total_tokens: 17,
               service_tier: "priority"
             }
    end

    test "extracts nested response usage from output items" do
      body =
        Jason.encode!(%{
          "output" => [
            %{"type" => "message"},
            %{
              "response" => %{
                "service_tier" => "default",
                "usage" => %{
                  "prompt_tokens" => 2,
                  "prompt_tokens_details" => %{"cached_tokens" => 1},
                  "completion_tokens" => 3,
                  "total_tokens" => 5
                }
              }
            }
          ]
        })

      assert %{
               status: "usage_known",
               input_tokens: 2,
               cached_input_tokens: 1,
               output_tokens: 3,
               reasoning_tokens: 0,
               total_tokens: 5,
               service_tier: "default"
             } = ResponseUsage.from_json(body)
    end

    test "marks malformed JSON and invalid usage token values as unknown" do
      assert ResponseUsage.from_json("{") == %{
               status: "usage_unknown",
               source: "json_decode_failed"
             }

      body = Jason.encode!(%{"usage" => %{"input_tokens" => 1.2}})

      assert ResponseUsage.from_json(body) == %{
               status: "usage_unknown",
               source: "invalid_usage_tokens"
             }
    end
  end

  describe "from_sse/1" do
    test "extracts first valid usage payload from SSE data frames" do
      body = """
      event: ping
      data: nope

      event: response.completed
      data: {"response":{"service_tier":"flex","usage":{"input_tokens":3,"cached_input_tokens":2,"output_tokens":4,"total_tokens":7}}}

      data: [DONE]

      """

      assert %{
               status: "usage_known",
               input_tokens: 3,
               cached_input_tokens: 2,
               output_tokens: 4,
               reasoning_tokens: 0,
               total_tokens: 7,
               service_tier: "flex"
             } = ResponseUsage.from_sse(body)
    end

    test "extracts usage from local usage-limit response.failed without changing failure semantics" do
      body =
        sse_event("response.failed", %{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_usage_limit_terminal",
            "status" => "failed",
            "error" => %{"code" => "usage_limit_exceeded"},
            "usage" => %{
              "input_tokens" => 10,
              "cached_input_tokens" => 4,
              "output_tokens" => 2,
              "reasoning_tokens" => 1,
              "total_tokens" => 12
            }
          }
        })

      assert ResponseUsage.from_sse(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 10,
               cached_input_tokens: 4,
               output_tokens: 2,
               reasoning_tokens: 1,
               total_tokens: 12,
               service_tier: nil
             }
    end

    test "marks SSE without usage as unknown" do
      body = ~S"""
      data: {"type":"response.created"}

      data: [DONE]

      """

      assert ResponseUsage.from_sse(body) ==
               %{status: "usage_unknown", source: "sse_usage_missing"}
    end
  end

  describe "from_websocket_body/1" do
    test "extracts usage from SSE-style collected websocket data chunks" do
      body = """
      data: {"type":"response.created"}

      data: {"type":"response.completed","response":{"service_tier":"priority","usage":{"input_tokens":11,"input_tokens_details":{"cached_tokens":5},"output_tokens":13,"reasoning_tokens":2,"total_tokens":24}}}

      """

      assert ResponseUsage.from_websocket_body(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 11,
               cached_input_tokens: 5,
               output_tokens: 13,
               reasoning_tokens: 2,
               total_tokens: 24,
               service_tier: "priority"
             }
    end

    test "extracts nested response.completed usage from newline-delimited websocket JSON messages" do
      body =
        [
          Jason.encode!(%{"type" => "response.created"}),
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "service_tier" => "default",
              "usage" => %{
                "input_tokens" => 17,
                "cached_input_tokens" => 6,
                "output_tokens" => 19,
                "reasoning_tokens" => 3,
                "total_tokens" => 36
              }
            }
          })
        ]
        |> Enum.join("\n")

      assert ResponseUsage.from_websocket_body(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 17,
               cached_input_tokens: 6,
               output_tokens: 19,
               reasoning_tokens: 3,
               total_tokens: 36,
               service_tier: "default"
             }
    end

    test "extracts direct response payload usage from newline-delimited websocket JSON messages" do
      body =
        [
          Jason.encode!(%{"type" => "response.in_progress"}),
          Jason.encode!(%{
            "id" => "resp_sample",
            "service_tier" => "flex",
            "usage" => %{
              "prompt_tokens" => 23,
              "prompt_tokens_details" => %{"cached_tokens" => 7},
              "completion_tokens" => 29,
              "total_tokens" => 52
            }
          })
        ]
        |> Enum.join("\n")

      assert ResponseUsage.from_websocket_body(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 23,
               cached_input_tokens: 7,
               output_tokens: 29,
               reasoning_tokens: 0,
               total_tokens: 52,
               service_tier: "flex"
             }
    end

    test "extracts top-level usage envelope from direct websocket JSON messages" do
      body =
        Jason.encode!(%{
          "usage" => %{
            "input_tokens" => 31,
            "cached_input_tokens" => 8,
            "output_tokens" => 37,
            "reasoning_tokens" => 5,
            "total_tokens" => 68
          }
        })

      assert ResponseUsage.from_websocket_body(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 31,
               cached_input_tokens: 8,
               output_tokens: 37,
               reasoning_tokens: 5,
               total_tokens: 68,
               service_tier: nil
             }
    end

    test "skips malformed websocket lines before a valid usage-bearing terminal frame" do
      body =
        [
          "not json",
          Jason.encode!(%{"type" => "response.created"}),
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "usage" => %{
                "input_tokens" => 41,
                "cached_input_tokens" => 9,
                "output_tokens" => 43,
                "reasoning_tokens" => 6,
                "total_tokens" => 84
              }
            }
          })
        ]
        |> Enum.join("\n")

      assert %{
               status: "usage_known",
               input_tokens: 41,
               cached_input_tokens: 9,
               output_tokens: 43,
               reasoning_tokens: 6,
               total_tokens: 84,
               service_tier: nil
             } = ResponseUsage.from_websocket_body(body)
    end

    test "marks non-terminal websocket frames without usage as websocket usage missing" do
      body =
        [
          Jason.encode!(%{"type" => "response.created"}),
          Jason.encode!(%{"type" => "response.in_progress"})
        ]
        |> Enum.join("\n")

      assert ResponseUsage.from_websocket_body(body) ==
               %{status: "usage_unknown", source: "websocket_usage_missing"}
    end

    test "marks terminal websocket frames without usage as websocket usage missing" do
      body =
        Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_empty"}})

      assert ResponseUsage.from_websocket_body(body) ==
               %{status: "usage_unknown", source: "websocket_usage_missing"}
    end
  end

  defp sse_event(event, payload) do
    "event: " <> event <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
  end
end
