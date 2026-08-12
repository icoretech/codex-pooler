defmodule CodexPooler.Gateway.Facade.Anthropic.MessagesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Anthropic.Messages
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @png Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>)
  @breakpoint %{"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}}

  test "coerces system blocks, multimodal tool history, cache controls, and thinking" do
    payload = %{
      "model" => "claude-client-alias-that-must-disappear",
      "max_tokens" => 512,
      "stream" => false,
      "system" => [
        %{"type" => "text", "text" => "Uncached system instruction."},
        Map.merge(%{"type" => "text", "text" => "Cached system instruction."}, @breakpoint)
      ],
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Inspect this image."},
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => @png
              }
            }
          ]
        },
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "I will look it up."},
            %{
              "type" => "tool_use",
              "id" => "toolu_local_fixture",
              "name" => "lookup_weather",
              "input" => %{"city" => "London"}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            Map.merge(
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_local_fixture",
                "content" => [%{"type" => "text", "text" => "cloudy"}]
              },
              @breakpoint
            ),
            %{"type" => "text", "text" => "Give the final forecast."}
          ]
        }
      ],
      "tools" => [
        %{
          "name" => "lookup_weather",
          "description" => "Look up weather",
          "input_schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => "lookup_weather"},
      "stop_sequences" => ["<END>"],
      "temperature" => 0.2,
      "top_p" => 0.8,
      "thinking" => %{"type" => "enabled", "budget_tokens" => 1_024}
    }

    assert {:ok, coerced} = Messages.coerce(payload, request_opts())

    assert coerced.endpoint == "/backend-api/codex/responses"
    assert coerced.request_options.persona == Persona.fixed(:anthropic_messages)
    assert coerced.request_options.openai_compatibility.collect_openai_response_stream
    assert coerced.payload["model"] == "gpt-5.6-sol"
    assert coerced.payload["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert coerced.payload["stream"] == true
    assert coerced.payload["store"] == false
    assert coerced.payload["max_output_tokens"] == 512
    assert coerced.payload["temperature"] == 0.2
    assert coerced.payload["top_p"] == 0.8
    assert coerced.payload["tool_choice"] == %{"type" => "function", "name" => "lookup_weather"}
    assert coerced.payload["prompt_cache_options"] == %{"mode" => "explicit"}
    refute Map.has_key?(coerced.payload, "stop_sequences")

    assert coerced.anthropic_formatting == %{
             stream?: false,
             think?: true,
             stops: ["<END>"],
             max_tokens: 512
           }

    assert coerced.payload["instructions"] =~ "Uncached system instruction."
    assert coerced.payload["instructions"] =~ "Your external model identity is gemma3"

    refute Jason.encode!(coerced.payload) =~ "claude-client-alias-that-must-disappear"

    assert [cached_system, user_image, assistant_text, call, result, final_user] =
             coerced.payload["input"]

    assert cached_system == %{
             "type" => "message",
             "role" => "developer",
             "content" => [
               %{
                 "type" => "input_text",
                 "text" => "Cached system instruction.",
                 "prompt_cache_breakpoint" => %{"mode" => "explicit"}
               }
             ]
           }

    assert %{
             "type" => "message",
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "Inspect this image."},
               %{"type" => "input_image", "image_url" => image_url}
             ]
           } = user_image

    assert String.starts_with?(image_url, "data:image/png;base64,")

    assert assistant_text == %{
             "type" => "message",
             "role" => "assistant",
             "content" => [
               %{"type" => "output_text", "text" => "I will look it up."}
             ]
           }

    assert call == %{
             "type" => "function_call",
             "call_id" => "toolu_local_fixture",
             "name" => "lookup_weather",
             "arguments" => Jason.encode!(%{"city" => "London"})
           }

    assert result == %{
             "type" => "function_call_output",
             "call_id" => "toolu_local_fixture",
             "output" => [
               %{
                 "type" => "input_text",
                 "text" => "cloudy",
                 "prompt_cache_breakpoint" => %{"mode" => "explicit"}
               }
             ]
           }

    assert final_user == %{
             "type" => "message",
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "Give the final forecast."}
             ]
           }

    assert [tool] = coerced.payload["tools"]
    assert tool["type"] == "function"
    assert tool["name"] == "lookup_weather"
    assert tool["description"] == "Look up weather"
    assert tool["parameters"] == hd(payload["tools"])["input_schema"]
  end

  test "accepts string system prompts and multi-turn string content" do
    assert {:ok, coerced} =
             Messages.coerce(
               %{
                 "system" => "Be concise.",
                 "messages" => [
                   %{"role" => "user", "content" => "Hello"},
                   %{"role" => "assistant", "content" => "Hi"},
                   %{"role" => "user", "content" => "Continue"}
                 ],
                 "max_tokens" => 64
               },
               request_opts()
             )

    assert coerced.payload["instructions"] =~ "Be concise."

    assert Enum.map(coerced.payload["input"], & &1["role"]) == [
             "user",
             "assistant",
             "user"
           ]
  end

  test "normalizes missing and arbitrary aliases to fixed target and max effort" do
    for selector <- [:missing, "claude-opus-client-alias"] do
      payload = %{
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "max_tokens" => 32
      }

      payload = if selector == :missing, do: payload, else: Map.put(payload, "model", selector)

      assert {:ok, coerced} = Messages.coerce(payload, request_opts())
      assert coerced.payload["model"] == "gpt-5.6-sol"
      assert coerced.payload["reasoning"] == %{"effort" => "max"}
      refute Jason.encode!(coerced.payload) =~ "claude-opus-client-alias"
    end
  end

  test "accepts current Claude Code context controls without delegating persona policy" do
    client_metadata =
      ~s({"device_id":"claude-device-private","session_id":"claude-session-private"})

    payload = %{
      "model" => "claude-client-model-private",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 32_000,
      "metadata" => %{"user_id" => client_metadata},
      "context_management" => %{
        "edits" => [%{"keep" => "all", "type" => "clear_thinking_20251015"}]
      },
      "output_config" => %{"effort" => "low"},
      "thinking" => %{"display" => "omitted", "type" => "adaptive"}
    }

    assert {:ok, coerced} = Messages.coerce(payload, request_opts())
    assert coerced.payload["model"] == "gpt-5.6-sol"
    assert coerced.payload["reasoning"] == %{"effort" => "max"}
    refute coerced.anthropic_formatting.think?

    encoded = Jason.encode!(coerced.payload)

    for hidden <- [
          "claude-client-model-private",
          "claude-device-private",
          "claude-session-private",
          "context_management",
          "output_config"
        ] do
      refute encoded =~ hidden
    end
  end

  test "translates every supported Anthropic tool choice" do
    base = %{
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 32,
      "tools" => [
        %{
          "name" => "lookup",
          "input_schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{}
          }
        }
      ]
    }

    for {choice, expected, parallel?} <- [
          {%{"type" => "auto"}, "auto", nil},
          {%{"type" => "auto", "disable_parallel_tool_use" => true}, "auto", false},
          {%{"type" => "any"}, "required", nil},
          {%{"type" => "tool", "name" => "lookup"}, %{"type" => "function", "name" => "lookup"},
           nil},
          {%{"type" => "none"}, "none", nil}
        ] do
      assert {:ok, canonical, _formatting} =
               Messages.to_responses(Map.put(base, "tool_choice", choice))

      assert canonical["tool_choice"] == expected

      if is_nil(parallel?) do
        refute Map.has_key?(canonical, "parallel_tool_calls")
      else
        assert canonical["parallel_tool_calls"] == parallel?
      end
    end
  end

  test "maps automatic and nested explicit cache controls to existing cache modes" do
    automatic = %{
      "cache_control" => %{"type" => "ephemeral"},
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 32
    }

    assert {:ok, automatic_canonical, _formatting} = Messages.to_responses(automatic)
    assert automatic_canonical["prompt_cache_options"] == %{"mode" => "implicit"}

    explicit = %{
      "messages" => [
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_cache",
              "name" => "lookup",
              "input" => %{}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_cache",
              "content" => [
                %{
                  "type" => "text",
                  "text" => "cached nested output",
                  "cache_control" => %{"type" => "ephemeral"}
                }
              ]
            }
          ]
        }
      ],
      "max_tokens" => 32
    }

    assert {:ok, explicit_canonical, _formatting} = Messages.to_responses(explicit)
    assert explicit_canonical["prompt_cache_options"] == %{"mode" => "explicit"}

    assert get_in(explicit_canonical, [
             "input",
             Access.at(1),
             "output",
             Access.at(0),
             "prompt_cache_breakpoint"
           ]) == %{"mode" => "explicit"}

    tool_cached = %{
      "messages" => [%{"role" => "user", "content" => "use the tool"}],
      "max_tokens" => 32,
      "tools" => [
        %{
          "name" => "cached_lookup",
          "input_schema" => %{"type" => "object", "properties" => %{}},
          "cache_control" => %{"type" => "ephemeral"}
        }
      ]
    }

    assert {:ok, tool_canonical, _formatting} = Messages.to_responses(tool_cached)
    assert tool_canonical["prompt_cache_options"] == %{"mode" => "explicit"}

    assert get_in(tool_canonical, ["tools", Access.at(0), "prompt_cache_breakpoint"]) ==
             %{"mode" => "explicit"}
  end

  test "rejects unsupported or malformed request shapes locally" do
    base = %{
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 32
    }

    cases = [
      {Map.delete(base, "messages"), "messages"},
      {Map.delete(base, "max_tokens"), "max_tokens"},
      {Map.put(base, "stream", "false"), "stream"},
      {Map.put(base, "max_tokens", 0), "max_tokens"},
      {Map.put(base, "stop_sequences", []), "stop_sequences"},
      {Map.put(base, "stop_sequences", List.duplicate("x", 17)), "stop_sequences"},
      {Map.put(base, "thinking", %{"type" => "enabled", "budget_tokens" => 0}),
       "thinking.budget_tokens"},
      {Map.put(base, "top_k", 10), "top_k"},
      {Map.put(base, "unknown", true), "unknown"},
      {Map.put(base, "tool_choice", %{"type" => "tool", "name" => "missing"}), "tool_choice"},
      {%{base | "messages" => [%{"role" => "system", "content" => "bad"}]}, "messages[0].role"},
      {%{
         base
         | "messages" => [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "image/svg+xml",
                     "data" => "PHN2Zz4="
                   }
                 }
               ]
             }
           ]
       }, "messages[0].content[0].source.media_type"}
    ]

    for {payload, param} <- cases do
      assert {:error, %{status: 400, param: ^param}} = Messages.coerce(payload, request_opts())
    end
  end

  defp request_opts do
    %{
      persona: Persona.fixed(:anthropic_messages),
      upstream_endpoint: "/backend-api/codex/responses",
      collect_openai_response_stream: true
    }
  end
end
