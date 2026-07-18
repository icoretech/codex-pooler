defmodule CodexPooler.Access.APIKeys.AuditLog do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit

  @status_active "active"
  @status_paused "paused"

  @type audit_result :: {:ok, term()} | {:error, term()} | term()

  @spec audit_api_key_status_change(
          audit_result(),
          Scope.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: audit_result()
  def audit_api_key_status_change(result, scope, action, previous_status, status) do
    audit_api_key_change(result, scope, action, fn _updated ->
      %{previous_status: previous_status, status: status}
    end)
  end

  @spec audit_api_key_change(audit_result(), Scope.t(), String.t(), (term() -> map())) ::
          audit_result()
  def audit_api_key_change(
        result,
        %Scope{} = scope,
        action,
        details_fun \\ fn _resource -> %{} end
      ) do
    tap(result, fn
      {:ok, resource} ->
        with %APIKey{} = api_key <- api_key_audit_resource(resource),
             %User{} = user <- scope.user do
          details =
            api_key
            |> api_key_audit_details()
            |> Map.merge(details_fun.(resource))

          Audit.record_user_event(user, %{
            pool_id: api_key.pool_id,
            action: action,
            target_type: "api_key",
            target_id: api_key.id,
            details: details
          })
        end

      _result ->
        :ok
    end)
  end

  @spec api_key_policy_audit_details(term()) :: map()
  def api_key_policy_audit_details(%{policy_bindings: bindings}) when is_list(bindings),
    do: %{policy_binding_count: length(bindings)}

  def api_key_policy_audit_details(_resource), do: %{}

  @spec api_key_update_audit_details(term(), APIKey.t(), map()) :: map()
  def api_key_update_audit_details(resource, %APIKey{} = previous_api_key, attrs) do
    updated_api_key = api_key_audit_resource(resource)

    pool_changed? =
      case updated_api_key do
        %APIKey{pool_id: pool_id} -> pool_id != previous_api_key.pool_id
        _resource -> false
      end

    %{
      changed_fields: api_key_audit_changed_fields(attrs),
      previous_pool_id: previous_api_key.pool_id,
      pool_changed: pool_changed?,
      previous_status: previous_api_key.status,
      previous_dashboard_access: previous_api_key.dashboard_access,
      previous_reasoning_policy_mode: reasoning_policy_mode(previous_api_key),
      previous_reasoning_policy_configuration: reasoning_policy_configuration(previous_api_key)
    }
  end

  @spec api_key_status_audit_action(String.t()) :: String.t()
  def api_key_status_audit_action(@status_paused), do: "api_key.pause"
  def api_key_status_audit_action(@status_active), do: "api_key.resume"

  defp api_key_audit_resource(%{api_key: %APIKey{} = api_key}), do: api_key
  defp api_key_audit_resource(%APIKey{} = api_key), do: api_key
  defp api_key_audit_resource(_resource), do: nil

  defp api_key_audit_details(%APIKey{} = api_key) do
    %{
      api_key_id: api_key.id,
      pool_id: api_key.pool_id,
      display_name: api_key.display_name,
      key_prefix: api_key.key_prefix,
      status: api_key.status,
      dashboard_access: api_key.dashboard_access,
      expires_at: api_key.expires_at && DateTime.to_iso8601(api_key.expires_at),
      allowed_model_mode: audit_model_mode(api_key.allowed_model_identifiers),
      allowed_model_count: audit_allowed_model_count(api_key.allowed_model_identifiers),
      enforced_model_identifier: api_key.enforced_model_identifier,
      reasoning_policy_mode: reasoning_policy_mode(api_key),
      reasoning_policy_configuration: reasoning_policy_configuration(api_key),
      enforced_service_tier: api_key.enforced_service_tier
    }
  end

  defp api_key_audit_changed_fields(attrs) do
    known_fields = [
      "display_name",
      "pool_id",
      "status",
      "dashboard_access",
      "expires_at",
      "allowed_model_identifiers",
      "metadata",
      "model_mode",
      "allowed_models_mode",
      "enforced_model_identifier",
      "enforced_reasoning_effort",
      "maximum_reasoning_effort",
      "enforced_service_tier",
      "default_policy",
      "model_policies"
    ]

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in known_fields))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp audit_model_mode(nil), do: "all_models"
  defp audit_model_mode([]), do: "deny_all_models"
  defp audit_model_mode(_values), do: "selected_models"

  defp audit_allowed_model_count(nil), do: nil
  defp audit_allowed_model_count(values) when is_list(values), do: length(values)

  defp reasoning_policy_mode(%APIKey{
         enforced_reasoning_effort: nil,
         maximum_reasoning_effort: nil
       }),
       do: "unrestricted"

  defp reasoning_policy_mode(%APIKey{
         enforced_reasoning_effort: nil,
         maximum_reasoning_effort: maximum
       })
       when is_binary(maximum),
       do: "allow_up_to"

  defp reasoning_policy_mode(%APIKey{
         enforced_reasoning_effort: enforced,
         maximum_reasoning_effort: nil
       })
       when is_binary(enforced),
       do: "always_use"

  defp reasoning_policy_configuration(%APIKey{enforced_reasoning_effort: enforced})
       when is_binary(enforced),
       do: enforced

  defp reasoning_policy_configuration(%APIKey{maximum_reasoning_effort: maximum})
       when is_binary(maximum),
       do: maximum

  defp reasoning_policy_configuration(%APIKey{}), do: nil
end
