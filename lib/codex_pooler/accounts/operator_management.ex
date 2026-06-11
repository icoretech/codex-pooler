defmodule CodexPooler.Accounts.OperatorManagement do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias CodexPooler.Accounts.{
    AuditLog,
    OperatorEmail,
    OperatorEvents,
    OperatorPasswords,
    Scope,
    Session,
    SessionNotifier,
    TOTPSetting,
    User
  }

  alias CodexPooler.Accounts.{OperatorAssignments, OperatorRoles}
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @datetime_formats ~w(default short long iso8601)

  @type operator_result :: CodexPooler.Accounts.operator_result()
  @type operator_lifecycle :: %{
          required(:role) => String.t(),
          required(:assigned_pool_ids) => [Ecto.UUID.t()]
        }
  @type lifecycle_attrs :: %{
          required(:role) => String.t(),
          required(:pool_ids) => [Ecto.UUID.t()]
        }
  @type profile_attrs :: %{
          optional(:email) => String.t() | nil,
          optional(:display_name) => String.t() | nil,
          optional(:datetime_format) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(String.t()) => String.t() | nil | boolean()
        }

  @spec list_operators() :: [User.t()]
  def list_operators do
    Repo.all(
      from u in User,
        left_join: t in TOTPSetting,
        on: t.user_id == u.id and t.status == "active",
        where: is_nil(u.deleted_at),
        select_merge: %{totp_status: t.status},
        order_by: [asc: fragment("lower(?)", u.email), asc: u.id]
    )
  end

  @spec list_operators_for_management(Scope.t() | User.t()) ::
          {:ok, [User.t()]} | {:error, :operator_management_denied}
  def list_operators_for_management(actor) do
    with {:ok, _actor} <- require_operator_management(actor) do
      {:ok, list_operators()}
    end
  end

  @spec change_new_operator(map()) :: Ecto.Changeset.t()
  def change_new_operator(attrs \\ %{}) when is_map(attrs),
    do: User.operator_create_changeset(%User{}, attrs)

  @spec change_operator(User.t()) :: Ecto.Changeset.t()
  def change_operator(%User{} = user), do: User.operator_update_changeset(user, %{})

  @spec operator_lifecycle(User.t()) :: operator_lifecycle()
  def operator_lifecycle(%User{} = user), do: operator_lifecycle_snapshot(user)

  @spec create_operator(Scope.t() | User.t(), map(), map()) :: operator_result()
  def create_operator(actor, attrs, metadata \\ %{}) do
    with {:ok, actor} <- require_operator_management(actor) do
      temporary_password = OperatorPasswords.temporary_password_from_attrs(attrs)
      send_email? = OperatorPasswords.send_email?(attrs)
      attrs = Map.put(attrs || %{}, "password", temporary_password)

      actor
      |> create_operator_with_password(attrs, metadata, temporary_password)
      |> OperatorEmail.maybe_deliver_operator_access(send_email?)
      |> broadcast_operator_change("operator.create")
    end
  end

  @spec update_operator(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          operator_result()
  def update_operator(actor, operator, attrs, metadata \\ %{})

  def update_operator(actor, operator, attrs, metadata) do
    with {:ok, actor} <- require_operator_management(actor),
         {:ok, operator} <- get_operator_target(operator) do
      update_operator_target(actor, operator, attrs, metadata)
      |> broadcast_operator_change("operator.update")
    end
  end

  @spec update_current_operator_profile(User.t(), profile_attrs(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_current_operator_profile(user, attrs, metadata \\ %{})

  def update_current_operator_profile(%User{} = user, attrs, metadata) when is_map(attrs) do
    update_current_operator_profile_target(user, attrs, metadata)
    |> broadcast_operator_change("operator.update")
  end

  def update_current_operator_profile(_user, _attrs, _metadata), do: {:error, :invalid_session}

  @spec deactivate_operator(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def deactivate_operator(actor, operator, attrs, metadata \\ %{})

  def deactivate_operator(actor, operator, attrs, metadata) do
    with {:ok, actor} <- require_operator_management(actor),
         {:ok, operator} <- get_operator_target(operator) do
      deactivate_operator_target(actor, operator, attrs, metadata)
      |> broadcast_operator_change("operator.deactivate")
    end
  end

  @spec reactivate_operator(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          operator_result()
  def reactivate_operator(actor, operator, attrs, metadata \\ %{})

  def reactivate_operator(actor, operator, attrs, metadata) do
    temporary_password = OperatorPasswords.temporary_password_from_attrs(attrs)
    send_email? = OperatorPasswords.send_email?(attrs)

    result =
      with {:ok, actor} <- require_operator_management(actor),
           {:ok, operator} <- get_operator_target(operator) do
        reactivate_operator_target(actor, operator, attrs, metadata, temporary_password)
      end
      |> broadcast_user_session_revocation()

    result
    |> OperatorEmail.maybe_deliver_operator_access(send_email?)
    |> broadcast_operator_change("operator.reactivate")
  end

  @spec reset_operator_password(Scope.t() | User.t(), User.t() | Ecto.UUID.t(), map(), map()) ::
          operator_result()
  def reset_operator_password(actor, operator, attrs, metadata \\ %{})

  def reset_operator_password(actor, operator, attrs, metadata) do
    send_email? = OperatorPasswords.send_email?(attrs)

    set_operator_temporary_password(
      actor,
      operator,
      attrs,
      metadata,
      "operator.password_reset"
    )
    |> OperatorEmail.maybe_deliver_temporary_password(send_email?)
    |> broadcast_operator_change("operator.password_reset")
  end

  @spec resend_operator_temporary_password(
          Scope.t() | User.t(),
          User.t() | Ecto.UUID.t(),
          map(),
          map()
        ) :: operator_result()
  def resend_operator_temporary_password(actor, operator, attrs, metadata \\ %{})

  def resend_operator_temporary_password(actor, operator, attrs, metadata) do
    send_email? = OperatorPasswords.send_email?(attrs)

    set_operator_temporary_password(
      actor,
      operator,
      attrs,
      metadata,
      "operator.temporary_password_resend"
    )
    |> OperatorEmail.maybe_deliver_temporary_password(send_email?)
    |> broadcast_operator_change("operator.temporary_password_resend")
  end

  @spec generate_temporary_password() :: binary()
  defdelegate generate_temporary_password(), to: OperatorPasswords

  defp require_operator_management(%Scope{user: %User{}} = scope) do
    scope
    |> Pools.require_capability(Pools.capability(:pool_manage))
    |> operator_management_result(scope)
  end

  defp require_operator_management(%User{} = user) do
    user
    |> Scope.for_user()
    |> Pools.require_capability(Pools.capability(:pool_manage))
    |> operator_management_result(user)
  end

  defp require_operator_management(_actor), do: {:error, :operator_management_denied}
  defp operator_management_result({:ok, _decision}, actor), do: {:ok, actor}

  defp operator_management_result({:error, _reason}, _actor),
    do: {:error, :operator_management_denied}

  defp create_operator_with_password(actor, attrs, metadata, temporary_password) do
    Repo.transaction(fn ->
      with {:ok, lifecycle_attrs} <- normalize_lifecycle_attrs(attrs),
           {:ok, user} <-
             %User{}
             |> User.operator_create_changeset(attrs)
             |> put_change(:updated_at, DateTime.utc_now())
             |> Repo.insert(),
           {:ok, role_summary} <-
             OperatorRoles.ensure_in_transaction(actor, user, lifecycle_attrs.role),
           {:ok, assignment_summary} <-
             OperatorAssignments.replace_in_transaction(
               actor,
               user,
               lifecycle_attrs.role,
               lifecycle_attrs.pool_ids
             ),
           {:ok, _audit} <-
             record_operator_audit(
               actor,
               "operator.create",
               user,
               metadata,
               operator_lifecycle_audit_details(user, role_summary, assignment_summary)
             ) do
        %{user: user, temporary_password: temporary_password}
      else
        error -> rollback_transaction_error(error)
      end
    end)
    |> normalize_transaction_error()
  end

  defp update_operator_target(actor, operator, attrs, metadata) do
    operator_for_update_transaction(operator.id, fn operator ->
      update_operator_in_transaction(actor, operator, attrs || %{}, metadata)
    end)
  end

  defp update_operator_in_transaction(actor, operator, attrs, metadata) do
    previous_lifecycle = operator_lifecycle_snapshot(operator)

    with {:ok, lifecycle_attrs} <- normalize_update_lifecycle_attrs(operator, attrs),
         {:ok, operator} <-
           operator
           |> User.operator_update_changeset(attrs)
           |> put_change(:updated_at, DateTime.utc_now())
           |> Repo.update(),
         {:ok, role_summary} <-
           OperatorRoles.ensure_in_transaction(actor, operator, lifecycle_attrs.role),
         {:ok, assignment_summary} <-
           OperatorAssignments.replace_in_transaction(
             actor,
             operator,
             lifecycle_attrs.role,
             lifecycle_attrs.pool_ids
           ),
         {:ok, _audit} <-
           record_operator_audit(
             actor,
             "operator.update",
             operator,
             metadata,
             operator_lifecycle_audit_details(
               operator,
               role_summary,
               assignment_summary,
               previous_lifecycle
             )
           ) do
      operator
    else
      error -> rollback_transaction_error(error)
    end
  end

  defp update_current_operator_profile_target(user, attrs, metadata) do
    attrs = operator_profile_attrs(attrs)

    operator_for_update_transaction(user.id, fn user ->
      with {:ok, user} <-
             user
             |> operator_profile_changeset(attrs)
             |> put_change(:updated_at, DateTime.utc_now())
             |> Repo.update(),
           {:ok, _audit} <-
             record_operator_audit(user, "operator.update", user, metadata, %{email: user.email}) do
        user
      else
        error -> rollback_transaction_error(error)
      end
    end)
  end

  defp operator_profile_changeset(user, attrs) do
    user
    |> User.operator_update_changeset(attrs)
    |> cast(attrs, [:datetime_format, :timezone])
    |> validate_datetime_preferences()
  end

  defp validate_datetime_preferences(changeset) do
    changeset
    |> validate_required([:datetime_format, :timezone])
    |> validate_inclusion(:datetime_format, @datetime_formats)
    |> check_constraint(:datetime_format, name: :users_datetime_format_check)
    |> validate_change(:timezone, &validate_timezone/2)
  end

  defp validate_timezone(:timezone, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), timezone, Zoneinfo.TimeZoneDatabase) do
      {:ok, _datetime} -> []
      {:error, _reason} -> [timezone: "must be a valid IANA time zone"]
    end
  end

  defp validate_timezone(:timezone, _timezone), do: [timezone: "must be a valid IANA time zone"]

  @spec operator_profile_attrs(map()) :: profile_attrs()
  defp operator_profile_attrs(attrs) do
    %{}
    |> maybe_put_profile_attr(attrs, :email)
    |> maybe_put_profile_attr(attrs, :display_name)
    |> maybe_put_profile_attr(attrs, :datetime_format)
    |> maybe_put_profile_attr(attrs, :timezone)
  end

  defp maybe_put_profile_attr(profile_attrs, attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) ->
        Map.put(profile_attrs, key, Map.get(attrs, key))

      Map.has_key?(attrs, string_key) ->
        Map.put(profile_attrs, string_key, Map.get(attrs, string_key))

      true ->
        profile_attrs
    end
  end

  defp deactivate_operator_target(actor, operator, attrs, metadata) do
    operator.id
    |> operator_for_update_transaction(fn operator ->
      if OperatorRoles.final_active_owner?(operator) do
        Repo.rollback(:last_active_owner)
      else
        deactivate_operator_in_transaction(actor, operator, attrs, metadata)
      end
    end)
    |> broadcast_user_session_revocation()
  end

  defp deactivate_operator_in_transaction(actor, operator, attrs, metadata) do
    update_operator_with_revocation(
      actor,
      operator,
      "operator.deactivate",
      metadata,
      fn operator ->
        %{
          email: operator.email,
          reason: normalized_reason(attrs)
        }
      end,
      fn operator, now ->
        operator
        |> change(status: "disabled", updated_at: now)
        |> Repo.update()
      end
    )
  end

  defp reactivate_operator_target(actor, operator, attrs, metadata, temporary_password) do
    operator_for_update_transaction(operator.id, fn operator ->
      reactivate_operator_in_transaction(actor, operator, attrs, metadata, temporary_password)
    end)
  end

  defp reactivate_operator_in_transaction(actor, operator, attrs, metadata, temporary_password) do
    operator =
      update_operator_with_revocation(
        actor,
        operator,
        "operator.reactivate",
        metadata,
        fn operator ->
          %{
            email: operator.email,
            reason: normalized_reason(attrs)
          }
        end,
        fn operator, now ->
          password_attrs =
            OperatorPasswords.temporary_password_changeset_attrs(attrs, temporary_password)

          operator
          |> User.operator_temporary_password_changeset(password_attrs)
          |> put_change(:status, "active")
          |> put_change(:updated_at, now)
          |> Repo.update()
        end
      )

    %{user: operator, temporary_password: temporary_password}
  end

  defp set_operator_temporary_password(actor, operator, attrs, metadata, action) do
    temporary_password = OperatorPasswords.temporary_password_from_attrs(attrs)

    password_attrs =
      OperatorPasswords.temporary_password_changeset_attrs(attrs, temporary_password)

    with {:ok, actor} <- require_operator_management(actor),
         {:ok, operator} <- get_operator_target(operator) do
      operator_for_update_transaction(operator.id, fn operator ->
        update_operator_temporary_password(
          actor,
          operator,
          password_attrs,
          temporary_password,
          metadata,
          action
        )
      end)
    end
    |> broadcast_user_session_revocation()
  end

  defp update_operator_temporary_password(
         actor,
         operator,
         password_attrs,
         temporary_password,
         metadata,
         action
       ) do
    now = DateTime.utc_now()

    with {:ok, operator} <-
           operator
           |> User.operator_temporary_password_changeset(password_attrs)
           |> put_change(:updated_at, now)
           |> Repo.update(),
         {_count, _rows} <- revoke_active_sessions_for_user(operator, now),
         {:ok, _audit} <-
           record_operator_audit(actor, action, operator, metadata, %{email: operator.email}) do
      %{user: operator, temporary_password: temporary_password}
    else
      error -> rollback_transaction_error(error)
    end
  end

  defp update_operator_with_revocation(
         actor,
         operator,
         action,
         metadata,
         details_builder,
         update_operator
       ) do
    now = DateTime.utc_now()

    with {:ok, operator} <- update_operator.(operator, now),
         {_count, _rows} <- revoke_active_sessions_for_user(operator, now),
         {:ok, _audit} <-
           record_operator_audit(
             actor,
             action,
             operator,
             metadata,
             details_builder.(operator)
           ) do
      operator
    else
      error -> rollback_transaction_error(error)
    end
  end

  defp normalize_lifecycle_attrs(attrs) do
    with {:ok, role} <-
           OperatorRoles.normalize(map_value(attrs, :role) || OperatorRoles.default()),
         {:ok, pool_ids} <- OperatorAssignments.normalize_pool_ids(map_value(attrs, :pool_ids)),
         :ok <- OperatorAssignments.ensure_pool_ids_exist(pool_ids) do
      {:ok, %{role: role, pool_ids: OperatorAssignments.role_pool_ids(role, pool_ids)}}
    end
  end

  defp normalize_update_lifecycle_attrs(operator, attrs) do
    current_lifecycle = operator_lifecycle_snapshot(operator)

    with {:ok, role} <- OperatorRoles.normalize(map_value(attrs, :role) || current_lifecycle.role),
         {:ok, pool_ids} <-
           OperatorAssignments.normalize_pool_ids(
             map_value(attrs, :pool_ids, current_lifecycle.assigned_pool_ids)
           ),
         :ok <- OperatorAssignments.ensure_pool_ids_exist(pool_ids) do
      {:ok, %{role: role, pool_ids: OperatorAssignments.role_pool_ids(role, pool_ids)}}
    end
  end

  defp operator_lifecycle_snapshot(%User{} = operator) do
    role = OperatorRoles.current(operator) || OperatorRoles.default()

    %{
      role: role,
      assigned_pool_ids:
        if(role == Pools.role(:instance_admin),
          do: OperatorAssignments.current_pool_ids(operator),
          else: []
        )
    }
  end

  defp map_value(attrs, key), do: map_value(attrs, key, nil)

  defp map_value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, Atom.to_string(key), Map.get(attrs, key, default))
  end

  defp map_value(_attrs, _key, default), do: default

  defp operator_lifecycle_audit_details(operator, role_summary, assignment_summary) do
    operator_lifecycle_audit_details(operator, role_summary, assignment_summary, nil)
  end

  defp operator_lifecycle_audit_details(
         operator,
         role_summary,
         assignment_summary,
         previous_lifecycle
       ) do
    %{
      email: operator.email,
      previous_role:
        Map.get(role_summary, :previous_role) ||
          if(previous_lifecycle, do: previous_lifecycle.role),
      role: role_summary.role,
      revoked_roles: role_summary.revoked_roles,
      previous_assigned_pool_ids: assignment_summary.previous_pool_ids,
      assigned_pool_ids: assignment_summary.assigned_pool_ids,
      added_pool_ids: assignment_summary.added_pool_ids,
      removed_pool_ids: assignment_summary.removed_pool_ids,
      assigned_pool_count: length(assignment_summary.assigned_pool_ids)
    }
  end

  defp record_operator_audit(actor, action, operator, metadata, details) do
    AuditLog.record_user_event(actor, %{
      action: action,
      target_type: "user",
      target_id: operator.id,
      metadata: metadata,
      details: details
    })
  end

  defp rollback_transaction_error({:error, %Ecto.Changeset{} = changeset}),
    do: Repo.rollback(changeset)

  defp rollback_transaction_error({:error, reason}), do: Repo.rollback(reason)
  defp rollback_transaction_error(reason), do: Repo.rollback(reason)

  defp operator_for_update_transaction(operator_id, callback) do
    Repo.transaction(fn ->
      case lock_user(operator_id) do
        {:ok, operator} -> callback.(operator)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_error()
  end

  defp get_operator_target(%User{} = user), do: {:ok, user}

  defp get_operator_target(operator_id) when is_binary(operator_id) do
    case Repo.get(User, operator_id) do
      %User{deleted_at: nil} = user -> {:ok, user}
      _user -> {:error, :invalid_operator}
    end
  end

  defp get_operator_target(_operator), do: {:error, :invalid_operator}

  defp lock_user(user_id) do
    case Repo.one(
           from u in User, where: u.id == ^user_id and is_nil(u.deleted_at), lock: "FOR UPDATE"
         ) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :invalid_operator}
    end
  end

  defp revoke_active_sessions_for_user(user, now) do
    Repo.update_all(
      from(s in Session, where: s.user_id == ^user.id and s.status == "active"),
      set: [status: "revoked", revoked_at: now]
    )
  end

  defp broadcast_user_session_revocation({:ok, %User{} = user} = result) do
    SessionNotifier.disconnect_user_sessions(user.id)
    result
  end

  defp broadcast_user_session_revocation({:ok, %{user: %User{} = user}} = result) do
    SessionNotifier.disconnect_user_sessions(user.id)
    result
  end

  defp broadcast_user_session_revocation(result), do: result

  defp broadcast_operator_change({:ok, %User{} = operator} = result, reason) do
    _ =
      OperatorEvents.broadcast_update(reason, %{
        operator_id: operator.id,
        status: operator.status
      })

    result
  end

  defp broadcast_operator_change({:ok, %{user: %User{} = operator}} = result, reason) do
    _ =
      OperatorEvents.broadcast_update(reason, %{
        operator_id: operator.id,
        status: operator.status
      })

    result
  end

  defp broadcast_operator_change(result, _reason), do: result

  defp normalize_transaction_error({:ok, value}), do: {:ok, value}

  defp normalize_transaction_error({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset}

  defp normalize_transaction_error({:error, reason}), do: {:error, reason}

  defp normalized_reason(attrs) when is_map(attrs) do
    case Map.get(attrs, "reason") || Map.get(attrs, :reason) do
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
  end

  defp normalized_reason(_attrs), do: nil
end
