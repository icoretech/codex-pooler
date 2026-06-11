defmodule CodexPooler.Gateway.Persistence.SessionContinuity.OwnerLease do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession
  }

  alias CodexPooler.Repo

  @type owner_token_result :: :ok | {:error, :stale_owner | :owner_unavailable}
  @type session_ref :: CodexSession.t() | Ecto.UUID.t() | String.t()

  @session_reconnectable_statuses CodexSession.reconnectable_statuses()
  @lease_active BridgeOwnerLease.active_status()
  @lease_expired BridgeOwnerLease.expired_status()
  @lease_released BridgeOwnerLease.released_status()

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

  @spec renew!(CodexSession.t(), RequestOptions.t(), DateTime.t()) :: BridgeOwnerLease.t() | :ok
  def renew!(%CodexSession{} = session, %RequestOptions{} = opts, now) do
    case active_for_update(session.id) do
      %BridgeOwnerLease{} = lease ->
        expires_at = DateTime.add(now, bridge_owner_lease_ttl_seconds(opts), :second)

        lease
        |> Ecto.Changeset.change(%{renewed_at: now, expires_at: expires_at, updated_at: now})
        |> Repo.update!()

      nil ->
        :ok
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
  def renew_owner_token(session_ref, owner_lease_token, %RequestOptions{} = opts) do
    now = now()

    Repo.transaction(fn ->
      with {:ok, %CodexSession{} = session, %BridgeOwnerLease{} = lease} <-
             active_snapshot_for_update(session_ref),
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

  @spec release(session_ref(), Ecto.UUID.t() | String.t(), String.t()) ::
          :ok | {:error, :stale_owner | :owner_unavailable}
  def release(session_ref, owner_lease_token, reason) when is_binary(reason) do
    now = now()

    Repo.transaction(fn ->
      with {:ok, session_id} <- session_id(session_ref),
           %BridgeOwnerLease{} = lease <- for_update(session_id, owner_lease_token) do
        release!(lease, reason, now)
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(owner_release_missing_reason(session_ref))
      end
    end)
    |> unwrap_ok_transaction()
  end

  def release(_session_ref, _owner_lease_token, _reason), do: {:error, :owner_unavailable}

  @spec replace_unavailable(session_ref(), RequestOptions.t()) ::
          {:ok, CodexSession.t()} | {:error, term()}
  def replace_unavailable(session_ref, %RequestOptions{} = opts) do
    now = now()
    owner = owner_instance_id(opts)
    expected_owner = expected_owner_snapshot(session_ref)

    Repo.transaction(fn ->
      with {:ok, session_id} <- session_id(session_ref),
           %CodexSession{} = session <- Repo.get(CodexSession, session_id, lock: "FOR UPDATE"),
           :ok <- validate_expected_owner_snapshot(session, expected_owner) do
        replace_unavailable!(session, owner, opts, now)
      else
        {:error, reason} -> Repo.rollback(reason)
        nil -> Repo.rollback(:owner_unavailable)
      end
    end)
    |> unwrap_transaction()
  end

  @spec expire_active_for_sessions!(Ecto.Queryable.t(), DateTime.t()) ::
          {non_neg_integer(), nil | [term()]}
  def expire_active_for_sessions!(expired_sessions, now) do
    BridgeOwnerLease
    |> where(
      [lease],
      lease.codex_session_id in subquery(expired_sessions) and lease.status == ^@lease_active
    )
    |> Repo.update_all(set: [status: @lease_expired, released_at: now, updated_at: now])
  end

  defp active_for_update(session_id) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == ^@lease_active,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1,
        lock: "FOR UPDATE"
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

  defp release!(%BridgeOwnerLease{status: @lease_released}, _reason, _now), do: :ok

  defp release!(%BridgeOwnerLease{} = lease, reason, now) do
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
        release!(lease, "owner_unavailable_takeover", now)

      nil ->
        :ok
    end
  end

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

  defp active_snapshot_for_update(session_ref) do
    with {:ok, session_id} <- session_id(session_ref),
         %CodexSession{} = session <- Repo.get(CodexSession, session_id, lock: "FOR UPDATE"),
         %BridgeOwnerLease{} = lease <- active_for_update(session.id) do
      {:ok, session, lease}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :owner_unavailable}
    end
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

  defp unwrap_ok_transaction({:ok, :ok}), do: :ok
  defp unwrap_ok_transaction({:error, reason}), do: {:error, reason}

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp unwrap_owner_token_renewal({:ok, %CodexSession{} = session}), do: {:ok, session}
  defp unwrap_owner_token_renewal({:error, reason}), do: {:error, reason}
end
