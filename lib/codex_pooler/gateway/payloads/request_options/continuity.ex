defmodule CodexPooler.Gateway.Payloads.RequestOptions.Continuity do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization

  @session_header_sources [
    "x-codex-window-id",
    "x-codex-session-id",
    "session-id",
    "x-session-id",
    "x-session-affinity",
    "session_id",
    "x-codex-conversation-id"
  ]

  defstruct [
    :accepted_turn_state,
    :previous_response_id,
    :response_id,
    :resolved_previous_response_assignment_id,
    :session_header,
    :session_header_source,
    :session_key,
    :conversation_key,
    :owner_instance_id,
    :bridge_owner_lease_ttl_seconds,
    :reconnect_window_seconds,
    :codex_session,
    :semantic_turn_key,
    :turn_claim_key,
    :authenticated_owner_attach,
    upstream_previous_response_id?: false
  ]

  @type t :: %__MODULE__{
          accepted_turn_state: String.t() | nil,
          previous_response_id: String.t() | nil,
          response_id: String.t() | nil,
          resolved_previous_response_assignment_id: Ecto.UUID.t() | nil,
          session_header: String.t() | nil,
          session_header_source: String.t() | nil,
          session_key: String.t() | nil,
          conversation_key: String.t() | nil,
          owner_instance_id: String.t() | nil,
          bridge_owner_lease_ttl_seconds: pos_integer() | nil,
          reconnect_window_seconds: non_neg_integer() | nil,
          codex_session: term(),
          semantic_turn_key: <<_::256>> | nil,
          turn_claim_key: String.t() | nil,
          authenticated_owner_attach: boolean(),
          upstream_previous_response_id?: boolean()
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      accepted_turn_state: Map.get(opts, :accepted_turn_state),
      previous_response_id: Map.get(opts, :previous_response_id),
      response_id: Map.get(opts, :response_id),
      session_header: Map.get(opts, :session_header),
      session_header_source: session_header_source(Map.get(opts, :session_header_source)),
      session_key: Map.get(opts, :session_key),
      conversation_key: Map.get(opts, :conversation_key),
      owner_instance_id: Map.get(opts, :owner_instance_id),
      bridge_owner_lease_ttl_seconds:
        Normalization.optional_positive_integer(Map.get(opts, :bridge_owner_lease_ttl_seconds)),
      reconnect_window_seconds:
        Normalization.optional_non_negative_integer(Map.get(opts, :reconnect_window_seconds)),
      codex_session: Map.get(opts, :codex_session),
      semantic_turn_key: semantic_turn_key(Map.get(opts, :semantic_turn_key)),
      turn_claim_key: turn_claim_key(Map.get(opts, :turn_claim_key)),
      authenticated_owner_attach: Map.get(opts, :authenticated_owner_attach, false) == true,
      upstream_previous_response_id?: false
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = continuity, updates) do
    updates
    |> Map.new()
    |> Map.drop([:codex_turn_id])
    |> Normalization.normalize_optional_update(
      :bridge_owner_lease_ttl_seconds,
      &Normalization.optional_positive_integer/1
    )
    |> Normalization.normalize_optional_update(
      :reconnect_window_seconds,
      &Normalization.optional_non_negative_integer/1
    )
    |> Normalization.normalize_optional_update(:session_header_source, &session_header_source/1)
    |> Normalization.normalize_optional_update(:semantic_turn_key, &semantic_turn_key/1)
    |> Normalization.normalize_optional_update(:turn_claim_key, &turn_claim_key/1)
    |> Normalization.normalize_optional_update(:upstream_previous_response_id?, &(&1 == true))
    |> then(&struct!(continuity, &1))
  end

  @spec session_header_source(term()) :: String.t() | nil
  def session_header_source(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> session_header_source()
  end

  def session_header_source(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if value in @session_header_sources do
      value
    end
  end

  def session_header_source(_value), do: nil

  @spec semantic_turn_key(term()) :: <<_::256>> | nil
  defp semantic_turn_key(value) when is_binary(value) and byte_size(value) == 32, do: value
  defp semantic_turn_key(_value), do: nil

  @spec turn_claim_key(term()) :: String.t() | nil
  defp turn_claim_key("codex-turn:" <> encoded = value) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, digest} when byte_size(digest) == 32 -> value
      _invalid -> nil
    end
  end

  defp turn_claim_key(_value), do: nil
end
