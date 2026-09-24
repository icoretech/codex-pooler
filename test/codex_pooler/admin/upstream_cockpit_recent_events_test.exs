defmodule CodexPooler.Admin.UpstreamCockpitRecentEventsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics.RequestHealth
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.Assignments.PoolAssignments

  setup do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug(), name: "Visible pool"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    %{
      scope: scope,
      owner: owner,
      pool: pool,
      api_key: api_key,
      identity: identity,
      assignment: assignment
    }
  end

  test "keeps old events, counts every upstream attempt, deduplicates and orders ties", context do
    %{assignment: other_assignment} = upstream_assignment_fixture(context.pool)
    old = DateTime.add(DateTime.utc_now(), -30, :day)
    failed = insert_request(context, "failed", old)
    retried = insert_request(context, "succeeded", old)
    attempt_fixture(retried, other_assignment, %{attempt_number: 2})
    attempt_fixture(retried, context.assignment, %{attempt_number: 3})

    for offset <- 1..20 do
      insert_request(context, "succeeded", DateTime.add(old, offset, :day))
    end

    unrelated = request_fixture(context, %{status: "failed"})
    attempt_fixture(unrelated, other_assignment)
    request_fixture(context, %{status: "failed"})

    expected = Enum.sort_by([failed, retried], & &1.id, :desc)
    # The walk runs out of the identity's few attempts: the whole history was searched.
    assert %{rows: rows, searched_attempt_limit: nil} = RequestHealth.recent_request_events(context.scope, context.identity, 10)

    assert Enum.map(rows, & &1.id) == Enum.map(expected, & &1.id)
    assert Enum.find(rows, &(&1.id == retried.id)).attempt_count == 3
    assert Enum.find(rows, &(&1.id == failed.id)).attempt_count == 1

    assert [first] =
             event_rows(context.scope, context.identity.id, 1)

    assert first.id == hd(expected).id

    # The identity's two newest attempts are both on the retried request: a walk
    # of two finds one request and must go further to find the second.
    assert Enum.map(event_rows(context.scope, context.identity, 2), & &1.id) == Enum.map(expected, & &1.id)
    assert event_rows(context.scope, nil, 10) == []
    assert event_rows(context.scope, context.identity, 0) == []
  end

  test "requires visible pool membership even for the same upstream identity", context do
    %{user: admin} =
      operator_fixture(context.scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    admin_scope = Scope.for_user(admin)
    visible = insert_request(context, "rejected", DateTime.utc_now())
    assert event_rows(admin_scope, context.identity, 10) == []
    operator_pool_assignment_fixture(admin, context.pool, created_by_user_id: context.owner.id)

    {:ok, hidden_pool} =
      Pools.create_pool(context.scope, %{slug: unique_slug(), name: "Hidden pool"})

    %{api_key: hidden_key} = active_api_key_fixture(hidden_pool)

    {:ok, hidden_assignment} =
      PoolAssignments.create_pool_assignment(
        hidden_pool,
        context.identity,
        %{assignment_label: "Hidden assignment"}
      )

    insert_request(
      %{context | pool: hidden_pool, api_key: hidden_key, assignment: hidden_assignment},
      "failed",
      DateTime.utc_now()
    )

    assert [row] = event_rows(admin_scope, context.identity, 10)
    assert row.id == visible.id
  end

  test "sparse recent failures do not aggregate the full attempt history", context do
    now = DateTime.utc_now()

    %{identity: other_identity, assignment: other_assignment} =
      upstream_assignment_fixture(context.pool)

    target_requests =
      for offset <- 1..5 do
        insert_request(context, "failed", DateTime.add(now, -20_000 - offset, :second))
      end

    request = hd(target_requests)
    attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^request.id)
    request_fields = Request.__schema__(:fields)
    attempt_fields = Attempt.__schema__(:fields)

    # Two batches already exceed the tuple-read budget; a full-history aggregate must fail it.
    for batch <- 0..1 do
      requests =
        for offset <- 1..1000 do
          ordinal = batch * 1000 + offset

          request
          |> Map.take(request_fields)
          |> Map.merge(%{
            id: Ecto.UUID.generate(),
            correlation_id: "scale-#{System.unique_integer([:positive])}",
            status: if(rem(ordinal, 100) == 0, do: "failed", else: "succeeded"),
            admitted_at: DateTime.add(now, -ordinal, :second)
          })
        end

      Repo.insert_all(Request, requests)

      attempts =
        for request <- requests do
          attempt
          |> Map.take(attempt_fields)
          |> Map.merge(%{
            id: Ecto.UUID.generate(),
            request_id: request.id,
            upstream_identity_id: other_identity.id,
            pool_upstream_assignment_id: other_assignment.id
          })
        end

      Repo.insert_all(Attempt, attempts)
    end

    analyze_fixture_tables!()
    {rows, query, params} = capture_event_query(context)
    assert Enum.map(rows, & &1.id) == Enum.map(target_requests, & &1.id)

    %{rows: [[[explain]]]} =
      Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, params)

    attempt_reads = attempt_reads(explain)

    assert attempt_reads < 1000,
           "five sparse events read #{attempt_reads} attempt tuples across 2,005 attempts: #{inspect(explain)}"
  end

  # Each attempt starts when its request is admitted, ten seconds apart, as in
  # production (no assignment has two attempts with one start). With one shared
  # start the walk met the tied attempts in heap order, so the tuples it read
  # before the fifth event followed where the test database placed the rows:
  # 797 alone, 1,105 in a full run, 3,965 with the failures stored last
  # (findings#206 row 206-440). Every query of the call is measured, the second
  # walk included.
  test "dense identity history keeps recent-event probes bounded", context do
    now = DateTime.utc_now()
    seed_request = insert_request(context, "failed", now)
    seed_attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^seed_request.id)

    # Twenty failures among 2,000 requests: a probe that reads the whole history fails the budget.
    history =
      insert_scaled!(seed_request, seed_attempt, context.assignment, 2_000, fn ordinal ->
        %{status: if(rem(ordinal, 100) == 0, do: "failed", else: "succeeded"), admitted_at: DateTime.add(now, -10 * ordinal, :second)}
      end)

    analyze_fixture_tables!()

    expected = [seed_request | history |> Enum.filter(&(&1.status == "failed")) |> Enum.take(4)]
    {rows, queries} = capture_event_queries(fn -> event_rows(context.scope, context.identity, 5) end)
    assert Enum.map(rows, & &1.id) == Enum.map(expected, & &1.id)

    probes =
      for {query, params} <- queries, String.contains?(query, "\"attempts\"") do
        %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, params)
        {attempt_reads(explain), explain}
      end

    for {attempt_reads, explain} <- probes do
      assert attempt_reads < 1000,
             "a probe for five dense events read #{attempt_reads} attempt tuples across 2,001 attempts: #{inspect(explain)}"
    end

    # The first walk, the second walk from the fifth admission, and the attempt counts.
    assert length(probes) == 3
  end

  # A healthy account with more attempts than the walk's window: without a
  # bound the walk reads every attempt of the assignment and probes each for a
  # retry, on every cockpit load (findings#206 row 206-441). The window is the
  # newest `event_walk_depth` attempts; the failure on its last attempt is
  # found, the two behind it are not, and the result says the search was cut.
  test "a healthy account deeper than the attempt window is walked only to the window and says so", context do
    depth = RequestHealth.event_walk_depth()
    now = DateTime.utc_now()
    seed_request = insert_request(context, "succeeded", now)
    seed_attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^seed_request.id)
    # The seed plus ordinals 1..depth-1 fill the window; ordinal depth is the first attempt behind it.
    failed_ordinals = [depth - 1, depth, depth + 500]

    history =
      insert_scaled!(seed_request, seed_attempt, context.assignment, depth + 500, fn ordinal ->
        %{status: if(ordinal in failed_ordinals, do: "failed", else: "succeeded"), admitted_at: DateTime.add(now, -10 * ordinal, :second)}
      end)

    analyze_fixture_tables!()

    last_in_window = Enum.at(history, depth - 2)
    assert last_in_window.status == "failed"

    {result, queries} = capture_event_queries(fn -> RequestHealth.recent_request_events(context.scope, context.identity, 5) end)
    assert %{rows: [%{id: found_id}], searched_attempt_limit: ^depth} = result
    assert found_id == last_in_window.id

    probes =
      for {query, params} <- queries, String.contains?(query, "\"attempts\"") do
        %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, params)
        {history_reads(explain), attempt_reads(explain), explain}
      end

    for {history_reads, attempt_reads, explain} <- probes do
      assert history_reads <= depth + 1,
             "a probe read #{history_reads} of the assignment's #{depth + 501} attempts, window #{depth}: #{inspect(explain)}"

      # The window and the attempt behind it, plus at most one retry probe for each window attempt.
      assert attempt_reads <= 2 * depth + 1, "a probe read #{attempt_reads} attempt tuples: #{inspect(explain)}"
    end

    # The walk, which meets the attempt behind its window itself, and the attempt counts.
    assert length(probes) == 2
  end

  # A busy account that went quiet: its own history is dense, so walking
  # `requests` newest first looks cheap to the planner, but every request other
  # accounts made since its last event is read and probed before the first of
  # its own (findings#206 row 206-385; 1.2M buffers for 30 quiet days on a
  # 1M-request rehearsal). The walk starts from the identity's own attempts.
  test "a dense identity that went quiet does not read the newer traffic of other identities", context do
    now = DateTime.utc_now()
    seed = insert_request(context, "failed", DateTime.add(now, -3, :day))
    seed_attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^seed.id)
    %{assignment: other_assignment} = upstream_assignment_fixture(context.pool)

    own =
      insert_scaled!(seed, seed_attempt, context.assignment, 1_000, fn ordinal ->
        %{status: if(rem(ordinal, 20) == 0, do: "failed", else: "succeeded"), admitted_at: DateTime.add(seed.admitted_at, -ordinal, :second)}
      end)

    _newer =
      insert_scaled!(seed, seed_attempt, other_assignment, 3_000, fn ordinal ->
        %{status: "succeeded", admitted_at: DateTime.add(now, -ordinal, :second)}
      end)

    analyze_fixture_tables!()

    expected =
      [seed | Enum.filter(own, &(&1.status == "failed"))]
      |> Enum.sort_by(&{DateTime.to_unix(&1.admitted_at, :microsecond), &1.id}, :desc)
      |> Enum.take(5)

    {rows, queries} = capture_event_queries(fn -> event_rows(context.scope, context.identity, 5) end)
    assert Enum.map(rows, & &1.id) == Enum.map(expected, & &1.id)
    assert Enum.all?(rows, &(&1.attempt_count == 1))

    request_reads =
      Enum.sum_by(queries, fn {query, params} ->
        %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params)

        explain["Plan"]
        |> plan_nodes()
        |> Enum.filter(&(&1["Relation Name"] == "requests"))
        |> Enum.sum_by(&((&1["Actual Rows"] + Map.get(&1, "Rows Removed by Filter", 0)) * &1["Actual Loops"]))
      end)

    assert request_reads < 1_000, "five events of a quiet identity read #{request_reads} request tuples behind 3,000 newer requests"
  end

  # The walk follows the identity's attempts, which start in a different order
  # than their requests were admitted when one waits longer before its first
  # attempt. The rows still rank by admission: the request admitted later wins
  # although its attempt started earlier.
  test "recent events rank by admission even when attempts started in another order", context do
    now = DateTime.utc_now()
    admitted_earlier = insert_request(context, "failed", DateTime.add(now, -10, :minute))
    admitted_later = insert_request(context, "failed", DateTime.add(now, -5, :minute))
    move_attempt_start!(admitted_earlier, DateTime.add(now, -1, :minute))
    move_attempt_start!(admitted_later, DateTime.add(now, -5, :minute))

    assert [%{id: first_id}] = event_rows(context.scope, context.identity, 1)
    assert first_id == admitted_later.id

    assert Enum.map(event_rows(context.scope, context.identity, 2), & &1.id) == [admitted_later.id, admitted_earlier.id]
  end

  defp event_rows(scope, identity, limit) do
    %{rows: rows} = RequestHealth.recent_request_events(scope, identity, limit)
    rows
  end

  defp move_attempt_start!(request, started_at) do
    {1, _} = Repo.update_all(from(attempt in Attempt, where: attempt.request_id == ^request.id), set: [started_at: started_at])
  end

  defp insert_scaled!(seed, seed_attempt, assignment, count, attrs_fun) do
    request_fields = Request.__schema__(:fields)
    attempt_fields = Attempt.__schema__(:fields)

    requests =
      for ordinal <- 1..count do
        seed
        |> Map.take(request_fields)
        |> Map.merge(%{id: Ecto.UUID.generate(), correlation_id: "quiet-scale-#{System.unique_integer([:positive])}"})
        |> Map.merge(attrs_fun.(ordinal))
      end

    requests |> Enum.chunk_every(1_000) |> Enum.each(&Repo.insert_all(Request, &1))

    requests
    |> Enum.map(fn request ->
      seed_attempt
      |> Map.take(attempt_fields)
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        request_id: request.id,
        upstream_identity_id: assignment.upstream_identity_id,
        pool_upstream_assignment_id: assignment.id,
        started_at: request.admitted_at
      })
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Attempt, &1))

    requests
  end

  # Every query the call makes, with its parameters, from this process.
  defp capture_event_queries(fun) do
    handler = {__MODULE__, :all, self()}
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:any_event_query, metadata.query, metadata.params})
        end,
        nil
      )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain_event_queries([])}
  end

  defp drain_event_queries(acc) do
    receive do
      {:any_event_query, query, params} -> drain_event_queries([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def handle_query(_event, _measurements, metadata, owner) do
    if self() == owner and String.contains?(metadata.query, "\"attempts\"") do
      send(owner, {:event_query, metadata.query, metadata.params})
    end
  end

  defp capture_event_query(context) do
    handler = {__MODULE__, self()}

    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_query/4,
        self()
      )

    try do
      rows = event_rows(context.scope, context.identity, 5)
      assert_received {:event_query, query, params}
      {rows, query, params}
    after
      :telemetry.detach(handler)
    end
  end

  # The walks are planned on the tables' statistics. A shared test database
  # can hold empty-table statistics (autovacuum after rolled-back sandbox rows
  # leaves `reltuples` at 0 over hundreds of pages), under which the walk's
  # per-attempt probes can take a skip-scanned index and time out; a running
  # install analyzes a table within seconds of its rows arriving (findings#206
  # row 206-500). The fixture is analyzed, and the statistics are asserted,
  # before a measured call.
  defp analyze_fixture_tables! do
    Repo.query!("ANALYZE requests")
    Repo.query!("ANALYZE attempts")

    assert %{rows: [[true]]} = Repo.query!("SELECT bool_and(reltuples > 0) FROM pg_class WHERE oid IN ('public.requests'::regclass, 'public.attempts'::regclass)")
  end

  defp plan_nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]

  # Attempt tuples every node of the plan read, subplan loops included.
  defp attempt_reads(explain) do
    explain["Plan"]
    |> plan_nodes()
    |> Enum.filter(&(&1["Relation Name"] == "attempts"))
    |> Enum.sum_by(&((&1["Actual Rows"] + Map.get(&1, "Rows Removed by Filter", 0)) * &1["Actual Loops"]))
  end

  # Attempt tuples every node of the plan read, except the per-request retry
  # probes: the rows read out of the assignment's history, however the planner
  # reached them.
  defp history_reads(explain) do
    explain["Plan"]
    |> plan_nodes()
    |> Enum.filter(&(&1["Relation Name"] == "attempts" and &1["Index Name"] != "attempts_request_number_uq"))
    |> Enum.sum_by(&((&1["Actual Rows"] + Map.get(&1, "Rows Removed by Filter", 0)) * &1["Actual Loops"]))
  end

  defp insert_request(context, status, admitted_at) do
    request =
      context
      |> request_fixture(%{status: status})
      |> Ecto.Changeset.change(admitted_at: admitted_at)
      |> Repo.update!()

    attempt_fixture(request, context.assignment)
    request
  end

  defp unique_slug, do: "recent-events-#{System.unique_integer([:positive])}"
end
