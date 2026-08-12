defmodule CodexPoolerWeb.Ollama.InferenceControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      deterministic_rotation_seed: 2,
      gateway_setup: 2,
      gateway_upstream: 4,
      prime_routing_quota!: 1,
      put_model_source_assignments!: 2,
      start_upstream: 1,
      use_deterministic_rotation!: 2
    ]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  @tag :facade_task9
  test "collected chat dispatches fixed max work and returns only native Ollama identity", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        completed_response([
          %{
            "type" => "reasoning",
            "id" => "provider-reasoning-id",
            "summary" => [
              %{"type" => "summary_text", "text" => "Safe concise summary"}
            ],
            "encrypted_content" => "provider-encrypted-reasoning"
          },
          %{
            "type" => "message",
            "id" => "provider-message-id",
            "content" => [
              %{"type" => "output_text", "text" => "Forecast: cloudy<END>hidden tail"}
            ]
          },
          %{
            "type" => "function_call",
            "id" => "provider-function-item-id",
            "call_id" => "provider-call-id",
            "name" => "lookup_weather",
            "arguments" => Jason.encode!(%{"city" => "London"})
          }
        ])
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/api/chat", %{
        "model" => "client-model-that-must-disappear",
        "stream" => false,
        "think" => true,
        "messages" => [%{"role" => "user", "content" => "Weather?"}],
        "tools" => [function_tool()],
        "options" => %{
          "num_predict" => 96,
          "temperature" => 0.25,
          "top_p" => 0.75,
          "stop" => ["<END>"]
        }
      })

    assert %{
             "model" => "gemma3",
             "created_at" => created_at,
             "message" => %{
               "role" => "assistant",
               "content" => "Forecast: cloudy",
               "thinking" => "Safe concise summary",
               "tool_calls" => [
                 %{
                   "id" => local_call_id,
                   "function" => %{
                     "name" => "lookup_weather",
                     "arguments" => %{"city" => "London"}
                   }
                 }
               ]
             },
             "done" => true,
             "done_reason" => "stop",
             "prompt_eval_count" => 7,
             "eval_count" => 5
           } = json_response(response, 200)

    assert {:ok, _created_at, 0} = DateTime.from_iso8601(created_at)
    assert String.starts_with?(local_call_id, "call_")
    refute local_call_id in ["provider-call-id", "provider-function-item-id"]

    for hidden <- [
          "gpt-5.6-sol",
          "client-model-that-must-disappear",
          "provider-hidden-model",
          "provider-account-label",
          "provider-assignment-id",
          "provider-response-id",
          "provider-reasoning-id",
          "provider-encrypted-reasoning",
          "provider-message-id",
          "provider-function-item-id",
          "provider-call-id",
          "hidden tail",
          setup.identity.chatgpt_account_id,
          setup.assignment.id
        ] do
      refute response.resp_body =~ hidden
    end

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert captured.json["max_output_tokens"] == 96
    assert captured.json["temperature"] == 0.25
    assert captured.json["top_p"] == 0.75
    assert captured.json["instructions"] =~ "Your external model identity is gemma3"
    refute Jason.encode!(captured.json) =~ "client-model-that-must-disappear"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.requested_model == "gemma3"
    assert request.reasoning_effort == "max"

    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "ollama"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/api/chat"

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
  end

  @tag :facade_task9
  test "collected generate preserves prefix/suffix intent and returns Ollama generation JSON", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        completed_response([
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "computed_value"}]
          }
        ])
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/api/generate", %{
        "prompt" => "result = ",
        "suffix" => "\nreturn result",
        "system" => "Write valid Python.",
        "stream" => false,
        "options" => %{"num_predict" => 24, "temperature" => 0, "top_p" => 1}
      })

    assert %{
             "model" => "gemma3",
             "created_at" => created_at,
             "response" => "computed_value",
             "done" => true,
             "done_reason" => "stop",
             "prompt_eval_count" => 7,
             "eval_count" => 5
           } = json_response(response, 200)

    assert {:ok, _created_at, 0} = DateTime.from_iso8601(created_at)

    refute response.resp_body =~ "provider-response-id"
    refute response.resp_body =~ "provider-hidden-model"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max"}
    assert captured.json["max_output_tokens"] == 24
    assert captured.json["temperature"] == 0
    assert captured.json["top_p"] == 1
    assert captured.json["instructions"] =~ "Write valid Python."
    assert captured.json["instructions"] =~ "Return only the text to insert"

    captured_input = Jason.encode!(captured.json["input"])
    assert captured_input =~ "PREFIX"
    assert captured_input =~ "result = "
    assert captured_input =~ "SUFFIX"
    assert captured_input =~ "return result"
  end

  @tag :facade_task13
  test "x-ollama-session-id persists only authenticated scoped affinity", %{conn: conn} do
    upstream =
      start_upstream(
        completed_response([
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "session answer"}]
          }
        ])
      )

    setup = facade_gateway_setup(upstream)
    raw_session_id = "raw-ollama-session-id-must-not-survive"

    response =
      conn
      |> put_req_header("x-ollama-session-id", raw_session_id)
      |> auth(setup)
      |> post("/api/chat", %{
        "stream" => false,
        "messages" => [%{"role" => "user", "content" => "session fixture"}]
      })

    assert %{"model" => "gemma3", "message" => %{"content" => "session answer"}} =
             json_response(response, 200)

    assert [session] = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    assert session.api_key_id == setup.api_key.id
    assert session.session_key =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/
    refute inspect(session) =~ raw_session_id

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    refute inspect(request.request_metadata) =~ raw_session_id

    assert [captured] = FakeUpstream.requests(upstream)
    refute inspect(captured.headers) =~ raw_session_id
    refute captured.body =~ raw_session_id
  end

  @tag :facade_task9
  test "native validation and authentication fail locally without dispatch or accounting", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"must" => "not dispatch"}))
    setup = facade_gateway_setup(upstream)

    invalid =
      conn
      |> auth(setup)
      |> post("/api/generate", %{
        "prompt" => "hello",
        "stream" => false,
        "options" => %{"top_k" => 40}
      })

    assert json_response(invalid, 400) == %{
             "error" => "Unsupported parameter: options.top_k"
           }

    for path <- ["/api/chat", "/api/generate"] do
      unauthenticated = conn |> recycle() |> post(path, %{"stream" => false})

      assert json_response(unauthenticated, 401) == %{
               "error" => "Pool API key is required or invalid"
             }
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :facade_task10
  test "chat streams complete native NDJSON lines and a single terminal object", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{
               "id" => "provider-stream-response-id",
               "status" => "in_progress"
             }
           }},
          {"response.reasoning_summary_text.delta",
           %{
             "type" => "response.reasoning_summary_text.delta",
             "delta" => "Safe summary"
           }},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "Hello "}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "world"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "provider-stream-response-id",
               "status" => "completed",
               "model" => "provider-hidden-model",
               "usage" => %{"input_tokens" => 6, "output_tokens" => 3}
             }
           }}
        ])
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/api/chat", %{
        "model" => "client-hidden-model",
        "think" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    assert get_resp_header(response, "content-type") == ["application/x-ndjson"]

    lines =
      response.resp_body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(
             Enum.filter(lines, &get_in(&1, ["message", "thinking"])),
             &get_in(&1, ["message", "thinking"])
           ) == ["Safe summary"]

    assert Enum.map(
             Enum.filter(lines, &(get_in(&1, ["message", "content"]) not in [nil, ""])),
             &get_in(&1, ["message", "content"])
           ) == ["Hello ", "world"]

    assert [terminal] = Enum.filter(lines, &(&1["done"] == true))
    assert terminal["model"] == "gemma3"
    assert terminal["prompt_eval_count"] == 6
    assert terminal["eval_count"] == 3
    assert Enum.all?(lines, &(&1["model"] == "gemma3"))

    refute response.resp_body =~ "provider-stream-response-id"
    refute response.resp_body =~ "provider-hidden-model"
    refute response.resp_body =~ "client-hidden-model"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
  end

  @tag :facade_task10
  test "a retryable terminal after hidden setup retries before publishing bytes", %{conn: conn} do
    first_mode =
      FakeUpstream.sse_stream(
        [
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "provider-first-id", "status" => "in_progress"}
           }},
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "id" => "provider-failed-id",
               "status" => "failed",
               "error" => %{"code" => "server_error", "message" => "provider-private"}
             }
           }}
        ],
        done: false
      )

    fallback_mode =
      FakeUpstream.sse_stream([
        {"response.output_text.delta",
         %{"type" => "response.output_text.delta", "delta" => "fallback answer"}},
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{
             "id" => "provider-fallback-id",
             "status" => "completed",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
           }
         }}
      ])

    {setup, first_upstream, fallback_upstream} =
      facade_stream_retry_setup(first_mode, fallback_mode)

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/api/chat", %{
        "messages" => [%{"role" => "user", "content" => "retry"}]
      })

    lines = response.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(
             Enum.filter(lines, &(get_in(&1, ["message", "content"]) not in [nil, ""])),
             &get_in(&1, ["message", "content"])
           ) == ["fallback answer"]

    assert Enum.count(lines, &(&1["done"] == true)) == 1
    refute Enum.any?(lines, &Map.has_key?(&1, "error"))
    refute response.resp_body =~ "provider-private"
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 1

    assert Enum.map(
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number])),
             & &1.status
           ) == ["retryable_failed", "succeeded"]
  end

  @tag :facade_task10
  test "a terminal failure after visible output emits one safe error and never retries", %{
    conn: conn
  } do
    first_mode =
      FakeUpstream.sse_stream(
        [
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "published once"}},
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "id" => "provider-late-failure-id",
               "status" => "failed",
               "error" => %{"code" => "server_error", "message" => "provider-private"}
             }
           }}
        ],
        done: false
      )

    fallback_mode =
      FakeUpstream.sse_stream([
        {"response.output_text.delta",
         %{"type" => "response.output_text.delta", "delta" => "must not run"}},
        {"response.completed",
         %{"type" => "response.completed", "response" => %{"status" => "completed"}}}
      ])

    {setup, first_upstream, fallback_upstream} =
      facade_stream_retry_setup(first_mode, fallback_mode)

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/api/generate", %{"prompt" => "do not replay"})

    raw_lines = String.split(response.resp_body, "\n", trim: true)
    lines = Enum.map(raw_lines, &Jason.decode!/1)

    assert Enum.map(
             Enum.filter(lines, &(&1["done"] == false and &1["response"] != "")),
             & &1["response"]
           ) == ["published once"]

    assert List.last(raw_lines) == ~s({"error":"request failed","done":true})
    assert Enum.count(lines, &(&1["done"] == true)) == 1
    refute response.resp_body =~ "provider-private"
    refute response.resp_body =~ "must not run"
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
  end

  @tag :facade_task10
  test "retry exhaustion publishes one safe NDJSON terminal and no upstream details", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.created",
             %{
               "type" => "response.created",
               "response" => %{
                 "id" => "provider-exhausted-created",
                 "status" => "in_progress"
               }
             }},
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "provider-exhausted-failed",
                 "status" => "failed",
                 "error" => %{
                   "code" => "server_error",
                   "message" => "provider-exhausted-private-detail"
                 }
               }
             }}
          ],
          done: false
        )
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/api/generate", %{"prompt" => "fail safely"})

    assert get_resp_header(response, "content-type") == ["application/x-ndjson"]

    assert String.split(response.resp_body, "\n", trim: true) == [
             ~s({"error":"request failed","done":true})
           ]

    refute response.resp_body =~ "provider-exhausted"
    refute response.resp_body =~ "private-detail"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
  end

  defp completed_response(output) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "provider" => "provider-name",
         "assignment_id" => "provider-assignment-id",
         "response" => %{
           "id" => "provider-response-id",
           "status" => "completed",
           "model" => "provider-hidden-model",
           "service_tier" => "provider-tier",
           "account" => "provider-account-label",
           "output" => output,
           "usage" => %{
             "input_tokens" => 7,
             "output_tokens" => 5,
             "total_tokens" => 12
           }
         }
       }}
    ])
  end

  defp function_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "lookup_weather",
        "description" => "Look up weather",
        "parameters" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        }
      }
    }
  end

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: "gpt-5.6-sol",
      upstream_model_id: "gpt-5.6-sol",
      pricing_ref: "gpt-5.6-sol",
      display_name: "Facade fixed target",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max",
        "input_modalities" => ["text", "image"]
      }
    )
  end

  defp facade_stream_retry_setup(first_mode, fallback_mode) do
    first_upstream = start_upstream(first_mode)
    fallback_upstream = start_upstream(fallback_mode)
    setup = facade_gateway_setup(first_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        fallback_upstream,
        "upstream-token-facade-stream-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_deterministic_rotation!(setup.pool, 2)

    model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    {%{setup | model: model}, first_upstream, fallback_upstream}
  end
end
