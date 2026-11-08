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
      capture_public_endpoint_identity!: 1,
      assert_public_endpoint_identity_released!: 1,
      register_unboxed_pool_cleanup!: 1,
      start_public_endpoint_with_server!: 0,
      gateway_setup: 1,
      gateway_setup: 2,
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
  alias CodexPooler.Accounting.RequestLifecycle.WindowUsage
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Runtime.Finalization.SettlementRetry
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

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

  for fault <- [:rollback, :raised, :metadata, :transient_cleanup], route <- ["/backend-api/codex/responses", "/v1/responses"], stream? <- [false, true] do
    @tag :retry_accounting_failure
    @tag capture_log: false
    @tag fault: fault, route: route, stream?: stream?
    test "#{route} stream=#{stream?} retry accounting #{fault} releases the current request synchronously", %{fault: fault, route: route, stream?: stream?} do
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)
      Sandbox.mode(Repo, :auto)
      upstream = start_upstream(FakeUpstream.strict_sequence([expect_dispatch(@initial_token, unauthorized_response(401, "invalid_api_key", "synthetic auth refusal")), oauth_refresh(refreshed_token_response("synthetic-refreshed"))]))
      setup = gateway_setup(upstream)
      register_unboxed_pool_cleanup!(setup)
      store_refresh_token!(setup.identity, "synthetic-refresh")
      install_retry_accounting_fault!(setup, if(fault == :transient_cleanup, do: :raised, else: fault))
      cleanup_sequence = if fault == :transient_cleanup, do: install_transient_cleanup_fault!(setup)
      {server, port} = start_public_endpoint_with_server!()
      ownership = capture_public_endpoint_identity!(server)

      on_exit(fn ->
        monitor = Process.monitor(server)

        try do
          ThousandIsland.stop(server)
        catch
          :exit, _stopped -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 15_000
        assert_public_endpoint_identity_released!(ownership)
      end)

      {response, logs} = with_log(fn -> Req.post!("http://127.0.0.1:#{port}" <> route, headers: [{"authorization", setup.authorization}], json: Map.put(stream_payload(setup, "retry-accounting"), "stream", stream?), retry: false, receive_timeout: 15_000) end)
      [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
      attempts = Repo.all(from a in Attempt, where: a.request_id == ^request.id, order_by: a.attempt_number)
      entries = Repo.all(from l in LedgerEntry, where: l.request_id == ^request.id)
      observed = %{http_status: response.status, code: get_in(response.body, ["error", "code"]), request_status: request.status, completed: not is_nil(request.completed_at), attempt_statuses: Enum.map(attempts, & &1.status), releases: Enum.count(entries, &(&1.entry_kind == "release")), settlements: Enum.count(entries, &(&1.entry_kind == "settlement"))}
      assert observed == %{http_status: 500, code: "gateway_accounting_failed", request_status: "failed", completed: true, attempt_statuses: ["failed"], releases: 1, settlements: 1}
      reservation = Enum.find(entries, &(&1.entry_kind == "reservation"))
      release = Enum.find(entries, &(&1.entry_kind == "release"))
      assert reservation.request_count - release.request_count == 0
      assert (reservation.total_tokens || 0) - (release.total_tokens || 0) == 0
      assert Decimal.equal?(Decimal.sub(reservation.estimated_cost_micros, release.estimated_cost_micros), 0)
      usage = WindowUsage.window_usages(setup.api_key.id, test: DateTime.add(DateTime.utc_now(), -3_600, :second))
      assert usage.test.pending_total_tokens == 0
      assert logs =~ "gateway accounting finalization failed"

      if cleanup_sequence do
        assert Repo.query!("SELECT last_value FROM #{cleanup_sequence}").rows == [[2]]
        assert logs =~ "settlement completed after a transient database failure"
      end

      assert :ok = FakeUpstream.verify!(upstream)
      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [@endpoint_path, "/oauth/token"]
    end
  end

  for successor <- [:newer_attempt, :newer_generation, :newer_owner] do
    @tag :retry_accounting_authority
    @tag capture_log: false
    @tag successor: successor
    test "retry accounting cleanup preserves #{successor} authority", %{successor: successor} do
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)
      Sandbox.mode(Repo, :auto)
      upstream = start_upstream(FakeUpstream.strict_sequence([expect_dispatch(@initial_token, unauthorized_response(401, "invalid_api_key", "synthetic auth refusal")), oauth_refresh(refreshed_token_response("synthetic-refreshed"))]))
      setup = gateway_setup(upstream)
      register_unboxed_pool_cleanup!(setup)
      store_refresh_token!(setup.identity, "synthetic-refresh")
      snapshot = install_successor_fault!(setup, successor)
      port = retry_failure_listener!()
      {response, _logs} = with_log(fn -> Req.post!("http://127.0.0.1:#{port}" <> @endpoint_path, headers: [{"authorization", setup.authorization}, {"session-id", Ecto.UUID.generate()}], json: stream_payload(setup, "stale-retry"), retry: false) end)
      assert response.status == 500
      assert response.body["error"]["code"] == "gateway_accounting_failed"
      [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
      assert_successor_unchanged!(snapshot, setup, successor)

      if successor == :newer_owner do
        assert request.status == "failed"
        assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "release"), :count) == 1
      else
        assert request.status == "in_progress"
        assert is_nil(request.completed_at)
        assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind in ["release", "settlement"]), :count) == 0
      end

      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  @tag :retry_accounting_persistent
  @tag capture_log: false
  test "persistent database refusal preserves the primary accounting error without claiming cleanup" do
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    Sandbox.mode(Repo, :auto)
    CodexPooler.TestAppEnv.restore_on_exit(SettlementRetry)
    Application.put_env(:codex_pooler, SettlementRetry, window_ms: 0)
    upstream = start_upstream(FakeUpstream.strict_sequence([expect_dispatch(@initial_token, unauthorized_response(401, "invalid_api_key", "synthetic auth refusal")), oauth_refresh(refreshed_token_response("synthetic-refreshed"))]))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    store_refresh_token!(setup.identity, "synthetic-refresh")
    install_retry_accounting_fault!(setup, :raised)
    name = "persistent_retry_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON ledger_entries")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    Repo.query!("CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic database unavailable' USING ERRCODE = 'admin_shutdown'; END $$")
    Repo.query!("CREATE TRIGGER #{name} BEFORE INSERT ON ledger_entries FOR EACH ROW WHEN (NEW.pool_id = '#{setup.pool.id}'::uuid AND NEW.entry_kind IN ('settlement','release')) EXECUTE FUNCTION #{name}()")
    port = retry_failure_listener!()
    {response, logs} = with_log(fn -> Req.post!("http://127.0.0.1:#{port}" <> @endpoint_path, headers: [{"authorization", setup.authorization}], json: stream_payload(setup, "persistent-retry"), retry: false) end)
    assert response.status == 500
    assert response.body["error"]["code"] == "gateway_accounting_failed"
    [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == "in_progress"
    assert is_nil(request.completed_at)
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind in ["release", "settlement"]), :count) == 0
    assert logs =~ "settlement abandoned after transient database failures"
    assert logs =~ "fallback=execution_recovery"
    assert :ok = FakeUpstream.verify!(upstream)
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

  for code <- ~w(invalid_api_key invalid_authentication) do
    test "backend SSE upstream 403 #{code} refreshes and retries", %{conn: conn} do
      assert_credential_403_refresh(conn, unquote(code))
    end
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

  for status <- [401, 403], surface <- [:body, :header, :model_conflict], route <- [@endpoint_path, "/v1/responses"], stream? <- [false, true], mode <- ["full", "lite"] do
    @tag :runtime_auth_denial
    test "#{route} #{mode} stream=#{stream?} terminal #{status} #{surface} denial skips refresh and replay", %{conn: conn} do
      assert_runtime_auth_denial(conn, unquote(status), unquote(surface), unquote(route), unquote(stream?), unquote(mode))
    end
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

  test "a terminal runtime denial after successful refresh stops without failing over", %{conn: conn} do
    refreshed_token = "synthetic-runtime-refreshed-access"

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial — a repairable 401 followed by a terminal runtime denial.
        FakeUpstream.strict_sequence([
          expect_dispatch(@initial_token, unauthorized_response(401, "invalid_api_key", "synthetic credential refusal")),
          oauth_refresh(refreshed_token_response(refreshed_token)),
          expect_dispatch(refreshed_token, unauthorized_response(401, "runtime_instance_paused", "synthetic runtime refusal"))
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "synthetic-runtime-refresh")
    fallback = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_fail_over"}))
    {setup, second} = second_candidate!(setup, fallback)
    conn = conn |> put_req_header("x-request-id", prefer_first_candidate(setup, second)) |> auth(setup) |> post(@endpoint_path, stream_payload(setup, "runtime after refresh"))

    assert conn.status == 401
    assert :ok = FakeUpstream.verify!(upstream)
    assert length(FakeUpstream.requests(upstream)) == 3
    assert FakeUpstream.count(fallback) == 0
    assert [first, terminal] = Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))
    assert first.status == "retryable_failed"
    assert first.network_error_code == "upstream_unauthorized"
    assert terminal.status == "failed"
    assert terminal.network_error_code == "upstream_status"
    assert terminal.response_metadata["rejection_error_code"] == "runtime_instance_paused"
    assert terminal.upstream_identity_id == setup.identity.id
    request = Repo.get!(Request, terminal.request_id)
    assert request.status == "failed"
    assert request.retry_count == 1
    assert request.last_error_code == "upstream_status"
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"
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

  defp install_transient_cleanup_fault!(setup) do
    CodexPooler.TestAppEnv.restore_on_exit(SettlementRetry)
    Application.put_env(:codex_pooler, SettlementRetry, initial_backoff_ms: 1, max_backoff_ms: 1)
    name = "transient_retry_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON ledger_entries")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
      Repo.query!("DROP SEQUENCE IF EXISTS #{name}_passes")
    end)

    Repo.query!("CREATE SEQUENCE #{name}_passes")
    Repo.query!("CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF nextval('#{name}_passes') = 1 THEN RAISE EXCEPTION 'synthetic transient settlement refusal' USING ERRCODE = 'query_canceled'; END IF; RETURN NEW; END $$")
    Repo.query!("CREATE TRIGGER #{name} BEFORE INSERT ON ledger_entries FOR EACH ROW WHEN (NEW.pool_id = '#{setup.pool.id}'::uuid AND NEW.entry_kind = 'settlement') EXECUTE FUNCTION #{name}()")
    name <> "_passes"
  end

  defp retry_failure_listener! do
    {server, port} = start_public_endpoint_with_server!()
    ownership = capture_public_endpoint_identity!(server)

    on_exit(fn ->
      monitor = Process.monitor(server)

      try do
        ThousandIsland.stop(server)
      catch
        :exit, _stopped -> :ok
      end

      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 15_000
      assert_public_endpoint_identity_released!(ownership)
    end)

    port
  end

  defp install_successor_fault!(setup, successor) do
    name = "retry_successor_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON requests")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
      Repo.query!("DROP TABLE IF EXISTS #{name}")
    end)

    {mutation, snapshot} =
      case successor do
        :newer_attempt ->
          {"INSERT INTO attempts SELECT (jsonb_populate_record(NULL::attempts, to_jsonb(a) || jsonb_build_object('id','#{Ecto.UUID.generate()}','attempt_number',2,'status','in_progress','completed_at',NULL))).* FROM attempts a WHERE a.request_id=NEW.id AND a.attempt_number=1;", "SELECT 'request', md5(row_to_json(r)::text) FROM requests r WHERE r.id=NEW.id UNION ALL SELECT 'attempt', md5(row_to_json(a)::text) FROM attempts a WHERE a.request_id=NEW.id"}

        :newer_generation ->
          {"UPDATE attempts SET replay_generation=1 WHERE request_id=NEW.id;", "SELECT 'request', md5(row_to_json(r)::text) FROM requests r WHERE r.id=NEW.id UNION ALL SELECT 'attempt', md5(row_to_json(a)::text) FROM attempts a WHERE a.request_id=NEW.id"}

        :newer_owner ->
          token = Ecto.UUID.generate()
          {"UPDATE codex_sessions SET owner_lease_token='#{token}'::uuid WHERE pool_id=NEW.pool_id; UPDATE bridge_owner_leases SET lease_token='#{token}'::uuid WHERE pool_id=NEW.pool_id;", "SELECT 'session', md5(row_to_json(s)::text) FROM codex_sessions s WHERE s.pool_id=NEW.pool_id UNION ALL SELECT 'lease', md5(row_to_json(l)::text) FROM bridge_owner_leases l WHERE l.pool_id=NEW.pool_id UNION ALL SELECT 'alias',md5(row_to_json(a)::text) FROM bridge_session_aliases a WHERE a.pool_id=NEW.pool_id"}
      end

    Repo.query!("CREATE TABLE #{name} (kind text, fingerprint text)")
    Repo.query!("CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN UPDATE upstream_identities SET metadata=metadata || jsonb_build_object('permanent_deletion_requested_at','2026-10-09T00:00:00Z') WHERE id='#{setup.identity.id}'::uuid; #{mutation} INSERT INTO #{name} #{snapshot}; RETURN NULL; END $$")
    Repo.query!("CREATE TRIGGER #{name} AFTER UPDATE OF request_metadata ON requests FOR EACH ROW WHEN (NEW.pool_id='#{setup.pool.id}'::uuid AND NEW.request_metadata ? 'auth_refresh' AND NOT OLD.request_metadata ? 'auth_refresh') EXECUTE FUNCTION #{name}()")
    name
  end

  defp assert_successor_unchanged!(name, setup, successor) do
    expected = Repo.query!("SELECT kind,fingerprint FROM #{name} ORDER BY kind,fingerprint").rows
    assert expected != []

    actual =
      if successor == :newer_owner do
        counts = Enum.frequencies_by(expected, &hd/1)
        assert counts["session"] == 1
        assert counts["lease"] == 1
        Repo.query!("SELECT * FROM (SELECT 'session' AS kind,md5(row_to_json(s)::text) AS fingerprint FROM codex_sessions s WHERE s.pool_id='#{setup.pool.id}'::uuid UNION ALL SELECT 'lease',md5(row_to_json(l)::text) FROM bridge_owner_leases l WHERE l.pool_id='#{setup.pool.id}'::uuid UNION ALL SELECT 'alias',md5(row_to_json(a)::text) FROM bridge_session_aliases a WHERE a.pool_id='#{setup.pool.id}'::uuid) x ORDER BY kind,fingerprint").rows
      else
        Repo.query!("SELECT * FROM (SELECT 'request' AS kind,md5(row_to_json(r)::text) AS fingerprint FROM requests r WHERE r.pool_id='#{setup.pool.id}'::uuid UNION ALL SELECT 'attempt',md5(row_to_json(a)::text) FROM attempts a JOIN requests r ON r.id=a.request_id WHERE r.pool_id='#{setup.pool.id}'::uuid) x ORDER BY kind,fingerprint").rows
      end

    assert actual == expected
  end

  defp install_retry_accounting_fault!(setup, fault) do
    name = "retry_accounting_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    table = if fault in [:rollback, :metadata], do: "requests", else: "attempts"

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    {body, condition, timing} =
      case fault do
        :rollback ->
          {"UPDATE upstream_identities SET metadata = metadata || jsonb_build_object('permanent_deletion_requested_at','2026-10-09T00:00:00Z') WHERE id = '#{setup.identity.id}'::uuid; RETURN NULL;", "NEW.pool_id = '#{setup.pool.id}'::uuid AND NEW.request_metadata ? 'auth_refresh'", "AFTER UPDATE OF request_metadata"}

        :metadata ->
          {"RAISE EXCEPTION 'synthetic metadata merge failure' USING ERRCODE = 'check_violation';", "NEW.pool_id = '#{setup.pool.id}'::uuid AND NEW.request_metadata ? 'auth_refresh'", "BEFORE UPDATE OF request_metadata"}

        :raised ->
          {"RAISE EXCEPTION 'synthetic retry insert failure' USING ERRCODE = 'check_violation';", "NEW.attempt_number = 2 AND NEW.pool_upstream_assignment_id = '#{setup.assignment.id}'::uuid", "BEFORE INSERT"}
      end

    Repo.query!("CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN #{body} END $$")
    Repo.query!("CREATE TRIGGER #{name} #{timing} ON #{table} FOR EACH ROW WHEN (#{condition}) EXECUTE FUNCTION #{name}()")
  end

  defp assert_credential_403_refresh(conn, code) do
    refreshed_token = "refreshed-access-403-#{System.unique_integer([:positive])}-do-not-leak"

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial — ordinary credential denials remain repairable.
        FakeUpstream.strict_sequence([
          expect_dispatch(@initial_token, unauthorized_response(403, code, "provider-403-sentinel")),
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

  defp assert_runtime_auth_denial(conn, status, surface, route, stream?, mode) do
    terminal_code = "runtime_instance_revoked"

    body_code =
      case surface do
        :body -> terminal_code
        :header -> "invalid_api_key"
        :model_conflict -> "model_not_found"
      end

    error = %{"error" => %{"code" => body_code, "type" => "invalid_request_error", "message" => "synthetic runtime refusal"}}
    identity_header = Base.encode64(CodexPooler.JSON.encode!(%{"error" => %{"code" => terminal_code}}))
    headers = if surface == :body, do: [], else: [{"x-error-json", identity_header}]

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial — pinned Codex denial codes over real HTTP; no refresh or replay is scripted.
        FakeUpstream.strict_sequence([expect_dispatch(@initial_token, FakeUpstream.json_response_with_headers(error, headers, status))])
      )

    setup = gateway_setup(upstream, model_metadata: %{"use_responses_lite" => mode == "lite"})
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    store_refresh_token!(setup.identity, "synthetic-runtime-denial-refresh")
    fallback = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_fail_over"}))
    {setup, second} = second_candidate!(setup, fallback)

    conn = conn |> put_req_header("x-request-id", prefer_first_candidate(setup, second)) |> auth(setup) |> post(route, stream_payload(setup, "terminal runtime denial") |> Map.put("stream", stream?))
    expected_status = if route == @endpoint_path and status == 403, do: 400, else: status
    assert conn.status == expected_status
    assert_runtime_denial_projection(conn, route, status, stream?, mode, body_code)
    assert get_resp_header(conn, "x-error-json") == []
    assert :ok = FakeUpstream.verify!(upstream)
    assert [%{path: @endpoint_path}] = FakeUpstream.requests(upstream)
    assert FakeUpstream.count(fallback) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == status
    assert request.retry_count == 0
    assert request.last_error_code == "upstream_status"
    refute Map.has_key?(request.request_metadata || %{}, "auth_refresh")

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == status
    assert attempt.upstream_identity_id == setup.identity.id
    assert attempt.response_metadata["rejection_error_code"] == body_code
    assert attempt.response_metadata["routing"]["model_serving_mode"] == mode
    refute Map.has_key?(attempt.response_metadata, "auth_refresh_trigger")
    refute inspect({request.request_metadata, attempt.response_metadata}) =~ identity_header
  end

  # Native Lite streaming 401 keeps the existing drained-body result; this
  # classifier does not add a new renderer or project the identity header.
  defp assert_runtime_denial_projection(conn, @endpoint_path, 401, true, "lite", _body_code) do
    assert conn.resp_body == ""
  end

  defp assert_runtime_denial_projection(conn, route, status, _stream?, mode, body_code) do
    assert %{"error" => error} = json_response(conn, conn.status)

    {expected_code, expected_type} =
      case {route, mode} do
        {"/v1/responses", "lite"} -> {"upstream_status", "server_error"}
        _other -> {body_code, "invalid_request_error"}
      end

    assert error["code"] == expected_code
    assert error["type"] == expected_type

    if route == "/v1/responses" or mode == "full" or status == 403 do
      refute error["message"] == "synthetic runtime refusal"
    end
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
