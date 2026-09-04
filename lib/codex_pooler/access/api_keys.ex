defmodule CodexPooler.Access.APIKeys do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions
  alias CodexPooler.Access.DashboardSessions.Lifecycle, as: DashboardSessionLifecycle

  alias CodexPooler.Access.APIKeys.{
    Assignment,
    AuditLog,
    Authentication,
    Errors,
    Material,
    Notifications,
    Policy,
    PolicyPersistence,
    PolicyUpdate,
    Queries,
    ReasoningEffortPolicy,
    RuntimeAuthorization
  }

  alias CodexPooler.Accounting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Authorization, as: PoolAuthorization
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @status_active "active"
  @status_paused "paused"
  @status_revoked "revoked"
  @policy_denial_precedence [
    :api_key_missing,
    :api_key_disabled,
    :api_key_policy_malformed,
    :model_not_allowed,
    :quota_unavailable,
    :quota_exhausted,
    :no_eligible_upstream
  ]

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

  @spec capture_runtime_authorization_epoch(APIKey.t() | Ecto.UUID.t()) ::
          {:ok, RuntimeAuthorization.epoch()} | {:error, RuntimeAuthorization.disposition()}
  defdelegate capture_runtime_authorization_epoch(api_key_or_id),
    to: RuntimeAuthorization,
    as: :capture

  @spec authorize_runtime_turn(APIKey.t() | Ecto.UUID.t(), RuntimeAuthorization.epoch()) ::
          {:ok, RuntimeAuthorization.authorization()}
          | {:error, RuntimeAuthorization.disposition()}
  defdelegate authorize_runtime_turn(api_key_or_id, captured_epoch),
    to: RuntimeAuthorization,
    as: :authorize_turn

  @spec runtime_epoch_for_status_change(APIKey.t(), String.t()) ::
          RuntimeAuthorization.epoch()
  defdelegate runtime_epoch_for_status_change(api_key, target_status),
    to: RuntimeAuthorization,
    as: :epoch_for_status_change

  @spec resolve_reasoning_effort(
          APIKey.t(),
          String.t() | nil,
          [String.t()] | nil,
          String.t() | nil
        ) :: ReasoningEffortPolicy.resolution()
  defdelegate resolve_reasoning_effort(api_key, requested_effort, model_efforts, model_default),
    to: ReasoningEffortPolicy,
    as: :resolve

  @spec project_reasoning_effort_metadata(
          APIKey.t() | ReasoningEffortPolicy.normalized_policy(),
          [ReasoningEffortPolicy.model_level()] | nil,
          String.t() | nil
        ) :: ReasoningEffortPolicy.MetadataProjection.t()
  defdelegate project_reasoning_effort_metadata(api_key, model_levels, model_default),
    to: ReasoningEffortPolicy,
    as: :project_metadata

  @spec project_reasoning_effort_denial_metadata(APIKey.t(), String.t() | nil) ::
          ReasoningEffortPolicy.denial_metadata()
  defdelegate project_reasoning_effort_denial_metadata(api_key, requested_effort),
    to: ReasoningEffortPolicy,
    as: :project_denial_metadata

  @spec create_api_key(Scope.t(), Pool.t() | Ecto.UUID.t(), map()) ::
          api_key_result()
  def create_api_key(scope, pool_or_id, attrs \\ %{})

  def create_api_key(%Scope{} = scope, pool_or_id, attrs) when is_map(attrs) do
    create_api_key_lifecycle(scope, pool_or_id, attrs)
  end

  def create_api_key(_scope, _pool_or_id, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp create_api_key_lifecycle(%Scope{} = scope, pool_or_id, attrs) do
    with %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: pool.id
           ),
         {:ok, expires_at} <-
           parse_expires_at(Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at")),
         {:ok, policy_attrs} <- Policy.normalize_attrs(scope, pool.id, attrs),
         {:ok, policy_inputs} <- Policy.normalize_inputs(attrs) do
      now = now()
      {key_prefix, raw_key, key_hash} = Material.generate()

      api_key_attrs =
        policy_attrs
        |> Map.merge(%{
          pool_id: pool.id,
          display_name: Map.get(attrs, :display_name) || Map.get(attrs, "display_name"),
          key_prefix: key_prefix,
          key_hash: key_hash,
          status: Map.get(attrs, :status) || Map.get(attrs, "status") || @status_active,
          dashboard_access: Policy.input(attrs, [:dashboard_access, "dashboard_access"]) || false,
          expires_at: expires_at,
          metadata: Policy.input(attrs, [:metadata, "metadata"]) || %{},
          created_by_user_id: scope.user.id,
          created_at: now
        })

      PolicyPersistence.create_api_key(api_key_attrs, policy_inputs, raw_key, now)
      |> PolicyPersistence.normalize_transaction_result()
      |> AuditLog.audit_api_key_change(
        scope,
        "api_key.create",
        &AuditLog.api_key_policy_audit_details/1
      )
      |> Notifications.notify_api_key_change("api_key_created")
    else
      nil -> {:error, Errors.access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  @spec list_api_keys(Scope.t()) :: {:ok, [APIKey.t()]} | {:error, access_error()}
  defdelegate list_api_keys(scope), to: Queries

  @spec count_api_keys_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  defdelegate count_api_keys_by_pool_ids(pool_ids), to: Queries

  @spec api_key_ids_for_pool(Pool.t()) :: [Ecto.UUID.t()]
  defdelegate api_key_ids_for_pool(pool), to: Queries

  @spec assign_api_keys_to_pool(
          Scope.t(),
          Pool.t() | Ecto.UUID.t(),
          [Ecto.UUID.t()]
        ) ::
          :ok | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate assign_api_keys_to_pool(scope, pool_or_id, api_key_ids), to: Assignment

  @spec list_api_keys_with_policy(Scope.t()) :: {:ok, [map()]} | {:error, access_error()}
  defdelegate list_api_keys_with_policy(scope), to: Queries

  @spec list_api_keys(Scope.t(), Pool.t() | Ecto.UUID.t()) ::
          {:ok, [APIKey.t()]} | {:error, access_error()}
  defdelegate list_api_keys(scope, pool_or_id), to: Queries

  @spec get_api_key(Scope.t(), Ecto.UUID.t()) :: {:ok, APIKey.t()} | {:error, access_error()}
  defdelegate get_api_key(scope, api_key_id), to: Queries

  @spec get_api_key_with_policy(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, access_error()}
  defdelegate get_api_key_with_policy(scope, api_key_id), to: Queries

  @spec update_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t(), map()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def update_api_key(%Scope{} = scope, %APIKey{} = api_key, attrs) when is_map(attrs) do
    case update_api_key_transaction(scope, api_key, attrs) do
      {:ok, {updated_api_key, previous_api_key, invalidate_dashboard_sessions?, notification}} ->
        maybe_broadcast_dashboard_invalidation(
          updated_api_key,
          "api_key_updated",
          invalidate_dashboard_sessions?
        )

        {:ok, updated_api_key}
        |> notify_api_key_update(previous_api_key, notification)
        |> AuditLog.audit_api_key_change(scope, "api_key.update", fn updated ->
          AuditLog.api_key_update_audit_details(updated, previous_api_key, attrs)
        end)

      {:error, _reason} = error ->
        error
    end
  end

  def update_api_key(%Scope{} = scope, api_key_id, attrs) when is_binary(api_key_id) do
    with {:ok, api_key} <- get_api_key(scope, api_key_id) do
      update_api_key(scope, api_key, attrs)
    end
  end

  def update_api_key(_scope, _api_key, _attrs),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec update_api_key_with_policy(
          Scope.t(),
          APIKey.t() | Ecto.UUID.t(),
          map()
        ) :: api_key_result()
  defdelegate update_api_key_with_policy(scope, api_key, attrs), to: PolicyUpdate

  defp authorize_api_key_update(%Scope{} = scope, %APIKey{} = api_key, attrs) do
    target_pool_id = Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") || api_key.pool_id

    with %Pool{} = _target_pool <- normalize_pool(target_pool_id),
         {:ok, _existing_decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ),
         {:ok, _target_decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: target_pool_id
           ) do
      {:ok, target_pool_id}
    else
      nil -> {:error, Errors.access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  defp update_api_key_transaction(scope, api_key, attrs) do
    Repo.transact(fn ->
      target_status = requested_status(attrs, api_key.status)

      with {:ok, transition} <-
             RuntimeAuthorization.prepare_status_transition(api_key, target_status),
           previous_api_key = transition.api_key,
           {:ok, target_pool_id} <- authorize_api_key_update(scope, previous_api_key, attrs),
           update_attrs = api_key_update_attrs(attrs, target_pool_id),
           {:ok, updated_api_key} <-
             update_api_key_record(previous_api_key, update_attrs, transition) do
        {:ok,
         {
           updated_api_key,
           previous_api_key,
           dashboard_session_invalidation_required?(previous_api_key, update_attrs),
           api_key_update_notification(attrs, transition)
         }}
      end
    end)
  end

  defp update_api_key_record(api_key, update_attrs, transition) do
    mutation = fn ->
      api_key
      |> APIKey.changeset(update_attrs)
      |> Ecto.Changeset.put_change(
        :runtime_revocation_epoch,
        transition.runtime_revocation_epoch
      )
      |> Repo.update()
    end

    if dashboard_session_invalidation_required?(api_key, update_attrs) do
      DashboardSessionLifecycle.run_in_transaction(api_key, "api_key_updated", mutation)
    else
      mutation.()
    end
  end

  @spec pause_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def pause_api_key(%Scope{} = scope, %APIKey{} = api_key),
    do:
      change_api_key_status(
        scope,
        api_key,
        [@status_active],
        @status_paused,
        "api_key_status_updated",
        "api_key.pause",
        %{}
      )

  def pause_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do:
      change_api_key_status(
        scope,
        api_key_id,
        [@status_active],
        @status_paused,
        "api_key_status_updated",
        "api_key.pause",
        %{}
      )

  def pause_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def pause_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec resume_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def resume_api_key(%Scope{} = scope, %APIKey{} = api_key),
    do:
      change_api_key_status(
        scope,
        api_key,
        [@status_paused],
        @status_active,
        "api_key_status_updated",
        "api_key.resume",
        %{}
      )

  def resume_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do:
      change_api_key_status(
        scope,
        api_key_id,
        [@status_paused],
        @status_active,
        "api_key_status_updated",
        "api_key.resume",
        %{}
      )

  def resume_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def resume_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec rotate_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          api_key_result()
  def rotate_api_key(%Scope{} = scope, %APIKey{} = api_key) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ),
         :ok <- ensure_api_key_rotatable(api_key) do
      {key_prefix, raw_key, key_hash} = Material.generate()

      mutation = fn ->
        api_key
        |> APIKey.changeset(%{key_prefix: key_prefix, key_hash: key_hash})
        |> Repo.update()
      end

      api_key
      |> DashboardSessionLifecycle.run("api_key_rotated", mutation)
      |> case do
        {:ok, rotated_key} -> {:ok, %{api_key: rotated_key, raw_key: raw_key}}
        {:error, _changeset} = error -> error
      end
      |> Notifications.notify_api_key_change("api_key_rotated")
      |> AuditLog.audit_api_key_change(scope, "api_key.rotate", fn _result ->
        %{previous_key_prefix: api_key.key_prefix}
      end)
    end
  end

  def rotate_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&rotate_api_key(scope, &1))

  def rotate_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def rotate_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec revoke_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def revoke_api_key(%Scope{} = scope, %APIKey{} = api_key),
    do:
      change_api_key_status(
        scope,
        api_key,
        [@status_active, @status_paused],
        @status_revoked,
        "api_key_revoked",
        "api_key.revoke",
        %{revoked_at: now()}
      )

  def revoke_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do:
      change_api_key_status(
        scope,
        api_key_id,
        [@status_active, @status_paused],
        @status_revoked,
        "api_key_revoked",
        "api_key.revoke",
        %{revoked_at: now()}
      )

  def revoke_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def revoke_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec delete_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, term()}
  def delete_api_key(%Scope{} = scope, %APIKey{} = api_key) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ) do
      delete_api_key_serialized(api_key)
      |> tap(fn
        {:ok, deleted_api_key} ->
          DashboardSessions.broadcast_invalidation(deleted_api_key, "api_key_deleted")

        {:error, _reason} ->
          :ok
      end)
      |> Notifications.notify_api_key_change("api_key_deleted")
      |> AuditLog.audit_api_key_change(scope, "api_key.delete")
    end
  end

  def delete_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&delete_api_key(scope, &1))

  def delete_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def delete_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  defp delete_api_key_serialized(%APIKey{} = api_key) do
    delete_api_key_serialized(api_key, session_ids_for_api_key(api_key.id), 3)
  end

  defp delete_api_key_serialized(api_key, session_ids, attempts_left) do
    maybe_wait_after_api_key_delete_snapshot(api_key.id, session_ids, attempts_left)

    result = Repo.transact(fn -> delete_api_key_with_locked_sessions(api_key, session_ids) end)

    case normalize_api_key_delete_result(result) do
      {:error, %{code: :api_key_delete_conflict}} when attempts_left > 1 ->
        delete_api_key_serialized(api_key, session_ids_for_api_key(api_key.id), attempts_left - 1)

      normalized ->
        normalized
    end
  rescue
    exception in Postgrex.Error ->
      if api_key_delete_retryable_postgres_error?(exception) do
        retry_api_key_delete_after_conflict(api_key, attempts_left)
      else
        reraise exception, __STACKTRACE__
      end

    exception in Ecto.ConstraintError ->
      if exception.type == :foreign_key do
        retry_api_key_delete_after_conflict(api_key, attempts_left)
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp delete_api_key_with_locked_sessions(api_key, session_ids) do
    lock_api_key_sessions(session_ids)

    with %APIKey{} = locked_api_key <- lock_api_key(api_key.id),
         :ok <- require_current_api_key_sessions(locked_api_key.id, session_ids),
         :ok <- close_api_key_replays(locked_api_key.id) do
      DashboardSessionLifecycle.run_in_transaction(
        locked_api_key,
        "api_key_deleted",
        fn -> Repo.delete(locked_api_key) end
      )
    else
      nil -> {:error, Errors.access_error(:api_key_not_found, "api key was not found")}
      {:error, _reason} = error -> error
    end
  end

  defp retry_api_key_delete_after_conflict(api_key, attempts_left) when attempts_left > 1,
    do: delete_api_key_serialized(api_key, session_ids_for_api_key(api_key.id), attempts_left - 1)

  defp retry_api_key_delete_after_conflict(_api_key, _attempts_left),
    do: api_key_delete_conflict()

  defp api_key_delete_retryable_postgres_error?(%Postgrex.Error{
         postgres: %{code: code}
       })
       when code in [:deadlock_detected, :serialization_failure, :foreign_key_violation],
       do: true

  defp api_key_delete_retryable_postgres_error?(%Postgrex.Error{}), do: false

  defp session_ids_for_api_key(api_key_id) do
    Repo.all(
      from session in CodexSession,
        where: session.api_key_id == ^api_key_id,
        order_by: [asc: session.id],
        select: session.id
    )
  end

  if Mix.env() == :test do
    defp maybe_wait_after_api_key_delete_snapshot(_api_key_id, session_ids, attempts_left) do
      case Application.get_env(:codex_pooler, :api_key_delete_test_barrier) do
        %{
          test_pid: test_pid,
          ref: ref,
          block_attempts_left: blocked_attempts
        }
        when is_pid(test_pid) and is_reference(ref) and is_list(blocked_attempts) ->
          send(
            test_pid,
            {:api_key_delete_session_snapshot, ref, self(), attempts_left, session_ids}
          )

          if attempts_left in blocked_attempts do
            receive do
              {:release_api_key_delete_snapshot, ^ref} -> :ok
            end
          end

        _no_barrier ->
          :ok
      end

      :ok
    end
  else
    defp maybe_wait_after_api_key_delete_snapshot(_api_key_id, _session_ids, _attempts_left),
      do: :ok
  end

  defp lock_api_key_sessions([]), do: :ok

  defp lock_api_key_sessions(session_ids) do
    Repo.all(
      from session in CodexSession,
        where: session.id in ^session_ids,
        order_by: [asc: session.id],
        lock: "FOR UPDATE"
    )

    :ok
  end

  defp lock_api_key(api_key_id) do
    Repo.one(from api_key in APIKey, where: api_key.id == ^api_key_id, lock: "FOR UPDATE")
  end

  defp require_current_api_key_sessions(api_key_id, expected_session_ids) do
    if session_ids_for_api_key(api_key_id) == expected_session_ids do
      :ok
    else
      api_key_delete_conflict()
    end
  end

  defp close_api_key_replays(api_key_id) do
    case api_key_delete_replay_close_override() do
      close when is_function(close, 1) ->
        close.(api_key_id)

      nil ->
        api_key_id
        |> Accounting.request_replay_ids_for_api_key()
        |> Enum.reduce_while(:ok, &close_deleted_request_replay/2)
    end
  end

  defp close_deleted_request_replay(request_id, :ok) do
    case Accounting.close_request_replay(request_id, :deleted) do
      {:ok, _result} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp api_key_delete_replay_close_override do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test do
      Application.get_env(:codex_pooler, :api_key_delete_replay_close_test_override)
    end
  end

  defp normalize_api_key_delete_result({:ok, %APIKey{} = api_key}), do: {:ok, api_key}
  defp normalize_api_key_delete_result({:error, %{code: _code} = error}), do: {:error, error}

  defp normalize_api_key_delete_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset}

  defp normalize_api_key_delete_result({:error, reason}), do: {:error, reason}

  defp api_key_delete_conflict do
    {:error,
     Errors.access_error(
       :api_key_delete_conflict,
       "api key deletion conflicts with active runtime work"
     )}
  end

  @spec authenticate_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_api_key(raw_key), to: Authentication

  @spec authenticate_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_authorization_header(header), to: Authentication

  @spec authenticate_v1_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_v1_authorization_header(header), to: Authentication

  @spec authenticate_v1_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_v1_api_key(raw_key), to: Authentication

  @spec policy_denial_precedence() :: [atom()]
  def policy_denial_precedence, do: @policy_denial_precedence

  @spec normalize_api_key_policy(term()) :: policy_result()
  def normalize_api_key_policy(policy), do: Policy.normalize(policy)

  @spec authorize_api_key_policy(term(), map()) :: {:ok, map()} | {:error, atom()}
  def authorize_api_key_policy(api_key_or_policy, attrs \\ %{})

  def authorize_api_key_policy(api_key_or_policy, attrs) when is_map(attrs) do
    Policy.authorize(api_key_or_policy, attrs)
  end

  def authorize_api_key_policy(_api_key_or_policy, _attrs),
    do: {:error, :api_key_policy_malformed}

  @spec hash_api_key_secret(binary()) :: binary()
  defdelegate hash_api_key_secret(secret), to: Authentication

  @spec access_error(atom(), String.t()) :: access_error()
  defdelegate access_error(code, message), to: Errors

  defp change_api_key_status(
         %Scope{} = scope,
         api_key_or_id,
         from_statuses,
         to_status,
         event_reason,
         audit_action,
         extra_attrs
       ) do
    case status_change_transaction(
           scope,
           api_key_or_id,
           from_statuses,
           to_status,
           event_reason,
           extra_attrs
         ) do
      {:ok, {updated_api_key, _previous_api_key, false, _invalidate_dashboard_sessions?}} ->
        {:ok, updated_api_key}

      {:ok, {updated_api_key, previous_api_key, true, invalidate_dashboard_sessions?}} ->
        maybe_broadcast_dashboard_invalidation(
          updated_api_key,
          event_reason,
          invalidate_dashboard_sessions?
        )

        {:ok, updated_api_key}
        |> Notifications.notify_api_key_change(event_reason)
        |> AuditLog.audit_api_key_status_change(
          scope,
          audit_action,
          previous_api_key.status,
          to_status
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp status_change_transaction(
         scope,
         api_key_or_id,
         from_statuses,
         to_status,
         event_reason,
         extra_attrs
       ) do
    Repo.transact(fn ->
      with {:ok, transition} <-
             prepare_lifecycle_status_transition(api_key_or_id, to_status),
           previous_api_key = transition.api_key,
           {:ok, _decision} <- authorize_status_change(scope, previous_api_key) do
        persist_status_change(
          transition,
          from_statuses,
          to_status,
          event_reason,
          extra_attrs
        )
      end
    end)
  end

  defp persist_status_change(transition, from_statuses, to_status, event_reason, extra_attrs) do
    previous_api_key = transition.api_key

    cond do
      previous_api_key.status == to_status ->
        {:ok, {previous_api_key, previous_api_key, false, false}}

      previous_api_key.status == @status_revoked ->
        {:error, Errors.access_error(:api_key_revoked, "revoked api keys cannot be changed")}

      previous_api_key.status not in from_statuses ->
        {:error,
         Errors.access_error(
           :api_key_status_conflict,
           "api key is not in a status that allows this action"
         )}

      true ->
        apply_status_change(transition, to_status, event_reason, extra_attrs)
    end
  end

  defp apply_status_change(transition, to_status, event_reason, extra_attrs) do
    previous_api_key = transition.api_key

    mutation =
      api_key_status_mutation(
        previous_api_key,
        to_status,
        transition.runtime_revocation_epoch,
        extra_attrs
      )

    case run_status_mutation(previous_api_key, to_status, event_reason, mutation) do
      {:ok, updated_api_key} ->
        {:ok, {updated_api_key, previous_api_key, true, to_status != @status_active}}

      {:error, _reason} = error ->
        error
    end
  end

  defp authorize_status_change(%Scope{} = scope, %APIKey{} = api_key) do
    PoolAuthorization.require_capability(
      scope,
      PoolAuthorization.capability(:pool_api_key_manage),
      pool_id: api_key.pool_id
    )
  end

  defp prepare_lifecycle_status_transition(api_key_or_id, to_status) do
    case RuntimeAuthorization.prepare_status_transition(api_key_or_id, to_status) do
      {:error, %{code: :api_key_missing}} ->
        {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

      result ->
        result
    end
  end

  defp api_key_status_mutation(
         %APIKey{} = api_key,
         to_status,
         runtime_revocation_epoch,
         extra_attrs
       ) do
    fn ->
      api_key
      |> APIKey.changeset(Map.put(extra_attrs, :status, to_status))
      |> Ecto.Changeset.put_change(:runtime_revocation_epoch, runtime_revocation_epoch)
      |> Repo.update()
    end
  end

  defp run_status_mutation(%APIKey{} = _api_key, @status_active, _event_reason, mutation),
    do: mutation.()

  defp run_status_mutation(%APIKey{} = api_key, _to_status, event_reason, mutation),
    do: DashboardSessionLifecycle.run_in_transaction(api_key, event_reason, mutation)

  defp ensure_api_key_rotatable(%APIKey{status: @status_revoked}),
    do: {:error, Errors.access_error(:api_key_revoked, "revoked api keys cannot be rotated")}

  defp ensure_api_key_rotatable(%APIKey{}), do: :ok

  defp api_key_update_attrs(attrs, target_pool_id) do
    [
      :display_name,
      :status,
      :dashboard_access,
      :expires_at,
      :allowed_model_identifiers,
      :metadata
    ]
    |> Enum.reduce(%{}, &put_update_attr(&2, attrs, &1))
    |> Map.put(:pool_id, target_pool_id)
  end

  defp dashboard_session_invalidation_required?(api_key, update_attrs) do
    pool_changed? = Map.get(update_attrs, :pool_id, api_key.pool_id) != api_key.pool_id

    dashboard_access_disabled? =
      Map.has_key?(update_attrs, :dashboard_access) and
        Map.get(update_attrs, :dashboard_access) == false and api_key.dashboard_access

    status_disabled? =
      Map.has_key?(update_attrs, :status) and
        Map.get(update_attrs, :status) != @status_active and api_key.status == @status_active

    pool_changed? or dashboard_access_disabled? or status_disabled?
  end

  defp put_update_attr(acc, attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> Map.put(acc, field, Map.get(attrs, field))
      Map.has_key?(attrs, string_field) -> Map.put(acc, field, Map.get(attrs, string_field))
      true -> acc
    end
  end

  defp requested_status(attrs, fallback) do
    Map.get(attrs, :status) || Map.get(attrs, "status") || fallback
  end

  defp maybe_broadcast_dashboard_invalidation(api_key, cause, true) do
    DashboardSessions.broadcast_invalidation(api_key, cause)
  end

  defp maybe_broadcast_dashboard_invalidation(_api_key, _cause, false), do: :ok

  defp notify_api_key_update(result, _previous_api_key, :effective_disabling_transition) do
    Notifications.notify_api_key_runtime_transition(
      result,
      "api_key_updated",
      api_key_from_result(result).pool_id
    )
  end

  defp notify_api_key_update(result, _previous_api_key, :status_without_disable), do: result

  defp notify_api_key_update(result, previous_api_key, :ordinary_update) do
    Notifications.notify_api_key_change(result, "api_key_updated", previous_api_key.pool_id)
  end

  defp api_key_update_notification(attrs, transition) do
    cond do
      transition.effective_disabling_transition? -> :effective_disabling_transition
      status_submitted?(attrs) -> :status_without_disable
      true -> :ordinary_update
    end
  end

  defp status_submitted?(attrs) do
    Map.has_key?(attrs, :status) or Map.has_key?(attrs, "status")
  end

  defp api_key_from_result({:ok, %APIKey{} = api_key}), do: api_key

  defp normalize_pool(%Pool{} = pool), do: pool
  defp normalize_pool(id) when is_binary(id), do: Pools.get_active_pool(id)
  defp normalize_pool(_pool_or_id), do: nil

  defp parse_expires_at(nil), do: {:ok, nil}
  defp parse_expires_at(""), do: {:ok, nil}

  defp parse_expires_at(%DateTime{} = expires_at),
    do: {:ok, DateTime.truncate(expires_at, :microsecond)}

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} ->
        {:ok, DateTime.truncate(expires_at, :microsecond)}

      {:error, _reason} ->
        {:error, Errors.access_error(:invalid_request, "expires_at must be an RFC3339 timestamp")}
    end
  end

  defp parse_expires_at(_value),
    do: {:error, Errors.access_error(:invalid_request, "expires_at must be an RFC3339 timestamp")}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
