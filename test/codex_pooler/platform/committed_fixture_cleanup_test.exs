defmodule CodexPooler.CommittedFixtureCleanupTest do
  @moduledoc """
  Locks the teardown contract for fixtures that commit rows outside the Ecto sandbox.

  A row committed through `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` is not rolled back, so it
  survives into every later test of the same `mix test` invocation. When the fixture keys are
  shared, one such leak turns a single real failure into a run-wide cascade of unique-index
  violations in unrelated files.

  The discriminating case is a *failing* test, not a passing one: `run_unboxed/1` evaluates the
  block in a linked task, so an assertion that fails inside it raises in the task and the exit
  signal kills the untrapped test process before any enclosing `after` can run.
  """
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  import Ecto.Query

  # The probe boots its own `mix run` VM so it can fail tests on purpose without failing this
  # one; that VM start is the floor here, not a wait. The module timeout is the failure
  # detection budget for it on a loaded host.
  @moduletag timeout: 120_000

  @probe_path "test/support/fixtures/committed_fixture_cleanup_probe.exs"

  test "an assertion failing inside an unboxed block still runs registered cleanup, never scoped" do
    probe = run_probe!()

    on_exit(fn -> delete_fixtures!(Map.values(probe.fixtures)) end)

    assert probe.summary == %{"stage" => "probe", "total" => 2, "failures" => 2},
           """
           both probe tests must fail on their forced assertion; anything else means the probe
           stopped exercising the path under test.
           #{probe.output}
           """

    scoped = Map.fetch!(probe.fixtures, "scoped")
    registered = Map.fetch!(probe.fixtures, "registered")

    assert committed_pricing_versions([scoped]) == [scoped["price_version"]],
           """
           the scoped `try/after` cleanup was expected to be skipped by the task exit signal.
           If this row is gone, the probe no longer discriminates and the registered-cleanup
           assertion below proves nothing.
           #{probe.output}
           """

    assert committed_pricing_versions([registered]) == [],
           """
           the registered cleanup did not run: a pricing snapshot committed outside the sandbox
           survived a test that died from an assertion failing inside `run_unboxed/1`, and will
           collide with every later fixture that shares its key.
           #{probe.output}
           """
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

    assert exit_code == 0 and is_map(summary),
           "the cleanup probe did not run to completion (exit #{exit_code})\n#{output}"

    fixtures =
      receipts
      |> Enum.filter(&(&1["stage"] == "fixture"))
      |> Map.new(&{&1["mode"], &1})

    assert Map.keys(fixtures) |> Enum.sort() == ["registered", "scoped"],
           "the cleanup probe did not commit both fixtures\n#{output}"

    %{output: output, summary: summary, fixtures: fixtures}
  end

  defp committed_pricing_versions(fixtures) do
    ids = Enum.map(fixtures, & &1["pricing_snapshot_id"])

    Sandbox.unboxed_run(Repo, fn ->
      Repo.all(
        from pricing in PricingSnapshot, where: pricing.id in ^ids, select: [:price_version]
      )
    end)
    |> Enum.map(& &1.price_version)
  end

  # The scoped arm is *expected* to leave its rows behind -- that is what the assertion above
  # reads -- so this has to remove everything the probe committed, not only the pricing snapshot
  # the probe is nominally about. Deleting a subset leaves the upstream identity rows
  # outside the sandbox, and suites asserting absolute identity counts then fail in files
  # unrelated to this one: the exact cascade this test exists to prevent.
  defp delete_fixtures!(fixtures) do
    pool_ids = Enum.map(fixtures, & &1["pool_id"])
    pricing_ids = Enum.map(fixtures, & &1["pricing_snapshot_id"])
    identity_ids = Enum.map(fixtures, & &1["identity_id"])

    Sandbox.unboxed_run(Repo, fn ->
      CodexPooler.PoolerFixtures.delete_committed_pools!(pool_ids)
      Repo.delete_all(from pricing in PricingSnapshot, where: pricing.id in ^pricing_ids)
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)
    end)

    :ok
  end
end
