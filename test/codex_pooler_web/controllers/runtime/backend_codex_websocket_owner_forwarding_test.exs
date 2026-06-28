defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingTest do
  @moduledoc """
  owner lifecycle terminal-state matrix

  This module is the nearest implementation-facing contract for owner-forwarded
  websocket failures. Keep these terminal states stable so later regression
  tests can grep the matrix before changing behavior.

  - `owner_unavailable` during downstream detach: cleanup-only, sanitized
    failure, triggers bounded recovery/interruption when an active turn may
    exist, and does not create a client-visible request by itself.
  - `owner_unavailable` during request/processed forwarding before upstream
    I/O: request and attempt finalize failed, turn finalizes failed, HTTP/status
    503, code `owner_unavailable`.
  - `owner_drained` during active turn: request and attempt failed, response
    status 499, turn interrupted, session interrupted, lease release reason
    `owner_drained`.
  - late owner drain after request success: request and attempt remain
    succeeded; turn remains or becomes succeeded; no owner error overwrite.
  - persistence failure during owner exit: sanitized observability event plus
    the same synchronous inline recovery helper to be implemented later; no
    Oban/supervised async recovery and no silent swallow.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketConnectionLogger

  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"
  @supported_compression_model "gpt-4o"
  @blocking_owner_receive_timeout_ms 1_000
  @response_task_stop_timeout_ms 1_000

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
    headers
    idempotency
    payload
    prompt
    upstream_body
    websocket_frame
  )

  defmodule StaleOwnerNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Persistence.CodexSession
    alias CodexPooler.Repo

    @impl true
    def connected_app_nodes, do: state().nodes

    @impl true
    def app_node?(node), do: node in state().nodes

    @impl true
    def call_owner(_node, _module, _function, [codex_session_id | _args], _timeout) do
      CodexSession
      |> Repo.get!(codex_session_id)
      |> Ecto.Changeset.change(%{owner_lease_token: Ecto.UUID.generate()})
      |> Repo.update!()

      {:error, :owner_unavailable}
    end

    defp state, do: Process.get(__MODULE__, %{nodes: []})
  end

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "owner-forwarded websocket turns reuse one upstream websocket connection" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_owner_first", "object" => "response"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_second", "object" => "response"})
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-forwarding",
          accepted_turn_state: "stable-ws-owner-forwarding",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload = websocket_payload(setup, "first")

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_first"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      second_payload = websocket_payload(setup, "second")

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_second"} = Jason.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("stable-ws-owner-forwarding")
        )

      refute_raw_turn_state_session_key!(setup.pool.id, "stable-ws-owner-forwarding")
      assert session.owner_instance_id == Atom.to_string(node())
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(session.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded upstream close before terminal persists safe transport metadata" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            {"response.output_text.delta",
             %{
               "type" => "response.output_text.delta",
               "response_id" => "resp_owner_transport_failure",
               "output_index" => 0,
               "content_index" => 0,
               "delta" => @sentinel
             }}
          ],
          reason: "owner upstream close reason sentinel"
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-transport-failure", "owner-transport-failure")

    try do
      payload =
        websocket_payload(setup, "owner forwarded transport failure", %{
          "request_id" => "ws-owner-transport-failure"
        })

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

      assert {:push, {:text, partial_frame}, state} = receive_owner_socket_push(state)

      assert %{"type" => "response.output_text.delta", "delta" => @sentinel} =
               Jason.decode!(partial_frame)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

      assert %{"type" => "error", "error" => %{"code" => "upstream_request_failed"}} =
               Jason.decode!(error_frame)

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.status == "failed"
      assert request_log.transport == "websocket"
      assert request_log.last_error_code == "upstream_stream_error"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
      assert attempt.status == "failed"

      assert attempt.response_metadata["transport_failure"] == %{
               "phase" => "upstream_close",
               "pre_visible_output" => false,
               "reason" => "upstream_websocket_closed_before_terminal",
               "reason_class" => "upstream_websocket_closed_before_terminal",
               "terminal_seen" => false,
               "text_frame_count" => 1
             }

      metadata_text = inspect(attempt.response_metadata)
      refute metadata_text =~ @sentinel
      refute metadata_text =~ "owner upstream close reason sentinel"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
      refute metadata_text =~ "Bearer "
      refute metadata_text =~ "upstream-token"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "owner-forwarded websocket terminal auth refresh retries through the same owner session" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream(
             [
               {"response.failed",
                %{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_owner_auth_terminal",
                    "error" => %{"code" => "invalid_api_key"},
                    "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
                  }
                }}
             ],
             done: false
           ),
           FakeUpstream.json_response(%{"access_token" => "owner-upstream-token-refreshed"}, 200),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_auth_retry_success",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-owner-ws-terminal-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-auth-refresh", "owner-auth-refresh")

    try do
      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {websocket_payload(setup, "owner auth refresh"), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_auth_retry_success"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert [first_request, refresh_request, retried_request] =
               await_upstream_requests(upstream, 3)

      assert first_request.method == "WEBSOCKET"
      assert refresh_request.path == "/oauth/token"
      assert retried_request.method == "WEBSOCKET"

      assert Map.new(retried_request.headers)["authorization"] ==
               "Bearer owner-upstream-token-refreshed"

      assert first_request.websocket_connection_id != retried_request.websocket_connection_id
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1
      assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

      owner_metadata = request.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_unauthorized"
      assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert second_attempt.status == "succeeded"

      metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-owner-ws-terminal-do-not-leak"
      refute metadata_text =~ "owner-upstream-token-refreshed"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "owner-forwarded websocket handshake 401 refreshes through the same owner without demotion" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_upgrade_error(
             %{"error" => %{"code" => "invalid_api_key"}},
             status: 401,
             headers: [{"x-openai-authorization-error", "invalid_api_key"}]
           ),
           FakeUpstream.json_response(
             %{"access_token" => "owner-upstream-token-handshake-refreshed"},
             200
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_auth_handshake_retry_success",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-owner-ws-handshake-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-auth-handshake-refresh", "owner-auth-handshake-refresh")

    try do
      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {websocket_payload(setup, "owner handshake auth refresh"), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_auth_handshake_retry_success"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert [refresh_request, retried_request] = await_upstream_requests(upstream, 2)
      assert refresh_request.path == "/oauth/token"
      assert retried_request.method == "WEBSOCKET"
      assert retried_request.path == "/backend-api/codex/responses"

      assert Map.new(retried_request.headers)["authorization"] ==
               "Bearer owner-upstream-token-handshake-refreshed"

      assert FakeUpstream.websocket_connection_count(upstream) == 1
      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1
      assert request.last_error_code == nil
      assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

      owner_metadata = request.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())
      refute Repo.exists?(from d in BridgeDemotion, where: d.pool_id == ^setup.pool.id)

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_unauthorized"
      assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert second_attempt.status == "succeeded"

      metadata_text =
        inspect(
          {request.request_metadata, first_attempt.response_metadata,
           second_attempt.response_metadata}
        )

      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-owner-ws-handshake-do-not-leak"
      refute metadata_text =~ "owner-upstream-token-handshake-refreshed"
      refute metadata_text =~ "Bearer "
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "response.processed after reconnect is forwarded through the owner upstream connection" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_processed",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-processed-first",
          accepted_turn_state: "stable-ws-owner-processed",
          client_ip: "127.0.0.1"
        }
      })

    first_payload = websocket_payload(setup, "first processed owner turn")

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
    assert %{"id" => "resp_owner_processed"} = Jason.decode!(first_frame)
    assert {:ok, first_state} = receive_owner_socket_complete(first_state)
    assert {:ok, first_state} = receive_socket_done(first_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-processed-second",
          accepted_turn_state: "stable-ws-owner-processed",
          client_ip: "127.0.0.1"
        }
      })

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_processed"
        })

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, second_state)

      assert {:ok, second_state} = receive_owner_socket_complete(second_state)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [first_request, processed_request] = await_upstream_requests(upstream, 2)
      assert first_request.method == "WEBSOCKET"
      assert processed_request.method == "WEBSOCKET"
      assert first_request.websocket_connection_id == processed_request.websocket_connection_id

      assert processed_request.json == %{
               "type" => "response.processed",
               "response_id" => "resp_owner_processed"
             }
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner-forwarded immediate response create retargets socket owner runtime before spawning" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_immediate_retarget_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_immediate_retarget_success",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_state} = owner_socket(auth, "ws-owner-retarget-anchor", "retarget-target")

    target_state =
      try do
        anchor_payload =
          websocket_payload(setup, "owner retarget anchor", %{
            "request_id" => "ws-owner-retarget-anchor"
          })

        assert {:ok, target_state} =
                 CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

        assert {:push, {:text, anchor_frame}, target_state} =
                 receive_owner_socket_push(target_state)

        assert %{"id" => "resp_owner_immediate_retarget_anchor"} = Jason.decode!(anchor_frame)
        assert {:ok, target_state} = receive_socket_done(target_state)
        target_state
      after
        CodexResponsesSocket.terminate(:closed, target_state)
      end

    target_session = target_state.codex_session

    {:ok, origin_state} = owner_socket(auth, "ws-owner-retarget-origin", "retarget-origin")
    origin_session = origin_state.codex_session

    retargeted_state =
      try do
        continuation_payload =
          Jason.encode!(%{
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

        assert %{"id" => "resp_owner_immediate_retarget_success"} = Jason.decode!(retarget_frame)
        assert {:ok, _retargeted_state} = receive_socket_done(retargeted_state)

        assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)

        assert anchor_request.websocket_connection_id ==
                 retargeted_request.websocket_connection_id

        assert retargeted_request.json["previous_response_id"] ==
                 "resp_owner_immediate_retarget_anchor"

        assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
        assert anchor_log.status == "succeeded"
        assert retargeted_log.status == "succeeded"
        assert retargeted_log.correlation_id == "ws-owner-retarget-continuation"

        owner_metadata = retargeted_log.request_metadata["websocket_owner_forwarding"]
        assert owner_metadata["enabled"] == true
        assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
        assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

        retargeted_state
      after
        CodexResponsesSocket.terminate(:closed, origin_state)
      end

    CodexResponsesSocket.terminate(:closed, retargeted_state)
  end

  test "owner-forwarded response create retargets from frame turn-state before spawning" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_turn_state_retarget_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_turn_state_retarget_success",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    target_turn_state = "stable-ws-owner-frame-turn-state-retarget"
    origin_turn_state = "stable-ws-owner-frame-turn-state-origin"

    {:ok, target_state} =
      owner_socket(
        auth,
        "ws-owner-turn-state-retarget-anchor",
        target_turn_state
      )

    target_state =
      try do
        anchor_payload =
          websocket_payload(setup, "owner turn-state retarget anchor", %{
            "request_id" => "ws-owner-turn-state-retarget-anchor"
          })

        assert {:ok, target_state} =
                 CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

        assert {:push, {:text, anchor_frame}, target_state} =
                 receive_owner_socket_push(target_state)

        assert %{"id" => "resp_owner_turn_state_retarget_anchor"} = Jason.decode!(anchor_frame)
        assert {:ok, target_state} = receive_socket_done(target_state)
        target_state
      after
        CodexResponsesSocket.terminate(:closed, target_state)
      end

    target_session = target_state.codex_session
    {:ok, origin_state} = owner_socket(auth, "ws-owner-turn-state-origin", origin_turn_state)
    origin_session = origin_state.codex_session

    retargeted_state =
      try do
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

        assert %{"id" => "resp_owner_turn_state_retarget_success"} = Jason.decode!(retarget_frame)
        assert {:ok, _retargeted_state} = receive_socket_done(retargeted_state)

        assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)

        assert anchor_request.websocket_connection_id ==
                 retargeted_request.websocket_connection_id

        assert retargeted_request.json["client_metadata"]["x-codex-turn-state"] ==
                 target_turn_state

        assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
        assert anchor_log.status == "succeeded"
        assert retargeted_log.status == "succeeded"
        assert retargeted_log.correlation_id == "ws-owner-turn-state-retarget-continuation"
        assert retargeted_log.request_metadata["codex_session_id"] == target_session.id

        owner_metadata = retargeted_log.request_metadata["websocket_owner_forwarding"]
        assert owner_metadata["enabled"] == true
        assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
        assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

        refute_raw_turn_state_session_key!(setup.pool.id, origin_turn_state)
        refute_raw_turn_state_session_key!(setup.pool.id, target_turn_state)
        assert_no_leak_in_persistence!(setup.pool.id)

        retargeted_state
      after
        CodexResponsesSocket.terminate(:closed, origin_state)
      end

    CodexResponsesSocket.terminate(:closed, retargeted_state)
  end

  test "owner-forwarded retarget ignores stale origin downstream and cleans up target owner" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_retarget_cleanup_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_retarget_cleanup_success",
             "object" => "response"
           })
         ]}
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

        assert %{"id" => "resp_owner_retarget_cleanup_anchor"} = Jason.decode!(anchor_frame)
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

        assert %{"id" => "resp_owner_retarget_cleanup_success"} = Jason.decode!(retarget_frame)
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
    assert retargeted_log.correlation_id == "ws-owner-retarget-cleanup-continuation"
    refute inspect(request_logs(setup.pool.id)) =~ "owner_unavailable"
    refute inspect(request_logs(setup.pool.id)) =~ "owner_drained"
  end

  test "owner-forwarded retarget refuses cross-pool previous response aliases before dispatch" do
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

      assert {:ok, refused_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, origin_state)

      assert refused_state.codex_session.id == origin_session.id
      assert refused_state.websocket_owner_lease_token == origin_lease_token
      assert refused_state.websocket_owner_downstream == origin_downstream

      assert {:push, {:text, error_frame}, refused_state} = receive_socket_done(refused_state)

      assert %{
               "status" => 503,
               "error" => %{
                 "code" => "owner_unavailable",
                 "message" => "websocket owner is unavailable"
               }
             } = Jason.decode!(error_frame)

      assert refused_state.codex_session.id == origin_session.id
      assert refused_state.websocket_owner_lease_token == origin_lease_token
      assert refused_state.websocket_owner_downstream == origin_downstream
      assert {:ok, _origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

      assert {:ok, _target_owner_pid} =
               WebsocketOwnerSession.lookup(target_state.codex_session.id)

      assert FakeUpstream.count(origin_upstream) == 0
      assert FakeUpstream.count(target_upstream) == 0
      assert FakeUpstream.websocket_connection_count(origin_upstream) == 0
      assert FakeUpstream.websocket_connection_count(target_upstream) == 0
      assert [] = request_logs(origin_setup.pool.id)
      assert [] = request_logs(target_setup.pool.id)
      assert_no_leak!("cross-scope retarget error frame", error_frame)
      assert_no_leak_in_persistence!(origin_setup.pool.id)
      assert_no_leak_in_persistence!(target_setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, origin_state)
    end
  end

  test "owner-forwarded retarget refuses stale previous response aliases without local fallback" do
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

      assert {:ok, refused_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

      assert refused_state.codex_session.id == session.id
      assert refused_state.websocket_owner_lease_token == lease_token
      assert refused_state.websocket_owner_downstream == downstream

      assert {:push, {:text, error_frame}, refused_state} = receive_socket_done(refused_state)

      assert %{
               "status" => 503,
               "error" => %{
                 "code" => "owner_unavailable",
                 "message" => "websocket owner is unavailable"
               }
             } = Jason.decode!(error_frame)

      assert refused_state.codex_session.id == session.id
      assert refused_state.websocket_owner_lease_token == lease_token
      assert refused_state.websocket_owner_downstream == downstream
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0
      assert [] = request_logs(setup.pool.id)
      assert_no_leak!("stale alias retarget error frame", error_frame)
      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "tool-output continuation after reconnect is forwarded through the owner" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_owner_tool_first", "object" => "response"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_tool_second", "object" => "response"})
         ]}
      )

    setup = gateway_setup(upstream, supported_compression_model_opts())
    enable_request_compression!(setup.pool)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-tool-first",
          accepted_turn_state: "stable-ws-owner-tool",
          client_ip: "127.0.0.1"
        }
      })

    first_payload = websocket_payload(setup, "first owner tool turn")

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
    assert %{"id" => "resp_owner_tool_first"} = Jason.decode!(first_frame)
    assert {:ok, first_state} = receive_owner_socket_complete(first_state)
    assert {:ok, first_state} = receive_socket_done(first_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-tool-second",
          accepted_turn_state: "stable-ws-owner-tool",
          client_ip: "127.0.0.1"
        }
      })

    try do
      omitted_sentinel = "owner websocket compressed omitted marker"
      original_output = compression_log_fixture(omitted_sentinel)

      tool_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_tool",
              "output" => original_output
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_owner_tool_first"
        })

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, second_state)

      assert {:push, {:text, second_frame}, second_state} =
               receive_owner_socket_push(second_state)

      assert %{"id" => "resp_owner_tool_second"} = Jason.decode!(second_frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_owner_tool_first"

      assert [%{"type" => "function_call_output", "call_id" => "call_owner_tool"} = tool_output] =
               second_request.json["input"]

      assert tool_output["output"] == original_output

      assert [first_log, second_log] = request_logs(setup.pool.id)
      assert first_log.status == "succeeded"
      assert second_log.status == "succeeded"

      second_attempt =
        Repo.one!(
          from(a in Attempt,
            where: a.request_id == ^second_log.id,
            order_by: [asc: a.attempt_number]
          )
        )

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "protected_tool_outputs",
               "route_class" => "proxy_websocket",
               "transport" => "websocket",
               "candidate_count" => 0,
               "compressed_count" => 0,
               "skipped_count" => 0,
               "protected_tool_output_skipped_count" => 1
             } = second_attempt.response_metadata["payload_compression"]

      owner_metadata = second_log.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert is_integer(owner_metadata["downstream_epoch"])
      assert owner_metadata["downstream_epoch"] > 0
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())
      refute inspect(second_log.request_metadata) =~ "lease-token"

      refute_payload_compression_leak!(
        second_attempt.response_metadata["payload_compression"],
        [omitted_sentinel, "call_owner_tool"]
      )
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner-forwarded processed ack followed by tool continuation records three succeeded websocket rows" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_chain_first",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{"id" => "resp_owner_chain_tool", "object" => "response"})
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-chain"

    {:ok, first_state} = owner_socket(auth, "ws-owner-chain-first", turn_state)

    try do
      first_payload =
        websocket_payload(setup, "first owner chained turn", %{
          "request_id" => "ws-owner-chain-first"
        })

      assert {:ok, first_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

      assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
      assert %{"id" => "resp_owner_chain_first"} = Jason.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, processed_state} = owner_socket(auth, "ws-owner-chain-processed", turn_state)

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_chain_first",
          "request_id" => "ws-owner-chain-processed"
        })

      assert {:ok, processed_state} =
               CodexResponsesSocket.handle_in(
                 {processed_payload, [opcode: :text]},
                 processed_state
               )

      assert {:ok, _processed_state} = receive_socket_done(processed_state)
    after
      CodexResponsesSocket.terminate(:closed, processed_state)
    end

    {:ok, tool_state} = owner_socket(auth, "ws-owner-chain-tool", turn_state)

    try do
      tool_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_chain_tool",
              "output" => "owner chain tool output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_owner_chain_first",
          "request_id" => "ws-owner-chain-tool"
        })

      assert {:ok, tool_state} =
               CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, tool_state)

      assert {:push, {:text, tool_frame}, tool_state} = receive_owner_socket_push(tool_state)
      assert %{"id" => "resp_owner_chain_tool"} = Jason.decode!(tool_frame)
      assert {:ok, _tool_state} = receive_socket_done(tool_state)
    after
      CodexResponsesSocket.terminate(:closed, tool_state)
    end

    assert [first_request, processed_request, tool_request] = await_upstream_requests(upstream, 3)
    assert first_request.websocket_connection_id == processed_request.websocket_connection_id
    assert processed_request.websocket_connection_id == tool_request.websocket_connection_id
    assert processed_request.json["type"] == "response.processed"
    assert tool_request.json["previous_response_id"] == "resp_owner_chain_first"

    assert [first_log, processed_log, tool_log] = request_logs(setup.pool.id)

    assert Enum.map([first_log, processed_log, tool_log], & &1.correlation_id) == [
             "ws-owner-chain-first",
             "ws-owner-chain-processed",
             "ws-owner-chain-tool"
           ]

    assert Enum.all?([first_log, processed_log, tool_log], &(&1.status == "succeeded"))
    assert Enum.all?([first_log, processed_log, tool_log], &(&1.transport == "websocket"))
    assert Enum.all?([first_log, processed_log, tool_log], &(&1.response_status_code == 200))

    for request_log <- [first_log, processed_log, tool_log] do
      owner_metadata = request_log.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert is_integer(owner_metadata["downstream_epoch"])
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())
    end
  end

  test "owner-forwarded socket queues processed and tool continuation frames sent back to back" do
    release_ref = make_ref()
    upstream_boundary = chained_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-queued-chain"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-queue-first", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    try do
      first_payload =
        websocket_payload(setup, "first owner queued turn", %{
          "request_id" => "ws-owner-queue-first"
        })

      assert {:ok, first_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

      assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
      assert %{"id" => "resp_owner_queue_first"} = Jason.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)

      ensure_previous_response_alias!(
        first_state.codex_session,
        setup.api_key,
        "resp_owner_queue_first"
      )
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, queued_state} = owner_socket(auth, "ws-owner-queue-processed", turn_state)

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_queue_first",
          "request_id" => "ws-owner-queue-processed"
        })

      tool_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_queue_tool",
              "output" => "owner queue tool output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_owner_queue_first",
          "request_id" => "ws-owner-queue-tool"
        })

      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, queued_state)

      assert_receive {:chained_owner_upstream_processed_blocked, processed_pid, ^release_ref}

      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, queued_state)

      assert MapSet.size(queued_state.tasks) == 1
      assert :queue.len(Map.get(queued_state, :queued_response_payloads, :queue.new())) == 1
      refute_received {:chained_owner_upstream_tool_started, ^release_ref}

      send(processed_pid, {:chained_owner_upstream_release, release_ref})
      assert {:ok, queued_state} = receive_socket_done(queued_state)
      assert_receive {:chained_owner_upstream_tool_started, ^release_ref}
      assert {:push, {:text, tool_frame}, queued_state} = receive_owner_socket_push(queued_state)
      assert %{"id" => "resp_owner_queue_tool"} = Jason.decode!(tool_frame)
      assert {:ok, _queued_state} = receive_socket_done(queued_state)
    after
      CodexResponsesSocket.terminate(:closed, queued_state)
    end

    assert [first_log, processed_log, tool_log] = request_logs(setup.pool.id)

    assert Enum.map([first_log, processed_log, tool_log], & &1.correlation_id) == [
             "ws-owner-queue-first",
             "ws-owner-queue-processed",
             "ws-owner-queue-tool"
           ]

    assert Enum.all?([first_log, processed_log, tool_log], &(&1.status == "succeeded"))
    assert Enum.all?([first_log, processed_log, tool_log], &(&1.response_status_code == 200))
  end

  test "queued owner-forwarded continuations retarget only when popped to start" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_anchor_a",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_anchor_b",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_a",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_b",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_a_state} =
      owner_socket(auth, "ws-owner-queue-alias-anchor-a", "queue-alias-target-a")

    target_a_session =
      try do
        anchor_a_payload =
          websocket_payload(setup, "owner queue alias anchor a", %{
            "request_id" => "ws-owner-queue-alias-anchor-a"
          })

        assert {:ok, target_a_state} =
                 CodexResponsesSocket.handle_in(
                   {anchor_a_payload, [opcode: :text]},
                   target_a_state
                 )

        assert {:push, {:text, anchor_a_frame}, target_a_state} =
                 receive_owner_socket_push(target_a_state)

        assert %{"id" => "resp_owner_queue_alias_anchor_a"} = Jason.decode!(anchor_a_frame)
        assert {:ok, _target_a_state} = receive_socket_done(target_a_state)

        ensure_previous_response_alias!(
          target_a_state.codex_session,
          setup.api_key,
          "resp_owner_queue_alias_anchor_a"
        )

        target_a_state.codex_session
      after
        CodexResponsesSocket.terminate(:closed, target_a_state)
      end

    {:ok, target_b_state} =
      owner_socket(auth, "ws-owner-queue-alias-anchor-b", "queue-alias-target-b")

    target_b_session =
      try do
        anchor_b_payload =
          websocket_payload(setup, "owner queue alias anchor b", %{
            "request_id" => "ws-owner-queue-alias-anchor-b"
          })

        assert {:ok, target_b_state} =
                 CodexResponsesSocket.handle_in(
                   {anchor_b_payload, [opcode: :text]},
                   target_b_state
                 )

        assert {:push, {:text, anchor_b_frame}, target_b_state} =
                 receive_owner_socket_push(target_b_state)

        assert %{"id" => "resp_owner_queue_alias_anchor_b"} = Jason.decode!(anchor_b_frame)
        assert {:ok, _target_b_state} = receive_socket_done(target_b_state)

        ensure_previous_response_alias!(
          target_b_state.codex_session,
          setup.api_key,
          "resp_owner_queue_alias_anchor_b"
        )

        target_b_state.codex_session
      after
        CodexResponsesSocket.terminate(:closed, target_b_state)
      end

    {:ok, origin_state} =
      owner_socket(auth, "ws-owner-queue-alias-active", "queue-alias-origin",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    origin_session = origin_state.codex_session
    origin_lease_token = origin_state.websocket_owner_lease_token
    origin_downstream = origin_state.websocket_owner_downstream

    {queued_a_state, queued_b_state} =
      try do
        active_payload =
          websocket_payload(setup, "owner queue alias active", %{
            "request_id" => "ws-owner-queue-alias-active"
          })

        queued_a_payload =
          websocket_payload(setup, "owner queue alias continuation a", %{
            "previous_response_id" => "resp_owner_queue_alias_anchor_a",
            "request_id" => "ws-owner-queue-alias-a"
          })

        queued_b_payload =
          websocket_payload(setup, "owner queue alias continuation b", %{
            "previous_response_id" => "resp_owner_queue_alias_anchor_b",
            "request_id" => "ws-owner-queue-alias-b"
          })

        assert {:ok, origin_state} =
                 CodexResponsesSocket.handle_in({active_payload, [opcode: :text]}, origin_state)

        assert_receive {:blocking_owner_upstream_received, active_worker_pid, ^release_ref}

        assert {:ok, origin_state} =
                 CodexResponsesSocket.handle_in({queued_a_payload, [opcode: :text]}, origin_state)

        assert origin_state.codex_session.id == origin_session.id
        assert origin_state.websocket_owner_lease_token == origin_lease_token
        assert origin_state.websocket_owner_downstream == origin_downstream
        assert MapSet.size(origin_state.tasks) == 1
        assert :queue.len(Map.get(origin_state, :queued_response_payloads, :queue.new())) == 1

        assert {:ok, origin_state} =
                 CodexResponsesSocket.handle_in({queued_b_payload, [opcode: :text]}, origin_state)

        assert origin_state.codex_session.id == origin_session.id
        assert origin_state.websocket_owner_lease_token == origin_lease_token
        assert origin_state.websocket_owner_downstream == origin_downstream
        assert MapSet.size(origin_state.tasks) == 1
        assert :queue.len(Map.get(origin_state, :queued_response_payloads, :queue.new())) == 2
        assert length(FakeUpstream.requests(upstream)) == 2

        send(active_worker_pid, {:blocking_owner_upstream_release, release_ref})
        assert {:ok, queued_a_state} = receive_socket_done(origin_state)
        assert queued_a_state.codex_session.id == target_a_session.id
        refute queued_a_state.codex_session.id == origin_session.id
        assert :queue.len(Map.get(queued_a_state, :queued_response_payloads, :queue.new())) == 1

        assert {:push, {:text, queued_a_frame}, queued_a_state} =
                 receive_owner_socket_push(queued_a_state)

        assert %{"id" => "resp_owner_queue_alias_a"} = Jason.decode!(queued_a_frame)
        assert {:ok, queued_b_state} = receive_socket_done(queued_a_state)
        assert queued_b_state.codex_session.id == target_b_session.id
        refute queued_b_state.codex_session.id == target_a_session.id
        refute queued_b_state.codex_session.id == origin_session.id

        assert {:push, {:text, queued_b_frame}, queued_b_state} =
                 receive_owner_socket_push(queued_b_state)

        assert %{"id" => "resp_owner_queue_alias_b"} = Jason.decode!(queued_b_frame)
        assert {:ok, queued_b_state} = receive_socket_done(queued_b_state)

        {queued_a_state, queued_b_state}
      after
        CodexResponsesSocket.terminate(:closed, origin_state)
      end

    CodexResponsesSocket.terminate(:closed, queued_a_state)
    CodexResponsesSocket.terminate(:closed, queued_b_state)

    assert [anchor_a_request, anchor_b_request, queued_a_request, queued_b_request] =
             await_upstream_requests(upstream, 4)

    assert anchor_a_request.websocket_connection_id == queued_a_request.websocket_connection_id
    assert anchor_b_request.websocket_connection_id == queued_b_request.websocket_connection_id

    assert queued_a_request.json["previous_response_id"] ==
             "resp_owner_queue_alias_anchor_a"

    assert queued_b_request.json["previous_response_id"] ==
             "resp_owner_queue_alias_anchor_b"

    assert [anchor_a_log, anchor_b_log, active_log, queued_a_log, queued_b_log] =
             request_logs(setup.pool.id)

    assert Enum.map(
             [anchor_a_log, anchor_b_log, active_log, queued_a_log, queued_b_log],
             & &1.correlation_id
           ) == [
             "ws-owner-queue-alias-anchor-a",
             "ws-owner-queue-alias-anchor-b",
             "ws-owner-queue-alias-active",
             "ws-owner-queue-alias-a",
             "ws-owner-queue-alias-b"
           ]

    assert Enum.all?(
             [anchor_a_log, anchor_b_log, active_log, queued_a_log, queued_b_log],
             &(&1.status == "succeeded")
           )

    assert active_log.request_metadata["codex_session_id"] == origin_session.id
    assert queued_a_log.request_metadata["codex_session_id"] == target_a_session.id
    assert queued_b_log.request_metadata["codex_session_id"] == target_b_session.id
  end

  test "owner-forwarded response processed close while in flight is not pre-request lifecycle" do
    release_ref = make_ref()
    upstream_boundary = chained_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-processed-close"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-processed-close-first", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    try do
      first_payload =
        websocket_payload(setup, "first owner processed close turn", %{
          "request_id" => "ws-owner-processed-close-first"
        })

      assert {:ok, first_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

      assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
      assert %{"id" => "resp_owner_queue_first"} = Jason.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, processed_state} = owner_socket(auth, "ws-owner-processed-close", turn_state)

    processed_payload =
      Jason.encode!(%{
        "type" => "response.processed",
        "response_id" => "resp_owner_queue_first",
        "request_id" => "ws-owner-processed-close"
      })

    assert {:ok, processed_state} =
             CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, processed_state)

    assert processed_state.request_response_work_started?
    assert_receive {:chained_owner_upstream_processed_blocked, processed_pid, ^release_ref}

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, processed_state)
        end)

      refute logs =~ WebsocketConnectionLogger.closed_message()
      refute logs =~ WebsocketConnectionLogger.init_failed_message()
      assert_no_websocket_lifecycle_leaks!(logs)

      send(processed_pid, {:chained_owner_upstream_release, release_ref})
      flush_socket_done(processed_state)
    after
      send(processed_pid, {:chained_owner_upstream_release, release_ref})
    end

    assert [first_log | _rest] = request_logs(setup.pool.id)
    assert first_log.correlation_id == "ws-owner-processed-close-first"
    assert first_log.status == "succeeded"
  end

  test "active owner reconnect suppresses replayed response create and preserves active turn" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
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
        "request_id" => "ws-owner-active-reconnect-first"
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:blocking_owner_upstream_received, owner_worker_pid, ^release_ref}

    {:ok, second_state} = owner_socket(auth, "ws-owner-active-reconnect-second", turn_state)
    assert second_state.websocket_owner_downstream.epoch == 2
    assert second_state.websocket_owner_active_turn_reconnect? == true

    try do
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

      assert [in_progress_request] = request_logs(setup.pool.id)
      assert in_progress_request.correlation_id == "ws-owner-active-reconnect-first"
      assert in_progress_request.status == "in_progress"

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, second_state)

      assert second_state.websocket_owner_active_turn_reconnect? == true
      assert MapSet.size(second_state.tasks) == 0
      assert length(request_logs(setup.pool.id)) == 1

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})

      assert {:ok, second_state} = receive_owner_socket_complete(second_state)
      assert second_state.websocket_owner_active_turn_reconnect? == false
      assert_receive {:codex_response_done, _pid, :ok}

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.correlation_id == "ws-owner-active-reconnect-first"
      assert request_log.status == "succeeded"
      assert request_log.response_status_code == 200
      assert request_log.last_error_code == nil

      owner_metadata = request_log.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["downstream_epoch"] == 1
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner forwarding does not acquire a second proxy websocket admission slot" do
    with_single_proxy_websocket_slot(fn ->
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_admission"}))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, state} =
        CodexResponsesSocket.init(%{
          auth: auth,
          opts: %{
            request_id: "ws-owner-admission",
            accepted_turn_state: "stable-ws-owner-admission",
            client_ip: "127.0.0.1"
          }
        })

      try do
        payload = websocket_payload(setup, "single admission owner turn")

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
        assert %{"id" => "resp_owner_admission"} = Jason.decode!(frame)
        assert {:ok, _state} = receive_socket_done(state)

        assert [_request] = FakeUpstream.requests(upstream)
        assert [request_log] = request_logs(setup.pool.id)
        assert request_log.status == "succeeded"
        assert request_log.transport == "websocket"
      after
        CodexResponsesSocket.terminate(:closed, state)
      end
    end)
  end

  test "owner-forwarded websocket terminal usage settles priced gpt-5.5 request logs" do
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
          "id" => "resp_owner_priced_gpt55",
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
    {:ok, state} = owner_socket(auth, "ws-owner-priced-gpt55", "owner-priced-gpt55")

    try do
      payload = websocket_payload(setup, "owner priced usage")

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_priced_gpt55"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end

    assert [request] = request_logs(setup.pool.id)
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert request.requested_model == "gpt-5.5"

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

    assert log.usage_status == "usage_known"
    assert log.token_counts.total_tokens == 168
    assert log.cost.status == "priced"
    assert %Decimal{} = log.cost.usd
    assert Decimal.positive?(log.cost.usd)
  end

  test "owner-forwarded response.processed reports owner unavailable when the local owner is gone" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-unavailable",
          accepted_turn_state: "stable-ws-owner-unavailable",
          client_ip: "127.0.0.1"
        }
      })

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_unavailable"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

      assert %{
               "type" => "error",
               "error" => %{"code" => "upstream_websocket_forward_failed", "message" => message}
             } = Jason.decode!(error_frame)

      assert message =~ "owner_unavailable"
      refute error_frame =~ "pinned_continuation_reauth_required"
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner transport session mismatch rejects response.create before upstream submit" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-guard-create", "owner-guard-create")
    {:ok, other_state} = owner_socket(auth, "ws-owner-guard-create-other", "owner-guard-other")

    stale_state = %{state | codex_session: other_state.codex_session}

    try do
      payload = websocket_payload(setup, "owner transport guard create")

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{
               "status" => 409,
               "error" => %{
                 "code" => "stale_owner",
                 "message" => "websocket owner lease is stale"
               }
             } = Jason.decode!(error_frame)

      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "failed"
      assert request.response_status_code == 409
      assert request.last_error_code == "stale_owner"

      assert [attempt] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)
      assert attempt.status == "failed"
      assert attempt.network_error_code == "stale_owner"
    after
      CodexResponsesSocket.terminate(:closed, state)
      CodexResponsesSocket.terminate(:closed, other_state)
    end
  end

  test "owner transport session mismatch rejects response.processed without local fallback" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-guard-processed", "owner-guard-processed")
    {:ok, other_state} = owner_socket(auth, "ws-owner-guard-processed-other", "owner-guard-other")

    stale_state = %{state | codex_session: other_state.codex_session}

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_guard_processed"
        })

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{
               "status" => 502,
               "error" => %{"code" => "upstream_websocket_forward_failed", "message" => message}
             } = Jason.decode!(error_frame)

      assert message =~ "stale_owner"
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0
      assert [] = request_logs(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
      CodexResponsesSocket.terminate(:closed, other_state)
    end
  end

  test "owner-forwarded anomalous close before request reservation logs bounded lifecycle metadata only" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-pre-request-close-#{System.unique_integer([:positive])}"
    turn_state = "stable-owner-pre-request-close-#{System.unique_integer([:positive])}"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts:
                     owner_lifecycle_request_options(request_id, turn_state,
                       authorization_header: "Bearer owner-close-secret-sentinel",
                       idempotency_key: "owner-close-idempotency-secret",
                       forwarded_headers: [{"cookie", "owner-close-cookie-secret"}]
                     ),
                   raw_frame: @sentinel
                 })

        refute state.request_response_work_started?
        assert is_map(state.websocket_owner_downstream)
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.closed_message(),
        ~w(codex_session_id downstream_epoch elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    owner_instance_id = String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=terminate"
    assert line =~ "reason_class=closed"
    assert line =~ "codex_session_id="
    assert line =~ "downstream_epoch=1"
    assert line =~ "owner_instance_id=#{owner_instance_id}"
    refute logs =~ "websocket owner detach failed"
    refute logs =~ "owner_unavailable"
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner-forwarded cleanup-only remote detach failure stays quiet without active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-cleanup-only-detach"
    turn_state = "stable-ws-owner-cleanup-only-detach"

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: owner_lifecycle_request_options(request_id, turn_state)
             })

    remote_node = :"codex_pooler@nodedown-cleanup-only-detach.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          RequestOptions.put_transport(state.opts,
            websocket_owner_forwarder_opts:
              WebsocketOwnerNodeHarness.node_client_opts([remote_node],
                calls: %{remote_node => :nodedown}
              )
          )
    }

    try do
      logs =
        capture_log([level: :warning], fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
        end)

      assert logs == ""
      assert_no_leak!("cleanup-only remote detach logs", logs)
      assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  @tag :owner_detach_failure_recovery
  test "owner detach unavailable during socket terminate is observable and interrupts active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_detach"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-detach-unavailable",
          accepted_turn_state: "stable-ws-owner-detach-unavailable",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    remote_node = :"codex_pooler@nodedown-detach.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :nodedown}
            )
          )
    }

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      assert logs =~ "websocket owner detach failed"
      assert logs =~ "owner_unavailable"
      assert_no_leak!("owner detach failure logs", logs)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "owner_unavailable"
      })

      reloaded_session = Repo.get!(CodexSession, state.codex_session.id)
      assert reloaded_session.owner_lease_expires_at

      assert DateTime.diff(
               reloaded_session.owner_lease_expires_at,
               reloaded_session.disconnected_at,
               :second
             ) == 300
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner detach unavailable during socket terminate with typed request options is observable and interrupts active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_detach_typed"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-detach-unavailable-typed",
          accepted_turn_state: "stable-ws-owner-detach-unavailable-typed",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    remote_node = :"codex_pooler@nodedown-detach-typed.example"

    typed_opts =
      RequestOptions.for_websocket(%{})
      |> RequestOptions.put_continuity(
        accepted_turn_state: "stable-ws-owner-detach-unavailable-typed",
        previous_response_id: nil,
        response_id: nil,
        session_header: nil,
        session_key: nil,
        conversation_key: nil,
        owner_instance_id: nil,
        bridge_owner_lease_ttl_seconds: nil,
        reconnect_window_seconds: nil,
        codex_session: nil,
        codex_turn_id: nil,
        authenticated_owner_attach: false
      )
      |> RequestOptions.put_runtime_context(
        now: nil,
        interrupt_reason: nil,
        gateway_debug_payload: nil
      )
      |> RequestOptions.put_transport(
        websocket_owner_forwarder_opts:
          WebsocketOwnerNodeHarness.node_client_opts([remote_node],
            calls: %{remote_node => :nodedown}
          )
      )

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts: typed_opts
    }

    try do
      assert %RequestOptions{} = remote_state.opts
      assert is_nil(remote_state.opts.continuity.previous_response_id)
      assert is_nil(remote_state.opts.runtime.interrupt_reason)

      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      assert logs =~ "websocket owner detach failed"
      assert logs =~ "owner_unavailable"
      refute logs =~ "Protocol.UndefinedError"
      assert_no_leak!("typed owner detach failure logs", logs)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "owner_unavailable"
      })
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "local owner clean exit releases lease interrupts active turn and permits fresh owner reconnect" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_death"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-clean-exit",
          accepted_turn_state: "stable-ws-owner-clean-exit",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    old_token = state.codex_session.owner_lease_token
    owner_ref = Process.monitor(owner_pid)

    :ok = GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert released_lease = released_owner_lease(state.codex_session.id, old_token)
    assert released_lease.metadata["release_reason"] == "owner_drained"
    refute released_lease.metadata["release_reason"] == "pinned_continuation_reauth_required"
    refute released_lease.metadata["release_reason"] == "owner_crashed"
    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, turn.id).error_code == "owner_drained"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == attempt.id
    assert Repo.get!(Request, request.id).status == "failed"
    assert Repo.get!(Request, request.id).response_status_code == 499
    assert Repo.get!(Request, request.id).last_error_code == "owner_drained"
    refute Repo.get!(Request, request.id).last_error_code == "pinned_continuation_reauth_required"
    assert Repo.get!(Attempt, attempt.id).network_error_code == "owner_drained"

    {:ok, reconnect_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-clean-exit-reconnect",
          accepted_turn_state: "stable-ws-owner-clean-exit",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert reconnect_state.codex_session.id == state.codex_session.id
      assert reconnect_state.codex_session.owner_lease_token != old_token
      assert {:ok, fresh_owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      assert fresh_owner_pid != owner_pid

      assert active_owner_lease(reconnect_state.codex_session.id).lease_token ==
               reconnect_state.codex_session.owner_lease_token
    after
      CodexResponsesSocket.terminate(:closed, reconnect_state)
    end
  end

  test "local owner crash interrupts active turn without waiting for lease expiry" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_crash"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-crash",
          accepted_turn_state: "stable-ws-owner-crash",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}

    owner_monitor = state.websocket_owner_monitor
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :killed} = owner_down

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, state) end)

    assert {:stop, :normal, {1011, "websocket owner crashed"}, stopped_state} =
             handle_result

    refute Map.has_key?(stopped_state, :websocket_owner_monitor)
    refute Map.has_key?(stopped_state, :websocket_owner_pid)
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "pinned_continuation_reauth_required"
    refute logs =~ "owner_drained"
    refute logs =~ "client_disconnected"
    assert_no_leak!("local owner crash monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_crashed"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_crashed"

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(stopped_state, :websocket_owner_downstream)
    )
  end

  test "unexpected owner monitor exit still crashes active turn" do
    assert_abnormal_owner_monitor_down_crashes_active_turn!(
      {:unexpected_owner_exit, :boom},
      "unexpected-exit"
    )
  end

  test "owner monitor normal exit drains active turn without closing websocket" do
    assert_graceful_owner_monitor_down_drains_active_turn!(:normal, "normal")
  end

  test "owner monitor shutdown exit drains active turn and finalizes request attempt turn" do
    assert_graceful_owner_monitor_down_drains_active_turn!(:shutdown, "shutdown")
  end

  test "owner monitor rolling restart exit drains active turn and releases lease" do
    assert_graceful_owner_monitor_down_drains_active_turn!(
      {:shutdown, :rolling_restart},
      "rolling-restart"
    )
  end

  test "idle owner monitor shutdown exit drains lease without warning or finalization" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_idle_owner_shutdown"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-idle-shutdown",
          accepted_turn_state: "stable-ws-owner-monitor-idle-shutdown",
          client_ip: "127.0.0.1"
        }
      })

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(:shutdown)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, warning_logs} =
      with_log([level: :warning], fn ->
        CodexResponsesSocket.handle_info(owner_down, monitored_state)
      end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    assert warning_logs == ""
    assert_no_leak!("idle owner shutdown monitor logs", warning_logs)

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    assert Repo.aggregate(
             from(r in Request, where: r.pool_id == ^setup.pool.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(a in Attempt,
               join: r in Request,
               on: a.request_id == r.id,
               where: r.pool_id == ^setup.pool.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id),
             :count
           ) == 0

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  test "intentional stale owner replacement does not close monitored socket as crashed" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_down"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-down",
          accepted_turn_state: "stable-ws-owner-stale-down",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    owner_monitor = state.websocket_owner_monitor

    :ok = GenServer.stop(owner_pid, {:shutdown, :stale_owner})
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, {:shutdown, :stale_owner}}

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, {:shutdown, :stale_owner}} =
                     owner_down

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, state) end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    refute logs =~ "owner_crashed"
    refute logs =~ "owner_drained"
    refute logs =~ "pinned_continuation_reauth_required"
    assert_no_leak!("stale owner monitor logs", logs)

    assert Repo.get!(Request, request.id).status == "in_progress"
    assert Repo.get!(Attempt, attempt.id).status == "in_progress"
    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"

    refute released_owner_lease_optional(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           )

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.codex_session.owner_lease_token

    assert kept_state.codex_session.owner_lease_token == state.codex_session.owner_lease_token

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  test "stale owner token rejects before upstream send" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-token",
          accepted_turn_state: "stable-ws-owner-stale-token",
          client_ip: "127.0.0.1"
        }
      })

    stale_state = state
    takeover_token = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    state.codex_session
    |> Ecto.Changeset.change(%{owner_lease_token: takeover_token, updated_at: now})
    |> Repo.update!()

    active_owner_lease(state.codex_session.id)
    |> Ecto.Changeset.change(%{lease_token: takeover_token, renewed_at: now, updated_at: now})
    |> Repo.update!()

    try do
      payload = websocket_payload(setup, "stale token should not reach upstream")

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{"error" => %{"code" => "stale_owner", "message" => message}} =
               Jason.decode!(error_frame)

      assert message == "websocket owner lease is stale"
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(
        :closed,
        Map.delete(stale_state, :websocket_owner_downstream)
      )
    end

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    logs =
      capture_info_log(fn ->
        cleanup_local_owner_sessions()
        assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :shutdown}
      end)

    assert logs =~ "websocket owner exit persistence failed"
    assert logs =~ "operation=release_owner_lease"
    assert logs =~ "reason_class=stale_owner"
    assert logs =~ "owner_exit_reason=owner_drained"
    assert_no_leak!("stale owner cleanup logs", logs)
  end

  @tag :owner_drained_terminal_state
  test "owner drain sends safe interruption releases lease and suppresses later stale downstream terminate" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_drain"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-drain-first",
          accepted_turn_state: "stable-ws-owner-drain",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, first_state.codex_session)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    assert :ok = WebsocketOwnerSession.drain_owner(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert_receive {:websocket_owner_frame, _correlation_id, _epoch,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.metadata.reason == "owner_drained"

    assert released_owner_lease(
             first_state.codex_session.id,
             first_state.codex_session.owner_lease_token
           )

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: first_state.codex_session,
      error_code: "owner_drained"
    })

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-drain-second",
          accepted_turn_state: "stable-ws-owner-drain",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert second_state.websocket_owner_downstream.epoch == 1
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(second_state.codex_session.id)
      assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  @tag :owner_drained_terminal_state
  test "late owner drain preserves already succeeded request attempt and turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_late_drain"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-late-drain",
          accepted_turn_state: "stable-ws-owner-late-drain",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_late_drain_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    assert :ok = WebsocketOwnerSession.drain_owner(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert_receive {:websocket_owner_frame, _correlation_id, _epoch,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.metadata.reason == "owner_drained"

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    assert Repo.get!(CodexSession, state.codex_session.id).status == "interrupted"

    logs = capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, state) end)

    refute logs =~ "websocket owner detach failed"
    refute logs =~ "owner_unavailable"
    assert_no_leak!("late owner drain detach logs", logs)

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
  end

  @tag :owner_interruption_terminal_state
  test "owner interruption preserves a turn after disconnect accounting wins the race" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_disconnect_race"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-disconnect-accounting-race",
          accepted_turn_state: "stable-ws-owner-disconnect-accounting-race",
          client_ip: "127.0.0.1"
        }
      })

    try do
      %{request: request, attempt: attempt, turn: turn} =
        active_turn_fixture(setup, auth, state.codex_session)

      assert {:ok, %{request: failed_request, attempt: failed_attempt}} =
               Accounting.finalize_request(request, attempt, %{
                 request_status: "failed",
                 attempt_status: "failed",
                 response_status_code: 499,
                 last_error_code: "client_disconnected",
                 error_message: "websocket client disconnected before the turn completed",
                 usage: %{status: "usage_unknown", source: "client_disconnected"}
               })

      assert failed_request.status == "failed"
      assert failed_attempt.status == "failed"
      assert Repo.get!(CodexTurn, turn.id).status == "in_progress"

      interrupt_opts =
        %{
          interrupt_reason: "client_disconnected",
          reconnect_window_seconds: 300
        }
        |> RequestOptions.for_websocket()

      assert {:ok, %{interrupted_turn_count: 1}} =
               Interruption.interrupt_codex_session(state.codex_session, interrupt_opts)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "client_disconnected"
      })
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :owner_recovery_preserves_success
  test "owner detach recovery preserves already succeeded request attempt and turn" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_recovery_success"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-recovery-success",
          accepted_turn_state: "stable-ws-owner-recovery-success",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_recovery_success_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    remote_node = :"codex_pooler@nodedown-recovery-success.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :nodedown}
            )
          )
    }

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      refute logs =~ "websocket owner detach failed"
      refute logs =~ "owner_unavailable"
      assert_no_leak!("owner recovery success logs", logs)
      assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner detach recovery cleanup remains idempotent after success preservation" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_cleanup_idempotent"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-recovery-cleanup",
          accepted_turn_state: "stable-ws-owner-recovery-cleanup",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_recovery_cleanup_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    remote_node = :"codex_pooler@nodedown-recovery-cleanup.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          RequestOptions.for_websocket(%{})
          |> RequestOptions.put_continuity(
            accepted_turn_state: "stable-ws-owner-recovery-cleanup",
            previous_response_id: nil,
            response_id: nil,
            session_header: nil,
            session_key: nil,
            conversation_key: nil,
            owner_instance_id: nil,
            bridge_owner_lease_ttl_seconds: nil,
            reconnect_window_seconds: nil,
            codex_session: nil,
            codex_turn_id: nil,
            authenticated_owner_attach: false
          )
          |> RequestOptions.put_runtime_context(
            now: nil,
            interrupt_reason: nil,
            gateway_debug_payload: nil
          )
          |> RequestOptions.put_transport(
            websocket_owner_forwarder_opts:
              WebsocketOwnerNodeHarness.node_client_opts([remote_node],
                calls: %{remote_node => :nodedown}
              )
          )
    }

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      refute logs =~ "websocket owner detach failed"
      refute logs =~ "owner_unavailable"
      refute logs =~ "Protocol.UndefinedError"
      assert_no_leak!("owner recovery cleanup logs", logs)
      assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

      assert :ok =
               CodexResponsesSocket.terminate(
                 :closed,
                 Map.delete(state, :websocket_owner_downstream)
               )
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "remote owner nodedown fails closed without mutating active lease" do
    remote_node = :"codex_pooler@nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-nodedown",
        owner_instance_id: remote_node_string
      })

    lease = active_owner_lease(session.id)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               session.owner_lease_token,
               %{pid: self(), epoch: 1, correlation_id: "corr-nodedown"},
               Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_nodedown"}),
               opts
             )

    reloaded_lease = Repo.get!(BridgeOwnerLease, lease.id)
    assert reloaded_lease.status == "active"
    assert reloaded_lease.lease_token == lease.lease_token
    assert reloaded_lease.owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner socket init takes over an unavailable remote owner lease" do
    remote_node = :"codex_pooler@init-nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-nodedown",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    state = %{
      auth: auth,
      opts: %{
        request_id: "ws-owner-init-nodedown",
        accepted_turn_state: "stable-ws-owner-init-nodedown",
        client_ip: "127.0.0.1",
        websocket_owner_forwarder_opts: forwarder_opts
      }
    }

    logs =
      capture_info_log(fn ->
        assert {:ok, returned_state} = CodexResponsesSocket.init(state)
        assert returned_state.auth == auth
        assert returned_state.opts.request_id == state.opts.request_id
        assert returned_state.opts.accepted_turn_state == state.opts.accepted_turn_state
        assert returned_state.opts.client_ip == state.opts.client_ip
        assert returned_state.opts.websocket_owner_forwarder_opts == forwarder_opts

        assert returned_state.codex_session.id == session.id
        assert returned_state.codex_session.owner_lease_token != old_lease.lease_token
        assert returned_state.codex_session.owner_instance_id == Atom.to_string(node())

        assert returned_state.websocket_owner_lease_token ==
                 returned_state.codex_session.owner_lease_token

        assert returned_state.websocket_owner_downstream.epoch == 1

        CodexResponsesSocket.terminate(:closed, returned_state)
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    refute logs =~ "pinned_continuation_reauth_required"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=ws-owner-init-nodedown"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_forward_timeout"
    refute logs =~ "owner_crashed"
    assert_no_leak!("owner init nodedown takeover logs", logs)
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
             "owner_unavailable_takeover"

    assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
    assert FakeUpstream.count(upstream) == 0
  end

  test "successful owner socket init takeover stays below warning" do
    remote_node = :"codex_pooler@init-nodedown-warning-owner.example"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, _session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-warning",
        owner_instance_id: Atom.to_string(remote_node)
      })

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    warning_logs =
      capture_log([level: :warning], fn ->
        assert {:ok, returned_state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: %{
                     request_id: "ws-owner-init-warning",
                     accepted_turn_state: "stable-ws-owner-init-warning",
                     client_ip: "127.0.0.1",
                     websocket_owner_forwarder_opts: forwarder_opts
                   }
                 })

        CodexResponsesSocket.terminate(:closed, returned_state)
      end)

    assert warning_logs == ""
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :task_5_timeout
  test "remote owner attach timeout preserves owner_forward_timeout" do
    remote_node = :"codex_pooler@attach-timeout-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-attach-timeout",
        owner_instance_id: remote_node_string
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout}
      )

    assert {:error, :owner_forward_timeout} =
             Gateway.prepare_websocket_session(auth, %{
               accepted_turn_state: "stable-ws-owner-attach-timeout",
               client_ip: "127.0.0.1",
               websocket_owner_forwarder_opts: Keyword.put(opts, :timeout, 25)
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{function: :remote_attach_downstream, timeout: 25}}

    assert active_owner_lease(session.id).owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :task_5_timeout
  test "owner socket init timeout closes normally while preserving owner error detail" do
    remote_node = :"codex_pooler@init-timeout-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-timeout",
        owner_instance_id: remote_node_string
      })

    request_id = "ws-owner-init-timeout"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert :ok =
                 WebsocketConnectionLogger.log_init_failed_before_request_reservation(
                   %{
                     request_id: request_id,
                     endpoint: "/backend-api/codex/responses",
                     transport: "websocket",
                     route_class: "proxy_websocket",
                     phase: "init",
                     elapsed_ms: 17,
                     codex_session_id: session.id,
                     owner_instance_id: remote_node_string,
                     proxy_instance_id: Atom.to_string(node())
                   },
                   :timeout
                 )
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        "websocket init failed before request reservation",
        ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    expected_endpoint = String.replace("/backend-api/codex/responses", ~r/[^a-zA-Z0-9_.:-]+/, "_")
    expected_owner_instance_id = String.replace(remote_node_string, ~r/[^a-zA-Z0-9_.:-]+/, "_")

    expected_proxy_instance_id =
      String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=#{expected_endpoint}"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "codex_session_id=#{session.id}"
    assert line =~ "owner_instance_id=#{expected_owner_instance_id}"
    assert line =~ "proxy_instance_id=#{expected_proxy_instance_id}"

    assert [] = request_logs(setup.pool.id)

    assert active_owner_lease(session.id).owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :task_5_nodedown
  test "remote owner attach nodedown takes over lease without leaking erpc details" do
    remote_node = :"codex_pooler@attach-nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-attach-nodedown",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :raw_nodedown}
      )

    logs =
      capture_info_log(fn ->
        assert {:ok, runtime} =
                 Gateway.prepare_websocket_session(auth, %{
                   accepted_turn_state: "stable-ws-owner-attach-nodedown",
                   client_ip: "127.0.0.1",
                   websocket_owner_forwarder_opts: opts
                 })

        assert runtime.codex_session.id == session.id
        assert runtime.codex_session.owner_lease_token != old_lease.lease_token
        assert runtime.codex_session.owner_instance_id == Atom.to_string(node())
        assert runtime.websocket_owner_downstream.epoch == 1

        Gateway.detach_websocket_owner_downstream(
          runtime.codex_session,
          runtime.websocket_owner_lease_token,
          runtime.websocket_owner_downstream,
          %{websocket_owner_forwarder_opts: opts}
        )
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_forward_timeout"
    refute logs =~ "owner_crashed"
    assert_no_leak!("owner attach nodedown takeover logs", logs)
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
             "owner_unavailable_takeover"

    assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner takeover failure remains warning and actionable without leaking lease token" do
    remote_node = :"codex_pooler@takeover-failure-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-takeover-failure",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)
    opts = stale_owner_node_client_opts([remote_node])

    logs =
      capture_log([level: :warning], fn ->
        assert {:error, :stale_owner} =
                 Gateway.prepare_websocket_session(auth, %{
                   accepted_turn_state: "stable-ws-owner-takeover-failure",
                   client_ip: "127.0.0.1",
                   websocket_owner_forwarder_opts: opts
                 })
      end)

    assert logs =~ "websocket owner takeover failed"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=investigate"
    assert logs =~ "outcome=failed"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "failure_reason=stale_owner"
    refute logs =~ old_lease.lease_token
    refute logs =~ "operator_action=none"
    assert_no_leak!("owner takeover failure logs", logs)
    assert FakeUpstream.count(upstream) == 0
  end

  test "role-neutral worker and scheduler nodes are not selected as owner targets" do
    remote_worker = :"codex_pooler@10.42.0.20"
    remote_scheduler = :"codex_pooler@10.42.0.21"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, worker_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-role-worker",
        owner_instance_id: Atom.to_string(remote_worker)
      })

    {:ok, scheduler_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-role-scheduler",
        owner_instance_id: Atom.to_string(remote_scheduler)
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_worker, remote_scheduler],
        roles: %{remote_worker => "worker", remote_scheduler => "scheduler"}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               worker_session,
               worker_session.owner_lease_token,
               downstream_target("corr-role-worker"),
               Jason.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_role_worker"
               }),
               opts
             )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               scheduler_session,
               scheduler_session.owner_lease_token,
               downstream_target("corr-role-scheduler"),
               Jason.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_role_scheduler"
               }),
               opts
             )

    assert_receive {:websocket_owner_harness_app_node_check,
                    %{node: ^remote_worker, role: "worker", app_node?: false}}

    assert_receive {:websocket_owner_harness_app_node_check,
                    %{node: ^remote_scheduler, role: "scheduler", app_node?: false}}

    refute_received {:websocket_owner_harness_node_call, %{node: ^remote_worker}}
    refute_received {:websocket_owner_harness_node_call, %{node: ^remote_scheduler}}
    assert FakeUpstream.count(upstream) == 0
  end

  test "stale owner downstream detach does not remove the newer downstream" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-first",
          accepted_turn_state: "stable-ws-owner-stale",
          client_ip: "127.0.0.1"
        }
      })

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-second",
          accepted_turn_state: "stable-ws-owner-stale",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert first_state.websocket_owner_downstream.epoch == 1
      assert second_state.websocket_owner_downstream.epoch == 2

      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

      payload = websocket_payload(setup, "after stale detach")

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

      assert {:push, {:text, frame}, second_state} = receive_owner_socket_push(second_state)
      assert %{"id" => "resp_owner_stale"} = Jason.decode!(frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner-forwarded turn takes over when the local owner disappears after socket init" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_dispatch_takeover"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-dispatch-takeover", "dispatch-takeover")
    session = state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}

    try do
      {{:ok, _handled_state, frame}, warning_logs} =
        with_log([level: :warning], fn ->
          payload = websocket_payload(setup, "dispatch takeover")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
          assert {:ok, state} = receive_socket_done(state)

          {:ok, state, frame}
        end)

      assert warning_logs == ""
      assert %{"id" => "resp_owner_dispatch_takeover"} = Jason.decode!(frame)
      assert active_owner_lease(session.id).lease_token == old_lease.lease_token
      assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
      assert [request] = await_upstream_requests(upstream, 1)
      assert request.json["input"] |> List.first() |> Map.get("content") == "dispatch takeover"

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.status == "succeeded"
      assert request_log.response_status_code == 200
      assert is_nil(request_log.last_error_code)

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
      assert attempt.status == "succeeded"
      assert attempt.upstream_status_code == 200
      assert is_nil(attempt.network_error_code)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded turn takes over when local owner drained after socket init" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_dispatch_drain_takeover"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-dispatch-drain-takeover", "dispatch-drain")
    session = state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    :ok = GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    logs =
      capture_info_log(fn ->
        try do
          payload = websocket_payload(setup, "dispatch drain takeover")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
          assert %{"id" => "resp_owner_dispatch_drain_takeover"} = Jason.decode!(frame)
          assert {:ok, _state} = receive_socket_done(state)

          active_lease = active_owner_lease(session.id)
          assert active_lease.lease_token != old_lease.lease_token
          assert active_lease.owner_instance_id == Atom.to_string(node())

          assert [request] = await_upstream_requests(upstream, 1)

          assert request.json["input"] |> List.first() |> Map.get("content") ==
                   "dispatch drain takeover"

          assert [request_log] = request_logs(setup.pool.id)
          assert request_log.status == "succeeded"
          assert request_log.response_status_code == 200
          assert is_nil(request_log.last_error_code)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=ws-owner-dispatch-drain-takeover"
    assert logs =~ "previous_owner_instance_id=#{Atom.to_string(node())}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_crashed"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] == "owner_drained"

    assert_no_leak!("local drain dispatch takeover logs", logs)
  end

  test "owner-forwarded socket replaces a local owner with a dead upstream before first dispatch" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_upstream"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} = owner_socket(auth, "ws-owner-stale-upstream-first", "stale-upstream")
    session = first_state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    %{upstream_pid: upstream_pid} = :sys.get_state(owner_pid)
    upstream_ref = Process.monitor(upstream_pid)
    Process.exit(upstream_pid, :kill)
    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream_pid, :killed}

    {:ok, second_state} = owner_socket(auth, "ws-owner-stale-upstream-second", "stale-upstream")

    try do
      {:ok, replacement_owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert replacement_owner_pid != owner_pid
      assert active_owner_lease(session.id).lease_token == old_lease.lease_token
      assert second_state.websocket_owner_downstream.epoch == 1

      payload = websocket_payload(setup, "after stale upstream")

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

      assert {:push, {:text, frame}, second_state} = receive_owner_socket_push(second_state)
      assert %{"id" => "resp_owner_stale_upstream"} = Jason.decode!(frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [request] = await_upstream_requests(upstream, 1)
      assert request.json["input"] |> List.first() |> Map.get("content") == "after stale upstream"
    after
      CodexResponsesSocket.terminate(:closed, first_state)
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner forwarding keeps authenticated attaches scoped to the same api key" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_auth"}))
    setup = gateway_setup(upstream)
    alternate_key = CodexPooler.PoolerFixtures.api_key_fixture(setup.pool)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-auth"})

    {:ok, alternate_auth} = Access.authenticate_authorization_header(alternate_key.authorization)

    assert Gateway.start_codex_session(alternate_auth, %{
             accepted_turn_state: "stable-ws-auth",
             authenticated_owner_attach: true
           }) == {:error, :owner_unavailable}

    refute Repo.get_by(CodexSession,
             session_key: turn_state_session_key("stable-ws-auth"),
             api_key_id: alternate_key.api_key.id
           )

    refute_raw_turn_state_session_key!(setup.pool.id, "stable-ws-auth")

    assert Repo.get!(CodexSession, session.id).api_key_id == setup.api_key.id
  end

  test "owner forwarding rejects cross-pool and guessed authenticated attaches" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_reject"}))
    setup = gateway_setup(upstream)
    other_key = CodexPooler.PoolerFixtures.api_key_fixture()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-auth-reject"})

    {:ok, other_auth} = Access.authenticate_authorization_header(other_key.authorization)

    assert Gateway.prepare_websocket_session(other_auth, %{
             session_header: session.session_key,
             client_ip: "127.0.0.1"
           }) == {:error, :owner_unavailable}

    assert Gateway.prepare_websocket_session(auth, %{
             session_header: Ecto.UUID.generate(),
             client_ip: "127.0.0.1"
           }) == {:error, :owner_unavailable}

    assert Gateway.prepare_websocket_session(auth, %{
             previous_response_id: "resp_owner_guess",
             client_ip: "127.0.0.1"
           }) == {:error, :owner_unavailable}

    refute Repo.get_by(CodexSession,
             pool_id: other_key.pool.id,
             session_key: session.session_key
           )
  end

  test "owner forwarding rejects a stale bearer before owner attach" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_bearer"}))
    setup = gateway_setup(upstream)

    setup.api_key
    |> APIKey.changeset(%{status: "revoked", revoked_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:error, _reason} = Access.authenticate_authorization_header(setup.authorization)
  end

  @tag :leakage
  test "owner-forwarded success processed and tool continuation keep sentinel out of persisted logs and process state" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_owner_leak_first"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_leak_processed"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_leak_tool"})
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_log(fn ->
        {:ok, first_state} = owner_socket(auth, "ws-owner-leak-success", "leak-success")

        first_state =
          try do
            first_payload = websocket_payload(setup, @sentinel)

            assert {:ok, first_state} =
                     CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

            assert {:push, {:text, first_frame}, first_state} =
                     receive_owner_socket_push(first_state)

            assert %{"id" => "resp_owner_leak_first"} = Jason.decode!(first_frame)
            assert {:ok, first_state} = receive_socket_done(first_state)
            first_state
          after
            CodexResponsesSocket.terminate(:closed, first_state)
          end

        {:ok, processed_state} = owner_socket(auth, "ws-owner-leak-processed", "leak-success")

        try do
          processed_payload =
            Jason.encode!(%{
              "type" => "response.processed",
              "response_id" => "resp_owner_leak_first",
              "client_context" => @sentinel
            })

          assert {:ok, processed_state} =
                   CodexResponsesSocket.handle_in(
                     {processed_payload, [opcode: :text]},
                     processed_state
                   )

          assert {:ok, processed_state} = receive_owner_socket_complete(processed_state)
          assert {:ok, _processed_state} = receive_socket_done(processed_state)
        after
          CodexResponsesSocket.terminate(:closed, processed_state)
        end

        {:ok, tool_state} = owner_socket(auth, "ws-owner-leak-tool", "leak-success")

        try do
          tool_payload =
            Jason.encode!(%{
              "type" => "response.create",
              "model" => setup.model.exposed_model_id,
              "input" => [
                %{
                  "type" => "function_call_output",
                  "call_id" => "call_owner_leak_tool",
                  "output" => @sentinel
                }
              ],
              "stream" => true,
              "generate" => true,
              "previous_response_id" => "resp_owner_leak_first"
            })

          assert {:ok, tool_state} =
                   CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, tool_state)

          assert {:push, {:text, tool_frame}, tool_state} = receive_owner_socket_push(tool_state)
          assert %{"id" => "resp_owner_leak_tool"} = Jason.decode!(tool_frame)
          assert {:ok, _tool_state} = receive_socket_done(tool_state)
        after
          CodexResponsesSocket.terminate(:closed, tool_state)
        end

        assert first_state.codex_session.id
      end)

    assert_no_leak!("success logs", logs)

    assert [first_request, processed_request, tool_request] = await_upstream_requests(upstream, 3)
    assert_leak_allowed_only_in_fake_upstream!(first_request)
    assert_leak_allowed_only_in_fake_upstream!(processed_request)
    assert_leak_allowed_only_in_fake_upstream!(tool_request)
    assert tool_request.json["previous_response_id"] == "resp_owner_leak_first"

    assert tool_request.json["input"] |> List.first() |> Map.get("call_id") ==
             "call_owner_leak_tool"

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert_no_leak_in_persistence!(setup.pool.id)

    {:ok, owner_pid} =
      WebsocketOwnerSession.lookup(
        Repo.get_by!(CodexSession, session_key: turn_state_session_key("leak-success")).id
      )

    assert_no_leak!("owner state after success", :sys.get_state(owner_pid))
  end

  @tag :leakage
  test "owner-forwarded upstream failure keeps sentinel out of logs and accounting rows" do
    upstream =
      start_upstream(
        {:json_error, 500,
         %{
           "error" => %{"code" => "synthetic_upstream_failure", "message" => "synthetic failure"}
         }}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-leak-failure", "leak-failure")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state} = receive_owner_socket_push(state)

          assert %{
                   "type" => "response.failed",
                   "error" => %{"code" => "synthetic_upstream_failure"}
                 } = Jason.decode!(error_frame)

          assert {:ok, _state} = receive_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("failure logs", logs)
    assert [request] = FakeUpstream.requests(upstream)
    assert_leak_allowed_only_in_fake_upstream!(request)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  @tag :leakage
  test "owner raw-frame workers and per-turn response tasks are sensitive while holding sentinel payloads" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-leak-sensitive", "leak-sensitive",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert_receive {:blocking_owner_upstream_received, owner_worker_pid, ^release_ref}
          assert_sensitive_process_hides_mailbox!(owner_worker_pid)
          assert_sensitive_tracked_response_task!(state)

          send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
          assert {:ok, state} = receive_owner_socket_complete(state)
          assert {:ok, _state} = receive_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("sensitive worker logs", logs)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  test "owner request reservation is finalized when socket closes during upstream work" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-close-during-request", "close-during-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "close while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert state.request_response_work_started?
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, state)
        end)

      refute logs =~ WebsocketConnectionLogger.closed_message()
      refute logs =~ WebsocketConnectionLogger.init_failed_message()
      refute logs =~ "websocket owner detach failed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession, session_key: turn_state_session_key("close-during-request"))

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "client_disconnected"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "client_disconnected"
      assert turn.status == "interrupted"
      assert turn.error_code == "client_disconnected"
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :owner_drained_terminal_state
  test "planned rollout drain during active owner request records owner drained instead of owner crashed" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-drain-active-request", "rollout-drain-active-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "rollout drain while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate({:shutdown, :rollout}, state)
        end)

      refute logs =~ "owner_crashed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("rollout-drain-active-request")
        )

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "owner_drained"
      refute request.last_error_code == "owner_crashed"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "owner_drained"
      refute attempt.network_error_code == "owner_crashed"
      assert turn.status == "interrupted"
      assert turn.error_code == "owner_drained"
      refute turn.error_code == "owner_crashed"

      assert released_owner_lease(
               session.id,
               state.websocket_owner_lease_token
             ).metadata["release_reason"] == "owner_drained"
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  test "owner rollout timeline preserves interrupted and recovered websocket rows" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(
             [%{"id" => "resp_owner_timeline_interrupted", "object" => "response"}],
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_timeline_recovered",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-rollout-timeline"
    interrupted_request_id = "ws-owner-timeline-interrupted"
    recovered_request_id = "ws-owner-timeline-recovered"

    {:ok, state} = owner_socket(auth, interrupted_request_id, turn_state)

    payload =
      websocket_payload(setup, "owner timeline interrupted", %{
        "request_id" => interrupted_request_id
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref}, 1_000

    assert [interrupted_upstream_request] = await_upstream_requests(upstream, 1)

    assert interrupted_upstream_request.json["input"] |> List.first() |> Map.get("content") ==
             "owner timeline interrupted"

    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    interrupted_request =
      Repo.one!(
        from r in Request,
          where: r.pool_id == ^setup.pool.id and r.correlation_id == ^interrupted_request_id
      )

    interrupted_attempt =
      Repo.one!(from a in Attempt, where: a.request_id == ^interrupted_request.id)

    interrupted_turn =
      Repo.one!(from t in CodexTurn, where: t.request_id == ^interrupted_request.id)

    session = Repo.get_by!(CodexSession, session_key: turn_state_session_key(turn_state))
    refute_raw_turn_state_session_key!(setup.pool.id, turn_state)

    assert_owner_interruption_state!(%{
      request: interrupted_request,
      attempt: interrupted_attempt,
      turn: interrupted_turn,
      session: session,
      error_code: "client_disconnected"
    })

    remote_node = :"codex_pooler@timeline-unavailable-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    old_lease = active_owner_lease(session.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session
    |> Ecto.Changeset.change(%{owner_instance_id: remote_node_string, updated_at: now})
    |> Repo.update!()

    old_lease
    |> Ecto.Changeset.change(%{owner_instance_id: remote_node_string, updated_at: now})
    |> Repo.update!()

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    logs =
      capture_info_log(fn ->
        {:ok, recovered_state} =
          owner_socket(auth, recovered_request_id, turn_state,
            websocket_owner_forwarder_opts: forwarder_opts
          )

        try do
          recovered_payload =
            websocket_payload(setup, "owner timeline recovered", %{
              "request_id" => recovered_request_id
            })

          assert {:ok, recovered_state} =
                   CodexResponsesSocket.handle_in(
                     {recovered_payload, [opcode: :text]},
                     recovered_state
                   )

          assert {:push, {:text, recovered_frame}, recovered_state} =
                   receive_owner_socket_push(recovered_state)

          assert %{"id" => "resp_owner_timeline_recovered"} = Jason.decode!(recovered_frame)
          assert {:ok, _recovered_state} = receive_socket_done(recovered_state)
        after
          CodexResponsesSocket.terminate(:closed, recovered_state)
        end
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=#{recovered_request_id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    assert_no_leak!("owner rollout timeline takeover logs", logs)

    released_lease = Repo.get!(BridgeOwnerLease, old_lease.id)
    assert released_lease.status == "released"
    assert released_lease.metadata["release_reason"] == "owner_unavailable_takeover"

    active_lease = active_owner_lease(session.id)
    assert active_lease.owner_instance_id == Atom.to_string(node())
    assert active_lease.metadata["source"] == "owner_unavailable_takeover"

    recovered_request =
      Repo.one!(
        from r in Request,
          where: r.pool_id == ^setup.pool.id and r.correlation_id == ^recovered_request_id
      )

    recovered_attempt = Repo.one!(from a in Attempt, where: a.request_id == ^recovered_request.id)
    recovered_turn = Repo.one!(from t in CodexTurn, where: t.request_id == ^recovered_request.id)

    assert Repo.get!(Request, interrupted_request.id).status == "failed"
    assert Repo.get!(Request, interrupted_request.id).response_status_code == 499
    assert Repo.get!(Request, interrupted_request.id).last_error_code == "client_disconnected"
    assert Repo.get!(Attempt, interrupted_attempt.id).status == "failed"
    assert Repo.get!(Attempt, interrupted_attempt.id).network_error_code == "client_disconnected"
    assert Repo.get!(CodexTurn, interrupted_turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, interrupted_turn.id).error_code == "client_disconnected"

    assert recovered_request.status == "succeeded"
    assert recovered_request.response_status_code == 200
    assert is_nil(recovered_request.last_error_code)
    assert recovered_attempt.status == "succeeded"
    assert recovered_attempt.upstream_status_code == 200
    assert is_nil(recovered_attempt.network_error_code)
    assert recovered_turn.status == "succeeded"
    assert is_nil(recovered_turn.error_code)
    assert recovered_turn.final_attempt_id == recovered_attempt.id

    assert [first_upstream_request, second_upstream_request] =
             await_upstream_requests(upstream, 2)

    assert Enum.map([first_upstream_request, second_upstream_request], fn request ->
             request.json["input"] |> List.first() |> Map.get("content")
           end) == ["owner timeline interrupted", "owner timeline recovered"]

    assert FakeUpstream.count(upstream) == 2
  end

  @tag :leakage
  test "owner remote wrapper and process crash paths sanitize sentinel-bearing frames" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_timeout = :"codex_pooler@timeout-leak.example"
    remote_crash = :"codex_pooler@crash-leak.example"

    {:ok, timeout_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "leak-remote-timeout",
        owner_instance_id: Atom.to_string(remote_timeout)
      })

    {:ok, crash_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "leak-remote-crash",
        owner_instance_id: Atom.to_string(remote_crash)
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_timeout, remote_crash],
        calls: %{remote_timeout => :timeout, remote_crash => :crash}
      )

    logs =
      capture_log(fn ->
        timeout_result =
          WebsocketOwnerForwarder.submit_frame(
            timeout_session,
            timeout_session.owner_lease_token,
            downstream_target("corr-timeout-leak"),
            @sentinel,
            Keyword.put(opts, :timeout, 25)
          )

        crash_result =
          WebsocketOwnerForwarder.submit_frame(
            crash_session,
            crash_session.owner_lease_token,
            downstream_target("corr-crash-leak"),
            @sentinel,
            opts
          )

        assert timeout_result == {:error, :owner_forward_timeout}
        assert crash_result == {:error, :owner_crashed}
        assert_no_leak!("remote timeout result", timeout_result)
        assert_no_leak!("remote crash result", crash_result)
      end)

    assert_no_leak!("remote wrapper logs", logs)

    Enum.each([:remote_submit_frame, :remote_submit_frame], fn function ->
      assert_receive {:websocket_owner_harness_node_call, %{function: ^function} = call}
      assert_no_leak!("remote call observation", call)
    end)

    owner_crash_logs =
      capture_log(fn ->
        upstream_boundary = crashing_owner_upstream_boundary(self())

        {:ok, owner_pid} =
          WebsocketOwnerSession.start_owner(
            codex_session_id: "synthetic-leak-owner-#{System.unique_integer([:positive])}",
            owner_lease_token: Ecto.UUID.generate(),
            owner_instance_id: Atom.to_string(node()),
            upstream: upstream_boundary
          )

        {:ok, downstream} =
          WebsocketOwnerSession.attach_downstream(
            owner_pid,
            downstream_target("corr-owner-crash")
          )

        assert WebsocketOwnerSession.submit_frame(owner_pid, downstream, @sentinel) ==
                 {:error, :owner_crashed}

        assert_receive {:crashing_owner_upstream_received, upstream_pid}

        assert_receive {:websocket_owner_frame, "corr-owner-crash", 1,
                        {:error, :owner_crashed, safe_payload}}

        assert safe_payload.metadata.reason == "owner_crashed"
        assert_no_leak!("owner crash payload", safe_payload)
        assert_no_leak!("owner state after crash", :sys.get_state(owner_pid))
        assert_no_leak!("crashing owner upstream state", crashing_owner_safe_state(upstream_pid))
      end)

    assert_no_leak!("owner crash logs", owner_crash_logs)

    per_turn_logs =
      capture_log(fn ->
        {:ok, state} = owner_socket(auth, "ws-owner-leak-worker-crash", "leak-worker-crash")

        try do
          crash_state = %{state | auth: %{}}
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, crash_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, crash_state)

          assert {:push, {:text, error_frame}, _state} = receive_socket_done(crash_state)

          assert %{
                   "type" => "error",
                   "error" => %{"code" => "websocket_response_task_failed"}
                 } = Jason.decode!(error_frame)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("per-turn worker crash logs", per_turn_logs)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  defp websocket_payload(setup, content, extra \\ %{}) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => content}],
      "stream" => true,
      "generate" => true
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp ensure_previous_response_alias!(
         %CodexSession{} = session,
         %APIKey{} = api_key,
         response_id
       ) do
    alias_hash = :crypto.hash(:sha256, response_id)

    case Repo.get_by(BridgeSessionAlias,
           pool_id: session.pool_id,
           api_key_id: api_key.id,
           alias_kind: "previous_response_id",
           alias_hash: alias_hash,
           status: "active"
         ) do
      %BridgeSessionAlias{} = alias_record ->
        alias_record

      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %BridgeSessionAlias{}
        |> BridgeSessionAlias.changeset(%{
          codex_session_id: session.id,
          pool_id: session.pool_id,
          api_key_id: api_key.id,
          alias_kind: "previous_response_id",
          alias_hash: alias_hash,
          alias_preview: "synthetic-prev",
          status: "active",
          expires_at: DateTime.add(now, 300, :second),
          last_seen_at: now,
          metadata: %{},
          created_at: now,
          updated_at: now
        })
        |> Repo.insert!()
    end
  end

  defp capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp capture_websocket_lifecycle_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(
        [
          level: :info,
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

  defp stale_owner_node_client_opts(nodes) when is_list(nodes) do
    previous = Process.get(StaleOwnerNodeClient)
    Process.put(StaleOwnerNodeClient, %{nodes: nodes})

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Process.delete(StaleOwnerNodeClient)
        value -> Process.put(StaleOwnerNodeClient, value)
      end
    end)

    [node_client: StaleOwnerNodeClient]
  end

  defp owner_socket(auth, request_id, turn_state, extra_opts \\ []) do
    CodexResponsesSocket.init(%{
      auth: auth,
      opts:
        Map.merge(
          %{
            request_id: request_id,
            accepted_turn_state: turn_state,
            client_ip: "127.0.0.1"
          },
          Map.new(extra_opts)
        )
    })
  end

  defp owner_lifecycle_request_options(request_id, turn_state, extra_opts \\ []) do
    %{
      request_id: request_id,
      accepted_turn_state: turn_state,
      client_ip: "127.0.0.1"
    }
    |> Map.merge(Map.new(extra_opts))
    |> RequestOptions.for_websocket()
  end

  defp enable_request_compression!(pool) do
    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      request_compression_enabled: true,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp supported_compression_model_opts do
    [
      exposed_model_id: @supported_compression_model,
      upstream_model_id: @supported_compression_model,
      pricing_ref: @supported_compression_model
    ]
  end

  defp refute_payload_compression_leak!(metadata, forbidden_values) when is_map(metadata) do
    metadata_text = inspect(metadata)

    for value <- forbidden_values do
      if String.contains?(metadata_text, value) do
        flunk("payload compression metadata leaked forbidden owner websocket request content")
      end
    end
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

  defp receive_owner_socket_push(state) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:push, _frame, _state} = result -> result
          {:ok, state} -> receive_owner_socket_push(state)
        end
    after
      1_000 -> flunk("expected owner websocket response frame")
    end
  end

  defp receive_owner_socket_complete(state) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:ok, state} -> {:ok, state}
          {:push, _frame, state} -> receive_owner_socket_complete(state)
        end
    after
      1_000 -> flunk("expected owner websocket completion frame")
    end
  end

  defp flush_socket_done(state) do
    receive do
      {:codex_response_done, pid, result} ->
        CodexResponsesSocket.handle_info({:codex_response_done, pid, result}, state)
    after
      100 -> :ok
    end
  end

  defp request_logs(pool_id) do
    Repo.all(
      from(r in Request,
        where: r.pool_id == ^pool_id,
        order_by: [asc: r.admitted_at]
      )
    )
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

    refute downcased_logs =~ @sentinel
  end

  defp assert_abnormal_owner_monitor_down_crashes_active_turn!(owner_reason, suffix) do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_#{suffix}"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-#{suffix}",
          accepted_turn_state: "stable-ws-owner-monitor-#{suffix}",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(owner_reason)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, monitored_state) end)

    assert {:stop, :normal, {1011, "websocket owner crashed"}, stopped_state} =
             handle_result

    refute Map.has_key?(stopped_state, :websocket_owner_monitor)
    refute Map.has_key?(stopped_state, :websocket_owner_pid)
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "owner_drained"
    refute logs =~ "client_disconnected"
    assert_no_leak!("owner #{suffix} abnormal monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_crashed"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_crashed"

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(stopped_state, :websocket_owner_downstream)
    )
  end

  defp assert_graceful_owner_monitor_down_drains_active_turn!(owner_reason, suffix) do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_#{suffix}"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-#{suffix}",
          accepted_turn_state: "stable-ws-owner-monitor-#{suffix}",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, state.codex_session)

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(owner_reason)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, monitored_state) end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    refute logs =~ "owner_crashed"
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "client_disconnected"
    assert_no_leak!("owner #{suffix} monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_drained"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  defp owner_monitor_down(owner_reason) do
    owner_pid =
      spawn(fn ->
        receive do
          {:finish_owner, :normal} -> :ok
          {:finish_owner, reason} -> exit(reason)
        end
      end)

    owner_monitor = Process.monitor(owner_pid)
    send(owner_pid, {:finish_owner, owner_reason})
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, ^owner_reason} = owner_down
    {owner_pid, owner_monitor, owner_down}
  end

  defp active_turn_fixture(setup, auth, session) do
    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "owner lifecycle"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: "ws-owner-lifecycle-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)
    %{request: reserved.request, attempt: attempt, turn: turn}
  end

  defp assert_owner_interruption_state!(%{
         request: request,
         attempt: attempt,
         turn: turn,
         session: session,
         error_code: error_code
       }) do
    reloaded_request = Repo.get!(Request, request.id)
    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    reloaded_turn = Repo.get!(CodexTurn, turn.id)
    reloaded_session = Repo.get!(CodexSession, session.id)

    assert reloaded_request.status == "failed"
    assert reloaded_request.response_status_code == 499
    assert reloaded_request.last_error_code == error_code
    assert reloaded_attempt.status == "failed"
    assert reloaded_attempt.upstream_status_code == 499
    assert reloaded_attempt.network_error_code == error_code
    assert reloaded_turn.status == "interrupted"
    assert reloaded_turn.error_code == error_code
    assert reloaded_turn.final_attempt_id == attempt.id
    assert reloaded_session.status == "interrupted"
  end

  defp assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn}) do
    reloaded_request = Repo.get!(Request, request.id)
    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    reloaded_turn = Repo.get!(CodexTurn, turn.id)

    assert reloaded_request.status == "succeeded"
    assert reloaded_request.response_status_code == 200
    assert is_nil(reloaded_request.last_error_code)
    assert reloaded_attempt.status == "succeeded"
    assert reloaded_attempt.upstream_status_code == 200
    assert is_nil(reloaded_attempt.network_error_code)
    assert reloaded_turn.status == "succeeded"
    assert is_nil(reloaded_turn.error_code)
    assert reloaded_turn.final_attempt_id == attempt.id
  end

  defp assert_no_leak_in_persistence!(pool_id) do
    assert_no_leak!("persistence rows", persistence_excerpt(pool_id))
  end

  defp refute_raw_turn_state_session_key!(pool_id, turn_state) do
    refute Repo.exists?(
             from session in CodexSession,
               where:
                 session.pool_id == ^pool_id and
                   fragment("lower(?)", session.session_key) == ^String.downcase(turn_state)
           )
  end

  defp turn_state_session_key(turn_state) do
    "x-codex-turn-state:" <>
      (:crypto.hash(:sha256, String.trim(turn_state)) |> Base.encode16(case: :lower))
  end

  defp persistence_excerpt(pool_id) do
    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^pool_id,
          order_by: [asc: r.admitted_at],
          select: %{
            endpoint: r.endpoint,
            transport: r.transport,
            status: r.status,
            request_metadata: r.request_metadata,
            last_error_code: r.last_error_code,
            response_status_code: r.response_status_code
          }
      )

    request_ids = Repo.all(from r in Request, where: r.pool_id == ^pool_id, select: r.id)
    session_ids = Repo.all(from s in CodexSession, where: s.pool_id == ^pool_id, select: s.id)

    %{
      requests: requests,
      attempts:
        Repo.all(
          from a in Attempt,
            where: a.request_id in ^request_ids,
            order_by: [asc: a.attempt_number],
            select: %{
              transport: a.transport,
              status: a.status,
              network_error_code: a.network_error_code,
              error_message: a.error_message,
              response_metadata: a.response_metadata
            }
        ),
      codex_sessions:
        Repo.all(
          from s in CodexSession,
            where: s.pool_id == ^pool_id,
            select: %{
              session_key: s.session_key,
              conversation_key: s.conversation_key,
              status: s.status,
              owner_instance_id: s.owner_instance_id
            }
        ),
      codex_turns:
        Repo.all(
          from t in CodexTurn,
            where: t.codex_session_id in ^session_ids,
            select: %{
              transport_kind: t.transport_kind,
              status: t.status,
              error_code: t.error_code
            }
        ),
      bridge_owner_leases:
        Repo.all(
          from l in BridgeOwnerLease,
            where: l.pool_id == ^pool_id,
            select: %{
              owner_instance_id: l.owner_instance_id,
              status: l.status,
              metadata: l.metadata
            }
        ),
      bridge_session_aliases:
        Repo.all(
          from a in BridgeSessionAlias,
            where: a.pool_id == ^pool_id,
            select: %{
              alias_kind: a.alias_kind,
              alias_preview: a.alias_preview,
              status: a.status,
              metadata: a.metadata
            }
        )
    }
  end

  defp assert_leak_allowed_only_in_fake_upstream!(request) do
    assert inspect(%{body: request.body, json: request.json}) =~ @sentinel
    assert_no_leak!("fake upstream metadata", Map.drop(request, [:body, :json]))
  end

  defp assert_no_leak!(label, value) do
    if value |> inspect(limit: 80, printable_limit: 4_000) |> String.contains?(@sentinel) do
      flunk("sentinel leaked through #{label}")
    end
  end

  defp assert_sensitive_tracked_response_task!(state) do
    [pid] = MapSet.to_list(state.tasks)
    assert_sensitive_process_hides_mailbox!(pid)
  end

  defp assert_sensitive_process_hides_mailbox!(pid) when is_pid(pid) do
    marker = {:sensitive_probe, make_ref(), @sentinel}
    send(pid, marker)
    assert_process_messages_hidden!(pid, 100)
  end

  defp assert_process_messages_hidden!(pid, attempts) when attempts > 0 do
    case :erlang.process_info(pid, :messages) do
      {:messages, []} ->
        :ok

      nil ->
        flunk("sensitive process exited before introspection check")

      _messages ->
        yield_once({:assert_process_messages_hidden, pid, attempts})
        assert_process_messages_hidden!(pid, attempts - 1)
    end
  end

  defp assert_process_messages_hidden!(_pid, 0), do: flunk("sensitive process exposed mailbox")

  defp assert_stale_owner_downstream_ignored(owner_pid, stale_downstream, state) do
    stale_payload = Jason.encode!(%{"id" => "resp_owner_retarget_stale_origin_frame"})

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

  defp downstream_target(correlation_id),
    do: %{pid: self(), epoch: 1, correlation_id: correlation_id}

  defp crashing_owner_upstream_boundary(test_pid) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false} end) end,
      send: fn upstream_pid, _payload, _writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:crashing_owner_upstream_received, upstream_pid})
        exit(:simulated_owner_worker_crash)
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp chained_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{count: 0} end) end,
      send: fn upstream_pid, upstream_payload, writer ->
        count =
          Agent.get_and_update(upstream_pid, fn state ->
            {state.count + 1, %{state | count: state.count + 1}}
          end)

        case {count, upstream_payload} do
          {1, %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{}} ->
            writer.(Jason.encode!(%{"id" => "resp_owner_queue_first", "object" => "response"}))
            :ok

          {2, payload} when is_binary(payload) ->
            send(test_pid, {:chained_owner_upstream_processed_blocked, self(), release_ref})

            receive do
              {:chained_owner_upstream_release, ^release_ref} -> :ok
            after
              5_000 -> exit(:chained_owner_upstream_timeout)
            end

          {3, %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{}} ->
            send(test_pid, {:chained_owner_upstream_tool_started, release_ref})
            writer.(Jason.encode!(%{"id" => "resp_owner_queue_tool", "object" => "response"}))
            :ok
        end
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false, closed?: false} end) end,
      send: fn upstream_pid, _request, _writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:blocking_owner_upstream_received, self(), release_ref})

        receive do
          {:blocking_owner_upstream_release, ^release_ref} -> :ok
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

  defp assert_blocking_owner_upstream_received!(release_ref) do
    receive do
      {:blocking_owner_upstream_received, owner_worker_pid, ^release_ref} -> owner_worker_pid
    after
      @blocking_owner_receive_timeout_ms ->
        flunk("expected blocking owner upstream to receive the websocket request")
    end
  end

  defp assert_response_task_stopped!(state) do
    [response_task_pid] = MapSet.to_list(state.tasks)
    monitor = Process.monitor(response_task_pid)

    assert_receive {:DOWN, ^monitor, :process, ^response_task_pid, _reason},
                   @response_task_stop_timeout_ms
  end

  defp crashing_owner_safe_state(upstream_pid) do
    Agent.get(upstream_pid, fn state -> state end)
  catch
    :exit, _reason -> %{closed?: true}
  end

  defp active_owner_lease(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1
    )
  end

  defp released_owner_lease(session_id, lease_token) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session_id and lease.lease_token == ^lease_token and
            lease.status == "released",
        limit: 1
    )
  end

  defp released_owner_lease_optional(session_id, lease_token) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session_id and lease.lease_token == ^lease_token and
            lease.status == "released",
        limit: 1
    )
  end

  defp await_upstream_requests(upstream, expected_count, attempts \\ 100)

  defp await_upstream_requests(upstream, expected_count, attempts) when attempts > 0 do
    requests = FakeUpstream.requests(upstream)

    if length(requests) == expected_count do
      requests
    else
      yield_once({:await_upstream_requests, expected_count, attempts})
      await_upstream_requests(upstream, expected_count, attempts - 1)
    end
  end

  defp await_upstream_requests(upstream, _expected_count, 0), do: FakeUpstream.requests(upstream)

  defp yield_once(message) do
    send(self(), message)

    receive do
      ^message -> :ok
    end
  end

  defp with_single_proxy_websocket_slot(fun) do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        bulkheads:
          Map.new(Admission.route_classes(), fn route_class ->
            {route_class, %{max_concurrency: 4, queue_limit: 0, queue_timeout_ms: 1_000}}
          end)
          |> Map.put("proxy_websocket", %{
            max_concurrency: 1,
            queue_limit: 0,
            queue_timeout_ms: 1_000
          })
      }
    )

    Admission.reset_for_test()

    try do
      fun.()
    after
      Admission.reset_for_test()

      case previous_settings do
        nil -> Application.delete_env(:codex_pooler, OperationalSettings)
        value -> Application.put_env(:codex_pooler, OperationalSettings, value)
      end
    end
  end

  defp cleanup_local_owner_sessions do
    logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn codex_session_id ->
          try do
            with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
              _result = GenServer.stop(owner_pid, :shutdown, 1_000)
            end
          catch
            :exit, _reason -> :ok
          end
        end)
      end)

    assert_no_leak!("owner cleanup logs", logs)
  end
end
