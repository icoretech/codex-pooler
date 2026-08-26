defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPoolerWeb.CodexResponsesSocket

  @turn_state_param "client_metadata.x-codex-turn-state"
  @detection_timeout_ms 15_000
  @stale_native_content "stale-native-content-must-not-succeed"
  @remote_compaction_v2_fixture_path Path.expand(
                                       "../../../fixtures/codex/rust-v0.149.1-ff29a44391deccde0aba0f8390337d7f3c319ea4/remote_compaction_v2_request.json",
                                       __DIR__
                                     )
  @external_resource @remote_compaction_v2_fixture_path
  @incremental_compaction_fixture_path Path.expand(
                                         "../../../fixtures/codex/rust-v0.149.1-ff29a44391deccde0aba0f8390337d7f3c319ea4/remote_compaction_v2_incremental_request.json",
                                         __DIR__
                                       )
  @external_resource @incremental_compaction_fixture_path

  for {path, transport, optional_metadata} <- [
        {"/backend-api/codex/responses", :buffered, :valid},
        {"/backend-api/codex/v1/responses", :buffered, :malformed},
        {"/backend-api/codex/responses", :sse, :valid},
        {"/backend-api/codex/v1/responses", :sse, :malformed}
      ] do
    if transport == :sse do
      @tag :codex_remote_compaction_v2
    end

    test "#{path} completes #{transport} native compaction and reuses the downstream socket" do
      path = unquote(path)
      transport = unquote(transport)
      optional_metadata = unquote(optional_metadata)
      admission_events = attach_admission_telemetry()

      fixture = native_compaction_fixture(transport, optional_metadata)

      upstream =
        start_upstream(
          {:sequence,
           [
             fixture.upstream_mode,
             FakeUpstream.json_response(%{
               "id" => fixture.follow_up_response_id,
               "object" => "response",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
             })
           ]}
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()
      upgrade_turn_state = "upgrade-#{fixture.case_id}"
      frame_turn_state = "frame-#{fixture.case_id}"

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, upgrade_turn_state, path)

      try do
        payload = compact_payload(setup, frame_turn_state, transport)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, websocket, done_frame} = public_websocket_receive_text!(conn, websocket, ref)
        {conn, websocket, completed_frame} = public_websocket_receive_text!(conn, websocket, ref)

        item = fixture.expected_item

        assert Jason.decode!(done_frame) == %{
                 "type" => "response.output_item.done",
                 "item" => item
               }

        assert Jason.decode!(completed_frame) == %{
                 "type" => "response.completed",
                 "response" => %{
                   "id" => fixture.response_id,
                   "status" => "completed",
                   "output" => [item],
                   "usage" => %{
                     "input_tokens" => 6,
                     "output_tokens" => 2,
                     "total_tokens" => 8
                   }
                 }
               }

        refute done_frame =~ fixture.omitted_sentinel
        refute completed_frame =~ fixture.omitted_sentinel

        assert_admission_events(admission_events, ["proxy_websocket", "proxy_compact"])

        assert [compact_request] = FakeUpstream.requests(upstream)
        assert compact_request.method == "POST"
        assert compact_request.path == "/backend-api/codex/responses"
        assert compact_request.json["store"] == false
        assert compact_request.json["model"] == setup.model.upstream_model_id
        assert List.last(compact_request.json["input"]) == %{"type" => "compaction_trigger"}

        assert Enum.map(compact_request.json["input"], & &1["type"]) == [
                 "message",
                 "compaction_trigger"
               ]

        assert_compact_transport_payload(compact_request.json, transport)

        refute Map.has_key?(compact_request.json, "type")
        refute Map.has_key?(compact_request.json, "generate")
        refute Map.has_key?(compact_request.json, "client_metadata")

        assert header_values(compact_request.headers, "x-codex-turn-state") == [
                 frame_turn_state
               ]

        assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
        assert request.endpoint == "/backend-api/codex/responses/compact"
        assert request.transport == "http_compact_json"
        assert request.status == "succeeded"
        assert request.request_metadata["codex_session_id"]

        assert request.request_metadata["compaction_bridge"] == %{
                 "applied" => true,
                 "result_transport" => Atom.to_string(transport)
               }

        assert get_in(request.request_metadata, ["reservation_snapshot_inputs", "route_class"]) ==
                 "proxy_compact"

        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
        assert attempt.request_id == request.id
        assert attempt.transport == "http_compact_json"
        assert attempt.status == "succeeded"
        assert attempt.pool_upstream_assignment_id == setup.assignment.id
        assert attempt.upstream_identity_id == setup.identity.id
        assert settlement_count(request.id) == 1

        assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
        assert turn.codex_session_id == request.request_metadata["codex_session_id"]
        assert turn.status == "succeeded"
        assert turn.transport_kind == "http_json"
        assert turn.final_attempt_id == attempt.id
        assert turn.completed_at

        assert %CodexSession{id: session_id, status: "active"} =
                 Repo.get!(CodexSession, turn.codex_session_id)

        assert Repo.exists?(
                 from(alias_record in BridgeSessionAlias,
                   where:
                     alias_record.codex_session_id == ^session_id and
                       alias_record.alias_kind == "turn_state" and
                       alias_record.alias_hash == ^:crypto.hash(:sha256, frame_turn_state) and
                       alias_record.status == "active"
                 )
               )

        assert_no_raw_compaction_persistence(setup, [
          fixture.encrypted_content,
          fixture.response_id,
          fixture.item_id,
          fixture.turn_id,
          fixture.omitted_sentinel,
          frame_turn_state
        ])

        follow_up_payload = ordinary_payload(setup)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, follow_up_payload)

        {_conn, _websocket, follow_up_frame} =
          public_websocket_receive_text!(conn, websocket, ref)

        assert %{"id" => follow_up_response_id} = Jason.decode!(follow_up_frame)
        assert follow_up_response_id == fixture.follow_up_response_id

        assert [^compact_request, ordinary_request] = FakeUpstream.requests(upstream)
        assert ordinary_request.method == "WEBSOCKET"
        assert ordinary_request.path == "/backend-api/codex/responses"
        assert FakeUpstream.websocket_connection_count(upstream) == 1

        assert [compact_log, ordinary_log] =
                 Repo.all(
                   from(r in Request,
                     where: r.pool_id == ^setup.pool.id,
                     order_by: [asc: r.admitted_at, asc: r.id]
                   )
                 )

        assert compact_log.id == request.id
        assert ordinary_log.endpoint == "/backend-api/codex/responses"
        assert ordinary_log.transport == "websocket"
        assert ordinary_log.request_metadata["codex_session_id"] == session_id
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "source-derived incremental compaction stays on the response lineage assignment and reuses the socket" do
    fixture = incremental_compaction_fixture!()

    for scenario_name <- [
          "anchored_tool_output_and_trigger",
          "anchored_trigger_only",
          "full_history_without_anchor"
        ] do
      source_frame =
        get_in(fixture, ["scenarios", scenario_name, "projection_relevant_frame_subset"])

      compact_item = incremental_compaction_item("success-#{scenario_name}")

      assignment_a_upstream =
        start_upstream(
          {:sequence,
           [
             ordinary_response(fixture["provider_response_id"]),
             incremental_compaction_response(compact_item, "resp_compact_#{scenario_name}"),
             ordinary_response("resp_follow_up_#{scenario_name}")
           ]}
        )

      assignment_b_upstream =
        start_upstream(ordinary_response("resp_assignment_b_should_not_run_#{scenario_name}"))

      setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)
      admission_events = attach_admission_telemetry()
      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(
          port,
          setup,
          "incremental-#{scenario_name}",
          "/backend-api/codex/responses"
        )

      try do
        lineage_payload = ordinary_payload(setup)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)
        {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{"id" => response_id} = Jason.decode!(lineage_frame)
        assert response_id == fixture["provider_response_id"]

        setup = activate_assignment_b(setup)

        compact_payload =
          incremental_compact_payload(
            setup,
            source_frame,
            "compact-#{scenario_name}"
          )

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
        {conn, websocket, done_frame} = public_websocket_receive_text!(conn, websocket, ref)
        {conn, websocket, completed_frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert Jason.decode!(done_frame) == %{
                 "type" => "response.output_item.done",
                 "item" => compact_item
               }

        assert %{
                 "type" => "response.completed",
                 "response" => %{"status" => "completed", "output" => [^compact_item]}
               } = Jason.decode!(completed_frame)

        assert [lineage_request, compact_request] =
                 FakeUpstream.requests(assignment_a_upstream)

        assert lineage_request.method == "WEBSOCKET"
        assert compact_request.method == "POST"
        assert compact_request.path == "/backend-api/codex/responses"
        assert compact_request.json["input"] == source_frame["input"]
        assert compact_request.json["store"] == false
        assert compact_request.json["stream"] == true

        assert Map.get(compact_request.json, "previous_response_id") ==
                 Map.get(source_frame, "previous_response_id")

        assert get_in(source_frame, ["client_metadata", "x-codex-turn-metadata"]) ==
                 get_in(fixture, ["v2_trigger_metadata", "x-codex-turn-metadata"])

        assert FakeUpstream.count(assignment_b_upstream) == 0

        assert_admission_events(admission_events, [
          "proxy_websocket",
          "proxy_websocket",
          "proxy_compact"
        ])

        compact_log =
          Repo.one!(
            from(request in Request,
              where:
                request.pool_id == ^setup.pool.id and
                  request.endpoint == "/backend-api/codex/responses/compact"
            )
          )

        assert compact_log.transport == "http_compact_json"
        assert compact_log.status == "succeeded"
        assert compact_log.retry_count == 0

        assert compact_log.request_metadata["compaction_bridge"] == %{
                 "applied" => true,
                 "result_transport" => "sse"
               }

        assert [compact_attempt] =
                 Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

        assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id
        assert compact_attempt.upstream_identity_id == setup.identity.id
        assert compact_attempt.status == "succeeded"
        refute compact_attempt.retryable
        assert settlement_count(compact_log.id) == 1

        assert [compact_turn] =
                 Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

        assert compact_turn.status == "succeeded"
        assert compact_turn.final_attempt_id == compact_attempt.id

        follow_up_payload =
          ordinary_payload(setup, %{
            "request_id" => "full-follow-up-#{scenario_name}",
            "input" => [
              %{
                "type" => "message",
                "role" => "user",
                "content" => "full follow-up after #{scenario_name}"
              }
            ]
          })

        {conn, websocket} =
          public_websocket_send_text!(conn, websocket, ref, follow_up_payload)

        {_conn, _websocket, follow_up_frame} =
          public_websocket_receive_text!(conn, websocket, ref)

        assert %{"id" => "resp_follow_up_" <> ^scenario_name} = Jason.decode!(follow_up_frame)

        assert [^lineage_request, ^compact_request, follow_up_request] =
                 FakeUpstream.requests(assignment_a_upstream)

        assert follow_up_request.method == "WEBSOCKET"
        refute Map.has_key?(follow_up_request.json, "previous_response_id")
        assert FakeUpstream.websocket_connection_count(assignment_a_upstream) == 1
        assert FakeUpstream.count(assignment_b_upstream) == 0
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "provider 400 on pinned incremental compaction is safe and leaves the socket reusable" do
    fixture = incremental_compaction_fixture!()

    source_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_tool_output_and_trigger",
        "projection_relevant_frame_subset"
      ])

    provider_message = "synthetic private provider rejection"

    provider_error = %{
      "code" => "invalid_request_error",
      "type" => "invalid_request_error",
      "param" => "input",
      "message" => provider_message
    }

    assignment_a_upstream =
      start_upstream(
        {:sequence,
         [
           ordinary_response(fixture["provider_response_id"]),
           FakeUpstream.json_response(%{"error" => provider_error}, 400),
           ordinary_response("resp_after_compact_provider_400")
         ]}
      )

    assignment_b_upstream =
      start_upstream(ordinary_response("resp_provider_400_fallback_should_not_run"))

    setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "provider-400-compact")

    try do
      lineage_payload = ordinary_payload(setup)

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)
      {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"id" => response_id} = Jason.decode!(lineage_frame)
      assert response_id == fixture["provider_response_id"]

      setup = activate_assignment_b(setup)

      compact_payload = incremental_compact_payload(setup, source_frame, "provider-400-compact")
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
      {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "invalid_request_error",
                 "type" => "invalid_request_error",
                 "param" => "input"
               }
             } = Jason.decode!(error_frame)

      assert [lineage_request, compact_request] = FakeUpstream.requests(assignment_a_upstream)
      assert compact_request.method == "POST"
      assert compact_request.json["previous_response_id"] == fixture["provider_response_id"]
      assert FakeUpstream.count(assignment_b_upstream) == 0

      compact_log =
        Repo.one!(
          from(request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                request.endpoint == "/backend-api/codex/responses/compact"
          )
        )

      assert compact_log.status == "failed"
      assert compact_log.response_status_code == 400
      assert compact_log.retry_count == 0

      assert [compact_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

      assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert compact_attempt.status == "failed"
      assert compact_attempt.upstream_status_code == 400
      assert compact_attempt.network_error_code == "upstream_status"
      refute compact_attempt.retryable
      assert compact_attempt.response_metadata["rejection_error_code"] == "invalid_request_error"
      assert compact_attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
      assert compact_attempt.response_metadata["rejection_error_param"] == "input"
      assert settlement_count(compact_log.id) == 1

      assert [compact_turn] =
               Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

      assert compact_turn.status == "failed"
      assert compact_turn.final_attempt_id == compact_attempt.id
      refute inspect({compact_log, compact_attempt, compact_turn}) =~ provider_message

      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          ordinary_payload(setup, %{"request_id" => "full-after-provider-400"})
        )

      {_conn, _websocket, follow_up_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_after_compact_provider_400"} = Jason.decode!(follow_up_frame)

      assert [^lineage_request, ^compact_request, follow_up_request] =
               FakeUpstream.requests(assignment_a_upstream)

      assert follow_up_request.method == "WEBSOCKET"
      refute Map.has_key?(follow_up_request.json, "previous_response_id")
      assert FakeUpstream.websocket_connection_count(assignment_a_upstream) == 1
      assert FakeUpstream.count(assignment_b_upstream) == 0
    after
      Mint.HTTP.close(conn)
    end
  end

  test "misalignment provider rejection uses bounded native compact error without message leakage" do
    fixture = incremental_compaction_fixture!()

    source_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_tool_output_and_trigger",
        "projection_relevant_frame_subset"
      ])

    provider_message = "private-misalignment-message-must-not-reach-native-wire"

    provider_error = %{
      "code" => "misalignment_policy_violation",
      "type" => "invalid_request_error",
      "param" => "input",
      "message" => provider_message
    }

    assignment_a_upstream =
      start_upstream(
        {:sequence,
         [
           ordinary_response(fixture["provider_response_id"]),
           FakeUpstream.json_response(%{"error" => provider_error}, 400)
         ]}
      )

    assignment_b_upstream =
      start_upstream(ordinary_response("resp_misalignment_fallback_should_not_run"))

    setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "misalignment-compact")

    try do
      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, ordinary_payload(setup))

      {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"id" => response_id} = Jason.decode!(lineage_frame)
      assert response_id == fixture["provider_response_id"]

      setup = activate_assignment_b(setup)

      compact_payload = incremental_compact_payload(setup, source_frame, "misalignment-compact")
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
      {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "misalignment_policy_violation",
                 "type" => "invalid_request_error",
                 "param" => "input",
                 "message" => "upstream rejected the compact request"
               }
             } = Jason.decode!(error_frame)

      refute error_frame =~ provider_message
      assert FakeUpstream.count(assignment_b_upstream) == 0

      compact_log =
        Repo.one!(
          from(request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                request.endpoint == "/backend-api/codex/responses/compact"
          )
        )

      assert compact_log.status == "failed"
      assert compact_log.response_status_code == 400
      assert compact_log.retry_count == 0

      assert [compact_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

      assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert compact_attempt.network_error_code == "misalignment_policy_violation"

      assert compact_attempt.response_metadata["rejection_error_code"] ==
               "misalignment_policy_violation"

      assert compact_attempt.response_metadata["rejection_error_param"] == "input"
      assert settlement_count(compact_log.id) == 1

      refute inspect({compact_log.request_metadata, compact_attempt.response_metadata}) =~
               provider_message
    after
      Mint.HTTP.close(conn)
    end
  end

  test "unavailable pinned assignment fails closed without fallback" do
    fixture = incremental_compaction_fixture!()

    source_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_trigger_only",
        "projection_relevant_frame_subset"
      ])

    assignment_a_upstream = start_upstream(ordinary_response(fixture["provider_response_id"]))
    assignment_b_upstream = start_upstream(ordinary_response("resp_full_request_on_assignment_b"))
    setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "unavailable-pinned-compact")

    try do
      lineage_payload = ordinary_payload(setup)

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)
      {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"id" => response_id} = Jason.decode!(lineage_frame)
      assert response_id == fixture["provider_response_id"]

      setup = activate_assignment_b(setup)

      assert {:ok, _assignment} = PoolAssignments.disable_pool_assignment(setup.assignment)

      compact_payload =
        incremental_compact_payload(setup, source_frame, "unavailable-pinned-compact")

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
      {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 503,
               "error" => %{"code" => "pinned_continuation_unavailable"}
             } = Jason.decode!(error_frame)

      assert [_lineage_request] = FakeUpstream.requests(assignment_a_upstream)
      assert FakeUpstream.count(assignment_b_upstream) == 0

      denied_request =
        Repo.one!(
          from(request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                request.endpoint == "/backend-api/codex/responses/compact"
          )
        )

      assert denied_request.endpoint == "/backend-api/codex/responses/compact"
      assert denied_request.status == "rejected"
      assert denied_request.last_error_code == "pinned_continuation_unavailable"
      assert denied_request.retry_count == 0

      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^denied_request.id), :count) ==
               0

      assert settlement_count(denied_request.id) == 0

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.request_id == ^denied_request.id),
               :count
             ) == 0

      assert FakeUpstream.requests(assignment_b_upstream) == []
    after
      Mint.HTTP.close(conn)
    end
  end

  test "ordinary native frames keep permissive malformed turn-state behavior" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ordinary_permissive_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Websocket.start_codex_session(auth, %{})

    assert :ok =
             Service.execute_websocket_response(
               auth,
               ordinary_payload(setup, %{
                 "client_metadata" => %{"x-codex-turn-state" => ["still-permissive"]}
               }),
               RequestOptions.for_websocket(%{codex_session: session}),
               fn frame ->
                 unless StreamProtocol.internal_control_event?(frame) do
                   send(self(), {:frame, frame})
                 end
               end
             )

    assert_receive {:frame, frame}, @detection_timeout_ms
    assert %{"id" => "resp_ordinary_permissive_turn_state"} = Jason.decode!(frame)
    assert FakeUpstream.count(upstream) == 1
  end

  test "direct socket rejects malformed bridge turn state before side effects and remains reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_invalid_bridge_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = direct_socket(auth, "direct-invalid-bridge-turn-state")

    try do
      state =
        Enum.reduce(invalid_turn_states(), state, fn turn_state, state ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in(
                     {compact_payload(setup, turn_state), [opcode: :text]},
                     state
                   )

          assert {:push, {:text, error_frame}, next_state} = receive_socket_message(state)
          assert_invalid_turn_state_error(error_frame)
          assert FakeUpstream.count(upstream) == 0
          assert Repo.aggregate(Request, :count) == 0
          assert Repo.aggregate(Attempt, :count) == 0
          assert Repo.aggregate(LedgerEntry, :count) == 0
          next_state
        end)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {ordinary_payload(setup), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_socket_message(state)
      assert %{"id" => "resp_after_invalid_bridge_turn_state"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert FakeUpstream.count(upstream) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded socket rejects malformed bridge turn state before retarget and remains reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_after_invalid_bridge_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "owner-invalid-bridge-turn-state",
          accepted_turn_state: "owner-upgrade-turn-state",
          client_ip: "127.0.0.1"
        }
      })

    original_session_id = state.codex_session.id

    try do
      state =
        Enum.reduce(edge_wrapped_invalid_turn_states(), state, fn turn_state, state ->
          {:ok, target_state} =
            CodexResponsesSocket.init(%{
              auth: auth,
              opts: %{
                request_id:
                  "owner-invalid-bridge-turn-state-target-#{System.unique_integer([:positive])}",
                accepted_turn_state: turn_state,
                client_ip: "127.0.0.1"
              }
            })

          target_session_id = target_state.codex_session.id

          try do
            assert {:ok, state} =
                     CodexResponsesSocket.handle_in(
                       {compact_payload(setup, turn_state), [opcode: :text]},
                       state
                     )

            assert state.codex_session.id == original_session_id
            refute state.codex_session.id == target_session_id
            assert {:push, {:text, error_frame}, next_state} = receive_socket_message(state)
            assert_invalid_turn_state_error(error_frame)
            assert next_state.codex_session.id == original_session_id
            refute next_state.codex_session.id == target_session_id
            assert_no_invalid_turn_state_side_effects(upstream)
            next_state
          after
            CodexResponsesSocket.terminate(:closed, target_state)
          end
        end)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {ordinary_payload(setup), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_socket_message(state)
      assert %{"id" => "resp_owner_after_invalid_bridge_turn_state"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_completion(state)
      assert FakeUpstream.count(upstream) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "buffered native bridge forwards one validated frame turn state and adapts once after settlement" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_native_buffered_compaction",
          "output" => [
            %{
              "type" => "compaction",
              "encrypted_content" => "synthetic-native-buffered-encrypted"
            }
          ],
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      direct_socket(auth, "native-buffered-success",
        accepted_turn_state: "upgrade-turn-state",
        forwarded_headers: [
          {"X-Codex-Turn-State", "stale-one"},
          {"x-codex-turn-state", "stale-two"}
        ]
      )

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {compact_payload(setup, "  frame-turn-state  "), [opcode: :text]},
                 state
               )

      assert {:push, {:text, done_frame}, state} = receive_socket_message(state)
      assert {:push, {:text, completed_frame}, state} = receive_socket_message(state)
      assert {:ok, _state} = receive_socket_done(state)

      assert %{"type" => "response.output_item.done", "item" => item} = Jason.decode!(done_frame)

      assert %{
               "type" => "response.completed",
               "response" => %{"output" => [^item]}
             } = Jason.decode!(completed_frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "POST"
      assert captured.path == "/backend-api/codex/responses"

      assert Enum.filter(captured.headers, fn {name, _value} ->
               String.downcase(name) == "x-codex-turn-state"
             end) == [{"x-codex-turn-state", "frame-turn-state"}]

      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "succeeded"
      assert settlement_count(request.id) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "invalid buffered native compact bodies fail before success settlement" do
    cases = [
      {FakeUpstream.malformed_json("{malformed-native-compact", 200),
       "upstream compact response was not valid JSON"},
      {FakeUpstream.json_response(%{"id" => "resp_missing_native_compact_content"}),
       "upstream compact response did not include encrypted compaction content"},
      {buffered_native_compaction_response("resp_empty_native_compact_content", "", :output),
       "upstream compact response did not include encrypted compaction content"},
      {buffered_native_compaction_response(
         "resp_blank_native_compact_content",
         " \t\r\n",
         :top_level
       ), "upstream compact response did not include encrypted compaction content"}
    ]

    for {mode, expected_message} <- cases do
      upstream = start_upstream(mode)
      setup = gateway_setup(upstream, compact?: true)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Websocket.start_codex_session(auth, %{})

      assert {:error, error} =
               Service.execute_websocket_response(
                 auth,
                 compact_payload(setup, nil),
                 RequestOptions.for_websocket(%{codex_session: session}),
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      assert error.status == 502
      assert error.code == "invalid_compaction_response"
      assert error.message == expected_message
      refute_received {:unexpected_frame, _frame}

      assert [request] =
               Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

      assert request.status == "failed"
      assert request.last_error_code == "invalid_compaction_response"
      assert request.retry_count == 0

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "failed"
      assert attempt.network_error_code == "invalid_compaction_response"
      refute attempt.retryable

      assert [turn] =
               Repo.all(
                 from(turn in CodexTurn,
                   where: turn.codex_session_id == ^session.id and turn.request_id == ^request.id
                 )
               )

      assert turn.status == "failed"
      assert turn.error_code == "invalid_compaction_response"
      assert turn.final_attempt_id == attempt.id
      assert settlement_count(request.id) == 1
      refute inspect({request, attempt, turn}) =~ @stale_native_content
    end
  end

  test "native compact saturation emits one error, releases admission, and keeps the socket reusable" do
    unrelated_lease_holder = hold_admission_lease("proxy_http")
    configure_compact_saturation()

    assert {:ok, saturation} = Admission.saturation()
    assert saturation["proxy_http"] == %{running: 1, queued: 0}

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_native_compact_saturation",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()
    compact_lease_holder = hold_admission_lease("proxy_compact")

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "native-compact-saturation",
        "/backend-api/codex/responses"
      )

    try do
      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          compact_payload(setup, "native-compact-saturation", :buffered)
        )

      {conn, websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert Jason.decode!(error_frame) == %{
               "type" => "error",
               "status" => 503,
               "error" => %{
                 "code" => "server_is_overloaded",
                 "message" => "gateway route class is temporarily overloaded",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      assert_no_invalid_turn_state_side_effects(upstream)
      assert {:ok, saturation} = Admission.saturation()
      assert saturation["proxy_compact"] == %{running: 1, queued: 0}
      assert saturation["proxy_websocket"] == %{running: 0, queued: 0}

      release_admission_lease(compact_lease_holder)
      assert_admission_released("proxy_compact")

      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, ordinary_payload(setup))

      {_conn, _websocket, follow_up_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_after_native_compact_saturation"} = Jason.decode!(follow_up_frame)
      assert FakeUpstream.count(upstream) == 1

      assert [request] = Repo.all(Request)
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
    after
      release_admission_lease(compact_lease_holder)
      release_admission_lease(unrelated_lease_holder)
      Mint.HTTP.close(conn)
    end
  end

  test "malformed native compact triggers dispatch nothing and keep the downstream socket reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_malformed_native_compact",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "malformed-native-compact",
        "/backend-api/codex/v1/responses"
      )

    try do
      {conn, websocket} =
        Enum.reduce(malformed_compact_payloads(setup), {conn, websocket}, fn payload,
                                                                             {conn, websocket} ->
          {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
          {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

          assert %{
                   "type" => "error",
                   "status" => 400,
                   "error" => %{"code" => "invalid_request", "param" => "input"}
                 } = Jason.decode!(frame)

          assert_no_invalid_turn_state_side_effects(upstream)
          {conn, websocket}
        end)

      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, ordinary_payload(setup))

      {_conn, _websocket, follow_up_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_after_malformed_native_compact"} = Jason.decode!(follow_up_frame)
      assert FakeUpstream.count(upstream) == 1
    after
      Mint.HTTP.close(conn)
    end
  end

  defp direct_socket(auth, request_id, extra_opts \\ []) do
    CodexResponsesSocket.init(%{
      auth: auth,
      opts:
        Map.merge(
          %{request_id: request_id, client_ip: "127.0.0.1"},
          Map.new(extra_opts)
        )
    })
  end

  defp compact_payload(setup, turn_state, transport \\ :buffered) do
    client_metadata =
      if is_nil(turn_state), do: %{}, else: %{"x-codex-turn-state" => turn_state}

    client_metadata =
      if transport == :sse do
        remote_compaction_v2_client_metadata()
        |> Map.merge(client_metadata)
      else
        client_metadata
      end

    Jason.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "synthetic compact input"},
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true,
      "generate" => true,
      "client_metadata" => client_metadata
    })
  end

  defp incremental_compact_payload(setup, source_frame, request_id) do
    source_frame
    |> Map.put("model", setup.model.exposed_model_id)
    |> Map.put("generate", true)
    |> Map.put("request_id", request_id)
    |> Jason.encode!()
  end

  defp incremental_compaction_fixture! do
    @incremental_compaction_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("contract")
  end

  defp incremental_compaction_item(suffix) do
    %{
      "type" => "compaction",
      "encrypted_content" => "synthetic-incremental-#{suffix}"
    }
  end

  defp incremental_compaction_response(item, response_id) do
    FakeUpstream.sse_stream([
      {"response.output_item.done", %{"type" => "response.output_item.done", "item" => item}},
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "status" => "completed",
           "output" => [item]
         }
       }}
    ])
  end

  defp ordinary_response(response_id) do
    FakeUpstream.json_response(%{
      "id" => response_id,
      "object" => "response",
      "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
    })
  end

  defp two_assignment_setup_with_b_disabled(setup_upstream, assignment_b_upstream) do
    setup = gateway_setup(setup_upstream, compact?: true)

    assignment_b =
      gateway_upstream(
        setup.pool,
        assignment_b_upstream,
        "upstream-token-incremental-assignment-b",
        compact?: true
      )

    prime_routing_quota!(assignment_b.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    assert {:ok, assignment_b_record} =
             PoolAssignments.disable_pool_assignment(assignment_b.assignment)

    model =
      put_model_source_assignments!(setup.model, [setup.assignment, assignment_b.assignment])

    setup
    |> Map.put(:model, model)
    |> Map.put(:assignment_b, assignment_b_record)
    |> Map.put(:identity_b, assignment_b.identity)
  end

  defp activate_assignment_b(setup) do
    assert {:ok, assignment_b} = PoolAssignments.activate_pool_assignment(setup.assignment_b)
    %{setup | assignment_b: assignment_b}
  end

  defp remote_compaction_v2_client_metadata do
    @remote_compaction_v2_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["request", "client_metadata"])
  end

  defp ordinary_payload(setup, extra \\ %{}) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "ordinary turn"}],
      "stream" => true,
      "generate" => true
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp buffered_native_compaction_response(response_id, encrypted_content, :output) do
    FakeUpstream.json_response(%{
      "id" => response_id,
      "output" => [
        %{"type" => "compaction", "encrypted_content" => encrypted_content},
        %{"type" => "compaction_summary", "encrypted_content" => @stale_native_content}
      ],
      "compaction_summary" => %{"encrypted_content" => @stale_native_content}
    })
  end

  defp buffered_native_compaction_response(response_id, encrypted_content, :top_level) do
    FakeUpstream.json_response(%{
      "id" => response_id,
      "compaction_summary" => %{"encrypted_content" => encrypted_content}
    })
  end

  defp invalid_turn_states do
    [
      ["wrong-type"],
      "   ",
      "control\tvalue",
      "non-ascii-\u00e9",
      String.duplicate("a", 4_097)
    ] ++ edge_wrapped_invalid_turn_states()
  end

  defp edge_wrapped_invalid_turn_states do
    [
      "\tvalid",
      "valid\t",
      "\rvalid",
      "valid\r",
      "\nvalid",
      "valid\n",
      "\r\nvalid",
      "valid\r\n",
      "\u00A0valid",
      "valid\u00A0",
      "\u00A0valid\u00A0"
    ]
  end

  defp malformed_compact_payloads(setup) do
    visible = %{"type" => "message", "role" => "user", "content" => "synthetic visible"}
    hidden = %{"type" => "reasoning", "encrypted_content" => "synthetic hidden"}
    trigger = %{"type" => "compaction_trigger"}

    for input <- [
          [visible, trigger, visible],
          [visible, trigger, trigger],
          [hidden, trigger]
        ] do
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => input,
        "stream" => true,
        "generate" => true
      })
    end
  end

  defp assert_invalid_turn_state_error(frame) do
    assert %{
             "type" => "error",
             "error" => %{
               "code" => "invalid_request",
               "param" => @turn_state_param
             }
           } = Jason.decode!(frame)

    refute frame =~ "wrong-type"
    refute frame =~ "control"
    refute frame =~ "non-ascii"
  end

  defp assert_no_invalid_turn_state_side_effects(upstream) do
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  defp settlement_count(request_id) do
    Repo.aggregate(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
      ),
      :count
    )
  end

  defp native_compaction_fixture(transport, optional_metadata) do
    suffix = "#{transport}_#{optional_metadata}"
    encrypted_content = "synthetic-native-#{suffix}-encrypted"
    item_id = "cmp_native_#{suffix}"
    turn_id = "turn_native_#{suffix}"
    omitted_sentinel = "native-#{suffix}-must-not-survive"
    response_id = "resp_native_#{suffix}"

    source_item =
      %{
        "type" => "compaction",
        "encrypted_content" => encrypted_content,
        "summary" => omitted_sentinel
      }
      |> put_optional_metadata(optional_metadata, item_id, turn_id, omitted_sentinel)

    expected_item =
      %{
        "type" => "compaction",
        "encrypted_content" => encrypted_content
      }
      |> put_expected_metadata(optional_metadata, item_id, turn_id)

    response = %{
      "id" => response_id,
      "output" => [source_item],
      "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
    }

    upstream_mode =
      case transport do
        :buffered ->
          FakeUpstream.json_response(response)

        :sse ->
          FakeUpstream.sse_stream([
            {"response.output_item.done",
             %{"type" => "response.output_item.done", "item" => source_item}},
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => Map.put(response, "status", "completed")
             }}
          ])
      end

    %{
      case_id: suffix,
      encrypted_content: encrypted_content,
      expected_item: expected_item,
      follow_up_response_id: "resp_native_#{suffix}_follow_up",
      item_id: item_id,
      omitted_sentinel: omitted_sentinel,
      response_id: response_id,
      turn_id: turn_id,
      upstream_mode: upstream_mode
    }
  end

  defp put_optional_metadata(item, :valid, item_id, turn_id, omitted_sentinel) do
    item
    |> Map.put("id", item_id)
    |> Map.put("internal_chat_message_metadata_passthrough", %{
      "turn_id" => turn_id,
      "unknown" => omitted_sentinel
    })
  end

  defp put_optional_metadata(item, :malformed, _item_id, _turn_id, omitted_sentinel) do
    item
    |> Map.put("id", 17)
    |> Map.put("internal_chat_message_metadata_passthrough", %{
      "turn_id" => [omitted_sentinel]
    })
  end

  defp put_expected_metadata(item, :valid, item_id, turn_id) do
    item
    |> Map.put("id", item_id)
    |> Map.put("internal_chat_message_metadata_passthrough", %{"turn_id" => turn_id})
  end

  defp put_expected_metadata(item, :malformed, _item_id, _turn_id), do: item

  defp header_values(headers, target_name) do
    for {name, value} <- headers, String.downcase(name) == target_name, do: value
  end

  defp assert_no_raw_compaction_persistence(setup, forbidden_values) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from(a in Attempt, where: a.request_id in ^request_ids))
    ledger_entries = Repo.all(from(e in LedgerEntry, where: e.request_id in ^request_ids))
    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    session_ids = Enum.map(sessions, & &1.id)
    turns = Repo.all(from(t in CodexTurn, where: t.codex_session_id in ^session_ids))
    aliases = Repo.all(from(a in BridgeSessionAlias, where: a.codex_session_id in ^session_ids))
    durable_text = inspect({requests, attempts, ledger_entries, sessions, turns, aliases})

    for value <- forbidden_values, is_binary(value) do
      refute durable_text =~ value
    end
  end

  defp attach_admission_telemetry do
    {:ok, event_store} = Agent.start_link(fn -> [] end)
    handler_id = "native-compact-admission-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :admission, :accepted],
        fn _event, _measurements, metadata, event_store ->
          Agent.get_and_update(event_store, fn events -> {:ok, [metadata | events]} end)
        end,
        event_store
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if Process.alive?(event_store) do
        Agent.stop(event_store)
      end
    end)

    event_store
  end

  defp assert_admission_events(event_store, expected_route_classes) do
    _ = :sys.get_state(Admission)

    route_classes =
      Agent.get(event_store, fn events ->
        events
        |> Enum.reverse()
        |> Enum.map(& &1.route_class)
      end)

    assert route_classes == expected_route_classes
    assert Enum.frequencies(route_classes) == Enum.frequencies(expected_route_classes)
  end

  defp assert_compact_transport_payload(payload, :buffered) do
    refute Map.has_key?(payload, "stream")
  end

  defp assert_compact_transport_payload(payload, :sse) do
    assert payload["stream"] == true
  end

  defp configure_compact_saturation do
    old_config = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: compact_saturation_settings()
    )

    on_exit(fn ->
      if old_config do
        Application.put_env(:codex_pooler, OperationalSettings, old_config)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  defp compact_saturation_settings do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class, %{max_concurrency: 4, queue_limit: 4, queue_timeout_ms: 1_000}}
        end)
        |> Map.put("proxy_compact", %{
          max_concurrency: 1,
          queue_limit: 0,
          queue_timeout_ms: 1_000
        })
    }
  end

  defp assert_admission_released(route_class) do
    _ = :sys.get_state(Admission)
    assert {:ok, saturation} = Admission.saturation()
    assert saturation[route_class] == %{running: 0, queued: 0}
  end

  defp hold_admission_lease(route_class) do
    parent = self()
    holder_ref = make_ref()

    holder_pid =
      spawn_link(fn ->
        {:ok, lease} = Admission.acquire(route_class, %{request_id: "held-#{route_class}"})
        send(parent, {:admission_lease_held, holder_ref})

        receive do
          {:release_admission_lease, ^holder_ref} -> Admission.release(lease)
        after
          @detection_timeout_ms -> Admission.release(lease)
        end
      end)

    assert_receive {:admission_lease_held, ^holder_ref}, @detection_timeout_ms
    {holder_pid, holder_ref}
  end

  defp release_admission_lease({holder_pid, holder_ref}) do
    if Process.alive?(holder_pid) do
      monitor = Process.monitor(holder_pid)
      send(holder_pid, {:release_admission_lease, holder_ref})
      assert_receive {:DOWN, ^monitor, :process, ^holder_pid, :normal}, @detection_timeout_ms
    end

    :ok
  end

  defp receive_socket_message(state) do
    receive do
      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:push, {:text, frame}, next_state} = result ->
            if StreamProtocol.internal_control_event?(frame) do
              receive_socket_message(next_state)
            else
              result
            end

          {:ok, next_state} ->
            receive_socket_message(next_state)
        end
    after
      @detection_timeout_ms -> flunk("expected websocket frame")
    end
  end

  defp receive_socket_completion(state) do
    receive do
      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:ok, next_state} = result ->
            if MapSet.size(Map.get(next_state, :tasks, MapSet.new())) == 0 do
              result
            else
              receive_socket_completion(next_state)
            end

          {:push, _frame, next_state} ->
            receive_socket_completion(next_state)
        end
    after
      @detection_timeout_ms -> flunk("expected websocket completion")
    end
  end
end
