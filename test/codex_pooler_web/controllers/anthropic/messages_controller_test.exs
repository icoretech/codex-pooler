defmodule CodexPoolerWeb.Anthropic.MessagesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
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
  alias CodexPooler.Repo

  @version "2023-06-01"

  test "accepts current version and beta syntax, dispatches fixed max work, and forwards neither header",
       %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("x-api-key", setup.raw_key)
      |> put_req_header("anthropic-version", @version)
      |> put_req_header(
        "anthropic-beta",
        "prompt-caching-2024-07-31, interleaved-thinking-2025-05-14"
      )
      |> post("/v1/messages", %{
        "model" => "claude-opus-client-alias",
        "max_tokens" => 96,
        "stream" => false,
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 1_024}
      })

    assert response.status == 200
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert captured.json["max_output_tokens"] == 96
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    refute Jason.encode!(captured.json) =~ "claude-opus-client-alias"

    captured_headers = Map.new(captured.headers)
    refute Map.has_key?(captured_headers, "anthropic-version")
    refute Map.has_key?(captured_headers, "anthropic-beta")
    refute Map.has_key?(captured_headers, "x-api-key")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.requested_model == "gemma3"
    assert request.reasoning_effort == "max"

    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) ==
             "anthropic"
  end

  test "accepts Bearer, x-api-key, and matching dual Pool credentials", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    credential_sets = [
      [{"authorization", setup.authorization}],
      [{"x-api-key", setup.raw_key}],
      [{"authorization", setup.authorization}, {"x-api-key", setup.raw_key}]
    ]

    for headers <- credential_sets do
      response =
        conn
        |> recycle()
        |> put_req_header("anthropic-version", @version)
        |> put_headers(headers)
        |> post("/v1/messages", minimal_message())

      assert response.status == 200
    end

    assert FakeUpstream.count(upstream) == 3
  end

  @tag :facade_task13
  test "Anthropic cache blocks keep scoped prefix affinity across uncached suffixes", %{
    conn: conn
  } do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)
    second_key = active_api_key_fixture(setup.pool)

    request = fn credential, suffix, client_model ->
      conn
      |> recycle()
      |> put_req_header("x-api-key", credential)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages", %{
        "model" => client_model,
        "max_tokens" => 32,
        "stream" => false,
        "system" => [
          %{
            "type" => "text",
            "text" => "stable cached controller prefix",
            "cache_control" => %{"type" => "ephemeral"}
          }
        ],
        "messages" => [%{"role" => "user", "content" => suffix}]
      })
    end

    first = request.(setup.raw_key, "first uncached suffix", "claude-client-cache-a")
    repeat = request.(setup.raw_key, "different uncached suffix", "claude-client-cache-b")
    other_key = request.(second_key.raw_key, "first uncached suffix", "claude-client-cache-c")

    for response <- [first, repeat, other_key] do
      assert %{"model" => "gemma3"} = json_response(response, 200)
    end

    assert [first_capture, repeat_capture, other_key_capture] = FakeUpstream.requests(upstream)
    assert first_capture.json["prompt_cache_key"] == repeat_capture.json["prompt_cache_key"]

    refute first_capture.json["prompt_cache_key"] ==
             other_key_capture.json["prompt_cache_key"]

    assert first_capture.json["prompt_cache_key"] =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/

    captured = inspect([first_capture, repeat_capture, other_key_capture])

    for hidden <- ["claude-client-cache-a", "claude-client-cache-b", "claude-client-cache-c"] do
      refute captured =~ hidden
      refute inspect(Repo.all(Request)) =~ hidden
    end
  end

  test "returns a collected Anthropic message with only local IDs and gemma3 identity", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        completed_response([
          %{
            "type" => "reasoning",
            "id" => "provider-reasoning-id",
            "encrypted_content" => "provider-encrypted-reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "Safe summary"}]
          },
          %{
            "type" => "message",
            "id" => "provider-message-id",
            "content" => [
              %{"type" => "output_text", "text" => "Forecast<END>provider-private-tail"}
            ]
          },
          %{
            "type" => "function_call",
            "id" => "provider-tool-id",
            "call_id" => "provider-call-id",
            "name" => "lookup_weather",
            "arguments" => ~s({"city":"London"})
          }
        ])
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages", %{
        "model" => "claude-client-selector",
        "max_tokens" => 96,
        "stream" => false,
        "stop_sequences" => ["<END>"],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 1_024},
        "messages" => [%{"role" => "user", "content" => "Weather?"}],
        "tools" => [
          %{
            "name" => "lookup_weather",
            "input_schema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      })

    assert %{
             "id" => message_id,
             "type" => "message",
             "role" => "assistant",
             "model" => "gemma3",
             "content" => [
               %{"type" => "thinking", "thinking" => "Safe summary", "signature" => signature},
               %{"type" => "text", "text" => "Forecast"},
               %{
                 "type" => "tool_use",
                 "id" => tool_id,
                 "name" => "lookup_weather",
                 "input" => %{"city" => "London"}
               }
             ],
             "stop_reason" => "stop_sequence",
             "stop_sequence" => "<END>",
             "usage" => %{
               "input_tokens" => 2,
               "cache_creation_input_tokens" => 0,
               "cache_read_input_tokens" => 0,
               "output_tokens" => 1
             }
           } = json_response(response, 200)

    assert String.starts_with?(message_id, "msg_")
    assert String.starts_with?(signature, "sig_")
    assert String.starts_with?(tool_id, "toolu_")

    for hidden <- [
          "gpt-5.6-sol",
          "claude-client-selector",
          "provider-hidden-response-id",
          "provider-hidden-model",
          "provider-reasoning-id",
          "provider-encrypted-reasoning",
          "provider-message-id",
          "provider-tool-id",
          "provider-call-id",
          "provider-private-tail",
          setup.identity.chatgpt_account_id,
          setup.assignment.id
        ] do
      refute response.resp_body =~ hidden
    end
  end

  test "streams exact Anthropic SSE with sanitized headers", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "hello"}},
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "provider-stream-id",
                 "model" => "provider-stream-model",
                 "status" => "completed",
                 "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
               }
             }}
          ],
          headers: [
            {"x-request-id", "provider-request-id"},
            {"x-openai-model", "provider-stream-model"},
            {"x-provider-account", "provider-account"},
            {"connection", "provider-private"},
            {"cache-control", "provider-private"}
          ]
        )
      )

    setup = facade_gateway_setup(upstream)
    local_request_id = Ecto.UUID.generate()

    response =
      conn
      |> put_req_header("x-request-id", local_request_id)
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages", %{
        "model" => "anything",
        "max_tokens" => 32,
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    events = sse_events(response.resp_body)

    assert Enum.map(events, & &1.event) == [
             "message_start",
             "content_block_start",
             "content_block_delta",
             "content_block_stop",
             "message_delta",
             "message_stop"
           ]

    assert get_in(hd(events).data, ["message", "model"]) == "gemma3"
    assert get_resp_header(response, "content-type") == ["text/event-stream"]
    assert get_resp_header(response, "cache-control") == ["no-cache"]
    assert get_resp_header(response, "x-request-id") == [local_request_id]
    assert get_resp_header(response, "x-openai-model") == []
    assert get_resp_header(response, "x-provider-account") == []
    assert get_resp_header(response, "connection") == []

    for hidden <- ["provider-stream-id", "provider-stream-model", "provider-account"] do
      refute response.resp_body =~ hidden
    end
  end

  test "maps a pre-stream upstream rejection to Anthropic JSON and status", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "error" => %{
              "type" => "provider_private_type",
              "code" => "provider_private_code",
              "message" => "provider private rejection"
            }
          },
          [
            {"x-request-id", "provider-request-id"},
            {"x-provider-account", "provider-account"}
          ],
          503
        )
      )

    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages", %{
        "max_tokens" => 32,
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "fail safely"}]
      })

    assert %{
             "type" => "error",
             "error" => %{
               "type" => "api_error",
               "message" => "gemma3 is temporarily unavailable"
             }
           } = json_response(response, 503)

    refute response.resp_body =~ "provider"
    assert get_resp_header(response, "x-provider-account") == []
  end

  test "a late terminal failure emits one Anthropic error event without retry or replay", %{
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
         %{"type" => "response.output_text.delta", "delta" => "must not run"}},
        {"response.completed",
         %{"type" => "response.completed", "response" => %{"status" => "completed"}}}
      ])

    {setup, first_upstream, fallback_upstream} =
      facade_stream_retry_setup(first_mode, fallback_mode)

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages", %{
        "max_tokens" => 32,
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "do not replay"}]
      })

    events = sse_events(response.resp_body)

    assert ["published once"] ==
             events
             |> Enum.filter(&(get_in(&1.data, ["delta", "type"]) == "text_delta"))
             |> Enum.map(&get_in(&1.data, ["delta", "text"]))

    assert List.last(events) == %{
             event: "error",
             data: %{
               "type" => "error",
               "error" => %{"type" => "api_error", "message" => "request failed"}
             }
           }

    assert Enum.count(events, &(&1.event == "error")) == 1
    refute response.resp_body =~ "provider-private"
    refute response.resp_body =~ "must not run"
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
  end

  test "a retryable terminal before Anthropic-visible bytes retries without publishing the first attempt",
       %{conn: conn} do
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
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages", %{
        "max_tokens" => 32,
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "retry safely"}]
      })

    events = sse_events(response.resp_body)

    assert ["fallback answer"] ==
             events
             |> Enum.filter(&(get_in(&1.data, ["delta", "type"]) == "text_delta"))
             |> Enum.map(&get_in(&1.data, ["delta", "text"]))

    assert List.last(events).event == "message_stop"
    refute Enum.any?(events, &(&1.event == "error"))
    refute response.resp_body =~ "provider-private"
    refute response.resp_body =~ "provider-first-id"
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 1

    assert Enum.map(
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number])),
             & &1.status
           ) == ["retryable_failed", "succeeded"]
  end

  test "rejects mismatched dual credentials before validation or dispatch", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)
    other = active_api_key_fixture(setup.pool)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-api-key", other.raw_key)
      |> post("/v1/messages", %{})

    assert %{
             "type" => "error",
             "error" => %{
               "type" => "authentication_error",
               "message" => "Pool API key is required or invalid"
             }
           } = json_response(response, 401)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "requires exactly the supported API version and bounded beta token syntax", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    cases = [
      {:missing_version, []},
      {:wrong_version, [{"anthropic-version", "2024-01-01"}]},
      {:blank_beta,
       [{"anthropic-version", @version}, {"anthropic-beta", "prompt-caching-2024-07-31,"}]},
      {:space_in_beta, [{"anthropic-version", @version}, {"anthropic-beta", "not a beta token"}]},
      {:control_in_beta,
       [{"anthropic-version", @version}, {"anthropic-beta", "beta-token\nother"}]}
    ]

    for {_label, headers} <- cases do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", setup.authorization)
        |> put_headers(headers)
        |> post("/v1/messages", minimal_message())

      assert %{
               "type" => "error",
               "error" => %{
                 "type" => "invalid_request_error",
                 "message" => message
               }
             } = json_response(response, 400)

      assert message in [
               "anthropic-version must be 2023-06-01",
               "anthropic-beta must be a comma-separated list of valid beta tokens"
             ]
    end

    duplicate_version =
      conn
      |> recycle()
      |> put_req_header("authorization", setup.authorization)
      |> Map.update!(:req_headers, fn headers ->
        [
          {"anthropic-version", @version},
          {"anthropic-version", @version}
          | Enum.reject(headers, fn {name, _value} -> name == "anthropic-version" end)
        ]
      end)
      |> post("/v1/messages", minimal_message())

    assert json_response(duplicate_version, 400)["error"]["type"] ==
             "invalid_request_error"

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "counts tokens locally and creates no request, attempt, or upstream traffic", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> put_req_header("anthropic-beta", "token-counting-2024-11-01")
      |> post("/v1/messages/count_tokens", %{
        "model" => "claude-sonnet-arbitrary-alias",
        "system" => "Count this system prompt",
        "messages" => [%{"role" => "user", "content" => "Count this message"}],
        "tools" => [
          %{
            "name" => "lookup",
            "input_schema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      })

    assert %{"input_tokens" => count} = json_response(response, 200)
    assert is_integer(count) and count > 0
    assert map_size(Jason.decode!(response.resp_body)) == 1
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "returns an Anthropic 400 for unbounded local count input without dispatch", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages/count_tokens", %{
        "messages" => [
          %{"role" => "user", "content" => String.duplicate("x", 8_193)}
        ]
      })

    assert %{
             "type" => "error",
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "request cannot be represented by the bounded local token counter"
             }
           } = json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp minimal_message do
    %{
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 32,
      "stream" => false
    }
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  defp completed_response(output \\ nil) do
    output =
      output ||
        [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "hello"}]
          }
        ]

    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "provider-hidden-response-id",
           "status" => "completed",
           "model" => "provider-hidden-model",
           "output" => output,
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
         }
       }}
    ])
  end

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    setup =
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

    prime_routing_quota!(setup.identity)
    setup
  end

  defp facade_stream_retry_setup(first_mode, fallback_mode) do
    first_upstream = start_upstream(first_mode)
    fallback_upstream = start_upstream(fallback_mode)
    setup = facade_gateway_setup(first_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        fallback_upstream,
        "upstream-token-anthropic-stream-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_deterministic_rotation!(setup.pool, 2)

    model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    {%{setup | model: model}, first_upstream, fallback_upstream}
  end

  defp sse_events(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, "\n")

      event =
        lines
        |> Enum.find(&String.starts_with?(&1, "event: "))
        |> String.replace_prefix("event: ", "")

      data =
        lines
        |> Enum.find(&String.starts_with?(&1, "data: "))
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()

      %{event: event, data: data}
    end)
  end
end
