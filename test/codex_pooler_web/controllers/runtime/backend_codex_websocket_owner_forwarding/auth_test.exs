defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.AuthTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient

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

  @tag :feature_websocket_terminal_auth_refresh
  test "owner-forwarded websocket terminal auth refresh retries through the same owner session" do
    upstream =
      start_upstream(
        # Strict finite scenario: the terminal auth failure on the first
        # connection triggers exactly one token refresh over HTTP, and the retry
        # must carry the refreshed bearer on a replacement connection.
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
                    "id" => "resp_owner_auth_terminal",
                    "error" => %{"code" => "invalid_api_key"},
                    "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
                  }
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "POST",
            path: "/oauth/token",
            respond:
              FakeUpstream.json_response(
                %{"access_token" => "owner-upstream-token-refreshed"},
                200
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            headers: [required: %{"authorization" => "Bearer owner-upstream-token-refreshed"}],
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_auth_retry_success",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
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
      assert %{"id" => "resp_owner_auth_retry_success"} = CodexPooler.JSON.decode!(frame)
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

      assert [first_opaque_connection_id, second_opaque_connection_id] =
               FakeUpstream.websocket_connection_ids(upstream)

      assert is_reference(first_opaque_connection_id)
      assert is_reference(second_opaque_connection_id)
      assert first_opaque_connection_id != second_opaque_connection_id

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1
      assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

      owner_metadata = request.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

      assert [first_attempt, second_attempt] = pool_attempts(setup.pool.id)

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_unauthorized"
      assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert second_attempt.status == "succeeded"

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

      metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-owner-ws-terminal-do-not-leak"
      refute metadata_text =~ "owner-upstream-token-refreshed"
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "owner-forwarded websocket handshake 401 refreshes through the same owner without demotion" do
    initial_residency = "ws-owner-initial-region-#{System.unique_integer([:positive])}"
    refreshed_residency = "ws-owner-refreshed-region-#{System.unique_integer([:positive])}"
    initial_access_token = synthetic_access_token(initial_residency)
    refreshed_access_token = synthetic_access_token(refreshed_residency)

    # Strict: a 401 handshake, one provider token refresh, then the retried
    # handshake succeeds through the same owner on the first accepted connection.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "GET",
            respond:
              FakeUpstream.websocket_upgrade_error(
                %{"error" => %{"code" => "invalid_api_key"}},
                status: 401,
                headers: [{"x-openai-authorization-error", "invalid_api_key"}]
              )
          ),
          FakeUpstream.expect_request(
            method: "POST",
            path: "/oauth/token",
            respond: FakeUpstream.json_response(%{"access_token" => refreshed_access_token}, 200)
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_auth_handshake_retry_success",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "access_token",
               plaintext: initial_access_token
             })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-owner-ws-handshake-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    telemetry_handler_id = attach_stream_outcome_telemetry!()
    on_exit(fn -> :telemetry.detach(telemetry_handler_id) end)

    {:ok, state} =
      owner_socket(auth, "ws-owner-auth-handshake-refresh", "owner-auth-handshake-refresh")

    try do
      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      {{:ok, state}, logs} =
        with_info_log(fn ->
          CodexResponsesSocket.handle_in(
            {websocket_payload(setup, "owner handshake auth refresh"), [opcode: :text]},
            state
          )
        end)

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)

      assert %{"id" => "resp_owner_auth_handshake_retry_success"} =
               CodexPooler.JSON.decode!(frame)

      assert {:ok, _state} = receive_socket_done(state)
      assert_receive {:stream_outcome, telemetry_metadata}
      refute inspect(telemetry_metadata) =~ initial_residency
      refute inspect(telemetry_metadata) =~ refreshed_residency
      refute inspect(telemetry_metadata) =~ initial_access_token
      refute inspect(telemetry_metadata) =~ refreshed_access_token
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert [refresh_request, retried_request] = await_upstream_requests(upstream, 2)
      assert refresh_request.path == "/oauth/token"
      assert retried_request.method == "WEBSOCKET"
      assert retried_request.path == "/backend-api/codex/responses"

      assert Map.new(retried_request.headers)["authorization"] ==
               "Bearer #{refreshed_access_token}"

      assert header_values(retried_request.headers, "x-openai-internal-codex-residency") == [
               refreshed_residency
             ]

      refute initial_residency in header_values(
               retried_request.headers,
               "x-openai-internal-codex-residency"
             )

      assert header_values(retried_request.headers, "chatgpt-account-id") == [
               setup.identity.chatgpt_account_id
             ]

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

      assert [first_attempt, second_attempt] = pool_attempts(setup.pool.id)

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
      refute metadata_text =~ initial_residency
      refute metadata_text =~ refreshed_residency
      refute metadata_text =~ initial_access_token
      refute metadata_text =~ refreshed_access_token
      refute metadata_text =~ "Bearer "

      assert_owner_websocket_values_not_persisted!(
        setup,
        [initial_residency, refreshed_residency, initial_access_token, refreshed_access_token],
        logs
      )
    after
      CodexResponsesSocket.terminate(:closed, state)
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

  defp attach_stream_outcome_telemetry! do
    handler_id = "owner-residency-stream-outcome-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    handler_id
  end
end
