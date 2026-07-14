defmodule CodexPooler.Upstreams.CodexClientIdentity do
  @moduledoc """
  Trusted Codex client identity synthesized for upstream requests.
  """

  @originator "codex_cli_rs"
  # renovate: datasource=github-releases depName=openai/codex extractVersion=^rust-v(?<version>.+)$
  @default_client_version "0.144.4"

  @type header :: {String.t(), String.t()}

  @spec version() :: String.t()
  def version do
    :codex_pooler
    |> Application.get_env(CodexPooler.Catalog, [])
    |> Keyword.get(:codex_client_version, @default_client_version)
    |> to_string()
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
end
