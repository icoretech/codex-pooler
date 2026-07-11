defmodule CodexPoolerWeb.V1.ChatCompletionsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request, RequestLogs}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  test "POST /v1/chat/completions non-streaming returns OpenAI chat shape", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_non_stream",
               "status" => "completed",
               "model" => "provider-gpt-test-model",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    payload =
      chat_payload(setup)
      |> Map.put("moderation", %{"model" => "omni-moderation-latest"})
      |> Map.put("reasoning_effort", "focused")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", payload)

    assert %{
             "id" => "resp_chat_non_stream",
             "object" => "chat.completion",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{"role" => "assistant", "content" => "synthetic answer"},
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{
               "prompt_tokens" => 4,
               "completion_tokens" => 6,
               "total_tokens" => 10
             }
           } = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert captured.json["moderation"] == %{"model" => "omni-moderation-latest"}

    assert captured.json["instructions"] == "Synthetic system"
    assert [%{"type" => "message", "role" => "user"}] = captured.json["input"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.reasoning_effort == "focused"
    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "openai_v1"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/chat/completions"

    assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
             "/backend-api/codex/responses"

    persistence_text = inspect({request.request_metadata, RequestLogs.list(setup.pool)})
    refute persistence_text =~ "Synthetic system"
    refute persistence_text =~ "Synthetic user"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  @tag :prompt_cache_controls
  test "POST /v1/chat/completions preserves prompt cache controls", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_prompt_cache_controls",
               "status" => "completed",
               "model" => "provider-gpt-test-model",
               "output" => [],
               "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    breakpoint = %{"mode" => "explicit"}
    options = %{"mode" => "explicit", "ttl" => "30m"}

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "prompt_cache_key" => "fixture-chat-cache-key",
        "prompt_cache_options" => options,
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "text",
                "text" => "fixture chat cache content",
                "prompt_cache_breakpoint" => breakpoint
              }
            ]
          }
        ]
      })

    assert %{"id" => "resp_chat_prompt_cache_controls"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["prompt_cache_key"] == "fixture-chat-cache-key"
    assert captured.json["prompt_cache_options"] == options

    assert [
             %{
               "content" => [
                 %{"prompt_cache_breakpoint" => ^breakpoint}
               ]
             }
           ] = captured.json["input"]
  end

  test "POST /v1/chat/completions keeps x-session-id local without forwarding it", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_x_session_id",
               "status" => "completed",
               "model" => "provider-gpt-test-model",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    session_header = "chat-x-session-id-#{System.unique_integer([:positive])}"

    conn =
      conn
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-id", session_header)
      |> put_req_header("x-session-affinity", "chat-lower-priority-affinity")
      |> post("/v1/chat/completions", chat_payload(setup))

    assert %{"id" => "resp_chat_x_session_id"} = json_response(conn, 200)

    assert %CodexSession{} = session = Repo.get_by(CodexSession, session_key: session_header)
    refute Repo.get_by(CodexSession, session_key: "chat-lower-priority-affinity")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.request_metadata["codex_session_id"] == session.id
    assert request.request_metadata["codex_session_key"] == session_header

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/chat/completions"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    captured_headers = Map.new(captured.headers)
    refute Map.has_key?(captured_headers, "session-id")
    refute Map.has_key?(captured_headers, "x-session-id")
    refute Map.has_key?(captured_headers, "x-session-affinity")
  end

  test "POST /v1/chat/completions preserves json_object response format in the upstream text format",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_chat_json_mode",
          "status" => "completed",
          "model" => "provider-gpt-test-model",
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "json mode answer"}]
            }
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        Map.put(chat_payload(setup), "response_format", %{"type" => "json_object"})
      )

    assert %{
             "id" => "resp_chat_json_mode",
             "object" => "chat.completion",
             "choices" => [
               %{
                 "message" => %{"content" => "json mode answer"}
               }
             ]
           } = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["text"]["format"]["type"] == "json_object"
    refute Map.has_key?(captured.json, "response_format")
  end

  test "POST /v1/chat/completions non-streaming backfills collected text deltas", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_chat_delta_collect", "status" => "in_progress"}
           }},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "delta"}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => " answer"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_delta_collect",
               "status" => "completed",
               "output" => []
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", chat_payload(setup))

    assert %{
             "id" => "resp_chat_delta_collect",
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "delta answer"}}
             ]
           } = json_response(conn, 200)
  end

  test "POST /v1/chat/completions maps Responses function calls to chat tool calls", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_chat_tool_call",
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "call_id" => "call_fixture",
              "name" => "lookup_fixture",
              "arguments" => "{\"query\":\"fixture\"}"
            }
          ],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", Map.put(chat_payload(setup), "tools", [function_tool()]))

    assert %{"choices" => [%{"message" => %{"tool_calls" => [tool_call]}}]} =
             json_response(conn, 200)

    assert tool_call["id"] == "call_fixture"
    assert tool_call["type"] == "function"
    assert get_in(tool_call, ["function", "name"]) == "lookup_fixture"
    assert get_in(tool_call, ["function", "arguments"]) == "{\"query\":\"fixture\"}"

    assert [captured] = FakeUpstream.requests(upstream)
    assert [translated_tool] = captured.json["tools"]
    assert translated_tool["type"] == "function"
    assert translated_tool["name"] == "lookup_fixture"
    assert translated_tool["parameters"] == get_in(function_tool(), ["function", "parameters"])
    refute Map.has_key?(translated_tool, "function")
  end

  @tag :streaming_chat
  test "POST /v1/chat/completions streaming emits chat completion chunks and done", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"codex.rate_limits", %{"type" => "codex.rate_limits", "limits" => []}},
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_chat_stream", "status" => "in_progress"}
           }},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "streamed answer"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_stream",
               "status" => "completed",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup)
        |> Map.put("stream", true)
        |> Map.put("stream_options", %{"include_usage" => true})
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "\"object\":\"chat.completion.chunk\""
    assert conn.resp_body =~ "\"role\":\"assistant\""
    assert conn.resp_body =~ "\"content\":\"streamed answer\""
    assert conn.resp_body =~ "\"finish_reason\":\"stop\""
    assert conn.resp_body =~ "\"choices\":[]"

    assert conn.resp_body =~
             "\"usage\":{\"completion_tokens\":4,\"prompt_tokens\":3,\"total_tokens\":7}"

    assert conn.resp_body =~ "data: [DONE]\n\n"
    assert conn.resp_body |> chat_chunk_ids() |> Enum.uniq() == ["resp_chat_stream"]
    refute conn.resp_body =~ "response.output_text.delta"
    refute conn.resp_body =~ "codex.rate_limits"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    refute Map.has_key?(captured.json, "stream_options")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
  end

  @tag :streaming_chat
  test "POST /v1/chat/completions streaming emits early terminal errors as first chunk", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic chat streaming validation"
             },
             "response" => %{
               "id" => "resp_chat_stream_failed",
               "status" => "failed",
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request_error",
                 "message" => "synthetic chat streaming validation"
               }
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup) |> Map.put("stream", true)
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"error" => error}] = chat_chunks(conn.resp_body)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "invalid_request_error"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "synthetic chat streaming validation"
    refute conn.resp_body =~ "\"role\":\"assistant\""
    refute conn.resp_body =~ "\"choices\""
    refute conn.resp_body =~ "data: [DONE]\n\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "invalid_request_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
  end

  test "POST /v1/chat/completions streaming emits early incomplete as length finish", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.incomplete",
           %{
             "type" => "response.incomplete",
             "response" => %{
               "id" => "resp_chat_stream_incomplete",
               "status" => "incomplete",
               "incomplete_details" => %{"reason" => "max_output_tokens"},
               "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup)
        |> Map.put("stream", true)
        |> Map.put("stream_options", %{"include_usage" => true})
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "\"role\":\"assistant\""
    assert conn.resp_body =~ "\"finish_reason\":\"length\""
    assert conn.resp_body =~ "\"choices\":[]"

    assert conn.resp_body =~
             "\"usage\":{\"completion_tokens\":0,\"prompt_tokens\":4,\"total_tokens\":4}"

    assert conn.resp_body =~ "data: [DONE]\n\n"
    refute conn.resp_body =~ "\"error\""
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert is_nil(request.last_error_code)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
    assert is_nil(attempt.network_error_code)
  end

  @tag :chat_content_filter_finish
  test "POST /v1/chat/completions non-streaming maps content filter incomplete reasons to finish_reason" do
    for reason <- ["content_filter", "content-filter"] do
      upstream =
        start_upstream(
          FakeUpstream.sse_stream([
            {"response.incomplete",
             %{
               "type" => "response.incomplete",
               "response" => %{
                 "id" => "resp_chat_content_filter_#{reason}",
                 "status" => "incomplete",
                 "incomplete_details" => %{"reason" => reason},
                 "output" => [
                   %{
                     "type" => "message",
                     "content" => [
                       %{"type" => "output_text", "text" => "synthetic filtered output"}
                     ]
                   }
                 ],
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}
               }
             }}
          ])
        )

      setup = gateway_setup(upstream)

      conn =
        build_conn()
        |> auth(setup)
        |> post("/v1/chat/completions", chat_payload(setup))

      assert %{"choices" => [%{"finish_reason" => "content_filter"}]} =
               json_response(conn, 200)

      refute conn.resp_body =~ "\"error\""
      assert FakeUpstream.count(upstream) == 1
    end
  end

  @tag :chat_content_filter_finish
  test "POST /v1/chat/completions streaming maps content filter incomplete reasons to finish_reason" do
    for reason <- ["content_filter", "content-filter"] do
      upstream =
        start_upstream(
          FakeUpstream.sse_stream([
            {"response.incomplete",
             %{
               "type" => "response.incomplete",
               "response" => %{
                 "id" => "resp_chat_stream_content_filter_#{reason}",
                 "status" => "incomplete",
                 "incomplete_details" => %{"reason" => reason},
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
               }
             }}
          ])
        )

      setup = gateway_setup(upstream)

      conn =
        build_conn()
        |> auth(setup)
        |> post(
          "/v1/chat/completions",
          chat_payload(setup)
          |> Map.put("stream", true)
          |> Map.put("stream_options", %{"include_usage" => true})
        )

      finish_reasons =
        conn.resp_body
        |> chat_chunks()
        |> Enum.flat_map(&Map.get(&1, "choices", []))
        |> Enum.map(& &1["finish_reason"])
        |> Enum.reject(&is_nil/1)

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/event-stream"
      assert conn.status == 200
      assert List.last(finish_reasons) == "content_filter"
      assert conn.resp_body =~ "data: [DONE]\n\n"
      refute conn.resp_body =~ "\"error\""
      assert FakeUpstream.count(upstream) == 1
    end
  end

  @tag :streaming_chat
  test "POST /v1/chat/completions streaming preserves late response.failed after output", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "partial chat text"}},
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic late chat streaming validation"
             },
             "response" => %{
               "id" => "resp_chat_stream_late_failed",
               "status" => "failed",
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request_error",
                 "message" => "synthetic late chat streaming validation"
               }
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup) |> Map.put("stream", true)
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "\"role\":\"assistant\""
    assert conn.resp_body =~ "\"content\":\"partial chat text\""
    assert conn.resp_body =~ "\"finish_reason\":\"stop\""
    assert conn.resp_body =~ "data: [DONE]\n\n"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "invalid_request_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
  end

  @tag :streaming_chat
  test "POST /v1/chat/completions streaming backfills tool call ids from item events", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_chat_stream_tool", "status" => "in_progress"}
           }},
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item_id" => "call_chat_stream_tool",
             "item" => %{
               "type" => "function_call",
               "name" => "lookup_fixture",
               "arguments" => ""
             }
           }},
          {"response.function_call_arguments.delta",
           %{
             "type" => "response.function_call_arguments.delta",
             "output_index" => 0,
             "delta" => "{\"query\":\"fixture\"}"
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_stream_tool",
               "status" => "completed",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup)
        |> Map.put("stream", true)
        |> Map.put("tools", [function_tool()])
      )

    [tool_chunk | _rest] =
      conn.resp_body
      |> chat_chunks()
      |> Enum.filter(&(get_in(&1, ["choices", Access.at(0), "delta", "tool_calls"]) != nil))

    assert [tool_call] = get_in(tool_chunk, ["choices", Access.at(0), "delta", "tool_calls"])
    assert tool_call["id"] == "call_chat_stream_tool"
    assert tool_call["type"] == "function"
    assert get_in(tool_call, ["function", "name"]) == "lookup_fixture"
    assert is_binary(get_in(tool_call, ["function", "arguments"]))

    refute conn.resp_body =~ ~s("id":null)
    assert conn.resp_body =~ "data: [DONE]\n\n"
  end

  @tag :streaming_chat
  test "POST /v1/chat/completions streaming emits moderation-only chunks", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{
               "id" => "resp_chat_stream_moderation",
               "status" => "in_progress"
             }
           }},
          {"response.moderation.completed",
           %{
             "type" => "response.moderation.completed",
             "moderation" => %{
               "input" => %{
                 "type" => "moderation_results",
                 "model" => "omni-moderation-latest",
                 "results" => []
               },
               "output" => %{
                 "type" => "moderation_results",
                 "model" => "omni-moderation-latest",
                 "results" => []
               }
             }
           }},
          {"response.output_text.delta",
           %{
             "type" => "response.output_text.delta",
             "delta" => "streamed moderated answer"
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_chat_stream_moderation",
               "status" => "completed",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup)
        |> Map.put("moderation", %{"model" => "omni-moderation-latest"})
        |> Map.put("stream", true)
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "\"choices\":[]"
    assert conn.resp_body =~ "\"moderation\""
    assert conn.resp_body =~ "\"input\":{\"model\":\"omni-moderation-latest\""
    assert conn.resp_body =~ "\"output\":{\"model\":\"omni-moderation-latest\""
    assert conn.resp_body =~ "\"content\":\"streamed moderated answer\""
    assert conn.resp_body =~ "data: [DONE]\n\n"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["moderation"] == %{"model" => "omni-moderation-latest"}

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    metadata = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata =~ "Synthetic user"
    refute metadata =~ "streamed moderated answer"
    refute metadata =~ "omni-moderation-latest"
  end

  test "POST /v1/chat/completions rejects unsafe reasoning effort before dispatch", %{
    conn: conn
  } do
    unsafe_effort = "synthetic freeform effort text"
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup)
        |> Map.put("reasoning_effort", unsafe_effort)
      )

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "invalid_request"
    assert error["param"] == "reasoning_effort"
    refute conn.resp_body =~ unsafe_effort
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :invalid_request_error
  test "POST /v1/chat/completions preserves local validation errors before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup) |> Map.put("function_call", "auto")
      )

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_request"
    assert error["message"] == "legacy function_call is not translatable"
    assert error["param"] == "function_call"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :provider_invalid_request_redaction
  test "POST /v1/chat/completions non-streaming redacts provider invalid_request_error", %{
    conn: conn
  } do
    provider_message =
      "provider 400 leaked https://provider.internal.example/chat?key=sk-secret and account acct_123"

    upstream_error =
      provider_invalid_request_error("context_length_exceeded", provider_message, "messages")

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_chat_provider_invalid_request",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn = conn |> auth(setup) |> post("/v1/chat/completions", chat_payload(setup))

    assert %{"error" => error} = json_response(conn, 502)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "context_length_exceeded"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ provider_message
    refute conn.resp_body =~ "provider.internal.example"
    refute conn.resp_body =~ "sk-secret"
    refute conn.resp_body =~ "acct_123"
    refute conn.resp_body =~ "messages"
    assert FakeUpstream.count(upstream) == 1
  end

  @tag :provider_invalid_request_redaction
  test "POST /v1/chat/completions streaming redacts provider invalid_request_error", %{
    conn: conn
  } do
    provider_message =
      "provider 400 leaked https://provider.internal.example/chat-stream?key=sk-secret and prompt SENTINEL_CHAT_STREAM"

    upstream_error =
      provider_invalid_request_error("context_length_exceeded", provider_message, "messages")

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_chat_stream_provider_invalid_request",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup) |> Map.put("stream", true)
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"error" => error}] = chat_chunks(conn.resp_body)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "context_length_exceeded"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ provider_message
    refute conn.resp_body =~ "provider.internal.example"
    refute conn.resp_body =~ "sk-secret"
    refute conn.resp_body =~ "SENTINEL_CHAT_STREAM"
    refute conn.resp_body =~ "\"param\""
    refute conn.resp_body =~ "data: [DONE]\n\n"
    assert FakeUpstream.count(upstream) == 1
  end

  @tag :server_error_redaction
  test "POST /v1/chat/completions streaming redacts safe-looking terminal 502 errors", %{
    conn: conn
  } do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/rate?token=secret"

    upstream_error = %{
      "type" => "api_error",
      "code" => "rate_limit_exceeded",
      "message" => provider_message,
      "param" => "provider_stack"
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_chat_stream_safe_looking_server_failed",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup) |> Map.put("stream", true)
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"error" => error}] = chat_chunks(conn.resp_body)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "rate_limit_exceeded"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/rate"
    refute conn.resp_body =~ "provider_stack"
    refute conn.resp_body =~ "data: [DONE]\n\n"
    assert FakeUpstream.count(upstream) == 1
  end

  @tag :server_error_redaction
  test "POST /v1/chat/completions streaming redacts server-class upstream errors", %{
    conn: conn
  } do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/path?token=secret"

    upstream_error = %{
      "type" => "internal_error",
      "code" => "internal_error",
      "message" => provider_message,
      "param" => "provider_stack"
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_chat_stream_server_failed",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        chat_payload(setup) |> Map.put("stream", true)
      )

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"error" => error}] = chat_chunks(conn.resp_body)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "internal_error"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/path"
    refute conn.resp_body =~ "provider_stack"
    refute conn.resp_body =~ "data: [DONE]\n\n"
    assert FakeUpstream.count(upstream) == 1
  end

  test "POST /v1/chat/completions falls back to Responses input and preserves additional tools",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_chat_fallback_input",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "fallback answer"}]
            }
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    additional_tools_item = additional_tools_item()

    absent_messages_conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{"role" => "user", "content" => "synthetic chat fallback input"},
          additional_tools_item
        ]
      })

    empty_messages_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "messages" => [],
        "input" => "synthetic empty-message fallback input"
      })

    assert %{"id" => "resp_chat_fallback_input", "object" => "chat.completion"} =
             json_response(absent_messages_conn, 200)

    assert %{"id" => "resp_chat_fallback_input", "object" => "chat.completion"} =
             json_response(empty_messages_conn, 200)

    assert [absent_messages_request, empty_messages_request] = FakeUpstream.requests(upstream)

    assert absent_messages_request.path == "/backend-api/codex/responses"
    assert absent_messages_request.json["stream"] == true
    assert absent_messages_request.json["store"] == false
    refute Map.has_key?(absent_messages_request.json, "tools")
    refute Map.has_key?(absent_messages_request.json, "tool_choice")

    assert absent_messages_request.json["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "synthetic chat fallback input"}
               ]
             },
             additional_tools_item
           ]

    assert empty_messages_request.path == "/backend-api/codex/responses"

    assert empty_messages_request.json["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "synthetic empty-message fallback input"}
               ]
             }
           ]

    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert length(requests) == 2
    assert Enum.all?(requests, &(&1.status == "succeeded"))
    assert Enum.all?(requests, &(&1.endpoint == "/backend-api/codex/responses"))
    assert Repo.aggregate(Attempt, :count) == 2

    metadata_text = inspect(Enum.map(requests, & &1.request_metadata))
    refute metadata_text =~ "synthetic chat fallback input"
    refute metadata_text =~ "synthetic empty-message fallback input"
    refute metadata_text =~ "lookup_additional_fixture"
  end

  test "POST /v1/chat/completions rejects malformed fallback input before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_cases = [
      {%{"messages" => []}, "invalid_request", "messages", "messages must be a non-empty array"},
      {%{
         "input" => [
           %{
             "type" => "additional_tools",
             "role" => "assistant",
             "tools" => [],
             "status" => "completed"
           }
         ]
       }, "invalid_request", "input", nil},
      {%{
         "input" => [
           %{
             "type" => "additional_tools",
             "role" => "developer",
             "tools" => [
               %{
                 "type" => "mcp",
                 "server_label" => "fixture-mcp",
                 "tunnel_id" => "mcp_tunnel_fixture"
               }
             ]
           }
         ]
       }, "invalid_request", "input", "remote MCP tools are not supported"},
      {%{"input" => "synthetic fallback input", "additional_tools" => []},
       "unsupported_parameter", "additional_tools", "Unsupported parameter: additional_tools"}
    ]

    Enum.each(invalid_cases, fn {payload_update, expected_code, expected_param, expected_message} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(
          "/v1/chat/completions",
          Map.put(payload_update, "model", setup.model.exposed_model_id)
        )

      assert %{"error" => error} = json_response(response, 400)
      assert error["code"] == expected_code
      assert error["param"] == expected_param

      if expected_message do
        assert error["message"] == expected_message
      end

      refute response.resp_body =~ "synthetic fallback input"
      refute response.resp_body =~ "completed"
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/chat/completions rejects malformed fallback instruction-role content before dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "developer",
            "content" => [%{"type" => "input_image", "image_url" => %{"url" => nil}}]
          }
        ]
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "invalid_request"
    assert error["param"] == "input"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :unsupported_logprobs
  test "POST /v1/chat/completions rejects unsupported logprobs before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", Map.put(chat_payload(setup), "logprobs", true))

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "unsupported_parameter"
    assert error["param"] == "logprobs"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/chat/completions translates SDK image and audio content parts", %{conn: conn} do
    audio_bytes = "synthetic wav bytes"
    audio_data = Base.encode64(audio_bytes)

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_chat_multimodal",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "synthetic multimodal answer"}]
            }
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
        })
      )

    setup = gateway_setup(upstream)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "synthetic multimodal chat"},
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/sample.png"}},
            %{
              "type" => "input_audio",
              "input_audio" => %{"data" => audio_data, "format" => "wav"}
            }
          ]
        }
      ]
    }

    conn = conn |> auth(setup) |> post("/v1/chat/completions", payload)

    assert %{"id" => "resp_chat_multimodal"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert [%{"content" => content}] = captured.json["input"]
    assert Enum.map(content, & &1["type"]) == ["input_text", "input_image", "input_audio"]
    assert Enum.at(content, 1)["image_url"] == "https://example.com/sample.png"
    assert get_in(Enum.at(content, 2), ["input_audio", "format"]) == "wav"

    [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic multimodal chat"
    refute metadata =~ audio_bytes
    refute metadata =~ audio_data
    refute metadata =~ "https://example.com/sample.png"
  end

  test "POST /v1/chat/completions rejects unsupported multimodal content before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_payloads = [
      %{
        "model" => setup.model.exposed_model_id,
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "image_url", "image_url" => "http://example.com/private.png"}
            ]
          }
        ]
      },
      %{
        "model" => setup.model.exposed_model_id,
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "input_audio",
                "input_audio" => %{"data" => Base.encode64("unsupported"), "format" => "flac"}
              }
            ]
          }
        ]
      }
    ]

    Enum.each(invalid_payloads, fn payload ->
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", payload)

      assert %{"error" => %{"code" => code}} = json_response(response, 400)
      assert code in ["invalid_request", "unsupported_input_image_format"]
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/chat/completions rejects invalid strict nested function tools before dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    sentinel = "STRICT_FUNCTION_SENTINEL_DO_NOT_LOG"

    conn =
      conn
      |> auth(setup)
      |> post(
        "/v1/chat/completions",
        Map.put(chat_payload(setup), "tools", [invalid_function_tool(sentinel)])
      )

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "invalid_function_parameters"
    assert error["param"] == "tools.0.parameters.required"
    refute conn.resp_body =~ sentinel
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/chat/completions translates named tool_choice and parallel tool call flags", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_chat_tool_choice",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
            }
          ],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    payload =
      chat_payload(setup)
      |> Map.put("tools", [function_tool()])
      |> Map.put("tool_choice", %{
        "type" => "function",
        "function" => %{"name" => "lookup_fixture"}
      })
      |> Map.put("parallel_tool_calls", false)

    conn = conn |> auth(setup) |> post("/v1/chat/completions", payload)

    assert %{"id" => "resp_chat_tool_choice"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["tool_choice"] == %{"type" => "function", "name" => "lookup_fixture"}
    assert captured.json["parallel_tool_calls"] == false
  end

  test "POST /v1/chat/completions rejects malformed tools and tool_choice before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_payloads = [
      Map.put(chat_payload(setup), "tools", [
        %{"type" => "function", "function" => %{"name" => "lookup_fixture"}}
      ]),
      Map.put(chat_payload(setup), "tools", [
        %{"type" => "function", "function" => %{"name" => "lookup_fixture", "parameters" => []}}
      ]),
      Map.put(chat_payload(setup), "tools", [
        %{"type" => "unknown", "function" => %{"name" => "lookup_fixture", "parameters" => %{}}}
      ]),
      chat_payload(setup)
      |> Map.put("tools", [function_tool()])
      |> Map.put("tool_choice", %{"type" => "function", "name" => "missing_fixture"}),
      chat_payload(setup)
      |> Map.put("tools", [function_tool()])
      |> Map.put("tool_choice", %{"type" => "function", "function" => %{}})
    ]

    Enum.each(invalid_payloads, fn payload ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/chat/completions", payload)

      assert %{"error" => error} = json_response(response, 400)
      assert error["code"] == "invalid_request"
      assert error["param"] in ["tools", "tool_choice"]
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/chat/completions rejects legacy function fields before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    for {field, value} <- [
          {"functions", [%{"name" => "legacy_fixture"}]},
          {"function_call", "auto"}
        ] do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/chat/completions", Map.put(chat_payload(setup), field, value))

      assert %{"error" => error} = json_response(response, 400)
      assert error["code"] == "invalid_request"
      assert error["param"] == field
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp chat_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "messages" => [
        %{"role" => "system", "content" => "Synthetic system"},
        %{"role" => "user", "content" => "Synthetic user"}
      ]
    }
  end

  defp function_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "lookup_fixture",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}}
        }
      }
    }
  end

  defp additional_tools_item do
    %{
      "type" => "additional_tools",
      "role" => "developer",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup_additional_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }
  end

  defp invalid_function_tool(sentinel) do
    %{
      "type" => "function",
      "function" => %{
        "name" => "lookup_fixture",
        "description" => sentinel,
        "strict" => true,
        "parameters" => %{
          "type" => "object",
          "additionalProperties" => false,
          "description" => sentinel,
          "properties" => %{
            "ok" => %{"type" => "boolean", "description" => sentinel}
          },
          "required" => []
        }
      }
    }
  end

  defp provider_invalid_request_error(code, provider_message, param) do
    %{
      "type" => "invalid_request_error",
      "code" => code,
      "message" => provider_message,
      "param" => param
    }
  end

  defp chat_chunk_ids(body) do
    ~r/"id":"([^"]+)"/
    |> Regex.scan(body)
    |> Enum.map(fn [_match, id] -> id end)
  end

  defp chat_chunks(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.map(&Jason.decode!/1)
  end
end
