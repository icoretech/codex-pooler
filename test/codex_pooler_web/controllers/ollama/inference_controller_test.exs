defmodule CodexPoolerWeb.Ollama.InferenceControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
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
end
