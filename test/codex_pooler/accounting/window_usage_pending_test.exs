defmodule CodexPooler.Accounting.WindowUsagePendingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLifecycle.WindowUsage
  alias CodexPooler.Repo

  @reserved 512

  describe "pending tokens" do
    # Production kept 159 reservations of requests that had already failed with
    # no attempt and no release (146 on one key, 12,720,346 reserved tokens):
    # nothing can ever end them, and they added their tokens to every daily and
    # weekly window of the key forever.
    test "a finished request's reservation that was never released is not pending and does not refuse the key's daily window" do
      setup = accounting_setup()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      dangling = request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{status: "failed", usage_status: "usage_unknown", last_error_code: "owner_drained", response_status_code: 499})
      ledger_entry_fixture(dangling, %{entry_kind: "reservation", usage_status: "usage_pending", total_tokens: 20_000, occurred_at: DateTime.add(as_of, -60, :second)})

      usage = window_usages(setup, as_of)

      assert usage.daily.pending_total_tokens == 0
      assert usage.daily.effective_total_tokens == 0
      assert usage.weekly.effective_total_tokens == 0
      # The default policy's daily max is 10,000 tokens.
      assert {:ok, _reserved} = Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{correlation_id: "window-pending-#{System.unique_integer([:positive])}"})
    end

    # Age never proves a request finished (the stale sweep skips replay-held and
    # live runtime requests): an open request admitted before the weekly window
    # still holds its reserved tokens in every window.
    test "an open request admitted before the weekly window is still pending" do
      setup = accounting_setup()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      open = open_request!(setup, DateTime.add(as_of, -8, :day))

      assert %{daily: %{pending_total_tokens: @reserved, effective_total_tokens: @reserved}, weekly: %{pending_total_tokens: @reserved}} = window_usages(setup, as_of)

      ledger_entry_fixture(open, %{entry_kind: "release", usage_status: "usage_pending", total_tokens: @reserved})

      assert %{daily: %{pending_total_tokens: 0}} = window_usages(setup, as_of)
    end

    test "a reservation dated after the window end, or of an open request without one, is not pending" do
      setup = accounting_setup()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      open_request!(setup, DateTime.add(as_of, 30, :second))
      request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{status: "accepted", usage_status: "usage_pending", transport: "websocket", completed_at: nil, response_status_code: nil})

      assert %{daily: %{pending_total_tokens: 0}} = window_usages(setup, as_of)
      assert %{daily: %{pending_total_tokens: @reserved}} = window_usages(setup, DateTime.add(as_of, 60, :second))
    end
  end

  describe "query plan" do
    # A history large enough that the requests table outgrows the few pages a
    # sequential scan wins with under empty statistics.
    @history 1000
    @open 2

    test "pending reads the key's open requests, not its reservation history, with missing, empty and fresh planner statistics" do
      setup = accounting_setup()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      insert_reservation_history!(setup, as_of)

      for statistics <- [:missing, :empty, :fresh] do
        put_statistics!(statistics)

        {usage, queries} = capture_queries(fn -> window_usages(setup, as_of) end)
        assert [{query, params}] = Enum.filter(queries, fn {query, _params} -> String.starts_with?(query, "WITH bounds") end)

        %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params)
        pending = explain["Plan"] |> nodes() |> Enum.find(&(&1["Subplan Name"] == "CTE pending"))
        handled = handled_rows(pending)

        # The key's open requests with one ledger probe each; any read of the
        # key's reservation history handles at least @history rows.
        assert handled <= 10 * (@open + 1), "pending handled #{handled} plan rows for #{@open} open of #{@history + @open + 1} requests with #{statistics} statistics: #{inspect(pending)}"
        assert usage.daily.pending_total_tokens == @open * @reserved
      end
    end
  end

  defp window_usages(setup, as_of) do
    WindowUsage.window_usages(setup.api_key.id, [daily: DateTime.new!(DateTime.to_date(as_of), ~T[00:00:00], "Etc/UTC"), weekly: DateTime.add(as_of, -7, :day)], as_of)
  end

  defp open_request!(setup, reserved_at) do
    open = request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{status: "in_progress", usage_status: "usage_pending", completed_at: nil, response_status_code: nil})
    open |> Ecto.Changeset.change(admitted_at: reserved_at) |> Repo.update!()
    ledger_entry_fixture(open, %{entry_kind: "reservation", usage_status: "usage_pending", total_tokens: @reserved, occurred_at: reserved_at, created_at: reserved_at})
    open
  end

  # @history settled requests over the last days, one finished request whose
  # reservation was never released, and @open requests still in progress.
  defp insert_reservation_history!(setup, as_of) do
    %{pool: pool, api_key: api_key} = setup
    seed = request_fixture(%{pool: pool, api_key: api_key})
    reservation = ledger_entry_fixture(seed, %{entry_kind: "reservation", usage_status: "usage_pending", total_tokens: @reserved, occurred_at: DateTime.add(as_of, -1, :day)})
    settlement = ledger_entry_fixture(seed, %{entry_kind: "settlement", total_tokens: 0, occurred_at: DateTime.add(as_of, -1, :day)})
    dangling = request_fixture(%{pool: pool, api_key: api_key}, %{status: "failed", usage_status: "usage_unknown", last_error_code: "owner_drained", response_status_code: 499})
    ledger_entry_fixture(dangling, %{entry_kind: "reservation", usage_status: "usage_pending", total_tokens: @reserved, occurred_at: DateTime.add(as_of, -2, :day)})

    for _ <- 1..@open, do: open_request!(setup, DateTime.add(as_of, -60, :second))

    request_fields = Request.__schema__(:fields)
    ledger_fields = LedgerEntry.__schema__(:fields)

    requests =
      for ordinal <- 1..(@history - 1) do
        seed |> Map.take(request_fields) |> Map.merge(%{id: Ecto.UUID.generate(), correlation_id: "window-pending-plan-#{System.unique_integer([:positive])}", admitted_at: DateTime.add(as_of, -10 * ordinal - 3600, :second)})
      end

    Repo.insert_all(Request, requests)

    entries =
      Enum.flat_map(requests, fn request ->
        for template <- [reservation, settlement] do
          template |> Map.take(ledger_fields) |> Map.merge(%{id: Ecto.UUID.generate(), request_id: request.id, occurred_at: request.admitted_at, created_at: request.admitted_at})
        end
      end)

    Repo.insert_all(LedgerEntry, entries)
  end

  @tables ["requests", "ledger_entries"]

  # Missing: a table nobody analyzed yet (a fresh database, or right after a
  # restore). Empty: statistics taken while the table was empty, before the
  # data arrived. Both reach the tables' indexes too.
  defp put_statistics!(:missing) do
    for relation <- relations() do
      Repo.query!("SELECT pg_clear_relation_stats('public', $1)", [relation])
    end

    clear_attribute_statistics!()

    assert %{rows: [[0, true]]} =
             Repo.query!("SELECT (SELECT count(*) FROM pg_stats WHERE schemaname = 'public' AND tablename = ANY($1)), bool_and(reltuples = -1) FROM pg_class WHERE relname = ANY($2) AND relnamespace = 'public'::regnamespace", [@tables, relations()])
  end

  defp put_statistics!(:empty) do
    for relation <- relations() do
      Repo.query!("SELECT pg_restore_relation_stats('schemaname', 'public', 'relname', $1::text, 'reltuples', 0::real, 'relpages', 1::integer, 'relallvisible', 0::integer)", [relation])
    end

    clear_attribute_statistics!()

    assert %{rows: [[0, true]]} =
             Repo.query!("SELECT (SELECT count(*) FROM pg_stats WHERE schemaname = 'public' AND tablename = ANY($1)), bool_and(reltuples = 0) FROM pg_class WHERE relname = ANY($2) AND relnamespace = 'public'::regnamespace", [@tables, relations()])
  end

  defp put_statistics!(:fresh) do
    for table <- @tables, do: Repo.query!("ANALYZE #{table}")
  end

  defp relations do
    %{rows: rows} = Repo.query!("SELECT indexrelid::regclass::text FROM pg_index WHERE indrelid = ANY(ARRAY['public.requests'::regclass, 'public.ledger_entries'::regclass])")
    @tables ++ Enum.map(rows, fn [index] -> String.replace_prefix(index, "public.", "") end)
  end

  defp clear_attribute_statistics! do
    for table <- @tables do
      Repo.query!("SELECT pg_clear_attribute_stats('public', $1, attname, false) FROM pg_attribute WHERE attrelid = $1::text::regclass AND attnum > 0 AND NOT attisdropped", [table])
    end
  end

  defp nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &nodes/1)]

  # Every row each plan node handled: the rows it returned and the rows its
  # filters removed, over all its loops. A bitmap index scan's rows are index
  # entries, dead ones included (rolled-back rows of earlier tests in the
  # partition); the bitmap heap scan above it counts the live rows.
  defp handled_rows(%{"Node Type" => "Bitmap Index Scan"}), do: 0

  defp handled_rows(node) do
    own = (node["Actual Rows"] + Map.get(node, "Rows Removed by Filter", 0) + Map.get(node, "Rows Removed by Join Filter", 0) + Map.get(node, "Rows Removed by Index Recheck", 0)) * node["Actual Loops"]
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
end
