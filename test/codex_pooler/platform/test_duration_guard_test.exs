defmodule CodexPooler.TestDurationGuardTest do
  use ExUnit.Case, async: false

  alias CodexPooler.TestDurationGuard

  @limits %{normal_us: 1_000_000, hard_us: 6_000_000}
  @guard Path.expand("test/support/test_duration_guard.ex")
  @probe Path.expand("scripts/verification/test_duration_guard_probe_test.exs")
  # make test-fast exports the candidates file to its partitions; a probe VM that inherited it would defer instead of failing
  @local_env [{"CI", nil}, {"DRONE", nil}, {"GITHUB_ACTIONS", nil}, {"CODEX_POOLER_TEST_DURATION_CANDIDATES", nil}]

  test "exact boundaries pass and both limits reject the first excess microsecond" do
    assert violation(1_000_000, %{}) == nil
    assert violation(1_000_001, %{}) =~ "exceeds 1000.0ms"
    assert violation(6_000_000, %{slow: "real process boundary"}) == nil
    assert violation(6_000_001, %{slow: "real process boundary"}) =~ "6000.0ms hard limit"
  end

  test "a slow exemption requires a nonempty string even when the test happens to be fast" do
    for invalid <- [true, "", " \n ", :slow, 42, %{reason: "boundary"}] do
      assert violation(1, %{slow: invalid}) =~ "reason must be a nonempty string"
    end

    assert violation(1, %{slow: false}) == nil
    assert violation(1, %{slow: nil}) == nil
    assert violation(1_000_001, %{slow: "real process boundary"}) == nil
  end

  test "only a unix_integration test with a slow reason may declare its own hard limit" do
    child_vm = %{unix_integration: true, slow: "boots a child Mix project", duration_limit_ms: 30_000}

    assert violation(29_000_000, child_vm) == nil
    assert violation(30_000_001, child_vm) =~ "exceeds its declared 30000.0ms limit"

    for invalid <- [
          Map.delete(child_vm, :unix_integration),
          Map.put(child_vm, :slow, ""),
          Map.put(child_vm, :duration_limit_ms, 6_000),
          Map.put(child_vm, :duration_limit_ms, 60_001),
          Map.put(child_vm, :duration_limit_ms, "30000")
        ] do
      assert violation(1, invalid) =~ "requires @tag duration_limit_ms"
    end

    assert violation(6_000_001, Map.delete(child_vm, :duration_limit_ms)) =~ "6000.0ms hard limit"
  end

  test "the normal limit is a report finding, the hard limit a timing finding, and malformed tags neither" do
    assert {:report, "unknown:0", text} = finding(1_000_001, %{})
    assert text =~ "not a failure"
    assert {:timing, "unknown:0", _text} = finding(6_000_001, %{})
    assert {:timing, "unknown:0", _text} = finding(6_000_001, %{slow: "real process boundary"})
    assert {:tag, "unknown:0", _text} = finding(1, %{slow: true})
    assert {:tag, "unknown:0", _text} = finding(1, %{duration_limit_ms: 30_000})
  end

  test "skipped and excluded tests do not need slow exemptions" do
    for state <- [{:skipped, "fixture"}, {:excluded, "fixture"}, {:invalid, nil}] do
      assert TestDurationGuard.violation(%ExUnit.Test{state: state, tags: %{slow: true}}, @limits) ==
               nil
    end
  end

  # Over the normal limit is reported for attention and never changes the exit
  # status; only the hard limit, a malformed tag and a missing formatter fail.
  for mode <- ["normal", "trace"],
      {scenario, expected_exit, diagnostic, reported} <- [
        {"fast", 0, nil, 0},
        {"allowed", 0, nil, 0},
        {"ordinary", 0, nil, 1},
        {"setup", 0, nil, 1},
        {"invalid", 1, "reason must be a nonempty string", 0},
        {"hard", 1, "slow tags cannot waive it", 0},
        {"missing", 1, "formatter missing or incomplete", 0},
        # A failing test outranks a duration violation: ExUnit's status 2 stays.
        {"hard_assertion", 2, "slow tags cannot waive it", 0},
        {"slow_assertion", 2, nil, 1}
      ] do
    @tag slow: "boots an isolated BEAM VM to verify ExUnit exit status and teardown"
    test "#{mode} subprocess enforces #{scenario} and completes teardown" do
      {output, exit_code} =
        System.cmd(
          "elixir",
          ["--erl", "+S 2:2", "-r", @guard, @probe, unquote(scenario), unquote(mode)],
          env: @local_env,
          stderr_to_stdout: true
        )

      assert exit_code == unquote(expected_exit), output
      assert output =~ "probe teardown completed", output
      assert output =~ "guard receipts remaining=0", output
      refute output =~ "warning:", output

      assert_diagnostic(output, unquote(diagnostic))
      assert_report(output, unquote(reported))
    end
  end

  for mode <- ["normal", "trace"] do
    @tag slow: "boots an isolated BEAM VM to verify the report's order, cap and exit status"
    test "#{mode} subprocess reports many outliers longest first, capped at 20 lines plus a count" do
      {output, exit_code} = System.cmd("elixir", ["--erl", "+S 2:2", "-r", @guard, @probe, "many", unquote(mode)], env: @local_env, stderr_to_stdout: true)

      assert exit_code == 0, output
      refute output =~ "test duration guard failed:", output
      assert [header | rest] = output |> String.split("\n") |> Enum.drop_while(&(not String.starts_with?(&1, "test duration report:")))
      assert header == "test duration report: 21 tests over 2.0ms without @tag slow (not a failure)"
      {lines, [more | _after]} = Enum.split_while(rest, &(&1 =~ ~r/^  \d+\.\dms /))
      assert more == "  ... and 1 more"
      assert length(lines) == 20
      assert Enum.all?(lines, &(&1 =~ ~r/^  \d+\.\dms scripts\/verification\/test_duration_guard_probe_test\.exs:\d+ CodexPooler\.TestDurationGuardProbe test outlier \d+$/))
      times = Enum.map(lines, fn line -> line |> String.trim_leading() |> Float.parse() |> elem(0) end)
      assert times == Enum.sort(times, :desc), output
    end
  end

  for {flag, value} <- [{"CI", "true"}, {"DRONE", "1"}, {"GITHUB_ACTIONS", "TRUE"}], mode <- ["normal", "trace"], scenario <- ["ordinary", "hard", "assertion"] do
    @tag slow: "boots an isolated BEAM VM to verify CI bypasses duration checks while assertion failures remain errors"
    test "#{flag} #{mode} disables duration checks for #{scenario}" do
      {output, exit_code} = System.cmd("elixir", ["--erl", "+S 2:2", "-r", @guard, @probe, unquote(scenario), unquote(mode)], env: List.keystore(@local_env, unquote(flag), 0, {unquote(flag), unquote(value)}), stderr_to_stdout: true)
      expected_exit = if unquote(scenario) == "assertion", do: 2, else: 0
      assert exit_code == expected_exit, output
      refute output =~ "test duration guard failed:", output
      refute output =~ "test duration report", output
      refute output =~ "hard limit", output
      refute output =~ "@tag slow", output
      assert output =~ "guard formatter registered=false", output
      assert output =~ "guard receipts after start=0", output
      assert output =~ "probe teardown completed", output
      assert output =~ "guard receipts remaining=0", output
    end
  end

  for mode <- ["normal", "trace"],
      {scenario, expected_exit, candidate} <- [
        {"fast", 0, nil},
        # Reported, never written: only a hard-limit excess is a candidate.
        {"ordinary", 0, nil},
        {"hard", 0, "2.0ms hard limit"},
        {"invalid", 1, nil},
        {"missing", 1, nil}
      ] do
    @tag :tmp_dir
    @tag slow: "boots an isolated BEAM VM to verify deferred candidates and the exit status they leave"
    test "#{mode} subprocess with a candidates file defers #{scenario} timing only", %{tmp_dir: dir} do
      candidates = Path.join(dir, "candidates.txt")

      {output, exit_code} =
        System.cmd("elixir", ["--erl", "+S 2:2", "-r", @guard, @probe, unquote(scenario), unquote(mode)],
          env: List.keystore(@local_env, "CODEX_POOLER_TEST_DURATION_CANDIDATES", 0, {"CODEX_POOLER_TEST_DURATION_CANDIDATES", candidates}),
          stderr_to_stdout: true
        )

      assert exit_code == unquote(expected_exit), output
      assert output =~ "probe teardown completed", output
      assert output =~ "guard receipts remaining=0", output

      assert_report(output, if(unquote(scenario) == "ordinary", do: 1, else: 0))

      case unquote(candidate) do
        nil ->
          assert File.read!(candidates) == ""
          refute output =~ "test duration guard deferred", output

        diagnostic ->
          assert [line] = candidates |> File.read!() |> String.split("\n", trim: true)
          assert [location, text] = String.split(line, "\t")
          assert location =~ ~r/^scripts\/verification\/test_duration_guard_probe_test\.exs:\d+$/
          assert text =~ diagnostic
          assert output =~ "test duration guard deferred 1 candidates", output
          refute output =~ "test duration guard failed:", output
      end
    end
  end

  @tag slow: "boots an isolated BEAM VM to verify false CI flags preserve local timing enforcement"
  test "false CI flags keep local duration checks active" do
    {output, exit_code} = System.cmd("elixir", ["--erl", "+S 2:2", "-r", @guard, @probe, "hard", "normal"], env: [{"CI", "false"}, {"DRONE", "0"}, {"GITHUB_ACTIONS", ""}, {"CODEX_POOLER_TEST_DURATION_CANDIDATES", nil}], stderr_to_stdout: true)
    assert exit_code == 1, output
    assert output =~ "test duration guard failed:", output
    assert output =~ "guard formatter registered=true", output
    assert output =~ "guard receipts remaining=0", output
  end

  for mode <- [[], ["--trace"]],
      {limit, hard_ms, failing?, expected_exit} <- [{"normal", 1_000, false, 0}, {"hard", 10, false, 1}, {"hard", 10, true, 2}] do
    @tag :tmp_dir
    @tag slow: "boots an isolated Mix project to verify the CLI exit status after test cleanup"
    test "mix test #{inspect(mode)} exits #{expected_exit} over the #{limit} limit#{if failing?, do: " with a failing test"}", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule DurationProbe.MixProject do
        use Mix.Project
        def project, do: [app: :duration_probe, version: "0.1.0"]
      end
      """)

      File.write!(Path.join(dir, "test/test_helper.exs"), """
      Code.require_file(#{inspect(@guard)})
      ExUnit.start()
      CodexPooler.TestDurationGuard.start!(normal_ms: 1, hard_ms: #{unquote(hard_ms)})
      """)

      File.write!(Path.join(dir, "test/duration_test.exs"), """
      defmodule DurationProbeTest do
        use ExUnit.Case
        test "body is too slow" do
          on_exit(fn -> IO.puts("probe teardown completed") end)
          receive do
          after
            20 -> :ok
          end

          refute #{unquote(failing?)}, "synthetic assertion failure"
        end
      end
      """)

      {output, exit_code} =
        System.cmd("mix", ["test", "--no-color"] ++ unquote(mode),
          cd: dir,
          env: [{"ELIXIR_ERL_OPTIONS", "+S 2:2"} | @local_env],
          stderr_to_stdout: true
        )

      assert exit_code == unquote(expected_exit), output
      assert output =~ "probe teardown completed", output
      refute output =~ "warning:", output

      if unquote(limit) == "hard" do
        assert output =~ "test duration guard failed:", output
        assert output =~ "10.0ms hard limit", output
        refute output =~ "test duration report", output
      else
        refute output =~ "test duration guard failed:", output
        assert output =~ "test duration report: 1 tests over 1.0ms without @tag slow (not a failure)", output
        assert output =~ ~r/^  \d+\.\dms test\/duration_test\.exs:\d+ DurationProbeTest test body is too slow$/m, output
      end
    end
  end

  defp violation(time, tags) do
    TestDurationGuard.violation(
      %ExUnit.Test{module: __MODULE__, name: :example, time: time, tags: tags},
      @limits
    )
  end

  defp finding(time, tags) do
    TestDurationGuard.finding(%ExUnit.Test{module: __MODULE__, name: :example, time: time, tags: tags}, @limits)
  end

  defp assert_diagnostic(output, nil), do: refute(output =~ "test duration guard failed:", output)

  defp assert_diagnostic(output, diagnostic) do
    assert output =~ "test duration guard failed:", output
    assert output =~ diagnostic, output
  end

  defp assert_report(output, 0), do: refute(output =~ "test duration report", output)

  defp assert_report(output, count) do
    assert output =~ "test duration report: #{count} tests over 1.0ms without @tag slow (not a failure)", output
    assert output =~ ~r/^  \d+\.\dms scripts\/verification\/test_duration_guard_probe_test\.exs:\d+ CodexPooler\.TestDurationGuardProbe test duration scenario$/m, output
  end
end
