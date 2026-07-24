defmodule CodexPooler.MixTasks.TestFastMakeTest do
  use ExUnit.Case, async: false

  @moduletag :test_infrastructure
  @timeout_ms 15_000

  test "two simultaneous N=4 invocations overlap with distinct namespaces and clean exact databases" do
    unless partitioned_child?() do
      fixture = start_fixture!()

      first = Task.async(fn -> run_make(fixture, 4) end)
      second = Task.async(fn -> run_make(fixture, 4) end)

      started = await_receipts!(fixture.directory, "run-", 8)
      File.touch!(fixture.release_path)

      assert {first_output, 0} = Task.await(first, @timeout_ms)
      assert {second_output, 0} = Task.await(second, @timeout_ms)
      assert first_output =~ "test-fast: PASS (4/4 partitions)"
      assert second_output =~ "test-fast: PASS (4/4 partitions)"

      assert_namespace_partitions(started, 2, 1..4)

      dropped = await_receipts!(fixture.directory, "drop-", 8)
      assert MapSet.new(dropped) == rename_receipts(started, "run-", "drop-")
    end
  end

  test "a failing partition is attributed, propagated, and cleaned" do
    unless partitioned_child?() do
      fixture = start_fixture!()

      assert {output, exit_code} =
               run_make(fixture, 2, TEST_FAST_FAIL_PARTITION: "2", TEST_FAST_RELEASE: "1")

      assert exit_code != 0
      assert output =~ "partition 2/2 FAIL (exit 17)"
      assert output =~ "test-fast: FAIL (1/2 partitions)"

      started = await_receipts!(fixture.directory, "run-", 2)
      dropped = await_receipts!(fixture.directory, "drop-", 2)
      assert MapSet.new(dropped) == rename_receipts(started, "run-", "drop-")
    end
  end

  for {signal, make_exit} <- [{"INT", 130}, {"TERM", 143}] do
    test "#{signal} stops children and cleans only the interrupted invocation databases" do
      unless partitioned_child?() do
        fixture = start_fixture!()
        port = open_make_port(fixture, 2, unquote(signal))

        started = await_receipts!(fixture.directory, "run-", 2)

        interrupt_port(port, unquote(signal))

        {output, exit_code} = collect_port(port)

        assert exit_code != 0
        assert output =~ "test-fast: interrupted; stopping partitions"
        assert output =~ "Error #{unquote(make_exit)}"

        dropped = await_receipts!(fixture.directory, "drop-", 2)
        assert MapSet.new(dropped) == rename_receipts(started, "run-", "drop-")
      end
    end
  end

  defp partitioned_child? do
    is_binary(System.get_env("CODEX_POOLER_TEST_RUN_NAMESPACE"))
  end

  defp start_fixture! do
    directory =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-test-fast-acceptance-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    helper_path = Path.join(directory, "test-fast-child")
    release_path = Path.join(directory, "release")

    File.write!(helper_path, """
    #!/bin/bash
    set -eu

    phase="$1"
    namespace="${CODEX_POOLER_TEST_RUN_NAMESPACE:?missing run namespace}"
    partition="${MIX_TEST_PARTITION:?missing partition}"
    receipt="${TEST_FAST_ACCEPTANCE_DIR}/${phase}-${namespace}-${partition}"

    if [ "$phase" = "drop" ]; then
      printf 'namespace=%s partition=%s\n' "$namespace" "$partition" > "$receipt"
      exit 0
    fi

    printf 'namespace=%s partition=%s\n' "$namespace" "$partition" > "$receipt"

    if [ "${TEST_FAST_FAIL_PARTITION:-}" = "$partition" ]; then
      exit 17
    fi

    trap 'exit 0' INT TERM

    while [ ! -e "${TEST_FAST_ACCEPTANCE_DIR}/release" ] &&
          [ "${TEST_FAST_RELEASE:-}" != "1" ]; do
      sleep 0.02
    done
    """)

    File.chmod!(helper_path, 0o700)

    on_exit(fn ->
      File.touch(release_path)
      File.rm_rf!(directory)
    end)

    %{directory: directory, helper_path: helper_path, release_path: release_path}
  end

  defp run_make(fixture, partitions, extra_env \\ []) do
    System.cmd(
      "make",
      ["--no-print-directory", "test-fast", "N=#{partitions}"],
      cd: File.cwd!(),
      env: make_env(fixture, extra_env),
      stderr_to_stdout: true
    )
  end

  defp open_make_port(fixture, partitions, "INT") do
    Port.open(
      {:spawn_executable, "/usr/bin/script"},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-q",
          "-e",
          "/dev/null",
          System.find_executable("make"),
          "--no-print-directory",
          "test-fast",
          "N=#{partitions}"
        ],
        cd: File.cwd!(),
        env:
          Enum.map(make_env(fixture, []), fn {key, value} ->
            {to_charlist(key), to_charlist(value)}
          end)
      ]
    )
  end

  defp open_make_port(fixture, partitions, "TERM") do
    Port.open(
      {:spawn_executable, System.find_executable("make")},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--no-print-directory", "test-fast", "N=#{partitions}"],
        cd: File.cwd!(),
        env:
          Enum.map(make_env(fixture, []), fn {key, value} ->
            {to_charlist(key), to_charlist(value)}
          end)
      ]
    )
  end

  defp interrupt_port(port, "INT") do
    true = Port.command(port, <<3>>)
  end

  defp interrupt_port(port, "TERM") do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {_output, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
  end

  defp make_env(fixture, extra_env) do
    [
      {"TEST_FAST_ACCEPTANCE_DIR", fixture.directory},
      {"TEST_FAST_COMMAND", "#{fixture.helper_path} run"},
      {"TEST_FAST_DROP_COMMAND", "#{fixture.helper_path} drop"}
      | Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)
    ]
  end

  defp await_receipts!(directory, prefix, expected, attempts \\ 300)

  defp await_receipts!(directory, prefix, expected, attempts) when attempts > 0 do
    receipts =
      directory
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    if length(receipts) == expected do
      receipts
    else
      receive do
      after
        20 -> await_receipts!(directory, prefix, expected, attempts - 1)
      end
    end
  end

  defp await_receipts!(directory, prefix, expected, 0) do
    flunk("expected #{expected} #{prefix} receipts in #{directory}")
  end

  defp assert_namespace_partitions(receipts, namespace_count, partitions) do
    parsed =
      Enum.map(receipts, fn receipt ->
        [namespace, partition] =
          receipt
          |> String.replace_prefix("run-", "")
          |> String.split("-", parts: 2)

        assert namespace =~ ~r/^[0-9a-f]{16}$/
        {namespace, String.to_integer(partition)}
      end)

    assert parsed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == namespace_count

    assert parsed
           |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
           |> Map.values()
           |> Enum.all?(&(Enum.sort(&1) == Enum.to_list(partitions)))
  end

  defp rename_receipts(receipts, from, to) do
    receipts
    |> Enum.map(&String.replace_prefix(&1, from, to))
    |> MapSet.new()
  end

  defp collect_port(port, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, output <> data)

      {^port, {:exit_status, exit_code}} ->
        {output, exit_code}
    after
      @timeout_ms ->
        terminate_port(port)
        Port.close(port)
        flunk("timed out waiting for make test-fast")
    end
  end

  defp terminate_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])

      nil ->
        :ok
    end
  end
end
