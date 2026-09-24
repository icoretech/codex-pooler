defmodule CodexPoolerWeb.Runtime.BackendCodexHTTPOwnerLeaseTest do
  use CodexPoolerWeb.ConnCase, async: false

  defmodule CancellingAdapter do
    @behaviour Plug.Conn.Adapter

    def send_resp(state, status, headers, body),
      do: wrap_reply(state, delegate(state, :send_resp, [status, headers, body]))

    def send_file(state, status, headers, path, offset, length),
      do: wrap_reply(state, delegate(state, :send_file, [status, headers, path, offset, length]))

    def send_chunked(%{notify: notify} = state, status, headers) do
      case delegate(state, :send_chunked, [status, headers]) do
        {:ok, body, delegate_state} ->
          send(notify, {:downstream_stream_started, self()})
          {:ok, body, %{state | delegate_state: delegate_state}}

        error ->
          error
      end
    end

    def chunk(%{notify: notify}, _body) do
      send(notify, {:downstream_stream_cancelled, self()})
      {:error, :closed}
    end

    def read_req_body(state, opts) do
      case delegate(state, :read_req_body, [opts]) do
        {status, body, delegate_state} when status in [:ok, :more] ->
          {status, body, %{state | delegate_state: delegate_state}}
      end
    end

    def inform(state, status, headers), do: delegate(state, :inform, [status, headers])
    def upgrade(state, protocol, opts), do: delegate(state, :upgrade, [protocol, opts])
    def push(state, path, headers), do: delegate(state, :push, [path, headers])
    def get_peer_data(state), do: delegate(state, :get_peer_data, [])
    def get_sock_data(state), do: delegate(state, :get_sock_data, [])
    def get_ssl_data(state), do: delegate(state, :get_ssl_data, [])
    def get_http_protocol(state), do: delegate(state, :get_http_protocol, [])

    defp delegate(%{delegate: adapter, delegate_state: delegate_state}, operation, args),
      do: apply(adapter, operation, [delegate_state | args])

    defp wrap_reply(state, {:ok, body, delegate_state}),
      do: {:ok, body, %{state | delegate_state: delegate_state}}
  end

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import Ecto.Query
  import ExUnit.CaptureLog

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn
  }

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.SessionContinuity, as: RoutingContinuity
  alias CodexPooler.Gateway.Runtime.{Service, SessionLeaseHeartbeat}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Repo
  alias CodexPoolerWeb.GatewayControllerHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000
  # Renewal tests watch the lease outlive its initial deadline, so the ttl must be
  # short, and a renewal delayed by N=4 scheduling must still land before the
  # previous deadline. Renewals run every ttl / 3 (staggered to 80-100 %), so a
  # 3 s ttl tolerates a 2 s delay where a 1 s ttl tolerated about 0.7 s.
  @owner_ttl_seconds 3
  # Tests whose claim is one stop trigger (caller death, downstream cancellation)
  # or a follow-up after the heartbeat stopped use a ttl whose first renewal
  # lands after the test and whose lease outlives it, so neither a late renewal
  # nor a lease expiry can decide the outcome; with a 1 s ttl either could stop
  # the heartbeat before its monitor or replace the session under the follow-up.
  @stable_owner_ttl_seconds 30
  # Tests that need the short heartbeat ttl acquire the lease with the stable
  # ttl and let only the heartbeat renew with the short one. With one short ttl
  # for both, the lease had to survive the whole pre-dispatch window between
  # continuity's acquisition and the heartbeat's synchronous renewal (10-30 ms
  # measured unloaded). Under N=4 load that window once exceeded 3 s, the
  # synchronous renewal found the lease expired, and the gateway answered its
  # designed pre-dispatch 503 owner_unavailable before the upstream was reached
  # (findings#206 row 206-492). From the synchronous renewal on, the lease
  # carries the short ttl and only the heartbeat keeps it live.
  @short_heartbeat_opts [ttl_seconds: @stable_owner_ttl_seconds, heartbeat_ttl_seconds: @owner_ttl_seconds]
  # Observing a live lease after its initial deadline takes real time beyond the
  # ttl; this is the reason the three renewal tests run for about 3.5 s.
  @beyond_initial_ttl_ms @owner_ttl_seconds * 1_000 + 400
  # The database-failure test terminates the blocked renewal's backend. The
  # synchronous renewal call waits for that failure within a deliberate test
  # bound, separate from the production lease-derived budget.
  @blocked_renewal_call_timeout_ms 10_000

  @tag slow: "holds a real PostgreSQL session lock beyond the former one-second caller budget"
  test "healthy HTTP ownership survives a finite session lock wait beyond the former call budget",
       %{conn: conn} do
    upstream =
      start_upstream(FakeUpstream.json_response(completed_response("resp_healthy_lock_wait")))

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("healthy-lock-wait")
    session = precreate_session!(setup, session_key)
    observer = database_observer!()
    barrier_ref = make_ref()

    task =
      controller_request(conn, setup, session_key, http_payload(setup), self(),
        ttl_seconds: 30,
        barrier: {barrier_ref, {:heartbeat, :before}}
      )

    assert_receive {:runtime_authorization_barrier, ^barrier_ref, :heartbeat, :before, task_pid},
                   @detection_budget

    blocker = lock_owner_session!(session.id)
    send(task_pid, {:runtime_authorization_release, barrier_ref})
    waiter_backend = await_blocked_backend!(observer, blocker.backend_pid)
    assert waiter_backend != blocker.backend_pid
    assert_zero_work!(setup)
    assert FakeUpstream.count(upstream) == 0

    # The observed real row wait must outlast both the old 800 ms lock budget
    # and 1 s caller budget; match the finite commit pressure seen in production.
    Process.send_after(self(), {:release_healthy_lock, barrier_ref}, 1_100)

    try do
      assert_receive {:release_healthy_lock, ^barrier_ref}, @detection_budget
      assert_zero_work!(setup)
      assert FakeUpstream.count(upstream) == 0
    after
      release_owner_lock!(blocker)
    end

    assert %{"id" => "resp_healthy_lock_wait"} =
             json_response(Task.await(task, @detection_budget), 200)

    assert FakeUpstream.count(upstream) == 1
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == "succeeded"

    assert [%{status: "succeeded"}] =
             Repo.all(from a in Attempt, where: a.request_id == ^request.id)

    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id), :count) == 1
    assert Repo.get!(CodexSession, session.id).owner_lease_token == session.owner_lease_token
    assert_backend_released!(observer, waiter_backend)
  end

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @tag slow: "restarts a real BEAM owner incarnation during gated HTTP finalization and verifies takeover through a second HTTP request"
  test "late successful HTTP finalization cannot extend an absent lease and the next request takes over",
       %{conn: conn} do
    release_ref = make_ref()

    peer_name = :"http_lease_owner_#{System.unique_integer([:positive])}"
    peer = CodexPooler.InstancePresencePeer.start_presence_peer!(peer_name)
    remote = peer.identity

    on_exit(fn ->
      CodexPooler.UnboxedFixture.run_unboxed(fn ->
        Repo.delete_all(from(p in InstancePresence.Instance, where: p.instance_id == ^remote.instance_id))
      end)
    end)

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            respond:
              FakeUpstream.gated_sse_headers(
                [{"response.completed", completed_event("resp_absent_late")}, {"done", "[DONE]"}],
                notify: self(),
                release_ref: release_ref
              )
          ),
          FakeUpstream.expect_request(
            method: "POST",
            respond: FakeUpstream.json_response(completed_response("resp_after_takeover"))
          )
        ])
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("absent-late")
    {:ok, runtime_auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, _} = InstancePresence.record_heartbeat(remote, DateTime.utc_now())

    {:ok, session} =
      Gateway.start_codex_session(runtime_auth, %{
        session_header: session_key,
        owner_instance_id: remote.node_name,
        owner_instance_boot_id: remote.boot_id,
        bridge_owner_lease_ttl_seconds: 45
      })

    {response, logs} =
      with_log(fn ->
        task =
          controller_request(
            conn,
            setup,
            session_key,
            Map.put(http_payload(setup), "stream", true),
            self(),
            ttl_seconds: 45
          )

        monitor = Process.monitor(task.pid)

        assert_receive {:fake_upstream_gate, :before_headers, upstream_pid, ^release_ref},
                       @detection_budget

        on_exit(fn -> send(upstream_pid, {:fake_upstream_release_gate, release_ref}) end)
        before_lease = active_lease!(session.id)

        {:ok, _} =
          InstancePresence.record_heartbeat(
            remote,
            DateTime.add(DateTime.utc_now(), -10, :minute)
          )

        CodexPooler.InstancePresencePeer.stop_presence_peer!(peer)
        _successor = CodexPooler.InstancePresencePeer.start_presence_peer!(peer_name)

        send(upstream_pid, {:fake_upstream_release_gate, release_ref})
        response = Task.await(task, @detection_budget)
        assert_receive {:DOWN, ^monitor, :process, _, :normal}, @detection_budget
        assert active_lease!(session.id).expires_at == before_lease.expires_at
        response
      end)

    assert response.status == 200
    assert response.resp_body =~ "response.completed"
    assert logs =~ "gateway continuity registration failed"
    assert [completed] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert completed.status == "succeeded"

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("x-session-id", session_key)
      |> post("/backend-api/codex/responses", http_payload(setup))

    assert %{"id" => "resp_after_takeover"} = json_response(response, 200)
    replacement = session_for!(setup, session_key)
    assert replacement.id == session.id
    refute replacement.owner_lease_token == session.owner_lease_token
    assert one_active_lease?(session.id)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag slow: "restarts a real BEAM owner incarnation and proves two PostgreSQL attaches blocked on one session converge on one lease"
  test "concurrent fresh HTTP attaches converge on one replacement for an absent incarnation" do
    peer_name = :"http_lease_owner_#{System.unique_integer([:positive])}"
    peer = CodexPooler.InstancePresencePeer.start_presence_peer!(peer_name)
    remote = peer.identity

    on_exit(fn ->
      CodexPooler.UnboxedFixture.run_unboxed(fn ->
        Repo.delete_all(from(p in InstancePresence.Instance, where: p.instance_id == ^remote.instance_id))
      end)
    end)

    upstream =
      start_upstream(FakeUpstream.json_response(completed_response("resp_attach_control")))

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, runtime_auth} = Access.authenticate_authorization_header(setup.authorization)
    session_key = unique_session_key("parallel-absent")
    {:ok, _} = InstancePresence.record_heartbeat(remote, DateTime.utc_now())

    {:ok, session} =
      Gateway.start_codex_session(runtime_auth, %{
        session_header: session_key,
        owner_instance_id: remote.node_name,
        owner_instance_boot_id: remote.boot_id
      })

    {:ok, _} =
      InstancePresence.record_heartbeat(remote, DateTime.add(DateTime.utc_now(), -10, :minute))

    CodexPooler.InstancePresencePeer.stop_presence_peer!(peer)
    _successor = CodexPooler.InstancePresencePeer.start_presence_peer!(peer_name)

    blocker = lock_owner_session!(session.id)
    parent = self()
    start_ref = make_ref()

    tasks =
      for replica <- 1..2 do
        Task.async(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:attaching, start_ref, backend})

            opts =
              RequestOptions.build(
                %{
                  session_header: session_key,
                  owner_instance_id: "sample-replica-#{replica}@remote",
                  owner_instance_boot_id: "candidate-#{replica}"
                },
                "/backend-api/codex/responses",
                %{}
              )

            RoutingContinuity.attach_codex_session(
              runtime_auth,
              %{},
              opts
            )
          end)
        end)
      end

    monitors = Enum.map(tasks, &Process.monitor(&1.pid))

    on_exit(fn ->
      send(blocker.task.pid, {:release_owner_session, blocker.ref})

      Enum.each(tasks, fn task ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)
    end)

    backends =
      for _ <- tasks do
        assert_receive {:attaching, ^start_ref, backend}, @detection_budget
        backend
      end

    assert length(Enum.uniq(backends)) == 2

    Enum.each(
      backends,
      &await_specific_block!(
        &1,
        blocker.backend_pid,
        System.monotonic_time(:millisecond) + @detection_budget
      )
    )

    release_owner_lock!(blocker)
    results = Enum.map(tasks, &Task.await(&1, @detection_budget))

    Enum.each(monitors, fn monitor ->
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, @detection_budget
    end)

    leases = for {:ok, opts} <- results, do: opts.continuity.codex_session.owner_lease_token
    assert length(leases) == 2
    assert length(Enum.uniq(leases)) == 1
    refute hd(leases) == session.owner_lease_token
    assert one_active_lease?(session.id)
  end

  defp await_specific_block!(waiter, blocker, deadline) do
    [[blocked]] =
      Repo.query!(
        "WITH RECURSIVE blockers(pid) AS (SELECT unnest(pg_blocking_pids($1)) UNION SELECT unnest(pg_blocking_pids(pid)) FROM blockers) SELECT EXISTS(SELECT 1 FROM blockers WHERE pid=$2)",
        [waiter, blocker]
      ).rows

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "attach did not reach the held session lock"

      receive do
      after
        10 -> await_specific_block!(waiter, blocker, deadline)
      end
    end
  end

  test "controller request options remain unchanged without the test-only owner-liveness seam", %{
    conn: conn
  } do
    opts = GatewayControllerHelpers.request_opts(conn)

    refute Map.has_key?(opts, :bridge_owner_lease_ttl_seconds)
    refute Map.has_key?(opts, :session_lease_heartbeat_test_observer)
    refute Map.has_key?(opts, :owner_instance_id)
    refute Map.has_key?(opts, :session_owner_witness)
    refute Map.has_key?(opts, :owner_lease_token)

    Process.put(
      {GatewayControllerHelpers, :owner_liveness_test_options},
      %{
        bridge_owner_lease_ttl_seconds: 2,
        session_lease_heartbeat_test_observer: self(),
        owner_instance_id: "synthetic-allowlisted-owner",
        session_owner_witness: :forbidden,
        owner_lease_token: :forbidden,
        session_header: :forbidden,
        payload: :forbidden
      }
    )

    injected = GatewayControllerHelpers.request_opts(conn)
    assert injected.bridge_owner_lease_ttl_seconds == 2
    assert injected.session_lease_heartbeat_test_observer == self()
    assert injected.owner_instance_id == "synthetic-allowlisted-owner"
    refute Map.has_key?(injected, :session_owner_witness)
    refute Map.has_key?(injected, :owner_lease_token)
    refute Map.has_key?(injected, :payload)
    assert injected.session_header == nil
  end

  test "non-session backend HTTP preserves behavior without starting a heartbeat", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(completed_response("resp_no_session")))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    put_owner_liveness_test_options(self(), @owner_ttl_seconds)

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", http_payload(setup))

    assert %{"id" => "resp_no_session"} = json_response(response, 200)
    refute_received {:session_lease_heartbeat, :started, _heartbeat}

    assert Repo.aggregate(from(s in CodexSession, where: s.pool_id == ^setup.pool.id), :count) ==
             0
  end

  @tag slow: "observes real heartbeat renewal beyond the initial three-second database lease"
  test "backend HTTP renews ownership beyond the initial ttl", %{conn: conn} do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.gated_json_headers(completed_response("resp_http_liveness"),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("headers")

    task = controller_request(conn, setup, session_key, http_payload(setup), self(), @short_heartbeat_opts)
    upstream_pid = await_upstream_gate!(task, :before_headers, release_ref)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    session = session_for!(setup, session_key)
    initial_deadline = session.owner_lease_expires_at
    assert_equal_live_deadlines!(session.id)
    await_beyond_initial_ttl!()
    assert_deadline_advanced!(session.id, initial_deadline)

    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    response = Task.await(task, @detection_budget)
    assert %{"id" => "resp_http_liveness"} = json_response(response, 200)
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
  end

  test "an immediate backend HTTP follow-up reuses the session its heartbeat renewed", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(completed_response("resp_http_first")))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("followup")

    # The heartbeat's synchronous renewal sets a 30 s deadline, so the follow-up
    # lands inside the lease however the test is scheduled; after an expiry the
    # gateway intentionally replaces the session, which is a different contract.
    task =
      controller_request(conn, setup, session_key, http_payload(setup), self(), ttl_seconds: @stable_owner_ttl_seconds)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    response = Task.await(task, @detection_budget)
    assert %{"id" => "resp_http_first"} = json_response(response, 200)
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget

    session = session_for!(setup, session_key)
    first_assignment_id = session.pool_upstream_assignment_id

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.json_response(completed_response("resp_followup"))
    )

    followup =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("x-session-id", session_key)
      |> post("/backend-api/codex/responses", http_payload(setup))

    assert %{"id" => "resp_followup"} = json_response(followup, 200)
    assert Repo.get!(CodexSession, session.id).pool_upstream_assignment_id == first_assignment_id

    assert Repo.aggregate(from(s in CodexSession, where: s.pool_id == ^setup.pool.id), :count) ==
             1

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
  end

  @tag slow: "holds real SSE until heartbeat renewal exceeds the initial three-second lease"
  test "backend SSE renews through delayed terminal delivery and settles after release", %{
    conn: conn
  } do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.gated_terminal_sse_stream(
          [
            {"response.created", %{"type" => "response.created", "response" => %{"id" => "resp_sse_liveness"}}}
          ],
          {"response.completed", completed_event("resp_sse_liveness")},
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("terminal")
    payload = Map.put(http_payload(setup), "stream", true)
    task = controller_request(conn, setup, session_key, payload, self(), @short_heartbeat_opts)
    upstream_pid = await_upstream_gate!(task, :before_terminal, release_ref)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    session = session_for!(setup, session_key)
    initial_deadline = session.owner_lease_expires_at
    assert_equal_live_deadlines!(session.id)
    await_beyond_initial_ttl!()
    assert_deadline_advanced!(session.id, initial_deadline)

    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    response = Task.await(task, @detection_budget)
    assert response.status == 200
    assert response.resp_body =~ "response.completed"
    assert response.resp_body =~ "data: [DONE]"
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [%{status: "succeeded"}] =
             Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert %{status: "succeeded"} = Repo.get_by!(CodexTurn, request_id: request.id)
  end

  @tag slow: "waits for the real three-second lease's periodic heartbeat to detect takeover during SSE"
  test "takeover during backend SSE keeps public completion and accounting but fences old continuity",
       %{conn: conn} do
    release_ref = make_ref()
    response_id = "resp_stale_completion"

    upstream =
      start_upstream(
        FakeUpstream.gated_terminal_sse_stream(
          [
            {"response.created", %{"type" => "response.created", "response" => %{"id" => response_id}}}
          ],
          {"response.completed", completed_event(response_id)},
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("takeover")
    payload = Map.put(http_payload(setup), "stream", true)

    # The old heartbeat only notices the takeover on its next renewal, which is
    # scheduled at ttl / 3 (staggered); a 3 s ttl makes that ~1 s instead of
    # ~10 s while keeping the lease comfortably live across the gate.
    task = controller_request(conn, setup, session_key, payload, self(), @short_heartbeat_opts)
    upstream_pid = await_upstream_gate!(task, :before_terminal, release_ref)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    session = session_for!(setup, session_key)

    alias_count_before_takeover =
      Repo.aggregate(
        from(a in BridgeSessionAlias, where: a.codex_session_id == ^session.id),
        :count
      )

    replacement = replace_owner!(session)
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget

    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    response = Task.await(task, @detection_budget)
    assert response.status == 200
    assert response.resp_body =~ "response.completed"

    current = Repo.get!(CodexSession, session.id)
    lease = active_lease!(session.id)
    assert current.owner_instance_id == replacement.owner_instance_id
    assert current.owner_lease_expires_at == replacement.deadline
    assert current.pool_upstream_assignment_id == replacement.assignment_id
    assert lease.expires_at == replacement.deadline
    assert lease.pool_upstream_assignment_id == replacement.assignment_id
    assert one_active_lease?(session.id)

    assert Repo.aggregate(
             from(a in BridgeSessionAlias, where: a.codex_session_id == ^session.id),
             :count
           ) == alias_count_before_takeover

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [%{status: "succeeded"}] =
             Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  @tag slow: "holds public SSE until heartbeat renewal exceeds the initial three-second lease"
  test "/v1 Responses preserves its public SSE envelope while the owner heartbeat remains live",
       %{conn: conn} do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.gated_terminal_sse_stream(
          [
            {"response.created", %{"type" => "response.created", "response" => %{"id" => "resp_v1_liveness"}}}
          ],
          {"response.completed", completed_event("resp_v1_liveness")},
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("v1-terminal")
    parent = self()

    task =
      Task.async(fn ->
        put_owner_liveness_test_options(parent, @short_heartbeat_opts)

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_key)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic public owner liveness",
          "stream" => true
        })
      end)

    upstream_pid = await_upstream_gate!(task, :before_terminal, release_ref)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    session = session_for!(setup, session_key)
    initial_deadline = session.owner_lease_expires_at
    await_beyond_initial_ttl!()
    assert_deadline_advanced!(session.id, initial_deadline)

    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    response = Task.await(task, @detection_budget)
    assert response.status == 200
    assert response.resp_body =~ "response.completed"
    refute response.resp_body =~ "data: [DONE]"
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
  end

  test "caller death stops the backend HTTP heartbeat", %{conn: conn} do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.gated_json_headers(completed_response("resp_cancelled"),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("caller-death")
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        put_owner_liveness_test_options(parent, @stable_owner_ttl_seconds)

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_key)
        |> post("/backend-api/codex/responses", http_payload(setup))
      end)

    assert_receive {:fake_upstream_gate, :before_headers, upstream_pid, ^release_ref},
                   @detection_budget

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    heartbeat_ref = Process.monitor(heartbeat)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @detection_budget
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, :normal}, @detection_budget
    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
  end

  @tag slow: "waits for a real periodic heartbeat, terminates its blocked PostgreSQL backend, and verifies fencing"
  test "renewal database failure stops an in-flight heartbeat and stale completion stays fenced",
       %{conn: conn} do
    release_ref = make_ref()
    response_id = "resp_database_failure"

    upstream =
      start_upstream(
        FakeUpstream.gated_terminal_sse_stream(
          [
            {"response.created", %{"type" => "response.created", "response" => %{"id" => response_id}}}
          ],
          {"response.completed", completed_event(response_id)},
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("renewal-db-failure")
    payload = Map.put(http_payload(setup), "stream", true)
    task = controller_request(conn, setup, session_key, payload, self(), @short_heartbeat_opts)
    upstream_pid = await_upstream_gate!(task, :before_terminal, release_ref)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    heartbeat_ref = Process.monitor(heartbeat)
    session = session_for!(setup, session_key)
    alias_count = alias_count(session.id)
    observer = database_observer!()
    blocker = lock_owner_session!(session.id)
    waiter_backend = await_blocked_backend!(observer, blocker.backend_pid)
    assert terminate_backend!(observer, waiter_backend)
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, :normal}, @detection_budget
    release_owner_lock!(blocker)

    replacement = replace_owner!(session)
    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    response = Task.await(task, @detection_budget)
    assert response.status == 200
    assert response.resp_body =~ "response.completed"
    assert_replacement_unchanged!(session.id, replacement, alias_count)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [%{status: "succeeded"}] =
             Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  @tag slow: "waits for periodic renewal to block on PostgreSQL before terminating its backend and releasing SSE"
  test "renewal database failure before delayed headers preserves the dispatched response",
       %{conn: conn} do
    release_ref = make_ref()
    response_id = "resp_pre_header_database_failure"

    upstream =
      start_upstream(
        FakeUpstream.gated_sse_headers(
          [{"response.completed", completed_event(response_id)}],
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("pre-header-renewal-db-failure")
    payload = Map.put(http_payload(setup), "stream", true)
    task = controller_request(conn, setup, session_key, payload, self(), @short_heartbeat_opts)
    upstream_pid = await_upstream_gate!(task, :before_headers, release_ref)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    heartbeat_ref = Process.monitor(heartbeat)
    session = session_for!(setup, session_key)
    alias_count = alias_count(session.id)
    observer = database_observer!()
    blocker = lock_owner_session!(session.id)
    waiter_backend = await_blocked_backend!(observer, blocker.backend_pid)
    assert terminate_backend!(observer, waiter_backend)
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, :normal}, @detection_budget
    release_owner_lock!(blocker)

    replacement = replace_owner!(session)
    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    response = Task.await(task, @detection_budget)
    assert response.status == 200
    assert response.resp_body =~ response_id
    assert response.resp_body =~ "response.completed"
    assert response.resp_body =~ "data: [DONE]"
    assert_replacement_unchanged!(session.id, replacement, alias_count)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [%{status: "succeeded"}] =
             Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  test "synchronous renewal timeout stops the blocked heartbeat before the owner lock releases",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(completed_response("must_not_dispatch")))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("initial-db-timeout")
    session = precreate_session!(setup, session_key)
    observer = database_observer!()
    barrier_ref = make_ref()
    parent = self()

    task =
      controller_request(conn, setup, session_key, http_payload(setup), parent,
        ttl_seconds: 30,
        barrier: {barrier_ref, {:heartbeat, :before}},
        renew_call_timeout_ms: 1_000
      )

    assert_receive {:runtime_authorization_barrier, ^barrier_ref, :heartbeat, :before, task_pid},
                   @detection_budget

    original_session = Repo.get!(CodexSession, session.id)
    original_lease = active_lease!(session.id)
    blocker = lock_owner_session!(session.id)
    send(task_pid, {:runtime_authorization_release, barrier_ref})
    waiter_backend = await_blocked_backend!(observer, blocker.backend_pid)
    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    heartbeat_ref = Process.monitor(heartbeat)

    try do
      response = Task.await(task, @detection_budget)

      # findings#191: the status is only half the answer. An SDK branches on
      # `type`, so a lifecycle 503 typed as the terminal class tells the client
      # not to retry the one failure that is worth retrying.
      assert %{"error" => %{"code" => "owner_unavailable", "type" => "server_error"}} =
               json_response(response, 503)

      refute Process.alive?(heartbeat)
      assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, _reason}, @detection_budget
      assert_backend_released!(observer, waiter_backend)
    after
      release_owner_lock!(blocker)
    end

    current_session = Repo.get!(CodexSession, session.id)
    current_lease = active_lease!(session.id)
    assert current_session.owner_lease_expires_at == original_session.owner_lease_expires_at
    assert current_session.last_heartbeat_at == original_session.last_heartbeat_at
    assert current_lease.expires_at == original_lease.expires_at
    assert current_lease.renewed_at == original_lease.renewed_at
    assert_refused_without_work!(setup, "owner_unavailable", "synchronous_renewal")
    assert FakeUpstream.count(upstream) == 0
  end

  test "database-unavailable synchronous renewal returns exact 503 before reservation", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(completed_response("must_not_dispatch")))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("initial-db-failure")
    session = precreate_session!(setup, session_key)
    observer = database_observer!()
    barrier_ref = make_ref()
    parent = self()

    task =
      controller_request(conn, setup, session_key, http_payload(setup), parent,
        ttl_seconds: 30,
        barrier: {barrier_ref, {:heartbeat, :before}},
        renew_call_timeout_ms: @blocked_renewal_call_timeout_ms
      )

    assert_receive {:runtime_authorization_barrier, ^barrier_ref, :heartbeat, :before, task_pid},
                   @detection_budget

    blocker = lock_owner_session!(session.id)
    send(task_pid, {:runtime_authorization_release, barrier_ref})

    # The heartbeat announces itself before its renewal blocks, and terminating
    # the blocked backend stops it at once, so it is monitored first; a monitor
    # taken after the termination can see it already gone and get :noproc.
    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    heartbeat_ref = Process.monitor(heartbeat)
    waiter_backend = await_blocked_backend!(observer, blocker.backend_pid)
    assert terminate_backend!(observer, waiter_backend)

    try do
      response = Task.await(task, @detection_budget)

      assert %{
               "error" => %{
                 "code" => "owner_unavailable",
                 "type" => "server_error",
                 "message" => "session owner lease is unavailable"
               }
             } = json_response(response, 503)

      assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
      assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, :normal}, @detection_budget
    after
      release_owner_lock!(blocker)
    end

    assert_refused_without_work!(setup, "owner_unavailable", "synchronous_renewal")
    assert FakeUpstream.count(upstream) == 0
  end

  test "downstream stream cancellation stops the heartbeat without killing the controller caller" do
    release_ref = make_ref()

    # The upstream holds its headers until the heartbeat is monitored: the
    # cancellation follows the first downstream chunk without a test step in
    # between, so an unheld stream can stop the heartbeat before the monitor.
    upstream =
      start_upstream(
        FakeUpstream.gated_sse_headers(
          [{"response.completed", completed_event("resp_downstream_cancel")}],
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    session_key = unique_session_key("downstream-cancel")
    parent = self()

    task =
      Task.async(fn ->
        put_owner_liveness_test_options(parent, @stable_owner_ttl_seconds)

        Plug.Test.conn(
          :post,
          "/backend-api/codex/responses",
          Map.put(http_payload(setup), "stream", true)
        )
        |> auth(setup)
        |> put_req_header("x-session-id", session_key)
        |> with_cancelling_adapter(parent)
        |> CodexPoolerWeb.Endpoint.call(CodexPoolerWeb.Endpoint.init([]))
      end)

    assert_receive {:fake_upstream_gate, :before_headers, upstream_pid, ^release_ref},
                   @detection_budget

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_budget
    heartbeat_ref = Process.monitor(heartbeat)
    send(upstream_pid, {:fake_upstream_release_gate, release_ref})
    assert_receive {:downstream_stream_started, caller}, @detection_budget
    assert caller == task.pid
    assert_receive {:downstream_stream_cancelled, ^caller}, @detection_budget
    response = Task.await(task, @detection_budget)
    assert response.status == 200
    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_budget
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, :normal}, @detection_budget
  end

  test "native backend websocket controller and socket behavior never starts an HTTP heartbeat",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(completed_response("resp_native_ws")))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    put_owner_liveness_test_options(self(), @owner_ttl_seconds)

    websocket_key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    _upgrade =
      conn
      |> auth(setup)
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-version", "13")
      |> put_req_header("sec-websocket-key", websocket_key)
      |> get("/backend-api/codex/responses")

    refute_received {:session_lease_heartbeat, :started, _heartbeat}

    {server, port} = start_public_endpoint_with_server!()
    turn_state = unique_session_key("native-websocket")
    {socket_conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    assert {:ok, [socket]} = ThousandIsland.connection_pids(server)
    socket_monitor = Process.monitor(socket)
    parent = self()
    handler = make_ref()
    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.attach(
      handler,
      [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
      fn _, _, metadata, _ ->
        if metadata.caller == socket, do: send(parent, {:socket_cleanup_finished, handler, self()})
      end,
      nil
    )

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("synthetic websocket owner control"),
        "stream" => true,
        "generate" => true
      })

    {socket_conn, websocket} = public_websocket_send_text!(socket_conn, websocket, ref, payload)
    {socket_conn, _websocket, frame} = public_websocket_receive_text!(socket_conn, websocket, ref)
    assert %{"id" => "resp_native_ws"} = CodexPooler.JSON.decode!(frame)
    refute_received {:session_lease_heartbeat, :started, _heartbeat}
    assert_socket_response_tasks_released!(socket)
    Mint.HTTP.close(socket_conn)
    assert_receive {:socket_cleanup_finished, ^handler, cleanup}, @detection_budget
    cleanup_monitor = Process.monitor(cleanup)
    assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup, _reason}, @detection_budget
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, _reason}, @detection_budget
  end

  for phase <- [{:reserve, :before}, {:reservation_lock, :before}] do
    test "controller returns exact stale_owner and rolls back when takeover occurs at #{inspect(phase)}",
         %{conn: conn} do
      upstream =
        start_upstream(FakeUpstream.json_response(completed_response("must_not_dispatch")))

      setup = gateway_setup(upstream)
      register_unboxed_pool_cleanup!(setup)
      session_key = unique_session_key("stale-barrier")
      session = precreate_session!(setup, session_key)
      barrier_ref = make_ref()
      parent = self()

      task =
        controller_request(conn, setup, session_key, http_payload(setup), parent,
          ttl_seconds: 30,
          barrier: {barrier_ref, unquote(phase)}
        )

      assert_receive {:runtime_authorization_barrier, ^barrier_ref, operation, barrier_phase, task_pid},
                     @detection_budget

      assert {operation, barrier_phase} == unquote(phase)
      replacement = replace_owner!(session)
      send(task_pid, {:runtime_authorization_release, barrier_ref})

      response = Task.await(task, @detection_budget)
      # findings#191: a lease that moved is backpressure, not a malformed
      # request; the same submission succeeds once the new owner is reached.
      assert %{"error" => %{"code" => "stale_owner", "type" => "server_error"}} =
               json_response(response, 409)

      # Both barriers sit after the synchronous renewal.
      assert_refused_without_work!(setup, "stale_owner", "reservation")
      assert FakeUpstream.count(upstream) == 0

      current = Repo.get!(CodexSession, session.id)
      lease = active_lease!(session.id)
      assert current.owner_instance_id == replacement.owner_instance_id
      assert current.owner_lease_expires_at == replacement.deadline
      assert current.pool_upstream_assignment_id == replacement.assignment_id
      assert lease.expires_at == replacement.deadline
      assert one_active_lease?(session.id)
    end
  end

  for failure <- [:expired, :missing] do
    test "controller returns exact owner_unavailable and rolls back for #{failure} ownership",
         %{conn: conn} do
      upstream =
        start_upstream(FakeUpstream.json_response(completed_response("must_not_dispatch")))

      setup = gateway_setup(upstream)
      register_unboxed_pool_cleanup!(setup)
      session_key = unique_session_key("unavailable")
      session = precreate_session!(setup, session_key)
      barrier_ref = make_ref()
      parent = self()

      task =
        controller_request(conn, setup, session_key, http_payload(setup), parent,
          ttl_seconds: 30,
          barrier: {barrier_ref, {:reservation_lock, :before}}
        )

      assert_receive {:runtime_authorization_barrier, ^barrier_ref, :reservation_lock, :before, task_pid},
                     @detection_budget

      make_owner_unavailable!(session, unquote(failure))
      send(task_pid, {:runtime_authorization_release, barrier_ref})

      response = Task.await(task, @detection_budget)

      assert %{"error" => %{"code" => "owner_unavailable", "type" => "server_error"}} =
               json_response(response, 503)

      assert_refused_without_work!(setup, "owner_unavailable", "reservation")
      assert FakeUpstream.count(upstream) == 0
    end
  end

  defp controller_request(conn, setup, session_key, payload, observer, opts) do
    parent = self()

    Task.async(fn ->
      put_owner_liveness_test_options(observer, opts)

      case Keyword.get(opts, :barrier) do
        {ref, phase} ->
          Process.put({Service, :runtime_authorization_barrier}, {parent, ref, phase})

        nil ->
          :ok
      end

      case Keyword.get(opts, :renew_call_timeout_ms) do
        timeout when is_integer(timeout) ->
          Process.put({SessionLeaseHeartbeat, :renew_call_timeout_ms}, timeout)

        nil ->
          :ok
      end

      conn
      |> auth(setup)
      |> put_req_header("x-session-id", session_key)
      |> post("/backend-api/codex/responses", payload)
    end)
  end

  defp put_owner_liveness_test_options(observer, opts) when is_list(opts) do
    put_owner_liveness_test_options(observer, Keyword.get(opts, :ttl_seconds, @owner_ttl_seconds))

    case Keyword.get(opts, :heartbeat_ttl_seconds) do
      ttl when is_integer(ttl) -> Process.put({SessionLeaseHeartbeat, :ttl_seconds}, ttl)
      nil -> :ok
    end
  end

  defp put_owner_liveness_test_options(observer, ttl_seconds) when is_integer(ttl_seconds) do
    Process.put(
      {GatewayControllerHelpers, :owner_liveness_test_options},
      %{
        bridge_owner_lease_ttl_seconds: ttl_seconds,
        session_lease_heartbeat_test_observer: observer,
        owner_instance_id: "synthetic-http-owner"
      }
    )
  end

  defp precreate_session!(setup, session_key) do
    {:ok, auth_context} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth_context, %{
        session_header: session_key,
        owner_instance_id: "synthetic-http-owner",
        bridge_owner_lease_ttl_seconds: 30
      })

    session
  end

  defp replace_owner!(session) do
    deadline = DateTime.add(db_now(), 90, :second)
    replacement_token = Ecto.UUID.generate()
    replacement_owner = "synthetic-replacement-owner"

    unboxed_run(fn ->
      Repo.transaction(fn ->
        current = Repo.get!(CodexSession, session.id)
        lease = active_lease!(session.id)

        current
        |> Ecto.Changeset.change(%{
          owner_instance_id: replacement_owner,
          owner_lease_token: replacement_token,
          owner_lease_expires_at: deadline,
          last_heartbeat_at: deadline,
          updated_at: deadline
        })
        |> Repo.update!()

        lease
        |> Ecto.Changeset.change(%{
          owner_instance_id: replacement_owner,
          lease_token: replacement_token,
          renewed_at: deadline,
          expires_at: deadline,
          updated_at: deadline
        })
        |> Repo.update!()
      end)
    end)

    %{
      owner_instance_id: replacement_owner,
      deadline: deadline,
      assignment_id: session.pool_upstream_assignment_id
    }
  end

  defp make_owner_unavailable!(session, :expired) do
    deadline = DateTime.add(db_now(), -1, :second)

    unboxed_run(fn ->
      session
      |> Repo.reload!()
      |> Ecto.Changeset.change(owner_lease_expires_at: deadline, last_heartbeat_at: deadline)
      |> Repo.update!()

      session.id
      |> active_lease!()
      |> Ecto.Changeset.change(expires_at: deadline, renewed_at: deadline)
      |> Repo.update!()
    end)
  end

  defp make_owner_unavailable!(session, :missing) do
    unboxed_run(fn -> Repo.delete!(active_lease!(session.id)) end)
  end

  defp lock_owner_session!(session_id) do
    parent = self()
    ref = make_ref()

    task = Task.async(fn -> run_owner_session_lock!(session_id, parent, ref) end)

    assert_receive {:owner_session_locked, ^ref, backend_pid}, @detection_budget
    %{task: task, ref: ref, backend_pid: backend_pid}
  end

  defp run_owner_session_lock!(session_id, parent, ref) do
    unboxed_run(fn ->
      Repo.transaction(fn -> hold_owner_session_lock!(session_id, parent, ref) end)
    end)
  end

  # The holder ends on the test's release or on the test process going down. A
  # timer of its own started before a chain of failure-detection waits in the
  # test body and expired first, replacing the failing assertion with this
  # linked task's exit.
  defp hold_owner_session_lock!(session_id, parent, ref) do
    parent_monitor = Process.monitor(parent)
    _session = Repo.one!(from(s in CodexSession, where: s.id == ^session_id, lock: "FOR UPDATE"))
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:owner_session_locked, ref, backend_pid})

    receive do
      {:release_owner_session, ^ref} -> :ok
      {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
    end
  end

  defp release_owner_lock!(%{task: task, ref: ref}) do
    send(task.pid, {:release_owner_session, ref})
    assert {:ok, :ok} = Task.await(task, @detection_budget)
    :ok
  end

  defp await_blocked_backend!(observer, blocker_backend_pid) do
    await_blocked_backend!(
      observer,
      blocker_backend_pid,
      System.monotonic_time(:millisecond) + 5_000
    )
  end

  defp await_blocked_backend!(observer, blocker_backend_pid, deadline) do
    %{rows: rows} =
      Postgrex.query!(
        observer,
        "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)) ORDER BY pid LIMIT 1",
        [blocker_backend_pid]
      )

    case rows do
      [[backend_pid]] ->
        backend_pid

      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          marker = make_ref()
          Process.send_after(self(), {:retry_blocked_backend, marker}, 10)
          assert_receive {:retry_blocked_backend, ^marker}, @detection_budget
          await_blocked_backend!(observer, blocker_backend_pid, deadline)
        else
          flunk("timed out waiting for the heartbeat database query to block")
        end
    end
  end

  defp terminate_backend!(observer, backend_pid) do
    %{rows: [[terminated?]]} =
      Postgrex.query!(observer, "SELECT pg_terminate_backend($1)", [backend_pid])

    terminated?
  end

  defp assert_backend_released!(observer, backend_pid) do
    assert_backend_released!(observer, backend_pid, System.monotonic_time(:millisecond) + 5_000)
  end

  defp assert_backend_released!(observer, backend_pid, deadline) do
    %{rows: rows} =
      Postgrex.query!(
        observer,
        "SELECT state, cardinality(pg_blocking_pids(pid)) FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    case rows do
      [] ->
        :ok

      [["idle", 0]] ->
        :ok

      _rows ->
        if System.monotonic_time(:millisecond) < deadline do
          marker = make_ref()
          Process.send_after(self(), {:retry_backend_release, marker}, 10)
          assert_receive {:retry_backend_release, ^marker}, @detection_budget
          assert_backend_released!(observer, backend_pid, deadline)
        else
          flunk("heartbeat database worker remained active after the heartbeat stopped")
        end
    end
  end

  defp database_observer! do
    connection_options =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
      |> Keyword.put(:backoff_type, :stop)

    {:ok, observer} = Postgrex.start_link(connection_options)

    on_exit(fn ->
      if Process.alive?(observer) do
        try do
          GenServer.stop(observer)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    observer
  end

  defp alias_count(session_id) do
    Repo.aggregate(
      from(a in BridgeSessionAlias, where: a.codex_session_id == ^session_id),
      :count
    )
  end

  defp assert_replacement_unchanged!(session_id, replacement, expected_alias_count) do
    current = Repo.get!(CodexSession, session_id)
    lease = active_lease!(session_id)
    assert current.owner_instance_id == replacement.owner_instance_id
    assert current.owner_lease_expires_at == replacement.deadline
    assert current.pool_upstream_assignment_id == replacement.assignment_id
    assert lease.expires_at == replacement.deadline
    assert lease.pool_upstream_assignment_id == replacement.assignment_id
    assert alias_count(session_id) == expected_alias_count
    assert one_active_lease?(session_id)
  end

  defp with_cancelling_adapter(%Plug.Conn{adapter: {adapter, delegate_state}} = conn, notify) do
    %{
      conn
      | adapter: {CancellingAdapter, %{delegate: adapter, delegate_state: delegate_state, notify: notify}}
    }
  end

  # Waits for the request to reach the fake upstream's gate. A request the
  # gateway answers before dispatch never reaches it, so its reply fails the
  # test with the status and body it got instead of a bare 15 s timeout.
  defp await_upstream_gate!(%Task{ref: task_ref}, gate, release_ref) do
    receive do
      {:fake_upstream_gate, ^gate, upstream_pid, ^release_ref} ->
        upstream_pid

      {^task_ref, %Plug.Conn{} = response} ->
        flunk("request was answered before it reached the upstream #{gate} gate: status=#{inspect(response.status)} body=#{inspect(response.resp_body, limit: 512, printable_limit: 512)}")
    after
      @detection_budget ->
        flunk("request neither reached the upstream #{gate} gate nor replied within #{@detection_budget} ms")
    end
  end

  defp session_for!(setup, session_key) do
    Repo.get_by!(CodexSession, pool_id: setup.pool.id, session_key: session_key)
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from(l in BridgeOwnerLease,
        where: l.codex_session_id == ^session_id and l.status == "active"
      )
    )
  end

  defp one_active_lease?(session_id) do
    Repo.aggregate(
      from(l in BridgeOwnerLease,
        where: l.codex_session_id == ^session_id and l.status == "active"
      ),
      :count
    ) == 1
  end

  defp assert_equal_live_deadlines!(session_id) do
    deadlines = live_deadlines!(session_id)
    assert deadlines.session == deadlines.lease
    assert DateTime.compare(deadlines.session, deadlines.now) == :gt
  end

  defp assert_deadline_advanced!(session_id, initial_deadline) do
    deadlines = live_deadlines!(session_id)
    assert DateTime.compare(deadlines.session, initial_deadline) == :gt
    assert deadlines.session == deadlines.lease
    assert DateTime.compare(deadlines.session, deadlines.now) == :gt
  end

  # The heartbeat renews the lease and the session in one transaction every
  # ttl / 3, so both deadlines and the clock come from one statement; separate
  # reads can straddle a renewal and see two different committed deadlines.
  defp live_deadlines!(session_id) do
    Repo.one!(
      from(s in CodexSession,
        join: l in BridgeOwnerLease,
        on: l.codex_session_id == s.id and l.status == "active",
        where: s.id == ^session_id,
        select: %{
          session: s.owner_lease_expires_at,
          lease: l.expires_at,
          now: type(fragment("clock_timestamp()"), :utc_datetime_usec)
        }
      )
    )
  end

  defp await_beyond_initial_ttl! do
    marker = make_ref()
    Process.send_after(self(), {:beyond_initial_ttl, marker}, @beyond_initial_ttl_ms)
    assert_receive {:beyond_initial_ttl, ^marker}, @detection_budget
  end

  defp assert_zero_work!(setup) do
    request_ids = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, select: r.id))
    assert request_ids == []
    assert Repo.aggregate(from(a in Attempt, where: a.request_id in ^request_ids), :count) == 0
    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id in ^request_ids), :count) == 0
  end

  # A session owner refusal before any attempt writes one rejected request row
  # naming the code and the phase that refused it, and no attempt, turn or
  # ledger entry (findings#206 row 206-564; before it the refusal left no row).
  defp assert_refused_without_work!(setup, code, phase) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == code
    assert request.request_metadata["gateway_denial"]["code"] == code
    assert request.request_metadata["continuity_denial"]["denial_family"] == "session_owner_lease"
    assert request.request_metadata["continuity_denial"]["failure_phase"] == phase
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id), :count) == 0
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) == 0
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp unique_session_key(label),
    do: "owner-liveness-#{label}-#{System.unique_integer([:positive])}"

  defp http_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("synthetic owner liveness")
    }
  end

  defp completed_response(id) do
    %{
      "id" => id,
      "object" => "response",
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
    }
  end

  defp completed_event(id) do
    %{
      "type" => "response.completed",
      "response" => completed_response(id)
    }
  end
end
