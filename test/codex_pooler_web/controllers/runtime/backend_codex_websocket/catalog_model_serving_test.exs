defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.CatalogModelServingTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @responses_lite_client_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"
  @model_serving_metadata_keys ~w(
    model_serving_mode_configured
    model_serving_mode
    model_serving_mode_source
  )
  @model_serving_websocket_routes [
    {:backend_responses, "/backend-api/codex/responses", "/backend-api/codex/responses", true},
    {:backend_v1_responses, "/backend-api/codex/v1/responses", "/backend-api/codex/responses",
     true},
    {:public_v1_responses, "/v1/responses", "/v1/responses", false}
  ]

  test "one authenticated catalog ETag is identical across every backend alias surface" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_shared_catalog_etag",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    model_responses =
      for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"] do
        conn = build_conn() |> auth(setup) |> get(path)
        body = json_response(conn, 200)
        {conn.resp_body, get_resp_header(conn, "etag"), body}
      end

    assert [{body_bytes, [exact_etag], body}, {body_bytes, [exact_etag], body}] = model_responses
    assert exact_etag == CodexCatalog.etag(body)
    assert <<"W/\"cp-models-v1-", _digest::binary-size(64), "\"">> = exact_etag

    for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
      conn =
        build_conn()
        |> auth(setup)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic shared catalog SSE request"),
          "stream" => true
        })

      assert conn.status == 200
      assert get_resp_header(conn, "x-models-etag") == [exact_etag]
      assert conn.resp_body =~ "resp_shared_catalog_etag"
    end

    models_request_count =
      Repo.aggregate(
        from(r in Request,
          where: fragment("?->>'operation'", r.request_metadata) == "models"
        ),
        :count
      )

    for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
      {conn, websocket, ref, response_headers} =
        public_websocket_connect_with_headers!(port, setup, "", path)

      try do
        assert List.keyfind(response_headers, "x-models-etag", 0) ==
                 {"x-models-etag", exact_etag}

        assert {"x-codex-turn-state", turn_state} =
                 List.keyfind(response_headers, "x-codex-turn-state", 0)

        assert {:ok, ^turn_state} = Ecto.UUID.cast(turn_state)

        assert Repo.aggregate(
                 from(r in Request,
                   where: fragment("?->>'operation'", r.request_metadata) == "models"
                 ),
                 :count
               ) == models_request_count

        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("synthetic shared catalog websocket request"),
            "stream" => true
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

        refute frame =~ "x-models-etag"
        refute CodexPooler.JSON.decode!(frame)["x-models-etag"]
        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "backend websocket keeps its handshake catalog ETag while each turn resolves fresh mode" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_catalog_etag_lifetime",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    override =
      Repo.insert!(%ModelServingOverride{
        pool_id: setup.pool.id,
        exposed_model_id: setup.model.exposed_model_id,
        mode: "lite",
        created_at: timestamp,
        updated_at: timestamp
      })

    initial_models = build_conn() |> auth(setup) |> get("/backend-api/codex/models")
    assert [initial_etag] = get_resp_header(initial_models, "etag")

    port = start_public_endpoint!()

    {conn, websocket, ref, response_headers} =
      public_websocket_connect_with_headers!(port, setup, "")

    updated_etag =
      override
      |> Ecto.Changeset.change(mode: "full", updated_at: DateTime.add(timestamp, 1, :second))
      |> Repo.update!()
      |> then(fn _updated_override ->
        updated_models = build_conn() |> auth(setup) |> get("/backend-api/codex/models")
        assert [updated_etag] = get_resp_header(updated_models, "etag")
        refute updated_etag == initial_etag
        updated_etag
      end)

    try do
      assert List.keyfind(response_headers, "x-models-etag", 0) ==
               {"x-models-etag", initial_etag}

      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic websocket ETag lifetime request"),
          "stream" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert CodexPooler.JSON.decode!(frame)["id"] == "resp_ws_catalog_etag_lifetime"
      refute frame =~ "x-models-etag"
    after
      Mint.HTTP.close(conn)
    end

    {fresh_conn, _websocket, _ref, fresh_headers} =
      public_websocket_connect_with_headers!(port, setup, "")

    try do
      assert List.keyfind(fresh_headers, "x-models-etag", 0) ==
               {"x-models-etag", updated_etag}
    after
      Mint.HTTP.close(fresh_conn)
    end
  end

  @tag :model_serving_modes
  test "backend websocket rejects a Lite typed tool choice before upstream dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    port = start_public_endpoint!()

    {conn, websocket, ref, _response_headers} =
      public_websocket_connect_with_headers!(port, setup, "", "/backend-api/codex/responses")

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic Lite typed-choice websocket request"),
          "tools" => [%{"type" => "custom", "name" => "typed_choice_fixture"}],
          "tool_choice" => %{"type" => "custom", "name" => "typed_choice_fixture"}
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "unsupported_parameter",
                 "param" => "tool_choice"
               }
             } = CodexPooler.JSON.decode!(frame)
    after
      Mint.HTTP.close(conn)
    end

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

  @tag :model_serving_modes
  test "backend websocket rejects scalar input and non-list tools before upstream dispatch in Full and Lite" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    port = start_public_endpoint!()

    assert_rejections = fn mode, expected_revision ->
      revision = set_model_serving_mode!(scope, setup, mode, expected_revision)

      for {payload, param} <- [
            {%{"input" => "synthetic scalar input"}, "input"},
            {%{"input" => [], "tools" => "synthetic non-list tools"}, "tools"}
          ] do
        {conn, websocket, ref, _response_headers} =
          public_websocket_connect_with_headers!(port, setup, "", "/backend-api/codex/responses")

        try do
          frame =
            CodexPooler.JSON.encode!(
              payload
              |> Map.put("type", "response.create")
              |> Map.put("model", setup.model.exposed_model_id)
            )

          {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
          {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

          assert %{
                   "type" => "error",
                   "status" => 400,
                   "error" => %{
                     "code" => "invalid_request",
                     "param" => ^param
                   }
                 } = CodexPooler.JSON.decode!(frame)
        after
          Mint.HTTP.close(conn)
        end
      end

      revision
    end

    revision = assert_rejections.("full", nil)
    _revision = assert_rejections.("lite", revision)

    assert FakeUpstream.count(upstream) == 0

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(CodexTurn, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  for {route_label, path, accounting_endpoint, catalog_etag?} <-
        @model_serving_websocket_routes do
    test "#{path} keeps one serving mode per turn and observes a Pool edit on the next turn" do
      route_label = unquote(route_label)
      path = unquote(path)
      accounting_endpoint = unquote(accounting_endpoint)
      catalog_etag? = unquote(catalog_etag?)

      upstream =
        start_upstream(
          # Strict finite scenario: exactly one native turn per serving mode;
          # a replayed or extra upstream send fails the fixture.
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond:
                FakeUpstream.websocket_text_frames([
                  CodexPooler.JSON.encode!(%{
                    "id" => "resp_ws_mode_lite_#{route_label}",
                    "object" => "response",
                    "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                  })
                ])
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond:
                FakeUpstream.websocket_text_frames([
                  CodexPooler.JSON.encode!(%{
                    "id" => "resp_ws_mode_full_#{route_label}",
                    "object" => "response",
                    "usage" => %{"input_tokens" => 5, "output_tokens" => 4, "total_tokens" => 9}
                  })
                ])
            )
          ])
        )

      setup = gateway_setup(upstream)
      scope = model_serving_scope()
      revision = set_model_serving_mode!(scope, setup, "lite")
      port = start_public_endpoint!()

      {conn, websocket, ref, response_headers} =
        public_websocket_connect_with_headers!(port, setup, "", path)

      try do
        assert_catalog_etag_header!(response_headers, catalog_etag?)

        lite_payload =
          model_serving_websocket_payload(setup, "#{route_label}-lite", "client-false")

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lite_payload)
        {conn, websocket, lite_frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert websocket_response_id(lite_frame) == "resp_ws_mode_lite_#{route_label}"
        assert [lite_upstream_request] = FakeUpstream.requests(upstream)
        assert_canonical_lite_websocket_request!(lite_upstream_request)

        _revision = set_model_serving_mode!(scope, setup, "full", revision)

        full_payload =
          model_serving_websocket_payload(setup, "#{route_label}-full", "client-true")

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, full_payload)
        {_conn, _websocket, full_frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert websocket_response_id(full_frame) == "resp_ws_mode_full_#{route_label}"

        assert [lite_upstream_request, full_upstream_request] =
                 FakeUpstream.requests(upstream)

        assert lite_upstream_request.path == "/backend-api/codex/responses"
        assert full_upstream_request.path == "/backend-api/codex/responses"
        assert_canonical_lite_websocket_request!(lite_upstream_request)
        assert_canonical_full_websocket_request!(full_upstream_request)

        assert [lite_request, full_request] = await_succeeded_pool_requests!(setup.pool.id, 2)

        assert lite_request.endpoint == accounting_endpoint
        assert full_request.endpoint == accounting_endpoint
        assert lite_request.status == "succeeded"
        assert full_request.status == "succeeded"

        assert_model_serving_accounting!(lite_request, "lite")
        assert_model_serving_accounting!(full_request, "full")
        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "same-assignment websocket retry keeps the original Lite snapshot after a Pool edit" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the connection-limit terminal is held behind
        # a native barrier so the Pool edit lands while the first attempt is in
        # flight; the retry must open a replacement connection and stay Lite.
        # provenance: synthetic_adversarial (response.failed envelope variants; #116 saw a type error terminal)
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_connection_limit_terminal_barrier(
              shape: :top_level,
              notify: self(),
              release_ref: release_ref
            )
          ),
          strict_native_response("resp_ws_mode_same_assignment_retry", 2, 4, 3)
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_mode_same_assignment_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-mode-retry-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    assignment_ids = [setup.assignment.id, fallback.assignment.id]

    request_id =
      Enum.find_value(1..500, fn index ->
        seed = "native-policy-reuse-bridge-ring-seed-#{index}"
        preferred = Enum.max_by(assignment_ids, &rendezvous_score(seed, &1))

        if preferred == setup.assignment.id, do: seed
      end) || raise "missing native policy routing seed"

    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "lite")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    task =
      Task.async(fn ->
        execute_websocket_response(
          auth,
          model_serving_websocket_payload(setup, "same-assignment", "client-false"),
          %{request_id: request_id},
          fn frame -> send(parent, {:websocket_frame, frame}) end
        )
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, upstream_pid,
                    ^release_ref},
                   1_000

    try do
      _revision = set_model_serving_mode!(scope, setup, "full", revision)
      send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
      assert :ok = Task.await(task, 3_000)
    after
      send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    end

    assert_received {:websocket_frame, frame}
    assert websocket_response_id(frame) == "resp_ws_mode_same_assignment_retry"

    assert [first_upstream_request, second_upstream_request] = FakeUpstream.requests(upstream)
    assert_canonical_lite_websocket_request!(first_upstream_request)
    assert_canonical_lite_websocket_request!(second_upstream_request)
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1

    assert [first_attempt, second_attempt] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert second_attempt.status == "succeeded"
    assert_model_serving_accounting!(request, "lite", [first_attempt, second_attempt])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "cross-assignment pre-visible failover keeps Full after the Pool changes to Lite" do
    release_ref = make_ref()

    timeout_upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_timeout(notify: self(), release_ref: release_ref)
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_mode_cross_assignment_failover",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(timeout_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-mode-fallback",
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
      Enum.find_value(1..500, fn index ->
        seed = "bridge-ring-request-seed-#{index}"

        preferred =
          [setup.assignment.id, fallback.assignment.id]
          |> Enum.max_by(&rendezvous_score(seed, &1))

        if preferred == setup.assignment.id, do: seed
      end) || raise "missing bridge ring request seed for #{setup.assignment.id}"

    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    task =
      Task.async(fn ->
        execute_websocket_response(
          auth,
          model_serving_websocket_payload(setup, "cross-assignment", "client-true"),
          %{request_id: request_id, connect_timeout_ms: 100},
          fn frame -> send(parent, {:websocket_frame, frame}) end
        )
      end)

    assert_receive {:fake_upstream_timeout_barrier, :websocket_upgrade, upstream_pid,
                    ^release_ref},
                   1_000

    try do
      _revision = set_model_serving_mode!(scope, setup, "lite", revision)
      assert Task.yield(task, 0) == nil
      assert :ok = Task.await(task, 3_000)
    after
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    end

    assert_received {:websocket_frame, frame}
    assert websocket_response_id(frame) == "resp_ws_mode_cross_assignment_failover"
    assert [fallback_request] = FakeUpstream.requests(fallback_upstream)
    assert_canonical_full_websocket_request!(fallback_request)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1

    assert [first_attempt, second_attempt] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.pool_upstream_assignment_id == fallback.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert second_attempt.status == "succeeded"
    assert_model_serving_accounting!(request, "full", [first_attempt, second_attempt])
  end

  test "catalog headers are absent from every excluded controller route" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_catalog_header_exclusion",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    public_models = build_conn() |> auth(setup) |> get("/v1/models")
    assert %{"object" => "list", "data" => [_model]} = json_response(public_models, 200)
    assert_no_catalog_headers(public_models)

    public_response =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("synthetic public response exclusion"),
        "stream" => false
      })

    assert %{"id" => "resp_catalog_header_exclusion", "object" => "response"} =
             json_response(public_response, 200)

    assert_no_catalog_headers(public_response)

    {public_ws_conn, _websocket, _ref, public_ws_headers} =
      public_websocket_connect_with_headers!(port, setup, "", "/v1/responses")

    try do
      refute List.keyfind(public_ws_headers, "etag", 0)
      refute List.keyfind(public_ws_headers, "x-models-etag", 0)
    after
      Mint.HTTP.close(public_ws_conn)
    end

    for path <- [
          "/backend-api/codex/responses/compact",
          "/backend-api/codex/v1/responses/compact"
        ] do
      conn =
        build_conn()
        |> auth(setup)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic backend compact exclusion")
        })

      assert conn.status == 200
      assert_no_catalog_headers(conn)
    end

    public_compact =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("synthetic public compact exclusion")
      })

    assert json_response(public_compact, 404)["error"]["code"] == "unsupported_endpoint"
    assert_no_catalog_headers(public_compact)

    for {path, expected_key} <- [
          {"/api/codex/usage", "rate_limit"},
          {"/wham/usage", "rate_limit"},
          {"/backend-api/wham/usage", "rate_limit"},
          {"/v1/usage", "total_tokens"}
        ] do
      conn = build_conn() |> auth(setup) |> get(path)
      assert Map.has_key?(json_response(conn, 200), expected_key)
      assert_no_catalog_headers(conn)
    end

    for path <- [
          "/backend-api/codex/models",
          "/backend-api/codex/v1/models",
          "/backend-api/codex/responses",
          "/backend-api/codex/v1/responses"
        ] do
      conn = get(build_conn(), path)
      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      assert_no_catalog_headers(conn)
    end

    health = get(build_conn(), "/healthz")
    assert json_response(health, 200) == %{"status" => "ok"}
    assert_no_catalog_headers(health)
  end

  defp assert_no_catalog_headers(conn) do
    assert get_resp_header(conn, "etag") == []
    assert get_resp_header(conn, "x-models-etag") == []
  end

  defp model_serving_websocket_payload(setup, label, spoofed_lite_value) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("synthetic websocket mode #{label}"),
      "stream" => true,
      "generate" => true,
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "medium", "context" => "current_turn"},
      "client_metadata" => %{
        @responses_lite_client_metadata_key => spoofed_lite_value,
        "model_serving_mode" => "unknown"
      }
    })
  end

  defp websocket_response_id(frame) do
    decoded = CodexPooler.JSON.decode!(frame)
    decoded["id"] || get_in(decoded, ["response", "id"])
  end

  defp assert_canonical_lite_websocket_request!(captured) do
    assert captured.method == "WEBSOCKET"

    assert get_in(captured.json, ["client_metadata", @responses_lite_client_metadata_key]) ==
             "true"

    assert captured.json["parallel_tool_calls"] == false
    assert get_in(captured.json, ["reasoning", "context"]) == "all_turns"
  end

  defp assert_canonical_full_websocket_request!(captured) do
    assert captured.method == "WEBSOCKET"

    refute get_in(captured.json, ["client_metadata", @responses_lite_client_metadata_key])
    assert captured.json["parallel_tool_calls"] == true
    assert get_in(captured.json, ["reasoning", "context"]) == "current_turn"
  end

  defp assert_catalog_etag_header!(headers, true) do
    assert {"x-models-etag", _etag} = List.keyfind(headers, "x-models-etag", 0)
  end

  defp assert_catalog_etag_header!(headers, false) do
    refute List.keyfind(headers, "x-models-etag", 0)
  end

  defp assert_model_serving_accounting!(request, mode, attempts \\ nil) do
    expected = %{
      "model_serving_mode_configured" => mode,
      "model_serving_mode" => mode,
      "model_serving_mode_source" => "override"
    }

    assert request.transport == "websocket"
    assert Map.take(request.request_metadata["routing"], @model_serving_metadata_keys) == expected

    attempts =
      attempts ||
        Repo.all(
          from(attempt in Attempt,
            where: attempt.request_id == ^request.id,
            order_by: [asc: attempt.attempt_number]
          )
        )

    refute attempts == []

    for attempt <- attempts do
      assert attempt.transport == "websocket"

      assert Map.take(attempt.response_metadata["routing"], @model_serving_metadata_keys) ==
               expected
    end
  end
end
