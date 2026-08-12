defmodule CodexPooler.Gateway.Facade.PublicProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Facade.{FileCapability, HeaderPolicy, PublicProjection}
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

  test "reconstructs accepted SSE blocks without retaining upstream framing fields" do
    payload = %{
      "type" => "response.completed",
      "provider" => @hidden_provider,
      "response" => %{
        "id" => "resp_canonical_sse",
        "object" => "response",
        "model" => @hidden_model,
        "status" => "completed"
      }
    }

    raw =
      [
        ": #{@hidden_account}\n",
        "id: #{@hidden_assignment}\n",
        "retry: 1000\n",
        "event: response.completed\n",
        "unknown: #{@hidden_provider}\n",
        "data: ",
        Jason.encode!(payload),
        "\n\n"
      ]
      |> IO.iodata_to_binary()

    assert {:ok, projected} = PublicProjection.sse_block_result(raw)

    assert ["event: response.completed", "data: " <> encoded] =
             String.split(projected, "\n", trim: true)

    assert Jason.decode!(encoded)["response"]["model"] == "gemma3"

    for sentinel <- [@hidden_account, @hidden_assignment, @hidden_provider, @hidden_model] do
      refute projected =~ sentinel
    end

    assert {:ok, "data: [DONE]\n\n"} =
             PublicProjection.sse_block_result(
               ": #{@hidden_account}\nid: #{@hidden_assignment}\ndata: [DONE]\n\n"
             )
  end

  test "derives an omitted SSE body type only from an allowed event label" do
    assert {:ok, projected} =
             PublicProjection.sse_block_result(
               "event: response.output_text.delta\ndata: {\"delta\":\"visible\"}\n\n"
             )

    assert ["event: response.output_text.delta", "data: " <> encoded] =
             String.split(projected, "\n", trim: true)

    assert Jason.decode!(encoded) == %{
             "type" => "response.output_text.delta",
             "delta" => "visible"
           }

    assert {:error, conflicting} =
             PublicProjection.sse_block_result(
               "event: response.completed\ndata: {\"type\":\"response.failed\"}\n\n"
             )

    assert conflicting =~ "event: error"
    refute conflicting =~ "response.completed"
    refute conflicting =~ "response.failed"

    assert {:error, unknown} =
             PublicProjection.sse_block_result(
               "event: provider.#{@hidden_provider}\ndata: {\"delta\":\"visible\"}\n\n"
             )

    refute unknown =~ @hidden_provider
  end

  test "projects a legacy bare response through the event entry point" do
    source = %{
      "id" => "resp_bare_event_entry",
      "object" => "response",
      "status" => "completed",
      "model" => @hidden_model,
      "provider" => @hidden_provider,
      "usage" => %{"input_tokens" => 2, "account" => @hidden_account}
    }

    projected = PublicProjection.responses_event(source)

    assert projected == %{
             "id" => "resp_bare_event_entry",
             "object" => "response",
             "status" => "completed",
             "model" => "gemma3",
             "usage" => %{"input_tokens" => 2}
           }
  end

  test "projects chat completions recursively and drops unknown nested envelopes" do
    arguments = Jason.encode!(%{"provider" => @hidden_provider})

    assert {:ok, projected} =
             PublicProjection.gateway_body_result(%{
               "id" => "chatcmpl_recursive_projection",
               "object" => "chat.completion",
               "created" => 1_723_000_000,
               "model" => @hidden_model,
               "provider" => @hidden_provider,
               "choices" => [
                 %{
                   "index" => 0,
                   "finish_reason" => "stop",
                   "account" => @hidden_account,
                   "message" => %{
                     "role" => "assistant",
                     "content" => "literal #{@hidden_provider} remains content",
                     "audio" => %{
                       "id" => "audio_safe",
                       "transcript" => "visible transcript",
                       "account" => @hidden_account
                     },
                     "tool_calls" => [
                       %{
                         "id" => "call_safe",
                         "type" => "function",
                         "function" => %{
                           "name" => "safe_tool",
                           "arguments" => arguments,
                           "account" => @hidden_account
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{
                 "prompt_tokens" => 3,
                 "completion_tokens" => 2,
                 "prompt_tokens_details" => %{
                   "audio_tokens" => 1,
                   "provider_token_count" => 7
                 }
               }
             })

    assert projected["model"] == "gemma3"
    assert projected["id"] == "chatcmpl_recursive_projection"
    assert projected["created"] == 1_723_000_000
    refute Map.has_key?(projected, "service_tier")
    assert [choice] = projected["choices"]
    assert choice["index"] == 0
    assert choice["message"]["role"] == "assistant"
    assert choice["message"]["audio"]["id"] == "audio_safe"
    assert choice["message"]["audio"]["transcript"] == "visible transcript"

    assert get_in(choice, ["message", "tool_calls", Access.at(0), "function", "arguments"]) ==
             arguments

    assert get_in(choice, ["message", "tool_calls", Access.at(0), "function", "name"]) ==
             "safe_tool"

    assert projected["usage"]["prompt_tokens"] == 3
    assert projected["usage"]["completion_tokens"] == 2
    assert projected["usage"]["prompt_tokens_details"] == %{"audio_tokens" => 1}

    serialized = Jason.encode!(projected)
    assert serialized =~ "literal #{@hidden_provider} remains content"
    refute serialized =~ @hidden_account
    refute serialized =~ @hidden_assignment
  end

  test "rejects malformed required and nested chat completion protocol fields" do
    valid = %{
      "id" => "chatcmpl_shape_guard",
      "object" => "chat.completion",
      "created" => 1_723_000_000,
      "model" => @hidden_model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "safe content"}
        }
      ]
    }

    malformed = [
      put_in(valid, ["choices"], %{"provider" => @hidden_provider}),
      put_in(valid, ["choices", Access.at(0), "index"], %{"account" => @hidden_account}),
      put_in(valid, ["choices", Access.at(0), "message"], [@hidden_assignment]),
      put_in(valid, ["choices", Access.at(0), "message"], nil),
      put_in(
        valid,
        ["choices", Access.at(0), "message", "tool_calls"],
        %{"provider" => @hidden_provider}
      ),
      Map.put(valid, "usage", %{"prompt_tokens" => [@hidden_account]})
    ]

    for body <- malformed do
      assert :error = PublicProjection.gateway_body_result(body)
    end
  end

  test "rejects wrong-typed fields across response items content usage and events" do
    valid_response = %{
      "id" => "resp_shape_guard",
      "object" => "response",
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }

    malformed = [
      put_in(valid_response, ["id"], %{"provider" => @hidden_provider}),
      put_in(valid_response, ["usage"], [@hidden_account]),
      put_in(valid_response, ["usage", "input_tokens"], %{"account" => @hidden_account}),
      put_in(valid_response, ["incomplete_details"], [@hidden_assignment]),
      put_in(valid_response, ["output"], [
        %{
          "id" => "item_shape_guard",
          "type" => "computer_call",
          "action" => [@hidden_provider]
        }
      ]),
      %{
        "type" => "response.output_item.added",
        "output_index" => %{"provider" => @hidden_provider},
        "item" => %{"id" => "item_event_guard", "type" => "message", "content" => []}
      },
      %{
        "type" => "response.content_part.added",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{
          "type" => "output_text",
          "text" => "safe",
          "annotations" => %{"account" => @hidden_account}
        }
      }
    ]

    for body <- malformed do
      assert :error = PublicProjection.gateway_body_result(body)
    end

    assert {:ok, nullable} =
             PublicProjection.gateway_body_result(%{
               "id" => "resp_nullable_shape_guard",
               "object" => "response",
               "status" => "incomplete",
               "incomplete_details" => nil,
               "reasoning" => nil,
               "usage" => nil,
               "output" => []
             })

    assert nullable["incomplete_details"] == nil
    assert nullable["usage"] == nil
  end

  test "rejects wrong-typed protocol fields across every supported envelope family" do
    cases = [
      chat: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => "chatcmpl_family_guard",
          "object" => "chat.completion",
          "created" => 1_723_000_000,
          "model" => @hidden_model,
          "choices" => [],
          "usage" => [@hidden_account]
        })
      end,
      response: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => "resp_family_guard",
          "object" => "response",
          "status" => %{"provider" => @hidden_provider},
          "output" => []
        })
      end,
      item: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => "resp_item_family_guard",
          "object" => "response",
          "output" => [
            %{
              "type" => "computer_call",
              "action" => %{
                "type" => "click",
                "x" => %{"account" => @hidden_account},
                "y" => 12
              }
            }
          ]
        })
      end,
      content: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => "resp_content_family_guard",
          "object" => "response",
          "output" => [
            %{
              "type" => "message",
              "content" => [
                %{"type" => "output_text", "text" => %{"provider" => @hidden_provider}}
              ]
            }
          ]
        })
      end,
      usage: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => "resp_usage_family_guard",
          "object" => "response",
          "output" => [],
          "usage" => %{"input_tokens" => [@hidden_account]}
        })
      end,
      model: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => @hidden_model,
          "object" => "model",
          "created" => %{"provider" => @hidden_provider}
        })
      end,
      file: fn ->
        PublicProjection.gateway_body_result(%{
          "id" => "file_family_guard",
          "object" => "file",
          "bytes" => %{"account" => @hidden_account},
          "filename" => "safe.txt",
          "purpose" => "user_data",
          "status" => "uploaded"
        })
      end,
      ollama: fn ->
        PublicProjection.ollama_body_result("/api/tags", %{
          "models" => [
            %{
              "name" => "gemma3",
              "model" => "gemma3",
              "modified_at" => "2026-08-11T00:00:00Z",
              "size" => 0,
              "digest" => "sha256:safe",
              "details" => %{
                "family" => %{"provider" => @hidden_provider},
                "parameter_size" => "virtual"
              }
            }
          ]
        })
      end
    ]

    results = Map.new(cases, fn {family, project} -> {family, project.()} end)
    assert results == Map.new(cases, fn {family, _project} -> {family, :error} end)
  end

  test "rejects malformed typed optional and nested schemas instead of deleting fields" do
    response_with_item = fn item ->
      %{
        "id" => "resp_nested_mutation_guard",
        "object" => "response",
        "output" => [item]
      }
    end

    cases = [
      compaction: %{
        "id" => "compact_mutation_guard",
        "object" => "response.compaction",
        "created_at" => %{"provider" => @hidden_provider},
        "output" => []
      },
      text_completion: %{
        "id" => "cmpl_mutation_guard",
        "object" => "text_completion",
        "created" => %{"account" => @hidden_account},
        "choices" => [
          %{"text" => "safe", "index" => 0, "finish_reason" => "stop", "logprobs" => nil}
        ]
      },
      image: %{
        "created" => 1,
        "quality" => %{"provider" => @hidden_provider},
        "data" => [%{"b64_json" => "safe-image"}]
      },
      catalog: %{
        "models" => [
          %{
            "slug" => "gemma3",
            "supports_streaming" => %{"provider" => @hidden_provider}
          }
        ]
      },
      rate_limit: %{
        "type" => "codex.rate_limits",
        "rate_limits" => %{
          "primary" => %{"used_percent" => %{"account" => @hidden_account}}
        }
      },
      caller:
        response_with_item.(%{
          "type" => "function_call",
          "caller" => %{"type" => "program", "caller_id" => [@hidden_assignment]}
        }),
      file_search_result:
        response_with_item.(%{
          "type" => "file_search_call",
          "queries" => ["safe"],
          "results" => [%{"file_id" => "file-safe", "score" => [@hidden_account]}]
        }),
      web_search_source:
        response_with_item.(%{
          "type" => "web_search_call",
          "action" => %{
            "type" => "search",
            "query" => "safe",
            "sources" => [%{"type" => "url", "url" => %{"provider" => @hidden_provider}}]
          }
        }),
      code_output:
        response_with_item.(%{
          "type" => "code_interpreter_call",
          "code" => "print('safe')",
          "outputs" => [%{"type" => "logs", "logs" => %{"account" => @hidden_account}}]
        }),
      reasoning_summary:
        response_with_item.(%{
          "type" => "reasoning",
          "summary" => [
            %{"type" => "summary_text", "text" => %{"provider" => @hidden_provider}}
          ]
        }),
      shell_action:
        response_with_item.(%{
          "type" => "local_shell_call",
          "action" => %{"type" => "exec", "timeout_ms" => [@hidden_account]}
        }),
      mcp_tool:
        response_with_item.(%{
          "type" => "mcp_list_tools",
          "tools" => [%{"name" => %{"provider" => @hidden_provider}}]
        }),
      patch_operation:
        response_with_item.(%{
          "type" => "apply_patch_call",
          "operation" => %{"type" => "update", "path" => [@hidden_assignment]}
        }),
      compaction_metadata:
        response_with_item.(%{
          "type" => "compaction",
          "encrypted_content" => "safe-encrypted-content",
          "internal_chat_message_metadata_passthrough" => %{
            "turn_id" => %{"account" => @hidden_account}
          }
        })
    ]

    results =
      Map.new(cases, fn {family, body} -> {family, PublicProjection.gateway_body_result(body)} end)

    assert results == Map.new(cases, fn {family, _body} -> {family, :error} end)
  end

  test "rejects malformed optional fields in a valid local file finalize envelope" do
    assert {:ok, download_url} =
             FileCapability.mint(
               "https://files.example.com/download?sig=safe",
               %FileRecord{
                 pool_id: Ecto.UUID.generate(),
                 api_key_id: Ecto.UUID.generate(),
                 file_id: "file_finalize_shape_guard",
                 byte_size: 12,
                 pool_upstream_assignment_id: Ecto.UUID.generate(),
                 upstream_identity_id: Ecto.UUID.generate(),
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
               },
               :download,
               origin: "http://127.0.0.1:4000"
             )

    assert :error =
             PublicProjection.gateway_body_result(%{
               "status" => "processed",
               "download_url" => download_url,
               "file_name" => %{"provider" => @hidden_provider},
               "mime_type" => "text/plain"
             })
  end

  test "accepts nullable tool namespaces only at their typed item location" do
    base = %{
      "id" => "resp_nullable_namespace_guard",
      "object" => "response",
      "output" => [
        %{
          "type" => "custom_tool_call",
          "call_id" => "call_nullable_namespace_guard",
          "name" => "safe_tool",
          "namespace" => nil,
          "input" => "safe input"
        }
      ]
    }

    assert {:ok, projected} = PublicProjection.gateway_body_result(base)
    assert get_in(projected, ["output", Access.at(0), "namespace"]) == nil

    assert :error =
             base
             |> put_in(
               ["output", Access.at(0), "namespace"],
               %{"provider" => @hidden_provider}
             )
             |> PublicProjection.gateway_body_result()
  end

  test "validates moderation status as a string without weakening numeric failure status" do
    assert {:ok, projected} =
             PublicProjection.gateway_body_result(%{
               "type" => "response.moderation.completed",
               "model" => @hidden_model,
               "check_id" => "check_shape_guard",
               "status" => "completed"
             })

    assert projected["status"] == "completed"

    assert :error =
             PublicProjection.gateway_body_result(%{
               "type" => "response.moderation.completed",
               "check_id" => "check_shape_guard",
               "status" => %{"provider" => @hidden_provider}
             })

    assert :error =
             PublicProjection.gateway_body_result(%{
               "type" => "response.failed",
               "status" => "502",
               "message" => "wrong typed status"
             })
  end

  test "projects compact and upstream error envelopes without retaining unknown fields" do
    encrypted = "encrypted-visible-compact-content"

    assert {:ok, compact} =
             PublicProjection.gateway_body_result(%{
               "id" => "resp_compact_projection",
               "object" => "response.compaction",
               "provider" => @hidden_provider,
               "output" => [
                 %{
                   "type" => "compaction",
                   "encrypted_content" => encrypted,
                   "account" => @hidden_account
                 }
               ],
               "usage" => %{
                 "input_tokens" => 3,
                 "output_tokens" => 1,
                 "provider" => @hidden_provider
               }
             })

    assert compact == %{
             "id" => "resp_compact_projection",
             "object" => "response.compaction",
             "output" => [%{"type" => "compaction", "encrypted_content" => encrypted}],
             "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
           }

    assert {:ok, failure} =
             PublicProjection.gateway_body_result(%{
               "error" => %{
                 "code" => "rate_limit_exceeded",
                 "type" => "requests",
                 "message" => "#{@hidden_provider} account failed",
                 "provider" => @hidden_provider
               },
               "provider" => @hidden_provider
             })

    assert failure["error"]["code"] == "rate_limit_exceeded"
    assert failure["error"]["message"] == "gemma3 request failed"
    refute Jason.encode!(failure) =~ @hidden_provider
  end

  test "uses the HTTP status when projecting untrusted errors and never retains sentinels" do
    assert {:ok, rate_limited} =
             PublicProjection.gateway_body_result(
               %{
                 "error" => %{
                   "code" => "provider-private-code-#{@hidden_provider}",
                   "message" => "account #{@hidden_account} was rate limited",
                   "param" => @hidden_assignment,
                   "provider" => @hidden_provider
                 }
               },
               429
             )

    assert rate_limited == %{
             "error" => %{
               "code" => "rate_limit_exceeded",
               "message" => "Local request limit exceeded",
               "param" => nil,
               "type" => "invalid_request_error"
             }
           }

    serialized = Jason.encode!(rate_limited)
    refute serialized =~ @hidden_provider
    refute serialized =~ @hidden_account
    refute serialized =~ @hidden_assignment

    assert {:ok, malformed_error_body} =
             PublicProjection.gateway_body_result(%{"unexpected" => @hidden_provider}, 400)

    assert malformed_error_body["error"]["code"] == "invalid_request"
    refute Jason.encode!(malformed_error_body) =~ @hidden_provider
  end

  test "projects explicit native catalog, image, bare response, and rate-limit schemas" do
    assert {:ok, catalog} =
             PublicProjection.gateway_body_result(%{
               "models" => [
                 %{
                   "slug" => "gemma3",
                   "display_name" => "gemma3",
                   "description" => "gemma3",
                   "default_reasoning_level" => "max",
                   "supported_reasoning_levels" => [
                     %{
                       "effort" => "max",
                       "description" => "Maximum",
                       "provider" => @hidden_provider
                     }
                   ],
                   "truncation_policy" => %{
                     "mode" => "tokens",
                     "limit" => 16_384,
                     "account" => @hidden_account
                   },
                   "input_modalities" => ["text", "image", @hidden_provider],
                   "service_tiers" => [
                     %{"id" => "priority", "name" => "Priority", "account" => @hidden_account}
                   ],
                   "provider" => @hidden_provider
                 }
               ],
               "account" => @hidden_account
             })

    assert get_in(catalog, ["models", Access.at(0), "slug"]) == "gemma3"

    assert get_in(catalog, ["models", Access.at(0), "supported_reasoning_levels"]) == [
             %{"effort" => "max", "description" => "Maximum"}
           ]

    assert get_in(catalog, ["models", Access.at(0), "truncation_policy"]) == %{
             "mode" => "tokens",
             "limit" => 16_384
           }

    assert get_in(catalog, ["models", Access.at(0), "input_modalities"]) == ["text", "image"]
    refute Jason.encode!(catalog) =~ @hidden_provider
    refute Jason.encode!(catalog) =~ @hidden_account

    assert {:ok, image} =
             PublicProjection.gateway_body_result(%{
               "created" => 123,
               "background" => "opaque",
               "output_format" => "png",
               "quality" => "medium",
               "size" => "1024x1024",
               "data" => [
                 %{
                   "b64_json" => "public-image-bytes",
                   "revised_prompt" => "public prompt",
                   "url" => "https://#{@hidden_provider}.invalid/signed",
                   "account" => @hidden_account
                 }
               ],
               "usage" => %{"input_tokens" => 3, "provider" => @hidden_provider},
               "provider" => @hidden_provider
             })

    assert image == %{
             "created" => 123,
             "background" => "opaque",
             "output_format" => "png",
             "quality" => "medium",
             "size" => "1024x1024",
             "data" => [
               %{"b64_json" => "public-image-bytes", "revised_prompt" => "public prompt"}
             ],
             "usage" => %{"input_tokens" => 3}
           }

    assert {:ok, bare} =
             PublicProjection.gateway_body_result(%{
               "id" => "resp_native_bare",
               "status" => "completed",
               "model" => @hidden_model,
               "provider" => @hidden_provider,
               "usage" => %{
                 "input_tokens" => 9,
                 "cached_input_tokens" => 4,
                 "output_tokens" => 2,
                 "reasoning_tokens" => 1,
                 "total_tokens" => 11,
                 "account" => @hidden_account
               }
             })

    assert bare["id"] == "resp_native_bare"
    assert bare["model"] == "gemma3"

    assert bare["usage"] == %{
             "input_tokens" => 9,
             "cached_input_tokens" => 4,
             "output_tokens" => 2,
             "reasoning_tokens" => 1,
             "total_tokens" => 11
           }

    rate_limit = %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => 12.5,
          "window_minutes" => 300,
          "reset_at" => 1_900_000_000,
          "provider" => @hidden_provider
        }
      },
      "account" => @hidden_account
    }

    assert {:ok, projected_rate_limit} = PublicProjection.gateway_body_result(rate_limit)

    assert projected_rate_limit == %{
             "type" => "codex.rate_limits",
             "rate_limits" => %{
               "primary" => %{
                 "used_percent" => 12.5,
                 "window_minutes" => 300,
                 "reset_at" => 1_900_000_000
               }
             }
           }
  end

  test "projects local v1 usage through an exact public schema" do
    source = %{
      request_count: 3,
      total_tokens: 77,
      cached_input_tokens: 11,
      total_cost_usd: 3.45,
      total_cost_status: "priced",
      limits: [
        %{
          limit_type: "total_tokens",
          limit_window: "daily",
          max_value: 1000,
          current_value: 77,
          remaining_value: 923,
          model_filter: "gemma3",
          reset_at: "2026-08-13T00:00:00Z",
          source: "pool_limit",
          provider: @hidden_provider
        }
      ],
      upstream_limits: [
        %{
          limit_type: "credits",
          limit_window: "5h",
          max_value: 120,
          current_value: 12,
          remaining_value: 108,
          model_filter: nil,
          reset_at: nil,
          source: "pool_capacity",
          account: @hidden_account
        }
      ],
      model_buckets: [
        %{
          model: "gemma3",
          request_count: 3,
          total_tokens: 77,
          provider: @hidden_provider
        }
      ],
      provider: @hidden_provider,
      account: @hidden_account
    }

    assert {:ok, projected} = PublicProjection.gateway_body_result(source)
    assert projected["request_count"] == 3
    assert projected["total_tokens"] == 77
    assert projected["total_cost_status"] == "priced"
    assert get_in(projected, ["limits", Access.at(0), "source"]) == "pool_limit"
    assert get_in(projected, ["model_buckets", Access.at(0), "model"]) == "gemma3"

    serialized = Jason.encode!(projected)
    refute serialized =~ @hidden_provider
    refute serialized =~ @hidden_account

    assert :error =
             PublicProjection.gateway_body_result(%{
               request_count: %{"provider" => @hidden_provider},
               total_tokens: 0,
               cached_input_tokens: 0,
               total_cost_usd: 0.0,
               total_cost_status: "unpriced",
               limits: [],
               upstream_limits: []
             })
  end

  test "preserves only documented public service tiers" do
    assert {:ok, safe} =
             PublicProjection.gateway_body_result(%{
               "id" => "resp_safe_tier",
               "object" => "response",
               "service_tier" => "fast"
             })

    assert safe["service_tier"] == "fast"

    assert {:ok, unknown} =
             PublicProjection.gateway_body_result(%{
               "id" => "resp_private_tier",
               "object" => "response",
               "service_tier" => @hidden_provider
             })

    refute Map.has_key?(unknown, "service_tier")
    refute Jason.encode!(unknown) =~ @hidden_provider

    assert {:ok, chat} =
             PublicProjection.gateway_body_result(%{
               "id" => "chat_private_tier",
               "object" => "chat.completion",
               "created" => 1_723_000_000,
               "model" => @hidden_model,
               "service_tier" => @hidden_provider,
               "choices" => []
             })

    refute Map.has_key?(chat, "service_tier")
  end

  test "projects native terminal variants and rejects wrong-typed explicit envelopes" do
    assert {:ok, done} =
             PublicProjection.gateway_body_result(%{
               "type" => "response.done",
               "provider" => @hidden_provider,
               "response" => %{
                 "id" => "resp_done",
                 "status" => "completed",
                 "account" => @hidden_account
               }
             })

    assert done == %{
             "type" => "response.done",
             "response" => %{"id" => "resp_done", "status" => "completed"}
           }

    assert {:ok, retry_error} =
             PublicProjection.gateway_body_result(%{
               "type" => "error",
               "status" => 400,
               "code" => "previous_response_not_found",
               "message" => "#{@hidden_provider} account #{@hidden_account} failed",
               "provider" => @hidden_provider
             })

    assert retry_error["type"] == "error"
    assert retry_error["code"] == "previous_response_not_found"
    assert retry_error["message"] == "Previous response was not found. Retrying the full request."
    refute Jason.encode!(retry_error) =~ @hidden_provider
    refute Jason.encode!(retry_error) =~ @hidden_account

    assert :error =
             PublicProjection.gateway_body_result(%{
               "models" => %{"provider" => @hidden_provider}
             })

    assert :error =
             PublicProjection.gateway_body_result(%{
               "created" => 1,
               "data" => %{"provider" => @hidden_provider}
             })

    assert :error =
             PublicProjection.gateway_body_result(%{
               "type" => "codex.rate_limits",
               "rate_limits" => %{"primary" => @hidden_provider}
             })
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

  test "keeps protocol-significant terminal classes while cloaking their text" do
    projected =
      PublicProjection.responses_event(%{
        "type" => "response.failed",
        "error" => %{
          "type" => "server_error",
          "code" => "context_length_exceeded",
          "message" => "upstream request failed"
        },
        "response" => %{
          "model" => @hidden_model,
          "error" => %{
            "type" => "server_error",
            "code" => "context_length_exceeded",
            "message" => "provider #{@hidden_account} failed"
          }
        }
      })

    assert projected["error"] == %{
             "type" => "server_error",
             "code" => "context_length_exceeded",
             "message" => "gemma3 request failed"
           }

    assert projected["response"]["model"] == "gemma3"
    assert projected["response"]["error"] == projected["error"]
    refute Jason.encode!(projected) =~ @hidden_account
    refute Jason.encode!(projected) =~ @hidden_model
  end

  test "allowlists response envelopes while preserving documented application data" do
    preserved_text = "literal #{@hidden_model} #{@hidden_provider} remains content"
    preserved_arguments = ~s({"provider":"#{@hidden_provider}","path":"notes.txt"})

    projected =
      PublicProjection.gateway_body(%{
        "id" => "resp_allowlisted",
        "object" => "response",
        "model" => @hidden_model,
        "unknown_root" => @hidden_provider,
        "response" => %{"unknown_nested_envelope" => @hidden_account},
        "output" => [
          %{
            "id" => "msg_allowlisted",
            "type" => "message",
            "role" => "assistant",
            "unknown_item_envelope" => @hidden_assignment,
            "content" => [
              %{
                "type" => "output_text",
                "text" => preserved_text,
                "annotations" => [%{"type" => "file_path", "filename" => "#{@hidden_model}.txt"}],
                "unknown_content_envelope" => @hidden_provider
              }
            ]
          },
          %{
            "id" => "call_allowlisted",
            "type" => "function_call",
            "call_id" => "call_allowlisted",
            "name" => "inspect_fixture",
            "arguments" => preserved_arguments,
            "unknown_tool_envelope" => @hidden_account
          }
        ]
      })

    assert projected["model"] == "gemma3"
    refute Map.has_key?(projected, "unknown_root")
    refute Map.has_key?(projected, "response")

    [message, tool_call] = projected["output"]
    refute Map.has_key?(message, "unknown_item_envelope")
    refute Map.has_key?(hd(message["content"]), "unknown_content_envelope")
    refute Map.has_key?(tool_call, "unknown_tool_envelope")
    assert get_in(message, ["content", Access.at(0), "text"]) == preserved_text

    assert get_in(message, ["content", Access.at(0), "annotations", Access.at(0), "filename"]) ==
             "#{@hidden_model}.txt"

    assert tool_call["arguments"] == preserved_arguments
  end

  test "recursively projects nested tool execution envelopes" do
    projected =
      PublicProjection.gateway_body(%{
        "id" => "resp_nested_tool_projection",
        "object" => "response",
        "model" => @hidden_model,
        "metadata" => %{"provider" => @hidden_provider},
        "tools" => [%{"type" => "computer", "provider" => @hidden_provider}],
        "output" => [
          %{
            "type" => "computer_call",
            "call_id" => "call_nested",
            "action" => %{
              "type" => "click",
              "button" => "left",
              "x" => 12,
              "y" => 34,
              "provider" => @hidden_provider
            },
            "pending_safety_checks" => [
              %{
                "id" => "check_nested",
                "code" => "fixture",
                "message" => "user-visible safety text",
                "account" => @hidden_account
              }
            ]
          }
        ]
      })

    refute Map.has_key?(projected, "metadata")
    refute Map.has_key?(projected, "tools")
    assert projected["id"] == "resp_nested_tool_projection"

    [call] = projected["output"]

    assert call["action"] == %{
             "type" => "click",
             "button" => "left",
             "x" => 12,
             "y" => 34
           }

    assert call["pending_safety_checks"] == [
             %{
               "id" => "check_nested",
               "code" => "fixture",
               "message" => "user-visible safety text"
             }
           ]

    refute Jason.encode!(projected) =~ @hidden_provider
    refute Jason.encode!(projected) =~ @hidden_account

    wrong_typed =
      PublicProjection.gateway_body(%{
        "object" => "response",
        "output" => [
          %{
            "type" => "computer_call",
            "action" => %{"provider" => @hidden_provider}
          }
        ],
        "usage" => [@hidden_account]
      })

    assert wrong_typed["type"] == "error"
    assert wrong_typed["code"] == "server_error"
    refute Jason.encode!(wrong_typed) =~ @hidden_provider
    refute Jason.encode!(wrong_typed) =~ @hidden_account
  end

  test "projects typed tool and reasoning scalar fields without unknown siblings" do
    projected =
      PublicProjection.gateway_body(%{
        "object" => "response",
        "reasoning" => %{
          "effort" => "max",
          "summary" => "auto",
          "encrypted_content" => %{"provider" => @hidden_provider}
        },
        "output" => [
          %{
            "type" => "file_search_call",
            "queries" => ["visible query"],
            "provider" => @hidden_provider
          },
          %{
            "type" => "code_interpreter_call",
            "code" => "print('safe')",
            "account" => @hidden_account,
            "outputs" => []
          },
          %{
            "type" => "image_generation_call",
            "result" => "visible-image-result",
            "assignment" => @hidden_assignment
          },
          %{
            "type" => "reasoning",
            "encrypted_content" => "visible-encrypted-content",
            "provider" => @hidden_provider
          }
        ]
      })

    assert get_in(projected, ["output", Access.at(0), "queries"]) == ["visible query"]
    assert get_in(projected, ["output", Access.at(1), "code"]) == "print('safe')"
    assert get_in(projected, ["output", Access.at(2), "result"]) == "visible-image-result"

    assert get_in(projected, ["output", Access.at(3), "encrypted_content"]) ==
             "visible-encrypted-content"

    refute Map.has_key?(projected["reasoning"], "encrypted_content")

    serialized = Jason.encode!(projected)
    refute serialized =~ @hidden_provider
    refute serialized =~ @hidden_account
    refute serialized =~ @hidden_assignment
  end

  test "projects exact local Ollama and native transcription response schemas" do
    assert {:ok, tags} =
             PublicProjection.ollama_body_result("/api/tags", %{
               "models" => [
                 %{
                   "name" => "gemma3",
                   "model" => "gemma3",
                   "modified_at" => "2026-08-11T00:00:00Z",
                   "size" => 0,
                   "digest" => "sha256:safe",
                   "details" => %{"family" => "gemma3", "parameter_size" => "virtual"},
                   "provider" => @hidden_provider
                 }
               ],
               "account" => @hidden_account
             })

    refute Jason.encode!(tags) =~ @hidden_provider
    refute Jason.encode!(tags) =~ @hidden_account

    assert {:ok, %{"status" => "success"}} =
             PublicProjection.ollama_body_result("/api/pull", %{
               "status" => "success",
               "provider" => @hidden_provider
             })

    assert {:ok, %{"text" => "literal #{@hidden_provider} remains content"}} =
             PublicProjection.transcription_body_result(%{
               "text" => "literal #{@hidden_provider} remains content",
               "account" => @hidden_account
             })

    assert :error =
             PublicProjection.transcription_body_result(%{
               "text" => %{"provider" => @hidden_provider}
             })
  end

  test "projects typed model, text-completion, programmatic, moderation, and keepalive shapes" do
    assert {:ok, model_list} =
             PublicProjection.gateway_body_result(%{
               "object" => "list",
               "provider" => @hidden_provider,
               "data" => [
                 %{
                   "id" => @hidden_model,
                   "object" => "model",
                   "created" => 1,
                   "owned_by" => @hidden_provider,
                   "permission" => [],
                   "display_name" => @hidden_model,
                   "supports_streaming" => true,
                   "supports_tools" => true,
                   "supports_reasoning" => true,
                   "input_modalities" => ["text", "image", @hidden_provider],
                   "context_length" => 8_192,
                   "account" => @hidden_account
                 }
               ]
             })

    assert [model] = model_list["data"]
    assert model["id"] == "gemma3"
    assert model["display_name"] == "gemma3"
    assert model["owned_by"] == "ollama"
    assert model["permission"] == []
    assert model["input_modalities"] == ["text", "image"]
    refute Jason.encode!(model_list) =~ @hidden_provider
    refute Jason.encode!(model_list) =~ @hidden_account

    assert {:ok, completion} =
             PublicProjection.gateway_body_result(%{
               "id" => "cmpl_safe",
               "object" => "text_completion",
               "created" => 1,
               "model" => @hidden_model,
               "choices" => [
                 %{
                   "text" => "literal #{@hidden_provider} remains content",
                   "index" => 0,
                   "logprobs" => nil,
                   "finish_reason" => "stop",
                   "account" => @hidden_account
                 }
               ],
               "usage" => %{"prompt_tokens" => 1, "total_tokens" => 2},
               "provider" => @hidden_provider
             })

    assert completion["model"] == "gemma3"
    assert hd(completion["choices"])["text"] =~ @hidden_provider
    refute Jason.encode!(Map.delete(completion, "choices")) =~ @hidden_provider

    caller = %{"type" => "program", "caller_id" => "caller-visible"}

    assert {:ok, event} =
             PublicProjection.gateway_body_result(%{
               "type" => "response.output_item.added",
               "item" => %{
                 "type" => "function_call",
                 "call_id" => "call_visible",
                 "name" => "tool_visible",
                 "namespace" => "functions",
                 "arguments" => "{\"provider\":\"#{@hidden_provider}\"}",
                 "caller" => Map.put(caller, "account", @hidden_account),
                 "provider" => @hidden_provider
               }
             })

    assert event["item"]["caller"] == caller
    assert event["item"]["namespace"] == "functions"
    refute event["item"] |> Map.delete("arguments") |> Jason.encode!() =~ @hidden_provider

    for typed <- [
          %{
            "type" => "response.moderation.started",
            "model" => @hidden_model,
            "check_id" => "check_visible",
            "provider" => @hidden_provider
          },
          %{"type" => "keepalive", "sequence_number" => 1, "provider" => @hidden_provider}
        ] do
      assert {:ok, projected} = PublicProjection.gateway_body_result(typed)
      refute Jason.encode!(projected) =~ @hidden_provider
    end
  end

  test "malformed JSON, malformed SSE, and unknown envelopes become local sanitized failures" do
    for source <- ["{not-json", Jason.encode!(%{"unknown_envelope" => @hidden_provider})] do
      projected = source |> PublicProjection.json_message() |> Jason.decode!()

      assert projected["type"] == "error"
      assert projected["code"] == "server_error"
      assert projected["error"]["code"] == "server_error"
      refute Jason.encode!(projected) =~ source
      refute Jason.encode!(projected) =~ @hidden_provider
    end

    malformed_sse =
      "event: response.completed\ndata: {not-json-#{@hidden_account}\n\n"

    projected_sse = PublicProjection.sse_block(malformed_sse) |> IO.iodata_to_binary()

    assert projected_sse =~ "event: error"
    assert projected_sse =~ ~s("code":"server_error")
    refute projected_sse =~ "not-json"
    refute projected_sse =~ @hidden_account
  end

  test "validates hostile failed websocket sources before exact terminal canonicalization" do
    source = %{
      "type" => "response.failed",
      "provider" => @hidden_provider,
      "response" => %{
        "id" => "resp_hostile_failed",
        "status" => "failed",
        "error" => %{
          "type" => @hidden_provider,
          "message" => @hidden_account
        },
        "output" => [%{"content" => @hidden_assignment}],
        "ordinary_sibling" => %{"provider" => @hidden_provider}
      }
    }

    assert {:ok, :canonical_response_failed} =
             PublicProjection.websocket_source_result(source)

    safe =
      source
      |> Jason.encode!()
      |> StreamProtocol.normalize_public_openai_responses_json_message()
      |> Jason.decode!()

    assert safe["type"] == "response.failed"
    assert safe["response"]["status"] == "failed"
    assert safe["response"]["output"] == []
    assert {:ok, projected_again} = PublicProjection.gateway_body_result(safe)
    assert projected_again["type"] == "response.failed"

    serialized = Jason.encode!(projected_again)
    refute serialized =~ @hidden_provider
    refute serialized =~ @hidden_account
    refute serialized =~ @hidden_assignment

    assert :error =
             PublicProjection.websocket_source_result(%{
               "type" => "provider.unknown",
               "response" => %{"provider" => @hidden_provider}
             })
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
