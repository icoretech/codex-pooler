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
    :session_header,
    :session_header_source,
    :session_key,
    :conversation_key,
    :owner_instance_id,
    :bridge_owner_lease_ttl_seconds,
    :reconnect_window_seconds,
    :codex_session,
    :codex_turn_id,
    :authenticated_owner_attach
  ]

  @type t :: %__MODULE__{
          accepted_turn_state: String.t() | nil,
          previous_response_id: String.t() | nil,
          response_id: String.t() | nil,
          session_header: String.t() | nil,
          session_header_source: String.t() | nil,
          session_key: String.t() | nil,
          conversation_key: String.t() | nil,
          owner_instance_id: String.t() | nil,
          bridge_owner_lease_ttl_seconds: pos_integer() | nil,
          reconnect_window_seconds: non_neg_integer() | nil,
          codex_session: term(),
          codex_turn_id: Ecto.UUID.t() | nil,
          authenticated_owner_attach: boolean()
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
      codex_turn_id: Map.get(opts, :codex_turn_id),
      authenticated_owner_attach: Map.get(opts, :authenticated_owner_attach, false) == true
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = continuity, updates) do
    updates
    |> Map.new()
    |> Normalization.normalize_optional_update(
      :bridge_owner_lease_ttl_seconds,
      &Normalization.optional_positive_integer/1
    )
    |> Normalization.normalize_optional_update(
      :reconnect_window_seconds,
      &Normalization.optional_non_negative_integer/1
    )
    |> Normalization.normalize_optional_update(:session_header_source, &session_header_source/1)
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
end
