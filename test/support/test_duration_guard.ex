defmodule CodexPooler.TestDurationGuard do
  @moduledoc """
  Fails the invocation when an ordinary test exceeds one second or any test
  exceeds six seconds. A test may opt into the intermediate range with
  `@tag slow: "specific reason this boundary needs more than one second"`.

  Only a `unix_integration` test, whose property is a child VM or Mix project
  it boots, may replace the six-second hard limit with its own measured one:
  `@tag duration_limit_ms: 30_000` next to its slow reason, above the hard
  limit and at most 60 000 ms. The ordinary suite has no such exemption.

  Uses ExUnit.Test.time: setup, body and captured logging, excluding setup_all
  and on_exit. Measuring asynchronous formatter delivery would charge unrelated
  scheduler/formatter backlog to a test instead of its actual execution time.
  CI skips registration entirely: runner-dependent timings are neither checked
  nor reported, while ExUnit still enforces assertion failures normally.

  With `CODEX_POOLER_TEST_DURATION_CANDIDATES` naming a file, a limit exceeded
  during the run is a candidate rather than a verdict: it is written there as
  `path:line<TAB>diagnostic`, one per line, and does not fail the invocation.
  `make test-fast` sets it for its partitions, because four partitions share
  the host and a test's time there includes the other three; it then re-runs
  exactly those locations on their own and fails on what still exceeds the same
  limits. A malformed tag and a missing formatter still fail the run itself.
  """

  use GenServer

  @config_key :codex_pooler_test_duration_guard
  @candidates_env "CODEX_POOLER_TEST_DURATION_CANDIDATES"
  @declared_limit_ceiling_ms 60_000
  @type limits :: %{normal_us: pos_integer(), hard_us: pos_integer()}
  @type finding :: {:timing | :tag, String.t() | nil, String.t()}

  @spec start!(keyword()) :: :ok
  def start!(opts \\ []) do
    unless Enum.any?(~w(CI DRONE GITHUB_ACTIONS), &(System.get_env(&1) in ["1", "true", "TRUE"])) do
      start_local!(opts)
    end

    :ok
  end

  defp start_local!(opts) do
    normal_ms = Keyword.get(opts, :normal_ms, 1_000)
    hard_ms = Keyword.get(opts, :hard_ms, 6_000)

    unless is_integer(normal_ms) and is_integer(hard_ms) and normal_ms > 0 and
             hard_ms >= normal_ms do
      raise ArgumentError, "duration limits must be positive integers with hard_ms >= normal_ms"
    end

    key = {__MODULE__, make_ref()}
    limits = %{normal_us: normal_ms * 1_000, hard_us: hard_ms * 1_000}
    candidates_path = candidates_path()
    :persistent_term.put(key, :awaiting_formatter)

    ExUnit.configure(
      formatters: Enum.uniq(ExUnit.configuration()[:formatters] ++ [__MODULE__]),
      codex_pooler_test_duration_guard: %{key: key, limits: limits}
    )

    # ExUnit drains/stops formatter servers before after_suite callbacks. The
    # receipt therefore outlives its server without leaving a process behind.
    ExUnit.after_suite(fn _stats -> finish(key, candidates_path) end)
    :ok
  end

  defp candidates_path do
    case System.get_env(@candidates_env) do
      path when is_binary(path) and path != "" -> path
      _unset -> nil
    end
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, @config_key)
    :persistent_term.put(config.key, :running)
    {:ok, Map.put(config, :findings, [])}
  end

  @impl true
  def handle_cast({:test_finished, test}, state) do
    case finding(test, state.limits) do
      nil -> {:noreply, state}
      finding -> {:noreply, %{state | findings: [finding | state.findings]}}
    end
  end

  def handle_cast({:suite_finished, _times}, state) do
    :persistent_term.put(state.key, {:finished, Enum.reverse(state.findings)})
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc false
  @spec violation(ExUnit.Test.t(), limits()) :: String.t() | nil
  def violation(%ExUnit.Test{} = test, limits) do
    case finding(test, limits) do
      nil -> nil
      {_kind, location, reason} -> "#{location} #{reason}"
    end
  end

  @doc false
  @spec finding(ExUnit.Test.t(), limits()) :: finding() | nil
  def finding(%ExUnit.Test{state: {state, _}}, _limits)
      when state in [:skipped, :excluded, :invalid],
      do: nil

  def finding(%ExUnit.Test{} = test, limits) do
    with {kind, text} <- tag_problem(test.tags, limits) || timing_problem(test.time, test.tags, limits) do
      {kind, location(test), "#{inspect(test.module)} #{test.name} (#{milliseconds(test.time)}ms): #{text}"}
    end
  end

  defp tag_problem(tags, limits) do
    declared = Map.get(tags, :duration_limit_ms)
    slow = Map.get(tags, :slow, false)

    cond do
      declared != nil and not valid_declared_limit?(declared, tags, limits) ->
        {:tag, "requires @tag duration_limit_ms: an integer above #{milliseconds(limits.hard_us)}ms and at most #{@declared_limit_ceiling_ms}ms, on a unix_integration test with a slow reason"}

      slow not in [false, nil] and not valid_reason?(slow) ->
        {:tag, "requires @tag slow: \"specific reason\"; the reason must be a nonempty string"}

      true ->
        nil
    end
  end

  # Tags are valid here: a declared limit replaces the hard limit, nothing else.
  defp timing_problem(time, tags, limits) do
    declared = Map.get(tags, :duration_limit_ms)
    hard_us = if declared, do: declared * 1_000, else: limits.hard_us

    cond do
      time > hard_us and declared != nil -> {:timing, "exceeds its declared #{milliseconds(hard_us)}ms limit"}
      time > hard_us -> {:timing, "exceeds the #{milliseconds(hard_us)}ms hard limit; slow tags cannot waive it"}
      time > limits.normal_us and not valid_reason?(Map.get(tags, :slow)) -> {:timing, "exceeds #{milliseconds(limits.normal_us)}ms; shorten the test or justify @tag slow: \"specific reason\""}
      true -> nil
    end
  end

  defp location(test) do
    file = test.tags |> Map.get(:file, "unknown") |> Path.relative_to_cwd()
    "#{file}:#{Map.get(test.tags, :line, 0)}"
  end

  defp valid_declared_limit?(declared, tags, limits) do
    is_integer(declared) and declared * 1_000 > limits.hard_us and
      declared <= @declared_limit_ceiling_ms and Map.get(tags, :unix_integration) == true and
      valid_reason?(Map.get(tags, :slow))
  end

  defp valid_reason?(reason) when is_binary(reason), do: String.trim(reason) != ""
  defp valid_reason?(_reason), do: false
  defp milliseconds(microseconds), do: :erlang.float_to_binary(microseconds / 1_000, decimals: 1)

  defp finish(key, candidates_path) do
    receipt = :persistent_term.get(key, :missing)
    :persistent_term.erase(key)

    findings =
      case receipt do
        {:finished, findings} -> findings
        _missing_or_incomplete -> [{:tag, nil, "formatter missing or incomplete; duration enforcement did not run"}]
      end

    {deferred, failures} = Enum.split_with(findings, &(elem(&1, 0) == :timing and is_binary(candidates_path)))

    if is_binary(candidates_path) do
      File.write!(candidates_path, Enum.map(deferred, fn {_kind, location, text} -> "#{location}\t#{text}\n" end))
    end

    if deferred != [] do
      IO.puts(:stderr, "test duration guard deferred #{length(deferred)} candidates to #{candidates_path}:\n" <> Enum.map_join(deferred, "\n", &render/1))
    end

    if failures != [] do
      IO.puts(:stderr, "test duration guard failed:\n" <> Enum.map_join(failures, "\n", &render/1))

      # Let Mix finish coverage and the test task drop its owned database before
      # returning failure. This also applies to ExUnit's plain autorun mode. A
      # run that already fails with a higher status (ExUnit's 2 for a failing
      # test) keeps it, so 1 still means a duration violation alone.
      System.at_exit(fn status -> exit({:shutdown, failure_status(status)}) end)
    end

    :ok
  end

  defp failure_status(status) when is_integer(status) and status > 1, do: status
  defp failure_status(_status), do: 1

  defp render({_kind, nil, text}), do: "  " <> text
  defp render({_kind, location, text}), do: "  #{location} #{text}"
end
