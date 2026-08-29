defmodule CodexPoolerWeb.V1.ResponsesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPooler.Gateway.OpenAICompatibility.AudioTestSupport,
    only: [
      assert_audio_accounting_metadata_only!: 2,
      assert_captured_audio_summary!: 2,
      assert_no_audio_side_effects!: 1,
      assert_sanitized_audio_error_response!: 3,
      expected_audio_summary: 2,
      input_audio_part: 2,
      public_audio_error: 1,
      with_ascii_whitespace: 1
    ]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      await_public_websocket_upgrade: 2,
      curl_json_request!: 4,
      gateway_setup: 1,
      gateway_setup: 2,
      gateway_upstream: 4,
      mint_websocket_new!: 4,
      pricing_config: 1,
      pricing_snapshot!: 2,
      prime_routing_quota!: 1,
      prime_weekly_exhausted_quota!: 1,
      prime_weekly_probe_quota!: 1,
      public_websocket_receive_close!: 3,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      put_model_source_assignments!: 2,
      register_unboxed_pool_cleanup!: 1,
      assert_pre_first_stream_idle_timeout!: 1,
      start_public_endpoint!: 0,
      start_public_endpoint_with_server!: 0,
      start_upstream: 1,
      unboxed_run: 1,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.Access

  alias CodexPooler.Accounting.{
    Attempt,
    DailyRollup,
    LedgerEntry,
    Request,
    RequestLogFact,
    RequestLogs
  }

  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Metadata.CanonicalModelSource
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  defmodule ClosedChunkAdapter do
    def chunk(_payload, _chunk), do: {:error, :closed}
  end

  @reasoning_denial_message "reasoning effort is not available for this API key"

  @tag :bulkhead_overload
  test "POST /v1/responses returns the Codex overload vocabulary before JSON or SSE dispatch", %{
    conn: conn
  } do
    setup_runtime_ingress_override(overloaded_bulkhead_settings())

    for stream? <- [false, true] do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream)

      leases =
        Enum.map(Admission.route_classes(), fn route_class ->
          assert {:ok, lease} =
                   Admission.acquire(route_class, %{request_id: "held-#{route_class}-#{stream?}"})

          lease
        end)

      try do
        response =
          conn
          |> recycle()
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic overload contract",
            "stream" => stream?
          })

        assert %{"error" => error} = json_response(response, 503)

        assert error == %{
                 "code" => "server_is_overloaded",
                 "message" => "gateway route class is temporarily overloaded",
                 "param" => nil,
                 "type" => "server_error"
               }

        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Request, :count) == 0
        assert Repo.aggregate(Attempt, :count) == 0
        assert Repo.aggregate(LedgerEntry, :count) == 0
      after
        Enum.each(leases, &Admission.release/1)
      end
    end
  end

  @tag :bulkhead_overload
  @tag :v1_websocket
  test "GET /v1/responses websocket returns the Codex overload vocabulary before dispatch" do
    for {internal_reason, queue_limit, queue_timeout_ms} <- [
          {"bulkhead_rejected", 0, 1_000},
          {"bulkhead_queue_timeout", 1, 25}
        ] do
      setup_runtime_ingress_override(overloaded_bulkhead_settings(queue_limit, queue_timeout_ms))

      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream)
      port = start_public_endpoint!()

      {conn, websocket, ref, _response_headers} =
        public_v1_websocket_connect!(
          port,
          setup,
          "v1-websocket-overload-#{internal_reason}",
          [{"openai-beta", "responses_websockets=2026-02-06"}]
        )

      assert {:ok, lease} =
               Admission.acquire("proxy_websocket", %{request_id: "held-#{internal_reason}"})

      try do
        payload =
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic public websocket overload",
            "stream" => true,
            "generate" => true
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{
                 "type" => "error",
                 "status" => 503,
                 "error" => %{
                   "code" => "server_is_overloaded",
                   "message" => "gateway route class is temporarily overloaded",
                   "param" => nil,
                   "type" => "server_error"
                 }
               } = Jason.decode!(frame)

        refute frame =~ internal_reason
        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Request, :count) == 0
        assert Repo.aggregate(Attempt, :count) == 0
        assert Repo.aggregate(LedgerEntry, :count) == 0
      after
        Admission.release(lease)
        Mint.HTTP.close(conn)
      end
    end
  end

  test "POST /v1/responses denies unavailable canonical reasoning before JSON or SSE dispatch", %{
    conn: conn
  } do
    for {stream?, requested_effort} <- [{false, "high"}, {true, "custom-above-policy"}] do
      persisted_effort = if requested_effort == "high", do: "high", else: "unknown"
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream)
      assert :ok = Events.subscribe_pool(setup.pool)

      setup.api_key
      |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
      |> Repo.update!()

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic policy denial",
          "stream" => stream?,
          "reasoning" => %{"effort" => requested_effort}
        })

      assert %{
               "error" => %{
                 "code" => "reasoning_effort_not_allowed",
                 "message" => @reasoning_denial_message,
                 "param" => "reasoning.effort"
               }
             } = json_response(response, 400)

      assert FakeUpstream.count(upstream) == 0
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "rejected"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) ==
               0

      assert get_in(request.request_metadata, ["gateway_denial", "reasoning_policy"]) == %{
               "policy_mode" => "allow_up_to",
               "configured_effort" => "medium",
               "requested_effort" => persisted_effort,
               "applied_effort" => nil
             }
    end
  end

  test "POST /v1/responses applies canonical reasoning policies across JSON and SSE", %{
    conn: conn
  } do
    cases = [
      {[maximum_reasoning_effort: "medium"], %{}, false, "medium", "allow_up_to"},
      {[maximum_reasoning_effort: "high"], %{"reasoning" => %{"effort" => "low"}}, true, "low",
       "allow_up_to"},
      {[enforced_reasoning_effort: "high"], %{"reasoning" => %{"effort" => "low"}}, false, "high",
       "always_use"},
      {[], %{}, false, nil, "unrestricted"},
      {[], %{"reasoning" => %{"effort" => "focused"}}, false, "focused", "unrestricted"}
    ]

    for {policy, extra_payload, stream?, expected_effort, expected_mode} <- cases do
      upstream = start_upstream(reasoning_policy_responses_upstream())
      setup = gateway_setup(upstream)

      setup.api_key
      |> Ecto.Changeset.change(policy)
      |> Repo.update!()

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(
          "/v1/responses",
          Map.merge(
            %{
              "model" => setup.model.exposed_model_id,
              "input" => "synthetic",
              "stream" => stream?
            },
            extra_payload
          )
        )

      if stream? do
        assert response.status == 200
        assert response.resp_body =~ "response.completed"
      else
        assert %{"id" => "resp_reasoning_policy_v1"} = json_response(response, 200)
      end

      assert [captured] = FakeUpstream.requests(upstream)
      assert get_in(captured.json, ["reasoning", "effort"]) == expected_effort
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert get_in(attempt.response_metadata, ["reasoning", "policy_mode"]) == expected_mode
      assert get_in(attempt.response_metadata, ["reasoning", "applied_effort"]) == expected_effort
    end
  end

  @tag :model_serving_modes
  test "public Responses keeps one model id while switching only the outgoing Pool mode", %{
    conn: conn
  } do
    for stream? <- [false, true] do
      upstream = start_upstream(public_mode_matrix_upstream())
      setup = gateway_setup(upstream)

      payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic public mode input",
        "stream" => stream?
      }

      put_public_model_serving_mode!(setup, "full")

      full_response =
        conn
        |> recycle()
        |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-lite")
        |> auth(setup)
        |> post("/v1/responses", payload)

      assert_public_mode_matrix_response!(full_response, stream?)

      put_public_model_serving_mode!(setup, "lite")

      lite_response =
        conn
        |> recycle()
        |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-lite")
        |> auth(setup)
        |> post("/v1/responses", payload)

      assert_public_mode_matrix_response!(lite_response, stream?)

      assert [full_capture, lite_capture] = FakeUpstream.requests(upstream)
      assert full_capture.path == "/backend-api/codex/responses"
      assert lite_capture.path == "/backend-api/codex/responses"
      assert full_capture.json["model"] == setup.model.upstream_model_id
      assert lite_capture.json["model"] == setup.model.upstream_model_id
      assert_public_mode_matrix_bodies!(full_capture, lite_capture)
      assert_public_mode_matrix_headers!(full_capture, lite_capture)
      assert_public_mode_matrix_metadata!(setup, ["full", "lite"])
    end
  end

  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexSession,
    CodexTurn,
    RoutingCircuitState,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPoolerWeb.PublicGatewayResult
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000
  @ttfh_threshold_ms 9_500
  @timing_observation_timeout_ms 1_000
  @failure_observation_timeout_ms 2_000

  defp with_public_metadata_headers(conn) do
    conn
    |> put_req_header("x-codex-turn-metadata", "turn-metadata-redacted")
    |> put_req_header("x-codex-window-id", "window-redacted")
    |> put_req_header("x-codex-parent-thread-id", "thread-redacted")
    |> put_req_header("x-codex-installation-id", "installation-redacted")
    |> put_req_header("x-openai-subagent", "subagent-redacted")
    |> put_req_header("x-codex-extra", "extra-redacted")
    |> put_req_header("x-openai-extra", "extra-redacted")
    |> put_req_header("cookie", "public-client-cookie")
    |> put_req_header("idempotency-key", "public-client-idempotency")
  end

  defp public_v1_websocket_connect!(port, setup, turn_state, extra_headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", turn_state}
      | extra_headers
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref, response_headers}
  end

  defp assert_receive_finalized_request! do
    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"status" => "succeeded"}
                    }},
                   @websocket_frame_timeout
  end

  defp perform_public_continuity_websocket_request!(port, setup, extra_headers) do
    turn_state = "v1-public-continuity-ws-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, extra_headers)

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_v1_websocket_continuity"}
             } = Jason.decode!(frame)

      assert_receive_finalized_request!()

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  defp assert_no_continuity_headers_forwarded!(captured) do
    captured_headers = Map.new(captured.headers)

    refute Map.has_key?(captured_headers, "session-id")
    refute Map.has_key?(captured_headers, "x-session-id")
    refute Map.has_key?(captured_headers, "x-session-affinity")
  end

  defp assert_pinned_reauth_recovery_body!(conn) do
    assert get_resp_header(conn, "x-codex-recovery-kind") == ["restart_with_full_context"]

    assert %{
             "error" => %{
               "code" => "pinned_continuation_reauth_required",
               "retryable" => false,
               "requires_new_upstream_session" => true,
               "recovery_kind" => "restart_with_full_context",
               "recovery" => recovery
             }
           } = json_response(conn, 503)

    assert_pinned_reauth_recovery_contract!(recovery)
  end

  defp assert_pinned_reauth_recovery_frame!(frame) do
    assert %{
             "type" => "error",
             "status" => 503,
             "error" => %{
               "code" => "pinned_continuation_reauth_required",
               "retryable" => false,
               "requires_new_upstream_session" => true,
               "recovery_kind" => "restart_with_full_context",
               "recovery" => recovery
             }
           } = Jason.decode!(frame)

    assert_pinned_reauth_recovery_contract!(recovery)
  end

  defp assert_pinned_reauth_recovery_contract!(recovery) do
    assert recovery["kind"] == "restart_with_full_context"
    assert recovery["anchor_removal"]["body"] == ["previous_response_id"]

    assert recovery["anchor_removal"]["headers"] == [
             "x-codex-previous-response-id",
             "x-codex-turn-state",
             "x-codex-window-id",
             "x-codex-session-id",
             "session-id",
             "x-session-id",
             "x-session-affinity",
             "session_id",
             "x-codex-conversation-id"
           ]
  end

  defp pinned_reauth_gateway_setup(pinned_upstream, fallback_upstream) do
    setup = gateway_setup(pinned_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        fallback_upstream,
        "upstream-token-v1-pinned-reauth-fallback",
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

    mark_pinned_assignment_reauth_required!(setup)

    {setup, fallback}
  end

  defp register_previous_response_anchor!(auth, assignment, previous_response_id) do
    session = register_session_header_anchor!(auth, assignment, "v1-previous-anchor-session")

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               Jason.encode!(%{"id" => previous_response_id})
             )

    session
  end

  defp register_session_header_anchor!(auth, assignment, session_header) do
    {:ok, session} = Gateway.start_codex_session(auth, %{session_header: session_header})
    pin_session_to_assignment!(session, assignment)
  end

  defp pin_session_to_assignment!(session, assignment) do
    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: assignment.id})
    |> Repo.update!()
  end

  defp mark_pinned_assignment_reauth_required!(setup) do
    setup.identity
    |> Ecto.Changeset.change(%{
      status: "reauth_required",
      metadata: %{
        "base_url" => setup.identity.metadata["base_url"],
        "token_refresh" => %{
          "status" => "reauth_required",
          "reason" => %{
            "code" => "refresh_token_revoked",
            "message" => "synthetic refresh state"
          }
        }
      }
    })
    |> Repo.update!()

    setup.assignment
    |> Ecto.Changeset.change(%{
      health_status: "disabled",
      eligibility_status: "ineligible"
    })
    |> Repo.update!()
  end

  defp put_request_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
  end

  defp visible_pinned_input do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{
            "type" => "input_text",
            "text" => "visible v1 pinned reauth context must not persist"
          }
        ]
      },
      %{
        "type" => "function_call_output",
        "call_id" => "call_v1_pinned_reauth",
        "output" => "visible v1 tool result must not persist"
      }
    ]
  end

  defp assert_no_pinned_reauth_leakage!(
         value,
         setup,
         previous_response_id,
         label \\ "pinned reauth leakage"
       )

  defp assert_no_pinned_reauth_leakage!(
         text,
         setup,
         previous_response_id,
         label
       )
       when is_binary(text) do
    refute text =~ previous_response_id, label
    refute text =~ "visible v1 pinned reauth context must not persist", label
    refute text =~ "visible v1 tool result must not persist", label
    refute text =~ "call_v1_pinned_reauth", label
    refute text =~ setup.authorization, label
    refute text =~ setup.raw_key, label
    refute text =~ "Bearer ", label
    refute text =~ "upstream-token", label
  end

  defp assert_no_pinned_reauth_leakage!(value, setup, previous_response_id, label) do
    assert_no_pinned_reauth_leakage!(inspect(value), setup, previous_response_id, label)
  end

  @tag :v1_websocket
  test "GET /v1/responses upgrades and dispatches through the public websocket route" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_v1_websocket_public",
                 "status" => "completed",
                 "service_tier" => "fast",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          done: false
        )
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{"service_tiers" => [%{"id" => "priority"}]}
        }
      )

    request_count = Repo.aggregate(Request, :count)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-public-ws-#{System.unique_integer([:positive])}"
    local_session_id = "v1-local-session-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"},
        {"session-id", local_session_id},
        {"x-session-affinity", local_session_id}
      ])

    try do
      assert {"x-codex-turn-state", ^turn_state} =
               List.keyfind(response_headers, "x-codex-turn-state", 0)

      refute List.keyfind(response_headers, "x-models-etag", 0)
      assert Repo.aggregate(Request, :count) == request_count

      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true,
          "service_tier" => "fast"
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_v1_websocket_public",
                 "service_tier" => "fast"
               }
             } = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true
      assert captured.json["service_tier"] == "priority"

      assert_no_continuity_headers_forwarded!(captured)

      assert_receive_finalized_request!()

      assert %CodexSession{} = session = Repo.get_by(CodexSession, session_key: local_session_id)
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"
      assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "openai_v1"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"

      assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
               "/backend-api/codex/responses"

      assert request.request_metadata["codex_session_id"] == session.id
      assert request.request_metadata["codex_session_key"] == local_session_id

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.transport == "websocket"
      assert attempt.status == "succeeded"

      persistence_text = inspect({request.request_metadata, attempt.response_metadata})
      refute persistence_text =~ setup.authorization
      refute persistence_text =~ setup.raw_key
      refute persistence_text =~ "Bearer "
      refute persistence_text =~ "upstream-token"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket resolves canonical reasoning policy after upgrade" do
    cases = [
      {[maximum_reasoning_effort: "medium"], %{}, "medium"},
      {[enforced_reasoning_effort: "high"], %{"reasoning" => %{"effort" => "low"}}, "high"},
      {[], %{"reasoning" => %{"effort" => "focused"}}, "focused"}
    ]

    for {policy, effort_payload, expected_effort} <- cases do
      upstream =
        start_upstream(public_websocket_completed_response("resp_v1_ws_reasoning_policy"))

      setup = gateway_setup(upstream)
      assert :ok = Events.subscribe_pool(setup.pool)

      setup.api_key
      |> Ecto.Changeset.change(policy)
      |> Repo.update!()

      port = start_public_endpoint!()
      turn_state = "v1-ws-reasoning-policy-#{System.unique_integer([:positive])}"

      {conn, websocket, ref, _response_headers} =
        public_v1_websocket_connect!(port, setup, turn_state, [
          {"openai-beta", "responses_websockets=2026-02-06"}
        ])

      try do
        payload =
          %{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic public websocket policy request",
            "stream" => true,
            "generate" => true
          }
          |> Map.merge(effort_payload)
          |> Jason.encode!()

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{
                 "type" => "response.completed",
                 "response" => %{"id" => "resp_v1_ws_reasoning_policy"}
               } = Jason.decode!(frame)

        assert [captured] = FakeUpstream.requests(upstream)
        assert get_in(captured.json, ["reasoning", "effort"]) == expected_effort

        assert_receive {Events,
                        %{
                          reason: "request_finalized",
                          payload: %{"request_id" => request_id, "status" => "succeeded"}
                        }},
                       @websocket_frame_timeout

        request = Repo.get!(Request, request_id)
        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

        assert get_in(attempt.response_metadata, ["reasoning", "applied_effort"]) ==
                 expected_effort

        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket denies unavailable canonical reasoning after upgrade" do
    upstream = start_upstream(public_websocket_completed_response("must_not_dispatch"))
    setup = gateway_setup(upstream)

    setup.api_key
    |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
    |> Repo.update!()

    port = start_public_endpoint!()
    turn_state = "v1-ws-reasoning-denial-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic public websocket policy denial",
          "stream" => true,
          "generate" => true,
          "reasoning" => %{"effort" => "high"}
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "reasoning_effort_not_allowed",
                 "message" => @reasoning_denial_message,
                 "param" => "reasoning.effort"
               }
             } = Jason.decode!(frame)

      assert FakeUpstream.count(upstream) == 0
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.status == "rejected"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) ==
               0

      assert get_in(request.request_metadata, ["gateway_denial", "reasoning_policy"]) == %{
               "policy_mode" => "allow_up_to",
               "configured_effort" => "medium",
               "requested_effort" => "high",
               "applied_effort" => nil
             }

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket preserves ordinary response.incomplete" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.incomplete",
             %{
               "type" => "response.incomplete",
               "response" => %{
                 "id" => "resp_v1_websocket_incomplete",
                 "status" => "incomplete",
                 "incomplete_details" => %{"reason" => "max_output_tokens"},
                 "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-public-ws-incomplete-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.incomplete",
               "response" => %{
                 "id" => "resp_v1_websocket_incomplete",
                 "status" => "incomplete",
                 "incomplete_details" => %{"reason" => "max_output_tokens"}
               }
             } = Jason.decode!(frame)

      refute frame =~ "response.failed"
      assert_receive_finalized_request!()

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"
      assert request.usage_status == "usage_known"
      assert is_nil(request.last_error_code)

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.transport == "websocket"
      assert attempt.status == "succeeded"
      assert attempt.usage_status == "usage_known"
      assert is_nil(attempt.network_error_code)

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket coerces public opencode replay frames before dispatch" do
    upstream =
      start_upstream(public_websocket_completed_response("resp_v1_websocket_opencode_replay"))

    setup = gateway_setup(upstream, model_metadata: %{"input_modalities" => ["text", "image"]})
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    request_id = "v1-public-ws-opencode-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, request_id, [
        {"openai-beta", "responses_websockets=2026-02-06"},
        {"session-id", request_id}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_ws_opencode_previous",
          "store" => false,
          "moderation" => %{"model" => "omni-moderation-latest"},
          "input" => [
            %{
              "role" => "assistant",
              "id" => "msg-1",
              "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
            },
            %{
              "type" => "reasoning",
              "id" => "rs_v1_ws_opencode_reasoning",
              "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
              "encrypted_content" => nil
            },
            %{
              "type" => "function_call",
              "id" => "fc_v1_ws_opencode_call",
              "call_id" => "",
              "name" => "lookup_fixture",
              "namespace" => "browser.search",
              "arguments" => "{\"value\":\"sample\"}",
              "encrypted_function_args" => []
            },
            %{
              "type" => "function_call_output",
              "call_id" => "",
              "output" => [
                %{"type" => "input_text", "text" => "synthetic tool text"},
                %{"type" => "input_image", "image_url" => "https://example.com/sample.png"}
              ]
            }
          ]
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_v1_websocket_opencode_replay"}
             } = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true
      assert captured.json["stream"] == true
      assert captured.json["store"] == false
      assert captured.json["previous_response_id"] == "resp_v1_ws_opencode_previous"
      assert captured.json["moderation"] == %{"model" => "omni-moderation-latest"}

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "message",
               "reasoning",
               "function_call",
               "function_call_output"
             ]

      assert hd(captured.json["input"])["role"] == "assistant"
      refute Map.has_key?(hd(captured.json["input"]), "id")
      assert Enum.at(captured.json["input"], 1)["id"] == "rs_v1_ws_opencode_reasoning"
      assert Enum.at(captured.json["input"], 2)["id"] == "fc_v1_ws_opencode_call"
      assert Enum.at(captured.json["input"], 2)["encrypted_function_args"] == []

      assert Enum.at(captured.json["input"], 2)["call_id"] == "fc_v1_ws_opencode_call"
      assert Enum.at(captured.json["input"], 2)["namespace"] == "browser.search"
      assert Enum.at(captured.json["input"], 3)["call_id"] == "fc_v1_ws_opencode_call"

      assert_receive_finalized_request!()

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      persistence_text = inspect(request.request_metadata)
      refute persistence_text =~ "synthetic assistant replay"
      refute persistence_text =~ "synthetic summary"
      refute persistence_text =~ "synthetic tool text"
      refute persistence_text =~ "resp_v1_ws_opencode_previous"
      refute persistence_text =~ "fc_v1_ws_opencode_call"
      refute persistence_text =~ setup.authorization
      refute persistence_text =~ setup.raw_key

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :custom_tool_replay
  @tag :v1_websocket
  test "GET /v1/responses websocket forwards namespaced custom tool replay before dispatch" do
    upstream =
      start_upstream(public_websocket_completed_response("resp_v1_websocket_custom_tool_replay"))

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-custom-tool-ws-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_v1_custom_tool_previous",
          "store" => false,
          "generate" => true,
          "input" => [
            %{
              "type" => "custom_tool_call",
              "id" => "ctc_v1_ws_call",
              "call_id" => "call_v1_custom_namespaced",
              "namespace" => "browser.search",
              "name" => "lookup",
              "input" => "{}",
              "status" => "completed",
              "metadata" => %{"turn_id" => "turn_v1_custom_call_legacy"},
              "internal_chat_message_metadata_passthrough" => %{
                "turn_id" => "turn_v1_custom_call"
              }
            },
            %{
              "type" => "custom_tool_call_output",
              "id" => "ctco_v1_ws_call",
              "call_id" => "call_v1_custom_namespaced",
              "name" => "lookup",
              "output" => "synthetic custom output",
              "metadata" => %{"turn_id" => "turn_v1_custom_output_legacy"},
              "internal_chat_message_metadata_passthrough" => %{
                "turn_id" => "turn_v1_custom_output"
              }
            }
          ]
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_v1_websocket_custom_tool_replay"}
             } = Jason.decode!(frame)

      assert_receive_finalized_request!()

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true
      assert captured.json["previous_response_id"] == "resp_v1_custom_tool_previous"

      assert [custom_call, custom_output] = captured.json["input"]
      assert custom_call["type"] == "custom_tool_call"
      assert custom_call["namespace"] == "browser.search"
      assert custom_call["name"] == "lookup"
      assert custom_call["input"] == "{}"
      refute Map.has_key?(custom_call, "status")

      assert custom_output["type"] == "custom_tool_call_output"
      assert custom_output["call_id"] == "call_v1_custom_namespaced"
      assert custom_output["name"] == "lookup"
      assert custom_output["output"] == "synthetic custom output"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      persistence_text = inspect({request.request_metadata, attempt.response_metadata})
      refute persistence_text =~ "synthetic custom output"
      refute persistence_text =~ "resp_v1_custom_tool_previous"
      refute persistence_text =~ "call_v1_custom_namespaced"
      refute persistence_text =~ "turn_v1_custom_call"
      refute persistence_text =~ "turn_v1_custom_output"
      refute persistence_text =~ setup.authorization
      refute persistence_text =~ setup.raw_key

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket rejects realtime item frames before dispatch" do
    upstream = start_upstream(public_websocket_completed_response("should_not_dispatch_realtime"))
    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    turn_state = "v1-realtime-item-ws-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "conversation.item.create",
          "item" => %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "synthetic realtime text"}]
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "error", "status" => 400, "error" => error} = Jason.decode!(frame)
      assert error["code"] == "invalid_request"
      assert error["param"] == "type"

      refute frame =~ "synthetic realtime text"
      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  @tag :tool_result_previous_response
  test "GET /v1/responses websocket forwards the same safe continuation shape and rejects malformed item references" do
    upstream =
      start_upstream(public_websocket_completed_response("resp_v1_websocket_safe_continuation"))

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-safe-continuation-ws-#{System.unique_integer([:positive])}"
    previous_response_id = "resp_v1_ws_safe_previous_#{System.unique_integer([:positive])}"
    tool_call_id = "call_v1_ws_safe_#{System.unique_integer([:positive])}"

    {safe_conn, safe_websocket, safe_ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => previous_response_id,
          "store" => false,
          "generate" => true,
          "input" => [
            %{"type" => "item_reference", "id" => "msg_v1_ws_safe_reference"},
            %{
              "type" => "function_call_output",
              "call_id" => tool_call_id,
              "name" => "lookup",
              "namespace" => "browser.search",
              "output" => "{\"ok\":true}"
            },
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
            }
          ]
        })

      {safe_conn, safe_websocket} =
        public_websocket_send_text!(safe_conn, safe_websocket, safe_ref, payload)

      {safe_conn, _safe_websocket, frame} =
        public_websocket_receive_text!(safe_conn, safe_websocket, safe_ref)

      assert %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_v1_websocket_safe_continuation"}
             } = Jason.decode!(frame)

      assert_receive_finalized_request!()

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true
      assert captured.json["store"] == false
      assert captured.json["previous_response_id"] == previous_response_id
      assert captured.json["stream"] == true

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "item_reference",
               "function_call_output",
               "message"
             ]

      assert hd(captured.json["input"])["id"] == "msg_v1_ws_safe_reference"
      assert Enum.at(captured.json["input"], 1)["call_id"] == tool_call_id
      assert Enum.at(captured.json["input"], 1)["name"] == "lookup"
      assert Enum.at(captured.json["input"], 1)["namespace"] == "browser.search"
      assert Enum.at(captured.json["input"], 2)["role"] == "user"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      invalid_turn_state = "v1-unsafe-continuation-ws-#{System.unique_integer([:positive])}"

      invalid_previous_response_id =
        "resp_v1_ws_unsafe_previous_#{System.unique_integer([:positive])}"

      {invalid_conn, invalid_websocket, invalid_ref, _invalid_response_headers} =
        public_v1_websocket_connect!(port, setup, invalid_turn_state, [
          {"openai-beta", "responses_websockets=2026-02-06"}
        ])

      try do
        invalid_payload =
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "previous_response_id" => invalid_previous_response_id,
            "generate" => true,
            "input" => [
              %{
                "type" => "item_reference",
                "id" => "msg_v1_ws_unsafe_reference",
                "output" => "unsafe-inline-leak"
              },
              %{
                "type" => "function_call_output",
                "call_id" => tool_call_id,
                "output" => "{\"ok\":true}"
              }
            ]
          })

        {invalid_conn, invalid_websocket} =
          public_websocket_send_text!(
            invalid_conn,
            invalid_websocket,
            invalid_ref,
            invalid_payload
          )

        {_invalid_conn, _invalid_websocket, invalid_frame} =
          public_websocket_receive_text!(invalid_conn, invalid_websocket, invalid_ref)

        assert %{"type" => "error", "status" => 400, "error" => error} =
                 Jason.decode!(invalid_frame)

        assert error["code"] == "invalid_request"
        assert error["param"] == "input"

        refute invalid_frame =~ "unsafe-inline-leak"
        refute invalid_frame =~ "msg_v1_ws_unsafe_reference"
        refute invalid_frame =~ invalid_previous_response_id
      after
        Mint.HTTP.close(invalid_conn)
      end

      assert FakeUpstream.count(upstream) == 1
      assert Repo.aggregate(Request, :count) == 1
      assert Repo.aggregate(Attempt, :count) == 1

      safe_conn
    after
      Mint.HTTP.close(safe_conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses keeps opencode continuity headers local without forwarding" do
    upstream =
      start_upstream(public_websocket_completed_response("resp_v1_websocket_continuity"))

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    session_id_header = "v1-ws-session-id-#{System.unique_integer([:positive])}"
    affinity_header = "v1-ws-session-affinity-#{System.unique_integer([:positive])}"

    perform_public_continuity_websocket_request!(port, setup, [
      {"session-id", session_id_header}
    ])

    perform_public_continuity_websocket_request!(port, setup, [
      {"x-session-affinity", affinity_header}
    ])

    assert %CodexSession{} =
             session_id_session = Repo.get_by(CodexSession, session_key: session_id_header)

    assert %CodexSession{} =
             affinity_session = Repo.get_by(CodexSession, session_key: affinity_header)

    requests =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
        )
      )

    assert Enum.map(requests, & &1.endpoint) == ["/v1/responses", "/v1/responses"]

    assert Enum.map(requests, & &1.request_metadata["codex_session_id"]) == [
             session_id_session.id,
             affinity_session.id
           ]

    assert Enum.map(requests, & &1.request_metadata["codex_session_key"]) == [
             session_id_header,
             affinity_header
           ]

    captured_requests = FakeUpstream.requests(upstream)
    assert length(captured_requests) == 2

    for captured <- captured_requests do
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert_no_continuity_headers_forwarded!(captured)
    end
  end

  test "GET /v1/responses with valid auth but no websocket upgrade fails without side effects", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn = conn |> auth(setup) |> get("/v1/responses")

    assert %{"error" => %{"code" => "websocket_upgrade_required"}} = json_response(conn, 400)
    assert get_resp_header(conn, "sec-websocket-accept") == []
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :capture_log
  test "GET /v1/responses blocked by runtime ingress fails before websocket upgrade", %{
    conn: conn
  } do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"id" => "blocked"})))
    setup_runtime_ingress_override(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

    conn =
      conn
      |> Map.put(:remote_ip, {198, 51, 100, 20})
      |> auth(setup)
      |> websocket_upgrade_headers()
      |> get("/v1/responses")

    assert %{"error" => error} = json_response(conn, 403)
    assert error["code"] == "access_denied"
    assert error["message"] == "client IP is not allowed"
    assert get_resp_header(conn, "sec-websocket-accept") == []
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses non-streaming dispatches through the gateway", %{conn: conn} do
    input_tokens_details = %{"cached_tokens" => 11, "fixture_tokens" => 13}
    output_tokens_details = %{"reasoning_tokens" => 17, "accepted_prediction_tokens" => 19}

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_non_stream",
               "status" => "completed",
               "service_tier" => "fast",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{
                 "input_tokens" => 23,
                 "input_tokens_details" => input_tokens_details,
                 "output_tokens" => 29,
                 "output_tokens_details" => output_tokens_details,
                 "total_tokens" => 52
               }
             }
           }}
        ])
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{"service_tiers" => [%{"id" => "priority"}]}
        }
      )

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 response",
        "service_tier" => "fast",
        "reasoning" => %{"effort" => "focused"}
      })

    assert %{
             "id" => "resp_v1_non_stream",
             "object" => "response",
             "service_tier" => "fast",
             "usage" => usage
           } =
             json_response(conn, 200)

    assert usage["input_tokens"] == 23
    assert usage["input_tokens_details"] == input_tokens_details
    assert usage["output_tokens"] == 29
    assert usage["output_tokens_details"] == output_tokens_details
    assert usage["total_tokens"] == 52

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert captured.json["service_tier"] == "priority"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.reasoning_effort == "focused"
    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "openai_v1"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/responses"

    assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
             "/backend-api/codex/responses"

    refute inspect(request.request_metadata) =~ "synthetic v1 response"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    settlement =
      Repo.get_by!(LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.input_tokens == 23
    assert settlement.cached_input_tokens == 11
    assert settlement.output_tokens == 29
    assert settlement.reasoning_tokens == 17
    assert settlement.total_tokens == 52
    refute Map.has_key?(settlement.details, "input_tokens_details")
    refute Map.has_key?(settlement.details, "output_tokens_details")

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.token_counts.input_tokens == 23
    assert log.token_counts.cached_input_tokens == 11
    assert log.token_counts.output_tokens == 29
    assert log.token_counts.reasoning_tokens == 17
    assert log.token_counts.total_tokens == 52
    refute Map.has_key?(log.token_counts, :input_tokens_details)
    refute Map.has_key?(log.token_counts, :output_tokens_details)
  end

  @tag :ultrafast_service_tier
  test "POST /v1/responses forwards, projects, and accounts for ultrafast JSON responses", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_ultrafast_json",
          "object" => "response",
          "status" => "completed",
          "service_tier" => "ultrafast",
          "output" => [],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{"service_tiers" => [%{"id" => "ultrafast"}]}
        }
      )

    ultrafast_pricing =
      pricing_snapshot!(setup.model, %{
        config: pricing_config(%{"service_tier" => "ultrafast"}),
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200)
      })

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic ultrafast JSON request",
        "service_tier" => "ultrafast"
      })

    assert %{
             "id" => "resp_v1_ultrafast_json",
             "object" => "response",
             "service_tier" => "ultrafast"
           } = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["service_tier"] == "ultrafast"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.requested_service_tier == "ultrafast"
    assert request.actual_service_tier == "ultrafast"
    assert request.service_tier == "ultrafast"
    assert request.request_metadata["pricing"]["status"] == "priced"
    assert request.request_metadata["pricing"]["requested_service_tier"] == "ultrafast"
    assert request.request_metadata["pricing"]["actual_service_tier"] == "ultrafast"
    assert request.request_metadata["pricing"]["service_tier"] == "ultrafast"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.pricing_snapshot_id == ultrafast_pricing.id

    assert [settlement] =
             Repo.all(
               from(l in LedgerEntry,
                 where:
                   l.request_id == ^request.id and l.entry_kind == "settlement" and
                     l.amount_status == "recorded"
               )
             )

    assert settlement.pricing_snapshot_id == ultrafast_pricing.id
    assert settlement.details["pricing_status"] == "priced"
    assert settlement.details["requested_service_tier"] == "ultrafast"
    assert settlement.details["actual_service_tier"] == "ultrafast"
    assert settlement.details["service_tier"] == "ultrafast"

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.requested_service_tier == "ultrafast"
    assert log.actual_service_tier == "ultrafast"
    assert log.service_tier == "ultrafast"
    assert log.cost.status == "priced"
  end

  @tag :ultrafast_service_tier
  test "POST /v1/responses forwards, projects, and accounts for ultrafast SSE responses", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_ultrafast_sse",
               "status" => "completed",
               "service_tier" => "ultrafast",
               "output" => [],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
             }
           }}
        ])
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{"service_tiers" => [%{"id" => "ultrafast"}]}
        }
      )

    ultrafast_pricing =
      pricing_snapshot!(setup.model, %{
        config: pricing_config(%{"service_tier" => "ultrafast"}),
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200)
      })

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic ultrafast SSE request",
        "service_tier" => "ultrafast",
        "stream" => true
      })

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"

    completed =
      conn.resp_body
      |> public_sse_events()
      |> Enum.find(&(&1["event"] == "response.completed"))

    assert %{"data" => completed} = completed

    assert completed["response"]["id"] == "resp_v1_ultrafast_sse"
    assert completed["response"]["service_tier"] == "ultrafast"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["service_tier"] == "ultrafast"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert request.requested_service_tier == "ultrafast"
    assert request.actual_service_tier == "ultrafast"
    assert request.service_tier == "ultrafast"
    assert request.request_metadata["pricing"]["status"] == "priced"
    assert request.request_metadata["pricing"]["requested_service_tier"] == "ultrafast"
    assert request.request_metadata["pricing"]["actual_service_tier"] == "ultrafast"
    assert request.request_metadata["pricing"]["service_tier"] == "ultrafast"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "http_sse"
    assert attempt.status == "succeeded"
    assert attempt.pricing_snapshot_id == ultrafast_pricing.id

    assert [settlement] =
             Repo.all(
               from(l in LedgerEntry,
                 where:
                   l.request_id == ^request.id and l.entry_kind == "settlement" and
                     l.amount_status == "recorded"
               )
             )

    assert settlement.pricing_snapshot_id == ultrafast_pricing.id
    assert settlement.details["pricing_status"] == "priced"
    assert settlement.details["requested_service_tier"] == "ultrafast"
    assert settlement.details["actual_service_tier"] == "ultrafast"
    assert settlement.details["service_tier"] == "ultrafast"

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.requested_service_tier == "ultrafast"
    assert log.actual_service_tier == "ultrafast"
    assert log.service_tier == "ultrafast"
    assert log.cost.status == "priced"
  end

  test "POST /v1/responses relays standalone-CR upstream SSE through the live HTTP endpoint" do
    terminal = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_v1_standalone_cr",
        "object" => "response",
        "status" => "completed",
        "output" => [],
        "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
      }
    }

    source =
      "event: response.completed\rdata: " <> Jason.encode!(terminal) <> "\r\r"

    upstream =
      start_upstream(
        FakeUpstream.chunked_response([source, "\n"],
          headers: [{"content-type", "text/event-stream"}]
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "synthetic standalone CR response",
      "stream" => true
    }

    {:ok, http_conn, ref, started} = start_public_v1_responses_request(port, setup, payload)

    try do
      {http_conn, status, response_headers, _elapsed_ms, chunks, done?} =
        await_public_response_headers!(http_conn, ref, started, @timing_observation_timeout_ms)

      assert status == 200
      assert header_value(response_headers, "content-type") =~ "text/event-stream"

      {body, :eof} =
        await_public_response_eof!(
          http_conn,
          ref,
          chunks,
          done?,
          @timing_observation_timeout_ms
        )

      assert [%{"event" => "response.created"}, %{"event" => "response.completed"} = event] =
               public_sse_events(body)

      assert get_in(event, ["data", "response", "id"]) == "resp_v1_standalone_cr"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.transport == "http_sse"
    after
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "POST /v1/responses uses a divergent healthy canonical alternate for JSON and SSE", %{
    conn: conn
  } do
    for stream? <- [false, true] do
      selected_upstream =
        start_upstream(FakeUpstream.json_response(%{"id" => "selected_must_not_dispatch"}))

      alternate_upstream =
        start_upstream(issue_231_completed_response("resp_issue_231_responses_#{stream?}"))

      {setup, alternate, source_proof} =
        issue_231_gateway_setup(selected_upstream, alternate_upstream, divergent?: true)

      assert source_proof.selected_digest != source_proof.alternate_digest

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "issue-231-private-responses-input",
          "stream" => stream?,
          "service_tier" => "priority",
          "reasoning" => %{"effort" => "high"}
        })

      if stream? do
        assert response.status == 200
        assert [content_type] = get_resp_header(response, "content-type")
        assert content_type =~ "text/event-stream"
        assert response.resp_body =~ "response.completed"
        assert response.resp_body =~ "resp_issue_231_responses_true"
      else
        assert %{"id" => "resp_issue_231_responses_false", "object" => "response"} =
                 json_response(response, 200)
      end

      assert FakeUpstream.count(selected_upstream) == 0
      assert [captured] = FakeUpstream.requests(alternate_upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["model"] == setup.model.upstream_model_id
      assert captured.json["service_tier"] == "priority"
      assert get_in(captured.json, ["reasoning", "effort"]) == "high"

      assert_issue_231_successful_accounting!(setup, alternate, "/v1/responses")
    end
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "POST /v1/responses keeps identical canonical sources eligible under weekly quota", %{
    conn: conn
  } do
    selected_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "selected_must_not_dispatch"}))

    alternate_upstream =
      start_upstream(issue_231_completed_response("resp_issue_231_identical_control"))

    {setup, alternate, source_proof} =
      issue_231_gateway_setup(selected_upstream, alternate_upstream, divergent?: false)

    assert source_proof.selected_digest == source_proof.alternate_digest

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "issue-231-private-identical-control",
        "service_tier" => "priority",
        "reasoning" => %{"effort" => "high"}
      })

    assert %{"id" => "resp_issue_231_identical_control"} = json_response(response, 200)
    assert FakeUpstream.count(selected_upstream) == 0
    assert FakeUpstream.count(alternate_upstream) == 1
    assert_issue_231_successful_accounting!(setup, alternate, "/v1/responses")
  end

  @tag :external_issues_229_231
  @tag :issue_231
  @tag :issue_231_all_exhausted
  test "POST /v1/responses rejects all divergent weekly-exhausted candidates without dispatch", %{
    conn: conn
  } do
    selected_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "selected_must_not_dispatch"}))

    alternate_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "alternate_must_not_dispatch"}))

    {setup, alternate, source_proof} =
      issue_231_gateway_setup(selected_upstream, alternate_upstream, divergent?: true)

    assert source_proof.selected_digest != source_proof.alternate_digest

    Repo.delete_all(
      from(window in CodexPooler.Upstreams.Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^alternate.identity.id
      )
    )

    prime_weekly_exhausted_quota!(alternate.identity)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "issue-231-private-all-exhausted-input",
        "service_tier" => "priority",
        "reasoning" => %{"effort" => "high"}
      })

    assert %{
             "error" => %{
               "code" => "quota_exhausted",
               "message" => "upstream request failed",
               "type" => "server_error"
             }
           } = json_response(response, 503)

    assert FakeUpstream.count(selected_upstream) == 0
    assert FakeUpstream.count(alternate_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.pool_id == setup.pool.id
    assert request.api_key_id == setup.api_key.id
    assert request.model_id == setup.model.id
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "rejected"
    assert request.last_error_code == "quota_exhausted"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    exclusions = request.request_metadata["candidate_exclusions"]

    assert MapSet.new(exclusions, fn exclusion ->
             {exclusion["pool_upstream_assignment_id"], exclusion["upstream_identity_id"]}
           end) ==
             MapSet.new([
               {setup.assignment.id, setup.identity.id},
               {alternate.assignment.id, alternate.identity.id}
             ])

    assert Enum.all?(exclusions, fn exclusion ->
             exclusion["reasons"]
             |> hd()
             |> Map.fetch!("reason_codes") == ["exhausted"]
           end)

    assert_issue_231_private_metadata!(
      {request.request_metadata, RequestLogs.list(setup.pool)},
      setup
    )
  end

  test "POST /v1/responses rejects invalid service tiers before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    for tier <- ["latency_preview", nil, 1, []] do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic invalid tier",
          "service_tier" => tier
        })

      assert %{"error" => %{"code" => "invalid_request", "param" => "service_tier"}} =
               json_response(response, 400)
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  test "POST /v1/responses lets an enforced priority tier override an admitted client tier", %{
    conn: conn
  } do
    upstream = start_upstream(reasoning_policy_responses_upstream())

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{"service_tiers" => [%{"id" => "priority"}]}
        }
      )

    setup.api_key
    |> Ecto.Changeset.change(enforced_service_tier: "priority")
    |> Repo.update!()

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic priority override",
        "service_tier" => "default"
      })

    assert %{"id" => "resp_reasoning_policy_v1"} = json_response(response, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["service_tier"] == "priority"
  end

  test "POST /v1/responses rejects an enforced tier unsupported by every candidate", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    setup.api_key
    |> Ecto.Changeset.change(enforced_service_tier: "priority")
    |> Repo.update!()

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic unsupported enforced tier",
        "service_tier" => "default"
      })

    assert %{"error" => %{"code" => "no_compatible_backend"}} = json_response(response, 503)
    assert FakeUpstream.count(upstream) == 0
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) == 0
  end

  @tag :programmatic_tool_calling
  test "POST /v1/responses collects programmatic tool output with one metadata-only settlement",
       %{
         conn: conn
       } do
    sentinels = programmatic_tool_sentinels()
    output_items = programmatic_tool_items(sentinels)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_programmatic_collected",
               "object" => "response",
               "status" => "completed",
               "output" => output_items,
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    payload = programmatic_tool_payload(setup.model.exposed_model_id, sentinels)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", payload)

    assert %{
             "id" => "resp_v1_programmatic_collected",
             "object" => "response",
             "status" => "completed",
             "output" => ^output_items
           } = json_response(response, 200)

    response_body = json_response(response, 200)

    refute Map.has_key?(response_body, "request_id")
    refute Map.has_key?(response_body, "attempt_id")
    refute Map.has_key?(response_body, "pool_id")
    refute Map.has_key?(response_body, "gateway_metadata")

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert_programmatic_input_forwarded!(captured.json["input"], sentinels)
    assert captured.json["tools"] == payload["tools"]
    assert captured.json["tool_choice"] == payload["tool_choice"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    assert Repo.aggregate(
             from(l in LedgerEntry,
               where:
                 l.request_id == ^request.id and l.entry_kind == "settlement" and
                   l.amount_status == "recorded"
             ),
             :count
           ) == 1

    assert_programmatic_metadata_only!(request, attempt, sentinels)
  end

  @tag :programmatic_tool_calling
  test "POST /v1/responses streams ordered programmatic tool events through EOF", %{conn: _conn} do
    sentinels = programmatic_tool_sentinels()
    output_items = programmatic_tool_items(sentinels)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{
               "id" => "resp_v1_programmatic_streamed",
               "object" => "response",
               "status" => "in_progress"
             }
           }},
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => Enum.at(output_items, 0)
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 0,
             "item" => Enum.at(output_items, 0)
           }},
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 1,
             "item" => Enum.at(output_items, 1)
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 1,
             "item" => Enum.at(output_items, 1)
           }},
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 2,
             "item" => Enum.at(output_items, 2)
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 2,
             "item" => Enum.at(output_items, 2)
           }},
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 3,
             "item" => Enum.at(output_items, 3)
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 3,
             "item" => Enum.at(output_items, 3)
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_programmatic_streamed",
               "object" => "response",
               "status" => "completed",
               "output" => output_items,
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    payload =
      programmatic_tool_payload(setup.model.exposed_model_id, sentinels)
      |> Map.put("stream", true)

    {:ok, http_conn, ref, started} = start_public_v1_responses_request(port, setup, payload)

    try do
      {http_conn, status, response_headers, _elapsed_ms, chunks, done?} =
        await_public_response_headers!(http_conn, ref, started, @timing_observation_timeout_ms)

      assert status == 200
      assert header_value(response_headers, "content-type") =~ "text/event-stream"

      {body, :eof} =
        await_public_response_eof!(
          http_conn,
          ref,
          chunks,
          done?,
          @timing_observation_timeout_ms
        )

      refute body =~ "[DONE]"

      events = public_sse_events(body)

      assert Enum.map(events, & &1["event"]) == [
               "response.created",
               "response.output_item.added",
               "response.output_item.done",
               "response.output_item.added",
               "response.output_item.done",
               "response.output_item.added",
               "response.output_item.done",
               "response.output_item.added",
               "response.output_item.done",
               "response.completed"
             ]

      assert Enum.map(
               Enum.filter(events, &(&1["event"] == "response.output_item.added")),
               &get_in(&1, ["data", "item"])
             ) == output_items

      assert Enum.map(
               Enum.filter(events, &(&1["event"] == "response.output_item.done")),
               &get_in(&1, ["data", "item"])
             ) == output_items

      assert %{
               "data" => %{
                 "response" => %{
                   "id" => "resp_v1_programmatic_streamed",
                   "object" => "response",
                   "status" => "completed",
                   "output" => ^output_items
                 }
               }
             } = List.last(events)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["stream"] == true
      assert captured.json["store"] == false
      assert_programmatic_input_forwarded!(captured.json["input"], sentinels)
      assert captured.json["tools"] == payload["tools"]
      assert captured.json["tool_choice"] == payload["tool_choice"]

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.transport == "http_sse"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"

      assert Repo.aggregate(
               from(l in LedgerEntry,
                 where:
                   l.request_id == ^request.id and l.entry_kind == "settlement" and
                     l.amount_status == "recorded"
               ),
               :count
             ) == 1

      assert_programmatic_metadata_only!(request, attempt, sentinels)
    after
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :programmatic_tool_calling
  test "POST /v1/responses rejects malformed programmatic vocabulary before admission", %{
    conn: conn
  } do
    sentinels = programmatic_tool_sentinels()
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    payload = programmatic_tool_payload(setup.model.exposed_model_id, sentinels)

    invalid_cases = [
      {"input", put_programmatic_payload_item(payload, 0, "unexpected", true)},
      {"input", put_programmatic_payload_item(payload, 1, "caller", %{"type" => "program"})},
      {"tools", put_programmatic_payload_tool(payload, 0, "unexpected", true)},
      {"tools", put_programmatic_payload_tool(payload, 1, "output_schema", [])}
    ]

    counts = durable_accounting_counts()

    Enum.each(invalid_cases, fn {expected_param, invalid_payload} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", invalid_payload)

      assert %{"error" => error} = json_response(response, 400)
      assert error["type"] == "invalid_request_error"
      assert error["code"] == "invalid_request"
      assert error["param"] == expected_param
      refute response.resp_body =~ sentinels.code
      refute response.resp_body =~ sentinels.result
      refute response.resp_body =~ sentinels.fingerprint
      refute response.resp_body =~ sentinels.schema
      refute response.resp_body =~ sentinels.item
      refute response.resp_body =~ sentinels.call
      refute response.resp_body =~ sentinels.caller
    end)

    assert FakeUpstream.count(upstream) == 0
    assert durable_accounting_counts() == counts
  end

  @tag :hosted_shell_history
  test "POST /v1/responses forwards hosted shell history across JSON and SSE without persistence or execution",
       %{conn: conn} do
    fixture = hosted_shell_privacy_fixture!()
    on_exit(fn -> File.rm_rf(fixture.temp_dir) end)

    assert File.exists?(fixture.temp_dir)
    refute File.exists?(fixture.marker_path)
    assert {:ok, %{mode: mode}} = File.stat(fixture.temp_dir)
    assert Bitwise.band(mode, 0o777) == 0o700

    upstream =
      start_upstream(
        {:sequence,
         [
           hosted_shell_completed_response("resp_hosted_shell_json"),
           hosted_shell_completed_response("resp_hosted_shell_sse")
         ]}
      )

    setup = gateway_setup(upstream)

    {{json_response_body, stream_response}, logs} =
      with_log(fn ->
        json_response =
          conn
          |> auth(setup)
          |> post(
            "/v1/responses",
            hosted_shell_payload(setup.model.exposed_model_id, fixture.input)
          )

        stream_response =
          conn
          |> recycle()
          |> auth(setup)
          |> post(
            "/v1/responses",
            setup.model.exposed_model_id
            |> hosted_shell_payload(fixture.input)
            |> Map.put("stream", true)
          )

        Logger.flush()
        {json_response(json_response, 200), stream_response}
      end)

    assert %{
             "id" => "resp_hosted_shell_json",
             "object" => "response",
             "status" => "completed"
           } = json_response_body

    assert stream_response.status == 200
    assert stream_response.resp_body =~ "event: response.completed\n"
    refute File.exists?(fixture.marker_path)

    captures = FakeUpstream.requests(upstream)

    unless length(captures) == 2 do
      flunk("expected two hosted shell upstream dispatches")
    end

    [json_capture, stream_capture] = captures

    assert_hosted_shell_forwarded!(json_capture, fixture.input)
    assert_hosted_shell_forwarded!(stream_capture, fixture.input)

    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from(a in Attempt, where: a.request_id in ^request_ids))

    assert length(requests) == 2
    assert length(attempts) == 2

    observable_text =
      inspect({
        Enum.map(requests, & &1.request_metadata),
        Enum.map(attempts, & &1.response_metadata),
        RequestLogs.list(setup.pool),
        CodexPooler.Audit.list_events(setup.pool).items,
        logs
      })

    assert_hosted_shell_sentinels_absent!(observable_text, fixture.sentinels)
  end

  @tag :hosted_shell_history
  test "POST /v1/responses relays five hosted shell events through SSE in order", %{conn: conn} do
    events = hosted_shell_sse_events()
    upstream = start_upstream(FakeUpstream.sse_stream(events))
    setup = gateway_setup(upstream)
    input = hosted_shell_history_fixture()

    response =
      conn
      |> auth(setup)
      |> post(
        "/v1/responses",
        setup.model.exposed_model_id
        |> hosted_shell_payload(input)
        |> Map.put("stream", true)
      )

    assert response.status == 200
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/event-stream"

    relayed = public_sse_events(response.resp_body)
    expected_types = Enum.map(events, fn {type, _event} -> type end)

    assert Enum.map(relayed, & &1["event"]) == expected_types
    assert Enum.all?(relayed, &(&1["event"] == get_in(&1, ["data", "type"])))

    assert Enum.zip(events, relayed)
           |> Enum.all?(fn {{_type, expected}, %{"data" => actual}} ->
             Map.delete(actual, "sequence_number") == Map.delete(expected, "sequence_number")
           end)

    sequences = Enum.map(relayed, &get_in(&1, ["data", "sequence_number"]))
    assert Enum.all?(sequences, &(is_integer(&1) and &1 >= 0))
    assert sequences == Enum.sort(sequences)
    assert sequences == Enum.uniq(sequences)

    assert [captured] = FakeUpstream.requests(upstream)
    assert_hosted_shell_forwarded!(captured, input)
  end

  @tag :hosted_shell_history
  test "POST /v1/responses rejects malformed hosted shell history before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)
    input = hosted_shell_history_fixture()

    malformed_inputs = [
      List.update_at(input, 0, &Map.put(&1, "unexpected", true)),
      List.update_at(input, 1, fn item ->
        Map.update!(item, "output", fn output ->
          List.replace_at(output, 0, %{"stdout" => "", "stderr" => ""})
        end)
      end)
    ]

    Enum.each(malformed_inputs, fn malformed_input ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(
          "/v1/responses",
          hosted_shell_payload(setup.model.exposed_model_id, malformed_input)
        )

      assert %{
               "error" => %{
                 "code" => "invalid_request",
                 "param" => "input",
                 "type" => "invalid_request_error"
               }
             } = json_response(response, 400)

      assert_no_hosted_shell_lifecycle_stream!(response.resp_body)
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  @tag :hosted_shell_history
  test "live curl exercises hosted shell JSON, malformed, and SSE boundaries" do
    input = hosted_shell_history_fixture()

    upstream =
      start_upstream(
        {:sequence,
         [
           hosted_shell_completed_response("resp_hosted_shell_curl_json"),
           FakeUpstream.sse_stream(hosted_shell_sse_events())
         ]}
      )

    setup = gateway_setup(upstream)
    {_server, port} = start_public_endpoint_with_server!()

    {json_headers, json_body} =
      curl_json_request!(
        port,
        setup.authorization,
        hosted_shell_payload(setup.model.exposed_model_id, input),
        "/v1/responses"
      )

    assert String.starts_with?(json_headers, "HTTP/1.1 200")

    assert %{
             "id" => "resp_hosted_shell_curl_json",
             "object" => "response",
             "status" => "completed"
           } = Jason.decode!(json_body)

    counts_before_malformed = durable_accounting_counts()

    malformed_input = List.update_at(input, 0, &Map.put(&1, "unexpected", true))

    {malformed_headers, malformed_body} =
      curl_json_request!(
        port,
        setup.authorization,
        hosted_shell_payload(setup.model.exposed_model_id, malformed_input),
        "/v1/responses"
      )

    assert String.starts_with?(malformed_headers, "HTTP/1.1 400")

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "param" => "input",
               "type" => "invalid_request_error"
             }
           } = Jason.decode!(malformed_body)

    assert_no_hosted_shell_lifecycle_stream!(malformed_body)
    assert FakeUpstream.count(upstream) == 1
    assert durable_accounting_counts() == counts_before_malformed

    {stream_headers, stream_body} =
      curl_hosted_shell_stream!(
        port,
        setup.authorization,
        setup.model.exposed_model_id,
        input
      )

    assert String.starts_with?(stream_headers, "HTTP/1.1 200")
    assert String.downcase(stream_headers) =~ "content-type: text/event-stream"

    events = public_sse_events(stream_body)

    assert Enum.map(events, & &1["event"]) ==
             Enum.map(hosted_shell_sse_events(), fn {type, _event} -> type end)

    refute Enum.any?(events, &(&1["event"] == "response.created"))
    assert FakeUpstream.count(upstream) == 2
  end

  @tag :prompt_cache_product_characterization
  test "POST /v1/responses accepts prompt cache controls without a public marker", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_prompt_cache_product_characterization",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "prompt_cache_key" => "characterization-cache-key",
        "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"},
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "input_text",
                "text" => "characterization content",
                "prompt_cache_breakpoint" => %{"mode" => "explicit"}
              }
            ]
          }
        ]
      })

    assert %{"id" => "resp_prompt_cache_product_characterization", "status" => "completed"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["prompt_cache_key"] == "characterization-cache-key"
    assert get_resp_header(conn, "x-codex-prompt-cache-mode") == []
    refute conn.resp_body =~ "prompt_cache_controls_downgraded"
  end

  @tag :prompt_cache_controls
  @tag :prompt_cache_adaptation
  test "POST /v1/responses accepts prompt cache controls and adapts them only at egress", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_prompt_cache_controls",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    raw_cache_key = "fixture-raw-cache-key"
    raw_prompt = "fixture raw prompt cache content"
    breakpoint = %{"mode" => "explicit"}
    options = %{"mode" => "explicit", "ttl" => "30m"}

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "prompt_cache_key" => raw_cache_key,
        "prompt_cache_options" => options,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "input_text",
                "text" => raw_prompt,
                "prompt_cache_breakpoint" => breakpoint
              },
              %{
                "type" => "input_text",
                "text" => "fixture prompt cache content after the breakpoint"
              }
            ]
          }
        ],
        "stream" => false,
        "store" => false
      })

    assert %{"id" => "resp_prompt_cache_controls"} = json_response(conn, 200)
    assert get_resp_header(conn, "x-codex-prompt-cache-mode") == []
    refute conn.resp_body =~ "prompt_cache_controls_downgraded"
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["prompt_cache_key"] == raw_cache_key
    refute Map.has_key?(captured.json, "prompt_cache_options")
    assert captured.json["store"] == false

    assert [
             %{
               "content" => [
                 %{"type" => "input_text", "text" => ^raw_prompt},
                 %{
                   "type" => "input_text",
                   "text" => "fixture prompt cache content after the breakpoint"
                 }
               ]
             }
           ] = captured.json["input"]

    refute inspect(captured.json) =~ "prompt_cache_breakpoint"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.response_metadata["prompt_cache_controls_downgraded"] == true
    refute Map.has_key?(request.request_metadata, "prompt_cache_controls_downgraded")

    persistence_text =
      inspect({request.request_metadata, attempt.response_metadata, RequestLogs.list(setup.pool)})

    refute persistence_text =~ raw_prompt
    refute persistence_text =~ raw_cache_key
  end

  @tag :prompt_cache_adaptation
  test "POST /v1/responses omits the attempt marker when no prompt cache controls were sent", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_prompt_cache_unaffected",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "unaffected prompt cache adaptation fixture"
      })

    assert %{"id" => "resp_prompt_cache_unaffected"} = json_response(conn, 200)
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    refute Map.has_key?(attempt.response_metadata, "prompt_cache_controls_downgraded")
    refute Map.has_key?(request.request_metadata, "prompt_cache_controls_downgraded")
  end

  @tag :selected_assignment_false_reasoning_envelope
  test "POST /v1/responses applies selected false while preserving the public response", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_reasoning_context",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    setup =
      put_setup_model_source_metadata!(setup, %{
        "id" => setup.model.upstream_model_id,
        "capabilities" => %{"responses" => true, "streaming" => true},
        "supported_reasoning_levels" => [%{"effort" => "high"}],
        "supports_reasoning_summary_parameter" => false
      })

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic reasoning context request",
        "include" => [
          "reasoning.encrypted_content",
          "reasoning.encrypted_content"
        ],
        "reasoning" => %{
          "effort" => "high",
          "summary" => "auto",
          "context" => " Current_Turn "
        }
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert %{"id" => "resp_v1_reasoning_context", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert captured.json["reasoning"] == %{
             "effort" => "high",
             "context" => "current_turn"
           }

    assert captured.json["include"] == ["reasoning.encrypted_content"]
  end

  test "POST /v1/responses normalizes an OMP 16.3.14 GPT-5.6 first turn for Responses Lite",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_omp_gpt56_first_turn",
               "object" => "response",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup =
      upstream
      |> gateway_setup()
      |> put_setup_model_source_metadata!(%{
        "use_responses_lite" => true,
        "capabilities" => %{"reasoning" => true, "responses" => true, "tools" => true},
        "service_tiers" => [
          %{"id" => "priority", "name" => "Priority", "description" => "Priority service"}
        ]
      })

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic OMP request"}]
          }
        ],
        "instructions" => "synthetic OMP instructions",
        "stream" => true,
        "store" => false,
        "max_output_tokens" => 64_000,
        "prompt_cache_key" => "synthetic-omp-cache-key",
        "reasoning" => %{"effort" => "max", "summary" => "auto"},
        "include" => ["reasoning.encrypted_content"],
        "service_tier" => "priority",
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup_fixture",
            "description" => "synthetic fixture tool",
            "parameters" => %{
              "type" => "object",
              "properties" => %{},
              "required" => [],
              "additionalProperties" => false
            }
          }
        ]
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "event: response.completed\n"
    assert conn.resp_body =~ "resp_v1_omp_gpt56_first_turn"

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    assert captured_headers["x-openai-internal-codex-responses-lite"] == "true"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert captured.json["parallel_tool_calls"] == false

    assert captured.json["reasoning"] == %{
             "context" => "all_turns",
             "effort" => "max",
             "summary" => "auto"
           }

    assert [
             %{
               "type" => "additional_tools",
               "role" => "developer",
               "tools" => [%{"type" => "function", "name" => "lookup_fixture"}]
             },
             %{"type" => "message", "role" => "developer"},
             %{"type" => "message", "role" => "user"}
           ] = captured.json["input"]

    refute Map.has_key?(captured.json, "tools")
    refute Map.has_key?(captured.json, "instructions")
    refute Map.has_key?(captured.json, "max_output_tokens")
  end

  test "POST /v1/responses bridges a terminal compaction trigger across JSON and SSE", %{
    conn: conn
  } do
    for stream? <- [false, true] do
      response_id = "resp_v1_compaction_trigger_#{stream?}"
      previous_response_id = "resp_v1_compaction_previous_#{stream?}"

      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => response_id,
            "object" => "response.compaction",
            "output" => [
              %{
                "type" => "compaction",
                "encrypted_content" => "synthetic-public-trigger-encrypted-#{stream?}",
                "id" => nil,
                "internal_chat_message_metadata_passthrough" => %{
                  "turn_id" => "native-public-turn-must-drop",
                  "compaction" => %{"implementation" => "responses_compaction_v2"},
                  "instruction" => "returned metadata must not select request transport"
                },
                "compaction" => %{"implementation" => "responses_compaction_v2"},
                "summary" => "plaintext-public-summary-must-drop"
              }
            ],
            "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
          })
        )

      setup = gateway_setup(upstream, compact?: true)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => previous_response_id,
          "input" =>
            public_tool_output_compaction_trigger_input("synthetic public compact #{stream?}"),
          "stream" => stream?,
          "include" => ["reasoning.encrypted_content"],
          "store" => false,
          "prompt_cache_key" => "public-compaction-cache-#{stream?}",
          "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"}
        })

      public_items =
        if stream? do
          assert response.status == 200
          assert [content_type] = get_resp_header(response, "content-type")
          assert content_type =~ "text/event-stream"

          events = public_sse_events(response.resp_body)

          assert Enum.map(events, & &1["event"]) == [
                   "response.output_item.done",
                   "response.completed"
                 ]

          done_item = get_in(List.first(events), ["data", "item"])
          completed_item = List.first(get_in(List.last(events), ["data", "response", "output"]))
          assert done_item == completed_item
          assert get_in(List.last(events), ["data", "response", "object"]) == "response"

          assert response.resp_body =~ "data: [DONE]\n\n"
          [done_item, completed_item]
        else
          assert %{
                   "id" => ^response_id,
                   "object" => "response",
                   "status" => "completed",
                   "output" => [item],
                   "usage" => %{"total_tokens" => 8}
                 } = json_response(response, 200)

          [item]
        end

      for item <- public_items do
        assert item == %{
                 "type" => "compaction",
                 "encrypted_content" => "synthetic-public-trigger-encrypted-#{stream?}",
                 "id" => nil
               }

        assert {:ok, %{payload: %{"input" => [^item]}}} =
                 Responses.coerce(%{
                   "model" => setup.model.exposed_model_id,
                   "input" => [item]
                 })
      end

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      refute Map.has_key?(captured.json, "stream")
      refute Map.has_key?(captured.json, "include")
      assert captured.json["store"] == false
      refute Map.has_key?(captured.json, "prompt_cache_options")
      assert captured.json["prompt_cache_key"] == "public-compaction-cache-#{stream?}"
      assert captured.json["previous_response_id"] == previous_response_id

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "function_call_output",
               "compaction_trigger"
             ]

      assert Enum.count(captured.json["input"], &(&1 == %{"type" => "compaction_trigger"})) == 1
      assert List.last(captured.json["input"]) == %{"type" => "compaction_trigger"}

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/codex/responses/compact"
      assert request.transport == "http_compact_json"
      assert request.status == "succeeded"

      assert get_in(request.request_metadata, ["reservation_snapshot_inputs", "route_class"]) ==
               "proxy_compact"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"

      assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
               "/backend-api/codex/responses"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.transport == "http_compact_json"
      assert attempt.status == "succeeded"

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      persisted = inspect({request, attempt, RequestLogs.list(setup.pool)})
      refute persisted =~ "synthetic-public-trigger-encrypted-#{stream?}"
      refute persisted =~ "native-public-turn-must-drop"
      refute persisted =~ "plaintext-public-summary-must-drop"
      refute persisted =~ "returned metadata must not select request transport"
    end
  end

  @tag :public_compaction_trigger_http_qa
  test "live curl bridges a public terminal compaction trigger as Responses SSE" do
    prompt_text = "synthetic public compaction curl input"
    encrypted_content = "synthetic-public-compaction-curl-encrypted"

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_public_compaction_curl",
          "object" => "response.compaction",
          "output" => [
            %{"type" => "compaction", "encrypted_content" => encrypted_content}
          ],
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()

    {headers, response_body} =
      curl_json_request!(
        port,
        setup.authorization,
        %{
          "model" => setup.model.exposed_model_id,
          "input" => public_compaction_trigger_input(prompt_text),
          "stream" => true
        },
        "/v1/responses"
      )

    assert String.starts_with?(headers, "HTTP/1.1 200")
    assert String.downcase(headers) =~ "content-type: text/event-stream"

    events = public_sse_events(response_body)

    assert Enum.map(events, & &1["event"]) == [
             "response.output_item.done",
             "response.completed"
           ]

    assert get_in(List.last(events), ["data", "response", "object"]) == "response"
    assert response_body =~ "data: [DONE]\n\n"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured.json, "stream")
    assert captured.json["store"] == false
    assert Enum.count(captured.json["input"], &(&1 == %{"type" => "compaction_trigger"})) == 1
    assert List.last(captured.json["input"]) == %{"type" => "compaction_trigger"}

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "succeeded"

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ prompt_text
    refute metadata_text =~ encrypted_content
  end

  test "POST /v1/responses rejects malformed compaction trigger placement before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream, compact?: true)
    visible = hd(public_compaction_trigger_input("visible public trigger fixture"))
    trigger = %{"type" => "compaction_trigger"}

    invalid_inputs = [
      [trigger],
      [trigger, visible],
      [visible, trigger, trigger],
      [%{"type" => "reasoning", "encrypted_content" => "hidden-only-trigger-fixture"}, trigger]
    ]

    for input <- invalid_inputs do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => input,
          "stream" => true
        })

      assert %{
               "error" => %{
                 "code" => "invalid_request",
                 "message" =>
                   "compaction_trigger must be the final input item and must follow visible input",
                 "param" => "input"
               }
             } = json_response(response, 400)
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses finalizes invalid selected compaction output across JSON and SSE", %{
    conn: conn
  } do
    invalid_items = [
      %{"type" => "compaction"},
      %{"type" => "compaction", "encrypted_content" => ""},
      %{"type" => "compaction", "encrypted_content" => " \t\n"}
    ]

    for stream? <- [false, true], invalid_item <- invalid_items do
      encrypted_later =
        "synthetic-invalid-public-later-#{stream?}-#{System.unique_integer([:positive])}"

      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "output" => [
              invalid_item,
              %{"type" => "compaction", "encrypted_content" => encrypted_later}
            ]
          })
        )

      setup = gateway_setup(upstream, compact?: true)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => public_compaction_trigger_input("invalid public compact #{stream?}"),
          "stream" => stream?
        })

      assert %{
               "error" => %{
                 "code" => "invalid_compaction_response",
                 "message" =>
                   "upstream compact response did not include encrypted compaction content",
                 "type" => "invalid_request_error"
               }
             } = json_response(response, 502)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/codex/responses/compact"
      assert request.status == "failed"
      assert request.completed_at
      assert request.last_error_code == "invalid_compaction_response"

      assert get_in(request.request_metadata, ["reservation_snapshot_inputs", "route_class"]) ==
               "proxy_compact"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "failed"
      assert attempt.completed_at
      assert attempt.network_error_code == "invalid_compaction_response"

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      persisted = inspect({request, attempt, RequestLogs.list(setup.pool)})
      refute response.resp_body =~ encrypted_later
      refute persisted =~ encrypted_later
    end
  end

  test "POST /v1/responses preserves verified compaction variants across JSON and SSE", %{
    conn: conn
  } do
    setup_runtime_ingress_override(%OperationalSettings{gateway_debug?: true})

    variants = [
      {"public_without_id",
       %{
         "type" => "compaction",
         "encrypted_content" => "synthetic-public-idless-compaction-private"
       }},
      {"public",
       %{
         "type" => "compaction",
         "encrypted_content" => "synthetic-public-compaction-private",
         "id" => "cmp_v1_public_private"
       }},
      {"public_with_null_id",
       %{
         "type" => "compaction",
         "encrypted_content" => "synthetic-public-null-id-compaction-private",
         "id" => nil
       }},
      {"native",
       %{
         "type" => "compaction",
         "encrypted_content" => "synthetic-native-compaction-private",
         "id" => "cmp_v1_native_private",
         "internal_chat_message_metadata_passthrough" => %{
           "turn_id" => "turn_v1_native_private"
         }
       }},
      {"omp_idless_native",
       %{
         "type" => "compaction",
         "encrypted_content" => "synthetic-omp-idless-compaction-private",
         "internal_chat_message_metadata_passthrough" => %{
           "turn_id" => "turn_v1_omp_private"
         }
       }}
    ]

    assert Enum.any?(variants, fn {_variant_name, item} ->
             Map.has_key?(item, "id") and is_nil(item["id"])
           end)

    for {variant_name, compaction_item} <- variants,
        {mode_name, stream?} <- [{"json", false}, {"sse", true}] do
      response_id = "resp_v1_compaction_#{variant_name}_#{mode_name}"

      upstream =
        start_upstream(
          FakeUpstream.sse_stream([
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => response_id,
                 "object" => "response",
                 "status" => "completed",
                 "output" => [],
                 "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
               }
             }}
          ])
        )

      setup = gateway_setup(upstream)

      {response, log_output} =
        with_log(fn ->
          conn
          |> recycle()
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "store" => false,
            "stream" => stream?,
            "input" => [
              compaction_item,
              %{
                "role" => "user",
                "content" => [
                  %{
                    "type" => "input_text",
                    "text" => "synthetic private follow-up for #{variant_name} #{mode_name}"
                  }
                ]
              }
            ]
          })
        end)

      if stream? do
        assert response.status == 200
        assert [content_type] = get_resp_header(response, "content-type")
        assert content_type =~ "text/event-stream"
        assert response.resp_body =~ "event: response.completed\n"
        assert response.resp_body =~ response_id
      else
        assert %{
                 "id" => ^response_id,
                 "object" => "response",
                 "status" => "completed"
               } = json_response(response, 200)
      end

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["stream"] == true
      assert captured.json["store"] == false
      refute Map.has_key?(captured.json, "previous_response_id")

      assert [captured_compaction, captured_user] = captured.json["input"]

      if variant_name == "omp_idless_native" do
        assert captured_compaction ==
                 Map.delete(compaction_item, "internal_chat_message_metadata_passthrough")
      else
        assert captured_compaction == compaction_item
      end

      if variant_name == "public_with_null_id" do
        assert Map.has_key?(captured_compaction, "id")
        assert captured_compaction["id"] == nil
      end

      assert captured_user["type"] == "message"
      assert captured_user["role"] == "user"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"

      assert get_in(attempt.response_metadata, ["gateway_debug", "items", "item_types"]) == [
               "compaction",
               "message"
             ]

      projection_text =
        inspect({
          request.request_metadata,
          attempt.response_metadata,
          RequestLogs.list(setup.pool, filters: %{request_id: request.id})
        })

      private_values = [
        compaction_item["encrypted_content"],
        compaction_item["id"],
        get_in(compaction_item, ["internal_chat_message_metadata_passthrough", "turn_id"]),
        "internal_chat_message_metadata_passthrough",
        "created_by"
      ]

      for private_value <- Enum.reject(private_values, &is_nil/1) do
        refute projection_text =~ private_value
        refute log_output =~ private_value
      end
    end
  end

  test "POST /v1/responses rejects unverified compaction metadata without side effects", %{
    conn: conn
  } do
    setup_runtime_ingress_override(%OperationalSettings{gateway_debug?: true})

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_items = [
      %{
        "type" => "compaction",
        "encrypted_content" => "synthetic-malformed-compaction-private",
        "id" => "cmp_v1_malformed_private",
        "internal_chat_message_metadata_passthrough" => %{
          "turn_id" => "turn_v1_malformed_private",
          "unexpected_nested_field" => "nested-v1-private"
        }
      },
      %{
        "type" => "compaction",
        "encrypted_content" => "synthetic-unverified-compaction-private",
        "id" => "cmp_v1_unverified_private",
        "created_by" => "creator-v1-private"
      },
      %{
        "type" => "compaction",
        "encrypted_content" => "synthetic-unknown-field-compaction-private",
        "id" => "cmp_v1_unknown_field_private",
        "unexpected_field" => "unknown-v1-private"
      }
    ]

    counts = durable_accounting_counts()

    for invalid_item <- invalid_items do
      {response, log_output} =
        with_log(fn ->
          conn
          |> recycle()
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => [invalid_item]
          })
        end)

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "param" => "input"
               }
             } = json_response(response, 400)

      private_values = [
        invalid_item["encrypted_content"],
        invalid_item["id"],
        get_in(invalid_item, ["internal_chat_message_metadata_passthrough", "turn_id"]),
        get_in(invalid_item, [
          "internal_chat_message_metadata_passthrough",
          "unexpected_nested_field"
        ]),
        invalid_item["created_by"],
        invalid_item["unexpected_field"],
        "internal_chat_message_metadata_passthrough",
        "created_by",
        "unexpected_nested_field",
        "unexpected_field"
      ]

      for private_value <- Enum.reject(private_values, &is_nil/1) do
        refute response.resp_body =~ private_value
        refute log_output =~ private_value
      end

      assert FakeUpstream.requests(upstream) == []
      assert durable_accounting_counts() == counts
      assert %{items: [], total: 0} = RequestLogs.list(setup.pool)
    end
  end

  test "POST /v1/responses forwards lowered non-strict function tool schemas", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_lowered_tool_schema",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic tool schema request",
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup_fixture",
            "strict" => false,
            "parameters" => non_strict_tool_schema()
          }
        ]
      })

    assert %{"id" => "resp_v1_lowered_tool_schema", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert captured.json["tools"] |> List.first() |> Map.fetch!("parameters") ==
             lowered_tool_schema()
  end

  test "POST /v1/responses forwards a Continue-style null strict function tool as omitted", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_continue_null_strict",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic Continue tool request",
        "tools" => [
          %{
            "type" => "function",
            "name" => "continue_style_fixture",
            "description" => "Synthetic flat function tool",
            "parameters" => %{"type" => "object", "properties" => %{}},
            "strict" => nil
          }
        ]
      })

    assert %{"id" => "resp_v1_continue_null_strict", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)

    assert captured.json["tools"] == [
             %{
               "type" => "function",
               "name" => "continue_style_fixture",
               "description" => "Synthetic flat function tool",
               "parameters" => %{"type" => "object", "properties" => %{}}
             }
           ]
  end

  @tag :responses_allowed_tools
  test "POST /v1/responses Full forwards allowed tools in caller order with duplicates", %{
    conn: conn
  } do
    upstream = start_upstream(issue_241_completed_response("resp_v1_allowed_tools"))
    setup = gateway_setup(upstream)
    put_public_model_serving_mode!(setup, "full")

    function_tool = %{
      "type" => "function",
      "name" => "lookup_allowed_fixture",
      "strict" => false,
      "defer_loading" => false,
      "parameters" => non_strict_tool_schema()
    }

    custom_tool = %{
      "type" => "custom",
      "name" => "custom_allowed_fixture",
      "format" => %{
        "type" => "grammar",
        "definition" => ~s(start: "allowed"),
        "syntax" => "lark"
      }
    }

    tools = [
      function_tool,
      custom_tool,
      %{"type" => "programmatic_tool_calling"},
      %{"type" => "web_search_preview"},
      %{"type" => "web_search"},
      %{"type" => "image_generation"}
    ]

    allowed_tools = [
      %{"type" => "custom", "name" => custom_tool["name"]},
      %{"type" => "web_search"},
      %{"type" => "function", "name" => function_tool["name"]},
      %{"type" => "programmatic_tool_calling"},
      %{"type" => "image_generation"},
      %{"type" => "web_search_preview"},
      %{"type" => "function", "name" => function_tool["name"]},
      %{"type" => "web_search"}
    ]

    tool_choice = %{"type" => "allowed_tools", "mode" => "required", "tools" => allowed_tools}

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic allowed tools request",
        "tools" => tools,
        "tool_choice" => tool_choice
      })

    assert %{"id" => "resp_v1_allowed_tools", "object" => "response"} =
             json_response(response, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tool_choice"] === tool_choice

    assert [forwarded_function, forwarded_custom | forwarded_builtins] = captured.json["tools"]

    assert forwarded_function ==
             function_tool
             |> Map.put("parameters", lowered_tool_schema())

    assert forwarded_custom == custom_tool
    assert forwarded_builtins == Enum.drop(tools, 2)
    assert_issue_241_success_lifecycle!(setup)
  end

  @tag :responses_allowed_tools
  test "POST /v1/responses rejects malformed Full allowed tools before admission", %{conn: conn} do
    upstream = start_upstream(issue_241_completed_response("must_not_dispatch_allowed_tools"))
    setup = gateway_setup(upstream)
    put_public_model_serving_mode!(setup, "full")

    function_tool = %{
      "type" => "function",
      "name" => "lookup_allowed_fixture",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    valid_tools = [function_tool, %{"type" => "web_search"}]
    function_member = %{"type" => "function", "name" => function_tool["name"]}

    invalid_cases = [
      {"missing mode", valid_tools, %{"type" => "allowed_tools", "tools" => [function_member]},
       %{
         "code" => "invalid_request",
         "message" => "tool_choice shape is not translatable",
         "param" => "tool_choice"
       }},
      {"undeclared function", valid_tools,
       %{
         "type" => "allowed_tools",
         "mode" => "auto",
         "tools" => [%{"type" => "function", "name" => "missing_allowed_fixture"}]
       },
       %{
         "code" => "invalid_request",
         "message" => "tool_choice shape is not translatable",
         "param" => "tool_choice"
       }},
      {"MCP member", valid_tools,
       %{
         "type" => "allowed_tools",
         "mode" => "auto",
         "tools" => [%{"type" => "mcp", "server_label" => "fixture-mcp"}]
       },
       %{
         "code" => "invalid_request",
         "message" => "tool_choice shape is not translatable",
         "param" => "tool_choice"
       }},
      {"MCP declaration", [%{"type" => "mcp"}],
       %{
         "type" => "allowed_tools",
         "mode" => "auto",
         "tools" => [%{"type" => "mcp", "server_label" => "fixture-mcp"}]
       },
       %{
         "code" => "invalid_request",
         "message" => "remote MCP tools are not supported",
         "param" => "tools"
       }}
    ]

    for {label, tools, tool_choice, expected_error} <- invalid_cases do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic invalid allowed tools request",
          "tools" => tools,
          "tool_choice" => tool_choice
        })

      assert %{"error" => error} = json_response(response, 400), label
      assert Map.take(error, ["code", "message", "param"]) == expected_error, label
      assert error["type"] == "invalid_request_error", label
      assert FakeUpstream.count(upstream) == 0, label
      assert Repo.aggregate(Request, :count) == 0, label
      assert Repo.aggregate(Attempt, :count) == 0, label
      assert Repo.aggregate(LedgerEntry, :count) == 0, label
    end
  end

  @tag :responses_allowed_tools
  test "POST /v1/responses rejects valid Lite allowed tools inside gateway accounting", %{
    conn: conn
  } do
    upstream =
      start_upstream(issue_241_completed_response("must_not_dispatch_lite_allowed_tools"))

    setup = gateway_setup(upstream)
    put_public_model_serving_mode!(setup, "lite")

    function_tool = %{
      "type" => "function",
      "name" => "lookup_lite_allowed_fixture",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic Lite allowed tools request",
        "tools" => [function_tool],
        "tool_choice" => %{
          "type" => "allowed_tools",
          "mode" => "auto",
          "tools" => [%{"type" => "function", "name" => function_tool["name"]}]
        }
      })

    assert %{
             "error" => %{
               "code" => "unsupported_parameter",
               "message" => "Unsupported parameter: tool_choice",
               "param" => "tool_choice"
             }
           } = json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "unsupported_parameter"
    assert request.request_metadata["gateway_denial"]["param"] == "tool_choice"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.request_id == ^request.id),
             :count
           ) == 0
  end

  @tag :issue_241
  test "POST /v1/responses forwards an official custom tool and its exact named choice", %{
    conn: conn
  } do
    upstream = start_upstream(issue_241_completed_response("resp_v1_custom_definition"))
    setup = gateway_setup(upstream)

    custom_tool = %{
      "type" => "custom",
      "name" => " custom_definition_fixture ",
      "description" => "  Synthetic grammar fixture  ",
      "defer_loading" => true,
      "allowed_callers" => ["programmatic", "direct", "programmatic"],
      "format" => %{
        "type" => "grammar",
        "definition" => "  ^fixture-[0-9]+$  ",
        "syntax" => "regex"
      }
    }

    tool_choice = %{"type" => "custom", "name" => custom_tool["name"]}

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic custom definition request",
        "tools" => [custom_tool],
        "tool_choice" => tool_choice
      })

    assert %{"id" => "resp_v1_custom_definition", "object" => "response"} =
             json_response(response, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [custom_tool]
    assert captured.json["tool_choice"] == tool_choice
    assert_issue_241_success_lifecycle!(setup)
  end

  @tag :issue_241
  test "POST /v1/responses rejects a Lite named custom choice before dispatch", %{conn: conn} do
    upstream = start_upstream(issue_241_completed_response("should_not_dispatch_lite_choice"))
    setup = gateway_setup(upstream)
    put_public_model_serving_mode!(setup, "lite")

    custom_tool = %{
      "type" => "custom",
      "name" => "lite_custom_choice_fixture",
      "description" => "Synthetic Lite choice fixture",
      "format" => %{
        "type" => "grammar",
        "definition" => ~s(start: "issue241"),
        "syntax" => "lark"
      }
    }

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic Lite custom choice request",
        "tools" => [custom_tool],
        "tool_choice" => %{"type" => "custom", "name" => custom_tool["name"]}
      })

    assert %{
             "error" => %{
               "code" => "unsupported_parameter",
               "message" => "Unsupported parameter: tool_choice",
               "param" => "tool_choice"
             }
           } = json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "unsupported_parameter"
    assert request.request_metadata["gateway_denial"]["param"] == "tool_choice"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.request_id == ^request.id),
             :count
           ) == 0
  end

  @tag :issue_241
  test "POST /v1/responses forwards only direct nested strict schema type repairs", %{conn: conn} do
    upstream = start_upstream(issue_241_completed_response("resp_v1_repaired_schema"))
    setup = gateway_setup(upstream)
    parameters = issue_241_repairable_parameters()

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic strict schema repair request",
        "tools" => [
          %{
            "type" => "function",
            "name" => "repair_schema_fixture",
            "strict" => true,
            "parameters" => parameters
          }
        ]
      })

    assert %{"id" => "resp_v1_repaired_schema", "object" => "response"} =
             json_response(response, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/responses"

    assert [captured_tool] = captured.json["tools"]

    expected_parameters =
      parameters
      |> put_in(["properties", "config", "type"], "object")
      |> put_in(["properties", "config", "properties", "entries", "type"], "array")
      |> put_in(
        ["properties", "config", "properties", "entries", "items", "type"],
        "object"
      )

    assert captured_tool == %{
             "type" => "function",
             "name" => "repair_schema_fixture",
             "strict" => true,
             "parameters" => expected_parameters
           }

    refute get_in(parameters, ["properties", "config"]) |> Map.has_key?("type")
    assert_issue_241_success_lifecycle!(setup)
  end

  @tag :issue_241
  test "POST /v1/responses tool validation failures have no dispatch or accounting effects", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    base_payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "synthetic rejected tool request"
    }

    invalid_cases = [
      {"malformed custom", "invalid_request", "tools",
       %{
         "tools" => [
           %{
             "type" => "custom",
             "name" => "malformed_custom_fixture",
             "format" => %{"type" => "grammar", "syntax" => "lark"}
           }
         ]
       }},
      {"unknown custom choice", "invalid_request", "tool_choice",
       %{
         "tools" => [%{"type" => "custom", "name" => "known_custom_fixture"}],
         "tool_choice" => %{"type" => "custom", "name" => "missing_custom_fixture"}
       }},
      {"executable name collision", "invalid_request", "tools",
       %{
         "tools" => [
           %{
             "type" => "function",
             "name" => "shared_fixture",
             "parameters" => %{"type" => "object", "properties" => %{}}
           },
           %{"type" => "custom", "name" => "shared_fixture"}
         ]
       }},
      {"explicit invalid public type", "invalid_function_parameters",
       "tools.0.parameters.properties.candidate.type",
       %{
         "tools" => [
           issue_241_strict_function_tool(%{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{"candidate" => %{"type" => "future-type"}},
             "required" => ["candidate"]
           })
         ]
       }},
      {"ambiguous repair evidence", "invalid_function_parameters",
       "tools.0.parameters.properties.candidate.type",
       %{
         "tools" => [
           issue_241_strict_function_tool(%{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{
               "candidate" => %{
                 "additionalProperties" => false,
                 "properties" => %{"value" => %{"type" => "string"}},
                 "required" => ["value"],
                 "items" => %{"type" => "string"}
               }
             },
             "required" => ["candidate"]
           })
         ]
       }},
      {"opaque combinator subtree", "invalid_function_parameters",
       "tools.0.parameters.properties.candidate.allOf.0.type",
       %{
         "tools" => [
           issue_241_strict_function_tool(%{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{
               "candidate" => %{
                 "type" => "string",
                 "allOf" => [
                   %{
                     "additionalProperties" => false,
                     "properties" => %{"value" => %{"type" => "string"}},
                     "required" => ["value"]
                   }
                 ]
               }
             },
             "required" => ["candidate"]
           })
         ]
       }}
    ]

    counts = durable_accounting_counts()

    Enum.each(invalid_cases, fn {label, expected_code, expected_param, payload} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", Map.merge(base_payload, payload))

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => ^expected_code,
                 "param" => ^expected_param
               }
             } = json_response(response, 400),
             label

      assert FakeUpstream.requests(upstream) == [], label
      assert durable_accounting_counts() == counts, label
    end)
  end

  @tag :issue_78
  test "POST /v1/responses rejects strict non-object roots before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_cases = [
      {"invalid_json_schema", "text.format.schema",
       %{
         "text" => %{
           "format" => %{
             "type" => "json_schema",
             "name" => "array_root_fixture",
             "strict" => true,
             "schema" => %{"type" => "array", "items" => %{"type" => "string"}}
           }
         }
       }},
      {"invalid_function_parameters", "tools.0.parameters",
       %{
         "tools" => [
           %{
             "type" => "function",
             "name" => "root_ref_fixture",
             "strict" => true,
             "parameters" => %{
               "$ref" => "#/$defs/arguments",
               "$defs" => %{
                 "arguments" => %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{"value" => %{"type" => "string"}},
                   "required" => ["value"]
                 }
               }
             }
           }
         ]
       }}
    ]

    counts = durable_accounting_counts()

    Enum.each(invalid_cases, fn {expected_code, expected_param, fields} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(
          "/v1/responses",
          Map.merge(
            %{
              "model" => setup.model.exposed_model_id,
              "input" => "synthetic strict root rejection"
            },
            fields
          )
        )

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => ^expected_code,
                 "param" => ^expected_param
               }
             } = json_response(response, 400)

      assert FakeUpstream.requests(upstream) == []
      assert durable_accounting_counts() == counts
    end)
  end

  @tag :command_read_protection
  test "POST /v1/responses forwards generic function file-read build output byte-exact",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_command_read_protection",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream, exposed_model_id: "gpt-4o", upstream_model_id: "gpt-4o")
    enable_request_compression!(setup.pool)
    command = "nl -ba src/private-example.ex | sed -n '1,75p'"
    call_id = "call_v1_private_file_read"
    original_output = compression_log_fixture("v1 private build output sentinel")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "tools" => [
          %{
            "type" => "function",
            "name" => "arbitrary_command_tool",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ],
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => call_id,
            "name" => "arbitrary_command_tool",
            "arguments" => Jason.encode!(%{"cmd" => command})
          },
          %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => original_output
          }
        ]
      })

    assert %{"id" => "resp_v1_command_read_protection"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    forwarded_output =
      captured.json["input"]
      |> Enum.find(&(&1["type"] == "function_call_output"))
      |> Map.fetch!("output")

    assert forwarded_output == original_output

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert %{
             "status" => "skipped",
             "reason" => "protected_tool_outputs",
             "route_class" => "proxy_stream",
             "transport" => "http_sse",
             "candidate_count" => 0,
             "compressed_count" => 0,
             "skipped_count" => 0,
             "protected_tool_output_skipped_count" => 1
           } = metadata = attempt.response_metadata["payload_compression"]

    metadata_text = inspect(metadata)
    refute metadata_text =~ command
    refute metadata_text =~ call_id
    refute metadata_text =~ "v1 private build output sentinel"
    refute Map.has_key?(metadata, "strategies")
  end

  test "POST /v1/responses preserves schema-bound tool output while compressing an unbound output",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_compressed_tool_output",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream, exposed_model_id: "gpt-4o", upstream_model_id: "gpt-4o")
    enable_request_compression!(setup.pool)
    schema_bound_output = Jason.encode!(%{"rows" => Enum.to_list(1..160)}, pretty: true)
    unbound_output = Jason.encode!(%{"rows" => Enum.to_list(161..320)}, pretty: true)

    assert byte_size(schema_bound_output) > 512
    assert byte_size(unbound_output) > 512

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "tools" => [
          %{
            "type" => "function",
            "name" => "schema_bound_public_http_fixture",
            "parameters" => %{"type" => "object", "properties" => %{}},
            "output_schema" => %{"type" => "object"}
          },
          %{
            "type" => "function",
            "name" => "unbound_public_http_fixture",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ],
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "call_public_http_schema_bound",
            "name" => "schema_bound_public_http_fixture",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call",
            "call_id" => "call_public_http_unbound",
            "name" => "unbound_public_http_fixture",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_public_http_schema_bound",
            "output" => schema_bound_output
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_public_http_unbound",
            "output" => unbound_output
          }
        ]
      })

    assert %{"id" => "resp_v1_compressed_tool_output"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    schema_bound_item =
      Enum.find(captured.json["input"], fn item ->
        item["type"] == "function_call_output" and
          item["call_id"] == "call_public_http_schema_bound"
      end)

    unbound_item =
      Enum.find(captured.json["input"], fn item ->
        item["type"] == "function_call_output" and item["call_id"] == "call_public_http_unbound"
      end)

    assert schema_bound_item["output"] == schema_bound_output
    assert Jason.decode!(schema_bound_item["output"]) == Jason.decode!(schema_bound_output)
    assert unbound_item["output"] != unbound_output
    assert Jason.decode!(unbound_item["output"]) == Jason.decode!(unbound_output)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/responses"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "compressed",
             "route_class" => "proxy_stream",
             "transport" => "http_sse",
             "candidate_count" => 1,
             "compressed_count" => 1,
             "skipped_count" => 0,
             "protected_tool_output_skipped_count" => 1
           } = metadata = attempt.response_metadata["payload_compression"]

    refute inspect(metadata) =~ "call_public_http_schema_bound"
    refute inspect(metadata) =~ "call_public_http_unbound"
  end

  @tag :v1_websocket_bridge_usage
  test "POST /v1/responses streaming settles retained terminal usage and pricing", %{
    conn: conn
  } do
    sentinel = "http-tail-#{System.unique_integer([:positive])}"
    padding_unit = "retained terminal padding "

    retained_padding =
      sentinel <>
        String.duplicate(
          padding_unit,
          div(RetainedBody.max_bytes(), byte_size(padding_unit)) + 128
        )

    terminal_payload =
      IO.iodata_to_binary([
        ~s({"type":"response.completed","response":{"id":"resp_v1_retained_usage_terminal","status":"completed","service_tier":"flex","usage":{"input_tokens":16,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"reasoning_tokens":0,"total_tokens":21},"output":[{"type":"message","content":[{"type":"output_text","text":),
        Jason.encode!(retained_padding),
        ~s(}]}]}})
      ])

    terminal_event = "event: response.completed\ndata: " <> terminal_payload <> "\n\n"
    assert byte_size(terminal_event) > RetainedBody.max_bytes()

    retained_terminal =
      RetainedBody.empty() |> RetainedBody.append(terminal_event) |> RetainedBody.read()

    assert byte_size(retained_terminal) == RetainedBody.max_bytes()

    assert ResponseUsage.from_sse(retained_terminal) == %{
             status: "usage_unknown",
             source: "sse_usage_missing"
           }

    usage_split = :binary.match(terminal_event, ~s("usage")) |> elem(0) |> Kernel.+(3)

    <<terminal_before_usage::binary-size(^usage_split), terminal_after_usage::binary>> =
      terminal_event

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.in_progress",
           %{
             "type" => "response.in_progress",
             "response" => %{
               "id" => "resp_v1_retained_usage_progress",
               "status" => "in_progress",
               "service_tier" => "auto",
               "usage" => %{
                 "input_tokens" => 0,
                 "cached_input_tokens" => 0,
                 "output_tokens" => 0,
                 "reasoning_tokens" => 0,
                 "total_tokens" => 0
               }
             }
           }},
          terminal_before_usage,
          terminal_after_usage
        ])
      )

    setup = gateway_setup(upstream)

    flex_pricing =
      pricing_snapshot!(setup.model, %{
        config: pricing_config(%{"service_tier" => "flex"}),
        input_token_micros: Decimal.new(25),
        output_token_micros: Decimal.new(50)
      })

    {{conn, telemetry_events}, log_output} =
      with_log(fn ->
        capture_stream_truncation_telemetry(fn ->
          conn
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic retained usage stream request",
            "service_tier" => "auto",
            "stream" => true
          })
        end)
      end)

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "resp_v1_retained_usage_progress"
    assert conn.resp_body =~ "resp_v1_retained_usage_terminal"
    assert conn.resp_body =~ sentinel

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert request.requested_service_tier == "auto"
    assert request.actual_service_tier == "flex"
    assert request.service_tier == "flex"
    assert request.request_metadata["pricing"]["status"] == "priced"
    assert request.request_metadata["pricing"]["actual_service_tier"] == "flex"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.transport == "http_sse"
    assert attempt.upstream_status_code == 200
    assert attempt.usage_status == "usage_known"

    assert %{
             "terminal_seen" => true,
             "terminal_kind" => "completed",
             "terminal_status" => "completed",
             "synthetic_terminal_sent" => false
           } = attempt.response_metadata["public_openai_responses_stream"]

    assert [settlement] =
             Repo.all(
               from(l in LedgerEntry,
                 where:
                   l.request_id == ^request.id and l.entry_kind == "settlement" and
                     l.amount_status == "recorded"
               )
             )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 16
    assert settlement.cached_input_tokens == 0
    assert settlement.output_tokens == 5
    assert settlement.reasoning_tokens == nil
    assert settlement.total_tokens == 21
    assert settlement.pricing_snapshot_id == flex_pricing.id
    assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(650))
    assert settlement.details["pricing_status"] == "priced"
    assert settlement.details["actual_service_tier"] == "flex"
    assert settlement.details["settled_cost_micros"] == "650.000000000"

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.usage_status == "usage_known"
    assert log.requested_service_tier == "auto"
    assert log.actual_service_tier == "flex"
    assert log.token_counts.input_tokens == 16
    assert log.token_counts.output_tokens == 5
    assert log.token_counts.total_tokens == 21
    assert log.cost.status == "priced"
    assert Decimal.positive?(log.cost.usd)

    assert telemetry_events != []

    persisted =
      inspect({
        request.request_metadata,
        attempt.response_metadata,
        settlement.details,
        RequestLogs.list(setup.pool, filters: %{request_id: request.id})
      })

    refute persisted =~ sentinel
    refute log_output =~ sentinel
    refute inspect(telemetry_events) =~ sentinel
  end

  test "POST /v1/responses rejects unsafe reasoning effort before dispatch", %{conn: conn} do
    unsafe_effort = "synthetic freeform effort text"
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic unsafe effort request",
        "reasoning" => %{"effort" => unsafe_effort}
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "invalid_request"
    assert error["param"] == "reasoning.effort"
    refute conn.resp_body =~ unsafe_effort
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses rejects unsafe reasoning context before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_contexts = ["recent_turns", "", " ", 1, ["all_turns"], %{"mode" => "all_turns"}]

    Enum.each(invalid_contexts, fn invalid_context ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic unsafe context request",
          "reasoning" => %{"context" => invalid_context}
        })

      assert %{"error" => error} = json_response(response, 400)
      assert error["code"] == "invalid_request"
      assert error["param"] == "reasoning.context"
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses accepts truncation but does not forward it upstream", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_truncation_not_forwarded",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 truncation request",
        "truncation" => "disabled"
      })

    assert %{"id" => "resp_v1_truncation_not_forwarded", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    refute Map.has_key?(captured.json, "truncation")
  end

  test "POST /v1/responses preserves request-shaped additional_tools input items", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_additional_tools",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    additional_tools_item = additional_tools_item()

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{"role" => "user", "content" => "synthetic response input"},
          additional_tools_item
        ]
      })

    assert %{"id" => "resp_v1_additional_tools", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    refute Map.has_key?(captured.json, "tools")
    refute Map.has_key?(captured.json, "tool_choice")

    assert captured.json["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic response input"}]
             },
             additional_tools_item
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/responses"

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "synthetic response input"
    refute metadata_text =~ "lookup_additional_fixture"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  test "POST /v1/responses rejects malformed additional_tools input items before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_items = [
      %{"type" => "additional_tools", "tools" => []},
      %{"type" => "additional_tools", "role" => "assistant", "tools" => []},
      %{
        "type" => "additional_tools",
        "role" => "developer",
        "tools" => [],
        "status" => "completed"
      }
    ]

    Enum.each(invalid_items, fn invalid_item ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [invalid_item]
        })

      assert %{"error" => error} = json_response(response, 400)
      assert error["code"] == "invalid_request"
      assert error["param"] == "input"
      refute response.resp_body =~ "completed"
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses rejects remote MCP tool definitions before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    mcp_tool = %{
      "type" => "mcp",
      "server_label" => "fixture-mcp",
      "tunnel_id" => "mcp_tunnel_fixture"
    }

    cases = [
      {%{"tools" => [mcp_tool]}, "tools"},
      {%{
         "input" => [
           %{
             "type" => "additional_tools",
             "role" => "developer",
             "tools" => [mcp_tool]
           }
         ]
       }, "input"}
    ]

    Enum.each(cases, fn {payload_update, expected_param} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(
          "/v1/responses",
          payload_update
          |> Map.put_new("input", "synthetic remote MCP request")
          |> Map.put("model", setup.model.exposed_model_id)
        )

      assert %{"error" => error} = json_response(response, 400)
      assert error["type"] == "invalid_request_error"
      assert error["code"] == "invalid_request"
      assert error["message"] == "remote MCP tools are not supported"
      assert error["param"] == expected_param
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses rejects nested tool_search before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    counts = durable_accounting_counts()

    supported_tool = %{
      "type" => "function",
      "name" => "lookup_nested_tool_search",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    for {position, stream} <- [{0, false}, {1, false}, {2, true}] do
      tools =
        [supported_tool, supported_tool]
        |> List.insert_at(position, %{"type" => "tool_search"})

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "stream" => stream,
          "input" => [
            %{"role" => "user", "content" => "synthetic nested tool search"},
            %{
              "type" => "additional_tools",
              "role" => "developer",
              "tools" => tools
            }
          ]
        })

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "message" => "tool_search tools are not supported",
                 "param" => "input"
               }
             } = json_response(response, 400)

      assert FakeUpstream.count(upstream) == 0
      assert durable_accounting_counts() == counts
      assert %{items: [], total: 0} = RequestLogs.list(setup.pool)
    end
  end

  test "POST /v1/responses rejects malformed instruction-role content before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "developer",
            "content" => [%{"type" => "input_image", "image_url" => %{"url" => nil}}]
          }
        ]
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "invalid_request"
    assert error["param"] == "input"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses non-streaming marks visible upstream output once", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "first"}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "second"}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "third"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_non_stream_visible_once",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    {conn, queries} =
      capture_repo_queries(fn ->
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic v1 visible marker request"
        })
      end)

    assert %{"id" => "resp_v1_non_stream_visible_once"} = json_response(conn, 200)
    assert visible_codex_turn_update_count(queries) == 1
  end

  @tag :custom_tool_replay
  @tag :tool_result_previous_response
  test "POST /v1/responses forwards namespaced custom tool replay without metadata leakage", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_custom_tool_replay",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_v1_custom_tool_previous",
        "store" => false,
        "input" => [
          %{
            "type" => "custom_tool_call",
            "id" => "ctc_v1_http_call",
            "call_id" => "call_v1_custom_namespaced",
            "namespace" => "browser.search",
            "name" => "lookup",
            "input" => "{}",
            "status" => "completed",
            "metadata" => %{"turn_id" => "turn_v1_custom_call_legacy"},
            "internal_chat_message_metadata_passthrough" => %{
              "turn_id" => "turn_v1_custom_call",
              "replay_context" => "custom-call-context"
            }
          },
          %{
            "type" => "custom_tool_call_output",
            "id" => "ctco_v1_http_call",
            "call_id" => "call_v1_custom_namespaced",
            "name" => "lookup",
            "output" => "synthetic custom output",
            "metadata" => %{"turn_id" => "turn_v1_custom_output_legacy"},
            "internal_chat_message_metadata_passthrough" => %{
              "turn_id" => "turn_v1_custom_output"
            }
          }
        ]
      })

    assert %{"id" => "resp_v1_custom_tool_replay", "object" => "response"} =
             json_response(conn, 200)

    assert FakeUpstream.count(upstream) == 1
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["previous_response_id"] == "resp_v1_custom_tool_previous"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert [custom_call, custom_output] = captured.json["input"]
    assert custom_call["type"] == "custom_tool_call"
    assert custom_call["namespace"] == "browser.search"
    assert custom_call["name"] == "lookup"
    assert custom_call["input"] == "{}"

    assert custom_call["internal_chat_message_metadata_passthrough"] == %{
             "turn_id" => "turn_v1_custom_call",
             "replay_context" => "custom-call-context"
           }

    refute Map.has_key?(custom_call, "status")

    assert custom_output["type"] == "custom_tool_call_output"
    assert custom_output["call_id"] == "call_v1_custom_namespaced"
    assert custom_output["name"] == "lookup"
    assert custom_output["output"] == "synthetic custom output"

    assert custom_output["internal_chat_message_metadata_passthrough"] == %{
             "turn_id" => "turn_v1_custom_output"
           }

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})
    refute persistence_text =~ "synthetic custom output"
    refute persistence_text =~ "resp_v1_custom_tool_previous"
    refute persistence_text =~ "call_v1_custom_namespaced"
    refute persistence_text =~ "turn_v1_custom_call"
    refute persistence_text =~ "turn_v1_custom_output"
    refute persistence_text =~ "custom-call-context"
    refute persistence_text =~ setup.authorization
    refute persistence_text =~ setup.raw_key
    refute persistence_text =~ "raw_request"
  end

  @tag :custom_tool_replay
  @tag :invalid_request_error
  test "POST /v1/responses rejects reserved tool-call metadata before dispatch or accounting", %{
    conn: conn
  } do
    reserved_key = "executed_tool_calls"
    reserved_sentinel = "reserved-executed-tool-calls-http-sentinel"
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_reserved_metadata_http",
            "name" => "lookup",
            "output" => "synthetic custom output",
            "internal_chat_message_metadata_passthrough" => %{
              "turn_id" => "turn_reserved_metadata_http",
              reserved_key => reserved_sentinel
            }
          }
        ]
      })

    assert %{"error" => error} = json_response(response, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_request"
    assert error["param"] == "input"
    refute response.resp_body =~ "internal_chat_message_metadata_passthrough"
    refute response.resp_body =~ reserved_sentinel
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    refute_received {Events, %{reason: "request_finalized"}}

    persistence_text = inspect(RequestLogs.list(setup.pool))
    refute persistence_text =~ reserved_key
    refute persistence_text =~ reserved_sentinel
  end

  @tag :custom_tool_replay
  test "POST /v1/responses rejects invalid custom tool replay before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_v1_custom_tool_previous",
        "input" => [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_v1_custom_namespaced",
            "namespace" => " ",
            "name" => "lookup",
            "input" => "{}"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_v1_custom_namespaced",
            "output" => "synthetic custom output"
          }
        ]
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "invalid_request"
    assert error["param"] == "input"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :tool_result_previous_response
  test "POST /v1/responses characterizes function-only namespace choices", %{conn: conn} do
    upstream = start_upstream(issue_241_completed_response("resp_v1_function_namespace"))
    setup = gateway_setup(upstream)

    namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic function namespace",
      "tools" => [
        %{
          "type" => "function",
          "name" => "namespace_function_fixture",
          "description" => "Synthetic namespace function",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic function namespace request",
        "tools" => [namespace_tool],
        "tool_choice" => %{"type" => "function", "name" => "namespace_function_fixture"}
      })

    assert %{"id" => "resp_v1_function_namespace", "object" => "response"} =
             json_response(response, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [namespace_tool]

    assert captured.json["tool_choice"] == %{
             "type" => "function",
             "name" => "namespace_function_fixture"
           }

    assert_issue_241_success_lifecycle!(setup)
  end

  test "POST /v1/responses forwards mixed namespaced custom tools without metadata leakage", %{
    conn: conn
  } do
    upstream = start_upstream(issue_241_completed_response("resp_v1_namespace_custom_definition"))
    setup = gateway_setup(upstream)
    prompt_marker = "synthetic namespaced custom prompt marker"
    description_marker = "synthetic namespaced custom description marker"
    custom_input_marker = "synthetic_namespaced_custom_input_marker"
    grammar_marker = ~s(start: "#{custom_input_marker}")

    namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic mixed namespace",
      "tools" => [
        %{
          "type" => "function",
          "name" => "namespaced_function_fixture",
          "description" => "Synthetic adjacent function",
          "parameters" => %{"type" => "object", "properties" => %{}}
        },
        %{
          "type" => "custom",
          "name" => "namespaced_custom_fixture",
          "description" => description_marker,
          "format" => %{
            "type" => "grammar",
            "definition" => grammar_marker,
            "syntax" => "lark"
          }
        }
      ]
    }

    tool_choice = %{"type" => "custom", "name" => "namespaced_custom_fixture"}

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => prompt_marker,
        "tools" => [namespace_tool],
        "tool_choice" => tool_choice
      })

    assert %{"id" => "resp_v1_namespace_custom_definition", "object" => "response"} =
             json_response(response, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [namespace_tool]
    assert captured.json["tool_choice"] == tool_choice

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    persistence_text =
      inspect({request.request_metadata, attempt.response_metadata, RequestLogs.list(setup.pool)})

    for marker <- [prompt_marker, description_marker, grammar_marker, custom_input_marker] do
      refute persistence_text =~ marker
    end

    assert_issue_241_success_lifecycle!(setup)
  end

  test "POST /v1/responses restores only declared custom namespaces in collected output", %{
    conn: conn
  } do
    namespaced_name = "collected_namespaced_custom_fixture"
    flat_name = "collected_flat_custom_fixture"

    output = [
      %{
        "type" => "custom_tool_call",
        "name" => namespaced_name,
        "call_id" => "call_collected_omitted",
        "input" => "collected_omitted"
      },
      %{
        "type" => "custom_tool_call",
        "name" => namespaced_name,
        "namespace" => nil,
        "call_id" => "call_collected_null",
        "input" => "collected_null"
      },
      %{
        "type" => "custom_tool_call",
        "name" => namespaced_name,
        "namespace" => "provider.tools",
        "call_id" => "call_collected_explicit",
        "input" => "collected_explicit"
      },
      %{
        "type" => "custom_tool_call",
        "name" => flat_name,
        "call_id" => "call_collected_flat",
        "input" => "collected_flat"
      },
      %{
        "type" => "custom_tool_call",
        "name" => "collected_unknown_custom_fixture",
        "namespace" => nil,
        "call_id" => "call_collected_unknown",
        "input" => "collected_unknown"
      }
    ]

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_collected_custom_namespaces",
               "status" => "completed",
               "output" => output,
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    namespace_tool = %{
      "type" => "namespace",
      "name" => "functions",
      "description" => "Synthetic collected namespace",
      "tools" => [%{"type" => "custom", "name" => namespaced_name}]
    }

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic collected namespace restoration",
        "tools" => [namespace_tool, %{"type" => "custom", "name" => flat_name}]
      })

    assert %{"output" => [omitted, null, explicit, flat, unknown]} = json_response(response, 200)
    assert omitted["namespace"] == "functions"
    assert null["namespace"] == "functions"
    assert explicit["namespace"] == "provider.tools"
    refute Map.has_key?(flat, "namespace")
    assert unknown["namespace"] == nil
  end

  test "POST /v1/responses restores declared custom namespaces in SSE output items", %{
    conn: conn
  } do
    name = "streamed_namespaced_custom_fixture"

    calls = [
      %{
        "type" => "custom_tool_call",
        "name" => name,
        "call_id" => "call_streamed_omitted",
        "input" => "streamed_omitted"
      },
      %{
        "type" => "custom_tool_call",
        "name" => name,
        "namespace" => nil,
        "call_id" => "call_streamed_null",
        "input" => "streamed_null"
      }
    ]

    events =
      Enum.map(calls, fn call ->
        {"response.output_item.done", %{"type" => "response.output_item.done", "item" => call}}
      end) ++
        [
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_streamed_custom_namespaces",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ]

    upstream = start_upstream(FakeUpstream.sse_stream(events))
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic streamed namespace restoration",
        "stream" => true,
        "tools" => [
          %{
            "type" => "namespace",
            "name" => "functions",
            "description" => "Synthetic streamed namespace",
            "tools" => [%{"type" => "custom", "name" => name}]
          }
        ]
      })

    restored_calls =
      response.resp_body
      |> public_sse_events()
      |> Enum.filter(&(&1["event"] == "response.output_item.done"))
      |> Enum.map(&get_in(&1, ["data", "item"]))

    assert Enum.map(restored_calls, & &1["namespace"]) == ["functions", "functions"]
  end

  test "POST /v1/responses rejects invalid namespaced custom tools before gateway accounting", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_tools = [
      {"malformed nested custom",
       %{
         "type" => "namespace",
         "name" => "functions",
         "description" => "Synthetic namespace",
         "tools" => [
           %{
             "type" => "custom",
             "name" => "malformed_namespaced_custom_fixture",
             "format" => %{"type" => "grammar", "syntax" => "lark"}
           }
         ]
       }},
      {"hosted namespace child",
       %{
         "type" => "namespace",
         "name" => "functions",
         "description" => "Synthetic namespace",
         "tools" => [%{"type" => "web_search_preview"}]
       }},
      {"nested namespace child",
       %{
         "type" => "namespace",
         "name" => "functions",
         "description" => "Synthetic namespace",
         "tools" => [
           %{
             "type" => "namespace",
             "name" => "nested",
             "description" => "Synthetic nested namespace",
             "tools" => [
               %{
                 "type" => "function",
                 "name" => "nested_function_fixture",
                 "parameters" => %{"type" => "object", "properties" => %{}}
               }
             ]
           }
         ]
       }},
      {"duplicate executable name",
       [
         %{
           "type" => "function",
           "name" => "duplicated_namespaced_executable",
           "parameters" => %{"type" => "object", "properties" => %{}}
         },
         %{
           "type" => "namespace",
           "name" => "functions",
           "description" => "Synthetic namespace",
           "tools" => [
             %{"type" => "custom", "name" => "duplicated_namespaced_executable"}
           ]
         }
       ]}
    ]

    for {label, tools} <- invalid_tools do
      tools = if is_list(tools), do: tools, else: [tools]

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic invalid namespaced custom request",
          "tools" => tools
        })

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "param" => "tools"
               }
             } = json_response(response, 400),
             label

      assert FakeUpstream.count(upstream) == 0, label
      assert Repo.aggregate(Request, :count) == 0, label
      assert Repo.aggregate(Attempt, :count) == 0, label
      assert Repo.aggregate(LedgerEntry, :count) == 0, label
      assert Repo.aggregate(RequestLogFact, :count) == 0, label
    end
  end

  test "POST /v1/responses keeps Lite namespaced custom choice denial inside gateway accounting",
       %{
         conn: conn
       } do
    upstream =
      start_upstream(issue_241_completed_response("should_not_dispatch_lite_namespace_choice"))

    setup = gateway_setup(upstream)
    put_public_model_serving_mode!(setup, "lite")

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic Lite namespaced custom choice request",
        "tools" => [
          %{
            "type" => "namespace",
            "name" => "functions",
            "description" => "Synthetic namespace",
            "tools" => [
              %{
                "type" => "custom",
                "name" => "lite_namespaced_custom_fixture",
                "format" => %{
                  "type" => "grammar",
                  "definition" => ~s(start: "lite_namespaced_custom_input"),
                  "syntax" => "lark"
                }
              }
            ]
          }
        ],
        "tool_choice" => %{"type" => "custom", "name" => "lite_namespaced_custom_fixture"}
      })

    assert %{
             "error" => %{
               "code" => "unsupported_parameter",
               "message" => "Unsupported parameter: tool_choice",
               "param" => "tool_choice"
             }
           } = json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "unsupported_parameter"
    assert request.request_metadata["gateway_denial"]["param"] == "tool_choice"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.request_id == ^request.id),
             :count
           ) == 0
  end

  test "POST /v1/responses keeps nested namespace lowering and strict function handling", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_http_namespace_tools",
               "status" => "completed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    namespace_tool = %{
      "type" => "namespace",
      "name" => "fixture_namespace",
      "description" => "Synthetic namespace tools",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lower_namespaced_fixture",
          "description" => "Lower synthetic namespaced fixture",
          "parameters" => non_strict_tool_schema(),
          "strict" => false,
          "defer_loading" => false
        },
        %{
          "type" => "function",
          "name" => "lookup_namespaced_fixture",
          "description" => "Lookup synthetic namespaced fixture",
          "parameters" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"value" => %{"type" => "string"}},
            "required" => ["value"]
          },
          "strict" => true,
          "defer_loading" => true
        }
      ]
    }

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic namespace request",
        "tools" => [namespace_tool],
        "tool_choice" => %{"type" => "function", "name" => "lookup_namespaced_fixture"}
      })

    assert %{"id" => "resp_v1_http_namespace_tools", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    [non_strict_function, strict_function] = namespace_tool["tools"]

    expected_namespace_tool =
      Map.put(namespace_tool, "tools", [
        Map.put(non_strict_function, "parameters", lowered_tool_schema()),
        strict_function
      ])

    assert captured.json["tools"] == [expected_namespace_tool]

    [captured_namespace] = captured.json["tools"]
    assert Enum.at(captured_namespace["tools"], 1) == strict_function

    assert captured.json["tool_choice"] == %{
             "type" => "function",
             "name" => "lookup_namespaced_fixture"
           }

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"
    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic namespace request"
    refute metadata =~ "lookup_namespaced_fixture"
  end

  test "POST /v1/responses rejects malformed namespace and unsupported tools before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_tools = [
      %{
        "type" => "namespace",
        "name" => "fixture_namespace",
        "description" => "Synthetic namespace tools",
        "tools" => [%{"type" => "function", "name" => "missing_parameters"}]
      },
      %{"type" => "unsupported_tool", "name" => "fixture"}
    ]

    for invalid_tool <- invalid_tools do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic invalid tool request",
          "tools" => [invalid_tool]
        })

      assert %{"error" => error} = json_response(response, 400)
      assert error["type"] == "invalid_request_error"
      assert error["code"] == "invalid_request"
      assert error["param"] == "tools"
      refute response.resp_body =~ "missing_parameters"
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :tool_result_previous_response
  test "POST /v1/responses forwards safe continuation shape and rejects malformed item references without echoing payloads",
       %{
         conn: conn
       } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_http_safe_continuation",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    previous_response_id = "resp_v1_http_safe_previous_#{System.unique_integer([:positive])}"
    tool_call_id = "call_v1_http_safe_#{System.unique_integer([:positive])}"

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => previous_response_id,
        "store" => false,
        "input" => [
          %{"type" => "item_reference", "id" => "msg_v1_http_safe_reference"},
          %{
            "type" => "function_call_output",
            "call_id" => tool_call_id,
            "name" => "lookup",
            "namespace" => "browser.search",
            "output" => "{\"ok\":true}"
          },
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
          }
        ]
      })

    assert %{"id" => "resp_v1_http_safe_continuation", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["previous_response_id"] == previous_response_id
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert Enum.map(captured.json["input"], & &1["type"]) == [
             "item_reference",
             "function_call_output",
             "message"
           ]

    assert hd(captured.json["input"])["id"] == "msg_v1_http_safe_reference"
    assert Enum.at(captured.json["input"], 1)["call_id"] == tool_call_id
    assert Enum.at(captured.json["input"], 1)["name"] == "lookup"
    assert Enum.at(captured.json["input"], 1)["namespace"] == "browser.search"
    assert Enum.at(captured.json["input"], 2)["role"] == "user"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    invalid_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => previous_response_id,
        "input" => [
          %{
            "type" => "item_reference",
            "id" => "msg_v1_http_unsafe_reference",
            "output" => "unsafe-inline-leak"
          },
          %{
            "type" => "function_call_output",
            "call_id" => tool_call_id,
            "output" => "{\"ok\":true}"
          }
        ]
      })

    invalid_response = json_response(invalid_conn, 400)
    assert %{"error" => error} = invalid_response
    assert error["code"] == "invalid_request"
    assert error["param"] == "input"

    invalid_text = inspect(invalid_response)
    refute invalid_text =~ "unsafe-inline-leak"
    refute invalid_text =~ "msg_v1_http_unsafe_reference"

    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
  end

  @tag :structured_tool_result_pass_through
  test "POST /v1/responses forwards structured tool output unchanged and keeps projections shape-only",
       %{conn: conn} do
    setup_runtime_ingress_override(%OperationalSettings{gateway_debug?: true})

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_http_structured_tool_result",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    previous_response_id = "resp_v1_http_structured_previous"
    tool_call_id = "call_v1_http_structured_tool"
    structured_output = structured_tool_result_output()

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => previous_response_id,
        "store" => false,
        "input" => [
          %{"type" => "item_reference", "id" => "msg_v1_http_structured_reference"},
          %{
            "type" => "function_call_output",
            "call_id" => tool_call_id,
            "output" => structured_output
          }
        ]
      })

    assert %{"id" => "resp_v1_http_structured_tool_result", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["previous_response_id"] == previous_response_id
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert Enum.map(captured.json["input"], & &1["type"]) == [
             "item_reference",
             "function_call_output"
           ]

    assert Enum.at(captured.json["input"], 1)["call_id"] == tool_call_id

    assert_payload_equal_no_echo!(
      Enum.at(captured.json["input"], 1)["output"],
      structured_output,
      "structured function_call_output output was not forwarded unchanged"
    )

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    assert get_in(attempt.response_metadata, [
             "gateway_debug",
             "shape",
             "client",
             "entries",
             "tool_result_count"
           ]) == 1

    assert get_in(attempt.response_metadata, [
             "gateway_debug",
             "items",
             "tool_result_types"
           ]) == ["function_call_output"]

    projection_text =
      inspect({request.request_metadata, attempt.response_metadata, RequestLogs.list(setup.pool)})

    assert_no_sentinel_echo!(projection_text, structured_tool_result_sentinels())
    refute projection_text =~ previous_response_id
    refute projection_text =~ tool_call_id
  end

  @tag :tool_result_previous_response
  test "POST /v1/responses keeps store false replay item ids at the raw Responses boundary", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_http_store_false_replay_ids",
               "status" => "completed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_v1_http_store_false_previous",
        "store" => false,
        "input" => [
          %{
            "type" => "reasoning",
            "id" => "rs_v1_http_store_false_replay",
            "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
            "content" => [
              %{"type" => "reasoning_text", "text" => "synthetic reasoning replay"}
            ],
            "encrypted_content" => "synthetic-encrypted-reasoning"
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "id" => "msg_v1_http_store_false_replay",
            "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
          },
          %{
            "type" => "function_call",
            "id" => "fc_v1_http_store_false_replay",
            "call_id" => "call_v1_http_store_false_replay",
            "name" => "lookup_fixture",
            "namespace" => "fixture_namespace",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "id" => "fco_v1_http_store_false_replay",
            "call_id" => "call_v1_http_store_false_replay",
            "output" => "synthetic tool output"
          },
          %{"type" => "item_reference", "id" => "msg_v1_http_store_false_reference"}
        ]
      })

    assert %{"id" => "resp_v1_http_store_false_replay_ids", "object" => "response"} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["store"] == false
    assert captured.json["previous_response_id"] == "resp_v1_http_store_false_previous"

    assert Enum.map(captured.json["input"], &Map.get(&1, "id")) == [
             "rs_v1_http_store_false_replay",
             "msg_v1_http_store_false_replay",
             "fc_v1_http_store_false_replay",
             "fco_v1_http_store_false_replay",
             "msg_v1_http_store_false_reference"
           ]

    assert Enum.at(captured.json["input"], 2)["call_id"] == "call_v1_http_store_false_replay"
    assert Enum.at(captured.json["input"], 3)["call_id"] == "call_v1_http_store_false_replay"

    assert Enum.at(captured.json["input"], 0)["content"] == [
             %{"type" => "reasoning_text", "text" => "synthetic reasoning replay"}
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic summary"
    refute metadata =~ "synthetic reasoning replay"
    refute metadata =~ "synthetic assistant replay"
    refute metadata =~ "synthetic tool output"
    refute metadata =~ "resp_v1_http_store_false_previous"
    refute metadata =~ "call_v1_http_store_false_replay"
  end

  @tag :tool_result_previous_response
  test "POST /v1/responses drops stateless reasoning from real opencode ordinary replay shape", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_http_opencode_ordinary_replay",
               "status" => "completed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "include" => ["reasoning.encrypted_content"],
        "prompt_cache_key" => "fixture-cache-key",
        "reasoning" => %{"effort" => "xhigh", "summary" => "detailed"},
        "store" => false,
        "stream" => true,
        "text" => %{"verbosity" => "medium"},
        "tool_choice" => "auto",
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup_fixture",
            "parameters" => %{
              "type" => "object",
              "properties" => %{},
              "additionalProperties" => false
            }
          }
        ],
        "input" => [
          %{"role" => "developer", "content" => "synthetic developer instruction"},
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic user request"}]
          },
          %{
            "type" => "reasoning",
            "content" => [
              %{"type" => "reasoning_text", "text" => "synthetic stateless reasoning"}
            ],
            "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
            "encrypted_content" => "synthetic-encrypted-reasoning"
          },
          %{
            "id" => "msg-1",
            "role" => "assistant",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
          },
          %{
            "id" => "fc_v1_http_replay",
            "type" => "function_call",
            "call_id" => "call_v1_http_replay",
            "name" => "lookup_fixture",
            "arguments" => "{\"value\":\"sample\"}"
          },
          %{
            "id" => "fco-1",
            "type" => "function_call_output",
            "call_id" => "call_v1_http_replay",
            "output" => "synthetic tool output"
          }
        ]
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "event: response.completed\n"
    assert conn.resp_body =~ "resp_v1_http_opencode_ordinary_replay"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured.json, "previous_response_id")
    assert captured.json["instructions"] == "synthetic developer instruction"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    assert captured.json["reasoning"] == %{"effort" => "xhigh", "summary" => "detailed"}
    assert captured.json["include"] == ["reasoning.encrypted_content"]

    assert Enum.map(captured.json["input"], & &1["type"]) == [
             "message",
             "message",
             "function_call",
             "function_call_output"
           ]

    refute inspect(captured.json["input"]) =~ "synthetic-encrypted-reasoning"
    refute inspect(captured.json["input"]) =~ "synthetic stateless reasoning"
    assert %{"role" => "assistant", "phase" => "commentary"} = Enum.at(captured.json["input"], 1)
    refute Map.has_key?(Enum.at(captured.json["input"], 1), "id")
    assert Enum.at(captured.json["input"], 2)["id"] == "fc_v1_http_replay"
    assert Enum.at(captured.json["input"], 2)["call_id"] == "call_v1_http_replay"
    refute Map.has_key?(Enum.at(captured.json["input"], 3), "id")
    assert Enum.at(captured.json["input"], 3)["call_id"] == "call_v1_http_replay"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic developer instruction"
    refute metadata =~ "synthetic user request"
    refute metadata =~ "synthetic summary"
    refute metadata =~ "synthetic assistant replay"
    refute metadata =~ "synthetic tool output"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  @tag :tool_result_previous_response
  test "POST /v1/responses drops stateless OMP reasoning and normalizes function call status", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_http_omp_completed_tool_replay",
               "status" => "completed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "store" => false,
        "stream" => true,
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic OMP request"}]
          },
          %{
            "type" => "reasoning",
            "content" => [],
            "summary" => [%{"type" => "summary_text", "text" => "synthetic OMP summary"}],
            "encrypted_content" => "synthetic-omp-encrypted-reasoning"
          },
          %{
            "type" => "function_call",
            "call_id" => "call_v1_http_omp_replay",
            "name" => "lookup_fixture",
            "arguments" => "{}",
            "status" => "completed"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_v1_http_omp_replay",
            "output" => "synthetic OMP tool output"
          }
        ]
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "event: response.completed\n"
    assert conn.resp_body =~ "resp_v1_http_omp_completed_tool_replay"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert Enum.map(captured.json["input"], & &1["type"]) == [
             "message",
             "function_call",
             "function_call_output"
           ]

    refute inspect(captured.json["input"]) =~ "synthetic-omp-encrypted-reasoning"
    refute Map.has_key?(Enum.at(captured.json["input"], 1), "status")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic OMP request"
    refute metadata =~ "synthetic OMP summary"
    refute metadata =~ "synthetic OMP tool output"
    refute metadata =~ "call_v1_http_omp_replay"
  end

  test "POST /v1/responses non-streaming preserves web search action queries", %{conn: conn} do
    web_search_item = web_search_call_item("ws_call_non_stream")

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_web_search_queries",
               "status" => "completed",
               "output" => [
                 web_search_item,
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "search complete"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic web search response"
      })

    response = json_response(conn, 200)
    assert %{"id" => "resp_v1_web_search_queries", "object" => "response"} = response
    assert [public_web_search | _rest] = response["output"]
    assert public_web_search["type"] == "web_search_call"

    assert public_web_search["action"] == %{
             "type" => "search",
             "query" => "synthetic release notes",
             "queries" => ["synthetic release notes", "synthetic changelog"]
           }

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
  end

  test "POST /v1/responses forwards indexed web search tool shape upstream", %{conn: conn} do
    tool = %{
      "type" => "web_search",
      "external_web_access" => true,
      "index_gated_web_access" => true
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_indexed_web_search_tool",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "indexed search accepted"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic indexed web search request",
        "tools" => [tool]
      })

    assert %{"id" => "resp_v1_indexed_web_search_tool"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [tool]
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
  end

  test "POST /v1/responses forwards exact web search domain filters without external access", %{
    conn: conn
  } do
    tool = %{
      "type" => "web_search",
      "filters" => %{
        "allowed_domains" => [" Example.COM ", "example.com", "Example.COM"],
        "blocked_domains" => [" blocked.example ", "blocked.example", "blocked.example"]
      }
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_web_search_domain_filters",
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic filtered web search request",
        "stream" => false,
        "store" => true,
        "tools" => [tool]
      })

    assert %{"id" => "resp_v1_web_search_domain_filters"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["tools"] == [tool]
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    refute Map.has_key?(hd(captured.json["tools"]), "external_web_access")
  end

  test "POST /v1/responses rejects an unsupported web search filter before dispatch", %{
    conn: conn
  } do
    rejected_field = "unsupported"
    rejected_value = "other.example"
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic invalid filtered web search request",
        "tools" => [
          %{
            "type" => "web_search",
            "filters" => %{
              "allowed_domains" => ["example.com"],
              rejected_field => [rejected_value]
            }
          }
        ]
      })

    public_error = json_response(conn, 400)

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "param" => "tools"
             }
           } = public_error

    public_error_text = Jason.encode!(public_error)
    refute public_error_text =~ rejected_field
    refute public_error_text =~ rejected_value

    assert FakeUpstream.requests(upstream) == []
  end

  test "POST /v1/responses keeps opencode continuity headers local without forwarding", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_continuity_headers",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    session_id_header = "v1-session-id-#{System.unique_integer([:positive])}"
    x_session_id_header = "v1-x-session-id-#{System.unique_integer([:positive])}"
    affinity_header = "v1-session-affinity-#{System.unique_integer([:positive])}"

    first_conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-session-id", " ")
      |> put_req_header("session-id", session_id_header)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 session-id continuity"
      })

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-id", x_session_id_header)
      |> put_req_header("x-session-affinity", "v1-lower-priority-affinity")
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 x-session-id continuity"
      })

    third_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-id", " ")
      |> put_req_header("x-session-affinity", affinity_header)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 affinity continuity"
      })

    assert %{"id" => "resp_v1_continuity_headers", "object" => "response"} =
             json_response(first_conn, 200)

    assert %{"id" => "resp_v1_continuity_headers", "object" => "response"} =
             json_response(second_conn, 200)

    assert %{"id" => "resp_v1_continuity_headers", "object" => "response"} =
             json_response(third_conn, 200)

    assert %CodexSession{} =
             session_id_session = Repo.get_by(CodexSession, session_key: session_id_header)

    assert %CodexSession{} =
             x_session_id_session = Repo.get_by(CodexSession, session_key: x_session_id_header)

    assert %CodexSession{} =
             affinity_session = Repo.get_by(CodexSession, session_key: affinity_header)

    refute Repo.get_by(CodexSession, session_key: "v1-lower-priority-affinity")

    requests =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
        )
      )

    assert Enum.map(requests, & &1.endpoint) == [
             "/backend-api/codex/responses",
             "/backend-api/codex/responses",
             "/backend-api/codex/responses"
           ]

    assert Enum.map(requests, & &1.request_metadata["codex_session_id"]) == [
             session_id_session.id,
             x_session_id_session.id,
             affinity_session.id
           ]

    assert Enum.map(requests, & &1.request_metadata["codex_session_key"]) == [
             session_id_header,
             x_session_id_header,
             affinity_header
           ]

    assert [first_upstream_request, second_upstream_request, third_upstream_request] =
             FakeUpstream.requests(upstream)

    for captured <- [first_upstream_request, second_upstream_request, third_upstream_request] do
      assert captured.path == "/backend-api/codex/responses"
      assert_no_continuity_headers_forwarded!(captured)
    end
  end

  @tag :v1_post_session_start_race
  test "POST /v1/responses recovers concurrent first starts for the same session key" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_session_start_race",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = unboxed_run(fn -> gateway_setup(upstream) end)
    unboxed_run(fn -> precreate_daily_rollups!(setup) end)
    register_unboxed_pool_cleanup!(setup.pool)
    parent = self()
    barrier = make_ref()
    session_key = "v1-session-start-race-#{System.unique_integer([:positive])}"

    tasks =
      for label <- [:first, :second] do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Process.put({SessionContinuity, :before_session_insert_barrier}, {parent, barrier})

          conn =
            unboxed_run(fn ->
              build_conn()
              |> auth(setup)
              |> put_req_header("session-id", session_key)
              |> post("/v1/responses", %{
                "model" => setup.model.exposed_model_id,
                "input" => "synthetic v1 session-start race #{label}"
              })
            end)

          {label, conn.status, json_response(conn, conn.status)}
        end)
      end

    ready_pids =
      for _label <- [:first, :second] do
        assert_receive {:session_insert_ready, ^barrier, pid}, 5_000
        pid
      end

    assert Enum.uniq(ready_pids) == ready_pids

    Enum.each(ready_pids, fn pid -> send(pid, {:session_insert_release, barrier}) end)

    results = Task.await_many(tasks, 10_000)
    statuses = Enum.map(results, fn {_label, status, _body} -> status end)

    refute 500 in statuses
    assert Enum.all?(statuses, &(&1 in [200, 409]))
    assert Enum.any?(statuses, &(&1 == 200))

    for {_label, status, body} <- results do
      case status do
        200 ->
          assert %{"id" => "resp_v1_session_start_race", "object" => "response"} = body

        409 ->
          assert %{
                   "error" => %{
                     "type" => "invalid_request_error",
                     "code" => "session_start_conflict",
                     "message" => "Session start conflict",
                     "param" => "session_id"
                   }
                 } = body
      end
    end

    success_count = Enum.count(statuses, &(&1 == 200))

    assert [session] =
             unboxed_run(fn ->
               Repo.all(
                 from(session in CodexSession,
                   where:
                     session.pool_id == ^setup.pool.id and
                       fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
                       session.status in ["active", "interrupted"]
                 )
               )
             end)

    requests =
      unboxed_run(fn ->
        Repo.all(
          from(request in Request,
            where: request.pool_id == ^setup.pool.id,
            order_by: [asc: request.admitted_at]
          )
        )
      end)

    assert length(requests) == success_count
    assert Enum.all?(requests, &(&1.status == "succeeded"))
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_id"] == session.id))
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_key"] == session_key))

    attempts =
      unboxed_run(fn ->
        Repo.all(
          from(attempt in Attempt, where: attempt.request_id in ^Enum.map(requests, & &1.id))
        )
      end)

    assert length(attempts) == success_count
    assert Enum.all?(attempts, &(&1.status == "succeeded"))

    captured_requests = FakeUpstream.requests(upstream)
    assert length(captured_requests) == success_count

    for captured <- captured_requests do
      assert captured.path == "/backend-api/codex/responses"
      assert_no_continuity_headers_forwarded!(captured)
    end

    unboxed_run(fn ->
      Repo.delete_all(from(turn in CodexTurn, where: turn.codex_session_id == ^session.id))
    end)
  end

  defp precreate_daily_rollups!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    date = DateTime.to_date(now)

    [
      %{dimension_kind: "pool", pool_id: setup.pool.id},
      %{dimension_kind: "api_key", pool_id: setup.pool.id, api_key_id: setup.api_key.id},
      %{
        dimension_kind: "pool_upstream_assignment",
        pool_id: setup.pool.id,
        pool_upstream_assignment_id: setup.assignment.id
      },
      %{
        dimension_kind: "upstream_identity",
        pool_id: setup.pool.id,
        upstream_identity_id: setup.identity.id
      },
      %{dimension_kind: "model", pool_id: setup.pool.id, model_id: setup.model.id}
    ]
    |> Enum.each(fn attrs ->
      attrs
      |> Map.merge(%{
        rollup_date: date,
        request_count: 0,
        success_count: 0,
        failure_count: 0,
        retry_count: 0,
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        total_tokens: 0,
        estimated_cost_micros: Decimal.new(0),
        settled_cost_micros: Decimal.new(0),
        created_at: now,
        updated_at: now
      })
      |> then(&struct(DailyRollup, &1))
      |> Repo.insert!()
    end)
  end

  @tag :pinned_reauth
  test "POST /v1/responses fails closed for pinned reauth continuation anchors", %{
    conn: conn
  } do
    pinned_upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))

    fallback_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "should_not_fallback"}))

    {setup, _fallback} = pinned_reauth_gateway_setup(pinned_upstream, fallback_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    previous_response_id = "resp_v1_pinned_reauth_#{System.unique_integer([:positive])}"
    register_previous_response_anchor!(auth, setup.assignment, previous_response_id)

    anchored_cases = [
      {"body previous_response_id", [], %{"previous_response_id" => previous_response_id}},
      {"header previous response", [{"x-codex-previous-response-id", previous_response_id}], %{}}
    ]

    for {{label, headers, payload_updates}, index} <- Enum.with_index(anchored_cases) do
      payload =
        Map.merge(
          %{
            "model" => setup.model.exposed_model_id,
            "input" => visible_pinned_input()
          },
          payload_updates
        )

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> put_request_headers(headers)
        |> post("/v1/responses", payload)

      assert_pinned_reauth_recovery_body!(response)

      response_text = inspect(json_response(response, 503))
      assert_no_pinned_reauth_leakage!(response_text, setup, previous_response_id, label)

      assert FakeUpstream.count(pinned_upstream) == 0, label
      assert FakeUpstream.count(fallback_upstream) == 0, label
      assert Repo.aggregate(Attempt, :count) == 0, label

      denied_requests =
        Repo.all(
          from(r in Request,
            where: r.pool_id == ^setup.pool.id,
            order_by: [asc: r.admitted_at, asc: r.id]
          )
        )

      assert length(denied_requests) == index + 1, label
      denied_request = List.last(denied_requests)
      assert denied_request.status == "rejected", label
      assert denied_request.last_error_code == "pinned_continuation_reauth_required", label

      assert denied_request.request_metadata["continuity_denial"]["denial_family"] ==
               "pinned_continuation_reauth"

      assert denied_request.endpoint == "/backend-api/codex/responses", label

      denied_metadata_text =
        inspect({Enum.map(denied_requests, & &1.request_metadata), RequestLogs.list(setup.pool)})

      assert_no_pinned_reauth_leakage!(denied_metadata_text, setup, previous_response_id, label)
    end
  end

  @tag :v1_websocket
  @tag :pinned_reauth
  test "GET /v1/responses websocket fails closed for pinned reauth continuation anchors" do
    pinned_upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))

    fallback_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "should_not_fallback"}))

    {setup, _fallback} = pinned_reauth_gateway_setup(pinned_upstream, fallback_upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    previous_response_id = "resp_v1_ws_pinned_reauth_#{System.unique_integer([:positive])}"
    register_previous_response_anchor!(auth, setup.assignment, previous_response_id)

    port = start_public_endpoint!()
    turn_state = "v1-ws-pinned-reauth-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"},
        {"x-codex-previous-response-id", previous_response_id}
      ])

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => visible_pinned_input(),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert_pinned_reauth_recovery_frame!(frame)
      assert_no_pinned_reauth_leakage!(frame, setup, previous_response_id)

      assert FakeUpstream.count(pinned_upstream) == 0
      assert FakeUpstream.count(fallback_upstream) == 0
      assert Repo.aggregate(Attempt, :count) == 0

      assert [denied_request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert denied_request.endpoint == "/backend-api/codex/responses"
      assert denied_request.transport == "websocket"
      assert denied_request.status == "rejected"
      assert denied_request.response_status_code == 503
      assert denied_request.last_error_code == "pinned_continuation_reauth_required"

      assert denied_request.request_metadata["continuity_denial"]["denial_family"] ==
               "pinned_continuation_reauth"

      denied_metadata_text =
        inspect({denied_request.request_metadata, RequestLogs.list(setup.pool)})

      assert_no_pinned_reauth_leakage!(denied_metadata_text, setup, previous_response_id)

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :installation_id_metadata
  test "POST /v1/responses does not forward public metadata headers upstream", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_public_headers",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "public response"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> with_public_metadata_headers()
      |> put_req_header("x-codex-routing-hint", "model=forged")
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 response with public metadata headers"
      })

    assert %{"id" => "resp_v1_public_headers", "object" => "response"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured_headers, "x-codex-turn-metadata")
    refute Map.has_key?(captured_headers, "x-codex-window-id")
    refute Map.has_key?(captured_headers, "x-codex-parent-thread-id")
    refute Map.has_key?(captured_headers, "x-codex-installation-id")
    refute Map.has_key?(captured_headers, "x-openai-subagent")
    refute Map.has_key?(captured_headers, "x-codex-extra")
    refute Map.has_key?(captured_headers, "x-openai-extra")
    refute Map.has_key?(captured_headers, "x-codex-routing-hint")
    refute Map.has_key?(captured_headers, "cookie")
    refute Map.has_key?(captured_headers, "idempotency-key")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
  end

  @tag :invalid_request_error
  @tag :typed_input_contract
  test "POST /v1/responses rejects explicit unknown typed content before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    counts = durable_accounting_counts()

    invalid_items = [
      %{
        "type" => "future_input_item",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "synthetic known-looking content"}]
      },
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "future_content_part", "text" => "synthetic unknown part"}]
      }
    ]

    for stream? <- [false, true], item <- invalid_items do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [item],
          "stream" => stream?
        })

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "param" => "input"
               }
             } = json_response(response, 400)
    end

    assert FakeUpstream.requests(upstream) == []
    assert durable_accounting_counts() == counts
    assert %{items: [], total: 0} = RequestLogs.list(setup.pool)
  end

  @tag :invalid_request_error
  @tag :encrypted_function_args
  test "POST /v1/responses rejects malformed encrypted function-call replay args before dispatch",
       %{
         conn: conn
       } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    counts = durable_accounting_counts()

    for {stream?, invalid_args} <-
          [{false, "opaque"}, {true, %{}}, {false, ["a", 1]}, {true, [nil]}] do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call",
              "call_id" => "call_encrypted_args_validation",
              "name" => "lookup_fixture",
              "arguments" => "{}",
              "encrypted_function_args" => invalid_args
            }
          ],
          "stream" => stream?
        })

      assert %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "param" => "input"
               }
             } = json_response(response, 400)
    end

    assert FakeUpstream.requests(upstream) == []
    assert durable_accounting_counts() == counts
    assert %{items: [], total: 0} = RequestLogs.list(setup.pool)
  end

  @tag :encrypted_function_args
  test "POST /v1/responses forwards encrypted function-call replay args without durable metadata",
       %{
         conn: conn
       } do
    for encrypted_args <- [[], ["a", "bb"]] do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_encrypted_function_args",
            "object" => "response",
            "status" => "completed"
          })
        )

      setup = gateway_setup(upstream)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call",
              "call_id" => "call_encrypted_args_forward",
              "name" => "lookup_fixture",
              "arguments" => "{}",
              "encrypted_function_args" => encrypted_args
            }
          ]
        })

      assert %{"id" => "resp_encrypted_function_args"} = json_response(response, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert [forwarded] = captured.json["input"]
      assert Map.has_key?(forwarded, "encrypted_function_args")

      assert Enum.map(forwarded["encrypted_function_args"], &byte_size/1) ==
               Enum.map(encrypted_args, &byte_size/1)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

      metadata = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata =~ "encrypted_function_args"
    end
  end

  @tag :invalid_request_error
  test "POST /v1/responses preserves local validation errors before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    unsafe_value = "LOCAL_RESPONSES_VALIDATION_SENTINEL"

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic local validation response",
        "max_output_tokens" => unsafe_value
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_request"
    assert error["message"] == "max_output_tokens must be a positive integer"
    assert error["param"] == "max_output_tokens"
    refute conn.resp_body =~ unsafe_value
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :provider_invalid_request_redaction
  test "POST /v1/responses JSON redacts provider-origin invalid_request_error bodies", %{
    conn: conn
  } do
    cases = [
      {401, "invalid_api_key", "provider_key",
       "provider 401 leaked https://provider.internal.example/auth?key=sk-secret account acct_123"},
      {403, "insufficient_quota", "organization",
       "provider 403 leaked org org-secret and https://provider.internal.example/quota"},
      {400, "context_length_exceeded", "input",
       "provider 400 echoed prompt SENTINEL_PROMPT_CONTEXT and file file-secret.txt"}
    ]

    Enum.each(cases, fn {status, code, param, provider_message} ->
      response =
        PublicGatewayResult.send(
          recycle(conn),
          {:ok,
           %{
             status: status,
             raw_body:
               Jason.encode!(%{
                 "error" => provider_invalid_request_error(code, provider_message, param)
               })
           }},
          fn decoded -> decoded end
        )

      assert %{"error" => error} = json_response(response, status)
      assert error["message"] == "upstream request failed"
      assert error["type"] == "server_error"
      assert error["code"] == code
      refute Map.has_key?(error, "param")
      refute response.resp_body =~ provider_message
      refute response.resp_body =~ param
      refute response.resp_body =~ "provider.internal.example"
      refute response.resp_body =~ "sk-secret"
      refute response.resp_body =~ "acct_123"
      refute response.resp_body =~ "org-secret"
      refute response.resp_body =~ "SENTINEL_PROMPT_CONTEXT"
      refute response.resp_body =~ "file-secret.txt"
    end)
  end

  @tag :provider_invalid_request_redaction
  test "POST /v1/responses streaming redacts provider-origin invalid_request_error", %{conn: conn} do
    provider_message =
      "provider 400 leaked https://provider.internal.example/context?key=sk-secret and prompt SENTINEL_STREAM"

    upstream_error =
      provider_invalid_request_error("context_length_exceeded", provider_message, "input")

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_v1_stream_provider_invalid_request",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic provider invalid request stream",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(conn.resp_body)

    for error <- [data["error"], get_in(data, ["response", "error"])] do
      assert error["message"] == "upstream request failed"
      assert error["type"] == "server_error"
      assert error["code"] == "context_length_exceeded"
      refute Map.has_key?(error, "param")
    end

    refute conn.resp_body =~ provider_message
    refute conn.resp_body =~ "provider.internal.example"
    refute conn.resp_body =~ "sk-secret"
    refute conn.resp_body =~ "SENTINEL_STREAM"
    refute conn.resp_body =~ "\"param\""
    refute conn.resp_body =~ "event: response.created\n"
    refute conn.resp_body =~ "event: response.output_text.delta\n"
    assert FakeUpstream.count(upstream) == 1
  end

  @tag :provider_invalid_request_redaction
  test "POST /v1/responses collected SSE preserves safe terminal error codes", %{conn: conn} do
    provider_message =
      "provider 400 leaked https://provider.internal.example/context?key=sk-secret and prompt SENTINEL_COLLECT"

    upstream_error =
      provider_invalid_request_error("context_length_exceeded", provider_message, "input")

    cases = [
      {"top-level only",
       %{
         "type" => "response.failed",
         "error" => upstream_error,
         "response" => %{
           "id" => "resp_v1_collect_top_level_error",
           "status" => "failed"
         }
       }},
      {"nested",
       %{
         "type" => "response.failed",
         "response" => %{
           "id" => "resp_v1_collect_nested_error",
           "status" => "failed",
           "error" => upstream_error
         }
       }}
    ]

    Enum.each(cases, fn {_label, terminal_event} ->
      upstream = start_upstream(FakeUpstream.sse_stream([{"response.failed", terminal_event}]))
      setup = gateway_setup(upstream)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic collected provider invalid request"
        })

      assert %{"error" => error} = json_response(response, 502)
      assert error["message"] == "upstream request failed"
      assert error["type"] == "server_error"
      assert error["code"] == "context_length_exceeded"
      refute Map.has_key?(error, "param")
      refute response.resp_body =~ provider_message
      refute response.resp_body =~ "provider.internal.example"
      refute response.resp_body =~ "sk-secret"
      refute response.resp_body =~ "SENTINEL_COLLECT"
      refute response.resp_body =~ "input"
      assert FakeUpstream.count(upstream) == 1
    end)
  end

  @tag :server_error_redaction
  test "POST /v1/responses SSE collection redacts safe-looking terminal 502 errors" do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/rate?token=secret"

    upstream_error = safe_looking_upstream_error(provider_message)

    body =
      "event: response.failed\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.failed",
          "error" => upstream_error,
          "response" => %{
            "id" => "resp_v1_collect_safe_looking_server_failed",
            "status" => "failed",
            "error" => upstream_error
          }
        }) <>
        "\n\n"

    assert {:error, error} = Responses.response_from_sse(body)
    assert error.status == 502
    assert error.message == "upstream request failed"
    assert error.code == "rate_limit_exceeded"
    assert error.param == nil
    refute inspect(error) =~ "provider failed"
    refute inspect(error) =~ "upstream.internal.example"
    refute inspect(error) =~ "/internal/rate"
    refute inspect(error) =~ "provider_stack"
  end

  test "POST /v1/responses SSE collection accepts standalone-CR terminal framing" do
    terminal = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_v1_collect_standalone_cr",
        "status" => "completed",
        "output" => []
      }
    }

    body = "event: response.completed\rdata: " <> Jason.encode!(terminal) <> "\r\r"

    assert {:ok, response} = Responses.response_from_sse(body)
    assert response["id"] == "resp_v1_collect_standalone_cr"
    assert response["status"] == "completed"
    assert response["object"] == "response"
  end

  # The real Codex backend sends `"output": []` in every terminal
  # response.completed — wire-verified 2026-08-03 across six decrypted turns,
  # including ones where the model demonstrably called a tool. Tool calls travel
  # in the streamed response.output_item.done events, so SSE collection must
  # backfill from them. Asserting on the bare terminal array is asserting on a
  # field this provider never populates.
  @tag :issue_241
  test "POST /v1/responses SSE collection backfills tool calls from a real empty terminal" do
    call = %{
      "type" => "custom_tool_call",
      "name" => "issue241_probe",
      "call_id" => "call_issue241",
      "input" => "issue241"
    }

    body =
      "event: response.output_item.done\n" <>
        "data: " <>
        Jason.encode!(%{"type" => "response.output_item.done", "item" => call}) <>
        "\n\n" <>
        "event: response.completed\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_issue241_empty_terminal",
            "status" => "completed",
            "error" => nil,
            "output" => []
          }
        }) <> "\n\n"

    assert {:ok, response} = Responses.response_from_sse(body)
    assert [^call] = response["output"]
    assert response["status"] == "completed"
  end

  @tag :issue_241
  test "POST /v1/responses SSE collection prefers a populated terminal over streamed items" do
    streamed = %{"type" => "function_call", "name" => "streamed", "arguments" => "{}"}
    authoritative = %{"type" => "function_call", "name" => "terminal", "arguments" => "{}"}

    body =
      "event: response.output_item.done\n" <>
        "data: " <>
        Jason.encode!(%{"type" => "response.output_item.done", "item" => streamed}) <>
        "\n\n" <>
        "event: response.completed\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_issue241_populated_terminal",
            "status" => "completed",
            "output" => [authoritative]
          }
        }) <> "\n\n"

    assert {:ok, response} = Responses.response_from_sse(body)
    assert [^authoritative] = response["output"]
  end

  @tag :server_error_redaction
  test "POST /v1/responses SSE collection redacts top-level-only terminal errors" do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/context?token=secret"

    upstream_error =
      provider_invalid_request_error("context_length_exceeded", provider_message, "input")

    body =
      "event: response.failed\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.failed",
          "error" => upstream_error,
          "response" => %{
            "id" => "resp_v1_collect_top_level_only_failed",
            "status" => "failed"
          }
        }) <>
        "\n\n"

    assert {:error, error} = Responses.response_from_sse(body)
    assert error.status == 502
    assert error.message == "upstream request failed"
    assert error.code == "context_length_exceeded"
    assert error.param == nil
    refute inspect(error) =~ "provider failed"
    refute inspect(error) =~ "upstream.internal.example"
    refute inspect(error) =~ "/internal/context"
    refute inspect(error) =~ "input"
  end

  @tag :server_error_redaction
  test "POST /v1/responses SSE collection rejects failure-coded incomplete" do
    body =
      "event: response.incomplete\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.incomplete",
          "response" => %{
            "id" => "resp_v1_collect_failed_incomplete",
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "context_length_exceeded"}
          }
        }) <>
        "\n\n"

    assert {:error, error} = Responses.response_from_sse(body)
    assert error.status == 502
    assert error.message == "upstream request failed"
    assert error.code == "context_length_exceeded"
  end

  @tag :server_error_redaction
  test "POST /v1/responses JSON redacts server-class upstream errors", %{conn: conn} do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/responses?token=secret"

    upstream =
      start_upstream(
        FakeUpstream.http_500_json_error(%{
          "error" => %{
            "type" => "server_error",
            "code" => "server_error",
            "message" => provider_message,
            "param" => "provider_stack"
          }
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic rejected response"
      })

    assert %{"error" => error} = json_response(conn, 500)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] in ["server_error", "upstream_error"]
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/responses"
    refute conn.resp_body =~ "provider_stack"
    assert FakeUpstream.count(upstream) == 1
  end

  @tag :server_error_redaction
  test "POST /v1/responses JSON redacts 429 provider API errors", %{conn: conn} do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/rate?token=secret-sentinel-429"

    conn =
      PublicGatewayResult.send(
        conn,
        {:ok,
         %{
           status: 429,
           raw_body: Jason.encode!(%{"error" => safe_looking_upstream_error(provider_message)})
         }},
        fn decoded -> decoded end
      )

    assert %{"error" => error} = json_response(conn, 429)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] in ["rate_limit_exceeded", "upstream_error"]
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/rate"
    refute conn.resp_body =~ "secret-sentinel-429"
    refute conn.resp_body =~ "provider_stack"
  end

  @tag :server_error_redaction
  test "POST /v1/responses gateway 500 errors redact safe-looking provider messages", %{
    conn: conn
  } do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/gateway?token=secret"

    conn =
      PublicGatewayResult.send(
        conn,
        {:error,
         %{
           status: 500,
           code: "rate_limit_exceeded",
           message: provider_message,
           param: "provider_stack"
         }},
        fn decoded -> decoded end
      )

    assert %{"error" => error} = json_response(conn, 500)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "rate_limit_exceeded"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/gateway"
    refute conn.resp_body =~ "provider_stack"
  end

  @tag :server_error_redaction
  test "POST /v1/responses streaming redacts terminal server-class upstream errors", %{
    conn: conn
  } do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/stream?token=secret"

    upstream_error = %{
      "type" => "internal_error",
      "code" => "internal_error",
      "message" => provider_message,
      "param" => "provider_stack"
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_v1_stream_server_failed",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic stream failure request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(conn.resp_body)
    assert get_in(data, ["error", "message"]) == "upstream request failed"
    assert get_in(data, ["error", "type"]) == "server_error"
    assert get_in(data, ["error", "code"]) == "internal_error"
    refute Map.has_key?(data["error"], "param")
    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/stream"
    refute conn.resp_body =~ "provider_stack"
    refute conn.resp_body =~ "event: response.created\n"
    refute conn.resp_body =~ "event: response.output_text.delta\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "internal_error"
  end

  @tag :server_error_redaction
  test "POST /v1/responses streaming redacts safe-looking terminal 502 errors", %{
    conn: conn
  } do
    provider_message =
      "provider failed at https://upstream.internal.example/internal/stream?token=secret"

    upstream_error = safe_looking_upstream_error(provider_message)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => upstream_error,
             "response" => %{
               "id" => "resp_v1_stream_safe_looking_server_failed",
               "status" => "failed",
               "error" => upstream_error
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic safe-looking stream failure request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(conn.resp_body)

    for error <- [data["error"], get_in(data, ["response", "error"])] do
      assert error["message"] == "upstream request failed"
      assert error["type"] == "server_error"
      assert error["code"] == "rate_limit_exceeded"
      refute Map.has_key?(error, "param")
    end

    refute conn.resp_body =~ "provider failed"
    refute conn.resp_body =~ "upstream.internal.example"
    refute conn.resp_body =~ "/internal/stream"
    refute conn.resp_body =~ "provider_stack"
    refute conn.resp_body =~ "event: response.created\n"
    refute conn.resp_body =~ "event: response.output_text.delta\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "rate_limit_exceeded"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming emits early response.failed as the first event", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic streaming validation"
             },
             "response" => %{
               "id" => "resp_v1_stream_failed",
               "status" => "failed",
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request_error",
                 "message" => "synthetic streaming validation"
               }
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic stream failure request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(conn.resp_body)
    assert get_in(data, ["error", "code"]) == "invalid_request_error"
    refute conn.resp_body =~ "event: response.created\n"
    refute conn.resp_body =~ "event: response.output_text.delta\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "invalid_request_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
  end

  @tag :streaming_sequence
  test "POST /v1/responses treats whitespace event labels as absent and drops late frames", %{
    conn: conn
  } do
    failed =
      %{
        "type" => "response.failed",
        "prompt" => "private-responses-blank-label-sentinel",
        "response" => %{
          "id" => "resp_v1_blank_label",
          "status" => "failed",
          "hostile" => "private-response-sibling",
          "error" => %{
            "code" => "context_length_exceeded",
            "message" => "private provider detail"
          }
        }
      }

    raw_failed = "event: \t \ndata: " <> Jason.encode!(failed) <> "\n\n"

    late_completed =
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{"id" => "resp_v1_late_completed", "status" => "completed"}
       }}

    upstream =
      start_upstream(FakeUpstream.sse_stream([raw_failed, late_completed], done: false))

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic blank-label Responses request",
        "stream" => true
      })

    assert conn.status == 200
    assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(conn.resp_body)
    assert data["sequence_number"] == 0
    assert data["response"]["status"] == "failed"
    assert data["response"]["error"]["code"] == "context_length_exceeded"
    assert data["response"]["error"]["message"] == "upstream request failed"
    refute conn.resp_body =~ "private-responses-blank-label-sentinel"
    refute conn.resp_body =~ "private-response-sibling"
    refute conn.resp_body =~ "private provider detail"
    refute conn.resp_body =~ "resp_v1_late_completed"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "context_length_exceeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "context_length_exceeded"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming emits early top-level error as the first event", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"error",
           %{
             "type" => "error",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic streaming validation error"
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic stream error request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert [%{"event" => "error", "data" => data}] = public_sse_events(conn.resp_body)
    assert get_in(data, ["error", "code"]) == "invalid_request_error"
    refute conn.resp_body =~ "event: response.created\n"
    refute conn.resp_body =~ "event: response.output_text.delta\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "invalid_request_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming preserves late response.failed after output", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "partial public text"}},
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic late streaming validation"
             },
             "response" => %{
               "id" => "resp_v1_stream_late_failed",
               "status" => "failed",
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request_error",
                 "message" => "synthetic late streaming validation"
               }
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic late stream failure request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200

    events = public_sse_events(conn.resp_body)

    assert Enum.map(events, & &1["event"]) == [
             "response.output_text.delta",
             "response.created",
             "response.failed"
           ]

    assert get_in(List.last(events), ["data", "error", "code"]) == "invalid_request_error"
    assert conn.resp_body =~ "partial public text"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "invalid_request_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming emits one hybrid error after visible output when upstream closes without a terminal",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{
               "type" => "response.output_text.delta",
               "delta" => "visible-before-upstream-close",
               "response" => %{"id" => "resp_visible_before_close"}
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic interrupted stream request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200

    body = conn.resp_body
    assert body =~ "visible-before-upstream-close"
    refute body =~ "event: response.completed\n"
    refute body =~ "event: response.incomplete\n"
    assert body =~ "upstream request failed: stream interrupted before terminal response event"
    refute body =~ "upstream stream interrupted before terminal response event"

    assert [
             %{
               "event" => "response.output_text.delta",
               "data" => %{"delta" => "visible-before-upstream-close"}
             },
             %{"event" => "error", "data" => data}
           ] = public_sse_events(body)

    assert MapSet.new(Map.keys(data)) ==
             MapSet.new(["code", "error", "message", "param", "sequence_number", "type"])

    assert %{
             "code" => "server_error",
             "error" => nested_error,
             "message" =>
               "upstream request failed: stream interrupted before terminal response event",
             "param" => nil,
             "sequence_number" => sequence_number,
             "type" => "error"
           } = data

    assert is_integer(sequence_number)
    assert sequence_number >= 0
    refute Map.has_key?(data, "response")

    assert MapSet.new(Map.keys(nested_error)) == MapSet.new(["code", "message", "param", "type"])

    assert nested_error == %{
             "code" => "server_error",
             "message" =>
               "upstream request failed: stream interrupted before terminal response event",
             "param" => nil,
             "type" => "server_error"
           }

    refute Enum.any?(public_sse_events(body), &(&1["event"] == "response.failed"))

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/responses"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"
    assert attempt.response_metadata["error_kind"] == "stream_interrupted"

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})
    refute persistence_text =~ "synthetic interrupted stream request"
    refute persistence_text =~ "visible-before-upstream-close"
  end

  @tag :owner_drained_terminal_state
  test "POST /v1/responses streaming emits owner_drained only for a post-budget bridge drain",
       %{conn: conn} do
    enable_websocket_owner_forwarding!()
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.delayed_terminal_sse_stream(
          [
            {"response.created",
             %{
               "type" => "response.created",
               "response" => %{"id" => "resp_controller_owner_drained", "status" => "in_progress"}
             }},
            {"response.output_text.delta",
             %{
               "type" => "response.output_text.delta",
               "response_id" => "resp_controller_owner_drained",
               "output_index" => 0,
               "content_index" => 0,
               "delta" => "visible before controller drain"
             }}
          ],
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{"id" => "resp_controller_owner_drained", "status" => "completed"}
           }},
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header(
          "x-session-id",
          "controller-owner-drained-#{System.unique_integer([:positive])}"
        )
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic controller owner drain",
          "stream" => true
        })
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   1_000

    assert %CodexTurn{first_visible_output_at: %DateTime{}} =
             turn = await_committed_public_turn(setup.pool.id)

    harness = start_rollout_drain_harness()

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, deadline, 10}
    assert deadline == harness.deadline
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)

    response = Task.await(request_task, 2_000)
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 2_000)

    assert response.status == 200
    assert response.resp_body =~ "visible before controller drain"

    assert [%{"event" => "error", "data" => data}] =
             response.resp_body
             |> public_sse_events()
             |> Enum.filter(&(&1["event"] == "error"))

    assert Map.keys(data) |> Enum.sort() ==
             ~w(code error message param sequence_number type)

    assert Map.keys(data["error"]) |> Enum.sort() == ~w(code message param type)

    assert %{
             "code" => "server_error",
             "error" => nested_error,
             "message" => message,
             "param" => nil,
             "sequence_number" => sequence_number,
             "type" => "error"
           } = data

    assert is_integer(sequence_number)

    assert nested_error == %{
             "code" => "server_error",
             "message" => message,
             "param" => nil,
             "type" => "server_error"
           }

    assert message ==
             "upstream request failed: stream interrupted before terminal response event"

    refute Map.has_key?(data, "response")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 499
    assert request.last_error_code == "owner_drained"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.network_error_code == "owner_drained"

    assert %CodexTurn{
             status: "interrupted",
             error_code: "owner_drained",
             first_visible_output_at: %DateTime{}
           } = Repo.reload!(turn)

    assert FakeUpstream.http_request_count(upstream) == 0
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming keeps non-timeout terminal-missing interruptions health-neutral after visible data",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.abrupt_close_mid_stream([
          {"response.output_text.delta",
           %{
             "type" => "response.output_text.delta",
             "delta" => "visible-before-abrupt-close",
             "response" => %{"id" => "resp_visible_before_abrupt_close"}
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic abrupt stream interruption request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "visible-before-abrupt-close"

    assert [%{"event" => "response.output_text.delta"}, %{"event" => "error", "data" => data}] =
             public_sse_events(conn.resp_body)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(code error message param sequence_number type)

    assert Map.keys(data["error"]) |> Enum.sort() == ~w(code message param type)

    assert %{
             "code" => "server_error",
             "error" => %{
               "code" => "server_error",
               "message" => message,
               "param" => nil,
               "type" => "server_error"
             },
             "message" => message,
             "param" => nil,
             "sequence_number" => sequence_number,
             "type" => "error"
           } = data

    assert is_integer(sequence_number)
    refute Map.has_key?(data, "response")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"

    assert %{
             "reason_class" => "upstream_stream_interrupted",
             "reason" => "closed_before_terminal",
             "phase" => "upstream_close",
             "terminal_seen" => false,
             "pre_visible_output" => false,
             "text_frame_count" => text_frame_count,
             "exception" => "Finch.TransportError"
           } = attempt.response_metadata["transport_failure"]

    assert text_frame_count >= 1
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})
    refute persistence_text =~ "synthetic abrupt stream interruption request"
    refute persistence_text =~ "visible-before-abrupt-close"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming accepts terminal response buffer without trailing separator",
       %{conn: conn} do
    terminal =
      [
        "event: response.completed\n",
        "data: ",
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_v1_terminal_without_separator",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [
                  %{"type" => "output_text", "text" => "terminal text without separator"}
                ]
              }
            ],
            "usage" => %{
              "input_tokens" => 7,
              "output_tokens" => 5,
              "total_tokens" => 12
            }
          }
        })
      ]
      |> IO.iodata_to_binary()

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{
               "type" => "response.output_text.delta",
               "delta" => "visible-before-terminal-buffer",
               "response" => %{"id" => "resp_v1_terminal_without_separator"}
             }},
            terminal
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic terminal-buffer stream request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200

    events = public_sse_events(conn.resp_body)
    event_names = Enum.map(events, & &1["event"])

    assert "response.completed" in event_names
    refute "response.failed" in event_names
    assert conn.resp_body =~ "visible-before-terminal-buffer"
    assert conn.resp_body =~ "terminal text without separator"
    refute conn.resp_body =~ "upstream_stream_error"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert is_nil(request.last_error_code)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
    assert is_nil(attempt.network_error_code)

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})
    refute persistence_text =~ "synthetic terminal-buffer stream request"
    refute persistence_text =~ "visible-before-terminal-buffer"
    refute persistence_text =~ "terminal text without separator"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming accepts a large recognizable terminal across chunks",
       %{conn: conn} do
    terminal_padding = String.duplicate("oversized terminal output ", 4_000)

    terminal =
      [
        "event: response.completed\n",
        "data: ",
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_v1_large_terminal_without_separator",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => terminal_padding}]
              }
            ],
            "usage" => %{
              "input_tokens" => 85_826,
              "output_tokens" => 699,
              "total_tokens" => 86_525
            },
            "service_tier" => "standard"
          }
        })
      ]
      |> IO.iodata_to_binary()

    assert byte_size(terminal) > RetainedBody.max_bytes()
    split_at = RetainedBody.max_bytes() + 1
    first = binary_part(terminal, 0, split_at)
    second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [first, second],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic oversized terminal-buffer stream request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200

    events = public_sse_events(conn.resp_body)
    event_names = Enum.map(events, & &1["event"])

    assert event_names == [
             "response.created",
             "response.output_text.delta",
             "response.completed"
           ]

    assert %{"data" => completed} = List.last(events)
    assert completed["type"] == "response.completed"
    assert completed["response"]["id"] == "resp_v1_large_terminal_without_separator"
    assert completed["response"]["status"] == "completed"

    assert [%{"content" => [%{"text" => ^terminal_padding}]}] =
             completed["response"]["output"]

    refute "response.failed" in event_names
    refute "error" in event_names
    refute conn.resp_body =~ "upstream_stream_error"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert is_nil(request.last_error_code)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
    assert is_nil(attempt.network_error_code)

    assert %{
             "mode" => "normalized",
             "finish_class" => "completed",
             "synthetic_terminal_sent" => false,
             "terminal_kind" => "completed",
             "terminal_seen" => true,
             "terminal_status" => "completed"
           } = attempt.response_metadata["public_openai_responses_stream"]

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})
    refute persistence_text =~ "synthetic oversized terminal-buffer stream request"
    refute persistence_text =~ "resp_v1_large_terminal_without_separator"
    refute persistence_text =~ terminal_padding
  end

  @tag :streaming_sequence
  test "POST /v1/responses settles a buffered separator-less terminal for an already-closed client" do
    terminal =
      [
        "event: response.completed\n",
        "data: ",
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_v1_flushed_terminal_closed_client",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "buffered terminal text"}]
              }
            ],
            "usage" => %{"input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12}
          }
        })
      ]
      |> IO.iodata_to_binary()

    split_at = div(byte_size(terminal), 2)
    first = binary_part(terminal, 0, split_at)
    second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

    upstream = start_upstream(FakeUpstream.sse_stream([first, second], done: false))
    setup = gateway_setup(upstream)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "synthetic closed-client flushed terminal request"
            }
          ]
        }
      ],
      "stream" => true
    }

    assert {:ok, %{stream: stream}} =
             CodexPooler.Gateway.execute(
               auth,
               "/v1/responses",
               payload,
               RequestOptions.build(
                 %{
                   upstream_endpoint: "/backend-api/codex/responses",
                   public_openai_responses_stream: true
                 },
                 "/v1/responses",
                 payload
               )
             )

    closed_conn = %{
      Phoenix.ConnTest.build_conn()
      | adapter: {ClosedChunkAdapter, nil},
        state: :chunked
    }

    assert {:ok, _conn} = stream.(closed_conn)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert is_nil(request.last_error_code)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
    assert is_nil(attempt.network_error_code)

    assert %{
             "finish_class" => "completed",
             "terminal_seen" => true,
             "terminal_kind" => "completed",
             "synthetic_terminal_sent" => false
           } = attempt.response_metadata["public_openai_responses_stream"]
  end

  @tag :streaming_sequence
  test "classifies a buffered separator-less failed terminal for an already-closed client" do
    terminal =
      [
        "event: response.failed\n",
        "data: ",
        Jason.encode!(%{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_v1_flushed_failed_terminal_closed_client",
            "status" => "failed",
            "error" => %{
              "code" => "context_length_exceeded",
              "message" => "private provider detail"
            }
          }
        })
      ]
      |> IO.iodata_to_binary()

    split_at = div(byte_size(terminal), 2)
    first = binary_part(terminal, 0, split_at)
    second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

    upstream = start_upstream(FakeUpstream.sse_stream([first, second], done: false))
    setup = gateway_setup(upstream)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "synthetic closed-client flushed failed terminal request"
            }
          ]
        }
      ],
      "stream" => true
    }

    assert {:ok, %{stream: stream}} =
             CodexPooler.Gateway.execute(
               auth,
               "/v1/responses",
               payload,
               RequestOptions.build(
                 %{
                   upstream_endpoint: "/backend-api/codex/responses",
                   public_openai_responses_stream: true
                 },
                 "/v1/responses",
                 payload
               )
             )

    closed_conn = %{
      Phoenix.ConnTest.build_conn()
      | adapter: {ClosedChunkAdapter, nil},
        state: :chunked
    }

    stream.(closed_conn)

    # A separator-less failed terminal classifies through the first-event
    # summary, whose coarse event-type code is the inherited accounting for
    # this shape (the with-separator path extracts the nested error code).
    # The contract under test: the upstream terminal failure wins over
    # client_disconnected and no synthetic terminal is fabricated.
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "response.failed"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "response.failed"

    # The relayed-stream summary stays pre-visible on this route (the failed
    # write drops the advanced relay state), so the load-bearing check is that
    # no synthetic terminal was fabricated for the dead client.
    summary = attempt.response_metadata["public_openai_responses_stream"]
    assert summary["synthetic_terminal_sent"] == false
    assert summary["visible_seen"] == false
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming buffers and sanitizes a large failure-coded incomplete terminal across chunks",
       %{conn: conn} do
    terminal_padding = String.duplicate("oversized failed incomplete output ", 4_000)

    terminal =
      [
        "event: response.incomplete\n",
        "data: ",
        Jason.encode!(%{
          "type" => "response.incomplete",
          "response" => %{
            "id" => "resp_v1_large_failed_incomplete_without_separator",
            "status" => "incomplete",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => terminal_padding}]
              }
            ],
            "incomplete_details" => %{"reason" => "context_length_exceeded"}
          }
        })
      ]
      |> IO.iodata_to_binary()

    assert byte_size(terminal) > RetainedBody.max_bytes()
    split_at = RetainedBody.max_bytes() + 1
    first = binary_part(terminal, 0, split_at)
    second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [first, second],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic oversized failed incomplete stream request",
        "stream" => true
      })

    assert conn.status == 200

    assert [%{"event" => "response.failed", "data" => data}] =
             public_sse_events(conn.resp_body)

    assert data["type"] == "response.failed"
    assert data["sequence_number"] == 0
    assert data["response"]["id"] == "resp_v1_large_failed_incomplete_without_separator"
    assert data["response"]["status"] == "failed"

    assert data["error"] == %{
             "code" => "context_length_exceeded",
             "message" => "upstream request failed",
             "type" => "server_error"
           }

    assert data["response"]["error"] == data["error"]
    assert is_nil(data["response"]["incomplete_details"])
    assert data["response"]["output"] == []
    assert is_nil(data["response"]["usage"])

    refute conn.resp_body =~ "event: response.incomplete"
    refute conn.resp_body =~ ~s("type":"error")
    refute conn.resp_body =~ "upstream_stream_error"
    refute conn.resp_body =~ terminal_padding

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.usage_status == "usage_unknown"
    assert request.last_error_code == "context_length_exceeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.usage_status == "usage_unknown"
    assert attempt.network_error_code == "context_length_exceeded"

    assert %{
             "mode" => "normalized",
             "finish_class" => "failed",
             "synthetic_terminal_sent" => false,
             "terminal_kind" => "failed",
             "terminal_seen" => true,
             "terminal_status" => "failed"
           } = attempt.response_metadata["public_openai_responses_stream"]

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.status == "failed"
    assert log.usage_status == "usage_unknown"
    assert log.denial_reason == "context_length_exceeded"
    assert log.token_counts.usage_status == "usage_unknown"
    assert log.cost.status == "unpriced"
    assert is_nil(log.cost.usd)

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})
    refute persistence_text =~ "synthetic oversized failed incomplete stream request"
    refute persistence_text =~ "resp_v1_large_failed_incomplete_without_separator"
    refute persistence_text =~ terminal_padding
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming preserves ordinary response.incomplete", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.incomplete",
           %{
             "type" => "response.incomplete",
             "response" => %{
               "id" => "resp_v1_stream_incomplete",
               "status" => "incomplete",
               "incomplete_details" => %{"reason" => "max_output_tokens"},
               "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic incomplete stream request",
        "stream" => true
      })

    assert conn.status == 200

    assert [%{"event" => "response.incomplete", "data" => data}] =
             public_sse_events(conn.resp_body)

    assert data["type"] == "response.incomplete"
    assert data["response"]["status"] == "incomplete"
    assert get_in(data, ["response", "incomplete_details", "reason"]) == "max_output_tokens"
    refute conn.resp_body =~ "response.failed"
    refute conn.resp_body =~ "\"error\""

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert is_nil(request.last_error_code)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
    assert is_nil(attempt.network_error_code)

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.status == "succeeded"
    assert log.usage_status == "usage_known"
    assert log.denial_reason == nil
    assert log.token_counts.usage_status == "usage_known"
    assert log.token_counts.input_tokens == 4
    assert is_nil(log.token_counts.output_tokens)
    assert log.token_counts.total_tokens == 4
    assert log.cost.status == "priced"
    assert Decimal.positive?(log.cost.usd)
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming rewrites failure-coded response.incomplete", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.incomplete",
           %{
             "type" => "response.incomplete",
             "response" => %{
               "id" => "resp_v1_stream_failed_incomplete",
               "status" => "incomplete",
               "incomplete_details" => %{"reason" => "context_length_exceeded"}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic failed incomplete stream request",
        "stream" => true
      })

    assert conn.status == 200
    assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(conn.resp_body)
    assert data["type"] == "response.failed"
    assert data["response"]["status"] == "failed"
    assert data["error"]["code"] == "context_length_exceeded"
    refute conn.resp_body =~ "event: response.incomplete\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.usage_status == "usage_unknown"
    assert request.last_error_code == "context_length_exceeded"

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.status == "failed"
    assert log.usage_status == "usage_unknown"
    assert log.denial_reason == "context_length_exceeded"
    assert log.token_counts.usage_status == "usage_unknown"
    assert log.cost.status == "unpriced"
    assert is_nil(log.cost.usd)
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming emits public Responses SSE and filters codex events", %{
    conn: conn
  } do
    input_tokens_details = %{"cached_tokens" => 31, "fixture_stream_tokens" => 37}
    output_tokens_details = %{"reasoning_tokens" => 41, "rejected_prediction_tokens" => 43}

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"codex.rate_limits", %{"type" => "codex.rate_limits", "limits" => []}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible text"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream",
               "status" => "completed",
               "service_tier" => "fast",
               "usage" => %{
                 "input_tokens" => 53,
                 "input_tokens_details" => input_tokens_details,
                 "output_tokens" => 59,
                 "output_tokens_details" => output_tokens_details,
                 "total_tokens" => 112
               }
             }
           }}
        ])
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{"service_tiers" => [%{"id" => "priority"}]}
        }
      )

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic stream request",
        "stream" => true,
        "service_tier" => "fast"
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "event: response.created\n"
    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ "visible text"
    assert conn.resp_body =~ "event: response.completed\n"
    refute conn.resp_body =~ "codex.rate_limits"
    refute conn.resp_body =~ "event: codex."

    events = public_sse_events(conn.resp_body)

    assert List.last(events)["event"] == "response.completed"

    assert %{
             "event" => "response.completed",
             "data" => %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_v1_stream",
                 "service_tier" => "fast",
                 "usage" => usage
               }
             }
           } = Enum.find(events, &(&1["event"] == "response.completed"))

    assert usage["input_tokens"] == 53
    assert usage["input_tokens_details"] == input_tokens_details
    assert usage["output_tokens"] == 59
    assert usage["output_tokens_details"] == output_tokens_details
    assert usage["total_tokens"] == 112

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["service_tier"] == "priority"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    settlement =
      Repo.get_by!(LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.input_tokens == 53
    assert settlement.cached_input_tokens == 31
    assert settlement.output_tokens == 59
    assert settlement.reasoning_tokens == 41
    assert settlement.total_tokens == 112
    refute Map.has_key?(settlement.details, "input_tokens_details")
    refute Map.has_key?(settlement.details, "output_tokens_details")

    assert %{items: [log], total: 1} =
             RequestLogs.list(setup.pool, filters: %{request_id: request.id})

    assert log.token_counts.input_tokens == 53
    assert log.token_counts.cached_input_tokens == 31
    assert log.token_counts.output_tokens == 59
    assert log.token_counts.reasoning_tokens == 41
    assert log.token_counts.total_tokens == 112
    refute Map.has_key?(log.token_counts, :input_tokens_details)
    refute Map.has_key?(log.token_counts, :output_tokens_details)
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming passes moderation metadata without storing prompts", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.moderation.started",
           %{
             "type" => "response.moderation.started",
             "model" => "omni-moderation-latest",
             "check_id" => "mod_check_stream_fixture"
           }},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible moderated text"}},
          {"response.moderation.completed",
           %{
             "type" => "response.moderation.completed",
             "model" => "omni-moderation-latest",
             "check_id" => "mod_check_stream_fixture",
             "status" => "completed"
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream_moderation_metadata",
               "status" => "completed",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic moderation stream request",
        "moderation" => %{"model" => "omni-moderation-latest"},
        "stream" => true
      })

    events = public_sse_events(conn.resp_body)

    assert %{
             "event" => "response.moderation.started",
             "data" => %{
               "type" => "response.moderation.started",
               "model" => "omni-moderation-latest",
               "check_id" => "mod_check_stream_fixture"
             }
           } = Enum.find(events, &(&1["event"] == "response.moderation.started"))

    assert %{
             "event" => "response.moderation.completed",
             "data" => %{
               "type" => "response.moderation.completed",
               "model" => "omni-moderation-latest",
               "check_id" => "mod_check_stream_fixture",
               "status" => "completed"
             }
           } = Enum.find(events, &(&1["event"] == "response.moderation.completed"))

    assert conn.resp_body =~ "visible moderated text"
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["moderation"] == %{"model" => "omni-moderation-latest"}

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"

    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic moderation stream request"
    refute metadata =~ "visible moderated text"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming passes response metadata moderation without storing it", %{
    conn: conn
  } do
    moderation_metadata = %{
      "openai_chatgpt_moderation_metadata" => %{
        "check_id" => "mod_check_metadata_fixture",
        "private_probe" => "metadata moderation sentinel must not persist"
      }
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{
               "id" => "resp_v1_stream_response_metadata_moderation",
               "status" => "in_progress",
               "metadata" => moderation_metadata
             }
           }},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible metadata text"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream_response_metadata_moderation",
               "status" => "completed",
               "metadata" => moderation_metadata,
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic response metadata moderation stream request",
        "stream" => true
      })

    events = public_sse_events(conn.resp_body)

    assert %{
             "event" => "response.created",
             "data" => %{
               "response" => %{
                 "metadata" => ^moderation_metadata
               }
             }
           } = Enum.find(events, &(&1["event"] == "response.created"))

    assert %{
             "event" => "response.completed",
             "data" => %{
               "response" => %{
                 "metadata" => ^moderation_metadata
               }
             }
           } = Enum.find(events, &(&1["event"] == "response.completed"))

    assert conn.resp_body =~ "visible metadata text"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    persistence_text =
      inspect({request.request_metadata, attempt.response_metadata, RequestLogs.list(setup.pool)})

    refute persistence_text =~ "synthetic response metadata moderation stream request"
    refute persistence_text =~ "visible metadata text"
    refute persistence_text =~ "metadata moderation sentinel must not persist"
    refute persistence_text =~ "openai_chatgpt_moderation_metadata"
    refute persistence_text =~ "mod_check_metadata_fixture"
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming marks visible upstream output once", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "first"}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "second"}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "third"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream_visible_once",
               "status" => "completed",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    {conn, queries} =
      capture_repo_queries(fn ->
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic streaming visible marker request",
          "stream" => true
        })
      end)

    assert conn.status == 200
    assert conn.resp_body =~ "resp_v1_stream_visible_once"
    assert visible_codex_turn_update_count(queries) == 1
  end

  @tag :streaming_timing
  test "POST /v1/responses streaming sends HTTP headers before delayed upstream body" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_v1_ttfh_stream",
                 "status" => "completed",
                 "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
               }
             }}
          ],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {:ok, http_conn, ref, started} =
      start_public_v1_responses_request(port, setup, %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic timing stream request",
        "stream" => true
      })

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref},
                   @timing_observation_timeout_ms

    try do
      {http_conn, status, response_headers, elapsed_ms, chunks, done?} =
        await_public_response_headers!(
          http_conn,
          ref,
          started,
          @timing_observation_timeout_ms
        )

      assert status == 200
      assert elapsed_ms < @ttfh_threshold_ms
      assert elapsed_ms < @timing_observation_timeout_ms
      assert header_value(response_headers, "content-type") =~ "text/event-stream"
      assert header_value(response_headers, "cache-control") == "no-cache"

      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

      body =
        await_public_response_done!(http_conn, ref, chunks, done?, @timing_observation_timeout_ms)

      assert body =~ "event: response.created\n"
      assert body =~ "event: response.completed\n"
    after
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :streaming_timing
  test "POST /v1/responses streaming upstream header timeout fails within client header budget" do
    release_ref = make_ref()
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 200})

    upstream =
      start_upstream(
        FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    logs =
      capture_log([level: :warning], fn ->
        {:ok, http_conn, ref, started} =
          start_public_v1_responses_request(port, setup, %{
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic timeout stream request",
            "stream" => true
          })

        assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                        ^release_ref},
                       @timing_observation_timeout_ms

        try do
          {http_conn, status, _response_headers, header_elapsed_ms, chunks, done?} =
            await_public_response_headers!(
              http_conn,
              ref,
              started,
              @failure_observation_timeout_ms
            )

          body =
            await_public_response_done!(
              http_conn,
              ref,
              chunks,
              done?,
              @failure_observation_timeout_ms
            )

          total_elapsed_ms = elapsed_ms(started)

          assert status == 502
          assert header_elapsed_ms < @ttfh_threshold_ms
          assert total_elapsed_ms < @ttfh_threshold_ms
          assert %{"error" => %{"code" => "upstream_request_failed"}} = Jason.decode!(body)
        after
          send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
          Mint.HTTP.close(http_conn)
        end
      end)

    warnings =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "gateway upstream transport failed"))

    assert [warning] = warnings
    assert warning =~ "transport=http_sse"
    assert warning =~ "endpoint=/backend-api/codex/responses"
    assert warning =~ "exception=Req.TransportError"
    assert warning =~ "reason=timeout"
    refute logs =~ "synthetic timeout stream request"
    refute logs =~ setup.authorization
    refute logs =~ setup.raw_key
  end

  @tag :streaming_timing
  test "POST /v1/responses streaming stays alive while upstream sends steady progress" do
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 250})

    upstream =
      start_upstream(
        FakeUpstream.delayed_sse_stream(
          long_turn_progress_events("resp_v1_long_turn_progress"),
          interval_ms: 100,
          notify: self()
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {:ok, http_conn, ref, started} =
      start_public_v1_responses_request(port, setup, %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic long progress stream request",
        "stream" => true
      })

    try do
      {http_conn, status, response_headers, header_elapsed_ms, chunks, done?} =
        await_public_response_headers!(
          http_conn,
          ref,
          started,
          @timing_observation_timeout_ms
        )

      assert status == 200
      assert header_elapsed_ms < @ttfh_threshold_ms
      assert header_value(response_headers, "content-type") =~ "text/event-stream"

      body =
        await_public_response_done!(
          http_conn,
          ref,
          chunks,
          done?,
          @failure_observation_timeout_ms
        )

      total_elapsed_ms = elapsed_ms(started)

      assert total_elapsed_ms >= 600
      assert body =~ "event: response.output_text.delta\n"
      assert body =~ "progress-6"
      assert body =~ "event: response.completed\n"
      refute body =~ "stream_idle_timeout"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.transport == "http_sse"
      assert request.status == "succeeded"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"
    after
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :streaming_timing
  test "POST /v1/responses streaming reports idle timeout after visible output" do
    release_ref = make_ref()
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 150})

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"visible-before-idle"}\n\n),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {:ok, http_conn, ref, started} =
      start_public_v1_responses_request(port, setup, %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic idle timeout stream request",
        "stream" => true
      })

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref},
                   @timing_observation_timeout_ms

    try do
      {http_conn, status, response_headers, header_elapsed_ms, chunks, done?} =
        await_public_response_headers!(
          http_conn,
          ref,
          started,
          @timing_observation_timeout_ms
        )

      assert status == 200
      assert header_elapsed_ms < @ttfh_threshold_ms
      assert header_value(response_headers, "content-type") =~ "text/event-stream"

      body =
        await_public_response_done!(
          http_conn,
          ref,
          chunks,
          done?,
          @failure_observation_timeout_ms
        )

      total_elapsed_ms = elapsed_ms(started)
      silent_gap_elapsed_ms = await_silent_gap!(started, 250)

      assert total_elapsed_ms >= 150
      assert silent_gap_elapsed_ms >= 250
      assert body =~ "visible-before-idle"
      refute body =~ "late"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.transport == "http_sse"
      assert request.status == "failed"
      assert request.last_error_code == "stream_idle_timeout"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "failed"
      assert attempt.network_error_code == "stream_idle_timeout"
      refute Map.has_key?(attempt.response_metadata, "transport_failure")
    after
      Process.send_after(upstream_pid, {:fake_upstream_release_timeout, release_ref}, 250)
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :streaming_timing
  test "POST /v1/responses streaming keeps silent pre-first-event SSE stalls metadata-only" do
    release_ref = make_ref()
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 100})

    upstream =
      start_upstream(
        FakeUpstream.timeout_after_sse_headers(notify: self(), release_ref: release_ref)
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {:ok, http_conn, ref, started} =
      start_public_v1_responses_request(port, setup, %{
        "model" => setup.model.exposed_model_id,
        "input" => "silent after headers stall fixture",
        "stream" => true
      })

    assert_receive {:fake_upstream_timeout_barrier, :after_sse_headers, upstream_pid,
                    ^release_ref},
                   @timing_observation_timeout_ms

    try do
      {http_conn, status, response_headers, header_elapsed_ms, chunks, done?} =
        await_public_response_headers!(
          http_conn,
          ref,
          started,
          @timing_observation_timeout_ms
        )

      assert status == 200
      assert header_elapsed_ms < @ttfh_threshold_ms
      assert header_value(response_headers, "content-type") =~ "text/event-stream"

      body =
        await_public_response_done!(
          http_conn,
          ref,
          chunks,
          done?,
          @failure_observation_timeout_ms
        )

      total_elapsed_ms = elapsed_ms(started)
      silent_gap_elapsed_ms = await_silent_gap!(started, 250)

      assert total_elapsed_ms >= 100
      assert silent_gap_elapsed_ms >= 250
      assert body == ""
      refute body =~ "response.created"
      refute body =~ "response.failed"
      refute body =~ "response.completed"
      refute body =~ "[DONE]"
      refute body =~ "stream_idle_timeout"

      assert FakeUpstream.count(upstream) == 1
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "http_sse"
      assert request.status == "failed"
      assert request.last_error_code == "stream_idle_timeout"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"

      assert attempt.status == "failed"
      assert attempt.network_error_code == "stream_idle_timeout"

      assert_pre_first_stream_idle_timeout!(setup)
    after
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :streaming_timing
  test "POST /v1/responses streaming keeps partial pre-first-event SSE stalls metadata-only" do
    release_ref = make_ref()
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 100})

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_public_raw_partial_stall"),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {:ok, http_conn, ref, started} =
      start_public_v1_responses_request(port, setup, %{
        "model" => setup.model.exposed_model_id,
        "input" => "partial frame stall fixture",
        "stream" => true
      })

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref},
                   @timing_observation_timeout_ms

    try do
      {http_conn, status, response_headers, header_elapsed_ms, chunks, done?} =
        await_public_response_headers!(
          http_conn,
          ref,
          started,
          @timing_observation_timeout_ms
        )

      assert status == 200
      assert header_elapsed_ms < @ttfh_threshold_ms
      assert header_value(response_headers, "content-type") =~ "text/event-stream"

      body =
        await_public_response_done!(
          http_conn,
          ref,
          chunks,
          done?,
          @failure_observation_timeout_ms
        )

      total_elapsed_ms = elapsed_ms(started)
      silent_gap_elapsed_ms = await_silent_gap!(started, 250)

      assert total_elapsed_ms >= 100
      assert silent_gap_elapsed_ms >= 250
      assert body == ""
      refute body =~ "response.created"
      refute body =~ "response.failed"
      refute body =~ "response.completed"
      refute body =~ "[DONE]"
      refute body =~ "resp_public_raw_partial_stall"
      refute body =~ "stream_idle_timeout"

      assert FakeUpstream.count(upstream) == 1
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "http_sse"
      assert request.status == "failed"
      assert request.last_error_code == "stream_idle_timeout"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"

      assert attempt.status == "failed"
      assert attempt.network_error_code == "stream_idle_timeout"

      assert_pre_first_stream_idle_timeout!(setup)
    after
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      Mint.HTTP.close(http_conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket stays alive while upstream sends steady progress" do
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 250})

    upstream =
      start_upstream(
        FakeUpstream.delayed_sse_stream(
          long_turn_progress_events("resp_v1_ws_long_turn_progress"),
          interval_ms: 100
        )
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-ws-long-progress-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    started = System.monotonic_time(:millisecond)

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, websocket, first_frame} = public_websocket_receive_text!(conn, websocket, ref)
      first_elapsed_ms = elapsed_ms(started)
      {conn, websocket, second_frame} = public_websocket_receive_text!(conn, websocket, ref)

      {conn, _websocket, terminal_frame} =
        receive_public_websocket_until_completed!(conn, websocket, ref)

      total_elapsed_ms = elapsed_ms(started)

      assert first_elapsed_ms < @ttfh_threshold_ms
      assert Jason.decode!(first_frame)["type"] == "response.output_text.delta"
      assert Jason.decode!(second_frame)["delta"] == "progress-2"
      assert %{"type" => "response.completed"} = Jason.decode!(terminal_frame)
      assert total_elapsed_ms >= 600

      assert_receive_finalized_request!()

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket rejects frames above the shared configured body cap" do
    setup_runtime_ingress_override(%OperationalSettings{
      max_decompressed_body_bytes: 700,
      websocket_idle_timeout_ms: 60_000
    })

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused_v1_oversized_frame"}))
    setup = gateway_setup(upstream)
    {server, port} = start_public_endpoint_with_server!()
    turn_state = "v1-ws-oversized-frame-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    try do
      assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
      monitor_ref = Process.monitor(connection_pid)

      {{conn, _websocket, code, reason}, logs} =
        with_log(fn ->
          {conn, websocket} =
            public_websocket_send_text!(conn, websocket, ref, String.duplicate("x", 1_000))

          result = public_websocket_receive_close!(conn, websocket, ref)

          assert_receive {:DOWN, ^monitor_ref, :process, ^connection_pid, _reason},
                         @connection_shutdown_timeout_ms

          Logger.flush()
          result
        end)

      assert code == 1009
      assert reason == ""
      assert logs =~ "max_frame_size_exceeded"
      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket terminates typeless upstream detail frames" do
    upstream_detail = "synthetic detail-only upstream frame must not persist"

    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          Jason.encode!(%{"detail" => upstream_detail})
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-ws-detail-terminal-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    started = System.monotonic_time(:millisecond)

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, terminal_frame} = public_websocket_receive_text!(conn, websocket, ref)
      elapsed_ms = elapsed_ms(started)

      assert elapsed_ms < @ttfh_threshold_ms

      assert %{
               "type" => "response.failed",
               "error" => %{"code" => "upstream_terminal_failure"},
               "response" => %{
                 "status" => "failed",
                 "error" => %{"code" => "upstream_terminal_failure"}
               }
             } = Jason.decode!(terminal_frame)

      refute terminal_frame =~ upstream_detail

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"status" => "failed"}
                      }},
                     @websocket_frame_timeout

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "failed"
      assert request.last_error_code == "upstream_terminal_failure"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "failed"
      refute attempt.network_error_code == "stream_idle_timeout"

      persistence_text = inspect({request.request_metadata, attempt.response_metadata})
      refute persistence_text =~ upstream_detail
      refute persistence_text =~ setup.authorization
      refute persistence_text =~ setup.raw_key

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :v1_websocket
  test "GET /v1/responses websocket keeps HTTP synthetic terminals isolated after visible timeout" do
    release_ref = make_ref()
    setup_runtime_ingress_override(%OperationalSettings{upstream_receive_timeout_ms: 150})

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"visible-before-ws-idle"}\n\n),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "v1-ws-idle-timeout-#{System.unique_integer([:positive])}"

    {conn, websocket, ref, _response_headers} =
      public_v1_websocket_connect!(port, setup, turn_state, [
        {"openai-beta", "responses_websockets=2026-02-06"}
      ])

    started = System.monotonic_time(:millisecond)

    try do
      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, websocket, visible_frame} = public_websocket_receive_text!(conn, websocket, ref)
      visible_elapsed_ms = elapsed_ms(started)
      silent_gap_elapsed_ms = await_silent_gap!(started, 250)

      {conn, _websocket, terminal_frame} = public_websocket_receive_text!(conn, websocket, ref)
      total_elapsed_ms = elapsed_ms(started)

      assert visible_elapsed_ms < @ttfh_threshold_ms
      assert silent_gap_elapsed_ms >= 250
      assert Jason.decode!(visible_frame)["delta"] == "visible-before-ws-idle"

      assert %{
               "type" => "error",
               "status" => 502,
               "error" => %{"code" => "stream_idle_timeout"}
             } = terminal = Jason.decode!(terminal_frame)

      refute Map.has_key?(terminal, "code")
      refute Map.has_key?(terminal, "param")
      refute Map.has_key?(terminal, "sequence_number")

      assert total_elapsed_ms >= 150

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "failed"
      assert request.last_error_code == "stream_idle_timeout"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "failed"
      assert attempt.network_error_code == "stream_idle_timeout"

      assert is_map(request.request_metadata)
      assert is_map(attempt.response_metadata)

      persistence_text = inspect({request.request_metadata, attempt.response_metadata})
      refute persistence_text =~ "hello"
      refute persistence_text =~ setup.authorization
      refute persistence_text =~ setup.raw_key

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "POST /v1/responses streaming preserves web search action queries", %{conn: conn} do
    web_search_item = web_search_call_item("ws_call_stream")

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => web_search_item
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 0,
             "item" => web_search_item
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream_web_search_queries",
               "status" => "completed",
               "output" => [web_search_item],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic streaming web search request",
        "stream" => true
      })

    events = public_sse_events(conn.resp_body)

    assert %{
             "type" => "web_search_call",
             "action" => %{
               "type" => "search",
               "query" => "synthetic release notes",
               "queries" => ["synthetic release notes", "synthetic changelog"]
             }
           } = event_item(events, "response.output_item.added")

    assert %{
             "type" => "web_search_call",
             "action" => %{
               "type" => "search",
               "query" => "synthetic release notes",
               "queries" => ["synthetic release notes", "synthetic changelog"]
             }
           } = event_item(events, "response.output_item.done")
  end

  test "POST /v1/responses streaming keeps non-text-first output ordering", %{conn: conn} do
    web_search_item = web_search_call_item("ws_call_first_visible")

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => web_search_item
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 0,
             "item" => web_search_item
           }},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "final text"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_non_text_first_stream",
               "status" => "completed",
               "output" => [
                 web_search_item,
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "final text"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic non text first stream request",
        "stream" => true
      })

    events = public_sse_events(conn.resp_body)
    event_types = Enum.map(events, & &1["event"])
    output_item_index = Enum.find_index(event_types, &(&1 == "response.output_item.added"))
    text_delta_index = Enum.find_index(event_types, &(&1 == "response.output_text.delta"))

    assert output_item_index != nil
    assert text_delta_index != nil
    assert output_item_index < text_delta_index
    assert event_item(events, "response.output_item.added")["type"] == "web_search_call"
  end

  test "POST /v1/responses streaming synthesizes missing public output item ids", %{
    conn: conn
  } do
    tool_item = %{
      "type" => "function_call",
      "call_id" => "call_v1_stream_public_tool_id",
      "name" => "lookup_fixture",
      "arguments" => "{}"
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => tool_item
           }},
          {"response.output_item.done",
           %{
             "type" => "response.output_item.done",
             "output_index" => 0,
             "item" => tool_item
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream_public_tool_id",
               "status" => "completed",
               "output" => [tool_item],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic streaming tool request",
        "stream" => true
      })

    events = public_sse_events(conn.resp_body)
    added_item = event_item(events, "response.output_item.added")
    done_item = event_item(events, "response.output_item.done")

    assert added_item["id"] == "call_v1_stream_public_tool_id"
    assert added_item["call_id"] == "call_v1_stream_public_tool_id"
    assert done_item["id"] == "call_v1_stream_public_tool_id"
    assert done_item["call_id"] == "call_v1_stream_public_tool_id"

    assert %{"data" => %{"response" => %{"output" => [completed_item]}}} =
             Enum.find(events, &(&1["event"] == "response.completed"))

    assert completed_item["id"] == "call_v1_stream_public_tool_id"
    assert completed_item["call_id"] == "call_v1_stream_public_tool_id"
  end

  test "POST /v1/responses streaming synthesizes missing delta from terminal output", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_terminal_only",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "terminal text"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic terminal stream request",
        "stream" => true
      })

    assert conn.resp_body =~ "event: response.created\n"
    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ "terminal text"
    assert conn.resp_body =~ "event: response.completed\n"
  end

  @tag :startup_error
  test "POST /v1/responses streaming startup error returns OpenAI-shaped error", %{conn: conn} do
    upstream =
      start_upstream(
        {:json_error, 400,
         %{
           "error" => %{
             "code" => "invalid_request_error",
             "message" => "synthetic startup rejection"
           }
         }}
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic startup error request",
        "stream" => true
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "upstream_status"
    refute Map.has_key?(error, "param")
    refute conn.resp_body =~ "synthetic startup rejection"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
  end

  @tag :input_file_upstream_404
  test "POST /v1/responses projects input-file upstream 404 without provider detail", %{
    conn: conn
  } do
    provider_detail = "provider 404 leaked https://provider.internal.example/files?key=sk-secret"

    upstream =
      start_upstream(
        {:json_error, 404,
         %{
           "error" => %{
             "code" => "provider_not_found",
             "message" => provider_detail,
             "param" => "input[0].content[0].file_id",
             "type" => "api_error"
           }
         }}
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "input_file",
                "filename" => "synthetic.pdf",
                "file_data" => "data:application/pdf;base64,c3ludGhldGljIGZpbGU="
              }
            ]
          }
        ]
      })

    assert %{"error" => error} = json_response(response, 404)

    assert error == %{
             "code" => "upstream_status",
             "message" => "upstream request failed",
             "type" => "invalid_request_error",
             "upstream_status" => 404
           }

    refute response.resp_body =~ "synthetic.pdf"

    refute response.resp_body =~ provider_detail
    refute response.resp_body =~ "provider.internal.example"
    refute response.resp_body =~ "sk-secret"
    refute response.resp_body =~ "provider_not_found"
    assert FakeUpstream.count(upstream) == 1
  end

  @tag :input_file_upstream_404
  test "POST /v1/responses keeps unrelated upstream 404 redacted", %{conn: conn} do
    provider_detail =
      "provider 404 leaked https://provider.internal.example/responses?key=sk-secret"

    upstream =
      start_upstream(
        {:json_error, 404,
         %{
           "error" => %{
             "code" => "provider_not_found",
             "message" => provider_detail,
             "param" => "input",
             "type" => "api_error"
           }
         }}
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic ordinary response"
      })

    assert %{"error" => error} = json_response(response, 502)
    assert error["message"] == "upstream request failed"
    assert error["type"] == "server_error"
    assert error["code"] == "upstream_status"
    refute Map.has_key?(error, "param")
    refute response.resp_body =~ provider_detail
    refute response.resp_body =~ "provider.internal.example"
    refute response.resp_body =~ "sk-secret"
    assert FakeUpstream.count(upstream) == 1
  end

  test "POST /v1/responses rejects unsupported logprobs before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic invalid request",
        "logprobs" => true
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "unsupported_parameter"
    assert error["param"] == "logprobs"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  @tag :input_audio_responses_baseline
  test "POST /v1/responses dispatches WAV input audio with metadata-only accounting", %{
    conn: conn
  } do
    audio_source = "wav response baseline"
    audio_data = Base.encode64(audio_source)
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_v1_audio_baseline"}))
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [input_audio_part("wav", audio_data)]
          }
        ]
      })

    assert %{"id" => "resp_v1_audio_baseline"} = json_response(response, 200)
    assert FakeUpstream.count(upstream) == 1

    assert_captured_audio_summary!(
      upstream,
      expected_audio_summary("audio/wav", audio_source)
    )

    assert_audio_accounting_metadata_only!(setup.pool, [audio_source, audio_data])
  end

  @tag :input_audio_backport
  test "POST /v1/responses translates M4A input audio with a safe upstream summary", %{
    conn: conn
  } do
    audio_source = "m4a response fixture"
    canonical_data = Base.encode64(audio_source)
    audio_data = with_ascii_whitespace(canonical_data)
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_v1_audio_m4a"}))
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [input_audio_part("m4a", audio_data)]
          }
        ]
      })

    assert %{"id" => "resp_v1_audio_m4a"} = json_response(response, 200)
    assert FakeUpstream.count(upstream) == 1

    assert_captured_audio_summary!(
      upstream,
      expected_audio_summary("audio/mp4", audio_source)
    )

    assert_audio_accounting_metadata_only!(setup.pool, [audio_source, audio_data, canonical_data])
  end

  @tag :input_audio_backport
  test "POST /v1/responses rejects malformed input audio before side effects", %{conn: conn} do
    audio_data = "not base64"
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [input_audio_part("m4a", audio_data)]
          }
        ]
      })

    assert_sanitized_audio_error_response!(
      response,
      public_audio_error("input_audio data must be base64"),
      [audio_data]
    )

    assert_no_audio_side_effects!(upstream)
  end

  @tag :input_audio_backport
  test "POST /v1/responses rejects FLAC input audio before side effects", %{conn: conn} do
    audio_source = "flac response fixture"
    audio_data = Base.encode64(audio_source)
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [input_audio_part("flac", audio_data)]
          }
        ]
      })

    assert_sanitized_audio_error_response!(
      response,
      public_audio_error("message content part is not translatable"),
      [audio_source, audio_data, "flac"]
    )

    assert_no_audio_side_effects!(upstream)
  end

  test "POST /v1/responses forwards supported SDK-shaped image and file parts safely", %{
    conn: conn
  } do
    image_bytes = "inline image fixture"
    pdf_bytes = "inline pdf fixture"
    image_data_url = "data:image/png;base64," <> Base.encode64(image_bytes)
    file_data_url = "data:application/pdf;base64," <> Base.encode64(pdf_bytes)

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_media_supported",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, model_metadata: %{"input_modalities" => ["text", "image"]})

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic multimodal response"},
              %{"type" => "input_image", "image_url" => image_data_url},
              %{"type" => "input_image", "image_url" => "https://example.com/sample.png"},
              %{
                "type" => "input_file",
                "filename" => "sample.pdf",
                "file_data" => file_data_url
              }
            ]
          }
        ]
      })

    assert %{"id" => "resp_v1_media_supported"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert [%{"content" => content}] = captured.json["input"]

    assert Enum.map(content, & &1["type"]) == [
             "input_text",
             "input_image",
             "input_image",
             "input_file"
           ]

    assert Enum.at(content, 1)["image_url"] =~ "data:image/png;base64,"
    assert Enum.at(content, 2)["image_url"] == "https://example.com/sample.png"
    assert Enum.at(content, 3)["filename"] == "sample.pdf"
    assert Enum.at(content, 3)["file_data"] =~ "data:application/pdf;base64,"

    [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic multimodal response"
    refute metadata =~ image_bytes
    refute metadata =~ pdf_bytes
    refute metadata =~ Base.encode64(image_bytes)
    refute metadata =~ Base.encode64(pdf_bytes)
    refute metadata =~ "https://example.com/sample.png"
  end

  test "POST /v1/responses rejects unsupported media references before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_parts = [
      {%{"type" => "input_image", "image_url" => "file:///tmp/private.png"},
       "unsupported_input_image_format"},
      {%{"type" => "input_image", "image_url" => "http://example.com/private.png"},
       "unsupported_input_image_format"},
      {%{
         "type" => "input_file",
         "filename" => "sample.html",
         "file_data" => "data:text/html;base64," <> Base.encode64("html fixture")
       }, "unsupported_input_file_format"}
    ]

    Enum.each(invalid_parts, fn {part, expected_code} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [%{"role" => "user", "content" => [part]}]
        })

      assert %{"error" => %{"code" => ^expected_code, "param" => "input"}} =
               json_response(response, 400)
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses/compact returns deterministic unsupported error without dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream, compact?: true)

    responses =
      for mode <- ["full", "lite"] do
        put_public_model_serving_mode!(setup, mode)

        response =
          conn
          |> recycle()
          |> auth(setup)
          |> with_public_metadata_headers()
          |> post("/v1/responses/compact", %{
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic compact request"
          })

        assert %{
                 "error" => %{
                   "code" => "unsupported_endpoint",
                   "message" => "Unsupported OpenAI /v1 endpoint",
                   "param" => nil
                 }
               } = json_response(response, 404)

        response
      end

    assert [full_response, lite_response] = responses
    assert json_response(full_response, 404) == json_response(lite_response, 404)
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp put_public_model_serving_mode!(setup, mode) do
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

  defp public_compaction_trigger_input(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      },
      %{"type" => "compaction_trigger"}
    ]
  end

  defp public_tool_output_compaction_trigger_input(output) do
    [
      %{
        "type" => "function_call_output",
        "call_id" => "call_public_compaction_trigger",
        "output" => output
      },
      %{"type" => "compaction_trigger"}
    ]
  end

  defp public_mode_matrix_upstream do
    FakeUpstream.sse_stream([
      {"response.created",
       %{
         "type" => "response.created",
         "response" => %{"id" => "resp_public_mode_matrix", "status" => "in_progress"}
       }},
      {"response.output_text.delta",
       %{"type" => "response.output_text.delta", "delta" => "synthetic public mode answer"}},
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_public_mode_matrix",
           "status" => "completed",
           "model" => "provider-gpt-test-model",
           "output" => [],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
         }
       }}
    ])
  end

  defp assert_public_mode_matrix_response!(response, false) do
    assert %{"id" => "resp_public_mode_matrix", "object" => "response"} =
             json_response(response, 200)
  end

  defp assert_public_mode_matrix_response!(response, true) do
    assert response.status == 200
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/event-stream"
    assert response.resp_body =~ "response.completed"
  end

  defp assert_public_mode_matrix_headers!(full_capture, lite_capture) do
    mode_header = "x-openai-internal-codex-responses-lite"
    full_headers = Map.new(full_capture.headers)
    lite_headers = Map.new(lite_capture.headers)

    refute Map.has_key?(full_headers, mode_header)
    assert lite_headers[mode_header] == "true"
    assert comparable_public_headers(full_headers) == comparable_public_headers(lite_headers)
  end

  defp comparable_public_headers(headers) do
    Map.drop(headers, [
      "x-openai-internal-codex-responses-lite",
      "content-length",
      "host",
      "authorization",
      "chatgpt-account-id"
    ])
  end

  defp assert_public_mode_matrix_bodies!(full_capture, lite_capture) do
    mode_specific_keys = ["input", "instructions", "reasoning", "parallel_tool_calls"]

    assert Map.drop(full_capture.json, mode_specific_keys) ==
             Map.drop(lite_capture.json, mode_specific_keys)

    assert is_list(full_capture.json["input"])
    assert is_list(lite_capture.json["input"])
    assert Enum.drop(lite_capture.json["input"], 1) == full_capture.json["input"]
    assert get_in(lite_capture.json, ["reasoning", "context"]) == "all_turns"
    assert lite_capture.json["parallel_tool_calls"] == false
  end

  defp assert_public_mode_matrix_metadata!(setup, modes) do
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

      assert request.endpoint == "/backend-api/codex/responses"
      assert request.status == "succeeded"
      assert request.transport == "http_sse"
      assert Map.take(request.request_metadata["routing"], expected_keys) == expected

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"
      assert Map.take(attempt.response_metadata["routing"], expected_keys) == expected
    end
  end

  defp enable_request_compression!(pool) do
    pool
    |> CodexPooler.Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      request_compression_enabled: true,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp long_turn_progress_events(response_id) do
    progress_events =
      for index <- 1..6 do
        {"response.output_text.delta",
         %{"type" => "response.output_text.delta", "delta" => "progress-#{index}"}}
      end

    progress_events ++
      [
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{
             "id" => response_id,
             "status" => "completed",
             "usage" => %{"input_tokens" => 2, "output_tokens" => 6, "total_tokens" => 8}
           }
         }}
      ]
  end

  defp public_websocket_completed_response(response_id) do
    FakeUpstream.sse_stream(
      [
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{
             "id" => response_id,
             "status" => "completed",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           }
         }}
      ],
      done: false
    )
  end

  defp receive_public_websocket_until_completed!(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case Jason.decode!(frame) do
      %{"type" => "response.completed"} -> {conn, websocket, frame}
      _other -> receive_public_websocket_until_completed!(conn, websocket, ref)
    end
  end

  defp reasoning_policy_responses_upstream do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_reasoning_policy_v1",
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
         }
       }}
    ])
  end

  defp start_public_v1_responses_request(port, setup, payload) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    started = System.monotonic_time(:millisecond)

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "POST", "/v1/responses", headers, Jason.encode!(payload))

    {:ok, conn, ref, started}
  end

  defp capture_repo_queries(fun) do
    parent = self()
    handler_id = "v1-responses-controller-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(
              parent,
              {handler_id, metadata[:source], query_command(metadata[:query]), metadata[:query]}
            )
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp capture_stream_truncation_telemetry(fun) do
    parent = self()
    handler_id = "v1-responses-truncation-#{System.unique_integer([:positive])}"
    event = [:codex_pooler, :gateway, :stream_buffer, :truncated]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _config ->
          send(parent, {handler_id, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_stream_truncation_telemetry(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_stream_truncation_telemetry(handler_id, events) do
    receive do
      {^handler_id, measurements, metadata} ->
        drain_stream_truncation_telemetry(handler_id, [{measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp drain_repo_queries(handler_id, queries) do
    receive do
      {^handler_id, source, command, query} ->
        drain_repo_queries(handler_id, [
          %{source: source, command: command, query: query} | queries
        ])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp visible_codex_turn_update_count(queries) do
    Enum.count(queries, fn
      %{source: "codex_turns", command: "UPDATE", query: query} when is_binary(query) ->
        query =~ ~s("first_visible_output_at") and
          query =~ ~s("first_visible_output_at" IS NULL)

      _query ->
        false
    end)
  end

  defp query_command(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp query_command(_query), do: "UNKNOWN"

  defp await_public_response_headers!(conn, ref, started, timeout_ms) do
    await_public_response_headers!(conn, ref, started, timeout_ms, nil, nil, [], false)
  end

  defp await_public_response_headers!(
         conn,
         ref,
         started,
         timeout_ms,
         status,
         headers,
         chunks,
         done?
       ) do
    if is_integer(status) and is_list(headers) do
      {conn, status, headers, elapsed_ms(started), chunks, done?}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              {status, headers, chunks, done?} =
                merge_public_response_parts(responses, ref, status, headers, chunks, done?)

              await_public_response_headers!(
                conn,
                ref,
                started,
                timeout_ms,
                status,
                headers,
                chunks,
                done?
              )

            {:error, conn, reason, _responses} ->
              Mint.HTTP.close(conn)
              flunk("public /v1 response stream failed before headers: #{inspect(reason)}")

            :unknown ->
              await_public_response_headers!(
                conn,
                ref,
                started,
                timeout_ms,
                status,
                headers,
                chunks,
                done?
              )
          end
      after
        timeout_ms -> flunk("timed out waiting for public /v1 response headers")
      end
    end
  end

  defp await_public_response_done!(_conn, _ref, chunks, true, _timeout_ms) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp await_public_response_done!(conn, ref, chunks, false, timeout_ms) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {_status, _headers, chunks, done?} =
              merge_public_response_parts(responses, ref, nil, nil, chunks, false)

            await_public_response_done!(conn, ref, chunks, done?, timeout_ms)

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("public /v1 response stream failed before completion: #{inspect(reason)}")

          :unknown ->
            await_public_response_done!(conn, ref, chunks, false, timeout_ms)
        end
    after
      timeout_ms -> flunk("timed out waiting for public /v1 response completion")
    end
  end

  defp await_public_response_eof!(conn, ref, chunks, done?, timeout_ms) do
    {body, done?} = await_public_response_eof(conn, ref, chunks, done?, timeout_ms)
    {body, if(done?, do: :eof, else: flunk("expected public /v1 response stream EOF"))}
  end

  defp await_public_response_eof(_conn, _ref, chunks, true, _timeout_ms) do
    {chunks |> Enum.reverse() |> IO.iodata_to_binary(), true}
  end

  defp await_public_response_eof(conn, ref, chunks, false, timeout_ms) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {_status, _headers, chunks, done?} =
              merge_public_response_parts(responses, ref, nil, nil, chunks, false)

            await_public_response_eof(conn, ref, chunks, done?, timeout_ms)

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("public /v1 response stream failed before EOF: #{inspect(reason)}")

          :unknown ->
            await_public_response_eof(conn, ref, chunks, false, timeout_ms)
        end
    after
      timeout_ms -> flunk("timed out waiting for public /v1 response stream EOF")
    end
  end

  defp merge_public_response_parts(responses, ref, status, headers, chunks, done?) do
    Enum.reduce(responses, {status, headers, chunks, done?}, fn
      {:status, ^ref, status}, {_status, headers, chunks, done?} ->
        {status, headers, chunks, done?}

      {:headers, ^ref, headers}, {status, _headers, chunks, done?} ->
        {status, headers, chunks, done?}

      {:data, ^ref, data}, {status, headers, chunks, done?} ->
        {status, headers, [data | chunks], done?}

      {:done, ^ref}, {status, headers, chunks, _done?} ->
        {status, headers, chunks, true}

      _part, acc ->
        acc
    end)
  end

  defp header_value(headers, name) do
    headers
    |> Enum.find_value(fn {header_name, value} ->
      if String.downcase(to_string(header_name)) == name, do: value
    end)
  end

  defp await_silent_gap!(started, gap_ms) do
    Process.send_after(self(), {:silent_gap_elapsed, make_ref()}, gap_ms)

    receive do
      {:silent_gap_elapsed, _ref} -> elapsed_ms(started)
    after
      gap_ms + @timing_observation_timeout_ms -> flunk("timed out waiting for silent gap")
    end
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp web_search_call_item(id) do
    %{
      "id" => id,
      "type" => "web_search_call",
      "status" => "completed",
      "action" => %{
        "type" => "search",
        "query" => "synthetic release notes",
        "queries" => ["synthetic release notes", "synthetic changelog"]
      }
    }
  end

  defp additional_tools_item do
    %{
      "type" => "additional_tools",
      "role" => "developer",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup_additional_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }
  end

  defp non_strict_tool_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "properties" => %{
        "mode" => %{"const" => "fast", "title" => "drop me"},
        "tags" => %{"items" => %{"const" => "tag"}}
      },
      "required" => ["mode"],
      "additionalProperties" => %{"const" => "extra"}
    }
  end

  defp lowered_tool_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"enum" => ["fast"]},
        "tags" => %{"type" => "array", "items" => %{"enum" => ["tag"]}}
      },
      "required" => ["mode"],
      "additionalProperties" => %{"enum" => ["extra"]}
    }
  end

  defp structured_tool_result_output do
    %{
      "command" => "RAW_TOOL_COMMAND_SENTINEL run private command",
      "exit_code" => 0,
      "files" => [
        %{
          "path" => "sample-output.txt",
          "content" => "RAW_TOOL_OUTPUT_SENTINEL\n" <> String.duplicate("line\n", 200)
        }
      ],
      "nested" => %{
        "list" => [
          %{"stdout_preview" => String.duplicate("RAW_TOOL_LONG_NESTED_VALUE_", 40)},
          %{"secret_like" => "RAW_TOOL_SECRET_LIKE_SENTINEL"}
        ],
        "ok" => true
      }
    }
  end

  defp structured_tool_result_sentinels do
    [
      "RAW_TOOL_COMMAND_SENTINEL",
      "RAW_TOOL_OUTPUT_SENTINEL",
      "RAW_TOOL_LONG_NESTED_VALUE_",
      "RAW_TOOL_SECRET_LIKE_SENTINEL"
    ]
  end

  defp safe_looking_upstream_error(provider_message) do
    %{
      "type" => "api_error",
      "code" => "rate_limit_exceeded",
      "message" => provider_message,
      "param" => "provider_stack"
    }
  end

  defp provider_invalid_request_error(code, provider_message, param) do
    %{
      "type" => "invalid_request_error",
      "code" => code,
      "message" => provider_message,
      "param" => param
    }
  end

  defp assert_payload_equal_no_echo!(actual, expected, message) do
    unless actual == expected, do: flunk(message)
  end

  defp assert_no_sentinel_echo!(text, sentinels) when is_binary(text) do
    Enum.each(sentinels, fn sentinel ->
      if text =~ sentinel, do: flunk("projection leaked structured tool-result sentinel")
    end)
  end

  defp programmatic_tool_sentinels do
    suffix = System.unique_integer([:positive])

    %{
      code: "program-code-#{suffix}",
      result: "program-result-#{suffix}",
      fingerprint: "program-fingerprint-#{suffix}",
      schema: "program-schema-#{suffix}",
      item: "program-item-#{suffix}",
      call: "program-call-#{suffix}",
      caller: "program-caller-#{suffix}"
    }
  end

  defp hosted_shell_privacy_fixture! do
    suffix =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-hosted-shell-#{System.unique_integer([:positive])}-#{suffix}"
      )

    marker_path = Path.join(temp_dir, "execution-marker")
    File.mkdir!(temp_dir)
    File.chmod!(temp_dir, 0o700)

    sentinels = %{
      command: "cmd_#{suffix}",
      stdout: "out_#{suffix}",
      stderr: "err_#{suffix}"
    }

    command = "printf #{sentinels.command} >/dev/null; : > #{marker_path}"

    input =
      hosted_shell_history_fixture(%{
        command: command,
        stdout: sentinels.stdout,
        stderr: sentinels.stderr,
        call_id: "call_#{suffix}"
      })

    %{
      input: input,
      marker_path: marker_path,
      sentinels: sentinels,
      temp_dir: temp_dir
    }
  end

  defp hosted_shell_payload(model, input) do
    %{
      "model" => model,
      "store" => false,
      "input" => input
    }
  end

  defp hosted_shell_history_fixture(overrides \\ %{}) do
    call_id = Map.get(overrides, :call_id, "hosted-shell-call")
    command = Map.get(overrides, :command, "printf synthetic-command")
    stdout = Map.get(overrides, :stdout, "synthetic stdout")
    stderr = Map.get(overrides, :stderr, "synthetic stderr")

    [
      %{
        "type" => "shell_call",
        "id" => "hosted-shell-call-item",
        "call_id" => call_id,
        "status" => "completed",
        "caller" => %{"type" => "direct"},
        "environment" => %{"type" => "local", "skills" => []},
        "action" => %{
          "commands" => [command],
          "timeout_ms" => 1_000,
          "max_output_length" => 4_096
        }
      },
      %{
        "type" => "shell_call_output",
        "id" => "hosted-shell-output-item",
        "call_id" => call_id,
        "status" => "completed",
        "caller" => %{"type" => "direct"},
        "max_output_length" => 4_096,
        "output" => [
          %{
            "stdout" => stdout,
            "stderr" => stderr,
            "outcome" => %{"type" => "exit", "exit_code" => 7}
          }
        ]
      },
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "continue after hosted shell"}]
      }
    ]
  end

  defp hosted_shell_completed_response(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
         }
       }}
    ])
  end

  defp curl_hosted_shell_stream!(port, authorization, model, input) do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-hosted-shell-curl-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(temp_dir)
    File.chmod!(temp_dir, 0o700)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    request_path = Path.join(temp_dir, "request.json")

    File.write!(
      request_path,
      Jason.encode!(hosted_shell_payload(model, input) |> Map.put("stream", true))
    )

    File.chmod!(request_path, 0o600)

    {output, exit_code} =
      System.cmd(
        "curl",
        [
          "-N",
          "-i",
          "--silent",
          "--show-error",
          "--max-time",
          "10",
          "-H",
          "content-type: application/json",
          "-H",
          "authorization: #{authorization}",
          "--data-binary",
          "@#{request_path}",
          "http://127.0.0.1:#{port}/v1/responses"
        ],
        stderr_to_stdout: true
      )

    unless exit_code == 0 do
      flunk("hosted shell curl SSE request failed")
    end

    case String.split(output, "\r\n\r\n", parts: 2) do
      [headers, body] -> {headers, body}
      _parts -> flunk("hosted shell curl SSE response was malformed")
    end
  end

  defp hosted_shell_sse_events do
    [
      {"response.shell_call_command.added",
       %{
         "type" => "response.shell_call_command.added",
         "command" => "printf synthetic-command",
         "command_index" => 0,
         "output_index" => 2,
         "sequence_number" => 50
       }},
      {"response.shell_call_command.delta",
       %{
         "type" => "response.shell_call_command.delta",
         "command_index" => 0,
         "delta" => " --synthetic-delta",
         "obfuscation" => "synthetic-padding",
         "output_index" => 2,
         "sequence_number" => 1
       }},
      {"response.shell_call_command.done",
       %{
         "type" => "response.shell_call_command.done",
         "command" => "printf synthetic-command --synthetic-delta",
         "command_index" => 0,
         "created_by" => "synthetic-response-actor",
         "output_index" => 2,
         "sequence_number" => 55
       }},
      {"response.shell_call_output_content.delta",
       %{
         "type" => "response.shell_call_output_content.delta",
         "command_index" => 0,
         "delta" => %{
           "stdout" => "synthetic stdout delta",
           "stderr" => "synthetic stderr delta"
         },
         "item_id" => "hosted-shell-output-item",
         "output_index" => 2,
         "sequence_number" => 54
       }},
      {"response.shell_call_output_content.done",
       %{
         "type" => "response.shell_call_output_content.done",
         "command_index" => 0,
         "item_id" => "hosted-shell-output-item",
         "output" => [
           %{
             "stdout" => "synthetic stdout final",
             "stderr" => "synthetic stderr final",
             "outcome" => %{"type" => "exit", "exit_code" => 7},
             "created_by" => "synthetic-output-actor"
           }
         ],
         "output_index" => 2,
         "sequence_number" => 60
       }},
      {"response.completed",
       %{
         "type" => "response.completed",
         "created_by" => "synthetic-completion-actor",
         "response" => %{
           "id" => "resp_hosted_shell_events",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
         },
         "sequence_number" => 2
       }}
    ]
  end

  defp assert_hosted_shell_forwarded!(capture, expected_input) do
    expected_input = hosted_shell_expected_upstream_input(expected_input)

    unless capture.path == "/backend-api/codex/responses" and capture.json["stream"] == true and
             capture.json["store"] == false and capture.json["input"] == expected_input do
      flunk("hosted shell history changed before upstream dispatch")
    end
  end

  defp hosted_shell_expected_upstream_input(input) do
    Enum.map(input, fn
      %{"type" => type} = item when type in ["shell_call", "shell_call_output"] ->
        Map.delete(item, "id")

      item ->
        item
    end)
  end

  defp assert_hosted_shell_sentinels_absent!(text, sentinels) do
    if Enum.any?(Map.values(sentinels), &String.contains?(text, &1)) do
      flunk("hosted shell history leaked into an observable metadata surface")
    end
  end

  defp assert_no_hosted_shell_lifecycle_stream!(body) do
    lifecycle_markers = ["event:", "response.created", "response.completed"]

    if Enum.any?(lifecycle_markers, &String.contains?(body, &1)) do
      flunk("malformed hosted shell history emitted a lifecycle stream")
    end
  end

  defp programmatic_tool_payload(model, sentinels) do
    %{
      "model" => model,
      "store" => true,
      "input" => programmatic_tool_items(sentinels),
      "tools" => [
        %{"type" => "programmatic_tool_calling"},
        %{
          "type" => "function",
          "name" => "lookup_programmatic_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "allowed_callers" => ["direct", "programmatic"],
          "output_schema" => %{
            "type" => "object",
            "x-opaque-programmatic-schema" => sentinels.schema
          }
        }
      ],
      "tool_choice" => %{"type" => "programmatic_tool_calling"}
    }
  end

  defp programmatic_tool_items(sentinels) do
    [
      %{
        "type" => "program",
        "id" => sentinels.item,
        "call_id" => sentinels.call,
        "code" => sentinels.code,
        "fingerprint" => sentinels.fingerprint
      },
      %{
        "type" => "function_call",
        "id" => "#{sentinels.item}-function-call",
        "call_id" => "#{sentinels.call}-function",
        "name" => "lookup_programmatic_fixture",
        "arguments" => "{}",
        "caller" => %{"type" => "program", "caller_id" => sentinels.caller}
      },
      %{
        "type" => "function_call_output",
        "id" => "#{sentinels.item}-function-output",
        "call_id" => "#{sentinels.call}-function",
        "output" => sentinels.result,
        "caller" => %{"type" => "program", "caller_id" => sentinels.caller}
      },
      %{
        "type" => "program_output",
        "id" => "#{sentinels.item}-output",
        "call_id" => sentinels.call,
        "result" => sentinels.result,
        "status" => "completed"
      }
    ]
  end

  defp assert_programmatic_input_forwarded!(input, sentinels) do
    assert Enum.map(input, & &1["type"]) == [
             "program",
             "function_call",
             "function_call_output",
             "program_output"
           ]

    assert [program, function_call, function_output, program_output] = input
    refute Map.has_key?(program, "id")
    assert program["call_id"] == sentinels.call
    assert program["code"] == sentinels.code
    assert program["fingerprint"] == sentinels.fingerprint

    refute Map.has_key?(function_call, "id")
    assert function_call["call_id"] == "#{sentinels.call}-function"
    assert function_call["caller"] == %{"type" => "program", "caller_id" => sentinels.caller}

    refute Map.has_key?(function_output, "id")
    assert function_output["call_id"] == "#{sentinels.call}-function"
    assert function_output["output"] == sentinels.result
    assert function_output["caller"] == %{"type" => "program", "caller_id" => sentinels.caller}

    refute Map.has_key?(program_output, "id")
    assert program_output["call_id"] == sentinels.call
    assert program_output["result"] == sentinels.result
    assert program_output["status"] == "completed"
  end

  defp put_programmatic_payload_item(payload, index, key, value) do
    input = List.update_at(payload["input"], index, &Map.put(&1, key, value))
    Map.put(payload, "input", input)
  end

  defp put_programmatic_payload_tool(payload, index, key, value) do
    tools = List.update_at(payload["tools"], index, &Map.put(&1, key, value))
    Map.put(payload, "tools", tools)
  end

  defp assert_programmatic_metadata_only!(request, attempt, sentinels) do
    metadata = inspect({request.request_metadata, attempt.response_metadata})

    for sentinel <- Map.values(sentinels) do
      refute metadata =~ sentinel
    end
  end

  defp issue_241_completed_response(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
         }
       }}
    ])
  end

  defp issue_241_repairable_parameters do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "config" => %{
          "additionalProperties" => false,
          "properties" => %{
            "entries" => %{
              "items" => %{
                "additionalProperties" => false,
                "properties" => %{"value" => %{"type" => "string"}},
                "required" => ["value"]
              }
            }
          },
          "required" => ["entries"]
        }
      },
      "required" => ["config"]
    }
  end

  defp issue_241_strict_function_tool(parameters) do
    %{
      "type" => "function",
      "name" => "invalid_schema_fixture",
      "strict" => true,
      "parameters" => parameters
    }
  end

  defp assert_issue_241_success_lifecycle!(setup) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    ledger_entries =
      Repo.all(
        from(l in LedgerEntry,
          where: l.request_id == ^request.id,
          order_by: [asc: l.created_at]
        )
      )

    assert Enum.frequencies_by(ledger_entries, & &1.entry_kind) == %{
             "reservation" => 1,
             "release" => 1,
             "settlement" => 1
           }

    assert %LedgerEntry{amount_status: "recorded", usage_status: "usage_pending"} =
             Enum.find(ledger_entries, &(&1.entry_kind == "reservation"))

    assert %LedgerEntry{amount_status: "recorded"} =
             Enum.find(ledger_entries, &(&1.entry_kind == "release"))

    assert %LedgerEntry{amount_status: "recorded", usage_status: "usage_known"} =
             Enum.find(ledger_entries, &(&1.entry_kind == "settlement"))

    assert Repo.aggregate(
             from(fact in RequestLogFact, where: fact.request_id == ^request.id),
             :count
           ) == 1
  end

  defp durable_accounting_counts do
    ledger_counts =
      LedgerEntry
      |> group_by([entry], entry.entry_kind)
      |> select([entry], {entry.entry_kind, count(entry.id)})
      |> Repo.all()
      |> Map.new()

    %{
      requests: Repo.aggregate(Request, :count),
      attempts: Repo.aggregate(Attempt, :count),
      ledger_entries: Repo.aggregate(LedgerEntry, :count),
      request_log_facts: Repo.aggregate(RequestLogFact, :count),
      reservations: Map.get(ledger_counts, "reservation", 0),
      releases: Map.get(ledger_counts, "release", 0),
      settlements: Map.get(ledger_counts, "settlement", 0)
    }
  end

  defp compression_log_fixture(omitted_sentinel) do
    middle =
      1..96
      |> Enum.map(fn
        48 -> "ordinary build line 48 #{omitted_sentinel}"
        index -> "ordinary build line #{index}"
      end)

    [
      "command started",
      "context before first",
      "error: first failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final failure",
      "context after final"
    ])
    |> Enum.join("\n")
  end

  defp public_sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case public_sse_event(block) do
        nil -> []
        event -> [event]
      end
    end)
  end

  defp await_committed_public_turn(pool_id, attempts_left \\ 1_000)

  defp await_committed_public_turn(_pool_id, 0),
    do: flunk("expected committed public bridge turn")

  defp await_committed_public_turn(pool_id, attempts_left) do
    turn =
      Repo.one(
        from(turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where: request.pool_id == ^pool_id,
          order_by: [desc: turn.started_at],
          limit: 1
        )
      )

    case turn do
      %CodexTurn{first_visible_output_at: %DateTime{}} ->
        turn

      _pending ->
        receive do
        after
          1 -> await_committed_public_turn(pool_id, attempts_left - 1)
        end
    end
  end

  defp enable_websocket_owner_forwarding! do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      capture_log(&stop_websocket_owners/0)

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp stop_websocket_owners do
    WebsocketOwnerSession.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(&stop_websocket_owner/1)
  end

  defp stop_websocket_owner(session_id) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(session_id) do
      GenServer.stop(owner_pid, :shutdown, 1_000)
    end
  end

  defp public_sse_event(block) do
    lines = String.split(block, "\n")
    event = lines |> Enum.find(&String.starts_with?(&1, "event: ")) |> strip_sse_prefix("event: ")
    data = lines |> Enum.find(&String.starts_with?(&1, "data: ")) |> strip_sse_prefix("data: ")

    if is_binary(event) and is_binary(data) and data != "[DONE]" do
      %{"event" => event, "data" => Jason.decode!(data)}
    end
  end

  defp event_item(events, event_type) do
    events
    |> Enum.find_value(fn
      %{"event" => ^event_type, "data" => %{"item" => item}} -> item
      _event -> nil
    end)
  end

  defp strip_sse_prefix(nil, _prefix), do: nil
  defp strip_sse_prefix(line, prefix), do: String.replace_prefix(line, prefix, "")

  defp websocket_upgrade_headers(conn) do
    conn
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
  end

  defp put_setup_model_source_metadata!(setup, source_metadata) when is_map(source_metadata) do
    source_metadata = Map.put_new(source_metadata, "slug", setup.model.exposed_model_id)

    metadata =
      setup.model.metadata
      |> Map.put("source_assignment_models", %{setup.assignment.id => source_metadata})

    model =
      setup.model
      |> Ecto.Changeset.change(%{metadata: metadata})
      |> Repo.update!()

    %{setup | model: model}
  end

  defp issue_231_gateway_setup(selected_upstream, alternate_upstream, opts) do
    setup = gateway_setup(selected_upstream, quota?: false)

    alternate =
      gateway_upstream(
        setup.pool,
        alternate_upstream,
        "upstream-token-issue-231-alternate",
        compact?: false
      )

    prime_weekly_exhausted_quota!(setup.identity)
    prime_weekly_probe_quota!(alternate.identity)

    source = get_in(setup.model.metadata, ["source_assignment_models", setup.assignment.id])

    selected_source =
      source
      |> Map.put("service_tiers", [%{"id" => "priority"}])
      |> Map.put("default_reasoning_level", "medium")
      |> Map.put("default_service_tier", "default")

    alternate_source =
      if Keyword.fetch!(opts, :divergent?) do
        # The reported pool diverged on presentation hints, which no longer
        # split a canonical partition. Keep them here as the realistic shape,
        # and add the behavioral field that does still split.
        selected_source
        |> Map.put("default_reasoning_level", "high")
        |> Map.put("default_service_tier", "priority")
        |> Map.put("context_window", 111_111)
      else
        selected_source
      end

    metadata =
      setup.model.metadata
      |> Map.put("source_assignment_ids", [setup.assignment.id, alternate.assignment.id])
      |> Map.put("source_assignment_models", %{
        setup.assignment.id => selected_source,
        alternate.assignment.id => alternate_source
      })

    model =
      setup.model
      |> Ecto.Changeset.change(%{source_assignment_count: 2, metadata: metadata})
      |> Repo.update!()

    {:ok, selected_canonical} = CanonicalModelSource.canonical_source(selected_source)
    {:ok, alternate_canonical} = CanonicalModelSource.canonical_source(alternate_source)

    {%{setup | model: model}, alternate,
     %{
       selected_digest: selected_canonical.digest,
       alternate_digest: alternate_canonical.digest
     }}
  end

  defp issue_231_completed_response(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "status" => "completed",
           "model" => "provider-gpt-test-model",
           "service_tier" => "priority",
           "output" => [],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
         }
       }}
    ])
  end

  defp assert_issue_231_successful_accounting!(setup, alternate, source_endpoint) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.pool_id == setup.pool.id
    assert request.api_key_id == setup.api_key.id
    assert request.model_id == setup.model.id
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert_issue_231_origin_metadata!(request, source_endpoint)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.pool_upstream_assignment_id == alternate.assignment.id
    assert attempt.upstream_identity_id == alternate.identity.id
    assert attempt.model_id == setup.model.id

    assert_issue_231_private_metadata!(
      {request.request_metadata, attempt.response_metadata, RequestLogs.list(setup.pool)},
      setup
    )
  end

  defp assert_issue_231_origin_metadata!(request, source_endpoint) do
    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "openai_v1"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             source_endpoint

    assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
             "/backend-api/codex/responses"
  end

  defp assert_issue_231_private_metadata!(metadata, setup) do
    metadata_text = inspect(metadata)
    refute metadata_text =~ "issue-231-private-"
    refute metadata_text =~ "supported_reasoning_levels"
    refute metadata_text =~ "default_reasoning_level"
    refute metadata_text =~ "default_service_tier"
    refute metadata_text =~ "used_percent"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token-issue-231"
  end

  defp setup_runtime_ingress_override(%OperationalSettings{} = settings) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp overloaded_bulkhead_settings(queue_limit \\ 0, queue_timeout_ms \\ 25) do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class,
           %{max_concurrency: 1, queue_limit: queue_limit, queue_timeout_ms: queue_timeout_ms}}
        end)
    }
  end
end