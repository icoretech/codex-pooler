defmodule CodexPooler.Dev.QaBackgroundWorkers do
  @moduledoc """
  Disables background job execution before an owned QA application boots and verifies its running configuration.
  """

  @spec disable_before_boot!() :: :ok
  def disable_before_boot! do
    config =
      Application.fetch_env!(:codex_pooler, Oban)
      |> Keyword.drop([:cron, :lifeline, :pruner])
      |> Keyword.merge(queues: false, plugins: false, stager: false)

    Application.put_env(:codex_pooler, Oban, config)
  end

  @doc """
  Boots the application for a development task that only writes fixture or seed
  rows: Oban queues, plugins and the stager stay off in that VM, so it never runs
  jobs against the database it writes, and the running instance is verified
  before the task continues. Jobs the task enqueues stay for the serving node.
  """
  @spec start_application!() :: :ok
  def start_application! do
    :ok = disable_before_boot!()
    Mix.Task.run("app.start")
    verify_disabled!()
  end

  @spec verify_disabled!(Oban.name()) :: :ok
  def verify_disabled!(name \\ Oban) do
    case Oban.config(name) do
      %Oban.Config{queues: [], plugins: [], stager: false} -> :ok
      _config -> raise "owned QA background workers remain enabled"
    end
  end
end
