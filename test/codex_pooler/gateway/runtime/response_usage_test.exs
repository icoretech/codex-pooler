defmodule CodexPooler.Gateway.Runtime.Finalization.ResponseUsageTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  describe "from_json/1" do
    test "extracts flat usage from JSON responses" do
      body =
        CodexPooler.JSON.encode!(%{
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

    test "prefers canonical nested reasoning and falls back to accepted flat reasoning" do
      for {details, flat, expected} <- [
            {%{"reasoning_tokens" => 17}, 5, 17},
            {nil, 7, 7},
            {%{"reasoning_tokens" => -1}, 11, 11},
            {%{"reasoning_tokens" => "invalid"}, 13, 13},
            {%{"reasoning_tokens" => nil}, 15, 15}
          ] do
        usage = %{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "reasoning_tokens" => flat,
          "total_tokens" => 30
        }

        usage =
          if is_nil(details),
            do: usage,
            else: Map.put(usage, "output_tokens_details", details)

        assert %{reasoning_tokens: ^expected, total_tokens: 30} =
                 ResponseUsage.from_decoded(%{"usage" => usage})
      end
    end

    test "marks invalid canonical nested reasoning without a flat fallback as unknown" do
      for invalid <- [-1, 1.5, "invalid", nil] do
        decoded = %{
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 20,
            "output_tokens_details" => %{"reasoning_tokens" => invalid},
            "total_tokens" => 30
          }
        }

        assert ResponseUsage.from_decoded(decoded) == %{
                 status: "usage_unknown",
                 source: "invalid_usage_tokens"
               }
      end
    end

    test "matches decoded input without an encode-decode round trip" do
      decoded = %{
        "service_tier" => "priority",
        "usage" => %{
          "input_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 4},
          "output_tokens" => 7,
          "total_tokens" => 17
        }
      }

      assert ResponseUsage.from_decoded(decoded) ==
               ResponseUsage.from_json(CodexPooler.JSON.encode!(decoded))
    end

    test "preserves absent, zero, and positive Responses cache-write counters" do
      for {reported, expected} <- [{:absent, nil}, {0, 0}, {9, 9}] do
        details = %{"cached_tokens" => 4}

        details =
          if reported == :absent,
            do: details,
            else: Map.put(details, "cache_write_tokens", reported)

        body =
          CodexPooler.JSON.encode!(%{
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
        CodexPooler.JSON.encode!(%{
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
        CodexPooler.JSON.encode!(%{
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

      body = CodexPooler.JSON.encode!(%{"usage" => %{"input_tokens" => 1.2}})

      assert ResponseUsage.from_json(body) == %{
               status: "usage_unknown",
               source: "invalid_usage_tokens"
             }

      for invalid <- [-1, 1.5, "9", "not-an-integer", nil] do
        body =
          CodexPooler.JSON.encode!(%{
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
      for {reported, expected} <- [{:absent, nil}, {0, 0}, {6, 6}] do
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

    test "truncated records cannot provide aggregate provenance" do
      for prefix <- [~s(output_text":"truncated prefix), ~s({"response":)],
          usage <- [
            %{"input_tokens" => 21, "output_tokens" => 41, "total_tokens" => 62},
            %{"input_tokens" => 21, "output_tokens" => 41, "total_tokens" => 99}
          ] do
        retained = prefix <> ~s(,"usage":) <> CodexPooler.JSON.encode!(usage) <> "}}\n\n"

        assert %{status: "usage_unknown", source: "sse_usage_missing"} =
                 ResponseUsage.from_sse(retained)

        assert %{status: "usage_unknown", source: "websocket_usage_missing"} =
                 ResponseUsage.from_websocket_body(retained)
      end
    end

    test "unscoped retained fragments cannot override a complete event" do
      complete = terminal_sse_usage(0)
      fragment = retained_usage_with_cache_write(~s("invalid"))
      assert ResponseUsage.from_sse(complete <> fragment) == ResponseUsage.from_sse(complete)
    end

    test "a complete terminal event after a truncated prefix restores provenance" do
      body = ~s(truncated,"usage":{"input_tokens":999) <> "\n\n" <> terminal_sse_usage(0)
      assert ResponseUsage.from_sse(body) == ResponseUsage.from_sse(terminal_sse_usage(0))
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

    test "unscoped retained websocket fragments cannot override complete frames" do
      complete = terminal_websocket_usage(0)
      fragment = retained_usage_with_cache_write("null")

      assert ResponseUsage.from_websocket_body(complete <> "\n" <> fragment) ==
               ResponseUsage.from_websocket_body(complete)
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
          CodexPooler.JSON.encode!(%{"type" => "response.created"}),
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "service_tier" => "default",
              "usage" => %{
                "input_tokens" => 17,
                "cached_input_tokens" => 6,
                "output_tokens" => 19,
                "output_tokens_details" => %{"reasoning_tokens" => 3},
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
          CodexPooler.JSON.encode!(%{"type" => "response.in_progress"}),
          CodexPooler.JSON.encode!(%{
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
        CodexPooler.JSON.encode!(%{
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
          CodexPooler.JSON.encode!(%{"type" => "response.created"}),
          CodexPooler.JSON.encode!(%{
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
          CodexPooler.JSON.encode!(%{"type" => "response.created"}),
          CodexPooler.JSON.encode!(%{"type" => "response.in_progress"})
        ]
        |> Enum.join("\n")

      assert ResponseUsage.from_websocket_body(body) ==
               %{status: "usage_unknown", source: "websocket_usage_missing"}
    end

    test "marks terminal websocket frames without usage as websocket usage missing" do
      body =
        CodexPooler.JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{"id" => "resp_empty"}
        })

      assert ResponseUsage.from_websocket_body(body) ==
               %{status: "usage_unknown", source: "websocket_usage_missing"}
    end
  end

  defp sse_event(event, payload) do
    "event: " <> event <> "\n" <> "data: " <> CodexPooler.JSON.encode!(payload) <> "\n\n"
  end

  defp chat_usage_body(reported) do
    details = cache_write_details(reported)

    CodexPooler.JSON.encode!(%{
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

  defp terminal_websocket_usage(reported),
    do: CodexPooler.JSON.encode!(terminal_usage_payload(reported))

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
