defmodule CodexPooler.TestDiagnostics do
  @moduledoc """
  Opt-in console receipts for tests that record evidence (lock orders, query
  counts, node topologies). The suite output stays quiet by default; set
  `CODEX_POOLER_TEST_DIAGNOSTICS=1` to print them.
  """

  @env "CODEX_POOLER_TEST_DIAGNOSTICS"

  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env(@env) == "1"

  @doc "Prints `line` only when diagnostics are enabled; `line` may be a lazy function."
  @spec puts(iodata() | (-> iodata())) :: :ok
  def puts(line) do
    if enabled?() do
      line = if is_function(line, 0), do: line.(), else: line
      IO.puts(line)
    end

    :ok
  end
end
