# Isolated synthetic fixture for TestDurationGuardTest; never loads the application.
ExUnit.start(trace: Enum.at(System.argv(), 1) == "trace")

ExUnit.after_suite(fn _stats ->
  receipts =
    Enum.count(:persistent_term.get(), fn
      {{CodexPooler.TestDurationGuard, _ref}, _value} -> true
      _entry -> false
    end)

  IO.puts("guard receipts remaining=#{receipts}")
end)

scenario = hd(System.argv())

limits =
  case scenario do
    "hard" -> [normal_ms: 1, hard_ms: 2]
    "invalid" -> [normal_ms: 1_000, hard_ms: 2_000]
    "fast" -> [normal_ms: 1_000, hard_ms: 2_000]
    _scenario -> [normal_ms: 1, hard_ms: 1_000]
  end

:ok = CodexPooler.TestDurationGuard.start!(limits)

IO.puts("guard formatter registered=#{CodexPooler.TestDurationGuard in ExUnit.configuration()[:formatters]}")

IO.puts(
  "guard receipts after start=#{Enum.count(:persistent_term.get(), fn
    {{CodexPooler.TestDurationGuard, _ref}, _value} -> true
    _entry -> false
  end)}"
)

if scenario == "missing", do: ExUnit.configure(formatters: [ExUnit.CLIFormatter])

defmodule CodexPooler.TestDurationGuardProbe do
  use ExUnit.Case

  @scenario hd(System.argv())

  slow_reason =
    case @scenario do
      reason when reason in ["allowed", "hard"] -> "synthetic duration boundary"
      "invalid" -> true
      _scenario -> false
    end

  @moduletag slow: slow_reason

  setup do
    on_exit(fn -> IO.puts("probe teardown completed") end)

    if @scenario == "setup" do
      # Real elapsed time is the boundary exercised by this fixture.
      receive do
      after
        20 -> :ok
      end
    end

    :ok
  end

  test "duration scenario" do
    if @scenario in ["ordinary", "allowed", "hard", "slow_assertion"] do
      receive do
      after
        20 -> :ok
      end
    end

    refute @scenario in ["assertion", "slow_assertion"], "synthetic assertion failure"
  end
end
