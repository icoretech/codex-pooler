defmodule CodexPooler.Gateway.Persistence.SessionReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Persistence.{
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

  defp usec(%DateTime{} = timestamp) do
    %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
  end
end
