defmodule CodexPooler.Access do
  @moduledoc """
  External API key, policy binding, invite, and gateway authorization APIs.
  """

  alias CodexPooler.Access.{APIKey, APIKeys, DashboardSessions, Invite, InviteEmail, Invites}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.Pool

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type auth_context :: %{
          required(:api_key) => APIKey.t(),
          required(:pool) => Pool.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:key_prefix) => String.t()
        }
  @type api_key_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | access_error()}
  @type policy_result :: {:ok, map()} | {:error, atom() | access_error()}
  @type invite_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | access_error()}
  @type pool_invite_email_result :: InviteEmail.pool_invite_result()
  @type invite_page :: Invites.invite_page()
  @type invite_page_result :: Invites.invite_page_result()
  @type dashboard_principal :: DashboardSessions.Principal.t()
  @type dashboard_session_handoff :: DashboardSessions.handoff()

  @spec resolve_reasoning_effort(
          APIKey.t(),
          String.t() | nil,
          [String.t()] | nil,
          String.t() | nil
        ) :: APIKeys.ReasoningEffortPolicy.resolution()
  defdelegate resolve_reasoning_effort(api_key, requested_effort, model_efforts, model_default),
    to: APIKeys

  @spec project_reasoning_effort_metadata(
          APIKey.t() | APIKeys.ReasoningEffortPolicy.normalized_policy(),
          [APIKeys.ReasoningEffortPolicy.model_level()] | nil,
          String.t() | nil
        ) :: APIKeys.ReasoningEffortPolicy.MetadataProjection.t()
  defdelegate project_reasoning_effort_metadata(api_key, model_levels, model_default),
    to: APIKeys

  @spec project_reasoning_effort_denial_metadata(APIKey.t(), String.t() | nil) ::
          APIKeys.ReasoningEffortPolicy.denial_metadata()
  defdelegate project_reasoning_effort_denial_metadata(api_key, requested_effort), to: APIKeys

  @spec create_invite(Scope.t(), Pool.t() | Ecto.UUID.t(), map()) ::
          invite_result()
  defdelegate create_invite(scope, pool_or_id, attrs \\ %{}), to: Invites

  @spec maybe_deliver_pool_invite_email(
          pool_invite_email_result(),
          boolean(),
          binary(),
          Pool.t(),
          Scope.t()
        ) ::
          pool_invite_email_result()
  def maybe_deliver_pool_invite_email(result, send_email?, invite_url, pool, %Scope{} = scope),
    do: InviteEmail.maybe_deliver_pool_invite(result, send_email?, invite_url, pool, scope.user)

  @spec get_invite_by_token(binary()) :: Invite.t() | nil
  defdelegate get_invite_by_token(raw_token), to: Invites

  @spec load_usable_invite(term()) :: {:ok, map()} | {:error, access_error()}
  defdelegate load_usable_invite(raw_token), to: Invites

  @spec load_usable_invite_contract(term()) :: {:ok, map()} | {:error, access_error()}
  defdelegate load_usable_invite_contract(raw_token), to: Invites

  @spec lock_usable_invite(term()) :: {:ok, term()} | {:error, access_error()}
  defdelegate lock_usable_invite(invite), to: Invites

  @spec consume_invite(Invite.t(), map()) :: invite_result()
  defdelegate consume_invite(invite, attrs), to: Invites

  @spec list_invites(Scope.t(), keyword()) :: invite_page_result()
  defdelegate list_invites(scope, opts \\ []), to: Invites

  @spec list_visible_invites(term(), keyword()) :: invite_page()
  defdelegate list_visible_invites(scope, opts \\ []), to: Invites

  @spec revoke_invite(Scope.t(), Invite.t() | Ecto.UUID.t()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate revoke_invite(scope, invite_or_id), to: Invites

  @spec reissue_invite(Scope.t(), Invite.t() | Ecto.UUID.t()) :: invite_result()
  defdelegate reissue_invite(scope, invite_or_id), to: Invites

  @spec create_api_key(Scope.t(), Pool.t() | Ecto.UUID.t(), map()) :: api_key_result()
  defdelegate create_api_key(scope, pool_or_id, attrs \\ %{}), to: APIKeys

  @spec list_api_keys(Scope.t()) :: {:ok, [APIKey.t()]} | {:error, access_error()}
  defdelegate list_api_keys(scope), to: APIKeys

  @spec count_api_keys_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  defdelegate count_api_keys_by_pool_ids(pool_ids), to: APIKeys

  @spec api_key_ids_for_pool(Pool.t()) :: [Ecto.UUID.t()]
  defdelegate api_key_ids_for_pool(pool), to: APIKeys

  @spec assign_api_keys_to_pool(Scope.t(), Pool.t() | Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          :ok | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate assign_api_keys_to_pool(scope, pool_or_id, api_key_ids), to: APIKeys

  @spec list_api_keys_with_policy(Scope.t()) :: {:ok, [map()]} | {:error, access_error()}
  defdelegate list_api_keys_with_policy(scope), to: APIKeys

  @spec list_api_keys(Scope.t(), Pool.t() | Ecto.UUID.t()) ::
          {:ok, [APIKey.t()]} | {:error, access_error()}
  defdelegate list_api_keys(scope, pool_or_id), to: APIKeys

  @spec get_api_key(Scope.t(), Ecto.UUID.t()) :: {:ok, APIKey.t()} | {:error, access_error()}
  defdelegate get_api_key(scope, api_key_id), to: APIKeys

  @spec get_api_key_with_policy(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, access_error()}
  defdelegate get_api_key_with_policy(scope, api_key_id), to: APIKeys

  @spec update_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t(), map()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate update_api_key(scope, api_key, attrs), to: APIKeys

  @spec update_api_key_with_policy(Scope.t(), APIKey.t() | Ecto.UUID.t(), map()) ::
          api_key_result()
  defdelegate update_api_key_with_policy(scope, api_key, attrs), to: APIKeys

  @spec pause_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate pause_api_key(scope, api_key), to: APIKeys

  @spec resume_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate resume_api_key(scope, api_key), to: APIKeys

  @spec rotate_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) :: api_key_result()
  defdelegate rotate_api_key(scope, api_key), to: APIKeys

  @spec revoke_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate revoke_api_key(scope, api_key), to: APIKeys

  @spec delete_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate delete_api_key(scope, api_key), to: APIKeys

  @spec authenticate_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_api_key(raw_key), to: APIKeys

  @spec authenticate_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_authorization_header(header), to: APIKeys

  @spec authenticate_v1_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_v1_authorization_header(header), to: APIKeys

  @spec authenticate_v1_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_v1_api_key(raw_key), to: APIKeys

  @spec issue_dashboard_session(term()) :: DashboardSessions.issue_result()
  defdelegate issue_dashboard_session(raw_api_key), to: DashboardSessions, as: :issue

  @spec authenticate_dashboard_session(term()) ::
          {:ok, dashboard_principal()} | {:error, :invalid_dashboard_session}
  defdelegate authenticate_dashboard_session(token), to: DashboardSessions, as: :authenticate

  @spec dashboard_session_handoff(term()) :: dashboard_session_handoff() | nil
  defdelegate dashboard_session_handoff(token), to: DashboardSessions, as: :handoff

  @spec authenticate_dashboard_session_handoff(term()) ::
          {:ok, dashboard_principal()} | {:error, :invalid_dashboard_session}
  defdelegate authenticate_dashboard_session_handoff(handoff),
    to: DashboardSessions,
    as: :authenticate_handoff

  @spec delete_dashboard_session(term()) :: :ok
  defdelegate delete_dashboard_session(token), to: DashboardSessions, as: :delete

  @spec delete_all_dashboard_sessions(APIKey.t() | Ecto.UUID.t()) :: :ok
  defdelegate delete_all_dashboard_sessions(api_key_or_id), to: DashboardSessions, as: :delete_all

  @spec policy_denial_precedence() :: [atom()]
  defdelegate policy_denial_precedence, to: APIKeys

  @spec normalize_api_key_policy(term()) :: policy_result()
  defdelegate normalize_api_key_policy(policy), to: APIKeys

  @spec authorize_api_key_policy(term(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate authorize_api_key_policy(api_key_or_policy, attrs \\ %{}), to: APIKeys

  @spec hash_api_key_secret(binary()) :: binary()
  defdelegate hash_api_key_secret(secret), to: APIKeys

  @spec access_error(atom(), String.t()) :: access_error()
  defdelegate access_error(code, message), to: APIKeys

  @spec hash_invite_token(binary()) :: binary()
  defdelegate hash_invite_token(token), to: Invites
end
