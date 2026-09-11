defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RoutingTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient

  @handoff_detection_timeout_ms 15_000

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

  test "owner-forwarded pre-visible assignment model miss retries a later assignment" do
    upstream =
      start_upstream(
        # Strict finite scenario: the pre-visible model miss is retried exactly
        # once on a replacement connection. The bridge ring does not fix which
        # assignment is tried first, so the bearer is asserted by the accounting
        # rows below rather than by the fixture.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_owner_assignment_model_miss",
                    "error" => %{
                      "code" => "model_not_found",
                      "message" => "raw owner model miss sentinel"
                    }
                  }
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_assignment_model_fallback_success",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream, exposed_model_id: "gpt-example-luna")

    second =
      gateway_upstream(setup.pool, upstream, "upstream-token-owner-model-fallback",
        compact?: false
      )

    prime_routing_quota!(second.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      )

    request_id = Ecto.UUID.generate()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, request_id, request_id)

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {websocket_payload(setup, "owner assignment model failover", %{
                    "request_id" => request_id
                  }), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)

      assert %{"id" => "resp_owner_assignment_model_fallback_success"} =
               CodexPooler.JSON.decode!(frame)

      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.count(upstream) == 2

      assert [first_opaque_connection_id, second_opaque_connection_id] =
               FakeUpstream.websocket_connection_ids(upstream)

      assert is_reference(first_opaque_connection_id)
      assert is_reference(second_opaque_connection_id)
      assert first_opaque_connection_id != second_opaque_connection_id

      assert [first_attempt, second_attempt] = pool_attempts(setup.pool.id)

      refute first_attempt.pool_upstream_assignment_id ==
               second_attempt.pool_upstream_assignment_id

      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_model_unavailable"
      assert first_attempt.usage_status == "usage_unknown"
      assert second_attempt.status == "succeeded"
      assert second_attempt.usage_status == "usage_known"

      first_connection = first_attempt.response_metadata["upstream_websocket_connection"]
      second_connection = second_attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id} = first_connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

      assert first_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 1,
               "reused" => false,
               "reconnected" => false
             }

      assert second_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 2,
               "reused" => false,
               "reconnected" => false
             }

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1

      assert [settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 )
               )

      assert settlement.attempt_id == second_attempt.id
      assert settlement.pool_upstream_assignment_id == second_attempt.pool_upstream_assignment_id
      assert settlement.usage_status == "usage_known"
      assert settlement.total_tokens == 7

      assert %RoutingCircuitState{
               pool_upstream_assignment_id: first_assignment_id,
               route_class: "proxy_websocket",
               reason_code: "upstream_model_unavailable"
             } = Repo.one!(from(c in RoutingCircuitState))

      assert first_assignment_id == first_attempt.pool_upstream_assignment_id

      assert %BridgeDemotion{
               pool_upstream_assignment_id: demoted_assignment_id,
               reason_code: "upstream_model_unavailable"
             } = Repo.one!(from(d in BridgeDemotion))

      assert demoted_assignment_id == first_attempt.pool_upstream_assignment_id

      persisted = inspect({request, first_attempt, second_attempt})
      refute persisted =~ "raw owner model miss sentinel"
      refute persisted =~ "owner assignment model failover"
      refute persisted =~ setup.authorization
      refute persisted =~ "upstream-token-owner-model-fallback"
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded reset probe success confirms on the owner" do
    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_owner_reset_probe_success"}
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_owner_reset_probe_success",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
             }
           }}
        ])
      )

    usage_upstream = reset_probe_usage_upstream()
    setup = gateway_setup(dispatch_upstream, quota?: false)
    identity = enable_reset_probe!(setup.identity, usage_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reset-probe-success", "owner-reset-probe-success")
    remote_node = :"codex_pooler@remote-reset-probe-success.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success},
        capture_request_to: self()
      )

    remote_state = unpinned_remote_owner_state(state, remote_node, node_opts)

    try do
      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "owner forwarded reset probe success"),
                 owner_response_options(remote_state, node_opts),
                 fn _data -> :ok end
               )

      assert {:push, {:text, created_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created_frame)

      assert {:push, {:text, completed_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed_frame)
      assert {:ok, _state} = receive_owner_socket_complete(remote_state)

      assert_remote_submit_request_v1!(remote_state, remote_node, :success)

      refute_received {:websocket_owner_harness_node_call, _duplicate}
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end

    assert_reset_probe_usage_calls!(usage_upstream)
    assert FakeUpstream.count(dispatch_upstream) == 1

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.transport == "websocket"
    assert request.retry_count == 0
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.attempt_id == attempt.id
    assert settlement.transport == "websocket"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "confirmed_by_upstream"
    assert get_in(redemption, ["result", "code"]) == "reset"

    assert_reset_probe_public_metadata_safe!(request, attempt, redemption, [
      setup.authorization,
      "owner forwarded reset probe success",
      "resp_owner_reset_probe_success"
    ])
  end

  test "owner-forwarded request preserves sibling capacity and does not consume a reset" do
    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_owner_capacity_fence"}
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_owner_capacity_fence",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
             }
           }}
        ])
      )

    usage_upstream = reset_probe_usage_upstream()
    setup = gateway_setup(dispatch_upstream, quota?: false)
    sibling = active_upstream_assignment_fixture(setup.pool, %{})
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(usage_upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_trigger_mode: "threshold",
        saved_reset_auto_redeem_quota_threshold_percent: 95,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    put_owner_capacity_quota!(identity, "96")
    put_owner_capacity_quota!(sibling.identity, "75")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-capacity-fence", "owner-capacity-fence")
    remote_node = :"codex_pooler@remote-capacity-fence.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success},
        capture_request_to: self()
      )

    remote_state = remote_owner_state(state, remote_node, node_opts)

    session =
      state.codex_session
      |> Ecto.Changeset.change(pool_upstream_assignment_id: setup.assignment.id)
      |> Repo.update!()

    assert Repo.reload!(session).pool_upstream_assignment_id == setup.assignment.id

    remote_state = %{
      remote_state
      | codex_session: %{session | owner_instance_id: Atom.to_string(remote_node)}
    }

    setup = %{setup | model: model}
    request_options = owner_response_options(remote_state, node_opts)

    refute SessionContinuity.hard_pinned_continuity?(request_options, model)

    assert Enum.sort(model.metadata["source_assignment_ids"]) ==
             Enum.sort([setup.assignment.id, sibling.assignment.id])

    try do
      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "owner forwarded capacity fence"),
                 request_options,
                 fn _data -> :ok end
               )

      assert {:push, {:text, created_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created_frame)

      assert {:push, {:text, completed_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed_frame)
      assert {:ok, _state} = receive_owner_socket_complete(remote_state)
      assert_remote_submit_request_v1!(remote_state, remote_node, :success)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end

    refute Enum.any?(
             FakeUpstream.requests(usage_upstream),
             &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
           )

    refute Map.has_key?(Repo.reload!(identity).metadata, "saved_reset_redemption")
    assert FakeUpstream.count(dispatch_upstream) == 1

    assert [attempt] =
             Repo.all(
               from(a in Attempt,
                 join: r in Request,
                 on: a.request_id == r.id,
                 where: r.pool_id == ^setup.pool.id
               )
             )

    assert attempt.pool_upstream_assignment_id == setup.assignment.id
    assert Repo.reload!(session).pool_upstream_assignment_id == setup.assignment.id
  end

  test "owner-forwarded reset probe terminal failure remains unconfirmed" do
    terminal_message = "owner-reset-terminal-message-sentinel"

    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "id" => "resp_owner_reset_probe_failure",
               "error" => %{
                 "code" => "upstream_terminal_failure",
                 "param" => "reasoning.effort",
                 "message" => terminal_message
               }
             }
           }}
        ])
      )

    usage_upstream = reset_probe_usage_upstream()
    setup = gateway_setup(dispatch_upstream, quota?: false)
    identity = enable_reset_probe!(setup.identity, usage_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reset-probe-failure", "owner-reset-probe-failure")
    remote_node = :"codex_pooler@remote-reset-probe-failure.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success},
        capture_request_to: self()
      )

    remote_state = unpinned_remote_owner_state(state, remote_node, node_opts)

    logs =
      capture_log(fn ->
        try do
          assert :ok =
                   Gateway.run_websocket_response(
                     auth,
                     websocket_payload(setup, "owner forwarded reset probe failure"),
                     owner_response_options(remote_state, node_opts),
                     fn _data -> :ok end
                   )

          assert {:push, {:text, terminal_frame}, remote_state} =
                   receive_owner_socket_push(remote_state)

          assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(terminal_frame)
          assert {:ok, _state} = receive_owner_socket_complete(remote_state)

          assert_remote_submit_request_v1!(remote_state, remote_node, :success)

          refute_received {:websocket_owner_harness_node_call, _duplicate}
        after
          CodexResponsesSocket.terminate(:closed, remote_state)
        end
      end)

    assert_reset_probe_usage_calls!(usage_upstream)
    assert FakeUpstream.count(dispatch_upstream) == 1

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.last_error_code == "upstream_terminal_failure"
    assert request.retry_count == 0

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.attempt_id == attempt.id
    assert settlement.transport == "websocket"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "consumed_pending_probe"
    assert is_binary(get_in(redemption, ["probe", "token"]))

    assert_reset_probe_public_metadata_safe!(request, attempt, redemption, [
      setup.authorization,
      "owner forwarded reset probe failure",
      "resp_owner_reset_probe_failure",
      terminal_message
    ])

    refute logs =~ get_in(redemption, ["probe", "token"])

    persisted = inspect({request.request_metadata, attempt.response_metadata})
    refute persisted =~ terminal_message
    refute logs =~ terminal_message
  end

  test "remote owner executes the proxy turn snapshot and the next turn observes the Pool edit" do
    upstream =
      start_upstream(
        # Strict finite scenario: the remote owner forwards exactly one lite
        # turn and then exactly one full turn; the canonical request shapes are
        # asserted on the captured requests below.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_mode_lite_snapshot",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_mode_full_next_turn",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "lite")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-mode-snapshot", "owner-mode-snapshot")
    remote_node = :"codex_pooler@remote-mode-owner.example"

    base_node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(state, remote_node, base_node_opts)
    release_ref = make_ref()
    parent = self()

    try do
      first_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [
              calls: %{remote_node => {:barrier_success, parent, release_ref}},
              notify: parent,
              capture_request_to: parent
            ],
            fn node_opts ->
              Gateway.run_websocket_response(
                auth,
                model_serving_owner_payload(setup, "remote-lite", "client-false"),
                owner_response_options(remote_state, node_opts),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert_receive {:websocket_owner_harness_call_barrier, rpc_pid, ^release_ref,
                      :remote_submit_request_v1},
                     1_000

      try do
        _revision = set_model_serving_mode!(scope, setup, "full", revision)
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})
        assert :ok = Task.await(first_turn, 3_000)
      after
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})
      end

      assert {:push, {:text, lite_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert owner_response_id(lite_frame) == "resp_owner_mode_lite_snapshot"
      assert {:ok, remote_state} = receive_owner_socket_complete(remote_state)

      assert :ok =
               WebsocketOwnerNodeHarness.with_node_client(
                 [remote_node],
                 [
                   calls: %{remote_node => :success},
                   notify: self(),
                   capture_request_to: self()
                 ],
                 fn node_opts ->
                   Gateway.run_websocket_response(
                     auth,
                     model_serving_owner_payload(setup, "remote-full", "client-true"),
                     owner_response_options(remote_state, node_opts),
                     fn _data -> :ok end
                   )
                 end
               )

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert {:push, {:text, full_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert owner_response_id(full_frame) == "resp_owner_mode_full_next_turn"
      assert {:ok, _remote_state} = receive_owner_socket_complete(remote_state)

      assert [lite_upstream_request, full_upstream_request] = FakeUpstream.requests(upstream)
      assert_canonical_lite_owner_request!(lite_upstream_request)
      assert_canonical_full_owner_request!(full_upstream_request)

      assert [lite_request, full_request] = request_logs(setup.pool.id)
      assert_owner_mode_accounting!(lite_request, "lite", "succeeded", remote_node)
      assert_owner_mode_accounting!(full_request, "full", "succeeded", remote_node)
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  test "live owner-forwarded websocket keeps an accepted model miss on its established lane" do
    pinned_upstream =
      start_upstream(
        # Strict finite scenario: the pinned lane receives the anchor and the
        # model-miss turn only; the accepted miss is not retried anywhere.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_live_anchor",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_owner_live_model_miss",
                    "error" => %{"code" => "model_not_found", "param" => "model"}
                  }
                })
              ])
          )
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_live_fallback_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream, exposed_model_id: "gpt-example-luna")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-live-model-miss", "owner-live-model-miss")

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_payload(setup, "synthetic owner live anchor"), [opcode: :text]},
               state
             )

    [anchor_task_pid] = MapSet.to_list(state.tasks)
    assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
    assert %{"id" => "resp_owner_live_anchor"} = CodexPooler.JSON.decode!(anchor_frame)
    assert {:ok, state} = receive_owner_socket_complete(state)
    assert {:ok, state} = acknowledge_response_task_delivery_if_pending(state, anchor_task_pid)
    assert {:ok, state} = receive_socket_done(state)
    assert MapSet.size(state.tasks) == 0

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-owner-live-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    _model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_payload(setup, "synthetic owner live model miss"), [opcode: :text]},
               state
             )

    [response_task_pid] = MapSet.to_list(state.tasks)

    assert_receive {:websocket_owner_output_commit_probe, _, _, ^response_task_pid, _, _, _} =
                     output_commit_probe,
                   @handoff_detection_timeout_ms

    assert {:ok, state} = CodexResponsesSocket.handle_info(output_commit_probe, state)

    assert {:push, {:text, failed_frame}, state} = receive_socket_push(state)
    assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(failed_frame)
    assert MapSet.size(state.tasks) == 1
    assert {:ok, state} = acknowledge_response_task_delivery_if_pending(state, response_task_pid)

    assert FakeUpstream.count(pinned_upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [anchor_request, failed_request] = request_logs(setup.pool.id)
    assert anchor_request.status == "succeeded"
    assert failed_request.status == "failed"
    assert failed_request.retry_count == 0

    assert [failed_attempt] =
             Repo.all(from(a in Attempt, where: a.request_id == ^failed_request.id))

    assert failed_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert failed_attempt.status == "failed"
    assert failed_attempt.usage_status == "usage_unknown"

    assert MapSet.size(state.tasks) == 0
    assert :ok = FakeUpstream.verify!(pinned_upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  defp unpinned_remote_owner_state(state, remote_node, node_opts) do
    state = remote_owner_state(state, remote_node, node_opts)

    codex_session =
      state.codex_session
      |> Ecto.Changeset.change(pool_upstream_assignment_id: nil)
      |> Repo.update!()

    %{
      state
      | codex_session: %{codex_session | owner_instance_id: Atom.to_string(remote_node)}
    }
  end

  defp reset_probe_usage_upstream do
    start_upstream(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" =>
           {200, %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}}
       }}
    )
  end

  defp enable_reset_probe!(identity, usage_upstream) do
    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(usage_upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    prime_weekly_exhausted_quota!(identity)
    identity
  end

  defp put_owner_capacity_quota!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new(used_percent),
                 reset_at: DateTime.add(now, 2, :hour),
                 observed_at: now,
                 last_sync_at: now,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
  end

  defp assert_reset_probe_usage_calls!(usage_upstream) do
    requests = FakeUpstream.requests(usage_upstream)

    assert [%{method: "POST", json: %{"redeem_request_id" => _}}] =
             Enum.filter(requests, &(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

    assert Enum.any?(requests, &(&1.method == "GET" and &1.path == "/api/codex/usage"))
  end

  defp assert_reset_probe_public_metadata_safe!(request, attempt, redemption, forbidden_values) do
    probe = redemption["probe"]
    persisted = inspect({request.request_metadata, attempt.response_metadata})

    refute persisted =~ probe["token"]
    refute persisted =~ inspect(probe["scope"])
    refute persisted =~ "upstream-token"
    refute Map.has_key?(request.request_metadata, "probe")
    refute Map.has_key?(attempt.response_metadata, "probe")

    Enum.each(forbidden_values, fn forbidden_value ->
      refute persisted =~ forbidden_value
    end)
  end
end
