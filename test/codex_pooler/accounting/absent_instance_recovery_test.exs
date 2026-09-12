defmodule CodexPooler.Accounting.AbsentInstanceRecoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Platform.{InstanceHeartbeat, InstancePresence}
  alias CodexPooler.Platform.InstancePresence.{Identity, Instance}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  describe "recover_absent_instance_attempts/2" do
    test "an instance that restarts in place does not keep its predecessor's orphan alive" do
      setup = accounting_setup()
      now = now()
      dispatched_at = DateTime.add(now, -10, :minute)

      first = start_instance!(:absent_recovery_restart_first)

      %{request: request, attempt: attempt, turn: turn} =
        dispatch_open_turn!(setup, dispatched_at)

      # The owner came from the running instance, not from the test.
      assert attempt.owner_instance_id == first.node_name
      assert attempt.owner_instance_boot_id == first.boot_id

      assignment_before = Repo.get!(PoolUpstreamAssignment, setup.assignment.id)

      # The VM is halted from inside, so no drain runs and its row keeps
      # whatever it was last refreshed with. Place that refresh ten minutes back
      # through the same upsert the heartbeat uses rather than waiting out the
      # liveness window.
      {:ok, _stale} = InstancePresence.record_heartbeat(first, dispatched_at)
      end_instance!(:absent_recovery_restart_first)

      # Kubernetes restarts the container in place: same pod, same address, so
      # the same node name, with a new VM behind it.
      second = start_instance!(:absent_recovery_restart_second)
      assert second.node_name == first.node_name
      assert second.boot_id != first.boot_id

      assert {:ok, %{absent_instance_attempts_recovered: 1}} =
               Accounting.recover_absent_instance_attempts(now)

      # The successor must not have refreshed the row that proves its
      # predecessor is gone.
      assert Repo.get!(Instance, first.instance_id).last_seen_at == dispatched_at

      assert DateTime.compare(
               Repo.get!(Instance, second.instance_id).last_seen_at,
               dispatched_at
             ) == :gt

      assert %Request{
               status: "failed",
               usage_status: "usage_unknown",
               response_status_code: 499,
               last_error_code: "absent_instance_recovered",
               completed_at: %DateTime{}
             } = Repo.get!(Request, request.id)

      assert %Attempt{
               status: "failed",
               usage_status: "usage_unknown",
               network_error_code: "absent_instance_recovered",
               completed_at: %DateTime{}
             } = recovered_attempt = Repo.reload!(attempt)

      assert recovered_attempt.owner_instance_id == first.node_name
      assert recovered_attempt.owner_instance_boot_id == first.boot_id

      assert %CodexTurn{status: "interrupted", error_code: "absent_instance_recovered"} =
               Repo.reload!(turn)

      assert ledger_kinds(request) == ["release", "reservation", "settlement"]

      # A recovery is our own lifecycle event: the upstream said nothing at all,
      # so its assignment must come out of the pass untouched.
      assert Repo.get!(PoolUpstreamAssignment, setup.assignment.id) == assignment_before

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)
    end

    test "an attempt owned by the live instance is untouched" do
      setup = accounting_setup()
      now = now()

      _live = start_instance!(:absent_recovery_live)

      %{request: request, attempt: attempt} =
        dispatch_open_turn!(setup, DateTime.add(now, -10, :minute))

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
      assert ledger_kinds(request) == ["reservation"]
    end

    test "an instance that reported inside the liveness window is untouched" do
      setup = accounting_setup()
      now = now()

      instance = start_instance!(:absent_recovery_inside_window)

      %{request: request, attempt: attempt} =
        dispatch_open_turn!(setup, DateTime.add(now, -10, :minute))

      {:ok, _recent} =
        InstancePresence.record_heartbeat(instance, DateTime.add(now, -30, :second))

      end_instance!(:absent_recovery_inside_window)

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
    end

    test "an attempt younger than the liveness window is untouched" do
      setup = accounting_setup()
      now = now()

      instance = start_instance!(:absent_recovery_young_attempt)

      %{request: request, attempt: attempt} =
        dispatch_open_turn!(setup, DateTime.add(now, -20, :second))

      {:ok, _stale} =
        InstancePresence.record_heartbeat(instance, DateTime.add(now, -10, :minute))

      end_instance!(:absent_recovery_young_attempt)

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
    end

    test "an instance that never published presence is left to the six-hour sweep" do
      setup = accounting_setup()
      now = now()

      # A VM that minted its incarnation and never got a heartbeat written: a
      # failed first write, or a role that could not reach the database.
      _boot_id = Identity.mint_boot_id!()
      identity = InstancePresence.local_identity()
      refute Repo.get(Instance, identity.instance_id)

      %{request: request, attempt: attempt} =
        dispatch_open_turn!(setup, DateTime.add(now, -7, :hour))

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"

      assert {:ok, %{stale_reservations_settled: 1}} = Accounting.recover_stale_reservations(now)

      assert %Request{status: "failed", last_error_code: "stale_reservation_recovered"} =
               Repo.get!(Request, request.id)

      assert Repo.reload!(attempt).status == "failed"
    end

    test "an attempt written before incarnations existed is out of reach and stays with the sweep" do
      setup = accounting_setup()
      now = now()
      dispatched_at = DateTime.add(now, -7, :hour)
      node_name = "codex_pooler@10.42.0.#{System.unique_integer([:positive])}"

      # The shape the previous release wrote and that is still in production: a
      # presence row keyed by the node name alone, with no incarnation, long
      # past the liveness window. Its writer no longer exists in the tree, so
      # the row is inserted exactly as it left it.
      Repo.insert!(%Instance{
        instance_id: node_name,
        started_at: dispatched_at,
        last_seen_at: dispatched_at,
        updated_at: dispatched_at
      })

      %{request: request, attempt: attempt} =
        dispatch_open_turn!(setup, dispatched_at, %{owner_instance_id: node_name})

      assert attempt.owner_instance_id == node_name
      assert is_nil(attempt.owner_instance_boot_id)

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"

      assert {:ok, %{stale_reservations_settled: 1}} = Accounting.recover_stale_reservations(now)

      assert Repo.get!(Request, request.id).last_error_code == "stale_reservation_recovered"
    end

    test "an attempt with no recorded owner is out of reach and stays with the six-hour sweep" do
      setup = accounting_setup()
      now = now()

      _live = start_instance!(:absent_recovery_no_owner)

      %{request: request, attempt: attempt} =
        dispatch_open_turn!(setup, DateTime.add(now, -7, :hour), %{owner_instance_id: nil})

      assert is_nil(attempt.owner_instance_id)
      assert is_nil(attempt.owner_instance_boot_id)

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"

      assert {:ok, %{stale_reservations_settled: 1}} = Accounting.recover_stale_reservations(now)

      assert Repo.get!(Request, request.id).last_error_code == "stale_reservation_recovered"
    end
  end

  describe "attempt ownership" do
    test "a dispatched attempt records the incarnation this instance publishes" do
      instance = start_instance!(:absent_recovery_ownership)
      setup = accounting_setup()

      {:ok, reserved} =
        Accounting.reserve(
          setup.auth,
          setup.model,
          %{"model" => setup.model.exposed_model_id, "stream" => true, "max_output_tokens" => 10},
          %{correlation_id: unique_correlation_id(), transport: "http_sse"}
        )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      assert attempt.owner_instance_id == instance.node_name
      assert attempt.owner_instance_boot_id == instance.boot_id

      # The recorded owner and the published row name the same VM. That link is
      # what the recovery join depends on, and nothing else in the pass restores
      # it if the two ever disagree.
      published = Repo.get!(Instance, instance.instance_id)
      assert published.node_name == attempt.owner_instance_id
      assert published.boot_id == attempt.owner_instance_boot_id
    end
  end

  # A VM start mints one incarnation and the real heartbeat publishes it. The
  # attempts below take their owner from that same identity through ordinary
  # dispatch, so nothing in these tests supplies the ownership it then asserts.
  defp start_instance!(name) do
    _boot_id = Identity.mint_boot_id!()
    identity = InstancePresence.local_identity()

    pid =
      start_supervised!(
        {InstanceHeartbeat, enabled: true, interval_ms: :timer.minutes(5), name: name},
        id: name
      )

    # The publish runs in the process's own continue, so one synchronous state
    # read is enough to know it has happened; no timer is waited out.
    _state = :sys.get_state(pid)

    assert %Instance{} = Repo.get(Instance, identity.instance_id)

    identity
  end

  defp end_instance!(name), do: :ok = stop_supervised!(name)

  defp dispatch_open_turn!(setup, dispatched_at, attempt_attrs \\ %{}) do
    {:ok, reserved} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "stream" => true, "max_output_tokens" => 10},
        %{correlation_id: unique_correlation_id(), now: dispatched_at, transport: "http_sse"}
      )

    {:ok, attempt} =
      Accounting.create_attempt(
        reserved.request,
        setup.assignment,
        Map.put(attempt_attrs, :now, dispatched_at)
      )

    session = session_row(setup, dispatched_at)
    turn = turn_row(session, reserved.request, attempt, dispatched_at)

    %{request: reserved.request, attempt: attempt, session: session, turn: turn}
  end

  # The session carries no owner lease, so the request is not an active runtime
  # turn held by another replica; the recovery pass may reach it.
  defp session_row(setup, started_at) do
    %CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: started_at,
      updated_at: started_at
    }
    |> Repo.insert!()
  end

  defp turn_row(session, request, attempt, started_at) do
    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "http_sse",
      status: CodexTurn.in_progress_status(),
      final_attempt_id: attempt.id,
      started_at: started_at,
      created_at: started_at,
      updated_at: started_at
    }
    |> Repo.insert!()
  end

  defp ledger_kinds(request) do
    request.id
    |> Accounting.list_ledger_entries_for_request()
    |> Enum.map(& &1.entry_kind)
    |> Enum.sort()
  end

  defp unique_correlation_id, do: "corr-absent-#{System.unique_integer([:positive])}"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
