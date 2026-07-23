defmodule CodexPooler.Gateway.Persistence.SessionContinuity do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    CodexSession,
    CodexTurn,
    SessionContinuity.Aliases,
    SessionContinuity.ExpiredSessions,
    SessionContinuity.OwnerLease,
    SessionContinuity.TurnLifecycle
  }

  alias CodexPooler.Repo

  @session_active CodexSession.active_status()
  @session_reconnectable_statuses CodexSession.reconnectable_statuses()
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

  @spec start_codex_session(auth(), opts()) :: session_result()
  def start_codex_session(auth, %RequestOptions{} = opts) do
    now = now()
    session_key = session_key(opts)
    owner = owner_instance_id(opts)

    Repo.transaction(fn ->
      session = upsert_session_for_start!(auth, opts, session_key, owner, now)
      lease = OwnerLease.acquire!(session, auth, opts, owner, now)
      Aliases.register!(session, auth, opts, now)
      OwnerLease.persist_session!(session, lease, now)
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

  @spec start_codex_session_from_turn_state(auth(), opts()) ::
          session_result() | {:error, :session_not_found}
  def start_codex_session_from_turn_state(auth, %RequestOptions{} = opts) do
    case blank_to_nil(opts.continuity.accepted_turn_state) do
      nil ->
        {:error, :session_not_found}

      turn_state ->
        start_codex_session_from_turn_state(auth, opts, turn_state)
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

  defp start_codex_session_from_turn_state(auth, opts, turn_state) do
    now = now()
    owner = owner_instance_id(opts)

    Repo.transaction(fn ->
      auth.pool.id
      |> Aliases.active_session_for_update(auth.api_key.id, "turn_state", turn_state, now)
      |> start_previous_response_session!(auth, opts, owner, now)
    end)
    |> unwrap_transaction()
  end

  defp previous_response_session_for_update(auth, previous_response_id, now) do
    Aliases.active_session_for_update(
      auth.pool.id,
      auth.api_key.id,
      "previous_response_id",
      previous_response_id,
      now
    )
  end

  defp start_previous_response_session!(%CodexSession{} = session, auth, opts, owner, now) do
    session = update_existing_session!(session, auth, opts, owner, now)
    lease = OwnerLease.acquire!(session, auth, opts, owner, now)
    Aliases.register!(session, auth, opts, now)
    OwnerLease.persist_session!(session, lease, now)
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
      session = codex_session_for_update!(session.id)
      auth = %{pool: %{id: session.pool_id}, api_key: %{id: session.api_key_id}}
      session = maybe_bind_session_assignment!(session, opts, now)

      continuity_opts = Aliases.continuity_opts(opts, payload, response_body)

      Aliases.register!(session, auth, continuity_opts, now)
      OwnerLease.renew!(session, opts, now)
      :ok
    end)
    |> unwrap_ok_transaction()
  end

  def register_codex_session_continuity(_session, _payload, _response_body, _opts),
    do: {:error, :invalid_session_continuity}

  @spec validate_owner_token(session_ref(), Ecto.UUID.t() | String.t()) :: owner_token_result()
  defdelegate validate_owner_token(session_ref, owner_lease_token), to: OwnerLease, as: :validate

  @spec renew_owner_token(session_ref(), Ecto.UUID.t() | String.t(), opts()) ::
          {:ok, CodexSession.t()} | {:error, :stale_owner | :owner_unavailable}
  defdelegate renew_owner_token(session_ref, owner_lease_token, opts), to: OwnerLease

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
  defdelegate release_owner_lease(session_ref, owner_lease_token, reason),
    to: OwnerLease,
    as: :release

  @spec release_owner_lease(
          session_ref(),
          Ecto.UUID.t() | String.t(),
          String.t(),
          :idle_expiry | :drain_cut | nil
        ) :: :ok | {:error, :stale_owner | :owner_unavailable}
  defdelegate release_owner_lease(session_ref, owner_lease_token, reason, owner_exit_cause),
    to: OwnerLease,
    as: :release

  @spec replace_unavailable_owner_lease(session_ref(), opts()) :: session_result()
  defdelegate replace_unavailable_owner_lease(session_ref, opts),
    to: OwnerLease,
    as: :replace_unavailable

  @spec codex_session_for_update!(Ecto.UUID.t()) :: CodexSession.t()
  defp codex_session_for_update!(session_id) do
    Repo.one!(
      from session in CodexSession,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
    )
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
    resolved_session = Aliases.resolved_session_for_update(auth, opts, session_key, now)

    if is_nil(resolved_session) do
      ExpiredSessions.close_for_key!(auth.pool.id, session_key, now)
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

  defp bridge_owner_lease_ttl_seconds(%RequestOptions{} = request_options) do
    case request_options.continuity.bridge_owner_lease_ttl_seconds do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _value -> OperationalSettings.current().bridge_owner_lease_ttl_seconds
    end
  end

  defp session_key(%RequestOptions{} = request_options) do
    request_options
    |> turn_state_session_key()
    |> Kernel.||(session_header_session_key(request_options))
    |> Kernel.||(request_options.continuity.session_key |> blank_to_nil())
    |> Kernel.||(Ecto.UUID.generate())
  end

  @spec turn_state_session_key(RequestOptions.t()) :: String.t() | nil
  defp turn_state_session_key(%RequestOptions{continuity: %{accepted_turn_state: turn_state}}) do
    case blank_to_nil(turn_state) do
      nil -> nil
      value -> "x-codex-turn-state:" <> safe_hash(value)
    end
  end

  defp session_header_session_key(%RequestOptions{
         continuity: %{session_header_source: "x-codex-window-id", session_header: session_header}
       }) do
    case blank_to_nil(session_header) do
      nil -> nil
      value -> "x-codex-window-id:" <> safe_hash(value)
    end
  end

  defp session_header_session_key(%RequestOptions{continuity: %{session_header: session_header}}) do
    blank_to_nil(session_header)
  end

  defp safe_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
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
end
