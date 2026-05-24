defmodule CodexPoolerWeb.V1.ChatCompletionsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
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

    conn =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", chat_payload(setup))

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

    assert [
             %{"type" => "message", "role" => "system"},
             %{"type" => "message", "role" => "user"}
           ] = captured.json["input"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
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
      |> post("/v1/chat/completions", Map.put(chat_payload(setup), "stream", true))

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "\"object\":\"chat.completion.chunk\""
    assert conn.resp_body =~ "\"role\":\"assistant\""
    assert conn.resp_body =~ "\"content\":\"streamed answer\""
    assert conn.resp_body =~ "\"finish_reason\":\"stop\""
    assert conn.resp_body =~ "data: [DONE]\n\n"
    refute conn.resp_body =~ "response.output_text.delta"
    refute conn.resp_body =~ "codex.rate_limits"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
  end

  test "POST /v1/chat/completions normalizes upstream JSON errors", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic chat upstream validation"
             },
             "response" => %{"id" => "resp_chat_failed", "status" => "failed"}
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn = conn |> auth(setup) |> post("/v1/chat/completions", chat_payload(setup))

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_request_error"
    assert error["message"] == "synthetic chat upstream validation"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert [_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
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
end
