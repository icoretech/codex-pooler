defmodule CodexPooler.Accounting.ReportingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.Reporting
  alias CodexPooler.Repo

  test "reporting consumption totals exclude usage_unknown settlement estimates" do
    pool = pool_fixture(%{slug: "reporting-known-only", name: "Reporting Known Only"})
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    started_at = ~U[2026-01-10 11:00:00.000000Z]
    ended_at = ~U[2026-01-10 12:00:00.000000Z]
    occurred_at = ~U[2026-01-10 11:30:00.000000Z]

    insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
      total_tokens: 100,
      input_tokens: 60,
      cached_input_tokens: 20,
      output_tokens: 30,
      reasoning_tokens: 10,
      estimated_cost_micros: 1_500_000,
      settled_cost_micros: 700_000
    })

    insert_settlement!(pool, api_key, assignment, identity, occurred_at, %{
      usage_status: "usage_unknown",
      total_tokens: 20_000,
      input_tokens: 12_000,
      cached_input_tokens: 4_000,
      output_tokens: 6_000,
      reasoning_tokens: 2_000,
      estimated_cost_micros: 200_000_000,
      settled_cost_micros: 90_000_000
    })

    assert Reporting.token_totals_by_pool_ids([pool.id], started_at, ended_at) == %{
             pool.id => 100
           }

    assert Reporting.token_totals_by_upstream_identity_ids([identity.id], started_at, ended_at) ==
             %{identity.id => 100}

    assert Reporting.token_usage_by_pool_ids([pool.id], started_at, ended_at) == %{
             pool.id => %{
               cached_input_tokens: 20,
               input_tokens: 60,
               output_tokens: 30,
               reasoning_tokens: 10,
               total_tokens: 100
             }
           }

    settlements = Reporting.settlements_for_pool_ids([pool.id], started_at, ended_at)

    assert Enum.sum(Enum.map(settlements, & &1.request_count)) == 2
    assert Enum.sum(Enum.map(settlements, & &1.total_tokens)) == 100
    assert Enum.sum(Enum.map(settlements, & &1.input_tokens)) == 60
    assert Enum.sum(Enum.map(settlements, & &1.cached_input_tokens)) == 20
    assert Enum.sum(Enum.map(settlements, & &1.output_tokens)) == 30
    assert Enum.sum(Enum.map(settlements, & &1.reasoning_tokens)) == 10
    assert sum_decimal_integer(settlements, :estimated_cost_micros) == 1_500_000
    assert sum_decimal_integer(settlements, :settled_cost_micros) == 700_000
  end

  defp insert_settlement!(pool, api_key, assignment, identity, occurred_at, attrs) do
    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "reporting-known-only-#{System.unique_integer([:positive])}"
      })
      |> set_request_time!(occurred_at)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(occurred_at)

    attrs =
      Map.merge(
        %{
          attempt_id: attempt.id,
          pool_upstream_assignment_id: assignment.id,
          upstream_identity_id: identity.id
        },
        attrs
      )

    request
    |> ledger_entry_fixture(attrs)
    |> set_ledger_time!(occurred_at)
  end

  defp set_request_time!(request, timestamp) do
    request
    |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp set_attempt_time!(attempt, timestamp) do
    attempt
    |> Ecto.Changeset.change(%{started_at: timestamp, completed_at: timestamp, latency_ms: 1_000})
    |> Repo.update!()
  end

  defp set_ledger_time!(ledger_entry, timestamp) do
    ledger_entry
    |> Ecto.Changeset.change(%{occurred_at: timestamp, created_at: timestamp})
    |> Repo.update!()
  end

  defp sum_decimal_integer(rows, field) do
    rows
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> Decimal.to_integer()
  end
end
