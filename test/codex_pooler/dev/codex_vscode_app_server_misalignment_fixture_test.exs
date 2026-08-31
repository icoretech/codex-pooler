defmodule CodexPooler.Dev.CodexVscodeAppServerMisalignmentFixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Dev.CodexCompactionSmokeFixture.Journal
  alias CodexPooler.Dev.CodexVscodeAppServerMisalignmentFixture

  setup do
    run_id = "misalignment-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "codex-misalignment-#{run_id}")
    bootstrap_owner_fixture()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, run_id: run_id}
  end

  test "acquire and release own only the dedicated run-scoped fixture root", context do
    options = fixture_options(context)

    assert {:ok, %{status: "ready", run_id: run_id}} =
             CodexVscodeAppServerMisalignmentFixture.acquire(options)

    assert run_id == context.run_id
    paths = Journal.paths(context.root, context.run_id)
    assert {:ok, %{"state" => "ready"}} = Journal.read_journal(paths, context.run_id)
    assert {:ok, secret} = Journal.read_secret(paths, context.run_id)
    refute File.read!(paths.journal) =~ secret["api_key"]

    assert {:ok, %{status: "released", run_id: ^run_id}} =
             CodexVscodeAppServerMisalignmentFixture.release(options)

    refute File.exists?(paths.root)
  end

  test "receipt reports only cardinalities and redaction booleans", context do
    options = fixture_options(context)

    assert {:ok, %{status: "ready"}} =
             CodexVscodeAppServerMisalignmentFixture.acquire(options)

    assert {:ok, receipt} =
             CodexVscodeAppServerMisalignmentFixture.receipt(options)

    assert receipt == %{
             status: "closed",
             request_count: 0,
             attempt_count: 0,
             codex_turn_count: 0,
             settlement_count: 0,
             request_redacted: true,
             attempt_redacted: true,
             turn_redacted: true,
             ledger_redacted: true
           }

    assert {:ok, %{status: "released"}} =
             CodexVscodeAppServerMisalignmentFixture.release(options)
  end

  test "parses the strict acquire status and release command shapes", context do
    assert {:ok, :acquire, options} =
             CodexVscodeAppServerMisalignmentFixture.parse_args([
               "acquire",
               "--run-id",
               context.run_id,
               "--upstream-base-url",
               "http://127.0.0.1:4111"
             ])

    assert options[:run_id] == context.run_id
    assert {:ok, :status, _options} = parse_status(context.run_id)
    assert {:ok, :release, _options} = parse_release(context.run_id)
    assert {:error, _message} = parse_status("")
  end

  defp fixture_options(context) do
    [
      run_id: context.run_id,
      root: context.root,
      upstream_base_url: "http://127.0.0.1:4111",
      environment: :test,
      allow_test_database: true
    ]
  end

  defp parse_status(run_id),
    do: CodexVscodeAppServerMisalignmentFixture.parse_args(["status", "--run-id", run_id])

  defp parse_release(run_id),
    do: CodexVscodeAppServerMisalignmentFixture.parse_args(["release", "--run-id", run_id])
end
