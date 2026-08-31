defmodule CodexPooler.ObanSplitRoleRuntimeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.ObanSplitRoleHarness, as: RemoteHarness
  alias CodexPooler.ObanSplitRoleWorker, as: SplitRoleWorker
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @peer_timeout 15_000

  setup_all do
    ensure_distribution_started!()
    :ok
  end

  test "scheduler leader Stager promotes a due retryable job for the queue-owning worker" do
    run_id = Ecto.UUID.generate()
    oban_name = String.to_atom("oban_split_role_#{System.unique_integer([:positive])}")
    worker_name = worker_name(SplitRoleWorker)
    scheduler = start_peer!(:scheduler)
    worker = start_peer!(:worker)

    on_exit(fn ->
      stop_remote!(scheduler)
      stop_remote!(worker)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM oban_jobs WHERE args->>'test_run_id' = $1", [run_id])
        Repo.query!("DELETE FROM oban_peers WHERE name = $1", [inspect(oban_name)])
      end)
    end)

    repo_opts = remote_repo_options()
    telemetry_id = {:split_role, System.unique_integer([:positive])}

    scheduler_runtime =
      :erpc.call(scheduler.node, RemoteHarness, :start, [
        :scheduler,
        repo_opts,
        oban_name,
        worker_name,
        run_id,
        self(),
        telemetry_id
      ])

    assert_receive {:split_role_event, :scheduler, :leader, true}, @peer_timeout

    assert %{queues: [], stager_pid: stager_pid, leader?: true} =
             :erpc.call(scheduler.node, RemoteHarness, :runtime_state, [oban_name])

    assert is_pid(stager_pid)

    worker_runtime =
      :erpc.call(worker.node, RemoteHarness, :start, [
        :worker,
        repo_opts,
        oban_name,
        worker_name,
        run_id,
        self(),
        telemetry_id
      ])

    assert %{queues: [jobs: _], leader?: false} =
             :erpc.call(worker.node, RemoteHarness, :runtime_state, [oban_name])

    job_id =
      Sandbox.unboxed_run(Repo, fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        {1, [%{id: id}]} =
          Repo.insert_all(
            Oban.Job,
            [
              %{
                args: %{"test_run_id" => run_id},
                attempt: 1,
                errors: [%{"attempt" => 1, "error" => "synthetic retry"}],
                inserted_at: now,
                max_attempts: 3,
                meta: %{},
                priority: 0,
                queue: "jobs",
                scheduled_at: DateTime.add(now, -1, :second),
                state: "retryable",
                tags: ["split_role_test"],
                worker: worker_name
              }
            ],
            returning: [:id]
          )

        id
      end)

    assert_receive {
                     :split_role_event,
                     :scheduler,
                     :stager,
                     %{leader: true, staged_count: 1}
                   },
                   @peer_timeout

    assert_receive {:split_role_event, :worker, :job_completed, ^job_id}, @peer_timeout

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(Oban.Job, job_id).state == "completed"
    end)

    assert :ok = :erpc.call(scheduler.node, RemoteHarness, :stop, [scheduler_runtime])
    assert :ok = :erpc.call(worker.node, RemoteHarness, :stop, [worker_runtime])
  end

  defp start_peer!(prefix) do
    peer_name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

    assert {:ok, peer_pid, peer_node} =
             :peer.start_link(%{
               name: peer_name,
               args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

    Process.unlink(peer_pid)
    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    assert {:module, SplitRoleWorker} =
             :erpc.call(peer_node, Code, :ensure_loaded, [SplitRoleWorker])

    assert {:module, RemoteHarness} = :erpc.call(peer_node, Code, :ensure_loaded, [RemoteHarness])

    %{node: peer_node, pid: peer_pid}
  end

  defp stop_remote!(%{node: node, pid: peer_pid}) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)

    refute node in Node.list(:connected)
  end

  defp remote_repo_options do
    Repo.config()
    |> Keyword.take([
      :connect_timeout,
      :database,
      :hostname,
      :parameters,
      :password,
      :port,
      :socket_dir,
      :socket_options,
      :ssl,
      :ssl_opts,
      :timeout,
      :url,
      :username
    ])
    |> Keyword.put(:pool, DBConnection.ConnectionPool)
    |> Keyword.put(:pool_size, 2)
  end

  defp ensure_distribution_started!, do: start_distribution!(node())

  defp start_distribution!(:nonode@nohost) do
    previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
    Application.put_env(:kernel, :prevent_overlapping_partitions, false)
    node_name = String.to_atom("oban_split_role_test_#{System.unique_integer([:positive])}")

    assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])

    on_exit(fn ->
      assert :ok = :net_kernel.stop()
      restore_partition_guard(previous_partition_guard)
    end)
  end

  defp start_distribution!(_distributed_node), do: :ok

  defp restore_partition_guard({:ok, value}),
    do: Application.put_env(:kernel, :prevent_overlapping_partitions, value)

  defp restore_partition_guard(:error),
    do: Application.delete_env(:kernel, :prevent_overlapping_partitions)

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
