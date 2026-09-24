defmodule CodexPoolerWeb.Runtime.BackendCodexHTTPCrossNodeLeaseTest do
  @moduledoc """
  A native HTTP turn whose session lease is held by another VM (the previous
  turn ran on the other web pod) and expires between the turn's continuity
  acquisition and its synchronous lease renewal (findings#206 row 206-564).

  Acquisition hands the request the other VM's live lease unchanged. The
  synchronous renewal then found it expired and answered `503
  owner_unavailable`, with no request row. Now the renewal takes an expired
  lease that nobody renewed or replaced over by compare-and-set on its token
  and expiry, under the database clock: the old token stops authorizing
  anything, so the old VM cannot keep acting as the owner. A lease the old VM
  still renews is never taken over. A refusal that remains writes one rejected
  request row with no attempt, turn or ledger entry.

  Topology: this node serves the HTTP request. A peer BEAM with its own
  PostgreSQL connections is the previous owner and makes its renewals through
  the real persistence. Websocket owner forwarding is enabled.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, register_unboxed_pool_cleanup!: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture
  alias CodexPoolerWeb.GatewayControllerHelpers
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, as: PeerSupport

  @detection_budget 15_000
  @request_ttl_seconds 30

  setup do
    PeerSupport.enter_peer_owner_topology!()
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)

    :ok
  end

  @tag slow: "boots a peer BEAM with its own Repo as the previous session owner"
  test "a lease that expires between acquisition and the synchronous renewal is taken over, and the old token stops authorizing" do
    %{setup: setup, upstream: upstream, peer: peer, session: session, alias_key: alias_key} = cross_node_fixture("expiry-race")
    old_token = session.owner_lease_token
    ref = make_ref()
    task = controller_request(setup, alias_key, ref, {:heartbeat, :before})

    assert_receive {:runtime_authorization_barrier, ^ref, :heartbeat, :before, task_pid}, @detection_budget

    # Acquisition handed this request the other VM's lease unchanged.
    assert %BridgeOwnerLease{lease_token: ^old_token} = lease = active_lease!(session.id)
    assert lease.owner_instance_id == Atom.to_string(peer)

    # The previous owner's lease runs out while this request is between
    # acquisition and its synchronous renewal (production: 1.5 s here, and the
    # lease had 1 s left). Injected, not waited for.
    expire_lease!(session.id)
    send(task_pid, {:runtime_authorization_release, ref})
    response = Task.await(task, @detection_budget)

    assert %{"id" => "resp_cross_node_takeover"} = json_response(response, 200)
    assert FakeUpstream.count(upstream) == 1

    assert [%BridgeOwnerLease{} = new_lease] = active_leases(session.id)
    refute new_lease.lease_token == old_token
    assert new_lease.owner_instance_id == InstancePresence.local_identity().node_name

    released = Repo.one!(from(l in BridgeOwnerLease, where: l.lease_token == ^old_token))
    assert released.status == "released"
    assert released.metadata["release_reason"] == "expired_unrenewed_takeover"

    # Single writer: the previous owner's token authorizes nothing on its own VM.
    assert {:error, :stale_owner} = peer_renew(peer, session.id, old_token)
    assert {:error, :stale_owner} = :erpc.call(peer, SessionContinuity, :validate_owner_token, [session.id, old_token])
    assert :ok = SessionContinuity.validate_owner_token(session.id, new_lease.lease_token)

    assert [request] = pool_requests(setup)
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_key"] == alias_key
  end

  @tag slow: "boots a peer BEAM with its own Repo and lets a near-expiry lease lapse on the database clock"
  test "a stalled turn on the old node cannot outlive the takeover when its lease lapses during this request" do
    %{setup: setup, upstream: upstream, peer: peer, session: session, alias_key: alias_key} = cross_node_fixture("stalled-old-owner")
    old_token = session.owner_lease_token

    # The old node's turn is still in flight but its heartbeat has stalled: its
    # lease has about one second left and nothing renews it. Extending the
    # lease at this request's acquisition would revive that turn's token;
    # the takeover must not.
    near_expiry = set_lease_expiry!(session.id, 1_000)
    ref = make_ref()
    task = controller_request(setup, alias_key, ref, {:heartbeat, :before})

    assert_receive {:runtime_authorization_barrier, ^ref, :heartbeat, :before, task_pid}, @detection_budget
    # The lease must lapse on the database clock between this request's
    # acquisition and its synchronous renewal; about one second of real time.
    await_db_clock_past!(near_expiry)
    send(task_pid, {:runtime_authorization_release, ref})

    assert %{"id" => "resp_cross_node_takeover"} = json_response(Task.await(task, @detection_budget), 200)
    assert FakeUpstream.count(upstream) == 1

    # The stalled heartbeat wakes up on the old node: it must find itself
    # replaced, not renew a lease the new owner also believes it holds.
    assert {:error, :stale_owner} = peer_renew(peer, session.id, old_token)
    assert [%BridgeOwnerLease{} = lease] = active_leases(session.id)
    assert lease.owner_instance_id == InstancePresence.local_identity().node_name
    refute lease.lease_token == old_token
  end

  @tag slow: "boots a peer BEAM with its own Repo as a live concurrent owner"
  test "a lease the old node keeps renewing is never taken over" do
    %{setup: setup, upstream: upstream, peer: peer, session: session, alias_key: alias_key} = cross_node_fixture("live-old-owner")
    old_token = session.owner_lease_token
    ref = make_ref()
    task = controller_request(setup, alias_key, ref, {:heartbeat, :before})

    assert_receive {:runtime_authorization_barrier, ^ref, :heartbeat, :before, task_pid}, @detection_budget
    # The old node's in-flight turn renews on its own VM while this request waits.
    assert {:ok, %CodexSession{owner_lease_token: ^old_token}} = peer_renew(peer, session.id, old_token)
    send(task_pid, {:runtime_authorization_release, ref})

    assert %{"id" => "resp_cross_node_takeover"} = json_response(Task.await(task, @detection_budget), 200)
    assert FakeUpstream.count(upstream) == 1

    # The existing cross-replica contract: a live lease is shared, not replaced.
    assert [%BridgeOwnerLease{lease_token: ^old_token} = lease] = active_leases(session.id)
    assert lease.owner_instance_id == Atom.to_string(peer)
    assert {:ok, %CodexSession{owner_lease_token: ^old_token}} = peer_renew(peer, session.id, old_token)
  end

  @tag slow: "boots a peer BEAM with its own Repo as the previous session owner"
  test "an owner refusal that remains writes one rejected request row and no work" do
    %{setup: setup, upstream: upstream, session: session, alias_key: alias_key} = cross_node_fixture("refusal-row")
    ref = make_ref()
    task = controller_request(setup, alias_key, ref, {:heartbeat, :before})

    assert_receive {:runtime_authorization_barrier, ^ref, :heartbeat, :before, task_pid}, @detection_budget
    # Another request took the session over in between: the lease this request
    # was handed is gone, so there is nothing to take over.
    replace_lease!(session.id)
    send(task_pid, {:runtime_authorization_release, ref})
    response = Task.await(task, @detection_budget)

    assert %{"error" => %{"code" => "stale_owner"}} = json_response(response, 409)
    assert FakeUpstream.count(upstream) == 0

    assert [request] = pool_requests(setup)
    assert request.status == "rejected"
    assert request.last_error_code == "stale_owner"
    assert request.response_status_code == 409
    assert request.request_metadata["gateway_denial"]["code"] == "stale_owner"
    assert request.request_metadata["continuity_denial"]["denial_family"] == "session_owner_lease"
    assert request.request_metadata["continuity_denial"]["failure_phase"] == "synchronous_renewal"
    assert request.request_metadata["codex_session_key"] == alias_key
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id), :count) == 0
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) == 0
  end

  defp cross_node_fixture(label) do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_cross_node_takeover",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    peer = PeerSupport.start_bridge_peer!(:current, setup.identity, repo: :real)
    alias_key = "cross-node-#{label}-#{System.unique_integer([:positive])}"
    {:ok, runtime_auth} = Access.authenticate_authorization_header(setup.authorization)

    # The previous turn ran on the peer: the session's lease names that VM.
    {:ok, session} =
      Gateway.start_codex_session(runtime_auth, %{
        session_header: alias_key,
        owner_instance_id: Atom.to_string(peer),
        bridge_owner_lease_ttl_seconds: @request_ttl_seconds
      })

    %{setup: setup, upstream: upstream, peer: peer, session: session, alias_key: alias_key}
  end

  # The request enters through the controller with the underscore alias only,
  # as Hermes `openai-codex` sends it, and names no owner override: this VM is
  # the one serving it.
  defp controller_request(setup, alias_key, ref, phase) do
    parent = self()

    Task.async(fn ->
      Process.put({Service, :runtime_authorization_barrier}, {parent, ref, phase})
      Process.put({GatewayControllerHelpers, :owner_liveness_test_options}, %{bridge_owner_lease_ttl_seconds: @request_ttl_seconds})

      build_conn()
      |> auth(setup)
      |> put_req_header("session_id", alias_key)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("cross node lease fixture")
      })
    end)
  end

  defp peer_renew(peer, session_id, token) do
    options = RequestOptions.build([bridge_owner_lease_ttl_seconds: @request_ttl_seconds, transport: "http_json"], "/backend-api/codex/responses", %{})
    :erpc.call(peer, SessionContinuity, :renew_owner_token, [session_id, token, options])
  end

  defp active_lease!(session_id), do: Repo.one!(active_leases_query(session_id))
  defp active_leases(session_id), do: Repo.all(active_leases_query(session_id))

  defp active_leases_query(session_id),
    do: from(l in BridgeOwnerLease, where: l.codex_session_id == ^session_id and l.status == "active")

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: r.admitted_at))

  defp expire_lease!(session_id), do: set_lease_expiry!(session_id, -1)

  # Moves the session's lease and the session copy of its deadline to
  # `offset_ms` from the database clock, and returns that deadline.
  defp set_lease_expiry!(session_id, offset_ms) do
    UnboxedFixture.run_unboxed(fn ->
      %{rows: [[deadline]]} = Repo.query!("SELECT clock_timestamp() + ($1 || ' milliseconds')::interval", [Integer.to_string(offset_ms)])
      Repo.update_all(active_leases_query(session_id), set: [expires_at: deadline])
      Repo.update_all(from(s in CodexSession, where: s.id == ^session_id), set: [owner_lease_expires_at: deadline])
      deadline
    end)
  end

  defp replace_lease!(session_id) do
    UnboxedFixture.run_unboxed(fn ->
      token = Ecto.UUID.generate()
      Repo.update_all(active_leases_query(session_id), set: [lease_token: token, owner_instance_id: "synthetic-replacement-owner"])
      Repo.update_all(from(s in CodexSession, where: s.id == ^session_id), set: [owner_lease_token: token, owner_instance_id: "synthetic-replacement-owner"])
    end)
  end

  defp await_db_clock_past!(deadline),
    do: await_db_clock_past!(deadline, System.monotonic_time(:millisecond) + @detection_budget)

  defp await_db_clock_past!(deadline, budget_end) do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    cond do
      DateTime.compare(now, deadline) == :gt ->
        :ok

      System.monotonic_time(:millisecond) > budget_end ->
        flunk("database clock never passed the lease deadline")

      true ->
        Process.sleep(50)
        await_db_clock_past!(deadline, budget_end)
    end
  end
end
