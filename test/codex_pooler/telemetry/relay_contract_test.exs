defmodule CodexPooler.Telemetry.RelayContractTest do
  # The relay is the only transport that carries an Oban job's telemetry to a
  # scraped reporter, so what it is allowed to carry, what the database refuses
  # to store, and what happens when nothing drains it are contract, not
  # implementation detail. `relay_storage_test.exs` covers the happy paths of
  # each function; this file pins the four properties the design comment on
  # findings#195 promised an operator and a reader of the schema:
  #
  #   * the row shape is metadata-only and bounded by the database, not only by
  #     a changeset a future caller could bypass;
  #   * an unknown event name is refused by the database itself;
  #   * two real PostgreSQL backends claiming at the same time split the work
  #     instead of double counting it;
  #   * every batch statement runs under a transaction-local timeout that does
  #     not outlive its transaction.
  #
  # It also states, as tests rather than prose, two things the ticket's own
  # comments corrected: the heartbeat that gates inserts is the *producer's*
  # own, so an absent consumer never stops a producer; and a relay outage is
  # invisible to the business transaction that emitted the event.
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture

  alias CodexPooler.Telemetry.{Relay, RelayEvent, RelayRuntime}
  alias Ecto.Adapters.SQL.Sandbox

  # Failure-detection budgets, not behaviour timers.
  @task_budget 15_000

  setup do
    :ok = Relay.refresh_heartbeat("relay-runtime")
  end

  describe "the row a relay event is allowed to be" do
    test "the table carries no identifier column and no free-text column" do
      rows =
        Repo.query!("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = 'telemetry_relay_events' ORDER BY column_name").rows

      columns = Map.new(rows, fn [name, type, _nullable] -> {name, type} end)
      nullability = Map.new(rows, fn [name, _type, nullable] -> {name, nullable} end)

      # Every column is named here on purpose. A new one arrives in this
      # assertion before it can arrive in production, which is the point: the
      # relay must never grow a request, session, pool, account, identity or
      # key id, and `claimed_by` is the only string an app node writes.
      assert Map.keys(columns) |> Enum.sort() == [
               "claimed_at",
               "claimed_by",
               "count",
               "event",
               "id",
               "inserted_at",
               "labels",
               "measurements"
             ]

      assert columns["labels"] == "jsonb"
      assert columns["measurements"] == "jsonb"
      assert columns["count"] == "bigint"

      # Both JSONB bounds are `STRICT` SQL functions, so they return NULL for a
      # NULL argument and a CHECK whose expression is NULL passes. Every refusal
      # the two tests below prove therefore rests on these columns being NOT
      # NULL: dropping that reopens "the column is wholly unchecked" with the
      # rest of this file green, which is exactly the shape findings#195 row
      # 195-23 is about.
      assert nullability["labels"] == "NO"
      assert nullability["measurements"] == "NO"
      assert nullability["event"] == "NO"
      assert nullability["count"] == "NO"
      assert nullability["inserted_at"] == "NO"
    end

    test "the forwarded label vocabulary is a closed set of bounded category keys" do
      # `RelayRuntime.labels/1` takes only these keys off the emitted metadata,
      # so a metric that starts tagging by an identifier cannot reach the table
      # through the relay. Listing them here makes adding one a deliberate act.
      assert Enum.sort(RelayRuntime.label_keys()) == [
               :decision,
               :downstream_transport,
               :outcome,
               :phase,
               :scope,
               :source,
               :transport,
               :upstream_transport,
               :via
             ]

      forbidden = ~w(id request_id session_id pool_id account_id api_key_id upstream_identity_id)a

      assert RelayRuntime.label_keys() |> Enum.filter(&(&1 in forbidden)) == []
    end

    test "an over-wide label or measurement map is refused by the database, not only the changeset" do
      # The changeset bound is proven in relay_storage_test. This one bypasses
      # it entirely, because the check constraint is what still holds when a
      # future caller writes the row some other way.
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               raw_insert(%{labels: Map.new(1..17, &{"k#{&1}", "v"})})

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               raw_insert(%{measurements: Map.new(1..9, &{"m#{&1}", 1})})

      assert {:ok, _} = raw_insert(%{labels: Map.new(1..16, &{"k#{&1}", "v"})})
    end

    test "the database bounds label strings themselves, not only how many there are" do
      # Bounding the key count leaves a raw writer free to store one unbounded
      # string, which is the same unbounded-storage hazard the key bound exists
      # to close. The database mirrors `RelayRuntime.bounded/1`'s 80 bytes.
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: over}}} =
               raw_insert(%{labels: %{"phase" => String.duplicate("x", 81)}})

      assert over == "labels_values_bounded"

      assert {:ok, _} = raw_insert(%{labels: %{"phase" => String.duplicate("x", 80)}})

      # A non-string value has no length bound at all, so it is refused outright.
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: typed}}} =
               raw_insert(%{labels: %{"phase" => 1}})

      assert typed == "labels_values_bounded"

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: key}}} =
               raw_insert(%{labels: %{String.duplicate("k", 41) => "v"}})

      assert key == "labels_values_bounded"
    end

    test "the database refuses a measurement that is not a non-negative integer" do
      # A relayed sample is a count or a millisecond duration. Nothing bounded
      # the values at all, so a negative or fractional one would have been
      # replayed into a Prometheus series as if an emitter had produced it.
      for value <- [-1, 1.5, "x", true] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
                 raw_insert(%{measurements: %{"count" => value}}),
               "measurement #{inspect(value)} was accepted by the database"

        assert name == "measurements_non_negative_integers"
      end

      assert {:ok, _} = raw_insert(%{measurements: %{"count" => 1, "applied_to_ms" => 0}})
    end

    test "the measurement bound holds for the whole column, not only an object's scalars" do
      # The first bound was a `$.*` path expression, and SQL/JSON path lax mode
      # descends into what it is given: an array value was tested element by
      # element, and a non-object column value matched nothing at all, so the
      # constraint was skipped whole rather than violated. Every value here was
      # accepted before. They are written as raw JSON literals because a column
      # value of `null` is the JSON one, not SQL NULL, which the column already
      # refuses for a different reason.
      literals = [
        "[-1]",
        "-1",
        "null",
        ~s("x"),
        "true",
        "[]",
        "[1,2]",
        ~s({"count":[1,2]}),
        ~s({"count":[]}),
        ~s({"count":{"a":1}}),
        ~s({"count":1e500}),
        ~s({"count":1.0}),
        ~s({"count":1000000000001})
      ]

      for literal <- literals do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
                 raw_insert_literal("measurements", literal),
               "measurements = #{literal} was accepted by the database"

        assert name == "measurements_non_negative_integers"
      end

      # The bound's own edges still store, so the refusals above are the rule
      # and not a constraint that refuses everything.
      assert {:ok, _} = raw_insert_literal("measurements", ~s({"count":1000000000000}))
      assert {:ok, _} = raw_insert_literal("measurements", ~s({"count":0}))
      assert {:ok, _} = raw_insert_literal("measurements", "{}")
    end

    test "a non-object labels value is refused by the constraint rather than raising past it" do
      # `jsonb_each` raises `22023` on a non-object, which is not a
      # `check_violation`: `check_constraint/3` cannot map it to a field error,
      # and a storage bound that raises a different class of error for the
      # shape furthest outside it is not a bound.
      for literal <- ["[]", ~s(["a"]), ~s("x"), "1", "null", "true"] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
                 raw_insert_literal("labels", literal),
               "labels = #{literal} did not violate a check constraint"

        assert name == "labels_values_bounded"
      end
    end

    test "the changeset refuses the same values the database refuses" do
      # The database is the backstop; the changeset is the path every producer
      # actually takes, and it admitted negatives, floats and unbounded strings.
      assert {:error, changeset} =
               Relay.insert("pre_attempt_release", %{}, 1, %{count: -1})

      assert %{measurements: _} = errors_on(changeset)

      assert {:error, changeset} =
               Relay.insert("pre_attempt_release", %{}, 1, %{count: 1.5})

      assert %{measurements: _} = errors_on(changeset)

      assert {:error, changeset} =
               Relay.insert("pre_attempt_release", %{"phase" => String.duplicate("x", 81)}, 1)

      assert %{labels: _} = errors_on(changeset)

      assert {:error, changeset} = Relay.insert("pre_attempt_release", %{"phase" => 1}, 1)
      assert %{labels: _} = errors_on(changeset)

      assert {:ok, _} =
               Relay.insert("pre_attempt_release", %{"phase" => String.duplicate("x", 80)}, 1, %{
                 count: 1
               })
    end

    test "label storage predicates agree on NUL and invalid UTF-8" do
      invalid_utf8 = <<0xFF, 0xFE>>

      for labels <- [
            %{"phase" => "in_process" <> <<0>>},
            %{("phase" <> <<0>>) => "in_process"},
            %{"phase" => invalid_utf8},
            %{invalid_utf8 => "in_process"}
          ] do
        refute RelayEvent.storable_labels?(labels)

        assert {:error, changeset} = Relay.insert("pre_attempt_release", labels, 1)
        assert %{labels: _} = errors_on(changeset)
      end

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22P05"}}} =
               raw_insert(%{labels: %{"phase" => "in_process" <> <<0>>}})

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22021"}}} =
               raw_insert_rejected_label("convert_from(decode('ff', 'hex'), 'UTF8')")
    end

    test "and refuses nothing the database would have stored" do
      # The two bounds have to agree in both directions, not just overlap. A
      # value the changeset refuses and the database accepts is only untidy; a
      # value the database refuses and the capture path accepts is a sample
      # that can never be stored and is re-queued forever, which is the failure
      # mode findings#195 row 195-101 records. These four disagreed.
      for value <- [1.0, 1_000_000_000_001, [1, 2], []] do
        assert {:error, changeset} =
                 Relay.insert("pre_attempt_release", %{}, 1, %{count: value})

        assert %{measurements: _} = errors_on(changeset),
               "the changeset accepted measurement #{inspect(value)}"

        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
                 raw_insert(%{measurements: %{"count" => value}}),
               "the database accepted measurement #{inspect(value)} the changeset refuses"

        assert name == "measurements_non_negative_integers"
      end
    end

    test "the database refuses an unknown event name and an out-of-range count" do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: event}}} =
               raw_insert(%{event: "not_an_allowlisted_event"})

      assert event == "event_allowed"

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: count}}} =
               raw_insert(%{count: -1})

      assert count == "count_bounded"

      assert {:ok, _} = raw_insert(%{count: RelayEvent.max_count()})

      assert {:error, changeset} =
               Relay.insert("pre_attempt_release", %{}, RelayEvent.max_count() + 1)

      assert {:count, {"must be less than or equal to %{number}", [validation: :number, kind: :less_than_or_equal_to, number: max]}} =
               List.keyfind(changeset.errors, :count, 0)

      assert max == RelayEvent.max_count()

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: over}}} =
               raw_insert(%{count: RelayEvent.max_count() + 1})

      assert over == "count_bounded"

      # The allowlist the database enforces is the one the schema declares, so
      # adding an event to one without the other cannot pass unnoticed.
      for event <- RelayEvent.events() do
        assert {:ok, _} = raw_insert(%{event: event}),
               "#{event} is on the schema allowlist but the database check refuses it"
      end
    end

    test "every storable event name is one the runtime can replay" do
      # Storing a name `RelayRuntime` cannot map back to a telemetry event is
      # worse than refusing it: the row is claimed, then dropped by `emit/1`
      # with no loss reason to count it. The allowlist held two such names —
      # `stale_sweep` is a `pre_attempt_release` phase and `interrupted` a
      # `stream_outcome` outcome, neither an event.
      #
      # The storable set is read off the live `event_allowed` constraint rather
      # than off a second Elixir constant. Comparing `RelayEvent.events/0` to
      # `RelayRuntime.relay_event_names/0` only pins two module attributes to
      # each other: a name added to the database allowlist alone — a migration
      # without the matching schema and runtime change — is storable,
      # unreplayable and uncounted, and neither constant can see it. This is
      # the direction the row is about, so it is the database that is asked.
      storable = database_event_allowlist()

      assert database_event_constraint_definition() == expected_event_constraint_definition(),
             "event_allowed must remain an exact finite IN allowlist"

      refute storable == [],
             "no values were read off event_allowed; the extraction, not the schema, is broken"

      assert storable == Enum.sort(RelayEvent.events())
      assert storable == Enum.sort(RelayRuntime.relay_event_names())

      # And the extraction describes the database it was read from, rather than
      # some text that merely parses: every name it found stores, and a name it
      # did not find is refused by the constraint it was read from.
      for event <- storable do
        assert {:ok, _} = raw_insert(%{event: event}),
               "#{event} was read off event_allowed but the database refuses it"
      end

      # Names across every length and character class the column can hold, not
      # only three short ones. A widening written without a string literal —
      # `OR octet_length(event) > 30` is the one that found this — adds no name
      # for the extraction to see, so what refuses it has to be a probe rather
      # than a parse. The column is `varchar(255)`, so 200 bytes is the longest
      # a refusal can be distinguished from a truncation.
      generated =
        for bytes <- [1, 8, 31, 64, 200],
            do: String.pad_trailing("g#{System.unique_integer([:positive])}", bytes, "x")

      absent =
        ~w(stale_sweep interrupted) ++
          generated ++ ["GHOST_EVENT", "ghost-event.1", "1234567890", " ", "%"]

      for refused <- absent do
        refute refused in storable

        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
                 raw_insert(%{event: refused}),
               "#{refused} is storable but nothing can replay it"

        assert name == "event_allowed"
      end
    end
  end

  describe "claiming across nodes" do
    test "two real backends claim disjointly and together claim everything" do
      # The sandboxed claim test runs both claimers over one connection, where
      # FOR UPDATE SKIP LOCKED can never be exercised. This one uses two real
      # PostgreSQL backends, asserts they are different backends, and asserts
      # the union is complete as well as disjoint: a lock that silently skipped
      # everything would be disjoint too.
      ids = for _ <- 1..8, do: Ecto.UUID.generate()

      register_unboxed_cleanup!(fn ->
        Repo.delete_all(from e in RelayEvent, where: e.id in ^ids)
      end)

      run_unboxed(fn ->
        for id <- ids do
          Repo.insert!(%RelayEvent{
            id: id,
            event: "pre_attempt_release",
            labels: %{},
            count: 1,
            inserted_at: DateTime.utc_now()
          })
        end
      end)

      parent = self()
      barrier = make_ref()

      claimers =
        for owner <- ["node-a", "node-b"] do
          Task.async(fn ->
            run_unboxed(fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, barrier, self()})

              receive do
                {:go, ^barrier} -> :ok
              after
                @task_budget -> raise "claim barrier was never released"
              end

              # Each claimer may take at most half, so a complete union is only
              # possible if both of them claimed.
              {backend, Relay.claim(4, owner)}
            end)
          end)
        end

      for _ <- claimers do
        assert_receive {:ready, ^barrier, pid}, @task_budget
        send(pid, {:go, barrier})
      end

      results = Enum.map(claimers, &Task.await(&1, @task_budget))
      backends = Enum.map(results, &elem(&1, 0))

      assert length(Enum.uniq(backends)) == 2,
             "both claimers ran on one backend, so SKIP LOCKED was never exercised"

      claimed =
        Enum.flat_map(results, fn {_backend, {:ok, rows}} -> Enum.map(rows, & &1.id) end)

      assert Enum.sort(claimed) == Enum.sort(ids)
      assert length(Enum.uniq(claimed)) == length(claimed)

      run_unboxed(fn ->
        assert {:ok, []} = Relay.claim(8, "node-c")

        owners =
          Repo.all(from e in RelayEvent, where: e.id in ^ids, select: e.claimed_by)
          |> Enum.uniq()
          |> Enum.sort()

        assert owners == ["node-a", "node-b"]
      end)
    end

    test "a row another backend holds is skipped rather than waited on" do
      # Disjointness alone does not distinguish SKIP LOCKED from a plain
      # FOR UPDATE: a second claimer that blocks and then re-reads still ends up
      # disjoint, because the rows it waited for are no longer unclaimed. What
      # SKIP LOCKED buys is that a drain on one app pod is never held up by a
      # row another pod is sitting on, so this asserts the claim completes while
      # the lock is still held, and skips exactly the held row.
      ids = for _ <- 1..4, do: Ecto.UUID.generate()
      [held | rest] = ids

      register_unboxed_cleanup!(fn ->
        Repo.delete_all(from e in RelayEvent, where: e.id in ^ids)
      end)

      run_unboxed(fn ->
        for id <- ids do
          Repo.insert!(%RelayEvent{
            id: id,
            event: "stream_outcome",
            labels: %{},
            count: 1,
            inserted_at: DateTime.utc_now()
          })
        end
      end)

      parent = self()
      release = make_ref()

      holder =
        Task.async(fn ->
          run_unboxed(fn ->
            Repo.transaction(fn ->
              Repo.one!(from e in RelayEvent, where: e.id == ^held, lock: "FOR UPDATE")
              send(parent, {:held, self()})

              receive do
                {:release, ^release} -> :ok
              after
                @task_budget -> :timeout
              end
            end)
          end)
        end)

      assert_receive {:held, holder_pid}, @task_budget
      on_exit(fn -> send(holder_pid, {:release, release}) end)

      claimed =
        Task.async(fn ->
          run_unboxed(fn -> Relay.claim(10, "skipping-node") end)
        end)
        |> Task.await(@task_budget)

      assert {:ok, rows} = claimed
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(rest)

      send(holder_pid, {:release, release})
      assert {:ok, _} = Task.await(holder, @task_budget)

      run_unboxed(fn ->
        assert {:ok, [%RelayEvent{id: ^held}]} = Relay.claim(10, "later-node")
      end)
    end
  end

  describe "statement bounds" do
    test "each batch statement runs under a transaction-local timeout that does not outlive it" do
      # `SET LOCAL` is the whole claim: a session-level timeout would survive
      # the transaction and silently bound unrelated work on the same pooled
      # connection. The queries are read off repo telemetry rather than off the
      # source, and the session value is read back afterwards on the same
      # backend.
      parent = self()
      handler = {__MODULE__, make_ref()}
      on_exit(fn -> :telemetry.detach(handler) end)

      :ok =
        :telemetry.attach(
          handler,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if Process.get({__MODULE__, :recording}),
              do: send(parent, {:query, metadata.query})
          end,
          nil
        )

      for {label, call} <- [
            {:claim, fn -> Relay.claim(1, "timeout-probe") end},
            {:expire, &Relay.expire_counted/0},
            {:prune, &Relay.prune/0}
          ] do
        session_default =
          run_unboxed(fn ->
            Process.put({__MODULE__, :recording}, true)
            before = show_statement_timeout()
            call.()
            after_call = show_statement_timeout()
            Process.delete({__MODULE__, :recording})

            assert before == after_call,
                   "#{label} left statement_timeout at #{after_call} on the session"

            after_call
          end)

        assert_receive {:query, "SET LOCAL statement_timeout = '5s'"}, @task_budget

        # The default is whatever the pooled connection was configured with;
        # what matters is that the five seconds did not become it.
        refute session_default == "5s"
        drain_recorded_queries()
      end
    end
  end

  describe "who the heartbeat is about" do
    test "no fresh consumer never stops a producer; the backlog is bounded by counted expiry" do
      # The ticket's 14:57Z entry read the heartbeat as consumer liveness. It
      # is not: `Relay.insert/5` gates on the *producer's own* freshness, so a
      # cluster with no draining reporter keeps producing. What bounds that
      # backlog is the one-hour counted expiry, and what makes the situation
      # visible is `fresh_consumers`. Both are asserted here so the corrected
      # semantics cannot quietly change back.
      #
      # Totals are read as deltas because focused suites share this database
      # and another one may hold committed relay rows of its own.
      baseline = Relay.health()
      before_expired = expired_loss()

      assert {:ok, %RelayEvent{}} =
               Relay.insert("pre_attempt_release", %{"via" => "job_relay"}, 3)

      after_insert = Relay.health()
      assert after_insert.backlog_rows - baseline.backlog_rows == 1
      assert after_insert.backlog_samples - baseline.backlog_samples == 3

      # A quiesced consumer is present but not draining, and must not read as
      # liveness.
      :ok = Relay.consumer_heartbeat("contract-quiesced", true)
      assert Relay.health().fresh_consumers == baseline.fresh_consumers

      :ok = Relay.consumer_heartbeat("contract-live", false)
      assert Relay.health().fresh_consumers == baseline.fresh_consumers + 1

      # A stale consumer heartbeat is not liveness either.
      Repo.query!("UPDATE telemetry_relay_consumers SET heartbeat_at = clock_timestamp() - interval '120 seconds' WHERE owner = 'contract-live'")

      assert Relay.health().fresh_consumers == baseline.fresh_consumers

      # Production continues regardless of any consumer's state: the only gate
      # is the producer's own heartbeat, proven by removing it.
      assert {:ok, %RelayEvent{}} =
               Relay.insert("pre_attempt_release", %{"via" => "job_relay"}, 2)

      Repo.query!("DELETE FROM telemetry_relay_heartbeats WHERE owner = 'relay-runtime'")

      assert {:error, :stale_heartbeat} =
               Relay.insert("pre_attempt_release", %{"via" => "job_relay"}, 1)

      # And an undrained backlog is reclaimed with its samples counted, not
      # silently dropped.
      aged =
        from(e in RelayEvent,
          where: is_nil(e.claimed_at) and e.inserted_at > ago(1, "hour")
        )

      {aged_rows, _} =
        Repo.update_all(aged,
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -3700, :second)]
        )

      assert aged_rows >= 2
      assert {^aged_rows, _} = Relay.expire_counted()
      assert expired_loss() - before_expired >= 5
    end
  end

  describe "a relay outage" do
    test "does not reach the business transaction that emitted the event" do
      # Capture runs in the emitting process, inside whatever transaction that
      # process has open. If it could raise, or touch the database, a relay
      # outage would roll back real work. The outage here is the real one the
      # persistence boundary produces: the producer's heartbeat is gone, so
      # every insert is refused.
      owner = self()

      runtime =
        start_supervised!({RelayRuntime, enabled: true, role: "worker", start_paused: true, name: :"relay-contract-test-#{System.unique_integer([:positive])}", flush_ms: 60_000, drain_ms: 60_000})

      Sandbox.allow(Repo, owner, runtime)
      :ok = GenServer.call(runtime, :activate)
      state = :sys.get_state(runtime)

      run_unboxed(fn ->
        Repo.query!("DELETE FROM telemetry_relay_heartbeats WHERE owner = $1", [state.owner])
      end)

      pool_name = "relay-outage-#{System.unique_integer([:positive])}"

      register_unboxed_cleanup!(fn ->
        Repo.delete_all(from p in CodexPooler.Pools.Pool, where: p.name == ^pool_name)
      end)

      committed =
        run_unboxed(fn ->
          Repo.transaction(fn ->
            pool = pool_fixture(%{name: pool_name})

            :telemetry.execute(
              [:codex_pooler, :accounting, :reservation, :pre_attempt_release],
              %{count: 1},
              %{
                phase: "stale_sweep",
                transport: "http_sse",
                outcome: "stale_reservation_recovered"
              }
            )

            pool.id
          end)
        end)

      assert {:ok, pool_id} = committed

      assert run_unboxed(fn -> Repo.get(CodexPooler.Pools.Pool, pool_id) end),
             "the business row was lost to a relay outage"

      # The event was captured in memory and the flush failed against the
      # database; neither reached the caller, and the handler is still attached.
      send(runtime, :flush)
      :sys.get_state(runtime)
      assert Process.alive?(runtime)

      assert Enum.any?(:telemetry.list_handlers([]), &(&1.id == state.handler)),
             "the failed flush detached the capture handler"

      # The outage is real rather than assumed: this producer's own writes are
      # still refused after the flush attempt.
      assert run_unboxed(fn ->
               Relay.insert("pre_attempt_release", %{}, 1, %{}, state.owner)
             end) == {:error, :stale_heartbeat}
    end
  end

  # The names the database will actually accept, read off the constraint itself.
  # `pg_get_constraintdef/1` renders the allowlist as quoted literals and casts
  # to unquoted type names, so every quoted run in the definition is a value.
  # The single-row match is part of the assertion: a renamed or dropped
  # constraint fails here rather than quietly reporting an empty allowlist.
  defp database_event_allowlist do
    definition = database_event_constraint_definition()

    ~r/'((?:[^']|'')*)'/
    |> Regex.scan(definition)
    |> Enum.map(fn [_match, value] -> String.replace(value, "''", "'") end)
    |> Enum.sort()
  end

  defp database_event_constraint_definition do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'telemetry_relay_events'::regclass AND conname = 'event_allowed'")

    definition
  end

  defp expected_event_constraint_definition do
    table = "relay_event_allowlist_expected_#{System.unique_integer([:positive])}"

    events =
      RelayEvent.events()
      |> Enum.map_join(",", fn event -> "'#{String.replace(event, "'", "''")}'" end)

    Repo.query!("CREATE TEMP TABLE #{table} (event varchar(255)) ON COMMIT DROP")

    Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT expected_event_allowed CHECK (event IN (#{events}))")

    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '#{table}'::regclass AND conname = 'expected_event_allowed'")

    definition
  end

  defp raw_insert(overrides) do
    attrs =
      Map.merge(
        %{event: "pre_attempt_release", labels: %{}, count: 1, measurements: %{}},
        overrides
      )

    Repo.query(
      "INSERT INTO telemetry_relay_events (event, labels, count, measurements, inserted_at) VALUES ($1, $2, $3, $4, $5)",
      [
        attrs.event,
        attrs.labels,
        attrs.count,
        attrs.measurements,
        DateTime.utc_now()
      ]
    )
  end

  # A JSON literal rather than a parameter: the shapes this file has to refuse
  # include the JSON value `null` and bare scalars, which no Elixir term a
  # parameter could carry encodes to. The literal is a test-local constant, not
  # anything a caller supplies.
  defp raw_insert_literal(column, literal) when column in ["labels", "measurements"] do
    Repo.query(
      "INSERT INTO telemetry_relay_events (event, labels, count, measurements, inserted_at) " <>
        "VALUES ('pre_attempt_release', #{if column == "labels", do: "'#{literal}'::jsonb", else: "'{}'::jsonb"}, 1, " <>
        "#{if column == "measurements", do: "'#{literal}'::jsonb", else: "'{}'::jsonb"}, now())"
    )
  end

  defp raw_insert_rejected_label(label_expression) do
    Repo.query(
      "INSERT INTO telemetry_relay_events (event, labels, count, measurements, inserted_at) " <>
        "VALUES ('pre_attempt_release', jsonb_build_object('phase', #{label_expression}), 1, '{}', now())"
    )
  end

  defp expired_loss do
    %{rows: rows} =
      Repo.query!("SELECT samples FROM telemetry_relay_losses WHERE reason = 'expired_unclaimed'")

    case rows do
      [[samples]] -> samples
      [] -> 0
    end
  end

  defp show_statement_timeout do
    %{rows: [[value]]} = Repo.query!("SHOW statement_timeout")
    value
  end

  defp drain_recorded_queries do
    receive do
      {:query, _} -> drain_recorded_queries()
    after
      0 -> :ok
    end
  end
end
