defmodule CodexPoolerWeb.Runtime.BackendCodexHttpAuthRefreshTest do
  alias CodexPooler.Access
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Upstreams.Auth.{AccessTokenExpiry, TokenRefreshMetadata}

  use CodexPoolerWeb.ConnCase, async: false
  use Oban.Testing, repo: CodexPooler.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      gateway_upstream: 4,
      native_text_input: 1,
      prime_routing_quota!: 1,
      rendezvous_score: 2,
      put_model_source_assignments!: 2,
      seed_preferring_assignment: 2,
      start_upstream: 1,
      stream_success_sse: 0,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @endpoint_path "/backend-api/codex/responses"
  @initial_token "upstream-token"
  @trigger_kind "http_upstream_auth_failure"

  setup do
    # The refresh receipt is an info line; the test logger level is :warning.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "scheduled transient refresh preserves a hard-pinned continuation", %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          oauth_refresh(FakeUpstream.json_response(%{"error" => "temporary"}, 503)),
          expect_dispatch(@initial_token, stream_success_sse())
        ])
      )

    setup = gateway_setup(upstream)
    fallback = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_route"}))
    {setup, _second} = second_candidate!(setup, fallback)
    store_refresh_token!(setup.identity, "synthetic-proactive-refresh-token")

    expiry =
      AccessTokenExpiry.known(
        DateTime.add(DateTime.utc_now(), 3600),
        :explicit
      )

    metadata =
      TokenRefreshMetadata.build_imported(
        setup.identity.metadata,
        expiry,
        1,
        "import",
        DateTime.utc_now()
      )

    identity = setup.identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

    {:ok, runtime_auth} =
      Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Websocket.start_codex_session(runtime_auth, %{
        session_header: Ecto.UUID.generate()
      })

    session =
      session
      |> Ecto.Changeset.change(pool_upstream_assignment_id: setup.assignment.id)
      |> Repo.update!()

    previous = "resp_proactive_anchor"

    assert :ok =
             Websocket.register_codex_session_continuity(
               session,
               %{},
               CodexPooler.JSON.encode!(%{"id" => previous})
             )

    assert {:error, _} =
             perform_job(CodexPooler.Jobs.TokenRefreshWorker, %{
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "scheduled"
             })

    response =
      conn
      |> auth(setup)
      |> post(
        @endpoint_path,
        Map.put(stream_payload(setup, "continuation"), "previous_response_id", previous)
      )

    assert response.status == 200, inspect(response.resp_body)
    assert response.resp_body =~ "response.completed"
    assert :ok = FakeUpstream.verify!(upstream)
    assert FakeUpstream.requests(fallback) == []
  end

  for mode <- [:native, :v1, :failover] do
    @tag follower_mode: mode
    test "concurrent 401 #{mode} follower leaves the leader identity and reconciliation untouched",
         %{
           conn: conn,
           follower_mode: mode
         } do
      ref = make_ref()
      token = "synthetic-concurrent-refreshed"

      upstream =
        start_upstream(
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            expect_dispatch(
              @initial_token,
              unauthorized_response(401, "invalid_api_key", "synthetic")
            ),
            oauth_refresh(
              FakeUpstream.barrier_json_response(%{"access_token" => token, "expires_in" => 3600},
                notify: self(),
                release_ref: ref
              )
            ),
            expect_dispatch(
              @initial_token,
              unauthorized_response(401, "invalid_api_key", "synthetic")
            ),
            expect_dispatch(token, stream_success_sse())
          ])
        )

      setup = gateway_setup(upstream)
      store_refresh_token!(setup.identity, "synthetic-concurrent-refresh")

      {setup, conn, fallback} =
        if mode == :failover do
          fallback = start_upstream(stream_success_sse())
          {setup, second} = second_candidate!(setup, fallback)

          {setup, put_req_header(conn, "x-request-id", prefer_first_candidate(setup, second)), fallback}
        else
          {setup, conn, nil}
        end

      endpoint = if mode == :v1, do: "/v1/responses", else: @endpoint_path

      leader =
        Task.async(fn ->
          conn |> auth(setup) |> post(endpoint, stream_payload(setup, "leader"))
        end)

      on_exit(fn -> if Process.alive?(leader.pid), do: Task.shutdown(leader, :brutal_kill) end)
      assert_receive {:fake_upstream_timeout_barrier, :before_headers, provider, ^ref}, 15_000
      on_exit(fn -> send(provider, {:fake_upstream_release_timeout, ref}) end)
      before = Repo.reload!(setup.identity)
      jobs_before = reconciliation_jobs(setup.identity.id)
      follower = conn |> auth(setup) |> post(endpoint, stream_payload(setup, "follower"))
      assert follower.status == if(mode == :failover, do: 200, else: 503)
      assert Repo.reload!(setup.identity).status == before.status
      assert reconciliation_jobs(setup.identity.id) == jobs_before
      assert Enum.count(FakeUpstream.requests(upstream), &(&1.path == "/oauth/token")) == 1
      send(provider, {:fake_upstream_release_timeout, ref})
      assert Task.await(leader, 15_000).status == 200
      assert Repo.reload!(setup.identity).status == "active"
      assert :ok = FakeUpstream.verify!(upstream)
      if fallback, do: assert(length(FakeUpstream.requests(fallback)) == 1)
    end
  end

  test "backend SSE upstream 401 refreshes the access token once and retries the same identity",
       %{conn: conn} do
    refreshed_token = "refreshed-access-#{System.unique_integer([:positive])}-do-not-leak"
    refresh_token = "refresh-token-http-401-do-not-leak"
    provider_message = "provider-401-message-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", provider_message)
          ),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(refreshed_token, stream_success_sse())
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, refresh_token)

    {conn, logs} =
      with_log([level: :info], fn ->
        conn |> auth(setup) |> post(@endpoint_path, stream_payload(setup, "401 refresh"))
      end)

    assert conn.status == 200
    assert conn.resp_body =~ "resp_stream_retry_success"
    refute conn.resp_body =~ provider_message
    refute conn.resp_body =~ refreshed_token

    assert :ok = FakeUpstream.verify!(upstream)
    assert [_first, refresh_request, _retried] = FakeUpstream.requests(upstream)
    assert refresh_request.path == "/oauth/token"

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"
    assert first_attempt.upstream_status_code == 401
    assert first_attempt.upstream_identity_id == setup.identity.id
    assert first_attempt.response_metadata["auth_refresh_trigger"] == @trigger_kind

    assert second_attempt.status == "succeeded"
    assert second_attempt.upstream_identity_id == setup.identity.id
    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    assert request.request_metadata["auth_refresh"] == %{
             "status" => "succeeded",
             "trigger_kind" => @trigger_kind
           }

    assert logs =~
             "upstream auth refresh transport=http outcome=succeeded " <>
               "request_id=#{request.id} identity=#{setup.identity.id}"

    assert_no_leak!(
      [
        request.request_metadata,
        first_attempt.response_metadata,
        second_attempt.response_metadata
      ],
      logs,
      [refreshed_token, refresh_token, provider_message, setup.authorization]
    )
  end

  test "backend SSE upstream 403 invalid_authentication refreshes and retries", %{conn: conn} do
    refreshed_token = "refreshed-access-403-#{System.unique_integer([:positive])}-do-not-leak"

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(403, "invalid_authentication", "provider-403-sentinel")
          ),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(refreshed_token, stream_success_sse())
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "refresh-token-http-403-do-not-leak")

    conn = conn |> auth(setup) |> post(@endpoint_path, stream_payload(setup, "403 refresh"))

    assert conn.status == 200
    assert conn.resp_body =~ "resp_stream_retry_success"
    assert :ok = FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"
  end

  test "backend SSE upstream 403 without an auth code does not refresh", %{conn: conn} do
    # Strict: a single non-auth 403 and no /oauth/token entry, so a refresh
    # would fail the fixture as an unexpected extra request.
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(403, "insufficient_quota", "provider-quota-sentinel")
          )
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "refresh-token-http-quota-do-not-leak")

    conn = conn |> auth(setup) |> post(@endpoint_path, stream_payload(setup, "403 quota"))

    # A final 403 that demotes nothing answers the Pooler-authored 400 naming
    # it (findings#254 row 254-80).
    assert conn.status == 400
    assert %{"error" => %{"code" => "insufficient_quota", "message" => "upstream rejected the request (insufficient_quota); upstream status 403"}} = json_response(conn, 400)
    refute conn.resp_body =~ "provider-quota-sentinel"
    assert :ok = FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    refute Map.has_key?(request.request_metadata || %{}, "auth_refresh")
  end

  test "refresh that is not retryable fails over to the next candidate", %{conn: conn} do
    refresh_token = "refresh-token-http-reauth-do-not-leak"

    first_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", "first-401")
          ),
          oauth_refresh(reauth_required_response())
        ])
      )

    second_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch("upstream-token-second", stream_success_sse())
        ])
      )

    setup = gateway_setup(first_upstream)
    store_refresh_token!(setup.identity, refresh_token)
    {setup, second} = second_candidate!(setup, second_upstream)

    {conn, logs} =
      with_log([level: :info], fn ->
        conn
        |> put_req_header("x-request-id", prefer_first_candidate(setup, second))
        |> auth(setup)
        |> post(@endpoint_path, stream_payload(setup, "failover"))
      end)

    assert conn.status == 200
    assert conn.resp_body =~ "resp_stream_retry_success"
    assert :ok = FakeUpstream.verify!(first_upstream)
    assert :ok = FakeUpstream.verify!(second_upstream)

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"
    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "succeeded"
    assert second_attempt.pool_upstream_assignment_id == second.assignment.id

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.request_metadata["auth_refresh"]["status"] == "reauth_required"
    assert request.request_metadata["auth_refresh"]["trigger_kind"] == @trigger_kind

    assert Repo.get!(UpstreamIdentity, setup.identity.id).status == "reauth_required"
    assert [_job] = reconciliation_jobs(setup.identity.id)

    assert logs =~
             "upstream auth refresh transport=http outcome=reauth_required " <>
               "request_id=#{request.id} identity=#{setup.identity.id}"

    assert_no_leak!([request.request_metadata, first_attempt.response_metadata], logs, [
      refresh_token,
      "first-401",
      setup.authorization
    ])
  end

  test "every candidate failing auth finalizes 503 upstream_unauthorized and reconciles once",
       %{conn: conn} do
    first_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", "first-401")
          ),
          oauth_refresh(reauth_required_response())
        ])
      )

    second_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            "upstream-token-second",
            unauthorized_response(401, "invalid_api_key", "second-401")
          ),
          oauth_refresh(reauth_required_response())
        ])
      )

    setup = gateway_setup(first_upstream)
    store_refresh_token!(setup.identity, "refresh-token-http-first-do-not-leak")
    {setup, second} = second_candidate!(setup, second_upstream)
    store_refresh_token!(second.identity, "refresh-token-http-second-do-not-leak")

    conn =
      conn
      |> put_req_header("x-request-id", prefer_first_candidate(setup, second))
      |> auth(setup)
      |> post(@endpoint_path, stream_payload(setup, "exhausted"))

    assert %{"error" => %{"code" => "upstream_unauthorized"} = error} = json_response(conn, 503)
    refute error["message"] =~ "first-401"
    refute error["message"] =~ "second-401"
    assert :ok = FakeUpstream.verify!(first_upstream)
    assert :ok = FakeUpstream.verify!(second_upstream)

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"
    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "failed"
    assert second_attempt.network_error_code == "upstream_unauthorized"
    assert second_attempt.pool_upstream_assignment_id == second.assignment.id

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 503
    assert request.last_error_code == "upstream_unauthorized"

    assert [%{denial_reason: "upstream_unauthorized", response_status_code: 503}] =
             RequestLogs.list(setup.pool.id, limit: 10).items

    assert [_first_job] = reconciliation_jobs(setup.identity.id)
    assert [_second_job] = reconciliation_jobs(second.identity.id)
  end

  test "a second 401 after a successful refresh does not refresh again", %{conn: conn} do
    refreshed_token = "refreshed-access-loop-#{System.unique_integer([:positive])}-do-not-leak"

    # Strict: exactly one /oauth/token entry; a second refresh would fail the
    # fixture as an unexpected extra request.
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", "loop-1")
          ),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(
            refreshed_token,
            unauthorized_response(401, "invalid_api_key", "loop-2")
          )
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "refresh-token-http-loop-do-not-leak")

    conn = conn |> auth(setup) |> post(@endpoint_path, stream_payload(setup, "loop"))

    assert %{"error" => %{"code" => "upstream_unauthorized"}} = json_response(conn, 503)
    assert :ok = FakeUpstream.verify!(upstream)
    assert length(FakeUpstream.requests(upstream)) == 3

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"
    assert second_attempt.status == "failed"
    assert second_attempt.network_error_code == "upstream_unauthorized"
    assert second_attempt.upstream_identity_id == setup.identity.id

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 503
    assert request.last_error_code == "upstream_unauthorized"
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"
    assert [_job] = reconciliation_jobs(setup.identity.id)
  end

  test "a refreshed identity with a pre-visible SSE failure still tries the next candidate", %{
    conn: conn
  } do
    refreshed_token = "synthetic-refreshed-access"
    # provenance: synthetic_adversarial — OAuth retry and first-event failover compose.
    first_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", "synthetic auth failure")
          ),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(refreshed_token, retryable_sse_failure())
        ])
      )

    second_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch("upstream-token-second", stream_success_sse())
        ])
      )

    setup = gateway_setup(first_upstream)
    store_refresh_token!(setup.identity, "synthetic-refresh-token")
    {setup, second} = second_candidate!(setup, second_upstream)

    conn =
      conn
      |> put_req_header("x-request-id", prefer_first_candidate(setup, second))
      |> auth(setup)
      |> post(@endpoint_path, stream_payload(setup, "refresh then SSE failover"))

    assert conn.status == 200
    assert FakeUpstream.count(second_upstream) == 1
    assert conn.resp_body =~ "resp_stream_retry_success"
    assert :ok = FakeUpstream.verify!(first_upstream)
    assert :ok = FakeUpstream.verify!(second_upstream)

    assert [first, refreshed, fallback] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert Enum.map([first, refreshed, fallback], & &1.status) == [
             "retryable_failed",
             "retryable_failed",
             "succeeded"
           ]

    assert refreshed.upstream_identity_id == setup.identity.id
    assert fallback.upstream_identity_id == second.identity.id
    assert Repo.get!(Request, fallback.request_id).retry_count == 2
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert_retry_ledger!(request)
  end

  test "each candidate can refresh once while retry accounting includes every attempt", %{
    conn: conn
  } do
    refreshed_token = "synthetic-refreshed-access"
    # provenance: synthetic_adversarial — OAuth retry and first-event failover compose.
    first_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", "synthetic auth failure")
          ),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(refreshed_token, retryable_sse_failure())
        ])
      )

    second_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            "upstream-token-second",
            unauthorized_response(401, "invalid_api_key", "synthetic second auth")
          ),
          oauth_refresh(refreshed_token_response("synthetic-second-refreshed")),
          expect_dispatch("synthetic-second-refreshed", stream_success_sse())
        ])
      )

    setup = gateway_setup(first_upstream)
    store_refresh_token!(setup.identity, "synthetic-refresh-token")
    {setup, second} = second_candidate!(setup, second_upstream)

    store_refresh_token!(second.identity, "synthetic-second-refresh-token")

    conn =
      conn
      |> put_req_header("x-request-id", prefer_first_candidate(setup, second))
      |> auth(setup)
      |> post(@endpoint_path, stream_payload(setup, "refresh then SSE failover"))

    assert conn.status == 200
    assert FakeUpstream.count(second_upstream) == 3
    assert conn.resp_body =~ "resp_stream_retry_success"
    assert :ok = FakeUpstream.verify!(first_upstream)
    assert :ok = FakeUpstream.verify!(second_upstream)

    assert [first, refreshed, fallback, final] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert Enum.map([first, refreshed, fallback, final], & &1.status) == [
             "retryable_failed",
             "retryable_failed",
             "retryable_failed",
             "succeeded"
           ]

    assert refreshed.upstream_identity_id == setup.identity.id
    assert fallback.upstream_identity_id == second.identity.id
    assert Repo.get!(Request, fallback.request_id).retry_count == 3
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert_retry_ledger!(request)
  end

  test "refresh followed by two pre-visible failures visits all three candidates", %{
    conn: conn
  } do
    refreshed_token = "synthetic-refreshed-access"
    # provenance: synthetic_adversarial — OAuth retry and first-event failover compose.
    first_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(
            @initial_token,
            unauthorized_response(401, "invalid_api_key", "synthetic auth failure")
          ),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(refreshed_token, retryable_sse_failure())
        ])
      )

    second_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch("upstream-token-second", retryable_sse_failure())
        ])
      )

    setup = gateway_setup(first_upstream)
    store_refresh_token!(setup.identity, "synthetic-refresh-token")
    {setup, second} = second_candidate!(setup, second_upstream)

    third_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch("upstream-token-third", stream_success_sse())
        ])
      )

    third = gateway_upstream(setup.pool, third_upstream, "upstream-token-third", compact?: false)
    prime_routing_quota!(third.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 3)

    setup = %{
      setup
      | model:
          put_model_source_assignments!(setup.model, [
            setup.assignment,
            second.assignment,
            third.assignment
          ])
    }

    assignments = [setup.assignment.id, second.assignment.id, third.assignment.id]

    seed =
      Enum.find_value(1..500, fn index ->
        seed = "synthetic-three-candidate-#{index}"

        if Enum.sort_by(
             assignments,
             &rendezvous_score(seed, &1),
             :desc
           ) == assignments, do: seed
      end)

    assert is_binary(seed)

    conn =
      conn
      |> put_req_header("x-request-id", seed)
      |> auth(setup)
      |> post(@endpoint_path, stream_payload(setup, "refresh then SSE failover"))

    assert conn.status == 200
    assert FakeUpstream.count(second_upstream) == 1
    assert conn.resp_body =~ "resp_stream_retry_success"
    assert :ok = FakeUpstream.verify!(first_upstream)
    assert :ok = FakeUpstream.verify!(second_upstream)
    assert :ok = FakeUpstream.verify!(third_upstream)

    assert [first, refreshed, fallback, final] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert Enum.map([first, refreshed, fallback, final], & &1.status) == [
             "retryable_failed",
             "retryable_failed",
             "retryable_failed",
             "succeeded"
           ]

    assert refreshed.upstream_identity_id == setup.identity.id
    assert fallback.upstream_identity_id == second.identity.id
    assert final.upstream_identity_id == third.identity.id
    assert Repo.get!(Request, fallback.request_id).retry_count == 3
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert_retry_ledger!(request)
  end

  defp assert_retry_ledger!(request) do
    kinds =
      Repo.all(
        from(entry in LedgerEntry,
          where: entry.request_id == ^request.id,
          select: entry.entry_kind
        )
      )

    assert Enum.frequencies(kinds) == %{"reservation" => 1, "release" => 1, "settlement" => 1}
  end

  defp retryable_sse_failure do
    {:sse,
     [
       "event: response.failed\ndata: " <>
         CodexPooler.JSON.encode!(%{
           "type" => "response.failed",
           "response" => %{
             "status" => "failed",
             "error" => %{"code" => "server_error", "message" => "synthetic failure"}
           }
         }) <> "\n\n"
     ]}
  end

  defp unauthorized_response(status, code, message) do
    FakeUpstream.json_response(
      %{"error" => %{"code" => code, "message" => message, "type" => "invalid_request_error"}},
      status
    )
  end

  defp refreshed_token_response(token),
    do: FakeUpstream.json_response(%{"access_token" => token}, 200)

  defp reauth_required_response,
    do: FakeUpstream.json_response(%{"error" => "invalid_grant"}, 400)

  defp oauth_refresh(respond),
    do: FakeUpstream.expect_request(method: "POST", path: "/oauth/token", respond: respond)

  defp expect_dispatch(token, respond) do
    FakeUpstream.expect_request(
      method: "POST",
      path: @endpoint_path,
      headers: [required: %{"authorization" => "Bearer #{token}"}],
      respond: respond
    )
  end

  defp stream_payload(setup, marker) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("http auth refresh fixture #{marker}"),
      "stream" => true
    }
  end

  defp store_refresh_token!(identity, plaintext) do
    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "refresh_token",
               plaintext: plaintext
             })
  end

  defp second_candidate!(setup, second_upstream) do
    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)
    model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
    {%{setup | model: model}, second}
  end

  defp prefer_first_candidate(setup, second) do
    seed_preferring_assignment([setup.assignment.id, second.assignment.id], setup.assignment.id)
  end

  defp reconciliation_jobs(identity_id) do
    [worker: AccountReconciliationWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["upstream_identity_id"] == identity_id))
  end

  defp assert_no_leak!(durable, logs, forbidden_values) do
    durable_text = inspect(durable)

    for value <- forbidden_values do
      refute durable_text =~ value
      refute logs =~ value
    end
  end
end
