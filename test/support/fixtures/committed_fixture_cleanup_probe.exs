# Probe for `CodexPooler.CommittedFixtureCleanupTest`. Not part of the ordinary suite: it is a
# `mix run` script rather than a `*_test.exs` file, because the `mix test` alias drops and
# recreates the test database and the parent test is using it.
#
# Two ExUnit tests commit a pricing snapshot outside the sandbox and then fail an assertion
# inside a `run_unboxed/1` block. They differ only in how the cleanup is attached: the first
# scopes it with `try/after`, the second registers it with ExUnit. Both are expected to fail;
# what the parent reads is which committed rows are left behind afterwards.
#
# Receipts are printed as one JSON object per line on stdout.

ExUnit.start(autorun: false, capture_log: true)

Ecto.Adapters.SQL.Sandbox.mode(CodexPooler.Repo, :manual)

defmodule CodexPooler.CommittedFixtureCleanupProbe do
  # This file deliberately does not end in `_test.exs`, which is what the check objects to.
  # Naming it so would make the `mix test` alias collect it, and that alias drops and recreates
  # the test database the parent test is currently using. It is run through `mix run` instead.
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.UnboxedFixture

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "scoped cleanup" do
    fixture = commit_fixture!("scoped")

    try do
      run_unboxed(fn -> flunk("forced failure inside the unboxed block") end)
    after
      delete_fixture!(fixture)
    end
  end

  test "registered cleanup" do
    fixture = commit_fixture!("registered")
    register_unboxed_cleanup!(fn -> delete_fixture!(fixture) end)

    run_unboxed(fn -> flunk("forced failure inside the unboxed block") end)
  end

  defp commit_fixture!(mode) do
    setup =
      run_unboxed(fn ->
        accounting_setup(%{
          account_label: "Committed fixture cleanup #{mode} #{System.unique_integer([:positive])}"
        })
      end)

    receipt(%{
      stage: "fixture",
      mode: mode,
      pool_id: setup.pool.id,
      pricing_snapshot_id: setup.pricing.id,
      price_version: setup.pricing.price_version,
      identity_id: setup.identity.id
    })

    setup
  end

  # Everything `accounting_setup/1` commits, not only the row this probe is about. A partial
  # delete leaves upstream accounts and identities behind, and the suites that assert absolute
  # identity counts then fail in files that have nothing to do with this one -- which is the
  # very defect this probe exists to demonstrate.
  defp delete_fixture!(setup) do
    Repo.delete_all(from pool in Pool, where: pool.id == ^setup.pool.id)
    Repo.delete_all(from pricing in PricingSnapshot, where: pricing.id == ^setup.pricing.id)
    Repo.delete_all(from identity in UpstreamIdentity, where: identity.id == ^setup.identity.id)
    :ok
  end

  defp receipt(payload), do: IO.puts(CodexPooler.JSON.encode!(payload))
end

%{failures: failures, total: total} = ExUnit.run()

IO.puts(CodexPooler.JSON.encode!(%{stage: "probe", failures: failures, total: total}))
