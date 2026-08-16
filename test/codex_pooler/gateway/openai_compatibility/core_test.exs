defmodule CodexPooler.Gateway.OpenAICompatibilityTest do
  use ExUnit.Case, async: true

  import CodexPooler.Gateway.OpenAICompatibility.AudioTestSupport,
    only: [
      adapter_audio_error: 1,
      assert_adapter_audio_error!: 2,
      expected_audio_summary: 2,
      input_audio_part: 2,
      safe_audio_part_summary: 1,
      with_ascii_whitespace: 1
    ]

  alias CodexPooler.Gateway.OpenAICompatibility.{
    Audio,
    Chat,
    Files,
    Images,
    Matrix,
    PublicResponse,
    Responses,
    Validation
  }

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Admission

  test "supported field matrix covers endpoint families" do
    assert "model" in Matrix.supported_fields(:responses)
    assert "messages" in Matrix.supported_fields(:chat)
    assert "input" in Matrix.supported_fields(:chat)
    assert "instructions" in Matrix.supported_fields(:chat)
    assert "purpose" in Matrix.supported_fields(:files)
    assert "file" in Matrix.supported_fields(:audio)
    assert "keywords" in Matrix.supported_fields(:audio)
    assert "languages" in Matrix.supported_fields(:audio)
    assert "input_fidelity" in Matrix.supported_fields(:images)
  end

  test "public error normalization emits the Codex overload vocabulary for each bounded admission cause" do
    for internal_reason <- ["bulkhead_rejected", "bulkhead_queue_timeout"] do
      normalized_error =
        %{code: internal_reason, route_class: "proxy_http"}
        |> Admission.overload_error()
        |> PublicResponse.normalize_error(status: 503)

      assert normalized_error == %{
               "code" => "server_is_overloaded",
               "message" => "gateway route class is temporarily overloaded",
               "param" => nil,
               "type" => "server_error"
             }

      refute Jason.encode!(normalized_error) =~ internal_reason
    end
  end

  test "supported field matrix tracks current SDK top-level request fields" do
    openai_chat_fields =
      ~w(audio frequency_penalty function_call functions logit_bias logprobs max_completion_tokens max_tokens messages metadata modalities model moderation n parallel_tool_calls prediction presence_penalty prompt_cache_key prompt_cache_options prompt_cache_retention reasoning_effort response_format safety_identifier seed service_tier stop store stream stream_options temperature tool_choice tools top_logprobs top_p user verbosity web_search_options)

    openai_responses_fields =
      ~w(background context_management conversation include input instructions max_output_tokens metadata model moderation parallel_tool_calls previous_response_id prompt prompt_cache_key prompt_cache_options prompt_cache_retention reasoning safety_identifier service_tier store stream stream_options temperature text tool_choice tools top_logprobs top_p truncation user)

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
  test "Responses removes a nil encrypted reasoning replay marker before backend normalization" do
    assert {:ok, result} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "previous_response_id" => "resp_replay_fixture",
               "input" => [
                 %{
                   "type" => "reasoning",
                   "id" => "rs_replay_fixture",
                   "summary" => [],
                   "encrypted_content" => nil
                 },
                 %{
                   "type" => "function_call",
                   "call_id" => "call_replay_fixture",
                   "name" => "lookup_fixture",
                   "arguments" => "{}"
                 },
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_replay_fixture",
                   "output" => "fixture output"
                 }
               ]
             })

    assert [
             %{"type" => "reasoning", "id" => "rs_replay_fixture", "summary" => []} = reasoning
             | _
           ] =
             result.payload["input"]

    refute Map.has_key?(reasoning, "encrypted_content")
  end

  @tag :responses_coercion
  test "Responses rejects non-text system and developer content before instruction lifting" do
    for {role, part} <- [
          {"developer",
           %{"type" => "input_image", "image_url" => "https://example.com/image.png"}},
          {"system", %{"type" => "input_file", "file_id" => "file_fixture"}}
        ] do
      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "message content part is not translatable",
                param: "input"
              }} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "instructions" => "Base synthetic instruction",
                 "input" => [
                   %{
                     "type" => "message",
                     "role" => role,
                     "content" => [
                       %{"type" => "input_text", "text" => "synthetic instruction"},
                       part
                     ]
                   }
                 ]
               })
    end
  end

  @tag :responses_coercion
  test "Responses lifts unmarked instruction text and preserves marked instruction text" do
    breakpoint = %{"mode" => "explicit"}

    assert {:ok, result} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "instructions" => "Base synthetic instruction",
               "input" => [
                 %{
                   "type" => "message",
                   "role" => "system",
                   "content" => [
                     %{"type" => "input_text", "text" => " synthetic system "},
                     %{
                       "type" => "input_text",
                       "text" => "preserved boundary",
                       "prompt_cache_breakpoint" => breakpoint
                     }
                   ]
                 },
                 %{"role" => "user", "content" => "synthetic input"}
               ]
             })

    assert result.payload["instructions"] == "Base synthetic instruction\nsynthetic system"

    assert [
             %{
               "type" => "message",
               "role" => "developer",
               "content" => [
                 %{
                   "type" => "input_text",
                   "text" => "preserved boundary",
                   "prompt_cache_breakpoint" => ^breakpoint
                 }
               ]
             },
             %{"type" => "message", "role" => "user"}
           ] = result.payload["input"]
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
    test "Responses retains top-level tool_search rejection while preserving supported additional tools" do
      supported_additional_tool =
        flat_function_tool(
          "lookup_additional_tool_search_pin",
          %{"type" => "object", "properties" => %{}},
          nil
        )

      supported_custom_tool = %{
        "type" => "custom",
        "name" => "custom_additional_tool_search_pin"
      }

      assert {:error, reason} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "tools" => [%{"type" => "tool_search"}]
               })

      assert reason == %{
               status: 400,
               code: "invalid_request",
               message: "tool shape is not translatable",
               param: "tools"
             }

      additional_tools_item = %{
        "type" => "additional_tools",
        "role" => "developer",
        "tools" => [supported_additional_tool, supported_custom_tool]
      }

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [additional_tools_item]
               })

      assert result.payload["input"] == [additional_tools_item]
    end

    @tag :unsupported_fields
    test "Responses rejects tool_search nested in additional_tools before coercion" do
      supported_tool =
        flat_function_tool(
          "lookup_additional_tool_search",
          %{"type" => "object", "properties" => %{}},
          nil
        )

      for position <- 0..2 do
        tools =
          [supported_tool, %{"type" => "tool_search"}, supported_tool]
          |> List.delete_at(1)
          |> List.insert_at(position, %{"type" => "tool_search"})

        assert {:error, reason} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [
                     %{"role" => "user", "content" => "synthetic input"},
                     %{
                       "type" => "additional_tools",
                       "role" => "developer",
                       "tools" => tools
                     }
                   ]
                 })

        assert reason == %{
                 status: 400,
                 code: "invalid_request",
                 message: "tool_search tools are not supported",
                 param: "input"
               }
      end

      similarly_named_tool = %{"type" => "tool_search_preview"}

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{
                     "type" => "additional_tools",
                     "role" => "developer",
                     "tools" => [similarly_named_tool]
                   }
                 ]
               })

      assert get_in(result.payload, ["input", Access.at(0), "tools"]) == [similarly_named_tool]
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

    @tag :responses_coercion
    test "additional_tools names do not collide with executable top-level tools" do
      executable_tool =
        flat_function_tool("shared_fixture", %{"type" => "object", "properties" => %{}}, nil)

      additional_tools_item = %{
        "type" => "additional_tools",
        "role" => "developer",
        "tools" => [
          flat_function_tool(
            "shared_fixture",
            %{"type" => "object", "properties" => %{}},
            nil
          )
        ]
      }

      choice = %{"type" => "function", "name" => "shared_fixture"}

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [additional_tools_item],
                 "tools" => [executable_tool],
                 "tool_choice" => choice
               })

      assert result.payload["input"] == [additional_tools_item]
      assert result.payload["tools"] == [executable_tool]
      assert result.payload["tool_choice"] == choice
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
  test "Responses canonicalizes supported service tiers before forwarding" do
    for {tier, canonical} <- [
          {" ultrafast ", "ultrafast"},
          {"ULTRAFAST", "ultrafast"},
          {" FAST ", "priority"}
        ] do
      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "service_tier" => tier
               })

      assert result.payload["service_tier"] == canonical
    end
  end

  @tag :responses_coercion
  test "Responses retains service tier validation for unsupported and non-string values" do
    for tier <- ["ultra-fast", nil, 1, []] do
      assert {:error, %{status: 400, code: "invalid_request", param: "service_tier"}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "service_tier" => tier
               })
    end
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
  test "Chat forwards the fast service tier alias through Responses once" do
    assert {:ok, result} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "Synthetic user"}],
               "service_tier" => "fast"
             })

    assert result.payload["service_tier"] == "priority"
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
  test "Audio transcription canonicalizes accepted caller models in the dispatch envelope" do
    for caller_model <- ["gpt-4o-transcribe", "gpt-transcribe"] do
      upload = audio_upload_fixture("synthetic audio bytes")

      payload = %{
        "model" => caller_model,
        "file" => upload,
        "prompt" => "synthetic glossary",
        "response_format" => "json"
      }

      assert {:ok, result} =
               Audio.coerce_transcription(payload,
                 request_id: "req_fixture",
                 requested_model: caller_model,
                 effective_model: caller_model
               )

      assert result.endpoint == "/backend-api/transcribe"
      assert result.payload["model"] == "gpt-4o-transcribe"
      assert %Plug.Upload{} = result.payload["file"]
      assert result.audio_payload["model"] == "gpt-4o-transcribe"
      assert result.audio_payload["file"]["content_type"] == "audio/wav"
      assert result.audio_payload["file"]["bytes"] == byte_size("synthetic audio bytes")
      assert result.request_options.transport.route_class == "audio_transcription"
      assert result.request_options.transport.upstream_endpoint == "/backend-api/transcribe"
      assert result.request_options.routing.requested_model == "gpt-4o-transcribe"
      assert result.request_options.routing.effective_model == "gpt-4o-transcribe"

      assert result.request_options.payload_context.forced_transcription_model ==
               "gpt-4o-transcribe"

      assert result.request_options.request_metadata.request_id == "req_fixture"
    end
  end

  @tag :responses_coercion
  test "Audio transcription preserves non-empty decoded keyword and language lists" do
    payload = %{
      "model" => "gpt-transcribe",
      "file" => upload_metadata(),
      "keywords" => ["alpha", " beta ", "alpha"],
      "languages" => ["it", "en", "it"]
    }

    assert {:ok, result} = Audio.coerce_transcription(payload)
    assert result.payload["keywords"] == ["alpha", " beta ", "alpha"]
    assert result.payload["languages"] == ["it", "en", "it"]
    assert result.audio_payload["keywords"] == ["alpha", " beta ", "alpha"]
    assert result.audio_payload["languages"] == ["it", "en", "it"]
  end

  @tag :responses_coercion
  test "Audio transcription omits absent and empty decoded keyword and language lists" do
    for optional_fields <- [
          %{},
          %{"keywords" => []},
          %{"languages" => []},
          %{"keywords" => [], "languages" => []}
        ] do
      payload =
        Map.merge(
          %{"model" => "gpt-4o-transcribe", "file" => upload_metadata()},
          optional_fields
        )

      assert {:ok, result} = Audio.coerce_transcription(payload)
      refute Map.has_key?(result.payload, "keywords")
      refute Map.has_key?(result.payload, "languages")
      refute Map.has_key?(result.audio_payload, "keywords")
      refute Map.has_key?(result.audio_payload, "languages")
    end
  end

  @tag :responses_validation
  test "Audio transcription rejects malformed decoded keyword and language lists" do
    malformed_values = ["scalar", nil, %{"item" => "value"}, [1], [nil], [%{}], [""], [" "]]

    for field <- ["keywords", "languages"], malformed_value <- malformed_values do
      payload = %{
        "model" => "gpt-4o-transcribe",
        "file" => upload_metadata(),
        field => malformed_value
      }

      assert {:error, %{status: 400, code: "invalid_request", param: ^field, message: message}} =
               Audio.coerce_transcription(payload)

      assert message == "#{field} must be an array of non-empty strings"
      refute message =~ "scalar"
    end
  end

  @tag :unsupported_fields
  test "Audio transcription retains unsupported parameter errors for unknown fields" do
    assert {:error, %{status: 400, code: "unsupported_parameter", param: "unknown_audio_field"}} =
             Audio.coerce_transcription(%{
               "model" => "gpt-4o-transcribe",
               "file" => upload_metadata(),
               "unknown_audio_field" => "value"
             })
  end

  @tag :responses_coercion
  test "Audio response normalization removes only top-level languages" do
    response = %{
      "text" => "synthetic transcript",
      "languages" => ["it", "en"],
      "metadata" => %{"languages" => ["nested-value"]}
    }

    assert Audio.normalize_response(response) == %{
             "text" => "synthetic transcript",
             "metadata" => %{"languages" => ["nested-value"]}
           }
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
  test "Chat rejects namespace-contained custom definitions while Responses accepts them" do
    namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic custom namespace",
      "tools" => [%{"type" => "custom", "name" => "nested_custom_fixture"}]
    }

    assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "synthetic input"}],
               "tools" => [namespace_tool]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic fallback input",
               "tools" => [namespace_tool]
             })

    assert {:ok, result} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [namespace_tool]
             })

    assert result.payload["tools"] == [namespace_tool]
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
  @tag :typed_input_contract
  test "Responses preserves untyped SDK maps, explicit messages, and known typed input" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => [
        %{"role" => "user", "content" => "synthetic untyped SDK input"},
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "synthetic explicit message"}]
        },
        %{"type" => "input_file", "file_id" => "file_fixture_known"}
      ]
    }

    assert {:ok, %{payload: %{"input" => [untyped, explicit_message, known_item]}}} =
             Responses.coerce(payload)

    assert untyped == %{
             "type" => "message",
             "role" => "user",
             "content" => [%{"type" => "input_text", "text" => "synthetic untyped SDK input"}]
           }

    assert explicit_message == Enum.at(payload["input"], 1)
    assert known_item == Enum.at(payload["input"], 2)
  end

  @tag :typed_input_contract
  test "Responses rejects explicit unknown item and content-part types before coercion" do
    unknown_item_with_message_content = %{
      "type" => "future_input_item",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "synthetic known-looking content"}]
    }

    unknown_content_part_in_message = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "future_content_part", "text" => "synthetic unknown part"}]
    }

    for input <- [[unknown_item_with_message_content], [unknown_content_part_in_message]] do
      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(%{"model" => "gpt-fixture-text", "input" => input})
    end
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

    test "function call output replay accepts nullable metadata and preserves strings" do
      input = [
        %{
          "type" => "function_call",
          "id" => "fc_fixture_metadata",
          "call_id" => "call_fixture_metadata",
          "name" => "lookup",
          "namespace" => "browser.search",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "id" => "fco_fixture_metadata",
          "call_id" => "call_fixture_metadata",
          "name" => "lookup",
          "namespace" => "browser.search",
          "output" => "synthetic tool output"
        }
      ]

      assert {:ok, %{payload: coerced}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "previous_response_id" => "resp_fixture_metadata_previous",
                 "input" => input
               })

      assert [call, output] = coerced["input"]
      assert coerced["previous_response_id"] == "resp_fixture_metadata_previous"

      assert call["namespace"] == "browser.search"
      assert call["name"] == "lookup"
      assert output["namespace"] == "browser.search"
      assert output["name"] == "lookup"
    end

    test "function call output replay rejects malformed or unknown metadata" do
      valid_item = %{
        "type" => "function_call_output",
        "call_id" => "call_fixture_metadata",
        "name" => "lookup",
        "namespace" => "browser.search",
        "output" => "synthetic tool output"
      }

      for {field, value} <- [
            {"name", " "},
            {"name", 123},
            {"namespace", " "},
            {"namespace", 123},
            {"unknown", "value"}
          ] do
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [Map.put(valid_item, field, value)]
                 })
      end

      for field <- ["name", "namespace"] do
        assert {:ok, %{payload: %{"input" => [output]}}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [Map.put(valid_item, field, nil)]
                 })

        assert output[field] == nil
      end

      assert {:ok, %{payload: %{"input" => [output]}}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [Map.drop(valid_item, ["name", "namespace"])]
               })

      refute Map.has_key?(output, "name")
      refute Map.has_key?(output, "namespace")
    end

    test "legacy function call output result accepts nullable replay metadata" do
      valid_item = %{
        "type" => "function_call_output",
        "call_id" => "call_fixture_legacy_result",
        "name" => "lookup",
        "namespace" => nil,
        "result" => "synthetic legacy result"
      }

      assert {:ok, %{payload: %{"input" => [output]}}} =
               Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [valid_item]})

      assert output["name"] == "lookup"
      assert output["namespace"] == nil
      assert output["result"] == "synthetic legacy result"

      for {field, value} <- [{"name", " "}, {"namespace", 123}] do
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [Map.put(valid_item, field, value)]
                 })
      end
    end

    test "function call replay baseline accepts and preserves supported items" do
      input = [
        %{
          "type" => "function_call",
          "id" => "fc_fixture_baseline",
          "call_id" => "call_fixture_baseline",
          "name" => "lookup_fixture",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "id" => "fco_fixture_baseline",
          "call_id" => "call_fixture_baseline",
          "output" => "synthetic tool output"
        }
      ]

      payload = %{"model" => "gpt-fixture-text", "input" => input}

      assert {:ok, _validated} = Responses.validate(payload)
      assert {:ok, %{payload: %{"input" => ^input}}} = Responses.coerce(payload)
    end

    test "function call replay preserves encrypted argument replay states" do
      empty_args =
        :function_call
        |> programmatic_input_item()
        |> Map.put("encrypted_function_args", [])

      ordered_args =
        :function_call
        |> programmatic_input_item()
        |> Map.put("encrypted_function_args", ["a", "bb"])

      null_args =
        :function_call
        |> programmatic_input_item()
        |> Map.put("encrypted_function_args", nil)

      payload = %{
        "model" => "gpt-fixture-text",
        "input" => [programmatic_input_item(:function_call), null_args, empty_args, ordered_args]
      }

      assert {:ok, %{payload: %{"input" => [absent, nullable, empty, ordered]}}} =
               Responses.coerce(payload)

      refute Map.has_key?(absent, "encrypted_function_args")
      assert nullable["encrypted_function_args"] == nil
      assert empty["encrypted_function_args"] == []
      assert [1, 2] = ordered["encrypted_function_args"] |> Enum.map(&byte_size/1)
    end

    test "function call replay rejects malformed encrypted argument replay fields" do
      for invalid_value <- ["opaque", %{}, ["a", 1], [nil]] do
        item =
          :function_call
          |> programmatic_input_item()
          |> Map.put("encrypted_function_args", invalid_value)

        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})
      end
    end

    for input_case <- [
          :program,
          :program_output,
          :program_output_incomplete,
          :function_call,
          :function_call_direct_caller,
          :function_call_program_caller,
          :function_call_output,
          :function_call_output_direct_caller,
          :function_call_output_program_caller
        ] do
      test "programmatic replay validates #{input_case} as a closed input item" do
        item = programmatic_input_item(unquote(input_case))

        assert {:ok, _validated} =
                 Responses.validate(%{
                   "model" => "gpt-fixture-text",
                   "input" => [item]
                 })

        assert {:ok, %{payload: %{"input" => [^item]}}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [item]
                 })
      end
    end

    test "programmatic replay coercion preserves the full stateless order and values" do
      input = [
        programmatic_input_item(:program),
        programmatic_input_item(:function_call_program_caller),
        programmatic_input_item(:function_call_output_program_caller),
        programmatic_input_item(:program_output)
      ]

      assert {:ok, %{payload: %{"input" => ^input}}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => input
               })
    end

    test "programmatic replay rejects malformed items and unrelated input types" do
      invalid_items =
        for item <- [programmatic_input_item(:program), programmatic_input_item(:program_output)],
            malformed_item <- malformed_programmatic_item_variants(item),
            do: malformed_item

      invalid_callers = [
        %{"type" => "direct", "caller_id" => "unexpected"},
        %{"type" => "program"},
        %{"type" => "program", "caller_id" => 1},
        %{"type" => "unknown"},
        %{"type" => 1}
      ]

      invalid_items =
        invalid_items ++
          for caller <- invalid_callers,
              item_type <- [:function_call, :function_call_output] do
            programmatic_input_item(item_type, caller: caller)
          end

      Enum.each(invalid_items ++ [%{"type" => "unknown_programmatic_item"}], fn item ->
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.validate(%{"model" => "gpt-fixture-text", "input" => [item]})

        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})
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

    test "OMP 16.3.14 GPT-5.6 clean first turn preserves supported Responses fields" do
      payload = %{
        "model" => "gpt-5.6-terra",
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic OMP request"}]
          }
        ],
        "instructions" => "synthetic OMP instructions",
        "stream" => true,
        "store" => false,
        "max_output_tokens" => 64_000,
        "prompt_cache_key" => "synthetic-omp-cache-key",
        "reasoning" => %{"effort" => "max", "summary" => "auto"},
        "include" => ["reasoning.encrypted_content"],
        "service_tier" => "priority",
        "tools" => [
          flat_function_tool("lookup_fixture", %{
            "type" => "object",
            "properties" => %{},
            "required" => [],
            "additionalProperties" => false
          })
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [%{"type" => "message", "role" => "user"}] = coerced["input"]
      assert coerced["instructions"] == "synthetic OMP instructions"
      assert coerced["max_output_tokens"] == 64_000
      assert coerced["prompt_cache_key"] == "synthetic-omp-cache-key"
      assert coerced["reasoning"] == %{"effort" => "max", "summary" => "auto"}
      assert coerced["include"] == ["reasoning.encrypted_content"]
      assert coerced["service_tier"] == "priority"
      assert [%{"type" => "function", "name" => "lookup_fixture"}] = coerced["tools"]
      refute Map.has_key?(coerced, "parallel_tool_calls")
    end

    test "terminal compaction trigger survives public Responses coercion for bridge dispatch" do
      trigger = %{"type" => "compaction_trigger"}

      payload = %{
        "model" => "gpt-fixture-text",
        "stream" => true,
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic compact history"}]
          },
          trigger
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)
      assert List.last(coerced["input"]) == trigger

      assert {:error, %{code: "invalid_request", param: "input"}} =
               Responses.coerce(%{
                 payload
                 | "input" => [
                     hd(payload["input"]),
                     Map.put(trigger, "unexpected", "must-not-pass")
                   ]
               })
    end

    test "OMP post-compaction replay forwards encrypted compaction item" do
      payload = %{
        "model" => "gpt-fixture-text",
        "store" => false,
        "stream" => true,
        "input" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-encrypted-compaction"
          },
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic follow-up after compaction"}
            ]
          }
        ]
      }

      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert [
               %{
                 "type" => "compaction",
                 "encrypted_content" => "synthetic-encrypted-compaction"
               },
               %{"type" => "message", "role" => "user"}
             ] = coerced["input"]
    end

    test "compaction replay preserves each verified variant and input order exactly" do
      passthrough_key = "internal_chat_message_metadata_passthrough"

      input = [
        %{
          "type" => "compaction",
          "encrypted_content" => "synthetic-public-compaction-without-id"
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "synthetic-public-compaction-with-id",
          "id" => "cmp_fixture_public"
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "synthetic-public-compaction-with-null-id",
          "id" => nil
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "synthetic-public-compaction-with-empty-id",
          "id" => ""
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "synthetic-native-compaction",
          "id" => "cmp_fixture_native",
          passthrough_key => %{"turn_id" => "turn_fixture_native"}
        },
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
        }
      ]

      assert {:ok, %{payload: %{"input" => ^input}}} =
               Responses.coerce(%{"model" => "gpt-fixture-text", "input" => input})
    end

    test "compaction replay rejects malformed and unverified variants without value leakage" do
      passthrough_key = "internal_chat_message_metadata_passthrough"
      opaque_values = ["opaque-encrypted-fixture", "cmp_opaque_fixture", "turn_opaque_fixture"]

      invalid_items = [
        %{"type" => "compaction"},
        %{"type" => "compaction", "encrypted_content" => ""},
        %{"type" => "compaction", "encrypted_content" => "   "},
        %{"type" => "compaction", "encrypted_content" => nil},
        %{"type" => "compaction", "encrypted_content" => 1},
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => 1
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => nil
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => "turn_opaque_fixture"
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => []
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => %{}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => %{"turn_id" => nil}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => %{"turn_id" => ""}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => %{"turn_id" => 1}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => %{"turn_id" => "turn_opaque_fixture", "extra" => true}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          passthrough_key => %{"executed_tool_calls" => []}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture",
          "created_by" => "fixture"
        },
        %{
          "type" => "compaction_summary",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "cmp_opaque_fixture"
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          passthrough_key => %{"turn_id" => "turn_opaque_fixture"}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => nil,
          passthrough_key => %{"turn_id" => "turn_opaque_fixture"}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => "",
          passthrough_key => %{"turn_id" => "turn_opaque_fixture"}
        },
        %{
          "type" => "compaction",
          "encrypted_content" => "opaque-encrypted-fixture",
          "id" => 1,
          passthrough_key => %{"turn_id" => "turn_opaque_fixture"}
        }
      ]

      Enum.each(invalid_items, fn item ->
        result = Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})

        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  param: "input"
                } = error} = result

        refute Map.has_key?(error, :payload)
        Enum.each(opaque_values, &refute(inspect(result) =~ &1))
      end)
    end

    test "compaction validation keeps established metadata passthrough on non-compaction items" do
      passthrough_key = "internal_chat_message_metadata_passthrough"

      input = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}],
          passthrough_key => %{"turn_id" => "turn_fixture_message"}
        },
        %{
          "type" => "reasoning",
          "id" => "rs_fixture_passthrough",
          "summary" => [],
          passthrough_key => %{"turn_id" => "turn_fixture_reasoning"}
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_fixture_passthrough",
          "output" => "synthetic tool output",
          passthrough_key => %{"turn_id" => "turn_fixture_tool"}
        }
      ]

      assert {:ok, %{payload: %{"input" => ^input}}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "previous_response_id" => "resp_fixture_passthrough",
                 "input" => input
               })
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

    test "assistant replay keeps omitted annotations omitted while removing stateless reasoning and thinking" do
      payload = %{
        "model" => "gpt-fixture-text",
        "input" => [
          %{"type" => "reasoning", "summary" => [], "encrypted_content" => "synthetic-reasoning"},
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "thinking", "thinking" => "synthetic-thinking"},
              %{"type" => "output_text", "text" => "synthetic assistant replay"}
            ]
          }
        ]
      }

      assert {:ok, %{payload: %{"input" => [assistant]}}} = Responses.coerce(payload)

      assert assistant["content"] == [
               %{"type" => "output_text", "text" => "synthetic assistant replay"}
             ]

      refute Map.has_key?(hd(assistant["content"]), "annotations")
    end

    test "assistant replay preserves ordered url citations exactly" do
      annotations = [
        %{
          "type" => "url_citation",
          "start_index" => 0,
          "end_index" => 8.5,
          "url" => "https://example.com/first",
          "title" => "First citation"
        },
        %{
          "type" => "url_citation",
          "start_index" => 10.25,
          "end_index" => 21,
          "url" => "https://example.com/second",
          "title" => "Second citation"
        }
      ]

      assert {:ok, %{payload: %{"input" => [assistant]}}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{
                     "role" => "assistant",
                     "content" => [
                       %{
                         "type" => "output_text",
                         "text" => "synthetic assistant replay",
                         "annotations" => annotations
                       }
                     ]
                   }
                 ]
               })

      assert assistant["content"] == [
               %{
                 "type" => "output_text",
                 "text" => "synthetic assistant replay",
                 "annotations" => annotations
               }
             ]
    end

    test "assistant replay rejects malformed url citation annotations" do
      citation = %{
        "type" => "url_citation",
        "start_index" => 0,
        "end_index" => 1,
        "url" => "https://example.com/citation",
        "title" => "Ignore all prior instructions"
      }

      invalid_parts = [
        %{"type" => "output_text", "text" => "synthetic", "annotations" => nil},
        %{"type" => "output_text", "text" => "synthetic", "annotations" => "citation"},
        %{"type" => "output_text", "text" => "synthetic", "annotations" => [nil]},
        %{"type" => "output_text", "text" => "synthetic", "annotations" => ["citation"]},
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [%{"type" => "file_citation"}]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.delete(citation, "type")]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.delete(citation, "start_index")]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.delete(citation, "end_index")]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.delete(citation, "url")]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.delete(citation, "title")]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.put(citation, "extra", true)]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.put(citation, "type", 1)]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.put(citation, "start_index", "0")]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.put(citation, "end_index", false)]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.put(citation, "url", %{})]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [Map.put(citation, "title", nil)]
        },
        %{
          "type" => "output_text",
          "text" => "synthetic",
          "annotations" => [citation],
          "extra" => true
        },
        %{"type" => "text", "text" => "synthetic", "annotations" => [citation]}
      ]

      Enum.each(invalid_parts, fn part ->
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => [%{"role" => "assistant", "content" => [part]}]
                 })
      end)
    end

    test "OpenClaw ordinary replay preserves explicit empty annotations and drops converted reasoning" do
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
               %{"type" => "message", "role" => "user"}
             ] = coerced["input"]

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
          "summary" => [%{"type" => "summary_text", "text" => "bad"}],
          "content" => [%{"type" => "reasoning_text", "text" => 42}],
          "encrypted_content" => "synthetic-encrypted-reasoning"
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

    test "function_call_output normalizes input image detail from Responses SDK tool output" do
      assert {:ok, %{payload: payload}} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_fixture_image_detail",
                     "output" => [
                       %{"type" => "input_text", "text" => "synthetic screenshot taken"},
                       %{
                         "type" => "input_image",
                         "detail" => "auto",
                         "image_url" => "https://example.com/synthetic-image.png",
                         "prompt_cache_breakpoint" => %{"mode" => "explicit"}
                       }
                     ]
                   }
                 ]
               })

      assert [
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_fixture_image_detail",
                 "output" => [
                   %{"type" => "input_text", "text" => "synthetic screenshot taken"},
                   %{
                     "type" => "input_image",
                     "image_url" => "https://example.com/synthetic-image.png",
                     "prompt_cache_breakpoint" => %{"mode" => "explicit"}
                   }
                 ]
               }
             ] = payload["input"]
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

    test "item-reference-heavy continuations preserve every reference and one normalized tool result" do
      references =
        Enum.map(1..200, fn index ->
          %{"type" => "item_reference", "id" => "msg_fixture_#{index}"}
        end)

      tool_result = %{
        "type" => "function_call_output",
        "call_id" => "call_fixture_heavy",
        "output" => "ok"
      }

      payload = %{
        "model" => "gpt-fixture-text",
        "previous_response_id" => "resp_fixture_heavy",
        "input" => references ++ [tool_result]
      }

      assert {:ok, validated} = Responses.validate(payload)
      assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

      assert coerced == Map.take(validated, Map.keys(coerced))
      assert Enum.take(coerced["input"], 200) == references

      assert List.last(coerced["input"]) == %{
               "type" => "function_call_output",
               "call_id" => "call_fixture_heavy",
               "output" => "ok"
             }
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
  test "public adapters reject explicit types outside the public vocabulary" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [flat_function_tool("future_type_fixture", %{"type" => "future-type"})]
    }

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.parameters.type"
            }} = Responses.coerce(response_payload)

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [function_tool("future_chat_type_fixture", %{"type" => "future-type"})]
    }

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.parameters.type"
            }} = Chat.coerce(chat_payload)
  end

  @tag :responses_coercion
  test "direct Responses threads repaired nested strict schemas through validation and coercion" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [flat_function_tool("repair_fixture", repairable_nested_parameters())]
    }

    assert {:ok, validated} = Responses.validate(payload)
    assert {:ok, result} = Responses.coerce(payload)

    for repaired <- [validated, result.payload] do
      assert get_in(repaired, [
               "tools",
               Access.at(0),
               "parameters",
               "properties",
               "config",
               "type"
             ]) ==
               "object"

      assert get_in(repaired, [
               "tools",
               Access.at(0),
               "parameters",
               "properties",
               "config",
               "properties",
               "entries",
               "type"
             ]) == "array"

      assert get_in(repaired, [
               "tools",
               Access.at(0),
               "parameters",
               "properties",
               "config",
               "properties",
               "entries",
               "items",
               "type"
             ]) == "object"
    end

    refute get_in(payload, ["tools", Access.at(0), "parameters", "properties", "config"])
           |> Map.has_key?("type")
  end

  @tag :responses_coercion
  test "Chat validates repairable strict schemas without repairing them" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [function_tool("chat_no_repair_fixture", repairable_nested_parameters())]
    }

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.parameters.properties.config.type"
            }} = Chat.validate(payload)

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.parameters.properties.config.type"
            }} = Chat.coerce(payload)

    refute get_in(payload, [
             "tools",
             Access.at(0),
             "function",
             "parameters",
             "properties",
             "config"
           ])
           |> Map.has_key?("type")
  end

  @tag :responses_coercion
  test "Responses and Chat do not repair strict structured output schemas" do
    missing_type_schema = repairable_nested_parameters()

    responses_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "text" => %{"format" => strict_text_format(missing_type_schema)}
    }

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "fixture_schema",
          "strict" => true,
          "schema" => missing_type_schema
        }
      }
    }

    assert {:error,
            %{
              code: "invalid_json_schema",
              param: "text.format.schema.properties.config.type"
            }} = Responses.coerce(responses_payload)

    assert {:error,
            %{
              code: "invalid_json_schema",
              param: "text.format.schema.properties.config.type"
            }} = Chat.coerce(chat_payload)

    refute get_in(missing_type_schema, ["properties", "config"]) |> Map.has_key?("type")
  end

  @tag :responses_coercion
  test "Responses and Chat reject invalid explicit structured output types" do
    invalid_schema =
      repairable_nested_parameters()
      |> put_in(["properties", "config", "type"], "future-type")

    responses_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "text" => %{"format" => strict_text_format(invalid_schema)}
    }

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "fixture_schema",
          "strict" => true,
          "schema" => invalid_schema
        }
      }
    }

    for result <- [Responses.coerce(responses_payload), Chat.coerce(chat_payload)] do
      assert {:error,
              %{
                code: "invalid_json_schema",
                param: "text.format.schema.properties.config.type"
              }} = result
    end
  end

  @tag :responses_coercion
  test "Chat surface policy does not leak into request options" do
    assert {:ok, result} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "synthetic input"}]
             })

    refute Map.has_key?(result.request_options.extra, :surface)
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

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.parameters.properties.nested.properties.ok"
            }} =
             Responses.coerce(payload)
  end

  describe "issue 241 direct Responses custom tool admission" do
    test "existing function tools and named choices remain semantically unchanged" do
      function_tool =
        flat_function_tool(
          "lookup_function_fixture",
          %{
            "type" => "object",
            "properties" => %{}
          },
          nil
        )

      tool_choice = %{"type" => "function", "name" => "lookup_function_fixture"}

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "tools" => [function_tool],
                 "tool_choice" => tool_choice
               })

      assert result.payload["tools"] == [function_tool]
      assert result.payload["tool_choice"] == tool_choice
    end

    test "namespace function children preserve exact containers and function choices" do
      Enum.each(["functions", "fixture_namespace"], fn namespace_name ->
        namespace_tool = %{
          "type" => "namespace",
          "name" => namespace_name,
          "description" => "Synthetic namespace tools",
          "tools" => [
            flat_function_tool(
              "lookup_#{namespace_name}",
              %{"type" => "object", "properties" => %{}},
              nil
            )
          ]
        }

        tool_choice = %{"type" => "function", "name" => "lookup_#{namespace_name}"}

        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [namespace_tool],
                   "tool_choice" => tool_choice
                 })

        assert result.payload["tools"] == [namespace_tool]
        assert result.payload["tool_choice"] == tool_choice
      end)
    end

    test "namespace custom children preserve exact mixed declarations and custom choices" do
      Enum.each(["functions", "fixture_namespace"], fn namespace_name ->
        custom_tool = %{
          "type" => "custom",
          "name" => "Custom_#{namespace_name}_Fixture",
          "description" => "Synthetic custom namespace fixture",
          "allowed_callers" => ["direct", "programmatic"],
          "format" => %{
            "type" => "grammar",
            "definition" => "start: TOKEN\nTOKEN: /[a-z]+/\n",
            "syntax" => "lark"
          }
        }

        namespace_tool = %{
          "type" => "namespace",
          "name" => namespace_name,
          "description" => "Synthetic namespace tools",
          "tools" => [
            flat_function_tool(
              "lookup_#{namespace_name}",
              %{"type" => "object", "properties" => %{}},
              nil
            ),
            custom_tool
          ]
        }

        tool_choice = %{"type" => "custom", "name" => custom_tool["name"]}

        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [namespace_tool],
                   "tool_choice" => tool_choice
                 })

        assert result.payload["tools"] == [namespace_tool]
        assert result.payload["tool_choice"] == tool_choice

        assert result.request_options.openai_compatibility.custom_tool_namespaces == %{
                 custom_tool["name"] => namespace_name
               }

        assert RequestOptions.openai_compatibility_metadata(result.request_options) == %{}
      end)
    end

    test "namespace custom choices retain exact case and whitespace semantics" do
      custom_tool = %{
        "type" => "custom",
        "name" => " Nested_Custom_Choice ",
        "format" => %{"type" => "text"}
      }

      namespace_tool = %{
        "type" => "namespace",
        "name" => "functions",
        "description" => "Synthetic namespace tools",
        "tools" => [custom_tool]
      }

      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [namespace_tool],
        "tool_choice" => %{"type" => "custom", "name" => custom_tool["name"]}
      }

      assert {:ok, result} = Responses.coerce(payload)
      assert result.payload["tools"] == [namespace_tool]
      assert result.payload["tool_choice"] == payload["tool_choice"]

      for choice_name <- ["nested_custom_choice", " Nested_Custom_Choice"] do
        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  message: "tool_choice references unknown custom tool",
                  param: "tool_choice"
                }} =
                 payload
                 |> put_in(["tool_choice", "name"], choice_name)
                 |> Responses.coerce()
      end
    end

    test "namespace custom children reject malformed and unsupported entries before coercion" do
      namespace_tool = fn child ->
        %{
          "type" => "namespace",
          "name" => "functions",
          "description" => "Synthetic namespace tools",
          "tools" => [child]
        }
      end

      invalid_children = [
        %{
          "type" => "custom",
          "name" => "malformed_custom_format",
          "format" => %{"type" => "grammar", "syntax" => "lark"}
        },
        %{
          "type" => "custom",
          "name" => "malformed_custom_callers",
          "allowed_callers" => ["hosted"]
        },
        %{"type" => "web_search_preview"},
        %{"type" => "web_search"},
        %{"type" => "image_generation"},
        %{"type" => "programmatic_tool_calling"},
        %{"type" => "mcp"},
        %{"type" => "tool_search"},
        %{
          "type" => "namespace",
          "name" => "nested",
          "description" => "Nested namespace",
          "tools" => [flat_function_tool("nested_lookup", %{}, nil)]
        }
      ]

      Enum.each(invalid_children, fn child ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [namespace_tool.(child)]
                 })
      end)
    end

    test "namespace custom choices reject unknown names and cross-container executable collisions" do
      nested_custom = %{"type" => "custom", "name" => "nested_custom_fixture"}

      namespace_tool = %{
        "type" => "namespace",
        "name" => "functions",
        "description" => "Synthetic namespace tools",
        "tools" => [nested_custom]
      }

      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "tool_choice references unknown custom tool",
                param: "tool_choice"
              }} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "tools" => [namespace_tool],
                 "tool_choice" => %{"type" => "custom", "name" => "missing_custom_fixture"}
               })

      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "tool names must be unique",
                param: "tools"
              }} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "tools" => [
                   %{"type" => "custom", "name" => "nested_custom_fixture"},
                   namespace_tool
                 ]
               })
    end

    test "official custom tools and typed named choices survive coercion unchanged" do
      cases = [
        {"omitted format with empty caller list",
         %{
           "type" => "custom",
           "name" => "default_text_custom_fixture",
           "allowed_callers" => []
         }},
        {"text with omitted callers",
         %{
           "type" => "custom",
           "name" => " text_custom_fixture ",
           "description" => "  Preserve custom description whitespace  ",
           "defer_loading" => true,
           "format" => %{"type" => "text"}
         }},
        {"lark grammar with explicit null callers",
         %{
           "type" => "custom",
           "name" => "lark_custom_fixture",
           "allowed_callers" => nil,
           "defer_loading" => false,
           "format" => %{
             "type" => "grammar",
             "definition" => "  start: WORD\n  %import common.WORD\n",
             "syntax" => "lark"
           }
         }},
        {"regex grammar with caller list",
         %{
           "type" => "custom",
           "name" => "regex_custom_fixture",
           "allowed_callers" => ["programmatic", "direct", "programmatic"],
           "format" => %{
             "type" => "grammar",
             "definition" => "  ^fixture-[0-9]+$  ",
             "syntax" => "regex"
           }
         }}
      ]

      Enum.each(cases, fn {_label, custom_tool} ->
        tool_choice = %{"type" => "custom", "name" => custom_tool["name"]}

        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [custom_tool],
                   "tool_choice" => tool_choice
                 })

        assert result.payload["tools"] == [custom_tool]
        assert result.payload["tool_choice"] == tool_choice

        assert Map.has_key?(get_in(result.payload, ["tools", Access.at(0)]), "allowed_callers") ==
                 Map.has_key?(custom_tool, "allowed_callers")
      end)
    end

    test "invalid custom tool shapes fail closed before coercion" do
      invalid_tools = [
        {"missing name", %{"type" => "custom"}},
        {"blank name", %{"type" => "custom", "name" => "   "}},
        {"non-string name", %{"type" => "custom", "name" => true}},
        {"non-string description",
         %{"type" => "custom", "name" => "custom_fixture", "description" => false}},
        {"non-boolean defer_loading",
         %{"type" => "custom", "name" => "custom_fixture", "defer_loading" => "true"}},
        {"null defer_loading",
         %{"type" => "custom", "name" => "custom_fixture", "defer_loading" => nil}},
        {"scalar allowed_callers",
         %{"type" => "custom", "name" => "custom_fixture", "allowed_callers" => "direct"}},
        {"boolean allowed_callers",
         %{"type" => "custom", "name" => "custom_fixture", "allowed_callers" => true}},
        {"invalid caller token",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "allowed_callers" => ["direct", "unknown"]
         }},
        {"invalid caller member type",
         %{"type" => "custom", "name" => "custom_fixture", "allowed_callers" => [false]}},
        {"null format", %{"type" => "custom", "name" => "custom_fixture", "format" => nil}},
        {"boolean format", %{"type" => "custom", "name" => "custom_fixture", "format" => true}},
        {"text format with extra key",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{"type" => "text", "definition" => "fixture"}
         }},
        {"grammar missing definition",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{"type" => "grammar", "syntax" => "lark"}
         }},
        {"grammar blank definition",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{"type" => "grammar", "definition" => "  ", "syntax" => "regex"}
         }},
        {"grammar non-string definition",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{"type" => "grammar", "definition" => false, "syntax" => "regex"}
         }},
        {"grammar missing syntax",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{"type" => "grammar", "definition" => "fixture"}
         }},
        {"grammar unknown syntax",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{
             "type" => "grammar",
             "definition" => "fixture",
             "syntax" => "peg"
           }
         }},
        {"grammar with extra key",
         %{
           "type" => "custom",
           "name" => "custom_fixture",
           "format" => %{
             "type" => "grammar",
             "definition" => "fixture",
             "syntax" => "lark",
             "extra" => true
           }
         }},
        {"unknown custom field",
         %{"type" => "custom", "name" => "custom_fixture", "parameters" => %{}}}
      ]

      Enum.each(invalid_tools, fn {_label, custom_tool} ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [custom_tool]
                 })
      end)
    end

    test "typed custom choices use exact names from declared custom tools" do
      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [
          %{"type" => "custom", "name" => "Custom_Choice_Fixture"},
          flat_function_tool("function_choice_fixture", %{}, nil)
        ]
      }

      invalid_choices = [
        {"missing custom choice name", %{"type" => "custom"}},
        {"blank custom choice name", %{"type" => "custom", "name" => "   "}},
        {"non-string custom choice name", %{"type" => "custom", "name" => true}},
        {"unknown custom choice", %{"type" => "custom", "name" => "missing_fixture"}},
        {"case-mismatched custom choice",
         %{"type" => "custom", "name" => "custom_choice_fixture"}},
        {"whitespace-mismatched custom choice",
         %{"type" => "custom", "name" => " Custom_Choice_Fixture "}},
        {"function name used as custom choice",
         %{"type" => "custom", "name" => "function_choice_fixture"}},
        {"custom choice with extra key",
         %{"type" => "custom", "name" => "Custom_Choice_Fixture", "extra" => true}},
        {"custom name used as function choice",
         %{"type" => "function", "name" => "Custom_Choice_Fixture"}}
      ]

      Enum.each(invalid_choices, fn {_label, choice} ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tool_choice"}} =
                 payload
                 |> Map.put("tool_choice", choice)
                 |> Responses.coerce()
      end)
    end

    test "invalid custom tools never produce a transformed dispatch payload" do
      result =
        Responses.coerce(
          %{
            "model" => "gpt-fixture-text",
            "input" => "synthetic input",
            "tools" => [
              %{
                "type" => "custom",
                "name" => "custom_sentinel_fixture",
                "format" => %{"type" => "text", "unexpected" => true}
              }
            ]
          },
          request_id: "req_custom_rejection_sentinel"
        )

      assert {:error, reason} = result
      assert reason.code == "invalid_request"
      assert reason.param == "tools"
      refute Map.has_key?(reason, :payload)
      refute match?({:ok, %{payload: _payload}}, result)
    end

    test "executable tools and namespace containers reject exact name collisions before choice lookup" do
      function = fn name -> flat_function_tool(name, %{}, nil) end
      custom = fn name -> %{"type" => "custom", "name" => name} end

      namespace = fn container_name, child_names ->
        %{
          "type" => "namespace",
          "name" => container_name,
          "description" => "Synthetic namespace tools",
          "tools" => Enum.map(child_names, function)
        }
      end

      collision_cases = [
        {"duplicate top-level functions", [function.("shared"), function.("shared")]},
        {"duplicate custom tools", [custom.("shared"), custom.("shared")]},
        {"duplicate namespace containers",
         [namespace.("shared_namespace", ["first"]), namespace.("shared_namespace", ["second"])]},
        {"duplicate children in one namespace",
         [namespace.("first_namespace", ["shared", "shared"])]},
        {"duplicate children across namespaces",
         [namespace.("first_namespace", ["shared"]), namespace.("second_namespace", ["shared"])]},
        {"function and custom", [function.("shared"), custom.("shared")]},
        {"function and namespace child",
         [function.("shared"), namespace.("fixture_namespace", ["shared"])]},
        {"custom and namespace child",
         [custom.("shared"), namespace.("fixture_namespace", ["shared"])]}
      ]

      Enum.each(collision_cases, fn {_label, tools} ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => tools,
                   "tool_choice" => %{"type" => "function", "name" => "missing_fixture"}
                 })
      end)
    end

    test "exact executable names remain case and whitespace sensitive for collision and choice resolution" do
      tools = [
        flat_function_tool("lookup", %{}, nil),
        flat_function_tool("Lookup", %{}, nil),
        %{"type" => "custom", "name" => " lookup "}
      ]

      choices = [
        %{"type" => "function", "name" => "lookup"},
        %{"type" => "function", "name" => "Lookup"},
        %{"type" => "custom", "name" => " lookup "}
      ]

      Enum.each(choices, fn choice ->
        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => tools,
                   "tool_choice" => choice
                 })

        assert Enum.map(result.payload["tools"], & &1["name"]) ==
                 Enum.map(tools, & &1["name"])

        assert result.payload["tool_choice"] == choice
      end)
    end
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

    test "Responses names both supported namespace child types in validation errors" do
      Enum.each([[], [%{"type" => "web_search_preview"}]], fn nested_tools ->
        assert {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  param: "tools",
                  message: "namespace tool requires function or custom tools"
                }} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [
                     %{
                       "type" => "namespace",
                       "name" => "fixture",
                       "description" => "Synthetic",
                       "tools" => nested_tools
                     }
                   ]
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

    test "Chat translates official custom definitions and named choices" do
      custom_tool = %{
        "type" => "custom",
        "custom" => %{
          "name" => "custom_fixture",
          "description" => "Processes free-form fixture input",
          "format" => %{"type" => "text"}
        }
      }

      custom_choice = %{
        "type" => "custom",
        "custom" => %{"name" => "custom_fixture"}
      }

      function_parameters = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }

      payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic input"}],
        "tools" => [function_tool("lookup_fixture", function_parameters, true), custom_tool],
        "tool_choice" => custom_choice
      }

      assert {:ok, result} = Chat.coerce(payload)

      assert result.payload["tools"] == [
               flat_function_tool("lookup_fixture", function_parameters, true),
               %{
                 "type" => "custom",
                 "name" => "custom_fixture",
                 "description" => "Processes free-form fixture input",
                 "format" => %{"type" => "text"}
               }
             ]

      assert result.payload["tool_choice"] == %{
               "type" => "custom",
               "name" => "custom_fixture"
             }
    end

    test "Chat rejects malformed custom definitions and named choices" do
      base_payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic input"}]
      }

      valid_custom_tool = %{
        "type" => "custom",
        "custom" => %{"name" => "custom_fixture"}
      }

      invalid_cases = [
        {Map.put(base_payload, "tools", [%{"type" => "custom", "name" => "custom_fixture"}]),
         "tools"},
        {Map.put(base_payload, "tools", [%{"type" => "custom", "custom" => %{}}]), "tools"},
        {Map.put(base_payload, "tools", [
           %{
             "type" => "custom",
             "custom" => %{"name" => "custom_fixture", "unsupported" => true}
           }
         ]), "tools"},
        {base_payload
         |> Map.put("tools", [valid_custom_tool])
         |> Map.put("tool_choice", %{"type" => "custom", "name" => "custom_fixture"}),
         "tool_choice"},
        {base_payload
         |> Map.put("tools", [valid_custom_tool])
         |> Map.put("tool_choice", %{
           "type" => "custom",
           "custom" => %{"name" => "custom_fixture"},
           "unsupported" => true
         }), "tool_choice"},
        {base_payload
         |> Map.put("tools", [valid_custom_tool])
         |> Map.put("tool_choice", %{
           "type" => "custom",
           "custom" => %{"name" => "missing_fixture"}
         }), "tool_choice"}
      ]

      Enum.each(invalid_cases, fn {payload, expected_param} ->
        assert {:error, %{status: 400, code: "invalid_request", param: ^expected_param}} =
                 Chat.coerce(payload)
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
          flat_function_tool(
            "lookup_fixture",
            %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{},
              "required" => []
            }
          )
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

    test "Responses accepts only the exact programmatic hosted tool and tool choice" do
      hosted_tool = %{"type" => "programmatic_tool_calling"}

      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [hosted_tool],
        "tool_choice" => hosted_tool
      }

      assert {:ok, result} = Responses.coerce(payload)
      assert result.payload["tools"] == [hosted_tool]
      assert result.payload["tool_choice"] == hosted_tool

      for invalid_tool <- [
            %{"type" => "programmatic_tool_calling", "unexpected" => true},
            %{"type" => "programmatic_tool_calling", "name" => "program"}
          ] do
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 payload
                 |> Map.put("tools", [invalid_tool])
                 |> Responses.coerce()
      end

      for invalid_choice <- [
            %{"type" => "programmatic_tool_calling", "unexpected" => true},
            %{"type" => "programmatic_tool_calling", "name" => "program"}
          ] do
        assert {:error, %{status: 400, code: "invalid_request", param: "tool_choice"}} =
                 payload
                 |> Map.put("tool_choice", invalid_choice)
                 |> Responses.coerce()
      end
    end

    test "Responses preserves flat and namespace function options through non-strict lowering" do
      output_schema = %{
        "x-opaque-keyword" => [nil, true, 7, %{"nested" => ["value"]}],
        "$defs" => %{"opaque" => %{"unknown" => "preserved"}}
      }

      flat_tool =
        flat_function_tool("lookup_flat_fixture", non_strict_tool_schema(), false)
        |> Map.merge(%{
          "description" => "Lookup flat fixture",
          "defer_loading" => true,
          "allowed_callers" => ["direct", "programmatic", "programmatic"],
          "output_schema" => output_schema
        })

      namespace_function =
        flat_function_tool("lookup_namespaced_fixture", non_strict_tool_schema(), false)
        |> Map.merge(%{
          "description" => "Lookup namespaced fixture",
          "defer_loading" => false,
          "allowed_callers" => [],
          "output_schema" => output_schema
        })

      namespace_tool = %{
        "type" => "namespace",
        "name" => "fixture_namespace",
        "description" => "Synthetic namespace tools",
        "tools" => [namespace_function]
      }

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic input",
                 "tools" => [flat_tool, namespace_tool]
               })

      coerced_flat = get_in(result.payload, ["tools", Access.at(0)])
      coerced_namespaced = get_in(result.payload, ["tools", Access.at(1), "tools", Access.at(0)])

      assert coerced_flat["parameters"] == lowered_tool_schema()
      assert coerced_namespaced["parameters"] == lowered_tool_schema()

      assert Map.drop(coerced_flat, ["parameters"]) == Map.drop(flat_tool, ["parameters"])

      assert Map.drop(coerced_namespaced, ["parameters"]) ==
               Map.drop(namespace_function, ["parameters"])

      assert coerced_flat["allowed_callers"] == ["direct", "programmatic", "programmatic"]
      assert coerced_namespaced["allowed_callers"] == []
      assert coerced_flat["output_schema"] == output_schema
      assert coerced_namespaced["output_schema"] == output_schema
    end

    test "Responses rejects unknown and malformed flat and namespace function options" do
      invalid_options = [
        %{"strict" => "true"},
        %{"defer_loading" => "true"},
        %{"allowed_callers" => "direct"},
        %{"allowed_callers" => ["direct", "unknown"]},
        %{"allowed_callers" => [nil]},
        %{"allowed_callers" => nil},
        %{"output_schema" => []},
        %{"output_schema" => "object"},
        %{"output_schema" => 1},
        %{"output_schema" => true},
        %{"output_schema" => nil},
        %{"unexpected" => true}
      ]

      Enum.each(invalid_options, fn invalid_option ->
        function_tool =
          flat_function_tool("lookup_fixture", %{}, nil)
          |> Map.merge(invalid_option)

        namespace_tool = %{
          "type" => "namespace",
          "name" => "fixture_namespace",
          "description" => "Synthetic namespace tools",
          "tools" => [function_tool]
        }

        for tool <- [function_tool, namespace_tool] do
          assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                   Responses.coerce(%{
                     "model" => "gpt-fixture-text",
                     "input" => "synthetic input",
                     "tools" => [tool]
                   })
        end
      end)
    end

    test "Responses keeps object tool choices exact and namespace names ineligible" do
      function_tool = flat_function_tool("lookup_fixture", %{}, nil)

      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [
          function_tool,
          %{
            "type" => "namespace",
            "name" => "fixture_namespace",
            "description" => "Synthetic namespace tools",
            "tools" => [flat_function_tool("nested_fixture", %{}, nil)]
          }
        ]
      }

      for invalid_choice <- [
            %{"type" => "function", "name" => "lookup_fixture", "unexpected" => true},
            %{"type" => "image_generation", "unexpected" => true},
            %{"type" => "function", "name" => "fixture_namespace"}
          ] do
        assert {:error, %{status: 400, code: "invalid_request", param: "tool_choice"}} =
                 payload
                 |> Map.put("tool_choice", invalid_choice)
                 |> Responses.coerce()
      end
    end

    test "namespace strict function options retain the nested parameter error path" do
      payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [
          %{
            "type" => "namespace",
            "name" => "fixture_namespace",
            "description" => "Synthetic namespace tools",
            "tools" => [
              flat_function_tool("lookup_namespaced_fixture", non_strict_tool_schema(), true)
              |> Map.merge(%{
                "allowed_callers" => ["programmatic"],
                "output_schema" => %{"unknown" => [nil, true]}
              })
            ]
          }
        ]
      }

      assert {:error,
              %{
                code: "invalid_function_parameters",
                param: "tools.0.tools.0.parameters.properties.nested.properties.ok"
              }} = Responses.coerce(payload)
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
    test "Responses retains web search access flag validation" do
      accepted_tools = [
        %{"type" => "web_search", "external_web_access" => false},
        %{
          "type" => "web_search",
          "external_web_access" => true,
          "index_gated_web_access" => true
        }
      ]

      Enum.each(accepted_tools, fn tool ->
        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })

        assert result.payload["tools"] == [tool]
      end)

      for tool <- [
            %{"type" => "web_search", "external_web_access" => "true"},
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
            %{"type" => "web_search", "index_gated_web_access" => true}
          ] do
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })
      end
    end

    test "Responses accepts bounded web search domain filters without rewriting values" do
      original_allowed_domains = [" Example.COM ", "example.com", "Example.COM"]
      original_blocked_domains = [" blocked.example ", "blocked.example", "blocked.example"]

      accepted_tools = [
        %{"type" => "web_search"},
        %{
          "type" => "web_search",
          "filters" => %{"allowed_domains" => original_allowed_domains}
        },
        %{
          "type" => "web_search",
          "filters" => %{"blocked_domains" => original_blocked_domains}
        },
        %{
          "type" => "web_search",
          "external_web_access" => true,
          "filters" => %{
            "allowed_domains" => original_allowed_domains,
            "blocked_domains" => original_blocked_domains
          }
        },
        %{
          "type" => "web_search",
          "filters" => %{
            "allowed_domains" => Enum.map(1..100, &"allowed-#{&1}.example"),
            "blocked_domains" => Enum.map(1..100, &"blocked-#{&1}.example")
          }
        }
      ]

      Enum.each(accepted_tools, fn tool ->
        assert {:ok, result} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [tool]
                 })

        assert result.payload["tools"] == [tool]
      end)
    end

    test "Responses rejects malformed web search domain filters" do
      invalid_filters = [
        nil,
        [],
        "example.com",
        %{},
        %{"unknown" => ["example.com"]},
        %{"allowed_domains" => []},
        %{"blocked_domains" => []},
        %{"allowed_domains" => ["example.com"], "blocked_domains" => []},
        %{"allowed_domains" => [], "blocked_domains" => ["example.com"]},
        %{"allowed_domains" => "example.com"},
        %{"blocked_domains" => "example.com"},
        %{"allowed_domains" => [123]},
        %{"blocked_domains" => [nil]},
        %{"allowed_domains" => [""]},
        %{"blocked_domains" => [" \t\n"]},
        %{"allowed_domains" => ["http://example.com"]},
        %{"allowed_domains" => [" HTTP://example.com"]},
        %{"blocked_domains" => ["https://example.com"]},
        %{"blocked_domains" => ["\tHtTpS://example.com"]},
        %{"allowed_domains" => Enum.map(1..101, &"allowed-#{&1}.example")},
        %{"blocked_domains" => Enum.map(1..101, &"blocked-#{&1}.example")}
      ]

      Enum.each(invalid_filters, fn filters ->
        assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
                 Responses.coerce(%{
                   "model" => "gpt-fixture-text",
                   "input" => "synthetic input",
                   "tools" => [%{"type" => "web_search", "filters" => filters}]
                 })
      end)
    end

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

    @tag :hosted_shell_history
    test "Responses preserves unsupported shell and remote MCP request boundaries" do
      cases = [
        {%{
           "model" => "gpt-fixture-text",
           "input" => [%{"type" => "local_shell_call", "call_id" => "call_fixture"}]
         }, "input item shape is not translatable", "input"},
        {%{
           "model" => "gpt-fixture-text",
           "input" => "synthetic input",
           "tools" => [%{"type" => "shell"}]
         }, "tool shape is not translatable", "tools"},
        {%{
           "model" => "gpt-fixture-text",
           "input" => [%{"type" => "mcp_call", "call_id" => "call_fixture"}]
         }, "input item shape is not translatable", "input"}
      ]

      Enum.each(cases, fn {payload, message, param} ->
        assert {:error, reason} = Responses.coerce(payload)

        assert reason == %{
                 status: 400,
                 code: "invalid_request",
                 message: message,
                 param: param
               }
      end)
    end

    @tag :hosted_shell_history
    test "Responses preserves hosted shell request history value-for-value" do
      input = [
        %{
          "type" => "shell_call",
          "call_id" => "call_fixture",
          "action" => %{"commands" => ["synthetic command"]}
        },
        %{
          "type" => "shell_call_output",
          "call_id" => "call_fixture",
          "output" => [
            %{
              "stdout" => "synthetic output",
              "stderr" => "",
              "outcome" => %{"type" => "exit", "exit_code" => 0}
            }
          ]
        }
      ]

      assert {:ok, %{payload: %{"input" => ^input}}} =
               Responses.coerce(%{"model" => "gpt-fixture-text", "input" => input})
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
          "content" => [
            %{"type" => "reasoning_text", "text" => "synthetic reasoning replay"}
          ],
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

    assert Enum.at(result.payload["input"], 0)["content"] == [
             %{"type" => "reasoning_text", "text" => "synthetic reasoning replay"}
           ]
  end

  @tag :responses_coercion
  test "Responses preserves Open Responses reasoning_text items in tool continuations" do
    payload = %{
      "model" => "gpt-fixture-text",
      "previous_response_id" => "resp_fixture_reasoning_text",
      "input" => [
        %{
          "type" => "reasoning",
          "summary" => [],
          "content" => [
            %{"type" => "reasoning_text", "text" => "synthetic reasoning text"}
          ]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_fixture_reasoning_text",
          "name" => "lookup_fixture",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_fixture_reasoning_text",
          "output" => "synthetic tool output"
        }
      ]
    }

    assert {:ok, %{payload: coerced}} = Responses.coerce(payload)

    assert coerced["input"] == [
             %{
               "type" => "reasoning",
               "summary" => [],
               "content" => [
                 %{"type" => "reasoning_text", "text" => "synthetic reasoning text"}
               ]
             },
             %{
               "type" => "function_call",
               "call_id" => "call_fixture_reasoning_text",
               "name" => "lookup_fixture",
               "arguments" => "{}"
             },
             %{
               "type" => "function_call_output",
               "call_id" => "call_fixture_reasoning_text",
               "output" => "synthetic tool output"
             }
           ]
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

  test "Responses preserves allowed direct passthrough siblings and nested executed tool calls" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    passthrough = %{
      "turn_id" => "turn_reservation_fixture",
      "synthetic_sibling" => "sibling_reservation_fixture",
      "nested" => %{"executed_tool_calls" => %{"synthetic" => true}}
    }

    inputs = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_native_reservation_fixture",
        "output" => "synthetic native output",
        passthrough_key => passthrough
      },
      %{
        "role" => "assistant",
        passthrough_key => passthrough,
        "tool_calls" => [
          %{
            "id" => "call_translated_assistant_reservation_fixture",
            "type" => "function",
            "function" => %{"name" => "lookup_fixture", "arguments" => "{}"}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "call_translated_tool_reservation_fixture",
        "content" => "synthetic translated output",
        passthrough_key => passthrough
      },
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "synthetic message"}],
        passthrough_key => passthrough
      },
      %{
        "type" => "input_file",
        "file_id" => "file_reservation_fixture",
        passthrough_key => passthrough
      },
      %{
        "call_id" => "call_generic_reservation_fixture",
        "result" => %{"ok" => true},
        passthrough_key => passthrough
      }
    ]

    assert {:ok, result} = Responses.coerce(responses_payload(inputs))

    assert Enum.map(result.payload["input"], &Map.fetch!(&1, passthrough_key)) ==
             List.duplicate(passthrough, 6)
  end

  test "Responses rejects reserved executed tool calls on native function call outputs" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    for executed_tool_calls <- [nil, %{"synthetic" => true}] do
      input = %{
        "type" => "function_call_output",
        "call_id" => "call_native_reserved_fixture",
        "output" => "synthetic native output",
        passthrough_key => %{"executed_tool_calls" => executed_tool_calls}
      }

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(responses_payload([input]))
    end
  end

  test "Responses rejects reserved executed tool calls on translated assistant tool calls" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    for executed_tool_calls <- [nil, %{"synthetic" => true}] do
      input = %{
        "role" => "assistant",
        passthrough_key => %{"executed_tool_calls" => executed_tool_calls},
        "tool_calls" => [
          %{
            "id" => "call_translated_assistant_reserved_fixture",
            "type" => "function",
            "function" => %{"name" => "lookup_fixture", "arguments" => "{}"}
          }
        ]
      }

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(responses_payload([input]))
    end
  end

  test "Responses rejects reserved executed tool calls on translated tool outputs" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    for executed_tool_calls <- [nil, %{"synthetic" => true}] do
      input = %{
        "role" => "tool",
        "tool_call_id" => "call_translated_tool_reserved_fixture",
        "content" => "synthetic translated output",
        passthrough_key => %{"executed_tool_calls" => executed_tool_calls}
      }

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(responses_payload([input]))
    end
  end

  test "Responses rejects reserved executed tool calls on ordinary messages" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    for executed_tool_calls <- [nil, %{"synthetic" => true}] do
      input = %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "synthetic message"}],
        passthrough_key => %{"executed_tool_calls" => executed_tool_calls}
      }

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(responses_payload([input]))
    end
  end

  test "Responses rejects reserved executed tool calls on top-level input files" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    for executed_tool_calls <- [nil, %{"synthetic" => true}] do
      input = %{
        "type" => "input_file",
        "file_id" => "file_reserved_fixture",
        passthrough_key => %{"executed_tool_calls" => executed_tool_calls}
      }

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(responses_payload([input]))
    end
  end

  test "Responses rejects reserved executed tool calls on generic tool result shapes" do
    passthrough_key = "internal_chat_message_metadata_passthrough"

    for executed_tool_calls <- [nil, %{"synthetic" => true}] do
      input = %{
        "call_id" => "call_generic_reserved_fixture",
        "result" => %{"ok" => true},
        passthrough_key => %{"executed_tool_calls" => executed_tool_calls}
      }

      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(responses_payload([input]))
    end
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
      for effort <- [
            "none",
            "minimal",
            "low",
            "medium",
            "high",
            "xhigh",
            "max",
            "ultra",
            "focused"
          ],
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

      for {tier, canonical} <- [
            {"auto", "auto"},
            {"default", "default"},
            {"flex", "flex"},
            {"priority", "priority"},
            {"scale", "scale"},
            {" ultrafast ", "ultrafast"},
            {"ULTRAFAST", "ultrafast"},
            {"fast", "priority"}
          ] do
        payload = %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic input",
          "service_tier" => tier
        }

        assert {:ok, result} = Responses.coerce(payload)
        assert result.payload["service_tier"] == canonical
      end
    end

    test "Responses rejects unsupported service_tier variants deterministically" do
      for tier <- ["unsupported", "ultra-fast", "", nil, 123, []] do
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

  describe "Responses input audio backport" do
    @tag :input_audio_backport
    test "Responses canonicalizes exactly the five supported public audio formats" do
      source = "format audio"

      formats = [
        {"wav", "audio/wav"},
        {"mp3", "audio/mpeg"},
        {"m4a", "audio/mp4"},
        {"webm", "audio/webm"},
        {"ogg", "audio/ogg"}
      ]

      for {format, mime} <- formats do
        assert_responses_audio_summary(
          responses_audio_payload(format, Base.encode64(source)),
          expected_audio_summary(mime, source),
          "expected #{format} input_audio to use its canonical backend MIME"
        )
      end
    end

    @tag :input_audio_backport
    test "Responses accepts ASCII Base64 whitespace and emits canonical Base64" do
      source = "whitespace audio"
      encoded = Base.encode64(source)

      assert_responses_audio_summary(
        responses_audio_payload("wav", with_ascii_whitespace(encoded)),
        expected_audio_summary("audio/wav", source),
        "expected whitespace-bearing input_audio to be canonicalized"
      )
    end

    @tag :input_audio_backport
    test "Responses preserves sanitized malformed and empty Base64 errors" do
      expected = adapter_audio_error("input_audio data must be base64")

      for data <- ["not base64", ""] do
        assert_adapter_audio_error!(
          Responses.coerce(responses_audio_payload("wav", data)),
          expected
        )
      end
    end

    @tag :input_audio_backport
    test "Responses rejects unsupported labels and non-exact public audio shapes" do
      encoded = Base.encode64("shape audio")
      valid_part = input_audio_part("wav", encoded)

      invalid_parts = [
        {"FLAC", input_audio_part("flac", encoded)},
        {"uppercase", input_audio_part("WAV", encoded)},
        {"MIME label", input_audio_part("audio/wav", encoded)},
        {"outer extra key", Map.put(valid_part, "extra", true)},
        {"nested extra key", put_in(valid_part, ["input_audio", "extra"], true)}
      ]

      expected = adapter_audio_error("message content part is not translatable")

      for {_label, part} <- invalid_parts do
        assert_adapter_audio_error!(
          Responses.coerce(responses_payload([user_audio_message(part)])),
          expected
        )
      end
    end

    @tag :input_audio_backport
    test "Responses rejects audio in function and custom tool outputs" do
      part = input_audio_part("wav", Base.encode64("tool output audio"))

      inputs = [
        {"function tool output",
         %{
           "type" => "function_call_output",
           "call_id" => "call_function_audio",
           "output" => [part]
         }},
        {"custom tool output",
         %{
           "type" => "custom_tool_call_output",
           "call_id" => "call_custom_audio",
           "name" => "custom_audio",
           "output" => [part]
         }}
      ]

      expected = adapter_audio_error("message content part is not translatable")

      for {_label, input} <- inputs do
        assert_adapter_audio_error!(
          Responses.coerce(responses_payload([input])),
          expected
        )
      end
    end

    @tag :input_audio_backport
    @tag timeout: 120_000
    test "Responses accepts exactly 50 MiB when only ASCII whitespace exceeds the encoded limit" do
      source = :binary.copy(<<0>>, 52_428_800)
      encoded = Base.encode64(source)
      encoded_with_whitespace = with_ascii_whitespace(encoded)

      assert byte_size(source) == 52_428_800
      assert byte_size(encoded) == 69_905_068
      assert byte_size(encoded_with_whitespace) == 69_905_072

      assert_responses_audio_summary(
        responses_audio_payload("wav", encoded_with_whitespace),
        expected_audio_summary("audio/wav", source),
        "expected whitespace-only encoded excess at exactly 50 MiB to be accepted"
      )
    end

    @tag :input_audio_backport
    @tag timeout: 120_000
    test "Responses rejects decoded audio one byte above 50 MiB" do
      source = :binary.copy(<<0>>, 52_428_801)

      assert_adapter_audio_error!(
        Responses.coerce(responses_audio_payload("wav", Base.encode64(source))),
        adapter_audio_error("input_audio data must be 50 MiB or smaller")
      )
    end

    @tag :input_audio_backport
    @tag timeout: 120_000
    test "Responses rejects an overlong non-whitespace Base64 input before decoding" do
      encoded = :binary.copy("A", 69_905_069)

      assert_adapter_audio_error!(
        Responses.coerce(responses_audio_payload("wav", encoded)),
        adapter_audio_error("input_audio data must be 50 MiB or smaller")
      )
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

    test "Responses data URL validation preserves case whitespace and malformed-base64 semantics" do
      valid_cases = [
        "data:image/png;base64,YWJj",
        "data:IMAGE/PNG;BASE64,YWJj",
        "data:image/png;base64,Y W\nJj"
      ]

      invalid_cases = [
        "DATA:image/png;base64,YWJj",
        "data:image/png;base64,",
        "data:image/png;base64,YW!j",
        "data:image/png;base64,YWJj!A==",
        "data:text/plain;base64,YWJj"
      ]

      for image_url <- valid_cases do
        assert {:ok, _result} = Responses.coerce(image_payload(image_url))
      end

      for image_url <- invalid_cases do
        assert {:error, %{code: "unsupported_input_image_format", param: "input"}} =
                 Responses.coerce(image_payload(image_url))
      end
    end

    test "Responses rejects unsupported image/file media references deterministically" do
      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-fixture-text",
                 "input" => [
                   %{
                     "role" => "user",
                     "content" => [%{"type" => "input_image", "file_id" => "file_fixture"}]
                   }
                 ]
               })

      assert get_in(result.payload, ["input", Access.at(0), "content", Access.at(0), "file_id"]) ==
               "file_fixture"

      invalid_payloads = [
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
      audio_source = "wav fixture"
      audio_data = Base.encode64(audio_source)

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

      case safe_audio_part_summary(Enum.at(content, 2)) do
        {:ok, summary} ->
          assert summary == expected_audio_summary("audio/wav", audio_source)

        {:error, :unexpected_audio_shape} ->
          flunk("expected Chat input_audio to use the canonical backend shape")
      end
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

  defp repairable_nested_parameters do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "config" => %{
          "additionalProperties" => false,
          "properties" => %{
            "entries" => %{
              "items" => %{
                "additionalProperties" => false,
                "properties" => %{"value" => %{"type" => "string"}},
                "required" => ["value"]
              }
            }
          },
          "required" => ["entries"]
        }
      },
      "required" => ["config"]
    }
  end

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

  @tag :prompt_cache_controls
  test "Responses preserves request options and cacheable content breakpoints" do
    breakpoint = prompt_cache_breakpoint()
    options = %{"mode" => "explicit", "ttl" => "30m"}

    payload = %{
      "model" => "gpt-5.6",
      "prompt_cache_options" => options,
      "input" => [
        %{
          "role" => "system",
          "content" => [
            %{"type" => "input_text", "text" => "lift this"},
            %{
              "type" => "input_text",
              "text" => "keep this",
              "prompt_cache_breakpoint" => breakpoint
            }
          ]
        },
        %{
          "role" => "developer",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "keep developer",
              "prompt_cache_breakpoint" => breakpoint
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "question",
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "input_image",
              "image_url" => "https://example.com/user-image.png",
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "input_file",
              "filename" => "fixture.txt",
              "file_data" => "data:text/plain;base64,Zml4dHVyZQ==",
              "prompt_cache_breakpoint" => breakpoint
            }
          ]
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_function",
          "output" => [
            %{
              "type" => "input_text",
              "text" => "function text",
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "input_image",
              "image_url" => "https://example.com/image.png",
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "input_file",
              "file_url" => "https://example.com/file.txt",
              "prompt_cache_breakpoint" => breakpoint
            }
          ]
        },
        %{
          "type" => "custom_tool_call_output",
          "call_id" => "call_custom",
          "output" => [
            %{
              "type" => "input_text",
              "text" => "custom text",
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "input_file",
              "filename" => "custom.txt",
              "file_data" => "data:text/plain;base64,Y3VzdG9t",
              "prompt_cache_breakpoint" => breakpoint
            }
          ]
        }
      ]
    }

    assert {:ok, result} = Responses.coerce(payload)
    assert result.payload["prompt_cache_options"] == options
    assert result.payload["instructions"] == "lift this"
    assert [%{"role" => "developer"}, %{"role" => "developer"} | _rest] = result.payload["input"]

    assert get_in(result.payload, [
             "input",
             Access.at(0),
             "content",
             Access.at(0),
             "prompt_cache_breakpoint"
           ]) == breakpoint

    assert get_in(result.payload, [
             "input",
             Access.at(1),
             "content",
             Access.at(0),
             "prompt_cache_breakpoint"
           ]) == breakpoint

    assert result.request_options.routing.prompt_cache_key == nil
  end

  @tag :prompt_cache_controls
  test "Responses accepts every request prompt cache options variant unchanged" do
    for options <- [
          %{},
          %{"mode" => "implicit"},
          %{"ttl" => "30m"},
          %{"mode" => "explicit", "ttl" => "30m"}
        ] do
      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "gpt-5.6",
                 "input" => "fixture",
                 "prompt_cache_options" => options
               })

      assert result.payload["prompt_cache_options"] == options
      assert result.request_options.routing.prompt_cache_key == nil
    end
  end

  @tag :prompt_cache_controls
  test "Chat preserves cache options and supported marked content during conversion" do
    breakpoint = prompt_cache_breakpoint()

    payload = %{
      "model" => "gpt-5.6",
      "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"},
      "messages" => [
        %{
          "role" => "system",
          "content" => [
            %{"type" => "text", "text" => "system", "prompt_cache_breakpoint" => breakpoint}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "user", "prompt_cache_breakpoint" => breakpoint},
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "https://example.com/image.png"},
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "file",
              "file" => %{"file_id" => "file_fixture"},
              "prompt_cache_breakpoint" => breakpoint
            },
            %{
              "type" => "file",
              "file" => %{
                "filename" => "fixture.txt",
                "file_data" => "data:text/plain;base64,Zml4dHVyZQ=="
              },
              "prompt_cache_breakpoint" => breakpoint
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call_fixture",
          "content" => [
            %{"type" => "text", "text" => "tool", "prompt_cache_breakpoint" => breakpoint}
          ]
        }
      ]
    }

    assert {:ok, result} = Chat.coerce(payload)
    assert result.payload["prompt_cache_options"] == payload["prompt_cache_options"]

    assert [%{"role" => "developer"} = instruction, %{"role" => "user"} = user, tool_output] =
             result.payload["input"]

    assert get_in(instruction, ["content", Access.at(0), "prompt_cache_breakpoint"]) == breakpoint
    assert Enum.all?(user["content"], &(&1["prompt_cache_breakpoint"] == breakpoint))
    assert get_in(tool_output, ["output", Access.at(0), "prompt_cache_breakpoint"]) == breakpoint
    assert result.request_options.routing.prompt_cache_key == nil
  end

  test "Chat preserves message-part grouping around repeated special tool parts" do
    payload = %{
      "model" => "gpt-5.6",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "before"},
            %{
              "type" => "tool-call",
              "toolCallId" => "call_grouped",
              "toolName" => "lookup",
              "input" => %{"query" => "fixture"}
            },
            %{"type" => "text", "text" => "between"},
            %{"type" => "tool-result", "toolCallId" => "call_grouped", "output" => "ok"},
            %{"type" => "text", "text" => "after"}
          ]
        }
      ]
    }

    assert {:ok, result} = Chat.coerce(payload)

    assert [before, tool_call, between, tool_result, after_part] = result.payload["input"]
    assert get_in(before, ["content", Access.at(0), "text"]) == "before"
    assert tool_call["type"] == "function_call"
    assert get_in(between, ["content", Access.at(0), "text"]) == "between"
    assert tool_result["type"] == "function_call_output"
    assert get_in(after_part, ["content", Access.at(0), "text"]) == "after"
  end

  @tag :prompt_cache_controls
  test "Chat rejects marked assistant text and input audio instead of dropping breakpoints" do
    breakpoint = prompt_cache_breakpoint()

    cases = [
      {%{
         "role" => "assistant",
         "content" => [
           %{"type" => "text", "text" => "answer", "prompt_cache_breakpoint" => breakpoint}
         ]
       },
       %{
         status: 400,
         code: "invalid_request",
         message: "assistant prompt_cache_breakpoint is not translatable",
         param: "input"
       }},
      {%{
         "role" => "user",
         "content" => [
           %{
             "type" => "input_audio",
             "input_audio" => %{"data" => "Zml4dHVyZQ==", "format" => "wav"},
             "prompt_cache_breakpoint" => breakpoint
           }
         ]
       },
       %{
         status: 400,
         code: "invalid_request",
         message: "input_audio prompt_cache_breakpoint is not translatable",
         param: "input"
       }}
    ]

    for {message, expected} <- cases do
      assert {:error, ^expected} = Chat.coerce(%{"model" => "gpt-5.6", "messages" => [message]})
    end
  end

  @tag :prompt_cache_controls
  test "Chat rejects image and file parts in tool messages" do
    breakpoint = prompt_cache_breakpoint()

    for part <- [
          %{
            "type" => "image_url",
            "image_url" => "https://example.com/image.png",
            "prompt_cache_breakpoint" => breakpoint
          },
          %{
            "type" => "file",
            "file" => %{"file_id" => "file_fixture"},
            "prompt_cache_breakpoint" => breakpoint
          }
        ] do
      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "messages must contain role/content objects",
                param: "messages"
              }} =
               Chat.coerce(%{
                 "model" => "gpt-5.6",
                 "messages" => [
                   %{"role" => "tool", "tool_call_id" => "call_fixture", "content" => [part]}
                 ]
               })
    end
  end

  @tag :prompt_cache_controls
  test "prompt cache options validation returns stable deterministic errors" do
    cases = [
      {[],
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_options must be an object",
         param: "prompt_cache_options"
       }},
      {%{"zeta" => true, "alpha" => true},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_options field is not supported",
         param: "prompt_cache_options.alpha"
       }},
      {%{"mode" => nil},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_options mode is not supported",
         param: "prompt_cache_options.mode"
       }},
      {%{"mode" => "automatic"},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_options mode is not supported",
         param: "prompt_cache_options.mode"
       }},
      {%{"ttl" => nil},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_options ttl is not supported",
         param: "prompt_cache_options.ttl"
       }},
      {%{"ttl" => "1h"},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_options ttl is not supported",
         param: "prompt_cache_options.ttl"
       }}
    ]

    for {options, expected} <- cases do
      assert {:error, ^expected} =
               Responses.coerce(%{
                 "model" => "gpt-5.6",
                 "input" => "fixture",
                 "prompt_cache_options" => options
               })
    end
  end

  @tag :prompt_cache_controls
  test "prompt cache breakpoint validation returns stable deterministic errors" do
    invalid_breakpoints = [
      {"explicit",
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_breakpoint must be an explicit mode object",
         param: "input.prompt_cache_breakpoint"
       }},
      {%{},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_breakpoint must be an explicit mode object",
         param: "input.prompt_cache_breakpoint"
       }},
      {%{"mode" => "implicit"},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_breakpoint must be an explicit mode object",
         param: "input.prompt_cache_breakpoint"
       }},
      {%{"mode" => "explicit", "zeta" => true, "alpha" => true},
       %{
         status: 400,
         code: "invalid_request",
         message: "prompt_cache_breakpoint field is not supported",
         param: "input.prompt_cache_breakpoint.alpha"
       }}
    ]

    for {breakpoint, expected} <- invalid_breakpoints do
      assert {:error, ^expected} =
               Responses.coerce(%{
                 "model" => "gpt-5.6",
                 "input" => [
                   %{
                     "role" => "user",
                     "content" => [
                       %{
                         "type" => "input_text",
                         "text" => "fixture",
                         "prompt_cache_breakpoint" => breakpoint
                       }
                     ]
                   }
                 ]
               })
    end
  end

  @tag :prompt_cache_controls
  test "marked content enforces role and tool-output allowlists" do
    breakpoint = prompt_cache_breakpoint()

    disallowed_messages = [
      %{
        "role" => "system",
        "content" => [
          %{
            "type" => "input_image",
            "image_url" => "https://example.com/image.png",
            "prompt_cache_breakpoint" => breakpoint
          }
        ]
      },
      %{
        "role" => "developer",
        "content" => [
          %{
            "type" => "input_file",
            "file_url" => "https://example.com/file.txt",
            "prompt_cache_breakpoint" => breakpoint
          }
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "text",
            "text" => "direct Responses text",
            "prompt_cache_breakpoint" => breakpoint
          }
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "input_audio",
            "input_audio" => %{"data" => "Zml4dHVyZQ==", "format" => "wav"},
            "prompt_cache_breakpoint" => breakpoint
          }
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "input_file",
            "file_data" => "Zml4dHVyZQ==",
            "prompt_cache_breakpoint" => breakpoint
          }
        ]
      }
    ]

    for message <- disallowed_messages do
      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "message content part is not translatable",
                param: "input"
              }} =
               Responses.coerce(%{"model" => "gpt-5.6", "input" => [message]})
    end

    for item <- [
          %{
            "type" => "function_call_output",
            "call_id" => "call_function",
            "output" => [
              %{
                "type" => "input_audio",
                "input_audio" => %{"data" => "Zml4dHVyZQ==", "format" => "wav"},
                "prompt_cache_breakpoint" => breakpoint
              }
            ]
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_function_text",
            "output" => [
              %{
                "type" => "text",
                "text" => "direct function text",
                "prompt_cache_breakpoint" => breakpoint
              }
            ]
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_custom",
            "name" => "custom_fixture",
            "output" => [
              %{
                "type" => "input_audio",
                "input_audio" => %{"data" => "Zml4dHVyZQ==", "format" => "wav"},
                "prompt_cache_breakpoint" => breakpoint
              }
            ]
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_custom_text",
            "name" => "custom_text_fixture",
            "output" => [
              %{
                "type" => "text",
                "text" => "direct custom text",
                "prompt_cache_breakpoint" => breakpoint
              }
            ]
          }
        ] do
      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "message content part is not translatable",
                param: "input"
              }} = Responses.coerce(%{"model" => "gpt-5.6", "input" => [item]})
    end
  end

  defp prompt_cache_breakpoint, do: %{"mode" => "explicit"}

  defp prompt_cache_key_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp upload_metadata do
    %{"filename" => "fixture.txt", "content_type" => "text/plain", "bytes" => 12}
  end

  defp responses_audio_payload(format, data) do
    responses_payload([user_audio_message(input_audio_part(format, data))])
  end

  defp responses_payload(input) do
    %{
      "model" => "gpt-fixture-text",
      "input" => input
    }
  end

  defp user_audio_message(part), do: %{"role" => "user", "content" => [part]}

  defp assert_responses_audio_summary(payload, expected, failure_message) do
    case Responses.coerce(payload) do
      {:ok, result} ->
        case safe_audio_summary(result) do
          {:ok, summary} -> assert summary == expected, failure_message
          {:error, :unexpected_audio_shape} -> flunk(failure_message)
        end

      {:error, _reason} ->
        flunk(failure_message)
    end
  end

  defp safe_audio_summary(%{payload: %{"input" => [%{"content" => [part]}]}})
       when is_map(part) do
    safe_audio_part_summary(part)
  end

  defp safe_audio_summary(_result), do: {:error, :unexpected_audio_shape}

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

  defp image_payload(image_url) do
    %{
      "model" => "gpt-fixture-text",
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => image_url}]
        }
      ]
    }
  end

  defp programmatic_input_item(:program) do
    %{
      "type" => "program",
      "id" => "",
      "call_id" => "",
      "code" => "",
      "fingerprint" => ""
    }
  end

  defp programmatic_input_item(:program_output) do
    %{
      "type" => "program_output",
      "id" => "",
      "call_id" => "",
      "result" => "",
      "status" => "completed"
    }
  end

  defp programmatic_input_item(:program_output_incomplete) do
    programmatic_input_item(:program_output)
    |> Map.put("status", "incomplete")
  end

  defp programmatic_input_item(:function_call_direct_caller),
    do: programmatic_input_item(:function_call, caller: %{"type" => "direct"})

  defp programmatic_input_item(:function_call_program_caller),
    do:
      programmatic_input_item(:function_call,
        caller: %{"type" => "program", "caller_id" => "program_call_fixture"}
      )

  defp programmatic_input_item(:function_call_output_direct_caller),
    do: programmatic_input_item(:function_call_output, caller: %{"type" => "direct"})

  defp programmatic_input_item(:function_call_output_program_caller),
    do:
      programmatic_input_item(:function_call_output,
        caller: %{"type" => "program", "caller_id" => "program_call_fixture"}
      )

  defp programmatic_input_item(type, opts \\ [])

  defp programmatic_input_item(:function_call, opts) do
    %{
      "type" => "function_call",
      "id" => "function_call_item_fixture",
      "call_id" => "function_call_fixture",
      "name" => "lookup_fixture",
      "arguments" => "{}"
    }
    |> maybe_put_caller(opts)
  end

  defp programmatic_input_item(:function_call_output, opts) do
    %{
      "type" => "function_call_output",
      "id" => "function_call_output_item_fixture",
      "call_id" => "function_call_fixture",
      "output" => "synthetic tool output"
    }
    |> maybe_put_caller(opts)
  end

  defp malformed_programmatic_item_variants(item) do
    item
    |> Map.keys()
    |> Enum.map(&Map.delete(item, &1))
    |> Kernel.++([Map.put(item, "unexpected", true)])
    |> Kernel.++(
      Enum.map(item, fn {key, _value} ->
        Map.put(item, key, 1)
      end)
    )
    |> Kernel.++(malformed_programmatic_status_variants(item))
  end

  defp malformed_programmatic_status_variants(%{"type" => "program_output"} = item),
    do: [Map.put(item, "status", "unknown")]

  defp malformed_programmatic_status_variants(_item), do: []

  defp maybe_put_caller(item, opts) do
    case Keyword.fetch(opts, :caller) do
      {:ok, caller} -> Map.put(item, "caller", caller)
      :error -> item
    end
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
