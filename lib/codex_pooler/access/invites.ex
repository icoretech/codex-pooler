defmodule CodexPooler.Access.Invites do
  @moduledoc """
  Invite lifecycle operations behind the public `CodexPooler.Access` facade.
  """

  import Ecto.Query

  alias CodexPooler.Access.{Invite, InviteAcceptance}
  alias CodexPooler.Access.Invites.PublicContract
  alias CodexPooler.Access.Invites.ReadModel
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Authorization, as: PoolAuthorization
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @invite_token_bytes 32
  @default_invite_ttl_seconds 24 * 60 * 60
  @status_active "active"
  @status_accepted "accepted"
  @status_revoked "revoked"
  @status_expired "expired"

  @type access_error :: CodexPooler.Access.access_error()
  @type invite_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | access_error()}
  @type list_opts :: ReadModel.list_opts()
  @type invite_row :: ReadModel.invite_row()
  @type invite_page :: ReadModel.invite_page()

  @spec create_invite(Scope.t(), Pool.t() | Ecto.UUID.t(), map()) ::
          invite_result()
  def create_invite(scope, pool_or_id, attrs \\ %{})

  def create_invite(%Scope{} = scope, pool_or_id, attrs) when is_map(attrs) do
    with %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_operate),
             pool_id: pool.id
           ),
         now = now(),
         {:ok, expires_at} <- invite_expires_at(attrs, now) do
      token = generate_invite_token()

      invite_attrs = %{
        pool_id: pool.id,
        token_hash: hash_invite_token(token),
        invited_email: Map.get(attrs, :invited_email) || Map.get(attrs, "invited_email"),
        status: @status_active,
        expires_at: expires_at,
        created_by_user_id: scope.user.id,
        created_at: now,
        updated_at: now
      }

      %Invite{}
      |> Invite.changeset(invite_attrs)
      |> insert_unique_active_invite(scope, pool, now)
      |> case do
        {:ok, invite} -> {:ok, %{invite: invite, token: token}}
        {:error, _reason} = error -> error
      end
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def create_invite(_scope, _pool_or_id, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_invites(Scope.t(), list_opts()) :: invite_page()
  def list_invites(scope, opts \\ [])

  def list_invites(%Scope{} = scope, opts), do: ReadModel.list_invites(scope, opts)

  def list_invites(_scope, _opts), do: %{items: [], total: 0, limit: 50}

  @spec revoke_invite(Scope.t(), Invite.t() | Ecto.UUID.t()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def revoke_invite(%Scope{} = scope, invite_or_id) do
    with %Invite{} = invite <- normalize_invite(invite_or_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_operate),
             pool_id: invite.pool_id
           ) do
      Repo.transaction(fn ->
        invite
        |> locked_invite()
        |> revoke_locked_invite(scope)
      end)
      |> normalize_transaction_result()
    else
      nil -> {:error, access_error(:invite_not_found, "invite was not found")}
      {:error, _reason} = error -> error
    end
  end

  def revoke_invite(_scope, _invite_or_id),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec reissue_invite(Scope.t(), Invite.t() | Ecto.UUID.t()) ::
          {:ok,
           %{
             revoked: Invite.t(),
             invite: Invite.t(),
             token: binary(),
             pool: Pool.t()
           }}
          | {:error, Ecto.Changeset.t() | access_error()}
  def reissue_invite(%Scope{} = scope, invite_or_id) do
    with %Invite{} = invite <- normalize_invite(invite_or_id),
         %Pool{} = pool <- Pools.get_active_pool(invite.pool_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_operate),
             pool_id: invite.pool_id
           ) do
      Repo.transaction(fn ->
        invite
        |> locked_invite()
        |> reissue_locked_invite(scope, pool)
      end)
      |> normalize_transaction_result()
    else
      nil -> {:error, access_error(:invite_not_found, "invite was not found")}
      {:error, _reason} = error -> error
    end
  end

  def reissue_invite(_scope, _invite_or_id),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp insert_unique_active_invite(
         %Ecto.Changeset{valid?: false} = changeset,
         _scope,
         _pool,
         _now
       ),
       do: {:error, changeset}

  defp insert_unique_active_invite(%Ecto.Changeset{} = changeset, scope, pool, now) do
    invited_email = Ecto.Changeset.get_change(changeset, :invited_email)

    Repo.transaction(fn ->
      expire_stale_active_invites(pool.id, invited_email, now)

      if active_invite_exists?(pool.id, invited_email) do
        Repo.rollback(
          access_error(
            :invite_exists,
            "An active invite already exists for this Codex account and Pool."
          )
        )
      else
        insert_active_invite(changeset, scope, pool)
      end
    end)
    |> normalize_transaction_result()
  end

  defp insert_active_invite(changeset, scope, pool) do
    changeset
    |> Repo.insert()
    |> audit_invite_create(scope, pool)
    |> broadcast_invite_change("invite_created")
    |> case do
      {:ok, invite} -> invite
      {:error, reason} -> Repo.rollback(invite_insert_error(reason))
    end
  end

  defp expire_stale_active_invites(pool_id, invited_email, now) do
    from(invite in Invite,
      where:
        invite.pool_id == ^pool_id and
          invite.invited_email == ^invited_email and
          invite.status == ^@status_active and
          not is_nil(invite.expires_at) and
          invite.expires_at <= ^now
    )
    |> Repo.update_all(set: [status: @status_expired, updated_at: now])
  end

  defp active_invite_exists?(pool_id, invited_email) do
    Repo.exists?(
      from invite in Invite,
        where:
          invite.pool_id == ^pool_id and
            invite.invited_email == ^invited_email and
            invite.status == ^@status_active
    )
  end

  defp audit_invite_create({:ok, %Invite{} = invite} = result, %Scope{user: %User{} = user}, pool) do
    Audit.record_user_event(user, %{
      pool_id: pool.id,
      action: "invite.create",
      target_type: "invite",
      target_id: invite.id,
      details: invite_audit_details(invite)
    })

    result
  end

  defp audit_invite_create(result, _scope, _pool), do: result

  defp audit_invite_revoke({:ok, %Invite{} = invite} = result, %Scope{user: %User{} = user}) do
    Audit.record_user_event(user, %{
      pool_id: invite.pool_id,
      action: "invite.revoke",
      target_type: "invite",
      target_id: invite.id,
      details: invite_audit_details(invite)
    })

    result
  end

  defp audit_invite_revoke(result, _scope), do: result

  defp broadcast_invite_change({:ok, %Invite{} = invite} = result, reason) do
    Events.broadcast_upstreams(invite.pool_id, reason, %{
      invite_id: invite.id,
      status: invite.status
    })

    result
  end

  defp broadcast_invite_change(result, _reason), do: result

  defp invite_audit_details(invite) do
    %{
      invite_id: invite.id,
      pool_id: invite.pool_id,
      invited_email: invite.invited_email,
      status: invite.status,
      expires_at: audit_datetime(invite.expires_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp audit_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp audit_datetime(_datetime), do: nil

  @spec get_invite_by_token(binary()) :: Invite.t() | nil
  def get_invite_by_token(raw_token) when is_binary(raw_token) do
    Repo.get_by(Invite, token_hash: hash_invite_token(raw_token))
  end

  def get_invite_by_token(_raw_token), do: nil

  @spec load_usable_invite(term()) :: {:ok, map()} | {:error, access_error()}
  def load_usable_invite(raw_token) when is_binary(raw_token) do
    with %Invite{} = invite <- get_invite_by_token(raw_token),
         :ok <- ensure_invite_usable(invite),
         %Pool{} = pool <- Pools.get_active_pool(invite.pool_id) do
      {:ok, %{invite: invite, pool: pool}}
    else
      nil -> {:error, access_error(:invite_not_found, "invite was not found")}
      {:error, _reason} = error -> error
    end
  end

  def load_usable_invite(_raw_token),
    do: {:error, access_error(:invite_not_found, "invite was not found")}

  @spec load_usable_invite_contract(term()) :: {:ok, map()} | {:error, access_error()}
  def load_usable_invite_contract(raw_token) when is_binary(raw_token) do
    case load_usable_invite(raw_token) do
      {:ok, %{invite: invite, pool: pool}} -> {:ok, PublicContract.build(invite, pool, raw_token)}
      {:error, _reason} = error -> error
    end
  end

  def load_usable_invite_contract(_raw_token),
    do: {:error, access_error(:invite_not_found, "invite was not found")}

  @spec lock_usable_invite(term()) :: {:ok, term()} | {:error, access_error()}
  def lock_usable_invite(%Invite{} = invite) do
    locked = Repo.one(from i in Invite, where: i.id == ^invite.id, lock: "FOR UPDATE")

    with %Invite{} = locked <- locked,
         :ok <- ensure_invite_usable(locked) do
      {:ok, locked}
    else
      nil -> {:error, access_error(:invite_not_found, "invite was not found")}
      {:error, _reason} = error -> error
    end
  end

  def lock_usable_invite(_invite),
    do: {:error, access_error(:invite_not_found, "invite was not found")}

  @spec consume_invite(Invite.t(), map()) :: invite_result()
  def consume_invite(%Invite{} = invite, attrs) when is_map(attrs) do
    with {:ok, upstream_identity_id} <- required_invite_attr(attrs, :upstream_identity_id) do
      invite
      |> consume_invite_transaction(attrs, upstream_identity_id)
      |> normalize_transaction_result()
    end
  end

  def consume_invite(_invite, _attrs),
    do: {:error, access_error(:invite_not_found, "invite was not found")}

  defp consume_invite_transaction(invite, attrs, upstream_identity_id) do
    Repo.transaction(fn ->
      invite
      |> locked_invite()
      |> consume_locked_invite_transaction(attrs, upstream_identity_id)
    end)
  end

  defp locked_invite(invite),
    do: Repo.one(from i in Invite, where: i.id == ^invite.id, lock: "FOR UPDATE")

  defp consume_locked_invite_transaction(nil, _attrs, _upstream_identity_id),
    do: Repo.rollback(access_error(:invite_not_found, "invite was not found"))

  defp consume_locked_invite_transaction(%Invite{} = locked, attrs, upstream_identity_id) do
    with :ok <- ensure_invite_usable(locked),
         now = now(),
         {:ok, acceptance} <- insert_invite_acceptance(locked, attrs, upstream_identity_id, now),
         {:ok, invite} <- accept_locked_invite(locked, now) do
      %{invite: invite, acceptance: acceptance}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revoke_locked_invite(nil, _scope),
    do: Repo.rollback(access_error(:invite_not_found, "invite was not found"))

  defp revoke_locked_invite(%Invite{} = locked, scope) do
    case effective_status(locked) do
      @status_active ->
        now = now()

        locked
        |> Invite.changeset(%{
          status: @status_revoked,
          revoked_at: now,
          updated_at: now
        })
        |> Repo.update()
        |> audit_invite_revoke(scope)
        |> broadcast_invite_change("invite_revoked")
        |> case do
          {:ok, invite} -> invite
          {:error, reason} -> Repo.rollback(reason)
        end

      _status ->
        Repo.rollback(access_error(:invite_not_found, "invite was not active"))
    end
  end

  defp reissue_locked_invite(nil, _scope, _pool),
    do: Repo.rollback(access_error(:invite_not_found, "invite was not found"))

  defp reissue_locked_invite(%Invite{} = locked, scope, pool) do
    case effective_status(locked) do
      @status_active ->
        now = now()

        with {:ok, revoked} <- revoke_active_invite(locked, scope, now),
             {:ok, invite, token} <- insert_reissued_invite(locked, scope, pool, now) do
          %{revoked: revoked, invite: invite, token: token, pool: pool}
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      _status ->
        Repo.rollback(access_error(:invite_not_found, "invite was not active"))
    end
  end

  defp revoke_active_invite(%Invite{} = locked, scope, now) do
    locked
    |> Invite.changeset(%{
      status: @status_revoked,
      revoked_at: now,
      updated_at: now
    })
    |> Repo.update()
    |> audit_invite_revoke(scope)
    |> broadcast_invite_change("invite_revoked")
  end

  defp insert_reissued_invite(%Invite{} = locked, scope, pool, now) do
    token = generate_invite_token()

    attrs = %{
      pool_id: locked.pool_id,
      token_hash: hash_invite_token(token),
      invited_email: locked.invited_email,
      status: @status_active,
      expires_at: DateTime.add(now, @default_invite_ttl_seconds, :second),
      created_by_user_id: scope.user.id,
      created_at: now,
      updated_at: now
    }

    %Invite{}
    |> Invite.changeset(attrs)
    |> Repo.insert()
    |> audit_invite_create(scope, pool)
    |> broadcast_invite_change("invite_created")
    |> case do
      {:ok, invite} -> {:ok, invite, token}
      {:error, reason} -> {:error, invite_insert_error(reason)}
    end
  end

  defp invite_insert_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :invited_email) do
      access_error(
        :invite_exists,
        "An active invite already exists for this Codex account and Pool."
      )
    else
      changeset
    end
  end

  defp invite_insert_error(reason), do: reason

  defp required_invite_attr(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _value ->
        {:error, access_error(:invalid_request, "#{key} is required")}
    end
  end

  defp insert_invite_acceptance(locked, attrs, upstream_identity_id, now) do
    %InviteAcceptance{}
    |> InviteAcceptance.changeset(%{
      invite_id: locked.id,
      pool_id: locked.pool_id,
      upstream_identity_id: upstream_identity_id,
      pool_upstream_assignment_id: invite_attr(attrs, :pool_upstream_assignment_id),
      onboarding_method: invite_attr(attrs, :onboarding_method) || "invite",
      accepted_by_email: invite_attr(attrs, :accepted_by_email),
      accepted_at: now,
      details: invite_attr(attrs, :details) || %{}
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp accept_locked_invite(locked, now) do
    locked
    |> Invite.changeset(%{
      status: @status_accepted,
      accepted_at: now,
      updated_at: now
    })
    |> Repo.update()
  end

  defp invite_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp effective_status(%Invite{status: @status_active, expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, now()) == :gt, do: @status_active, else: @status_expired
  end

  defp effective_status(%Invite{status: status}), do: status

  defp normalize_invite(%Invite{} = invite), do: invite
  defp normalize_invite(id) when is_binary(id), do: Repo.get(Invite, id)
  defp normalize_invite(_invite_or_id), do: nil

  @spec hash_invite_token(binary()) :: binary()
  def hash_invite_token(token), do: :crypto.hash(:sha256, String.trim(token))

  defp normalize_pool(%Pool{} = pool), do: pool
  defp normalize_pool(id) when is_binary(id), do: Pools.get_active_pool(id)
  defp normalize_pool(_pool_or_id), do: nil

  defp parse_expires_at(%DateTime{} = expires_at),
    do: {:ok, DateTime.truncate(expires_at, :microsecond)}

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} ->
        {:ok, DateTime.truncate(expires_at, :microsecond)}

      {:error, _reason} ->
        {:error, access_error(:invalid_request, "expires_at must be an RFC3339 timestamp")}
    end
  end

  defp parse_expires_at(_value),
    do: {:error, access_error(:invalid_request, "expires_at must be an RFC3339 timestamp")}

  defp invite_expires_at(attrs, now) do
    case Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at") do
      nil -> {:ok, DateTime.add(now, @default_invite_ttl_seconds, :second)}
      "" -> {:ok, DateTime.add(now, @default_invite_ttl_seconds, :second)}
      value -> parse_expires_at(value)
    end
  end

  defp generate_invite_token do
    @invite_token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp ensure_invite_usable(%Invite{} = invite) do
    cond do
      invite.status == @status_accepted ->
        {:error, access_error(:invite_consumed, "invite is expired or already consumed")}

      invite.status != @status_active ->
        {:error, access_error(:invite_not_found, "invite was not found")}

      not is_nil(invite.expires_at) and DateTime.compare(invite.expires_at, now()) != :gt ->
        {:error, access_error(:invite_consumed, "invite is expired or already consumed")}

      true ->
        :ok
    end
  end

  defp normalize_transaction_result({:ok, %{result: value}}), do: {:ok, value}
  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, _operation, value, _changes}), do: {:error, value}
  defp normalize_transaction_result({:error, value}), do: {:error, value}

  defp access_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
