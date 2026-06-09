defmodule CodexPooler.Gateway.OpenAICompatibilityContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport

  setup do
    old_files_config = Application.get_env(:codex_pooler, Files, [])
    old_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 256,
      file_ttl_seconds: 60
    )

    Application.put_env(:codex_pooler, FileBridge,
      finalize_retry_timeout_ms: 1_000,
      finalize_retry_interval_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, Files, old_files_config)
      Application.put_env(:codex_pooler, FileBridge, old_bridge_config)
    end)

    :ok
  end

  describe "Task 4 Responses continuation and input-reference behavior" do
    @tag :tool_result_previous_response
    test "v1 Responses forwards the observed Vercel tool-output continuation shape", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.require_json_field(
            "previous_response_id",
            %{
              "id" => "resp_v1_ai_sdk_item_reference",
              "object" => "response",
              "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
            },
            %{"error" => %{"code" => "missing_tool_context"}}
          )
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_ai_sdk_previous",
          "store" => true,
          "input" => [
            %{
              "type" => "item_reference",
              "id" => "msg_existing_123"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_123",
              "output" => "{\"ok\":true}"
            },
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
            }
          ],
          "tools" => [
            %{
              "type" => "function",
              "name" => "lookup",
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
        })

      assert %{"id" => "resp_v1_ai_sdk_item_reference"} = json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_ai_sdk_previous"
      assert captured.json["store"] == false

      assert [
               %{"type" => "item_reference", "id" => "msg_existing_123"},
               %{"type" => "function_call_output", "call_id" => "call_123"},
               %{"type" => "message", "role" => "user"}
             ] = captured.json["input"]

      assert [
               %{"type" => "function", "name" => "lookup", "parameters" => %{"type" => "object"}}
             ] = captured.json["tools"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic follow-up"
      refute metadata =~ "msg_existing_123"
      refute metadata =~ "resp_v1_ai_sdk_previous"
      refute metadata =~ "call_123"
      refute metadata =~ "{\"ok\":true}"
      refute metadata =~ "raw_request"
    end

    @tag :tool_result_previous_response
    test "v1 Responses forwards opencode replay continuation item types without metadata leakage",
         %{
           conn: conn
         } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_opencode_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_opencode_previous",
          "store" => false,
          "input" => [
            %{
              "role" => "assistant",
              "id" => "msg_v1_opencode_assistant",
              "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
            },
            %{
              "type" => "reasoning",
              "id" => "rs_v1_opencode_reasoning",
              "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
              "encrypted_content" => nil
            },
            %{
              "type" => "function_call",
              "id" => "fc_v1_opencode_call",
              "call_id" => "call_v1_opencode_replay",
              "name" => "lookup_fixture",
              "arguments" => "{\"value\":\"sample\"}"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_v1_opencode_replay",
              "output" => [
                %{"type" => "input_text", "text" => "synthetic tool text"},
                %{"type" => "input_image", "image_url" => "https://example.com/sample.png"}
              ]
            }
          ]
        })

      assert %{"id" => "resp_v1_opencode_replay"} = json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["previous_response_id"] == "resp_v1_opencode_previous"

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "message",
               "reasoning",
               "function_call",
               "function_call_output"
             ]

      assert captured.json["input"] |> Enum.at(0) |> Map.get("role") == "assistant"
      assert captured.json["input"] |> Enum.at(1) |> Map.get("summary") |> length() == 1

      assert captured.json["input"] |> Enum.at(3) |> Map.get("output") |> Enum.map(& &1["type"]) ==
               ["input_text", "input_image"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic assistant replay"
      refute metadata =~ "synthetic summary"
      refute metadata =~ "synthetic tool text"
      refute metadata =~ "resp_v1_opencode_previous"
      refute metadata =~ "msg_v1_opencode_assistant"
      refute metadata =~ "rs_v1_opencode_reasoning"
      refute metadata =~ "fc_v1_opencode_call"
      refute metadata =~ "call_v1_opencode_replay"
      refute metadata =~ "raw_request"
    end

    @tag :tool_result_previous_response
    test "v1 Responses forwards opencode native replay with recovered tool call ids", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_opencode_native_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_opencode_native_previous",
          "store" => false,
          "input" => [
            %{
              "type" => "function_call",
              "id" => "fc_v1_opencode_native_call",
              "call_id" => "",
              "name" => "lookup_fixture",
              "arguments" => "{\"value\":\"sample\"}"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "",
              "output" => "synthetic native tool text"
            }
          ]
        })

      assert %{"id" => "resp_v1_opencode_native_replay"} = json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_opencode_native_previous"

      assert [
               %{
                 "type" => "function_call",
                 "id" => "fc_v1_opencode_native_call",
                 "call_id" => "fc_v1_opencode_native_call"
               },
               %{"type" => "function_call_output", "call_id" => "fc_v1_opencode_native_call"}
             ] = captured.json["input"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic native tool text"
      refute metadata =~ "resp_v1_opencode_native_previous"
      refute metadata =~ "fc_v1_opencode_native_call"
      refute metadata =~ "raw_request"
    end

    @tag :tool_result_previous_response
    test "v1 Responses translates Hermes chat-style tool continuations before dispatch", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_hermes_tool_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_hermes_previous",
          "store" => false,
          "input" => [
            %{
              "role" => "tool",
              "tool_call_id" => "call_v1_hermes_lookup",
              "content" => "synthetic hermes tool result"
            }
          ]
        })

      assert %{"id" => "resp_v1_hermes_tool_replay"} = json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_hermes_previous"

      assert [
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_v1_hermes_lookup",
                 "output" => "synthetic hermes tool result"
               }
             ] = captured.json["input"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic hermes tool result"
      refute metadata =~ "resp_v1_hermes_previous"
      refute metadata =~ "call_v1_hermes_lookup"
      refute metadata =~ "raw_request"
    end

    @tag :tool_result_previous_response
    test "v1 Responses translates Hermes assistant tool-call replay before dispatch", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_hermes_assistant_tool_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_hermes_assistant_previous",
          "store" => false,
          "input" => [
            %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{
                  "id" => "call_v1_hermes_terminal",
                  "call_id" => "call_v1_hermes_terminal",
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
              "tool_call_id" => "call_v1_hermes_terminal",
              "content" => %{
                "output" => "synthetic hermes terminal output",
                "exit_code" => 0,
                "error" => nil
              }
            }
          ]
        })

      assert %{"id" => "resp_v1_hermes_assistant_tool_replay"} = json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_hermes_assistant_previous"

      assert [
               %{
                 "type" => "function_call",
                 "call_id" => "call_v1_hermes_terminal",
                 "name" => "terminal",
                 "arguments" => "{\"cmd\":\"date\"}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_v1_hermes_terminal",
                 "output" => "synthetic hermes terminal output"
               }
             ] = captured.json["input"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic hermes terminal output"
      refute metadata =~ "resp_v1_hermes_assistant_previous"
      refute metadata =~ "call_v1_hermes_terminal"
      refute metadata =~ "raw_request"
    end

    test "v1 Responses translates Hermes reasoning and empty assistant replay before dispatch", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_hermes_reasoning_tool_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_hermes_reasoning_previous",
          "store" => false,
          "input" => [
            %{
              "type" => "reasoning",
              "summary" => [],
              "encrypted_content" => "synthetic-hermes-encrypted-reasoning"
            },
            %{"role" => "assistant", "content" => ""},
            %{
              "type" => "function_call",
              "call_id" => "call_v1_hermes_reasoning_terminal",
              "name" => "terminal",
              "arguments" => "{\"cmd\":\"date\"}"
            },
            %{
              "role" => "tool",
              "tool_call_id" => "call_v1_hermes_reasoning_terminal",
              "content" => %{
                "output" => "synthetic hermes reasoning terminal output",
                "exit_code" => 0,
                "error" => nil
              }
            }
          ]
        })

      assert %{"id" => "resp_v1_hermes_reasoning_tool_replay"} =
               json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_hermes_reasoning_previous"

      assert [
               %{
                 "type" => "reasoning",
                 "summary" => [],
                 "encrypted_content" => "synthetic-hermes-encrypted-reasoning"
               },
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => ""}]
               },
               %{
                 "type" => "function_call",
                 "call_id" => "call_v1_hermes_reasoning_terminal",
                 "name" => "terminal",
                 "arguments" => "{\"cmd\":\"date\"}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_v1_hermes_reasoning_terminal",
                 "output" => "synthetic hermes reasoning terminal output"
               }
             ] = captured.json["input"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic hermes reasoning terminal output"
      refute metadata =~ "synthetic-hermes-encrypted-reasoning"
      refute metadata =~ "resp_v1_hermes_reasoning_previous"
      refute metadata =~ "call_v1_hermes_reasoning_terminal"
      refute metadata =~ "raw_request"
    end

    test "v1 Responses accepts Hermes completed assistant replay metadata before dispatch", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_hermes_completed_assistant_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "store" => false,
          "input" => [
            %{
              "type" => "reasoning",
              "summary" => [],
              "encrypted_content" => "synthetic-hermes-encrypted-reasoning"
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "id" => "msg_v1_hermes_completed_assistant",
              "phase" => "final_answer",
              "status" => "completed",
              "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
            },
            %{"role" => "user", "content" => "synthetic follow-up"}
          ]
        })

      assert %{"id" => "resp_v1_hermes_completed_assistant_replay"} =
               json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      refute Map.has_key?(captured.json, "previous_response_id")

      assert [
               %{"type" => "reasoning"},
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "id" => "msg_v1_hermes_completed_assistant",
                 "phase" => "final_answer",
                 "status" => "completed",
                 "content" => [%{"type" => "output_text"}]
               },
               %{"type" => "message", "role" => "user"}
             ] = captured.json["input"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic assistant replay"
      refute metadata =~ "synthetic-hermes-encrypted-reasoning"
      refute metadata =~ "msg_v1_hermes_completed_assistant"
      refute metadata =~ "raw_request"
    end

    test "v1 Responses normalizes OpenClaw assistant thinking replay before dispatch", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_openclaw_assistant_thinking_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
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
        })

      assert %{"id" => "resp_v1_openclaw_assistant_thinking_replay"} =
               json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
               },
               %{"type" => "message", "role" => "user"}
             ] = captured.json["input"]

      refute inspect(captured.json["input"]) =~ "thinkingSignature"

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic assistant replay"
      refute metadata =~ "synthetic-thinking-signature"
      refute metadata =~ "raw_request"
    end

    test "v1 Responses accepts converted OpenClaw reasoning replay before dispatch", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_openclaw_converted_reasoning_replay",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
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
              "encrypted_content" => "synthetic-openclaw-encrypted-reasoning",
              "id" => "rs_v1_openclaw_converted_reasoning",
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
              "id" => "msg_v1_openclaw_converted_assistant",
              "phase" => "final_answer"
            },
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
            }
          ]
        })

      assert %{"id" => "resp_v1_openclaw_converted_reasoning_replay"} =
               json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "reasoning",
                 "encrypted_content" => "synthetic-openclaw-encrypted-reasoning",
                 "id" => "rs_v1_openclaw_converted_reasoning"
               },
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}],
                 "status" => "completed",
                 "id" => "msg_v1_openclaw_converted_assistant",
                 "phase" => "final_answer"
               },
               %{"type" => "message", "role" => "user"}
             ] = captured.json["input"]

      refute inspect(captured.json["input"]) =~ "annotations"

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic assistant replay"
      refute metadata =~ "synthetic-openclaw-encrypted-reasoning"
      refute metadata =~ "rs_v1_openclaw_converted_reasoning"
      refute metadata =~ "raw_request"
    end

    @tag :tool_result_previous_response
    test "v1 Responses rejects stale or malformed previous-response references before dispatch",
         _context do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_should_not_dispatch",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      invalid_payloads = [
        {%{
           "previous_response_id" => "resp_v1_stale_ordinary",
           "input" => "synthetic ordinary continuation"
         }, "previous_response_id"},
        {%{
           "previous_response_id" => "resp_v1_stale_item_reference",
           "input" => [
             %{"type" => "item_reference", "id" => "msg_existing_stale"},
             %{"role" => "user", "content" => "synthetic ordinary continuation"}
           ]
         }, "input"},
        {%{
           "previous_response_id" => "resp_v1_broad_reference",
           "input" => [
             %{"type" => "item_reference", "id" => "msg_existing_extra", "output" => "bad"},
             %{"type" => "function_call_output", "call_id" => "call_invalid", "output" => "bad"}
           ]
         }, "input"},
        {%{
           "input" => [
             %{"type" => "item_reference", "id" => "msg_existing_missing_previous"},
             %{
               "type" => "function_call_output",
               "call_id" => "call_missing_previous",
               "output" => "bad"
             }
           ]
         }, "input"},
        {%{
           "previous_response_id" => 123,
           "input" => [
             %{"type" => "function_call_output", "call_id" => "call_invalid", "output" => "bad"}
           ]
         }, "previous_response_id"}
      ]

      Enum.each(invalid_payloads, fn {payload, expected_param} ->
        rejected_conn =
          build_conn()
          |> auth(setup)
          |> post("/v1/responses", Map.put(payload, "model", setup.model.exposed_model_id))

        assert %{"error" => %{"code" => "invalid_request", "param" => ^expected_param}} =
                 json_response(rejected_conn, 400)

        assert FakeUpstream.count(upstream) == 0
      end)

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic ordinary continuation"
      refute metadata =~ "resp_v1_stale_ordinary"
      refute metadata =~ "resp_v1_stale_item_reference"
      refute metadata =~ "resp_v1_broad_reference"
      refute metadata =~ "msg_existing_stale"
      refute metadata =~ "msg_existing_extra"
      refute metadata =~ "call_invalid"
      refute metadata =~ "raw_request"
    end
  end

  @tag :input_file_affinity
  test "v1 input_file routes to the uploaded file owner assignment and rejects cross-key or missing refs",
       %{conn: conn} do
    unique = System.unique_integer([:positive])
    file_id = "file_v1_affinity_#{unique}"

    file_upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      file_upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: FakeUpstream.url(file_upstream) <> "/upload/#{file_id}"
      )
    )

    setup = gateway_setup(file_upstream)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("affinity.txt", "text/plain", "synthetic affinity bytes")
      })

    assert %{"id" => ^file_id, "status" => "uploaded"} = json_response(create_conn, 200)

    owner_response_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_file_owner",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    other_response_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_file_other_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = swap_upstream_base_url!(setup, owner_response_upstream)

    other =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_v1_file_other_#{unique}",
        metadata: %{"base_url" => FakeUpstream.url(other_response_upstream)},
        access_token: "v1-file-other-token"
      })

    prime_routing_quota!(other.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, other.assignment])
      )

    owner_before = FakeUpstream.count(owner_response_upstream)
    other_before = FakeUpstream.count(other_response_upstream)

    response_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_file", "file_id" => file_id}]
          }
        ]
      })

    assert %{"id" => "resp_v1_file_owner"} = json_response(response_conn, 200)
    assert FakeUpstream.count(owner_response_upstream) == owner_before + 1
    assert FakeUpstream.count(other_response_upstream) == other_before

    assert [captured] = FakeUpstream.requests(owner_response_upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert captured.json["input"]
           |> List.first()
           |> Map.fetch!("content")
           |> List.first()
           |> Map.fetch!("file_id") == file_id

    refute inspect(captured.json) =~ "fake-upload"
    refute inspect(captured.json) =~ "fake-download"

    second_key = active_api_key_fixture(setup.pool)

    denied_conn =
      build_conn()
      |> auth(second_key)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => file_id}]
      })

    assert %{"error" => %{"code" => "file_not_found", "param" => "file_id"}} =
             json_response(denied_conn, 404)

    missing_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => "file_missing_v1_affinity"}]
      })

    assert %{"error" => %{"code" => "file_not_found", "param" => "file_id"}} =
             json_response(missing_conn, 404)

    assert FakeUpstream.count(owner_response_upstream) == owner_before + 1
    assert FakeUpstream.count(other_response_upstream) == other_before

    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic affinity bytes"
    refute persisted_gateway_metadata(setup.pool.id) =~ "fake-upload"
    refute persisted_gateway_metadata(setup.pool.id) =~ "fake-download"
  end

  test "sediment image references stay rejected before dispatch with sanitized metadata", %{
    conn: conn
  } do
    file_id = "file_v1_sediment_#{System.unique_integer([:positive])}"
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: FakeUpstream.url(upstream) <> "/upload/#{file_id}"
      )
    )

    setup = gateway_setup(upstream)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("image-ref.txt", "text/plain", "synthetic sediment bytes")
      })

    assert json_response(create_conn, 200)["id"] == file_id
    create_dispatch_count = FakeUpstream.count(upstream)

    rejected_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_image", "image_url" => "sediment://#{file_id}"}
            ]
          }
        ]
      })

    assert %{"error" => %{"code" => "unsupported_input_image_format", "param" => "input"}} =
             json_response(rejected_conn, 400)

    assert FakeUpstream.count(upstream) == create_dispatch_count
    refute persisted_gateway_metadata(setup.pool.id) =~ "sediment://"
    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic sediment bytes"
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-task11-file-#{System.unique_integer([:positive])}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp persisted_gateway_metadata(pool_id) do
    Repo.all(from request in Request, where: request.pool_id == ^pool_id)
    |> inspect()
  end

  defp swap_upstream_base_url!(setup, upstream) do
    base_url = FakeUpstream.url(upstream)

    identity =
      setup.identity
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    assignment =
      setup.assignment
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    %{setup | identity: identity, assignment: assignment}
  end

  defp prime_routing_quota!(identity) do
    BackendCodexTestSupport.prime_routing_quota!(identity)
  end

  defp put_model_source_assignments!(model, assignments) do
    BackendCodexTestSupport.put_model_source_assignments!(model, assignments)
  end
end
