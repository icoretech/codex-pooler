defmodule CodexPooler.Accounting.OutstandingReservationCountTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, LedgerReads, Request}
  alias CodexPooler.Repo

  describe "the active-request cap" do
    test "refuses exactly at the cap and admits again once a reservation settles" do
      setup = capped_setup(2)
      first = reserve!(setup)
      _second = reserve!(setup)

      assert LedgerReads.outstanding_reservation_count(setup.api_key.id) == 2
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(setup)

      release_key_reservation!(first)

      assert LedgerReads.outstanding_reservation_count(setup.api_key.id) == 1
      _third = reserve!(setup)
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(setup)
    end

    # The stale-reservation sweep closes open requests after six hours, but it
    # skips replay-held and live runtime requests and runs only on a scheduler
    # node, so age never proves a request finished: an open request admitted a
    # week ago still holds its slot.
    test "an open request admitted long before the stale-reservation sweep window still holds its slot" do
      setup = capped_setup(1)
      holder = reserve!(setup)
      week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

      holder |> Ecto.Changeset.change(admitted_at: week_ago) |> Repo.update!()
      Repo.update_all(from(entry in LedgerEntry, where: entry.request_id == ^holder.id), set: [occurred_at: week_ago, created_at: week_ago])

      assert LedgerReads.outstanding_reservation_count(setup.api_key.id) == 1
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(setup)
    end

    # Production kept 159 reservations of requests that had already failed with
    # no attempt (owner_drained, owner_unavailable, client_disconnected, May to
    # September 2026) and no release: nothing reopens a finished request and the
    # sweep only visits open ones, so such a reservation can never be live work,
    # yet it used to hold a cap slot forever (146 of them on one key).
    test "a finished request's reservation that was never released holds no slot" do
      setup = capped_setup(1)
      holder = reserve!(setup)

      holder
      |> Ecto.Changeset.change(status: "failed", usage_status: "usage_unknown", completed_at: DateTime.utc_now(), response_status_code: 499, last_error_code: "owner_drained")
      |> Repo.update!()

      assert [%LedgerEntry{entry_kind: "reservation"}] = Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^holder.id))
      assert LedgerReads.outstanding_reservation_count(setup.api_key.id) == 0
      _next = reserve!(setup)
    end

    test "an open request without a reservation, or whose reservation was released, holds no slot" do
      setup = capped_setup(1)
      claim = request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{status: "accepted", usage_status: "usage_pending", transport: "websocket", completed_at: nil, response_status_code: nil})
      released = request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{status: "in_progress", usage_status: "usage_pending", completed_at: nil, response_status_code: nil})
      ledger_entry_fixture(released, %{entry_kind: "reservation", usage_status: "usage_pending"})
      ledger_entry_fixture(released, %{entry_kind: "release", usage_status: "usage_pending"})

      assert [] = Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^claim.id))
      assert LedgerReads.outstanding_reservation_count(setup.api_key.id) == 0
      _holder = reserve!(setup)
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(setup)
    end
  end

  describe "query plan" do
    # Small histories are the ones the planner mis-sizes: with missing
    # statistics the old anti join rescanned the key's ledger rows for every
    # reservation up to about 300 reservations, and with empty-table statistics
    # at every size; with fresh statistics it still read the key's whole history
    # on every admission (747,651 reservations for the largest production key).
    @history 1000
    @open 2

    test "the count reads the key's open requests, not its history, with missing, empty and fresh planner statistics" do
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      insert_reservation_history!(pool, api_key, now)

      for statistics <- [:missing, :empty, :fresh] do
        put_statistics!(statistics)

        {count, queries} = capture_queries(fn -> LedgerReads.outstanding_reservation_count(api_key.id) end)
        assert [{query, params}] = queries

        %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params)
        handled = handled_rows(explain["Plan"])

        # The key's open requests with a reservation probe and a terminal probe
        # each; any read of the key's history handles at least @history rows.
        assert handled <= 10 * (@open + 1), "active-request count handled #{handled} plan rows for #{@open} open of #{@history + @open + 1} requests with #{statistics} statistics: #{inspect(explain)}"
        assert count == @open
      end
    end
  end

  defp capped_setup(limit) do
    setup = accounting_setup()
    setup.api_key |> Ecto.Changeset.change(max_active_requests: limit) |> Repo.update!()
    setup
  end

  defp reserve(setup) do
    Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{correlation_id: "active-cap-#{System.unique_integer([:positive])}"})
  end

  defp reserve!(setup) do
    assert {:ok, %{request: request}} = reserve(setup)
    request
  end

  # @history settled requests, one finished request whose reservation was never
  # released, and @open requests still in progress.
  defp insert_reservation_history!(pool, api_key, now) do
    seed = request_fixture(%{pool: pool, api_key: api_key})
    reservation = ledger_entry_fixture(seed, %{entry_kind: "reservation", usage_status: "usage_pending", occurred_at: now})
    settlement = ledger_entry_fixture(seed, %{entry_kind: "settlement", occurred_at: now})
    dangling = request_fixture(%{pool: pool, api_key: api_key}, %{status: "failed", usage_status: "usage_unknown", last_error_code: "owner_drained", response_status_code: 499})
    ledger_entry_fixture(dangling, %{entry_kind: "reservation", usage_status: "usage_pending", occurred_at: now})

    for _ <- 1..@open do
      open = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress", usage_status: "usage_pending", completed_at: nil, response_status_code: nil})
      ledger_entry_fixture(open, %{entry_kind: "reservation", usage_status: "usage_pending", occurred_at: now})
    end

    request_fields = Request.__schema__(:fields)
    ledger_fields = LedgerEntry.__schema__(:fields)

    requests =
      for ordinal <- 1..(@history - 1) do
        seed |> Map.take(request_fields) |> Map.merge(%{id: Ecto.UUID.generate(), correlation_id: "active-count-plan-#{System.unique_integer([:positive])}", admitted_at: DateTime.add(now, -10 * ordinal, :second)})
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
