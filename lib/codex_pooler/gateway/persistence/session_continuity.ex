defmodule CodexPooler.Gateway.Persistence.SessionContinuity do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    SessionContinuity.TurnLifecycle
  }

  alias CodexPooler.Repo

  @session_active CodexSession.active_status()
  @session_closed CodexSession.closed_status()
  @session_reconnectable_statuses CodexSession.reconnectable_statuses()
  @lease_active BridgeOwnerLease.active_status()
  @lease_expired BridgeOwnerLease.expired_status()
  @lease_released BridgeOwnerLease.released_status()
  @alias_active BridgeSessionAlias.active_status()
  @alias_expired BridgeSessionAlias.expired_status()
  @type auth :: CodexPooler.Access.auth_context()
  @type opts :: RequestOptions.t()
  @type payload :: map()
  @type session_result :: {:ok, CodexSession.t()} | {:error, term()}
  @type turn_result :: {:ok, CodexTurn.t()} | {:error, term()}
  @type complete_turn_result ::
          {:ok, %{required(:request) => Request.t(), optional(:attempt) => Attempt.t() | nil}}
          | term()
  @type request_ref :: Request.t() | Ecto.UUID.t()
  @type owner_token_result :: :ok | {:error, :stale_owner | :owner_unavailable}
  @type session_ref :: CodexSession.t() | Ecto.UUID.t() | String.t()

  @session_start_conflict_error %{
    status: 409,
    code: "session_start_conflict",
    message: "Session start conflict",
    param: "session_id"
  }

  @session_alias_conflict_target {:unsafe_fragment,
                                  "(pool_id, api_key_id, alias_kind, alias_hash) WHERE status = 'active'"}

  @spec start_codex_session(auth(), opts()) :: session_result()
  def start_codex_session(auth, %RequestOptions{} = opts) do
    now = now()
    session_key = session_key(opts)
    owner = owner_instance_id(opts)

    Repo.transaction(fn ->
      session = upsert_session_for_start!(auth, opts, session_key, owner, now)
      lease = acquire_bridge_owner_lease!(session, auth, opts, owner, now)
      register_session_aliases!(session, auth, opts, now)
      persist_session_lease!(session, lease, now)
    end)
    |> unwrap_transaction()
  end

  @spec start_codex_session_from_previous_response_id(auth(), opts()) ::
          session_result() | {:error, :session_not_found}
  def start_codex_session_from_previous_response_id(auth, %RequestOptions{} = opts) do
    case blank_to_nil(opts.continuity.previous_response_id) do
      nil ->
        {:error, :session_not_found}

      previous_response_id ->
        start_codex_session_from_previous_response_id(auth, opts, previous_response_id)
    end
  end

  defp start_codex_session_from_previous_response_id(auth, opts, previous_response_id) do
    now = now()
    owner = owner_instance_id(opts)

    Repo.transaction(fn ->
      auth
      |> previous_response_session_for_update(previous_response_id, now)
      |> start_previous_response_session!(auth, opts, owner, now)
    end)
    |> unwrap_transaction()
  end

  defp previous_response_session_for_update(auth, previous_response_id, now) do
    active_alias_session_for_update(
      auth.pool.id,
      auth.api_key.id,
      "previous_response_id",
      previous_response_id,
      now
    )
  end

  defp start_previous_response_session!(%CodexSession{} = session, auth, opts, owner, now) do
    session = update_existing_session!(session, auth, opts, owner, now)
    lease = acquire_bridge_owner_lease!(session, auth, opts, owner, now)
    register_session_aliases!(session, auth, opts, now)
    persist_session_lease!(session, lease, now)
  end

  defp start_previous_response_session!(nil, _auth, _opts, _owner, _now),
    do: Repo.rollback(:session_not_found)

  @spec register_codex_session_continuity(
          CodexSession.t(),
          payload(),
          map() | binary(),
          opts()
        ) :: :ok | {:error, term()}

  def register_codex_session_continuity(
        %CodexSession{} = session,
        payload,
        response_body,
        %RequestOptions{} = opts
      )
      when is_map(payload) do
    now = now()

    Repo.transaction(fn ->
      session = Repo.get!(CodexSession, session.id, lock: "FOR UPDATE")
      auth = %{pool: %{id: session.pool_id}, api_key: %{id: session.api_key_id}}
      session = maybe_bind_session_assignment!(session, opts, now)

      continuity_opts = continuity_alias_opts(opts, payload, response_body)

      register_session_aliases!(session, auth, continuity_opts, now)
      renew_bridge_owner_lease!(session, opts, now)
      :ok
    end)
    |> unwrap_ok_transaction()
  end

  def register_codex_session_continuity(_session, _payload, _response_body, _opts),
    do: {:error, :invalid_session_continuity}

  @spec validate_owner_token(session_ref(), Ecto.UUID.t() | String.t()) :: owner_token_result()
  def validate_owner_token(session_ref, owner_lease_token) do
    now = now()

    case active_owner_lease_snapshot(session_ref) do
      {:ok, %CodexSession{} = session, %BridgeOwnerLease{} = lease} ->
        validate_owner_token_snapshot(session, lease, owner_lease_token, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec renew_owner_token(session_ref(), Ecto.UUID.t() | String.t(), opts()) ::
          {:ok, CodexSession.t()} | {:error, :stale_owner | :owner_unavailable}
  def renew_owner_token(session_ref, owner_lease_token, %RequestOptions{} = opts) do
    now = now()

    Repo.transaction(fn ->
      with {:ok, %CodexSession{} = session, %BridgeOwnerLease{} = lease} <-
             active_owner_lease_snapshot_for_update(session_ref),
           :ok <- validate_owner_token_snapshot(session, lease, owner_lease_token, now) do
        expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

        renewed_lease =
          lease
          |> Ecto.Changeset.change(%{renewed_at: now, expires_at: expires_at, updated_at: now})
          |> Repo.update!()

        session
        |> Ecto.Changeset.change(%{
          owner_instance_id: renewed_lease.owner_instance_id,
          owner_lease_token: renewed_lease.lease_token,
          owner_lease_expires_at: renewed_lease.expires_at,
          last_heartbeat_at: now,
          updated_at: now
        })
        |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_owner_token_renewal()
  end

  @spec duplicate_codex_turn?(CodexSession.t(), Ecto.UUID.t() | String.t()) :: boolean()
  defdelegate duplicate_codex_turn?(session, request_id), to: TurnLifecycle
  @spec start_codex_turn(CodexSession.t(), Request.t(), opts()) :: turn_result()
  defdelegate start_codex_turn(session, request, opts), to: TurnLifecycle
  @spec complete_codex_turn(complete_turn_result(), String.t(), term()) :: term()
  defdelegate complete_codex_turn(result, status, error_code), to: TurnLifecycle
  @spec mark_codex_turn_visible(request_ref()) :: :ok
  defdelegate mark_codex_turn_visible(request_ref), to: TurnLifecycle

  @spec release_owner_lease(session_ref(), Ecto.UUID.t() | String.t(), String.t()) ::
          :ok | {:error, :stale_owner | :owner_unavailable}
  def release_owner_lease(session_ref, owner_lease_token, reason) when is_binary(reason) do
    now = now()

    Repo.transaction(fn ->
      with {:ok, session_id} <- session_id(session_ref),
           %BridgeOwnerLease{} = lease <- owner_lease_for_update(session_id, owner_lease_token) do
        release_owner_lease!(lease, reason, now)
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(owner_release_missing_reason(session_ref))
      end
    end)
    |> unwrap_ok_transaction()
  end

  def release_owner_lease(_session_ref, _owner_lease_token, _reason),
    do: {:error, :owner_unavailable}

  @spec replace_unavailable_owner_lease(session_ref(), opts()) :: session_result()
  def replace_unavailable_owner_lease(session_ref, %RequestOptions{} = opts) do
    now = now()
    owner = owner_instance_id(opts)
    expected_owner = expected_owner_snapshot(session_ref)

    Repo.transaction(fn ->
      with {:ok, session_id} <- session_id(session_ref),
           %CodexSession{} = session <- Repo.get(CodexSession, session_id, lock: "FOR UPDATE"),
           :ok <- validate_expected_owner_snapshot(session, expected_owner) do
        replace_unavailable_owner_lease!(session, owner, opts, now)
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(:owner_unavailable)
      end
    end)
    |> unwrap_transaction()
  end

  defp upsert_session_for_start!(auth, opts, session_key, owner, now) do
    existing_session = existing_session_for_start!(auth, opts, session_key, now)

    case existing_session do
      %CodexSession{} = session ->
        update_existing_session!(session, auth, opts, owner, now)

      nil ->
        maybe_test_block_before_session_insert()
        insert_new_session!(auth, opts, session_key, owner, now)
    end
  end

  defp existing_session_for_start!(auth, opts, session_key, now) do
    resolved_session = resolved_session_for_update(auth, opts, session_key, now)

    if is_nil(resolved_session) do
      close_expired_sessions!(auth.pool.id, session_key, now)
    end

    reject_blocked_authenticated_owner_attach!(auth, opts, session_key, now, resolved_session)

    existing_session = resolved_session || active_session_for_update(auth, opts, session_key, now)

    if is_nil(existing_session) and authenticated_owner_attach_requires_existing?(opts) do
      Repo.rollback(:owner_unavailable)
    end

    existing_session
  end

  defp reject_blocked_authenticated_owner_attach!(auth, opts, session_key, now, nil) do
    if authenticated_owner_attach_blocked?(auth, opts, session_key, now) do
      Repo.rollback(:owner_unavailable)
    end
  end

  defp reject_blocked_authenticated_owner_attach!(
         _auth,
         _opts,
         _session_key,
         _now,
         %CodexSession{}
       ),
       do: :ok

  defp update_existing_session!(%CodexSession{} = session, auth, opts, owner, now) do
    session
    |> Ecto.Changeset.change(%{
      api_key_id: auth.api_key.id,
      status: @session_active,
      owner_instance_id: owner,
      owner_lease_token: session.owner_lease_token || Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second),
      last_heartbeat_at: now,
      disconnected_at: nil,
      closed_at: nil,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp insert_new_session!(auth, opts, session_key, owner, now) do
    attrs = %{
      pool_id: auth.pool.id,
      api_key_id: auth.api_key.id,
      session_key: session_key,
      conversation_key: conversation_key(opts),
      status: @session_active,
      owner_instance_id: owner,
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    }

    %CodexSession{}
    |> session_start_changeset(attrs)
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, %CodexSession{} = session} ->
        session

      {:error, %Ecto.Changeset{} = changeset} ->
        recover_session_start_conflict!(changeset, auth, opts, session_key, owner, now)
    end
  end

  defp session_start_changeset(%CodexSession{} = session, attrs) do
    session
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:session_key,
      name: :codex_sessions_pool_session_key_uq
    )
  end

  defp recover_session_start_conflict!(changeset, auth, opts, session_key, owner, now) do
    if session_key_unique_constraint?(changeset) do
      case active_session_for_update(auth, opts, session_key, now) do
        %CodexSession{} = session ->
          Logger.info(
            "session_start_conflict_recovered reason=codex_sessions_pool_session_key_uq outcome=reused_existing_session"
          )

          update_existing_session!(session, auth, opts, owner, now)

        nil ->
          Repo.rollback(@session_start_conflict_error)
      end
    else
      Repo.rollback(changeset)
    end
  end

  defp session_key_unique_constraint?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.constraints, fn constraint ->
      constraint.type == :unique and constraint.constraint == "codex_sessions_pool_session_key_uq"
    end) and
      Keyword.has_key?(changeset.errors, :session_key)
  end

  if Mix.env() == :test do
    defp maybe_test_block_before_session_insert do
      case Process.get({__MODULE__, :before_session_insert_barrier}) do
        {owner_pid, ref} when is_pid(owner_pid) ->
          send(owner_pid, {:session_insert_ready, ref, self()})

          receive do
            {:session_insert_release, ^ref} -> :ok
          end

        _value ->
          :ok
      end
    end
  else
    defp maybe_test_block_before_session_insert, do: :ok
  end

  defp persist_session_lease!(%CodexSession{} = session, %BridgeOwnerLease{} = lease, now) do
    session
    |> Ecto.Changeset.change(%{
      owner_instance_id: lease.owner_instance_id,
      owner_lease_token: lease.lease_token,
      owner_lease_expires_at: lease.expires_at,
      last_heartbeat_at: now,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp maybe_bind_session_assignment!(%CodexSession{} = session, opts, now) do
    case pool_upstream_assignment_id(opts) do
      assignment_id when is_binary(assignment_id) ->
        bind_session_assignment!(session, assignment_id, now)

      _value ->
        session
    end
  end

  defp bind_session_assignment!(
         %CodexSession{pool_upstream_assignment_id: assignment_id} = session,
         assignment_id,
         _now
       )
       when is_binary(assignment_id),
       do: session

  defp bind_session_assignment!(
         %CodexSession{pool_upstream_assignment_id: nil} = session,
         assignment_id,
         now
       ) do
    session
    |> Ecto.Changeset.change(%{
      pool_upstream_assignment_id: assignment_id,
      last_heartbeat_at: now,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp bind_session_assignment!(%CodexSession{} = session, _assignment_id, _now), do: session

  defp resolved_session_for_update(auth, opts, session_key, now) do
    alias_candidates(opts, session_key)
    |> Enum.find_value(fn {kind, value} ->
      active_alias_session_for_update(auth.pool.id, auth.api_key.id, kind, value, now)
    end)
  end

  defp active_alias_session_for_update(pool_id, api_key_id, alias_kind, alias_value, now) do
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

  defp maybe_require_active_owner_lease(query, "previous_response_id", _now), do: query

  defp maybe_require_active_owner_lease(query, _alias_kind, now) do
    where(query, [session], session.owner_lease_expires_at > ^now)
  end

  defp acquire_bridge_owner_lease!(%CodexSession{} = session, auth, opts, owner, now) do
    expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

    BridgeOwnerLease
    |> where(
      [lease],
      lease.codex_session_id == ^session.id and lease.status == ^@lease_active and
        lease.expires_at <= ^now
    )
    |> Repo.update_all(set: [status: @lease_expired, released_at: now, updated_at: now])

    case active_bridge_owner_lease_for_update(session.id) do
      %BridgeOwnerLease{owner_instance_id: ^owner} = lease ->
        lease
        |> Ecto.Changeset.change(%{
          pool_upstream_assignment_id: session.pool_upstream_assignment_id,
          renewed_at: now,
          expires_at: expires_at,
          updated_at: now
        })
        |> Repo.update!()

      %BridgeOwnerLease{} = lease ->
        lease

      nil ->
        %BridgeOwnerLease{}
        |> BridgeOwnerLease.changeset(%{
          codex_session_id: session.id,
          pool_id: auth.pool.id,
          api_key_id: auth.api_key.id,
          pool_upstream_assignment_id: session.pool_upstream_assignment_id,
          owner_instance_id: owner,
          lease_token: Ecto.UUID.generate(),
          status: @lease_active,
          acquired_at: now,
          renewed_at: now,
          expires_at: expires_at,
          metadata: %{"source" => "gateway_session"},
          created_at: now,
          updated_at: now
        })
        |> Repo.insert!()
    end
  end

  defp active_bridge_owner_lease_for_update(session_id) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == ^@lease_active,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp owner_lease_for_update(session_id, owner_lease_token) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.lease_token == ^owner_lease_token,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp release_owner_lease!(%BridgeOwnerLease{status: @lease_released}, _reason, _now), do: :ok

  defp release_owner_lease!(%BridgeOwnerLease{} = lease, reason, now) do
    metadata =
      lease.metadata
      |> normalize_metadata()
      |> Map.put("release_reason", reason)

    lease
    |> Ecto.Changeset.change(%{
      status: @lease_released,
      released_at: lease.released_at || now,
      metadata: metadata,
      updated_at: now
    })
    |> Repo.update!()

    :ok
  end

  defp replace_unavailable_owner_lease!(%CodexSession{status: status} = session, owner, opts, now)
       when status in @session_reconnectable_statuses do
    release_active_owner_lease_for_takeover!(session.id, now)

    session
    |> insert_takeover_owner_lease!(owner, opts, now)
    |> then(&persist_session_lease!(session, &1, now))
  end

  defp replace_unavailable_owner_lease!(%CodexSession{}, _owner, _opts, _now) do
    Repo.rollback(:owner_unavailable)
  end

  defp release_active_owner_lease_for_takeover!(session_id, now) do
    case active_bridge_owner_lease_for_update(session_id) do
      %BridgeOwnerLease{} = lease ->
        release_owner_lease!(lease, "owner_unavailable_takeover", now)

      nil ->
        :ok
    end
  end

  defp insert_takeover_owner_lease!(%CodexSession{} = session, owner, opts, now) do
    expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

    %BridgeOwnerLease{}
    |> BridgeOwnerLease.changeset(%{
      codex_session_id: session.id,
      pool_id: session.pool_id,
      api_key_id: session.api_key_id,
      pool_upstream_assignment_id: session.pool_upstream_assignment_id,
      owner_instance_id: owner,
      lease_token: Ecto.UUID.generate(),
      status: @lease_active,
      acquired_at: now,
      renewed_at: now,
      expires_at: expires_at,
      metadata: %{"source" => "owner_unavailable_takeover"},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp expected_owner_snapshot(%CodexSession{} = session) do
    %{owner_instance_id: session.owner_instance_id, owner_lease_token: session.owner_lease_token}
  end

  defp expected_owner_snapshot(_session_ref), do: nil

  defp validate_expected_owner_snapshot(_session, nil), do: :ok

  defp validate_expected_owner_snapshot(%CodexSession{} = session, expected) do
    if session.owner_instance_id == expected.owner_instance_id and
         session.owner_lease_token == expected.owner_lease_token,
       do: :ok,
       else: {:error, :stale_owner}
  end

  defp owner_release_missing_reason(session_ref) do
    with {:ok, session_id} <- session_id(session_ref),
         %BridgeOwnerLease{} <- active_bridge_owner_lease_for_update(session_id) do
      :stale_owner
    else
      _missing -> :owner_unavailable
    end
  end

  defp active_owner_lease_snapshot(session_ref) do
    with {:ok, session_id} <- session_id(session_ref),
         %CodexSession{} = session <- Repo.get(CodexSession, session_id),
         %BridgeOwnerLease{} = lease <- active_bridge_owner_lease(session.id) do
      {:ok, session, lease}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :owner_unavailable}
    end
  end

  defp active_owner_lease_snapshot_for_update(session_ref) do
    with {:ok, session_id} <- session_id(session_ref),
         %CodexSession{} = session <- Repo.get(CodexSession, session_id, lock: "FOR UPDATE"),
         %BridgeOwnerLease{} = lease <- active_bridge_owner_lease_for_update(session.id) do
      {:ok, session, lease}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :owner_unavailable}
    end
  end

  defp active_bridge_owner_lease(session_id) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == ^@lease_active,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1
    )
  end

  defp validate_owner_token_snapshot(
         %CodexSession{} = session,
         %BridgeOwnerLease{} = lease,
         owner_lease_token,
         now
       ) do
    cond do
      session.status not in @session_reconnectable_statuses ->
        {:error, :owner_unavailable}

      expired_at?(session.owner_lease_expires_at, now) or expired_at?(lease.expires_at, now) ->
        {:error, :owner_unavailable}

      session.owner_lease_token != owner_lease_token or lease.lease_token != owner_lease_token ->
        {:error, :stale_owner}

      true ->
        :ok
    end
  end

  defp session_id(%CodexSession{id: id}) when is_binary(id), do: {:ok, id}

  defp session_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :owner_unavailable}
    end
  end

  defp session_id(_session_ref), do: {:error, :owner_unavailable}

  defp expired_at?(%DateTime{} = expires_at, now), do: DateTime.compare(expires_at, now) != :gt
  defp expired_at?(_expires_at, _now), do: true

  defp renew_bridge_owner_lease!(%CodexSession{} = session, opts, now) do
    case active_bridge_owner_lease_for_update(session.id) do
      %BridgeOwnerLease{} = lease ->
        expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

        lease
        |> Ecto.Changeset.change(%{renewed_at: now, expires_at: expires_at, updated_at: now})
        |> Repo.update!()

      nil ->
        :ok
    end
  end

  defp register_session_aliases!(%CodexSession{} = session, auth, opts, now) do
    alias_candidates(opts, session.session_key)
    |> Enum.each(fn {alias_kind, alias_value} ->
      upsert_session_alias!(session, auth, alias_kind, alias_value, now)
    end)
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

  defp active_session_for_update(auth, opts, session_key, now) do
    query =
      from session in CodexSession,
        where:
          session.pool_id == ^auth.pool.id and
            fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
            session.status in ^@session_reconnectable_statuses and
            (is_nil(session.owner_lease_expires_at) or session.owner_lease_expires_at > ^now),
        order_by: [desc: session.updated_at, desc: session.created_at],
        limit: 1,
        lock: "FOR UPDATE"

    query
    |> maybe_scope_owner_attach_to_api_key(auth, opts)
    |> Repo.one()
  end

  defp maybe_scope_owner_attach_to_api_key(query, auth, %RequestOptions{
         continuity: %{authenticated_owner_attach: true}
       }) do
    where(query, [session], session.api_key_id == ^auth.api_key.id)
  end

  defp maybe_scope_owner_attach_to_api_key(query, _auth, _opts), do: query

  defp authenticated_owner_attach_blocked?(
         auth,
         %RequestOptions{
           continuity: %{authenticated_owner_attach: true}
         },
         session_key,
         now
       ) do
    CodexSession
    |> where(
      [session],
      session.pool_id == ^auth.pool.id and
        session.api_key_id != ^auth.api_key.id and
        fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
        session.status in ^@session_reconnectable_statuses and
        (is_nil(session.owner_lease_expires_at) or session.owner_lease_expires_at > ^now)
    )
    |> limit(1)
    |> Repo.exists?()
  end

  defp authenticated_owner_attach_blocked?(_auth, _opts, _session_key, _now), do: false

  defp authenticated_owner_attach_requires_existing?(%RequestOptions{
         continuity: %{
           authenticated_owner_attach: true,
           accepted_turn_state: nil,
           previous_response_id: previous_response_id,
           session_header: session_header
         }
       }) do
    not is_nil(blank_to_nil(previous_response_id)) or not is_nil(blank_to_nil(session_header))
  end

  defp authenticated_owner_attach_requires_existing?(_opts), do: false

  defp close_expired_sessions!(pool_id, session_key, now) do
    expired_sessions =
      from session in CodexSession,
        where:
          session.pool_id == ^pool_id and
            fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
            session.status in ^@session_reconnectable_statuses and
            not is_nil(session.owner_lease_expires_at) and
            session.owner_lease_expires_at <= ^now,
        select: session.id

    BridgeOwnerLease
    |> where(
      [lease],
      lease.codex_session_id in subquery(expired_sessions) and lease.status == ^@lease_active
    )
    |> Repo.update_all(set: [status: @lease_expired, released_at: now, updated_at: now])

    BridgeSessionAlias
    |> where(
      [alias_record],
      alias_record.codex_session_id in subquery(expired_sessions) and
        alias_record.status == ^@alias_active
    )
    |> Repo.update_all(set: [status: @alias_expired, updated_at: now])

    CodexSession
    |> where([session], session.id in subquery(expired_sessions))
    |> Repo.update_all(set: [status: @session_closed, closed_at: now, updated_at: now])
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

  defp continuity_alias_opts(%RequestOptions{} = request_options, payload, response_body) do
    request_options
    |> ContinuityPayload.put_previous_response_id(payload)
    |> RequestOptions.put_continuity(response_id: response_id_from_body(response_body))
  end

  defp bridge_owner_lease_ttl_seconds(%RequestOptions{} = request_options) do
    case request_options.continuity.bridge_owner_lease_ttl_seconds do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _value -> OperationalSettings.current().bridge_owner_lease_ttl_seconds
    end
  end

  defp expired_alias_ttl_seconds, do: OperationalSettings.current().expired_alias_ttl_seconds

  defp session_key(%RequestOptions{} = request_options) do
    request_options.continuity.accepted_turn_state
    |> blank_to_nil()
    |> Kernel.||(request_options.continuity.session_header |> blank_to_nil())
    |> Kernel.||(request_options.continuity.session_key |> blank_to_nil())
    |> Kernel.||(Ecto.UUID.generate())
  end

  defp conversation_key(%RequestOptions{} = request_options) do
    request_options.continuity.conversation_key |> blank_to_nil()
  end

  defp owner_instance_id(%RequestOptions{} = request_options) do
    request_options.continuity.owner_instance_id
    |> blank_to_nil()
    |> Kernel.||(Atom.to_string(node()))
  end

  defp pool_upstream_assignment_id(%RequestOptions{} = request_options) do
    request_options.file_bridge.pool_upstream_assignment_id
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unwrap_ok_transaction({:ok, :ok}), do: :ok
  defp unwrap_ok_transaction({:error, reason}), do: {:error, reason}

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp unwrap_owner_token_renewal({:ok, %CodexSession{} = session}), do: {:ok, session}
  defp unwrap_owner_token_renewal({:error, reason}), do: {:error, reason}
end
