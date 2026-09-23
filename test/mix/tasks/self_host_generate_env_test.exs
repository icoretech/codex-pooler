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

  test "the secret-bearing file is owner-only while the secrets are being written", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, ".env")
    observations = Path.join(tmp_dir, "modes")
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    # The stand-in openssl runs while the heredoc holding SECRET_KEY_BASE and the encryption keys
    # is written to the already-created target, so it sees the permissions other local users see then.
    File.write!(Path.join(bin, "openssl"), """
    #!/bin/sh
    if [ -e "$GENERATE_ENV_TARGET" ]; then ls -ln "$GENERATE_ENV_TARGET" | cut -c1-10 >> "$GENERATE_ENV_OBSERVATIONS"; fi
    echo c2VjcmV0
    """)

    File.chmod!(Path.join(bin, "openssl"), 0o755)

    assert {_output, 0} =
             System.cmd("sh", ["-c", "umask 022 && exec sh scripts/self-host/generate-env.sh \"$1\"", "sh", target],
               env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"GENERATE_ENV_TARGET", target}, {"GENERATE_ENV_OBSERVATIONS", observations}],
               stderr_to_stdout: true
             )

    modes = observations |> File.read!() |> String.split("\n", trim: true)
    assert modes != [], "the stand-in openssl never saw the target while secrets were written"
    assert Enum.all?(modes, &(&1 == "-rw-------")), "target permissions while secrets were written: #{inspect(modes)}"
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
  end
end
