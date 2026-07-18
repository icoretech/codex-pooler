defmodule CodexPooler.Accounting.ObservatoryThroughputTrendTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.Repo

  test "throughput trend compares p50 rates across exact window halves" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-observatory-throughput"})
    upper_bound = ~U[2026-07-17 12:00:00Z]
    principal = dashboard_principal(pool, api_key)

    samples = [
      {~U[2026-07-17 11:05:00Z], 10},
      {~U[2026-07-17 11:15:00Z], 20},
      {~U[2026-07-17 11:25:00Z], 90},
      {~U[2026-07-17 11:30:00Z], 30},
      {~U[2026-07-17 11:40:00Z], 60},
      {~U[2026-07-17 11:50:00Z], 120}
    ]

    Enum.each(samples, fn {timestamp, tokens} ->
      request = timed_request(pool, api_key, model, timestamp)
      attempt = timed_attempt(request, assignment, timestamp)

      ledger_entry_fixture(request, %{
        attempt_id: attempt.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        total_tokens: tokens,
        occurred_at: usec(timestamp),
        created_at: usec(timestamp),
        details: %{"pricing_status" => "priced"}
      })
    end)

    assert {:ok, projection} = Observatory.read(principal, "1h", as_of: upper_bound)

    assert projection.performance.throughput_tokens_per_second.p50 == 45.0

    assert projection.trends.throughput == %{
             previous: 20.0,
             current: 60.0,
             delta: 200.0
           }

    refute inspect(projection) =~ ~r/(NaN|Infinity)/
  end

  defp timed_request(pool, api_key, model, timestamp) do
    timestamp = usec(timestamp)

    %{pool: pool, api_key: api_key}
    |> request_fixture(%{model_id: model.id, status: "succeeded"})
    |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp timed_attempt(request, assignment, timestamp) do
    timestamp = usec(timestamp)

    request
    |> attempt_fixture(assignment, %{latency_ms: 1_000})
    |> Ecto.Changeset.change(%{started_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp dashboard_principal(pool, api_key) do
    DashboardPrincipal.new(%{
      api_key_id: api_key.id,
      pool_id: pool.id,
      display_name: api_key.display_name,
      key_prefix: api_key.key_prefix
    })
  end

  defp dashboard_api_key_fixture(pool) do
    %{api_key: api_key} = active_api_key_fixture(pool)

    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp usec(timestamp), do: %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
end
