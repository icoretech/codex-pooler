defmodule CodexPooler.Gateway.Payloads.TransportEnvelope do
  @moduledoc """
  Shared upstream HTTP transport envelope helpers.
  """

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @codex_residency_header "x-openai-internal-codex-residency"
  # Provider session headers the Codex client sends on every backend HTTP
  # request. The ChatGPT backend uses `session-id` for sticky routing, so a
  # full-history HTTP turn that omits it lands on an arbitrary replica and
  # misses the prompt cache the previous turn warmed. The values are bounded
  # opaque identifiers (the client's thread id, also carried in the body as
  # `prompt_cache_key` and `client_metadata`).
  @provider_session_header_names ["session-id", "thread-id", "x-client-request-id"]
  @provider_session_header_max_bytes 128

  # Fixed namespace for the `session-id` the Pooler synthesizes on public
  # `/v1` routes from the client's `prompt_cache_key`. OpenAI-compatible
  # clients never send the provider's session headers, so the derived id is
  # what keeps consecutive HTTP turns of one conversation on the replica that
  # holds the warm prompt cache. It is UUID v5 of the RFC 4122 URL namespace
  # (`6ba7b811-9dad-11d1-80b4-00c04fd430c8`) over
  # `https://github.com/icoretech/codex-pooler/v1/session-id`. Never change
  # it: every derived id would change and every warm cache would be lost.
  @prompt_cache_session_namespace "0aac30b0-0311-52bd-8fb7-258f9c6f0278"
  @prompt_cache_session_namespace_bytes Base.decode16!(
                                          String.replace(
                                            @prompt_cache_session_namespace,
                                            "-",
                                            ""
                                          ),
                                          case: :lower
                                        )
  @prompt_cache_session_key_max_bytes 512

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

  # `conn_opts` and `conn_max_idle_time` are Finch pool options, so Req runs
  # these requests on its own Finch instance keyed by them (one HTTP/1 pool per
  # origin, shared by every account) rather than on the global `Req.Finch`.
  # Keeping them per request keeps the connect timeout and the connection idle
  # bound instance settings that apply without a restart; a Finch started at
  # boot would freeze them. No `connect_options` are passed, so Req's default
  # `protocols: [:http1]` holds and upstream HTTP never negotiates HTTP/2.
  # `conn_max_idle_time` exists only for Finch HTTP/1 pools; an HTTP/2 pool
  # would need `http2: [ping_interval:]` or `max_connection_age` instead. The
  # idle bound is explained at `OperationalSettings`, whose
  # `upstream_http_pool_options/0` also bounds the non-gateway provider Req
  # callers; they land on a different Finch instance because they keep their
  # own connect timeout. The bound is read from the current settings snapshot
  # here rather than carried in `TimeoutConfig`: that struct travels inside
  # versioned websocket owner requests whose field set is validated exactly
  # across nodes, and an owner never opens a Finch HTTP connection.
  # `pool_max_idle_time` stays unset: stopping an idle per-origin pool can race
  # a request that has just looked it up, and stale connections are already
  # dropped at checkout.
  @spec req_timeout_options(TimeoutConfig.t() | timeout_settings()) :: keyword()
  def req_timeout_options(timeouts) do
    [
      receive_timeout: timeouts.receive_timeout_ms,
      finch:
        [
          pool_timeout: timeouts.pool_timeout_ms,
          conn_opts: [transport_opts: [timeout: timeouts.connect_timeout_ms]]
        ] ++ OperationalSettings.upstream_http_pool_options()
    ]
  end

  @spec provider_session_header_names() :: [String.t()]
  def provider_session_header_names, do: @provider_session_header_names

  @doc """
  Whether a provider session header value may be forwarded upstream: a
  non-empty ASCII identifier of at most #{@provider_session_header_max_bytes} bytes.
  """
  @spec provider_session_header_value?(term()) :: boolean()
  def provider_session_header_value?(value) when is_binary(value) do
    byte_size(value) in 1..@provider_session_header_max_bytes and
      Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, value)
  end

  def provider_session_header_value?(_value), do: false

  @doc """
  The fixed namespace UUID behind `prompt_cache_session_id/2`.
  """
  @spec prompt_cache_session_namespace() :: String.t()
  def prompt_cache_session_namespace, do: @prompt_cache_session_namespace

  @doc """
  The provider `session-id` synthesized for a public `/v1` request from its
  raw `prompt_cache_key`, scoped to the authenticated tenant: RFC 4122 UUID v5
  over the fixed Pooler namespace and the name

      <pool id byte length>:<pool id>,<api key id byte length>:<api key id>,<raw key>

  The two ids are netstring-encoded (decimal byte length, `:`, bytes, `,`) and
  the raw key takes the rest of the name, so the name parses back into exactly
  one `(pool id, api key id, key)` triple and no two triples share a name,
  whatever bytes the ids or the key contain. The same tenant and key yield the
  same value on every node and across restarts without persistence, while two
  API keys or two Pools that send the same key never share a provider session.
  The model stays out of the name so a model switch inside one conversation
  keeps its session.

  `scope` must be the trusted `%{pool_id: _, api_key_id: _}` captured from the
  authenticated runtime principal. Returns `nil` when either id is missing or
  not a non-empty binary (fail closed: there is no unscoped derivation), and
  for any key that is not a non-empty binary of at most
  #{@prompt_cache_session_key_max_bytes} bytes. The value derives from a
  client-chosen key and must be treated like the key itself: it belongs only
  in the upstream request header, never in logs, request metadata, or debug
  summaries.
  """
  @spec prompt_cache_session_id(term(), term()) :: String.t() | nil
  def prompt_cache_session_id(%{pool_id: pool_id, api_key_id: api_key_id}, key)
      when is_binary(pool_id) and byte_size(pool_id) > 0 and is_binary(api_key_id) and
             byte_size(api_key_id) > 0 and is_binary(key) and
             byte_size(key) in 1..@prompt_cache_session_key_max_bytes do
    name = [netstring(pool_id), netstring(api_key_id), key]

    <<time_low::32, time_mid::16, time_hi::16, clock_seq::16, node::48, _rest::binary>> =
      :crypto.hash(:sha, [@prompt_cache_session_namespace_bytes, name])

    time_hi = Bitwise.bor(Bitwise.band(time_hi, 0x0FFF), 0x5000)
    clock_seq = Bitwise.bor(Bitwise.band(clock_seq, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low,
      time_mid,
      time_hi,
      clock_seq,
      node
    ])
    |> IO.iodata_to_binary()
  end

  def prompt_cache_session_id(_scope, _key), do: nil

  defp netstring(value), do: [Integer.to_string(byte_size(value)), ":", value, ","]

  @spec headers(UpstreamIdentity.t(), String.t(), [{String.t(), String.t()}], keyword()) :: [
          {String.t(), String.t()}
        ]
  def headers(identity, token, headers, opts \\ []) do
    token = String.trim(token)

    [
      {"authorization", "Bearer #{token}"}
    ]
    |> Kernel.++(codex_identity_headers(opts))
    |> Kernel.++(codex_account_headers(identity))
    |> Kernel.++(headers)
    |> Kernel.++(safe_forwarded_headers(Keyword.get(opts, :forwarded_headers, [])))
    |> Kernel.++(codex_residency_headers(token))
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

        cond do
          String.starts_with?(name, "x-openai-") or String.starts_with?(name, "x-codex-") ->
            [{name, value}]

          name in @provider_session_header_names and provider_session_header_value?(value) ->
            [{name, value}]

          true ->
            []
        end

      _other ->
        []
    end)
    |> Enum.reject(fn {name, _value} ->
      name in ["authorization", "accept", "content-type", @codex_residency_header]
    end)
  end

  defp safe_forwarded_headers(_headers), do: []

  defp codex_residency_headers(token) do
    case CodexAuth.compute_residency(token) do
      residency when is_binary(residency) -> [{@codex_residency_header, residency}]
      nil -> []
    end
  end
end
