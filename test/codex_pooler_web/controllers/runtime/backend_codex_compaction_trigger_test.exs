defmodule CodexPoolerWeb.Runtime.BackendCodexCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPooler.Gateway.OpenAICompatibility.AudioTestSupport,
    only: [assert_audio_accounting_metadata_only!: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Facade.IdentityInstruction
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  test "compaction trigger aliases reject API-key reasoning policies below the fixed maximum", %{
    conn: conn
  } do
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
                 "code" => "local_policy_denied",
                 "message" => "Request denied by local Pool policy",
                 "param" => nil
               }
             } = json_response(response, 403)

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
      |> Ecto.Changeset.change(enforced_reasoning_effort: "max")
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
      assert captured.json["reasoning"] == %{"effort" => "max"}
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert get_in(attempt.response_metadata, ["reasoning", "policy_mode"]) == "always_use"
      assert get_in(attempt.response_metadata, ["reasoning", "applied_effort"]) == "max"
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
  @tag :prompt_cache_adaptation
  test "POST /backend-api/codex/responses adapts nested prompt cache breakpoints before compact dispatch",
       %{
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

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{
            "type" => "input_text",
            "text" => "compact bridge visible fixture",
            "prompt_cache_breakpoint" => %{"mode" => "explicit"}
          },
          %{"type" => "input_text", "text" => "compact bridge second content item"}
        ]
      }
    ]

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

    assert captured.json["instructions"] ==
             "compact bridge instruction\n\n#{IdentityInstruction.instruction()}"

    assert captured.json["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "compact bridge visible fixture"},
                 %{"type" => "input_text", "text" => "compact bridge second content item"}
               ]
             }
           ]

    assert captured.json["reasoning"] == %{"effort" => "max"}
    refute Map.has_key?(captured.json, "store")
    assert captured.json["service_tier"] == "priority"
    assert captured.json["prompt_cache_key"] =~ ~r/^facade:[A-Za-z0-9_-]{43}$/
    refute captured.json["prompt_cache_key"] == "compact-camel-cache-key"
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
    assert attempt.response_metadata["prompt_cache_controls_downgraded"] == true

    assert Repo.aggregate(
             from(l in LedgerEntry,
               where:
                 l.request_id == ^request.id and l.entry_kind == "settlement" and
                   l.amount_status == "recorded"
             ),
             :count
           ) == 1

    persistence_text = inspect({request, attempt})
    refute persistence_text =~ request_turn_state
    refute persistence_text =~ response_turn_state
  end

  test "POST /backend-api/codex/responses bridges audio-only input to compact SSE", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_audio_compaction_bridge",
          "object" => "response.compaction",
          "output" => [
            %{
              "type" => "compaction",
              "encrypted_content" => "encrypted-audio-compact-fixture"
            }
          ]
        })
      )

    audio_source = "synthetic compaction audio"
    audio_data = Base.encode64(audio_source)
    audio_url = "data:audio/wav;base64," <> audio_data
    setup = gateway_setup(upstream, compact?: true)

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_audio", "audio_url" => audio_url}]
      }
    ]

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => input ++ [compaction_trigger()],
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200

    response_body = response(conn, 200)
    assert response_body =~ "encrypted-audio-compact-fixture"
    refute response_body =~ "audio_url"
    refute response_body =~ "audio_data"
    refute response_body =~ audio_data
    refute response_body =~ audio_url

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert captured.json["input"] == input
    refute inspect(captured.json) =~ "compaction_trigger"

    assert_audio_accounting_metadata_only!(setup.pool, [audio_source, audio_data, audio_url])
  end

  @tag :client_metadata
  test "compaction trigger aliases normalize all accepted compact result shapes", %{conn: conn} do
    routes = [
      {"responses", "/backend-api/codex/responses"},
      {"v1_responses", "/backend-api/codex/v1/responses"}
    ]

    shapes = [
      {"output_compaction", :output, "compaction", "cmp_output_current", "turn-output-current"},
      {"output_summary", :output, "compaction_summary", "legacy item id / 1",
       "\tlegacy turn id\n"},
      {"top_level_summary", :top_level, "compaction_summary", "", ""}
    ]

    for {route_name, path} <- routes,
        {shape_name, location, source_type, item_id, turn_id} <- shapes do
      case_name = "#{route_name}-#{shape_name}"
      encrypted_content = "encrypted-#{case_name}"
      response_id = "resp_#{case_name}"
      request_turn_state = "request-#{case_name}"
      response_turn_state = "response-#{case_name}"
      unknown_item_value = "unknown-item-#{case_name}"
      unknown_nested_value = "unknown-nested-#{case_name}"
      plaintext_value = "plaintext-#{case_name}"
      unknown_response_value = "unknown-response-#{case_name}"

      source_item =
        compact_source_item(
          source_type,
          encrypted_content,
          item_id,
          turn_id,
          unknown_item_value,
          unknown_nested_value,
          plaintext_value
        )

      compact_response =
        compact_result_payload(location, source_item, response_id, unknown_response_value)

      upstream =
        start_upstream(
          FakeUpstream.json_response_with_headers(
            compact_response,
            [{"x-codex-turn-state", response_turn_state}]
          )
        )

      setup = gateway_setup(upstream, compact?: true)

      response =
        conn
        |> recycle()
        |> put_req_header("x-codex-turn-state", request_turn_state)
        |> auth(setup)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "input" => visible_input("visible #{case_name}") ++ [compaction_trigger()],
          "stream" => true
        })

      assert response.status == 200
      assert ["text/event-stream" <> _suffix] = get_resp_header(response, "content-type")
      assert get_resp_header(response, "x-codex-turn-state") == [response_turn_state]

      response_body = response(response, 200)
      events = backend_sse_events(response_body)

      assert Enum.map(events, & &1["event"]) == [
               "response.output_item.done",
               "response.completed"
             ]

      assert response_body =~ "data: [DONE]\n\n"

      assert [done_event, completed_event] = events
      assert done_event["data"]["type"] == "response.output_item.done"
      assert completed_event["data"]["type"] == "response.completed"

      done_item = done_event["data"]["item"]
      completed_response = completed_event["data"]["response"]
      assert [completed_item] = completed_response["output"]
      assert done_item == completed_item

      expected_item = %{
        "type" => "compaction",
        "encrypted_content" => encrypted_content,
        "id" => item_id,
        "internal_chat_message_metadata_passthrough" => %{"turn_id" => turn_id}
      }

      assert done_item == expected_item

      assert Enum.sort(Map.keys(done_item)) ==
               Enum.sort([
                 "type",
                 "encrypted_content",
                 "id",
                 "internal_chat_message_metadata_passthrough"
               ])

      assert Map.keys(done_item["internal_chat_message_metadata_passthrough"]) == ["turn_id"]
      assert completed_response["id"] == response_id
      refute completed_response["id"] == done_item["id"]
      assert completed_response["status"] == "completed"

      assert completed_response["usage"] == %{
               "input_tokens" => 5,
               "output_tokens" => 2,
               "total_tokens" => 7
             }

      assert Enum.sort(Map.keys(completed_response)) ==
               Enum.sort(["id", "status", "output", "usage"])

      for forbidden <- [
            "unknown_item_field",
            "unknown_nested_field",
            "plaintext_summary",
            "unrelated_response_field",
            unknown_item_value,
            unknown_nested_value,
            plaintext_value,
            unknown_response_value
          ] do
        refute response_body =~ forbidden
      end

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses/compact"
      assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state
      refute inspect(captured.json) =~ "compaction_trigger"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/codex/responses/compact"
      assert request.transport == "http_compact_json"
      assert request.status == "succeeded"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"

      assert [settlement] =
               Repo.all(
                 from(l in LedgerEntry,
                   where:
                     l.request_id == ^request.id and l.entry_kind == "settlement" and
                       l.amount_status == "recorded"
                 )
               )

      persisted = inspect({request, attempt, settlement})

      for replay_value <- [
            encrypted_content,
            item_id,
            turn_id,
            unknown_item_value,
            unknown_nested_value,
            plaintext_value,
            unknown_response_value
          ],
          replay_value != "" do
        refute persisted =~ replay_value
      end
    end
  end

  test "compaction replay optional fields preserve strings and omit every other shape", %{
    conn: conn
  } do
    cases = [
      {"missing", %{}, %{}},
      {"nil", %{"id" => nil, "internal_chat_message_metadata_passthrough" => %{"turn_id" => nil}},
       %{}},
      {"non_string",
       %{"id" => 17, "internal_chat_message_metadata_passthrough" => %{"turn_id" => ["bad"]}},
       %{}},
      {"missing_turn",
       %{
         "id" => "cmp-missing-turn",
         "internal_chat_message_metadata_passthrough" => %{"unknown_nested_field" => "drop"}
       }, %{"id" => "cmp-missing-turn"}},
      {"nil_id_valid_turn",
       %{
         "id" => nil,
         "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-without-id"}
       }, %{"internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-without-id"}}},
      {"empty_strings",
       %{"id" => "", "internal_chat_message_metadata_passthrough" => %{"turn_id" => ""}},
       %{"id" => "", "internal_chat_message_metadata_passthrough" => %{"turn_id" => ""}}},
      {"legacy_strings",
       %{
         "id" => " legacy item id ",
         "internal_chat_message_metadata_passthrough" => %{"turn_id" => "\tlegacy turn\n"}
       },
       %{
         "id" => " legacy item id ",
         "internal_chat_message_metadata_passthrough" => %{"turn_id" => "\tlegacy turn\n"}
       }}
    ]

    for {case_name, optional_source, expected_optional} <- cases do
      source_item =
        %{
          "type" => "compaction_summary",
          "encrypted_content" => "encrypted-optional-#{case_name}",
          "unknown_item_field" => "drop-item-#{case_name}"
        }
        |> Map.merge(optional_source)

      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_optional_#{case_name}",
            "output" => [source_item]
          })
        )

      setup = gateway_setup(upstream, compact?: true)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => visible_input("visible optional #{case_name}") ++ [compaction_trigger()],
          "stream" => true
        })

      item = terminal_compaction_item(response)

      expected_item =
        Map.merge(
          %{
            "type" => "compaction",
            "encrypted_content" => "encrypted-optional-#{case_name}"
          },
          expected_optional
        )

      assert item == expected_item
      refute response.resp_body =~ "unknown_item_field"
      refute response.resp_body =~ "unknown_nested_field"
      refute response.resp_body =~ "drop-item-#{case_name}"
    end
  end

  test "compaction selection keeps first valid output precedence over later output and fallback",
       %{
         conn: conn
       } do
    selected =
      compact_source_item(
        "compaction_summary",
        "encrypted-first-valid",
        "cmp-first-valid",
        "turn-first-valid",
        "drop-first-item",
        "drop-first-nested",
        "drop-first-plaintext"
      )

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_selection_precedence",
          "output" => [
            %{"type" => "compaction", "encrypted_content" => nil},
            %{"type" => "message", "encrypted_content" => "not-a-compaction"},
            selected,
            %{
              "type" => "compaction",
              "encrypted_content" => "encrypted-later-valid",
              "id" => "cmp-later-valid"
            }
          ],
          "compaction_summary" => %{
            "encrypted_content" => "encrypted-top-level-fallback",
            "id" => "cmp-top-level-fallback"
          }
        })
      )

    setup = gateway_setup(upstream, compact?: true)

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => visible_input("visible selection precedence") ++ [compaction_trigger()],
        "stream" => true
      })

    assert terminal_compaction_item(response) == %{
             "type" => "compaction",
             "encrypted_content" => "encrypted-first-valid",
             "id" => "cmp-first-valid",
             "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-first-valid"}
           }

    refute response.resp_body =~ "encrypted-later-valid"
    refute response.resp_body =~ "encrypted-top-level-fallback"
  end

  test "compaction bridge keeps malformed JSON and missing encrypted content errors stable", %{
    conn: conn
  } do
    cases = [
      {FakeUpstream.malformed_json("{malformed-compact-json", 200),
       %{
         "code" => "service_error",
         "message" => "gemma3 request failed",
         "param" => nil,
         "type" => "server_error"
       }},
      {FakeUpstream.json_response(%{
         "id" => "resp_missing_encrypted_content",
         "output" => [%{"type" => "compaction", "id" => "cmp-without-content"}],
         "compaction_summary" => %{"id" => "cmp-fallback-without-content"}
       }),
       %{
         "code" => "service_error",
         "message" => "gemma3 request failed",
         "param" => nil,
         "type" => "server_error"
       }}
    ]

    for {upstream_mode, expected_error} <- cases do
      upstream = start_upstream(upstream_mode)
      setup = gateway_setup(upstream, compact?: true)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => visible_input("visible invalid compact result") ++ [compaction_trigger()],
          "stream" => true
        })

      assert %{"error" => ^expected_error} = json_response(response, 502)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses/compact"
      refute response.resp_body =~ "cmp-without-content"
      refute response.resp_body =~ "cmp-fallback-without-content"
      refute response.resp_body =~ "malformed-compact-json"
    end
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
      [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_audio", "audio_url" => " \t\r\n"}]
        },
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

  defp compact_source_item(
         type,
         encrypted_content,
         id,
         turn_id,
         unknown_item_value,
         unknown_nested_value,
         plaintext_value
       ) do
    %{
      "type" => type,
      "encrypted_content" => encrypted_content,
      "id" => id,
      "internal_chat_message_metadata_passthrough" => %{
        "turn_id" => turn_id,
        "unknown_nested_field" => unknown_nested_value
      },
      "unknown_item_field" => unknown_item_value,
      "plaintext_summary" => plaintext_value
    }
  end

  defp compact_result_payload(:output, source_item, response_id, unknown_response_value) do
    %{
      "id" => response_id,
      "object" => "response.compaction",
      "output" => [source_item],
      "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7},
      "unrelated_response_field" => unknown_response_value
    }
  end

  defp compact_result_payload(:top_level, source_item, response_id, unknown_response_value) do
    %{
      "id" => response_id,
      "object" => "response.compaction",
      "output" => [%{"type" => "message", "content" => []}],
      "compaction_summary" => source_item,
      "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7},
      "unrelated_response_field" => unknown_response_value
    }
  end

  defp terminal_compaction_item(response) do
    response_body = response(response, 200)
    assert [done_event, completed_event] = backend_sse_events(response_body)
    done_item = done_event["data"]["item"]
    assert [completed_item] = completed_event["data"]["response"]["output"]
    assert done_item == completed_item
    done_item
  end

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
          setup.assignment.id =>
            Map.put(
              setup.model.metadata["upstream_model"],
              "slug",
              setup.model.exposed_model_id
            )
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
