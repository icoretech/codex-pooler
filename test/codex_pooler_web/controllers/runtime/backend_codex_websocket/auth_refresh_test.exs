defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.AuthRefreshTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request, RequestReplay}
  alias CodexPooler.FakeUpstream

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @large_websocket_frame_timeout 5_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000

  @tag :feature_websocket_terminal_auth_refresh
  test "websocket handshake 401 refreshes once and retries the same assignment" do
    initial_residency = "ws-initial-region-#{System.unique_integer([:positive])}"
    refreshed_residency = "ws-refreshed-region-#{System.unique_integer([:positive])}"
    initial_access_token = synthetic_access_token(initial_residency)
    refreshed_access_token = synthetic_access_token(refreshed_residency)

    # Strict: a 401 handshake, one provider token refresh, then the retried
    # handshake succeeds and the turn lands on the first accepted connection.
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
          strict_native_response_payload(websocket_auth_retry_success_payload("handshake_401"), 1)
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
               plaintext: "refresh-token-ws-handshake-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_log(fn ->
        capture_stream_outcome_telemetry(fn ->
          assert :ok =
                   execute_websocket_response(
                     auth,
                     websocket_auth_refresh_payload(setup, "handshake-401"),
                     %{request_id: "ws-auth-handshake-401"},
                     fn frame -> send(self(), {:websocket_frame, frame}) end
                   )

          assert_receive {:stream_outcome, telemetry_metadata}
          refute inspect(telemetry_metadata) =~ initial_residency
          refute inspect(telemetry_metadata) =~ refreshed_residency
          refute inspect(telemetry_metadata) =~ initial_access_token
          refute inspect(telemetry_metadata) =~ refreshed_access_token
        end)
      end)

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_auth_retry_handshake_401"} = CodexPooler.JSON.decode!(frame)

    [refresh_request, retried_request] = FakeUpstream.requests(upstream)
    assert refresh_request.path == "/oauth/token"
    assert retried_request.method == "WEBSOCKET"
    assert retried_request.path == "/backend-api/codex/responses"
    assert Map.new(retried_request.headers)["authorization"] == "Bearer #{refreshed_access_token}"

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
    refute metadata_text =~ initial_residency
    refute metadata_text =~ refreshed_residency
    refute metadata_text =~ initial_access_token
    refute metadata_text =~ refreshed_access_token

    assert_websocket_values_not_persisted!(
      setup,
      [initial_residency, refreshed_residency, initial_access_token, refreshed_access_token],
      logs
    )
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "stale generation handshake auth failure exits without refresh retry or downstream frame" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{"error" => %{"code" => "invalid_api_key"}},
          status: 401,
          headers: [{"x-openai-authorization-error", "invalid_api_key"}],
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    client =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(
          auth,
          websocket_auth_refresh_payload(setup, "stale-replay-generation"),
          %{
            request_id: "ws-auth-stale-replay-generation",
            accepted_turn_state: Ecto.UUID.generate()
          },
          fn frame -> send(parent, {:stale_auth_websocket_frame, frame}) end
        )
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref},
                   @large_websocket_frame_timeout

    assert [request] = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert turn = Repo.get_by!(CodexTurn, request_id: request.id)

    turn
    |> Ecto.Changeset.change(%{semantic_turn_digest: <<1::256>>})
    |> Repo.update!()

    session = Repo.get!(CodexSession, turn.codex_session_id)

    assert {:ok, _armed} =
             RequestReplay.arm(%{
               api_key_id: auth.api_key.id,
               pool_id: auth.pool.id,
               codex_session_id: session.id,
               request_id: request.id,
               codex_turn_id: turn.id,
               eligible_attempt_id: attempt.id,
               api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch,
               model_id: setup.model.id,
               model_identifier: setup.model.exposed_model_id,
               endpoint: request.endpoint,
               semantic_turn_digest: <<1::256>>,
               replay_claim_digest: <<2::256>>,
               owner_instance_id: session.owner_instance_id,
               owner_lease_token: session.owner_lease_token,
               predecessor_epoch: 1,
               failure_reason: :client_disconnected,
               pre_visible_output: true
             })

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert :ok = Task.await(client, @connection_shutdown_timeout_ms)
    refute_received {:stale_auth_websocket_frame, _frame}
    refute Enum.any?(FakeUpstream.requests(upstream), &(&1.path == "/oauth/token"))
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "retryable_failed"
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "websocket auth failure under a replaced credential epoch skips the provider refresh" do
    release_ref = make_ref()

    # No /oauth/token entry in the sequence: a provider refresh would consume
    # the retry success payload and fail the test loudly.
    # Strict: a held 401 handshake, then the retried handshake succeeds
    # without any provider refresh in between.
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
                headers: [{"x-openai-authorization-error", "invalid_api_key"}],
                notify: self(),
                release_ref: release_ref
              )
          ),
          strict_native_response_payload(websocket_auth_retry_success_payload("stale_epoch"), 1)
        ])
      )

    setup = gateway_setup(upstream)
    original_epoch = CredentialFencing.credential_epoch(setup.identity)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    client =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(
          auth,
          websocket_auth_refresh_payload(setup, "stale-epoch"),
          %{request_id: "ws-auth-stale-epoch"},
          fn frame -> send(parent, {:websocket_frame, frame}) end
        )
      end)

    # The dispatch has connected with the original credentials; rotate them
    # before the 401 is delivered, as a concurrent refresh would.
    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref},
                   5_000

    identity = Repo.get!(UpstreamIdentity, setup.identity.id)

    identity
    |> Ecto.Changeset.change(%{metadata: CredentialFencing.advance_credential_epoch(identity)})
    |> Repo.update!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "rotated-ws-token-do-not-leak"
             })

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert :ok = Task.await(client, 5_000)

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_auth_retry_stale_epoch"} = CodexPooler.JSON.decode!(frame)

    # The stale 401 never reached the provider: no OAuth request, and the
    # retry ran with the rotated token stored by the concurrent refresh.
    # The rejected upgrade never records a request row, so the sole entry is
    # the retried connection.
    requests = FakeUpstream.requests(upstream)
    refute Enum.any?(requests, &(&1.path == "/oauth/token"))

    assert [retried] = requests
    assert retried.method == "WEBSOCKET"
    assert Map.new(retried.headers)["authorization"] == "Bearer rotated-ws-token-do-not-leak"

    persisted = Repo.get!(UpstreamIdentity, setup.identity.id)
    assert CredentialFencing.credential_epoch(persisted) == original_epoch + 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "rotated-ws-token-do-not-leak"
  end

  for auth_code <- ["invalid_api_key", "invalid_authentication"] do
    @auth_code auth_code
    @tag :feature_websocket_terminal_auth_refresh
    test "websocket pre-visible terminal auth #{auth_code} refreshes once and retries the same assignment" do
      auth_code = @auth_code

      upstream =
        start_upstream(
          # Strict finite scenario: one terminal auth failure, exactly one
          # provider refresh, then one retry on a replacement connection.
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            strict_native_request(1, websocket_terminal_auth_failure(auth_code)),
            strict_oauth_refresh(
              FakeUpstream.json_response(%{"access_token" => "upstream-token-refreshed"}, 200)
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 2,
              json: [valid: true, equals: %{"type" => "response.create"}],
              headers: [required: %{"authorization" => "Bearer upstream-token-refreshed"}],
              respond:
                FakeUpstream.websocket_text_frames([
                  CodexPooler.JSON.encode!(websocket_auth_retry_success_payload(auth_code))
                ])
            )
          ])
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
      assert %{"id" => ^expected_response_id} = CodexPooler.JSON.decode!(frame)
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
      assert first_attempt.response_metadata["upstream_error_param"] == "reasoning.effort"

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
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  @tag :feature_websocket_terminal_auth_refresh_failures
  test "websocket terminal auth preserves original failure when refresh is already in progress" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: the terminal auth failure is held behind a
        # native barrier so the identity can be marked refreshing first; no
        # /oauth/token entry and no retry entry exist, so either request fails
        # the fixture as an unexpected extra request.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_terminal_then_close_barrier(
              %{
                "type" => "response.failed",
                "response" => %{
                  "id" => "resp_ws_auth_refresh_in_progress",
                  "error" => %{"code" => "invalid_api_key"},
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
                }
              },
              notify: self(),
              release_ref: release_ref
            )
          )
        ])
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

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, upstream_pid,
                    ^release_ref},
                   1_000

    metadata = active_token_refresh_metadata()

    assert {:ok, _identity} =
             IdentityLifecycle.update_upstream_identity(setup.identity, %{
               status: "refreshing",
               metadata: Map.put(setup.identity.metadata || %{}, "token_refresh", metadata)
             })

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert :ok = Task.await(task, 2_000)

    # The native barrier holds the post-terminal close as well; release it so
    # the fake connection can retire cleanly after the failure has been
    # observed.
    assert_receive {:fake_upstream_websocket_barrier, :before_close, ^upstream_pid, ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "invalid_api_key"}}
           } =
             CodexPooler.JSON.decode!(frame)

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
    assert :ok = FakeUpstream.verify!(upstream)
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
          # Strict finite scenario: one terminal auth failure and one failed
          # provider refresh; there is no retry entry, so a redispatch fails
          # the fixture as an unexpected extra request.
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            strict_native_request(1, websocket_terminal_auth_failure("invalid_authentication")),
            strict_oauth_refresh(
              FakeUpstream.json_response(@refresh_response_body, @refresh_response_status)
            )
          ])
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
             } = CodexPooler.JSON.decode!(frame)

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
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  @tag :feature_websocket_terminal_auth_refresh_failures
  test "websocket disconnect during terminal auth refresh drains the response task without DB noise" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: one terminal auth failure, one held provider
        # refresh, then exactly one retry drained after the client disconnect.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(1, websocket_terminal_auth_failure("invalid_api_key")),
          strict_oauth_refresh(
            FakeUpstream.barrier_json_response(
              %{"access_token" => "upstream-token-refreshed"},
              notify: self(),
              release_ref: release_ref
            )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(
                  websocket_auth_retry_success_payload("disconnect_refresh")
                )
              ])
          )
        ])
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
        assert :ok = Task.await(terminator, @connection_shutdown_timeout_ms)
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
    assert Repo.get!(CodexSession, state.codex_session.id).status == "active"
    assert request.response_status_code == 200
    assert turn.error_code == nil

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
    assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(frame)

    assert [first_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_terminal_failure"
    assert attempt.transport == "websocket"

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

  defp strict_native_response_payload(payload, connection_ordinal) when is_map(payload) do
    strict_native_request(
      connection_ordinal,
      FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(payload)])
    )
  end

  defp websocket_auth_retry_success_payload(marker) do
    %{
      "id" => "resp_ws_auth_retry_#{marker}",
      "object" => "response",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
    }
  end

  defp websocket_terminal_auth_failure(code) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "id" => "resp_ws_terminal_auth_#{code}",
          "error" => %{"code" => code, "param" => "reasoning.effort"},
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
        }
      })
    ])
  end

  defp strict_oauth_refresh(respond) do
    FakeUpstream.expect_request(method: "POST", path: "/oauth/token", respond: respond)
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
end
