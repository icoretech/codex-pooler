defmodule CodexPooler.Accounts do
  @moduledoc """
  Operator account, session, bootstrap, and recovery semantics.
  """

  alias CodexPooler.Accounts.{
    Authentication,
    Bootstrap,
    MFA,
    OperatorEvents,
    OperatorManagement,
    Scope,
    Session,
    User
  }

  alias CodexPooler.Repo

  @type auth_error :: {:error, atom()}
  @type auth_result ::
          {:ok, %{user: %User{}, session: %Session{}, token: binary()}} | {:error, term()}
  @type user_session_summary :: Authentication.user_session_summary()
  @type operator_result :: {:ok, map() | User.t()} | {:error, Ecto.Changeset.t() | atom()}

  @spec get_user_by_email(term()) :: User.t() | nil
  defdelegate get_user_by_email(email), to: Authentication

  @spec get_user_by_email_and_password(term(), term()) :: User.t() | nil
  defdelegate get_user_by_email_and_password(email, password), to: Authentication

  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec list_operators() :: [User.t()]
  defdelegate list_operators(), to: OperatorManagement

  @spec subscribe_operator_updates() :: :ok | {:error, term()}
  def subscribe_operator_updates, do: OperatorEvents.subscribe_updates()

  @spec list_operators_for_management(Scope.t() | User.t()) ::
          {:ok, [User.t()]} | {:error, :operator_management_denied}
  defdelegate list_operators_for_management(actor), to: OperatorManagement

  @spec change_new_operator(map()) :: Ecto.Changeset.t()
  defdelegate change_new_operator(attrs \\ %{}), to: OperatorManagement

  @spec change_operator(User.t()) :: Ecto.Changeset.t()
  defdelegate change_operator(user), to: OperatorManagement

  @spec operator_lifecycle(User.t()) :: OperatorManagement.operator_lifecycle()
  defdelegate operator_lifecycle(user), to: OperatorManagement

  @spec create_operator(Scope.t() | User.t(), map(), map()) :: operator_result()
  defdelegate create_operator(actor, attrs, metadata \\ %{}), to: OperatorManagement

  @spec update_operator(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          operator_result()
  defdelegate update_operator(actor, operator, attrs, metadata \\ %{}), to: OperatorManagement

  @spec update_current_operator_profile(User.t(), OperatorManagement.profile_attrs(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  defdelegate update_current_operator_profile(user, attrs, metadata \\ %{}),
    to: OperatorManagement

  @spec deactivate_operator(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  defdelegate deactivate_operator(actor, operator, attrs, metadata \\ %{}),
    to: OperatorManagement

  @spec reactivate_operator(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          operator_result()
  defdelegate reactivate_operator(actor, operator, attrs, metadata \\ %{}),
    to: OperatorManagement

  @spec reset_operator_password(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          operator_result()
  defdelegate reset_operator_password(actor, operator, attrs, metadata \\ %{}),
    to: OperatorManagement

  @spec resend_operator_temporary_password(
          Scope.t() | User.t(),
          User.t() | Ecto.UUID.t(),
          map(),
          map()
        ) :: operator_result()
  defdelegate resend_operator_temporary_password(actor, operator, attrs, metadata \\ %{}),
    to: OperatorManagement

  @spec generate_temporary_password() :: binary()
  defdelegate generate_temporary_password(), to: OperatorManagement

  @spec bootstrap_status() :: String.t()
  def bootstrap_status, do: Bootstrap.status()

  @spec bootstrap_pending?() :: boolean()
  def bootstrap_pending?, do: Bootstrap.pending?()

  @spec change_bootstrap(map()) :: Ecto.Changeset.t()
  def change_bootstrap(attrs \\ %{}), do: Bootstrap.change(attrs)

  @spec bootstrap_owner(map(), map()) :: auth_result()
  def bootstrap_owner(attrs, metadata \\ %{}), do: Bootstrap.create_owner(attrs, metadata)

  @spec login_user(map(), map()) :: auth_result() | auth_error()
  defdelegate login_user(attrs, metadata \\ %{}), to: Authentication

  @spec complete_second_factor_login(term(), map(), map()) :: auth_result() | auth_error()
  defdelegate complete_second_factor_login(user_id, attrs, metadata \\ %{}), to: Authentication

  @spec get_user_by_session_token(term()) :: {User.t(), DateTime.t()} | nil
  defdelegate get_user_by_session_token(token), to: Authentication

  @spec authenticate_session_token(term()) :: {User.t(), DateTime.t()} | nil
  defdelegate authenticate_session_token(token), to: Authentication

  @spec session_id_for_token(term()) :: Ecto.UUID.t() | nil
  defdelegate session_id_for_token(token), to: Authentication

  @spec list_user_sessions(User.t(), binary() | nil) :: [user_session_summary()]
  defdelegate list_user_sessions(user, current_token \\ nil), to: Authentication

  @spec roles_for_user(User.t()) :: [String.t()]
  defdelegate roles_for_user(user), to: Authentication

  @spec delete_user_session_token(term()) :: :ok
  defdelegate delete_user_session_token(token), to: Authentication

  @spec logout_user(term(), User.t(), map()) :: :ok
  defdelegate logout_user(token, user, metadata \\ %{}), to: Authentication

  @spec revoke_other_user_sessions(User.t(), binary() | nil, map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate revoke_other_user_sessions(user, current_token, metadata \\ %{}), to: Authentication

  @spec revoke_user_session(User.t(), Ecto.UUID.t(), binary() | nil, map()) ::
          {:ok, %{current?: boolean(), revoked_count: non_neg_integer()}} | {:error, term()}
  defdelegate revoke_user_session(user, session_id, current_token, metadata \\ %{}),
    to: Authentication

  @spec change_user_password(User.t(), map(), map()) :: auth_result() | auth_error()
  defdelegate change_user_password(user, attrs, metadata \\ %{}), to: Authentication

  @spec change_current_user_password(User.t(), map(), map(), binary() | nil) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  defdelegate change_current_user_password(user, attrs, metadata \\ %{}, current_token \\ nil),
    to: Authentication

  @spec complete_required_password_change(User.t(), map(), map(), term()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  defdelegate complete_required_password_change(
                user,
                attrs,
                metadata \\ %{},
                current_token \\ nil
              ),
              to: Authentication

  @spec enable_totp_for_user(User.t()) :: {:ok, map()} | {:error, term()}
  defdelegate enable_totp_for_user(user), to: MFA

  @spec totp_enabled?(User.t()) :: boolean()
  defdelegate totp_enabled?(user), to: MFA

  @spec current_totp_code(binary()) :: String.t()
  defdelegate current_totp_code(secret), to: MFA
end
