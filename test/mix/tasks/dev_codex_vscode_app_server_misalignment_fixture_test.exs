defmodule Mix.Tasks.DevCodexVscodeAppServerMisalignmentFixtureTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Dev.CodexVscodeAppServerMisalignmentFixture,
    as: MisalignmentFixtureTask

  test "status emits a metadata-only absent receipt for a new run id" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      Mix.Task.reenable("dev.codex_vscode_app_server_misalignment_fixture")
    end)

    run_id = "misalignment-task-#{System.unique_integer([:positive])}"
    Mix.Task.reenable("dev.codex_vscode_app_server_misalignment_fixture")

    MisalignmentFixtureTask.run([
      "status",
      "--run-id",
      run_id
    ])

    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json) == %{"run_id" => run_id, "status" => "absent"}
  end
end
