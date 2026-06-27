defmodule CodexPooler.Gateway.Persistence.SessionReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    SessionReadModel
  }

  alias CodexPooler.Repo

  describe "list_codex_sessions/2" do
    test "projects latest session, turn, attempt, lease, and alias state" do
      now = usec(~U[2026-06-08 09:00:00Z])
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      first = upstream_assignment_fixture(pool)
      second = upstream_assignment_fixture(pool)
      model = model_fixture(pool, %{exposed_model_id: "gpt-gateway-readmodel"})

      session =
        session_fixture(pool, api_key, first.assignment, now, %{
          session_key: "session-readmodel-primary",
          conversation_key: "conversation-readmodel-primary",
          owner_instance_id: "gateway-node-a",
          owner_lease_expires_at: DateTime.add(now, 120, :second)
        })

      earlier_request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          model_id: model.id,
          requested_model: model.exposed_model_id,
          correlation_id: "session-readmodel-earlier",
          status: "succeeded",
          transport: "websocket"
        })

      earlier_attempt = attempt_fixture(earlier_request, first.assignment)

      earlier_turn =
        turn_fixture(session, earlier_request, earlier_attempt, now, %{
          turn_sequence: 1,
          status: "succeeded",
          transport_kind: "websocket",
          started_at: DateTime.add(now, -120, :second),
          completed_at: DateTime.add(now, -100, :second)
        })

      latest_request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          model_id: model.id,
          requested_model: "gpt-gateway-readmodel-plus",
          correlation_id: "session-readmodel-latest",
          status: "failed",
          usage_status: "usage_unknown",
          transport: "websocket",
          last_error_code: nil,
          response_status_code: 502
        })

      _older_failed_attempt =
        attempt_fixture(latest_request, first.assignment, %{
          attempt_number: 1,
          status: "failed",
          network_error_code: "older_attempt_error"
        })

      latest_attempt =
        attempt_fixture(latest_request, second.assignment, %{
          attempt_number: 2,
          status: "failed",
          network_error_code: "latest_attempt_error"
        })

      latest_turn =
        turn_fixture(session, latest_request, latest_attempt, now, %{
          turn_sequence: 2,
          status: "failed",
          transport_kind: "websocket",
          started_at: DateTime.add(now, -30, :second),
          completed_at: DateTime.add(now, -10, :second)
        })

      lease_fixture(session, pool, api_key, first.assignment, now, DateTime.add(now, 90, :second))
      alias_fixture(session, pool, api_key, now, DateTime.add(now, 90, :second), "turn_state")
      alias_fixture(session, pool, api_key, now, DateTime.add(now, 90, :second), "session_header")

      alias_fixture(
        session,
        pool,
        api_key,
        now,
        DateTime.add(now, -1, :second),
        "previous_response_id",
        status: "expired"
      )

      _outside_model_session =
        session_with_request!(pool, api_key, first.assignment, now, %{
          session_key: "session-readmodel-outside-model",
          requested_model: "gpt-unrelated",
          status: "succeeded"
        })

      other_pool = pool_fixture()
      %{api_key: other_api_key} = active_api_key_fixture(other_pool)
      other_assignment = upstream_assignment_fixture(other_pool)

      _other_pool_session =
        session_with_request!(other_pool, other_api_key, other_assignment.assignment, now, %{
          session_key: "session-readmodel-other-pool",
          requested_model: "gpt-gateway-readmodel-plus",
          status: "succeeded"
        })

      result =
        SessionReadModel.list_codex_sessions(pool,
          limit: 5,
          filters: [
            api_key_id: api_key.id,
            upstream_identity_id: second.identity.id,
            model: "readmodel-plus",
            status: "failed",
            date_from: DateTime.add(now, -10, :second),
            date_to: DateTime.add(now, 10, :second)
          ]
        )

      assert result.total == 1
      assert result.limit == 5

      assert [
               %{
                 id: session_id,
                 api_key_display_name: "Gateway test key",
                 api_key_prefix: api_key_prefix,
                 session_key: "session-readmodel-primary",
                 conversation_key: "conversation-readmodel-primary",
                 pool_upstream_assignment_id: first_assignment_id,
                 upstream_identity_id: latest_upstream_identity_id,
                 requested_model: "gpt-gateway-readmodel-plus",
                 status: "active",
                 latest_turn_status: "failed",
                 latest_request_id: latest_request_id,
                 latest_request_status: "failed",
                 latest_error_code: "latest_attempt_error",
                 owner_instance_id: "gateway-node-a",
                 owner_lease_status: "active",
                 active_alias_count: 2
               }
             ] = result.items

      assert session_id == session.id
      assert api_key_prefix == api_key.key_prefix
      assert first_assignment_id == first.assignment.id
      assert latest_upstream_identity_id == second.identity.id
      assert latest_request_id == latest_request.id

      assert Enum.map(result.turns, & &1.id) == [latest_turn.id, earlier_turn.id]

      assert [
               %{
                 request_id: ^latest_request_id,
                 status: "failed",
                 error_code: "latest_attempt_error",
                 final_attempt_id: latest_attempt_id,
                 upstream_identity_id: latest_attempt_upstream_id,
                 pool_upstream_assignment_id: latest_attempt_assignment_id,
                 response_status_code: 502
               },
               %{
                 request_id: earlier_request_id,
                 status: "succeeded",
                 final_attempt_id: earlier_attempt_id
               }
             ] = result.turns

      assert latest_attempt_id == latest_attempt.id
      assert latest_attempt_upstream_id == second.identity.id
      assert latest_attempt_assignment_id == second.assignment.id
      assert earlier_request_id == earlier_request.id
      assert earlier_attempt_id == earlier_attempt.id
    end

    test "clamps limits and returns empty projections for invalid references" do
      assert %{items: [], turns: [], total: 0, limit: 1} =
               SessionReadModel.list_codex_sessions(:invalid, limit: 0)

      %{pool: pool} = active_api_key_fixture()

      assert %{limit: 100} = SessionReadModel.list_codex_sessions(pool, limit: 250)
      assert %{limit: 50} = SessionReadModel.list_codex_sessions(pool, limit: "not an integer")
      assert [] = SessionReadModel.list_codex_turns_for_sessions([])
      assert [] = SessionReadModel.list_codex_turns_for_sessions(:invalid)
    end
  end

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

      turn_fixture(session_with_owner_timestamp, timestamp_request, timestamp_attempt, now,
        status: "in_progress"
      )

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

      turn_fixture(session_with_active_lease, lease_request, lease_attempt, now,
        status: "in_progress"
      )

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

  defp session_with_request!(pool, api_key, assignment, now, attrs) do
    session =
      session_fixture(pool, api_key, assignment, now, %{
        session_key: Map.fetch!(attrs, :session_key),
        owner_lease_expires_at: DateTime.add(now, 60, :second)
      })

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: Map.fetch!(attrs, :requested_model),
        status: Map.get(attrs, :status, "succeeded"),
        correlation_id: "#{Map.fetch!(attrs, :session_key)}-request"
      })

    attempt = attempt_fixture(request, assignment)
    turn_fixture(session, request, attempt, now)
    session
  end

  defp session_fixture(pool, api_key, assignment, now, attrs) do
    now = usec(now)

    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: Map.get(attrs, :session_key, "session-#{System.unique_integer([:positive])}"),
      conversation_key: Map.get(attrs, :conversation_key),
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

  defp turn_fixture(session, request, attempt, now, attrs \\ %{}) do
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

  defp alias_fixture(session, pool, api_key, now, expires_at, alias_kind, attrs \\ []) do
    now = usec(now)
    expires_at = usec(expires_at)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      alias_kind: alias_kind,
      alias_hash: :crypto.hash(:sha256, "#{alias_kind}-#{System.unique_integer([:positive])}"),
      alias_preview: "#{alias_kind}:preview",
      status: Keyword.get(attrs, :status, "active"),
      expires_at: expires_at,
      last_seen_at: now,
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
