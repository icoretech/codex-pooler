defmodule CodexPooler.Upstreams.CodexClientIdentity do
  @moduledoc """
  Trusted Codex client identity synthesized for upstream requests.
  """

  @originator "codex_cli_rs"
  @default_client_version Application.compile_env(:codex_pooler, __MODULE__)
                          |> Keyword.fetch!(:default_client_version)
  @version_pattern ~r/\A\d+\.\d+\.\d+\z/

  @type header :: {String.t(), String.t()}

  @spec version() :: String.t()
  def version do
    case configured_version() do
      version when is_binary(version) ->
        if Regex.match?(@version_pattern, version), do: version, else: @default_client_version

      _invalid ->
        @default_client_version
    end
  end

  @spec originator() :: String.t()
  def originator, do: @originator

  @spec user_agent() :: String.t()
  def user_agent, do: versioned_user_agent(version())

  @spec headers() :: [header()]
  def headers do
    version = version()

    [
      {"user-agent", versioned_user_agent(version)},
      {"originator", @originator},
      {"version", version}
    ]
  end

  defp versioned_user_agent(version), do: "#{@originator}/#{version}"

  defp configured_version do
    case Application.get_env(:codex_pooler, CodexPooler.Catalog, []) do
      config when is_list(config) ->
        Enum.find_value(config, fn
          {:codex_client_version, version} -> version
          _entry -> nil
        end)

      _invalid_config ->
        nil
    end
  end
end
