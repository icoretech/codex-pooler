defmodule CodexPooler.Gateway.Payloads.WebsocketTurnIdentity do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @direct_turn_param "client_metadata.turn_id"
  @canonical_metadata_key "x-codex-turn-metadata"
  @canonical_metadata_param "client_metadata.x-codex-turn-metadata"
  @canonical_turn_param "client_metadata.x-codex-turn-metadata.turn_id"
  @turn_param "turn_id"
  @request_param "request_id"
  @turn_id_pattern ~r/\A[A-Za-z0-9_.:-]+\z/
  @claim_prefix "codex-turn:"
  @request_claim_prefix "codex-request:"
  @request_claim_domain "native_websocket_response_claim_v1"
  @replay_claim_domain "native_websocket_response_replay_claim_v1"
  @replay_volatile_metadata_keys [
    "x-codex-ws-stream-request-start-ms",
    "ws_request_header_traceparent",
    "ws_request_header_tracestate"
  ]
  @excluded_client_metadata_keys [
    "turn_id",
    @canonical_metadata_key,
    "x-codex-ws-stream-request-start-ms",
    "ws_request_header_traceparent",
    "ws_request_header_tracestate"
  ]

  @type identity :: %{
          required(:semantic_turn_key) => <<_::256>>,
          required(:turn_claim_key) => String.t()
        }

  @type result :: {:ok, identity()} | :missing | {:error, Error.reason()}

  @spec resolve(map(), String.t()) :: result()
  def resolve(payload, codex_session_id)
      when is_map(payload) and is_binary(codex_session_id) and codex_session_id != "" do
    with {:ok, raw_turn_id} <- raw_turn_id(payload) do
      digest = :crypto.hash(:sha256, codex_session_id <> <<0>> <> raw_turn_id)

      {:ok,
       %{
         semantic_turn_key: digest,
         turn_claim_key: @claim_prefix <> Base.url_encode64(digest, padding: false)
       }}
    end
  end

  def resolve(payload, _codex_session_id) when is_map(payload) do
    case raw_turn_id(payload) do
      :missing ->
        :missing

      {:ok, _raw_turn_id} ->
        {:error,
         Error.invalid_request(
           "native websocket session identity is unavailable",
           "codex_session_id"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  @spec request_claim_key(<<_::256>>, map()) :: String.t()
  def request_claim_key(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_map(payload) do
    projection = request_claim_projection(payload)

    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        request_claim_hmac_key(),
        :erlang.term_to_binary(
          {@request_claim_domain, semantic_turn_key, projection},
          [:deterministic]
        )
      )

    @request_claim_prefix <> Base.url_encode64(digest, padding: false)
  end

  @spec replay_claim_digest(<<_::256>>, map()) ::
          {:ok, <<_::256>>} | {:error, Error.reason()}
  def replay_claim_digest(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_map(payload) do
    with {:ok, projection} <- replay_claim_projection(payload),
         {:ok, key} <- replay_claim_hmac_key() do
      input =
        :erlang.term_to_binary(
          {@replay_claim_domain, semantic_turn_key, projection},
          [:deterministic]
        )

      {:ok, :crypto.mac(:hmac, :sha256, key, input)}
    end
  end

  def replay_claim_digest(_semantic_turn_key, _payload),
    do: invalid_replay_claim("semantic_turn_key")

  @spec raw_turn_id(map()) :: {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp raw_turn_id(payload) do
    case Map.fetch(payload, "client_metadata") do
      {:ok, client_metadata} when is_map(client_metadata) ->
        client_metadata_turn_id(client_metadata, payload)

      {:ok, nil} ->
        legacy_turn_id(payload)

      {:ok, _non_map_metadata} ->
        legacy_turn_id(payload)

      :error ->
        legacy_turn_id(payload)
    end
  end

  @spec client_metadata_turn_id(map(), map()) ::
          {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp client_metadata_turn_id(client_metadata, payload) do
    case Map.fetch(client_metadata, "turn_id") do
      {:ok, raw_turn_id} ->
        validate(raw_turn_id, @direct_turn_param)

      :error ->
        canonical_metadata_turn_id(client_metadata, payload)
    end
  end

  @spec canonical_metadata_turn_id(map(), map()) ::
          {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp canonical_metadata_turn_id(client_metadata, payload) do
    case Map.fetch(client_metadata, @canonical_metadata_key) do
      {:ok, value} ->
        case decode_canonical_metadata(value) do
          {:ok, metadata} -> canonical_turn_id(metadata, payload)
          {:error, _reason} = error -> error
        end

      :error ->
        legacy_turn_id(payload)
    end
  end

  defp canonical_turn_id(metadata, payload) do
    case fetch_canonical_turn_id(metadata) do
      {:ok, raw_turn_id} -> validate(raw_turn_id, @canonical_turn_param)
      :missing -> legacy_turn_id(payload)
    end
  end

  @spec decode_canonical_metadata(term()) :: {:ok, map()} | {:error, Error.reason()}
  defp decode_canonical_metadata(value) when is_map(value), do: {:ok, value}

  defp decode_canonical_metadata(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _invalid} -> invalid(@canonical_metadata_param)
      {:error, _reason} -> invalid(@canonical_metadata_param)
    end
  end

  defp decode_canonical_metadata(_value), do: invalid(@canonical_metadata_param)

  @spec fetch_canonical_turn_id(map()) :: {:ok, term()} | :missing
  defp fetch_canonical_turn_id(metadata) do
    case Map.fetch(metadata, "turn_id") do
      {:ok, raw_turn_id} -> {:ok, raw_turn_id}
      :error -> :missing
    end
  end

  @spec legacy_turn_id(map()) :: {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp legacy_turn_id(payload) do
    case Map.fetch(payload, "turn_id") do
      {:ok, raw_turn_id} -> validate(raw_turn_id, @turn_param)
      :error -> request_id(payload)
    end
  end

  @spec request_id(map()) :: {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp request_id(payload) do
    case Map.fetch(payload, "request_id") do
      {:ok, raw_turn_id} -> validate(raw_turn_id, @request_param)
      :error -> :missing
    end
  end

  @spec validate(term(), String.t()) :: {:ok, String.t()} | {:error, Error.reason()}
  defp validate(value, param)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= 256 do
    if String.valid?(value) and Regex.match?(@turn_id_pattern, value) do
      {:ok, value}
    else
      invalid(param)
    end
  end

  defp validate(_value, param), do: invalid(param)

  @spec invalid(String.t()) :: {:error, Error.reason()}
  defp invalid(param) do
    {:error, Error.invalid_request("native websocket turn identity is invalid", param)}
  end

  defp request_claim_projection(payload) do
    payload
    |> Map.drop([@turn_param, @request_param])
    |> scrub_request_client_metadata()
  end

  defp replay_claim_projection(payload) do
    payload
    |> Map.drop([@turn_param, @request_param])
    |> normalize_replay_client_metadata()
  end

  defp normalize_replay_client_metadata(%{"client_metadata" => metadata} = payload)
       when is_map(metadata) do
    metadata = Map.drop(metadata, ["turn_id" | @replay_volatile_metadata_keys])

    case Map.fetch(metadata, @canonical_metadata_key) do
      {:ok, value} ->
        with {:ok, canonical} <- decode_canonical_metadata(value),
             {:ok, normalized} <- normalize_replay_metadata(canonical) do
          {:ok,
           Map.put(
             payload,
             "client_metadata",
             Map.put(metadata, @canonical_metadata_key, normalized)
           )}
        end

      :error ->
        {:ok, Map.put(payload, "client_metadata", metadata)}
    end
  end

  defp normalize_replay_client_metadata(%{"client_metadata" => nil} = payload),
    do: {:ok, payload}

  defp normalize_replay_client_metadata(%{"client_metadata" => _invalid}),
    do: invalid_replay_claim(@canonical_metadata_param)

  defp normalize_replay_client_metadata(payload), do: {:ok, payload}

  defp normalize_replay_metadata(value) when is_map(value) do
    value
    |> Map.drop(["turn_id"])
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, child}, {:ok, acc} when is_binary(key) ->
        case normalize_replay_metadata(child) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, invalid_replay_claim(@canonical_metadata_param)}
    end)
  end

  defp normalize_replay_metadata(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn child, {:ok, acc} ->
      case normalize_replay_metadata(child) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_replay_metadata(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_replay_metadata(_value),
    do: invalid_replay_claim(@canonical_metadata_param)

  defp replay_claim_hmac_key do
    with {:ok, secret} <- configured_secret_key_base() do
      {:ok, :crypto.hash(:sha256, secret <> <<0>> <> @replay_claim_domain)}
    end
  end

  defp configured_secret_key_base do
    case Application.fetch_env(:codex_pooler, CodexPoolerWeb.Endpoint) do
      {:ok, config} when is_list(config) ->
        case Keyword.fetch(config, :secret_key_base) do
          {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
          _invalid -> invalid_replay_claim("secret_key_base")
        end

      _missing ->
        invalid_replay_claim("secret_key_base")
    end
  end

  defp invalid_replay_claim(param) do
    {:error, Error.invalid_request("native websocket replay claim is invalid", param)}
  end

  defp scrub_request_client_metadata(%{"client_metadata" => client_metadata} = payload)
       when is_map(client_metadata) do
    Map.put(
      payload,
      "client_metadata",
      Map.drop(client_metadata, @excluded_client_metadata_keys)
    )
  end

  defp scrub_request_client_metadata(payload), do: payload

  defp request_claim_hmac_key do
    :crypto.hash(:sha256, secret_key_base() <> <<0>> <> @request_claim_domain)
  end

  defp secret_key_base do
    :codex_pooler
    |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
