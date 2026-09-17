defmodule CodexPooler.Accounting.Usage.RollingCostSummaryParityTest do
  @moduledoc false

  # Oracle for the rolling api-key cost summary, expressed as the legacy
  # predicate in raw SQL under a UTC session: `occurred_at::date BETWEEN
  # start_date AND end_date`, the same joins and filters, and no
  # `amount_status` filter, so a voided settlement still counts. The public
  # results of `build_api_key_self_usage/3` and `build_v1_usage_for_api_key/3`
  # must equal what the oracle implies, both before and after the half-open
  # timestamptz rewrite.

  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Repo

  @micros_per_usd Decimal.new(1_000_000)

  # The fixed reference instant every windowed case asserts against, and a seed
  # timestamp that sits inside the resulting 28-day window. Both are absolute, so
  # these tests keep their meaning regardless of when the suite runs.
  @as_of ~U[2026-09-17 12:00:00.000000Z]
  @in_window_occurred_at ~U[2026-09-10 09:30:00.000000Z]

  setup do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{pool: pool, api_key: api_key, auth: %{pool: pool, api_key: api_key}}
  end

  test "no qualifying rows stay unpriced", context do
    assert_parity(context, ~U[2026-09-17 12:00:00.000000Z])
  end

  test "the day window is inclusive on both UTC calendar edges", context do
    as_of = ~U[2026-09-17 12:00:00.000000Z]

    for occurred_at <- boundary_timestamps(as_of) do
      settlement(context, %{occurred_at: occurred_at, settled_cost_micros: 250_000})
    end

    assert_parity(context, as_of)
  end

  test "the day window is inclusive on both UTC calendar edges at midnight", context do
    as_of = ~U[2026-09-17 00:00:00.000000Z]

    for occurred_at <- boundary_timestamps(as_of) do
      settlement(context, %{occurred_at: occurred_at, settled_cost_micros: 250_000})
    end

    assert_parity(context, as_of)
  end

  test "a zero-cost settlement with the key present is counted and priced", context do
    settlement(context, %{settled_cost_micros: 0, details: %{"settled_cost_micros" => 0}})
    assert_parity(context, @as_of, 1)
  end

  test "settlements without the details key are excluded", context do
    settlement(context, %{details: %{}})
    settlement(context, %{details: %{"settled_cost_micros" => nil}})
    assert_parity(context, @as_of, 0)
  end

  test "a voided settlement with the key is preserved", context do
    settlement(context, %{amount_status: "voided", settled_cost_micros: 4_000_000})
    assert_parity(context, @as_of, 1)
  end

  test "other usage statuses and entry kinds are excluded", context do
    for usage_status <- ~w(usage_unknown usage_pending not_applicable) do
      settlement(context, %{usage_status: usage_status})
    end

    for entry_kind <- ~w(reservation adjustment) do
      settlement(context, %{entry_kind: entry_kind})
    end

    assert_parity(context, @as_of, 0)
  end

  test "other api keys and other pools are excluded", %{pool: pool} = context do
    other_pool = pool_fixture()
    %{api_key: other_key} = active_api_key_fixture(pool)

    settle_for(%{pool: pool, api_key: other_key}, %{settled_cost_micros: 7_000_000})

    settle_for(%{pool: other_pool, api_key: context.api_key}, %{
      settled_cost_micros: 9_000_000
    })

    settlement(context, %{settled_cost_micros: 1_000_000})
    assert_parity(context, @as_of, 1)
  end

  test "fractional settled costs keep their rounding", context do
    for micros <- ["1234.567890123", "0.000000499", "98765.432109877"] do
      settlement(context, %{
        settled_cost_micros: micros,
        details: %{"settled_cost_micros" => micros}
      })
    end

    assert_parity(context, @as_of, 3)
  end

  # `start 00:00:00.000000Z` and `end 23:59:59.999999Z` qualify; one microsecond
  # before the start and the first microsecond of the day after the end do not.
  defp boundary_timestamps(as_of) do
    start_date = as_of |> DateTime.add(-27, :day) |> DateTime.to_date()
    end_date = DateTime.to_date(as_of)
    start_at = DateTime.new!(start_date, ~T[00:00:00.000000], "Etc/UTC")
    end_before = DateTime.new!(Date.add(end_date, 1), ~T[00:00:00.000000], "Etc/UTC")

    [
      start_at,
      DateTime.add(start_at, -1, :microsecond),
      DateTime.add(end_before, -1, :microsecond),
      end_before
    ]
  end

  # Every fixed-window case uses @as_of, so fixtures must land INSIDE that window.
  # Defaulting to `DateTime.utc_now()` made these cases vacuous once the clock moved
  # past 2026-09-17: both the oracle and the candidate excluded every row by date, so
  # an exclusion test could pass even if the candidate stopped honouring its predicate.
  defp settlement(context, attrs), do: settle_for(context.auth, attrs)

  defp settle_for(auth, attrs) do
    micros = Map.get(attrs, :settled_cost_micros, 1_250_000)

    request = request_fixture(auth)

    ledger_entry_fixture(
      request,
      attrs
      |> Map.put_new(:details, %{"settled_cost_micros" => to_string(micros)})
      |> Map.put(:settled_cost_micros, to_string(micros))
      |> Map.put_new(:occurred_at, @in_window_occurred_at)
    )
  end

  # Asserts candidate/oracle agreement AND that the scenario is non-vacuous:
  # `expected_rows` pins how many rows the oracle must actually qualify, so a
  # silently-empty window fails instead of passing as "unpriced".
  defp assert_parity(context, as_of, expected_rows) do
    {count, _sum} = oracle(context.pool.id, context.api_key.id, as_of)

    assert count == expected_rows,
           "expected #{expected_rows} qualifying oracle row(s), got #{count}; " <>
             "the fixture window no longer covers the seeded settlements"

    assert_parity(context, as_of)
  end

  defp assert_parity(%{pool: pool, api_key: api_key}, as_of) do
    {count, sum} = oracle(pool.id, api_key.id, as_of)

    expected_status = if count > 0, do: "priced", else: "unpriced"

    expected_usd =
      if count > 0, do: sum |> Decimal.div(@micros_per_usd) |> Decimal.round(6), else: nil

    assert {:ok, usage} = Accounting.build_api_key_self_usage(pool, api_key, as_of: as_of)
    assert usage.total_cost_status == expected_status

    case expected_usd do
      nil -> assert usage.total_cost_usd == nil
      %Decimal{} -> assert Decimal.equal?(usage.total_cost_usd, expected_usd)
    end

    assert {:ok, v1} = Accounting.build_v1_usage_for_api_key(pool, api_key, as_of: as_of)
    assert v1.total_cost_status == expected_status
    assert v1.total_cost_usd == if(expected_usd, do: Decimal.to_float(expected_usd), else: 0.0)
  end

  # The predicate as it was before the rewrite, evaluated by PostgreSQL itself.
  defp oracle(pool_id, api_key_id, as_of) do
    start_date = as_of |> DateTime.add(-27, :day) |> DateTime.to_date()
    end_date = DateTime.to_date(as_of)

    Repo.query!("SET LOCAL TimeZone = 'UTC'")

    %{rows: [[count, sum]]} =
      Repo.query!(
        """
        SELECT count(entry.id), coalesce(sum(entry.settled_cost_micros), 0)
        FROM ledger_entries entry
        JOIN requests request ON request.id = entry.request_id
        WHERE request.pool_id = $1
          AND entry.api_key_id = $2
          AND entry.entry_kind = 'settlement'
          AND entry.usage_status = 'usage_known'
          AND entry.occurred_at::date >= $3
          AND entry.occurred_at::date <= $4
          AND (entry.details->>'settled_cost_micros') IS NOT NULL
        """,
        [Ecto.UUID.dump!(pool_id), Ecto.UUID.dump!(api_key_id), start_date, end_date]
      )

    {count, sum}
  end
end
