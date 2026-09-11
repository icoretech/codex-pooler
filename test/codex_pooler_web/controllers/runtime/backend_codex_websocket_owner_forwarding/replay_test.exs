defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.ReplayTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestClientRetryLink
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias Ecto.Adapters.SQL.Sandbox

  @blocking_owner_receive_timeout_ms 5_000
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

  @tag :replay_matrix
  @tag :replay_topology
  @tag :findings116
  test "remote owner forwarding replays one pre-visible disconnect into one completed lifecycle" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the first connection closes before any
        # terminal, the replay must be the only other send and must arrive on a
        # replacement connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
            ],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: release_ref,
                code: 1001,
                reason: "synthetic remote replay disconnect"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_remote_replay_complete",
                    "status" => "completed",
                    "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                  }
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()
    {:ok, state} = owner_socket(auth, "ws-remote-replay", turn_state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-replay.example"
    ReplayRemoteNodeClient.configure(remote_node, self())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      state.codex_session
      |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
      |> Repo.update!()

    active_owner_lease(session.id)
    |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
    |> Repo.update!()

    :sys.replace_state(owner_pid, fn owner_state ->
      %{owner_state | owner_instance_id: Atom.to_string(remote_node)}
    end)

    node_client_options = [node_client: ReplayRemoteNodeClient]

    remote_state =
      state
      |> remote_owner_state(remote_node, node_client_options)
      |> Map.put(:codex_session, session)

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "function_call_output",
            "call_id" => "call_remote_replay",
            "output" => "synthetic remote replay output"
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              CodexPooler.JSON.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "remote-replay-turn",
                "request_kind" => "turn"
              })
          }
        }
      )

    assert {:ok, remote_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, remote_state)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   @handoff_detection_timeout_ms

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}

    assert_receive {:replay_remote_owner_call, ^remote_node,
                    :remote_prepare_next_replay_descriptor}

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v1}
    assert %{active_turn: %{descriptor: %{replay_generation: 0}}} = :sys.get_state(owner_pid)

    assert Gateway.detach_websocket_owner_downstream(
             session,
             remote_state.websocket_owner_lease_token,
             remote_state.websocket_owner_downstream,
             remote_state.opts
           ) in [:suspended, :ok]

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_cancel_downstream}

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} =
             :sys.get_state(owner_pid)

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:ok, remote_state} = receive_socket_done(remote_state)
    assert MapSet.size(remote_state.tasks) == 0

    assert [request] = request_logs(setup.pool.id)
    assert [initial_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert initial_attempt.replay_generation == 0
    assert initial_attempt.status == "retryable_failed"

    assert %RequestReplayEntitlement{status: "armed", closed_at: nil} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    {:ok, replay_state} =
      owner_socket(auth, "ws-remote-replay-retry", turn_state,
        websocket_owner_forwarder_opts: node_client_options
      )

    assert {:ok, replay_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, replay_state)

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_consume_replay_reserve}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_validate_replay_reserve}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}

    assert_receive {:replay_remote_owner_call, ^remote_node,
                    :remote_prepare_next_replay_descriptor}

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v4}

    assert {:push, {:text, replay_frame}, replay_state} = receive_owner_socket_push(replay_state)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(replay_frame)
    assert {:ok, replay_state} = receive_owner_socket_complete(replay_state)
    assert {:ok, replay_state} = receive_socket_done(replay_state)

    assert [%Request{id: request_id}] = request_logs(setup.pool.id)
    assert request_id == request.id

    assert [attempt_n, attempt_n_plus_one] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert {attempt_n.replay_generation, attempt_n_plus_one.replay_generation} == {0, 1}
    assert attempt_n_plus_one.status == "succeeded"
    assert FakeUpstream.count(upstream) == 2

    assert %RequestReplayEntitlement{status: "consumed", closed_at: %DateTime{}} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "reservation"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "release"
             ),
             :count
           ) == 1

    assert [%CodexTurn{status: "succeeded", final_attempt_id: final_attempt_id}] =
             Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert final_attempt_id == attempt_n_plus_one.id
    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, replay_state)
    assert Process.alive?(owner_pid)
  end

  @tag :replay_matrix
  @tag :replay_topology
  @tag :stream_cut_resend
  test "remote owner forwarding persists a lifecycle-only stream cut and admits the byte-identical resend" do
    tool_output_request = [
      valid: true,
      equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
    ]

    upstream =
      start_upstream(
        # Strict finite scenario: the first connection delivers only lifecycle
        # frames and then drops without a terminal or a close frame; the
        # byte-identical resend is the only other send and must arrive on a
        # replacement connection.
        # provenance: observed findings issue 124 (lifecycle frames, transport close; resend reply synthetic)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: tool_output_request,
            respond:
              FakeUpstream.websocket_text_frames_then_abrupt_close([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.created",
                  "response" => %{"id" => "resp_remote_stream_cut", "status" => "in_progress"}
                }),
                CodexPooler.JSON.encode!(%{
                  "type" => "response.in_progress",
                  "response" => %{"id" => "resp_remote_stream_cut", "status" => "in_progress"}
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: tool_output_request,
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_remote_stream_cut_resend",
                    "status" => "completed",
                    "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                  }
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()
    {:ok, state} = owner_socket(auth, "ws-remote-stream-cut", turn_state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-stream-cut.example"
    ReplayRemoteNodeClient.configure(remote_node, self())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      state.codex_session
      |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
      |> Repo.update!()

    active_owner_lease(session.id)
    |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
    |> Repo.update!()

    :sys.replace_state(owner_pid, fn owner_state ->
      %{owner_state | owner_instance_id: Atom.to_string(remote_node)}
    end)

    node_client_options = [node_client: ReplayRemoteNodeClient]

    remote_state =
      state
      |> remote_owner_state(remote_node, node_client_options)
      |> Map.put(:codex_session, session)

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "function_call_output",
            "call_id" => "call_remote_stream_cut",
            "output" => "synthetic remote stream cut output sentinel"
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              CodexPooler.JSON.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "remote-stream-cut-turn",
                "request_kind" => "turn"
              })
          }
        }
      )

    assert {:ok, remote_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, remote_state)

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v1},
                   @handoff_detection_timeout_ms

    {remote_state, seen_types, error_frame} = receive_owner_frames_until_error(remote_state, [])
    assert ["response.created", "response.in_progress"] = seen_types
    assert %{"type" => "error", "status" => 502} = error_frame

    # The owner-relayed error is the turn's only terminal on the wire: the
    # finishing response task settles without authoring a second error frame.
    assert {remote_state, []} = collect_native_turn_frames!(remote_state)
    assert MapSet.size(remote_state.tasks) == 0

    assert [failed] = request_logs(setup.pool.id)
    assert String.starts_with?(failed.correlation_id, "codex-request:")
    assert {failed.status, failed.last_error_code} == {"failed", "upstream_stream_error"}
    assert [failed_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^failed.id))

    # The remote owner materialized the request through the owner request
    # callbacks; the observation it carried is persisted on the attempt.
    assert failed_attempt.response_metadata["native_client_retry_observation"] == %{
             "version" => 1,
             "authority_complete" => true,
             "output_item_done_count" => 0,
             "output_item_done_count_saturated" => false,
             "partial_reasoning_seen" => false,
             "first_visible_at" => nil,
             "terminal_seen" => false,
             "terminal_candidate_seen" => false
           }

    assert %{
             "termination_source" => "mint_transport_error",
             "reason" => "closed",
             "terminal_seen" => false
           } = failed_attempt.response_metadata["transport_failure"]

    assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)

    {:ok, retry_state} =
      owner_socket(auth, "ws-remote-stream-cut-retry", turn_state,
        websocket_owner_forwarder_opts: node_client_options
      )

    {retry_state, log} =
      with_info_log(fn ->
        assert {:ok, retry_state} =
                 CodexResponsesSocket.handle_in({payload, [opcode: :text]}, retry_state)

        assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v1},
                       @handoff_detection_timeout_ms

        assert {:push, {:text, completed_frame}, retry_state} =
                 receive_owner_socket_push(retry_state)

        assert %{
                 "type" => "response.completed",
                 "response" => %{"id" => "resp_remote_stream_cut_resend"}
               } = CodexPooler.JSON.decode!(completed_frame)

        assert {:ok, retry_state} = receive_owner_socket_complete(retry_state)
        assert {:ok, retry_state} = receive_socket_done(retry_state)
        retry_state
      end)

    assert log =~ "websocket client resend admitted stage=websocket_turn_claim"
    assert log =~ "predecessor_shape=lifecycle_cut"
    refute log =~ "websocket replay rejection"
    refute log =~ "sentinel"

    failed_id = failed.id
    assert [%Request{id: ^failed_id}, resend] = request_logs(setup.pool.id)
    assert String.starts_with?(resend.correlation_id, "codex-request-retry:")
    assert resend.request_metadata["client_resend"]["predecessor_request_id"] == failed_id

    {resend, _attempt, _turn, _settlement, _fact} =
      await_forwarding_persistence!(resend.id, session.id, "succeeded")

    assert resend.status == "succeeded"
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, retry_state)
  end

  @tag :replay_matrix
  @tag :replay_race
  @tag :replay_topology
  @tag :replay_cleanup
  test "real peer owner replays one pre-visible disconnect through the non-owner proxy" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)

    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the real peer owner's first connection closes
        # before any terminal, the replay is the only other send on a
        # replacement connection, and the duplicate retry sends nothing.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
            ],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: release_ref,
                code: 1001,
                reason: "synthetic real peer replay disconnect"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_real_peer_replay_complete",
                    "status" => "completed",
                    "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                  }
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    turn_state = Ecto.UUID.generate()
    session_header = "real-peer-replay-#{System.unique_integer([:positive])}"
    {session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)
    assert node(owner_pid) == remote_node
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session.id)

    assert {:ok, ^owner_pid} =
             :erpc.call(remote_node, WebsocketOwnerSession, :lookup, [session.id])

    assert node(
             :erpc.call(remote_node, :erlang, :map_get, [:upstream_pid, :sys.get_state(owner_pid)])
           ) ==
             remote_node

    forwarder_opts = [
      node_client: WebsocketOwnerForwarder.ERPCNodeClient,
      app_node_names: [Atom.to_string(remote_node)]
    ]

    {:ok, state} =
      owner_socket(auth, "ws-real-peer-replay", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "function_call_output",
            "call_id" => "call_real_peer_replay",
            "output" => "synthetic real peer replay output"
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              CodexPooler.JSON.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "real-peer-replay-turn",
                "request_kind" => "turn"
              })
          }
        }
      )

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   @handoff_detection_timeout_ms

    remote_owner_state = :erpc.call(remote_node, :sys, :get_state, [owner_pid])
    assert remote_owner_state.codex_session_id == session.id
    assert remote_owner_state.owner_instance_id == Atom.to_string(remote_node)
    assert remote_owner_state.active_turn.descriptor.replay_generation == 0

    assert Gateway.detach_websocket_owner_downstream(
             session,
             state.websocket_owner_lease_token,
             state.websocket_owner_downstream,
             state.opts
           ) in [:suspended, :ok]

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} =
             :erpc.call(remote_node, :sys, :get_state, [owner_pid])

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:ok, state} = receive_socket_done(state)
    assert MapSet.size(state.tasks) == 0

    assert [request] = request_logs(setup.pool.id)
    assert [initial_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert initial_attempt.replay_generation == 0
    assert initial_attempt.status == "retryable_failed"

    {:ok, replay_state} =
      owner_socket(auth, "ws-real-peer-replay-retry", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    assert {:ok, replay_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, replay_state)

    assert {:push, {:text, replay_frame}, replay_state} =
             receive_owner_socket_push(replay_state)

    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(replay_frame)
    assert {:ok, replay_state} = receive_owner_socket_complete(replay_state)
    assert {:ok, replay_state} = receive_socket_done(replay_state)

    assert [attempt_n, attempt_n_plus_one] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert {attempt_n.replay_generation, attempt_n_plus_one.replay_generation} == {0, 1}
    assert attempt_n_plus_one.status == "succeeded"
    assert FakeUpstream.count(upstream) == 2

    assert Repo.aggregate(from(r in Request, where: r.id == ^request.id), :count) == 1
    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id), :count) == 1

    for kind <- ["reservation", "settlement", "release"] do
      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == ^kind
               ),
               :count
             ) == 1
    end

    assert [%CodexTurn{status: "succeeded", final_attempt_id: final_attempt_id}] =
             Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert final_attempt_id == attempt_n_plus_one.id

    assert %RequestReplayEntitlement{status: "consumed", closed_at: %DateTime{}} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    {:ok, duplicate_state} =
      owner_socket(auth, "ws-real-peer-replay-duplicate", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    assert {:ok, duplicate_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, duplicate_state)

    assert {:push, {:text, duplicate_frame}, duplicate_state} =
             receive_socket_done(duplicate_state)

    assert CodexPooler.JSON.decode!(duplicate_frame)["error"]["code"] == "duplicate_turn"
    assert FakeUpstream.count(upstream) == 2
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 2
    assert :ok = FakeUpstream.verify!(upstream)

    assert :ok = CodexResponsesSocket.terminate(:closed, duplicate_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, replay_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    stop_remote_owner!(remote_node, session.id, owner_pid)
  end

  @tag :client_retry_owner_race
  test "two proxy downstreams race one client retry through the real peer owner" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)

    release_ref = make_ref()

    terminal =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_client_retry_owner_race",
          "status" => "completed",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        }
      })

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(
          terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    session_header = "client-retry-owner-race-#{System.unique_integer([:positive])}"
    {session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    forwarder_opts = [
      node_client: WebsocketOwnerForwarder.ERPCNodeClient,
      app_node_names: [Atom.to_string(remote_node)]
    ]

    turn_state = Ecto.UUID.generate()

    {:ok, first_state} =
      owner_socket(auth, "client-retry-owner-a", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    {:ok, second_state} =
      owner_socket(auth, "client-retry-owner-b", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic retry input"}]
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              CodexPooler.JSON.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "client-retry-owner-race",
                "request_kind" => "turn"
              })
          }
        }
      )

    options =
      Gateway.websocket_owner_response_options(
        first_state.opts,
        first_state.codex_session,
        first_state.websocket_owner_lease_token,
        first_state.websocket_owner_downstream
      )
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    {:ok, prepared} = Service.prepare_websocket_response(payload, options, fn _frame -> :ok end)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, %{request: predecessor}} =
      Accounting.claim_websocket_turn(auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: Ecto.UUID.generate(),
        native_client_retry_witness: prepared.native_client_retry_witness
      })

    assert predecessor.native_client_retry_version == 1
    assert predecessor.native_client_retry_digest == prepared.replay_claim_digest

    predecessor_turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: predecessor.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: prepared.semantic_turn_key,
        status: "failed",
        error_code: "upstream_stream_error",
        first_visible_output_at: now,
        completed_at: now,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    predecessor_attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(predecessor, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: %{
          "transport_failure" => %{
            "phase" => "receive",
            "termination_source" => "peer_close_frame",
            "transport_signal" => "tcp_closed"
          },
          "native_client_retry_observation" => %{
            "version" => 1,
            "authority_complete" => true,
            "output_item_done_count" => 0,
            "output_item_done_count_saturated" => false,
            "partial_reasoning_seen" => true,
            "first_visible_at" => DateTime.to_iso8601(now),
            "terminal_seen" => false,
            "terminal_candidate_seen" => false
          }
        }
      })

    Repo.update!(
      Ecto.Changeset.change(predecessor,
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        last_error_code: "upstream_stream_error"
      )
    )

    Repo.update!(
      Ecto.Changeset.change(predecessor_turn, final_attempt_id: predecessor_attempt.id)
    )

    assert {:ok, current_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, upstream_pid,
                    ^release_ref},
                   @handoff_detection_timeout_ms

    loser_result = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, first_state)

    assert {:push, {:text, loser_error}, _loser_state} = loser_result

    assert CodexPooler.JSON.decode!(loser_error)["error"]["code"] in [
             "duplicate_turn",
             "owner_busy"
           ]

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:push, {:text, _frame}, current_state} = receive_owner_socket_push(current_state)
    assert {:ok, current_state} = receive_owner_socket_complete(current_state)
    assert {:ok, _current_state} = receive_socket_done(current_state)

    assert Repo.aggregate(RequestClientRetryLink, :count) == 1

    successor_id = Repo.one!(from l in RequestClientRetryLink, select: l.successor_request_id)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^successor_id), :count) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert node(owner_pid) == remote_node

    {successor, _attempt, _turn, _settlement, _fact} =
      await_forwarding_persistence!(successor_id, session.id, "succeeded")

    assert successor.id == successor_id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where:
                 entry.request_id == ^successor_id and entry.entry_kind == "settlement" and
                   entry.amount_status == "recorded"
             ),
             :count
           ) == 1
  end

  @tag :replay_active_reattach
  @tag :replay_matrix
  @tag :replay_topology
  test "healthy active owner rejects an exact retry without attachment mutation" do
    release_ref = make_ref()
    upstream_boundary = terminal_blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-active-reconnect"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-active-reconnect-first", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "first owner active reconnect turn", %{
        "request_id" => "ws-owner-active-reconnect-first",
        "client_metadata" => %{
          "turn_id" => "ws-owner-active-reconnect-first",
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "turn_id" => "ws-owner-active-reconnect-first",
              "request_kind" => "turn"
            })
        }
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    assert MapSet.size(first_state.tasks) == 1
    [response_task_pid] = MapSet.to_list(first_state.tasks)

    {:ok, second_state} = owner_socket(auth, "ws-owner-active-reconnect-second", turn_state)
    assert second_state.websocket_owner_downstream.epoch == 2
    assert second_state.websocket_owner_active_turn_reconnect? == true

    assert %{active_turn: %{descriptor: %{kind: :native} = active_descriptor}} =
             :sys.get_state(second_state.websocket_owner_pid)

    assert active_descriptor.semantic_turn_key ==
             :crypto.hash(
               :sha256,
               second_state.codex_session.id <> <<0>> <> "ws-owner-active-reconnect-first"
             )

    try do
      assert [in_progress_request] = request_logs(setup.pool.id)
      assert_native_turn_correlation!(in_progress_request.correlation_id)
      assert in_progress_request.status == "in_progress"

      {replay_result, replay_log} =
        with_info_log(fn ->
          CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, second_state)
        end)

      assert {:push, {:text, duplicate_error}, ^second_state} = replay_result
      assert CodexPooler.JSON.decode!(duplicate_error)["error"]["code"] == "duplicate_turn"

      assert event_count(replay_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
               1

      assert replay_log =~ "reconnect_disposition=identity_rejected"

      assert second_state.websocket_owner_active_turn_reconnect? == true
      assert MapSet.size(second_state.tasks) == 0
      assert length(request_logs(setup.pool.id)) == 1

      assert length(request_logs(setup.pool.id)) == 1
    after
      {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
      Sandbox.allow(Repo, self(), owner_pid)
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})

      assert {:push, {:text, terminal_frame}, first_state} =
               receive_owner_socket_push(first_state)

      assert CodexPooler.JSON.decode!(terminal_frame)["type"] == "response.completed"
      assert {:ok, first_state} = receive_owner_socket_complete(first_state)
      first_state = receive_receiver_delivery_gap_result(response_task_pid, first_state)

      assert {:ok, first_state} =
               acknowledge_response_task_delivery_if_pending(first_state, response_task_pid)

      assert_response_task_stopped!(first_state, response_task_pid)
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
      assert :ok = CodexResponsesSocket.terminate(:closed, second_state)
      await_owner_cleanup!(first_state.codex_session.id)
    end
  end

  @tag :replay_protocol_v2
  @tag :replay_topology
  test "router upgrade carries typed RequestOptions through V2 healthy duplicate" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "resp_router_v2"}
          })
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    turn_state = "router-v2-typed-options"

    payload =
      websocket_payload(setup, "router typed options", %{
        "request_id" => "router-v2-typed-options",
        "client_metadata" => %{
          "turn_id" => "router-v2-typed-options",
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "turn_id" => "router-v2-typed-options",
              "request_kind" => "turn"
            })
        }
      })

    {first_conn, first_ws, first_ref} = public_websocket_connect!(port, setup, turn_state)
    {first_conn, first_ws} = public_websocket_send_text!(first_conn, first_ws, first_ref, payload)
    _ = public_websocket_receive_text!(first_conn, first_ws, first_ref)

    {retry_conn, retry_ws, retry_ref} = public_websocket_connect!(port, setup, turn_state)
    {retry_conn, retry_ws} = public_websocket_send_text!(retry_conn, retry_ws, retry_ref, payload)

    {_retry_conn, _retry_ws, error} =
      public_websocket_receive_text!(retry_conn, retry_ws, retry_ref)

    assert CodexPooler.JSON.decode!(error)["error"]["code"] == "duplicate_turn"

    Mint.HTTP.close(first_conn)
    Mint.HTTP.close(retry_conn)

    session =
      Repo.one!(from session in CodexSession, order_by: [desc: session.created_at], limit: 1)

    case WebsocketOwnerSession.lookup(session.id) do
      {:ok, owner_pid} -> GenServer.stop(owner_pid, :normal)
      {:error, :owner_unavailable} -> :ok
    end
  end

  @tag :replay_race
  @tag :replay_topology
  @tag :findings116
  test "active owner reconnect rejects ambiguous frames while prewarm remains local and neutral" do
    for route <- [:direct, :proxy] do
      assert_active_reconnect_frame_matrix(route)
    end
  end

  @tag :findings116
  test "pending replacement prewarm stays local and preserves the handoff in both topologies" do
    for route <- [:direct, :proxy] do
      assert_pending_replacement_prewarm_neutral(route)
    end
  end

  @tag :findings116
  test "cancelled owner reconnect admits one edited replacement only after fenced readiness" do
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-edited-replacement"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-edited-replacement-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "edited replacement predecessor", %{
        "request_id" => "ws-owner-edited-replacement-a",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, first_worker_pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    owner_upstream_pid = :sys.get_state(owner_pid).upstream_pid

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    assert %{
             active_turn: %{
               descriptor: %{kind: :native},
               canceled_result: _canceled_result
             }
           } = :sys.get_state(owner_pid)

    {:ok, replacement_state} =
      owner_socket(auth, "ws-owner-edited-replacement-b", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    cancelled_equal_payload =
      websocket_payload(setup, "cancelled equal predecessor replay", %{
        "request_id" => "ws-owner-edited-replacement-a",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-a"}
      })

    {cancelled_equal_result, cancelled_equal_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in(
          {cancelled_equal_payload, [opcode: :text]},
          replacement_state
        )
      end)

    assert {:push, {:text, cancelled_equal_error}, ^replacement_state} =
             cancelled_equal_result

    assert CodexPooler.JSON.decode!(cancelled_equal_error)["error"]["code"] == "owner_busy"

    assert event_count(
             cancelled_equal_log,
             WebsocketConnectionLogger.reconnect_disposition_message()
           ) == 1

    assert cancelled_equal_log =~ "reconnect_disposition=owner_busy"
    assert length(request_logs(setup.pool.id)) == 1

    replacement_payload =
      websocket_payload(setup, "edited replacement successor", %{
        "request_id" => "ws-owner-edited-replacement-b",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-b"}
      })

    assert {:ok, pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               replacement_state
             )

    assert is_map(pending_state.websocket_owner_pending_handoff)
    assert MapSet.size(pending_state.tasks) == 0
    assert length(request_logs(setup.pool.id)) == 1

    assert {:ok, ^pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               pending_state
             )

    third_payload =
      websocket_payload(setup, "third pending replacement", %{
        "request_id" => "ws-owner-edited-replacement-d",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-d"}
      })

    {third_result, third_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in(
          {third_payload, [opcode: :text]},
          pending_state
        )
      end)

    assert {:push, {:text, third_error}, ^pending_state} = third_result

    assert CodexPooler.JSON.decode!(third_error)["error"]["code"] == "owner_busy"
    assert event_count(third_log, WebsocketConnectionLogger.reconnect_disposition_message()) == 1
    assert third_log =~ "reconnect_disposition=owner_busy"
    assert length(request_logs(setup.pool.id)) == 1

    # The predecessor upstream never finishes cancelling, so readiness can only
    # come from the owner's soft handoff timeout (1 s by default and not
    # configurable through the socket). Fire that timer now; the fencing under
    # test is the pending state asserted above, not the wait for the timer.
    owner_pending = :sys.get_state(owner_pid).pending_handoff
    assert %{status: :waiting, control_ref: control_ref, soft_token: soft_token} = owner_pending
    send(owner_pid, {:websocket_owner_handoff_soft_timeout, control_ref, soft_token})

    assert_receive {:websocket_owner_handoff_ready, _, _, _, _, _} = ready,
                   @handoff_detection_timeout_ms

    assert {:ok, admitted_state} = CodexResponsesSocket.handle_info(ready, pending_state)
    assert admitted_state.websocket_owner_pending_handoff == nil
    assert MapSet.size(admitted_state.tasks) == 1

    assert_receive {:controller_handoff_replacement_started, 2},
                   @handoff_detection_timeout_ms

    assert length(request_logs(setup.pool.id)) == 2

    assert {:ok, admitted_state} = receive_owner_socket_complete(admitted_state)
    assert {:ok, admitted_state} = receive_socket_done(admitted_state)

    assert [predecessor, replacement] = request_logs(setup.pool.id)
    assert predecessor.last_error_code == "client_disconnected"
    assert replacement.status == "succeeded"
    assert predecessor.correlation_id != replacement.correlation_id

    following_payload =
      websocket_payload(setup, "following replacement turn", %{
        "request_id" => "ws-owner-edited-replacement-c",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-c"}
      })

    assert {:ok, following_state} =
             CodexResponsesSocket.handle_in(
               {following_payload, [opcode: :text]},
               admitted_state
             )

    assert_receive {:controller_handoff_replacement_started, 3},
                   @handoff_detection_timeout_ms

    assert {:ok, following_state} = receive_owner_socket_complete(following_state)
    assert {:ok, following_state} = receive_socket_done(following_state)

    assert [_predecessor, _replacement, following] = request_logs(setup.pool.id)
    assert following.status == "succeeded"

    assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    assert :sys.get_state(owner_pid).upstream_pid == owner_upstream_pid
    refute inspect(request_logs(setup.pool.id)) =~ "previous_response_generation_mismatch"

    assert Repo.aggregate(
             from(attempt in Attempt,
               join: request in Request,
               on: request.id == attempt.request_id,
               where: request.pool_id == ^setup.pool.id
             ),
             :count
           ) ==
             3

    assert Repo.aggregate(
             from(turn in CodexTurn,
               where: turn.codex_session_id == ^first_state.codex_session.id
             ),
             :count
           ) == 3

    refute Process.alive?(first_worker_pid)
    CodexResponsesSocket.terminate(:closed, first_state)
    CodexResponsesSocket.terminate(:closed, following_state)
  end

  @tag :findings116
  test "pending edited replacement socket close cancels once without replacement rows or leaks" do
    private_sentinel = "REPLAY_PRIVATE_PENDING_CLOSE_SENTINEL"
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-pending-close"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-pending-close-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "pending close predecessor", %{
        "request_id" => "ws-owner-pending-close-a",
        "client_metadata" => %{"turn_id" => "ws-owner-pending-close-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, predecessor_pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    parent = self()

    socket_pid =
      spawn(fn ->
        receive do
          :start ->
            {:ok, state} =
              owner_socket(auth, "ws-owner-pending-close-b", turn_state,
                websocket_owner_forwarder_opts: [upstream: upstream_boundary]
              )

            receive do
              {:frame, payload} ->
                {:ok, pending_state} =
                  CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

                pending = pending_state.websocket_owner_pending_handoff
                capability_pid = pending.prepared.provenance.capability.server
                send(parent, {:pending_close_socket_ready, self(), capability_pid})

                receive do
                  :terminate ->
                    :ok = CodexResponsesSocket.terminate(:closed, pending_state)
                end
            end
        end
      end)

    Sandbox.allow(Repo, self(), socket_pid)
    socket_monitor = Process.monitor(socket_pid)
    send(socket_pid, :start)

    replacement_payload =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "ws-owner-pending-close-b",
        "client_metadata" => %{"turn_id" => "ws-owner-pending-close-b"}
      })

    classification_log =
      capture_info_log(fn ->
        send(socket_pid, {:frame, replacement_payload})

        assert_receive {:pending_close_socket_ready, ^socket_pid, capability_pid},
                       @handoff_detection_timeout_ms

        Process.put(:pending_close_capability_pid, capability_pid)
      end)

    capability_pid = Process.delete(:pending_close_capability_pid)
    capability_monitor = Process.monitor(capability_pid)
    owner_pending = :sys.get_state(owner_pid).pending_handoff

    assert length(request_logs(setup.pool.id)) == 1

    assert event_count(
             classification_log,
             WebsocketConnectionLogger.reconnect_disposition_message()
           ) == 1

    assert classification_log =~ "reconnect_disposition=replacement_handoff"
    refute classification_log =~ private_sentinel

    close_log =
      capture_info_log(fn ->
        send(socket_pid, :terminate)

        assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, :normal},
                       @handoff_detection_timeout_ms
      end)

    assert_receive {:DOWN, ^capability_monitor, :process, ^capability_pid, :normal},
                   @handoff_detection_timeout_ms

    assert event_count(close_log, WebsocketConnectionLogger.handoff_outcome_message()) == 1
    assert close_log =~ "handoff_outcome=socket_closed"
    refute close_log =~ private_sentinel
    assert %{pending_handoff: nil} = :sys.get_state(owner_pid)

    send(
      owner_pid,
      {:websocket_owner_handoff_soft_timeout, owner_pending.control_ref, owner_pending.soft_token}
    )

    send(
      owner_pid,
      {:websocket_owner_handoff_absolute_timeout, owner_pending.control_ref,
       owner_pending.absolute_token}
    )

    send(
      socket_pid,
      {:websocket_owner_handoff_ready, "stale", 99, self(), socket_pid, make_ref()}
    )

    assert %{pending_handoff: nil} = :sys.get_state(owner_pid)

    assert [predecessor] = request_logs(setup.pool.id)

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^predecessor.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(turn in CodexTurn, where: turn.request_id == ^predecessor.id),
             :count
           ) == 1

    assert Enum.all?(
             Repo.all(from(entry in LedgerEntry, where: entry.pool_id == ^setup.pool.id)),
             fn entry ->
               entry.request_id == predecessor.id
             end
           )

    refute Process.alive?(predecessor_pid)
    CodexResponsesSocket.terminate(:closed, first_state)
  end

  test "stuck edited replacement times out once without replacement rows" do
    private_sentinel = "REPLAY_PRIVATE_TIMEOUT_SENTINEL"
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-handoff-timeout"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-handoff-timeout-a", turn_state,
        websocket_owner_forwarder_opts: [
          upstream: upstream_boundary,
          handoff_soft_timeout_ms: 25,
          handoff_absolute_timeout_ms: 100
        ]
      )

    first_payload =
      websocket_payload(setup, "timeout predecessor", %{
        "request_id" => "ws-owner-handoff-timeout-a",
        "client_metadata" => %{"turn_id" => "ws-owner-handoff-timeout-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, _predecessor_pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    {:ok, replacement_state} =
      owner_socket(auth, "ws-owner-handoff-timeout-b", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    replacement_payload =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "ws-owner-handoff-timeout-b",
        "client_metadata" => %{"turn_id" => "ws-owner-handoff-timeout-b"}
      })

    owner_monitor = Process.monitor(owner_pid)
    assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    assert Process.alive?(owner_pid)

    assert {:ok, pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               replacement_state
             )

    owner_pending = :sys.get_state(owner_pid).pending_handoff

    send(
      owner_pid,
      {:websocket_owner_handoff_soft_timeout, owner_pending.control_ref, owner_pending.soft_token}
    )

    assert length(request_logs(setup.pool.id)) == 1
    assert_receive {:websocket_owner_handoff_ready, _, _, _, _, _}, @handoff_detection_timeout_ms

    owner_pending = :sys.get_state(owner_pid).pending_handoff

    send(
      owner_pid,
      {:websocket_owner_handoff_absolute_timeout, owner_pending.control_ref,
       owner_pending.absolute_token}
    )

    {timeout_result, timeout_log} =
      with_info_log(fn ->
        assert_receive {:websocket_owner_handoff_failed, _, _, _, _, _, :owner_forward_timeout} =
                         failed,
                       @handoff_detection_timeout_ms

        CodexResponsesSocket.handle_info(failed, pending_state)
      end)

    assert {:push, {:text, timeout_error}, timeout_state} = timeout_result
    assert CodexPooler.JSON.decode!(timeout_error)["error"]["code"] == "owner_forward_timeout"
    assert timeout_state.websocket_owner_pending_handoff == nil
    assert event_count(timeout_log, WebsocketConnectionLogger.handoff_outcome_message()) == 1
    assert timeout_log =~ "handoff_outcome=timeout"
    refute timeout_log =~ private_sentinel
    assert length(request_logs(setup.pool.id)) == 1

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal},
                   @handoff_detection_timeout_ms

    assert {:error, :owner_unavailable} =
             WebsocketOwnerSession.lookup(timeout_state.codex_session.id)
  end

  defp receive_owner_frames_until_error(state, seen_types) do
    assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "error"} = error -> {state, Enum.reverse(seen_types), error}
      %{"type" => type} -> receive_owner_frames_until_error(state, [type | seen_types])
    end
  end

  defp stop_remote_owner!(remote_node, codex_session_id, owner_pid) do
    owner_monitor = Process.monitor(owner_pid)

    assert :ok =
             :erpc.call(
               remote_node,
               WebsocketOwnerNodeHarness,
               :stop_owner,
               [codex_session_id, @handoff_detection_timeout_ms],
               @handoff_detection_timeout_ms
             )

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, _reason},
                   @handoff_detection_timeout_ms

    assert :erpc.call(remote_node, WebsocketOwnerNodeHarness, :owner_absent?, [codex_session_id])
    assert Repo.get_by!(BridgeOwnerLease, codex_session_id: codex_session_id).status == "released"
  end

  defp assert_active_reconnect_frame_matrix(route) when route in [:direct, :proxy] do
    private_sentinel = "REPLAY_ACTIVE_MATRIX_PRIVATE_SENTINEL"
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-active-matrix-#{route}"

    {:ok, first_state} =
      owner_socket(auth, "ws-active-matrix-#{route}-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "active matrix predecessor", %{
        "request_id" => "ws-active-matrix-#{route}-a",
        "client_metadata" => %{"turn_id" => "ws-active-matrix-#{route}-a"}
      })

    assert {:ok, _first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    {:ok, reconnect_state} = owner_socket(auth, "ws-active-matrix-#{route}-b", turn_state)

    reconnect_state = maybe_proxy_owner_state(reconnect_state, route)
    owner_pid = reconnect_state.websocket_owner_pid
    before_owner = :sys.get_state(owner_pid)

    prewarm =
      CodexPooler.JSON.encode!(%{"generate" => false, "model" => setup.model.exposed_model_id})

    {prewarm_result, prewarm_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({prewarm, [opcode: :text]}, reconnect_state)
      end)

    assert {:ok, prewarm_state} = prewarm_result
    assert prewarm_log == ""
    assert length(request_logs(setup.pool.id)) == 1
    assert :sys.get_state(owner_pid).active_turn.descriptor == before_owner.active_turn.descriptor
    assert :sys.get_state(owner_pid).pending_handoff == before_owner.pending_handoff

    assert {:push, {:text, created}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert CodexPooler.JSON.decode!(created)["type"] == "response.created"

    assert {:push, {:text, completed}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert CodexPooler.JSON.decode!(completed)["type"] == "response.completed"
    assert {:ok, prewarm_state} = receive_socket_done(prewarm_state)

    missing = websocket_payload(setup, private_sentinel)

    {missing_result, missing_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({missing, [opcode: :text]}, prewarm_state)
      end)

    assert {:push, {:text, missing_error}, ^prewarm_state} = missing_result
    assert CodexPooler.JSON.decode!(missing_error)["error"]["code"] == "owner_busy"

    assert event_count(missing_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
             1

    assert event_count(missing_log, WebsocketConnectionLogger.replay_rejection_message()) == 1

    assert missing_log =~ "reconnect_disposition=owner_busy"
    assert missing_log =~ "rejection_stage=owner_preflight"
    assert missing_log =~ "reason_code=owner_busy"
    refute missing_log =~ private_sentinel

    different =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "ws-active-matrix-#{route}-different",
        "client_metadata" => %{"turn_id" => "ws-active-matrix-#{route}-different"}
      })

    {different_result, different_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({different, [opcode: :text]}, prewarm_state)
      end)

    assert {:push, {:text, different_error}, ^prewarm_state} = different_result

    assert CodexPooler.JSON.decode!(different_error)["error"]["code"] == "owner_busy"

    assert event_count(different_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
             1

    assert different_log =~ "reconnect_disposition=owner_busy"
    refute different_log =~ private_sentinel
    refute Map.has_key?(:sys.get_state(owner_pid).active_turn, :canceled_result)

    malformed =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "fallback-must-not-win",
        "client_metadata" => %{"turn_id" => "invalid/identity"}
      })

    {malformed_result, malformed_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({malformed, [opcode: :text]}, prewarm_state)
      end)

    assert {:push, {:text, malformed_error}, ^prewarm_state} = malformed_result

    assert %{"status" => 400, "error" => %{"code" => "invalid_request", "param" => param}} =
             CodexPooler.JSON.decode!(malformed_error)

    assert param == "client_metadata.turn_id"

    assert event_count(malformed_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
             1

    assert malformed_log =~ "reconnect_disposition=identity_rejected"
    refute malformed_log =~ private_sentinel

    processed =
      CodexPooler.JSON.encode!(%{
        "type" => "response.processed",
        "response_id" => "resp_active_matrix"
      })

    assert {:push, {:text, processed_error}, ^prewarm_state} =
             CodexResponsesSocket.handle_in({processed, [opcode: :text]}, prewarm_state)

    assert CodexPooler.JSON.decode!(processed_error)["error"]["code"] == "owner_busy"

    public_opts =
      reconnect_state.opts
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    public_state = %{prewarm_state | opts: public_opts}

    public_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => private_sentinel
      })

    assert {:push, {:text, public_error}, ^public_state} =
             CodexResponsesSocket.handle_in({public_payload, [opcode: :text]}, public_state)

    assert CodexPooler.JSON.decode!(public_error)["error"]["code"] == "owner_busy"
    assert length(request_logs(setup.pool.id)) == 1

    send(worker_pid, {:blocking_owner_upstream_release, release_ref})
    assert {:ok, prewarm_state} = receive_owner_socket_complete(prewarm_state)
    assert {:ok, prewarm_state} = receive_socket_done(prewarm_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, prewarm_state)
  end

  defp assert_pending_replacement_prewarm_neutral(route) when route in [:direct, :proxy] do
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-pending-prewarm-#{route}"

    {:ok, first_state} =
      owner_socket(auth, "ws-pending-prewarm-#{route}-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "pending prewarm predecessor", %{
        "request_id" => "ws-pending-prewarm-#{route}-a",
        "client_metadata" => %{"turn_id" => "ws-pending-prewarm-#{route}-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, _pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    {:ok, replacement_state} =
      owner_socket(auth, "ws-pending-prewarm-#{route}-b", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    replacement_state = maybe_proxy_owner_state(replacement_state, route)

    replacement_payload =
      websocket_payload(setup, "pending prewarm replacement", %{
        "request_id" => "ws-pending-prewarm-#{route}-b",
        "client_metadata" => %{"turn_id" => "ws-pending-prewarm-#{route}-b"}
      })

    assert {:ok, pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               replacement_state
             )

    pending_before = pending_state.websocket_owner_pending_handoff
    owner_pending_before = :sys.get_state(owner_pid).pending_handoff

    prewarm =
      CodexPooler.JSON.encode!(%{"generate" => false, "model" => setup.model.exposed_model_id})

    {prewarm_result, prewarm_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({prewarm, [opcode: :text]}, pending_state)
      end)

    assert {:ok, prewarm_state} = prewarm_result
    assert prewarm_log == ""
    assert prewarm_state.websocket_owner_pending_handoff == pending_before

    assert :sys.get_state(owner_pid).pending_handoff.control_ref ==
             owner_pending_before.control_ref

    assert length(request_logs(setup.pool.id)) == 1

    assert {:push, {:text, created}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert CodexPooler.JSON.decode!(created)["type"] == "response.created"

    assert {:push, {:text, completed}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert CodexPooler.JSON.decode!(completed)["type"] == "response.completed"
    assert {:ok, prewarm_state} = receive_socket_done(prewarm_state)
    assert prewarm_state.websocket_owner_pending_handoff == pending_before
    assert length(request_logs(setup.pool.id)) == 1
    CodexResponsesSocket.terminate(:closed, prewarm_state)
    CodexResponsesSocket.terminate(:closed, first_state)
  end

  defp event_count(log, message) when is_binary(log) and is_binary(message) do
    log
    |> String.split(message)
    |> length()
    |> Kernel.-(1)
  end

  defp terminal_blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false, closed?: false} end) end,
      send: fn upstream_pid, request, writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:blocking_owner_upstream_received, self(), release_ref})

        receive do
          {:blocking_owner_upstream_release, ^release_ref} ->
            frame =
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_owner_active_reconnect",
                  "status" => "completed",
                  "output" => [],
                  "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
                }
              })

            decoded = CodexPooler.JSON.decode!(frame)

            cond do
              is_function(request.frame_observer, 2) -> request.frame_observer.(frame, decoded)
              is_function(request.frame_observer, 1) -> request.frame_observer.(frame)
              true -> :ok
            end

            writer.(frame, TerminalDiscriminator.classify(frame))
            :ok
        after
          5_000 -> exit(:blocking_owner_upstream_timeout)
        end
      end,
      close: fn upstream_pid ->
        Agent.update(upstream_pid, fn state -> %{state | closed?: true} end)
        Agent.stop(upstream_pid)
      end
    }
  end

  defp reconnect_handoff_owner_upstream_boundary(test_pid) do
    counter = :counters.new(1, [:atomics])

    %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        :ok = :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        if count == 1 do
          Process.flag(:trap_exit, true)
          send(test_pid, {:controller_handoff_predecessor_started, self()})

          receive do
            {:EXIT, _from, :shutdown} ->
              receive do
                :controller_handoff_never -> :ok
              end
          end
        else
          send(test_pid, {:controller_handoff_replacement_started, count})
          :ok
        end
      end,
      invalidate: fn _upstream_pid -> :ok end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end
end
