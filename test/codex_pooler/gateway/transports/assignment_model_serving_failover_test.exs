defmodule CodexPooler.Gateway.Transports.AssignmentModelServingFailoverTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 2,
      gateway_upstream: 4,
      prime_routing_quota!: 1,
      seed_preferring_assignment: 2,
      start_upstream: 1,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  test "predispatch serving mode survives pre-visible assignment failover and accounting",
       %{conn: conn} do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(
          %{
            "error" => %{
              "code" => "model_not_found",
              "type" => "invalid_request_error",
              "param" => "model"
            }
          },
          500
        )
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_serving_mode_failover_success",
          "object" => "response"
        })
      )

    setup = gateway_setup(first_upstream, exposed_model_id: "gpt-example-mode-snapshot")

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-mode-fallback",
        compact?: false
      )

    prime_routing_quota!(second.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id, second.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => %{"use_responses_lite" => false},
            second.assignment.id => %{"use_responses_lite" => true}
          }
        }
      })
      |> Repo.update!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: model.exposed_model_id,
      mode: "lite",
      created_at: now,
      updated_at: now
    })

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, second.assignment.id],
        setup.assignment.id
      )

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => model.exposed_model_id,
        "input" => "synthetic serving mode failover input"
      })

    assert %{"id" => "resp_serving_mode_failover_success"} = json_response(conn, 200)

    assert [%{json: first_payload}] = FakeUpstream.requests(first_upstream)
    assert [%{json: second_payload}] = FakeUpstream.requests(second_upstream)
    assert first_payload["model"] == second_payload["model"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1

    expected_mode_metadata = %{
      "model_serving_mode_configured" => "lite",
      "model_serving_mode" => "lite",
      "model_serving_mode_source" => "override"
    }

    assert Map.take(request.request_metadata["routing"], Map.keys(expected_mode_metadata)) ==
             expected_mode_metadata

    assert [first_attempt, second_attempt] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert first_attempt.status == "retryable_failed"
    assert second_attempt.status == "succeeded"

    for attempt <- [first_attempt, second_attempt] do
      assert Map.take(attempt.response_metadata["routing"], Map.keys(expected_mode_metadata)) ==
               expected_mode_metadata
    end
  end

  describe "classification-only contract at the provenance-aware seam" do
    test "structured model_not_found is retryable before visible output" do
      terminal = terminal_event(error_payload("model_not_found", "model"))

      assert {{:retry,
               %{
                 code: "model_not_found",
                 upstream_code: "model_not_found",
                 upstream_error_param: "model"
               }}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "code-less model-param shape is retryable before visible output" do
      terminal = terminal_event(code_less_model_param_payload())

      assert {{:retry,
               %{
                 code: "invalid_request_error",
                 upstream_code: "invalid_request_error",
                 upstream_error_param: "model"
               }}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "leading SSE comment does not hide a coalesced structured model miss" do
      terminal = terminal_event(error_payload("model_not_found", "model"))
      coalesced = ": upstream keepalive\n\n" <> terminal

      assert {{:retry, %{code: "model_not_found", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 coalesced,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "leading rate-limit event does not hide a coalesced provenance-backed model miss" do
      rate_limits =
        sse_event("codex.rate_limits", %{
          "type" => "codex.rate_limits",
          "rate_limits" => []
        })

      terminal = terminal_event(code_less_model_param_payload())

      assert {{:retry, %{code: "invalid_request_error", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 rate_limits <> terminal,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "bounded leading-block scan fails closed after its classification limit" do
      comments = Enum.map_join(1..33, &": keepalive-#{&1}\n\n")
      terminal = terminal_event(error_payload("model_not_found", "model"))
      stream = comments <> terminal

      assert {{:write, ^stream}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 stream,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "leading comment does not leave a coalesced completed event unclassified" do
      completed =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_completed"}
        })

      stream = ": upstream keepalive\n\n" <> completed

      assert {{:write, ^stream}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 stream,
                 StreamAttempt.first_event_state(),
                 true
               )
    end
  end

  describe "current non-retry controls" do
    test "structured model_not_found remains terminal when assignment failover is disabled" do
      terminal = terminal_event(error_payload("model_not_found", "model"))

      assert {{:write_terminal_failure, ^terminal,
               %{code: "model_not_found", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state()
               )
    end

    test "code-less model-param shape requires exact assignment provenance" do
      terminal = terminal_event(code_less_model_param_payload())

      assert {{:write_terminal_failure, ^terminal,
               %{
                 code: "invalid_request_error",
                 upstream_code: "invalid_request_error",
                 upstream_error_param: "model"
               }}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state(),
                 false
               )
    end

    test "generic, invalid-model, and continuation misses are written as terminal failures" do
      controls = [
        {"generic", generic_error_payload()},
        {"invalid_model", error_payload("invalid_model", "model")},
        {"previous_response_not_found",
         error_payload("previous_response_not_found", "previous_response_id")}
      ]

      for {_label, payload} <- controls do
        terminal = terminal_event(payload)

        assert {{:write_terminal_failure, ^terminal, _failure}, %{classified?: true, buffer: ""}} =
                 StreamAttempt.classify_first_event(terminal, StreamAttempt.first_event_state())
      end
    end

    test "structured model_not_found after visible output cannot enter the retry branch" do
      created =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_example_visible", "status" => "in_progress"}
        })

      assert {{:write, ^created}, state} =
               StreamAttempt.classify_first_event(
                 created,
                 StreamAttempt.first_event_state(),
                 true
               )

      terminal = terminal_event(error_payload("model_not_found", "model"))

      assert {{:write_terminal_failure, ^terminal,
               %{code: "model_not_found", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(terminal, state, true)
    end
  end

  defp code_less_model_param_payload do
    %{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{"type" => "invalid_request_error", "param" => "model"}
      }
    }
  end

  defp generic_error_payload do
    %{
      "type" => "response.failed",
      "response" => %{"status" => "failed", "error" => %{"type" => "request_failed"}}
    }
  end

  defp error_payload(code, param) do
    %{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{"code" => code, "type" => "invalid_request_error", "param" => param}
      }
    }
  end

  defp terminal_event(payload), do: sse_event("response.failed", payload)

  defp sse_event(event, payload) do
    "event: #{event}\n" <> "data: #{Jason.encode!(payload)}\n\n"
  end
end
