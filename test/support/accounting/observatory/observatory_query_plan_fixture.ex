defmodule CodexPooler.Accounting.ObservatoryQueryPlanFixture do
  @moduledoc false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.Repo

  @scope_indexes [
    "requests_api_key_pool_admitted_idx",
    "requests_api_key_pool_admitted_id_idx",
    "request_log_facts_pkey"
  ]

  def set_statement_timeout do
    Repo.query!("SET LOCAL statement_timeout = '30s'")

    # The representative fixture is orders of magnitude smaller than production,
    # so the planner would hash-join a seq-scanned fact table for the aggregates.
    # Force nested-loop index access to assert the production-shape plan: the
    # scope index paths exist and the per-request fact lookup stays bounded.
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_hashjoin = off")
    Repo.query!("SET LOCAL enable_mergejoin = off")

    # Incremental sort can prefer an unrelated admitted-at prefix index and
    # filter API-key scope rows after the scan. The contract exercises the
    # dedicated fully ordered scope index instead.
    Repo.query!("SET LOCAL enable_incremental_sort = off")

    # Keep the scoped-request bitmap exact. With a lossy (page-level) bitmap the
    # heap recheck rereads whole pages of the 7k-row fixture and removes the
    # non-matching rows, which is non-deterministic and inflates the bounded
    # relation-work assertion; ample work_mem keeps the bitmap tuple-exact.
    Repo.query!("SET LOCAL work_mem = '256MB'")

    # Assert the single-worker production-shape plan. Parallel workers split the
    # scoped scan across loops non-deterministically (chosen on cost estimates
    # that drift with the shared test DB's stats), which is orthogonal to the
    # per-request bounded-access contract we verify here.
    Repo.query!("SET LOCAL max_parallel_workers_per_gather = 0")
  end

  def refresh_statistics do
    # Repeated sandbox rollbacks leave dead pages in these local test indexes.
    Enum.each(@scope_indexes, &Repo.query!("REINDEX INDEX " <> &1))
    Repo.query!("ANALYZE requests")
    Repo.query!("ANALYZE request_log_facts")
  end

  def insert_representative_rows! do
    pool = pool_fixture()
    wrong_pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    api_key = api_key |> APIKey.changeset(%{dashboard_access: true}) |> Repo.update!()
    %{api_key: other_api_key} = active_api_key_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-observatory-plan"})
    wrong_model = model_fixture(wrong_pool, %{exposed_model_id: "gpt-observatory-other"})
    upper_bound = ~U[2026-07-17 12:00:00Z]

    {request_template, ledger_template, fact_template} =
      retained_template_pair!(pool, api_key, model, DateTime.add(upper_bound, -13))

    fixture_ref = System.unique_integer([:positive])

    build_pair = fn index, pool_id, api_key_id, model_id, timestamp ->
      request_id = Ecto.UUID.generate()
      entry_id = Ecto.UUID.generate()
      timestamp = %{timestamp | microsecond: {0, 6}}

      request_row =
        Map.merge(request_template, %{
          id: request_id,
          pool_id: pool_id,
          api_key_id: api_key_id,
          model_id: model_id,
          admitted_at: timestamp,
          completed_at: timestamp,
          idempotency_key: nil,
          correlation_id: "observatory-plan-#{fixture_ref}-#{index}"
        })

      ledger_row =
        Map.merge(ledger_template, %{
          id: entry_id,
          request_id: request_id,
          pool_id: pool_id,
          api_key_id: api_key_id,
          occurred_at: timestamp,
          created_at: timestamp
        })

      # The observatory reads the denormalized fact, so every scoped request needs
      # its 1:1 projection row for the per-request fact lookup to be exercised.
      fact_row =
        Map.merge(fact_template, %{
          request_id: request_id,
          latest_settlement_entry_id: entry_id,
          latest_settlement_occurred_at: timestamp,
          latest_settlement_created_at: timestamp,
          inserted_at: timestamp,
          updated_at: timestamp
        })

      {request_row, ledger_row, fact_row}
    end

    rows =
      for index <- 2..240 do
        timestamp = DateTime.add(upper_bound, -(rem(index * 13, 3_500) + 1), :second)
        build_pair.(index, pool.id, api_key.id, model.id, timestamp)
      end ++
        for index <- 1..2_000 do
          timestamp = DateTime.add(upper_bound, -(7_200 + index), :second)
          build_pair.(10_000 + index, pool.id, api_key.id, model.id, timestamp)
        end ++
        for index <- 1..5_000 do
          timestamp = DateTime.add(upper_bound, -(rem(index * 17, 3_500) + 1), :second)
          build_pair.(20_000 + index, pool.id, other_api_key.id, model.id, timestamp)
        end ++
        for index <- 1..5_000 do
          timestamp = DateTime.add(upper_bound, -(rem(index * 19, 3_500) + 1), :second)
          build_pair.(30_000 + index, wrong_pool.id, api_key.id, wrong_model.id, timestamp)
        end

    rows
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(Request, &1))

    rows
    |> Enum.map(&elem(&1, 1))
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(LedgerEntry, &1))

    rows
    |> Enum.map(&elem(&1, 2))
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(RequestLogFact, &1))

    %{
      principal:
        DashboardPrincipal.new(%{
          api_key_id: api_key.id,
          pool_id: pool.id,
          display_name: api_key.display_name,
          key_prefix: api_key.key_prefix
        }),
      upper_bound: upper_bound,
      row_count: length(rows) + 1
    }
  end

  defp retained_template_pair!(pool, api_key, model, timestamp) do
    timestamp = %{timestamp | microsecond: {0, 6}}

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{model_id: model.id, status: "succeeded"})
      |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
      |> Repo.update!()

    ledger =
      ledger_entry_fixture(request, %{
        input_tokens: 6,
        cached_input_tokens: 2,
        output_tokens: 3,
        reasoning_tokens: 1,
        total_tokens: 10,
        settled_cost_micros: 2,
        occurred_at: timestamp,
        created_at: timestamp,
        details: %{"pricing_status" => "priced"}
      })

    {request_fields, []} = Request.__schema__(:insertable_fields)
    {ledger_fields, []} = LedgerEntry.__schema__(:insertable_fields)

    fact_template = %{
      latest_settlement_usage_status: "usage_known",
      latest_settlement_pricing_status: "priced",
      latest_input_tokens: 6,
      latest_cached_input_tokens: 2,
      latest_output_tokens: 3,
      latest_reasoning_tokens: 1,
      latest_total_tokens: 10,
      latest_settled_cost_micros: 2,
      latest_estimated_cost_micros: nil
    }

    {
      request |> Map.from_struct() |> Map.take(request_fields),
      ledger |> Map.from_struct() |> Map.take(ledger_fields),
      fact_template
    }
  end
end
