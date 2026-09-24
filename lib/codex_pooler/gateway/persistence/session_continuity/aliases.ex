defmodule CodexPooler.Gateway.Persistence.SessionContinuity.Aliases do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeSessionAlias,
    CodexSession,
    CodexTurn
  }

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.SessionAlias,
    as: SessionAliasStatus

  alias CodexPooler.Repo

  @session_reconnectable_statuses SessionStatus.reconnectable_statuses()
  @alias_active SessionAliasStatus.active_status()

  @alias_metadata %{"source" => "gateway_continuity"}
  @serving_modes ~w(full lite)

  @session_alias_conflict_target {:unsafe_fragment, "(pool_id, api_key_id, alias_kind, alias_hash) WHERE status = 'active'"}

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
            session.api_key_id == ^api_key_id and
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
    candidates = alias_candidates(opts, session_key)

    case candidates do
      [] -> nil
      candidates -> resolved_session_query(auth, candidates, now) |> Repo.one()
    end
  end

  # Read-only strict lookup for the saved-reset bypass proof: the anchor must
  # resolve through an alias that already exists (before this request registers
  # its own), to a session with a bound assignment. Mirrors the
  # previous_response_id validity rules of `active_session_for_update/5`
  # without locking or registering anything.
  @spec previous_response_assignment_id(map(), String.t(), DateTime.t()) :: Ecto.UUID.t() | nil
  def previous_response_assignment_id(auth, previous_response_id, now) do
    case previous_response_resolution(auth, previous_response_id, now) do
      %{assignment_id: assignment_id} -> assignment_id
      nil -> nil
    end
  end

  # The same strict lookup, also returning the Full/Lite dialect recorded on the
  # anchor's alias when its response completed (`response_alias_metadata/1`).
  # The mode is `nil` when the alias carries none (written before the record
  # existed); there is no alias at all for a response a request without a
  # session produced.
  @spec previous_response_resolution(map(), String.t(), DateTime.t()) ::
          %{assignment_id: Ecto.UUID.t() | nil, serving_mode: String.t() | nil} | nil
  def previous_response_resolution(auth, previous_response_id, now) do
    alias_hash = alias_hash(previous_response_id)

    Repo.one(
      from session in CodexSession,
        join: alias_record in BridgeSessionAlias,
        on: alias_record.codex_session_id == session.id,
        where:
          alias_record.pool_id == ^auth.pool.id and alias_record.api_key_id == ^auth.api_key.id and
            session.api_key_id == ^auth.api_key.id and
            alias_record.alias_kind == "previous_response_id" and
            alias_record.alias_hash == ^alias_hash and
            alias_record.status == ^@alias_active and alias_record.expires_at > ^now and
            session.status in ^@session_reconnectable_statuses,
        order_by: [desc: alias_record.last_seen_at, desc: alias_record.updated_at],
        limit: 1,
        select: %{
          assignment_id: session.pool_upstream_assignment_id,
          serving_mode: fragment("?->>'serving_mode'", alias_record.metadata)
        }
    )
    |> known_resolution_serving_mode()
  end

  defp known_resolution_serving_mode(%{serving_mode: mode} = resolution), do: %{resolution | serving_mode: known_serving_mode(mode)}
  defp known_resolution_serving_mode(nil), do: nil

  @spec previous_response_session_id(map(), String.t(), DateTime.t()) :: Ecto.UUID.t() | nil
  def previous_response_session_id(auth, previous_response_id, now) do
    alias_hash = alias_hash(previous_response_id)

    Repo.one(
      from session in CodexSession,
        join: alias_record in BridgeSessionAlias,
        on: alias_record.codex_session_id == session.id,
        where:
          alias_record.pool_id == ^auth.pool.id and alias_record.api_key_id == ^auth.api_key.id and
            session.api_key_id == ^auth.api_key.id and
            alias_record.alias_kind == "previous_response_id" and
            alias_record.alias_hash == ^alias_hash and
            alias_record.status == ^@alias_active and alias_record.expires_at > ^now and
            session.status in ^@session_reconnectable_statuses,
        order_by: [desc: alias_record.last_seen_at, desc: alias_record.updated_at],
        limit: 1,
        select: session.id
    )
  end

  @spec register!(CodexSession.t(), map(), RequestOptions.t(), DateTime.t()) :: :ok
  def register!(%CodexSession{} = session, auth, %RequestOptions{} = opts, now) do
    expires_at = DateTime.add(now, expired_alias_ttl_seconds(), :second)

    response_alias = {"previous_response_id", blank_to_nil(opts.continuity.response_id)}

    rows =
      opts
      |> alias_candidates(session.session_key)
      |> Enum.map(fn {alias_kind, alias_value} = candidate ->
        metadata = if candidate == response_alias, do: response_alias_metadata(opts), else: @alias_metadata
        alias_attrs(session, auth, alias_kind, alias_value, now, expires_at, metadata)
      end)

    if rows != [] do
      Repo.insert_all(BridgeSessionAlias, rows,
        on_conflict: alias_upsert_query(session, now, expires_at),
        conflict_target: @session_alias_conflict_target
      )
    end

    :ok
  end

  @spec continuity_opts(RequestOptions.t(), map(), map() | binary()) :: RequestOptions.t()
  def continuity_opts(%RequestOptions{} = request_options, payload, response_body) do
    response_id =
      case blank_to_nil(request_options.continuity.response_id) do
        nil -> response_id_from_body(response_body)
        response_id -> response_id
      end

    request_options
    |> ContinuityPayload.put_previous_response_id(payload)
    |> RequestOptions.put_continuity(response_id: response_id)
  end

  @spec register_session_header_hash(CodexSession.t(), map(), <<_::256>>, DateTime.t()) ::
          :ok | {:error, :session_alias_conflict}
  def register_session_header_hash(
        %CodexSession{pool_id: pool_id, api_key_id: api_key_id} = session,
        %{pool: %{id: pool_id}, api_key: %{id: api_key_id}},
        hash,
        now
      )
      when is_binary(hash) and byte_size(hash) == 32 do
    expires_at = DateTime.add(now, expired_alias_ttl_seconds(), :second)

    row = %{
      id: Ecto.UUID.generate(),
      codex_session_id: session.id,
      pool_id: pool_id,
      api_key_id: api_key_id,
      alias_kind: "session_header",
      alias_hash: hash,
      alias_preview: alias_preview(hash),
      status: @alias_active,
      expires_at: expires_at,
      last_seen_at: now,
      metadata: %{"source" => "native_final_window"},
      created_at: now,
      updated_at: now
    }

    Repo.insert_all(BridgeSessionAlias, [row],
      on_conflict:
        from(alias_record in BridgeSessionAlias,
          where: alias_record.codex_session_id == ^session.id,
          update: [set: [expires_at: ^expires_at, last_seen_at: ^now, updated_at: ^now]]
        ),
      conflict_target: @session_alias_conflict_target
    )

    if Repo.exists?(
         from alias_record in BridgeSessionAlias,
           where:
             alias_record.pool_id == ^pool_id and alias_record.api_key_id == ^api_key_id and
               alias_record.alias_kind == "session_header" and alias_record.alias_hash == ^hash and
               alias_record.status == ^@alias_active and
               alias_record.codex_session_id == ^session.id
       ) do
      :ok
    else
      {:error, :session_alias_conflict}
    end
  end

  @doc """
  Leads the `session_header` lookup of a window a websocket turn frame carries
  to the session of the socket that sent it (findings#206, P115). The window's
  alias is created, refreshed, or moved from the session holding it, unless
  that session has a turn in progress, whose own reconnect needs the window.
  It runs under the socket session's lock inside the turn's reservation, so
  it never waits for the alias row: one another transaction holds (an
  upgrade resolving the window) is left alone (`:busy`). Answers what it did;
  a lookup aid, it never fails the turn.
  """
  @spec point_frame_window_hash(CodexSession.t(), map(), <<_::256>>, DateTime.t()) :: :created | :refreshed | :moved | :kept | :busy
  def point_frame_window_hash(
        %CodexSession{pool_id: pool_id, api_key_id: api_key_id} = session,
        %{pool: %{id: pool_id}, api_key: %{id: api_key_id}},
        hash,
        now
      )
      when is_binary(hash) and byte_size(hash) == 32 do
    expires_at = DateTime.add(now, expired_alias_ttl_seconds(), :second)

    current =
      Repo.one(
        from alias_record in BridgeSessionAlias,
          where:
            alias_record.pool_id == ^pool_id and alias_record.api_key_id == ^api_key_id and
              alias_record.alias_kind == "session_header" and alias_record.alias_hash == ^hash and
              alias_record.status == ^@alias_active,
          lock: "FOR UPDATE SKIP LOCKED"
      )

    case current do
      nil -> register_session_header_hash_row(session, hash, now, expires_at)
      %BridgeSessionAlias{} = row -> point_existing_alias(row, session, now, expires_at)
    end
  end

  defp point_existing_alias(%BridgeSessionAlias{codex_session_id: session_id} = row, %CodexSession{id: session_id}, now, expires_at) do
    refresh_alias!(row, now, expires_at, row.metadata)
    :refreshed
  end

  defp point_existing_alias(%BridgeSessionAlias{codex_session_id: holder_id} = row, %CodexSession{} = session, now, expires_at) do
    if turn_in_progress?(holder_id) do
      :kept
    else
      row
      |> Ecto.Changeset.change(codex_session_id: session.id)
      |> refresh_alias!(now, expires_at, %{"source" => "native_frame_window"})

      :moved
    end
  end

  defp register_session_header_hash_row(session, hash, now, expires_at) do
    Repo.insert_all(
      BridgeSessionAlias,
      [
        %{
          id: Ecto.UUID.generate(),
          codex_session_id: session.id,
          pool_id: session.pool_id,
          api_key_id: session.api_key_id,
          alias_kind: "session_header",
          alias_hash: hash,
          alias_preview: alias_preview(hash),
          status: @alias_active,
          expires_at: expires_at,
          last_seen_at: now,
          metadata: %{"source" => "native_frame_window"},
          created_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: @session_alias_conflict_target
    )
    |> case do
      {1, _rows} -> :created
      {0, _rows} -> :busy
    end
  end

  defp refresh_alias!(%BridgeSessionAlias{} = row, now, expires_at, metadata), do: row |> Ecto.Changeset.change() |> refresh_alias!(now, expires_at, metadata)

  defp refresh_alias!(%Ecto.Changeset{} = changeset, now, expires_at, metadata) do
    changeset
    |> Ecto.Changeset.change(expires_at: expires_at, last_seen_at: now, updated_at: now, metadata: metadata)
    |> Repo.update!()
  end

  defp turn_in_progress?(session_id), do: Repo.exists?(from(turn in CodexTurn, where: turn.codex_session_id == ^session_id and turn.status == "in_progress"))

  defp maybe_require_active_owner_lease(query, "previous_response_id", _now), do: query

  defp maybe_require_active_owner_lease(query, _alias_kind, now) do
    where(query, [session], session.owner_lease_expires_at > ^now)
  end

  # The alias of the response a request produced records the Full/Lite dialect
  # that request was served in. A context the provider holds keeps the dialect
  # of the request that built it: one opened under Full holds no Lite tool
  # manifest and no instructions message, which Lite sends only on a request
  # that opens a context (findings#232 rows 232-184 and 232-270).
  defp response_alias_metadata(%RequestOptions{} = opts) do
    serving_mode = if RequestOptions.use_responses_lite?(opts), do: "lite", else: "full"
    Map.put(@alias_metadata, "serving_mode", serving_mode)
  end

  defp alias_attrs(session, auth, alias_kind, alias_value, now, expires_at, metadata) do
    alias_hash = alias_hash(alias_value)

    %{
      id: Ecto.UUID.generate(),
      codex_session_id: session.id,
      pool_id: auth.pool.id,
      api_key_id: auth.api_key.id,
      alias_kind: alias_kind,
      alias_hash: alias_hash,
      alias_preview: alias_preview(alias_hash),
      status: @alias_active,
      expires_at: expires_at,
      last_seen_at: now,
      metadata: metadata,
      created_at: now,
      updated_at: now
    }
  end

  defp alias_upsert_query(session, now, expires_at) do
    from alias_record in BridgeSessionAlias,
      update: [
        set: [
          codex_session_id: ^session.id,
          alias_preview: fragment("EXCLUDED.alias_preview"),
          expires_at: fragment("GREATEST(?, ?)", alias_record.expires_at, ^expires_at),
          last_seen_at: fragment("GREATEST(COALESCE(?, ?), ?)", alias_record.last_seen_at, ^now, ^now),
          # Merged, so re-registering a response's alias as the anchor of a
          # later request keeps the dialect recorded when it completed.
          metadata: fragment("? || EXCLUDED.metadata", alias_record.metadata),
          updated_at: fragment("GREATEST(?, ?)", alias_record.updated_at, ^now)
        ]
      ]
  end

  defp resolved_session_query(auth, candidates, now) do
    [{kind_1, hash_1}, {kind_2, hash_2}, {kind_3, hash_3}, {kind_4, hash_4}, {kind_5, hash_5}] =
      padded_hashed_candidates(candidates, 5)

    from session in CodexSession,
      join: alias_record in BridgeSessionAlias,
      on: alias_record.codex_session_id == session.id,
      where:
        alias_record.pool_id == ^auth.pool.id and alias_record.api_key_id == ^auth.api_key.id and
          session.api_key_id == ^auth.api_key.id and
          alias_record.status == ^@alias_active and alias_record.expires_at > ^now and
          session.status in ^@session_reconnectable_statuses and
          (alias_record.alias_kind == "previous_response_id" or
             session.owner_lease_expires_at > ^now),
      where:
        fragment(
          "(?, ?) IN ((?, ?), (?, ?), (?, ?), (?, ?), (?, ?))",
          alias_record.alias_kind,
          alias_record.alias_hash,
          ^kind_1,
          ^hash_1,
          ^kind_2,
          ^hash_2,
          ^kind_3,
          ^hash_3,
          ^kind_4,
          ^hash_4,
          ^kind_5,
          ^hash_5
        ),
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? = ? AND ? = ? THEN 1 WHEN ? = ? AND ? = ? THEN 2 WHEN ? = ? AND ? = ? THEN 3 WHEN ? = ? AND ? = ? THEN 4 WHEN ? = ? AND ? = ? THEN 5 ELSE 6 END",
            alias_record.alias_kind,
            ^kind_1,
            alias_record.alias_hash,
            ^hash_1,
            alias_record.alias_kind,
            ^kind_2,
            alias_record.alias_hash,
            ^hash_2,
            alias_record.alias_kind,
            ^kind_3,
            alias_record.alias_hash,
            ^hash_3,
            alias_record.alias_kind,
            ^kind_4,
            alias_record.alias_hash,
            ^hash_4,
            alias_record.alias_kind,
            ^kind_5,
            alias_record.alias_hash,
            ^hash_5
          ),
        desc: alias_record.last_seen_at,
        desc: alias_record.updated_at
      ],
      limit: 1,
      lock: "FOR UPDATE"
  end

  defp padded_hashed_candidates(candidates, size) do
    candidates
    |> Enum.map(fn {kind, value} -> {kind, alias_hash(value)} end)
    |> Kernel.++(List.duplicate({"", <<>>}, size))
    |> Enum.take(size)
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
    case CodexPooler.JSON.decode(body) do
      {:ok, decoded} -> response_id_from_decoded(decoded)
      {:error, _reason} -> nil
    end
  end

  defp response_id_from_sse_body(body) do
    body
    |> String.split("\n")
    |> Stream.filter(&String.starts_with?(&1, "data: "))
    |> Stream.map(&String.replace_prefix(&1, "data: ", ""))
    |> Stream.filter(&String.starts_with?(&1, "{"))
    |> Enum.find_value(fn payload ->
      case CodexPooler.JSON.decode(payload) do
        {:ok, decoded} -> response_id_from_decoded(decoded)
        {:error, _reason} -> nil
      end
    end)
  end

  defp response_id_from_decoded(%{"id" => id}) when is_binary(id), do: blank_to_nil(id)

  defp response_id_from_decoded(%{"response" => %{"id" => id}}) when is_binary(id),
    do: blank_to_nil(id)

  defp response_id_from_decoded(_decoded), do: nil

  defp known_serving_mode(mode) when mode in @serving_modes, do: mode
  defp known_serving_mode(_mode), do: nil

  defp alias_hash(value), do: :crypto.hash(:sha256, value)

  defp alias_preview(hash), do: hash |> Base.encode16(case: :lower) |> String.slice(0, 16)

  defp expired_alias_ttl_seconds, do: OperationalSettings.current().expired_alias_ttl_seconds

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
