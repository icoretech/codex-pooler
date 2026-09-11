defmodule CodexPooler.Gateway.Persistence.SessionContinuity.OwnerLease do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession
  }

  alias CodexPooler.Gateway.Persistence.SessionContinuity.LockWaitDiagnostics
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease, as: OwnerLeaseStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Repo

  @type owner_token_result :: :ok | {:error, :stale_owner | :owner_unavailable}
  @type renewal_option :: {:lock_timeout_ms, pos_integer()}
  @type session_ref :: CodexSession.t() | Ecto.UUID.t() | String.t()

  @session_reconnectable_statuses SessionStatus.reconnectable_statuses()
  @lease_active OwnerLeaseStatus.active_status()
  @lease_expired OwnerLeaseStatus.expired_status()
  @lease_released OwnerLeaseStatus.released_status()

  @spec acquire!(CodexSession.t(), map(), RequestOptions.t(), String.t(), DateTime.t()) ::
          BridgeOwnerLease.t()
  def acquire!(%CodexSession{} = session, auth, %RequestOptions{} = opts, owner, now) do
    expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

    BridgeOwnerLease
    |> where(
      [lease],
      lease.codex_session_id == ^session.id and lease.status == ^@lease_active and
        lease.expires_at <= ^now
    )
    |> Repo.update_all(set: [status: @lease_expired, released_at: now, updated_at: now])

    case active_for_update(session.id) do
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

  @spec persist_session!(CodexSession.t(), BridgeOwnerLease.t(), DateTime.t()) :: CodexSession.t()
  def persist_session!(%CodexSession{} = session, %BridgeOwnerLease{} = lease, now) do
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

  @spec renew_locked!(CodexSession.t(), RequestOptions.t()) :: CodexSession.t()
  def renew_locked!(%CodexSession{} = session, %RequestOptions{} = opts) do
    case active_for_update(session.id) do
      %BridgeOwnerLease{} = lease ->
        now = db_now()

        case validate_owner_token_snapshot(session, lease, session.owner_lease_token, now) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

        renewed_lease =
          lease
          |> Ecto.Changeset.change(%{renewed_at: now, expires_at: expires_at, updated_at: now})
          |> Repo.update!()

        persist_session!(session, renewed_lease, now)

      nil ->
        Repo.rollback(:owner_unavailable)
    end
  end

  @spec validate(session_ref(), Ecto.UUID.t() | String.t()) :: owner_token_result()
  def validate(session_ref, owner_lease_token) do
    now = now()

    case active_snapshot(session_ref) do
      {:ok, %CodexSession{} = session, %BridgeOwnerLease{} = lease} ->
        validate_owner_token_snapshot(session, lease, owner_lease_token, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec renew_owner_token(session_ref(), Ecto.UUID.t() | String.t(), RequestOptions.t()) ::
          {:ok, CodexSession.t()} | {:error, :stale_owner | :owner_unavailable}
  def renew_owner_token(session_ref, owner_lease_token, %RequestOptions{} = opts),
    do: renew_owner_token(session_ref, owner_lease_token, opts, [])

  # `lock_timeout_ms` bounds the total time the renewal may wait for the session
  # and lease row locks. PostgreSQL applies `lock_timeout` per statement, so the
  # remaining budget is set again before each lock wait; exhausting it rolls the
  # renewal back cleanly as `:lock_timeout` instead of leaving the caller to kill
  # a process that is still inside the transaction. The timed-out lock statement
  # runs in a savepoint, so the still-open transaction can name the holder in
  # the returned lock-wait diagnostics before it rolls back.
  @spec renew_owner_token(
          session_ref(),
          Ecto.UUID.t() | String.t(),
          RequestOptions.t(),
          [renewal_option()]
        ) ::
          {:ok, CodexSession.t()}
          | {:error, :stale_owner | :owner_unavailable | {:lock_timeout, LockWaitDiagnostics.t()}}
  def renew_owner_token(session_ref, owner_lease_token, %RequestOptions{} = opts, renewal_opts)
      when is_list(renewal_opts) do
    lock_deadline = lock_deadline(renewal_opts)

    Repo.transaction(fn ->
      with {:ok, %CodexSession{} = session, %BridgeOwnerLease{} = lease} <-
             active_snapshot_for_update(session_ref, lock_deadline),
           now <- db_now(),
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
          owner_lease_expires_at: expires_at,
          last_heartbeat_at: now,
          updated_at: now
        })
        |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_owner_token_renewal()
  rescue
    error in Postgrex.Error ->
      if lock_timeout_error?(error, renewal_opts),
        do: {:error, {:lock_timeout, LockWaitDiagnostics.unresolved(:unknown)}},
        else: reraise(error, __STACKTRACE__)
  end

  @spec release(session_ref(), Ecto.UUID.t() | String.t(), String.t()) ::
          :ok | {:error, :stale_owner | :owner_unavailable}
  def release(session_ref, owner_lease_token, reason) when is_binary(reason) do
    release(session_ref, owner_lease_token, reason, nil)
  end

  def release(_session_ref, _owner_lease_token, _reason), do: {:error, :owner_unavailable}

  @spec release(
          session_ref(),
          Ecto.UUID.t() | String.t(),
          String.t(),
          :idle_expiry | :drain_cut | nil
        ) :: :ok | {:error, :stale_owner | :owner_unavailable}
  def release(session_ref, owner_lease_token, reason, owner_exit_cause)
      when is_binary(reason) and owner_exit_cause in [:idle_expiry, :drain_cut, nil] do
    now = now()

    Repo.transaction(fn ->
      with {:ok, session_id} <- session_id(session_ref),
           %BridgeOwnerLease{} = lease <- for_update(session_id, owner_lease_token) do
        release!(lease, reason, owner_exit_cause, now)
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(owner_release_missing_reason(session_ref))
      end
    end)
    |> unwrap_ok_transaction()
  end

  def release(_session_ref, _owner_lease_token, _reason, _owner_exit_cause),
    do: {:error, :owner_unavailable}

  @spec replace_unavailable(session_ref(), RequestOptions.t()) ::
          {:ok, CodexSession.t()} | {:error, term()}
  def replace_unavailable(session_ref, %RequestOptions{} = opts) do
    now = now()
    owner = owner_instance_id(opts)
    expected_owner = expected_owner_snapshot(session_ref)

    Repo.transaction(fn ->
      with {:ok, session_id} <- session_id(session_ref),
           %CodexSession{} = session <- codex_session_for_update(session_id),
           :ok <- validate_expected_owner_snapshot(session, expected_owner) do
        replace_unavailable!(session, owner, opts, now)
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(:owner_unavailable)
      end
    end)
    |> unwrap_transaction()
  end

  defp active_for_update(session_id, opts \\ []) do
    Repo.one(
      from(lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == ^@lease_active,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1,
        lock: "FOR UPDATE"
      ),
      opts
    )
  end

  defp for_update(session_id, owner_lease_token) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.lease_token == ^owner_lease_token,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp release!(%BridgeOwnerLease{status: @lease_released}, _reason, _owner_exit_cause, _now),
    do: :ok

  defp release!(%BridgeOwnerLease{} = lease, reason, owner_exit_cause, now) do
    metadata =
      lease.metadata
      |> normalize_metadata()
      |> Map.put("release_reason", reason)
      |> maybe_put_owner_exit_cause(owner_exit_cause)

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

  defp replace_unavailable!(%CodexSession{status: status} = session, owner, opts, now)
       when status in @session_reconnectable_statuses do
    release_active_for_takeover!(session.id, now)

    session
    |> insert_takeover!(owner, opts, now)
    |> then(&persist_session!(session, &1, now))
  end

  defp replace_unavailable!(%CodexSession{}, _owner, _opts, _now) do
    Repo.rollback(:owner_unavailable)
  end

  defp release_active_for_takeover!(session_id, now) do
    case active_for_update(session_id) do
      %BridgeOwnerLease{} = lease ->
        release!(lease, "owner_unavailable_takeover", nil, now)

      nil ->
        :ok
    end
  end

  defp maybe_put_owner_exit_cause(metadata, owner_exit_cause)
       when owner_exit_cause in [:idle_expiry, :drain_cut] do
    Map.put(metadata, "owner_exit_cause", Atom.to_string(owner_exit_cause))
  end

  defp maybe_put_owner_exit_cause(metadata, nil), do: metadata

  defp insert_takeover!(%CodexSession{} = session, owner, opts, now) do
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
         %BridgeOwnerLease{} <- active_for_update(session_id) do
      :stale_owner
    else
      _missing -> :owner_unavailable
    end
  end

  defp active_snapshot(session_ref) do
    with {:ok, session_id} <- session_id(session_ref),
         %CodexSession{} = session <- Repo.get(CodexSession, session_id),
         %BridgeOwnerLease{} = lease <- active(session.id) do
      {:ok, session, lease}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :owner_unavailable}
    end
  end

  defp active_snapshot_for_update(session_ref, lock_deadline) do
    with {:ok, session_id} <- session_id(session_ref),
         :ok <- put_lock_timeout(lock_deadline, :codex_sessions),
         {:ok, %CodexSession{} = session} <-
           row_lock(lock_deadline, :codex_sessions, session_id, &codex_session_for_update/2),
         :ok <- put_lock_timeout(lock_deadline, :bridge_owner_leases),
         {:ok, %BridgeOwnerLease{} = lease} <-
           row_lock(lock_deadline, :bridge_owner_leases, session.id, &active_for_update/2) do
      {:ok, session, lease}
    else
      {:error, reason} -> {:error, reason}
      {:ok, nil} -> {:error, :owner_unavailable}
    end
  end

  defp row_lock(nil, _relation, session_id, lock), do: {:ok, lock.(session_id, [])}

  defp row_lock(_lock_deadline, relation, session_id, lock) do
    {:ok, lock.(session_id, mode: :savepoint)}
  rescue
    error in Postgrex.Error ->
      if lock_not_available?(error),
        do: {:error, {:lock_timeout, LockWaitDiagnostics.capture(relation, session_id)}},
        else: reraise(error, __STACKTRACE__)
  end

  @spec codex_session_for_update(Ecto.UUID.t(), keyword()) :: CodexSession.t() | nil
  defp codex_session_for_update(session_id, opts \\ []) do
    Repo.one(
      from(session in CodexSession,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
      ),
      opts
    )
  end

  defp active(session_id) do
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

  defp bridge_owner_lease_ttl_seconds(%RequestOptions{} = request_options) do
    case request_options.continuity.bridge_owner_lease_ttl_seconds do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _value -> OperationalSettings.current().bridge_owner_lease_ttl_seconds
    end
  end

  defp owner_instance_id(%RequestOptions{} = request_options) do
    request_options.continuity.owner_instance_id
    |> blank_to_nil()
    |> Kernel.||(Atom.to_string(node()))
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end

  defp lock_deadline(renewal_opts) do
    case Keyword.get(renewal_opts, :lock_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 ->
        System.monotonic_time(:millisecond) + timeout

      _no_bound ->
        nil
    end
  end

  defp put_lock_timeout(nil, _relation), do: :ok

  defp put_lock_timeout(deadline, relation) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        _result =
          Repo.query!("SELECT set_config('lock_timeout', $1, true)", ["#{remaining}ms"])

        :ok

      _exhausted ->
        {:error, {:lock_timeout, LockWaitDiagnostics.unresolved(relation)}}
    end
  end

  defp lock_timeout_error?(%Postgrex.Error{} = error, renewal_opts),
    do: lock_not_available?(error) and not is_nil(lock_deadline(renewal_opts))

  defp lock_not_available?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_not_available?(%Postgrex.Error{}), do: false

  defp unwrap_ok_transaction({:ok, :ok}), do: :ok
  defp unwrap_ok_transaction({:error, reason}), do: {:error, reason}

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp unwrap_owner_token_renewal({:ok, %CodexSession{} = session}), do: {:ok, session}
  defp unwrap_owner_token_renewal({:error, reason}), do: {:error, reason}
end
