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

      calls = record_boot_calls(fn -> assert_raise unquote(error), fn -> unquote(task).run(unquote(args)) end end)

      config = Application.fetch_env!(:codex_pooler, Oban)
      assert {config[:queues], config[:plugins], config[:stager]} == {false, false, false}

      # The application is already running in this VM, so the env above cannot
      # tell whether it was written before the boot; the recorded calls can.
      assert disabled_at = Enum.find_index(calls, &disabling_put_env?/1)
      assert boot_at = Enum.find_index(calls, &match?({Mix.Task, :run, ["app.start" | _]}, &1))
      assert disabled_at < boot_at
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

  # Records, in order, this process's writes of the Oban env and its
  # `app.start` runs while `fun` executes. The trace session is private to this
  # test, so other tracers and processes are unaffected (findings#232 row
  # 232-91: the boot order is otherwise unobservable without a child VM).
  defp record_boot_calls(fun) do
    collector = spawn_link(fn -> collect_calls([]) end)
    session = :trace.session_create(__MODULE__, collector, [])

    try do
      _ = :trace.function(session, {Application, :put_env, 3}, [{[:codex_pooler, Oban, :_], [], []}], [:global])
      _ = :trace.function(session, {Mix.Task, :run, 1}, [{["app.start"], [], []}], [:global])
      _ = :trace.function(session, {Mix.Task, :run, 2}, [{["app.start", :_], [], []}], [:global])
      1 = :trace.process(session, self(), true, [:call])

      fun.()

      delivered = :trace.delivered(session, self())
      assert_receive {:trace_delivered, _tracee, ^delivered}, 15_000
      send(collector, {:calls, self()})
      assert_receive {:boot_calls, calls}, 15_000
      calls
    after
      :trace.session_destroy(session)
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, mfa} -> collect_calls([mfa | calls])
      {:calls, from} -> send(from, {:boot_calls, Enum.reverse(calls)})
    end
  end

  defp disabling_put_env?({Application, :put_env, [:codex_pooler, Oban, config]}),
    do: {config[:queues], config[:plugins], config[:stager]} == {false, false, false}

  defp disabling_put_env?(_call), do: false

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
