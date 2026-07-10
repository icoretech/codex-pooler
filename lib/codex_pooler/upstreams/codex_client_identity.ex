defmodule CodexPooler.Upstreams.CodexClientIdentity do
  @moduledoc """
  Trusted Codex client identity synthesized for upstream requests.
  """

  @originator "codex_cli_rs"
  @automatic_user_agent_setting "auto"
  @legacy_automatic_user_agent_settings ["codex_cli_rs/0.0.0"]
  # renovate: datasource=github-releases depName=openai/codex extractVersion=^rust-v(?<version>.+)$
  @default_client_version "0.144.1"

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

  @spec automatic_user_agent_setting() :: String.t()
  def automatic_user_agent_setting, do: @automatic_user_agent_setting

  @spec user_agent() :: String.t()
  def user_agent, do: user_agent(@automatic_user_agent_setting)

  @spec user_agent(String.t() | nil) :: String.t()
  def user_agent(setting), do: resolve_user_agent(setting, version())

  @spec headers() :: [header()]
  def headers, do: headers(@automatic_user_agent_setting)

  @spec headers(String.t() | nil) :: [header()]
  def headers(user_agent_setting) do
    version = version()

    [
      {"user-agent", resolve_user_agent(user_agent_setting, version)},
      {"originator", @originator},
      {"version", version}
    ]
  end

  defp resolve_user_agent(nil, version), do: versioned_user_agent(version)

  defp resolve_user_agent(setting, version) when is_binary(setting) do
    setting = String.trim(setting)

    if setting == "" or
         setting in [@automatic_user_agent_setting | @legacy_automatic_user_agent_settings] do
      versioned_user_agent(version)
    else
      setting
    end
  end

  defp versioned_user_agent(version), do: "#{@originator}/#{version}"
end
