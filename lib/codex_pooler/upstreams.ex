defmodule CodexPooler.Upstreams do
  @moduledoc """
  Upstream identity, import, assignment, and operator secret storage APIs.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.{
    Assignments,
    Import,
    OAuth,
    SavedResetPolicy,
    SavedResetRedemptionEnqueue,
    SecretStore,
    TokenRefreshEnqueue
  }

  alias CodexPooler.Upstreams.Lifecycle.{AccountLifecycle, IdentityLifecycle}

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    OAuthFlow,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  @deleted UpstreamIdentity.deleted_status()
  @assignment_deleted PoolUpstreamAssignment.deleted_status()
  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type lifecycle_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type assignment_ref :: PoolUpstreamAssignment.t() | Ecto.UUID.t()
  @type identity_result ::
          {:ok, UpstreamIdentity.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type assignment_result ::
          {:ok, PoolUpstreamAssignment.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type secret_result ::
          {:ok, EncryptedSecret.t() | binary()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type import_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type oauth_flow_start_result :: OAuth.start_result()
  @type oauth_flow_completion_result :: OAuth.completion_result()
  @type oauth_flow_summary :: OAuth.safe_flow_summary()

  @spec list_upstream_identities(keyword()) :: [UpstreamIdentity.t()]
  def list_upstream_identities(opts \\ []) do
    status = Keyword.get(opts, :status)
    excluded_status = Keyword.get(opts, :exclude_status)

    UpstreamIdentity
    |> maybe_where_status(status)
    |> maybe_exclude_status(excluded_status)
    |> order_by([identity], asc: identity.account_label)
    |> Repo.all()
  end

  @spec list_upstream_identities_for_pool_management(Scope.t(), keyword()) ::
          {:ok, [UpstreamIdentity.t()]} | {:error, lifecycle_error()}
  def list_upstream_identities_for_pool_management(scope, opts \\ []) do
    if Pools.can_manage_pools?(scope) do
      {:ok, list_upstream_identities(opts)}
    else
      {:error,
       %{
         code: :capability_denied,
         message: "pool management is required to list upstream account options"
       }}
    end
  end

  @spec list_visible_upstream_identities(Scope.t()) :: [UpstreamIdentity.t()]
  def list_visible_upstream_identities(%Scope{} = scope) do
    pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)

    case pool_ids do
      [] ->
        []

      _ ->
        Repo.all(
          from identity in UpstreamIdentity,
            join: assignment in PoolUpstreamAssignment,
            on: assignment.upstream_identity_id == identity.id,
            where: assignment.pool_id in ^pool_ids,
            where: assignment.status != ^@assignment_deleted,
            where: identity.status != ^@deleted,
            distinct: true,
            order_by: [
              asc: identity.account_label,
              asc: identity.chatgpt_account_id,
              asc: identity.created_at
            ]
        )
    end
  end

  def list_visible_upstream_identities(_scope), do: []

  @spec get_upstream_identity(term()) :: UpstreamIdentity.t() | nil
  def get_upstream_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  def get_upstream_identity(_id), do: nil

  @spec get_upstream_identity_by_chatgpt_account(term()) :: UpstreamIdentity.t() | nil
  defdelegate get_upstream_identity_by_chatgpt_account(chatgpt_account_id),
    to: IdentityLifecycle

  @spec list_upstream_identities_by_chatgpt_account(term()) :: [UpstreamIdentity.t()]
  defdelegate list_upstream_identities_by_chatgpt_account(chatgpt_account_id),
    to: IdentityLifecycle

  @spec get_upstream_identity_by_chatgpt_account_and_workspace(term(), term()) ::
          UpstreamIdentity.t() | nil
  defdelegate get_upstream_identity_by_chatgpt_account_and_workspace(
                chatgpt_account_id,
                workspace_id
              ),
              to: IdentityLifecycle

  @spec import_codex_auth_json(term(), term(), binary()) :: import_result()
  defdelegate import_codex_auth_json(scope, pool, content), to: Import

  @spec start_browser_oauth(Scope.t(), Pool.t(), keyword()) :: oauth_flow_start_result()
  defdelegate start_browser_oauth(scope, pool, opts \\ []), to: OAuth

  @spec start_device_oauth(Scope.t(), Pool.t(), keyword()) :: oauth_flow_start_result()
  defdelegate start_device_oauth(scope, pool, opts \\ []), to: OAuth

  @spec complete_browser_oauth(Scope.t(), Ecto.UUID.t(), String.t()) ::
          oauth_flow_completion_result()
  defdelegate complete_browser_oauth(scope, flow_id, callback_url), to: OAuth

  @spec poll_device_oauth(Scope.t(), Ecto.UUID.t()) :: oauth_flow_completion_result()
  defdelegate poll_device_oauth(scope, flow_id), to: OAuth

  @spec cancel_oauth_flow(Scope.t(), Ecto.UUID.t()) ::
          {:ok, OAuthFlow.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  defdelegate cancel_oauth_flow(scope, flow_id), to: OAuth

  @spec expire_oauth_flows(DateTime.t()) :: %{
          expired: non_neg_integer(),
          deleted: non_neg_integer()
        }
  defdelegate expire_oauth_flows(now), to: OAuth

  @spec cleanup_oauth_flows(DateTime.t()) :: %{
          expired: non_neg_integer(),
          deleted: non_neg_integer()
        }
  defdelegate cleanup_oauth_flows(now), to: OAuth

  @spec list_visible_oauth_flow_summaries(Scope.t(), keyword()) :: [oauth_flow_summary()]
  defdelegate list_visible_oauth_flow_summaries(scope, opts \\ []), to: OAuth

  @spec rename_account_for_scope(Scope.t(), identity_ref(), map()) :: lifecycle_result()
  defdelegate rename_account_for_scope(scope, identity_or_id, attrs), to: AccountLifecycle

  @spec pause_account_for_scope(Scope.t(), identity_ref(), map()) :: lifecycle_result()
  defdelegate pause_account_for_scope(scope, identity_or_id, attrs), to: AccountLifecycle

  @spec reactivate_account_for_scope(Scope.t(), identity_ref(), map()) ::
          lifecycle_result()
  defdelegate reactivate_account_for_scope(scope, identity_or_id, attrs), to: AccountLifecycle

  @spec soft_delete_account_for_scope(Scope.t(), identity_ref(), map()) ::
          lifecycle_result()
  defdelegate soft_delete_account_for_scope(scope, identity_or_id, attrs), to: AccountLifecycle

  @spec enqueue_token_refresh_for_scope(Scope.t(), identity_ref(), keyword()) ::
          {:ok, map()} | {:error, lifecycle_error() | Ecto.Changeset.t()}
  defdelegate enqueue_token_refresh_for_scope(scope, identity_or_id, opts \\ []),
    to: TokenRefreshEnqueue,
    as: :enqueue_for_scope

  @spec update_saved_reset_policy_for_scope(Scope.t(), identity_ref(), map()) ::
          lifecycle_result()
  defdelegate update_saved_reset_policy_for_scope(scope, identity_or_id, attrs),
    to: SavedResetPolicy,
    as: :update_for_scope

  @spec enqueue_saved_reset_redemption_for_scope(
          Scope.t(),
          identity_ref(),
          Ecto.UUID.t(),
          keyword()
        ) ::
          lifecycle_result()
  defdelegate enqueue_saved_reset_redemption_for_scope(
                scope,
                identity_or_id,
                pool_id,
                opts \\ []
              ),
              to: SavedResetRedemptionEnqueue,
              as: :enqueue_for_scope

  @spec sync_pool_assignments_for_pool_edit(Pool.t(), [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, term()}
  defdelegate sync_pool_assignments_for_pool_edit(pool, selected_ids, opts \\ []),
    to: Assignments

  @spec put_assignment_cooldown(assignment_ref(), DateTime.t(), map()) :: assignment_result()
  defdelegate put_assignment_cooldown(assignment_or_id, cooldown_until, attrs \\ %{}),
    to: Assignments

  @spec list_pool_assignments(Pool.t() | Ecto.UUID.t()) :: [PoolUpstreamAssignment.t()]
  defdelegate list_pool_assignments(pool_or_id), to: Assignments

  @spec count_pool_assignments_by_pool_ids([Ecto.UUID.t()]) ::
          %{optional(Ecto.UUID.t()) => non_neg_integer()}
  defdelegate count_pool_assignments_by_pool_ids(pool_ids),
    to: Assignments

  @spec list_active_pool_assignments(Pool.t() | Ecto.UUID.t()) :: [PoolUpstreamAssignment.t()]
  defdelegate list_active_pool_assignments(pool_or_id), to: Assignments

  @spec list_pool_assignments_for_identity(identity_ref()) :: [PoolUpstreamAssignment.t()]
  defdelegate list_pool_assignments_for_identity(identity_or_id),
    to: Assignments

  @spec list_eligible_pool_assignments(Pool.t() | Ecto.UUID.t(), keyword()) ::
          [PoolUpstreamAssignment.t()]
  defdelegate list_eligible_pool_assignments(pool_or_id, opts \\ []),
    to: Assignments

  @spec upsert_encrypted_secret(identity_ref(), map()) :: secret_result()
  def upsert_encrypted_secret(identity_or_id, attrs) when is_map(attrs),
    do: SecretStore.upsert_encrypted_secret(identity_or_id, attrs)

  @spec store_encrypted_secret(identity_ref(), map()) :: secret_result()
  def store_encrypted_secret(identity_or_id, attrs) when is_map(attrs),
    do: SecretStore.store_encrypted_secret(identity_or_id, attrs)

  @spec reconcile_pool_account(
          Pool.t() | Ecto.UUID.t(),
          assignment_ref(),
          keyword()
        ) ::
          lifecycle_result()
  def reconcile_pool_account(pool_or_id, assignment_or_id, opts \\ []),
    do: Assignments.reconcile_pool_account(pool_or_id, assignment_or_id, opts)

  @spec lifecycle_error(atom(), String.t()) :: lifecycle_error()
  def lifecycle_error(code, message), do: %{code: code, message: message}

  defp maybe_where_status(query, nil), do: query

  defp maybe_where_status(query, status),
    do: from(identity in query, where: identity.status == ^status)

  defp maybe_exclude_status(query, nil), do: query

  defp maybe_exclude_status(query, status),
    do: from(identity in query, where: identity.status != ^status)
end
