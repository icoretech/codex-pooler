defmodule CodexPooler.Gateway.Persistence.SessionReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    CodexTurn,
    SessionReadModel
  }

  alias CodexPooler.Repo

  describe "reporting projections" do
    test "projects request turns and pool-level session/turn summaries" do
      now = usec(~U[2026-06-08 09:30:00Z])
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      %{assignment: assignment} = upstream_assignment_fixture(pool)

      session =
        session_fixture(pool, api_key, assignment, now, %{
          owner_lease_expires_at: DateTime.add(now, 60, :second)
        })

      request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          correlation_id: "gateway-reporting-turn",
          status: "failed"
        })

      attempt = attempt_fixture(request, assignment, %{status: "failed"})

      turn =
        turn_fixture(session, request, attempt, now, %{
          status: "failed",
          error_code: "owner_unavailable",
          completed_at: DateTime.add(now, 10, :second)
        })

      request_id = request.id

      assert %{^request_id => projected_turn} =
               SessionReadModel.request_turns_by_request_ids([request_id, "not-a-uuid"])

      assert projected_turn.id == turn.id
      assert projected_turn.codex_session_id == session.id
      assert projected_turn.status == "failed"
      assert projected_turn.error_code == "owner_unavailable"
      assert projected_turn.final_attempt_id == attempt.id
      assert projected_turn.created_at == turn.created_at
      assert projected_turn.updated_at == turn.updated_at
      assert projected_turn.completed_at == turn.completed_at

      assert SessionReadModel.request_turns_by_request_ids(:invalid) == %{}
      assert SessionReadModel.active_session_count_for_pool_ids([pool.id, "not-a-uuid"]) == 1
      assert SessionReadModel.active_session_count_for_pool_ids(:invalid) == 0

      assert [%{status: "failed"}] =
               SessionReadModel.turn_statuses_for_pool_ids(
                 [pool.id, "not-a-uuid"],
                 DateTime.add(now, -60, :second),
                 DateTime.add(now, 60, :second)
               )

      assert [] = SessionReadModel.turn_statuses_for_pool_ids(:invalid, now, now)
    end
  end

  describe "active_runtime_request?/2" do
    test "detects in-progress turns owned by session lease timestamps or active lease rows" do
      now = usec(~U[2026-06-08 10:00:00Z])
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      %{assignment: assignment} = upstream_assignment_fixture(pool)

      session_with_owner_timestamp =
        session_fixture(pool, api_key, assignment, now, %{
          owner_lease_expires_at: DateTime.add(now, 60, :second)
        })

      timestamp_request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          correlation_id: "active-runtime-owner-timestamp",
          status: "in_progress",
          completed_at: nil,
          response_status_code: nil
        })

      timestamp_attempt =
        attempt_fixture(timestamp_request, assignment, %{status: "in_progress", completed_at: nil})

      turn_fixture(session_with_owner_timestamp, timestamp_request, timestamp_attempt, now, status: "in_progress")

      session_with_active_lease =
        session_fixture(pool, api_key, assignment, now, %{
          owner_lease_expires_at: DateTime.add(now, -1, :second)
        })

      lease_request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          correlation_id: "active-runtime-lease-row",
          status: "in_progress",
          completed_at: nil,
          response_status_code: nil
        })

      lease_attempt =
        attempt_fixture(lease_request, assignment, %{status: "in_progress", completed_at: nil})

      turn_fixture(session_with_active_lease, lease_request, lease_attempt, now, status: "in_progress")

      lease_fixture(
        session_with_active_lease,
        pool,
        api_key,
        assignment,
        now,
        DateTime.add(now, 60, :second)
      )

      expired_session =
        session_fixture(pool, api_key, assignment, now, %{
          owner_lease_expires_at: DateTime.add(now, -1, :second)
        })

      expired_request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          correlation_id: "inactive-runtime-expired",
          status: "in_progress",
          completed_at: nil,
          response_status_code: nil
        })

      expired_attempt =
        attempt_fixture(expired_request, assignment, %{status: "in_progress", completed_at: nil})

      turn_fixture(expired_session, expired_request, expired_attempt, now, status: "in_progress")

      assert SessionReadModel.active_runtime_request?(timestamp_request, now)
      assert SessionReadModel.active_runtime_request?(lease_request.id, now)
      refute SessionReadModel.active_runtime_request?(expired_request.id, now)
    end
  end

  defp session_fixture(pool, api_key, assignment, now, attrs) do
    now = usec(now)

    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: Map.get(attrs, :session_key, "session-#{System.unique_integer([:positive])}"),
      pool_upstream_assignment_id: assignment.id,
      status: Map.get(attrs, :status, "active"),
      owner_instance_id: Map.get(attrs, :owner_instance_id, "gateway-node"),
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: Map.get(attrs, :owner_lease_expires_at),
      last_heartbeat_at: now,
      disconnected_at: Map.get(attrs, :disconnected_at),
      closed_at: Map.get(attrs, :closed_at),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
    |> Repo.insert!()
  end

  defp turn_fixture(session, request, attempt, now, attrs) do
    attrs = Map.new(attrs)
    started_at = attrs |> Map.get(:started_at, DateTime.add(now, -30, :second)) |> usec()

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: Map.get(attrs, :turn_sequence, 1),
      transport_kind: Map.get(attrs, :transport_kind, request.transport),
      status: Map.get(attrs, :status, "succeeded"),
      error_code: Map.get(attrs, :error_code),
      first_visible_output_at: Map.get(attrs, :first_visible_output_at),
      final_attempt_id: attempt.id,
      started_at: started_at,
      completed_at: Map.get(attrs, :completed_at),
      created_at: started_at,
      updated_at: started_at
    }
    |> Repo.insert!()
  end

  defp lease_fixture(session, pool, api_key, assignment, now, expires_at) do
    now = usec(now)
    expires_at = usec(expires_at)

    %BridgeOwnerLease{}
    |> BridgeOwnerLease.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      pool_upstream_assignment_id: assignment.id,
      owner_instance_id: session.owner_instance_id,
      lease_token: Ecto.UUID.generate(),
      status: "active",
      acquired_at: now,
      renewed_at: now,
      expires_at: expires_at,
      metadata: %{"source" => "session_read_model_test"},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp usec(%DateTime{} = timestamp) do
    %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
  end
end
