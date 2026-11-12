defmodule CodexPooler.SelfHostGenerateEnvTest do
  use CodexPooler.UnixIntegrationCase,
    async: false,
    tools: ~w(env openssl sh)

  @moduletag :tmp_dir

  test "explicit empty lowercase proxy variables disable uppercase fallbacks", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, ".env")

    assert {_output, 0} =
             System.cmd(
               "env",
               [
                 "http_proxy=",
                 "HTTP_PROXY=http://ignored-http.example:8080",
                 "https_proxy=",
                 "HTTPS_PROXY=http://ignored-https.example:8080",
                 "no_proxy=",
                 "NO_PROXY=ignored.example",
                 "sh",
                 "scripts/self-host/generate-env.sh",
                 target
               ],
               stderr_to_stdout: true
             )

    contents = File.read!(target)
    assert contents =~ "\nhttp_proxy=\n"
    assert contents =~ "\nhttps_proxy=\n"
    assert contents =~ "\nno_proxy=\n"
    refute contents =~ "ignored-http.example"
    refute contents =~ "ignored-https.example"
    refute contents =~ "ignored.example"
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
  end

  test "the secret-bearing file is owner-only from creation to publication", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, ".env")
    observations = Path.join(tmp_dir, "modes")
    bin = Path.join(tmp_dir, "bin")

    # The stand-in mv runs at publication, when the staged file holds every secret and the target
    # name is already claimed, so it sees the permissions other local users see for both.
    write_tool!(bin, "mv", """
    #!/bin/sh
    for path in "$@"; do
      if [ -e "$path" ]; then ls -ln "$path" | cut -c1-10 >> "$GENERATE_ENV_OBSERVATIONS"; fi
    done
    exec "$GENERATE_ENV_REAL_MV" "$@"
    """)

    assert {_output, 0} =
             System.cmd("sh", ["-c", "umask 022 && exec sh scripts/self-host/generate-env.sh \"$1\"", "sh", target],
               env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"GENERATE_ENV_REAL_MV", System.find_executable("mv")}, {"GENERATE_ENV_OBSERVATIONS", observations}],
               stderr_to_stdout: true
             )

    modes = observations |> File.read!() |> String.split("\n", trim: true)
    assert length(modes) == 2, "the stand-in mv did not see both the staged file and the claimed target: #{inspect(modes)}"
    assert Enum.all?(modes, &(&1 == "-rw-------")), "permissions at publication: #{inspect(modes)}"
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
    assert File.ls!(Path.dirname(target)) |> Enum.sort() == [".env", "bin", "modes"]
  end

  describe "secret generation failure" do
    for {failing_call, label} <- [{0, "database password"}, {1, "SECRET_KEY_BASE"}, {2, "TOTP key"}, {3, "upstream secret key"}] do
      @tag failing_call: failing_call
      test "a failed openssl call for the #{label} writes nothing and reports failure", %{tmp_dir: tmp_dir, failing_call: failing_call} do
        {output, exit_code, target} = generate_with_counting_openssl(tmp_dir, failing_call)

        assert exit_code != 0
        assert output =~ "openssl failed to generate a secret"
        refute output =~ "wrote"
        refute File.exists?(target)
        assert File.ls!(Path.dirname(target)) == []
      end
    end

    test "control: the same stand-in without a failure writes three complete keys", %{tmp_dir: tmp_dir} do
      {output, exit_code, target} = generate_with_counting_openssl(tmp_dir, -1)

      assert exit_code == 0
      assert output =~ "wrote"
      values = env_values(target)

      assert [64, 32, 32] == for(key <- ~w(SECRET_KEY_BASE CODEX_POOLER_TOTP_ENCRYPTION_KEY CODEX_POOLER_UPSTREAM_SECRET_KEY), do: values |> Map.fetch!(key) |> Base.decode64!() |> byte_size())
      assert values["POSTGRES_PASSWORD"] =~ ~r/\A[0-9a-f]{48}\z/
      assert File.ls!(Path.dirname(target)) == [".env"]
    end
  end

  describe "two invocations for one target" do
    test "the one that loses the race fails and leaves the winner's file untouched", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "out")
      File.mkdir_p!(out)
      target = Path.join(out, ".env")
      ready = Path.join(tmp_dir, "ready")
      release = Path.join(tmp_dir, "release")
      bin = Path.join(tmp_dir, "bin")
      on_exit(fn -> File.touch(release) end)

      # The held invocation has already passed its existence check when its first openssl call parks.
      write_tool!(bin, "openssl", """
      #!/bin/sh
      if [ "$GENERATE_ENV_HELD" = yes ] && [ "$*" = "rand -hex 24" ]; then
        : > "$GENERATE_ENV_READY"
        while [ ! -e "$GENERATE_ENV_RELEASE" ]; do sleep 0.02; done
      fi
      exec "$GENERATE_ENV_REAL_OPENSSL" "$@"
      """)

      env = [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"GENERATE_ENV_REAL_OPENSSL", System.find_executable("openssl")}, {"GENERATE_ENV_READY", ready}, {"GENERATE_ENV_RELEASE", release}]
      run = fn held -> System.cmd("sh", ["scripts/self-host/generate-env.sh", target], env: [{"GENERATE_ENV_HELD", held} | env], stderr_to_stdout: true) end

      held = Task.async(fn -> run.("yes") end)
      assert :ok = await_file(ready, 250)
      refute File.exists?(target)

      assert {_output, 0} = run.("no")
      winner = File.read!(target)

      assert {sequential_output, sequential_exit} = run.("no")
      assert sequential_exit != 0
      assert sequential_output =~ "already exists"

      File.touch!(release)
      assert {late_output, late_exit} = Task.await(held, 5_000)

      assert late_exit != 0
      assert late_output =~ "already exists"
      refute late_output =~ "wrote"
      assert File.read!(target) == winner
      assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
      assert File.ls!(out) == [".env"]
    end

    test "a dangling symbolic link at the target is refused and not followed", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, ".env")
      elsewhere = Path.join(tmp_dir, "elsewhere")
      File.ln_s!(elsewhere, target)

      assert {output, exit_code} = System.cmd("sh", ["scripts/self-host/generate-env.sh", target], stderr_to_stdout: true)
      assert exit_code != 0
      assert output =~ "already exists"
      refute File.exists?(elsewhere)
    end
  end

  # Fails the Nth openssl call (0-based; -1 never) and answers the others with fixed synthetic values.
  defp generate_with_counting_openssl(tmp_dir, failing_call) do
    out = Path.join(tmp_dir, "out")
    File.mkdir_p!(out)
    target = Path.join(out, ".env")
    bin = Path.join(tmp_dir, "bin")
    counter = Path.join(tmp_dir, "calls")
    File.write!(counter, "")

    write_tool!(bin, "openssl", """
    #!/bin/sh
    call=$(wc -l < "$GENERATE_ENV_CALLS" | tr -d ' ')
    echo x >> "$GENERATE_ENV_CALLS"
    if [ "$call" = "$GENERATE_ENV_FAILING_CALL" ]; then exit 23; fi
    case "$*" in
      "rand -hex 24") echo #{String.duplicate("ab", 24)} ;;
      "rand -base64 64") echo #{Base.encode64(String.duplicate("S", 64))} ;;
      "rand -base64 32") echo #{Base.encode64(String.duplicate("K", 32))} ;;
      *) exit 64 ;;
    esac
    """)

    env = [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"GENERATE_ENV_CALLS", counter}, {"GENERATE_ENV_FAILING_CALL", Integer.to_string(failing_call)}]
    {output, exit_code} = System.cmd("sh", ["scripts/self-host/generate-env.sh", target], env: env, stderr_to_stdout: true)
    {output, exit_code, target}
  end

  defp write_tool!(bin, name, script) do
    File.mkdir_p!(bin)
    path = Path.join(bin, name)
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp env_values(target) do
    for line <- target |> File.read!() |> String.split("\n", trim: true), [key, value] <- [String.split(line, "=", parts: 2)], into: %{}, do: {key, value}
  end

  defp await_file(_path, 0), do: :timeout

  defp await_file(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      await_file(path, attempts - 1)
    end
  end
end
