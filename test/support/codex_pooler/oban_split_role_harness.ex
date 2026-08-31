defmodule CodexPooler.ObanSplitRoleWorker do
  @moduledoc false

  use Oban.Worker, queue: :jobs, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule CodexPooler.ObanSplitRoleHarness do
  @moduledoc false

  @stager_event [:oban, :plugin, :stop]
  @peer_event [:oban, :peer, :election, :stop]
  @job_event [:oban, :job, :stop]

  @spec start(atom(), keyword(), atom(), String.t(), String.t(), pid(), term()) :: map()
  def start(role, repo_opts, oban_name, worker_name, test_run_id, parent, telemetry_id) do
    {:ok, _applications} = Application.ensure_all_started(:ecto_sql)
    {:ok, _applications} = Application.ensure_all_started(:oban)

    Application.put_env(:codex_pooler, CodexPooler.Repo, repo_opts)

    {:ok, repo_pid} = CodexPooler.Repo.start_link(name: CodexPooler.Repo)
    Process.unlink(repo_pid)

    :ok =
      :telemetry.attach_many(
        telemetry_id,
        [@stager_event, @peer_event, @job_event],
        &__MODULE__.handle_event/4,
        %{
          oban_name: oban_name,
          parent: parent,
          role: role,
          test_run_id: test_run_id,
          worker_name: worker_name
        }
      )

    {:ok, oban_pid} = Oban.start_link(oban_options(role, oban_name))
    Process.unlink(oban_pid)

    %{oban_pid: oban_pid, repo_pid: repo_pid, telemetry_id: telemetry_id}
  end

  @spec runtime_state(atom()) :: map()
  def runtime_state(oban_name) do
    config = Oban.config(oban_name)

    %{
      leader?: Oban.Peer.leader?(oban_name),
      queues: config.queues,
      stager_pid: Oban.Registry.whereis(oban_name, Oban.Stager)
    }
  end

  @spec stop(map()) :: :ok
  def stop(%{oban_pid: oban_pid, repo_pid: repo_pid, telemetry_id: telemetry_id}) do
    :telemetry.detach(telemetry_id)
    stop_process(oban_pid)
    stop_process(repo_pid)
    :ok
  end

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(@peer_event, _measurements, metadata, data) do
    if metadata[:conf].name == data.oban_name do
      send(data.parent, {:split_role_event, data.role, :leader, metadata[:leader]})
    end

    :ok
  end

  def handle_event(@stager_event, _measurements, metadata, data) do
    if metadata[:conf].name == data.oban_name and metadata[:plugin] == Oban.Stager do
      send(data.parent, {
        :split_role_event,
        data.role,
        :stager,
        %{leader: metadata[:leader], staged_count: metadata[:staged_count]}
      })
    end

    :ok
  end

  def handle_event(@job_event, _measurements, metadata, data) do
    job = metadata[:job]

    if job.worker == data.worker_name and job.args["test_run_id"] == data.test_run_id do
      send(data.parent, {:split_role_event, data.role, :job_completed, job.id})
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _data), do: :ok

  defp oban_options(:scheduler, oban_name) do
    [
      repo: CodexPooler.Repo,
      name: oban_name,
      queues: false,
      plugins: [],
      stager: {Oban.Stager, interval: 100},
      shutdown_grace_period: 0,
      testing: :disabled,
      log: false
    ]
  end

  defp oban_options(:worker, oban_name) do
    [
      repo: CodexPooler.Repo,
      name: oban_name,
      queues: [jobs: 1],
      plugins: false,
      shutdown_grace_period: 0,
      testing: :disabled,
      log: false
    ]
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
  end
end
