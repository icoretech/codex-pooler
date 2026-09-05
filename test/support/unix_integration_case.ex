defmodule CodexPooler.UnixIntegrationCase do
  @moduledoc """
  Prerequisites for the explicitly selected Unix shell integration profile.
  """

  use ExUnit.CaseTemplate

  using options do
    quote do
      @moduletag :unix_integration
      @moduletag unix_tools: unquote(Keyword.get(options, :tools, []))
      @moduletag docker_compose: unquote(Keyword.get(options, :docker_compose, false))
    end
  end

  setup_all tags do
    assert match?({:unix, _}, :os.type()),
           "unix_integration requires Unix shell tools; run this explicit profile in WSL2, Linux, or macOS"

    missing = Enum.reject(["/bin/bash" | tags.unix_tools], &System.find_executable/1)

    assert missing == [],
           "unix_integration is missing required tools: #{Enum.join(missing, ", ")}; install them before running this explicit profile"

    if tags.docker_compose do
      {_output, code} = System.cmd("docker", ["compose", "version"], stderr_to_stdout: true)

      assert code == 0,
             "unix_integration requires the Docker Compose CLI plugin; install it before running this explicit profile (no Docker daemon is needed)"
    end

    :ok
  end
end
