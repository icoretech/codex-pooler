defmodule CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity

  defmodule Compaction do
    @moduledoc false

    @enforce_keys [:trigger, :reason, :implementation, :phase, :strategy]
    defstruct [:trigger, :reason, :implementation, :phase, :strategy]

    @type t :: %__MODULE__{
            trigger: :auto | :manual,
            reason: :user_requested | :context_limit | :model_downshift | :comp_hash_changed,
            implementation: :responses | :responses_compaction_v2 | :responses_compact,
            phase: :standalone_turn | :pre_turn | :mid_turn,
            strategy: :memento | :prefix_compaction
          }
  end

  @enforce_keys [
    :window_id_digest,
    :context_window_id_digest,
    :request_kind
  ]
  defstruct [
    :semantic_turn_key,
    :window_id_digest,
    :context_window_id_digest,
    :window_number,
    :request_kind,
    :compaction
  ]

  @type request_kind :: :turn | :prewarm | :compaction | :memory
  @type digest :: <<_::256>>
  @type t :: %__MODULE__{
          semantic_turn_key: digest() | nil,
          window_id_digest: digest() | nil,
          context_window_id_digest: digest() | nil,
          window_number: non_neg_integer() | nil,
          request_kind: request_kind(),
          compaction: Compaction.t() | nil
        }

  @canonical_key "x-codex-turn-metadata"
  @canonical_param "client_metadata.x-codex-turn-metadata"
  @max_metadata_bytes 4_096
  @max_identifier_bytes 256
  @max_window_number 18_446_744_073_709_551_615
  @digest_salt "native_compaction_admission:v1"

  @spec parse(map(), String.t()) :: {:ok, t()} | {:error, Error.reason()}
  def parse(payload, codex_session_id) when is_map(payload) and is_binary(codex_session_id) do
    with {:ok, canonical} <- fetch_canonical(payload),
         {:ok, request_kind, compaction} <- request_kind(canonical),
         {:ok, semantic_turn_key} <- semantic_turn_key(canonical, codex_session_id, request_kind),
         {:ok, window_id, context_window_id, window_number} <-
           request_identity(canonical, request_kind) do
      {:ok,
       %__MODULE__{
         semantic_turn_key: semantic_turn_key,
         window_id_digest: maybe_digest(window_id, &window_id_digest/1),
         context_window_id_digest: maybe_digest(context_window_id, &context_id_digest/1),
         window_number: window_number,
         request_kind: request_kind,
         compaction: compaction
       }}
    end
  end

  def parse(_payload, _codex_session_id), do: invalid(@canonical_param)

  @spec rejection_class(Error.reason()) :: atom()
  def rejection_class(%{native_metadata_rejection_class: rejection_class})
      when rejection_class in [
             :missing_canonical,
             :malformed_canonical,
             :invalid_turn_id,
             :invalid_window_id,
             :invalid_context_window_id,
             :invalid_window_number,
             :unsupported_request_kind,
             :invalid_compaction
           ],
      do: rejection_class

  def rejection_class(%{param: "client_metadata.x-codex-turn-metadata.turn_id"}),
    do: :invalid_turn_id

  def rejection_class(%{param: "client_metadata.x-codex-turn-metadata.window_id"}),
    do: :invalid_window_id

  def rejection_class(%{param: "client_metadata.x-codex-turn-metadata.context_window_id"}),
    do: :invalid_context_window_id

  def rejection_class(%{param: "client_metadata.x-codex-turn-metadata.window_number"}),
    do: :invalid_window_number

  def rejection_class(%{param: "client_metadata.x-codex-turn-metadata.request_kind"}),
    do: :unsupported_request_kind

  def rejection_class(%{param: "client_metadata.x-codex-turn-metadata.compaction"}),
    do: :invalid_compaction

  def rejection_class(_reason), do: :malformed_canonical

  @spec response_id_digest(String.t()) :: digest()
  def response_id_digest(value), do: digest(:provider_response_id, value)

  @spec window_id_digest(String.t()) :: digest()
  def window_id_digest(value), do: digest(:window_id, value)

  @spec context_id_digest(String.t()) :: digest()
  def context_id_digest(value), do: digest(:context_window_id, value)

  @spec compaction_item_digest(map()) :: digest()
  def compaction_item_digest(item) when is_map(item) do
    digest(:native_compaction_item, :erlang.term_to_binary(item, [:deterministic]))
  end

  defp fetch_canonical(%{"client_metadata" => client_metadata}) when is_map(client_metadata) do
    case Map.fetch(client_metadata, @canonical_key) do
      {:ok, value} -> decode_canonical(value)
      :error -> invalid(:missing_canonical, @canonical_param)
    end
  end

  defp fetch_canonical(_payload), do: invalid(@canonical_param)

  defp decode_canonical(value) when is_map(value) do
    if byte_size(:erlang.term_to_binary(value, [:deterministic])) <= @max_metadata_bytes do
      {:ok, value}
    else
      invalid(:malformed_canonical, @canonical_param)
    end
  end

  defp decode_canonical(value)
       when is_binary(value) and byte_size(value) <= @max_metadata_bytes do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> invalid(:malformed_canonical, @canonical_param)
      {:error, _reason} -> invalid(:malformed_canonical, @canonical_param)
    end
  end

  defp decode_canonical(_value), do: invalid(:malformed_canonical, @canonical_param)

  defp validated_identity(canonical, codex_session_id) do
    case WebsocketTurnIdentity.resolve(
           %{"client_metadata" => %{@canonical_key => Map.take(canonical, ["turn_id"])}},
           codex_session_id
         ) do
      {:ok, _identity} = result -> result
      :missing -> invalid(:invalid_turn_id, param("turn_id"))
      {:error, _reason} = error -> error
    end
  end

  defp semantic_turn_key(_canonical, _codex_session_id, :memory), do: {:ok, nil}

  defp semantic_turn_key(canonical, codex_session_id, :prewarm) do
    case Map.fetch(canonical, "turn_id") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, ""} -> {:ok, nil}
      {:ok, _turn_id} -> semantic_turn_key(canonical, codex_session_id, :turn)
    end
  end

  defp semantic_turn_key(canonical, codex_session_id, request_kind)
       when request_kind in [:turn, :compaction] do
    with {:ok, identity} <- validated_identity(canonical, codex_session_id) do
      {:ok, identity.semantic_turn_key}
    end
  end

  defp required_identifier(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value}
      when is_binary(value) and byte_size(value) >= 1 and
             byte_size(value) <= @max_identifier_bytes ->
        if String.valid?(value) and String.trim(value) != "" do
          {:ok, value}
        else
          invalid(identifier_rejection_class(key), param(key))
        end

      _other ->
        invalid(identifier_rejection_class(key), param(key))
    end
  end

  defp required_context_id(metadata) do
    with {:ok, value} <- required_identifier(metadata, "context_window_id"),
         {:ok, _uuid} <- Ecto.UUID.cast(value) do
      {:ok, value}
    else
      _other -> invalid(:invalid_context_window_id, param("context_window_id"))
    end
  end

  defp optional_window_number(metadata) do
    case Map.fetch(metadata, "window_number") do
      :error ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value >= 0 and value <= @max_window_number ->
        {:ok, value}

      {:ok, _invalid} ->
        invalid(:invalid_window_number, param("window_number"))
    end
  end

  defp request_kind(%{"request_kind" => "turn"} = metadata) do
    case Map.fetch(metadata, "compaction") do
      :error -> {:ok, :turn, nil}
      {:ok, _invalid} -> invalid(:invalid_compaction, param("compaction"))
    end
  end

  defp request_kind(%{"request_kind" => "prewarm"} = metadata) do
    case Map.fetch(metadata, "compaction") do
      :error -> {:ok, :prewarm, nil}
      {:ok, _invalid} -> invalid(:invalid_compaction, param("compaction"))
    end
  end

  defp request_kind(%{"request_kind" => "memory"} = metadata) do
    case Map.fetch(metadata, "compaction") do
      :error -> {:ok, :memory, nil}
      {:ok, _invalid} -> invalid(:invalid_compaction, param("compaction"))
    end
  end

  defp request_kind(%{"request_kind" => "compaction"} = metadata) do
    with {:ok, compaction} <- Map.fetch(metadata, "compaction"),
         {:ok, parsed} <- parse_compaction(compaction) do
      {:ok, :compaction, parsed}
    else
      _other -> invalid(:invalid_compaction, param("compaction"))
    end
  end

  defp request_kind(_metadata),
    do: invalid(:unsupported_request_kind, param("request_kind"))

  defp request_identity(metadata, :compaction) do
    with {:ok, window_id} <- required_identifier(metadata, "window_id"),
         {:ok, context_window_id} <- required_context_id(metadata),
         {:ok, window_number} <- optional_window_number(metadata) do
      {:ok, window_id, context_window_id, window_number}
    end
  end

  defp request_identity(metadata, request_kind) when request_kind in [:turn, :prewarm] do
    with {:ok, window_id} <- optional_identifier(metadata, "window_id"),
         {:ok, context_window_id} <- optional_context_id(metadata),
         {:ok, window_number} <- optional_window_number(metadata) do
      {:ok, window_id, context_window_id, window_number}
    end
  end

  defp request_identity(_metadata, :memory), do: {:ok, nil, nil, nil}

  defp optional_identifier(metadata, key) do
    case Map.fetch(metadata, key) do
      :error -> {:ok, nil}
      {:ok, _value} -> required_identifier(metadata, key)
    end
  end

  defp optional_context_id(metadata) do
    case Map.fetch(metadata, "context_window_id") do
      :error -> {:ok, nil}
      {:ok, _value} -> required_context_id(metadata)
    end
  end

  defp parse_compaction(compaction) when is_map(compaction) do
    with {:ok, trigger} <- enum(compaction, "trigger", %{"auto" => :auto, "manual" => :manual}),
         {:ok, reason} <-
           enum(compaction, "reason", %{
             "user_requested" => :user_requested,
             "context_limit" => :context_limit,
             "model_downshift" => :model_downshift,
             "comp_hash_changed" => :comp_hash_changed
           }),
         {:ok, implementation} <-
           enum(compaction, "implementation", %{
             "responses" => :responses,
             "responses_compaction_v2" => :responses_compaction_v2,
             "responses_compact" => :responses_compact
           }),
         {:ok, phase} <-
           enum(compaction, "phase", %{
             "standalone_turn" => :standalone_turn,
             "pre_turn" => :pre_turn,
             "mid_turn" => :mid_turn
           }),
         {:ok, strategy} <-
           enum(compaction, "strategy", %{
             "memento" => :memento,
             "prefix_compaction" => :prefix_compaction
           }) do
      {:ok,
       %Compaction{
         trigger: trigger,
         reason: reason,
         implementation: implementation,
         phase: phase,
         strategy: strategy
       }}
    end
  end

  defp parse_compaction(_compaction), do: :error

  defp enum(map, key, values) do
    case Map.fetch(map, key) do
      {:ok, raw} -> Map.fetch(values, raw)
      :error -> :error
    end
  end

  defp digest(domain, value) when is_binary(value) do
    domain_key = :crypto.hash(:sha256, secret_key_base() <> <<0>> <> @digest_salt)
    :crypto.mac(:hmac, :sha256, domain_key, Atom.to_string(domain) <> <<0>> <> value)
  end

  defp secret_key_base do
    :codex_pooler
    |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp param(field), do: @canonical_param <> "." <> field

  defp maybe_digest(nil, _digest), do: nil
  defp maybe_digest(value, digest), do: digest.(value)

  defp identifier_rejection_class("window_id"), do: :invalid_window_id
  defp identifier_rejection_class("context_window_id"), do: :invalid_context_window_id
  defp identifier_rejection_class(_key), do: :malformed_canonical

  defp invalid(param), do: invalid(:malformed_canonical, param)

  defp invalid(rejection_class, param) do
    reason = Error.invalid_request("native Codex turn metadata is invalid", param)
    {:error, Map.put(reason, :native_metadata_rejection_class, rejection_class)}
  end
end

defimpl Inspect, for: CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata do
  def inspect(_metadata, _opts), do: "#NativeCodexTurnMetadata<redacted>"
end

defimpl Inspect, for: CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata.Compaction do
  def inspect(_compaction, _opts), do: "#NativeCodexTurnMetadata.Compaction<redacted>"
end
