defmodule CodexPooler.Access.APIKeys.PolicyUpdate do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Lifecycle, as: DashboardSessionLifecycle

  alias CodexPooler.Access.APIKeys.{
    AuditLog,
    Errors,
    Notifications,
    Policy,
    PolicyPersistence,
    Queries
  }

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Authorization, as: PoolAuthorization
  alias CodexPooler.Pools.Pool

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type api_key_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | access_error()}

  @spec update_api_key_with_policy(
          Scope.t(),
          APIKey.t() | Ecto.UUID.t(),
          map()
        ) :: api_key_result()
  def update_api_key_with_policy(%Scope{} = scope, %APIKey{} = api_key, attrs)
      when is_map(attrs) do
    with {:ok, current_api_key} <- Queries.get_api_key(scope, api_key.id) do
      update_current_api_key_with_policy(scope, current_api_key, attrs)
    end
  end

  def update_api_key_with_policy(%Scope{} = scope, api_key_id, attrs)
      when is_binary(api_key_id) do
    with {:ok, api_key} <- Queries.get_api_key(scope, api_key_id) do
      update_current_api_key_with_policy(scope, api_key, attrs)
    end
  end

  def update_api_key_with_policy(_scope, _api_key, _attrs),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  defp update_current_api_key_with_policy(scope, api_key, attrs) do
    with {:ok, target_pool_id} <- authorize_api_key_update(scope, api_key, attrs),
         {:ok, policy_attrs, policy_inputs} <-
           update_api_key_policy_attrs(scope, target_pool_id, attrs) do
      update_attrs =
        attrs
        |> api_key_update_attrs(target_pool_id)
        |> Map.merge(policy_attrs)

      mutation = fn ->
        api_key
        |> PolicyPersistence.update_api_key_policy(update_attrs, policy_inputs, now())
        |> PolicyPersistence.normalize_transaction_result()
      end

      result =
        if dashboard_session_invalidation_required?(api_key, update_attrs) do
          DashboardSessionLifecycle.run(api_key, "api_key_updated", mutation)
        else
          mutation.()
        end

      result
      |> Notifications.notify_api_key_change("api_key_updated", api_key.pool_id)
      |> AuditLog.audit_api_key_change(scope, "api_key.update", fn updated ->
        updated
        |> AuditLog.api_key_update_audit_details(api_key, attrs)
        |> Map.merge(AuditLog.api_key_policy_audit_details(updated))
      end)
    end
  end

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

  defp update_api_key_policy_attrs(scope, target_pool_id, attrs) do
    with {:ok, normalized_policy} <- Policy.normalize_attrs(scope, target_pool_id, attrs),
         {:ok, policy_inputs} <- Policy.normalize_inputs(attrs) do
      {:ok, normalized_policy, policy_inputs}
    end
  end

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
        Map.get(update_attrs, :status) != "active" and api_key.status == "active"

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

  defp normalize_pool(%Pool{} = pool), do: pool
  defp normalize_pool(id) when is_binary(id), do: Pools.get_active_pool(id)
  defp normalize_pool(_pool_or_id), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
