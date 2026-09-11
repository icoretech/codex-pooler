defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RetargetTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient

  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      TurnBudgetNodeClient.reset()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "owner-forwarded immediate response create retargets socket owner runtime before spawning" do
    upstream =
      start_upstream(
        # Strict finite scenario: the anchor and the retargeted continuation are
        # the only sends, both on the target owner's single connection, and the
        # continuation carries the anchor id.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_immediate_retarget_anchor",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_immediate_retarget_anchor"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_immediate_retarget_success",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_state} = owner_socket(auth, "ws-owner-retarget-anchor", "retarget-target")

    anchor_payload =
      websocket_payload(setup, "owner retarget anchor", %{
        "request_id" => "ws-owner-retarget-anchor"
      })

    assert {:ok, target_state} =
             CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

    assert {:push, {:text, anchor_frame}, target_state} =
             receive_owner_socket_push(target_state)

    assert %{"id" => "resp_owner_immediate_retarget_anchor"} =
             CodexPooler.JSON.decode!(anchor_frame)

    assert {:ok, target_state} = receive_socket_done(target_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, target_state)

    target_session = target_state.codex_session

    {:ok, origin_state} = owner_socket(auth, "ws-owner-retarget-origin", "retarget-origin")
    origin_session = origin_state.codex_session

    continuation_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "owner retarget continuation"
          }
        ],
        "stream" => true,
        "generate" => true,
        "previous_response_id" => "resp_owner_immediate_retarget_anchor",
        "request_id" => "ws-owner-retarget-continuation"
      })

    assert {:ok, retargeted_state} =
             CodexResponsesSocket.handle_in(
               {continuation_payload, [opcode: :text]},
               origin_state
             )

    assert retargeted_state.codex_session.id == target_session.id
    refute retargeted_state.codex_session.id == origin_session.id
    assert retargeted_state.websocket_owner_lease_token == target_session.owner_lease_token
    assert retargeted_state.websocket_owner_downstream.epoch > 0

    assert {:push, {:text, retarget_frame}, retargeted_state} =
             receive_owner_socket_push(retargeted_state)

    assert %{"id" => "resp_owner_immediate_retarget_success"} =
             CodexPooler.JSON.decode!(retarget_frame)

    assert {:ok, retargeted_state} = receive_socket_done(retargeted_state)

    assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)

    assert anchor_request.websocket_connection_id ==
             retargeted_request.websocket_connection_id

    assert retargeted_request.json["previous_response_id"] ==
             "resp_owner_immediate_retarget_anchor"

    assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
    assert anchor_log.status == "succeeded"
    assert retargeted_log.status == "succeeded"
    assert_native_turn_correlation!(retargeted_log.correlation_id)

    owner_metadata = retargeted_log.request_metadata["websocket_owner_forwarding"]
    assert owner_metadata["enabled"] == true
    assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
    assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, retargeted_state)
  end

  test "owner-forwarded response create retargets from frame turn-state before spawning" do
    target_turn_state = "stable-ws-owner-frame-turn-state-retarget"
    origin_turn_state = "stable-ws-owner-frame-turn-state-origin"

    upstream =
      start_upstream(
        # Strict finite scenario: the anchor and the turn-state retargeted
        # continuation are the only sends, both on the target owner's single
        # connection, and the continuation still carries the target turn state.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_turn_state_retarget_anchor",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "client_metadata.x-codex-turn-state" => target_turn_state
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_turn_state_retarget_success",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_state} =
      owner_socket(
        auth,
        "ws-owner-turn-state-retarget-anchor",
        target_turn_state
      )

    anchor_payload =
      websocket_payload(setup, "owner turn-state retarget anchor", %{
        "request_id" => "ws-owner-turn-state-retarget-anchor"
      })

    assert {:ok, target_state} =
             CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

    assert {:push, {:text, anchor_frame}, target_state} =
             receive_owner_socket_push(target_state)

    assert %{"id" => "resp_owner_turn_state_retarget_anchor"} =
             CodexPooler.JSON.decode!(anchor_frame)

    assert {:ok, target_state} = receive_socket_done(target_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, target_state)

    target_session = target_state.codex_session
    {:ok, origin_state} = owner_socket(auth, "ws-owner-turn-state-origin", origin_turn_state)
    origin_session = origin_state.codex_session

    continuation_payload =
      websocket_payload(setup, "owner turn-state retarget continuation", %{
        "client_metadata" => %{"x-codex-turn-state" => target_turn_state},
        "request_id" => "ws-owner-turn-state-retarget-continuation"
      })

    assert {:ok, retargeted_state} =
             CodexResponsesSocket.handle_in(
               {continuation_payload, [opcode: :text]},
               origin_state
             )

    assert retargeted_state.codex_session.id == target_session.id
    refute retargeted_state.codex_session.id == origin_session.id
    assert retargeted_state.websocket_owner_lease_token == target_session.owner_lease_token
    assert retargeted_state.websocket_owner_downstream.epoch > 0

    assert {:push, {:text, retarget_frame}, retargeted_state} =
             receive_owner_socket_push(retargeted_state)

    assert %{"id" => "resp_owner_turn_state_retarget_success"} =
             CodexPooler.JSON.decode!(retarget_frame)

    assert {:ok, retargeted_state} = receive_socket_done(retargeted_state)

    assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)

    assert anchor_request.websocket_connection_id ==
             retargeted_request.websocket_connection_id

    assert retargeted_request.json["client_metadata"]["x-codex-turn-state"] ==
             target_turn_state

    assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
    assert anchor_log.status == "succeeded"
    assert retargeted_log.status == "succeeded"
    assert_native_turn_correlation!(retargeted_log.correlation_id)
    assert retargeted_log.request_metadata["codex_session_id"] == target_session.id

    owner_metadata = retargeted_log.request_metadata["websocket_owner_forwarding"]
    assert owner_metadata["enabled"] == true
    assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
    assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

    refute_raw_turn_state_session_key!(setup.pool.id, origin_turn_state)
    refute_raw_turn_state_session_key!(setup.pool.id, target_turn_state)
    assert_no_leak_in_persistence!(setup.pool.id)

    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, retargeted_state)
  end

  test "owner-forwarded retarget ignores stale origin downstream and cleans up target owner" do
    upstream =
      start_upstream(
        # Strict finite scenario: the anchor and the retargeted continuation are
        # the only sends, both on the target owner's single connection, and the
        # continuation carries the anchor id.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_retarget_cleanup_anchor",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_retarget_cleanup_anchor"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_retarget_cleanup_success",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_state} =
      owner_socket(auth, "ws-owner-retarget-cleanup-anchor", "retarget-cleanup-target")

    target_state =
      try do
        anchor_payload =
          websocket_payload(setup, "owner retarget cleanup anchor", %{
            "request_id" => "ws-owner-retarget-cleanup-anchor"
          })

        assert {:ok, target_state} =
                 CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

        assert {:push, {:text, anchor_frame}, target_state} =
                 receive_owner_socket_push(target_state)

        assert %{"id" => "resp_owner_retarget_cleanup_anchor"} =
                 CodexPooler.JSON.decode!(anchor_frame)

        assert {:ok, target_state} = receive_socket_done(target_state)
        target_state
      after
        CodexResponsesSocket.terminate(:closed, target_state)
      end

    target_session = target_state.codex_session
    {:ok, target_owner_pid} = WebsocketOwnerSession.lookup(target_session.id)
    assert %{downstream: nil} = :sys.get_state(target_owner_pid)

    {:ok, origin_state} =
      owner_socket(auth, "ws-owner-retarget-cleanup-origin", "retarget-cleanup-origin")

    origin_session = origin_state.codex_session
    origin_downstream = origin_state.websocket_owner_downstream
    {:ok, origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

    retargeted_state =
      try do
        continuation_payload =
          websocket_payload(setup, "owner retarget cleanup continuation", %{
            "previous_response_id" => "resp_owner_retarget_cleanup_anchor",
            "request_id" => "ws-owner-retarget-cleanup-continuation"
          })

        assert {:ok, retargeted_state} =
                 CodexResponsesSocket.handle_in(
                   {continuation_payload, [opcode: :text]},
                   origin_state
                 )

        assert retargeted_state.codex_session.id == target_session.id
        refute retargeted_state.codex_session.id == origin_session.id
        assert retargeted_state.websocket_owner_lease_token == target_session.owner_lease_token
        assert retargeted_state.websocket_owner_downstream.epoch > 0
        assert :sys.get_state(origin_owner_pid).downstream == origin_downstream

        assert :sys.get_state(target_owner_pid).downstream ==
                 retargeted_state.websocket_owner_downstream

        {retargeted_state, stale_logs} =
          with_log([level: :warning], fn ->
            assert_stale_owner_downstream_ignored(
              origin_owner_pid,
              origin_downstream,
              retargeted_state
            )
          end)

        assert stale_logs == ""
        assert_no_leak!("stale origin downstream logs", stale_logs)

        assert {:push, {:text, retarget_frame}, retargeted_state} =
                 receive_owner_socket_push(retargeted_state)

        assert %{"id" => "resp_owner_retarget_cleanup_success"} =
                 CodexPooler.JSON.decode!(retarget_frame)

        assert {:ok, retargeted_state} = receive_socket_done(retargeted_state)
        retargeted_state
      after
        {_, origin_cleanup_logs} =
          with_log([level: :warning], fn ->
            assert :ok = CodexResponsesSocket.terminate(:closed, origin_state)
          end)

        assert origin_cleanup_logs == ""
        assert_no_leak!("stale origin cleanup logs", origin_cleanup_logs)
      end

    {_, target_cleanup_logs} =
      with_log([level: :warning], fn ->
        assert :ok = CodexResponsesSocket.terminate(:closed, retargeted_state)
      end)

    assert target_cleanup_logs == ""
    assert_no_leak!("retarget cleanup logs", target_cleanup_logs)
    assert %{downstream: nil} = :sys.get_state(target_owner_pid)
    assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)
    assert anchor_request.websocket_connection_id == retargeted_request.websocket_connection_id

    assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
    assert anchor_log.status == "succeeded"
    assert retargeted_log.status == "succeeded"
    assert_native_turn_correlation!(retargeted_log.correlation_id)
    refute inspect(request_logs(setup.pool.id)) =~ "owner_unavailable"
    refute inspect(request_logs(setup.pool.id)) =~ "owner_drained"
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "owner-forwarded retarget keeps the current runtime for a cross-pool alias cache miss before the generation guard" do
    origin_upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    target_upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    origin_setup = gateway_setup(origin_upstream)
    target_setup = gateway_setup(target_upstream)
    previous_response_id = "#{@sentinel}-cross-pool-alias"

    {:ok, origin_auth} = Access.authenticate_authorization_header(origin_setup.authorization)
    {:ok, target_auth} = Access.authenticate_authorization_header(target_setup.authorization)

    {:ok, target_state} =
      owner_socket(target_auth, "ws-owner-cross-scope-target", "cross-scope-target")

    try do
      ensure_previous_response_alias!(
        target_state.codex_session,
        target_setup.api_key,
        previous_response_id
      )
    after
      CodexResponsesSocket.terminate(:closed, target_state)
    end

    {:ok, origin_state} =
      owner_socket(origin_auth, "ws-owner-cross-scope-origin", "cross-scope-origin")

    origin_session = origin_state.codex_session
    origin_lease_token = origin_state.websocket_owner_lease_token
    origin_downstream = origin_state.websocket_owner_downstream

    try do
      payload =
        websocket_payload(origin_setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-cross-scope-refused"
        })

      {retarget_admitted_state, logs} =
        with_log([level: :warning], fn ->
          assert {:ok, retarget_admitted_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, origin_state)

          assert retarget_admitted_state.codex_session.id == origin_session.id
          assert retarget_admitted_state.websocket_owner_lease_token == origin_lease_token
          assert retarget_admitted_state.websocket_owner_downstream == origin_downstream

          assert {:ok, retarget_admitted_state} = receive_socket_done(retarget_admitted_state)

          retarget_admitted_state
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert retarget_admitted_state.codex_session.id == origin_session.id
      assert retarget_admitted_state.websocket_owner_lease_token == origin_lease_token
      assert retarget_admitted_state.websocket_owner_downstream == origin_downstream
      assert {:ok, _origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

      assert {:ok, _target_owner_pid} =
               WebsocketOwnerSession.lookup(target_state.codex_session.id)

      assert FakeUpstream.count(origin_upstream) == 0
      assert FakeUpstream.count(target_upstream) == 0
      assert FakeUpstream.websocket_connection_count(origin_upstream) == 1
      assert FakeUpstream.websocket_connection_count(target_upstream) == 0
      assert [guarded_request] = request_logs(origin_setup.pool.id)
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.response_metadata["transport_failure"]["termination_source"] ==
               "continuation_generation_guard"

      assert [] = request_logs(target_setup.pool.id)
      assert_no_leak_in_persistence!(origin_setup.pool.id)
      assert_no_leak_in_persistence!(target_setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, origin_state)
    end
  end

  test "owner-forwarded retarget keeps the current runtime for an expired alias cache miss before the generation guard" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    previous_response_id = "#{@sentinel}-stale-alias"

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-stale-alias", "stale-alias-origin")
    session = state.codex_session
    lease_token = state.websocket_owner_lease_token
    downstream = state.websocket_owner_downstream

    stale_alias = ensure_previous_response_alias!(session, setup.api_key, previous_response_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    stale_alias
    |> BridgeSessionAlias.changeset(%{
      status: "expired",
      expires_at: DateTime.add(now, -1, :second),
      updated_at: now
    })
    |> Repo.update!()

    try do
      payload =
        websocket_payload(setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-stale-alias-refused"
        })

      {retarget_admitted_state, logs} =
        with_log([level: :warning], fn ->
          assert {:ok, retarget_admitted_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

          assert retarget_admitted_state.codex_session.id == session.id
          assert retarget_admitted_state.websocket_owner_lease_token == lease_token
          assert retarget_admitted_state.websocket_owner_downstream == downstream

          assert {:ok, retarget_admitted_state} = receive_socket_done(retarget_admitted_state)

          retarget_admitted_state
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert retarget_admitted_state.codex_session.id == session.id
      assert retarget_admitted_state.websocket_owner_lease_token == lease_token
      assert retarget_admitted_state.websocket_owner_downstream == downstream
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [guarded_request] = request_logs(setup.pool.id)
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.response_metadata["transport_failure"]["termination_source"] ==
               "continuation_generation_guard"

      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :continuation_generation_boundary
  test "owner-forwarded alias cache miss forwards unchanged on the reused current connection" do
    previous_response_id = "#{@sentinel}-reused-alias-miss"

    upstream =
      start_upstream(
        # Strict finite scenario: the anchor and the alias-miss continuation are
        # the only sends, both on the reused first connection, and the unknown
        # previous_response_id is forwarded unchanged.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_reused_alias_miss_anchor",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => previous_response_id
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_reused_alias_miss_continuation",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reused-alias-miss", "reused-alias-miss")

    try do
      anchor_payload =
        websocket_payload(setup, "owner reused alias miss anchor", %{
          "request_id" => "ws-owner-reused-alias-miss-anchor"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(anchor_frame) == "resp_owner_reused_alias_miss_anchor"
      assert {:ok, state} = receive_socket_done(state)

      continuation_payload =
        websocket_payload(setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-reused-alias-miss-continuation"
        })

      {_state, logs} =
        with_info_log(fn ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

          assert {:push, {:text, continuation_frame}, state} = receive_owner_socket_push(state)

          assert owner_response_id(continuation_frame) ==
                   "resp_owner_reused_alias_miss_continuation"

          assert {:ok, state} = receive_socket_done(state)
          state
        end)

      assert logs =~ "websocket owner retarget alias miss"
      assert logs =~ "alias_kind=previous_response_id"
      assert logs =~ "outcome=current_runtime"
      assert logs =~ "request_id=ws-owner-reused-alias-miss"
      assert logs =~ "codex_session_id=#{state.codex_session.id}"
      assert logs =~ "owner_instance_id=#{state.codex_session.owner_instance_id}"
      assert logs =~ "proxy_instance_id=#{node()}"
      refute logs =~ previous_response_id
      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert_no_leak!("reused alias miss logs", logs)

      assert FakeUpstream.count(upstream) == 2
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [anchor_request, continuation_request] = await_upstream_requests(upstream, 2)

      assert anchor_request.websocket_connection_id ==
               continuation_request.websocket_connection_id

      assert continuation_request.json["previous_response_id"] == previous_response_id

      assert [anchor_log, continuation_log] = request_logs(setup.pool.id)
      assert anchor_log.status == "succeeded"
      assert continuation_log.status == "succeeded"
      assert_no_leak_in_persistence!(setup.pool.id)
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :continuation_generation_boundary
  test "owner-forwarded alias cache miss guards a replacement connection then reuses it for a full request" do
    previous_response_id = "#{@sentinel}-replacement-alias-miss"

    upstream =
      start_upstream(
        # Strict finite scenario: the anchor is the only send on the first
        # connection, the guarded alias-miss continuation sends nothing, and the
        # explicit full retry is the only send on the replacement connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_replacement_alias_miss_anchor",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_replacement_alias_miss_full_retry",
                  "object" => "response"
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-replacement-alias-miss", "replacement-alias-miss")

    try do
      anchor_payload =
        websocket_payload(setup, "owner replacement alias miss anchor", %{
          "request_id" => "ws-owner-replacement-alias-miss-anchor"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(anchor_frame) == "resp_owner_replacement_alias_miss_anchor"
      assert {:ok, state} = receive_socket_done(state)

      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      upstream_pid = :sys.get_state(owner_pid).upstream_pid
      assert :ok = UpstreamWebsocketSession.invalidate_connection(upstream_pid)

      continuation_payload =
        websocket_payload(setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-replacement-alias-miss-continuation"
        })

      {state, logs} =
        with_log([level: :warning], fn ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

          assert {:push, {:text, guard_terminal}, state} = receive_owner_socket_push(state)

          assert CodexPooler.JSON.decode!(guard_terminal) ==
                   CodexPooler.JSON.decode!(native_owner_retry_terminal())

          assert {:ok, state} = receive_socket_done(state)
          refute_received {:websocket_owner_frame, _, _, {:data, ^guard_terminal}}
          state
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert_no_leak!("replacement alias miss logs", logs)

      assert FakeUpstream.count(upstream) == 1
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [anchor_request, guarded_request] = request_logs(setup.pool.id)
      assert anchor_request.status == "succeeded"
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.status == "failed"
      assert guarded_attempt.network_error_code == "stream_incomplete"

      assert guarded_attempt.response_metadata["transport_failure"] == %{
               "connection_use" => "reconnected",
               "phase" => "send_payload",
               "pre_visible_output" => true,
               "reason" => "previous_response_generation_mismatch",
               "reason_class" => "previous_response_generation_mismatch",
               "termination_source" => "continuation_generation_guard",
               "terminal_seen" => false,
               "text_frame_count" => 0,
               "upstream_committed" => false
             }

      assert %{
               "generation" => 2,
               "reconnected" => true,
               "reused" => false
             } = guarded_attempt.response_metadata["upstream_websocket_connection"]

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^guarded_request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(bridge_alias in BridgeSessionAlias,
                 where:
                   bridge_alias.pool_id == ^setup.pool.id and
                     bridge_alias.api_key_id == ^setup.api_key.id and
                     bridge_alias.alias_kind == "previous_response_id" and
                     bridge_alias.alias_hash == ^:crypto.hash(:sha256, previous_response_id)
               ),
               :count
             ) == 0

      full_retry_payload =
        websocket_payload(setup, "owner replacement alias miss full retry", %{
          "request_id" => "ws-owner-replacement-alias-miss-full-retry"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({full_retry_payload, [opcode: :text]}, state)

      assert {:push, {:text, full_retry_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(full_retry_frame) == "resp_owner_replacement_alias_miss_full_retry"
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.count(upstream) == 2
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [anchor_upstream_request, full_retry_upstream_request] =
               await_upstream_requests(upstream, 2)

      assert anchor_upstream_request.websocket_connection_id !=
               full_retry_upstream_request.websocket_connection_id

      refute Map.has_key?(full_retry_upstream_request.json, "previous_response_id")

      assert [^anchor_request, ^guarded_request, full_retry_request] = request_logs(setup.pool.id)
      assert full_retry_request.status == "succeeded"

      assert [full_retry_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^full_retry_request.id))

      assert %{
               "generation" => 2,
               "reconnected" => false,
               "reused" => true
             } = full_retry_attempt.response_metadata["upstream_websocket_connection"]

      assert_no_leak_in_persistence!(setup.pool.id)
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded retarget keeps the current runtime for guessed and cross-key alias cache misses" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    alternate_key = CodexPooler.PoolerFixtures.api_key_fixture(setup.pool)
    previous_response_id = "#{@sentinel}-cross-key-alias"

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, alternate_auth} = Access.authenticate_authorization_header(alternate_key.authorization)
    {:ok, origin_state} = owner_socket(auth, "ws-owner-cache-miss-origin", "cache-miss-origin")

    {:ok, target_state} =
      owner_socket(alternate_auth, "ws-owner-cache-miss-target", "cache-miss-target")

    origin_session = origin_state.codex_session
    origin_lease_token = origin_state.websocket_owner_lease_token
    origin_downstream = origin_state.websocket_owner_downstream

    try do
      ensure_previous_response_alias!(
        target_state.codex_session,
        alternate_key.api_key,
        previous_response_id
      )

      {returned_runtimes, logs} =
        with_log([level: :warning], fn ->
          for alias_miss <- ["#{@sentinel}-guessed-alias", previous_response_id] do
            assert {:ok, returned_runtime} =
                     Gateway.retarget_websocket_owner_runtime(auth, origin_state, %{
                       "type" => "response.create",
                       "previous_response_id" => alias_miss
                     })

            returned_runtime
          end
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"

      for returned_runtime <- returned_runtimes do
        assert returned_runtime.codex_session.id == origin_session.id
        assert returned_runtime.websocket_owner_lease_token == origin_lease_token
        assert returned_runtime.websocket_owner_downstream == origin_downstream
      end

      assert {:ok, _origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

      assert {:ok, _target_owner_pid} =
               WebsocketOwnerSession.lookup(target_state.codex_session.id)

      assert FakeUpstream.count(upstream) == 0
      assert [] = request_logs(setup.pool.id)
      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, origin_state)
      CodexResponsesSocket.terminate(:closed, target_state)
    end
  end

  defp assert_stale_owner_downstream_ignored(owner_pid, stale_downstream, state) do
    stale_payload = CodexPooler.JSON.encode!(%{"id" => "resp_owner_retarget_stale_origin_frame"})

    stale_message =
      {:websocket_owner_frame, stale_downstream.correlation_id, stale_downstream.epoch,
       {:data, stale_payload}}

    case WebsocketOwnerSession.push_downstream(owner_pid, {:data, stale_payload}) do
      :ok ->
        assert_receive ^stale_message

      {:error, reason} ->
        assert reason in [:duplicate_downstream, :owner_unavailable, :stale_downstream]
    end

    case CodexResponsesSocket.handle_info(stale_message, state) do
      {:ok, state} ->
        state

      {:push, _frame, _state} ->
        flunk("stale origin downstream frame was accepted after retarget")
    end
  end
end
