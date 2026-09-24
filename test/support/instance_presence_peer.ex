defmodule CodexPooler.InstancePresencePeer do
  @moduledoc false
  import ExUnit.Callbacks
  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]
  alias CodexPooler.Platform.InstancePresence.Identity

  @type os_process_source :: :proc | :ps
  @type os_process_identity :: %{
          pid: String.t(),
          source: os_process_source(),
          start_signature: String.t()
        }
  @type os_process_snapshot :: %{
          source: os_process_source(),
          start_signature: String.t(),
          state: String.t(),
          parent_pid: non_neg_integer()
        }

  @doc """
  Task timeout for one unboxed cleanup that waits on a peer, from that peer's
  detection budget.

  A cleanup may wait on two budgets in sequence -- an OS-process wait and a
  database-connection wait -- so its `Task.await` must outlast both, plus room
  for the cleanup's own work. A timeout at or below the budget reports
  `Task.await` timing out instead of the peer assertion that actually failed,
  which is exactly the wrong end of the failure (findings#207 rows 207-41,
  207-47). Deriving it here is what keeps the relation from drifting: callers
  never write the arithmetic.
  """
  @spec cleanup_timeout_ms(pos_integer()) :: pos_integer()
  def cleanup_timeout_ms(peer_timeout_ms)
      when is_integer(peer_timeout_ms) and peer_timeout_ms > 0,
      do: peer_timeout_ms * 2 + 5_000

  @doc """
  Removes one peer's committed state in the only order that is safe.

  The peer's own backends are ended first: a hard-killed VM's proof publisher
  can still hold a backend mid-statement on the very rows the cleanup deletes,
  and a cleanup that deleted first would block on that lock until its task
  timeout (findings#207 row 207-40). PostgreSQL's default zero-timeout
  `pg_terminate_backend/1` returns after sending the termination signal, so the
  absence of the peer's connections must be established second and the row
  deletion runs only after that proof. Callers pass only the deletion; the
  order is this function's, not theirs.

  `:terminate`, `:delete` and `:await` are injectable so the order itself can be
  observed without a real VM.
  """
  @spec purge_peer_state!(String.t(), (-> term()), keyword()) :: :ok
  def purge_peer_state!(boot_id, delete_rows, opts \\ [])
      when is_binary(boot_id) and is_function(delete_rows, 0) do
    budget = Keyword.get(opts, :budget_ms, 15_000)
    terminate = Keyword.get(opts, :terminate, &terminate_peer_connections!/1)
    await = Keyword.get(opts, :await, &assert_peer_connections_absent!/2)

    :ok = terminate.(boot_id)
    :ok = await.(boot_id, budget)
    _deleted = delete_rows.()
    :ok
  end

  @spec peer_application_name(String.t()) :: String.t()
  def peer_application_name(boot_id) when is_binary(boot_id), do: "execution_peer_" <> boot_id

  @spec terminate_peer_connections!(String.t()) :: :ok
  def terminate_peer_connections!(boot_id) when is_binary(boot_id) do
    CodexPooler.Repo.query!(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " <>
        "WHERE application_name = $1 AND pid <> pg_backend_pid()",
      [peer_application_name(boot_id)]
    )

    :ok
  end

  @spec assert_peer_connections_absent!(String.t(), pos_integer()) :: :ok
  def assert_peer_connections_absent!(boot_id, budget_ms) when is_binary(boot_id) do
    await_peer_connections_absent(boot_id, System.monotonic_time(:millisecond) + budget_ms)
  end

  defp await_peer_connections_absent(boot_id, deadline) do
    # PostgreSQL caches statistics snapshots for the current transaction. The
    # SQL sandbox keeps one transaction open for the whole test, so a sample
    # taken before pg_terminate_backend finishes would otherwise stay stale for
    # every retry and falsely exhaust the detection budget.
    CodexPooler.Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[count]]} =
      CodexPooler.Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1",
        [peer_application_name(boot_id)]
      )

    if count > 0 do
      assert System.monotonic_time(:millisecond) < deadline, "peer database connections survived"
      Process.sleep(10)
      await_peer_connections_absent(boot_id, deadline)
    else
      :ok
    end
  end

  @spec capture_os_process_identity!(String.t(), keyword()) :: os_process_identity()
  def capture_os_process_identity!(os_pid, opts \\ []) do
    probe = Keyword.get(opts, :probe, &os_process_snapshot/1)

    case probe.(os_pid) do
      {:present, %{source: source, start_signature: start_signature}}
      when source in [:proc, :ps] and is_binary(start_signature) ->
        %{pid: os_pid, source: source, start_signature: start_signature}

      result ->
        flunk("owned peer OS process identity unavailable: #{inspect(result)}")
    end
  end

  @spec assert_os_process_stopped!(os_process_identity(), keyword()) :: :ok
  def assert_os_process_stopped!(identity, opts \\ []) do
    budget = Keyword.get(opts, :budget_ms, 15_000)
    probe = Keyword.get(opts, :probe, &os_process_snapshot/1)
    deadline = System.monotonic_time(:millisecond) + budget
    await_os_process_stopped(identity, probe, deadline)
  end

  defp await_os_process_stopped(identity, probe, deadline) do
    case classify_owned_process(identity, probe.(identity.pid)) do
      :stopped ->
        :ok

      status when status in [:live, :unknown] ->
        assert System.monotonic_time(:millisecond) < deadline,
               "owned peer OS process remained #{status} through shutdown detection budget"

        receive do
        after
          25 -> :ok
        end

        await_os_process_stopped(identity, probe, deadline)
    end
  end

  @spec classify_owned_process(
          os_process_identity(),
          :absent | {:present, os_process_snapshot()} | {:error, term()}
        ) :: :stopped | :live | :unknown
  def classify_owned_process(_identity, :absent), do: :stopped

  def classify_owned_process(
        %{source: source, start_signature: expected},
        {:present, %{source: source, start_signature: actual}}
      )
      when actual != expected,
      do: :stopped

  def classify_owned_process(
        %{source: source, start_signature: signature},
        {:present, %{source: source, start_signature: signature, state: state}}
      )
      when is_binary(state) do
    if String.starts_with?(state, "Z"), do: :stopped, else: :live
  end

  def classify_owned_process(_identity, _result), do: :unknown

  @spec assert_os_process_absent!(String.t(), keyword()) :: :ok
  def assert_os_process_absent!(os_pid, opts \\ []) do
    budget = Keyword.get(opts, :budget_ms, 15_000)
    probe = Keyword.get(opts, :probe, &os_process_probe/1)
    await_os_process_absent(os_pid, probe, System.monotonic_time(:millisecond) + budget)
  end

  defp await_os_process_absent(os_pid, probe, deadline) do
    if classify_os_process_probe(probe.(os_pid)) != :absent do
      assert System.monotonic_time(:millisecond) < deadline,
             "owned peer OS process survived shutdown detection budget"

      receive do
      after
        25 -> :ok
      end

      await_os_process_absent(os_pid, probe, deadline)
    else
      :ok
    end
  end

  @spec classify_os_process_probe({String.t(), integer()}) :: :present | :absent | :unknown
  def classify_os_process_probe({_output, 0}), do: :present

  def classify_os_process_probe({output, exit_code}) when exit_code > 0 do
    # System.cmd resolves the executable path; procps-ng uses that argv[0] in
    # diagnostics, unlike shells that print only "kill".
    if Regex.match?(~r/\A(?:(?:\/(?:[^\/\s:]+\/)*)?kill: )?\(?[0-9]+\)?: [Nn]o such process\s*\z/, output),
      do: :absent,
      else: :unknown
  end

  def classify_os_process_probe(_result), do: :unknown

  defp os_process_probe(os_pid) do
    System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
  end

  defp os_process_snapshot(os_pid) do
    case :os.type() do
      {:unix, :linux} -> linux_process_snapshot("/proc/#{os_pid}/stat")
      _other -> portable_process_snapshot(os_pid)
    end
  end

  defp linux_process_snapshot(proc_path) do
    case File.read(proc_path) do
      {:ok, stat} ->
        parse_linux_process_stat(stat)

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp portable_process_snapshot(os_pid) do
    case System.cmd("ps", ["-o", "state=", "-o", "lstart=", "-o", "ppid=", "-p", os_pid],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {output, 0} ->
        parse_portable_process_output(output)

      {_output, 1} ->
        classify_portable_absence(os_pid)

      {output, exit_code} ->
        {:error, {:ps_failed, exit_code, String.trim(output)}}
    end
  end

  @doc false
  @spec parse_linux_process_stat(String.t()) ::
          {:present, os_process_snapshot()} | {:error, atom()}
  def parse_linux_process_stat(stat) do
    with [_, fields] <- Regex.run(~r/\A\d+ \(.+\) (.+)\z/s, stat),
         values when length(values) > 19 <- String.split(fields),
         {parent_pid, ""} <- values |> Enum.at(1) |> Integer.parse() do
      {:present,
       %{
         source: :proc,
         state: Enum.at(values, 0),
         parent_pid: parent_pid,
         start_signature: Enum.at(values, 19)
       }}
    else
      _invalid -> {:error, :invalid_proc_stat}
    end
  end

  @doc false
  @spec parse_portable_process_output(String.t()) ::
          {:present, os_process_snapshot()} | {:error, atom()}
  def parse_portable_process_output(output) do
    case Regex.run(~r/\A\s*(\S+)\s+(.+?)\s+(\d+)\s*\z/, output) do
      [_, state, started_at, parent_pid] ->
        {:present,
         %{
           source: :ps,
           state: state,
           parent_pid: String.to_integer(parent_pid),
           start_signature: String.replace(started_at, ~r/\s+/, " ")
         }}

      _invalid ->
        {:error, :invalid_ps_output}
    end
  end

  defp classify_portable_absence(os_pid) do
    case os_process_probe(os_pid) do
      {diagnostic, exit_code} ->
        if classify_os_process_probe({diagnostic, exit_code}) == :absent,
          do: :absent,
          else: {:error, :ps_process_unknown}
    end
  end

  @spec start_presence_peer!(atom()) :: map()
  def start_presence_peer!(name) do
    on_exit(fn -> CodexPooler.PeerRegistry.assert_peer_absent!(name) end)

    if node() == :nonode@nohost do
      previous = Application.fetch_env(:kernel, :prevent_overlapping_partitions)

      on_exit(fn ->
        :net_kernel.stop()

        restore_distribution_config(previous)
      end)

      {_, 0} = System.cmd("epmd", ["-daemon"])
      CodexPooler.PeerRegistry.assert_epmd_ready!()
      Application.put_env(:kernel, :prevent_overlapping_partitions, false)

      {:ok, _} =
        :net_kernel.start([:"lease_observer_#{System.unique_integer([:positive])}", :shortnames])
    end

    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           {:ok, peer, remote} =
             :peer.start_link(%{
               name: name,
               args: [~c"+S", ~c"2:2", ~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

           send(parent, {:presence_peer, self(), peer, remote})

           receive do
             :stop -> :peer.stop(peer)
           end
         end},
        id: make_ref()
      )

    assert_receive {:presence_peer, ^owner, peer, remote}, 15_000
    :ok = :erpc.call(remote, :code, :add_paths, [:code.get_path()])
    :erpc.call(remote, Identity, :mint_boot_id!, [])
    identity = :erpc.call(remote, Identity, :local, [])
    %{owner: owner, peer: peer, remote: remote, name: name, identity: identity}
  end

  @spec stop_presence_peer!(map()) :: :ok
  def stop_presence_peer!(peer) do
    monitor = Process.monitor(peer.owner)
    send(peer.owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 15_000
    CodexPooler.PeerRegistry.assert_peer_absent!(peer.name, peer_node: peer.remote)
    :ok
  end

  alias CodexPooler.{Accounting, Repo}
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Platform.{InstanceHeartbeat, InstancePresence}

  @spec start(map()) :: {struct(), struct(), pid()}
  def start(setup) do
    {:ok, registry} =
      GenServer.start(CodexPooler.Gateway.Transports.Websocket.ActivityRegistry, :ok, [])

    parent = self()

    {:ok, pid} =
      ResponseTask.start(
        parent,
        :local_owner,
        fn _ ->
          {:ok, reserved} =
            Accounting.reserve(
              setup.auth,
              setup.model,
              %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
              %{transport: "http_sse", correlation_id: Ecto.UUID.generate()}
            )

          {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
          send(parent, {:started, reserved.request, attempt, self()})

          receive do
            :finish -> :ok
          end
        end,
        fn _, _ -> :ok end,
        activity_registry: registry
      )

    receive do
      {:started, request, attempt, ^pid} -> {request, attempt, pid}
    after
      15_000 -> raise "presence execution did not start"
    end
  end

  @spec await_starvation() :: map()
  def await_starvation do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :instance_presence, :heartbeat],
        &__MODULE__.capture/4,
        self()
      )

    try do
      {result, logs} =
        ExUnit.CaptureLog.with_log(fn ->
          {:ok, heartbeat} = InstanceHeartbeat.start_link(enabled: true, interval_ms: 10)
          Process.unlink(heartbeat)

          try do
            await_failures(0)
          after
            GenServer.stop(heartbeat)
          end
        end)

      Map.put(result, :warned, String.contains?(logs, "instance presence heartbeat write failed"))
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def capture(_event, %{failures: 1}, %{}, parent), do: send(parent, :heartbeat_failed)

  # Fixture cadence of the production heartbeat while a peer publishes: a missed
  # beat is retried on the next tick, as production does every 15 s.
  @presence_retry_interval_ms 50

  @doc """
  Publishes a BEAM peer's presence row through the production heartbeat and
  returns how many beats failed before one landed.

  A single `InstancePresence.record_heartbeat/0` call made the fixture depend on
  one beat fitting its one-second production write budget. On a loaded host a
  freshly bootstrapped peer spent that budget before its insert, DBConnection
  closed the insert's connection, and the test failed with `tcp recv: closed`
  (findings#206 row 206-473). The peer instead runs the real
  `InstanceHeartbeat`, which retries a failed beat on its next tick, until its
  row exists; the heartbeat is then stopped, so the row changes only when the
  test changes it. Only a peer with no landed beat inside `budget_ms` fails, and
  the failure names the missed beats and the one-second budget that cuts a
  starved beat.
  """
  @spec publish_presence!(pid(), pos_integer()) :: non_neg_integer()
  def publish_presence!(peer, budget_ms) when is_integer(budget_ms) and budget_ms > 0 do
    # The peer stops its heartbeat before answering, which can wait out one
    # more beat's budget.
    case :peer.call(peer, __MODULE__, :publish_local_presence, [budget_ms], budget_ms * 2 + 5_000) do
      {:ok, failed_beats} ->
        failed_beats

      {:error, failed_beats} ->
        flunk(
          "the peer published no presence within #{budget_ms} ms: #{failed_beats} heartbeat beat(s) failed. " <>
            "A beat that outlives InstancePresence's one-second production write budget loses its connection " <>
            "(DBConnection closes it: `tcp recv: closed`), so a host or database that starves the peer fails " <>
            "every beat; the peer logs each failed write"
        )
    end
  end

  @doc false
  @spec publish_local_presence(pos_integer()) :: {:ok | :error, non_neg_integer()}
  def publish_local_presence(budget_ms) do
    identity = InstancePresence.local_identity()
    failures = :counters.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :instance_presence, :heartbeat],
        &__MODULE__.count_failed_beat/4,
        failures
      )

    try do
      {:ok, heartbeat} =
        InstanceHeartbeat.start_link(enabled: true, identity: identity, interval_ms: @presence_retry_interval_ms)

      Process.unlink(heartbeat)

      published? =
        try do
          await_presence_row(identity, System.monotonic_time(:millisecond) + budget_ms)
        after
          GenServer.stop(heartbeat)
        end

      {if(published?, do: :ok, else: :error), :counters.get(failures, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  # The poll shares the peer's pool with the beats; a connection the pool is
  # replacing is "not yet", not a failure of the fixture.
  defp presence_row?(identity) do
    Repo.exists?(from instance in InstancePresence.Instance, where: instance.instance_id == ^identity.instance_id)
  rescue
    _error in [DBConnection.ConnectionError] -> false
  end

  @doc false
  def count_failed_beat(_event, %{failures: 1}, _metadata, failures), do: :counters.add(failures, 1, 1)

  defp await_presence_row(identity, deadline) do
    cond do
      presence_row?(identity) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_presence_row(identity, deadline)
    end
  end

  defp restore_distribution_config({:ok, value}),
    do: Application.put_env(:kernel, :prevent_overlapping_partitions, value)

  defp restore_distribution_config(:error),
    do: Application.delete_env(:kernel, :prevent_overlapping_partitions)

  defp await_failures(count) do
    receive do
      :heartbeat_failed ->
        identity = InstancePresence.local_identity()

        %{rows: [[age]]} =
          Repo.query!(
            "SELECT EXTRACT(EPOCH FROM clock_timestamp() - last_seen_at)::float8 FROM instance_presences WHERE instance_id=$1",
            [identity.instance_id]
          )

        if count + 1 >= 8 and age > InstancePresence.liveness_window_seconds(),
          do: %{failures: count + 1, age_seconds: age},
          else: await_failures(count + 1)
    after
      30_000 -> raise "production heartbeat did not report a failed write"
    end
  end
end
