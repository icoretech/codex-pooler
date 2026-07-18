defmodule CodexPooler.Access.DashboardSessions do
  @moduledoc """
  Issues and authenticates API-key dashboard browser sessions.

  Browser tokens are returned only at issuance. Persistence contains only a
  SHA-256 digest and absolute expiry, while every authentication reads current
  API-key and Pool eligibility from PostgreSQL.
  """

  import Ecto.Query

  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Access.APIKeys.Material
  alias CodexPooler.Access.DashboardSessions.{Authentication, Principal}
  alias CodexPooler.Events
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @token_bytes 32
  @token_hash_bytes 32
  @dummy_api_key_hash :crypto.hash(:sha256, "dashboard-authentication-dummy")
  @invalid_key_prefix "sk-cxp-invalid-dashboard-session"
  @invalid_key_secret "dashboard-session-invalid-secret"
  @invalid_pool_id "00000000-0000-0000-0000-000000000000"
  @ttl_seconds 14 * 24 * 60 * 60
  @maximum_active_sessions 10
  @invalid_credentials {:error, :invalid_dashboard_credentials}
  @invalid_session {:error, :invalid_dashboard_session}

  @type issue_result ::
          {:ok, %{required(:token) => String.t(), required(:expires_at) => DateTime.t()}}
          | {:error, :invalid_dashboard_credentials | Ecto.Changeset.t()}
  @type invalidation_target :: %{
          required(:id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:status) => String.t()
        }
  @type handoff :: %{required(:dashboard_session_id) => Ecto.UUID.t()}

  @spec issue(term()) :: issue_result()
  def issue(raw_api_key) do
    {key_prefix, secret} =
      case Material.split(raw_api_key) do
        {:ok, key_prefix, secret} -> {key_prefix, secret}
        {:error, _reason} -> {@invalid_key_prefix, @invalid_key_secret}
      end

    issue_verified_session(key_prefix, secret)
  end

  @spec authenticate(term()) :: {:ok, Principal.t()} | {:error, :invalid_dashboard_session}
  def authenticate(token) when is_binary(token) do
    Authentication.authenticate_token_hash(hash_token(token))
  end

  def authenticate(_token), do: @invalid_session

  @spec handoff(term()) :: handoff() | nil
  def handoff(token) when is_binary(token) do
    now = now()

    case Authentication.eligible_session_query(now)
         |> where([session, _api_key, _pool], session.token_hash == ^hash_token(token))
         |> select([session, _api_key, _pool], session.id)
         |> Repo.one() do
      nil -> nil
      dashboard_session_id -> %{dashboard_session_id: dashboard_session_id}
    end
  end

  def handoff(_token), do: nil

  @spec authenticate_handoff(term()) ::
          {:ok, Principal.t()} | {:error, :invalid_dashboard_session}
  def authenticate_handoff(%{dashboard_session_id: dashboard_session_id} = handoff)
      when map_size(handoff) == 1 and is_binary(dashboard_session_id) do
    case Ecto.UUID.cast(dashboard_session_id) do
      {:ok, dashboard_session_id} -> Authentication.authenticate_session_id(dashboard_session_id)
      :error -> @invalid_session
    end
  end

  def authenticate_handoff(_handoff), do: @invalid_session

  @spec delete(term()) :: :ok
  def delete(token) when is_binary(token) do
    Repo.delete_all(
      from session in APIKeyDashboardSession,
        where: session.token_hash == ^hash_token(token)
    )

    :ok
  end

  def delete(_token), do: :ok

  @spec delete_all(APIKey.t() | Ecto.UUID.t()) :: :ok
  def delete_all(%APIKey{id: api_key_id}), do: delete_all(api_key_id)

  def delete_all(api_key_id) when is_binary(api_key_id) do
    Repo.transaction(fn ->
      case Repo.one(from api_key in APIKey, where: api_key.id == ^api_key_id, lock: "FOR UPDATE") do
        %APIKey{} = api_key ->
          delete_all_for_api_key(api_key.id)
          api_key

        nil ->
          nil
      end
    end)
    |> case do
      {:ok, %APIKey{} = api_key} ->
        broadcast_invalidation(api_key, "dashboard_sessions_deleted")

      {:ok, nil} ->
        :ok
    end

    :ok
  end

  def delete_all(_api_key), do: :ok

  @doc false
  @spec delete_all_for_api_key(Ecto.UUID.t()) :: non_neg_integer()
  def delete_all_for_api_key(api_key_id) when is_binary(api_key_id) do
    {count, _rows} =
      Repo.delete_all(
        from session in APIKeyDashboardSession,
          where: session.api_key_id == ^api_key_id
      )

    count
  end

  @doc false
  @spec delete_all_for_pool(Ecto.UUID.t()) :: [invalidation_target()]
  def delete_all_for_pool(pool_id) when is_binary(pool_id) do
    targets =
      Repo.all(
        from api_key in APIKey,
          join: session in APIKeyDashboardSession,
          on: session.api_key_id == api_key.id,
          where: api_key.pool_id == ^pool_id,
          distinct: api_key.id,
          select: %{id: api_key.id, pool_id: api_key.pool_id, status: api_key.status}
      )

    api_key_ids = Enum.map(targets, & &1.id)

    if api_key_ids != [] do
      Repo.delete_all(
        from session in APIKeyDashboardSession,
          where: session.api_key_id in ^api_key_ids
      )
    end

    targets
  end

  @doc false
  @spec broadcast_invalidation(APIKey.t() | invalidation_target(), String.t()) :: :ok
  def broadcast_invalidation(api_key, cause) when is_binary(cause) do
    target = invalidation_target(api_key)

    Events.broadcast_dashboard_sessions(
      target.pool_id,
      target.id,
      "dashboard_session_invalidated",
      %{cause: cause, pool_id: target.pool_id, status: target.status}
    )

    :ok
  end

  defp issue_verified_session(key_prefix, secret) do
    Repo.transaction(fn ->
      now = now()
      api_key = lock_api_key(key_prefix)
      expected_hash = if api_key, do: api_key.key_hash, else: @dummy_api_key_hash
      pool_id = if api_key, do: api_key.pool_id, else: @invalid_pool_id
      active_pool = lock_active_pool(pool_id)

      with :ok <- Material.verify(expected_hash, secret),
           %APIKey{} = api_key <- api_key,
           :ok <- ensure_api_key_eligible(api_key, now),
           %Pool{} <- active_pool do
        purge_expired_sessions(api_key.id, now)
        trim_sessions_for_issuance(api_key.id)
        insert_session(api_key.id, now)
      else
        _ineligible -> Repo.rollback(:invalid_dashboard_credentials)
      end
    end)
    |> normalize_issue_result()
  end

  defp lock_api_key(key_prefix) do
    Repo.one(from api_key in APIKey, where: api_key.key_prefix == ^key_prefix, lock: "FOR UPDATE")
  end

  defp lock_active_pool(pool_id) do
    Repo.one(
      from pool in Pool, where: pool.id == ^pool_id and pool.status == "active", lock: "FOR SHARE"
    )
  end

  defp ensure_api_key_eligible(%APIKey{status: "active", dashboard_access: true} = api_key, now) do
    case api_key.expires_at do
      nil ->
        :ok

      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, now) == :gt, do: :ok, else: :error
    end
  end

  defp ensure_api_key_eligible(%APIKey{}, _now), do: :error

  defp purge_expired_sessions(api_key_id, now) do
    Repo.delete_all(
      from session in APIKeyDashboardSession,
        where: session.api_key_id == ^api_key_id and session.expires_at <= ^now
    )
  end

  defp trim_sessions_for_issuance(api_key_id) do
    retained_count = @maximum_active_sessions - 1

    overflow_ids =
      Repo.all(
        from session in APIKeyDashboardSession,
          where: session.api_key_id == ^api_key_id,
          order_by: [desc: session.inserted_at, desc: session.id],
          offset: ^retained_count,
          select: session.id
      )

    if overflow_ids != [] do
      Repo.delete_all(from session in APIKeyDashboardSession, where: session.id in ^overflow_ids)
    end
  end

  defp insert_session(api_key_id, now) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(now, @ttl_seconds, :second)

    changeset =
      %APIKeyDashboardSession{api_key_id: api_key_id}
      |> APIKeyDashboardSession.changeset(%{
        token_hash: hash_token(token),
        expires_at: expires_at
      })

    case Repo.insert(changeset) do
      {:ok, _session} -> %{token: token, expires_at: expires_at}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp normalize_issue_result({:ok, result}), do: {:ok, result}
  defp normalize_issue_result({:error, :invalid_dashboard_credentials}), do: @invalid_credentials
  defp normalize_issue_result({:error, %Ecto.Changeset{} = changeset}), do: {:error, changeset}
  defp normalize_issue_result({:error, _reason}), do: @invalid_credentials

  defp invalidation_target(%APIKey{} = api_key),
    do: %{id: api_key.id, pool_id: api_key.pool_id, status: api_key.status}

  defp invalidation_target(%{id: id, pool_id: pool_id, status: status}),
    do: %{id: id, pool_id: pool_id, status: status}

  defp hash_token(token) do
    digest = :crypto.hash(:sha256, token)
    true = byte_size(digest) == @token_hash_bytes
    digest
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
