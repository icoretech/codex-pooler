defmodule CodexPooler.Gateway.Persistence.SessionContinuity.Aliases do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeSessionAlias,
    CodexSession
  }

  alias CodexPooler.Repo

  @session_reconnectable_statuses CodexSession.reconnectable_statuses()
  @alias_active BridgeSessionAlias.active_status()

  @session_alias_conflict_target {:unsafe_fragment,
                                  "(pool_id, api_key_id, alias_kind, alias_hash) WHERE status = 'active'"}

  @spec active_session_for_update(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          DateTime.t()
        ) :: CodexSession.t() | nil
  def active_session_for_update(pool_id, api_key_id, alias_kind, alias_value, now) do
    alias_hash = alias_hash(alias_value)

    query =
      from session in CodexSession,
        join: alias_record in BridgeSessionAlias,
        on: alias_record.codex_session_id == session.id,
        where:
          alias_record.pool_id == ^pool_id and alias_record.api_key_id == ^api_key_id and
            alias_record.alias_kind == ^alias_kind and alias_record.alias_hash == ^alias_hash and
            alias_record.status == ^@alias_active and alias_record.expires_at > ^now and
            session.status in ^@session_reconnectable_statuses,
        order_by: [desc: alias_record.last_seen_at, desc: alias_record.updated_at],
        limit: 1,
        lock: "FOR UPDATE"

    query
    |> maybe_require_active_owner_lease(alias_kind, now)
    |> Repo.one()
  end

  @spec resolved_session_for_update(map(), RequestOptions.t(), String.t(), DateTime.t()) ::
          CodexSession.t() | nil
  def resolved_session_for_update(auth, %RequestOptions{} = opts, session_key, now) do
    alias_candidates(opts, session_key)
    |> Enum.find_value(fn {kind, value} ->
      active_session_for_update(auth.pool.id, auth.api_key.id, kind, value, now)
    end)
  end

  @spec register!(CodexSession.t(), map(), RequestOptions.t(), DateTime.t()) :: :ok
  def register!(%CodexSession{} = session, auth, %RequestOptions{} = opts, now) do
    alias_candidates(opts, session.session_key)
    |> Enum.each(fn {alias_kind, alias_value} ->
      upsert_session_alias!(session, auth, alias_kind, alias_value, now)
    end)
  end

  @spec continuity_opts(RequestOptions.t(), map(), map() | binary()) :: RequestOptions.t()
  def continuity_opts(%RequestOptions{} = request_options, payload, response_body) do
    request_options
    |> ContinuityPayload.put_previous_response_id(payload)
    |> RequestOptions.put_continuity(response_id: response_id_from_body(response_body))
  end

  defp maybe_require_active_owner_lease(query, "previous_response_id", _now), do: query

  defp maybe_require_active_owner_lease(query, _alias_kind, now) do
    where(query, [session], session.owner_lease_expires_at > ^now)
  end

  defp upsert_session_alias!(session, auth, alias_kind, alias_value, now) do
    alias_hash = alias_hash(alias_value)
    expires_at = DateTime.add(now, expired_alias_ttl_seconds(), :second)

    attrs = %{
      codex_session_id: session.id,
      pool_id: auth.pool.id,
      api_key_id: auth.api_key.id,
      alias_kind: alias_kind,
      alias_hash: alias_hash,
      alias_preview: alias_preview(alias_hash),
      status: @alias_active,
      expires_at: expires_at,
      last_seen_at: now,
      metadata: %{"source" => "gateway_continuity"},
      updated_at: now
    }

    on_conflict =
      from alias_record in BridgeSessionAlias,
        update: [
          set: [
            codex_session_id: ^session.id,
            alias_preview: ^attrs.alias_preview,
            expires_at: fragment("GREATEST(?, EXCLUDED.expires_at)", alias_record.expires_at),
            last_seen_at:
              fragment(
                "GREATEST(COALESCE(?, EXCLUDED.last_seen_at), EXCLUDED.last_seen_at)",
                alias_record.last_seen_at
              ),
            metadata: ^attrs.metadata,
            updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", alias_record.updated_at)
          ]
        ]

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(Map.put(attrs, :created_at, now))
    |> Repo.insert!(
      on_conflict: on_conflict,
      conflict_target: @session_alias_conflict_target
    )
  end

  defp alias_candidates(%RequestOptions{} = request_options, session_key) do
    continuity = request_options.continuity

    [
      {"turn_state", continuity.accepted_turn_state},
      {"previous_response_id", continuity.previous_response_id},
      {"previous_response_id", continuity.response_id},
      {"session_header", continuity.session_header},
      {"canonical_session_key", session_key}
    ]
    |> Enum.map(fn {kind, value} -> {kind, blank_to_nil(value)} end)
    |> Enum.reject(fn {_kind, value} -> is_nil(value) end)
    |> Enum.uniq()
  end

  defp response_id_from_body(body) when is_binary(body) do
    body
    |> response_id_from_json_body()
    |> Kernel.||(response_id_from_sse_body(body))
  end

  defp response_id_from_body(_body), do: nil

  defp response_id_from_json_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> response_id_from_decoded(decoded)
      {:error, _reason} -> nil
    end
  end

  defp response_id_from_sse_body(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.find_value(fn payload ->
      case Jason.decode(payload) do
        {:ok, decoded} -> response_id_from_decoded(decoded)
        {:error, _reason} -> nil
      end
    end)
  end

  defp response_id_from_decoded(%{"id" => id}) when is_binary(id), do: blank_to_nil(id)

  defp response_id_from_decoded(%{"response" => %{"id" => id}}) when is_binary(id),
    do: blank_to_nil(id)

  defp response_id_from_decoded(_decoded), do: nil

  defp alias_hash(value), do: :crypto.hash(:sha256, value)

  defp alias_preview(hash), do: hash |> Base.encode16(case: :lower) |> String.slice(0, 16)

  defp expired_alias_ttl_seconds, do: OperationalSettings.current().expired_alias_ttl_seconds

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
