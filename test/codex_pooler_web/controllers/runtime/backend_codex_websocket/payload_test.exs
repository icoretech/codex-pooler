defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.PayloadTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.AgentV2ContractFixture
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo

  @websocket_frame_timeout 1_000
  @large_websocket_frame_timeout 5_000
  @reasoning_denial_message "reasoning effort is not available for this API key"

  test "native websocket preserves trusted cyber metadata only in the provider event" do
    trusted_access_sentinel = "trusted-cyber-provider-event-only"

    hostile = %{
      authorization: "hostile-authorization-sentinel",
      cookie: "hostile-cookie-sentinel",
      provider_etag: "hostile-provider-etag-sentinel",
      quota: "hostile-quota-sentinel",
      rate_limit: "hostile-rate-limit-sentinel",
      reasoning: "hostile-reasoning-control-sentinel",
      request_id: "hostile-request-id-sentinel",
      safety: "hostile-safety-control-sentinel",
      unknown: "hostile-unknown-header-sentinel"
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "headers" => %{
                 "authorization" => hostile.authorization,
                 "cookie" => hostile.cookie,
                 "etag" => hostile.provider_etag,
                 "x-codex-primary-used-percent" => hostile.quota,
                 "x-codex-rate-limit-reached-type" => hostile.rate_limit,
                 "x-codex-safety-buffering-enabled" => hostile.safety,
                 "x-reasoning-included" => hostile.reasoning,
                 "x-request-id" => hostile.request_id,
                 "x-unknown-header" => hostile.unknown
               },
               "response" => %{
                 "id" => "resp_ws_trusted_cyber_metadata",
                 "status" => "completed",
                 "metadata" => %{
                   "trusted_access_for_cyber" => trusted_access_sentinel
                 },
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          headers: [
            {"set-cookie", hostile.cookie},
            {"authorization", hostile.authorization},
            {"x-request-id", hostile.request_id},
            {"etag", hostile.provider_etag},
            {"x-codex-primary-used-percent", hostile.quota},
            {"x-codex-rate-limit-reached-type", hostile.rate_limit},
            {"x-unknown-header", hostile.unknown},
            {"x-reasoning-included", hostile.reasoning},
            {"x-codex-safety-buffering-enabled", hostile.safety}
          ]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {result, logs} =
      with_log(fn ->
        execute_websocket_response(
          auth,
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("synthetic trusted cyber metadata request"),
            "stream" => true,
            "generate" => true
          }),
          %{request_id: "ws-trusted-cyber-metadata", capture_metadata_control?: true},
          fn frame -> send(self(), {:websocket_frame, frame}) end
        )
      end)

    assert result == :ok

    assert_received {:websocket_frame, metadata_frame}

    assert %{
             "type" => "codex.response.metadata",
             "headers" => %{"x-models-etag" => models_etag}
           } = CodexPooler.JSON.decode!(metadata_frame)

    assert String.starts_with?(models_etag, ~s(W/"cp-models-v1-))
    assert_received {:websocket_frame, provider_frame}

    assert %{
             "type" => "response.completed",
             "headers" => %{
               "x-codex-safety-buffering-enabled" => "true",
               "x-reasoning-included" => "true"
             },
             "response" => %{
               "metadata" => %{"trusted_access_for_cyber" => ^trusted_access_sentinel}
             }
           } = CodexPooler.JSON.decode!(provider_frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert request.status == "succeeded"
    assert attempt.status == "succeeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    audit_events = Repo.all(from(e in AuditEvent))
    request_logs = RequestLogs.list(setup.pool.id, limit: 10)
    sessions = Repo.all(from(s in CodexSession))
    turns = Repo.all(from(t in CodexTurn))

    durable_text =
      inspect({request, attempt, sessions, turns, audit_events, request_logs.items}) <> logs

    refute metadata_frame =~ trusted_access_sentinel
    refute durable_text =~ trusted_access_sentinel

    for hostile_value <- Map.values(hostile) do
      refute metadata_frame =~ hostile_value
      refute provider_frame =~ hostile_value
      refute durable_text =~ hostile_value
    end
  end

  @tag :prompt_cache_adaptation
  test "GET /backend-api/codex/responses adapts prompt cache controls in a response.create frame" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_public_ws_route",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "public-ws-route-#{System.unique_integer([:positive])}"

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "prompt_cache_key" => "backend-websocket-cache-key",
          "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"},
          "input" => [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [
                %{
                  "type" => "input_text",
                  "text" => "backend websocket prompt cache content",
                  "prompt_cache_breakpoint" => %{"mode" => "explicit"}
                }
              ]
            }
          ],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_public_ws_route"} = CodexPooler.JSON.decode!(frame)

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"request_id" => request_id, "status" => "succeeded"}
                      }},
                     @websocket_frame_timeout

      request = Repo.get!(Request, request_id)
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.response_metadata["prompt_cache_controls_downgraded"] == true
      refute Map.has_key?(request.request_metadata, "prompt_cache_controls_downgraded")

      upstream_websocket_connection = attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id} = upstream_websocket_connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

      assert upstream_websocket_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 1,
               "reused" => false,
               "reconnected" => false
             }

      assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)
      assert is_reference(connection_id)

      assert [settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 )
               )

      assert settlement.request_id == request.id

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["prompt_cache_key"] == "backend-websocket-cache-key"
      refute Map.has_key?(captured.json, "prompt_cache_options")
      refute inspect(captured.json) =~ "prompt_cache_breakpoint"
      refute inspect({request.request_metadata, captured.json}) =~ setup.authorization

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "backend websocket canonicalizes fast and preserves the provider response frame" do
    provider_payload = %{
      "id" => "resp_backend_ws_fast_tier",
      "object" => "response",
      "service_tier" => "fast",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
    }

    upstream = start_upstream(FakeUpstream.json_response(provider_payload))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "service_tiers" => [%{"id" => "priority", "name" => "Priority"}]
          }
        }
      )

    port = start_public_endpoint!()
    turn_state = "ws-fast-tier-#{System.unique_integer([:positive])}"
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "service_tier" => "fast",
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert frame == CodexPooler.JSON.encode!(provider_payload)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["service_tier"] == "priority"

      assert Map.new(captured.headers)["x-codex-routing-hint"] ==
               "model=#{setup.model.upstream_model_id};tier=priority"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "backend websocket preserves namespace tools and lowers ordinary functions" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_namespace_tools",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    turn_state = "ws-namespace-tools-#{System.unique_integer([:positive])}"
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    namespace_tool = backend_namespace_tool()

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic namespace request"),
          "tools" => [namespace_tool, backend_ordinary_function_tool()],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_ws_namespace_tools"} = CodexPooler.JSON.decode!(frame)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert Enum.at(captured.json["tools"], 0) == namespace_tool

      assert captured.json["tools"] |> Enum.at(1) |> Map.fetch!("parameters") ==
               lowered_backend_function_schema()

      assert Enum.at(captured.json["tools"], 1)["encrypted"]

      assert [request] = await_succeeded_pool_requests!(setup.pool.id, 1)
      assert request.status == "succeeded"
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /backend-api/codex/responses ignores prompt-cache routing input from websocket frames" do
    primary_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_public_ws_prompt_cache_primary",
          "object" => "response",
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    alternate_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_public_ws_prompt_cache_alternate",
          "object" => "response",
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(primary_upstream)

    alternate =
      gateway_upstream(setup.pool, alternate_upstream, "upstream-token-ws-prompt-cache-alternate",
        compact?: false
      )

    prime_routing_quota!(alternate.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, alternate.assignment])
      )

    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "public-ws-prompt-cache-#{System.unique_integer([:positive])}"
    raw_prompt_cache_key = "raw-ws-prompt-cache-routing-key-do-not-log"

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{"type" => "message", "role" => "user", "content" => "websocket prompt cache"}
          ],
          "prompt_cache_key" => raw_prompt_cache_key,
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert CodexPooler.JSON.decode!(frame)["id"] in [
               "resp_public_ws_prompt_cache_primary",
               "resp_public_ws_prompt_cache_alternate"
             ]

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"request_id" => request_id, "status" => "succeeded"}
                      }},
                     @websocket_frame_timeout

      request = Repo.get!(Request, request_id)
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      routing = request.request_metadata["routing"]
      assert routing["strategy"] == "bridge_ring"
      assert routing["routing_locality_status"] == "unavailable"
      assert routing["routing_locality_applied"] == false
      assert routing["routing_locality_unhonored_reason"] == "prompt_cache_key_absent"
      refute Map.has_key?(routing, "routing_locality_seed_fingerprint")
      refute Map.has_key?(routing, "routing_locality_assignment_fingerprint")

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.transport == "websocket"
      assert attempt.status == "succeeded"

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ raw_prompt_cache_key
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
      refute metadata_text =~ "Bearer "
      refute metadata_text =~ "upstream-token"
      refute metadata_text =~ "cache_hit"
      refute metadata_text =~ "provider_cache"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :issue_78
  test "GET /backend-api/codex/responses preserves a strict array-root schema" do
    assert_native_strict_array_root_preserved!(
      "/backend-api/codex/responses",
      "resp_native_ws_strict_array_direct"
    )
  end

  @tag :issue_78
  test "GET /backend-api/codex/v1/responses preserves a strict array-root schema" do
    assert_native_strict_array_root_preserved!(
      "/backend-api/codex/v1/responses",
      "resp_native_ws_strict_array_v1_alias"
    )
  end

  @tag :issue_78
  test "GET /backend-api/codex/responses preserves a strict local root-ref schema" do
    assert_native_strict_local_root_ref_preserved!(
      "/backend-api/codex/responses",
      "resp_native_ws_strict_root_ref_direct"
    )
  end

  @tag :issue_78
  test "GET /backend-api/codex/v1/responses preserves a strict local root-ref schema" do
    assert_native_strict_local_root_ref_preserved!(
      "/backend-api/codex/v1/responses",
      "resp_native_ws_strict_root_ref_v1_alias"
    )
  end

  test "backend websocket routes resolve reasoning policy after upgrade" do
    cases = [
      {"/backend-api/codex/responses", [maximum_reasoning_effort: "medium"], %{}, "medium"},
      {"/backend-api/codex/v1/responses", [maximum_reasoning_effort: "high"],
       %{"reasoning_effort" => "low"}, "low"},
      {"/backend-api/codex/responses", [enforced_reasoning_effort: "high"],
       %{"reasoningEffort" => "low"}, "high"},
      {"/backend-api/codex/v1/responses", [], %{"reasoning_effort" => "focused"}, "focused"}
    ]

    for {path, policy, effort_payload, expected_effort} <- cases do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_reasoning_policy",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)
      assert :ok = Events.subscribe_pool(setup.pool)

      setup.api_key
      |> Ecto.Changeset.change(policy)
      |> Repo.update!()

      port = start_public_endpoint!()
      turn_state = "ws-reasoning-policy-#{System.unique_integer([:positive])}"
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state, path)

      try do
        payload =
          %{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("synthetic websocket policy request"),
            "stream" => true,
            "generate" => true
          }
          |> Map.merge(effort_payload)
          |> CodexPooler.JSON.encode!()

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{"id" => "resp_ws_reasoning_policy"} = CodexPooler.JSON.decode!(frame)
        assert [captured] = FakeUpstream.requests(upstream)
        assert get_in(captured.json, ["reasoning", "effort"]) == expected_effort

        assert_receive {Events,
                        %{
                          reason: "request_finalized",
                          payload: %{"request_id" => request_id, "status" => "succeeded"}
                        }},
                       @websocket_frame_timeout

        request = Repo.get!(Request, request_id)
        assert request.status == "succeeded"
        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

        assert get_in(attempt.response_metadata, ["reasoning", "applied_effort"]) ==
                 expected_effort

        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "backend websocket routes deny unavailable reasoning after upgrade without reservation" do
    cases = [
      {"/backend-api/codex/responses", %{"reasoning_effort" => "high"}, "high"},
      {"/backend-api/codex/v1/responses", %{"reasoningEffort" => "custom-effort"}, "unknown"}
    ]

    for {path, effort_payload, persisted_effort} <- cases do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream)

      setup.api_key
      |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
      |> Repo.update!()

      port = start_public_endpoint!()
      turn_state = "ws-reasoning-denial-#{System.unique_integer([:positive])}"
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state, path)

      try do
        {_updated_conn, logs} =
          capture_native_turn_warning(fn ->
            payload =
              %{
                "type" => "response.create",
                "model" => setup.model.exposed_model_id,
                "input" => native_text_input("synthetic websocket policy denial"),
                "stream" => true,
                "generate" => true
              }
              |> Map.merge(effort_payload)
              |> CodexPooler.JSON.encode!()

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
                   } = CodexPooler.JSON.decode!(frame)

            assert FakeUpstream.count(upstream) == 0
            assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
            assert request.status == "rejected"

            assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) ==
                     0

            assert Repo.aggregate(
                     from(l in LedgerEntry, where: l.request_id == ^request.id),
                     :count
                   ) ==
                     0

            assert get_in(request.request_metadata, ["gateway_denial", "reasoning_policy"]) == %{
                     "policy_mode" => "allow_up_to",
                     "configured_effort" => "medium",
                     "requested_effort" => persisted_effort,
                     "applied_effort" => nil
                   }

            conn
          end)

        assert_native_turn_warnings(logs, 1)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "websocket response.create rewrites ultra to the highest catalog level when the model lacks max" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_ultra_catalog",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{"supported_reasoning_levels" => ~w(low medium high xhigh)}
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-ultra-catalog"})

    result =
      execute_websocket_response(
        auth,
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "store" => false,
          "stream" => true,
          "reasoning" => %{"effort" => "ultra"}
        }),
        %{request_id: "ws-ultra-catalog", codex_session: session},
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_receive {:websocket_frame, _completed_frame}, @websocket_frame_timeout

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.json["reasoning"]["effort"] == "xhigh"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert get_in(attempt.response_metadata, ["reasoning", "rewrite"]) == "ultra_to_xhigh"
  end

  @tag :websocket_response_create_envelope
  test "websocket response.create envelopes are unwrapped and SSE events are pushed as websocket messages" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_sse",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
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

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-envelope"})

    result =
      execute_websocket_response(
        auth,
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{"type" => "message", "role" => "user", "content" => "hello"},
            %{
              "type" => "agent_message",
              "author" => "root",
              "recipient" => "worker",
              "content" => [
                %{
                  "type" => "encrypted_content",
                  "encrypted_content" => "sample-agent-encrypted-content"
                }
              ]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => nil,
              "encrypted_content" => "sample-encrypted-content"
            }
          ],
          "tools" => [],
          "tool_choice" => "auto",
          "parallel_tool_calls" => true,
          "store" => false,
          "stream" => true,
          "include" => [
            "reasoning.encrypted_content",
            "reasoning.encrypted_content"
          ],
          "reasoning" => %{
            "effort" => "high",
            "summary" => "auto",
            "context" => "selected"
          },
          "generate" => true
        }),
        %{request_id: "ws-envelope", codex_session: session},
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_receive {:websocket_frame, completed_frame}, @websocket_frame_timeout

    assert %{"id" => "resp_ws_sse"} = CodexPooler.JSON.decode!(completed_frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.json["type"] == "response.create"
    assert captured.json["generate"] == true
    refute Map.has_key?(captured.json, "previous_response_id")
    assert captured.json["instructions"] == ""

    assert captured.json["reasoning"] == %{
             "effort" => "high",
             "context" => "selected"
           }

    assert captured.json["include"] == ["reasoning.encrypted_content"]

    assert captured.json["input"] == [
             %{"type" => "message", "role" => "user", "content" => "hello"},
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => nil,
               "encrypted_content" => "sample-encrypted-content"
             }
           ]

    assert captured.json["stream"] == true
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
  end

  test "websocket response.create preserves canonical v2 encrypted handoffs before upstream dispatch" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_mixed_agent_message",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-mixed-agent-message"})

    canonical_handoff = AgentV2ContractFixture.handoff!(:spawn_agent)

    raw_agent_encrypted_content =
      canonical_handoff
      |> Map.fetch!("content")
      |> Enum.at(1)
      |> Map.fetch!("encrypted_content")

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "hello"},
                   canonical_handoff,
                   %{
                     "type" => "message",
                     "role" => "assistant",
                     "content" => nil,
                     "encrypted_content" => "sample-assistant-encrypted-replay"
                   },
                   %{
                     "type" => "agent_message",
                     "author" => "root",
                     "recipient" => "worker",
                     "content" => [
                       %{"type" => "input_text", "text" => "clear agent message"}
                     ]
                   }
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-mixed-agent-message", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
    assert %{"id" => "resp_ws_mixed_agent_message"} = CodexPooler.JSON.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.json["type"] == "response.create"

    assert Enum.map(captured.json["input"], &Map.fetch!(&1, "type")) == [
             "message",
             "agent_message",
             "message",
             "agent_message"
           ]

    assert Enum.at(captured.json["input"], 1) == canonical_handoff

    assert captured.json["input"] |> Enum.at(2) |> Map.fetch!("encrypted_content")

    assert captured.json["input"]
           |> Enum.at(3)
           |> Map.fetch!("content")
           |> Enum.at(0)
           |> Map.fetch!("type") ==
             "input_text"

    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ raw_agent_encrypted_content
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
  end

  @tag :websocket_response_create_image_payload
  test "websocket response.create preserves input_image payloads end to end" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          "event: response.created\r\ndata: #{CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_ws_image"}})}\r\n\r\n",
          "event: response.completed\r\ndata: #{CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_ws_image", "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}})}\r\n\r\n"
        ])
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text", "image"],
          "supports_image_detail_original" => true
        }
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-image-payload"})

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "describe this image"},
          %{
            "type" => "input_image",
            "image_url" => "https://example.com/test-image.png",
            "detail" => "high"
          }
        ]
      }
    ]

    result =
      execute_websocket_response(
        auth,
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => input,
          "stream" => true,
          "generate" => true
        }),
        %{request_id: "ws-image-payload", codex_session: session},
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_receive {:websocket_frame, created_frame}, @websocket_frame_timeout
    assert_receive {:websocket_frame, completed_frame}, @websocket_frame_timeout
    assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created_frame)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed_frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["type"] == "response.create"
    assert captured.json["input"] == input
  end

  test "websocket response.create preserves input_image file_id references" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_file_id"}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text", "image"],
          "supports_image_detail_original" => true
        }
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    file_id = "file_ws_reference"

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{
                     "type" => "message",
                     "role" => "user",
                     "content" => [
                       %{"type" => "input_text", "text" => "describe this image"},
                       %{"type" => "input_image", "file_id" => file_id}
                     ]
                   }
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-file-id"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"

    assert [
             %{
               "content" => [
                 %{"type" => "input_text"},
                 %{"type" => "input_image", "file_id" => ^file_id}
               ]
             }
           ] = captured.json["input"]
  end

  @tag :websocket_large_completion_frame
  test "websocket streaming preserves large terminal response completed payloads" do
    completed_payload = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_ws_large_completed",
        "metadata" => %{"padding" => String.duplicate("x", 17_000)},
        "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
      }
    }

    completed_event =
      "event: response.completed\ndata: #{CodexPooler.JSON.encode!(completed_payload)}\n\n"

    {completed_prefix, completed_suffix} = String.split_at(completed_event, 17_000)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          "event: response.created\ndata: #{CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_ws_large_completed"}})}\n\n",
          completed_prefix,
          completed_suffix
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-large-completed"})

    parent = self()

    result =
      execute_websocket_response(
        auth,
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        }),
        %{request_id: "ws-large-completed", codex_session: session},
        fn frame -> send(parent, {:websocket_frame, frame}) end
      )

    assert result == :ok

    # The completed event is intentionally split around a large payload; this
    # regression only needs the recomposed terminal frame. Non-terminal frame
    # forwarding is covered by the adjacent websocket streaming tests.
    frames =
      receive_websocket_frames_by_type(
        ["response.completed"],
        @large_websocket_frame_timeout
      )

    assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_large_completed"}} =
             frames["response.completed"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
  end

  test "websocket stream conversion preserves response completed events split across SSE chunks" do
    created_event =
      "event: response.created\ndata: #{CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_ws_split_sse_completed"}})}\n\n"

    completed_payload = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_ws_split_sse_completed",
        "metadata" => %{"padding" => String.duplicate("x", 17_000)},
        "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
      }
    }

    completed_event =
      "event: response.completed\ndata: #{CodexPooler.JSON.encode!(completed_payload)}\n\n"

    completed_prefix = String.slice(completed_event, 0, 24)
    completed_middle = String.slice(completed_event, 24, 17_000)
    completed_suffix = String.slice(completed_event, 17_024..-1//1)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          created_event,
          completed_prefix,
          completed_middle,
          completed_suffix
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    parent = self()

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
                   request_id: "ws-split-sse-conversion",
                   upstream_endpoint: "/backend-api/codex/responses",
                   websocket_writer: fn frame -> send(parent, {:websocket_frame, frame}) end
                 },
                 "/backend-api/codex/responses",
                 payload
               )
             )

    assert :ok = stream.()

    frames =
      receive_websocket_frames_by_type(
        ["response.created", "response.completed"],
        @large_websocket_frame_timeout
      )

    assert %{"type" => "response.created", "response" => %{"id" => "resp_ws_split_sse_completed"}} =
             frames["response.created"]

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => "resp_ws_split_sse_completed"}
           } =
             frames["response.completed"]

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/responses"
  end

  defp assert_native_strict_array_root_preserved!(path, response_id) do
    strict_array_schema = %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"],
        "additionalProperties" => false
      }
    }

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => response_id,
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "native-strict-array-#{System.unique_integer([:positive])}",
        path
      )

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic native strict array request"),
          "text" => %{
            "format" => %{
              "type" => "json_schema",
              "name" => "native_strict_array_fixture",
              "strict" => true,
              "schema" => strict_array_schema
            }
          },
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => ^response_id} = CodexPooler.JSON.decode!(frame)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert get_in(captured.json, ["text", "format", "schema"]) == strict_array_schema
      assert FakeUpstream.count(upstream) == 1

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  defp assert_native_strict_local_root_ref_preserved!(path, response_id) do
    strict_local_root_ref_schema = %{
      "$ref" => "#/$defs/root",
      "$defs" => %{
        "root" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"],
          "additionalProperties" => false
        }
      }
    }

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => response_id,
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "native-strict-root-ref-#{System.unique_integer([:positive])}",
        path
      )

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic native strict root-ref request"),
          "text" => %{
            "format" => %{
              "type" => "json_schema",
              "name" => "native_strict_root_ref_fixture",
              "strict" => true,
              "schema" => strict_local_root_ref_schema
            }
          },
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => ^response_id} = CodexPooler.JSON.decode!(frame)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"

      assert get_in(captured.json, ["text", "format", "schema"]) ==
               strict_local_root_ref_schema

      assert FakeUpstream.count(upstream) == 1

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  defp backend_namespace_tool do
    %{
      "type" => "namespace",
      "name" => "fixture_namespace",
      "description" => "Synthetic namespace tools",
      "encrypted" => true,
      "unknown_namespace_key" => %{"encrypted" => true, "preserve" => [1, nil, false]},
      "tools" => [
        %{
          "type" => "function",
          "name" => "namespaced_lookup",
          "strict" => false,
          "encrypted" => true,
          "parameters" => backend_function_schema(),
          "unknown_function_key" => %{"encrypted" => true}
        },
        %{
          "type" => "namespace",
          "name" => "nested_namespace",
          "tools" => [%{"type" => "future_tool", "encrypted" => true}],
          "unknown_nested_key" => true
        }
      ]
    }
  end

  defp backend_ordinary_function_tool do
    %{
      "type" => "function",
      "name" => "ordinary_lookup",
      "strict" => false,
      "encrypted" => true,
      "parameters" => backend_function_schema()
    }
  end

  defp backend_function_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "properties" => %{
        "mode" => %{"const" => "fast", "title" => "drop me", "encrypted" => true},
        "nested" => %{
          "properties" => %{"value" => %{"type" => "string", "encrypted" => true}},
          "required" => ["value"],
          "encrypted" => true
        }
      },
      "required" => ["mode"],
      "additionalProperties" => false,
      "encrypted" => true
    }
  end

  defp lowered_backend_function_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"enum" => ["fast"]},
        "nested" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        }
      },
      "required" => ["mode"],
      "additionalProperties" => false
    }
  end
end
