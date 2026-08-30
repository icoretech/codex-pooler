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
    :semantic_turn_key,
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

  @type request_kind :: :turn | :compaction
  @type digest :: <<_::256>>
  @type t :: %__MODULE__{
          semantic_turn_key: digest(),
          window_id_digest: digest(),
          context_window_id_digest: digest(),
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
         {:ok, identity} <- validated_identity(canonical, codex_session_id),
         {:ok, window_id} <- required_identifier(canonical, "window_id"),
         {:ok, context_window_id} <- required_context_id(canonical),
         {:ok, window_number} <- optional_window_number(canonical),
         {:ok, request_kind, compaction} <- request_kind(canonical) do
      {:ok,
       %__MODULE__{
         semantic_turn_key: identity.semantic_turn_key,
         window_id_digest: window_id_digest(window_id),
         context_window_id_digest: context_id_digest(context_window_id),
         window_number: window_number,
         request_kind: request_kind,
         compaction: compaction
       }}
    end
  end

  def parse(_payload, _codex_session_id), do: invalid(@canonical_param)

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
      :error -> invalid(@canonical_param)
    end
  end

  defp fetch_canonical(_payload), do: invalid(@canonical_param)

  defp decode_canonical(value) when is_map(value) do
    if byte_size(:erlang.term_to_binary(value, [:deterministic])) <= @max_metadata_bytes do
      {:ok, value}
    else
      invalid(@canonical_param)
    end
  end

  defp decode_canonical(value)
       when is_binary(value) and byte_size(value) <= @max_metadata_bytes do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> invalid(@canonical_param)
      {:error, _reason} -> invalid(@canonical_param)
    end
  end

  defp decode_canonical(_value), do: invalid(@canonical_param)

  defp validated_identity(canonical, codex_session_id) do
    case WebsocketTurnIdentity.resolve(
           %{"client_metadata" => %{@canonical_key => Map.take(canonical, ["turn_id"])}},
           codex_session_id
         ) do
      {:ok, _identity} = result -> result
      :missing -> invalid(param("turn_id"))
      {:error, _reason} = error -> error
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
          invalid(param(key))
        end

      _other ->
        invalid(param(key))
    end
  end

  defp required_context_id(metadata) do
    with {:ok, value} <- required_identifier(metadata, "context_window_id"),
         {:ok, _uuid} <- Ecto.UUID.cast(value) do
      {:ok, value}
    else
      _other -> invalid(param("context_window_id"))
    end
  end

  defp optional_window_number(metadata) do
    case Map.fetch(metadata, "window_number") do
      :error ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value >= 0 and value <= @max_window_number ->
        {:ok, value}

      {:ok, _invalid} ->
        invalid(param("window_number"))
    end
  end

  defp request_kind(%{"request_kind" => "turn"} = metadata) do
    case Map.fetch(metadata, "compaction") do
      :error -> {:ok, :turn, nil}
      {:ok, _invalid} -> invalid(param("compaction"))
    end
  end

  defp request_kind(%{"request_kind" => "compaction"} = metadata) do
    with {:ok, compaction} <- Map.fetch(metadata, "compaction"),
         {:ok, parsed} <- parse_compaction(compaction) do
      {:ok, :compaction, parsed}
    else
      _other -> invalid(param("compaction"))
    end
  end

  defp request_kind(_metadata), do: invalid(param("request_kind"))

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

  defp invalid(param) do
    {:error, Error.invalid_request("native Codex turn metadata is invalid", param)}
  end
end

defimpl Inspect, for: CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata do
  def inspect(_metadata, _opts), do: "#NativeCodexTurnMetadata<redacted>"
end

defimpl Inspect, for: CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata.Compaction do
  def inspect(_compaction, _opts), do: "#NativeCodexTurnMetadata.Compaction<redacted>"
end
