defmodule CodexPooler.Accounting.UsageSettlementPostgresTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{DailyRollup, HourlyModelUsageRollup, LedgerEntry, RequestLogFact}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  test "committed finalizers race one late measured usage correction through PostgreSQL locks" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, fixture} = Repo.transaction(&committed_fixture/0)
        fixture
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        BackendCodexTestSupport.cleanup_unboxed_pool!(fixture.pool.id)
        Repo.delete!(fixture.pricing)
      end)
    end)

    parent = self()
    release = make_ref()

    tasks =
      for lane <- [:first, :second] do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:backend_ready, lane, backend_pid, self()})

            receive do
              {:release, ^release} ->
                Accounting.finalize_success_with_disposition(
                  fixture.failed.request,
                  fixture.failed.attempt,
                  fixture.usage,
                  %{
                    response_status_code: 200,
                    before_finalize: fn ->
                      if lane == :first do
                        send(parent, :first_finalizer_locked)

                        receive do
                          {:finish, ^release} -> :ok
                        after
                          @detection_budget -> raise "finalization lock barrier was not released"
                        end
                      end
                    end
                  }
                )
            after
              @detection_budget -> raise "finalizer start barrier was not released"
            end
          end)
        end)
      end

    ready =
      for _lane <- 1..2 do
        assert_receive {:backend_ready, lane, backend_pid, task_pid}, @detection_budget
        {lane, backend_pid, task_pid}
      end

    assert ready |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2
    {:first, first_backend, first_pid} = Enum.find(ready, &(elem(&1, 0) == :first))
    {:second, second_backend, second_pid} = Enum.find(ready, &(elem(&1, 0) == :second))
    send(first_pid, {:release, release})
    assert_receive :first_finalizer_locked, @detection_budget
    send(second_pid, {:release, release})

    try do
      Sandbox.unboxed_run(Repo, fn ->
        assert_blocked_by!(
          second_backend,
          first_backend,
          System.monotonic_time(:millisecond) + @detection_budget
        )
      end)
    after
      send(first_pid, {:finish, release})
    end

    results = Enum.map(tasks, &Task.await(&1, @detection_budget))
    assert Enum.count(results, &match?({:ok, %{finalization_disposition: :replaced}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{finalization_disposition: :reused}}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      request_id = fixture.failed.request.id
      entries = Repo.all(from(l in LedgerEntry, where: l.request_id == ^request_id))
      settlements = Enum.filter(entries, &(&1.entry_kind == "settlement"))
      assert length(settlements) == 2
      assert Enum.count(settlements, &(&1.amount_status == "voided")) == 1
      [recorded] = Enum.filter(settlements, &(&1.amount_status == "recorded"))
      assert recorded.correction_of_entry_id == fixture.failed.settlement.id
      assert recorded.pricing_snapshot_id == fixture.pricing.id
      assert recorded.usage_status == "usage_known"
      assert recorded.input_tokens == 16
      assert recorded.cached_input_tokens == 4
      assert recorded.output_tokens == 5
      assert recorded.reasoning_tokens == 2
      assert recorded.total_tokens == 21
      assert Decimal.equal?(recorded.settled_cost_micros, Decimal.new(623))
      assert Enum.count(entries, &(&1.entry_kind == "reservation")) == 1
      assert Enum.count(entries, &(&1.entry_kind == "release")) == 1
      fact = Repo.get_by!(RequestLogFact, request_id: request_id)
      assert fact.latest_settlement_entry_id == recorded.id
      assert fact.latest_total_tokens == 21
      assert Decimal.equal?(fact.latest_settled_cost_micros, Decimal.new(623))

      assert [daily] =
               Repo.all(
                 from(r in DailyRollup,
                   where: r.pool_id == ^fixture.pool.id and r.dimension_kind == "pool"
                 )
               )

      assert [hourly] =
               Repo.all(from(r in HourlyModelUsageRollup, where: r.pool_id == ^fixture.pool.id))

      for rollup <- [daily, hourly] do
        assert rollup.request_count == 1
        assert rollup.success_count == 1
        assert rollup.failure_count == 0
        assert rollup.input_tokens == 16
        assert rollup.cached_input_tokens == 4
        assert rollup.output_tokens == 5
        assert rollup.reasoning_tokens == 2
        assert rollup.total_tokens == 21
        assert Decimal.equal?(rollup.settled_cost_micros, Decimal.new(623))
      end
    end)
  end

  defp assert_blocked_by!(waiter, holder, deadline) do
    [[blocked?]] =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder, waiter]).rows

    if not blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "second PostgreSQL finalizer never waited on the first"

      assert_blocked_by!(waiter, holder, deadline)
    end
  end

  defp committed_fixture do
    setup =
      accounting_setup(%{
        price_version: "usage-race-#{System.unique_integer([:positive])}",
        input_token_micros: Decimal.new(25),
        cached_input_token_micros: Decimal.new(5),
        output_token_micros: Decimal.new(50),
        reasoning_token_micros: Decimal.new(75),
        request_base_micros: Decimal.new(3)
      })

    {:ok, reserved} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 5},
        %{}
      )

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    {:ok, failed} =
      Accounting.finalize_failure(reserved.request, attempt, %{
        last_error_code: "owner_drained",
        usage: %{status: "usage_unknown", source: "owner_drained"}
      })

    Map.merge(setup, %{
      failed: failed,
      usage: %{
        status: "usage_known",
        source: "late_owner_completion",
        recorded_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        input_tokens: 16,
        cached_input_tokens: 4,
        output_tokens: 5,
        reasoning_tokens: 2,
        total_tokens: 21
      }
    })
  end
end
