defmodule CodexPooler.MixTasks.DevServerLifecycleTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../../dev_support/bin/dev-server-lifecycle", __DIR__)

  test "start accepts the Makefile PORT assignment command and records the owned process" do
    fixture = mix_server_fixture!()
    login_home = temp_dir!("login-home")
    File.write!(Path.join(login_home, ".bash_profile"), "PATH=/usr/bin:/bin\nexport PATH\n")

    {output, code} =
      lifecycle("start", fixture, [
        {"HOME", login_home},
        {"PATH", "#{fixture.bin_dir}:#{System.fetch_env!("PATH")}"}
      ])

    log = File.read!(fixture.log_path)
    assert code == 0, "lifecycle start failed: #{output}#{log}"
    assert output =~ "owned dev server started"

    active_run = fixture.state_dir |> Path.join("active") |> File.read!() |> String.trim()
    receipt_path = Path.join(fixture.state_dir, "#{active_run}.receipt")
    receipt = File.read!(receipt_path)
    assert receipt =~ ~r/^pid\t[1-9][0-9]*$/m
    assert receipt =~ ~r/^start_signature\t.+$/m
    assert receipt =~ "command\t"
    assert receipt =~ "mix phx.server"
    assert receipt =~ "cwd\t#{File.cwd!()}"
    assert receipt =~ "port\t#{fixture.port}"

    [pid_string] = Regex.run(~r/^pid\t([1-9][0-9]*)$/m, receipt, capture: :all_but_first)
    pid = String.to_integer(pid_string)
    assert process_alive?(pid)

    assert {status_output, 0} =
             lifecycle("status", fixture, [
               {"PATH", "#{fixture.bin_dir}:#{System.fetch_env!("PATH")}"}
             ])

    assert status_output =~ "healthz ok"

    assert {stop_output, 0} =
             lifecycle("stop", fixture, [
               {"PATH", "#{fixture.bin_dir}:#{System.fetch_env!("PATH")}"}
             ])

    assert stop_output =~ "owned dev server stopped"
    refute process_alive?(pid)
    refute File.exists?(Path.join(fixture.state_dir, "active"))
    refute File.exists?(receipt_path)
  end

  test "start refuses unrelated healthy and non-healthy listeners without stopping them" do
    for healthy? <- [true, false] do
      fixture = server_fixture!(healthy?: healthy?, cwd: temp_dir!("unrelated"))

      assert {output, code} = lifecycle("start", fixture)
      assert code != 0
      assert output =~ "refusing occupied port"
      assert process_alive?(fixture.listener_pid)

      stop_fixture(fixture)
    end
  end

  test "start refuses a healthy server from another checkout" do
    other_checkout = temp_dir!("other-checkout")
    fixture = server_fixture!(healthy?: true, cwd: other_checkout)

    assert {output, code} = lifecycle("start", fixture)
    assert code != 0
    assert output =~ "refusing occupied port"
    assert process_alive?(fixture.listener_pid)

    stop_fixture(fixture)
  end

  test "stop clears a stale legacy pidfile without requiring an ownership receipt" do
    fixture = server_fixture!(start?: false, cwd: File.cwd!())
    File.mkdir_p!(fixture.state_dir)
    legacy_pid_path = Path.join(fixture.state_dir, "legacy.pid")
    File.write!(legacy_pid_path, "999999\n")

    assert {output, 0} = lifecycle("stop", fixture)
    assert output =~ "removed stale legacy PID file"
    refute File.exists?(legacy_pid_path)
  end

  test "stop succeeds when no lifecycle state exists" do
    fixture = server_fixture!(start?: false, cwd: File.cwd!())

    assert {output, 0} = lifecycle("stop", fixture)
    assert output =~ "no owned dev server to stop"
  end

  test "stop adopts and stops a verified legacy listener without requiring an ownership receipt" do
    fixture = server_fixture!(healthy?: true, cwd: File.cwd!())
    File.mkdir_p!(fixture.state_dir)
    legacy_pid_path = Path.join(fixture.state_dir, "legacy.pid")
    File.write!(legacy_pid_path, "#{fixture.listener_pid}\n")

    assert {output, 0} = lifecycle("stop", fixture)
    assert output =~ "adopted verified legacy dev server"
    assert output =~ "owned dev server stopped"
    refute process_alive?(fixture.listener_pid)
    refute File.exists?(legacy_pid_path)
  end

  test "stop refuses a legacy listener from another checkout" do
    fixture = server_fixture!(healthy?: true, cwd: temp_dir!("legacy-other-checkout"))
    File.mkdir_p!(fixture.state_dir)
    legacy_pid_path = Path.join(fixture.state_dir, "legacy.pid")
    File.write!(legacy_pid_path, "#{fixture.listener_pid}\n")

    assert {output, code} = lifecycle("stop", fixture)
    assert code != 0
    assert output =~ "refusing legacy PID from another checkout"
    assert process_alive?(fixture.listener_pid)

    stop_fixture(fixture)
  end

  test "stop refuses a broken ownership pointer and cleans a reused-pid receipt without stopping that process" do
    fixture = server_fixture!(healthy?: false, cwd: File.cwd!())
    File.mkdir_p!(fixture.state_dir)

    File.write!(Path.join(fixture.state_dir, "active"), "missing-run\n")

    assert {output, code} = lifecycle("stop", fixture)
    assert code != 0
    assert output =~ "refusing"
    assert process_alive?(fixture.listener_pid)

    reused_run = "0123456789abcdef01234567"
    File.write!(Path.join(fixture.state_dir, "active"), "#{reused_run}\n")

    reused_receipt_path = Path.join(fixture.state_dir, "#{reused_run}.receipt")

    File.write!(reused_receipt_path, """
    version\t1
    state\trunning
    pid\t#{fixture.listener_pid}
    start_signature\tnot-the-current-start
    command\tmix phx.server
    cwd\t#{File.cwd!()}
    port\t#{fixture.port}
    """)

    # The recorded start signature proves the owned process is gone and the
    # pid now belongs to someone else: the receipt is cleaned, the reused
    # process is never signalled.
    assert {output, 0} = lifecycle("stop", fixture)
    assert output =~ "cleared stale ownership receipt"
    assert output =~ "no live owned dev server to stop"
    assert process_alive?(fixture.listener_pid)
    refute File.exists?(reused_receipt_path)
    refute File.exists?(Path.join(fixture.state_dir, "active"))

    stop_fixture(fixture)
  end

  test "status reports a stale ownership receipt for a dead owned pid" do
    fixture = server_fixture!(start?: false, cwd: File.cwd!())
    write_stale_receipt!(fixture, pid: 999_999)

    assert {output, code} = lifecycle("status", fixture)
    assert code != 0
    assert output =~ "stale ownership receipt"
    assert output =~ "999999"
    assert output =~ "no longer exists"
    assert output =~ "start or stop will clean it"
  end

  test "stop cleans a stale dead-pid receipt without touching other processes" do
    sentinel = server_fixture!(healthy?: false, cwd: temp_dir!("stale-sentinel"))
    fixture = server_fixture!(start?: false, cwd: File.cwd!())
    %{receipt_path: receipt_path} = write_stale_receipt!(fixture, pid: 999_999)

    assert {output, 0} = lifecycle("stop", fixture)
    assert output =~ "cleared stale ownership receipt"
    assert output =~ "no live owned dev server to stop"
    refute File.exists?(receipt_path)
    refute File.exists?(Path.join(fixture.state_dir, "active"))
    assert process_alive?(sentinel.listener_pid)

    stop_fixture(sentinel)
  end

  test "start recovers from a stale dead-pid receipt and then stops cleanly" do
    fixture = mix_server_fixture!()
    login_home = temp_dir!("stale-login-home")
    File.write!(Path.join(login_home, ".bash_profile"), "PATH=/usr/bin:/bin\nexport PATH\n")
    %{receipt_path: receipt_path, run_id: stale_run} = write_stale_receipt!(fixture, pid: 999_999)

    {output, code} =
      lifecycle("start", fixture, [
        {"HOME", login_home},
        {"PATH", "#{fixture.bin_dir}:#{System.fetch_env!("PATH")}"}
      ])

    assert code == 0, "lifecycle start failed: #{output}"
    assert output =~ "cleared stale ownership receipt"
    assert output =~ "owned dev server started"
    refute File.exists?(receipt_path)

    active_run = fixture.state_dir |> Path.join("active") |> File.read!() |> String.trim()
    refute active_run == stale_run

    assert {stop_output, 0} =
             lifecycle("stop", fixture, [
               {"PATH", "#{fixture.bin_dir}:#{System.fetch_env!("PATH")}"}
             ])

    assert stop_output =~ "owned dev server stopped"
    refute File.exists?(Path.join(fixture.state_dir, "active"))
  end

  test "start still refuses a stale receipt recorded by another checkout" do
    fixture = server_fixture!(start?: false, cwd: File.cwd!())
    write_stale_receipt!(fixture, pid: 999_999, cwd: temp_dir!("foreign-checkout"))

    assert {output, code} = lifecycle("start", fixture)
    assert code != 0
    assert output =~ "another checkout"
    assert File.exists?(Path.join(fixture.state_dir, "active"))
  end

  test "start records ownership and stop terminates only the revalidated owned listener" do
    fixture = server_fixture!(start?: false, healthy?: true, cwd: File.cwd!(), long?: true)
    unrelated = server_fixture!(healthy?: false, cwd: temp_dir!("sentinel"))

    assert {output, 0} = lifecycle("start", fixture)
    assert output =~ "owned dev server started"

    active_run = fixture.state_dir |> Path.join("active") |> File.read!() |> String.trim()
    receipt = File.read!(Path.join(fixture.state_dir, "#{active_run}.receipt"))
    assert receipt =~ "start_signature\t"
    assert receipt =~ "command\t"
    assert receipt =~ "cwd\t#{File.cwd!()}"
    assert receipt =~ "port\t#{fixture.port}"

    assert {output, 0} = lifecycle("stop", fixture)
    assert output =~ "owned dev server stopped"
    refute File.exists?(Path.join(fixture.state_dir, "active"))
    assert process_alive?(unrelated.listener_pid)

    stop_fixture(unrelated)
  end

  test "stop escalates a hung owned process after TERM" do
    fixture = server_fixture!(start?: false, healthy?: true, cwd: File.cwd!(), ignore_term?: true)

    assert {_output, 0} = lifecycle("start", fixture)
    assert {output, 0} = lifecycle("stop", fixture, [{"DEV_SERVER_TERM_ATTEMPTS", "2"}])
    assert output =~ "escalating to KILL"
  end

  test "stop succeeds when the owned process exits while KILL is delivered" do
    fixture = server_fixture!(start?: false, healthy?: true, cwd: File.cwd!(), ignore_term?: true)
    bash_env = Path.join(Path.dirname(fixture.log_path), "kill-race.bash")
    race_marker = Path.join(Path.dirname(fixture.log_path), "kill-race-observed")

    File.write!(bash_env, """
    kill() {
      if [ "${1:-}" = "-KILL" ] && [ ! -e "$DEV_SERVER_KILL_RACE_MARKER" ]; then
        : > "$DEV_SERVER_KILL_RACE_MARKER"
        builtin kill "$@" >/dev/null 2>&1 || true
        return 1
      fi

      builtin kill "$@"
    }
    """)

    assert {_output, 0} = lifecycle("start", fixture)

    assert {output, 0} =
             lifecycle("stop", fixture, [
               {"BASH_ENV", bash_env},
               {"DEV_SERVER_KILL_RACE_MARKER", race_marker},
               {"DEV_SERVER_TERM_ATTEMPTS", "2"}
             ])

    assert output =~ "escalating to KILL"
    assert output =~ "owned dev server stopped"
    assert File.exists?(race_marker)
  end

  test "start rejects malformed commands before creating ownership state" do
    fixture = server_fixture!(start?: false, healthy?: true, cwd: File.cwd!())
    fixture = %{fixture | command: "mix\nphx.server"}

    assert {output, code} = lifecycle("start", fixture)
    assert code != 0
    assert output =~ "invalid server command"
    refute File.exists?(Path.join(fixture.state_dir, "active"))
  end

  defp write_stale_receipt!(fixture, opts) do
    pid = Keyword.fetch!(opts, :pid)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    run_id = "feedfacefeedfacefeedface"
    File.mkdir_p!(fixture.state_dir)
    File.chmod!(fixture.state_dir, 0o700)
    receipt_path = Path.join(fixture.state_dir, "#{run_id}.receipt")

    File.write!(receipt_path, """
    version\t1
    state\trunning
    pid\t#{pid}
    start_signature\tTue Aug 11 14:51:05 2026
    command\tmix phx.server
    cwd\t#{cwd}
    port\t#{fixture.port}
    """)

    File.write!(Path.join(fixture.state_dir, "active"), "#{run_id}\n")
    %{receipt_path: receipt_path, run_id: run_id}
  end

  defp lifecycle(action, fixture, extra_env \\ []) do
    System.cmd(@script, [action],
      cd: File.cwd!(),
      env:
        [
          {"DEV_SERVER_PORT", Integer.to_string(fixture.port)},
          {"DEV_SERVER_STATE_DIR", fixture.state_dir},
          {"DEV_SERVER_LEGACY_PID", Path.join(fixture.state_dir, "legacy.pid")},
          {"DEV_SERVER_LOG", fixture.log_path},
          {"DEV_SERVER_CWD", File.cwd!()},
          {"DEV_SERVER_COMMAND", fixture.command},
          {"DEV_SERVER_HEALTH_URL", "http://127.0.0.1:#{fixture.port}/healthz"},
          {"DEV_SERVER_START_ATTEMPTS", "100"},
          {"DEV_SERVER_POLL_SECONDS", "0.02"}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp server_fixture!(opts) do
    port = unused_port!()
    directory = temp_dir!("server")
    state_dir = Path.join(directory, "state")
    log_path = Path.join(directory, "server.log")
    script = Path.join(directory, "fixture_server.py")
    healthy = if Keyword.get(opts, :healthy?, false), do: "true", else: "false"
    ignore_term = if Keyword.get(opts, :ignore_term?, false), do: "true", else: "false"
    padding = if Keyword.get(opts, :long?, false), do: String.duplicate("x", 600), else: "short"

    File.write!(script, """
    #!/usr/bin/python3
    import http.server, signal, socketserver, sys
    healthy = sys.argv[2] == "true"
    if sys.argv[3] == "true": signal.signal(signal.SIGTERM, signal.SIG_IGN)
    class Handler(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
        status = 200 if healthy and self.path == "/healthz" else 503
        body = b'{"status":"ok"}' if status == 200 else b'no'
        self.send_response(status); self.end_headers(); self.wfile.write(body)
      def log_message(self, *_args): pass
    with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), Handler) as server: server.serve_forever()
    """)

    File.chmod!(script, 0o700)

    command = "#{script} #{port} #{healthy} #{ignore_term} mix phx.server #{padding}"
    fixture = %{port: port, state_dir: state_dir, log_path: log_path, command: command}

    if Keyword.get(opts, :start?, true) do
      port_handle =
        Port.open({:spawn_executable, script}, [
          :binary,
          :exit_status,
          args: [Integer.to_string(port), healthy, ignore_term, "mix", "phx.server", padding],
          cd: Keyword.fetch!(opts, :cwd)
        ])

      {:os_pid, pid} = Port.info(port_handle, :os_pid)
      await_listener!(port)
      on_exit(fn -> stop_os_pid(pid) end)
      Map.merge(fixture, %{listener_pid: pid, port_handle: port_handle})
    else
      fixture
    end
  end

  defp mix_server_fixture! do
    port = unused_port!()
    directory = temp_dir!("makefile-command")
    bin_dir = Path.join(directory, "bin")
    state_dir = Path.join(directory, "state")
    log_path = Path.join(directory, "server.log")
    mix_path = Path.join(bin_dir, "mix")

    File.mkdir_p!(bin_dir)

    File.write!(mix_path, """
    #!/usr/bin/python3
    import http.server
    import os
    import sys

    if sys.argv[1:] != ["phx.server"]:
        raise SystemExit(2)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            status = 200 if self.path == "/healthz" else 404
            body = b'{"status":"ok"}' if status == 200 else b'not found'
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler) as server:
        server.serve_forever()
    """)

    File.chmod!(mix_path, 0o700)

    %{
      port: port,
      bin_dir: bin_dir,
      state_dir: state_dir,
      log_path: log_path,
      command: "PORT=#{port} mix phx.server"
    }
  end

  defp stop_fixture(%{listener_pid: pid, port_handle: port_handle}) do
    stop_os_pid(pid)
    Port.close(port_handle)
  catch
    :error, :badarg -> :ok
  end

  defp stop_fixture(_fixture), do: :ok

  defp process_alive?(pid) do
    {_output, code} = signal_os_pid(pid, "-0")

    code == 0
  end

  defp stop_os_pid(pid) do
    if process_alive?(pid) do
      _ = signal_os_pid(pid, "-TERM")
    end

    await_process_exit(pid, 100)
  end

  defp await_process_exit(_pid, 0), do: :ok

  defp await_process_exit(pid, attempts) do
    if process_alive?(pid) do
      Process.sleep(10)
      await_process_exit(pid, attempts - 1)
    else
      :ok
    end
  end

  defp signal_os_pid(pid, signal) do
    executable = System.find_executable("kill") || raise "missing kill executable"
    System.cmd(executable, [signal, Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp await_listener!(port, attempts \\ 100)
  defp await_listener!(_port, 0), do: flunk("listener did not start")

  defp await_listener!(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 20) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        Process.sleep(10)
        await_listener!(port, attempts - 1)
    end
  end

  defp unused_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp temp_dir!(label) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
