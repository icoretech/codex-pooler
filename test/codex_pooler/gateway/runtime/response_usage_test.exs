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

    test "preserves absent, zero, and positive Responses cache-write counters" do
      for {reported, expected} <- [{:absent, nil}, {0, 0}, {9, 9}] do
        details = %{"cached_tokens" => 4}

        details =
          if reported == :absent,
            do: details,
            else: Map.put(details, "cache_write_tokens", reported)

        body =
          Jason.encode!(%{
            "usage" => %{
              "input_tokens" => 10,
              "input_tokens_details" => details,
              "output_tokens" => 7,
              "total_tokens" => 17
            }
          })

        assert Map.get(ResponseUsage.from_json(body), :cache_write_tokens) == expected
      end
    end

    test "preserves absent, zero, and positive Chat cache-write counters" do
      for {reported, expected} <- [{:absent, nil}, {0, 0}, {6, 6}] do
        body = chat_usage_body(reported)
        assert Map.get(ResponseUsage.from_json(body), :cache_write_tokens) == expected
      end
    end

    test "preserves current absent cache-write behavior" do
      body =
        Jason.encode!(%{
          "usage" => %{
            "input_tokens" => 10,
            "input_tokens_details" => %{"cached_tokens" => 4},
            "output_tokens" => 7,
            "total_tokens" => 17
          }
        })

      usage = ResponseUsage.from_json(body)

      assert usage.cached_input_tokens == 4
      refute Map.has_key?(usage, :cache_write_tokens)
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
                  "prompt_tokens" => 0,
                  "prompt_tokens_details" => %{"cached_tokens" => 0},
                  "completion_tokens" => 0,
                  "total_tokens" => 0
                }
              }
            },
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

      for invalid <- [-1, 1.5, "9", "not-an-integer", nil] do
        body =
          Jason.encode!(%{
            "usage" => %{
              "input_tokens" => 10,
              "input_tokens_details" => %{
                "cached_tokens" => 4,
                "cache_write_tokens" => invalid
              },
              "output_tokens" => 2,
              "total_tokens" => 12
            }
          })

        assert ResponseUsage.from_json(body) == %{
                 status: "usage_unknown",
                 source: "invalid_usage_tokens"
               }
      end
    end
  end

  describe "from_sse/1" do
    test "preserves absent, zero, and positive terminal SSE cache-write counters" do
      for {reported, expected} <- [{:absent, nil}, {0, 0}, {8, 8}] do
        body = terminal_sse_usage(reported)
        assert Map.get(ResponseUsage.from_sse(body), :cache_write_tokens) == expected
      end
    end

    test "extracts latest valid usage payload from SSE data frames" do
      body = """
      event: ping
      data: nope

      event: response.in_progress
      data: {"response":{"service_tier":"default","usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":0}}}

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

    test "extracts usage from a retained SSE suffix that starts inside a large data frame" do
      body =
        ~s(output_text":"truncated prefix) <>
          ~s(","usage":{"input_tokens":214407,"input_tokens_details":{"cached_tokens":206848,"cache_write_tokens":1024},"output_tokens":512,"reasoning_tokens":0,"total_tokens":214919},"status":"completed"}}\n\n) <>
          "data: [DONE]\n\n"

      assert ResponseUsage.from_sse(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 214_407,
               cached_input_tokens: 206_848,
               cache_write_tokens: 1_024,
               output_tokens: 512,
               reasoning_tokens: 0,
               total_tokens: 214_919,
               service_tier: nil
             }
    end

    test "rejects malformed cache-write counters in retained SSE usage" do
      for invalid <- ["-1", "1.5", ~s("1"), "null"] do
        body = retained_usage_with_cache_write(invalid) <> "data: [DONE]\n\n"

        assert ResponseUsage.from_sse(body) == %{
                 status: "usage_unknown",
                 source: "invalid_usage_tokens"
               }
      end
    end

    test "malformed retained terminal usage overrides earlier known SSE usage" do
      body =
        terminal_sse_usage(0) <>
          retained_usage_with_cache_write(~s("9")) <>
          "data: [DONE]\n\n"

      assert ResponseUsage.from_sse(body) == %{
               status: "usage_unknown",
               source: "invalid_usage_tokens"
             }
    end

    test "prefers retained terminal usage over earlier zero-token SSE usage" do
      body =
        sse_event("response.in_progress", %{
          "response" => %{
            "service_tier" => "standard",
            "usage" => %{
              "input_tokens" => 0,
              "cached_input_tokens" => 0,
              "output_tokens" => 0,
              "reasoning_tokens" => 0,
              "total_tokens" => 0
            }
          }
        }) <>
          ~s("service_tier":"flex","output_text":"truncated prefix) <>
          ~s(","usage":{"input_tokens":16086,"input_tokens_details":{"cached_tokens":0},"output_tokens":117,"reasoning_tokens":0,"total_tokens":16203},"status":"completed"}}\n\n) <>
          "data: [DONE]\n\n"

      assert ResponseUsage.from_sse(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 16_086,
               cached_input_tokens: 0,
               output_tokens: 117,
               reasoning_tokens: 0,
               total_tokens: 16_203,
               service_tier: "flex"
             }
    end

    test "uses retained service tier serialized after terminal usage" do
      json_like_output_text =
        String.duplicate(
          ~s({"usage":{"input_tokens":999,"output_tokens":999,"total_tokens":1998},"service_tier":"printed"}),
          80
        )

      body =
        sse_event("response.in_progress", %{
          "response" => %{
            "service_tier" => "auto",
            "usage" => %{
              "input_tokens" => 0,
              "cached_input_tokens" => 0,
              "output_tokens" => 0,
              "reasoning_tokens" => 0,
              "total_tokens" => 0
            }
          }
        }) <>
          ~s(output_text":"truncated prefix) <>
          ~s(","usage":{"input_tokens":16,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"reasoning_tokens":0,"total_tokens":21},"output_text":) <>
          Jason.encode!(json_like_output_text) <>
          ~s(,"service_tier":"flex","status":"completed"}}\n\n) <>
          "data: [DONE]\n\n"

      assert ResponseUsage.from_sse(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 16,
               cached_input_tokens: 0,
               output_tokens: 5,
               reasoning_tokens: 0,
               total_tokens: 21,
               service_tier: "flex"
             }
    end

    test "inherits stream service tier when retained terminal usage starts at usage" do
      body =
        sse_event("response.in_progress", %{
          "response" => %{
            "service_tier" => "priority",
            "usage" => %{
              "input_tokens" => 0,
              "cached_input_tokens" => 0,
              "output_tokens" => 0,
              "reasoning_tokens" => 0,
              "total_tokens" => 0
            }
          }
        }) <>
          ~s(output_text":"truncated prefix) <>
          ~s(","usage":{"input_tokens":11,"cached_input_tokens":2,"output_tokens":5,"reasoning_tokens":1,"total_tokens":16},"status":"completed"}}\n\n) <>
          "data: [DONE]\n\n"

      assert %{
               status: "usage_known",
               input_tokens: 11,
               cached_input_tokens: 2,
               output_tokens: 5,
               reasoning_tokens: 1,
               total_tokens: 16,
               service_tier: "priority"
             } = ResponseUsage.from_sse(body)
    end

    test "marks SSE without usage as unknown" do
      body = ~S"""
      data: {"type":"response.created"}

      data: [DONE]

      """

      assert ResponseUsage.from_sse(body) ==
               %{status: "usage_unknown", source: "sse_usage_missing"}
    end

    test "marks empty terminal usage maps as unknown" do
      body =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"usage" => %{}}
        })

      assert ResponseUsage.from_sse(body) ==
               %{status: "usage_unknown", source: "invalid_usage_tokens"}
    end

    test "keeps explicit zero token usage as known" do
      body =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{
            "usage" => %{
              "input_tokens" => 0,
              "cached_input_tokens" => 0,
              "output_tokens" => 0,
              "reasoning_tokens" => 0,
              "total_tokens" => 0
            }
          }
        })

      assert ResponseUsage.from_sse(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 0,
               cached_input_tokens: 0,
               output_tokens: 0,
               reasoning_tokens: 0,
               total_tokens: 0,
               service_tier: nil
             }
    end
  end

  describe "from_websocket_body/1" do
    test "preserves absent, zero, and positive terminal websocket cache-write counters" do
      for {reported, expected} <- [{:absent, nil}, {0, 0}, {5, 5}] do
        body = terminal_websocket_usage(reported)
        assert Map.get(ResponseUsage.from_websocket_body(body), :cache_write_tokens) == expected
      end
    end

    test "rejects malformed cache-write counters in retained websocket usage" do
      for invalid <- ["-1", "1.5", ~s("1"), "null"] do
        assert ResponseUsage.from_websocket_body(retained_usage_with_cache_write(invalid)) == %{
                 status: "usage_unknown",
                 source: "invalid_usage_tokens"
               }
      end
    end

    test "malformed retained terminal usage overrides earlier known websocket usage" do
      body = terminal_websocket_usage(0) <> "\n" <> retained_usage_with_cache_write("null")

      assert ResponseUsage.from_websocket_body(body) == %{
               status: "usage_unknown",
               source: "invalid_usage_tokens"
             }
    end

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

  defp chat_usage_body(reported) do
    details = cache_write_details(reported)

    Jason.encode!(%{
      "usage" => %{
        "prompt_tokens" => 10,
        "prompt_tokens_details" => details,
        "completion_tokens" => 7,
        "total_tokens" => 17
      }
    })
  end

  defp terminal_sse_usage(reported) do
    sse_event("response.completed", terminal_usage_payload(reported))
  end

  defp terminal_websocket_usage(reported), do: Jason.encode!(terminal_usage_payload(reported))

  defp terminal_usage_payload(reported) do
    %{
      "type" => "response.completed",
      "response" => %{
        "usage" => %{
          "input_tokens" => 10,
          "input_tokens_details" => cache_write_details(reported),
          "output_tokens" => 7,
          "total_tokens" => 17
        }
      }
    }
  end

  defp cache_write_details(:absent), do: %{"cached_tokens" => 4}

  defp cache_write_details(reported),
    do: %{"cached_tokens" => 4, "cache_write_tokens" => reported}

  defp retained_usage_with_cache_write(cache_write_tokens) do
    ~s|"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":4,"cache_write_tokens":#{cache_write_tokens}},"output_tokens":2,"total_tokens":12}}|
  end
end
