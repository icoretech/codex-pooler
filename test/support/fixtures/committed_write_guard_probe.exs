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
    {outcome, messages} =
      case state do
        nil -> {"passed", []}
        {:failed, failures} -> {"failed", Enum.map(failures, &failure_message/1)}
        other -> {other |> elem(0) |> Atom.to_string(), []}
      end

    Probe.receipt(%{
      stage: "test",
      name: Atom.to_string(name),
      outcome: outcome,
      guard: Enum.find_value(messages, "none", &guard_kind/1),
      tables: messages |> Enum.flat_map(&changed_tables/1) |> Enum.uniq() |> Enum.sort()
    })

    {:noreply, nil}
  end

  def handle_cast(_event, nil), do: {:noreply, nil}

  defp failure_message({_kind, %{message: message}, _stack}) when is_binary(message), do: message
  defp failure_message({kind, reason, stack}), do: Exception.format_banner(kind, reason, stack)

  defp guard_kind(message) do
    cond do
      message =~ "committed rows changed during" -> "during"
      message =~ "committed rows changed before" -> "before"
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

defmodule CodexPooler.CommittedWriteGuardProbe.LastUntracedTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.CommittedWriteGuardProbe, as: Probe

  # No counter moves and no node is connected, so the test's own verification cannot see the row;
  # only the count after the suite can.
  test "commits through a connection opened before the guard started, as the last test" do
    Probe.insert_presence!(Probe.untraced_connection(), "untraced")
  end
end

%{failures: failures, total: total} = ExUnit.run()

CodexPooler.CommittedWriteGuardProbe.receipt(%{stage: "probe", failures: failures, total: total})
