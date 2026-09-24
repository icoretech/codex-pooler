defmodule CodexPooler.MixTasks.QaPhaseTest do
  use CodexPooler.UnixIntegrationCase, async: false, tools: ~w(perl)

  @helper Path.expand("../../../dev_support/bin/qa-phase", __DIR__)

  test "preserves the actual command exit code and output" do
    assert {"owned phase\n", 23} = System.cmd(@helper, ["/bin/bash", "-c", "printf 'owned phase\\n'; exit 23"], stderr_to_stdout: true)
  end

  for disposition <- ["trap 'exit 143' TERM", "trap '' TERM"] do
    @tag phase_disposition: disposition
    test "TERM stops the owned command and stubborn descendant with #{disposition}", %{phase_disposition: disposition} do
      root = Path.join(System.tmp_dir!(), "qa-phase-#{System.pid()}-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      File.mkdir_p!(root)
      marker = Path.join(root, "pids")
      executable = Path.join(root, "phase")

      File.write!(executable, """
      #!/bin/bash
      #{disposition}
      bash -c 'trap "" TERM; while [ ! -s "$1" ]; do sleep 0.01; done; echo "ready $$"; while :; do sleep 1; done' phase-child "$1" &
      descendant=$!
      printf '%s %s\n' "$$" "$descendant" > "$1"
      wait
      """)

      File.chmod!(executable, 0o700)
      port = Port.open({:spawn_executable, @helper}, [:binary, :exit_status, :stderr_to_stdout, args: [executable, marker]])
      {:os_pid, supervisor_pid} = Port.info(port, :os_pid)

      supervisor_identity = CodexPooler.InstancePresencePeer.capture_os_process_identity!(Integer.to_string(supervisor_pid))
      on_exit(fn -> stop_owned_supervisor(supervisor_identity) end)

      assert_receive {^port, {:data, ready}}, 15_000
      assert ready =~ "ready "
      [command_pid, descendant_pid] = marker |> File.read!() |> String.split()
      identities = Enum.map([Integer.to_string(supervisor_pid), command_pid, descendant_pid], &CodexPooler.InstancePresencePeer.capture_os_process_identity!/1)
      assert {_, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(supervisor_pid)], stderr_to_stdout: true)
      assert_receive {^port, {:exit_status, 137}}, 15_000
      for identity <- identities, do: CodexPooler.InstancePresencePeer.assert_os_process_stopped!(identity)
    end
  end

  test "the cap marker stops the owned command group without any signal to the supervisor" do
    root = Path.join(System.tmp_dir!(), "qa-phase-cap-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    pids = Path.join(root, "pids")
    cap = Path.join(root, "cap-reached")
    executable = Path.join(root, "phase")

    File.write!(executable, """
    #!/bin/bash
    [ -z "${QA_PHASE_CANCEL_FILE:-}" ] || exit 64
    (while :; do sleep 0.05; done) &
    printf '%s %s\n' "$$" "$!" > "$1"
    echo ready
    wait
    """)

    File.chmod!(executable, 0o700)
    port = Port.open({:spawn_executable, @helper}, [:binary, :exit_status, :stderr_to_stdout, args: [executable, pids], env: [{~c"QA_PHASE_CANCEL_FILE", String.to_charlist(cap)}]])
    {:os_pid, supervisor_pid} = Port.info(port, :os_pid)
    supervisor_identity = CodexPooler.InstancePresencePeer.capture_os_process_identity!(Integer.to_string(supervisor_pid))
    on_exit(fn -> stop_owned_supervisor(supervisor_identity) end)

    assert_receive {^port, {:data, "ready\n"}}, 15_000
    [command_pid, descendant_pid] = pids |> File.read!() |> String.split()
    identities = Enum.map([command_pid, descendant_pid], &CodexPooler.InstancePresencePeer.capture_os_process_identity!/1)
    File.touch!(cap)
    assert_receive {^port, {:exit_status, 137}}, 15_000
    for identity <- [supervisor_identity | identities], do: CodexPooler.InstancePresencePeer.assert_os_process_stopped!(identity)
  end

  test "a cap marker present before launch ends the phase before the command starts" do
    root = Path.join(System.tmp_dir!(), "qa-phase-cap-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    cap = Path.join(root, "cap-reached")
    started = Path.join(root, "started")
    File.touch!(cap)

    assert {"", 124} = System.cmd(@helper, ["/bin/bash", "-c", ": > \"$1\"", "phase", started], env: [{"QA_PHASE_CANCEL_FILE", cap}], stderr_to_stdout: true)
    refute File.exists?(started)
  end

  defp stop_owned_supervisor(identity) do
    snapshot = owned_snapshot(identity)

    if CodexPooler.InstancePresencePeer.classify_owned_process(identity, snapshot) == :live do
      System.cmd("/bin/kill", ["-TERM", identity.pid], stderr_to_stdout: true)
    end

    CodexPooler.InstancePresencePeer.assert_os_process_stopped!(identity)
  end

  defp owned_snapshot(%{source: :proc, pid: pid}) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> CodexPooler.InstancePresencePeer.parse_linux_process_stat(stat)
      {:error, :enoent} -> :absent
    end
  end

  defp owned_snapshot(%{source: :ps, pid: pid}) do
    case System.cmd("/bin/ps", ["-p", pid, "-o", "stat=", "-o", "lstart=", "-o", "ppid="], env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {output, 0} -> CodexPooler.InstancePresencePeer.parse_portable_process_output(output)
      {_output, _code} -> :unknown
    end
  end
end
