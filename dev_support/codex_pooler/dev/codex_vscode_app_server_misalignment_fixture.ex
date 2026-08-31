defmodule CodexPooler.Dev.CodexVscodeAppServerMisalignmentFixture do
  @moduledoc """
  Run-scoped resources for the released Codex app-server misalignment smoke.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Dev.CodexCompactionSmokeFixture
  alias CodexPooler.Dev.CodexCompactionSmokeFixture.Journal
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  @default_root Path.join(["tmp", "codex-vscode-app-server-misalignment"])

  @type options :: keyword()

  @spec parse_args([String.t()]) :: {:ok, atom(), options()} | {:error, String.t()}
  def parse_args(args), do: CodexCompactionSmokeFixture.parse_args(args)

  @spec acquire(options()) :: {:ok, map()} | {:error, String.t()}
  def acquire(options), do: CodexCompactionSmokeFixture.acquire(with_root(options))

  @spec status(options()) :: {:ok, map()} | {:error, String.t()}
  def status(options), do: CodexCompactionSmokeFixture.status(with_root(options))

  @spec release(options()) :: {:ok, map()} | {:error, String.t()}
  def release(options), do: CodexCompactionSmokeFixture.release(with_root(options))

  @spec receipt(options()) :: {:ok, map()} | {:error, String.t()}
  def receipt(options) do
    options = with_root(options)
    run_id = Keyword.fetch!(options, :run_id)
    root = Keyword.fetch!(options, :root)
    paths = Journal.paths(root, run_id)

    case Journal.read_journal(paths, run_id) do
      {:ok, %{"state" => "ready", "pool_id" => pool_id}} ->
        requests = Repo.all(from request in Request, where: request.pool_id == ^pool_id)
        request_ids = Enum.map(requests, & &1.id)
        attempts = Repo.all(from attempt in Attempt, where: attempt.request_id in ^request_ids)
        turns = Repo.all(from turn in CodexTurn, where: turn.request_id in ^request_ids)
        entries = Repo.all(from entry in LedgerEntry, where: entry.request_id in ^request_ids)

        forbidden_keys = ["misalignment", "error_type", "detailed_explanation", "steer"]

        {:ok,
         %{
           status: "closed",
           request_count: length(requests),
           attempt_count: length(attempts),
           codex_turn_count: length(turns),
           settlement_count: Enum.count(entries, &(&1.entry_kind == "settlement")),
           request_redacted: redacted?(requests, forbidden_keys),
           attempt_redacted: redacted?(attempts, forbidden_keys),
           turn_redacted: redacted?(turns, forbidden_keys),
           ledger_redacted: redacted?(entries, forbidden_keys)
         }}

      {:ok, _journal} ->
        {:error, "fixture is not ready"}

      {:error, _reason} ->
        {:error, "fixture journal is unsafe or invalid"}
    end
  end

  @spec with_isolated_config(String.t(), (String.t() -> result)) :: result when result: var
  def with_isolated_config(run_id, function),
    do: CodexCompactionSmokeFixture.with_isolated_config(run_id, function)

  defp with_root(options) do
    Keyword.put_new(options, :root, Path.expand(@default_root, File.cwd!()))
  end

  defp redacted?(rows, forbidden_keys) do
    encoded = Jason.encode!(rows)
    Enum.all?(forbidden_keys, &(not String.contains?(encoded, &1)))
  end
end
