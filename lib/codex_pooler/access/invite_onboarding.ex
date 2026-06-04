defmodule CodexPooler.Access.InviteOnboarding do
  @moduledoc """
  LiveView-facing invite onboarding orchestration for Codex upstream accounts.
  """

  alias CodexPooler.Access.Invites
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Lifecycle.InternalLifecycle
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @type invite_error :: {:error, term()}
  @type pending_account :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t()
        }
  @type device_start :: %{
          required(:account) => pending_account(),
          required(:verification) => map()
        }
  @type completed_onboarding :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t()
        }

  @spec start_device(String.t()) :: {:ok, device_start()} | invite_error()
  def start_device(token) when is_binary(token) do
    with {:ok, %{invite: invite, pool: pool}} <- Invites.load_usable_invite(token),
         {:ok, verification} <- CodexAuth.request_device_code(),
         {:ok, account} <- create_pending_account(invite, pool, "device", verification) do
      {:ok,
       %{
         account: account,
         verification: verification
       }}
    end
  end

  @spec poll_device(String.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, completed_onboarding()} | invite_error()
  def poll_device(token, upstream_account_id)
      when is_binary(token) and is_binary(upstream_account_id) do
    with {:ok, %{invite: invite, pool: pool}} <- Invites.load_usable_invite(token),
         {:ok, identity, assignment} <- load_invite_account(invite, pool, upstream_account_id),
         {:ok, state_json} <-
           Secrets.decrypt_active_secret(identity, "device_code"),
         {:ok, state} <- Jason.decode(state_json),
         {:ok, tokens} <- CodexAuth.poll_device_authorization(state) do
      complete_onboarding(invite, identity, assignment, tokens, "device")
    end
  end

  defp create_pending_account(invite, pool, method, auth_state) do
    label = invite.invited_email || "Invited account"
    auth_state = Map.put(auth_state, :invite_id, invite.id)

    Repo.transaction(fn ->
      with {:ok, invite} <- Invites.lock_usable_invite(invite),
           {:ok, identity, assignment} <- pending_account(invite, pool, label, method) do
        # Reason: secret write failure must rollback the pending invite account.
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        case Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "device_code",
               plaintext: Jason.encode!(auth_state)
             }) do
          {:ok, _secret} -> %{identity: identity, assignment: assignment}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp complete_onboarding_metadata(metadata, invite, method) do
    Map.merge(metadata || %{}, %{"invite_id" => invite.id, "onboarding_method" => method})
  end

  defp pending_account(invite, pool, label, method) do
    case find_pending_account(invite, pool) do
      {:ok, identity, assignment} ->
        refresh_pending_account(identity, assignment, invite, label, method)

      :error ->
        create_new_pending_account(invite, pool, label, method)
    end
  end

  defp find_pending_account(invite, pool) do
    pool.id
    |> Upstreams.list_pool_assignments()
    |> Enum.filter(&invite_bound?(&1.metadata, invite))
    |> Enum.find_value(:error, fn assignment ->
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      if pending_account?(identity, assignment, invite) do
        {:ok, identity, assignment}
      end
    end)
  end

  defp pending_account?(
         %UpstreamIdentity{} = identity,
         %PoolUpstreamAssignment{} = assignment,
         invite
       ) do
    identity.status == "pending" and assignment.status == "pending" and
      identity.onboarding_method == "invite" and
      invite_bound?(identity.metadata, invite)
  end

  defp pending_account?(_identity, _assignment, _invite), do: false

  defp refresh_pending_account(identity, assignment, invite, label, method) do
    with {:ok, %{identity: identity, assignment: assignment}} <-
           InternalLifecycle.update_pending_pool_account(
             identity,
             assignment,
             %{
               account_label: label,
               metadata: %{"invite_id" => invite.id, "onboarding_method" => method}
             },
             %{
               assignment_label: label,
               metadata: %{"invite_id" => invite.id, "onboarding_method" => method}
             }
           ) do
      {:ok, identity, assignment}
    end
  end

  defp create_new_pending_account(invite, pool, label, method) do
    with {:ok, %{identity: identity, assignment: assignment}} <-
           InternalLifecycle.create_pending_pool_account(
             pool,
             %{
               account_label: label,
               onboarding_method: "invite",
               metadata: %{"invite_id" => invite.id, "onboarding_method" => method}
             },
             %{
               assignment_label: label,
               metadata: %{"invite_id" => invite.id, "onboarding_method" => method}
             }
           ) do
      {:ok, identity, assignment}
    end
  end

  defp load_invite_account(invite, pool, upstream_account_id) do
    with identity when not is_nil(identity) <-
           Upstreams.get_upstream_identity(upstream_account_id),
         true <- invite_bound?(identity.metadata, invite),
         assignment when not is_nil(assignment) <- assignment_for(pool, identity),
         true <- invite_bound?(assignment.metadata, invite) do
      {:ok, identity, assignment}
    else
      _missing ->
        {:error, %{code: :upstream_identity_not_found, message: "upstream account was not found"}}
    end
  end

  defp complete_onboarding(invite, identity, assignment, tokens, method) do
    Repo.transaction(fn ->
      with {:ok, info} <- CodexAuth.token_info(tokens.id_token),
           {:ok, info} <- verify_invited_email(invite, info),
           {:ok, completed} <-
             complete_verified_account(invite, identity, assignment, tokens, method, info) do
        completed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, completed} ->
        _job =
          Jobs.enqueue_assignment_priming(completed.assignment.pool_id, completed.assignment,
            trigger_kind: "account_link"
          )

        Events.broadcast_upstreams(completed.assignment.pool_id, "upstream_account_onboarded", %{
          assignment_id: completed.assignment.id,
          upstream_identity_id: completed.identity.id,
          onboarding_method: method
        })

        {:ok, completed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_invited_email(invite, info) do
    case normalized_email(invite.invited_email) do
      nil ->
        {:ok, info}

      invited_email ->
        case normalized_email(info.email) do
          ^invited_email ->
            {:ok, Map.put(info, :email, invited_email)}

          _authorized_email ->
            {:error,
             %{
               code: :invite_email_mismatch,
               message: "The authorized Codex account email does not match this invite."
             }}
        end
    end
  end

  defp complete_verified_account(invite, identity, assignment, tokens, method, info) do
    case present_string(info.chatgpt_account_id) do
      nil ->
        {:error,
         %{
           code: :codex_account_identity_missing,
           message: "Codex account identity was not returned by upstream auth"
         }}

      chatgpt_account_id ->
        info = Map.put(info, :chatgpt_account_id, chatgpt_account_id)

        case IdentityLifecycle.select_upsert_identity(verified_identity_attrs(identity, info)) do
          {:error, reason} ->
            {:error, reason}

          {:ok, %UpstreamIdentity{id: existing_id} = existing} when existing_id != identity.id ->
            complete_existing_account(
              invite,
              identity,
              assignment,
              existing,
              tokens,
              method,
              info
            )

          _missing_or_same ->
            complete_pending_account(invite, identity, assignment, tokens, method, info)
        end
    end
  end

  defp verified_identity_attrs(identity, info) do
    %{
      chatgpt_account_id: info.chatgpt_account_id,
      account_email: info.email,
      account_label: info.email || identity.account_label,
      workspace_id: info.workspace_id,
      workspace_label: info.workspace_label,
      seat_type: info.seat_type,
      plan_family: info.plan_family,
      plan_label: info.plan_label
    }
  end

  defp complete_pending_account(invite, identity, assignment, tokens, method, info) do
    with {:ok, %{identity: identity, assignment: assignment}} <-
           activate_verified_pool_account(identity, assignment, invite, method, info),
         {:ok, _secret} <- store_verified_tokens(identity, tokens),
         {:ok, %{invite: invite}} <-
           consume_verified_invite(invite, identity, assignment, method, info) do
      {:ok, %{identity: identity, assignment: assignment, invite: invite, info: info}}
    end
  end

  defp complete_existing_account(
         invite,
         pending_identity,
         _pending_assignment,
         existing,
         tokens,
         method,
         info
       ) do
    with {:ok, identity} <- activate_verified_identity(existing, invite, method, info),
         {:ok, _secret} <- store_verified_tokens(identity, tokens),
         {:ok, assignment} <- ensure_verified_assignment(invite, identity, method),
         {:ok, %{invite: invite}} <-
           consume_verified_invite(invite, identity, assignment, method, info),
         {:ok, _deleted} <- delete_pending_placeholder(pending_identity) do
      {:ok, %{identity: identity, assignment: assignment, invite: invite, info: info}}
    end
  end

  defp activate_verified_identity(identity, invite, method, info) do
    attrs =
      Map.put(
        verified_identity_attrs(identity, info),
        :metadata,
        identity.metadata
        |> complete_onboarding_metadata(invite, method)
        |> Map.put("chatgpt_user_id", info.chatgpt_user_id)
        |> put_account_email(info.email)
      )

    IdentityLifecycle.activate_upstream_identity_with_plan(identity, attrs)
  end

  defp activate_verified_pool_account(identity, assignment, invite, method, info) do
    InternalLifecycle.activate_verified_pool_account(
      identity,
      assignment,
      Map.put(
        verified_identity_attrs(identity, info),
        :metadata,
        identity.metadata
        |> complete_onboarding_metadata(invite, method)
        |> Map.put("chatgpt_user_id", info.chatgpt_user_id)
        |> put_account_email(info.email)
      ),
      %{
        metadata: complete_onboarding_metadata(assignment.metadata, invite, method),
        skip_quota_priming: true
      }
    )
  end

  defp store_verified_tokens(identity, tokens) do
    with {:ok, secret} <-
           Upstreams.store_encrypted_secret(identity, %{
             secret_kind: "access_token",
             plaintext: tokens.access_token
           }),
         {:ok, _refresh} <- maybe_store_refresh_token(identity, tokens.refresh_token) do
      {:ok, secret}
    end
  end

  defp activate_verified_assignment(assignment, invite, method) do
    PoolAssignments.activate_pool_assignment(assignment, %{
      metadata: complete_onboarding_metadata(assignment.metadata, invite, method),
      skip_quota_priming: true
    })
  end

  defp ensure_verified_assignment(invite, identity, method) do
    pool = Repo.get!(Pool, invite.pool_id)

    case assignment_for(pool, identity) do
      %PoolUpstreamAssignment{} = assignment ->
        activate_verified_assignment(assignment, invite, method)

      nil ->
        InternalLifecycle.ensure_active_pool_assignment(pool, identity, %{
          assignment_label: identity.account_label,
          metadata: complete_onboarding_metadata(%{}, invite, method),
          skip_quota_priming: true
        })
    end
  end

  defp consume_verified_invite(invite, identity, assignment, method, info) do
    Invites.consume_invite(invite, %{
      upstream_identity_id: identity.id,
      pool_upstream_assignment_id: assignment.id,
      onboarding_method: method,
      accepted_by_email: info.email,
      details: %{"chatgpt_account_id" => info.chatgpt_account_id}
    })
  end

  defp delete_pending_placeholder(%UpstreamIdentity{status: "pending"} = identity),
    do: Repo.delete(identity)

  defp delete_pending_placeholder(_identity), do: {:ok, nil}

  defp maybe_store_refresh_token(_identity, nil), do: {:ok, nil}

  defp maybe_store_refresh_token(identity, refresh_token) do
    Upstreams.store_encrypted_secret(identity, %{
      secret_kind: "refresh_token",
      plaintext: refresh_token
    })
  end

  defp assignment_for(pool, identity) do
    pool.id
    |> Upstreams.list_pool_assignments()
    |> Enum.find(&(&1.upstream_identity_id == identity.id))
  end

  defp invite_bound?(metadata, invite), do: Map.get(metadata || %{}, "invite_id") == invite.id

  defp put_account_email(metadata, email) when is_binary(email),
    do: Map.put(metadata, "account_email", email)

  defp put_account_email(metadata, _email), do: metadata

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp normalized_email(value) do
    value
    |> present_string()
    |> case do
      nil -> nil
      email -> String.downcase(email)
    end
  end
end
