defmodule CodexPoolerWeb.Runtime.BackendCodexCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  test "compaction trigger aliases enforce reasoning before compact dispatch", %{conn: conn} do
    for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream, compact?: true)

      setup.api_key
      |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
      |> Repo.update!()

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "input" => visible_input("synthetic") ++ [compaction_trigger()],
          "stream" => true,
          "reasoning" => %{"effort" => "high"}
        })

      assert %{
               "error" => %{
                 "code" => "reasoning_effort_not_allowed",
                 "message" => "reasoning effort is not available for this API key",
                 "param" => "reasoning.effort"
               }
             } = json_response(response, 400)

      assert FakeUpstream.count(upstream) == 0
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/codex/responses/compact"
      assert request.status == "rejected"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) ==
               0
    end
  end

  test "compaction trigger aliases apply exact reasoning to compact upstream", %{conn: conn} do
    for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_compact_policy",
            "object" => "response.compaction",
            "output" => [
              %{"type" => "compaction", "encrypted_content" => "synthetic-compact-content"}
            ]
          })
        )

      setup = gateway_setup(upstream, compact?: true)

      setup.api_key
      |> Ecto.Changeset.change(enforced_reasoning_effort: "high")
      |> Repo.update!()

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "input" => visible_input("synthetic") ++ [compaction_trigger()],
          "stream" => true,
          "reasoning" => %{"effort" => "low"}
        })

      assert response.status == 200
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses/compact"
      assert captured.json["reasoning"] == %{"effort" => "high"}
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert get_in(attempt.response_metadata, ["reasoning", "policy_mode"]) == "always_use"
      assert get_in(attempt.response_metadata, ["reasoning", "applied_effort"]) == "high"
    end
  end

  @tag :model_serving_modes
  test "both backend compact aliases keep the selected Pool mode for JSON and SSE", %{
    conn: conn
  } do
    for path <- [
          "/backend-api/codex/responses/compact",
          "/backend-api/codex/v1/responses/compact"
        ],
        stream? <- [false, true] do
      upstream = start_upstream(compact_mode_matrix_upstream(stream?))
      setup = gateway_setup(upstream, compact?: true)

      payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic compact mode input",
        "stream" => stream?
      }

      put_compact_model_serving_mode!(setup, "full")

      full_response =
        conn
        |> recycle()
        |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-lite")
        |> auth(setup)
        |> post(path, payload)

      assert_compact_mode_matrix_response!(full_response, stream?)

      put_compact_model_serving_mode!(setup, "lite")

      lite_response =
        conn
        |> recycle()
        |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-lite")
        |> auth(setup)
        |> post(path, payload)

      assert_compact_mode_matrix_response!(lite_response, stream?)

      assert [full_capture, lite_capture] = FakeUpstream.requests(upstream)
      assert full_capture.path == "/backend-api/codex/responses/compact"
      assert lite_capture.path == "/backend-api/codex/responses/compact"
      assert full_capture.json["model"] == setup.model.upstream_model_id
      assert lite_capture.json["model"] == setup.model.upstream_model_id

      assert Map.drop(full_capture.json, ["reasoning", "parallel_tool_calls"]) ==
               Map.drop(lite_capture.json, ["reasoning", "parallel_tool_calls"])

      assert get_in(lite_capture.json, ["reasoning", "context"]) == "all_turns"
      assert lite_capture.json["parallel_tool_calls"] == false
      assert_compact_mode_matrix_headers!(full_capture, lite_capture)
      assert_compact_mode_matrix_metadata!(setup, ["full", "lite"])
    end
  end

  @tag :client_metadata
  test "POST /backend-api/codex/responses bridges terminal compaction_trigger to compact SSE", %{
    conn: conn
  } do
    request_turn_state = "compact-bridge-request-turn-state-#{System.unique_integer([:positive])}"

    response_turn_state =
      "compact-bridge-response-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "id" => "resp_compaction_bridge",
            "object" => "response.compaction",
            "output" => [
              %{
                "type" => "compaction",
                "encrypted_content" => "encrypted-compact-fixture"
              }
            ],
            "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8},
            "raw_compact_detail" => "must-not-leak"
          },
          [{"x-codex-turn-state", response_turn_state}]
        )
      )

    setup =
      upstream
      |> gateway_setup(
        compact?: true,
        model_metadata: %{
          "upstream_model" => %{
            "capabilities" => %{
              "responses" => true,
              "streaming" => true,
              "reasoning" => true
            },
            "service_tiers" => [
              %{
                "id" => "priority",
                "name" => "Priority",
                "description" => "Priority processing for synthetic tests."
              }
            ]
          }
        }
      )
      |> enable_priority_service_tier!()

    input = visible_input("compact bridge visible fixture")

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "instructions" => "compact bridge instruction",
        "input" => input ++ [compaction_trigger()],
        "stream" => true,
        "include" => ["reasoning.encrypted_content"],
        "reasoning" => %{"effort" => "low"},
        "store" => false,
        "service_tier" => "priority",
        "promptCacheKey" => "compact-camel-cache-key",
        "previous_response_id" => "resp_previous_compact",
        "conversation" => "conv_compact_fixture"
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert get_resp_header(conn, "x-codex-turn-state") == [response_turn_state]

    events = backend_sse_events(response(conn, 200))
    assert Enum.map(events, & &1["event"]) == ["response.output_item.done", "response.completed"]
    assert response(conn, 200) =~ "data: [DONE]\n\n"

    assert %{
             "type" => "response.output_item.done",
             "item" => %{
               "type" => "compaction",
               "encrypted_content" => "encrypted-compact-fixture"
             }
           } = List.first(events)["data"]

    assert %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_compaction_bridge",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "compaction",
                   "encrypted_content" => "encrypted-compact-fixture"
                 }
               ],
               "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
             }
           } = List.last(events)["data"]

    refute response(conn, 200) =~ "raw_compact_detail"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["instructions"] == "compact bridge instruction"
    assert captured.json["input"] == input
    assert captured.json["reasoning"] == %{"effort" => "low"}
    refute Map.has_key?(captured.json, "store")
    assert captured.json["service_tier"] == "priority"
    assert captured.json["prompt_cache_key"] == "compact-camel-cache-key"
    assert captured.json["previous_response_id"] == "resp_previous_compact"
    assert captured.json["conversation"] == "conv_compact_fixture"
    refute Map.has_key?(captured.json, "stream")
    refute Map.has_key?(captured.json, "include")
    refute inspect(captured.json) =~ "compaction_trigger"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    persistence_text = inspect({request, attempt})
    refute persistence_text =~ request_turn_state
    refute persistence_text =~ response_turn_state
  end

  test "POST /backend-api/codex/v1/responses bridges compaction_summary result shape", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_compaction_summary_bridge",
          "object" => "response.compaction",
          "compaction_summary" => %{
            "encrypted_content" => "encrypted-summary-fixture",
            "plaintext_summary" => "must-not-leak"
          },
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => visible_input("compact alias visible fixture") ++ [compaction_trigger()],
        "stream" => true
      })

    assert conn.status == 200
    assert response(conn, 200) =~ "encrypted-summary-fixture"
    refute response(conn, 200) =~ "plaintext_summary"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "succeeded"
  end

  test "POST /backend-api/codex/responses extracts compaction_summary output items", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_compaction_summary_item_bridge",
          "object" => "response.compaction",
          "output" => [
            %{
              "type" => "compaction_summary",
              "encrypted_content" => "encrypted-summary-item-fixture",
              "plaintext_summary" => "must-not-leak"
            }
          ]
        })
      )

    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => visible_input("compact summary item fixture") ++ [compaction_trigger()],
        "stream" => true
      })

    assert conn.status == 200
    assert response(conn, 200) =~ "encrypted-summary-item-fixture"
    refute response(conn, 200) =~ "plaintext_summary"
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
  end

  test "POST /backend-api/codex/responses rejects malformed compaction_trigger before dispatch",
       %{
         conn: _conn
       } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream, compact?: true)

    invalid_inputs = [
      [compaction_trigger()],
      [compaction_trigger() | visible_input("non-terminal trigger fixture")],
      [
        %{"type" => "reasoning", "encrypted_content" => "hidden-only-trigger-fixture"},
        compaction_trigger()
      ],
      visible_input("duplicate trigger fixture") ++ [compaction_trigger(), compaction_trigger()]
    ]

    Enum.each(invalid_inputs, fn input ->
      conn =
        build_conn()
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => input,
          "stream" => true
        })

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_request"
      assert error["param"] == "input"
      refute inspect(error) =~ "duplicate trigger fixture"
      refute inspect(error) =~ "hidden-only-trigger-fixture"
      refute inspect(error) =~ "non-terminal trigger fixture"
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "compact SSE terminal failure finalizes as a failure without duplicating relayed blocks",
       %{conn: conn} do
    # Regression: the compact stream writer must classify terminal events like
    # every other SSE stream. Before the fix, a compact stream ending in
    # response.failed was relayed and finalized as a SUCCESSFUL request, and the
    # exhaustion path replayed the full retained body (duplicating blocks that
    # had already been written downstream).
    rate_limits_block =
      "event: codex.rate_limits\n" <>
        "data: #{Jason.encode!(%{"type" => "codex.rate_limits", "rate_limits" => %{"secondary" => %{"used_percent" => 11, "window_minutes" => 10_080, "reset_at" => DateTime.to_unix(DateTime.add(DateTime.utc_now(), 3, :day))}}})}\n\n"

    {_event, failed_payload} = first_event_terminal_payload("response.failed", "server_error")

    failure_block =
      "event: response.failed\n" <> "data: #{Jason.encode!(failed_payload)}\n\n"

    upstream = start_upstream({:sse, [rate_limits_block, failure_block]})
    setup = gateway_setup(upstream, compact?: true)

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => visible_input("synthetic"),
        "stream" => true
      })

    # The client received the terminal failure exactly once, and the already
    # relayed rate-limits block was not replayed by the final delivery.
    body = response.resp_body
    assert length(String.split(body, "event: response.failed")) == 2
    assert length(String.split(body, "event: codex.rate_limits")) == 2

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    refute request.status == "succeeded"

    attempts = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    refute Enum.any?(attempts, &(&1.status == "succeeded"))
  end

  defp visible_input(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    ]
  end

  defp compaction_trigger, do: %{"type" => "compaction_trigger"}

  defp put_compact_model_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.get_by(ModelServingOverride,
           pool_id: setup.pool.id,
           exposed_model_id: setup.model.exposed_model_id
         ) do
      nil ->
        Repo.insert!(%ModelServingOverride{
          pool_id: setup.pool.id,
          exposed_model_id: setup.model.exposed_model_id,
          mode: mode,
          created_at: timestamp,
          updated_at: timestamp
        })

      override ->
        override
        |> Ecto.Changeset.change(mode: mode, updated_at: timestamp)
        |> Repo.update!()
    end
  end

  defp compact_mode_matrix_upstream(true) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_compact_mode_matrix",
           "status" => "completed",
           "output" => []
         }
       }}
    ])
  end

  defp compact_mode_matrix_upstream(false) do
    FakeUpstream.json_response(%{
      "id" => "resp_compact_mode_matrix",
      "object" => "response.compaction",
      "output" => [
        %{"type" => "compaction", "encrypted_content" => "encrypted-compact-mode-fixture"}
      ]
    })
  end

  defp assert_compact_mode_matrix_response!(response, false) do
    assert %{"id" => "resp_compact_mode_matrix", "object" => "response.compaction"} =
             json_response(response, 200)
  end

  defp assert_compact_mode_matrix_response!(response, true) do
    assert response.status == 200
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/event-stream"
    assert response.resp_body =~ "response.completed"
  end

  defp assert_compact_mode_matrix_headers!(full_capture, lite_capture) do
    mode_header = "x-openai-internal-codex-responses-lite"
    full_headers = Map.new(full_capture.headers)
    lite_headers = Map.new(lite_capture.headers)

    refute Map.has_key?(full_headers, mode_header)
    assert lite_headers[mode_header] == "true"
    assert comparable_compact_headers(full_headers) == comparable_compact_headers(lite_headers)
  end

  defp comparable_compact_headers(headers) do
    Map.drop(headers, [
      "x-openai-internal-codex-responses-lite",
      "content-length",
      "host",
      "authorization",
      "chatgpt-account-id"
    ])
  end

  defp assert_compact_mode_matrix_metadata!(setup, modes) do
    expected_keys = [
      "model_serving_mode_configured",
      "model_serving_mode",
      "model_serving_mode_source"
    ]

    requests =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
        )
      )

    assert length(requests) == length(modes)

    for {request, mode} <- Enum.zip(requests, modes) do
      expected = %{
        "model_serving_mode_configured" => mode,
        "model_serving_mode" => mode,
        "model_serving_mode_source" => "override"
      }

      assert request.endpoint == "/backend-api/codex/responses/compact"
      assert request.status == "succeeded"
      assert Map.take(request.request_metadata["routing"], expected_keys) == expected

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"
      assert Map.take(attempt.response_metadata["routing"], expected_keys) == expected
    end
  end

  defp enable_priority_service_tier!(setup) do
    setup.model
    |> Ecto.Changeset.change(%{
      metadata:
        Map.put(setup.model.metadata, "source_assignment_models", %{
          setup.assignment.id => setup.model.metadata["upstream_model"]
        })
    })
    |> Repo.update!()

    setup
  end

  defp backend_sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case backend_sse_event(block) do
        nil -> []
        event -> [event]
      end
    end)
  end

  defp backend_sse_event(block) do
    lines = String.split(block, "\n")
    event = lines |> Enum.find(&String.starts_with?(&1, "event: ")) |> strip_prefix("event: ")
    data = lines |> Enum.find(&String.starts_with?(&1, "data: ")) |> strip_prefix("data: ")

    if is_binary(event) and is_binary(data) and data != "[DONE]" do
      %{"event" => event, "data" => Jason.decode!(data)}
    end
  end

  defp strip_prefix(nil, _prefix), do: nil
  defp strip_prefix(line, prefix), do: String.replace_prefix(line, prefix, "")
end
