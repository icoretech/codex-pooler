defmodule CodexPooler.Gateway.OpenAICompatibilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.{
    Audio,
    Chat,
    Files,
    Images,
    Matrix,
    Responses,
    Validation
  }

  alias CodexPooler.Gateway.Payloads.RequestOptions

  test "supported field matrix covers endpoint families" do
    assert "model" in Matrix.supported_fields(:responses)
    assert "messages" in Matrix.supported_fields(:chat)
    assert "input" in Matrix.supported_fields(:chat)
    assert "instructions" in Matrix.supported_fields(:chat)
    assert "purpose" in Matrix.supported_fields(:files)
    assert "file" in Matrix.supported_fields(:audio)
    assert "input_fidelity" in Matrix.supported_fields(:images)
  end

  test "supported field matrix tracks current SDK top-level request fields" do
    openai_chat_fields =
      ~w(audio frequency_penalty function_call functions logit_bias logprobs max_completion_tokens max_tokens messages metadata modalities model moderation n parallel_tool_calls prediction presence_penalty prompt_cache_key prompt_cache_retention reasoning_effort response_format safety_identifier seed service_tier stop store stream stream_options temperature tool_choice tools top_logprobs top_p user verbosity web_search_options)

    openai_responses_fields =
      ~w(background context_management conversation include input instructions max_output_tokens metadata model moderation parallel_tool_calls previous_response_id prompt prompt_cache_key prompt_cache_retention reasoning safety_identifier service_tier store stream stream_options temperature text tool_choice tools top_logprobs top_p truncation user)

    assert MapSet.subset?(
             MapSet.new(openai_chat_fields),
             MapSet.new(Matrix.supported_fields(:chat))
           )

    assert MapSet.subset?(
             MapSet.new(openai_responses_fields),
             MapSet.new(Matrix.supported_fields(:responses))
           )
  end

  @tag :responses_coercion
  test "accepted Responses fields coerce to gateway payload and request options" do
    payload = %{
      "model" => "gpt-fixture-text",
      "instructions" => "Use concise synthetic output",
      "input" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ],
      "tool_choice" => "auto",
      "moderation" => %{"model" => "omni-moderation-latest"},
      "reasoning" => %{"effort" => "focused", "context" => "all_turns"},
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"ok" => %{"type" => "boolean"}},
            "required" => ["ok"]
          }
        }
      },
      "stream" => true
    }

    assert {:ok, result} =
             Responses.coerce(payload,
               request_id: "req_fixture",
               collect_openai_response_stream: true
             )

    assert result.endpoint == "/backend-api/codex/responses"
    assert result.payload["model"] == "gpt-fixture-text"
    assert result.payload["tools"] == payload["tools"]
    assert result.payload["moderation"] == %{"model" => "omni-moderation-latest"}
    assert result.payload["reasoning"] == %{"effort" => "focused", "context" => "all_turns"}
    assert result.payload["stream"] == true
    assert result.payload["store"] == false

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic input"}]
             }
           ] =
             result.payload["input"]

    assert %RequestOptions{} = result.request_options
    assert RequestOptions.route_class(result.request_options) == "proxy_stream"
    assert result.request_options.routing.requested_model == nil
    refute inspect(result.request_options.request_metadata) =~ "synthetic input"
  end

  @tag :responses_coercion
  test "Responses accepts SDK reasoning context variants and forwards normalized values" do
    accepted_contexts = [
      {"auto", "auto"},
      {" Current_Turn ", "current_turn"},
      {"ALL_TURNS", "all_turns"}
    ]

    Enum.each(accepted_contexts, fn {context, expected_context} ->
      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "reasoning" => %{"context" => context}
               })

      assert result.payload["reasoning"] == %{"context" => expected_context}
    end)
  end

  @tag :responses_coercion
  test "string Responses input coerces to a backend-compatible input_text message" do
    assert {:ok, result} =
             Responses.coerce(
               %{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic direct string input"
               },
               collect_openai_response_stream: true
             )

    assert result.payload["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic direct string input"}]
             }
           ]
  end

  @tag :responses_coercion
  test "Responses system and developer message input text lifts into instructions" do
    assert {:ok, result} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "instructions" => "Base synthetic instruction",
               "input" => [
                 %{
                   "type" => "message",
                   "role" => "system",
                   "content" => [%{"type" => "input_text", "text" => " synthetic system "}]
                 },
                 %{
                   "type" => "message",
                   "role" => "developer",
                   "content" => [
                     %{"type" => "input_text", "text" => "synthetic developer"},
                     %{"type" => "text", "text" => " "},
                     %{"type" => "input_image", "image_url" => "https://example.com/image.png"}
                   ]
                 },
                 %{
                   "type" => "message",
                   "role" => "system",
                   "content" => [
                     %{"type" => "text", "text" => "synthetic second system"},
                     %{"type" => "input_file", "file_id" => "file_fixture"}
                   ]
                 },
                 %{"role" => "user", "content" => "synthetic input"}
               ]
             })

    assert result.payload["instructions"] ==
             "Base synthetic instruction\nsynthetic system\nsynthetic developer\nsynthetic second system"

    assert result.payload["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_image", "image_url" => "https://example.com/image.png"}
               ]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_file", "file_id" => "file_fixture"}]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic input"}]
             }
           ]
  end

  @tag :responses_coercion
  test "Responses rejects malformed instruction-role content before dispatch" do
    assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [
                 %{
                   "role" => "developer",
                   "content" => [%{"type" => "input_image", "image_url" => %{"url" => nil}}]
                 }
               ]
             })
  end

  describe "Task 2 Responses additional_tools input item compatibility" do
    @tag :responses_coercion
    test "Responses preserves request-shaped additional_tools input items without executable tool merging" do
      additional_tool =
        flat_function_tool(
          "lookup_additional_fixture",
          %{"type" => "object", "properties" => %{}},
          nil
        )

      additional_tools_item = %{
        "type" => "additional_tools",
        "role" => "developer",
        "tools" => [additional_tool]
      }

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{"role" => "user", "content" => "synthetic input"},
                   additional_tools_item
                 ]
               })

      assert result.payload["input"] == [
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "synthetic input"}]
               },
               additional_tools_item
             ]

      refute Map.has_key?(result.payload, "tools")
      refute Map.has_key?(result.payload, "tool_choice")
    end

    @tag :responses_coercion
    test "Responses accepts empty additional_tools lists and optional ids" do
      valid_items = [
        %{"type" => "additional_tools", "role" => "developer", "tools" => []},
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [],
          "id" => "at_fixture"
        }
      ]

      Enum.each(valid_items, fn item ->
        assert {:ok, result} =
                 Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})

        assert result.payload["input"] == [item]
      end)
    end

    @tag :unsupported_fields
    test "additional_tools input items do not satisfy top-level tool_choice" do
      additional_tools_item = %{
        "type" => "additional_tools",
        "role" => "developer",
        "tools" => [
          flat_function_tool(
            "lookup_additional_fixture",
            %{"type" => "object", "properties" => %{}},
            nil
          )
        ]
      }

      for coerce <- [&Responses.coerce/1, &Chat.coerce/1] do
        assert {:error, reason} =
                 coerce.(%{
                   "model" => "gpt-fixture-text",
                   "input" => [additional_tools_item],
                   "tool_choice" => %{"type" => "function", "name" => "lookup_additional_fixture"}
                 })

        assert reason == %{
                 status: 400,
                 code: "invalid_request",
                 message: "tool_choice references unknown function tool",
                 param: "tool_choice"
               }
      end
    end

    @tag :unsupported_fields
    test "Responses rejects top-level additional_tools" do
      assert {:error, reason} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "additional_tools" => []
               })

      assert reason == %{
               status: 400,
               code: "unsupported_parameter",
               message: "Unsupported parameter: additional_tools",
               param: "additional_tools"
             }
    end

    @tag :unsupported_fields
    test "Responses rejects malformed and output-shaped additional_tools input items" do
      invalid_items = [
        %{"type" => "additional_tools", "tools" => []},
        %{"type" => "additional_tools", "role" => "assistant", "tools" => []},
        %{"type" => "additional_tools", "role" => "system", "tools" => []},
        %{"type" => "additional_tools", "role" => "developer", "tools" => %{}},
        %{"type" => "additional_tools", "role" => "developer"},
        %{"type" => "additional_tools", "role" => "developer", "tools" => [], "id" => ""},
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [],
          "id" => "   "
        },
        %{"type" => "additional_tools", "role" => "developer", "tools" => [], "id" => 123},
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [],
          "output" => []
        },
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [],
          "status" => "completed"
        },
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [],
          "summary" => []
        },
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [],
          "content" => []
        },
        %{
          "type" => "additional_tools",
          "id" => "at_output_fixture",
          "role" => "assistant",
          "tools" => [],
          "status" => "completed"
        }
      ]

      Enum.each(invalid_items, fn item ->
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})
      end)
    end

    @tag :unsupported_fields
    test "Responses rejects remote MCP tools inside additional_tools input items" do
      remote_mcp_tools = [
        %{
          "type" => "mcp",
          "server_label" => "fixture-mcp",
          "server_url" => "https://mcp.example.com"
        },
        %{
          "type" => "mcp",
          "server_label" => "fixture-mcp",
          "connector_id" => "connector_googledrive"
        },
        %{
          "type" => "mcp",
          "server_label" => "fixture-mcp",
          "tunnel_id" => "mcp_tunnel_fixture"
        }
      ]

      Enum.each(remote_mcp_tools, fn tool ->
        additional_tools_item = %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [tool]
        }

        for coerce <- [&Responses.coerce/1, &Chat.coerce/1] do
          assert {:error, reason} =
                   coerce.(%{
                     "model" => "gpt-fixture-text",
                     "input" => [additional_tools_item]
                   })

          assert reason == %{
                   status: 400,
                   code: "invalid_request",
                   message: "remote MCP tools are not supported",
                   param: "input"
                 }
        end
      end)
    end
  end

  @tag :responses_coercion
  test "Chat payloads coerce through a Responses-compatible intermediate" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [
        %{"role" => "system", "content" => "Synthetic system"},
        %{"role" => "user", "content" => "Synthetic user"}
      ],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "fixture_schema",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"answer" => %{"type" => "string"}},
            "required" => ["answer"]
          }
        }
      },
      "tool_choice" => "none"
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)
    assert result.endpoint == "/backend-api/codex/responses"
    assert result.payload["model"] == "gpt-fixture-text"
    assert result.payload["stream"] == true
    assert result.payload["store"] == false

    assert result.payload["instructions"] == "Synthetic system"

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Synthetic user"}]
             }
           ] = result.payload["input"]

    assert get_in(result.payload, ["text", "format", "type"]) == "json_schema"
    assert get_in(result.payload, ["text", "format", "strict"]) == true
  end

  @tag :responses_coercion
  test "Chat translates Cline tool-call and tool-result message parts" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Synthetic assistant tool setup"},
            %{
              "type" => "tool-call",
              "toolCallId" => "call_fixture_cline",
              "toolName" => "run_commands",
              "input" => %{"commands" => ["printf fixture"]}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool-result",
              "toolCallId" => "call_fixture_cline",
              "toolName" => "run_commands",
              "output" => [
                %{"type" => "text", "text" => "synthetic tool stdout"},
                %{"type" => "image_url", "image_url" => "https://example.com/sample.png"},
                %{"type" => "image", "data" => "YWJj", "mediaType" => "image/jpeg"}
              ],
              "isError" => false
            }
          ]
        }
      ]
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)

    assert [assistant_message, function_call, function_output] = result.payload["input"]

    assert assistant_message == %{
             "type" => "message",
             "role" => "assistant",
             "content" => [%{"type" => "output_text", "text" => "Synthetic assistant tool setup"}]
           }

    assert %{
             "type" => "function_call",
             "call_id" => "call_fixture_cline",
             "name" => "run_commands",
             "arguments" => arguments
           } = function_call

    assert Jason.decode!(arguments) == %{"commands" => ["printf fixture"]}

    assert function_output == %{
             "type" => "function_call_output",
             "call_id" => "call_fixture_cline",
             "output" => [
               %{"type" => "input_text", "text" => "synthetic tool stdout"},
               %{"type" => "input_image", "image_url" => "https://example.com/sample.png"},
               %{"type" => "input_image", "image_url" => "data:image/jpeg;base64,YWJj"}
             ]
           }

    refute inspect(result.payload["input"]) =~ "toolCallId"
  end

  @tag :responses_coercion
  test "Chat preserves assistant tool_calls before Cline tool-result message parts" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [
        %{
          "role" => "assistant",
          "content" => "Synthetic assistant replay",
          "tool_calls" => [
            %{
              "id" => "call_fixture_cline_replay",
              "type" => "function",
              "function" => %{
                "name" => "execute_command",
                "arguments" => "{\"command\":\"printf fixture\"}"
              }
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool-result",
              "toolCallId" => "call_fixture_cline_replay",
              "toolName" => "execute_command",
              "output" => %{"output" => "synthetic command output", "exitCode" => 0},
              "isError" => false
            }
          ]
        }
      ]
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)

    assert [assistant_message, function_call, function_output] = result.payload["input"]

    assert assistant_message == %{
             "type" => "message",
             "role" => "assistant",
             "content" => [%{"type" => "output_text", "text" => "Synthetic assistant replay"}]
           }

    assert function_call == %{
             "type" => "function_call",
             "call_id" => "call_fixture_cline_replay",
             "name" => "execute_command",
             "arguments" => "{\"command\":\"printf fixture\"}"
           }

    assert function_output == %{
             "type" => "function_call_output",
             "call_id" => "call_fixture_cline_replay",
             "output" => %{"exitCode" => 0, "output" => "synthetic command output"}
           }

    refute inspect(result.payload["input"]) =~ "tool_calls"
    refute inspect(result.payload["input"]) =~ "toolCallId"
  end

  @tag :structured_tool_result_pass_through
  test "Chat forwards structured Cline tool-result output unchanged" do
    structured_output = structured_tool_result_output()

    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => "call_fixture_cline_structured",
              "type" => "function",
              "function" => %{
                "name" => "execute_command",
                "arguments" => "{\"command\":\"synthetic\"}"
              }
            }
          ],
          "content" => "Synthetic assistant replay"
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool-result",
              "toolCallId" => "call_fixture_cline_structured",
              "toolName" => "execute_command",
              "output" => structured_output,
              "isError" => false
            }
          ]
        }
      ]
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)
    assert [_assistant_message, _function_call, function_output] = result.payload["input"]
    assert function_output["type"] == "function_call_output"
    assert function_output["call_id"] == "call_fixture_cline_structured"

    assert_payload_equal_no_echo!(
      function_output["output"],
      structured_output,
      "structured Cline tool-result output was not forwarded unchanged"
    )
  end

  @tag :responses_coercion
  test "Chat maps supported SDK controls instead of silently dropping them" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "Synthetic user"}],
      "max_completion_tokens" => 123,
      "metadata" => %{"fixture" => "true"},
      "moderation" => %{"model" => "omni-moderation-latest"},
      "prompt_cache_key" => "fixture-cache-key",
      "prompt_cache_retention" => "24h",
      "reasoning_effort" => "focused",
      "safety_identifier" => "fixture-safety-id",
      "service_tier" => "priority",
      "temperature" => 0.2,
      "top_p" => 0.9,
      "verbosity" => "low"
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)
    assert result.payload["max_output_tokens"] == 123
    assert result.payload["metadata"] == %{"fixture" => "true"}
    assert result.payload["moderation"] == %{"model" => "omni-moderation-latest"}
    assert result.payload["prompt_cache_key"] == "fixture-cache-key"
    assert result.payload["prompt_cache_retention"] == "24h"

    assert result.request_options.routing.prompt_cache_key ==
             prompt_cache_key_hash("fixture-cache-key")

    refute result.request_options.routing.prompt_cache_key == "fixture-cache-key"
    refute Map.has_key?(result.request_options.extra, "prompt_cache_key")
    assert result.payload["reasoning"] == %{"effort" => "focused"}
    assert result.payload["safety_identifier"] == "fixture-safety-id"
    assert result.payload["service_tier"] == "priority"
    assert result.payload["temperature"] == 0.2
    assert result.payload["top_p"] == 0.9
    assert result.payload["text"]["verbosity"] == "low"
  end

  @tag :responses_coercion
  test "Chat normalizes enum controls before forwarding them" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "Synthetic user"}],
      "reasoning_effort" => " LOW ",
      "service_tier" => " Priority ",
      "verbosity" => " HIGH "
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)

    assert result.payload["reasoning"] == %{"effort" => "low"}
    assert result.payload["service_tier"] == "priority"
    assert result.payload["text"]["verbosity"] == "high"
  end

  @tag :responses_coercion
  test "Chat falls back to Responses-shaped input when messages are absent" do
    payload = %{
      "model" => "gpt-fixture-text",
      "instructions" => "Use synthetic fixture instructions",
      "input" => [
        %{"role" => "developer", "content" => "synthetic fallback instruction"},
        %{"role" => "user", "content" => "synthetic fallback input"}
      ],
      "tools" => [
        flat_function_tool("lookup_fixture", %{"type" => "object", "properties" => %{}}, nil)
      ],
      "tool_choice" => "auto"
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)

    assert result.payload["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic fallback input"}]
             }
           ]

    assert result.payload["instructions"] ==
             "Use synthetic fixture instructions\nsynthetic fallback instruction"

    assert result.payload["tools"] == payload["tools"]
    assert result.payload["tool_choice"] == "auto"
    assert result.payload["stream"] == true
    assert result.payload["store"] == false
  end

  @tag :responses_coercion
  test "Chat falls back to Responses-shaped input when messages are empty" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [],
      "input" => "synthetic fallback input"
    }

    assert {:ok, result} = Chat.coerce(payload)

    assert result.payload["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic fallback input"}]
             }
           ]

    assert result.payload["instructions"] == ""
  end

  @tag :responses_coercion
  test "Chat keeps non-empty messages authoritative over conflicting input" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic message input"}],
      "input" => "synthetic conflicting fallback input"
    }

    assert {:ok, result} = Chat.coerce(payload)

    assert result.payload["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic message input"}]
             }
           ]
  end

  @tag :unsupported_fields
  test "Chat still rejects empty messages when no fallback input is present" do
    assert {:error, reason} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => []
             })

    assert reason == %{
             status: 400,
             code: "invalid_request",
             message: "messages must be a non-empty array",
             param: "messages"
           }
  end

  @tag :responses_coercion
  test "Images generation validates parameters and builds an image_generation Responses payload" do
    payload = %{
      "model" => "gpt-image-1",
      "prompt" => "synthetic image request",
      "size" => "1024x1024",
      "quality" => "high",
      "background" => "transparent",
      "input_fidelity" => "high",
      "n" => 1
    }

    assert {:ok, result} = Images.coerce_generation(payload)
    assert result.endpoint == "/backend-api/codex/responses"
    assert result.payload["model"] == "gpt-image-1"
    assert result.payload["stream"] == true
    assert [%{"type" => "image_generation", "quality" => "high"}] = result.payload["tools"]
    assert result.payload["tool_choice"] == %{"type" => "image_generation"}
  end

  @tag :responses_coercion
  test "Audio transcription builds a backend multipart dispatch envelope" do
    upload = audio_upload_fixture("synthetic audio bytes")

    payload = %{
      "model" => "gpt-4o-transcribe",
      "file" => upload,
      "prompt" => "synthetic glossary",
      "response_format" => "json"
    }

    assert {:ok, result} = Audio.coerce_transcription(payload, request_id: "req_fixture")
    assert result.endpoint == "/backend-api/transcribe"
    assert result.payload == payload
    assert %Plug.Upload{} = result.payload["file"]
    assert result.audio_payload["file"]["content_type"] == "audio/wav"
    assert result.audio_payload["file"]["bytes"] == byte_size("synthetic audio bytes")
    assert result.request_options.transport.route_class == "audio_transcription"
    assert result.request_options.transport.upstream_endpoint == "/backend-api/transcribe"

    assert result.request_options.payload_context.forced_transcription_model ==
             "gpt-4o-transcribe"

    assert result.request_options.request_metadata.request_id == "req_fixture"
  end

  @tag :responses_validation
  test "OpenAI shell validation uses validation-only adapter contracts" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic direct string input"
    }

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic"}]
    }

    image_payload = %{
      "model" => "gpt-image-1",
      "prompt" => "synthetic image request"
    }

    assert {:ok, ^response_payload} = Responses.validate(response_payload)
    assert {:ok, ^chat_payload} = Chat.validate(chat_payload)
    assert {:ok, ^image_payload} = Images.validate_generation(image_payload)

    assert :ok = Validation.validate_shell(:responses, response_payload)
    assert :ok = Validation.validate_shell(:chat, chat_payload)
    assert :ok = Validation.validate_shell(:image_generations, image_payload)

    assert {:error, %{code: "invalid_request", param: "tools"}} =
             Validation.validate_shell(:responses, %{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [%{"type" => "function", "function" => %{}}]
             })
  end

  @tag :responses_validation
  test "public compatibility validators return structured errors for non-map payloads" do
    expected_reason = %{
      status: 400,
      code: "invalid_request",
      message: "request body must be an object",
      param: nil
    }

    assert {:error, ^expected_reason} = Validation.normalize_payload("not an object")
    assert {:error, ^expected_reason} = Responses.validate(["not", "an", "object"])
    assert {:error, ^expected_reason} = Responses.coerce(:not_an_object)
    assert {:error, ^expected_reason} = Chat.validate(nil)
    assert {:error, ^expected_reason} = Chat.coerce(nil)
    assert {:error, ^expected_reason} = Images.validate_generation(42)
    assert {:error, ^expected_reason} = Images.coerce_generation(42)
    assert {:error, ^expected_reason} = Images.validate_edit(false)
    assert {:error, ^expected_reason} = Images.coerce_edit(false)
    assert {:error, ^expected_reason} = Files.validate_create("file payload")
    assert {:error, ^expected_reason} = Audio.validate_transcription("audio payload")
    assert {:error, ^expected_reason} = Audio.coerce_transcription("audio payload")
    assert {:error, ^expected_reason} = Validation.validate_shell(:responses, "not an object")
  end

  @tag :unsupported_fields
  test "logprobs returns deterministic unsupported parameter errors" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "logprobs" => true
             })

    assert reason == %{
             status: 400,
             code: "unsupported_parameter",
             message: "Unsupported parameter: logprobs",
             param: "logprobs"
           }
  end

  @tag :unsupported_fields
  test "known but locally unsupported SDK fields return deterministic errors" do
    for field <- ["n", "prediction", "stop", "web_search_options"] do
      assert {:error, %{status: 400, code: "unsupported_parameter", param: ^field}} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic"}],
                 field => unsupported_value(field)
               })
    end

    for field <- ["background", "conversation", "prompt"] do
      assert {:error, %{status: 400, code: "unsupported_parameter", param: ^field}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 field => unsupported_value(field)
               })
    end
  end

  @tag :unsupported_fields
  test "Chat does not support top-level additional_tools on fallback or messages paths" do
    invalid_payloads = [
      %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic fallback input",
        "additional_tools" => [
          %{"type" => "function", "name" => "lookup_fixture", "parameters" => %{}}
        ]
      },
      %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic message input"}],
        "additional_tools" => [
          %{"type" => "function", "name" => "lookup_fixture", "parameters" => %{}}
        ]
      }
    ]

    Enum.each(invalid_payloads, fn payload ->
      assert {:error, reason} = Chat.coerce(payload)

      assert reason == %{
               status: 400,
               code: "unsupported_parameter",
               message: "Unsupported parameter: additional_tools",
               param: "additional_tools"
             }
    end)
  end

  @tag :unsupported_fields
  test "unknown stream_options keys return deterministic errors" do
    assert {:error, %{status: 400, code: "invalid_request", param: "stream_options.unknown"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "synthetic"}],
               "stream_options" => %{"include_usage" => true, "unknown" => true}
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "stream_options.unknown"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "stream_options" => %{"include_obfuscation" => false, "unknown" => true}
             })
  end

  @tag :unsupported_fields
  test "moderation and reasoning context accept only narrow supported shapes" do
    invalid_payloads = [
      {%{"moderation" => %{}}, "moderation.model"},
      {%{"moderation" => %{"model" => " "}}, "moderation.model"},
      {%{"moderation" => %{"model" => "omni-moderation-latest", "extra" => true}},
       "moderation.extra"},
      {%{"moderation" => "omni-moderation-latest"}, "moderation"},
      {%{"reasoning" => %{"context" => "recent_turns"}}, "reasoning.context"},
      {%{"reasoning" => %{"effort" => " "}}, "reasoning.effort"},
      {%{"reasoning" => %{"effort" => "very high"}}, "reasoning.effort"},
      {%{"reasoning" => %{"effort" => "high!!!"}}, "reasoning.effort"},
      {%{"reasoning" => %{"effort" => "synthetic freeform effort text"}}, "reasoning.effort"},
      {%{"reasoning" => %{"effort" => "focused\nmax"}}, "reasoning.effort"},
      {%{"reasoning" => %{"effort" => String.duplicate("a", 33)}}, "reasoning.effort"}
    ]

    Enum.each(invalid_payloads, fn {payload, expected_param} ->
      assert {:error, %{status: 400, code: "invalid_request", param: ^expected_param}} =
               Responses.coerce(
                 Map.merge(
                   %{"model" => "gpt-fixture-text", "input" => "synthetic input"},
                   payload
                 )
               )
    end)

    assert {:error, %{status: 400, code: "invalid_request", param: "moderation.model"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "synthetic"}],
               "moderation" => %{"model" => " "}
             })

    invalid_chat_efforts = [
      "",
      "   ",
      "very high",
      "high!!!",
      "synthetic freeform effort text",
      "focused\nmax",
      String.duplicate("a", 33)
    ]

    Enum.each(invalid_chat_efforts, fn effort ->
      assert {:error, %{status: 400, code: "invalid_request", param: "reasoning_effort"}} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic"}],
                 "reasoning_effort" => effort
               })
    end)
  end

  @tag :unsupported_fields
  test "token limit fields require positive integers before forwarding" do
    for {field, value} <- [{"max_tokens", "128"}, {"max_completion_tokens", 0}] do
      assert {:error, %{status: 400, code: "invalid_request", param: ^field}} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic"}],
                 field => value
               })
    end

    assert {:error, %{status: 400, code: "invalid_request", param: "max_output_tokens"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "max_output_tokens" => -1
             })
  end

  @tag :responses_coercion
  test "Responses forwards supported SDK scalar controls" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "max_output_tokens" => 321,
      "metadata" => %{"fixture" => "true"},
      "moderation" => %{"model" => "omni-moderation-latest"},
      "prompt_cache_key" => "fixture-cache-key",
      "prompt_cache_retention" => "24h",
      "safety_identifier" => "fixture-safety-id",
      "stream_options" => %{"include_obfuscation" => false},
      "temperature" => 0.3,
      "top_p" => 0.8
    }

    assert {:ok, result} = Responses.coerce(payload, collect_openai_response_stream: true)

    assert Map.take(result.payload, Map.keys(payload) -- ["input"]) ==
             Map.delete(payload, "input")

    assert result.request_options.routing.prompt_cache_key ==
             prompt_cache_key_hash("fixture-cache-key")

    refute result.request_options.routing.prompt_cache_key == "fixture-cache-key"
    refute Map.has_key?(result.request_options.extra, "prompt_cache_key")
  end

  @tag :responses_coercion
  test "OpenAI source endpoints keep prompt cache forwarding and typed routing input aligned" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "prompt_cache_key" => "fixture-response-cache-key",
      "prompt_cache_retention" => "24h"
    }

    assert {:ok, response_result} =
             Responses.coerce(response_payload,
               collect_openai_response_stream: true,
               openai_source_endpoint: "/v1/responses"
             )

    assert response_result.payload["prompt_cache_key"] == "fixture-response-cache-key"
    assert response_result.payload["prompt_cache_retention"] == "24h"

    assert response_result.request_options.routing.prompt_cache_key ==
             prompt_cache_key_hash("fixture-response-cache-key")

    refute response_result.request_options.routing.prompt_cache_key ==
             "fixture-response-cache-key"

    refute Map.has_key?(response_result.request_options.extra, "prompt_cache_key")

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "prompt_cache_key" => "fixture-chat-cache-key",
      "prompt_cache_retention" => "24h"
    }

    assert {:ok, chat_result} =
             Chat.coerce(chat_payload,
               collect_openai_response_stream: true,
               openai_source_endpoint: "/v1/chat/completions"
             )

    assert chat_result.payload["prompt_cache_key"] == "fixture-chat-cache-key"
    assert chat_result.payload["prompt_cache_retention"] == "24h"

    assert chat_result.request_options.routing.prompt_cache_key ==
             prompt_cache_key_hash("fixture-chat-cache-key")

    refute chat_result.request_options.routing.prompt_cache_key == "fixture-chat-cache-key"
    refute Map.has_key?(chat_result.request_options.extra, "prompt_cache_key")
  end

  @tag :unsupported_fields
  test "untranslatable tool and legacy Chat function shapes are rejected" do
    assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [%{"type" => "function", "function" => %{}}]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "functions"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "synthetic"}],
               "functions" => [%{"name" => "legacy_fixture"}]
             })
  end

  @tag :unsupported_fields
  test "malformed nested compatibility payloads are rejected before coercion" do
    assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [%{"type" => "synthetic_unknown", "payload" => %{}}]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "messages"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "text", "payload" => "missing text"}]
                 }
               ]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 %{"type" => "function", "function" => %{"name" => "missing_parameters"}}
               ]
             })
  end

  @tag :unsupported_fields
  test "invalid image parameters return deterministic reason maps" do
    assert {:error, reason} =
             Images.coerce_generation(%{
               "model" => "gpt-image-1",
               "prompt" => "synthetic image request",
               "size" => "2048x2048"
             })

    assert reason == %{
             status: 400,
             code: "invalid_request",
             message: "size is not supported",
             param: "size"
           }

    assert {:error, %{code: "invalid_model", param: "model"}} =
             Images.coerce_generation(%{
               "model" => "unknown-image-model",
               "prompt" => "synthetic image request"
             })
  end

  describe "Task 4 Responses continuation and input-reference validation" do
    @describetag :tool_result_previous_response
    @tag :custom_tool_replay
    test "custom tool replay preserves namespace and internal metadata" do
      payload = %{
        "model" => "gpt-fixture-text",
        "previous_response_id" => "resp_fixture_custom_tool_previous",
        "store" => false,
        "input" => [
          %{
            "type" => "custom_tool_call",
            "id" => "ctc_fixture_call",
            "call_id" => "call_fixture_custom",
            "namespace" => "browser.search",
            "name" => "lookup",
            "input" => "{}",
            "status" => "completed",
            "metadata" => %{"turn_id" => "turn_custom_legacy"},
            "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn_custom"}
          },
          %{
            "type" => "custom_tool_call_output",
            "id" => "ctco_fixture_call",
            "call_id" => "call_fixture_custom",
            "name" => "lookup",
            "output" => "synthetic custom output",
            "metadata" => %{"turn_id" => "turn_custom_output_legacy"},
            "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn_custom_output"}
          }
        ]
      }

      assert {:ok, result} = Responses.coerce(payload, request_id: "req_fixture_custom_tool")

      assert [custom_call, custom_output] = result.payload["input"]

      assert Enum.map(result.payload["input"], & &1["type"]) == [
               "custom_tool_call",
               "custom_tool_call_output"
             ]

      assert custom_call["namespace"] == "browser.search"
      assert custom_call["name"] == "lookup"
      assert custom_call["input"] == "{}"
      assert custom_call["metadata"] == %{"turn_id" => "turn_custom_legacy"}

      assert custom_call["internal_chat_message_metadata_passthrough"] == %{
               "turn_id" => "turn_custom"
             }

      refute Map.has_key?(custom_call, "status")

      assert custom_output["name"] == "lookup"
      assert custom_output["output"] == "synthetic custom output"
      assert custom_output["metadata"] == %{"turn_id" => "turn_custom_output_legacy"}

      assert custom_output["internal_chat_message_metadata_passthrough"] == %{
               "turn_id" => "turn_custom_output"
             }
    end

    @tag :custom_tool_replay
    test "custom tool replay rejects malformed custom item shapes" do
      invalid_payloads = [
        [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_fixture_custom",
            "namespace" => " ",
            "name" => "lookup",
            "input" => "{}"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom",
            "output" => "ok"
          }
        ],
        [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_fixture_custom",
            "namespace" => 123,
            "name" => "lookup",
            "input" => "{}"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom",
            "output" => "ok"
          }
        ],
        [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_fixture_custom",
            "name" => "lookup"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom",
            "output" => "ok"
          }
        ],
        [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_fixture_custom",
            "namespace" => "browser.search",
            "name" => "lookup",
            "input" => "{}",
            "status" => "in_progress"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom",
            "output" => "ok"
          }
        ],
        [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom",
            "namespace" => "browser.search",
            "output" => "ok"
          }
        ],
        [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom",
            "result" => "ok"
          }
        ]
      ]

      Enum.each(invalid_payloads, fn input ->
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "previous_response_id" => "resp_fixture_custom_tool_previous",
                   "input" => input
                 })
      end)
    end

    test "opencode replay continuations accept only the supported replay item shapes" do
      payload = %{
        "model" => "gpt-fixture-text",
        "previous_response_id" => "resp_fixture_opencode_replay",
        "store" => false,
        "input" => [
          %{
            "role" => "assistant",
            "id" => "msg_fixture_assistant",
            "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
          },
          %{
            "type" => "reasoning",
            "id" => "rs_fixture_reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
            "encrypted_content" => nil
          },
          %{
            "type" => "function_call",
            "id" => "fc_fixture_call",
            "call_id" => "call_fixture",
            "name" => "lookup_fixture",
            "namespace" => "browser.search",
            "arguments" => "{\"value\":\"sample\"}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_fixture",
            "output" => [
              %{"type" => "input_text", "text" => "synthetic tool text"},
              %{"type" => "input_image", "image_url" => "https://example.com/sample.png"}
            ]
          }
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert Enum.map(coerced["input"], & &1["type"]) == [
               "message",
               "reasoning",
               "function_call",
               "function_call_output"
             ]

      assert %{"role" => "assistant", "content" => [%{"type" => "output_text"}]} =
               Enum.at(coerced["input"], 0)

      assert %{"type" => "function_call_output", "output" => output} =
               Enum.at(coerced["input"], 3)

      assert Enum.map(output, & &1["type"]) == ["input_text", "input_image"]
      assert Enum.at(coerced["input"], 2)["namespace"] == "browser.search"
    end

    test "opencode ordinary replay drops idless encrypted reasoning and preserves assistant phase" do
      payload = %{
        "model" => "gpt-fixture-text",
        "include" => ["reasoning.encrypted_content"],
        "prompt_cache_key" => "fixture-cache-key",
        "reasoning" => %{"effort" => "xhigh", "summary" => "detailed"},
        "store" => false,
        "stream" => true,
        "text" => %{"verbosity" => "medium"},
        "tool_choice" => "auto",
        "tools" => [
          flat_function_tool("lookup_fixture", %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => false
          })
        ],
        "input" => [
          %{"role" => "developer", "content" => "synthetic developer instruction"},
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic user request"},
              %{"type" => "input_text", "text" => "synthetic extra context"}
            ]
          },
          %{
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
            "encrypted_content" => "synthetic-encrypted-reasoning"
          },
          %{
            "role" => "assistant",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
          },
          %{
            "type" => "function_call",
            "call_id" => "call_fixture",
            "name" => "lookup_fixture",
            "arguments" => "{\"value\":\"sample\"}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_fixture",
            "output" => "synthetic tool output"
          }
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)
      refute Map.has_key?(coerced, "previous_response_id")
      assert coerced["instructions"] == "synthetic developer instruction"

      assert Enum.map(coerced["input"], & &1["type"]) == [
               "message",
               "message",
               "function_call",
               "function_call_output"
             ]

      assert %{"role" => "assistant", "phase" => "commentary"} =
               Enum.at(coerced["input"], 1)

      refute inspect(coerced["input"]) =~ "synthetic-encrypted-reasoning"
    end

    test "OMP stateless replay drops known function call status metadata" do
      payload = %{
        "model" => "gpt-fixture-text",
        "store" => false,
        "stream" => true,
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "call_fixture_completed",
            "name" => "lookup_fixture",
            "arguments" => "{\"value\":\"completed\"}",
            "status" => "completed"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_fixture_completed",
            "output" => "synthetic completed tool output"
          },
          %{
            "type" => "function_call",
            "call_id" => "call_fixture_incomplete",
            "name" => "lookup_fixture",
            "arguments" => "{\"value\":\"incomplete\"}",
            "status" => "incomplete"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_fixture_incomplete",
            "output" => "synthetic incomplete tool output"
          },
          %{"role" => "user", "content" => "synthetic follow-up"}
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [
               %{"type" => "function_call"} = completed_call,
               %{"type" => "function_call_output"},
               %{"type" => "function_call"} = incomplete_call,
               %{"type" => "function_call_output"},
               %{"type" => "message", "role" => "user"}
             ] = coerced["input"]

      refute Map.has_key?(completed_call, "status")
      refute Map.has_key?(incomplete_call, "status")
    end

    test "Hermes ordinary replay drops reasoning and preserves completed assistant metadata" do
      payload = %{
        "model" => "gpt-fixture-text",
        "store" => false,
        "input" => [
          %{
            "type" => "reasoning",
            "summary" => [],
            "encrypted_content" => "synthetic-encrypted-reasoning"
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "id" => "msg_fixture_hermes_completed_assistant",
            "phase" => "final_answer",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
          },
          %{"role" => "user", "content" => "synthetic follow-up"}
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "id" => "msg_fixture_hermes_completed_assistant",
                 "phase" => "final_answer",
                 "status" => "completed",
                 "content" => [%{"type" => "output_text"}]
               },
               %{"type" => "message", "role" => "user"}
             ] = coerced["input"]

      refute inspect(coerced["input"]) =~ "synthetic-encrypted-reasoning"
    end

    test "OpenClaw ordinary replay normalizes assistant thinking content" do
      payload = %{
        "model" => "gpt-fixture-text",
        "store" => false,
        "input" => [
          %{"role" => "user", "content" => "synthetic first turn"},
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "thinking",
                "thinking" => "",
                "thinkingSignature" => "synthetic-thinking-signature"
              },
              %{"type" => "text", "text" => "synthetic assistant replay"}
            ]
          },
          %{"role" => "user", "content" => "synthetic follow-up"}
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
               },
               %{"type" => "message", "role" => "user"}
             ] = coerced["input"]

      refute inspect(coerced["input"]) =~ "thinkingSignature"
    end

    test "OpenClaw ordinary replay drops converted reasoning and keeps message items" do
      payload = %{
        "model" => "gpt-fixture-text",
        "store" => false,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic first turn"}]
          },
          %{
            "type" => "reasoning",
            "content" => [],
            "encrypted_content" => "synthetic-encrypted-reasoning",
            "id" => "rs_synthetic_openclaw",
            "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}]
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{
                "type" => "output_text",
                "text" => "synthetic assistant replay",
                "annotations" => []
              }
            ],
            "status" => "completed",
            "id" => "msg_synthetic_openclaw",
            "phase" => "final_answer"
          },
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
          }
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}],
                 "status" => "completed",
                 "id" => "msg_synthetic_openclaw",
                 "phase" => "final_answer"
               },
               %{"type" => "message", "role" => "user"}
             ] = coerced["input"]

      refute inspect(coerced["input"]) =~ "annotations"
      refute inspect(coerced["input"]) =~ "content\" => []"
      refute inspect(coerced["input"]) =~ "synthetic-encrypted-reasoning"
      refute inspect(coerced["input"]) =~ "rs_synthetic_openclaw"
    end

    test "opencode native replay repairs paired blank tool call ids only" do
      payload = %{
        "model" => "gpt-fixture-text",
        "previous_response_id" => "resp_fixture_opencode_native_replay",
        "store" => false,
        "input" => [
          %{
            "type" => "function_call",
            "id" => "fc_fixture_native_call",
            "call_id" => "",
            "name" => "lookup_fixture",
            "arguments" => "{\"value\":\"sample\"}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "",
            "output" => "synthetic tool output"
          }
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [
               %{
                 "type" => "function_call",
                 "id" => "fc_fixture_native_call",
                 "call_id" => "fc_fixture_native_call"
               },
               %{"type" => "function_call_output", "call_id" => "fc_fixture_native_call"}
             ] = coerced["input"]
    end

    test "opencode replay continuations reject malformed or unsupported variants locally" do
      invalid_items = [
        %{"role" => "assistant", "content" => [%{"type" => "input_text", "text" => "bad"}]},
        %{
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "bad"}],
          "status" => "failed"
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "bad"}],
          "phase" => "progress"
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "bad"}],
          "phase" => "commentary",
          "status" => "failed"
        },
        %{
          "role" => "user",
          "content" => "bad",
          "phase" => "commentary"
        },
        %{"type" => "reasoning", "id" => "", "summary" => []},
        %{
          "type" => "reasoning",
          "summary" => [%{"type" => "summary_text", "text" => "bad"}],
          "encrypted_content" => ""
        },
        %{
          "type" => "reasoning",
          "summary" => [%{"type" => "summary_text", "text" => "bad"}],
          "encrypted_content" => "synthetic-encrypted-reasoning",
          "status" => "completed"
        },
        %{
          "type" => "reasoning",
          "id" => "rs_fixture",
          "summary" => [%{"type" => "text", "text" => "bad"}]
        },
        %{
          "type" => "reasoning",
          "id" => "rs_fixture",
          "summary" => [],
          "encrypted_content" => %{}
        },
        %{
          "type" => "reasoning",
          "id" => "rs_fixture",
          "summary" => [],
          "status" => "completed"
        },
        %{
          "type" => "function_call",
          "call_id" => "",
          "name" => "lookup_fixture",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call",
          "call_id" => "call_fixture",
          "name" => "lookup_fixture",
          "arguments" => %{}
        },
        %{
          "type" => "function_call",
          "call_id" => "call_fixture",
          "name" => "lookup_fixture",
          "arguments" => "{}",
          "status" => "in_progress"
        },
        %{
          "type" => "function_call",
          "call_id" => "call_fixture",
          "name" => "lookup_fixture",
          "arguments" => "{}",
          "namespace" => " "
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_fixture",
          "output" => %{"bad" => self()}
        },
        %{"type" => "local_shell_call", "call_id" => "call_fixture"},
        %{"type" => "mcp_approval_response", "call_id" => "call_fixture", "output" => "bad"},
        %{"type" => "web_search_call", "id" => "ws_fixture"},
        %{"type" => "unknown_fixture", "id" => "item_fixture"}
      ]

      Enum.each(invalid_items, fn item ->
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "previous_response_id" => "resp_fixture_previous",
                   "input" => [
                     item,
                     %{
                       "type" => "function_call_output",
                       "call_id" => "call_fixture",
                       "output" => "ok"
                     }
                   ]
                 })
      end)
    end

    test "structured function_call_output preserves string and JSON output behavior" do
      assert {:ok, %{payload: string_payload}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_fixture",
                     "output" => "synthetic string output"
                   }
                 ]
               })

      assert [%{"output" => "synthetic string output"}] = string_payload["input"]

      structured_output = [
        %{"type" => "input_image", "image_url" => "sediment://file_fixture"}
      ]

      assert {:ok, %{payload: structured_payload}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_fixture",
                     "output" => structured_output
                   }
                 ]
               })

      assert [%{"output" => ^structured_output}] = structured_payload["input"]
    end

    test "structured function_call_output preserves explicit null output" do
      assert {:ok, %{payload: payload}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "previous_response_id" => "resp_fixture_null_previous",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_fixture_null",
                     "output" => nil
                   }
                 ]
               })

      assert [%{"type" => "function_call_output", "call_id" => "call_fixture_null"} = item] =
               payload["input"]

      assert Map.has_key?(item, "output")
      assert is_nil(item["output"])
    end

    @tag :structured_tool_result_pass_through
    test "structured function_call_output forwards nested JSON output unchanged" do
      structured_output = structured_tool_result_output()

      assert {:ok, %{payload: payload}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "previous_response_id" => "resp_fixture_structured_previous",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_fixture_structured",
                     "output" => structured_output
                   }
                 ]
               })

      assert payload["previous_response_id"] == "resp_fixture_structured_previous"

      assert [%{"type" => "function_call_output", "call_id" => "call_fixture_structured"} = item] =
               payload["input"]

      assert_payload_equal_no_echo!(
        item["output"],
        structured_output,
        "structured Responses function_call_output was not forwarded unchanged"
      )
    end

    test "tool-result input normalization returns explicit results without raising" do
      assert {:ok, %{payload: payload}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{"call_id" => "call_fixture", "result" => %{"status" => "ok"}}
                 ]
               })

      assert [%{"call_id" => "call_fixture", "result" => %{"status" => "ok"}}] =
               payload["input"]
    end

    test "item_reference continuations require previous response tool-result context" do
      payload = %{
        "model" => "gpt-fixture-text",
        "previous_response_id" => "resp_fixture_previous",
        "input" => [
          %{"type" => "item_reference", "id" => "msg_existing_fixture"},
          %{
            "type" => "function_call_output",
            "call_id" => "call_fixture",
            "output" => "{\"ok\":true}"
          }
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)
      assert coerced["previous_response_id"] == "resp_fixture_previous"

      assert [
               %{"type" => "item_reference", "id" => "msg_existing_fixture"},
               %{"type" => "function_call_output", "call_id" => "call_fixture"}
             ] = coerced["input"]

      malformed_references = [
        %{"type" => "item_reference"},
        %{"type" => "item_reference", "id" => ""},
        %{"type" => "item_reference", "id" => "msg_existing_fixture", "output" => "bad"}
      ]

      Enum.each(malformed_references, fn item ->
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})
      end)

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{"type" => "item_reference", "id" => "msg_existing_fixture"},
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_fixture",
                     "output" => "ok"
                   }
                 ]
               })

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [%{"type" => "item_reference", "id" => "msg_existing_fixture"}]
               })

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "previous_response_id" => "resp_fixture_previous",
                 "input" => [
                   %{"type" => "item_reference", "id" => "msg_existing_fixture"},
                   %{"role" => "user", "content" => "synthetic ordinary continuation"}
                 ]
               })
    end

    test "previous_response_id without semantic tool output is rejected" do
      invalid_payloads = [
        %{
          "previous_response_id" => "resp_fixture_ordinary",
          "input" => "synthetic ordinary continuation"
        },
        %{
          "previous_response_id" => "resp_fixture_message_only",
          "input" => [%{"role" => "user", "content" => "synthetic ordinary continuation"}]
        },
        %{
          "previous_response_id" => "",
          "input" => [
            %{"type" => "function_call_output", "call_id" => "call_fixture", "output" => "ok"}
          ]
        },
        %{
          "previous_response_id" => 123,
          "input" => [
            %{"type" => "function_call_output", "call_id" => "call_fixture", "output" => "ok"}
          ]
        }
      ]

      Enum.each(invalid_payloads, fn payload ->
        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  param: "previous_response_id"
                }} =
                 payload
                 |> Map.put("model", "gpt-fixture-text")
                 |> Responses.coerce()
      end)
    end
  end

  @tag :unsupported_fields
  test "invalid file purpose and multipart metadata return deterministic reason maps" do
    assert {:error, reason} =
             Files.validate_create(%{"purpose" => "fine_tuning", "file" => upload_metadata()})

    assert reason == %{
             status: 400,
             code: "invalid_request",
             message: "file purpose is not supported",
             param: "purpose"
           }

    assert {:error, %{status: 400, code: "invalid_request", param: "file"}} =
             Files.validate_create(%{
               "purpose" => "user_data",
               "file" => %{"filename" => "fixture.txt"}
             })
  end

  @tag :unsupported_fields
  test "invalid audio model and missing file metadata are rejected" do
    assert {:error, %{code: "invalid_model", param: "model"}} =
             Audio.validate_transcription(%{"model" => "whisper-1", "file" => upload_metadata()})

    assert {:error, %{code: "invalid_model", param: "model"}} =
             Audio.coerce_transcription(%{"model" => "whisper-1", "file" => upload_metadata()})

    assert {:error, %{code: "invalid_request", param: "file"}} =
             Audio.validate_transcription(%{"model" => "gpt-4o-transcribe"})

    assert {:error, %{code: "invalid_request", param: "file"}} =
             Audio.coerce_transcription(%{"model" => "gpt-4o-transcribe"})
  end

  @tag :unsupported_fields
  test "existing strict schema and input image guards are reused" do
    assert {:error, %{code: "invalid_json_schema", param: "text.format.schema.required"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "text" => %{
                 "format" => %{
                   "type" => "json_schema",
                   "strict" => true,
                   "schema" => %{
                     "type" => "object",
                     "additionalProperties" => false,
                     "properties" => %{"ok" => %{"type" => "boolean"}},
                     "required" => []
                   }
                 }
               }
             })

    assert {:error, %{code: "unsupported_input_image_format", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "input_image", "image_url" => "sediment://file_fixture"}
                   ]
                 }
               ]
             })
  end

  @tag :responses_coercion
  test "strict function parameters accept explicit schemas in Responses and Chat" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        flat_function_tool("lookup_fixture", %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"ok" => %{"type" => "boolean"}},
          "required" => ["ok"]
        })
      ]
    }

    assert {:ok, response_result} = Responses.coerce(response_payload)
    assert response_result.payload["tools"] == response_payload["tools"]

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [
        function_tool("lookup_nullable_fixture", %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"ok" => %{"type" => ["string", "null"]}},
          "required" => ["ok"]
        })
      ]
    }

    assert {:ok, chat_result} = Chat.coerce(chat_payload)
    assert chat_result.payload["tools"] == translated_chat_tools(chat_payload["tools"])
  end

  @tag :responses_coercion
  test "Responses accepts flat function tools emitted by released OpenAI SDK" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup_fixture",
          "description" => "Lookup synthetic fixture",
          "parameters" => %{
            "$schema" => "http://json-schema.org/draft-07/schema#",
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"value" => %{"type" => "string"}},
            "required" => ["value"]
          }
        }
      ]
    }

    assert {:ok, result} = Responses.coerce(payload)

    assert get_in(result.payload, ["tools", Access.at(0), "parameters"]) ==
             payload
             |> get_in(["tools", Access.at(0), "parameters"])
             |> Map.delete("$schema")
  end

  @tag :responses_coercion
  test "Responses lowers non-strict function tool schemas before validation" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        flat_function_tool("lookup_fixture", non_strict_tool_schema(), false)
      ]
    }

    assert {:ok, result} = Responses.coerce(payload)
    assert get_in(result.payload, ["tools", Access.at(0), "parameters"]) == lowered_tool_schema()
  end

  @tag :responses_coercion
  test "Responses keeps strict function tool schemas on the strict validation path" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        flat_function_tool("lookup_fixture", non_strict_tool_schema(), true)
      ]
    }

    assert {:error, %{code: "invalid_function_parameters", param: "tools.0.parameters.type"}} =
             Responses.coerce(payload)
  end

  describe "Task 5 Responses and Chat tool shape compatibility" do
    test "documents the tool shape divergence between Responses and Chat" do
      divergence = [
        %{
          endpoint: :responses,
          accepted_shape: "flat function tool",
          translated_upstream_shape: "flat function tool"
        },
        %{
          endpoint: :chat,
          accepted_shape: "nested function tool",
          translated_upstream_shape: "flat function tool"
        }
      ]

      assert divergence == [
               %{
                 endpoint: :responses,
                 accepted_shape: "flat function tool",
                 translated_upstream_shape: "flat function tool"
               },
               %{
                 endpoint: :chat,
                 accepted_shape: "nested function tool",
                 translated_upstream_shape: "flat function tool"
               }
             ]
    end

    test "Responses accepts flat function tools with nonblank names and map parameters" do
      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup_fixture",
            "description" => "Lookup synthetic fixture",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ]
      }

      assert {:ok, result} = Responses.coerce(payload)
      assert result.payload["tools"] == payload["tools"]
    end

    test "Responses accepts namespace tools with nested function tools" do
      namespace_tool = %{
        "type" => "namespace",
        "name" => "fixture_namespace",
        "description" => "Synthetic namespace tools",
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup_namespaced_fixture",
            "description" => "Lookup synthetic namespaced fixture",
            "parameters" => %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{"value" => %{"type" => "string"}},
              "required" => ["value"]
            },
            "strict" => true,
            "defer_loading" => true
          }
        ]
      }

      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [namespace_tool],
        "tool_choice" => %{"type" => "function", "name" => "lookup_namespaced_fixture"}
      }

      assert {:ok, result} = Responses.coerce(payload)
      assert result.payload["tools"] == [namespace_tool]
      assert result.payload["tool_choice"] == payload["tool_choice"]
    end

    test "Chat accepts nested function tools and translates them to flat Responses tools" do
      payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic input"}],
        "tools" => [
          function_tool("lookup_fixture", %{"type" => "object", "properties" => %{}}, nil)
        ]
      }

      assert {:ok, result} = Chat.coerce(payload)
      assert result.payload["tools"] == translated_chat_tools(payload["tools"])
    end

    test "Responses rejects malformed and Chat-only tool shapes" do
      invalid_payloads = [
        {%{"type" => "function", "parameters" => %{}}, "tools"},
        {%{"type" => "function", "name" => "", "parameters" => %{}}, "tools"},
        {%{"type" => "function", "name" => "   ", "parameters" => %{}}, "tools"},
        {%{"type" => "function", "name" => "lookup_fixture", "parameters" => []}, "tools"},
        {%{"type" => "unsupported_tool", "name" => "lookup_fixture", "parameters" => %{}},
         "tools"},
        {function_tool("chat_only_nested", %{"type" => "object", "properties" => %{}}), "tools"}
      ]

      Enum.each(invalid_payloads, fn {tool, expected_param} ->
        assert {:error, %{status: 400, code: "invalid_request", param: ^expected_param}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })
      end)
    end

    test "Responses rejects malformed namespace tools" do
      invalid_tools = [
        %{"type" => "namespace", "name" => "", "description" => "Synthetic", "tools" => []},
        %{"type" => "namespace", "name" => "fixture", "description" => "", "tools" => []},
        %{"type" => "namespace", "name" => "fixture", "description" => "Synthetic"},
        %{
          "type" => "namespace",
          "name" => "fixture",
          "description" => "Synthetic",
          "tools" => []
        },
        %{
          "type" => "namespace",
          "name" => "fixture",
          "description" => "Synthetic",
          "tools" => [%{"type" => "web_search_preview"}]
        },
        %{
          "type" => "namespace",
          "name" => "fixture",
          "description" => "Synthetic",
          "tools" => [%{"type" => "function", "name" => "", "parameters" => %{}}]
        },
        %{
          "type" => "namespace",
          "name" => "fixture",
          "description" => "Synthetic",
          "tools" => [%{"type" => "function", "name" => "lookup_fixture", "parameters" => []}]
        },
        %{
          "type" => "namespace",
          "name" => "fixture",
          "description" => "Synthetic",
          "tools" => [
            %{
              "type" => "function",
              "name" => "lookup_fixture",
              "parameters" => %{},
              "defer_loading" => "yes"
            }
          ]
        }
      ]

      Enum.each(invalid_tools, fn tool ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })
      end)
    end

    test "Chat rejects malformed nested function tools" do
      invalid_tools = [
        %{"type" => "function", "function" => %{"parameters" => %{}}},
        %{"type" => "function", "function" => %{"name" => "", "parameters" => %{}}},
        %{"type" => "function", "function" => %{"name" => "lookup_fixture", "parameters" => []}},
        %{"type" => "unknown", "function" => %{"name" => "lookup_fixture", "parameters" => %{}}}
      ]

      Enum.each(invalid_tools, fn tool ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Chat.coerce(%{
                   "model" => "gpt-fixture-text",
                   "messages" => [%{"role" => "user", "content" => "synthetic input"}],
                   "tools" => [tool]
                 })
      end)
    end

    test "tool_choice variants are explicit for strings, named functions, and image generation" do
      base_payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [
          flat_function_tool("lookup_fixture", %{"type" => "object", "properties" => %{}}, nil)
        ]
      }

      for choice <- ["auto", "none", "required"] do
        payload = Map.put(base_payload, "tool_choice", choice)
        assert {:ok, result} = Responses.coerce(payload)
        assert result.payload["tool_choice"] == choice
      end

      named_choice = %{"type" => "function", "name" => "lookup_fixture"}
      assert {:ok, result} = Responses.coerce(Map.put(base_payload, "tool_choice", named_choice))
      assert result.payload["tool_choice"] == named_choice

      image_payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [%{"type" => "image_generation"}],
        "tool_choice" => %{"type" => "image_generation"}
      }

      assert {:ok, result} = Responses.coerce(image_payload)
      assert result.payload["tool_choice"] == %{"type" => "image_generation"}
    end

    test "tool_choice rejects missing, blank, malformed, and unknown named function choices" do
      base_payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [
          flat_function_tool("lookup_fixture", %{"type" => "object", "properties" => %{}})
        ]
      }

      invalid_choices = [
        %{"type" => "function"},
        %{"type" => "function", "name" => ""},
        %{"type" => "function", "name" => "missing_fixture"},
        %{"type" => "function", "function" => %{"name" => "lookup_fixture"}},
        %{"type" => "unsupported_tool"}
      ]

      Enum.each(invalid_choices, fn choice ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tool_choice"}} =
                 base_payload
                 |> Map.put("tool_choice", choice)
                 |> Responses.coerce()
      end)
    end

    test "parallel_tool_calls true and false are preserved for Responses and Chat" do
      for value <- [true, false] do
        response_payload = %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "parallel_tool_calls" => value
        }

        assert {:ok, response_result} = Responses.coerce(response_payload)
        assert response_result.payload["parallel_tool_calls"] == value

        chat_payload = %{
          "model" => "gpt-fixture-text",
          "messages" => [%{"role" => "user", "content" => "synthetic input"}],
          "parallel_tool_calls" => value
        }

        assert {:ok, chat_result} = Chat.coerce(chat_payload)
        assert chat_result.payload["parallel_tool_calls"] == value
      end
    end
  end

  describe "Task 9 advanced Responses built-in tool classification" do
    test "Responses allows only exact safe passthrough built-in tool shapes" do
      for tool <- [
            %{"type" => "web_search_preview"},
            %{
              "type" => "web_search",
              "external_web_access" => false
            },
            %{
              "type" => "web_search",
              "external_web_access" => true,
              "index_gated_web_access" => true
            },
            %{
              "type" => "web_search",
              "external_web_access" => true
            },
            %{"type" => "image_generation"},
            %{
              "type" => "image_generation",
              "model" => "gpt-image-1",
              "size" => "1024x1024",
              "quality" => "high",
              "background" => "transparent",
              "input_fidelity" => "high",
              "output_format" => "png"
            }
          ] do
        payload = %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "tools" => [tool]
        }

        assert {:ok, result} = Responses.coerce(payload)
        assert result.payload["tools"] == [tool]
      end
    end

    test "Responses rejects unsupported hosted built-in and deferred tools" do
      rejected_tools = [
        %{"type" => "web_search_preview", "search_context_size" => "low"},
        %{"type" => "web_search", "external_web_access" => "true"},
        %{
          "type" => "web_search",
          "external_web_access" => true,
          "index_gated_web_access" => "true"
        },
        %{
          "type" => "web_search",
          "external_web_access" => true,
          "index_gated_web_access" => false
        },
        %{
          "type" => "web_search",
          "external_web_access" => false,
          "index_gated_web_access" => true
        },
        %{"type" => "web_search", "index_gated_web_access" => true},
        %{"type" => "web_search", "external_web_access" => true, "filters" => %{}},
        %{"type" => "image_generation", "quality" => "high"},
        %{"type" => "file_search", "vector_store_ids" => ["vs_fixture"]},
        %{"type" => "code_interpreter", "container" => %{"type" => "auto"}},
        %{"type" => "computer_use", "environment" => "browser"},
        %{"type" => "shell", "description" => "synthetic shell"},
        %{"type" => "local_shell", "description" => "synthetic local shell"},
        %{"type" => "apply_patch", "description" => "synthetic patch"},
        %{"type" => "tool_search", "namespace" => "fixture_namespace"},
        %{
          "type" => "function",
          "name" => "lookup_fixture",
          "parameters" => %{},
          "namespace" => "fixture_namespace"
        },
        %{
          "type" => "function",
          "name" => "lookup_fixture",
          "parameters" => %{},
          "deferred" => true
        }
      ]

      Enum.each(rejected_tools, fn tool ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })
      end)
    end

    test "Responses rejects remote MCP tools with explicit errors" do
      remote_mcp_tools = [
        %{
          "type" => "mcp",
          "server_label" => "fixture-mcp",
          "server_url" => "https://mcp.example.com"
        },
        %{
          "type" => "mcp",
          "server_label" => "fixture-mcp",
          "connector_id" => "connector_googledrive"
        },
        %{
          "type" => "mcp",
          "server_label" => "fixture-mcp",
          "tunnel_id" => "mcp_tunnel_fixture"
        }
      ]

      Enum.each(remote_mcp_tools, fn tool ->
        assert {:error, reason} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })

        assert reason == %{
                 status: 400,
                 code: "invalid_request",
                 message: "remote MCP tools are not supported",
                 param: "tools"
               }
      end)
    end
  end

  @tag :responses_coercion
  test "store false replay continuations preserve raw Responses item ids" do
    payload = %{
      "model" => "gpt-fixture-text",
      "previous_response_id" => "resp_fixture_previous",
      "store" => false,
      "input" => [
        %{
          "type" => "reasoning",
          "id" => "rs_fixture_replay",
          "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
          "encrypted_content" => "synthetic-encrypted-reasoning"
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "id" => "msg_fixture_replay",
          "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
        },
        %{
          "type" => "function_call",
          "id" => "fc_fixture_replay",
          "call_id" => "call_fixture_replay",
          "name" => "lookup_fixture",
          "namespace" => "fixture_namespace",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "id" => "fco_fixture_replay",
          "call_id" => "call_fixture_replay",
          "output" => "synthetic tool output"
        },
        %{"type" => "item_reference", "id" => "msg_fixture_reference"}
      ]
    }

    assert {:ok, result} = Responses.coerce(payload, collect_openai_response_stream: true)
    assert result.payload["store"] == false
    assert result.payload["previous_response_id"] == "resp_fixture_previous"

    assert Enum.map(result.payload["input"], &Map.get(&1, "id")) == [
             "rs_fixture_replay",
             "msg_fixture_replay",
             "fc_fixture_replay",
             "fco_fixture_replay",
             "msg_fixture_reference"
           ]

    assert Enum.at(result.payload["input"], 2)["call_id"] == "call_fixture_replay"
    assert Enum.at(result.payload["input"], 3)["call_id"] == "call_fixture_replay"
  end

  test "Responses preserves item metadata and Codex internal turn metadata on replay items" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    payload = %{
      "model" => "gpt-fixture-text",
      "previous_response_id" => "resp_fixture_metadata",
      "store" => false,
      "input" => [
        %{
          "type" => "reasoning",
          "id" => "rs_fixture_metadata",
          "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
          "encrypted_content" => nil,
          "metadata" => %{"turn_id" => "turn_reasoning_legacy"},
          passthrough_key => %{"turn_id" => "turn_reasoning"}
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}],
          "metadata" => %{"turn_id" => "turn_message_legacy"},
          passthrough_key => %{"turn_id" => "turn_message"}
        },
        %{
          "type" => "function_call",
          "id" => "fc_fixture_metadata",
          "call_id" => "call_fixture_native_metadata",
          "name" => "lookup_fixture",
          "arguments" => "{}",
          "metadata" => %{"turn_id" => "turn_call_legacy"},
          passthrough_key => %{"turn_id" => "turn_call"}
        },
        %{
          "type" => "function_call_output",
          "id" => "fco_fixture_metadata",
          "call_id" => "call_fixture_native_metadata",
          "output" => "synthetic tool output",
          "metadata" => %{"turn_id" => "turn_output_legacy"},
          passthrough_key => %{"turn_id" => "turn_output"}
        },
        %{
          "role" => "assistant",
          "metadata" => %{"turn_id" => "turn_rebuilt_call_legacy"},
          passthrough_key => %{"turn_id" => "turn_rebuilt_call"},
          "tool_calls" => [
            %{
              "id" => "call_fixture_rebuilt_metadata",
              "type" => "function",
              "function" => %{
                "name" => "terminal",
                "arguments" => "{\"cmd\":\"date\"}"
              }
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call_fixture_rebuilt_metadata",
          "content" => "synthetic translated tool output",
          "metadata" => %{"turn_id" => "turn_rebuilt_output_legacy"},
          passthrough_key => %{"turn_id" => "turn_rebuilt_output"}
        }
      ]
    }

    assert {:ok, result} = Responses.coerce(payload, collect_openai_response_stream: true)

    assert Enum.map(result.payload["input"], &get_in(&1, ["metadata", "turn_id"])) == [
             "turn_reasoning_legacy",
             "turn_message_legacy",
             "turn_call_legacy",
             "turn_output_legacy",
             "turn_rebuilt_call_legacy",
             "turn_rebuilt_output_legacy"
           ]

    assert Enum.map(result.payload["input"], &get_in(&1, [passthrough_key, "turn_id"])) == [
             "turn_reasoning",
             "turn_message",
             "turn_call",
             "turn_output",
             "turn_rebuilt_call",
             "turn_rebuilt_output"
           ]
  end

  test "Responses rejects malformed Codex internal turn metadata on translated replay items" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    invalid_inputs = [
      %{
        "role" => "assistant",
        passthrough_key => "turn_fixture_invalid",
        "tool_calls" => [
          %{
            "id" => "call_fixture_invalid_parent",
            "type" => "function",
            "function" => %{"name" => "terminal", "arguments" => "{}"}
          }
        ]
      },
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "call_fixture_invalid_child",
            passthrough_key => "turn_fixture_invalid",
            "type" => "function",
            "function" => %{"name" => "terminal", "arguments" => "{}"}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "call_fixture_invalid_output",
        "content" => "synthetic translated tool output",
        passthrough_key => "turn_fixture_invalid"
      }
    ]

    Enum.each(invalid_inputs, fn input ->
      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "previous_response_id" => "resp_fixture_metadata",
                 "input" => [input]
               })
    end)
  end

  @tag :responses_coercion
  test "strict function parameters reject missing additionalProperties at the top level" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 flat_function_tool("lookup_missing_additional_properties", %{
                   "type" => "object",
                   "properties" => %{"ok" => %{"type" => "boolean"}},
                   "required" => ["ok"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_missing_additional_properties': strict json_schema object schemas must set additionalProperties to false",
             param: "tools.0.parameters"
           }
  end

  @tag :responses_coercion
  test "strict function parameters reject additionalProperties true at the top level" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 flat_function_tool("lookup_additional_properties_true", %{
                   "type" => "object",
                   "additionalProperties" => true,
                   "properties" => %{"ok" => %{"type" => "boolean"}},
                   "required" => ["ok"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_additional_properties_true': strict json_schema object schemas must set additionalProperties to false",
             param: "tools.0.parameters"
           }
  end

  @tag :responses_coercion
  test "strict function parameters reject required omissions and coverage gaps" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 flat_function_tool("lookup_omitted_required", %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{"ok" => %{"type" => "boolean"}}
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_omitted_required': strict json_schema object schemas must list every property in required (missing ok)",
             param: "tools.0.parameters.required"
           }

    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 flat_function_tool("lookup_missing_required_property", %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{
                     "ok" => %{"type" => "boolean"},
                     "extra" => %{"type" => "string"}
                   },
                   "required" => ["ok"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_missing_required_property': strict json_schema object schemas must list every property in required (missing extra)",
             param: "tools.0.parameters.required"
           }
  end

  @tag :responses_coercion
  test "strict function parameters reject nested object violations and preserve the failing tool index" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 %{"type" => "web_search_preview"},
                 flat_function_tool("lookup_nested_object", %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{
                     "settings" => %{
                       "type" => "object",
                       "properties" => %{"ok" => %{"type" => "boolean"}},
                       "required" => ["ok"]
                     }
                   },
                   "required" => ["settings"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_nested_object': strict json_schema object schemas must set additionalProperties to false",
             param: "tools.1.parameters.properties.settings"
           }
  end

  @tag :responses_coercion
  test "strict function parameters accept local $defs and definitions refs in Responses" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [flat_function_tool("lookup_local_refs", local_ref_function_parameters())]
    }

    assert {:ok, result} = Responses.coerce(payload)
    assert result.payload["tools"] == payload["tools"]
  end

  @tag :responses_coercion
  test "strict function parameters accept local $defs and definitions refs in Chat" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [function_tool("lookup_local_refs", local_ref_function_parameters())]
    }

    assert {:ok, result} = Chat.coerce(payload)
    assert result.payload["tools"] == translated_chat_tools(payload["tools"])
  end

  @tag :responses_coercion
  test "strict function parameters reject invalid local refs with sanitized errors in Responses and Chat" do
    invalid_payloads = [
      {
        "unresolved",
        invalid_local_ref_function_parameters("#/$defs/missing", "profile", %{}),
        "tools.0.parameters.properties.profile.$ref"
      },
      {
        "malformed",
        invalid_local_ref_function_parameters("#/%24defs/%zz", "profile", %{}),
        "tools.0.parameters.properties.profile.$ref"
      },
      {
        "double_hash",
        invalid_local_ref_function_parameters("##/$defs/profile", "profile", %{}),
        "tools.0.parameters.properties.profile.$ref"
      },
      {
        "remote",
        invalid_local_ref_function_parameters(
          "https://example.com/schema.json#/$defs/profile",
          "profile",
          %{}
        ),
        "tools.0.parameters.properties.profile.$ref"
      },
      {
        "circular",
        invalid_local_ref_function_parameters(
          "#/$defs/node",
          "node",
          %{"next" => %{"$ref" => "#/$defs/node"}}
        ),
        "tools.0.parameters.properties.profile.properties.next.$ref"
      },
      {
        "non_map_target",
        invalid_local_ref_function_parameters(
          "#/$defs/profile",
          "profile",
          "not a schema object"
        ),
        "tools.0.parameters.properties.profile.$ref"
      }
    ]

    Enum.each(invalid_payloads, fn {_name, parameters, expected_param} ->
      response_payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [flat_function_tool("lookup_invalid_local_ref", parameters)]
      }

      chat_payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic input"}],
        "tools" => [function_tool("lookup_invalid_local_ref", parameters)]
      }

      assert {:error,
              %{
                status: 400,
                code: "invalid_function_parameters",
                param: ^expected_param
              }} =
               Responses.coerce(response_payload)

      assert {:error,
              %{
                status: 400,
                code: "invalid_function_parameters",
                param: ^expected_param
              }} =
               Chat.coerce(chat_payload)
    end)
  end

  @tag :responses_coercion
  test "strict false and omitted strict function parameters preserve accepted behavior" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        flat_function_tool(
          "lookup_false",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          false
        ),
        flat_function_tool(
          "lookup_omitted",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          nil
        )
      ]
    }

    assert {:ok, response_result} = Responses.coerce(response_payload)
    assert response_result.payload["tools"] == response_payload["tools"]

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [
        function_tool(
          "lookup_chat_false",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          false
        ),
        function_tool(
          "lookup_chat_omitted",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          nil
        )
      ]
    }

    assert {:ok, chat_result} = Chat.coerce(chat_payload)
    assert chat_result.payload["tools"] == translated_chat_tools(chat_payload["tools"])
  end

  describe "Task 6 structured outputs, reasoning, and service tier compatibility" do
    test "Responses accepts strict text.format json_schema refs and rejects remote refs" do
      accepted_payloads = [
        %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "text" => %{"format" => strict_text_format(local_ref_schema())}
        },
        %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "text" => %{"format" => strict_text_format(root_ref_defs_schema())}
        },
        %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "text" => %{"format" => strict_text_format(root_ref_definitions_schema())}
        }
      ]

      Enum.each(accepted_payloads, fn payload ->
        assert {:ok, result} = Responses.coerce(payload)
        assert get_in(result.payload, ["text", "format", "type"]) == "json_schema"
        assert get_in(result.payload, ["text", "format", "strict"]) == true
      end)

      assert {:error,
              %{
                status: 400,
                code: "invalid_json_schema",
                param: "text.format.schema.$ref"
              }} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "text" => %{"format" => strict_text_format(remote_ref_schema())}
               })
    end

    test "Chat translates structured response_format json_schema and json_object shapes" do
      json_schema_payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic input"}],
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "fixture_schema",
            "strict" => true,
            "schema" => root_ref_defs_schema()
          }
        }
      }

      assert {:ok, result} = Chat.coerce(json_schema_payload)
      assert get_in(result.payload, ["text", "format", "type"]) == "json_schema"
      assert get_in(result.payload, ["text", "format", "name"]) == "fixture_schema"
      assert get_in(result.payload, ["text", "format", "strict"]) == true

      assert {:ok, result} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic input"}],
                 "response_format" => %{"type" => "json_object"}
               })

      assert result.payload["text"] == %{"format" => %{"type" => "json_object"}}

      assert {:error, %{status: 400, code: "invalid_request", param: "response_format"}} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic input"}],
                 "response_format" => %{"type" => "json_schema", "json_schema" => []}
               })

      assert {:error,
              %{
                status: 400,
                code: "invalid_json_schema",
                param: "text.format.schema.$ref"
              }} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic input"}],
                 "response_format" => %{
                   "type" => "json_schema",
                   "json_schema" => %{
                     "name" => "remote_fixture",
                     "strict" => true,
                     "schema" => remote_ref_schema()
                   }
                 }
               })
    end

    test "Responses accepts explicit reasoning effort and summary variants" do
      for effort <- ["minimal", "low", "medium", "high", "xhigh", "max", "focused"],
          summary <- ["auto", "concise", "detailed"] do
        payload = %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "reasoning" => %{"effort" => effort, "summary" => summary}
        }

        assert {:ok, result} = Responses.coerce(payload)
        assert result.payload["reasoning"] == payload["reasoning"]
      end
    end

    test "Responses preserves Vercel detailed reasoning summary default shape" do
      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "reasoning" => %{"effort" => "high", "summary" => "detailed"}
      }

      assert {:ok, result} = Responses.coerce(payload)
      assert result.payload["reasoning"] == payload["reasoning"]
    end

    test "Responses rejects unsupported reasoning shapes deterministically" do
      invalid_reasoning_payloads = [
        {%{"summary" => "verbose"}, "reasoning.summary"},
        {%{"effort" => "low", "unsupported" => true}, "reasoning.unsupported"},
        {"low", "reasoning"},
        {%{"effort" => 1}, "reasoning.effort"},
        {%{"summary" => false}, "reasoning.summary"},
        {%{"context" => "recent_turns"}, "reasoning.context"},
        {%{"context" => ""}, "reasoning.context"},
        {%{"context" => " "}, "reasoning.context"},
        {%{"context" => 1}, "reasoning.context"},
        {%{"context" => ["all_turns"]}, "reasoning.context"},
        {%{"context" => %{"mode" => "all_turns"}}, "reasoning.context"}
      ]

      Enum.each(invalid_reasoning_payloads, fn {reasoning, expected_param} ->
        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  param: ^expected_param
                }} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "reasoning" => reasoning
                 })
      end)
    end

    test "Responses accepts omitted and explicit service_tier variants" do
      assert {:ok, result} =
               Responses.coerce(%{"model" => "gpt-fixture-text", "input" => "synthetic input"})

      refute Map.has_key?(result.payload, "service_tier")

      for tier <- ["auto", "default", "flex", "priority", "scale"] do
        payload = %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "service_tier" => tier
        }

        assert {:ok, result} = Responses.coerce(payload)
        assert result.payload["service_tier"] == tier
      end
    end

    test "Responses rejects unsupported service_tier variants deterministically" do
      for tier <- ["unsupported", "ultrafast", "", 123, true] do
        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  param: "service_tier"
                }} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "service_tier" => tier
                 })
      end
    end

    test "SDK-internal serviceTier alias remains unsupported on public v1 payloads" do
      assert {:error,
              %{
                status: 400,
                code: "unsupported_parameter",
                param: "serviceTier"
              }} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "serviceTier" => "priority"
               })

      assert {:error,
              %{
                status: 400,
                code: "unsupported_parameter",
                param: "serviceTier"
              }} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [%{"role" => "user", "content" => "synthetic input"}],
                 "serviceTier" => "priority"
               })
    end

    test "Responses accepts truncation auto and disabled without forwarding it" do
      for truncation <- ["auto", "disabled", " AUTO ", " Disabled "] do
        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "truncation" => truncation
                 })

        refute Map.has_key?(result.payload, "truncation")
      end
    end

    test "Responses rejects unsupported truncation variants deterministically" do
      for truncation <- ["enabled", "", 123, true] do
        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  param: "truncation"
                }} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "truncation" => truncation
                 })
      end
    end
  end

  describe "Task 7 multimodal media compatibility" do
    test "Responses accepts supported image URLs and inline PDF file data" do
      image_data_url = "data:image/png;base64," <> Base.encode64("png fixture")
      file_data_url = "data:application/pdf;base64," <> Base.encode64("pdf fixture")

      payload = %{
        "model" => "gpt-fixture-text",
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic media request"},
              %{"type" => "input_image", "image_url" => image_data_url},
              %{"type" => "input_image", "image_url" => "https://example.com/sample.png"},
              %{
                "type" => "input_file",
                "filename" => "sample.pdf",
                "file_data" => file_data_url
              }
            ]
          }
        ]
      }

      assert {:ok, result} = Responses.coerce(payload)
      assert [message] = result.payload["input"]

      assert Enum.map(message["content"], & &1["type"]) == [
               "input_text",
               "input_image",
               "input_image",
               "input_file"
             ]
    end

    test "Responses rejects unsupported image/file media references deterministically" do
      invalid_payloads = [
        {%{"type" => "input_image", "file_id" => "file_fixture"},
         "unsupported_input_image_format"},
        {%{"type" => "input_image", "image_url" => "sediment://file_fixture"},
         "unsupported_input_image_format"},
        {%{"type" => "input_image", "image_url" => "http://example.com/sample.png"},
         "unsupported_input_image_format"},
        {%{
           "type" => "input_image",
           "image_url" => "data:text/html;base64," <> Base.encode64("html fixture")
         }, "unsupported_input_image_format"},
        {%{
           "type" => "input_file",
           "filename" => "sample.html",
           "file_data" => "data:text/html;base64," <> Base.encode64("html fixture")
         }, "unsupported_input_file_format"}
      ]

      Enum.each(invalid_payloads, fn {part, expected_code} ->
        assert {:error, %{status: 400, code: ^expected_code, param: "input"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [%{"role" => "user", "content" => [part]}]
                 })
      end)
    end

    test "Chat translates SDK image and audio parts through Responses compatibility" do
      audio_data = Base.encode64("wav fixture")

      payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "synthetic multimodal chat"},
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "https://example.com/sample.png"}
              },
              %{
                "type" => "input_audio",
                "input_audio" => %{"data" => audio_data, "format" => "wav"}
              }
            ]
          }
        ]
      }

      assert {:ok, result} = Chat.coerce(payload)
      assert [%{"content" => content}] = result.payload["input"]
      assert Enum.map(content, & &1["type"]) == ["input_text", "input_image", "input_audio"]
      assert Enum.at(content, 1)["image_url"] == "https://example.com/sample.png"
      assert get_in(Enum.at(content, 2), ["input_audio", "format"]) == "wav"
    end

    test "Chat rejects unsupported image schemes and malformed audio before dispatch" do
      assert {:error, %{status: 400, code: "unsupported_input_image_format", param: "input"}} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => [
                       %{"type" => "image_url", "image_url" => "file:///tmp/private.png"}
                     ]
                   }
                 ]
               })

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Chat.coerce(%{
                 "model" => "gpt-fixture-text",
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => [
                       %{
                         "type" => "input_audio",
                         "input_audio" => %{"data" => "not base64", "format" => "wav"}
                       }
                     ]
                   }
                 ]
               })
    end
  end

  defp function_tool(name, parameters, strict \\ true) do
    function = %{"name" => name, "parameters" => parameters}

    function =
      case strict do
        nil -> function
        value -> Map.put(function, "strict", value)
      end

    %{"type" => "function", "function" => function}
  end

  defp flat_function_tool(name, parameters, strict \\ true) do
    tool = %{"type" => "function", "name" => name, "parameters" => parameters}

    case strict do
      nil -> tool
      value -> Map.put(tool, "strict", value)
    end
  end

  defp translated_chat_tools(tools), do: Enum.map(tools, &translated_chat_tool/1)

  defp non_strict_tool_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "properties" => %{
        "mode" => %{"const" => "fast", "title" => "drop me"},
        "tags" => %{"items" => %{"const" => "tag"}},
        "nested" => %{
          "properties" => %{"ok" => true},
          "required" => ["ok"]
        },
        "choice" => %{
          "oneOf" => [
            %{"const" => "a"},
            %{"type" => "string", "default" => "drop me"}
          ]
        }
      },
      "required" => ["mode"],
      "additionalProperties" => %{"const" => "extra"},
      "$defs" => %{
        "Ref" => %{
          "properties" => %{"value" => %{"const" => "ref"}},
          "required" => ["value"]
        }
      },
      "definitions" => %{
        "Legacy" => %{"items" => %{"const" => "legacy"}}
      }
    }
  end

  defp lowered_tool_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"enum" => ["fast"]},
        "tags" => %{"type" => "array", "items" => %{"enum" => ["tag"]}},
        "nested" => %{
          "type" => "object",
          "properties" => %{"ok" => %{}},
          "required" => ["ok"]
        },
        "choice" => %{
          "oneOf" => [
            %{"enum" => ["a"]},
            %{"type" => "string"}
          ]
        }
      },
      "required" => ["mode"],
      "additionalProperties" => %{"enum" => ["extra"]},
      "$defs" => %{
        "Ref" => %{
          "type" => "object",
          "properties" => %{"value" => %{"enum" => ["ref"]}},
          "required" => ["value"]
        }
      },
      "definitions" => %{
        "Legacy" => %{"type" => "array", "items" => %{"enum" => ["legacy"]}}
      }
    }
  end

  defp translated_chat_tool(%{"type" => "function", "function" => function}) do
    function
    |> Map.take(["name", "description", "parameters", "strict"])
    |> Map.put("type", "function")
  end

  defp translated_chat_tool(tool), do: tool

  defp strict_text_format(schema) do
    %{
      "type" => "json_schema",
      "name" => "fixture_schema",
      "strict" => true,
      "schema" => schema
    }
  end

  defp local_ref_schema, do: local_ref_function_parameters()

  defp root_ref_defs_schema do
    %{
      "$ref" => "#/$defs/root",
      "$defs" => %{
        "root" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"answer" => %{"$ref" => "#/$defs/answer"}},
          "required" => ["answer"]
        },
        "answer" => %{"type" => "string"}
      }
    }
  end

  defp root_ref_definitions_schema do
    %{
      "$ref" => "#/definitions/root",
      "definitions" => %{
        "root" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"enabled" => %{"$ref" => "#/definitions/enabled"}},
          "required" => ["enabled"]
        },
        "enabled" => %{"type" => "boolean"}
      }
    }
  end

  defp remote_ref_schema do
    %{"$ref" => "https://example.com/schema.json#/$defs/root"}
  end

  defp local_ref_function_parameters do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "from_defs" => %{"$ref" => "#/$defs/profile"},
        "from_definitions" => %{"$ref" => "#/definitions/settings"}
      },
      "required" => ["from_defs", "from_definitions"],
      "$defs" => %{
        "profile" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"summary" => %{"type" => "string"}},
          "required" => ["summary"]
        }
      },
      "definitions" => %{
        "settings" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"enabled" => %{"type" => "boolean"}},
          "required" => ["enabled"]
        }
      }
    }
  end

  defp invalid_local_ref_function_parameters(ref, definition_name, definition_properties)
       when is_map(definition_properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"profile" => %{"$ref" => ref}},
      "required" => ["profile"],
      "$defs" => %{
        definition_name => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => definition_properties,
          "required" => Map.keys(definition_properties)
        }
      }
    }
  end

  defp invalid_local_ref_function_parameters(ref, definition_name, definition_schema) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"profile" => %{"$ref" => ref}},
      "required" => ["profile"],
      "$defs" => %{definition_name => definition_schema}
    }
  end

  defp prompt_cache_key_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp upload_metadata do
    %{"filename" => "fixture.txt", "content_type" => "text/plain", "bytes" => 12}
  end

  defp audio_upload_fixture(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-audio-coerce-#{System.unique_integer([:positive])}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: "fixture.wav", content_type: "audio/wav"}
  end

  defp structured_tool_result_output do
    %{
      "command" => "TASK7_RAW_TOOL_COMMAND_SENTINEL run private command",
      "exit_code" => 0,
      "files" => [
        %{
          "path" => "sample-output.txt",
          "content" => "TASK7_RAW_TOOL_OUTPUT_SENTINEL\n" <> String.duplicate("line\n", 200)
        }
      ],
      "nested" => %{
        "list" => [
          %{"stdout_preview" => String.duplicate("TASK7_LONG_NESTED_VALUE_", 40)},
          %{"secret_like" => "TASK7_SECRET_LIKE_TOOL_SENTINEL"}
        ],
        "ok" => true
      }
    }
  end

  defp assert_payload_equal_no_echo!(actual, expected, message) do
    unless actual == expected, do: flunk(message)
  end

  defp unsupported_value("conversation"), do: "conv_fixture"
  defp unsupported_value("n"), do: 2
  defp unsupported_value("prediction"), do: %{"type" => "content", "content" => "synthetic"}
  defp unsupported_value("prompt"), do: %{"id" => "prompt_fixture"}
  defp unsupported_value("stop"), do: ["STOP"]
  defp unsupported_value("stream_options"), do: %{"include_usage" => true}
  defp unsupported_value("web_search_options"), do: %{"search_context_size" => "low"}
  defp unsupported_value(_field), do: true
end
