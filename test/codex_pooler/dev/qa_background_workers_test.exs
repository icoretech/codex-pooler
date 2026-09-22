defmodule CodexPooler.Dev.QaBackgroundWorkersTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Dev.QaBackgroundWorkers

  test "preboot disabling removes workers from an actual Oban instance without testing mode" do
    CodexPooler.TestAppEnv.restore_on_exit(Oban)

    config =
      oban_options()
      |> Keyword.merge(
        queues: [default: [limit: 1, paused: true]],
        plugins: [Oban.Pruner],
        cron: [crontab: []],
        lifeline: [],
        pruner: [],
        reindexer: [],
        stager: []
      )

    Application.put_env(:codex_pooler, Oban, config)
    assert :ok = QaBackgroundWorkers.disable_before_boot!()

    disabled = Application.fetch_env!(:codex_pooler, Oban)
    start_oban!(disabled)
    name = Keyword.fetch!(disabled, :name)
    actual = Oban.config(name)

    assert actual.testing == :disabled
    assert actual.queues == []
    assert actual.plugins == []
    assert actual.stager == false
    assert actual.repo == CodexPooler.Repo
    assert :ok = QaBackgroundWorkers.verify_disabled!(name)
    assert Supervisor.which_children(Oban.Registry.whereis(name, Oban.Harbor)) == []
    assert Oban.Registry.whereis(name, {:queue, "default"}) == nil
  end

  test "runtime verification rejects an enabled queue even when plugins and staging are disabled" do
    config = Keyword.put(oban_options(), :queues, default: [limit: 1, paused: true])
    start_oban!(config)

    assert_raise RuntimeError, "owned QA background workers remain enabled", fn ->
      QaBackgroundWorkers.verify_disabled!(Keyword.fetch!(config, :name))
    end
  end

  test "runtime verification rejects an enabled plugin even when queues and staging are disabled" do
    config = Keyword.put(oban_options(), :plugins, [{Oban.Pruner, interval: 60_000}])
    start_oban!(config)

    assert_raise RuntimeError, "owned QA background workers remain enabled", fn ->
      QaBackgroundWorkers.verify_disabled!(Keyword.fetch!(config, :name))
    end
  end

  test "runtime verification rejects the independent stager even when queues and plugins are disabled" do
    config = Keyword.put(oban_options(), :stager, interval: 60_000)
    start_oban!(config)

    assert_raise RuntimeError, "owned QA background workers remain enabled", fn ->
      QaBackgroundWorkers.verify_disabled!(Keyword.fetch!(config, :name))
    end
  end

  # Every development task that boots the application to write fixture or seed
  # rows keeps Oban queues, plugins and the stager off in its own VM, like
  # `mix dev.mcp_fixture` (findings#232, 232-24/232-26): each case reaches the
  # boot and then stops at its own environment guard before any write.
  for {task, args, error} <- [
        {Mix.Tasks.Dev.OpenaiV1Fixture, ["acquire"], Mix.Error},
        {Mix.Tasks.Dev.OpenaiV1Fixture, ["release"], Mix.Error},
        {Mix.Tasks.Dev.RoutingStrategyFixture, ["acquire"], Mix.Error},
        {Mix.Tasks.Dev.RoutingStrategyFixture, ["release"], Mix.Error},
        {Mix.Tasks.Dev.Seed, ["no-such-profile"], Mix.Error},
        {Mix.Tasks.Dev.SavedResetConfirmationFixtures, ["--scenario", "absent"], Mix.Error},
        {Mix.Tasks.Dev.SavedResetConfirmationFixtures, ["--cleanup", "tmp/absent-journal.json"], Mix.Error}
      ] do
    test "mix #{Mix.Task.task_name(task)} #{hd(args)} disables background jobs before it boots the application" do
      CodexPooler.TestAppEnv.restore_on_exit(Oban)
      enabled = Keyword.merge(Application.fetch_env!(:codex_pooler, Oban), queues: [default: 1], plugins: [Oban.Pruner], stager: [interval: 1_000])
      Application.put_env(:codex_pooler, Oban, enabled)

      assert_raise unquote(error), fn -> unquote(task).run(unquote(args)) end

      config = Application.fetch_env!(:codex_pooler, Oban)
      assert {config[:queues], config[:plugins], config[:stager]} == {false, false, false}
    end
  end

  for task <- [Mix.Tasks.Dev.OpenaiV1Fixture, Mix.Tasks.Dev.RoutingStrategyFixture] do
    test "mix #{Mix.Task.task_name(task)} status boots nothing and leaves the Oban configuration alone" do
      CodexPooler.TestAppEnv.restore_on_exit(Oban)
      enabled = Keyword.merge(Application.fetch_env!(:codex_pooler, Oban), queues: [default: 1], plugins: [Oban.Pruner], stager: [interval: 1_000])
      Application.put_env(:codex_pooler, Oban, enabled)

      try do
        unquote(task).run(["status"])
      rescue
        Mix.Error -> :ok
      end

      assert Application.fetch_env!(:codex_pooler, Oban) == enabled
    end
  end

  defp start_oban!(config) do
    name = Keyword.fetch!(config, :name)
    on_exit(fn -> assert Oban.whereis(name) == nil end)
    start_supervised!({Oban, config})
  end

  defp oban_options do
    [
      name: {__MODULE__, make_ref()},
      repo: CodexPooler.Repo,
      notifier: Oban.Notifiers.Isolated,
      peer: false,
      testing: :disabled,
      queues: false,
      plugins: false,
      stager: false
    ]
  end
end
