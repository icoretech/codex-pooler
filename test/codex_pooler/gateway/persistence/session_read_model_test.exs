defmodule CodexPooler.Gateway.Persistence.SessionReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.Request

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

    test "turn statuses stay linear in the window with missing and fresh planner statistics" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      other_pool = pool_fixture()
      %{assignment: assignment} = upstream_assignment_fixture(pool)
      session = session_fixture(pool, api_key, assignment, now, %{owner_lease_expires_at: DateTime.add(now, 60, :second)})
      # Small tables are the ones the planner mis-sizes: with missing statistics, the
      # old join rescanned the Pools' requests for every turn at 300 and 500 turns.
      count = 500
      insert_turn_history!(pool, api_key, session, count, now)

      for statistics <- [:missing, :fresh] do
        put_statistics!(statistics)

        {rows, queries} =
          capture_queries(fn -> SessionReadModel.turn_statuses_for_pool_ids([pool.id, other_pool.id], DateTime.add(now, -7, :day), now) end)

        assert length(rows) == count
        assert [{query, params}] = Enum.filter(queries, fn {query, _params} -> String.contains?(query, "\"codex_turns\"") end)

        %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params)
        handled = handled_rows(explain["Plan"])

        # A scan of the window and one request probe per turn; a rescan per turn is count^2 / 2.
        assert handled <= 6 * count, "turn statuses handled #{handled} plan rows for #{count} window turns with #{statistics} statistics: #{inspect(explain)}"
      end
    end
  end

  # Turns 10 s apart, each on its own request, all inside the window; the seed
  # request has no turn.
  defp insert_turn_history!(pool, api_key, session, count, now) do
    seed = request_fixture(%{pool: pool, api_key: api_key})
    request_fields = Request.__schema__(:fields)

    requests =
      for ordinal <- 1..count do
        admitted_at = DateTime.add(now, -10 * ordinal, :second)
        seed |> Map.take(request_fields) |> Map.merge(%{id: Ecto.UUID.generate(), correlation_id: "turn-plan-#{System.unique_integer([:positive])}", admitted_at: admitted_at})
      end

    Repo.insert_all(Request, requests)

    turns =
      requests
      |> Enum.with_index(1)
      |> Enum.map(fn {request, ordinal} ->
        %{
          id: Ecto.UUID.generate(),
          codex_session_id: session.id,
          request_id: request.id,
          turn_sequence: ordinal,
          transport_kind: "http_sse",
          status: "succeeded",
          started_at: request.admitted_at,
          completed_at: request.admitted_at,
          created_at: request.admitted_at,
          updated_at: request.admitted_at
        }
      end)

    Repo.insert_all(CodexTurn, turns)
  end

  # Missing: what the planner sees before a table's first ANALYZE, in a fresh
  # database or right after a bulk load.
  defp put_statistics!(:missing) do
    for table <- ["requests", "codex_turns"] do
      Repo.query!("SELECT pg_clear_relation_stats('public', $1)", [table])
      Repo.query!("SELECT pg_clear_attribute_stats('public', $1, attname, false) FROM pg_attribute WHERE attrelid = $1::text::regclass AND attnum > 0 AND NOT attisdropped", [table])
    end

    assert %{rows: [[0, [-1.0, -1.0]]]} =
             Repo.query!("SELECT (SELECT count(*) FROM pg_stats WHERE schemaname = 'public' AND tablename IN ('requests', 'codex_turns')), array_agg(reltuples) FROM pg_class WHERE oid IN ('public.requests'::regclass, 'public.codex_turns'::regclass)")
  end

  defp put_statistics!(:fresh) do
    Repo.query!("ANALYZE requests")
    Repo.query!("ANALYZE codex_turns")
  end

  # Every row each plan node handled: the rows it returned and the rows its filters removed, over all its loops.
  # A bitmap index scan's rows are index entries, dead ones included (rolled-back rows of earlier tests in the
  # partition); the bitmap heap scan above it counts the live rows, so the index side is left out.
  defp handled_rows(%{"Node Type" => "Bitmap Index Scan"}), do: 0

  defp handled_rows(node) do
    own = (node["Actual Rows"] + Map.get(node, "Rows Removed by Filter", 0) + Map.get(node, "Rows Removed by Join Filter", 0)) * node["Actual Loops"]
    own + (node |> Map.get("Plans", []) |> Enum.sum_by(&handled_rows/1))
  end

  # Every query the call makes from this process, with its parameters.
  defp capture_queries(fun) do
    handler = {__MODULE__, :capture_queries, self()}
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:captured_query, metadata.query, metadata.params})
        end,
        nil
      )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain_queries([])}
  end

  defp drain_queries(acc) do
    receive do
      {:captured_query, query, params} -> drain_queries([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
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
