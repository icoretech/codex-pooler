defmodule CodexPoolerWeb.V1.ResponsesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      await_public_websocket_upgrade: 2,
      gateway_setup: 1,
      gateway_setup: 2,
      gateway_upstream: 4,
      mint_websocket_new!: 4,
      pricing_config: 1,
      pricing_snapshot!: 2,
      prime_routing_quota!: 1,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      put_model_source_assignments!: 2,
      register_unboxed_pool_cleanup!: 1,
      assert_pre_first_stream_idle_timeout!: 1,
      start_public_endpoint!: 0,
      start_upstream: 1,
      unboxed_run: 1,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, DailyRollup, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody

  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, SessionContinuity}

  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.PublicGatewayResult
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000
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
      start_upstream(public_websocket_completed_response("resp_v1_websocket_public"))

    setup = gateway_setup(upstream)
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
               "response" => %{"id" => "resp_v1_websocket_public"}
             } = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true

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
  test "GET /v1/responses websocket coerces public opencode replay frames before dispatch" do
    upstream =
      start_upstream(public_websocket_completed_response("resp_v1_websocket_opencode_replay"))

    setup = gateway_setup(upstream)
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
              "id" => "msg_v1_ws_opencode_assistant",
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
              "arguments" => "{\"value\":\"sample\"}"
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
        from r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
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
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_non_stream",
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

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 response",
        "reasoning" => %{"effort" => "focused"}
      })

    assert %{"id" => "resp_v1_non_stream", "object" => "response"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

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
  end

  test "POST /v1/responses compresses eligible translated tool output before dispatch",
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
    omitted_sentinel = "v1 translated omitted sentinel"
    original_output = compression_log_fixture(omitted_sentinel)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_v1_compressed_tool_output",
            "content" => original_output
          }
        ]
      })

    assert %{"id" => "resp_v1_compressed_tool_output"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    translated_item = List.first(captured.json["input"])
    assert translated_item["type"] == "function_call_output"
    assert translated_item["call_id"] == "call_v1_compressed_tool_output"

    compressed_output = translated_item["output"]
    assert compressed_output != original_output
    assert compressed_output =~ "[compressed log output: omitted"
    refute compressed_output =~ omitted_sentinel

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
             "skipped_count" => 0
           } = metadata = attempt.response_metadata["payload_compression"]

    assert "log_output" in metadata["strategies"]
    assert metadata["original_bytes"] > metadata["compressed_bytes"]
    assert metadata["original_tokens"] > metadata["compressed_tokens"]
    refute inspect(metadata) =~ omitted_sentinel
    refute inspect(metadata) =~ "call_v1_compressed_tool_output"
  end

  test "POST /v1/responses streaming settles retained terminal usage and pricing", %{
    conn: conn
  } do
    padding_unit = "retained terminal padding "

    retained_padding =
      String.duplicate(
        padding_unit,
        div(RetainedBody.max_bytes(), byte_size(padding_unit)) + 128
      )

    terminal_payload =
      IO.iodata_to_binary([
        ~s({"type":"response.completed","response":{"id":"resp_v1_retained_usage_terminal","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":),
        Jason.encode!(retained_padding),
        ~s(}]}],"usage":{"input_tokens":16,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"reasoning_tokens":0,"total_tokens":21},"service_tier":"flex"}})
      ])

    terminal_event = "event: response.completed\ndata: " <> terminal_payload <> "\n\n"
    assert byte_size(terminal_event) > RetainedBody.max_bytes()

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
          terminal_event
        ])
      )

    setup = gateway_setup(upstream)

    flex_pricing =
      pricing_snapshot!(setup.model, %{
        config: pricing_config(%{"service_tier" => "flex"}),
        input_token_micros: Decimal.new(25),
        output_token_micros: Decimal.new(50)
      })

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic retained usage stream request",
        "service_tier" => "auto",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "resp_v1_retained_usage_progress"
    assert conn.resp_body =~ "resp_v1_retained_usage_terminal"

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
    assert attempt.usage_status == "usage_known"

    settlement =
      Repo.get_by!(LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 16
    assert settlement.cached_input_tokens == nil
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

  @tag :tool_result_previous_response
  test "POST /v1/responses forwards namespace tools unchanged", %{conn: conn} do
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
    assert captured.json["tools"] == [namespace_tool]

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

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic summary"
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
            "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}],
            "encrypted_content" => "synthetic-encrypted-reasoning"
          },
          %{
            "role" => "assistant",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "synthetic assistant replay"}]
          },
          %{
            "type" => "function_call",
            "call_id" => "call_v1_http_replay",
            "name" => "lookup_fixture",
            "arguments" => "{\"value\":\"sample\"}"
          },
          %{
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

    assert Enum.map(captured.json["input"], & &1["type"]) == [
             "message",
             "message",
             "function_call",
             "function_call_output"
           ]

    refute inspect(captured.json["input"]) =~ "synthetic-encrypted-reasoning"
    assert %{"role" => "assistant", "phase" => "commentary"} = Enum.at(captured.json["input"], 1)

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
        from r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
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
                 from session in CodexSession,
                   where:
                     session.pool_id == ^setup.pool.id and
                       fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
                       session.status in ["active", "interrupted"]
               )
             end)

    requests =
      unboxed_run(fn ->
        Repo.all(
          from request in Request,
            where: request.pool_id == ^setup.pool.id,
            order_by: [asc: request.admitted_at]
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
    refute Map.has_key?(captured_headers, "cookie")
    refute Map.has_key?(captured_headers, "idempotency-key")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
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
  test "POST /v1/responses streaming emits public Responses SSE and filters codex events", %{
    conn: conn
  } do
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
        "input" => "synthetic stream request",
        "stream" => true
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

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
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

    {:ok, http_conn, ref, started} =
      start_public_v1_responses_request(port, setup, %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic timeout stream request",
        "stream" => true
      })

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref},
                   @timing_observation_timeout_ms

    logs =
      capture_log([level: :warning], fn ->
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
  test "GET /v1/responses websocket reports idle timeout after visible output" do
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
             } = Jason.decode!(terminal_frame)

      assert total_elapsed_ms >= 150

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "failed"
      assert request.last_error_code == "stream_idle_timeout"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "failed"
      assert attempt.network_error_code == "stream_idle_timeout"

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

    setup = gateway_setup(upstream)

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
      {%{"type" => "input_image", "file_id" => "file_image_fixture"},
       "unsupported_input_image_format"},
      {%{"type" => "input_image", "image_url" => "file:///tmp/private.png"},
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

    conn =
      conn
      |> auth(setup)
      |> with_public_metadata_headers()
      |> post("/v1/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic compact request"
      })

    assert %{"error" => error} = json_response(conn, 404)
    assert error["code"] == "unsupported_endpoint"
    assert error["message"] == "Unsupported OpenAI /v1 endpoint"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
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
    Process.send_after(self(), {:task_11_silent_gap_elapsed, make_ref()}, gap_ms)

    receive do
      {:task_11_silent_gap_elapsed, _ref} -> elapsed_ms(started)
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

  defp structured_tool_result_output do
    %{
      "command" => "TASK7_RAW_TOOL_COMMAND_SENTINEL run private command",
      "exit_code" => 0,
      "files" => [
        %{
          "path" => "sample-output.txt",
          "content" => "TASK7_RAW_TOOL_OUTPUT_SENTINEL\n" <> String.duplicate("line\n", 200)
        }
      ],
      "nested" => %{
        "list" => [
          %{"stdout_preview" => String.duplicate("TASK7_LONG_NESTED_VALUE_", 40)},
          %{"secret_like" => "TASK7_SECRET_LIKE_TOOL_SENTINEL"}
        ],
        "ok" => true
      }
    }
  end

  defp structured_tool_result_sentinels do
    [
      "TASK7_RAW_TOOL_COMMAND_SENTINEL",
      "TASK7_RAW_TOOL_OUTPUT_SENTINEL",
      "TASK7_LONG_NESTED_VALUE_",
      "TASK7_SECRET_LIKE_TOOL_SENTINEL"
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
end
