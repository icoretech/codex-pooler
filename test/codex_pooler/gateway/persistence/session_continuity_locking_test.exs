defmodule CodexPooler.Gateway.Persistence.SessionContinuityLockingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Persistence.SessionContinuity.ExpiredSessions
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @contention_context {__MODULE__, :contention_context}
  @contention_sequence {__MODULE__, :contention_sequence}
  @contention_paused {__MODULE__, :contention_paused}
  @frozen_context {__MODULE__, :frozen_context}
  @frozen_sequence {__MODULE__, :frozen_sequence}
  @frozen_paused {__MODULE__, :frozen_paused}
  @direction_iterations 10
  @start_first_direction "session_lease_start_first"
  @renewal_first_direction "session_lease_renewal_first"

  describe "Task 7 baseline characterization" do
    @tag :task7_pin
    test "missing renewal preserves owner-unavailable nil semantics and rolls back" do
      session_count = Repo.aggregate(CodexSession, :count)
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert {:error, :owner_unavailable} =
               SessionContinuity.renew_owner_token(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 request_options(bridge_owner_lease_ttl_seconds: 120)
               )

      assert Repo.aggregate(CodexSession, :count) == session_count
      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :task7_pin
    test "missing continuity registration preserves raise semantics and rolls back" do
      missing_session = %CodexSession{id: Ecto.UUID.generate()}
      alias_count = Repo.aggregate(BridgeSessionAlias, :count)
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert_raise Ecto.NoResultsError, fn ->
        SessionContinuity.register_codex_session_continuity(
          missing_session,
          %{},
          %{"id" => "response-placeholder"},
          request_options([])
        )
      end

      assert Repo.aggregate(BridgeSessionAlias, :count) == alias_count
      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :task7_pin
    test "owner release remains a transactional lease-only operation" do
      %{session: session, token: token} = owner_session_fixture()
      session_before = Repo.get!(CodexSession, session.id)

      {result, events} =
        capture_repo_queries(fn ->
          SessionContinuity.release_owner_lease(session.id, token, "owner_drained")
        end)

      assert :ok = result
      refute Enum.any?(events, &(&1.source == "codex_sessions"))

      assert Enum.any?(events, fn event ->
               event.source == "bridge_owner_leases" and event.command == "SELECT" and
                 event.for_update? and event.in_transaction?
             end)

      assert Enum.any?(events, fn event ->
               event.source == "bridge_owner_leases" and event.command == "UPDATE" and
                 event.in_transaction?
             end)

      assert %BridgeOwnerLease{status: "released"} =
               Repo.get!(BridgeOwnerLease, token_lease_id(token))

      assert Repo.get!(CodexSession, session.id) == session_before
    end

    @tag :task7_order_contract
    test "replacement and continuity registration lock session before owner lease" do
      %{session: replacement_session} = owner_session_fixture()

      {replacement_result, replacement_events} =
        capture_detailed_repo_queries(fn ->
          SessionContinuity.replace_unavailable_owner_lease(
            replacement_session,
            request_options(owner_instance_id: "node-b")
          )
        end)

      assert {:ok, %CodexSession{}} = replacement_result
      assert_session_before_lease_lock!(replacement_events)

      %{session: continuity_session} = owner_session_fixture()

      {continuity_result, continuity_events} =
        capture_detailed_repo_queries(fn ->
          SessionContinuity.register_codex_session_continuity(
            continuity_session,
            %{},
            %{"id" => "response-placeholder"},
            request_options([])
          )
        end)

      assert :ok = continuity_result
      assert_session_before_lease_lock!(continuity_events)
    end
  end

  describe "Task 7 session and owner-lease contention" do
    @tag :task7_contention
    @tag :task7_red
    test "session_lease_start_first blocks renewal on session before lease" do
      records =
        run_direction(@start_first_direction, fn fixture ->
          {
            fn ->
              Gateway.start_codex_session(fixture.auth, %{
                session_key: fixture.session_key,
                owner_instance_id: "node-a"
              })
            end,
            fn ->
              SessionContinuity.renew_owner_token(
                fixture.session.id,
                fixture.token,
                request_options(bridge_owner_lease_ttl_seconds: 120)
              )
            end
          }
        end)

      assert length(records) == @direction_iterations
      report_direction(@start_first_direction, records)
    end

    @tag :task7_contention
    test "session_lease_renewal_first blocks start on session before lease" do
      records =
        run_direction(@renewal_first_direction, fn fixture ->
          {
            fn ->
              SessionContinuity.renew_owner_token(
                fixture.session.id,
                fixture.token,
                request_options(bridge_owner_lease_ttl_seconds: 120)
              )
            end,
            fn ->
              Gateway.start_codex_session(fixture.auth, %{
                session_key: fixture.session_key,
                owner_instance_id: "node-a"
              })
            end
          }
        end)

      assert length(records) == @direction_iterations
      report_direction(@renewal_first_direction, records)
    end
  end

  describe "Task 7 expired-session frozen boundary" do
    @tag :task7_frozen
    test "close_for_key freezes the old id while a replacement blocks on the partial unique index" do
      fixture = unboxed_expired_replacement_fixture()

      try do
        record =
          with_frozen_query_handler(fn ->
            run_frozen_replacement_schedule(fixture)
          end)

        assert record.boundary_signature == expired_boundary_signature()
        report_frozen_schedule(record)
      after
        cleanup_unboxed_fixture!()
      end
    end

    @tag :task7_start_boundary
    test "real start flow invokes the frozen boundary before inserting the replacement" do
      fixture = unboxed_expired_session_fixture("task7-start-boundary")

      try do
        {result, events} =
          capture_detailed_repo_queries(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Gateway.start_codex_session(fixture.auth, %{
                session_key: fixture.session_key,
                owner_instance_id: "node-replacement"
              })
            end)
          end)

        assert {:ok, %CodexSession{} = replacement} = result
        refute replacement.id == fixture.session.id
        assert boundary_signature(events) == expired_boundary_signature()

        boundary_close =
          Enum.find_index(events, fn event ->
            event.source == "codex_sessions" and event.operation == "UPDATE"
          end)

        replacement_insert =
          Enum.find_index(events, fn event ->
            event.source == "codex_sessions" and event.operation == "INSERT"
          end)

        assert is_integer(boundary_close)
        assert is_integer(replacement_insert)
        assert boundary_close < replacement_insert

        assert %CodexSession{status: "closed"} =
                 Sandbox.unboxed_run(Repo, fn -> Repo.get!(CodexSession, fixture.session.id) end)

        assert %CodexSession{status: "active"} =
                 Sandbox.unboxed_run(Repo, fn -> Repo.get!(CodexSession, replacement.id) end)

        report_start_boundary(events, fixture.session.id)
      after
        cleanup_unboxed_fixture!()
      end
    end
  end

  defp run_frozen_replacement_schedule(fixture) do
    parent = self()
    ref = make_ref()
    observer = start_observer(parent, ref)

    task_a =
      start_frozen_operation(parent, ref, fn ->
        Repo.transaction(fn ->
          ExpiredSessions.close_for_key!(
            fixture.auth.pool.id,
            fixture.session_key,
            fixture.boundary_now
          )
        end)
      end)

    task_b =
      start_operation(
        parent,
        ref,
        :b,
        fn -> update_closed_replacement!(fixture) end,
        pause?: false
      )

    try do
      {_observer_pid, observer_backend_pid} = await_observer_ready!(ref)
      {_a_pid, a_backend_pid} = await_frozen_ready!(ref)
      {_b_pid, b_backend_pid} = await_operation_ready!(ref, :b)

      assert MapSet.size(MapSet.new([observer_backend_pid, a_backend_pid, b_backend_pid])) == 3

      send(task_a.pid, {:task7_run_frozen, ref})
      {events, close_event} = await_frozen_close_barrier!(ref, [])

      send(task_b.pid, {:task7_run, ref})

      observation =
        observe_blocked_session_operation!(
          observer,
          ref,
          b_backend_pid,
          a_backend_pid,
          "UPDATE"
        )

      send(task_a.pid, {:task7_release_frozen, ref})

      assert {:ok, {:ok, {1, nil}}} = Task.await(task_a, 10_000)
      assert {:ok, %CodexSession{status: "interrupted"}} = Task.await(task_b, 10_000)

      send(observer.pid, {:task7_stop_observer, ref})
      assert :ok = Task.await(observer, 5_000)

      events = drain_frozen_events(ref, events)
      assert close_event.source == "codex_sessions"
      assert_frozen_boundary_events!(events, fixture.session.id)

      assert_frozen_replacement_state!(fixture)

      assert {:ok, {1, nil}} =
               Sandbox.unboxed_run(Repo, fn ->
                 Repo.transaction(fn ->
                   ExpiredSessions.close_for_key!(
                     fixture.auth.pool.id,
                     fixture.session_key,
                     DateTime.add(fixture.boundary_now, 10, :second)
                   )
                 end)
               end)

      assert %CodexSession{status: "closed"} =
               Sandbox.unboxed_run(Repo, fn ->
                 Repo.get!(CodexSession, fixture.replacement.id)
               end)

      %{
        kind: "expired_sessions_frozen_set",
        backend_pid_hashes:
          Enum.map([a_backend_pid, b_backend_pid, observer_backend_pid], &sha256/1),
        blocked_replacement: sanitize_block(observation),
        frozen_session_id_sha256: sha256(fixture.session.id),
        replacement_id_sha256: sha256(fixture.replacement.id),
        boundary_signature: boundary_signature(events),
        ordered_id_hashes: ordered_id_hashes(events),
        replacement_untouched_by_first_boundary: true,
        replacement_closed_by_second_boundary: true,
        final_field_names: ["status", "owner_lease_expires_at", "closed_at", "updated_at"]
      }
    after
      send(task_a.pid, {:task7_release_frozen, ref})
      send(task_b.pid, {:task7_release, ref, :b, :session})
      send(task_b.pid, {:task7_release, ref, :b, :lease})
      send(observer.pid, {:task7_stop_observer, ref})
      shutdown_task(task_a)
      shutdown_task(task_b)
      shutdown_task(observer)
    end
  end

  defp start_frozen_operation(parent, ref, operation) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        Process.put(@frozen_context, %{parent: parent, ref: ref})
        send(parent, {:task7_frozen_ready, ref, self(), backend_pid})

        try do
          receive do
            {:task7_run_frozen, ^ref} -> safely_run(operation)
          after
            10_000 -> {:error, :frozen_operation_start_timeout}
          end
        after
          Process.delete(@frozen_context)
          Process.delete(@frozen_sequence)
          Process.delete(@frozen_paused)
        end
      end)
    end)
  end

  defp with_frozen_query_handler(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, :frozen, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_frozen_query(metadata)
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp handle_frozen_query(metadata) do
    case Process.get(@frozen_context) do
      %{parent: parent, ref: ref} ->
        if metadata[:repo] == Repo do
          sequence = Process.get(@frozen_sequence, 0) + 1
          Process.put(@frozen_sequence, sequence)
          event = contention_event(metadata, sequence)
          send(parent, {:task7_frozen_query, ref, event})

          if event.source == "codex_sessions" and event.operation == "UPDATE" and
               not Process.get(@frozen_paused, false) do
            Process.put(@frozen_paused, true)
            send(parent, {:task7_frozen_close_barrier, ref, event})

            receive do
              {:task7_release_frozen, ^ref} -> :ok
            after
              10_000 -> raise "Task 7 frozen close barrier was not released"
            end
          end
        end

      _context ->
        :ok
    end
  end

  defp await_frozen_close_barrier!(ref, events) do
    receive do
      {:task7_frozen_query, ^ref, event} ->
        await_frozen_close_barrier!(ref, events ++ [event])

      {:task7_frozen_close_barrier, ^ref, event} ->
        {events, event}
    after
      10_000 -> flunk("Task 7 frozen session close barrier was not observed")
    end
  end

  defp await_frozen_ready!(ref) do
    receive do
      {:task7_frozen_ready, ^ref, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("Task 7 frozen boundary connection did not become ready")
    end
  end

  defp drain_frozen_events(ref, events) do
    receive do
      {:task7_frozen_query, ^ref, event} -> drain_frozen_events(ref, events ++ [event])
    after
      0 -> events
    end
  end

  defp observe_blocked_session_operation!(
         observer,
         ref,
         waiter_pid,
         blocker_pid,
         expected_operation
       ) do
    request_ref = make_ref()

    send(
      observer.pid,
      {:task7_observe_block, ref, request_ref, waiter_pid, blocker_pid, expected_operation}
    )

    receive do
      {:task7_block_observed, ^ref, ^request_ref, {:error, reason}} ->
        flunk("PostgreSQL observer failed before positive lock evidence: #{inspect(reason)}")

      {:task7_block_observed, ^ref, ^request_ref, observation} ->
        assert observation.wait_event_type == "Lock"
        assert observation.state == "active"
        observation
    after
      6_000 -> flunk("PostgreSQL observer did not return a session blocker observation")
    end
  end

  defp assert_frozen_boundary_events!(events, frozen_session_id) do
    assert boundary_signature(events) == expired_boundary_signature()

    dependent_events =
      Enum.filter(events, fn event ->
        event.source in ["bridge_owner_leases", "bridge_session_aliases"] or
          (event.source == "codex_sessions" and event.operation == "UPDATE")
      end)

    assert dependent_events != []

    Enum.each(dependent_events, fn event ->
      assert uuid_params(event.params) == [frozen_session_id]
      refute String.contains?(String.upcase(event.query), " IN (SELECT")
    end)

    events
    |> Enum.filter(&(&1.operation == "SELECT" and &1.for_update?))
    |> Enum.each(fn event -> assert ordered_primary_key_lock?(event.query) end)
  end

  defp assert_frozen_replacement_state!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      assert %CodexSession{status: "closed"} = Repo.get!(CodexSession, fixture.session.id)

      assert %CodexSession{
               status: "interrupted",
               closed_at: nil,
               owner_lease_expires_at: replacement_expiry,
               updated_at: replacement_updated_at
             } = Repo.get!(CodexSession, fixture.replacement.id)

      assert replacement_expiry == fixture.replacement_expires_at
      assert replacement_updated_at == fixture.replacement_updated_at

      assert %BridgeOwnerLease{status: "expired"} =
               Repo.get!(BridgeOwnerLease, fixture.lease.id)

      assert Enum.all?(
               Repo.all(
                 from alias_record in BridgeSessionAlias,
                   where: alias_record.codex_session_id == ^fixture.session.id
               ),
               &(&1.status == "expired")
             )
    end)
  end

  defp update_closed_replacement!(fixture) do
    fixture.replacement
    |> Ecto.Changeset.change(%{
      status: "interrupted",
      owner_instance_id: "node-replacement",
      owner_lease_token: fixture.replacement_token,
      owner_lease_expires_at: fixture.replacement_expires_at,
      last_heartbeat_at: fixture.replacement_expires_at,
      closed_at: nil,
      updated_at: fixture.replacement_updated_at
    })
    |> Repo.update!()
  end

  defp run_direction(direction_id, operations) do
    Enum.map(1..@direction_iterations, fn iteration ->
      run_direction_iteration(direction_id, iteration, operations)
    end)
  end

  defp run_direction_iteration(direction_id, iteration, operations) do
    fixture = unboxed_owner_session_fixture(direction_id, iteration)

    try do
      with_contention_query_handler(fn ->
        run_contended_operations(direction_id, iteration, fixture, operations.(fixture))
      end)
    after
      cleanup_unboxed_fixture!()
    end
  end

  defp run_contended_operations(direction_id, iteration, fixture, {a_operation, b_operation}) do
    parent = self()
    ref = make_ref()
    observer = start_observer(parent, ref)
    task_a = start_operation(parent, ref, :a, a_operation, pause?: true)
    task_b = start_operation(parent, ref, :b, b_operation, pause?: false)

    try do
      {_observer_pid, observer_backend_pid} = await_observer_ready!(ref)
      {_a_pid, a_backend_pid} = await_operation_ready!(ref, :a)
      {_b_pid, b_backend_pid} = await_operation_ready!(ref, :b)

      assert MapSet.size(MapSet.new([observer_backend_pid, a_backend_pid, b_backend_pid])) == 3

      send(task_a.pid, {:task7_run, ref})
      {_session_event, traces} = await_barrier!(ref, :a, :session, empty_traces())

      send(task_b.pid, {:task7_run, ref})

      {first_block, traces} =
        observe_blocked_before_lease!(
          observer,
          ref,
          :b,
          b_backend_pid,
          a_backend_pid,
          traces
        )

      send(task_a.pid, {:task7_release, ref, :a, :session})
      {_lease_event, traces} = await_barrier!(ref, :a, :lease, traces)

      {second_block, traces} =
        observe_blocked_before_lease!(
          observer,
          ref,
          :b,
          b_backend_pid,
          a_backend_pid,
          traces
        )

      send(task_a.pid, {:task7_release, ref, :a, :lease})

      assert {:ok, {:ok, %CodexSession{}}} = Task.await(task_a, 10_000)
      assert {:ok, {:ok, %CodexSession{}}} = Task.await(task_b, 10_000)

      send(observer.pid, {:task7_stop_observer, ref})
      assert :ok = Task.await(observer, 5_000)

      traces = drain_contention_events(ref, traces)
      assert_canonical_order!(traces.a)
      assert_canonical_order!(traces.b)

      final = final_owner_snapshot(fixture.session.id)
      assert final.active_lease_count == 1
      assert final.session_owner_matches_lease?

      %{
        direction_id: direction_id,
        iteration: iteration,
        backend_pid_hashes:
          Enum.map([a_backend_pid, b_backend_pid, observer_backend_pid], &sha256/1),
        blocker_observations: [sanitize_block(first_block), sanitize_block(second_block)],
        a_order: relation_operation_order(traces.a),
        b_order: relation_operation_order(traces.b),
        final: final
      }
    after
      send(task_a.pid, {:task7_release, ref, :a, :session})
      send(task_a.pid, {:task7_release, ref, :a, :lease})
      send(task_b.pid, {:task7_release, ref, :b, :session})
      send(task_b.pid, {:task7_release, ref, :b, :lease})
      send(observer.pid, {:task7_stop_observer, ref})
      shutdown_task(task_a)
      shutdown_task(task_b)
      shutdown_task(observer)
    end
  end

  defp with_contention_query_handler(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, :contention, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_contention_query(metadata)
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp handle_contention_query(metadata) do
    case Process.get(@contention_context) do
      %{parent: parent, ref: ref, role: role} = context ->
        if metadata[:repo] == Repo do
          sequence = Process.get(@contention_sequence, 0) + 1
          Process.put(@contention_sequence, sequence)
          event = contention_event(metadata, sequence)
          send(parent, {:task7_query, ref, role, event})
          maybe_pause_contention(context, event)
        end

      _context ->
        :ok
    end
  end

  defp contention_event(metadata, sequence) do
    query = Map.get(metadata, :query, "")
    upcased_query = String.upcase(query)

    %{
      sequence: sequence,
      source: metadata[:source],
      operation: command_name(query),
      for_update?: String.contains?(upcased_query, "FOR UPDATE"),
      params: Map.get(metadata, :params, []),
      query: query,
      query_sha256: sha256(query)
    }
  end

  defp maybe_pause_contention(%{pause?: true} = context, event) do
    cond do
      session_lock_event?(event) -> pause_contention(context, :session, event)
      lease_lock_event?(event) -> pause_contention(context, :lease, event)
      true -> :ok
    end
  end

  defp maybe_pause_contention(_context, _event), do: :ok

  defp pause_contention(context, family, event) do
    pause_key = {@contention_paused, family}

    unless Process.get(pause_key, false) do
      Process.put(pause_key, true)
      send(context.parent, {:task7_barrier, context.ref, context.role, family, event})

      receive do
        {:task7_release, ref, role, ^family}
        when ref == context.ref and role == context.role ->
          :ok
      after
        10_000 -> raise "Task 7 #{family} barrier was not released"
      end
    end
  end

  defp start_operation(parent, ref, role, operation, opts) do
    pause? = Keyword.fetch!(opts, :pause?)

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()

        Process.put(@contention_context, %{
          parent: parent,
          ref: ref,
          role: role,
          pause?: pause?
        })

        send(parent, {:task7_operation_ready, ref, role, self(), backend_pid})

        try do
          receive do
            {:task7_run, ^ref} -> safely_run(operation)
          after
            10_000 -> {:error, :operation_start_timeout}
          end
        after
          Process.delete(@contention_context)
          Process.delete(@contention_sequence)
          Process.delete({@contention_paused, :session})
          Process.delete({@contention_paused, :lease})
        end
      end)
    end)
  end

  defp safely_run(operation) do
    {:ok, operation.()}
  rescue
    exception -> {:error, exception.__struct__, Exception.message(exception)}
  catch
    kind, reason -> {:error, kind, inspect(reason)}
  end

  defp start_observer(parent, ref) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        send(parent, {:task7_observer_ready, ref, self(), backend_pid})
        observer_loop(parent, ref)
      end)
    end)
  end

  defp observer_loop(parent, ref) do
    receive do
      {:task7_observe_block, ^ref, request_ref, waiter_pid, blocker_pid, expected_operation} ->
        observation = observe_session_block(waiter_pid, blocker_pid, expected_operation)
        send(parent, {:task7_block_observed, ref, request_ref, observation})
        observer_loop(parent, ref)

      {:task7_stop_observer, ^ref} ->
        :ok
    after
      15_000 -> {:error, :observer_timeout}
    end
  end

  defp observe_session_block(waiter_pid, blocker_pid, expected_operation) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_observe_session_block(waiter_pid, blocker_pid, expected_operation, deadline)
  end

  defp do_observe_session_block(waiter_pid, blocker_pid, expected_operation, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT pg_blocking_pids($1), wait_event_type, wait_event, state, query
        FROM pg_stat_activity
        WHERE pid = $1
        """,
        [waiter_pid]
      )

    case rows do
      [[blocking_pids, "Lock", wait_event, "active", query]] ->
        if blocker_pid in blocking_pids and
             blocked_session_operation?(query, expected_operation) do
          %{
            blocking_pids: blocking_pids,
            wait_event_type: "Lock",
            wait_event: wait_event,
            state: "active",
            operation: expected_operation,
            query: query
          }
        else
          retry_session_block(waiter_pid, blocker_pid, expected_operation, deadline)
        end

      _rows ->
        retry_session_block(waiter_pid, blocker_pid, expected_operation, deadline)
    end
  end

  defp retry_session_block(waiter_pid, blocker_pid, expected_operation, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :session_block_not_observed}
    else
      do_observe_session_block(waiter_pid, blocker_pid, expected_operation, deadline)
    end
  end

  defp observe_blocked_before_lease!(
         observer,
         ref,
         role,
         waiter_pid,
         blocker_pid,
         traces
       ) do
    request_ref = make_ref()

    send(
      observer.pid,
      {:task7_observe_block, ref, request_ref, waiter_pid, blocker_pid, "SELECT"}
    )

    await_blocked_before_lease!(ref, role, request_ref, traces)
  end

  defp await_blocked_before_lease!(ref, role, request_ref, traces) do
    receive do
      {:task7_query, ^ref, ^role, event} ->
        traces = append_trace(traces, role, event)

        if event.source == "bridge_owner_leases" do
          flunk(
            "bridge_owner_leases #{event.operation} completed before the blocked codex_sessions SELECT FOR UPDATE"
          )
        end

        await_blocked_before_lease!(ref, role, request_ref, traces)

      {:task7_query, ^ref, other_role, event} when other_role in [:a, :b] ->
        await_blocked_before_lease!(
          ref,
          role,
          request_ref,
          append_trace(traces, other_role, event)
        )

      {:task7_block_observed, ^ref, ^request_ref, {:error, reason}} ->
        flunk("PostgreSQL observer failed before positive lock evidence: #{inspect(reason)}")

      {:task7_block_observed, ^ref, ^request_ref, observation} ->
        assert observation.wait_event_type == "Lock"
        assert observation.state == "active"
        {observation, traces}
    after
      6_000 -> flunk("PostgreSQL observer did not return a session blocker observation")
    end
  end

  defp await_barrier!(ref, role, family, traces) do
    receive do
      {:task7_query, ^ref, query_role, event} when query_role in [:a, :b] ->
        if query_role == :b and family == :lease and event.source == "bridge_owner_leases" do
          flunk("blocked operation reached bridge_owner_leases before session release")
        end

        await_barrier!(ref, role, family, append_trace(traces, query_role, event))

      {:task7_barrier, ^ref, ^role, ^family, event} ->
        {event, traces}
    after
      10_000 -> flunk("Task 7 #{role} #{family} barrier was not observed")
    end
  end

  defp await_observer_ready!(ref) do
    receive do
      {:task7_observer_ready, ^ref, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("Task 7 observer connection did not become ready")
    end
  end

  defp await_operation_ready!(ref, role) do
    receive do
      {:task7_operation_ready, ^ref, ^role, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("Task 7 #{role} connection did not become ready")
    end
  end

  defp drain_contention_events(ref, traces) do
    receive do
      {:task7_query, ^ref, role, event} when role in [:a, :b] ->
        drain_contention_events(ref, append_trace(traces, role, event))
    after
      0 -> traces
    end
  end

  defp empty_traces, do: %{a: [], b: []}

  defp append_trace(traces, role, event) do
    Map.update!(traces, role, &(&1 ++ [event]))
  end

  defp assert_canonical_order!(events) do
    session_index = Enum.find_index(events, &session_lock_event?/1)
    lease_index = Enum.find_index(events, &lease_lock_event?/1)

    assert is_integer(session_index)
    assert is_integer(lease_index)
    assert session_index < lease_index
  end

  defp assert_session_before_lease_lock!(events) do
    assert_canonical_order!(events)

    refute events
           |> Enum.take_while(&(not session_lock_event?(&1)))
           |> Enum.any?(&(&1.source == "bridge_owner_leases"))
  end

  defp relation_operation_order(events) do
    events
    |> Enum.filter(&(&1.source in ["codex_sessions", "bridge_owner_leases"]))
    |> Enum.map(fn event ->
      %{
        relation: event.source,
        operation: event.operation,
        lock: if(event.for_update?, do: "FOR UPDATE", else: nil),
        query_sha256: event.query_sha256
      }
    end)
  end

  defp session_lock_event?(event) do
    event.source == "codex_sessions" and event.operation == "SELECT" and event.for_update?
  end

  defp lease_lock_event?(event) do
    event.source == "bridge_owner_leases" and event.operation == "SELECT" and
      event.for_update?
  end

  defp blocked_session_operation?(query, operation) when is_binary(query) do
    upcased_query = String.upcase(query)

    String.starts_with?(String.trim_leading(upcased_query), operation) and
      String.contains?(upcased_query, "CODEX_SESSIONS") and
      (operation != "SELECT" or String.contains?(upcased_query, "FOR UPDATE"))
  end

  defp blocked_session_operation?(_query, _operation), do: false

  defp final_owner_snapshot(session_id) do
    Sandbox.unboxed_run(Repo, fn ->
      session = Repo.get!(CodexSession, session_id)

      leases =
        Repo.all(
          from lease in BridgeOwnerLease,
            where: lease.codex_session_id == ^session_id and lease.status == "active",
            order_by: [asc: lease.id]
        )

      active_lease = List.first(leases)

      %{
        active_lease_count: length(leases),
        session_owner_matches_lease?:
          match?(%BridgeOwnerLease{}, active_lease) and
            session.owner_instance_id == active_lease.owner_instance_id and
            session.owner_lease_token == active_lease.lease_token and
            session.owner_lease_expires_at == active_lease.expires_at,
        final_field_names: [
          "status",
          "owner_instance_id",
          "owner_lease_token",
          "owner_lease_expires_at"
        ],
        session_status: session.status,
        lease_status: if(active_lease, do: active_lease.status)
      }
    end)
  end

  defp sanitize_block(observation) do
    %{
      blocking_pid_hashes: Enum.map(observation.blocking_pids, &sha256/1),
      wait_event_type: observation.wait_event_type,
      wait_event: observation.wait_event,
      state: observation.state,
      relation: "codex_sessions",
      operation: observation.operation,
      lock: if(observation.operation == "SELECT", do: "FOR UPDATE", else: "ROW/UNIQUE INDEX"),
      query_sha256: sha256(observation.query)
    }
  end

  defp report_direction(direction_id, records) do
    if path = System.get_env("TASK7_MANUAL_QA_PATH") do
      record = %{
        kind: "session_lease_direction",
        direction_id: direction_id,
        iterations: length(records),
        records: records
      }

      File.write!(path, Jason.encode!(record) <> "\n", [:append])
    end
  end

  defp shutdown_task(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp capture_detailed_repo_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, :detailed, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and self() == parent do
            send(parent, {handler_id, contention_event(metadata, 0)})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_detailed_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_detailed_queries(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_detailed_queries(handler_id, events ++ [event])
    after
      0 -> events
    end
  end

  defp boundary_signature(events) do
    events
    |> boundary_events()
    |> Enum.map(fn event ->
      %{
        relation: event.source,
        operation: event.operation,
        lock: if(event.for_update?, do: "FOR UPDATE", else: nil),
        ordered_by_primary_key:
          event.operation != "SELECT" or ordered_primary_key_lock?(event.query)
      }
    end)
  end

  defp boundary_events(events) do
    case Enum.split_while(events, &(not expired_session_lock_event?(&1))) do
      {_before, []} ->
        []

      {_before, from_boundary} ->
        Enum.reduce_while(from_boundary, [], fn event, acc ->
          if boundary_relation_event?(event) do
            next = acc ++ [event]

            if event.source == "codex_sessions" and event.operation == "UPDATE" do
              {:halt, next}
            else
              {:cont, next}
            end
          else
            {:cont, acc}
          end
        end)
    end
  end

  defp expired_boundary_signature do
    [
      %{
        relation: "codex_sessions",
        operation: "SELECT",
        lock: "FOR UPDATE",
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_owner_leases",
        operation: "SELECT",
        lock: "FOR UPDATE",
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_session_aliases",
        operation: "SELECT",
        lock: "FOR UPDATE",
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_owner_leases",
        operation: "UPDATE",
        lock: nil,
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_session_aliases",
        operation: "UPDATE",
        lock: nil,
        ordered_by_primary_key: true
      },
      %{
        relation: "codex_sessions",
        operation: "UPDATE",
        lock: nil,
        ordered_by_primary_key: true
      }
    ]
  end

  defp expired_session_lock_event?(event) do
    event.source == "codex_sessions" and event.operation == "SELECT" and event.for_update? and
      String.contains?(String.upcase(event.query), "OWNER_LEASE_EXPIRES_AT") and
      ordered_primary_key_lock?(event.query)
  end

  defp boundary_relation_event?(event) do
    event.source in ["codex_sessions", "bridge_owner_leases", "bridge_session_aliases"] and
      event.operation in ["SELECT", "UPDATE"]
  end

  defp ordered_primary_key_lock?(query) do
    String.contains?(String.upcase(query), "ORDER BY") and
      Regex.match?(~r/ORDER BY\s+[^;]*\."id"(?:\s+ASC)?/i, query) and
      String.contains?(String.upcase(query), "FOR UPDATE")
  end

  defp uuid_params(params) do
    params
    |> flatten_params()
    |> Enum.flat_map(fn value ->
      case Ecto.UUID.cast(value) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp flatten_params(values) when is_list(values), do: Enum.flat_map(values, &flatten_params/1)
  defp flatten_params(value), do: [value]

  defp ordered_id_hashes(events) do
    events
    |> boundary_events()
    |> Enum.reject(&expired_session_lock_event?/1)
    |> Enum.map(fn event ->
      %{
        relation: event.source,
        operation: event.operation,
        id_sha256: Enum.map(uuid_params(event.params), &sha256/1)
      }
    end)
  end

  defp report_frozen_schedule(record) do
    if path = System.get_env("TASK7_MANUAL_QA_PATH") do
      File.write!(path, Jason.encode!(record) <> "\n", [:append])
    end
  end

  defp report_start_boundary(events, frozen_session_id) do
    if path = System.get_env("TASK7_MANUAL_QA_PATH") do
      record = %{
        kind: "expired_sessions_start_boundary",
        boundary_signature: boundary_signature(events),
        frozen_session_id_sha256: sha256(frozen_session_id),
        ordered_id_hashes: ordered_id_hashes(events),
        start_after_close: true
      }

      File.write!(path, Jason.encode!(record) <> "\n", [:append])
    end
  end

  defp unboxed_expired_replacement_fixture do
    fixture = unboxed_expired_session_fixture("task7-frozen")

    Sandbox.unboxed_run(Repo, fn ->
      replacement =
        %CodexSession{
          pool_id: fixture.auth.pool.id,
          api_key_id: fixture.auth.api_key.id,
          session_key: fixture.session_key,
          status: "closed",
          closed_at: fixture.boundary_now,
          created_at: fixture.boundary_now,
          updated_at: fixture.boundary_now
        }
        |> Repo.insert!()

      Map.merge(fixture, %{
        replacement: replacement,
        replacement_token: Ecto.UUID.generate(),
        replacement_expires_at: DateTime.add(fixture.boundary_now, -30, :second),
        replacement_updated_at: DateTime.add(fixture.boundary_now, 1, :second)
      })
    end)
  end

  defp unboxed_expired_session_fixture(prefix) do
    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth = auth_fixture()

      session_key =
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 session_key: session_key,
                 owner_instance_id: "node-old"
               })

      boundary_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expired_at = DateTime.add(boundary_now, -60, :second)
      session = Repo.get!(CodexSession, session.id)
      lease = active_lease!(session.id)

      session
      |> Ecto.Changeset.change(%{
        owner_lease_expires_at: expired_at,
        last_heartbeat_at: expired_at,
        updated_at: expired_at
      })
      |> Repo.update!()

      lease
      |> Ecto.Changeset.change(%{expires_at: expired_at, updated_at: expired_at})
      |> Repo.update!()

      %{
        auth: auth,
        boundary_now: boundary_now,
        lease: lease,
        session: Repo.get!(CodexSession, session.id),
        session_key: session_key
      }
    end)
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        order_by: [asc: lease.id],
        limit: 1
    )
  end

  defp unboxed_owner_session_fixture(direction_id, iteration) do
    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth = auth_fixture()

      session_key =
        "task7-#{direction_id}-#{iteration}-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 session_key: session_key,
                 owner_instance_id: "node-a"
               })

      session = Repo.get!(CodexSession, session.id)

      %{
        auth: auth,
        session: session,
        session_key: session_key,
        token: session.owner_lease_token
      }
    end)
  end

  defp cleanup_unboxed_fixture! do
    Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end)
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture do
    auth = auth_fixture()

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state:
                 "task-7-pin-#{System.unique_integer([:positive, :monotonic])}",
               owner_instance_id: "node-a"
             })

    session = Repo.get!(CodexSession, session.id)
    %{auth: auth, session: session, token: session.owner_lease_token}
  end

  defp token_lease_id(token) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.lease_token == ^token,
        select: lease.id
    )
  end

  defp request_options(opts) do
    opts
    |> Map.new()
    |> RequestOptions.for_websocket()
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            query = Map.get(metadata, :query, "")

            send(parent, {
              handler_id,
              %{
                source: metadata[:source],
                command: command_name(query),
                for_update?: String.contains?(String.upcase(query), "FOR UPDATE"),
                in_transaction?: Repo.in_transaction?()
              }
            })
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_repo_queries(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp sha256(value) do
    value
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
