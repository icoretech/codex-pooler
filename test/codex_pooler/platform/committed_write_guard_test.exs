defmodule CodexPooler.CommittedWriteGuardTest do
  @moduledoc """
  Locks `CodexPooler.CommittedWriteGuard`: a test that leaves committed rows behind, or changes a
  committed singleton row, fails and names the tables; the tests around it do not; a module that
  leaves behind what its `setup_all` committed fails as a module, while one that removes it passes
  and neither charges the module after it; and rows nothing guarded, or that came through a channel
  no test verification sees, fail the run instead.

  The probe runs the guard in a `mix run` VM of its own, so its tests can leak on purpose without
  failing this one. Every row they commit carries a probe label and is removed here, and this
  test's own guard checks that nothing the probe committed survives.
  """
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  # The probe boots its own `mix run` VM; that VM start is the floor here, not a wait. The module
  # timeout is the failure-detection budget for it on a loaded host.
  @moduletag timeout: 120_000

  @probe_path "test/support/fixtures/committed_write_guard_probe.exs"

  @tag slow: "boots an isolated ExUnit runtime and verifies actual committed leaks and cleanup outcomes"
  test "fails the tests that leave committed rows behind, and the run when nothing guarded them" do
    on_exit(&delete_probe_rows!/0)
    probe = run_probe!()

    assert probe.outcomes == %{
             "test leaves an upstream identity no user created behind" => {"failed", "during", ["upstream_identities"]},
             "test writes inside the sandbox after that leak" => {"passed", "none", []},
             "test fails in its body after leaking a committed identity" => {"failed", "none", []},
             "test commits an identity and registers its removal first" => {"passed", "none", []},
             "test commits through a connection it starts with DBConnection.start_link/2" => {"failed", "during", ["instance_presences"]},
             "test updates the committed instance settings singleton and never restores it" => {"failed", "during", ["instance_settings"]},
             "test completes the committed bootstrap singleton and never restores it" => {"failed", "during", ["platform_bootstrap_state"]},
             "test bumps only the committed instance settings updated_at" => {"passed", "none", []},
             "test runs with the identity its setup_all committed" => {"passed", "none", []},
             "test writes nothing of its own" => {"passed", "none", []},
             "test passes while the row its setup_all committed is still there" => {"passed", "none", []},
             "test is not charged for the module that leaked before it" => {"passed", "none", []},
             "test leaves a pricing snapshot behind in auto mode" => {"failed", "during", ["pricing_snapshots"]},
             "test commits an identity without the guard" => {"passed", "none", []},
             "test starts after rows an unguarded test committed" => {"failed", "before", ["upstream_identities"]},
             "test starts after that failure has been reported" => {"passed", "none", []},
             "test commits a row through a connection opened before the guard started" => {"failed", "during", ["instance_presences"]},
             "test writes nothing after that untraced leak" => {"passed", "none", []},
             "test updates a committed row through that connection, as the last test" => {"passed", "none", []}
           },
           probe.output

    # A module the guard fails invalidates its tests, so ExUnit counts one failure for the test
    # `SetupAllLeakTest` passed as well.
    assert probe.summary == %{"stage" => "probe", "total" => 19, "failures" => 9}, probe.output

    assert probe.modules == %{
             "CodexPooler.CommittedWriteGuardProbe.SandboxedCaseTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.TimestampChangeTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.SetupAllFixtureTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.SetupAllLeakTest" => {"failed", "module", ["upstream_identities"]},
             "CodexPooler.CommittedWriteGuardProbe.AfterSetupAllLeakTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.AutoModeTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.UnguardedTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.AfterUnguardedTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.UntracedRowLeakTest" => {"passed", "none", []},
             "CodexPooler.CommittedWriteGuardProbe.LastUntracedTest" => {"passed", "none", []}
           },
           probe.output

    assert probe.output =~
             ~r/committed rows changed during .*test fails in its body after leaking a committed identity.*\n  upstream_identities: \d+ -> \d+ \(\+1\)/,
           "the original test failure must not hide the guard diagnostic\n#{probe.output}"

    assert probe.exit_code != 0,
           "rows changed after the last verification must fail the run\n#{probe.output}"

    # The last test changed content without changing a count, so only the after-suite content
    # comparison can name it.
    assert probe.output =~
             ~r/after the guard last verified them.*\n  instance_presences: content changed \(\d+ rows\)/s,
           probe.output
  end

  defp run_probe! do
    {output, exit_code} =
      System.cmd("mix", ["run", "--no-compile", @probe_path],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    receipts =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))
      |> Enum.map(&CodexPooler.JSON.decode!/1)

    summary = Enum.find(receipts, &(&1["stage"] == "probe"))

    assert is_map(summary),
           "the guard probe did not run to completion (exit #{exit_code})\n#{output}"

    %{
      output: output,
      exit_code: exit_code,
      summary: summary,
      outcomes: receipts_by_name(receipts, "test"),
      modules: receipts_by_name(receipts, "module")
    }
  end

  defp receipts_by_name(receipts, stage) do
    receipts
    |> Enum.filter(&(&1["stage"] == stage))
    |> Map.new(&{&1["name"], {&1["outcome"], &1["guard"], &1["tables"]}})
  end

  # Registered before the probe runs, so a probe that dies half way still has its rows removed.
  defp delete_probe_rows! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(
        from identity in UpstreamIdentity,
          where: like(identity.account_label, "Committed write guard probe %")
      )

      Repo.delete_all(
        from pricing in PricingSnapshot,
          where: like(pricing.model_identifier, "committed-write-guard-probe-%")
      )

      Repo.query!("DELETE FROM instance_presences WHERE instance_id LIKE 'committed-write-guard-probe-%'")

      Repo.query!(
        "UPDATE instance_settings SET metadata = metadata - 'committed_write_guard_probe' " <>
          "WHERE metadata ? 'committed_write_guard_probe'"
      )

      # Only a bootstrap this probe completed: a row a real bootstrap test left completed carries
      # another status and is not touched.
      Repo.query!("UPDATE platform_bootstrap_state SET completed_at = NULL WHERE status = 'pending'")
    end)

    :ok
  end
end
