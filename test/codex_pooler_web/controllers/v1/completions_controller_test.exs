defmodule CodexPoolerWeb.V1.CompletionsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @tag :facade_task7
  test "POST /v1/completions translates a missing-model string request and cloaks the result", %{
    conn: conn
  } do
    upstream = start_upstream(completed_sse("collected answer", "provider-collected-id"))
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/completions", %{
        "prompt" => "legacy prompt sentinel",
        "max_tokens" => 23,
        "temperature" => 0.25,
        "top_p" => 0.75,
        "stop" => "HALT"
      })

    assert %{
             "id" => "cmpl_" <> _,
             "object" => "text_completion",
             "model" => "gemma3",
             "choices" => [
               %{
                 "index" => 0,
                 "text" => "collected answer",
                 "logprobs" => nil,
                 "finish_reason" => "stop"
               }
             ]
           } = json_response(response, 200)

    refute response.resp_body =~ "provider-collected-id"
    refute response.resp_body =~ "gpt-5.6-sol"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max"}
    assert prompt_text(captured.json) == "legacy prompt sentinel"
    assert captured.json["max_output_tokens"] == 23
    assert captured.json["temperature"] == 0.25
    assert captured.json["top_p"] == 0.75
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert captured.json["instructions"] =~ "Your external model identity is gemma3"
    refute Map.has_key?(captured.json, "stop")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.requested_model == "gemma3"
    assert request.request_metadata["effective_model"] == "gpt-5.6-sol"
  end

  @tag :facade_task7
  test "a non-streamed prompt list executes and accounts once per prompt in input order", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        {:sequence,
         [
           completed_sse("first answer", "provider-first"),
           completed_sse("second answer", "provider-second")
         ]}
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/completions", %{
        "model" => "arbitrary-client-model",
        "prompt" => ["first prompt", "second prompt"]
      })

    assert %{"model" => "gemma3", "choices" => choices} = json_response(response, 200)

    assert Enum.map(choices, &{&1["index"], &1["text"]}) == [
             {0, "first answer"},
             {1, "second answer"}
           ]

    assert Enum.map(FakeUpstream.requests(upstream), &prompt_text(&1.json)) == [
             "first prompt",
             "second prompt"
           ]

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    assert Repo.aggregate(Attempt, :count) == 2
    refute response.resp_body =~ "provider-first"
    refute response.resp_body =~ "provider-second"
    refute response.resp_body =~ "arbitrary-client-model"
    refute response.resp_body =~ "gpt-5.6-sol"
  end

  @tag :facade_task7
  test "streaming returns OpenAI text_completion SSE with gemma3 on every chunk", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "streamed legacy answer"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "provider-stream-id",
               "model" => "provider-hidden-model",
               "status" => "completed",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/completions", %{
        "model" => "ignored",
        "prompt" => "stream prompt",
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
      })

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["text/event-stream"]
    assert response.resp_body =~ "\"object\":\"text_completion\""
    assert response.resp_body =~ "\"model\":\"gemma3\""
    assert response.resp_body =~ "\"text\":\"streamed legacy answer\""
    assert response.resp_body =~ "\"usage\":{"
    assert response.resp_body =~ "data: [DONE]"
    refute response.resp_body =~ "provider-stream-id"
    refute response.resp_body =~ "provider-hidden-model"
    refute response.resp_body =~ "gpt-5.6-sol"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max"}
  end

  @tag :facade_task7
  test "rejects streamed prompt lists and unsafe legacy sampling controls before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(completed_sse("must not run", "must-not-run"))
    setup = facade_gateway_setup(upstream)

    cases = [
      {%{"prompt" => ["one", "two"], "stream" => true}, "prompt"},
      {%{"prompt" => "one", "best_of" => 2}, "best_of"},
      {%{"prompt" => "one", "logprobs" => 1}, "logprobs"},
      {%{"prompt" => "one", "echo" => true}, "echo"},
      {%{"prompt" => "one", "n" => 2}, "n"}
    ]

    for {payload, param} <- cases do
      response = conn |> recycle() |> auth(setup) |> post("/v1/completions", payload)
      assert %{"error" => %{"param" => ^param}} = json_response(response, 400)
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/completions requires a Pool API key", %{conn: conn} do
    response = post(conn, "/v1/completions", %{"prompt" => "hello"})

    assert %{"error" => %{"code" => "api_key_missing"}} = json_response(response, 401)
  end

  defp completed_sse(text, response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "model" => "provider-hidden-model",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => text}]
             }
           ],
           "usage" => %{"input_tokens" => 4, "output_tokens" => 5, "total_tokens" => 9}
         }
       }}
    ])
  end

  defp prompt_text(%{"input" => [%{"content" => [%{"text" => text}]}]}), do: text

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
        "default_reasoning_level" => "max"
      }
    )
  end
end
