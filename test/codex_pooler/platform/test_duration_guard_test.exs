defmodule CodexPooler.TestDurationGuardTest do
  use ExUnit.Case, async: false

  alias CodexPooler.TestDurationGuard

  @limits %{normal_us: 1_000_000, hard_us: 6_000_000}
  @guard Path.expand("test/support/test_duration_guard.ex")
  @probe Path.expand("scripts/verification/test_duration_guard_probe_test.exs")
  @local_env [{"CI", nil}, {"DRONE", nil}, {"GITHUB_ACTIONS", nil}]

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

  test "exceeded limits are timing findings while malformed tags are not" do
    assert {:timing, "unknown:0", _text} = finding(1_000_001, %{})
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

  for mode <- ["normal", "trace"],
      {scenario, expected_exit, diagnostic} <- [
        {"fast", 0, nil},
        {"allowed", 0, nil},
        {"ordinary", 1, "exceeds 1.0ms"},
        {"setup", 1, "exceeds 1.0ms"},
        {"invalid", 1, "reason must be a nonempty string"},
        {"hard", 1, "slow tags cannot waive it"},
        {"missing", 1, "formatter missing or incomplete"}
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
    end
  end

  for {flag, value} <- [{"CI", "true"}, {"DRONE", "1"}, {"GITHUB_ACTIONS", "TRUE"}], mode <- ["normal", "trace"], scenario <- ["ordinary", "hard", "assertion"] do
    @tag slow: "boots an isolated BEAM VM to verify CI bypasses duration checks while assertion failures remain errors"
    test "#{flag} #{mode} disables duration checks for #{scenario}" do
      {output, exit_code} = System.cmd("elixir", ["--erl", "+S 2:2", "-r", @guard, @probe, unquote(scenario), unquote(mode)], env: List.keystore(@local_env, unquote(flag), 0, {unquote(flag), unquote(value)}), stderr_to_stdout: true)
      expected_exit = if unquote(scenario) == "assertion", do: 2, else: 0
      assert exit_code == expected_exit, output
      refute output =~ "test duration guard failed:", output
      refute output =~ "test duration report (", output
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
        {"ordinary", 0, "exceeds 1.0ms"},
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
          env: [{"CODEX_POOLER_TEST_DURATION_CANDIDATES", candidates} | @local_env],
          stderr_to_stdout: true
        )

      assert exit_code == unquote(expected_exit), output
      assert output =~ "probe teardown completed", output
      assert output =~ "guard receipts remaining=0", output

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
    {output, exit_code} = System.cmd("elixir", ["--erl", "+S 2:2", "-r", @guard, @probe, "ordinary", "normal"], env: [{"CI", "false"}, {"DRONE", "0"}, {"GITHUB_ACTIONS", ""}], stderr_to_stdout: true)
    assert exit_code == 1, output
    assert output =~ "test duration guard failed:", output
    assert output =~ "guard formatter registered=true", output
    assert output =~ "guard receipts remaining=0", output
  end

  for mode <- [[], ["--trace"]] do
    @tag :tmp_dir
    @tag slow: "boots an isolated Mix project to verify CLI failure after test cleanup"
    test "mix test #{inspect(mode)} fails its exit status after duration violation", %{
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
      CodexPooler.TestDurationGuard.start!(normal_ms: 1, hard_ms: 1_000)
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
        end
      end
      """)

      {output, exit_code} =
        System.cmd("mix", ["test", "--no-color"] ++ unquote(mode),
          cd: dir,
          env: [{"ELIXIR_ERL_OPTIONS", "+S 2:2"} | @local_env],
          stderr_to_stdout: true
        )

      assert exit_code == 1, output
      assert output =~ "test duration guard failed:", output
      assert output =~ "exceeds 1.0ms", output
      assert output =~ "probe teardown completed", output
      refute output =~ "warning:", output
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
end
