defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.DispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.CodexClientIdentity

  test "backend websocket selected partition failure creates no accounting work" do
    selected_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch_selected"}))

    divergent_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch_divergent"}))

    setup = gateway_setup(selected_upstream)

    divergent =
      gateway_upstream(
        setup.pool,
        divergent_upstream,
        "upstream-token-ws-divergent-partition",
        compact?: false
      )

    prime_routing_quota!(divergent.identity)

    canonical_anchor_time = ~U[2026-07-30 08:00:00.000000Z]

    Repo.update_all(
      from(assignment in CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
        where: assignment.id == ^setup.assignment.id
      ),
      set: [created_at: canonical_anchor_time]
    )

    Repo.update_all(
      from(assignment in CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
        where: assignment.id == ^divergent.assignment.id
      ),
      set: [created_at: DateTime.add(canonical_anchor_time, 1, :second)]
    )

    selected_source = %{
      "slug" => setup.model.exposed_model_id,
      "id" => setup.model.upstream_model_id,
      "capabilities" => %{"responses" => false, "streaming" => true}
    }

    divergent_source = %{
      "slug" => setup.model.exposed_model_id,
      "id" => setup.model.upstream_model_id,
      "capabilities" => %{"responses" => true, "streaming" => true}
    }

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id, divergent.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => selected_source,
            divergent.assignment.id => divergent_source
          },
          "upstream_model" => divergent_source
        }
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)
    port = start_public_endpoint!()
    turn_state = "ws-selected-partition-#{System.unique_integer([:positive])}"
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => model.exposed_model_id,
          "input" => native_text_input("synthetic selected partition failure"),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 503,
               "error" => %{"code" => "no_eligible_backend"}
             } = CodexPooler.JSON.decode!(frame)

      assert FakeUpstream.count(selected_upstream) == 0
      assert FakeUpstream.count(divergent_upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "backend websocket malformed canonical hard pin creates no accounting work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          setup.model.metadata
          | "source_assignment_models" => %{setup.assignment.id => "malformed"}
        }
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    source_turn_state = "ws-malformed-source-#{System.unique_integer([:positive])}"
    previous_response_id = "resp_ws_malformed_source_#{System.unique_integer([:positive])}"
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: source_turn_state})
    session = pin_session_to_assignment!(session, setup.assignment)

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               CodexPooler.JSON.encode!(%{"id" => previous_response_id})
             )

    port = start_public_endpoint!()
    turn_state = "ws-malformed-pin-#{System.unique_integer([:positive])}"
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => model.exposed_model_id,
          "input" => native_text_input("synthetic malformed canonical pin"),
          "previous_response_id" => previous_response_id,
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 503,
               "error" => %{"code" => "pinned_continuation_unavailable"}
             } = CodexPooler.JSON.decode!(frame)

      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0

      conn
    after
      Mint.HTTP.close(conn)
    end
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
      "input" => native_text_input("hello over typed ws"),
      "stream" => true
    }

    options =
      %{request_id: "ws-typed-options", client_ip: "127.0.0.1", codex_session: session}
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.put_routing(quota_decision: %{"summary" => "prebuilt"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(payload),
               options,
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_typed_options"} = CodexPooler.JSON.decode!(frame)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id
  end

  test "websocket dispatch synthesizes Codex identity and ignores runtime metadata headers" do
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
    lineage_metadata = CodexPooler.JSON.encode!(%{"forked_from_thread_id" => lineage_id})

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
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
                 "stream" => true,
                 "generate" => true
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
    assert %{"id" => "resp_ws_forwarded_metadata_ignored"} = CodexPooler.JSON.decode!(frame)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "WEBSOCKET"
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["type"] == "response.create"
    assert captured.json["generate"] == true
    refute Map.has_key?(captured.json, "previous_response_id")
    assert header!(captured.headers, "openai-beta") == "responses_websockets=2026-02-06"

    assert header!(captured.headers, "user-agent") ==
             "codex_cli_rs/#{CodexClientIdentity.version()}"

    assert header!(captured.headers, "originator") == CodexClientIdentity.originator()
    assert header!(captured.headers, "version") == CodexClientIdentity.version()

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
               CodexPooler.JSON.encode!(%{
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
    assert %{"id" => "resp_ws_client_metadata_responses_lite"} = CodexPooler.JSON.decode!(frame)

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
               CodexPooler.JSON.encode!(%{
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
    assert %{"id" => "resp_ws_request_scoped_turn_state"} = CodexPooler.JSON.decode!(frame)

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
                 CodexPooler.JSON.encode!(%{
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
      assert %{"id" => "resp_ws_malformed_turn_state"} = CodexPooler.JSON.decode!(frame)
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
               CodexPooler.JSON.encode!(%{
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
    assert %{"id" => "resp_ws_responses_lite_marker"} = CodexPooler.JSON.decode!(frame)

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
               CodexPooler.JSON.encode!(%{
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
    assert %{"id" => "resp_ws_responses_lite_spoof_ignored"} = CodexPooler.JSON.decode!(frame)

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
      "input" => native_text_input("gateway typed options")
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

  test "websocket generate false warmup completes locally without upstream dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-warmup"})

    result =
      execute_websocket_response(
        auth,
        CodexPooler.JSON.encode!(%{
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
             CodexPooler.JSON.decode!(created_frame)

    assert %{"type" => "response.completed", "response" => %{"id" => ""}} =
             CodexPooler.JSON.decode!(completed_frame)

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
        CodexPooler.JSON.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_ws_processed"
        }),
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
        CodexPooler.JSON.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_stale"
        }),
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

  defp client_metadata_fixture(label) do
    forked_thread_id = "client-metadata-fork-#{label}"
    window_id = "client-metadata-window-#{label}"
    sentinel = "client-metadata-sentinel-#{label}"

    turn_metadata =
      CodexPooler.JSON.encode!(%{
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
end
