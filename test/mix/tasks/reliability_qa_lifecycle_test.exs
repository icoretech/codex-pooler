defmodule CodexPooler.MixTasks.ReliabilityQaLifecycleTest do
  use ExUnit.Case, async: false

  @wrapper Path.expand("../../../dev_support/bin/reliability-qa-lifecycle", __DIR__)
  @lifecycle Path.expand("../../../dev_support/bin/dev-server-lifecycle", __DIR__)

  test "help describes the explicit lifecycle protocol without mutation" do
    {output, code} = System.cmd(@wrapper, ["--help"], stderr_to_stdout: true)

    assert code == 0
    assert output =~ "QA_READY"
    assert output =~ "QA_COMPLETE"
    assert output =~ "QA_ABORT"
  end

  test "invalid root fails before creating runtime state" do
    root =
      Path.join(
        System.tmp_dir!(),
        "missing-reliability-root-#{System.unique_integer([:positive])}"
      )

    {output, code} =
      System.cmd(@wrapper, ["--root", root, "--run-id", "a203b8f15e6d4901invalid"],
        stderr_to_stdout: true
      )

    assert code != 0
    assert output =~ "invalid Pooler root"
    refute File.exists?(root)
  end

  test "status reports a clean stopped state without stop-refusal wording" do
    state_dir = temp_dir!("stopped-state")

    {output, code} =
      System.cmd(@lifecycle, ["status"],
        cd: File.cwd!(),
        env: [
          {"DEV_SERVER_PORT", "44123"},
          {"DEV_SERVER_STATE_DIR", state_dir},
          {"DEV_SERVER_LEGACY_PID", Path.join(state_dir, "legacy.pid")},
          {"DEV_SERVER_CWD", File.cwd!()}
        ],
        stderr_to_stdout: true
      )

    assert code == 0
    assert output =~ "dev-server: stopped"
    refute output =~ "refusing stop"
  end

  test "QA_COMPLETE returns a managed cleanup failure and retains runtime evidence" do
    fixture = wrapper_fixture!(23, 0)

    {output, code} = run_wrapper(fixture, "QA_COMPLETE")

    assert code == 23, output
    assert output =~ "QA_READY"
    assert output =~ "\"seed_profile\":\"full\""
    assert output =~ "\"seed_source_sha256\":\""
    refute output =~ "synthetic-expiry-"
    assert File.dir?(fixture.runtime_root)
    assert File.exists?(Path.join(fixture.runtime_root, "secret.fixture"))
    refute File.exists?(fixture.compose_down_marker)
  end

  test "the 20 minute cap starts before preparation rather than after QA_READY" do
    fixture = wrapper_fixture!(0, 3)

    {output, code} =
      run_wrapper(fixture, "QA_COMPLETE", [{"RELIABILITY_QA_TIMEOUT_SECONDS", "1"}])

    assert code == 124, output
    refute output =~ "QA_READY"
    assert File.exists?(fixture.compose_down_marker)
  end

  test "owned compose overrides replace inherited wildcard database ports with loopback" do
    fixture = wrapper_fixture!(23, 0)
    {_output, 23} = run_wrapper(fixture, "QA_COMPLETE")
    base = Path.join(fixture.root, "base-compose.yml")

    File.write!(base, """
    services:
      db:
        image: postgres:18
        ports:
          - "45488:5432"
    """)

    {output, code} =
      System.cmd(
        "docker",
        [
          "compose",
          "-f",
          base,
          "-f",
          Path.join(fixture.runtime_root, "compose.override.yml"),
          "config",
          "--format",
          "json"
        ],
        stderr_to_stdout: true
      )

    assert code == 0, output

    assert [%{"host_ip" => "127.0.0.1", "published" => "45488", "target" => 5432}] =
             Jason.decode!(output)["services"]["db"]["ports"]
  end

  defp temp_dir!(label) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp wrapper_fixture!(stop_exit, prepare_sleep) do
    root = temp_dir!("reliability-wrapper")
    bin = Path.join(root, "bin")
    build = Path.join(root, "build")
    runtime_root = Path.join([root, "tmp", "reliability-qa", "a203b8f15e6d4901fixture"])
    compose_down_marker = Path.join(root, "compose-down")
    File.mkdir_p!(bin)
    File.mkdir_p!(build)
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "dev_support/bin"))
    File.mkdir_p!(Path.join(root, "dev_support/codex_pooler/dev/seeds"))
    File.write!(Path.join(root, "mix.exs"), "defmodule Fixture.MixProject do\nend\n")
    File.write!(Path.join(root, "mix.lock"), "%{}\n")
    File.write!(Path.join(root, "mise.toml"), "\n")
    File.write!(Path.join(root, ".gitignore"), "tmp/\nbuild/\n")
    File.write!(Path.join(root, "docker-compose.dev.yml"), "services: {}\n")
    File.write!(Path.join(root, "Makefile"), "dev-prepare:\n\t@true\n")
    File.write!(Path.join(root, "config/dev.exs"), "import Config\n")
    File.write!(Path.join(root, "lib/fixture.ex"), "defmodule Fixture do\nend\n")

    File.write!(
      Path.join(root, "dev_support/codex_pooler/dev/seeds/full.ex"),
      "defmodule Fixture.Seeds.Full do\nend\n"
    )

    File.cp!(@wrapper, Path.join(root, "dev_support/bin/reliability-qa-lifecycle"))

    write_executable!(
      Path.join(root, "dev_support/bin/dev-server-lifecycle"),
      """
      #!/bin/bash
      set -euo pipefail
      case "$1" in
        start)
          mkdir -p "$DEV_SERVER_STATE_DIR"
          printf 'fixturefixturefixturefix\n' > "$DEV_SERVER_STATE_DIR/active"
          printf 'version\t1\nstate\trunning\npid\t123\nstart_signature\tfixture-start\ncommand\tmix phx.server\ncwd\t%s\nport\t%s\n' "$DEV_SERVER_CWD" "$DEV_SERVER_PORT" > "$DEV_SERVER_STATE_DIR/fixturefixturefixturefix.receipt"
          printf secret > "$(dirname "$DEV_SERVER_STATE_DIR")/secret.fixture"
          ;;
        stop) exit #{stop_exit} ;;
        status) exit 0 ;;
      esac
      """
    )

    write_executable!(
      Path.join(bin, "docker"),
      """
      #!/bin/bash
      if [[ " $* " == *" ps "* || " $* " == *" volume ls "* ]]; then exit 0; fi
      if [[ " $* " == *" down "* ]]; then : > "#{compose_down_marker}"; fi
      exit 0
      """
    )

    write_executable!(Path.join(bin, "lsof"), "#!/bin/bash\nexit 1\n")
    write_executable!(Path.join(bin, "curl"), "#!/bin/bash\nexit 0\n")

    write_executable!(
      Path.join(bin, "mise"),
      """
      #!/bin/bash
      set -euo pipefail
      shift 2
      if [[ " $* " == *" make "* ]]; then
        sleep #{prepare_sleep}
        mkdir -p "$MIX_BUILD_PATH/lib/codex_pooler/ebin"
        printf beam > "$MIX_BUILD_PATH/lib/codex_pooler/ebin/Elixir.Fixture.beam"
        exit 0
      fi
      if [[ " $* " == *" mix run "* ]]; then printf 'CATALOG_COUNT=1\n'; fi
      exit 0
      """
    )

    {_output, 0} = System.cmd("git", ["init", "-q"], cd: root)
    {_output, 0} = System.cmd("git", ["add", "."], cd: root)

    {_output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.com",
          "commit",
          "-qm",
          "fixture"
        ],
        cd: root
      )

    File.chmod!(Path.join(root, "dev_support/bin/reliability-qa-lifecycle"), 0o700)

    %{
      root: root,
      bin: bin,
      build: build,
      runtime_root: runtime_root,
      compose_down_marker: compose_down_marker
    }
  end

  defp run_wrapper(fixture, input, extra_env \\ []) do
    System.cmd(
      Path.join(fixture.root, "dev_support/bin/reliability-qa-lifecycle"),
      ["--root", fixture.root, "--run-id", "a203b8f15e6d4901fixture", "--port", "44188"],
      cd: fixture.root,
      env:
        [
          {"PATH", "#{fixture.bin}:#{System.fetch_env!("PATH")}"},
          {"RELIABILITY_QA_POSTGRES_PORT", "45488"},
          {"RELIABILITY_QA_MIX_BUILD_PATH", fixture.build},
          {"RELIABILITY_QA_COMMAND", input}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o700)
  end
end
