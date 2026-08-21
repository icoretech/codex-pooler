defmodule CodexPooler.Gateway.OpenAICompatibilityContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      curl_json_request!: 4,
      gateway_setup: 1,
      gateway_setup: 2,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Payloads.ToolResultShape
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
    test "v1 Responses forwards stateless programmatic replay in order for collected responses",
         %{
           conn: conn
         } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_programmatic_collected",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)
      input = programmatic_replay_input()

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "store" => true,
          "input" => input
        })

      assert %{"id" => "resp_v1_programmatic_collected"} = json_response(response_conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == input
      refute Map.has_key?(captured.json, "previous_response_id")

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "program",
               "function_call",
               "function_call_output",
               "program_output"
             ]

      assert captured.json["stream"] == true
      assert captured.json["store"] == false
    end

    @tag :hosted_shell_history
    test "v1 Responses forwards stateless hosted-shell history in order for collected responses",
         %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_hosted_shell_stateless",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)
      input = hosted_shell_history_input()

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "store" => true,
          "input" => input
        })

      assert %{"id" => "resp_v1_hosted_shell_stateless"} = json_response(response_conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == input

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "shell_call",
               "shell_call_output",
               "message"
             ]

      assert captured.json["stream"] == true
      assert captured.json["store"] == false
    end

    @tag :hosted_shell_history
    test "v1 Responses rejects malformed hosted-shell history before dispatch", _context do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_hosted_shell_should_not_dispatch",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      invalid_inputs = [
        put_in(hosted_shell_history_input(), [Access.at(0), "action", "unknown"], true),
        [
          hosted_shell_output()
          |> Map.put("output", [%{"stdout" => "", "stderr" => ""}])
        ]
      ]

      Enum.each(invalid_inputs, fn input ->
        rejected_conn =
          build_conn()
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => input
          })

        assert %{"error" => %{"code" => "invalid_request", "param" => "input"}} =
                 json_response(rejected_conn, 400)

        assert FakeUpstream.count(upstream) == 0
      end)
    end

    test "v1 Responses streaming forces upstream stream and store policy for stateless replay", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_programmatic_streamed",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)
      input = programmatic_replay_input()

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "stream" => true,
          "store" => true,
          "input" => input
        })

      assert [content_type] = get_resp_header(response_conn, "content-type")
      assert content_type =~ "text/event-stream"
      assert response_conn.status == 200

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == input
      refute Map.has_key?(captured.json, "previous_response_id")

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "program",
               "function_call",
               "function_call_output",
               "program_output"
             ]

      assert captured.json["stream"] == true
      assert captured.json["store"] == false
    end

    test "program output remains semantic tool-result context only when structurally valid" do
      for status <- ["completed", "incomplete"] do
        assert ToolResultShape.tool_result?(%{
                 "type" => "program_output",
                 "call_id" => "call_programmatic_context",
                 "result" => "",
                 "status" => status
               })
      end

      refute ToolResultShape.tool_result?(%{
               "type" => "program_output",
               "result" => "",
               "status" => "completed"
             })

      refute ToolResultShape.tool_result?(%{
               "type" => "message",
               "call_id" => "call_misleading_context"
             })
    end

    @tag :tool_result_previous_response
    test "v1 Responses preserves a referenced program-output continuation", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.require_json_field(
            "previous_response_id",
            %{
              "id" => "resp_v1_program_output_reference",
              "object" => "response",
              "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
            },
            %{"error" => %{"code" => "missing_tool_context"}}
          )
        )

      setup = gateway_setup(upstream)
      program_output = programmatic_replay_input() |> List.last()

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_program_output_previous",
          "input" => [
            %{"type" => "item_reference", "id" => "msg_program_output_reference"},
            program_output
          ]
        })

      assert %{"id" => "resp_v1_program_output_reference"} = json_response(response_conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_program_output_previous"

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "item_reference",
               "program_output"
             ]
    end

    @tag :hosted_shell_history
    test "v1 Responses forwards a referenced hosted-shell output continuation", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.require_json_field(
            "previous_response_id",
            %{
              "id" => "resp_v1_hosted_shell_previous",
              "object" => "response",
              "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
            },
            %{"error" => %{"code" => "missing_tool_context"}}
          )
        )

      setup = gateway_setup(upstream)

      input = [
        %{"type" => "item_reference", "id" => "msg_hosted_shell_reference"},
        hosted_shell_output()
      ]

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_hosted_shell_previous",
          "input" => input
        })

      assert %{"id" => "resp_v1_hosted_shell_previous"} = json_response(response_conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_hosted_shell_previous"
      assert captured.json["input"] == input

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "item_reference",
               "shell_call_output"
             ]
    end

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
    test "v1 Responses forwards a named standalone function-output continuation unchanged", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.require_json_field(
            "previous_response_id",
            %{
              "id" => "resp_v1_standalone_function_output",
              "object" => "response",
              "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
            },
            %{"error" => %{"code" => "missing_tool_context"}}
          )
        )

      setup = gateway_setup(upstream)

      previous_response_id = "STANDALONE_ANCHOR_SENTINEL"

      input = [
        %{"type" => "item_reference", "id" => "msg_standalone_function_output"},
        %{
          "type" => "function_call_output",
          "name" => "STANDALONE_NAME_SENTINEL",
          "namespace" => "fixture.namespace",
          "output" => "STANDALONE_OUTPUT_SENTINEL",
          "metadata" => %{"source_call_id" => "STANDALONE_CALL_ID_SENTINEL"}
        }
      ]

      response_conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => previous_response_id,
          "input" => input
        })

      assert %{"id" => "resp_v1_standalone_function_output"} =
               json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == previous_response_id
      assert captured.json["input"] == input

      metadata = persisted_gateway_metadata(setup.pool.id)

      for sentinel <- [
            "STANDALONE_OUTPUT_SENTINEL",
            "STANDALONE_NAME_SENTINEL",
            "STANDALONE_CALL_ID_SENTINEL",
            "STANDALONE_ANCHOR_SENTINEL"
          ] do
        refute metadata =~ sentinel
      end

      refute metadata =~ "raw_request"
    end

    @tag :tool_result_previous_response
    test "v1 Responses preserves explicit null Vercel tool-output continuation", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.require_json_field(
            "previous_response_id",
            %{
              "id" => "resp_v1_ai_sdk_null_tool_output",
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
          "previous_response_id" => "resp_v1_ai_sdk_null_previous",
          "input" => [
            %{"type" => "item_reference", "id" => "msg_existing_null_123"},
            %{
              "type" => "function_call_output",
              "call_id" => "call_null_123",
              "output" => nil
            },
            %{"role" => "user", "content" => "synthetic follow-up"}
          ]
        })

      assert %{"id" => "resp_v1_ai_sdk_null_tool_output"} = json_response(response_conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["previous_response_id"] == "resp_v1_ai_sdk_null_previous"

      assert [
               %{"type" => "item_reference", "id" => "msg_existing_null_123"},
               %{"type" => "function_call_output", "call_id" => "call_null_123"} = tool_output,
               %{"type" => "message", "role" => "user"}
             ] = captured.json["input"]

      assert Map.has_key?(tool_output, "output")
      assert is_nil(tool_output["output"])

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic follow-up"
      refute metadata =~ "msg_existing_null_123"
      refute metadata =~ "resp_v1_ai_sdk_null_previous"
      refute metadata =~ "call_null_123"
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

      setup =
        gateway_setup(upstream, model_metadata: %{"input_modalities" => ["text", "image"]})

      passthrough_key = "internal_chat_message_metadata_passthrough"

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
              "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}],
              passthrough_key => %{"turn_id" => "turn_v1_message"}
            },
            %{
              "type" => "reasoning",
              "id" => "rs_v1_opencode_reasoning",
              "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
              "encrypted_content" => nil,
              passthrough_key => %{"turn_id" => "turn_v1_reasoning"}
            },
            %{
              "type" => "function_call",
              "id" => "fc_v1_opencode_call",
              "call_id" => "call_v1_opencode_replay",
              "name" => "lookup_fixture",
              "arguments" => "{\"value\":\"sample\"}",
              passthrough_key => %{"turn_id" => "turn_v1_call"}
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_v1_opencode_replay",
              "output" => [
                %{"type" => "input_text", "text" => "synthetic tool text"},
                %{"type" => "input_image", "image_url" => "https://example.com/sample.png"}
              ],
              passthrough_key => %{"turn_id" => "turn_v1_output"}
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

      assert Enum.map(captured.json["input"], &get_in(&1, [passthrough_key, "turn_id"])) == [
               "turn_v1_message",
               "turn_v1_reasoning",
               "turn_v1_call",
               "turn_v1_output"
             ]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic assistant replay"
      refute metadata =~ "synthetic summary"
      refute metadata =~ "synthetic tool text"
      refute metadata =~ "resp_v1_opencode_previous"
      refute metadata =~ "msg_v1_opencode_assistant"
      refute metadata =~ "rs_v1_opencode_reasoning"
      refute metadata =~ "fc_v1_opencode_call"
      refute metadata =~ "call_v1_opencode_replay"
      refute metadata =~ "turn_v1_message"
      refute metadata =~ "turn_v1_reasoning"
      refute metadata =~ "turn_v1_call"
      refute metadata =~ "turn_v1_output"
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
    test "v1 Responses drops OMP function-call replay status before dispatch", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_omp_replay_status",
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
          "stream" => true,
          "input" => [
            %{
              "type" => "function_call",
              "call_id" => "call_v1_omp_incomplete",
              "name" => "lookup_fixture",
              "arguments" => "{\"value\":\"sample\"}",
              "status" => "incomplete"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_v1_omp_incomplete",
              "output" => "synthetic omp tool text"
            },
            %{"role" => "user", "content" => "synthetic follow-up"}
          ]
        })

      assert [content_type] = get_resp_header(response_conn, "content-type")
      assert content_type =~ "text/event-stream"
      assert response_conn.status == 200

      assert [captured] = FakeUpstream.requests(upstream)

      assert [
               %{
                 "type" => "function_call",
                 "call_id" => "call_v1_omp_incomplete",
                 "name" => "lookup_fixture",
                 "arguments" => "{\"value\":\"sample\"}"
               } = function_call,
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_v1_omp_incomplete",
                 "output" => "synthetic omp tool text"
               },
               %{"type" => "message", "role" => "user"}
             ] = captured.json["input"]

      refute Map.has_key?(function_call, "status")

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic omp tool text"
      refute metadata =~ "call_v1_omp_incomplete"
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
              "metadata" => %{"turn_id" => "turn_v1_hermes_assistant"},
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
              "metadata" => %{"turn_id" => "turn_v1_hermes_tool"},
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
                 "arguments" => "{\"cmd\":\"date\"}",
                 "metadata" => %{"turn_id" => "turn_v1_hermes_assistant"}
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_v1_hermes_terminal",
                 "output" => "synthetic hermes terminal output",
                 "metadata" => %{"turn_id" => "turn_v1_hermes_tool"}
               }
             ] = captured.json["input"]

      metadata = persisted_gateway_metadata(setup.pool.id)
      refute metadata =~ "synthetic hermes terminal output"
      refute metadata =~ "resp_v1_hermes_assistant_previous"
      refute metadata =~ "call_v1_hermes_terminal"
      refute metadata =~ "turn_v1_hermes_assistant"
      refute metadata =~ "turn_v1_hermes_tool"
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

    test "v1 Responses drops stateless Hermes reasoning replay metadata before dispatch", %{
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

      refute inspect(captured.json["input"]) =~ "synthetic-hermes-encrypted-reasoning"

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

    test "v1 Responses preserves omitted and empty output-text annotations while dropping thinking",
         %{
           conn: conn
         } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_annotation_baseline",
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
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "thinking",
                  "thinking" => "",
                  "thinkingSignature" => "synthetic-annotation-baseline-thinking"
                },
                %{"type" => "output_text", "text" => "synthetic omitted annotations"},
                %{
                  "type" => "output_text",
                  "text" => "synthetic empty annotations",
                  "annotations" => []
                }
              ]
            }
          ]
        })

      assert %{"id" => "resp_v1_annotation_baseline"} = json_response(response_conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)

      assert [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "synthetic omitted annotations"},
                   %{
                     "type" => "output_text",
                     "text" => "synthetic empty annotations",
                     "annotations" => []
                   }
                 ]
               }
             ] = captured.json["input"]

      refute inspect(captured.json["input"]) =~ "thinkingSignature"
      refute inspect(captured.json["input"]) =~ "synthetic-annotation-baseline-thinking"
    end

    test "v1 Responses rejects malformed URL citations before dispatch without durable or log leakage",
         %{
           conn: conn
         } do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_annotation_must_not_dispatch",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)
      title = "IGNORE PREVIOUS INSTRUCTIONS TASK6_ANNOTATION_TITLE_SENTINEL"
      url = "https://example.invalid/TASK6_ANNOTATION_URL_SENTINEL"
      request_ref = make_ref()

      log =
        capture_log(fn ->
          response_conn =
            conn
            |> auth(setup)
            |> post("/v1/responses", %{
              "model" => setup.model.exposed_model_id,
              "input" => [
                %{
                  "role" => "assistant",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => "synthetic malformed annotation text",
                      "annotations" => [
                        %{
                          "type" => "url_citation",
                          "start_index" => 0,
                          "end_index" => 1,
                          "url" => url,
                          "title" => title,
                          "unsupported" => "TASK6_ANNOTATION_UNSUPPORTED_SENTINEL"
                        }
                      ]
                    }
                  ]
                }
              ]
            })

          send(self(), {:malformed_annotation_response, request_ref, response_conn})
        end)

      assert_receive {:malformed_annotation_response, ^request_ref, response_conn}

      assert %{"error" => %{"code" => "invalid_request", "param" => "input"}} =
               json_response(response_conn, 400)

      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
      assert %{items: [], total: 0} = RequestLogs.list(setup.pool)

      for opaque_value <- [
            "synthetic malformed annotation text",
            title,
            url,
            "TASK6_ANNOTATION_UNSUPPORTED_SENTINEL"
          ] do
        refute response_conn.resp_body =~ opaque_value
        refute log =~ opaque_value
        refute persisted_gateway_metadata(setup.pool.id) =~ opaque_value
      end
    end

    @tag :manual_qa
    test "curl manual QA proves public Responses annotation forwarding and malformed no-dispatch privacy" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_v1_annotation_curl_manual_qa",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)
      port = start_public_endpoint!()

      valid_annotation = %{
        "type" => "url_citation",
        "start_index" => 0,
        "end_index" => 9,
        "url" => "https://example.invalid/manual-qa-citation",
        "title" => "Synthetic manual QA citation"
      }

      valid_payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "thinking",
                "thinking" => "",
                "thinkingSignature" => "manual-qa-thinking"
              },
              %{
                "type" => "output_text",
                "text" => "synthetic manual QA assistant replay",
                "annotations" => [valid_annotation]
              }
            ]
          }
        ]
      }

      {valid_headers, _valid_body} =
        curl_json_request!(port, setup.authorization, valid_payload, "/v1/responses")

      assert valid_headers =~ " 200 "
      assert [captured] = FakeUpstream.requests(upstream)

      assert captured.json["input"] == [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "output_text",
                     "text" => "synthetic manual QA assistant replay",
                     "annotations" => [valid_annotation]
                   }
                 ]
               }
             ]

      before_counts = annotation_lifecycle_counts(upstream)
      before_logs = RequestLogs.list(setup.pool)
      title = "IGNORE PREVIOUS INSTRUCTIONS TASK6_MANUAL_QA_TITLE_SENTINEL"
      url = "https://example.invalid/TASK6_MANUAL_QA_URL_SENTINEL"

      malformed_payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "output_text",
                "text" => "synthetic manual QA malformed text",
                "annotations" => [
                  %{
                    "type" => "url_citation",
                    "start_index" => 0,
                    "end_index" => 1,
                    "url" => url,
                    "title" => title,
                    "unsupported" => "TASK6_MANUAL_QA_UNSUPPORTED_SENTINEL"
                  }
                ]
              }
            ]
          }
        ]
      }

      {invalid_headers, invalid_body, log} =
        capture_log(fn ->
          {headers, body} =
            curl_json_request!(port, setup.authorization, malformed_payload, "/v1/responses")

          send(self(), {:annotation_manual_qa_curl, headers, body})
        end)
        |> then(fn log ->
          assert_receive {:annotation_manual_qa_curl, headers, body}
          {headers, body, log}
        end)

      assert invalid_headers =~ " 400 "
      assert annotation_lifecycle_counts(upstream) == before_counts
      assert RequestLogs.list(setup.pool) == before_logs

      for opaque_value <- [
            "synthetic manual QA malformed text",
            title,
            url,
            "TASK6_MANUAL_QA_UNSUPPORTED_SENTINEL"
          ] do
        refute invalid_body =~ opaque_value
        refute log =~ opaque_value
        refute persisted_gateway_metadata(setup.pool.id) =~ opaque_value
      end
    end

    test "v1 Responses preserves exact URL citations while dropping stateless OpenClaw reasoning replay",
         %{
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

      citations = [
        %{
          "type" => "url_citation",
          "start_index" => 0,
          "end_index" => 9,
          "url" => "https://example.invalid/citation-one",
          "title" => "Synthetic citation one"
        },
        %{
          "type" => "url_citation",
          "start_index" => 10.0,
          "end_index" => 19.5,
          "url" => "https://example.invalid/citation-two",
          "title" => "Synthetic citation two"
        }
      ]

      expected_input = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "synthetic first turn"}]
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "synthetic assistant replay",
              "annotations" => citations
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
                  "annotations" => citations
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
      assert captured.json["input"] == expected_input
      refute inspect(captured.json["input"]) =~ "synthetic-openclaw-encrypted-reasoning"
      refute inspect(captured.json["input"]) =~ "rs_v1_openclaw_converted_reasoning"

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

      invalid_standalone_function_outputs = [
        %{
          "type" => "function_call_output",
          "call_id" => " ",
          "name" => "lookup_fixture",
          "output" => "bad"
        },
        %{
          "type" => "function_call_output",
          "call_id" => 123,
          "name" => "lookup_fixture",
          "output" => "bad"
        },
        %{"type" => "function_call_output", "output" => "bad"},
        %{"type" => "function_call_output", "name" => " ", "output" => "bad"},
        %{"type" => "function_call_output", "name" => 123, "output" => "bad"},
        %{
          "type" => "function_call_output",
          "name" => "lookup_fixture",
          "namespace" => " ",
          "output" => "bad"
        },
        %{
          "type" => "function_call_output",
          "name" => "lookup_fixture",
          "namespace" => 123,
          "output" => "bad"
        },
        %{"type" => "function_call_output", "name" => "lookup_fixture"},
        %{"type" => "function_call_output", "name" => "lookup_fixture", "result" => "bad"}
      ]

      invalid_payloads =
        [
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
           }, "previous_response_id"},
          {%{
             "previous_response_id" => "",
             "input" => [
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_blank_previous",
                 "output" => "bad"
               }
             ]
           }, "previous_response_id"},
          {%{
             "input" => [
               %{
                 "type" => "program_output",
                 "id" => "program_output_missing_result",
                 "call_id" => "call_program_output_invalid",
                 "status" => "completed"
               }
             ]
           }, "input"},
          {%{
             "input" => [
               %{
                 "type" => "program_output",
                 "id" => "program_output_wrong_status",
                 "call_id" => "call_program_output_wrong_status",
                 "result" => "",
                 "status" => "unknown"
               }
             ]
           }, "input"},
          {%{
             "previous_response_id" => "resp_v1_misleading_non_result",
             "input" => [
               %{"type" => "message", "call_id" => "call_misleading_non_result"}
             ]
           }, "input"}
        ] ++
          Enum.map(invalid_standalone_function_outputs, fn item ->
            {%{
               "previous_response_id" => "resp_v1_invalid_standalone",
               "input" => [item]
             }, "input"}
          end)

      Enum.each(invalid_payloads, fn {payload, expected_param} ->
        rejected_conn =
          build_conn()
          |> auth(setup)
          |> post("/v1/responses", Map.put(payload, "model", setup.model.exposed_model_id))

        assert %{"error" => %{"code" => "invalid_request", "param" => ^expected_param}} =
                 json_response(rejected_conn, 400)

        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Attempt, :count) == 0

        assert Repo.aggregate(
                 from(entry in LedgerEntry, where: entry.entry_kind == "reservation"),
                 :count
               ) == 0

        assert Repo.aggregate(
                 from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
                 :count
               ) == 0
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
    file_contents = "synthetic affinity bytes"
    upload_url = stub_upload_put(file_id)

    file_upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      file_upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: upload_url
      )
    )

    setup = gateway_setup(file_upstream)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("affinity.txt", "text/plain", file_contents)
      })

    assert %{"id" => ^file_id, "status" => "uploaded"} = json_response(create_conn, 200)
    assert_upload_put(file_id, "/upload/#{file_id}", file_contents, "text/plain")

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
    file_contents = "synthetic sediment bytes"
    upload_url = stub_upload_put(file_id)
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: upload_url
      )
    )

    setup = gateway_setup(upstream)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("image-ref.txt", "text/plain", file_contents)
      })

    assert json_response(create_conn, 200)["id"] == file_id
    assert_upload_put(file_id, "/upload/#{file_id}", file_contents, "text/plain")
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

  defp programmatic_replay_input do
    [
      %{
        "type" => "program",
        "id" => "program_item_fixture",
        "call_id" => "program_call_fixture",
        "code" => "",
        "fingerprint" => ""
      },
      %{
        "type" => "function_call",
        "call_id" => "function_call_fixture",
        "name" => "lookup_fixture",
        "arguments" => "{}",
        "caller" => %{"type" => "program", "caller_id" => "program_call_fixture"}
      },
      %{
        "type" => "function_call_output",
        "call_id" => "function_call_fixture",
        "output" => "",
        "caller" => %{"type" => "program", "caller_id" => "program_call_fixture"}
      },
      %{
        "type" => "program_output",
        "id" => "program_output_item_fixture",
        "call_id" => "program_call_fixture",
        "result" => "",
        "status" => "completed"
      }
    ]
  end

  defp hosted_shell_history_input do
    [
      %{
        "type" => "shell_call",
        "id" => "shell_call_history_item",
        "call_id" => "call_hosted_shell_history",
        "action" => %{"commands" => [], "timeout_ms" => 1, "max_output_length" => 16},
        "caller" => %{"type" => "direct"},
        "status" => "completed",
        "environment" => %{"type" => "container_reference", "container_id" => ""}
      },
      hosted_shell_output(),
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "synthetic hosted shell follow-up"}]
      }
    ]
  end

  defp hosted_shell_output do
    %{
      "type" => "shell_call_output",
      "id" => "shell_call_output_history_item",
      "call_id" => "call_hosted_shell_history",
      "output" => [
        %{
          "stdout" => "synthetic hosted shell stdout",
          "stderr" => "",
          "outcome" => %{"type" => "exit", "exit_code" => 0}
        }
      ],
      "caller" => %{"type" => "direct"},
      "status" => "completed",
      "max_output_length" => 16
    }
  end

  defp stub_upload_put(file_id) do
    stub_name = {__MODULE__, :upload_put, file_id}
    test_pid = self()

    Req.Test.stub(stub_name, fn conn ->
      send(test_pid, {
        :upload_put,
        file_id,
        conn.method,
        conn.request_path,
        Req.Test.raw_body(conn),
        conn.req_headers
      })

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.text("")
    end)

    current_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(
      :codex_pooler,
      FileBridge,
      Keyword.merge(current_bridge_config, upload_req_options: [plug: {Req.Test, stub_name}])
    )

    "https://fake-upload.invalid/upload/#{file_id}?sig=fake-upload"
  end

  defp assert_upload_put(file_id, path, body, content_type) do
    assert_receive {:upload_put, ^file_id, "PUT", ^path, ^body, headers}, 1_000
    assert header!(headers, "content-type") == content_type
    assert header!(headers, "x-ms-blob-type") == "BlockBlob"
    refute Enum.any?(headers, fn {name, _value} -> name in ["authorization", "cookie"] end)
  end

  defp header!(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _other -> nil
    end)
    |> case do
      nil -> flunk("missing header #{name}")
      value -> value
    end
  end

  defp persisted_gateway_metadata(pool_id) do
    Repo.all(from request in Request, where: request.pool_id == ^pool_id)
    |> inspect()
  end

  defp annotation_lifecycle_counts(upstream) do
    %{
      upstream_requests: FakeUpstream.count(upstream),
      requests: Repo.aggregate(Request, :count),
      attempts: Repo.aggregate(Attempt, :count),
      ledger_entries: Repo.aggregate(LedgerEntry, :count)
    }
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
