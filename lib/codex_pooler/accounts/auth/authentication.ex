defmodule CodexPooler.Accounts.Authentication do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias CodexPooler.Accounts.{AuditLog, MFA, Session, User}
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  @session_token_bytes 32

  @type auth_error :: CodexPooler.Accounts.auth_error()
  @type auth_result :: CodexPooler.Accounts.auth_result()
  @type user_session_summary :: %{
          id: Ecto.UUID.t(),
          current?: boolean(),
          created_at: DateTime.t(),
          last_seen_at: DateTime.t() | nil,
          expires_at: DateTime.t(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil
        }

  @spec get_user_by_email(term()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        where: fragment("lower(?)", u.email) == ^normalize_email(email) and is_nil(u.deleted_at)
    )
  end

  def get_user_by_email(_email), do: nil

  @spec get_user_by_email_and_password(term(), term()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_email_and_password(_, _) do
    User.valid_password?(nil, nil)
    nil
  end

  @spec login_user(map(), map()) :: auth_result() | auth_error()
  def login_user(attrs, metadata \\ %{}) do
    attrs = normalize_login_attrs(attrs)

    Repo.transaction(fn ->
      case authorize_login_request(attrs.email, attrs.password) do
        {:ok, user} ->
          complete_second_factor_checked_login_transaction(
            user,
            attrs.totp_code,
            attrs.recovery_code,
            metadata
          )

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  @spec complete_second_factor_login(term(), map(), map()) :: auth_result() | auth_error()
  def complete_second_factor_login(user_id, attrs, metadata \\ %{})

  def complete_second_factor_login(user_id, attrs, metadata) when is_binary(user_id) do
    totp_code = Map.get(attrs, "totp_code") || Map.get(attrs, :totp_code) || ""
    recovery_code = Map.get(attrs, "recovery_code") || Map.get(attrs, :recovery_code) || ""

    Repo.transaction(fn ->
      user = Repo.get(User, user_id)

      if active_login_user?(user) do
        complete_second_factor_checked_login_transaction(user, totp_code, recovery_code, metadata)
      else
        Repo.rollback(:invalid_credentials)
      end
    end)
    |> normalize_transaction_error()
  end

  def complete_second_factor_login(_user_id, _attrs, _metadata),
    do: {:error, :invalid_credentials}

  @spec get_user_by_session_token(term()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) when is_binary(token) do
    token_hash = hash_token(token)

    token_hash
    |> user_session_token_query(DateTime.utc_now())
    |> Repo.one()
    |> scrub_session_user_result()
  end

  def get_user_by_session_token(_token), do: nil

  @spec authenticate_session_token(term()) :: {User.t(), DateTime.t()} | nil
  def authenticate_session_token(token) when is_binary(token) do
    token_hash = hash_token(token)

    case token_hash |> user_session_token_query(DateTime.utc_now()) |> Repo.one() do
      {user, created_at} ->
        touch_session(token_hash)
        {Map.put(user, :password, nil), created_at}

      nil ->
        nil
    end
  end

  def authenticate_session_token(_token), do: nil

  @spec session_id_for_token(term()) :: Ecto.UUID.t() | nil
  def session_id_for_token(token) when is_binary(token) do
    token
    |> hash_token()
    |> then(fn token_hash ->
      Repo.one(
        from s in Session,
          where: s.session_token_hash == ^token_hash,
          where: s.status == "active",
          select: s.id
      )
    end)
  end

  def session_id_for_token(_token), do: nil

  @spec list_user_sessions(User.t(), binary() | nil) :: [user_session_summary()]
  def list_user_sessions(user, current_token \\ nil)

  def list_user_sessions(%User{id: user_id}, current_token) do
    now = DateTime.utc_now()
    current_token_hash = current_session_token_hash(current_token)

    Session
    |> where([session], session.user_id == ^user_id)
    |> where([session], session.status == "active")
    |> where([session], session.expires_at > ^now)
    |> order_by([session], desc: session.created_at)
    |> Repo.all()
    |> Enum.map(&session_summary(&1, current_token_hash))
    |> current_session_first()
  end

  def list_user_sessions(_user, _current_token), do: []

  @spec roles_for_user(User.t()) :: [String.t()]
  def roles_for_user(%User{id: user_id}) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id and m.status == "active",
        order_by: [asc: m.role],
        select: m.role
    )
  end

  @spec delete_user_session_token(term()) :: :ok
  def delete_user_session_token(token) when is_binary(token) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(s in Session,
        where: s.session_token_hash == ^hash_token(token) and s.status == "active"
      ),
      set: [status: "revoked", revoked_at: now]
    )

    :ok
  end

  def delete_user_session_token(_token), do: :ok

  @spec logout_user(term(), User.t(), map()) :: :ok
  def logout_user(token, user, metadata \\ %{}) do
    delete_user_session_token(token)

    AuditLog.record_user_event(user, %{
      action: "auth.logout",
      target_type: "session",
      metadata: metadata
    })

    :ok
  end

  @spec revoke_other_user_sessions(User.t(), binary() | nil, map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_other_user_sessions(user, current_token, metadata \\ %{})

  def revoke_other_user_sessions(%User{} = user, current_token, metadata)
      when is_binary(current_token) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()
      {count, _rows} = revoke_active_sessions_for_user(user, now, except_token: current_token)

      case AuditLog.record_user_event(user, %{
             action: "auth.sessions_revoked",
             target_type: "session",
             metadata: metadata,
             details: %{revoked_sessions: count}
           }) do
        {:ok, _audit} -> count
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  def revoke_other_user_sessions(_user, _current_token, _metadata), do: {:error, :invalid_session}

  @spec revoke_user_session(User.t(), Ecto.UUID.t(), binary() | nil, map()) ::
          {:ok, %{current?: boolean(), revoked_count: non_neg_integer()}} | {:error, term()}
  def revoke_user_session(user, session_id, current_token, metadata \\ %{})

  def revoke_user_session(%User{id: user_id} = user, session_id, current_token, metadata)
      when is_binary(session_id) do
    Repo.transaction(fn ->
      current_token_hash = current_session_token_hash(current_token)

      session =
        Repo.one(
          from s in Session,
            where: s.id == ^session_id,
            where: s.user_id == ^user_id,
            where: s.status == "active"
        )

      case session do
        nil ->
          %{current?: false, revoked_count: 0}

        %Session{} = session ->
          revoke_active_user_session(user, session, current_token_hash, metadata)
      end
    end)
    |> normalize_transaction_error()
  end

  def revoke_user_session(_user, _session_id, _current_token, _metadata),
    do: {:error, :invalid_session}

  defp revoke_active_user_session(user, session, current_token_hash, metadata) do
    now = DateTime.utc_now()

    {count, _rows} =
      Repo.update_all(
        from(s in Session, where: s.id == ^session.id and s.status == "active"),
        set: [status: "revoked", revoked_at: now]
      )

    current? =
      is_binary(current_token_hash) and session.session_token_hash == current_token_hash

    case AuditLog.record_user_event(user, %{
           action: "auth.session_revoked",
           target_type: "session",
           target_id: session.id,
           metadata: metadata,
           details: %{current_session: current?, revoked_sessions: count}
         }) do
      {:ok, _audit} -> %{current?: current?, revoked_count: count}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec change_user_password(User.t(), map(), map()) :: auth_result() | auth_error()
  def change_user_password(user, attrs, metadata \\ %{})

  def change_user_password(%User{} = user, attrs, metadata) do
    attrs = normalize_password_change_attrs(attrs)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      with {:ok, user} <- update_user_password(user, attrs),
           {_count, _rows} <- revoke_active_sessions_for_user(user, now),
           {:ok, session, token} <- create_session(user, metadata),
           {:ok, _audit} <-
             AuditLog.record_user_event(user, %{
               action: "auth.password_change",
               target_type: "user",
               target_id: user.id,
               metadata: metadata
             }) do
        %{user: user, session: session, token: token}
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  def change_user_password(_user, _attrs, _metadata), do: {:error, :invalid_session}

  @spec change_current_user_password(User.t(), map(), map(), binary() | nil) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def change_current_user_password(user, attrs, metadata \\ %{}, current_token \\ nil)

  def change_current_user_password(%User{} = user, attrs, metadata, current_token)
      when is_map(attrs) do
    attrs = normalize_password_change_attrs(attrs)

    if User.valid_password?(user, current_password_from_attrs(attrs)) do
      change_verified_current_user_password(user, attrs, metadata, current_token)
    else
      {:error, :invalid_current_password}
    end
  end

  def change_current_user_password(_user, _attrs, _metadata, _current_token),
    do: {:error, :invalid_session}

  @spec complete_required_password_change(User.t(), map(), map(), term()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def complete_required_password_change(user, attrs, metadata \\ %{}, current_token \\ nil)

  def complete_required_password_change(%User{} = user, attrs, metadata, current_token) do
    attrs = normalize_password_change_attrs(attrs)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      with {:ok, user} <- update_user_password(user, attrs),
           {_count, _rows} <-
             revoke_active_sessions_for_user(user, now, except_token: current_token),
           {:ok, _audit} <-
             AuditLog.record_user_event(user, %{
               action: "auth.required_password_change",
               target_type: "user",
               target_id: user.id,
               metadata: metadata
             }) do
        user
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  def complete_required_password_change(_user, _attrs, _metadata, _current_token),
    do: {:error, :invalid_session}

  defp complete_second_factor_checked_login_transaction(user, totp_code, recovery_code, metadata) do
    case verify_second_factor(user, totp_code, recovery_code, metadata) do
      :ok ->
        complete_successful_login_transaction(user, metadata)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp complete_successful_login_transaction(user, metadata) do
    with {:ok, session, token} <- create_session(user, metadata),
         {:ok, user} <- touch_last_login(user),
         {:ok, _audit} <-
           AuditLog.record_user_event(user, %{
             action: "auth.login",
             target_type: "session",
             target_id: session.id,
             metadata: metadata,
             details: %{email: user.email}
           }) do
      %{user: user, session: session, token: token}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp active_login_user?(%User{deleted_at: nil, status: "active"}), do: true
  defp active_login_user?(_user), do: false

  defp normalize_login_attrs(attrs) do
    %{
      email: normalize_email(login_attr(attrs, :email)),
      password: login_attr(attrs, :password),
      totp_code: login_attr(attrs, :totp_code),
      recovery_code: login_attr(attrs, :recovery_code)
    }
  end

  defp login_attr(attrs, key) do
    Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key) || ""
  end

  defp authorize_login_request("", _password), do: {:error, :invalid_request}
  defp authorize_login_request(_email, ""), do: {:error, :invalid_request}

  defp authorize_login_request(email, password) do
    case get_user_by_email(email) do
      %User{} = user -> verify_login_user_password(user, password)
      nil -> verify_missing_login_user(password)
    end
  end

  defp verify_login_user_password(user, password) do
    if User.valid_password?(user, password) and active_login_user?(user) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  defp verify_missing_login_user(password) do
    User.valid_password?(nil, password)
    {:error, :invalid_credentials}
  end

  defp user_session_token_query(token_hash, now) do
    from s in Session,
      join: u in assoc(s, :user),
      where: s.session_token_hash == ^token_hash,
      where: s.status == "active",
      where: s.expires_at > ^now,
      where: u.status == "active" and is_nil(u.deleted_at),
      select: {u, s.created_at}
  end

  defp scrub_session_user_result({user, created_at}),
    do: {Map.put(user, :password, nil), created_at}

  defp scrub_session_user_result(nil), do: nil

  defp create_session(user, metadata) do
    token = :crypto.strong_rand_bytes(@session_token_bytes) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, session_ttl_seconds(), :second)

    session = %Session{
      user_id: user.id,
      session_token_hash: hash_token(token),
      status: "active",
      expires_at: expires_at,
      ip_address: inet(metadata[:ip_address]),
      user_agent: metadata[:user_agent],
      created_at: now
    }

    case Repo.insert(session) do
      {:ok, session} -> {:ok, session, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp touch_last_login(user) do
    user
    |> change(last_login_at: DateTime.utc_now(), updated_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> put_change(:password_change_required, false)
    |> put_change(:updated_at, DateTime.utc_now())
    |> Repo.update()
  end

  defp revoke_active_sessions_for_user(user, now, opts \\ []) do
    except_token = Keyword.get(opts, :except_token)

    query = from(s in Session, where: s.user_id == ^user.id and s.status == "active")

    query =
      if is_binary(except_token) do
        except_token_hash = hash_token(except_token)
        from s in query, where: s.session_token_hash != ^except_token_hash
      else
        query
      end

    Repo.update_all(
      query,
      set: [status: "revoked", revoked_at: now]
    )
  end

  defp touch_session(token_hash) do
    Repo.update_all(
      from(s in Session, where: s.session_token_hash == ^token_hash),
      set: [last_seen_at: DateTime.utc_now()]
    )
  end

  defp current_session_token_hash(current_token) when is_binary(current_token),
    do: hash_token(current_token)

  defp current_session_token_hash(_current_token), do: nil

  defp session_summary(session, current_token_hash) do
    %{
      id: session.id,
      current?:
        is_binary(current_token_hash) and session.session_token_hash == current_token_hash,
      created_at: session.created_at,
      last_seen_at: session.last_seen_at,
      expires_at: session.expires_at,
      ip_address: session.ip_address,
      user_agent: session.user_agent
    }
  end

  defp current_session_first(sessions) do
    {current_sessions, other_sessions} = Enum.split_with(sessions, & &1.current?)
    current_sessions ++ other_sessions
  end

  defp verify_second_factor(user, totp_code, recovery_code, metadata),
    do: MFA.verify_second_factor(user, totp_code, recovery_code, metadata)

  defp normalize_transaction_error({:ok, value}), do: {:ok, value}

  defp normalize_transaction_error({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset}

  defp normalize_transaction_error({:error, reason}), do: {:error, reason}

  defp normalize_email(email) do
    email
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_password_change_attrs(attrs) do
    new_password = Map.get(attrs, "new_password") || Map.get(attrs, :new_password)

    if new_password do
      Map.put(attrs, "password", new_password)
    else
      attrs
    end
  end

  defp current_password_from_attrs(attrs) when is_map(attrs) do
    Map.get(attrs, "current_password") || Map.get(attrs, :current_password)
  end

  defp change_verified_current_user_password(user, attrs, metadata, current_token) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      with {:ok, user} <- update_user_password(user, attrs),
           {_count, _rows} <-
             revoke_active_sessions_for_user(user, now, except_token: current_token),
           {:ok, _audit} <-
             AuditLog.record_user_event(user, %{
               action: "auth.password_change",
               target_type: "user",
               target_id: user.id,
               metadata: metadata
             }) do
        user
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp inet(nil), do: nil

  defp inet(value) do
    value = to_charlist(value)

    case :inet.parse_address(value) do
      {:ok, address} -> %Postgrex.INET{address: address}
      {:error, _reason} -> nil
    end
  end

  defp session_ttl_seconds do
    config = Application.get_env(:codex_pooler, CodexPooler.Accounts, [])
    Keyword.get(config, :session_ttl_seconds, 14 * 24 * 60 * 60)
  end
end
