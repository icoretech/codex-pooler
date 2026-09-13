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
    rows = RequestHealth.recent_request_event_rows(context.scope, context.identity, 10)

    assert Enum.map(rows, & &1.id) == Enum.map(expected, & &1.id)
    assert Enum.find(rows, &(&1.id == retried.id)).attempt_count == 3
    assert Enum.find(rows, &(&1.id == failed.id)).attempt_count == 1

    assert [first] =
             RequestHealth.recent_request_event_rows(context.scope, context.identity.id, 1)

    assert first.id == hd(expected).id
    assert RequestHealth.recent_request_event_rows(context.scope, nil, 10) == []
    assert RequestHealth.recent_request_event_rows(context.scope, context.identity, 0) == []
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
    assert RequestHealth.recent_request_event_rows(admin_scope, context.identity, 10) == []
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

    assert [row] = RequestHealth.recent_request_event_rows(admin_scope, context.identity, 10)
    assert row.id == visible.id
  end

  test "sparse recent failures do not aggregate the full attempt history", context do
    now = DateTime.utc_now()
    request = insert_request(context, "failed", now)
    attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^request.id)
    request_fields = Request.__schema__(:fields)
    attempt_fields = Attempt.__schema__(:fields)

    for batch <- 0..9 do
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
          |> Map.merge(%{id: Ecto.UUID.generate(), request_id: request.id})
        end

      Repo.insert_all(Attempt, attempts)
    end

    Repo.query!("ANALYZE requests")
    Repo.query!("ANALYZE attempts")
    {rows, query, params} = capture_event_query(context)
    assert length(rows) == 5

    %{rows: [[[explain]]]} =
      Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, params)

    attempt_reads =
      explain["Plan"]
      |> plan_nodes()
      |> Enum.filter(&(&1["Relation Name"] == "attempts"))
      |> Enum.sum_by(fn node ->
        (node["Actual Rows"] + Map.get(node, "Rows Removed by Filter", 0)) * node["Actual Loops"]
      end)

    assert attempt_reads < 1000,
           "five sparse events read #{attempt_reads} attempt tuples across 10,001 attempts: #{inspect(explain)}"
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
      rows = RequestHealth.recent_request_event_rows(context.scope, context.identity, 5)
      assert_received {:event_query, query, params}
      {rows, query, params}
    after
      :telemetry.detach(handler)
    end
  end

  defp plan_nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]

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
