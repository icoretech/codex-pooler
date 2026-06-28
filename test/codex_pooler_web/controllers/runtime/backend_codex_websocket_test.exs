defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000
  @large_websocket_frame_timeout 5_000

  @websocket_lifecycle_metadata_keys ~w(
    codex_session_id
    downstream_epoch
    elapsed_ms
    endpoint
    owner_instance_id
    phase
    proxy_instance_id
    reason_class
    request_id
    route_class
    transport
  )

  @websocket_lifecycle_forbidden_terms ~w(
    auth.json
    authorization
    bearer
    cookie
    header
    idempotency
    payload
    prompt
    upstream_body
    websocket_frame
    init-failure-secret-sentinel
    init-cookie-secret
    init-idempotency-secret
    init-prompt-sentinel
  )

  test "GET /backend-api/codex/responses requires websocket upgrade", %{conn: conn} do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    conn = conn |> auth(setup) |> get("/backend-api/codex/responses")

    assert json_response(conn, 400)["error"]["code"] == "websocket_upgrade_required"
  end

  test "GET /backend-api/codex/responses replaces whitespace-only websocket turn state" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    port = start_public_endpoint!()

    {conn, _websocket, _ref, response_headers} =
      public_websocket_connect_with_headers!(port, setup, "   ")

    try do
      assert {"x-codex-turn-state", turn_state} =
               List.keyfind(response_headers, "x-codex-turn-state", 0)

      assert {:ok, ^turn_state} = Ecto.UUID.cast(turn_state)
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /backend-api/codex/responses upgrades and dispatches through the public websocket route" do
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
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_public_ws_route"} = Jason.decode!(frame)

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

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      refute inspect({request.request_metadata, captured.json}) =~ setup.authorization

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
        Jason.encode!(%{
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

      assert Jason.decode!(frame)["id"] in [
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

  test "GET /backend-api/codex/v1/responses upgrades through the websocket alias route" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_public_ws_v1_alias_route",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "public-ws-v1-alias-route-#{System.unique_integer([:positive])}"

    {conn, websocket, ref} =
      public_websocket_connect!(port, setup, turn_state, "/backend-api/codex/v1/responses")

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

      assert %{"id" => "resp_public_ws_v1_alias_route"} = Jason.decode!(frame)

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

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "socket init failure before request reservation logs one bounded warning and creates no request row" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-init-failure-#{System.unique_integer([:positive])}"

    request_options =
      %{
        request_id: request_id,
        client_ip: "127.0.0.1",
        previous_response_id: "resp_missing_init_failure",
        authorization_header: "Bearer init-failure-secret-sentinel",
        idempotency_key: "init-idempotency-secret",
        forwarded_headers: [{"cookie", "init-cookie-secret"}]
      }
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_continuity(authenticated_owner_attach: true)

    logs =
      capture_websocket_lifecycle_log(:warning, fn ->
        assert {:stop, :normal, {1011, "websocket owner is unavailable"}, returned_state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: request_options,
                   raw_frame: "init-prompt-sentinel"
                 })

        assert returned_state.opts.request_metadata.request_id == request_id
        refute Map.has_key?(returned_state, :request_response_work_started?)
        refute Map.has_key?(returned_state, :connection_started_at_monotonic_ms)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.init_failed_message(),
        ~w(elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(codex_session_id downstream_epoch owner_instance_id proxy_instance_id)
      )

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=init"
    assert line =~ "reason_class=owner_unavailable"
    assert line =~ "elapsed_ms="

    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)
    assert FakeUpstream.count(upstream) == 0
  end

  test "socket init lifecycle warning does not cover controller auth or upgrade errors", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    auth_logs =
      capture_websocket_lifecycle_log(:warning, fn ->
        conn = get(conn, "/backend-api/codex/responses")
        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end)

    refute auth_logs =~ WebsocketConnectionLogger.init_failed_message()

    upgrade_logs =
      capture_websocket_lifecycle_log(:warning, fn ->
        conn =
          Phoenix.ConnTest.build_conn()
          |> auth(setup)
          |> get("/backend-api/codex/responses")

        assert json_response(conn, 400)["error"]["code"] == "websocket_upgrade_required"
      end)

    refute upgrade_logs =~ WebsocketConnectionLogger.init_failed_message()
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert FakeUpstream.count(upstream) == 0
  end

  test "socket terminate anomalous close before request reservation logs one bounded line and creates no request row" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-pre-request-close-#{System.unique_integer([:positive])}"

    logs =
      capture_websocket_lifecycle_log(:info, fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts:
                     websocket_lifecycle_request_options(request_id,
                       authorization_header: "Bearer terminate-secret-sentinel",
                       idempotency_key: "terminate-idempotency-secret",
                       forwarded_headers: [{"cookie", "terminate-cookie-secret"}]
                     ),
                   raw_frame: "terminate-websocket-frame-sentinel"
                 })

        refute state.request_response_work_started?
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.closed_message(),
        ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(downstream_epoch owner_instance_id proxy_instance_id)
      )

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=terminate"
    assert line =~ "reason_class=closed"
    assert line =~ "codex_session_id="
    assert line =~ "elapsed_ms="

    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)
  end

  test "socket terminate clean pre-request closes stay quiet for normal and shutdown" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_websocket_lifecycle_log(:info, fn ->
        for reason <- [:normal, :shutdown] do
          request_id =
            "ws-clean-pre-request-close-#{reason}-#{System.unique_integer([:positive])}"

          assert {:ok, state} =
                   CodexResponsesSocket.init(%{
                     auth: auth,
                     opts: websocket_lifecycle_request_options(request_id)
                   })

          refute state.request_response_work_started?
          assert :ok = CodexResponsesSocket.terminate(reason, state)
        end
      end)

    refute logs =~ WebsocketConnectionLogger.closed_message()
    refute logs =~ WebsocketConnectionLogger.init_failed_message()
    assert_no_websocket_lifecycle_leaks!(logs)
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)
  end

  test "socket terminate after request work starts does not emit pre-request lifecycle line" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_post_work_close",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_websocket_lifecycle_log(:info, fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: websocket_lifecycle_request_options("ws-post-work-close")
                 })

        payload =
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
            "stream" => true,
            "generate" => true
          })

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        assert state.request_response_work_started?
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    refute logs =~ WebsocketConnectionLogger.closed_message()
    refute logs =~ WebsocketConnectionLogger.init_failed_message()
    assert_no_websocket_lifecycle_leaks!(logs)

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
  end

  @tag :websocket_session_success
  test "websocket response dispatch persists a succeeded session turn" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_backend",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-success"})

    result =
      execute_websocket_response(
        auth,
        Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => "hello over ws"}),
        %{
          request_id: "ws-request-#{System.unique_integer([:positive])}",
          client_ip: "127.0.0.1",
          codex_session: session
        },
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_backend"} = Jason.decode!(frame)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.request_id == request.id
    assert turn.status == "succeeded"
    assert turn.transport_kind == "websocket"
    assert turn.completed_at
    assert turn.first_visible_output_at

    session = Repo.get!(CodexSession, session.id)
    assert session.status == "active"
    assert session.pool_upstream_assignment_id == setup.assignment.id
  end

  test "websocket response dispatch accepts prebuilt typed request options" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_typed_options",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-typed-options"})

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "hello over typed ws",
      "stream" => true
    }

    options =
      %{request_id: "ws-typed-options", client_ip: "127.0.0.1", codex_session: session}
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.put_routing(quota_decision: %{"summary" => "prebuilt"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(payload),
               options,
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_typed_options"} = Jason.decode!(frame)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id
  end

  test "websocket dispatch ignores regular runtime forwarded metadata headers" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_forwarded_metadata_ignored",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-forwarded-metadata"})

    lineage_id = "ws-forwarded-metadata-lineage"
    lineage_metadata = Jason.encode!(%{"forked_from_thread_id" => lineage_id})

    forwarded_headers = [
      {"x-codex-turn-metadata", lineage_metadata},
      {"x-codex-window-id", "ws-forwarded-metadata-window"},
      {"x-codex-parent-thread-id", "ws-forwarded-metadata-parent"},
      {"x-codex-installation-id", "ws-forwarded-metadata-installation"},
      {"x-openai-subagent", "ws-forwarded-metadata-subagent"},
      {"x-codex-extra-websocket", "ws-forwarded-metadata-extra"}
    ]

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => "resp_ws_forwarded_metadata_previous"
               }),
               %{
                 request_id: "ws-forwarded-metadata-ignored",
                 client_ip: "127.0.0.1",
                 codex_session: session,
                 forwarded_headers: forwarded_headers
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_forwarded_metadata_ignored"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["type"] == "response.create"
    assert captured.json["generate"] == true
    assert captured.json["previous_response_id"] == "resp_ws_forwarded_metadata_previous"
    assert header!(captured.headers, "openai-beta") == "responses_websockets=2026-02-06"
    assert header!(captured.headers, "user-agent") == "codex_cli_rs/0.0.0"

    for {name, _value} <- forwarded_headers do
      refute Enum.any?(captured.headers, fn {header_name, _value} -> header_name == name end)
    end

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.status == "succeeded"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.request_id == request.id
    assert turn.status == "succeeded"
    assert turn.transport_kind == "websocket"

    persistence_text =
      inspect({request.request_metadata, attempt.response_metadata, session, turn})

    refute persistence_text =~ lineage_metadata
    refute persistence_text =~ lineage_id
    refute persistence_text =~ "ws-forwarded-metadata-window"
    refute persistence_text =~ "ws-forwarded-metadata-parent"
    refute persistence_text =~ "ws-forwarded-metadata-installation"
    refute persistence_text =~ "ws-forwarded-metadata-subagent"
    refute persistence_text =~ "ws-forwarded-metadata-extra"
    refute persistence_text =~ setup.authorization
  end

  @tag :client_metadata
  test "websocket dispatch preserves canonical turn metadata while adding Responses Lite marker" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_client_metadata_responses_lite",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup =
      upstream
      |> gateway_setup()
      |> put_setup_model_source_metadata!(%{"use_responses_lite" => true})

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-client-metadata"})

    metadata = client_metadata_fixture("websocket")

    forwarded_headers = [
      {"x-codex-turn-metadata", "ws-client-metadata-forwarded-turn"},
      {"x-codex-installation-id", "ws-client-metadata-forwarded-installation"}
    ]

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true,
                 "client_metadata" => metadata.client_metadata
               }),
               %{
                 request_id: "ws-client-metadata-responses-lite",
                 client_ip: "127.0.0.1",
                 codex_session: session,
                 forwarded_headers: forwarded_headers
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_client_metadata_responses_lite"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"

    assert captured.json["client_metadata"]["x-codex-turn-metadata"] ==
             metadata.turn_metadata

    assert captured.json["client_metadata"]["existing_client_metadata"] ==
             "existing-client-metadata-websocket"

    assert captured.json["client_metadata"][
             "ws_request_header_x_openai_internal_codex_responses_lite"
           ] ==
             "true"

    for {name, value} <- forwarded_headers do
      refute Enum.any?(captured.headers, fn {header_name, header_value} ->
               header_name == name or header_value == value
             end)
    end

    assert_client_metadata_not_persisted!(setup, metadata)

    request_text = inspect(Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id)))
    refute request_text =~ "ws-client-metadata-forwarded"
  end

  @tag :client_metadata
  test "websocket request-scoped x-codex-turn-state from client_metadata participates in continuity without upgrade state" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_request_scoped_turn_state",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{})
    request_turn_state = "ws-request-scoped-turn-state-#{System.unique_integer([:positive])}"

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true,
                 "client_metadata" => %{"x-codex-turn-state" => request_turn_state}
               }),
               %{request_id: "ws-request-scoped-turn-state", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_request_scoped_turn_state"} = Jason.decode!(frame)

    assert [turn_alias] =
             Repo.all(
               from(alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.alias_kind == "turn_state" and
                     alias_record.status == "active"
               )
             )

    assert turn_alias.alias_hash == :crypto.hash(:sha256, request_turn_state)
    assert_websocket_turn_state_not_persisted!(setup, request_turn_state)
  end

  @tag :client_metadata
  test "websocket ignores malformed request-scoped x-codex-turn-state client metadata" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_malformed_turn_state",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{})

    metadata_cases = [
      {"blank", %{"x-codex-turn-state" => "   "}},
      {"nonbinary", %{"x-codex-turn-state" => ["opaque-turn-state-sentinel"]}},
      {"malformed", ["x-codex-turn-state", "opaque-client-metadata-sentinel"]}
    ]

    for {label, client_metadata} <- metadata_cases do
      assert :ok =
               execute_websocket_response(
                 auth,
                 Jason.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                   "stream" => true,
                   "generate" => true,
                   "client_metadata" => client_metadata
                 }),
                 %{request_id: "ws-malformed-turn-state-#{label}", codex_session: session},
                 fn frame -> send(self(), {:websocket_frame, label, frame}) end
               )

      assert_received {:websocket_frame, ^label, frame}
      assert %{"id" => "resp_ws_malformed_turn_state"} = Jason.decode!(frame)
    end

    refute Repo.exists?(
             from(alias_record in BridgeSessionAlias,
               where:
                 alias_record.codex_session_id == ^session.id and
                   alias_record.alias_kind == "turn_state" and
                   alias_record.status == "active"
             )
           )

    persistence_text =
      inspect({
        Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id)),
        Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id)),
        Repo.all(from(turn in CodexTurn)),
        Repo.all(
          from(alias_record in BridgeSessionAlias,
            where: alias_record.codex_session_id == ^session.id
          )
        ),
        Accounting.list_request_logs(setup.pool).items
      })

    refute persistence_text =~ "opaque-turn-state-sentinel"
    refute persistence_text =~ "opaque-client-metadata-sentinel"
  end

  test "websocket dispatch sends trusted Responses Lite marker as per-request client metadata" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_responses_lite_marker",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup =
      upstream
      |> gateway_setup()
      |> put_setup_model_source_metadata!(%{"use_responses_lite" => true})

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-responses-lite"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-responses-lite-marker",
                 client_ip: "127.0.0.1",
                 codex_session: session,
                 forwarded_headers: [
                   {"x-openai-internal-codex-responses-lite", "client-spoofed-lite"},
                   {"x-openai-internal-unapproved", "client-internal-spoof"}
                 ]
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_responses_lite_marker"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"

    assert captured.json["client_metadata"][
             "ws_request_header_x_openai_internal_codex_responses_lite"
           ] ==
             "true"

    refute Enum.any?(captured.headers, fn {name, _value} ->
             name == "x-openai-internal-codex-responses-lite"
           end)

    persistence_text = inspect(Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id)))
    refute persistence_text =~ "client-spoofed-lite"
    refute persistence_text =~ "client-internal-spoof"
  end

  test "websocket dispatch ignores client-spoofed Responses Lite marker for non-Lite models" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_responses_lite_spoof_ignored",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-responses-lite-spoof"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-responses-lite-spoof-ignored",
                 client_ip: "127.0.0.1",
                 codex_session: session,
                 forwarded_headers: [
                   {"x-openai-internal-codex-responses-lite", "true"},
                   {"x-openai-internal-unapproved", "client-internal-spoof"}
                 ]
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_responses_lite_spoof_ignored"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"

    refute get_in(captured.json, [
             "client_metadata",
             "ws_request_header_x_openai_internal_codex_responses_lite"
           ])

    refute Enum.any?(captured.headers, fn {name, _value} ->
             name == "x-openai-internal-codex-responses-lite"
           end)
  end

  test "websocket response dispatch returns a structured error for non-text frames" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:error,
            %{
              status: 400,
              code: "invalid_request",
              message: "websocket message must be a text JSON frame"
            }} =
             execute_websocket_response(
               auth,
               {:binary, <<0, 1, 2>>},
               %{},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.requests(upstream) == []
  end

  test "public gateway session and turn calls accept keyword and typed request options" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(
        auth,
        accepted_turn_state: "stable-ws-public-typed-options",
        owner_instance_id: "node-a"
      )

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "gateway typed options"
    }

    correlation_id = "ws-public-typed-options-#{System.unique_integer([:positive])}"

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               payload,
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: correlation_id,
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    options =
      %{
        codex_turn_id: correlation_id,
        pool_upstream_assignment_id: setup.assignment.id
      }
      |> RequestOptions.build("/backend-api/codex/responses", payload)

    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request, options)

    assert turn.request_id == reserved.request.id
    assert turn.transport_kind == "websocket"

    session = Repo.get!(CodexSession, session.id)
    assert session.owner_instance_id == "node-a"
    assert session.pool_upstream_assignment_id == setup.assignment.id
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
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-envelope"})

    result =
      execute_websocket_response(
        auth,
        Jason.encode!(%{
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
          "include" => [],
          "generate" => true,
          "previous_response_id" => "resp_ws_previous"
        }),
        %{request_id: "ws-envelope", codex_session: session},
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_receive {:websocket_frame, completed_frame}, @websocket_frame_timeout

    assert %{"id" => "resp_ws_sse"} = Jason.decode!(completed_frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.json["type"] == "response.create"
    assert captured.json["generate"] == true
    assert captured.json["previous_response_id"] == "resp_ws_previous"
    assert captured.json["instructions"] == ""

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

  test "websocket response.create strips mixed encrypted agent messages before upstream dispatch" do
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

    raw_agent_encrypted_content = "sample-mixed-agent-encrypted-content"

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "hello"},
                   %{
                     "type" => "agent_message",
                     "author" => "root",
                     "recipient" => "worker",
                     "content" => [
                       %{"type" => "input_text", "text" => "Message Type: MESSAGE\nPayload:\n"},
                       %{
                         "type" => "encrypted_content",
                         "encrypted_content" => raw_agent_encrypted_content
                       }
                     ]
                   },
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
    assert %{"id" => "resp_ws_mixed_agent_message"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.json["type"] == "response.create"

    assert Enum.map(captured.json["input"], &Map.fetch!(&1, "type")) == [
             "message",
             "message",
             "agent_message"
           ]

    assert captured.json["input"] |> Enum.at(1) |> Map.fetch!("encrypted_content")

    assert captured.json["input"]
           |> Enum.at(2)
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
        pricing_ref: "gpt-5.5"
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
               Jason.encode!(%{
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
    assert %{"id" => "resp_ws_priced_gpt55"} = Jason.decode!(frame)

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
               Jason.encode!(%{
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
    assert %{"id" => "resp_ws_missing_usage"} = Jason.decode!(frame)

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

  @tag :websocket_response_create_image_payload
  test "websocket response.create preserves input_image payloads end to end" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          "event: response.created\r\ndata: #{Jason.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_ws_image"}})}\r\n\r\n",
          "event: response.completed\r\ndata: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_ws_image", "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}})}\r\n\r\n"
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
        Jason.encode!(%{
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
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)
    assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["type"] == "response.create"
    assert captured.json["input"] == input
  end

  test "websocket response.create rejects unsupported input_image references before dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text", "image"],
          "supports_image_detail_original" => true
        }
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    sentinel_file_id = "file_ws_reference_do_not_log"

    assert {:error,
            %{
              status: 400,
              code: "unsupported_input_image_format",
              param: "input",
              message: message
            }} =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{
                     "type" => "message",
                     "role" => "user",
                     "content" => [
                       %{"type" => "input_text", "text" => "describe this image"},
                       %{"type" => "input_image", "file_id" => sentinel_file_id}
                     ]
                   }
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-unsupported-image"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert message =~
             "Responses input_image values must use https image URLs or supported image data URLs"

    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "rejected"
    assert request.last_error_code == "unsupported_input_image_format"
    assert request.request_metadata["gateway_denial"]["param"] == "input"
    refute inspect(request.request_metadata) =~ sentinel_file_id
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
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

    completed_event = "event: response.completed\ndata: #{Jason.encode!(completed_payload)}\n\n"
    {completed_prefix, completed_suffix} = String.split_at(completed_event, 17_000)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          "event: response.created\ndata: #{Jason.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_ws_large_completed"}})}\n\n",
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
        Jason.encode!(%{
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
               Jason.encode!(%{
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
               Jason.encode!(%{
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
    previous_response_id = "resp_ws_usage_limit_anchor_#{System.unique_integer([:positive])}"

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               Jason.encode!(%{"id" => previous_response_id})
             )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "trigger websocket usage limit terminal",
                 "previous_response_id" => previous_response_id,
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
           } = Jason.decode!(frame)

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
    refute metadata_text =~ previous_response_id
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
               Jason.encode!(%{
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
    assert {:error, _reason} = Jason.decode(malformed_frame)

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
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "header body quota conflict",
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

    failed_frame = Jason.encode!(frames["response.failed"])
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

    refute Enum.any?(
             QuotaWindows.list_quota_windows(setup.identity),
             &(&1.source == "codex_response_headers" and &1.window_kind == "primary")
           )
  end

  test "websocket stream conversion preserves response completed events split across SSE chunks" do
    created_event =
      "event: response.created\ndata: #{Jason.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_ws_split_sse_completed"}})}\n\n"

    completed_payload = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_ws_split_sse_completed",
        "metadata" => %{"padding" => String.duplicate("x", 17_000)},
        "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
      }
    }

    completed_event = "event: response.completed\ndata: #{Jason.encode!(completed_payload)}\n\n"
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

  @tag :websocket_previous_response_bridge
  test "websocket continuity turns preserve client supplied previous_response_id for upstream context" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_bridge",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-previous-bridge"})

    first_payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
      "stream" => true,
      "generate" => true
    }

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(first_payload),
               %{request_id: "ws-previous-bridge-first", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    assert %{"id" => "resp_ws_bridge"} = Jason.decode!(first_frame)

    second_payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
      "stream" => true,
      "generate" => true,
      "previous_response_id" => "resp_ws_bridge"
    }

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(second_payload),
               %{request_id: "ws-previous-bridge-second", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :second, frame}) end
             )

    assert_received {:websocket_frame, :second, second_frame}
    assert %{"id" => "resp_ws_bridge"} = Jason.decode!(second_frame)

    assert [first_request, second_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"
    assert second_request.method == "WEBSOCKET"
    assert first_request.json["type"] == "response.create"
    assert second_request.json["type"] == "response.create"
    assert first_request.json["generate"] == true
    assert second_request.json["generate"] == true
    refute Map.has_key?(first_request.json, "previous_response_id")
    assert second_request.json["previous_response_id"] == "resp_ws_bridge"

    assert second_request.json["input"] == [
             %{"type" => "message", "role" => "user", "content" => "second"}
           ]

    assert [first_log, second_log] =
             Repo.all(
               from request in Request,
                 where: request.pool_id == ^setup.pool.id,
                 order_by: [asc: request.admitted_at]
             )

    assert first_log.status == "succeeded"
    assert second_log.status == "succeeded"
    assert first_log.response_status_code == 200
    assert second_log.response_status_code == 200

    assert [first_turn, second_turn] =
             Repo.all(
               from turn in CodexTurn,
                 where: turn.codex_session_id == ^session.id,
                 order_by: [asc: turn.turn_sequence]
             )

    assert first_turn.status == "succeeded"
    assert second_turn.status == "succeeded"
    assert second_turn.turn_sequence == 2
  end

  @tag :websocket_persistent_upstream_session
  test "downstream websocket keeps one upstream websocket session across continuation turns" do
    previous_env =
      Application.get_env(
        :codex_pooler,
        UpstreamWebsocketSession,
        []
      )

    Application.put_env(:codex_pooler, UpstreamWebsocketSession, keepalive_interval_ms: 20)

    on_exit(fn ->
      Application.put_env(
        :codex_pooler,
        UpstreamWebsocketSession,
        previous_env
      )
    end)

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_persistent",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    FakeUpstream.notify_websocket_controls(upstream, self())

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-persistent-connection",
          accepted_turn_state: "stable-ws-persistent-connection",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_persistent"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)
      assert_receive {:fake_upstream_websocket_control, :ping, 1}, 1_000

      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_ws_persistent"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, state)

      assert {:ok, state} = receive_socket_done(state)

      second_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_sample",
              "output" => "sample output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_persistent"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_persistent"} = Jason.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, processed_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.method == "WEBSOCKET"
      assert processed_request.method == "WEBSOCKET"
      assert second_request.method == "WEBSOCKET"
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert processed_request.websocket_connection_id == first_request.websocket_connection_id
      refute Map.has_key?(first_request.json, "previous_response_id")

      assert processed_request.json == %{
               "response_id" => "resp_ws_persistent",
               "type" => "response.processed"
             }

      assert second_request.json["previous_response_id"] == "resp_ws_persistent"

      assert second_request.json["input"] == [
               %{
                 "call_id" => "call_sample",
                 "output" => "sample output",
                 "type" => "function_call_output"
               }
             ]
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "persistent upstream websocket reconnects once when the prior connection closed before the next turn" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_reconnected",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-reconnect-stale-upstream",
          accepted_turn_state: "stable-ws-reconnect-stale-upstream",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_reconnected"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      assert :ok = FakeUpstream.close_websocket_connections(upstream)

      second_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_reconnected"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_reconnected"} = Jason.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id != second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_ws_reconnected"

      assert [first_log, second_log] =
               Repo.all(
                 from(r in Request,
                   where: r.pool_id == ^setup.pool.id,
                   order_by: [asc: r.admitted_at]
                 )
               )

      assert first_log.status == "succeeded"
      assert second_log.status == "succeeded"
      assert second_log.last_error_code == nil
      assert Repo.all(from(d in BridgeDemotion)) == []
      assert Repo.all(from(c in RoutingCircuitState)) == []
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "persistent upstream websocket does not reconnect after a partial response body" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_partial_close",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-partial-close-no-reconnect",
          accepted_turn_state: "stable-ws-partial-close-no-reconnect",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_partial_close"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      FakeUpstream.set_mode(
        upstream,
        FakeUpstream.websocket_sse_then_close(
          [
            {"response.output_text.delta",
             %{
               "type" => "response.output_text.delta",
               "response_id" => "resp_ws_partial_close",
               "output_index" => 0,
               "content_index" => 0,
               "delta" => "partial"
             }}
          ],
          reason: "fake upstream closed after partial frame"
        )
      )

      second_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_partial_close"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, partial_frame}, state} = receive_socket_push(state)

      assert %{"type" => "response.output_text.delta", "delta" => "partial"} =
               Jason.decode!(partial_frame)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

      assert %{"type" => "error", "error" => %{"code" => "upstream_request_failed"}} =
               Jason.decode!(error_frame)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_ws_partial_close"

      assert [first_log, second_log] =
               Repo.all(
                 from(r in Request,
                   where: r.pool_id == ^setup.pool.id,
                   order_by: [asc: r.admitted_at]
                 )
               )

      assert first_log.status == "succeeded"
      assert second_log.status == "failed"
      assert second_log.transport == "websocket"
      assert second_log.last_error_code == "upstream_stream_error"

      assert [second_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^second_log.id))

      assert second_attempt.status == "failed"

      assert second_attempt.response_metadata["transport_failure"] == %{
               "phase" => "upstream_close",
               "pre_visible_output" => false,
               "reason" => "upstream_websocket_closed_before_terminal",
               "reason_class" => "upstream_websocket_closed_before_terminal",
               "terminal_seen" => false,
               "text_frame_count" => 1
             }

      metadata_text = inspect(second_attempt.response_metadata)
      refute metadata_text =~ "partial"
      refute metadata_text =~ "fake upstream closed after partial frame"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
      refute metadata_text =~ "Bearer "
      refute metadata_text =~ "upstream-token"

      assert [demotion] = Repo.all(from(d in BridgeDemotion))
      assert demotion.pool_upstream_assignment_id == setup.assignment.id
      assert demotion.reason_code == "upstream_stream_error"

      assert [circuit] =
               Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_websocket"))

      assert circuit.pool_upstream_assignment_id == setup.assignment.id
      assert circuit.reason_code == "upstream_stream_error"
      assert circuit.failure_count == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "concurrent downstream websocket frames do not queue behind the active upstream turn" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_ws_parallel",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-concurrent-frames",
          accepted_turn_state: "stable-ws-concurrent-frames",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "main turn"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_chunk_barrier, 0, first_upstream_pid, ^release_ref}, 1_000

      second_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "sidecar turn"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_chunk_barrier, 0, second_upstream_pid, ^release_ref}, 1_000
      send(first_upstream_pid, {:fake_upstream_release_chunk, release_ref})
      send(second_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = Jason.decode!(first_frame)
      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = Jason.decode!(second_frame)
      assert {:ok, state} = receive_socket_done(state)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id != second_request.websocket_connection_id
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "tool output websocket continuations wait for the active upstream turn" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_ws_ordered_tool",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-ordered-tool-continuation",
          accepted_turn_state: "stable-ws-ordered-tool-continuation",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "main turn"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_chunk_barrier, 0, first_upstream_pid, ^release_ref}, 1_000

      second_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_ordered_tool",
              "output" => "sample output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_ordered_tool"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      refute_receive {:fake_upstream_chunk_barrier, 0, _second_upstream_pid, ^release_ref}, 100

      send(first_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      assert_receive {:fake_upstream_chunk_barrier, 0, second_upstream_pid, ^release_ref}, 1_000
      send(second_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = Jason.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_ws_ordered_tool"

      assert [%{"type" => "function_call_output", "call_id" => "call_ordered_tool"}] =
               second_request.json["input"]
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "downstream websocket does not inject last response id when continuation omits previous_response_id" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_auto_previous",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-no-auto-previous-response-id",
          accepted_turn_state: "stable-ws-no-auto-previous-response-id",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_auto_previous"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      second_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "follow-up"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_auto_previous"} = Jason.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      refute Map.has_key?(first_request.json, "previous_response_id")
      refute Map.has_key?(second_request.json, "previous_response_id")
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "websocket tool output continuations keep previous_response_id for upstream context" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_tool_continuation",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-tool-continuation"})

    tool_output = "sample output"
    tool_call_id = "call_sample"
    previous_response_id = "resp_ws_tool_origin"

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => tool_call_id,
                     "output" => tool_output
                   }
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => previous_response_id
               }),
               %{request_id: "ws-tool-continuation", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
    assert %{"id" => "resp_ws_tool_continuation"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["previous_response_id"] == previous_response_id
    assert captured.json["type"] == "response.create"
    assert captured.json["generate"] == true

    assert captured.json["input"] == [
             %{
               "type" => "function_call_output",
               "call_id" => tool_call_id,
               "output" => tool_output
             }
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert request.usage_status == "usage_known"
    assert request.request_metadata["codex_session_id"] == session.id

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.status == "succeeded"
    assert attempt.upstream_status_code == 200

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.request_id == request.id
    assert turn.status == "succeeded"
    assert turn.transport_kind == "websocket"
    assert turn.completed_at
    assert turn.final_attempt_id == attempt.id

    session = Repo.get!(CodexSession, session.id)
    assert session.status == "active"
    assert session.pool_upstream_assignment_id == setup.assignment.id

    persistence_text =
      inspect({request.request_metadata, attempt.response_metadata, session, turn})

    refute persistence_text =~ setup.authorization
    refute persistence_text =~ previous_response_id
    refute persistence_text =~ tool_call_id
    refute persistence_text =~ tool_output
    refute persistence_text =~ "upstream-token"
  end

  test "websocket custom tool output continuations keep previous_response_id for upstream context" do
    upstream =
      start_upstream(
        FakeUpstream.require_json_field(
          "previous_response_id",
          %{
            "id" => "resp_ws_custom_tool_continuation",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{
            "error" => %{
              "type" => "invalid_request_error",
              "message" =>
                "No tool call found for custom tool call output with call_id call_sample.",
              "param" => "input"
            }
          }
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-custom-tool"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{
                     "type" => "custom_tool_call_output",
                     "call_id" => "call_sample",
                     "name" => "sample_tool",
                     "output" => "sample output"
                   }
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => "resp_ws_custom_tool_origin"
               }),
               %{request_id: "ws-custom-tool-continuation", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_custom_tool_continuation"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["previous_response_id"] == "resp_ws_custom_tool_origin"
    assert captured.json["type"] == "response.create"
    assert captured.json["generate"] == true
  end

  test "future tool output continuations keep previous_response_id by shape" do
    upstream =
      start_upstream(
        FakeUpstream.require_json_field(
          "previous_response_id",
          %{
            "id" => "resp_ws_future_tool_continuation",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "missing_future_tool_context"}}
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-future-tool"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{
                     "type" => "future_tool_call_output",
                     "call_id" => "future_call_sample",
                     "output" => "future sample output"
                   }
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => "resp_ws_future_tool_origin"
               }),
               %{request_id: "ws-future-tool-continuation", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_future_tool_continuation"} = Jason.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["previous_response_id"] == "resp_ws_future_tool_origin"

    assert captured.json["input"] |> List.first() |> Map.fetch!("type") ==
             "future_tool_call_output"
  end

  test "HTTP custom tool output continuations keep previous_response_id", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.require_json_field(
          "previous_response_id",
          %{
            "id" => "resp_http_custom_tool_continuation",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "missing_custom_tool_context"}}
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_sample",
            "name" => "sample_tool",
            "output" => "sample output"
          }
        ],
        "previous_response_id" => "resp_http_custom_tool_origin"
      })

    assert %{"id" => "resp_http_custom_tool_continuation"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["previous_response_id"] == "resp_http_custom_tool_origin"
    refute Map.has_key?(captured.json, "type")
  end

  test "gateway debug mode logs safe continuation decisions and stores request metadata" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)
    previous_logger_level = Logger.level()

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{gateway_debug?: true}
    )

    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: previous_logger_level)

      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    upstream =
      start_upstream(
        FakeUpstream.require_json_field(
          "previous_response_id",
          %{
            "id" => "resp_ws_debug_tool_continuation",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "missing_debug_tool_context"}}
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-debug-tool"})

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert :ok =
                 execute_websocket_response(
                   auth,
                   Jason.encode!(%{
                     "type" => "response.create",
                     "model" => setup.model.exposed_model_id,
                     "metadata" => %{"debug_note" => "metadata value must stay hidden"},
                     "input" => [
                       %{
                         "type" => "custom_tool_call_output",
                         "call_id" => "call_debug_sample",
                         "output" => "debug output must stay hidden"
                       }
                     ],
                     "stream" => true,
                     "generate" => true,
                     "previous_response_id" => "resp_ws_debug_tool_origin"
                   }),
                   %{request_id: "ws-debug-tool-continuation", codex_session: session},
                   fn frame -> send(self(), {:websocket_frame, frame}) end
                 )
      end)

    assert log =~ "codex_pooler gateway_debug payload"
    assert log =~ "previous_response_id_action=preserved"
    assert log =~ "client_json_bytes="
    assert log =~ "client_approx_tokens="
    assert log =~ "upstream_json_bytes="
    assert log =~ "upstream_approx_tokens="
    assert log =~ "client_entry_count=1"
    assert log =~ "client_chat_entry_count=0"
    assert log =~ "client_string_bytes="
    assert log =~ "custom_tool_call_output"
    refute log =~ "debug output must stay hidden"
    refute log =~ "metadata value must stay hidden"
    refute log =~ "resp_ws_debug_tool_origin"
    refute log =~ "call_debug_sample"

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_debug_tool_continuation"} = Jason.decode!(frame)

    attempt =
      Repo.one!(
        from(a in Attempt,
          join: r in Request,
          on: r.id == a.request_id,
          where: r.endpoint == "/backend-api/codex/responses" and r.transport == "websocket"
        )
      )

    debug = attempt.response_metadata["gateway_debug"]
    refute Map.has_key?(debug, "previous_response_id")
    assert debug["previous_response_id_summary"]["action"] == "preserved"
    assert debug["items"]["tool_result_types"] == ["custom_tool_call_output"]
    assert debug["shape"]["client"]["json"]["bytes"] > 0
    assert debug["shape"]["client"]["json"]["approx_tokens"] > 0
    assert debug["shape"]["client"]["json"]["strategy"] == "json_bytes_div_4_ceil"

    assert debug["shape"]["client"]["top_level_keys"] == [
             "generate",
             "input",
             "metadata",
             "model",
             "previous_response_id",
             "stream",
             "type"
           ]

    assert debug["shape"]["client"]["entries"]["count"] == 1

    assert debug["shape"]["client"]["entries"]["item_types"] == %{
             "custom_tool_call_output" => 1
           }

    assert debug["shape"]["client"]["entries"]["tool_result_count"] == 1
    assert debug["shape"]["client"]["chat_entries"]["kind"] == "absent"
    assert debug["shape"]["client"]["string_stats"]["string_bytes"] > 0
    assert debug["shape"]["client"]["string_stats"]["max_string_bytes"] > 0
    assert debug["shape"]["client"]["flags"]["stream"] == true
    assert debug["shape"]["client"]["flags"]["generate"] == true
    assert debug["shape"]["client"]["flags"]["has_previous_response_id"] == true
    assert debug["shape"]["upstream"]["json"]["bytes"] > 0
    assert debug["shape"]["upstream"]["flags"]["has_instructions"] == true

    metadata_text = inspect(debug)
    refute metadata_text =~ "debug output must stay hidden"
    refute metadata_text =~ "metadata value must stay hidden"
    refute metadata_text =~ "resp_ws_debug_tool_origin"
    refute metadata_text =~ "call_debug_sample"
  end

  test "HTTP backend continuity drops previous_response_id without tool outputs", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.reject_json_field(
          "previous_response_id",
          %{
            "id" => "resp_http_bridge",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "invalid_previous_response_id"}}
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "hello",
        "previous_response_id" => "resp_http_previous"
      })

    assert %{"id" => "resp_http_bridge"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    refute Map.has_key?(captured.json, "previous_response_id")
  end

  test "websocket generate false warmup completes locally without upstream dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-warmup"})

    result =
      execute_websocket_response(
        auth,
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "instructions" => "warmup",
          "input" => [],
          "tools" => [],
          "tool_choice" => "auto",
          "parallel_tool_calls" => true,
          "store" => false,
          "stream" => true,
          "include" => [],
          "generate" => false
        }),
        %{request_id: "ws-warmup", codex_session: session},
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_received {:websocket_frame, created_frame}
    assert_received {:websocket_frame, completed_frame}

    assert %{"type" => "response.created", "response" => %{"id" => ""}} =
             Jason.decode!(created_frame)

    assert %{"type" => "response.completed", "response" => %{"id" => ""}} =
             Jason.decode!(completed_frame)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id)) == []
  end

  test "websocket response processed fails without an upstream websocket session" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-processed"})

    result =
      execute_websocket_response(
        auth,
        Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_ws_processed"}),
        %{request_id: "ws-processed", codex_session: session},
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert {:error,
            %{
              status: 502,
              code: "upstream_websocket_forward_failed",
              message: message
            }} = result

    assert message =~ "upstream_websocket_session_missing"
    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id)) == []
  end

  test "websocket response processed fails for stale upstream sessions" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-processed-stale"})

    stale_pid = spawn(fn -> :ok end)
    ref = Process.monitor(stale_pid)
    assert_receive {:DOWN, ^ref, :process, ^stale_pid, _reason}

    result =
      execute_websocket_response(
        auth,
        Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_stale"}),
        %{
          request_id: "ws-processed-stale",
          codex_session: session,
          upstream_websocket_session: stale_pid
        },
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert {:error,
            %{
              status: 502,
              code: "upstream_websocket_forward_failed",
              message: message
            }} = result

    assert message =~ "upstream_websocket_session_unavailable"
    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id)) == []
  end

  @tag :bridge_ring
  test "websocket response dispatch keeps DB-backed sticky affinity for a persisted session" do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_first",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_second",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(first_upstream)

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{"source_assignment_ids" => [setup.assignment.id, second.assignment.id]}
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-affinity"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => "first ws"}),
               %{request_id: "ws-affinity-first", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    first_body = Jason.decode!(first_frame)

    first_assignment =
      assignment_for_response(first_body["id"], setup.assignment, second.assignment)

    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      routing_strategy: "least_recent_success",
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => "second ws"}),
               %{request_id: "ws-affinity-second", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :second, frame}) end
             )

    assert_received {:websocket_frame, :second, second_frame}
    second_body = Jason.decode!(second_frame)

    second_assignment =
      assignment_for_response(second_body["id"], setup.assignment, second.assignment)

    assert second_assignment.id == first_assignment.id
    assert Repo.aggregate(BridgeAffinity, :count) == 1

    assert [request | _rest] =
             Repo.all(from request in Request, order_by: [desc: request.admitted_at])

    assert request.request_metadata["routing"]["strategy"] == "least_recent_success"
    assert request.request_metadata["routing"]["affinity_status"] == "hit"
    assert request.request_metadata["routing"]["affinity_kind"] == "codex_session"

    assert request.request_metadata["routing"]["selected_bridge_candidate_id"] ==
             first_assignment.id

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "second ws"
    refute metadata_text =~ "resp_ws_second"
  end

  @tag :websocket_session_assignment_unavailable
  test "websocket continuation fails closed when the persisted session assignment is unavailable" do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_unavailable_first",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_unavailable_second_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(first_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-unavailable"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => "first ws"}),
               %{request_id: "ws-unavailable-first", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    assert %{"id" => "resp_ws_unavailable_first"} = Jason.decode!(first_frame)

    persisted_session = Repo.get!(CodexSession, session.id)
    assert persisted_session.pool_upstream_assignment_id == setup.assignment.id

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      )

    assert {:ok, _assignment} =
             PoolAssignments.disable_pool_assignment(setup.assignment)

    assert {:error, %{code: "pinned_continuation_unavailable", status: 503} = error} =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => "second ws",
                 "previous_response_id" => "resp_ws_unavailable_first"
               }),
               %{request_id: "ws-unavailable-second", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :second, frame}) end
             )

    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"

    assert error.continuity_denial == %{
             "denial_family" => "pinned_continuation_unavailable",
             "continuity_family" => "pinned_codex_session",
             "pin_mode" => "hard",
             "pin_reason" => "previous_response_id",
             "internal_reason" => "assignment_unavailable",
             "pool_upstream_assignment_id" => setup.assignment.id,
             "upstream_identity_id" => setup.identity.id
           }

    refute_received {:websocket_frame, :second, _frame}
    assert FakeUpstream.count(second_upstream) == 0

    assert [denied_request] =
             Repo.all(
               from request in Request,
                 where: request.correlation_id == "ws-unavailable-second"
             )

    assert denied_request.status == "rejected"
    assert denied_request.last_error_code == "pinned_continuation_unavailable"
    refute denied_request.last_error_code == "stream_incomplete"

    metadata_text = inspect(denied_request.request_metadata || %{})
    refute metadata_text =~ "second ws"
    refute metadata_text =~ "resp_ws_unavailable_first"
  end

  @tag :websocket_pinned_reauth_recovery
  test "websocket pinned reauth continuation returns in-frame recovery without fallback or owner replacement" do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_should_not_dispatch",
          "object" => "response"
        })
      )

    fresh_start_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_fresh_start_should_not_dispatch",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream)

    fresh_start =
      gateway_upstream(
        setup.pool,
        fresh_start_upstream,
        "upstream-token-ws-pinned-reauth-fresh-start",
        compact?: false
      )

    prime_routing_quota!(fresh_start.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fresh_start.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "turn-ws-pinned-reauth-#{System.unique_integer([:positive])}"
    previous_response_id = "resp_ws_pinned_reauth_#{System.unique_integer([:positive])}"
    visible_input = "visible websocket pinned reauth context must not persist"

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: turn_state})
    session = pin_session_to_assignment!(session, setup.assignment)

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               %{"id" => previous_response_id}
             )

    lease_before = active_owner_lease_for_session!(session.id)
    mark_pinned_assignment_reauth_required!(setup)

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: %{
                 request_id: "ws-pinned-reauth-frame",
                 accepted_turn_state: turn_state,
                 client_ip: "127.0.0.1"
               }
             })

    try do
      assert state.codex_session.id == session.id
      assert_owner_lease_not_replaced!(session.id, lease_before)

      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => visible_input,
          "stream" => true,
          "generate" => true,
          "previous_response_id" => previous_response_id
        })

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, error_frame}, _state_after} = receive_socket_done(state)

      assert_pinned_reauth_websocket_frame!(error_frame)
      refute error_frame =~ previous_response_id
      refute error_frame =~ visible_input
      refute error_frame =~ setup.authorization
      refute error_frame =~ setup.raw_key
      refute error_frame =~ "Bearer "

      assert FakeUpstream.count(pinned_upstream) == 0
      assert FakeUpstream.count(fresh_start_upstream) == 0
      assert_pinned_reauth_rejected_request!("ws-pinned-reauth-frame")
      assert Repo.aggregate(Attempt, :count) == 0

      metadata_text = inspect(Accounting.list_request_logs(setup.pool))
      refute metadata_text =~ previous_response_id
      refute metadata_text =~ visible_input
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
      assert_owner_lease_not_replaced!(session.id, lease_before)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :websocket_pinned_reauth_recovery
  test "websocket frame previous_response_id recovers pinned session before using fresh socket session" do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_frame_alias_pinned_should_not_dispatch",
          "object" => "response"
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_frame_alias_fallback_should_not_dispatch",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        fallback_upstream,
        "upstream-token-ws-frame-alias-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    source_turn_state = "turn-ws-frame-alias-source-#{System.unique_integer([:positive])}"
    fresh_turn_state = "turn-ws-frame-alias-fresh-#{System.unique_integer([:positive])}"
    previous_response_id = "resp_ws_frame_alias_#{System.unique_integer([:positive])}"
    visible_tool_output = "visible websocket frame alias output must not persist"

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: source_turn_state})
    session = pin_session_to_assignment!(session, setup.assignment)

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               Jason.encode!(%{"id" => previous_response_id})
             )

    mark_pinned_assignment_reauth_required!(setup)

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: %{
                 request_id: "ws-frame-alias-pinned-reauth",
                 accepted_turn_state: fresh_turn_state,
                 client_ip: "127.0.0.1"
               }
             })

    try do
      assert state.codex_session.id != session.id

      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "future_tool_call_output",
              "call_id" => "call_ws_frame_alias",
              "output" => visible_tool_output
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => previous_response_id
        })

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, error_frame}, _state_after} = receive_socket_done(state)

      assert_pinned_reauth_websocket_frame!(error_frame)
      refute error_frame =~ previous_response_id
      refute error_frame =~ visible_tool_output
      refute error_frame =~ setup.authorization
      refute error_frame =~ setup.raw_key
      refute error_frame =~ "Bearer "

      assert FakeUpstream.count(pinned_upstream) == 0
      assert FakeUpstream.count(fallback_upstream) == 0
      assert_pinned_reauth_rejected_request!("ws-frame-alias-pinned-reauth")
      assert Repo.aggregate(Attempt, :count) == 0

      metadata_text = inspect(Accounting.list_request_logs(setup.pool))
      refute metadata_text =~ previous_response_id
      refute metadata_text =~ visible_tool_output
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :websocket_pinned_reauth_recovery
  test "websocket per-message dispatch returns pinned reauth recovery without fallback attempts" do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_dispatch_should_not_run",
          "object" => "response"
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_fallback_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-ws-pinned-reauth-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    previous_response_id = "resp_ws_pinned_dispatch_#{System.unique_integer([:positive])}"
    visible_tool_output = "visible websocket tool output must not persist"

    {:ok, session} =
      Gateway.start_codex_session(auth, %{previous_response_id: previous_response_id})

    session = pin_session_to_assignment!(session, setup.assignment)
    mark_pinned_assignment_reauth_required!(setup)

    payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "future_tool_call_output",
            "call_id" => "call_ws_pinned_reauth",
            "output" => visible_tool_output
          }
        ],
        "stream" => true,
        "generate" => true,
        "previous_response_id" => previous_response_id
      })

    assert {:error, error} =
             execute_websocket_response(
               auth,
               payload,
               %{
                 request_id: "ws-pinned-reauth-dispatch",
                 codex_session: session,
                 previous_response_id: previous_response_id
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_pinned_reauth_gateway_error!(error)
    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_pinned_reauth_rejected_request!("ws-pinned-reauth-dispatch")
    assert Repo.aggregate(Attempt, :count) == 0

    metadata_text = inspect({error, Accounting.list_request_logs(setup.pool)})
    refute metadata_text =~ previous_response_id
    refute metadata_text =~ visible_tool_output
    refute metadata_text =~ "call_ws_pinned_reauth"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token"
  end

  @tag :task_6_websocket_resume
  test "websocket reconnect resumes the same durable alias and owner lease before expiry" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_resume",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-resume"

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: turn_state,
        session_header: "session-resume",
        owner_instance_id: "node-a"
      })

    assert [turn_alias] =
             Repo.all(
               from alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.alias_kind == "turn_state"
             )

    assert turn_alias.alias_hash == :crypto.hash(:sha256, turn_state)

    assert [lease] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^session.id and lease.status == "active"
             )

    assert lease.owner_instance_id == "node-a"

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => "resume first"
               }),
               %{
                 request_id: "ws-resume-first",
                 codex_session: session,
                 accepted_turn_state: turn_state
               },
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    assert %{"id" => "resp_ws_resume"} = Jason.decode!(first_frame)

    Gateway.interrupt_codex_session(session, %{reconnect_window_seconds: 300})

    {:ok, resumed} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: turn_state,
        session_header: "session-resume",
        owner_instance_id: "node-a"
      })

    assert resumed.id == session.id

    assert [renewed_lease] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^session.id and lease.status == "active"
             )

    assert renewed_lease.id == lease.id
    assert renewed_lease.lease_token == lease.lease_token
    assert DateTime.compare(renewed_lease.renewed_at, lease.renewed_at) in [:gt, :eq]

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1
  end

  @tag :task_6_http_websocket_continuity
  test "HTTP response id continuity resumes the same durable session for websocket", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_http_to_ws",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-turn-state", "http-turn-state")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "http continuity"
      })

    assert %{"id" => "resp_http_to_ws"} = json_response(conn, 200)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert [http_session] = Repo.all(from(session in CodexSession))

    assert [response_alias] =
             Repo.all(
               from alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^http_session.id and
                     alias_record.alias_kind == "previous_response_id"
             )

    assert response_alias.alias_hash == :crypto.hash(:sha256, "resp_http_to_ws")
    refute inspect(response_alias) =~ "resp_http_to_ws"
    refute inspect(response_alias) =~ "http continuity"

    {:ok, websocket_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "new-websocket-turn-state",
        previous_response_id: "resp_http_to_ws",
        owner_instance_id: "node-ws"
      })

    assert websocket_session.id == http_session.id

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "previous_response_id" => "resp_http_to_ws",
                 "input" => "ws continuity"
               }),
               %{
                 request_id: "ws-continuity-turn",
                 codex_session: websocket_session,
                 previous_response_id: "resp_http_to_ws"
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_http_to_ws"} = Jason.decode!(frame)

    assert websocket_request =
             Enum.find(
               FakeUpstream.requests(upstream),
               &(&1.json["previous_response_id"] == "resp_http_to_ws")
             )

    assert websocket_request.json["previous_response_id"] == "resp_http_to_ws"

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^http_session.id),
             :count
           ) ==
             2
  end

  test "HTTP response id continuity refreshes sticky session quota before fallback candidates", %{
    conn: conn
  } do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    stale_quota_response = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_at" => DateTime.to_iso8601(reset_at)
        }
      }
    }

    first_stale_upstream =
      start_upstream({:path_json, %{"/api/codex/usage" => {200, stale_quota_response}}})

    second_stale_upstream =
      start_upstream({:path_json, %{"/api/codex/usage" => {200, stale_quota_response}}})

    sticky_upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/usage" => {200, stale_quota_response},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_sticky_refreshed_quota",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(first_stale_upstream, quota?: false)

    second_stale =
      gateway_upstream(setup.pool, second_stale_upstream, "upstream-token-second-stale",
        compact?: false
      )

    sticky =
      gateway_upstream(setup.pool, sticky_upstream, "upstream-token-sticky", compact?: false)

    prime_stale_routing_quota!(setup.identity)
    prime_stale_routing_quota!(second_stale.identity)
    prime_stale_routing_quota!(sticky.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          second_stale.assignment,
          sticky.assignment
        ])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{previous_response_id: "resp_sticky_previous"})

    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: sticky.assignment.id})
    |> Repo.update!()

    {:ok, resumed_session} =
      Gateway.start_codex_session(auth, %{previous_response_id: "resp_sticky_previous"})

    assert resumed_session.id == session.id
    assert resumed_session.pool_upstream_assignment_id == sticky.assignment.id

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_sticky_previous",
        "input" => "recover sticky session quota"
      })

    assert %{"id" => "resp_sticky_refreshed_quota"} = json_response(conn, 200)

    assert [] = FakeUpstream.requests(first_stale_upstream)
    assert [] = FakeUpstream.requests(second_stale_upstream)

    assert [usage_request, response_request] = FakeUpstream.requests(sticky_upstream)
    assert usage_request.path == "/api/codex/usage"
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.request_metadata["codex_session_id"] == session.id
    assert get_in(request.request_metadata, ["quota_decision", "refreshed_stale_quota"]) == true

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             sticky.assignment.id

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == sticky.assignment.id
  end

  test "live upstream websocket continuity refreshes stale sticky quota before rejection" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    exhausted_quota_response = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 100,
          "limit_window_seconds" => 18_000,
          "reset_at" => DateTime.to_iso8601(reset_at)
        }
      }
    }

    sticky_upstream =
      start_upstream({:path_json, %{"/api/codex/usage" => {200, exhausted_quota_response}}})

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_live_anchor_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream, quota?: false)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-ws-live-anchor-fallback",
        compact?: false
      )

    prime_stale_routing_quota!(setup.identity)
    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "live-ws-quota"})
    pin_session_to_assignment!(session, setup.assignment)
    {:ok, upstream_websocket_session} = UpstreamWebsocketSession.start_link()

    try do
      assert {:error, %{code: "pinned_continuation_unavailable"} = error} =
               execute_websocket_response(
                 auth,
                 Jason.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => "live upstream websocket quota rejection",
                   "stream" => true,
                   "generate" => true
                 }),
                 %{
                   request_id: "ws-live-stale-quota",
                   codex_session: session,
                   upstream_websocket_session: upstream_websocket_session
                 },
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert error.retryable == false
      assert error.requires_new_upstream_session == true
      assert error.recovery["kind"] == "restart_with_full_context"

      assert error.continuity_denial == %{
               "denial_family" => "pinned_continuation_unavailable",
               "continuity_family" => "pinned_codex_session",
               "pin_mode" => "hard",
               "pin_reason" => "live_upstream_websocket",
               "internal_reason" => "quota_evidence_unavailable",
               "pool_upstream_assignment_id" => setup.assignment.id,
               "upstream_identity_id" => setup.identity.id
             }
    after
      UpstreamWebsocketSession.close(upstream_websocket_session)
    end

    refute_received {:websocket_frame, _frame}
    assert [%{path: "/api/codex/usage"}] = FakeUpstream.requests(sticky_upstream)
    assert FakeUpstream.requests(fallback_upstream) == []
    assert Repo.aggregate(Attempt, :count) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.transport == "websocket"
    assert request.last_error_code == "pinned_continuation_unavailable"
  end

  test "HTTP response id continuity survives expired owner leases", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_http_expired_lease",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-turn-state", "http-expired-lease-turn")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "http continuity past lease"
      })

    assert %{"id" => "resp_http_expired_lease"} = json_response(conn, 200)
    assert [http_session] = Repo.all(from(session in CodexSession))

    expired_at = DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:microsecond)

    http_session
    |> Ecto.Changeset.change(%{owner_lease_expires_at: expired_at})
    |> Repo.update!()

    BridgeOwnerLease
    |> where([lease], lease.codex_session_id == ^http_session.id)
    |> Repo.update_all(set: [expires_at: expired_at, updated_at: expired_at])

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, resumed_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "later-http-turn-state",
        previous_response_id: "resp_http_expired_lease",
        owner_instance_id: "node-after-http-lease"
      })

    assert resumed_session.id == http_session.id
    assert DateTime.compare(resumed_session.owner_lease_expires_at, expired_at) == :gt

    assert [%BridgeOwnerLease{owner_instance_id: "node-after-http-lease", status: "active"}] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^http_session.id and lease.status == "active"
             )
  end

  @tag :task_6_same_connection_distinct_turns
  test "distinct websocket messages sharing connection request id both dispatch and account" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_same_connection",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "same-connection"})
    opts = %{request_id: "connection-request-id", codex_session: session}

    first_payload = Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => "first"})

    second_payload =
      Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => "second"})

    assert :ok =
             execute_websocket_response(auth, first_payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert :ok =
             execute_websocket_response(auth, second_payload, opts, fn frame ->
               send(self(), {:websocket_frame, :second, frame})
             end)

    assert_received {:websocket_frame, :first, _frame}
    assert_received {:websocket_frame, :second, _frame}
    assert FakeUpstream.count(upstream) == 2
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    assert Repo.aggregate(from(a in Attempt), :count) == 2

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             2

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 2
  end

  @tag :task_6_duplicate_turn
  test "duplicate explicit websocket turn id does not double account attempts or usage" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_duplicate_turn",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "duplicate-turn"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      Jason.encode!(%{
        "model" => setup.model.exposed_model_id,
        "turn_id" => "duplicate-turn-id",
        "input" => "dedupe me"
      })

    assert :ok =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert_received {:websocket_frame, :first, _frame}

    assert {:error, %{code: "duplicate_turn"}} =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :duplicate, frame})
             end)

    refute_received {:websocket_frame, :duplicate, _frame}
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(from(a in Attempt), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 1
  end

  @tag :task_6_duplicate_turn
  test "concurrent duplicate explicit websocket turn id is atomically rejected" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_concurrent_duplicate_turn",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "duplicate-race"})

    opts = %{request_id: "connection-request-id", codex_session: session}
    parent = self()

    payload =
      Jason.encode!(%{
        "model" => setup.model.exposed_model_id,
        "turn_id" => "duplicate-race-turn-id",
        "input" => "dedupe me concurrently"
      })

    tasks =
      for label <- [:first, :second] do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:duplicate_turn_task_ready, label, self()})

          receive do
            :run_duplicate_turn_request -> :ok
          after
            5_000 -> flunk("duplicate turn task #{label} was not released")
          end

          execute_websocket_response(auth, payload, opts, fn frame ->
            send(parent, {:websocket_frame, label, frame})
          end)
        end)
      end

    task_pids =
      for _label <- [:first, :second] do
        assert_receive {:duplicate_turn_task_ready, _label, pid}, 5_000
        pid
      end

    Enum.each(task_pids, &send(&1, :run_duplicate_turn_request))

    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?(:ok, &1)) == 1
    assert Enum.count(results, &match?({:error, %{code: "duplicate_turn"}}, &1)) == 1

    assert_receive {:websocket_frame, _label, _frame}, @websocket_frame_timeout
    refute_received {:websocket_frame, _label, _frame}

    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(from(a in Attempt), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 1
  end

  @tag :task_6_demoted_owner
  test "demoted backend does not receive the next websocket turn" do
    demoted_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_demoted_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    active_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_demotion",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(demoted_upstream)

    second =
      gateway_upstream(setup.pool, active_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{"source_assignment_ids" => [setup.assignment.id, second.assignment.id]}
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "demotion-turn"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeDemotion{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      reason_code: "upstream_5xx",
      status: "active",
      demoted_until: DateTime.add(now, 60, :second),
      attempt_count: 1,
      metadata: %{"source" => "test_demotion"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => "avoid demoted"
               }),
               %{request_id: "after-demotion-turn", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_after_demotion"} = Jason.decode!(frame)
    assert FakeUpstream.count(demoted_upstream) == 0
    assert FakeUpstream.count(active_upstream) == 1

    assert [%BridgeDemotion{pool_upstream_assignment_id: demoted_assignment_id, status: "active"}] =
             Repo.all(from(demotion in BridgeDemotion))

    assert demoted_assignment_id == setup.assignment.id
  end

  test "soft assigned websocket session can avoid a demoted continuity backend" do
    sticky_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_sticky_demoted_session",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_sticky_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{"source_assignment_ids" => [setup.assignment.id, fallback.assignment.id]}
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "sticky-demoted"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeDemotion{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      reason_code: "upstream_stream_error",
      status: "active",
      demoted_until: DateTime.add(now, 60, :second),
      attempt_count: 1,
      metadata: %{"source" => "test_demotion"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => "preserve sticky session assignment"
               }),
               %{request_id: "sticky-demoted-turn", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_sticky_fallback_should_not_run"} = Jason.decode!(frame)
    assert FakeUpstream.count(sticky_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    request = Repo.get!(Request, turn.request_id)
    assert request.transport == "websocket"
    assert request.endpoint == "/backend-api/codex/responses"

    assert get_in(request.request_metadata, ["routing", "affinity_kind"]) == "codex_session"

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             fallback.assignment.id

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "preserve sticky session assignment"
    refute metadata_text =~ "resp_sticky_fallback_should_not_run"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == fallback.assignment.id
  end

  test "soft local websocket session alias can avoid an exhausted continuity backend before dispatch" do
    sticky_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_exhausted_sticky_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_soft_alias_quota_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream, quota?: false)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-soft-alias-fallback",
        compact?: false
      )

    prime_exhausted_routing_quota!(setup.identity)
    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "soft-ws-quota-#{System.unique_integer([:positive])}"
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: turn_state})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "soft local alias may fall back before dispatch",
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-soft-alias-quota-fallback",
                 accepted_turn_state: turn_state
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_soft_alias_quota_fallback"} = Jason.decode!(frame)

    assert FakeUpstream.count(sticky_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             fallback.assignment.id

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == fallback.assignment.id
    refute attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.request_id == request.id
    assert turn.status == "succeeded"

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "soft local alias may fall back before dispatch"
    refute metadata_text =~ "resp_ws_soft_alias_quota_fallback"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
  end

  @tag :hard_pinned_quota_recovery
  test "live upstream websocket session keeps exhausted continuity backend hard pinned" do
    sticky_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_live_sticky_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_live_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream, quota?: false)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-live-fallback",
        compact?: false
      )

    prime_exhausted_routing_quota!(setup.identity)
    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "live-ws-quota-#{System.unique_integer([:positive])}"
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: turn_state})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    upstream_websocket_session = start_supervised!(UpstreamWebsocketSession)

    assert {:error, %{code: "pinned_continuation_unavailable", status: 503} = error} =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "live websocket state must not fall back",
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-live-hard-quota-exhausted",
                 codex_session: session,
                 accepted_turn_state: turn_state,
                 upstream_websocket_session: upstream_websocket_session
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"

    assert error.continuity_denial == %{
             "denial_family" => "pinned_continuation_unavailable",
             "continuity_family" => "pinned_codex_session",
             "pin_mode" => "hard",
             "pin_reason" => "live_upstream_websocket",
             "internal_reason" => "quota_exhausted",
             "pool_upstream_assignment_id" => setup.assignment.id,
             "upstream_identity_id" => setup.identity.id
           }

    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(sticky_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0

    assert [request] =
             Repo.all(
               from request in Request,
                 where: request.correlation_id == "ws-live-hard-quota-exhausted"
             )

    assert request.status == "rejected"
    assert request.transport == "websocket"
    assert request.last_error_code == "pinned_continuation_unavailable"

    assert %{
             "denial_family" => "pinned_continuation_unavailable",
             "pin_reason" => "live_upstream_websocket",
             "internal_reason" => "quota_exhausted",
             "pool_upstream_assignment_id" => assignment_id,
             "upstream_identity_id" => identity_id
           } = request.request_metadata["continuity_denial"]

    assert assignment_id == setup.assignment.id
    assert identity_id == setup.identity.id
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    metadata_text = inspect(request.request_metadata || %{})
    refute metadata_text =~ "live websocket state must not fall back"
    refute metadata_text =~ "resp_ws_live"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
  end

  test "fresh websocket upgrade timeout before visible output tries the next eligible assignment" do
    release_ref = make_ref()

    timeout_upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_timeout(notify: self(), release_ref: release_ref)
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_upgrade_timeout_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(timeout_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(
          auth,
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => "fail over before visible websocket output",
            "stream" => true,
            "generate" => true
          }),
          %{request_id: request_id, connect_timeout_ms: 25},
          fn frame -> send(parent, {:websocket_frame, frame}) end
        )
      end)

    assert_receive {:fake_upstream_timeout_barrier, :websocket_upgrade, upstream_pid,
                    ^release_ref},
                   1_000

    try do
      assert :ok = Task.await(task, 2_000)
    after
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    end

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_upgrade_timeout_fallback"} = Jason.decode!(frame)

    assert FakeUpstream.count(timeout_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert first_attempt.network_error_code == "upstream_stream_error"

    assert second_attempt.pool_upstream_assignment_id == fallback.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"
  end

  test "non-101 websocket upgrade rejection stays classified as upstream_stream_error" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{
            "error" => %{
              "code" => "upgrade_rejected",
              "message" => "upgrade body sentinel"
            }
          },
          status: 403,
          headers: [
            {"x-upstream-status", "upgrade-denied-sentinel"},
            {"set-cookie", "cookie-sentinel"}
          ]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:error,
            %{
              code: "upstream_request_failed",
              message: "upstream request failed",
              status: 502
            }} =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "non-101 websocket upgrade rejection",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-upgrade-rejected"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upgrade body sentinel"
    refute metadata_text =~ "upgrade-denied-sentinel"
    refute metadata_text =~ "cookie-sentinel"
    refute metadata_text =~ "upgrade_rejected"
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "websocket handshake 401 refreshes once and retries the same assignment" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_upgrade_error(
             %{"error" => %{"code" => "invalid_api_key"}},
             status: 401,
             headers: [{"x-openai-authorization-error", "invalid_api_key"}]
           ),
           FakeUpstream.json_response(%{"access_token" => "upstream-token-refreshed"}, 200),
           FakeUpstream.json_response(websocket_auth_retry_success_payload("handshake_401"))
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-ws-handshake-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               websocket_auth_refresh_payload(setup, "handshake-401"),
               %{request_id: "ws-auth-handshake-401"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_auth_retry_handshake_401"} = Jason.decode!(frame)

    [refresh_request, retried_request] = FakeUpstream.requests(upstream)
    assert refresh_request.path == "/oauth/token"
    assert retried_request.method == "WEBSOCKET"
    assert retried_request.path == "/backend-api/codex/responses"
    assert Map.new(retried_request.headers)["authorization"] == "Bearer upstream-token-refreshed"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"

    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "refresh-token-ws-handshake-do-not-leak"
    refute metadata_text =~ "upstream-token-refreshed"
  end

  for auth_code <- ["invalid_api_key", "invalid_authentication"] do
    @auth_code auth_code
    @tag :feature_websocket_terminal_auth_refresh
    test "websocket pre-visible terminal auth #{auth_code} refreshes once and retries the same assignment" do
      auth_code = @auth_code

      upstream =
        start_upstream(
          {:sequence,
           [
             websocket_terminal_auth_failure(auth_code),
             FakeUpstream.json_response(%{"access_token" => "upstream-token-refreshed"}, 200),
             FakeUpstream.json_response(websocket_auth_retry_success_payload(auth_code))
           ]}
        )

      setup = gateway_setup(upstream)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(setup.identity, %{
                 secret_kind: "refresh_token",
                 plaintext: "refresh-token-ws-terminal-do-not-leak"
               })

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert :ok =
               execute_websocket_response(
                 auth,
                 websocket_auth_refresh_payload(setup, auth_code),
                 %{request_id: "ws-auth-terminal-#{auth_code}"},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      expected_response_id = "resp_ws_auth_retry_#{auth_code}"
      assert_received {:websocket_frame, frame}
      assert %{"id" => ^expected_response_id} = Jason.decode!(frame)
      refute_received {:websocket_frame, _unexpected}

      [first_request, refresh_request, retried_request] = FakeUpstream.requests(upstream)
      assert first_request.method == "WEBSOCKET"
      assert refresh_request.path == "/oauth/token"
      assert retried_request.method == "WEBSOCKET"

      assert Map.new(retried_request.headers)["authorization"] ==
               "Bearer upstream-token-refreshed"

      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_unauthorized"
      assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"
      assert first_attempt.response_metadata["stream_error_code"] == auth_code

      assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert second_attempt.status == "succeeded"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.retry_count == 1
      assert request.last_error_code == nil
      assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

      assert Repo.all(from(d in BridgeDemotion)) == []
      assert Repo.all(from(c in RoutingCircuitState)) == []

      metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-ws-terminal-do-not-leak"
      refute metadata_text =~ "upstream-token-refreshed"
    end
  end

  @tag :feature_websocket_terminal_auth_refresh_failures
  test "websocket terminal auth preserves original failure when refresh is already in progress" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(
             [
               {"response.failed",
                %{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_ws_auth_refresh_in_progress",
                    "error" => %{"code" => "invalid_api_key"},
                    "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
                  }
                }}
             ],
             done: false,
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.json_response(%{"access_token" => "provider-should-not-run"}, 200),
           FakeUpstream.json_response(%{"id" => "retry-should-not-run", "object" => "response"})
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-ws-in-progress-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(
          auth,
          websocket_auth_refresh_payload(setup, "refresh-in-progress"),
          %{request_id: "ws-auth-refresh-in-progress"},
          fn frame -> send(parent, {:websocket_frame, frame}) end
        )
      end)

    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref}, 1_000

    metadata = active_token_refresh_metadata()

    assert {:ok, _identity} =
             IdentityLifecycle.update_upstream_identity(setup.identity, %{
               status: "refreshing",
               metadata: Map.put(setup.identity.metadata || %{}, "token_refresh", metadata)
             })

    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert :ok = Task.await(task, 2_000)

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "invalid_api_key"}}
           } =
             Jason.decode!(frame)

    assert [first_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "invalid_api_key"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "invalid_api_key"

    assert request.request_metadata["auth_refresh"] == %{
             "status" => "refresh_in_progress",
             "attempt_id" => metadata["attempt_id"],
             "generation" => metadata["generation"],
             "started_at" => metadata["started_at"],
             "stale_after_ms" => metadata["stale_after_ms"],
             "trigger_kind" => "websocket_terminal_auth_failure"
           }

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "refresh-token-ws-in-progress-do-not-leak"
    refute metadata_text =~ "provider-should-not-run"
    refute metadata_text =~ "retry-should-not-run"
  end

  for {refresh_status, refresh_response_status, refresh_response_body} <- [
        {"reauth_required", 400, %{"error" => "invalid_grant"}},
        {"refresh_failed", 503, %{"error" => "temporary"}}
      ] do
    @refresh_status refresh_status
    @refresh_response_status refresh_response_status
    @refresh_response_body refresh_response_body
    @tag :feature_websocket_terminal_auth_refresh_failures
    test "websocket terminal auth preserves original failure when refresh marks #{@refresh_status}" do
      refresh_status = @refresh_status

      upstream =
        start_upstream(
          {:sequence,
           [
             websocket_terminal_auth_failure("invalid_authentication"),
             FakeUpstream.json_response(@refresh_response_body, @refresh_response_status),
             FakeUpstream.json_response(%{"id" => "retry-should-not-run", "object" => "response"})
           ]}
        )

      setup = gateway_setup(upstream)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(setup.identity, %{
                 secret_kind: "refresh_token",
                 plaintext: "refresh-token-ws-#{refresh_status}-do-not-leak"
               })

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert :ok =
               execute_websocket_response(
                 auth,
                 websocket_auth_refresh_payload(setup, refresh_status),
                 %{request_id: "ws-auth-refresh-#{refresh_status}"},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_received {:websocket_frame, frame}

      assert %{
               "type" => "response.failed",
               "response" => %{"error" => %{"code" => "invalid_authentication"}}
             } = Jason.decode!(frame)

      assert [first_request, refresh_request] = FakeUpstream.requests(upstream)
      assert first_request.method == "WEBSOCKET"
      assert refresh_request.path == "/oauth/token"
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [attempt] = Repo.all(from(a in Attempt))
      assert attempt.status == "failed"
      assert attempt.network_error_code == "invalid_authentication"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "failed"
      assert request.retry_count == 0
      assert request.last_error_code == "invalid_authentication"
      assert request.request_metadata["auth_refresh"]["status"] == refresh_status

      assert request.request_metadata["auth_refresh"]["trigger_kind"] ==
               "websocket_terminal_auth_failure"

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-ws-#{refresh_status}-do-not-leak"
      refute metadata_text =~ "retry-should-not-run"
    end
  end

  @tag :feature_websocket_terminal_auth_refresh_failures
  test "websocket disconnect during terminal auth refresh drains the response task without DB noise" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_terminal_auth_failure("invalid_api_key"),
           FakeUpstream.barrier_json_response(
             %{"access_token" => "upstream-token-refreshed"},
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.json_response(websocket_auth_retry_success_payload("disconnect_refresh"))
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-ws-disconnect-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-auth-refresh-disconnect",
          accepted_turn_state: "stable-ws-auth-refresh-disconnect",
          client_ip: "127.0.0.1"
        }
      })

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_auth_refresh_payload(setup, "disconnect-refresh"), [opcode: :text]},
               state
             )

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, refresh_pid, ^release_ref},
                   1_000

    log =
      capture_log(fn ->
        terminator =
          Task.async(fn ->
            CodexResponsesSocket.terminate(:closed, state)
          end)

        refute Task.yield(terminator, 0)
        send(refresh_pid, {:fake_upstream_release_timeout, release_ref})
        assert :ok = Task.await(terminator, 2_000)
      end)

    assert [first_request, refresh_request, retried_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"
    assert refresh_request.path == "/oauth/token"
    assert retried_request.method == "WEBSOCKET"

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    assert turn.status == "succeeded"
    assert Repo.get!(CodexSession, state.codex_session.id).status == "interrupted"

    refute log =~ "Postgrex.Protocol"
    refute log =~ "DBConnection"
    refute log =~ "client "
    refute log =~ " exited"

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "refresh-token-ws-disconnect-do-not-leak"
    refute metadata_text =~ "upstream-token-refreshed"
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "websocket pre-visible terminal non-auth failure does not refresh or retry" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_non_auth_terminal",
                 "error" => %{"code" => "upstream_terminal_failure"},
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-ws-non-auth-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               websocket_auth_refresh_payload(setup, "non-auth"),
               %{request_id: "ws-terminal-non-auth-no-refresh"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"type" => "response.failed"} = Jason.decode!(frame)

    assert [first_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_terminal_failure"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "upstream_terminal_failure"
    refute Map.has_key?(request.request_metadata || %{}, "auth_refresh")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "refresh-token-ws-non-auth-do-not-leak"
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "websocket terminal auth after partial output does not refresh or retry" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "partial"}},
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_partial_auth_terminal",
                 "error" => %{"code" => "invalid_api_key"},
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-ws-partial-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "partial-auth"})

    assert :ok =
             execute_websocket_response(
               auth,
               websocket_auth_refresh_payload(setup, "partial-auth"),
               %{request_id: "ws-terminal-auth-after-partial", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames =
      receive_websocket_frames_by_type(["response.output_text.delta", "response.failed"], 1_000)

    assert frames["response.output_text.delta"]["delta"] == "partial"
    assert frames["response.failed"]["response"]["error"]["code"] == "invalid_api_key"

    assert [first_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "invalid_api_key"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "invalid_api_key"
    refute Map.has_key?(request.request_metadata || %{}, "auth_refresh")

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    assert turn.first_visible_output_at
    assert turn.status == "failed"
    assert turn.error_code == "invalid_api_key"

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "refresh-token-ws-partial-do-not-leak"
  end

  @tag :feature_websocket_connection_limit_retry
  test "websocket connection limit first event retries same assignment without demotion" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream(
             [
               {"error",
                %{
                  "type" => "error",
                  "status" => 400,
                  "code" => "websocket_connection_limit_reached",
                  "message" => "open a replacement websocket connection"
                }}
             ],
             done: false
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_ws_connection_limit_retry",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_connection_limit_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-limit-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "retry first websocket connection limit",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: request_id},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_connection_limit_retry"} = Jason.decode!(frame)
    refute_received {:websocket_frame, _unexpected}

    assert FakeUpstream.count(upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert first_attempt.network_error_code == "websocket_connection_limit_reached"
    assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"

    assert first_attempt.response_metadata["stream_error_code"] ==
             "websocket_connection_limit_reached"

    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"
  end

  @tag :feature_websocket_connection_limit_retry
  test "websocket connection limit retries after internal rate limit event" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream(
             [
               {"codex.rate_limits", codex_rate_limits_payload(29, reset_at)},
               {"error",
                %{
                  "type" => "error",
                  "status" => 400,
                  "code" => "websocket_connection_limit_reached",
                  "message" => "open a replacement websocket connection"
                }}
             ],
             done: false
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_ws_connection_limit_after_rate_limits",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_connection_limit_after_rate_limits_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-rate-limit-retry-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "retry after internal websocket rate limits",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: request_id},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames = receive_websocket_frames_by_type(["codex.rate_limits"], @websocket_frame_timeout)
    assert %{"type" => "codex.rate_limits"} = frames["codex.rate_limits"]

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_connection_limit_after_rate_limits"} = Jason.decode!(frame)
    refute_received {:websocket_frame, _unexpected}

    assert FakeUpstream.count(upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert first_attempt.network_error_code == "websocket_connection_limit_reached"
    assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"

    assert first_attempt.response_metadata["stream_error_code"] ==
             "websocket_connection_limit_reached"

    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    wait_for_rate_limit_event_tasks()
    assert window = wait_for_rate_limit_event_window(setup.identity, "primary")
    assert window.source == "codex_rate_limit_event"
    assert Decimal.equal?(window.used_percent, Decimal.new("29.0"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq
  end

  @tag :task_8_websocket_failure
  test "websocket terminal upstream failure demotes and circuit fails assignment" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_failed",
                 "error" => %{"code" => "upstream_terminal_failure"},
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "terminal-failure"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "terminal failure",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-terminal-failure", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"type" => "response.failed"} = Jason.decode!(frame)
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.last_error_code == "upstream_terminal_failure"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "upstream_terminal_failure"

    assert [demotion] = Repo.all(from(d in BridgeDemotion))
    assert demotion.pool_upstream_assignment_id == setup.assignment.id
    assert demotion.reason_code == "upstream_terminal_failure"
    assert demotion.status == "active"

    assert [circuit] =
             Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_websocket"))

    assert circuit.pool_upstream_assignment_id == setup.assignment.id
    assert circuit.reason_code == "upstream_terminal_failure"
    assert circuit.failure_count == 1
  end

  test "websocket context length terminal failure does not demote or circuit the assignment" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_context_too_large",
                 "error" => %{"code" => "context_length_exceeded"},
                 "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "context-large"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "too much context",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-context-too-large", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"type" => "response.failed"} = Jason.decode!(frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "context_length_exceeded"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "context_length_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket top-level upstream error is canonicalized for Codex clients" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "sequence_number" => 1,
               "error" => %{
                 "code" => "context_length_exceeded",
                 "message" => "Input exceeds this model context window."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "context-large"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "too much context",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-top-level-context-error", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "context_length_exceeded"}}
           } = Jason.decode!(frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "context_length_exceeded"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "context_length_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket wrapped status_code previous response error is masked without replaying or circuiting" do
    reset_at = DateTime.utc_now() |> DateTime.add(30, :minute) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 400,
               "error" => %{
                 "code" => "previous_response_not_found",
                 "message" => "Previous response with id 'resp_status_code_missing' not found.",
                 "param" => "previous_response_id"
               },
               "headers" => %{
                 "X-Request-ID" => "ws-frame-previous-request",
                 "X-Codex-Primary-Used-Percent" => 81,
                 "X-Codex-Primary-Window-Minutes" => 300,
                 "X-Codex-Primary-Reset-At" => DateTime.to_iso8601(reset_at),
                 "Should-Not-Persist" => "synthetic-sentinel"
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_status_code_previous_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-status-code-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "status-code-missing-previous"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "continue"}
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => "resp_status_code_missing"
               }),
               %{
                 request_id: "ws-status-code-previous-response-not-found",
                 codex_session: session
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{
                 "code" => "stream_incomplete",
                 "message" => "upstream stream incomplete"
               }
             }
           } = Jason.decode!(frame)

    refute frame =~ "previous_response_not_found"
    refute frame =~ "resp_status_code_missing"
    refute frame =~ "headers"
    refute frame =~ "ws-frame-previous-request"
    refute frame =~ "synthetic-sentinel"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [_request] = FakeUpstream.requests(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "x-codex-primary-reset-at" => DateTime.to_iso8601(reset_at),
             "x-codex-primary-used-percent" => "81",
             "x-codex-primary-window-minutes" => "300",
             "x-request-id" => "ws-frame-previous-request"
           }

    refute attempt.response_metadata["upstream_error_code"] == "error"

    assert window = wait_for_response_header_window(setup.identity, "primary")
    assert window.source == "codex_response_headers"
    assert Decimal.eq?(window.used_percent, Decimal.new("81"))

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket multiline previous response error frame is masked without replaying or circuiting" do
    previous_response_id = "resp_multiline_missing"
    request_content = "multiline previous response request content sentinel"

    raw_upstream_frame =
      Jason.encode!(
        %{
          "type" => "error",
          "status" => 400,
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "previous_response_not_found",
            "param" => "previous_response_id",
            "message" =>
              "Previous response with id '#{previous_response_id}' not found for #{request_content}."
          },
          "headers" => %{
            "X-Request-ID" => "ws-multiline-previous-request",
            "Authorization" => "synthetic-auth-redacted",
            "Should-Not-Persist" => "synthetic-sentinel",
            "X-Arbitrary-Debug" => ["drop-array"]
          }
        },
        pretty: true
      )

    assert raw_upstream_frame =~ "
"

    upstream = start_upstream(FakeUpstream.websocket_text_frames([raw_upstream_frame]))

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_multiline_previous_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-multiline-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "multiline-missing-previous"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => request_content}
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => previous_response_id
               }),
               %{request_id: "ws-multiline-previous-response-not-found", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{
                 "code" => "stream_incomplete",
                 "message" => "upstream stream incomplete"
               }
             }
           } = Jason.decode!(frame)

    refute frame =~ "previous_response_not_found"
    refute frame =~ previous_response_id
    refute frame =~ request_content
    refute frame =~ raw_upstream_frame
    refute frame =~ "headers"
    refute frame =~ "synthetic-auth-redacted"
    refute frame =~ "synthetic-sentinel"
    refute frame =~ "drop-array"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["previous_response_id"] == previous_response_id

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])
    refute Map.has_key?(request.request_metadata || %{}, "websocket_frame_headers")

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "x-request-id" => "ws-multiline-previous-request"
           }

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ raw_upstream_frame
    refute metadata_text =~ previous_response_id
    refute metadata_text =~ request_content
    refute metadata_text =~ "synthetic-auth-redacted"
    refute metadata_text =~ "synthetic-sentinel"
    refute metadata_text =~ "drop-array"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket wrapped status_code rate limit error records useful upstream metadata" do
    reset_at = DateTime.utc_now() |> DateTime.add(90, :minute) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 429,
               "error" => %{
                 "code" => "rate_limit_exceeded",
                 "message" => "rate limited"
               },
               "headers" => %{
                 "OpenAI-Request-ID" => "ws-frame-openai-request",
                 "X-Codex-Rate-Limit-Reached-Type" => "workspace_member_usage_limit_reached",
                 "X-Codex-Primary-Used-Percent" => 96,
                 "X-Codex-Primary-Window-Minutes" => 300,
                 "X-Codex-Primary-Reset-At" => DateTime.to_iso8601(reset_at),
                 "Authorization" => "synthetic-auth-redacted",
                 "Set-Cookie" => "synthetic-session-cookie=drop",
                 "Should-Not-Persist" => "synthetic-sentinel",
                 "X-Arbitrary-Debug" => "drop-me",
                 "X-Request-ID" => ["drop-array"]
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "rate-limit"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "hit a websocket rate limit",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-status-code-rate-limit", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "rate_limit_exceeded"}}
           } = Jason.decode!(frame)

    refute frame =~ ~s("code":"error")
    refute frame =~ "stream_incomplete"
    refute frame =~ "headers"
    refute frame =~ "ws-frame-openai-request"
    refute frame =~ "synthetic-auth-redacted"
    refute frame =~ "synthetic-session-cookie"
    refute frame =~ "synthetic-sentinel"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "rate_limit_exceeded"
    refute Map.has_key?(request.request_metadata || %{}, "websocket_frame_headers")

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "rate_limit_exceeded"
    assert attempt.response_metadata["error_kind"] == "rate_limit_exceeded"
    assert attempt.response_metadata["status_code"] == 200

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "openai-request-id" => "ws-frame-openai-request",
             "x-codex-primary-reset-at" => DateTime.to_iso8601(reset_at),
             "x-codex-primary-used-percent" => "96",
             "x-codex-primary-window-minutes" => "300",
             "x-codex-rate-limit-reached-type" => "workspace_member_usage_limit_reached"
           }

    refute attempt.response_metadata["upstream_error_code"] == "error"
    refute Map.has_key?(attempt.response_metadata, "masked_error_code")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "synthetic-auth-redacted"
    refute metadata_text =~ "synthetic-session-cookie"
    refute metadata_text =~ "synthetic-sentinel"
    refute metadata_text =~ "drop-me"

    assert window = wait_for_response_header_window(setup.identity, "primary")
    assert window.source == "codex_response_headers"
    assert Decimal.eq?(window.used_percent, Decimal.new("96"))
    assert window.metadata["rate_limit_reached_type"] == "workspace_member_usage_limit_reached"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "rate_limit_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket wrapped status_code message-only server error fails safely without raw body metadata" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 500,
               "message" => "upstream failed"
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "server-error"})

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => "trigger websocket server error",
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-status-code-message-only-server-error", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{"code" => "server_error", "message" => "upstream failed"}
             }
           } = Jason.decode!(frame)

    refute frame =~ ~s("code":"error")
    refute frame =~ "stream_incomplete"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "server_error"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "server_error"
    assert attempt.response_metadata["error_kind"] == "server_error"
    assert attempt.response_metadata["status_code"] == 200
    refute attempt.response_metadata["upstream_error_code"] == "error"
    refute Map.has_key?(attempt.response_metadata, "masked_error_code")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ ~s("type":"error")
    refute metadata_text =~ ~s("status_code":500)
    refute metadata_text =~ "upstream failed"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "server_error"
  end

  test "websocket previous response terminal failure is masked without replaying or circuiting" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "param" => "previous_response_id",
                 "message" => "Previous response with id 'resp_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_previous_missing_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "missing-previous"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "continue"}
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => "resp_missing"
               }),
               %{request_id: "ws-previous-response-not-found", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "stream_incomplete"}}
           } =
             Jason.decode!(frame)

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [_request] = FakeUpstream.requests(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  for upstream_code <- ["previous_response_not_found", "invalid_previous_response_id"] do
    @upstream_code upstream_code
    test "websocket explicit #{upstream_code} terminal failure is masked without replaying or circuiting" do
      upstream_code = @upstream_code

      upstream =
        start_upstream(
          FakeUpstream.sse_stream(
            [
              {"error",
               %{
                 "type" => "error",
                 "status" => 400,
                 "error" => %{
                   "type" => "invalid_request_error",
                   "code" => upstream_code
                 }
               }}
            ],
            done: false
          )
        )

      fallback_upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_explicit_previous_fallback_should_not_run",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      fallback =
        gateway_upstream(setup.pool, fallback_upstream, "upstream-token-explicit-fallback",
          compact?: false
        )

      prime_routing_quota!(fallback.identity)

      setup =
        Map.put(
          setup,
          :model,
          put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
        )

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, session} =
        Gateway.start_codex_session(auth, %{accepted_turn_state: "explicit-#{upstream_code}"})

      session =
        session
        |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
        |> Repo.update!()

      assert :ok =
               execute_websocket_response(
                 auth,
                 Jason.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => [
                     %{"type" => "message", "role" => "user", "content" => "continue"}
                   ],
                   "stream" => true,
                   "generate" => true,
                   "previous_response_id" => "resp_explicit_#{upstream_code}"
                 }),
                 %{request_id: "ws-explicit-#{upstream_code}", codex_session: session},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_received {:websocket_frame, frame}

      assert %{
               "type" => "response.failed",
               "response" => %{
                 "error" => %{
                   "code" => "stream_incomplete",
                   "message" => "upstream stream incomplete"
                 }
               }
             } = Jason.decode!(frame)

      refute frame =~ upstream_code
      refute frame =~ "resp_explicit_"

      assert FakeUpstream.count(upstream) == 1
      assert FakeUpstream.count(fallback_upstream) == 0
      assert [_request] = FakeUpstream.requests(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "failed"
      assert request.response_status_code == 200
      assert request.last_error_code == "stream_incomplete"
      refute get_in(request.request_metadata, ["routing", "demotion_reason"])

      assert [attempt] = Repo.all(from(a in Attempt))
      assert attempt.network_error_code == "stream_incomplete"
      assert attempt.response_metadata["upstream_error_code"] == upstream_code
      assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      assert turn.status == "failed"
      assert turn.error_code == "stream_incomplete"

      assert Repo.all(from(d in BridgeDemotion)) == []
      assert Repo.all(from(c in RoutingCircuitState)) == []
    end
  end

  test "websocket previous response terminal failure after partial output is masked without replaying" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "partial"}},
            {"error",
             %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "param" => "previous_response_id",
                 "message" => "Previous response with id 'resp_partial_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_partial_missing_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "partial-missing"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               Jason.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "continue"}
                 ],
                 "stream" => true,
                 "generate" => true,
                 "previous_response_id" => "resp_partial_missing"
               }),
               %{request_id: "ws-partial-previous-response-not-found", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, partial_frame}

    assert %{"type" => "response.output_text.delta", "delta" => "partial"} =
             Jason.decode!(partial_frame)

    assert_received {:websocket_frame, terminal_frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{
                 "code" => "stream_incomplete",
                 "message" => "upstream stream incomplete"
               }
             }
           } = Jason.decode!(terminal_frame)

    refute terminal_frame =~ "previous_response_not_found"
    refute terminal_frame =~ "resp_partial_missing"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [_request] = FakeUpstream.requests(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "stable websocket session key is reused before timeout and replaced after timeout" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-reconnect",
        owner_instance_id: "node-a"
      })

    assert [%BridgeOwnerLease{id: old_lease_id}] =
             Repo.all(
               from lease in BridgeOwnerLease, where: lease.codex_session_id == ^session.id
             )

    Gateway.interrupt_codex_session(session, %{reconnect_window_seconds: 300})

    {:ok, reused} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-reconnect",
        owner_instance_id: "node-a"
      })

    assert reused.id == session.id

    expired_at = DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:microsecond)

    reused
    |> Ecto.Changeset.change(%{status: "interrupted", owner_lease_expires_at: expired_at})
    |> Repo.update!()

    {:ok, replacement} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-reconnect",
        owner_instance_id: "node-b"
      })

    assert replacement.id != session.id
    assert Repo.get!(CodexSession, session.id).status == "closed"
    assert Repo.get!(BridgeOwnerLease, old_lease_id).status == "expired"

    assert [] =
             Repo.all(
               from alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.status == "active"
             )

    assert [%BridgeOwnerLease{owner_instance_id: "node-b", status: "active"}] =
             Repo.all(
               from lease in BridgeOwnerLease, where: lease.codex_session_id == ^replacement.id
             )
  end

  @tag :websocket_disconnect_interrupts_turn
  test "websocket disconnect interrupts active turn and request accounting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-disconnect"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "disconnect me"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-disconnect-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    Gateway.interrupt_codex_session(session, %{
      reason: "client_disconnected",
      reconnect_window_seconds: 300
    })

    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == attempt.id
    assert Repo.get!(Request, reserved.request.id).status == "failed"
    assert Repo.get!(Request, reserved.request.id).response_status_code == 499
    assert Repo.get!(Request, reserved.request.id).last_error_code == "client_disconnected"
    assert Repo.get!(CodexSession, session.id).status == "interrupted"
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket disconnect does not partially interrupt when accounting finalization fails" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-disconnect-failure"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "disconnect me"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-disconnect-failure-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    Repo.delete_all(
      from entry in LedgerEntry,
        where: entry.source_event_id == ^"request:#{reserved.request.id}:reservation"
    )

    assert {:error, {:interrupt_accounting_failed, %Ecto.NoResultsError{}}} =
             Gateway.interrupt_codex_session(session, %{
               reason: "client_disconnected",
               reconnect_window_seconds: 300
             })

    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == nil
    assert Repo.get!(Request, reserved.request.id).status == "in_progress"
    assert Repo.get!(Attempt, attempt.id).status == "in_progress"
    assert Repo.get!(CodexSession, session.id).status == "active"
  end

  test "websocket disconnect does not downgrade a completed turn" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-completed-disconnect"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "complete me"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-completed-disconnect-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    assert {:ok, _result} =
             AttemptSettlement.finalize_success(
               reserved.request,
               attempt,
               %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
               %{response_status_code: 200}
             )

    Gateway.interrupt_codex_session(session, %{
      reason: "client_disconnected",
      reconnect_window_seconds: 300
    })

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil
    assert Repo.get!(CodexSession, session.id).status == "interrupted"
  end

  test "websocket response task exits are reported as structured websocket errors" do
    payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => "gpt-test-model",
        "input" => "sensitive prompt sentinel"
      })

    log =
      capture_log(fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.handle_in(
                   {payload, [opcode: :text]},
                   %{tasks: MapSet.new(), opts: %{request_id: "ws-task-crash-log"}}
                 )

        assert MapSet.size(state.tasks) == 1

        assert {:push, {:text, frame}, state} =
                 receive_socket_done(state, @large_websocket_frame_timeout)

        assert Jason.decode!(frame) == %{
                 "type" => "error",
                 "status" => 500,
                 "error" => %{
                   "message" => "websocket response task failed",
                   "type" => "invalid_request_error",
                   "code" => "websocket_response_task_failed",
                   "param" => nil
                 }
               }

        assert MapSet.size(state.tasks) == 0
      end)

    assert log =~ "websocket response task failed"
    assert log =~ "failure_kind=exception"
    assert log =~ "failure_reason=KeyError"
    assert log =~ "request_id=ws-task-crash-log"
    assert log =~ "payload_type=response.create"
    assert log =~ "payload_model=gpt-test-model"
    refute log =~ "sensitive prompt sentinel"
  end

  test "websocket response task DOWN messages remove tasks that exit before done" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(pid)
    state = %{tasks: MapSet.new([pid]), task_monitors: %{pid => monitor}}

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert {:ok, state} =
             CodexResponsesSocket.handle_info({:DOWN, monitor, :process, pid, :killed}, state)

    assert state.tasks == MapSet.new()
    assert state.task_monitors == %{}
  end

  test "late websocket success after disconnect promotes an interrupted turn" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "late-success-disconnect"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "finish after disconnect"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-late-success-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    Gateway.interrupt_codex_session(session, %{
      reason: "client_disconnected",
      reconnect_window_seconds: 300
    })

    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(Request, reserved.request.id).status == "failed"

    assert {:ok, _result} =
             AttemptSettlement.finalize_success(
               reserved.request,
               attempt,
               %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
               %{response_status_code: 200}
             )

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil

    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    assert reloaded_attempt.status == "succeeded"
    assert reloaded_attempt.network_error_code == nil
    assert reloaded_attempt.error_message == nil

    assert %{items: [log]} =
             Accounting.list_request_logs(setup.pool, filters: %{request_id: reserved.request.id})

    assert log.status == "succeeded"
    assert log.errors == []
  end

  test "websocket terminate lets a just-completed response task finish before interrupting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "task-drain"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "complete me"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-task-drain-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        AttemptSettlement.finalize_success(
          reserved.request,
          attempt,
          %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
          %{response_status_code: 200}
        )

        send(parent, {:task_drain_finalized, self()})
        send(parent, {:codex_response_done, self(), :ok})
      end)

    assert_receive {:task_drain_finalized, ^pid}, 1_000

    assert :ok =
             CodexResponsesSocket.terminate(:closed, %{
               tasks: MapSet.new([pid]),
               codex_session: session,
               opts: %{reason: "client_disconnected", reconnect_window_seconds: 300}
             })

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil
    assert Repo.get!(CodexSession, session.id).status == "interrupted"
  end

  test "websocket terminate waits for in-flight response task finalization after interrupting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "task-finalization-drain"})

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "complete after close"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id:
                   "ws-task-finalization-drain-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:task_finalization_waiting, self()})

        receive do
          :finish_task_finalization -> :ok
        end

        AttemptSettlement.finalize_success(
          reserved.request,
          attempt,
          %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
          %{response_status_code: 200}
        )

        send(parent, {:task_finalization_finished, self()})
        send(parent, {:codex_response_done, self(), :ok})
      end)

    assert_receive {:task_finalization_waiting, ^pid}, 1_000

    terminator =
      Task.async(fn ->
        CodexResponsesSocket.terminate(:closed, %{
          tasks: MapSet.new([pid]),
          codex_session: session,
          opts: %{reason: "client_disconnected", reconnect_window_seconds: 300}
        })
      end)

    refute_receive {:task_finalization_finished, ^pid}, 350
    refute Task.yield(terminator, 0)

    send(pid, :finish_task_finalization)

    assert_receive {:task_finalization_finished, ^pid}, 1_000
    assert :ok = Task.await(terminator, 1_000)

    assert Repo.get!(CodexTurn, turn.id).status == "succeeded"
    assert Repo.get!(CodexTurn, turn.id).error_code == nil
    assert Repo.get!(Request, reserved.request.id).status == "succeeded"
    assert Repo.get!(Request, reserved.request.id).last_error_code == nil
    assert Repo.get!(CodexSession, session.id).status == "interrupted"
  end

  test "websocket terminate wait preserves unrelated mailbox messages" do
    unrelated = {:unrelated_websocket_mailbox_message, make_ref()}

    task =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    send(self(), unrelated)

    assert :ok =
             CodexResponsesSocket.terminate(:closed, %{
               tasks: MapSet.new([task]),
               codex_session: nil,
               opts: %{}
             })

    assert Process.alive?(task)
    send(task, :stop)

    assert_receive ^unrelated
  end

  defp capture_websocket_lifecycle_log(level, fun) when is_atom(level) and is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: level)

    try do
      capture_log(
        [
          level: level,
          format: "$metadata$message\n",
          metadata: @websocket_lifecycle_metadata_keys,
          colors: [enabled: false]
        ],
        fun
      )
    after
      Logger.configure(level: previous_level)
    end
  end

  defp websocket_lifecycle_request_options(request_id, attrs \\ []) when is_binary(request_id) do
    %{
      request_id: request_id,
      accepted_turn_state: "#{request_id}-turn",
      client_ip: "127.0.0.1"
    }
    |> Map.merge(Map.new(attrs))
    |> RequestOptions.for_websocket()
  end

  defp assert_websocket_lifecycle_line!(logs, message, required_keys, optional_keys) do
    lifecycle_lines =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, message))

    assert [line] = lifecycle_lines

    metadata_text =
      line
      |> String.replace_prefix(message, "")
      |> String.trim_leading()

    metadata_keys =
      metadata_text
      |> String.split(" ", trim: true)
      |> Enum.map(fn token -> token |> String.split("=", parts: 2) |> hd() end)

    assert Enum.all?(metadata_keys, &(&1 in @websocket_lifecycle_metadata_keys))
    assert Enum.all?(required_keys, &(&1 in metadata_keys))
    assert Enum.all?(metadata_keys, &(&1 in (required_keys ++ optional_keys)))
    assert_no_websocket_lifecycle_leaks!(logs)

    line
  end

  defp assert_no_websocket_lifecycle_leaks!(logs) do
    downcased_logs = String.downcase(logs)

    for forbidden_term <- @websocket_lifecycle_forbidden_terms do
      refute downcased_logs =~ forbidden_term
    end
  end

  defp websocket_auth_refresh_payload(setup, marker) do
    Jason.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => "websocket auth refresh fixture #{marker}",
      "stream" => true,
      "generate" => true
    })
  end

  defp websocket_auth_retry_success_payload(marker) do
    %{
      "id" => "resp_ws_auth_retry_#{marker}",
      "object" => "response",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
    }
  end

  defp websocket_terminal_auth_failure(code) do
    FakeUpstream.sse_stream(
      [
        {"response.failed",
         %{
           "type" => "response.failed",
           "response" => %{
             "id" => "resp_ws_terminal_auth_#{code}",
             "error" => %{"code" => code},
             "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
           }
         }}
      ],
      done: false
    )
  end

  defp active_token_refresh_metadata(opts \\ []) do
    %{
      "status" => "refreshing",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => Keyword.get(opts, :generation, 1),
      "started_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "trigger_kind" => "test",
      "receive_timeout_ms" => Keyword.get(opts, :receive_timeout_ms, 30_000),
      "stale_after_ms" => Keyword.get(opts, :stale_after_ms, 60_000)
    }
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

  defp active_owner_lease_for_session!(codex_session_id) do
    assert [lease] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^codex_session_id and lease.status == "active"
             )

    lease
  end

  defp assert_owner_lease_not_replaced!(codex_session_id, lease_before) do
    lease_after = active_owner_lease_for_session!(codex_session_id)
    assert lease_after.id == lease_before.id
    assert lease_after.lease_token == lease_before.lease_token
  end

  defp assert_pinned_reauth_websocket_frame!(frame) do
    assert %{
             "type" => "error",
             "status" => 503,
             "error" => error
           } = Jason.decode!(frame)

    assert error["code"] == "pinned_continuation_reauth_required"
    assert error["retryable"] == false
    assert error["requires_new_upstream_session"] == true
    assert error["recovery_kind"] == "restart_with_full_context"
    assert error["recovery"]["kind"] == "restart_with_full_context"
    assert error["recovery"]["anchor_removal"]["body"] == ["previous_response_id"]

    assert error["recovery"]["anchor_removal"]["headers"] == [
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

  defp assert_pinned_reauth_gateway_error!(error) do
    assert error.status == 503
    assert error.code == "pinned_continuation_reauth_required"
    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"
    assert error.recovery["anchor_removal"]["body"] == ["previous_response_id"]
  end

  defp assert_pinned_reauth_rejected_request!(correlation_id) do
    assert [request] =
             Repo.all(
               from request in Request,
                 where: request.correlation_id == ^correlation_id
             )

    assert request.status == "rejected"
    assert request.response_status_code == 503
    assert request.last_error_code == "pinned_continuation_reauth_required"
    refute request.request_metadata["requires_new_upstream_session"] == false

    request
  end

  defp codex_rate_limits_payload(used_percent, reset_at) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => used_percent,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }
  end

  defp wait_for_rate_limit_event_window(identity, window_kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.find(&(&1.source == "codex_rate_limit_event" and &1.window_kind == window_kind))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_rate_limit_event_window(identity, window_kind, deadline)
          end
        else
          flunk("expected codex.rate_limits quota window for #{window_kind}")
        end

      window ->
        window
    end
  end

  defp wait_for_response_header_window(identity, window_kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.find(&(&1.source == "codex_response_headers" and &1.window_kind == window_kind))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_response_header_window(identity, window_kind, deadline)
          end
        else
          flunk("expected Codex response header quota window for #{window_kind}")
        end

      window ->
        window
    end
  end

  defp wait_for_rate_limit_event_tasks(deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case Task.Supervisor.children(CodexPooler.RateLimitEventSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_rate_limit_event_tasks(deadline)
          end
        else
          flunk("expected codex.rate_limits persistence tasks to finish")
        end
    end
  end

  defp put_setup_model_source_metadata!(setup, source_metadata) when is_map(source_metadata) do
    metadata =
      setup.model.metadata
      |> Map.put("source_assignment_models", %{setup.assignment.id => source_metadata})

    model =
      setup.model
      |> Ecto.Changeset.change(%{metadata: metadata})
      |> Repo.update!()

    %{setup | model: model}
  end

  defp client_metadata_fixture(label) do
    forked_thread_id = "client-metadata-fork-#{label}"
    window_id = "client-metadata-window-#{label}"
    sentinel = "client-metadata-sentinel-#{label}"

    turn_metadata =
      Jason.encode!(%{
        "forked_from_thread_id" => forked_thread_id,
        "window_id" => window_id,
        "sentinel" => sentinel
      })

    %{
      turn_metadata: turn_metadata,
      forked_thread_id: forked_thread_id,
      window_id: window_id,
      sentinel: sentinel,
      client_metadata: %{
        "x-codex-turn-metadata" => turn_metadata,
        "existing_client_metadata" => "existing-client-metadata-#{label}"
      }
    }
  end

  defp assert_client_metadata_not_persisted!(setup, metadata) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: a.request_id == r.id,
          where: r.pool_id == ^setup.pool.id
        )
      )

    sessions = Repo.all(from(s in CodexSession))
    turns = Repo.all(from(t in CodexTurn))
    audit_events = Repo.all(from(e in AuditEvent))
    logs = RequestLogs.list(setup.pool.id, limit: 10)

    persistence_text =
      inspect({requests, attempts, sessions, turns, audit_events, logs.items})

    refute persistence_text =~ metadata.turn_metadata
    refute persistence_text =~ metadata.forked_thread_id
    refute persistence_text =~ metadata.window_id
    refute persistence_text =~ metadata.sentinel
    refute persistence_text =~ "existing-client-metadata"
  end

  defp assert_websocket_turn_state_not_persisted!(setup, turn_state) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: a.request_id == r.id,
          where: r.pool_id == ^setup.pool.id
        )
      )

    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    turns = Repo.all(from(t in CodexTurn))
    audit_events = Repo.all(from(e in AuditEvent))
    logs = RequestLogs.list(setup.pool.id, limit: 10)

    persistence_text =
      inspect({requests, attempts, sessions, turns, audit_events, logs.items})

    refute persistence_text =~ turn_state
  end

  defp refute_rate_limit_event_windows(identity) do
    refute Enum.any?(
             QuotaWindows.list_quota_windows(identity),
             &(&1.source == "codex_rate_limit_event")
           )
  end

  defp header!(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _other -> nil
    end)
    |> case do
      nil -> flunk("missing header #{name}")
      value -> value
    end
  end

  defp execute_websocket_response(auth, raw_payload, opts, push_frame) do
    request_options = RequestOptions.for_websocket(opts)
    RuntimeGateway.execute_websocket_response(auth, raw_payload, request_options, push_frame)
  end
end
