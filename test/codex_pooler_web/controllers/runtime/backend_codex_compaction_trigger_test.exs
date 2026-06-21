defmodule CodexPoolerWeb.Runtime.BackendCodexCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

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
