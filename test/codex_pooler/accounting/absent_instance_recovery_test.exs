defmodule CodexPooler.Accounting.AbsentInstanceRecoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  describe "recover_absent_instance_attempts/2" do
    test "settles an attempt whose owning instance stopped reporting and releases the reservation" do
      context =
        open_stream_context(owner_reported_at: minutes_ago(10), dispatched_at: minutes_ago(10))

      %{
        setup: setup,
        now: now,
        request: request,
        attempt: attempt,
        turn: turn,
        instance_id: instance_id
      } = context

      assignment_before = Repo.get!(PoolUpstreamAssignment, setup.assignment.id)

      assert {:ok, %{absent_instance_attempts_recovered: 1}} =
               Accounting.recover_absent_instance_attempts(now)

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
               owner_instance_id: ^instance_id,
               completed_at: %DateTime{}
             } = Repo.reload!(attempt)

      assert %CodexTurn{status: "interrupted", error_code: "absent_instance_recovered"} =
               Repo.reload!(turn)

      assert request.id
             |> Accounting.list_ledger_entries_for_request()
             |> Enum.map(& &1.entry_kind)
             |> Enum.sort() == ["release", "reservation", "settlement"]

      # A recovery is our own lifecycle event: the upstream said nothing at all,
      # so its assignment must come out of the pass untouched.
      assert Repo.get!(PoolUpstreamAssignment, setup.assignment.id) == assignment_before

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)
    end

    test "leaves an attempt owned by a live instance alone" do
      %{now: now, request: request, attempt: attempt} =
        open_stream_context(owner_reported_at: :now, dispatched_at: minutes_ago(10))

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"

      assert request.id
             |> Accounting.list_ledger_entries_for_request()
             |> Enum.map(& &1.entry_kind) == ["reservation"]
    end

    test "leaves an attempt whose instance reported inside the liveness window alone" do
      %{now: now, request: request, attempt: attempt} =
        open_stream_context(
          owner_reported_at: DateTime.add(DateTime.utc_now(), -30, :second),
          dispatched_at: minutes_ago(10)
        )

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
    end

    test "leaves an instance that never published presence to the six-hour sweep" do
      %{now: now, request: request, attempt: attempt} =
        open_stream_context(owner_reported_at: :never, dispatched_at: hours_ago(7))

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"

      assert {:ok, %{stale_reservations_settled: 1}} = Accounting.recover_stale_reservations(now)

      assert %Request{status: "failed", last_error_code: "stale_reservation_recovered"} =
               Repo.get!(Request, request.id)

      assert Repo.reload!(attempt).status == "failed"
    end

    test "an attempt with no recorded owner is out of reach and stays with the six-hour sweep" do
      %{now: now, request: request, attempt: attempt} =
        open_stream_context(owner_reported_at: minutes_ago(10), dispatched_at: hours_ago(7))

      attempt
      |> Ecto.Changeset.change(%{owner_instance_id: nil})
      |> Repo.update!()

      assert {:ok, %{absent_instance_attempts_recovered: 0}} =
               Accounting.recover_absent_instance_attempts(now)

      assert Repo.get!(Request, request.id).status == "in_progress"

      assert {:ok, %{stale_reservations_settled: 1}} = Accounting.recover_stale_reservations(now)

      assert Repo.get!(Request, request.id).last_error_code == "stale_reservation_recovered"
    end
  end

  describe "attempt ownership" do
    test "a dispatched attempt records the instance that created it" do
      setup = accounting_setup()

      {:ok, reserved} =
        Accounting.reserve(
          setup.auth,
          setup.model,
          %{"model" => setup.model.exposed_model_id, "stream" => true, "max_output_tokens" => 10},
          %{correlation_id: unique_correlation_id(), transport: "http_sse"}
        )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      assert attempt.owner_instance_id == InstancePresence.local_instance_id()
    end
  end

  defp open_stream_context(opts) do
    setup = accounting_setup()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    dispatched_at = Keyword.fetch!(opts, :dispatched_at)
    instance_id = "codex_pooler@10.0.0.#{System.unique_integer([:positive])}"

    publish_presence(instance_id, Keyword.fetch!(opts, :owner_reported_at), now)

    {:ok, reserved} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "stream" => true, "max_output_tokens" => 10},
        %{correlation_id: unique_correlation_id(), now: dispatched_at, transport: "http_sse"}
      )

    {:ok, attempt} =
      Accounting.create_attempt(reserved.request, setup.assignment, %{
        now: dispatched_at,
        owner_instance_id: instance_id
      })

    session = session_row(setup, dispatched_at)
    turn = turn_row(session, reserved.request, attempt, dispatched_at)

    %{
      setup: setup,
      now: now,
      instance_id: instance_id,
      request: reserved.request,
      attempt: attempt,
      session: session,
      turn: turn
    }
  end

  defp publish_presence(_instance_id, :never, _now), do: :ok

  defp publish_presence(instance_id, :now, now) do
    {:ok, _presence} = InstancePresence.record_heartbeat(instance_id, now)
    :ok
  end

  defp publish_presence(instance_id, %DateTime{} = reported_at, _now) do
    {:ok, _presence} = InstancePresence.record_heartbeat(instance_id, reported_at)
    :ok
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

  defp unique_correlation_id, do: "corr-absent-#{System.unique_integer([:positive])}"

  defp minutes_ago(minutes),
    do: DateTime.utc_now() |> DateTime.add(-minutes, :minute) |> DateTime.truncate(:microsecond)

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours, :hour) |> DateTime.truncate(:microsecond)
end
