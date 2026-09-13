defmodule CodexPooler.CommittedWriteGuardTest do
  @moduledoc """
  Locks `CodexPooler.CommittedWriteGuard`: a test that leaves committed rows behind, or changes a
  committed singleton row, fails and names the tables; the tests around it do not; and rows nothing
  guarded, or that came through a channel no test verification sees, fail the run instead.

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

  test "fails the tests that leave committed rows behind, and the run when nothing guarded them" do
    on_exit(&delete_probe_rows!/0)
    probe = run_probe!()

    assert probe.outcomes == %{
             "test leaves an upstream identity no user created behind" =>
               {"failed", "during", ["upstream_identities"]},
             "test writes inside the sandbox after that leak" => {"passed", "none", []},
             "test commits an identity and registers its removal first" => {"passed", "none", []},
             "test commits through a connection it starts with DBConnection.start_link/2" =>
               {"failed", "during", ["instance_presences"]},
             "test updates the committed instance settings singleton and never restores it" =>
               {"failed", "during", ["instance_settings"]},
             "test leaves a pricing snapshot behind in auto mode" =>
               {"failed", "during", ["pricing_snapshots"]},
             "test commits an identity without the guard" => {"passed", "none", []},
             "test starts after rows an unguarded test committed" =>
               {"failed", "before", ["upstream_identities"]},
             "test starts after that failure has been reported" => {"passed", "none", []},
             "test commits through a connection opened before the guard started, as the last test" =>
               {"passed", "none", []}
           },
           probe.output

    assert probe.summary == %{"stage" => "probe", "total" => 10, "failures" => 5}, probe.output

    assert probe.exit_code != 0,
           "rows committed after the last verification must fail the run\n#{probe.output}"

    assert probe.output =~
             ~r/after the guard last verified them.*\n  instance_presences: \d+ -> \d+ \(\+1\)/s,
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
      outcomes:
        receipts
        |> Enum.filter(&(&1["stage"] == "test"))
        |> Map.new(&{&1["name"], {&1["outcome"], &1["guard"], &1["tables"]}})
    }
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

      Repo.query!(
        "DELETE FROM instance_presences WHERE instance_id LIKE 'committed-write-guard-probe-%'"
      )

      Repo.query!(
        "UPDATE instance_settings SET metadata = metadata - 'committed_write_guard_probe' " <>
          "WHERE metadata ? 'committed_write_guard_probe'"
      )
    end)

    :ok
  end
end
