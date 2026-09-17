defmodule CodexPooler.Accounting.ContentionIndexPlanTest do
  @moduledoc false

  # The two contention indexes must be usable by the plans PostgreSQL really
  # builds for the queries the application really sends.
  #
  # The two Pooler-owned statements are captured from `[:codex_pooler, :repo,
  # :query]` while the application path runs, then planned with `GENERIC_PLAN`:
  # a prepared statement is planned once without parameter values, so a
  # partial-index predicate that arrives as a bind parameter cannot be proven
  # and the index is unusable.
  #
  # `enable_seqscan = off` only removes the whole-table alternative for a
  # fixture too small to make an index look cheap; it cannot make an unusable
  # index usable. No other planner setting is touched.

  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @api_key_index "ledger_entries_api_key_known_settlement_occurred_idx"
  @attempts_index "attempts_open_started_idx"

  setup do
    fixture = contention_fixture!()
    Repo.query!("ANALYZE ledger_entries, requests, attempts, upstream_identities")
    fixture
  end

  test "the api-key cost summary can use its partial index in a generic plan", %{
    pool: pool,
    api_key: api_key,
    as_of: as_of
  } do
    {result, queries} =
      capture_repo_queries(fn ->
        Accounting.build_api_key_self_usage(pool, api_key, as_of: as_of)
      end)

    assert {:ok, _usage} = result
    sql = single_query!(queries, &cost_summary_query?/1, "api-key cost summary")

    assert uses_index?(generic_plan!(sql), @api_key_index),
           "cost summary plan did not use #{@api_key_index}:\n#{sql}"
  end

  test "stale terminal attempt cleanup can use its partial index in a generic plan", %{
    as_of: as_of
  } do
    {result, queries} =
      capture_repo_queries(fn -> Accounting.recover_stale_reservations(as_of) end)

    assert {:ok, _summary} = result
    sql = single_query!(queries, &stale_attempts_query?/1, "stale terminal attempts")

    assert uses_index?(generic_plan!(sql), @attempts_index),
           "cleanup plan did not use #{@attempts_index}:\n#{sql}"
  end

  # `GENERIC_PLAN` leaves the parameters unbound, so the statement cannot go
  # through the extended protocol, which would demand a value per `$n`; the
  # simple protocol returns the plan document as text.
  defp generic_plan!(sql) do
    no_seqscan(fn ->
      %{rows: [[document]]} =
        Repo.query!("EXPLAIN (GENERIC_PLAN, FORMAT JSON) " <> sql, [], query_type: :text)

      [%{"Plan" => plan}] = CodexPooler.JSON.decode!(document)
      plan
    end)
  end

  defp no_seqscan(fun) do
    Repo.query!("SET LOCAL enable_seqscan = off")
    fun.()
  after
    Repo.query!("SET LOCAL enable_seqscan = on")
  end

  defp uses_index?(node, index_name) do
    node["Index Name"] == index_name or
      Enum.any?(Map.get(node, "Plans", []), &uses_index?(&1, index_name))
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo, do: send(test_pid, {handler_id, metadata.query})
        end,
        nil
      )

    try do
      {fun.(), drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp single_query!(queries, matcher, label) do
    case queries |> Enum.filter(matcher) |> Enum.uniq() do
      [sql] -> sql
      other -> flunk("expected exactly one #{label} query, got #{length(other)}")
    end
  end

  defp cost_summary_query?(sql) do
    String.contains?(sql, "ledger_entries") and String.contains?(sql, "settled_cost_micros") and
      String.contains?(sql, "usage_status")
  end

  defp stale_attempts_query?(sql) do
    String.contains?(sql, "FROM \"attempts\"") and String.contains?(sql, "ORDER BY") and
      String.contains?(sql, "started_at")
  end

  # A target api key with settlements inside and outside its rolling window, other
  # keys and pools carrying more ledger rows, and open attempts on terminal
  # requests next to non-stale and closed ones.
  defp contention_fixture! do
    as_of = ~U[2026-09-17 12:00:00.000000Z]
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment, identity: identity} = upstream_assignment_fixture(pool)
    auth = %{pool: pool, api_key: api_key}

    {:ok, _window} =
      EvidenceStore.record_evidence(
        identity,
        CodexPooler.QuotaEvidenceSupport.account_secondary_evidence("22", as_of),
        as_of
      )

    for day <- 0..9 do
      request = request_fixture(auth)

      ledger_entry_fixture(request, %{
        occurred_at: DateTime.add(as_of, -day * 86_400, :second),
        upstream_identity_id: identity.id,
        pool_upstream_assignment_id: assignment.id,
        settled_cost_micros: 1_500 + day,
        details: %{"settled_cost_micros" => 1_500 + day}
      })
    end

    other_pool = pool_fixture()
    %{api_key: other_key} = active_api_key_fixture(other_pool)

    %{assignment: other_assignment, identity: other_identity} =
      upstream_assignment_fixture(other_pool)

    other_auth = %{pool: other_pool, api_key: other_key}

    for day <- 0..39 do
      request = request_fixture(other_auth)

      entry_kind = if rem(day, 4) == 0, do: "reservation", else: "settlement"

      ledger_entry_fixture(request, %{
        entry_kind: entry_kind,
        usage_status: if(rem(day, 3) == 0, do: "usage_unknown", else: "usage_known"),
        occurred_at: DateTime.add(as_of, -day * 3_600, :second),
        upstream_identity_id: other_identity.id,
        pool_upstream_assignment_id: other_assignment.id,
        settled_cost_micros: 900 + day,
        details: %{"settled_cost_micros" => 900 + day}
      })
    end

    stale_started_at = DateTime.add(as_of, -12 * 3_600, :second)

    for n <- 1..4 do
      terminal_request = request_fixture(auth, %{status: "succeeded"})

      terminal_request
      |> attempt_fixture(assignment, %{status: "in_progress", completed_at: nil})
      |> Ecto.Changeset.change(%{started_at: DateTime.add(stale_started_at, -n, :second)})
      |> Repo.update!()

      request_fixture(auth, %{status: "succeeded"})
      |> attempt_fixture(assignment, %{status: "succeeded"})
    end

    for _n <- 1..4 do
      request_fixture(other_auth, %{status: "in_progress", completed_at: nil})
      |> attempt_fixture(other_assignment, %{status: "in_progress", completed_at: nil})
    end

    %{pool: pool, api_key: api_key, identity: identity, as_of: as_of}
  end
end
