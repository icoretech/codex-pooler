# Probe for `CodexPooler.CommittedWriteGuardTest`. Not part of the ordinary suite: it is a `mix run`
# script rather than a `*_test.exs` file, because the `mix test` alias drops and recreates the test
# database the parent test is using.
#
# It starts the committed write guard the way `test/test_helper.exs` does, then runs, in order,
# tests that leave committed rows behind in each way the guard has to catch, between tests the
# guard must not blame. Receipts are printed as one JSON object per line on stdout: one per finished
# test with its outcome and the tables its failure names, and a summary. Every row a probe test
# commits carries the `committed-write-guard-probe` or `Committed write guard probe` label the
# parent removes.

defmodule CodexPooler.CommittedWriteGuardProbe do
  @moduledoc false

  @connection_keys [
    :hostname,
    :port,
    :username,
    :password,
    :socket_dir,
    :socket_options,
    :ssl,
    :ssl_opts,
    :database
  ]

  def receipt(payload), do: IO.puts(CodexPooler.JSON.encode!(payload))

  def connection_options do
    CodexPooler.Repo.config() |> Keyword.take(@connection_keys) |> Keyword.put(:pool_size, 1)
  end

  def untraced_connection, do: __MODULE__.UntracedConnection

  def insert_presence!(conn, label) do
    instance_id = "committed-write-guard-probe-#{label}-#{System.unique_integer([:positive])}"

    Postgrex.query!(
      conn,
      "INSERT INTO instance_presences (instance_id, started_at, last_seen_at) " <>
        "VALUES ($1, now(), now())",
      [instance_id]
    )

    instance_id
  end

  # An in-place update of rows this probe committed: no row count moves, so only a content
  # comparison can see it.
  def touch_presences!(conn) do
    %Postgrex.Result{num_rows: updated} =
      Postgrex.query!(
        conn,
        "UPDATE instance_presences SET last_seen_at = last_seen_at + interval '1 second' " <>
          "WHERE instance_id LIKE 'committed-write-guard-probe-%'",
        []
      )

    updated
  end
end

ExUnit.start(
  autorun: false,
  capture_log: true,
  seed: 0,
  formatters: [CodexPooler.CommittedWriteGuardProbe.Receipts]
)

Ecto.Adapters.SQL.Sandbox.mode(CodexPooler.Repo, :manual)

# Opened before the guard starts, so no counter the guard reads ever moves for it: the last test
# commits through it the way a test commits over a connection opened before its window.
{:ok, _untraced} =
  CodexPooler.CommittedWriteGuardProbe.connection_options()
  |> Keyword.put(:name, CodexPooler.CommittedWriteGuardProbe.untraced_connection())
  |> Postgrex.start_link()

:ok = CodexPooler.CommittedWriteGuard.start!()

defmodule CodexPooler.CommittedWriteGuardProbe.Receipts do
  @moduledoc false
  use GenServer

  alias CodexPooler.CommittedWriteGuardProbe, as: Probe

  @impl GenServer
  def init(_opts), do: {:ok, nil}

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{name: name, state: state}}, nil) do
    {outcome, messages} = outcome(state)

    Probe.receipt(%{
      stage: "test",
      name: Atom.to_string(name),
      outcome: outcome,
      guard: Enum.find_value(messages, "none", &guard_kind/1),
      tables: messages |> Enum.flat_map(&changed_tables/1) |> Enum.uniq() |> Enum.sort()
    })

    {:noreply, nil}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{name: name, state: state}}, nil) do
    {outcome, messages} = outcome(state)

    Probe.receipt(%{
      stage: "module",
      name: inspect(name),
      outcome: outcome,
      guard: Enum.find_value(messages, "none", &guard_kind/1),
      tables: messages |> Enum.flat_map(&changed_tables/1) |> Enum.uniq() |> Enum.sort()
    })

    {:noreply, nil}
  end

  def handle_cast(_event, nil), do: {:noreply, nil}

  defp outcome(nil), do: {"passed", []}
  defp outcome({:failed, failures}), do: {"failed", Enum.map(failures, &failure_message/1)}
  defp outcome(other), do: {other |> elem(0) |> Atom.to_string(), []}

  defp failure_message({_kind, %{message: message}, _stack}) when is_binary(message), do: message
  defp failure_message({kind, reason, stack}), do: Exception.format_banner(kind, reason, stack)

  defp guard_kind(message) do
    cond do
      message =~ "committed rows changed during" -> "during"
      message =~ "committed rows changed before" -> "before"
      message =~ "committed rows changed while" -> "module"
      true -> nil
    end
  end

  defp changed_tables(message) do
    ~r/^  ([a-z_]+): (?:(?:\d+|absent) -> |content changed)/m
    |> Regex.scan(message, capture: :all_but_first)
    |> List.flatten()
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.SandboxedCaseTest do
  # This file deliberately does not end in `_test.exs`: the `mix test` alias would collect it and
  # drop the test database the parent test is using. It runs through `mix run` instead.
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture

  alias CodexPooler.CommittedWriteGuardProbe, as: Probe
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "leaves an upstream identity no user created behind" do
    run_unboxed(fn ->
      upstream_identity_fixture(%{account_label: "Committed write guard probe leak"})
    end)
  end

  test "writes inside the sandbox after that leak" do
    assert %UpstreamIdentity{} = upstream_identity_fixture()
  end

  test "fails in its body after leaking a committed identity" do
    run_unboxed(fn ->
      upstream_identity_fixture(%{account_label: "Committed write guard probe failed body"})
    end)

    flunk("synthetic primary failure")
  end

  test "commits an identity and registers its removal first" do
    label = "Committed write guard probe cleanup #{System.unique_integer([:positive])}"

    register_unboxed_cleanup!(fn ->
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.account_label == ^label)
    end)

    run_unboxed(fn -> upstream_identity_fixture(%{account_label: label}) end)
  end

  test "commits through a connection it starts with DBConnection.start_link/2" do
    opts = Postgrex.Utils.default_opts(Probe.connection_options())
    {:ok, conn} = DBConnection.start_link(Postgrex.Protocol, opts)
    Probe.insert_presence!(conn, "dbconnection")
    GenServer.stop(conn)
  end

  test "updates the committed instance settings singleton and never restores it" do
    run_unboxed(fn ->
      Repo.query!(
        ~s[UPDATE instance_settings ] <>
          ~s[SET metadata = metadata || '{"committed_write_guard_probe": true}'::jsonb]
      )
    end)
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.TimestampChangeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.UnboxedFixture

  # Two committed timestamp-only changes the guard must tell apart: one that names an event, and
  # one that is bookkeeping. Neither changes a row count, so only the content comparison can see
  # either of them.
  test "completes the committed bootstrap singleton and never restores it" do
    run_unboxed(fn ->
      Repo.query!("UPDATE platform_bootstrap_state SET completed_at = now() WHERE status = 'pending'")
    end)
  end

  # `updated_at` alone: no restore is registered, because the guard is documented not to report it
  # and nothing in the suite reads it.
  test "bumps only the committed instance settings updated_at" do
    run_unboxed(fn -> Repo.query!("UPDATE instance_settings SET updated_at = now()") end)
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.SetupAllFixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @label "Committed write guard probe setup_all fixture"

  setup_all do
    # Registered after the guard's own module callback and therefore run before it: the module
    # removes what it committed, and the guard then finds the committed state as it was.
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from identity in UpstreamIdentity, where: identity.account_label == @label)
      end)
    end)

    Sandbox.unboxed_run(Repo, fn -> upstream_identity_fixture(%{account_label: @label}) end)

    :ok
  end

  test "runs with the identity its setup_all committed" do
    assert %UpstreamIdentity{} = upstream_identity_fixture()
  end

  test "writes nothing of its own" do
    assert true
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.SetupAllLeakTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias Ecto.Adapters.SQL.Sandbox

  @label "Committed write guard probe setup_all leak"

  setup_all do
    Sandbox.unboxed_run(Repo, fn -> upstream_identity_fixture(%{account_label: @label}) end)
    :ok
  end

  test "passes while the row its setup_all committed is still there" do
    assert true
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.AfterSetupAllLeakTest do
  use CodexPooler.DataCase, async: false

  test "is not charged for the module that leaked before it" do
    assert true
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.AutoModeTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "leaves a pricing snapshot behind in auto mode" do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    unique = System.unique_integer([:positive])

    Repo.insert!(%PricingSnapshot{
      model_identifier: "committed-write-guard-probe-#{unique}",
      price_version: "guard-probe-#{unique}",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(1),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(1),
      reasoning_token_micros: Decimal.new(1),
      request_base_micros: Decimal.new(0),
      effective_at: now,
      captured_at: now,
      config: CodexPooler.AccountingTestSupport.pricing_config(%{})
    })
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.UnguardedTest do
  use ExUnit.Case, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "commits an identity without the guard" do
    Sandbox.unboxed_run(Repo, fn ->
      upstream_identity_fixture(%{account_label: "Committed write guard probe unguarded"})
    end)
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.AfterUnguardedTest do
  use CodexPooler.DataCase, async: false

  test "starts after rows an unguarded test committed" do
    assert true
  end

  test "starts after that failure has been reported" do
    assert true
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.UntracedRowLeakTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.CommittedWriteGuardProbe, as: Probe

  # The connection was opened before the guard started, so no counter the guard reads moves for it
  # and no node is connected: only the row count this test ends with can charge the row to it.
  test "commits a row through a connection opened before the guard started" do
    Probe.insert_presence!(Probe.untraced_connection(), "untraced-leak")
  end

  test "writes nothing after that untraced leak" do
    assert true
  end
end

defmodule CodexPooler.CommittedWriteGuardProbe.LastUntracedTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.CommittedWriteGuardProbe, as: Probe

  # The documented limit: an in-place update through a channel the guard cannot see moves no row
  # count either, so the content is never compared for this test. Only the check after the suite
  # sees it, and being the last test there is no later one to report it.
  test "updates a committed row through that connection, as the last test" do
    assert Probe.touch_presences!(Probe.untraced_connection()) > 0
  end
end

%{failures: failures, total: total} = ExUnit.run()

CodexPooler.CommittedWriteGuardProbe.receipt(%{stage: "probe", failures: failures, total: total})
