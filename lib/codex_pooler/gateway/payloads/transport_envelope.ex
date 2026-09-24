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

  # Per-request client metadata headers the Codex client stamps on its native
  # HTTP Responses and compact calls (openai/codex main c11ed24c2:
  # core/src/responses_metadata.rs `compatibility_headers`, core/src/client.rs
  # `build_responses_compatibility_headers` and `build_subagent_headers`,
  # ext/guardian-v2 sync reviewer and classifier sampler, rollout-trace
  # `add_request_headers`). `x-codex-installation-id` is deliberately absent:
  # the client sends it only as a websocket frame `client_metadata` key, never
  # as a request header (findings#240). This is the one closed allowlist for
  # every upstream envelope; `UpstreamDispatch` gates it by endpoint and the
  # files bridge relies on `headers/4` applying it.
  @forwarded_metadata_header_names [
    "x-codex-turn-metadata",
    "x-codex-window-id",
    "x-codex-parent-thread-id",
    "x-codex-turn-state",
    "x-openai-subagent",
    "x-openai-memgen-request",
    "x-codex-guardian",
    "x-codex-inference-call-id"
  ]
  # Value bounds for the flags above. A memory-consolidation session sends
  # exactly `true`; guardian review and classifier turns send one of a closed
  # vocabulary; the rollout-trace call id is a client-generated UUID string, so
  # any ASCII identifier within the provider session length is accepted.
  # Anything else is dropped rather than fingerprinted: these values travel to
  # the provider and are never persisted, so a fingerprint would only send the
  # provider garbage.
  @memgen_request_header_name "x-openai-memgen-request"
  @memgen_request_header_value "true"
  @guardian_header_name "x-codex-guardian"
  @guardian_header_values ["reviewer", "classifier"]
  @inference_call_id_header_name "x-codex-inference-call-id"
  @inference_call_id_max_bytes 128
  @inference_call_id_pattern ~r/\A[A-Za-z0-9_.:-]+\z/
  @turn_metadata_header_name "x-codex-turn-metadata"

  # Fixed namespace for the `session-id` the Pooler synthesizes from the
  # client's `prompt_cache_key` on public `/v1` routes, and on native
  # Codex-backend HTTP routes when the client sent no usable `session-id`.
  # OpenAI-compatible clients never send the provider's session headers, so
  # the derived id is what keeps consecutive HTTP turns of one conversation on
  # the replica that holds the warm prompt cache. It is UUID v5 of the RFC 4122 URL namespace
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

  # Fixed namespace for the `session-id` the Pooler synthesizes on native
  # Codex-backend HTTP routes from the accepted local continuity alias
  # (`session_id`, `x-session-id` and the others) when the request carries
  # neither a usable client `session-id` nor a `prompt_cache_key`. A distinct
  # namespace, so an alias and a `prompt_cache_key` with the same text never
  # yield the same id. UUID v5 of the RFC 4122 URL namespace over
  # `https://github.com/icoretech/codex-pooler/backend-api/continuity-alias/session-id`.
  # Never change it, for the same reason as the one above.
  @continuity_alias_session_namespace "60a80f24-3dd3-5aeb-be77-26ea7c41d36f"
  @continuity_alias_session_namespace_bytes Base.decode16!(
                                              String.replace(@continuity_alias_session_namespace, "-", ""),
                                              case: :lower
                                            )

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
  # idle bound is explained at `CodexPooler.Platform.OutboundHTTP`, which also
  # bounds every non-gateway outbound Req caller; those land on a different
  # Finch instance because they keep their own connect timeout. The bound is
  # read from the current settings snapshot
  # here rather than carried in `TimeoutConfig`: that struct travels inside
  # versioned websocket owner requests whose field set is validated exactly
  # across nodes, and an owner never opens a Finch HTTP connection.
  # `pool_max_idle_time` stays unset: stopping an idle per-origin pool can race
  # a request that has just looked it up, and stale connections are already
  # dropped at checkout.
  @spec req_timeout_options(TimeoutConfig.t() | timeout_settings(), String.t() | nil) :: keyword()
  def req_timeout_options(timeouts, url \\ nil) do
    pool_options =
      if is_binary(url) do
        OperationalSettings.upstream_http_pool_options(url,
          transport_opts: [timeout: timeouts.connect_timeout_ms]
        )
      else
        OperationalSettings.upstream_http_pool_options(transport_opts: [timeout: timeouts.connect_timeout_ms])
      end

    [
      receive_timeout: timeouts.receive_timeout_ms,
      finch: [pool_timeout: timeouts.pool_timeout_ms] ++ pool_options
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
  Bounds a client's captured metadata headers to the one closed allowlist every
  upstream envelope applies: names are lowercased, unknown names are dropped
  whatever their prefix, the provider session names are bounded identifiers,
  the per-request flags are bounded to their vocabulary, and direct turn
  metadata keeps only its bounded projection. `headers/4` applies it to every
  `:forwarded_headers` option, so no caller can forward an arbitrary
  `x-openai-*` or `x-codex-*` header by skipping a pre-filter. It is
  idempotent, so an already bounded list passes unchanged.
  """
  @spec bounded_forwarded_metadata_headers(term()) :: [{String.t(), String.t()}]
  def bounded_forwarded_metadata_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        bounded_forwarded_metadata_header(String.downcase(name), value)

      _other ->
        []
    end)
  end

  def bounded_forwarded_metadata_headers(_headers), do: []

  @doc """
  One header through the same bounds as `bounded_forwarded_metadata_headers/1`;
  `name` must already be lowercase. Returns the header as a one-element list
  or an empty list.
  """
  @spec bounded_forwarded_metadata_header(term(), term()) :: [{String.t(), String.t()}]
  def bounded_forwarded_metadata_header(name, value) when is_binary(name) and is_binary(value) do
    cond do
      name in @provider_session_header_names ->
        if provider_session_header_value?(value), do: [{name, value}], else: []

      name in @forwarded_metadata_header_names ->
        bounded_metadata_header(name, value)

      true ->
        []
    end
  end

  def bounded_forwarded_metadata_header(_name, _value), do: []

  defp bounded_metadata_header(@memgen_request_header_name = name, @memgen_request_header_value = value),
    do: [{name, value}]

  defp bounded_metadata_header(@memgen_request_header_name, _value), do: []

  defp bounded_metadata_header(@guardian_header_name = name, value) when value in @guardian_header_values,
    do: [{name, value}]

  defp bounded_metadata_header(@guardian_header_name, _value), do: []

  defp bounded_metadata_header(@inference_call_id_header_name = name, value) do
    if byte_size(value) in 1..@inference_call_id_max_bytes and Regex.match?(@inference_call_id_pattern, value),
      do: [{name, value}],
      else: []
  end

  defp bounded_metadata_header(@turn_metadata_header_name = name, value),
    do: [{name, project_turn_metadata_header(value)}]

  defp bounded_metadata_header(name, value), do: [{name, value}]

  # Direct turn metadata is compatibility output: the unbounded code-mode tool
  # inventory travels in the frame `client_metadata`, so the header keeps
  # everything but that top-level key. A second pass finds no key and returns
  # the value unchanged.
  defp project_turn_metadata_header(value) do
    case CodexPooler.JSON.decode(value) do
      {:ok, %{"code_mode_tool_names" => _value} = metadata} ->
        encode_projected_turn_metadata(metadata, value)

      _other ->
        value
    end
  end

  defp encode_projected_turn_metadata(metadata, original) do
    case metadata
         |> Map.delete("code_mode_tool_names")
         |> CodexPooler.JSON.encode(escape: :unicode_safe) do
      {:ok, projected} -> projected
      {:error, _error} -> original
    end
  end

  @doc """
  The fixed namespace UUID behind `prompt_cache_session_id/2`.
  """
  @spec prompt_cache_session_namespace() :: String.t()
  def prompt_cache_session_namespace, do: @prompt_cache_session_namespace

  @doc """
  The provider `session-id` synthesized from a request's raw
  `prompt_cache_key` (every public `/v1` request, and a native Codex-backend
  HTTP or compact request that carries no usable client `session-id`), scoped
  to the authenticated tenant: RFC 4122 UUID v5
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
  def prompt_cache_session_id(scope, key),
    do: scoped_session_id(@prompt_cache_session_namespace_bytes, scope, key)

  @doc """
  The fixed namespace UUID behind `continuity_alias_session_id/2`.
  """
  @spec continuity_alias_session_namespace() :: String.t()
  def continuity_alias_session_namespace, do: @continuity_alias_session_namespace

  @doc """
  The provider `session-id` synthesized for a native Codex-backend HTTP or
  compact request from its accepted local continuity alias, when the request
  carries neither a usable client `session-id` nor a `prompt_cache_key`
  (findings#206 row 206-606). Same construction, scope, bounds and privacy
  rules as `prompt_cache_session_id/2`, under its own namespace: the alias is
  a client-local identifier with no tenant scope, so only this scoped digest
  of it ever reaches the provider, never the alias itself.
  """
  @spec continuity_alias_session_id(term(), term()) :: String.t() | nil
  def continuity_alias_session_id(scope, alias),
    do: scoped_session_id(@continuity_alias_session_namespace_bytes, scope, alias)

  defp scoped_session_id(namespace_bytes, %{pool_id: pool_id, api_key_id: api_key_id}, key)
       when is_binary(pool_id) and byte_size(pool_id) > 0 and is_binary(api_key_id) and
              byte_size(api_key_id) > 0 and is_binary(key) and
              byte_size(key) in 1..@prompt_cache_session_key_max_bytes do
    name = [netstring(pool_id), netstring(api_key_id), key]

    <<time_low::32, time_mid::16, time_hi::16, clock_seq::16, node::48, _rest::binary>> =
      :crypto.hash(:sha, [namespace_bytes, name])

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

  defp scoped_session_id(_namespace_bytes, _scope, _key), do: nil

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
    case UpstreamIdentity.account_scope(account_id) do
      nil -> []
      account_scope -> [{"chatgpt-account-id", account_scope}]
    end
  end

  defp codex_account_headers(_identity), do: []

  # The structural guarantee of every envelope: whatever a caller passes as
  # `:forwarded_headers` goes through the closed allowlist and value bounds,
  # never a prefix rule, so authorization, accept, content-type, the residency
  # header and any unlisted `x-openai-*`/`x-codex-*` name cannot pass.
  defp safe_forwarded_headers(headers), do: bounded_forwarded_metadata_headers(headers)

  defp codex_residency_headers(token) do
    case CodexAuth.compute_residency(token) do
      residency when is_binary(residency) -> [{@codex_residency_header, residency}]
      nil -> []
    end
  end
end
