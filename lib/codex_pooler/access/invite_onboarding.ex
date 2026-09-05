defmodule CodexPooler.Access.InviteOnboarding do
  @moduledoc """
  LiveView-facing invite onboarding orchestration for Codex upstream accounts.
  """

  import Ecto.Query

  alias CodexPooler.Access.{Invite, Invites}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Lifecycle.IdentitySlotLock
  alias CodexPooler.Upstreams.Lifecycle.InternalLifecycle
  alias CodexPooler.Upstreams.{PreparedAccount, Secrets, SecretStore, TokenLinking}
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

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
          required(:status) => atom(),
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:secret_status) => atom(),
          required(:invite) => Invite.t(),
          required(:info) => CodexAuth.token_info()
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
      complete_onboarding(invite, pool, identity, assignment, tokens, "device")
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
        case SecretStore.store_encrypted_secret(identity, %{
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
    |> UpstreamAssignments.list_pool_assignments()
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
               metadata:
                 CredentialFencing.initialize_metadata(%{
                   "invite_id" => invite.id,
                   "onboarding_method" => method
                 })
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

  defp complete_onboarding(invite, pool, identity, assignment, tokens, method) do
    with {:ok, info} <- CodexAuth.token_info(tokens.id_token),
         {:ok, info} <- verify_invited_email(invite, info),
         {:ok, scope} <- invite_scope(invite),
         {:ok, prepared} <-
           prepare_verified_account(scope, pool, identity, invite, tokens, method, info) do
      persist_completed_onboarding(
        scope,
        invite,
        pool,
        identity,
        assignment,
        prepared,
        method,
        info
      )
    end
  end

  defp persist_completed_onboarding(
         scope,
         invite,
         pool,
         pending_identity,
         pending_assignment,
         prepared,
         method,
         info
       ) do
    Repo.transaction(fn ->
      with {:ok, locked_invite} <- Invites.lock_usable_invite(invite),
           _resources <- IdentitySlotLock.lock_slots!([prepared.attrs]),
           {:ok, selected_identity} <- IdentityLifecycle.select_upsert_identity(prepared.attrs),
           candidate_identities <- candidate_identities(prepared, selected_identity),
           locked_rows <-
             IdentitySlotLock.lock_identity_rows!([pending_identity | candidate_identities]),
           {:ok, pending_identity, _pending_assignment} <-
             revalidate_pending_account(
               locked_invite,
               pool,
               pending_identity,
               pending_assignment,
               locked_rows
             ),
           :ok <- revalidate_selected_identity(prepared, selected_identity, locked_rows),
           :ok <- ensure_selected_assignment(scope, pool, selected_identity, prepared),
           prepared <-
             bind_prepared_target(
               prepared,
               pending_identity,
               selected_identity,
               locked_rows,
               pool
             ),
           {:ok, linked} <-
             TokenLinking.link_prepared_in_transaction(scope, pool, prepared, slots_locked?: true),
           {:ok, %{invite: accepted_invite}} <-
             consume_verified_invite(
               locked_invite,
               linked.identity,
               linked.assignment,
               method,
               info
             ),
           {:ok, _deleted} <- delete_pending_placeholder(pending_identity, linked.identity) do
        %{linked: linked, invite: accepted_invite, info: info}
      else
        {:error, reason} -> Repo.rollback(invite_completion_error(reason))
      end
    end)
    |> case do
      {:ok, %{linked: linked, invite: accepted_invite, info: info}} ->
        with {:ok, published} <-
               TokenLinking.publish_link_result(scope, pool, linked,
                 quota_trigger_kind: "account_link",
                 broadcast_reason: "upstream_account_onboarded"
               ) do
          {:ok, Map.merge(published, %{invite: accepted_invite, info: info})}
        end

      {:error, reason} ->
        {:error, invite_completion_error(reason)}
    end
  end

  defp invite_scope(%{created_by_user_id: user_id}) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> {:ok, Scope.for_user(user)}
      nil -> {:error, invite_not_usable_error()}
    end
  end

  defp invite_scope(_invite), do: {:error, invite_not_usable_error()}

  defp prepare_verified_account(scope, pool, identity, invite, tokens, method, info) do
    with chatgpt_account_id when is_binary(chatgpt_account_id) <-
           present_string(info.chatgpt_account_id),
         {:ok, prepared} <-
           PreparedAccount.prepare(
             scope,
             pool,
             %{
               chatgpt_account_id: chatgpt_account_id,
               chatgpt_user_id: info.chatgpt_user_id,
               account_email: info.email,
               account_label: info.email || identity.account_label,
               workspace_id: info.workspace_id,
               workspace_label: info.workspace_label,
               seat_type: info.seat_type,
               plan_label: info.plan_label,
               access_token: tokens.access_token,
               refresh_token: tokens.refresh_token,
               expires_in: Map.get(tokens, :expires_in),
               received_at: Map.get(tokens, :received_at),
               identity_metadata: %{"invite_id" => invite.id, "onboarding_method" => method}
             },
             credential_provenance: :codex_chatgpt,
             onboarding_method: "invite",
             actor_metadata_key: "invited_by_user_id",
             token_refresh_trigger_kind: "device_authorization"
           ),
         :ok <- PreparedAccount.evaluate(prepared, now()) do
      {:ok, prepared}
    else
      nil ->
        {:error,
         %{
           code: :codex_account_identity_missing,
           message: "Codex account identity was not returned by upstream auth"
         }}

      {:error, reason} ->
        map_preparation_error({:error, reason})
    end
  end

  defp map_preparation_error({:error, %{code: :access_token_expired}}),
    do: {:error, invite_not_usable_error()}

  defp map_preparation_error(result), do: result

  defp revalidate_pending_account(
         invite,
         pool,
         pending_identity,
         pending_assignment,
         locked_rows
       ) do
    identity = Enum.find(locked_rows.identities, &(&1.id == pending_identity.id))
    assignment = Enum.find(locked_rows.assignments, &(&1.id == pending_assignment.id))

    if pending_account?(identity, assignment, invite) and assignment.pool_id == pool.id do
      {:ok, identity, assignment}
    else
      {:error, invite_not_usable_error()}
    end
  end

  defp revalidate_selected_identity(prepared, initially_selected, locked_rows) do
    with {:ok, selected} <- IdentityLifecycle.select_upsert_identity(prepared.attrs),
         true <- identity_id(selected) == identity_id(initially_selected),
         true <- is_nil(selected) or Enum.any?(locked_rows.identities, &(&1.id == selected.id)) do
      :ok
    else
      _changed -> {:error, invite_not_usable_error()}
    end
  end

  defp candidate_identities(prepared, selected_identity) do
    siblings =
      IdentityLifecycle.list_upstream_identities_by_chatgpt_account(
        prepared.attrs.chatgpt_account_id
      )

    [selected_identity | siblings]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp ensure_selected_assignment(_scope, _pool, nil, _prepared), do: :ok

  defp ensure_selected_assignment(scope, pool, selected_identity, prepared) do
    case assignment_for(pool, selected_identity) do
      %PoolUpstreamAssignment{} ->
        :ok

      nil ->
        with :ok <- PreparedAccount.evaluate(prepared, now()) do
          insert_selected_assignment(scope, pool, selected_identity, prepared)
        end
    end
  end

  defp insert_selected_assignment(scope, pool, selected_identity, prepared) do
    timestamp = now()

    result =
      %PoolUpstreamAssignment{}
      |> PoolUpstreamAssignment.changeset(%{
        pool_id: pool.id,
        upstream_identity_id: selected_identity.id,
        assignment_label: selected_identity.account_label,
        status: PoolUpstreamAssignment.pending_status(),
        health_status: PoolUpstreamAssignment.unknown_health_status(),
        eligibility_status: PoolUpstreamAssignment.eligible_status(),
        created_by_user_id: scope.user.id,
        created_at: timestamp,
        updated_at: timestamp,
        metadata: %{
          "invite_id" => prepared.attrs.identity_metadata["invite_id"],
          "onboarding_method" => "invite"
        }
      })
      |> Repo.insert(mode: :savepoint)

    case result do
      {:ok, _assignment} ->
        :ok

      {:error, changeset} ->
        refetch_assignment_after_conflict(pool, selected_identity, changeset)
    end
  end

  defp refetch_assignment_after_conflict(pool, selected_identity, changeset) do
    if assignment_unique_conflict?(changeset) do
      case Repo.one(
             from assignment in PoolUpstreamAssignment,
               where:
                 assignment.pool_id == ^pool.id and
                   assignment.upstream_identity_id == ^selected_identity.id,
               limit: 1
           ) do
        %PoolUpstreamAssignment{} -> :ok
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp assignment_unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint_name] == "pool_upstream_assignments_identity_uq"
    end)
  end

  defp bind_prepared_target(prepared, pending_identity, nil, locked_rows, _pool) do
    if Enum.any?(locked_rows.identities, fn identity ->
         identity.id != pending_identity.id and
           identity.chatgpt_account_id == prepared.attrs.chatgpt_account_id
       end) do
      prepared
    else
      put_in(prepared.attrs.target_identity_id, pending_identity.id)
    end
  end

  defp bind_prepared_target(
         prepared,
         _pending_identity,
         selected_identity,
         _locked_rows,
         pool
       ) do
    if assignment_for(pool, selected_identity) do
      put_in(prepared.attrs.target_identity_id, selected_identity.id)
    else
      prepared
    end
  end

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(nil), do: nil

  defp invite_completion_error(%{code: :access_token_expired}), do: invite_not_usable_error()
  defp invite_completion_error(reason), do: reason

  defp invite_not_usable_error,
    do: %{code: :invite_consumed, message: "invite is expired or already consumed"}

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

  defp consume_verified_invite(invite, identity, assignment, method, info) do
    Invites.consume_invite(invite, %{
      upstream_identity_id: identity.id,
      pool_upstream_assignment_id: assignment.id,
      onboarding_method: method,
      accepted_by_email: info.email,
      details: %{"chatgpt_account_id" => info.chatgpt_account_id}
    })
  end

  defp delete_pending_placeholder(
         %UpstreamIdentity{status: "pending", id: pending_id} = identity,
         %UpstreamIdentity{id: completed_id}
       )
       when pending_id != completed_id,
       do: Repo.delete(identity)

  defp delete_pending_placeholder(_pending_identity, _completed_identity), do: {:ok, nil}

  defp assignment_for(pool, identity) do
    pool.id
    |> UpstreamAssignments.list_pool_assignments()
    |> Enum.find(&(&1.upstream_identity_id == identity.id))
  end

  defp invite_bound?(metadata, invite), do: Map.get(metadata || %{}, "invite_id") == invite.id

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
