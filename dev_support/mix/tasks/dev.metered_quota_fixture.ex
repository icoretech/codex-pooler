defmodule Mix.Tasks.Dev.MeteredQuotaFixture do
  @moduledoc """
  Manages the deterministic local metered quota QA fixture.

      MIX_ENV=dev mix dev.metered_quota_fixture acquire --output tmp/metered-quota-fixture/receipt.json
      MIX_ENV=dev mix dev.metered_quota_fixture status --receipt tmp/metered-quota-fixture/receipt.json
      MIX_ENV=dev mix dev.metered_quota_fixture release --receipt tmp/metered-quota-fixture/receipt.json
  """

  use Mix.Task

  alias CodexPooler.Dev.MeteredQuotaFixture

  @requirements ["app.config"]
  @shortdoc "Manage the deterministic local metered quota QA fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- parse_args(args),
         :ok <- maybe_start_application(action, options),
         result <- run_action(action, options) do
      case result do
        {:ok, status} -> Mix.shell().info(Jason.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [output: :string, receipt: :string], aliases: []) do
      {[output: path], ["acquire"], []} -> {:ok, :acquire, receipt_options(path)}
      {[], ["acquire"], []} -> {:ok, :acquire, []}
      {[receipt: path], ["status"], []} -> {:ok, :status, receipt_options(path)}
      {[], ["status"], []} -> {:ok, :status, []}
      {[receipt: path], ["release"], []} -> {:ok, :release, receipt_options(path)}
      {[], ["release"], []} -> {:ok, :release, []}
      _invalid -> {:error, usage()}
    end
  end

  defp receipt_options(path) do
    expanded_path = Path.expand(path)
    [receipt_path: expanded_path, allowed_receipt_root: Path.dirname(expanded_path)]
  end

  defp maybe_start_application(:status, options) do
    case File.lstat(MeteredQuotaFixture.receipt_path(options)) do
      {:error, :enoent} -> :ok
      _present_or_error -> start_application()
    end
  end

  defp maybe_start_application(_action, _options), do: start_application()

  defp start_application do
    Mix.Task.run("app.start")
    :ok
  end

  defp run_action(:acquire, options), do: MeteredQuotaFixture.acquire(options)
  defp run_action(:status, options), do: MeteredQuotaFixture.status(options)
  defp run_action(:release, options), do: MeteredQuotaFixture.release(options)

  defp usage do
    "use acquire [--output PATH], status [--receipt PATH], or release [--receipt PATH]"
  end
end
