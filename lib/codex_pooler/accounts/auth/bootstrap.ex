defmodule CodexPooler.Accounts.Bootstrap do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias CodexPooler.Accounts.{AuditLog, PlatformBootstrapState, Session, User}
  alias CodexPooler.Pools.{Authorization, Membership}
  alias CodexPooler.Repo

  @session_token_bytes 32

  @type auth_result :: CodexPooler.Accounts.auth_result()

  @spec status() :: String.t()
  def status do
    Repo.get!(PlatformBootstrapState, true).status
  end

  @spec pending?() :: boolean()
  def pending?, do: status() == "pending"

  @spec change(map()) :: Ecto.Changeset.t()
  def change(attrs \\ %{}) do
    User.bootstrap_changeset(%User{}, attrs)
  end

  @spec create_owner(map(), map()) :: auth_result()
  def create_owner(attrs, metadata \\ %{}) do
    Repo.transaction(fn ->
      state =
        Repo.one!(
          from s in PlatformBootstrapState,
            where: s.singleton == true,
            lock: "FOR UPDATE"
        )

      if state.status != "pending" do
        Repo.rollback(:bootstrap_already_completed)
      end

      with {:ok, user} <- insert_bootstrap_user(attrs),
           {:ok, _membership} <- insert_owner_membership(user),
           {:ok, _state} <- mark_bootstrap_completed(state, user),
           {:ok, session, token} <- create_session(user, metadata),
           {:ok, user} <- touch_last_login(user),
           {:ok, _audit} <-
             AuditLog.record_user_event(user, %{
               action: "auth.bootstrap",
               target_type: "user",
               target_id: user.id,
               metadata: metadata,
               details: %{email: user.email}
             }) do
        %{user: user, session: session, token: token}
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  defp insert_bootstrap_user(attrs) do
    %User{}
    |> User.bootstrap_changeset(attrs)
    |> put_change(:updated_at, DateTime.utc_now())
    |> Repo.insert()
  end

  defp insert_owner_membership(user) do
    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      role: Authorization.role(:instance_owner),
      status: "active"
    })
    |> Repo.insert()
  end

  defp mark_bootstrap_completed(state, user) do
    now = DateTime.utc_now()

    state
    |> change(status: "completed", owner_user_id: user.id, completed_at: now, updated_at: now)
    |> Repo.update()
  end

  defp create_session(user, metadata) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@session_token_bytes), padding: false)
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

  defp normalize_transaction_error({:ok, value}), do: {:ok, value}

  defp normalize_transaction_error({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset}

  defp normalize_transaction_error({:error, reason}), do: {:error, reason}

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
