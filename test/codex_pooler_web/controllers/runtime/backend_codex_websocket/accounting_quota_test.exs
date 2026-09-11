defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.AccountingQuotaTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @websocket_frame_timeout 1_000

  test "websocket terminal usage settles priced gpt-5.5 request logs" do
    terminal_usage = %{
      "input_tokens" => 123,
      "input_tokens_details" => %{"cached_tokens" => 17},
      "output_tokens" => 45,
      "reasoning_tokens" => 6,
      "total_tokens" => 168
    }

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_priced_gpt55",
          "object" => "response",
          "usage" => terminal_usage
        })
      )

    setup = gateway_setup(upstream)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: "gpt-5.5",
        upstream_model_id: "gpt-5.5",
        pricing_ref: "gpt-5.5",
        metadata:
          put_in(
            setup.model.metadata,
            ["source_assignment_models", setup.assignment.id, "slug"],
            "gpt-5.5"
          )
      })
      |> Repo.update!()

    pricing_snapshot!(model, %{
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30)
    })

    setup = %{setup | model: model}
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-priced-gpt55"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-priced-gpt55", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
    assert %{"id" => "resp_ws_priced_gpt55"} = CodexPooler.JSON.decode!(frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert request.requested_model == "gpt-5.5"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 123
    assert settlement.cached_input_tokens == 17
    assert settlement.output_tokens == 45
    assert settlement.reasoning_tokens == 6
    assert settlement.total_tokens == 168
    assert settlement.pricing_snapshot_id
    assert Decimal.positive?(settlement.settled_cost_micros)
    assert settlement.details["pricing_status"] == "priced"
    assert is_binary(settlement.details["settled_cost_micros"])

    assert %{items: [log], total: 1} =
             Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})

    assert log.transport == "websocket"
    assert log.status == "succeeded"
    assert log.usage_status == "usage_known"
    assert log.token_counts.input_tokens == 123
    assert log.token_counts.cached_input_tokens == 17
    assert log.token_counts.output_tokens == 45
    assert log.token_counts.reasoning_tokens == 6
    assert log.token_counts.total_tokens == 168
    assert log.cost.status == "priced"
    assert %Decimal{} = log.cost.usd
    assert Decimal.positive?(log.cost.usd)
  end

  test "websocket terminal response without usage stays unpriced" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_missing_usage",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-missing-usage"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-missing-usage", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
    assert %{"id" => "resp_ws_missing_usage"} = CodexPooler.JSON.decode!(frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_unknown"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_unknown"

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.usage_status == "usage_unknown"
    assert settlement.pricing_snapshot_id
    refute settlement.details["settled_cost_micros"]
    assert settlement.details["pricing_status"] == "priced"
    assert settlement.details["settled_cost_micros"] == nil

    assert %{items: [log], total: 1} =
             Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})

    assert log.transport == "websocket"
    assert log.status == "succeeded"
    assert log.usage_status == "usage_unknown"
    assert log.cost.status == "unpriced"
    assert log.cost.usd == nil
  end

  test "websocket stream conversion persists codex.rate_limits events through StreamDispatch" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"codex.rate_limits", codex_rate_limits_payload(34, reset_at)},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_ws_streamdispatch_rate_limits",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
      "stream" => true
    }

    assert {:ok, %{websocket_stream: stream}} =
             RuntimeGateway.execute(
               auth,
               "/backend-api/codex/responses",
               payload,
               RequestOptions.build(
                 %{
                   request_id: "ws-streamdispatch-rate-limits",
                   upstream_endpoint: "/backend-api/codex/responses",
                   websocket_writer: fn frame -> send(self(), {:websocket_frame, frame}) end
                 },
                 "/backend-api/codex/responses",
                 payload
               )
             )

    assert :ok = stream.()

    frames = receive_websocket_frames_by_type(["response.completed"], @websocket_frame_timeout)

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => "resp_ws_streamdispatch_rate_limits"}
           } = frames["response.completed"]

    assert window = wait_for_rate_limit_event_window(setup.identity, "primary")
    assert window.source == "codex_rate_limit_event"
    assert Decimal.equal?(window.used_percent, Decimal.new("34.0"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq
    wait_for_rate_limit_event_tasks()
  end

  test "websocket success path persists body codex.rate_limits events" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"codex.rate_limits", codex_rate_limits_payload(36, reset_at)},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_ws_success_rate_limits",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-success-rate-limits"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames = receive_websocket_frames_by_type(["response.completed"], @websocket_frame_timeout)

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => "resp_ws_success_rate_limits"}
           } = frames["response.completed"]

    assert window = wait_for_rate_limit_event_window(setup.identity, "primary")
    assert window.source == "codex_rate_limit_event"
    assert Decimal.equal?(window.used_percent, Decimal.new("36.0"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq
    wait_for_rate_limit_event_tasks()
  end

  test "websocket terminal error path persists prior body codex.rate_limits events" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"codex.rate_limits", codex_rate_limits_payload(91, reset_at)},
            {"error",
             %{
               "type" => "error",
               "status" => 429,
               "error" => %{
                 "code" => "rate_limit_exceeded",
                 "message" => "rate limit reached",
                 "type" => "invalid_request_error"
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-terminal-error-rate-limits"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames = receive_websocket_frames_by_type(["response.failed"], @websocket_frame_timeout)

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{"code" => "rate_limit_exceeded"}
             }
           } = frames["response.failed"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "failed"
    assert request.last_error_code == "rate_limit_exceeded"

    assert window = wait_for_rate_limit_event_window(setup.identity, "primary")
    assert window.source == "codex_rate_limit_event"
    assert Decimal.equal?(window.used_percent, Decimal.new("91.0"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq
    wait_for_rate_limit_event_tasks()
  end

  test "websocket first-and-only usage-limit terminal event fails without retrying or leaking" do
    raw_body_sentinel = "raw-websocket-usage-limit-body-do-not-persist"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "headers" => %{
                 "X-Codex-Rate-Limit-Reached-Type" => "workspace_owner_usage_limit_reached",
                 "Authorization" => "Bearer ws-usage-limit-header-do-not-persist",
                 "Cookie" => "ws-usage-limit-cookie=drop",
                 "X-Raw-Body" => raw_body_sentinel
               },
               "response" => %{
                 "id" => "resp_usage_limit_terminal",
                 "status" => "failed",
                 "error" => %{"code" => "usage_limit_exceeded"},
                 "usage" => %{
                   "input_tokens" => 10,
                   "cached_input_tokens" => 4,
                   "output_tokens" => 2,
                   "reasoning_tokens" => 1,
                   "total_tokens" => 12
                 }
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_usage_limit_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-usage-limit-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "usage-limit"})
    session = pin_session_to_assignment!(session, setup.assignment)

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("trigger websocket usage limit terminal"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: request_id, codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "id" => "resp_usage_limit_terminal",
               "status" => "failed",
               "error" => %{"code" => "usage_limit_exceeded"}
             }
           } = CodexPooler.JSON.decode!(frame)

    refute frame =~ "headers"
    refute frame =~ "workspace_owner_usage_limit_reached"
    refute frame =~ "ws-usage-limit-header-do-not-persist"
    refute frame =~ "ws-usage-limit-cookie"
    refute frame =~ raw_body_sentinel

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "usage_limit_exceeded"
    refute Map.has_key?(request.request_metadata || %{}, "websocket_frame_headers")

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.transport == "websocket"
    assert attempt.status == "failed"
    assert attempt.network_error_code == "usage_limit_exceeded"
    assert attempt.request_id == request.id
    assert attempt.response_metadata["error_kind"] == "usage_limit_exceeded"

    assert attempt.response_metadata["rate_limit_reached_type"] ==
             "workspace_owner_usage_limit_reached"

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "x-codex-rate-limit-reached-type" => "workspace_owner_usage_limit_reached"
           }

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    refute Enum.any?(Repo.all(from(a in Attempt)), &(&1.status == "succeeded"))
    refute Enum.any?(Repo.all(from(r in Request)), &(&1.status == "succeeded"))

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "response.failed"
    refute metadata_text =~ "resp_usage_limit_terminal"
    refute metadata_text =~ "trigger websocket usage limit terminal"
    refute metadata_text =~ "ws-usage-limit-header-do-not-persist"
    refute metadata_text =~ "ws-usage-limit-cookie"
    refute metadata_text =~ raw_body_sentinel
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
  end

  test "websocket malformed partial codex.rate_limits body event does not crash or persist" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          "event: codex.rate_limits\ndata: {\"type\":\"codex.rate_limits\",\"rate_limits\":{\"primary\":\n\n",
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_ws_malformed_rate_limits",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-malformed-rate-limits"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_receive {:websocket_frame, malformed_frame}, @websocket_frame_timeout
    assert {:error, _reason} = CodexPooler.JSON.decode(malformed_frame)

    frames = receive_websocket_frames_by_type(["response.completed"], @websocket_frame_timeout)

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => "resp_ws_malformed_rate_limits"}
           } = frames["response.completed"]

    wait_for_rate_limit_event_tasks()
    refute_rate_limit_event_windows(setup.identity)
  end

  test "websocket header and body quota conflict keeps rate limit event precedence" do
    body_reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    header_reset_at =
      DateTime.add(DateTime.utc_now(), 1_800, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"codex.rate_limits", codex_rate_limits_payload(43, body_reset_at)},
            {"error",
             %{
               "type" => "error",
               "status_code" => 429,
               "error" => %{
                 "code" => "rate_limit_exceeded",
                 "message" => "rate limited"
               },
               "headers" => %{
                 "X-Request-ID" => "ws-frame-conflict-request",
                 "X-Codex-Primary-Used-Percent" => 82,
                 "X-Codex-Primary-Window-Minutes" => 300,
                 "X-Codex-Primary-Reset-At" => DateTime.to_iso8601(header_reset_at),
                 "Authorization" => "synthetic-auth-redacted",
                 "Should-Not-Persist" => "synthetic-sentinel"
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("header body quota conflict"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-quota-header-body-conflict"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames =
      receive_websocket_frames_by_type(
        ["codex.rate_limits", "response.failed"],
        @websocket_frame_timeout
      )

    assert %{"type" => "codex.rate_limits"} = frames["codex.rate_limits"]

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "rate_limit_exceeded"}}
           } = frames["response.failed"]

    failed_frame = CodexPooler.JSON.encode!(frames["response.failed"])
    refute failed_frame =~ "headers"
    refute failed_frame =~ "ws-frame-conflict-request"
    refute failed_frame =~ "synthetic-auth-redacted"
    refute failed_frame =~ "synthetic-sentinel"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "rate_limit_exceeded"
    refute Map.has_key?(request.request_metadata || %{}, "websocket_frame_headers")

    assert [attempt] = Repo.all(from(a in Attempt))

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "x-codex-primary-reset-at" => DateTime.to_iso8601(header_reset_at),
             "x-codex-primary-used-percent" => "82",
             "x-codex-primary-window-minutes" => "300",
             "x-request-id" => "ws-frame-conflict-request"
           }

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "synthetic-auth-redacted"
    refute metadata_text =~ "synthetic-sentinel"

    wait_for_rate_limit_event_tasks()
    assert window = wait_for_rate_limit_event_window(setup.identity, "primary")
    assert window.source == "codex_rate_limit_event"
    assert Decimal.equal?(window.used_percent, Decimal.new("43.0"))
    assert DateTime.compare(window.reset_at, body_reset_at) == :eq

    assert Enum.any?(
             QuotaWindows.list_evidence(setup.identity),
             &(&1.source == "codex_response_headers" and &1.window_kind == "primary")
           )
  end

  defp refute_rate_limit_event_windows(identity) do
    refute Enum.any?(
             QuotaWindows.list_quota_windows(identity),
             &(&1.source == "codex_rate_limit_event")
           )
  end
end
