defmodule CodexPooler.Gateway.Payloads.TransportEnvelope do
  @moduledoc """
  Shared upstream HTTP transport envelope helpers.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type timeout_settings :: %{
          required(:connect_timeout_ms) => non_neg_integer(),
          required(:pool_timeout_ms) => non_neg_integer(),
          required(:receive_timeout_ms) => non_neg_integer()
        }

  @spec timeout_config(RequestOptions.t(), TimeoutConfig.t() | timeout_settings()) ::
          TimeoutConfig.t()
  def timeout_config(%RequestOptions{timeout_config: timeout_config}, defaults) do
    %TimeoutConfig{
      receive_timeout_ms: timeout_config.receive_timeout_ms || defaults.receive_timeout_ms,
      pool_timeout_ms: timeout_config.pool_timeout_ms || defaults.pool_timeout_ms,
      connect_timeout_ms: timeout_config.connect_timeout_ms || defaults.connect_timeout_ms
    }
  end

  @spec req_timeout_options(TimeoutConfig.t() | timeout_settings()) :: keyword()
  def req_timeout_options(timeouts) do
    [
      receive_timeout: timeouts.receive_timeout_ms,
      pool_timeout: timeouts.pool_timeout_ms,
      connect_options: [timeout: timeouts.connect_timeout_ms]
    ]
  end

  @spec headers(UpstreamIdentity.t(), String.t(), [{String.t(), String.t()}], keyword()) :: [
          {String.t(), String.t()}
        ]
  def headers(identity, token, headers, opts \\ []) do
    [
      {"authorization", "Bearer #{String.trim(token)}"}
    ]
    |> Kernel.++(codex_identity_headers(opts))
    |> Kernel.++(codex_account_headers(identity))
    |> Kernel.++(headers)
    |> Kernel.++(safe_forwarded_headers(Keyword.get(opts, :forwarded_headers, [])))
  end

  defp codex_identity_headers(opts) do
    if Keyword.get(opts, :include_codex_identity?, false) do
      CodexClientIdentity.headers()
    else
      []
    end
  end

  defp codex_account_headers(%UpstreamIdentity{chatgpt_account_id: account_id})
       when is_binary(account_id) do
    account_id = String.trim(account_id)

    if account_id == "" or String.starts_with?(account_id, "email_") or
         String.starts_with?(account_id, "local_") do
      []
    else
      [{"chatgpt-account-id", account_id}]
    end
  end

  defp codex_account_headers(_identity), do: []

  defp safe_forwarded_headers(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if String.starts_with?(name, "x-openai-") or String.starts_with?(name, "x-codex-") do
          [{name, value}]
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.reject(fn {name, _value} -> name in ["authorization", "accept", "content-type"] end)
  end

  defp safe_forwarded_headers(_headers), do: []
end
