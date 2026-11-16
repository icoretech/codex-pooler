defmodule CodexPooler.Upstreams.UsageCapPolicy do
  @moduledoc """
  Identity-wide usage cap with scoped, transactional operator updates.

  The cap is the share of the account's long window (weekly, or 30-day on a
  plan without a weekly window), from 1 to 99 percent,
  above which routing stops choosing the account for new work, so its owner
  keeps the rest for their own use. `nil` means no cap. The setting belongs to
  the account, not to one Pool assignment, because the provider's quota does:
  it applies in every Pool the account serves. Routing reads it through
  `CodexPooler.Gateway.Routing.CandidateEligibility.UsageCap`.
  """

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.{AccountAudit, AccountLifecycle, IdentitySlotLock}
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @audit_action "upstream_account.usage_cap_policy_update"
  @broadcast_reason "upstream_account_usage_cap_policy_updated"

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type policy_result :: %{
          required(:status) => :usage_cap_policy_updated | :usage_cap_policy_unchanged,
          required(:identity) => UpstreamIdentity.t(),
          required(:assignments) => [PoolUpstreamAssignment.t()],
          required(:secret_status) => :present | :missing | :expired | :refresh_due | :reauth_required
        }
  @type update_result :: {:ok, policy_result()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @doc false
  @spec audit_action() :: String.t()
  def audit_action, do: @audit_action

  @doc """
  Updates the cap only when the persisted identity is operable across its Pools.

  This auto-publishing boundary rejects caller-owned transactions so subscribers
  cannot observe a change that a surrounding transaction later rolls back.
  """
  @spec update_for_scope(Scope.t(), identity_ref(), map()) :: update_result()
  def update_for_scope(%Scope{user: %User{}} = scope, identity_or_id, attrs) when is_map(attrs) do
    if Repo.in_transaction?() do
      {:error,
       lifecycle_error(
         :transaction_not_allowed,
         "auto-publishing usage cap updates are not allowed inside a caller-owned transaction"
       )}
    else
      update_outside_transaction(scope, identity_or_id, attrs)
    end
  end

  def update_for_scope(_scope, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "user scope and usage cap are required")}

  defp update_outside_transaction(scope, identity_or_id, attrs) do
    with {:ok, identity_id} <- identity_id(identity_or_id) do
      Repo.transact(fn -> update_locked_policy(scope, identity_id, attrs) end)
      |> publish_policy_change()
    end
  end

  defp update_locked_policy(scope, identity_id, attrs) do
    %{identities: identities, assignments: assignments} = IdentitySlotLock.lock_identity_rows!([identity_id])

    with [identity] <- identities,
         {:ok, persisted_identity} <- AccountLifecycle.authorize(scope, identity.id) do
      changeset = UpstreamIdentity.usage_cap_policy_changeset(persisted_identity, attrs)

      apply_policy_change(Ecto.Changeset.apply_action(changeset, :update), scope, persisted_identity, assignments, changeset)
    else
      [] -> {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
      {:error, _reason} = error -> error
    end
  end

  defp apply_policy_change({:ok, requested}, scope, identity, assignments, changeset) do
    if requested.usage_cap_percent == identity.usage_cap_percent do
      {:ok, result(:usage_cap_policy_unchanged, identity, assignments)}
    else
      persist_policy_change(scope, identity, assignments, changeset)
    end
  end

  defp apply_policy_change({:error, changeset}, _scope, _identity, _assignments, _original), do: {:error, changeset}

  defp persist_policy_change(scope, identity, assignments, changeset) do
    with {:ok, updated_identity} <-
           changeset
           |> Ecto.Changeset.put_change(:updated_at, now())
           |> Repo.update() do
      updated_result = result(:usage_cap_policy_updated, updated_identity, assignments)

      AccountAudit.record_change_strict({:ok, updated_result}, scope, @audit_action, usage_cap_change: {identity.usage_cap_percent, updated_identity.usage_cap_percent})
    end
  end

  defp result(status, identity, assignments) do
    %{
      status: status,
      identity: identity,
      assignments: assignments,
      secret_status: Secrets.secret_status(identity)
    }
  end

  defp publish_policy_change({:ok, %{status: :usage_cap_policy_updated} = result} = ok) do
    result.assignments
    |> Enum.uniq_by(& &1.pool_id)
    |> Enum.each(fn assignment ->
      Events.broadcast_upstreams(assignment.pool_id, @broadcast_reason, %{
        upstream_identity_id: result.identity.id
      })
    end)

    ok
  end

  defp publish_policy_change(result), do: result

  defp identity_id(%UpstreamIdentity{id: id}), do: identity_id(id)

  defp identity_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
