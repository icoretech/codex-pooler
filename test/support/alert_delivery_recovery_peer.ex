defmodule CodexPooler.AlertDeliveryRecoveryPeer do
  @moduledoc false

  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Repo

  @spec start_owner_worker(String.t(), pid()) :: :ok
  def start_owner_worker(queue, parent) do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:oban)
    {:ok, _} = Application.ensure_all_started(:mix)
    Code.ensure_loaded!(AlertDeliveryWorker)
    name = String.to_atom("peer_alert_#{System.unique_integer([:positive])}")
    :ok = :telemetry.attach({__MODULE__, name}, [:oban, :job, :start], &__MODULE__.observe/4, %{name: name, repo: Repo, parent: parent})
    {:ok, pid} = Oban.start_link(name: name, repo: Repo, testing: :disabled, queues: [{String.to_atom(queue), 1}], plugins: [], peer: false, notifier: Oban.Notifiers.PG, log: false)
    Process.unlink(pid)
    :ok
  end

  @spec observe([atom()], map(), map(), map()) :: term()
  def observe([:oban, :job, :start], _, %{conf: %{name: name}}, %{name: name} = config) do
    Repo.put_dynamic_repo(config.repo)
    {:links, links} = Process.info(self(), :links)
    send(config.parent, {:executor_started, self(), links})
  end

  def observe([:oban, :job, :exception], _, %{conf: %{name: name}}, %{name: name} = config), do: send(config.parent, :executor_acknowledged)
  def observe(_, _, _, _), do: :ok
end
