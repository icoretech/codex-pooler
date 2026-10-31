defmodule CodexPooler.I18nQualityTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @tag :tmp_dir
  @tag timeout: 120_000
  test "quality runs real extraction after strict compilation without consolidated protocols and rejects source drift", %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    aliases = Mix.Project.config()[:aliases]
    extraction_step = Enum.find(aliases[:quality], &String.ends_with?(&1, "quality.i18n"))
    assert Enum.find_index(aliases[:quality], &(&1 == "quality.xref")) < Enum.find_index(aliases[:quality], &(&1 == extraction_step))
    assert hd(aliases[:"quality.xref"]) == "compile --warnings-as-errors"

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "priv/gettext"))
    File.write!(Path.join(tmp_dir, "mix.exs"), fixture_project(extraction_step))
    source = Path.join(tmp_dir, "lib/sample.ex")
    File.write!(source, fixture_source())

    assert {_initial_output, 0} = run_mix(tmp_dir, ["gettext.extract"])
    pot_path = Path.join(tmp_dir, "priv/gettext/default.pot")
    assert File.read!(pot_path) =~ ~s(msgid "Existing message")

    {output, exit_code} = run_mix(tmp_dir, ["quality"])
    assert exit_code == 0, output
    refute output =~ "protocol has already been consolidated"

    File.write!(source, fixture_source() <> "\ndefmodule Sample.Extra do\n  use Gettext, backend: Sample.Gettext\n  def label, do: gettext(\"New message\")\nend\n")
    {output, exit_code} = run_mix(tmp_dir, ["quality"])
    assert exit_code != 0
    assert output =~ "mix gettext.extract failed due to --check-up-to-date"
    refute output =~ "protocol has already been consolidated"
    refute File.read!(pot_path) =~ ~s(msgid "New message")
  end

  defp fixture_project(extraction_step) do
    gettext = Path.join(@root, "deps/gettext")
    expo = Path.join(@root, "deps/expo")

    """
    defmodule Sample.MixProject do
      use Mix.Project
      def project do
        [app: :sample, version: "0.1.0", deps: [
          {:gettext, path: #{inspect(gettext)}},
          {:expo, path: #{inspect(expo)}, override: true}
        ], aliases: [
          quality: ["compile --warnings-as-errors", #{inspect(extraction_step)}],
          "quality.i18n": ["gettext.extract --check-up-to-date"]
        ]]
      end
    end
    """
  end

  defp fixture_source do
    """
    defmodule Sample.Gettext do
      use Gettext.Backend, otp_app: :sample
    end

    defmodule Sample.Value do
      @derive {Inspect, only: [:id]}
      @derive JSON.Encoder
      defstruct [:id]
    end

    defmodule Sample.Page do
      use Gettext, backend: Sample.Gettext
      def label, do: gettext("Existing message")
    end
    """
  end

  defp run_mix(directory, args) do
    env = [{"ERL_FLAGS", "+S 2:2"}, {"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
    System.cmd(System.find_executable("mix"), args, cd: directory, env: env, stderr_to_stdout: true)
  end
end
