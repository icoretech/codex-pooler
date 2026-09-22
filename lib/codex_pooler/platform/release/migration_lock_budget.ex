defmodule CodexPooler.Release.MigrationLockBudget do
  @moduledoc """
  Bounded waiting for migrations that build or drop indexes concurrently.

  A migration used to run with one `lock_timeout` of ten seconds, which PostgreSQL applies to every
  lock wait of a statement. `CREATE INDEX CONCURRENTLY` and `DROP INDEX CONCURRENTLY` wait on two
  different things:

    * a table lock (`pg_locks.locktype` `relation`, or a row lock such as `transactionid`): a real
      lock queue, where waiting longer can hold up other sessions. It keeps the short budget
      (10 seconds by default);
    * another transaction's virtual transaction id (`virtualxid`): the concurrent build waits for
      every transaction that writes the table or holds a snapshot older than the build, and the
      concurrent drop for every transaction that uses the table. Nothing queues behind this wait
      and application reads and writes continue, so a `pg_dump`, a reporting query or an idle
      `psql` transaction merely delays the migration. It gets a longer budget
      (5 minutes in total per `run/3` by default).

  One statement-level timeout cannot tell the two apart, so `run/3` sets `lock_timeout` to the
  longer budget as a backstop and a watcher on its own connection samples the migration backend's
  lock wait twice a second: it cancels the statement when a table or row lock wait passes the short
  budget or when the time spent waiting for other transactions passes the long one, and logs the
  blocking sessions while it waits. When the watcher cannot start, the statement runs with the
  short `lock_timeout` for every wait, which is the behaviour before this helper.

  On either timeout the migration raises `CodexPooler.Release.MigrationLockBudget.Error`, naming the
  blocking sessions by pid, `application_name`, backend type, state, transaction age and whether they
  hold a snapshot, never their query text. An interrupted concurrent build leaves an INVALID index
  that the calling migration's convergence step drops and rebuilds on the next run.

  Migrations under `priv/repo/migrations` call `run/3`, so its name and arity are a permanent
  contract: a migration that has already shipped compiles against it on every fresh database.
  """

  require Logger

  @lock_wait_ms 10_000
  @transaction_wait_ms 300_000
  @poll_interval_ms 500
  @notice_after_ms 5_000
  @notice_interval_ms 30_000
  @watch_start_timeout_ms 5_000
  @watch_stop_timeout_ms 5_000
  @watch_application_name "codex_pooler_migrate_watch"
  @max_listed_blockers 10
  @connect_keys [:hostname, :port, :username, :password, :database, :socket_dir, :socket, :ssl, :socket_options, :connect_timeout, :handshake_timeout, :endpoints]

  defmodule Error do
    @moduledoc "A migration statement exhausted its lock budget; the message names the blocking sessions."
    defexception [:reason, :waited_ms, :budget_ms, :blockers, :postgres_code, :message]

    @type t :: %__MODULE__{
            reason: :lock_wait | :transaction_wait | :unclassified,
            waited_ms: non_neg_integer() | nil,
            budget_ms: pos_integer(),
            blockers: [map()],
            postgres_code: atom() | nil,
            message: String.t()
          }
  end

  @type option ::
          {:lock_wait_ms, pos_integer()}
          | {:transaction_wait_ms, pos_integer()}
          | {:poll_interval_ms, pos_integer()}

  @doc """
  Runs `fun` on one checked-out connection of `repo` with the migration lock budget.

  Options: `:lock_wait_ms` (each table or row lock wait, default 10 000),
  `:transaction_wait_ms` (total wait for other transactions, default 300 000) and
  `:poll_interval_ms` (watcher sampling, default 500). The previous `lock_timeout` of the
  connection is restored afterwards.
  """
  @spec run(module(), (-> result), [option()]) :: result when result: term()
  def run(repo, fun, opts \\ []) when is_atom(repo) and is_function(fun, 0) and is_list(opts) do
    budget = %{
      lock_wait_ms: Keyword.get(opts, :lock_wait_ms, @lock_wait_ms),
      transaction_wait_ms: Keyword.get(opts, :transaction_wait_ms, @transaction_wait_ms),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    }

    repo.checkout(fn -> run_checked_out(repo, fun, budget) end, timeout: :infinity)
  end

  defp run_checked_out(repo, fun, budget) do
    [[backend_pid]] = query!(repo, "SELECT pg_backend_pid()", []).rows
    [[previous_timeout]] = query!(repo, "SHOW lock_timeout", []).rows
    watch = start_watch(repo, backend_pid, budget)

    backstop_ms =
      if watch, do: budget.transaction_wait_ms + budget.lock_wait_ms, else: budget.lock_wait_ms

    query!(repo, "SELECT set_config('lock_timeout', $1, false)", ["#{backstop_ms}ms"])

    try do
      case capture(fun) do
        {:ok, result} ->
          result

        {:postgrex_error, error, stacktrace} ->
          report = stop_watch(watch)
          reraise translate(error, report, repo, backend_pid, budget), stacktrace
      end
    after
      _report = stop_watch(watch)
      query!(repo, "SELECT set_config('lock_timeout', $1, false)", [previous_timeout])
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  rescue
    error in Postgrex.Error -> {:postgrex_error, error, __STACKTRACE__}
  end

  defp translate(%Postgrex.Error{} = error, report, repo, backend_pid, budget) do
    code = postgres_code(error)

    cond do
      report.canceled != nil and code == :query_canceled ->
        %{reason: reason, waited_ms: waited_ms, blockers: blockers} = report.canceled
        build_error(reason, waited_ms, budget_for(reason, budget), blockers, code)

      code == :lock_not_available ->
        {reason, waited_ms, blockers} = timeout_context(lock_timeout?(error), report, repo, backend_pid)
        build_error(reason, waited_ms, budget_for(reason, budget), blockers, code)

      true ->
        error
    end
  end

  # PostgreSQL refused the lock itself: the backstop when the watcher ran, the short budget when it
  # could not start, or a `NOWAIT` lock. The watcher's last sample names the blockers of a timed-out
  # wait; without one the wait cannot be classified and the open transactions of this database are
  # the candidates.
  defp timeout_context(true, %{last_wait: %{reason: reason, waited_ms: waited_ms, blockers: blockers}}, _repo, _backend_pid),
    do: {reason, waited_ms, blockers}

  defp timeout_context(_timeout?, _report, repo, backend_pid) do
    blockers =
      case repo.query(open_transactions_sql(), [backend_pid], log: false) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &blocker_from_row/1)
        {:error, _error} -> []
      end

    {:unclassified, nil, blockers}
  end

  defp lock_timeout?(%Postgrex.Error{postgres: %{message: message}}) when is_binary(message),
    do: String.contains?(message, "lock timeout")

  defp lock_timeout?(%Postgrex.Error{}), do: false

  defp budget_for(:transaction_wait, budget), do: budget.transaction_wait_ms
  defp budget_for(_lock_wait_or_unclassified, budget), do: budget.lock_wait_ms

  defp build_error(reason, waited_ms, budget_ms, blockers, code) do
    %Error{
      reason: reason,
      waited_ms: waited_ms,
      budget_ms: budget_ms,
      blockers: blockers,
      postgres_code: code,
      message: error_message(reason, waited_ms, budget_ms, blockers, code)
    }
  end

  defp error_message(:transaction_wait, waited_ms, budget_ms, blockers, code) do
    "migration stopped after waiting #{seconds(waited_ms)} s for other transactions to finish " <>
      "(budget #{seconds(budget_ms)} s). CREATE INDEX CONCURRENTLY and DROP INDEX CONCURRENTLY wait " <>
      "for every transaction that uses the table or holds a snapshot older than the index build; " <>
      "this wait does not block application reads or writes. Blocking sessions: " <>
      describe_blockers(blockers) <>
      ". End those transactions or let them finish (a backup, a reporting query or an idle " <>
      "psql session), then run the migration again: an interrupted concurrent index build is " <>
      "dropped and rebuilt on the next run. (PostgreSQL #{code})"
  end

  defp error_message(:lock_wait, waited_ms, budget_ms, blockers, code) do
    "migration stopped after waiting #{seconds(waited_ms)} s for a table or row lock " <>
      "(budget #{seconds(budget_ms)} s). Sessions holding the conflicting lock: " <>
      describe_blockers(blockers) <>
      ". Finish or end those sessions, then run the migration again; nothing of the interrupted " <>
      "statement was recorded. (PostgreSQL #{code})"
  end

  defp error_message(:unclassified, _waited_ms, budget_ms, blockers, code) do
    "migration stopped because a lock was not available within #{seconds(budget_ms)} s or at all " <>
      "(NOWAIT), and the wait could not be sampled. Open transactions in this database: " <>
      describe_blockers(blockers) <>
      ". Finish or end the session holding the lock, then run the migration again; an " <>
      "interrupted concurrent index build is dropped and rebuilt on the next run. (PostgreSQL #{code})"
  end

  defp describe_blockers([]), do: "none observed (the blocking transaction ended before it could be sampled)"

  defp describe_blockers(blockers) do
    {listed, rest} = Enum.split(blockers, @max_listed_blockers)
    described = Enum.map_join(listed, "; ", &describe_blocker/1)

    case length(rest) do
      0 -> described
      more -> "#{described}; and #{more} more"
    end
  end

  defp describe_blocker(blocker) do
    "pid=#{blocker.pid} application_name=#{quote_text(blocker.application_name)} " <>
      "backend_type=#{quote_text(blocker.backend_type)} state=#{quote_text(blocker.state)} " <>
      "transaction_age_s=#{blocker.transaction_age_s || "unknown"} holds_snapshot=#{blocker.holds_snapshot}"
  end

  defp quote_text(nil), do: "unknown"

  defp quote_text(text) when is_binary(text) do
    printable =
      text
      |> String.slice(0, 64)
      |> String.replace(~r/[^\x20-\x21\x23-\x5b\x5d-\x7e]/u, "?")

    ~s("#{printable}")
  end

  defp seconds(ms), do: div(ms + 500, 1000)

  defp postgres_code(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code), do: code
  defp postgres_code(%Postgrex.Error{}), do: nil

  defp query!(repo, sql, params), do: repo.query!(sql, params, log: false)

  ## Watcher

  defp start_watch(repo, backend_pid, budget) do
    parent = self()
    ref = make_ref()
    options = watch_connect_options(repo)
    {pid, monitor} = spawn_monitor(fn -> watch_init(parent, ref, options, backend_pid, budget) end)

    receive do
      {^ref, :ready} ->
        %{pid: pid, monitor: monitor, ref: ref}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Logger.warning("migration lock watcher did not start (#{watch_failure(reason)}); every lock wait keeps the #{budget.lock_wait_ms} ms lock_timeout")
        nil
    after
      @watch_start_timeout_ms ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        Logger.warning("migration lock watcher did not start in time; every lock wait keeps the #{budget.lock_wait_ms} ms lock_timeout")
        nil
    end
  end

  defp watch_failure({:shutdown, {:watch_connect_failed, module}}), do: "cannot connect: #{inspect(module)}"
  defp watch_failure({%{__exception__: true} = exception, _stacktrace}), do: inspect(exception.__struct__)
  defp watch_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp watch_failure(_reason), do: "exit"

  defp watch_connect_options(repo) do
    repo.config()
    |> Keyword.take(@connect_keys)
    |> Keyword.merge(
      pool_size: 1,
      backoff_type: :stop,
      parameters: [application_name: @watch_application_name]
    )
  end

  # Idempotent: the error path stops the watcher to read its report and the `after` block stops
  # it again. A watcher that does not answer in time is killed.
  defp stop_watch(nil), do: empty_report()

  defp stop_watch(%{pid: pid, monitor: monitor, ref: ref}) do
    if Process.alive?(pid) do
      send(pid, {:stop, self(), ref})

      receive do
        {^ref, report} ->
          await_down(monitor, pid)
          report

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          empty_report()
      after
        @watch_stop_timeout_ms ->
          Process.exit(pid, :kill)
          await_down(monitor, pid)
          empty_report()
      end
    else
      Process.demonitor(monitor, [:flush])
      empty_report()
    end
  end

  defp await_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @watch_stop_timeout_ms -> Process.demonitor(monitor, [:flush])
    end

    :ok
  end

  defp empty_report, do: %{canceled: nil, last_wait: nil}

  defp watch_init(parent, ref, options, backend_pid, budget) do
    parent_monitor = Process.monitor(parent)
    {:ok, conn} = Postgrex.start_link(options)

    case Postgrex.query(conn, "SELECT 1", []) do
      {:ok, %Postgrex.Result{}} -> send(parent, {ref, :ready})
      {:error, error} -> exit({:shutdown, {:watch_connect_failed, error.__struct__}})
    end

    watch_loop(%{
      conn: conn,
      parent: parent,
      parent_monitor: parent_monitor,
      ref: ref,
      backend_pid: backend_pid,
      budget: budget,
      completed_transaction_ms: 0,
      current_key: nil,
      current_ms: 0,
      last_notice_ms: nil,
      canceled: nil,
      last_wait: nil
    })
  end

  defp watch_loop(state) do
    receive do
      {:stop, from, ref} when ref == state.ref ->
        send(from, {ref, %{canceled: state.canceled, last_wait: state.last_wait}})
        GenServer.stop(state.conn)

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.parent_monitor ->
        GenServer.stop(state.conn)
    after
      state.budget.poll_interval_ms ->
        state |> sample() |> watch_loop()
    end
  end

  defp sample(state) do
    case Postgrex.query(state.conn, wait_sql(), [state.backend_pid]) do
      {:ok, %Postgrex.Result{rows: []}} -> finish_current_wait(state)
      {:ok, %Postgrex.Result{rows: [row | _rows]}} -> observe_wait(state, row)
      {:error, _error} -> state
    end
  end

  defp finish_current_wait(state) do
    %{state | completed_transaction_ms: state.completed_transaction_ms + state.current_ms, current_key: nil, current_ms: 0}
  end

  defp observe_wait(state, ["virtualxid", target, waitstart, waited_ms, blocker_pids]) do
    key = {target, waitstart}
    wait = %{locktype: "virtualxid", target: target, waitstart: waitstart}

    state =
      if key == state.current_key do
        %{state | current_ms: waited_ms}
      else
        %{finish_current_wait(state) | current_key: key, current_ms: waited_ms}
      end

    total_ms = state.completed_transaction_ms + state.current_ms
    blockers = describe_pids(state.conn, blocker_pids)
    state = %{state | last_wait: %{reason: :transaction_wait, waited_ms: total_ms, blockers: blockers}}

    cond do
      state.canceled != nil -> state
      total_ms >= state.budget.transaction_wait_ms -> cancel(state, wait, :transaction_wait, total_ms, blockers)
      true -> maybe_notice(state, total_ms, blockers)
    end
  end

  defp observe_wait(state, [locktype, target, waitstart, waited_ms, blocker_pids]) do
    wait = %{locktype: locktype, target: target, waitstart: waitstart}
    state = finish_current_wait(state)
    blockers = describe_pids(state.conn, blocker_pids)
    state = %{state | last_wait: %{reason: :lock_wait, waited_ms: waited_ms, blockers: blockers}}

    if state.canceled == nil and waited_ms >= state.budget.lock_wait_ms do
      cancel(state, wait, :lock_wait, waited_ms, blockers)
    else
      state
    end
  end

  defp cancel(state, wait, reason, waited_ms, blockers) do
    case cancel_if_still_waiting(state.conn, state.backend_pid, wait) do
      :canceled -> %{state | canceled: %{reason: reason, waited_ms: waited_ms, blockers: blockers}}
      :not_waiting -> state
    end
  end

  @doc false
  # Cancels the migration backend only while it is still in the sampled wait: the lock type, the
  # waited virtual transaction id and the wait's start time must match in the same statement that
  # sends the cancel. A plain `pg_cancel_backend` a sample (and a blocker lookup) after the wait was
  # observed would otherwise hit the migration's next statement when the wait ended in between
  # (findings#255 row 255-61); a wait that ended is sampled again on the next poll.
  @spec cancel_if_still_waiting(GenServer.server(), pos_integer(), %{locktype: String.t(), target: String.t(), waitstart: String.t()}) ::
          :canceled | :not_waiting
  def cancel_if_still_waiting(conn, backend_pid, %{locktype: locktype, target: target, waitstart: waitstart}) do
    case Postgrex.query(conn, cancel_sql(), [backend_pid, locktype, target, waitstart]) do
      {:ok, %Postgrex.Result{rows: [[true]]}} -> :canceled
      _not_waiting_or_failed -> :not_waiting
    end
  end

  defp maybe_notice(state, total_ms, blockers) do
    now = System.monotonic_time(:millisecond)

    due? =
      case state.last_notice_ms do
        nil -> total_ms >= @notice_after_ms
        last -> now - last >= @notice_interval_ms
      end

    if due? do
      Logger.warning(
        "migration is waiting for other transactions to finish before its concurrent index statement can complete " <>
          "(#{seconds(total_ms)} s of #{seconds(state.budget.transaction_wait_ms)} s; application reads and writes continue). " <>
          "Blocking sessions: #{describe_blockers(blockers)}"
      )

      %{state | last_notice_ms: now}
    else
      state
    end
  end

  defp describe_pids(_conn, []), do: []

  defp describe_pids(conn, pids) do
    case Postgrex.query(conn, blockers_sql(), [pids]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        described = Enum.map(rows, &blocker_from_row/1)
        seen = MapSet.new(described, & &1.pid)
        unseen = for pid <- pids, not MapSet.member?(seen, pid), do: unknown_blocker(pid)
        described ++ unseen

      {:error, _error} ->
        Enum.map(pids, &unknown_blocker/1)
    end
  end

  defp unknown_blocker(pid), do: %{pid: pid, application_name: nil, backend_type: nil, state: nil, transaction_age_s: nil, holds_snapshot: nil}

  defp blocker_from_row([pid, application_name, backend_type, state, transaction_age_s, holds_snapshot]) do
    %{
      pid: pid,
      application_name: application_name,
      backend_type: backend_type,
      state: state,
      transaction_age_s: transaction_age_s,
      holds_snapshot: holds_snapshot
    }
  end

  defp wait_sql do
    """
    SELECT l.locktype,
           coalesce(l.virtualxid, ''),
           coalesce(l.waitstart::text, ''),
           coalesce((extract(epoch FROM clock_timestamp() - l.waitstart) * 1000)::bigint, 0),
           pg_blocking_pids(l.pid)
    FROM pg_locks l
    WHERE l.pid = $1 AND NOT l.granted
    LIMIT 1
    """
  end

  defp cancel_sql do
    """
    SELECT pg_cancel_backend(l.pid)
    FROM pg_locks l
    WHERE l.pid = $1 AND NOT l.granted
      AND l.locktype = $2
      AND coalesce(l.virtualxid, '') = $3
      AND coalesce(l.waitstart::text, '') = $4
    LIMIT 1
    """
  end

  defp blockers_sql do
    """
    SELECT a.pid, a.application_name, a.backend_type, a.state,
           (extract(epoch FROM clock_timestamp() - a.xact_start))::bigint,
           a.backend_xmin IS NOT NULL
    FROM pg_stat_activity a
    WHERE a.pid = ANY($1::int[])
    ORDER BY a.xact_start NULLS LAST, a.pid
    """
  end

  defp open_transactions_sql do
    """
    SELECT a.pid, a.application_name, a.backend_type, a.state,
           (extract(epoch FROM clock_timestamp() - a.xact_start))::bigint,
           a.backend_xmin IS NOT NULL
    FROM pg_stat_activity a
    WHERE a.datname = current_database()
      AND a.pid <> $1
      AND a.xact_start IS NOT NULL
      AND a.application_name <> '#{@watch_application_name}'
    ORDER BY a.xact_start, a.pid
    LIMIT #{@max_listed_blockers}
    """
  end
end
