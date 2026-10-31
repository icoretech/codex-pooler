defmodule CodexPoolerWeb.Admin.ApiKeyPageSupport do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Access.APIKey
  alias Phoenix.Component

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end

  @spec api_key_delete_form(%{required(:id) => Ecto.UUID.t()}) :: Phoenix.HTML.Form.t()
  def api_key_delete_form(%{id: api_key_id}) do
    %{"id" => api_key_id, "confirmation_prefix" => ""}
    |> Component.to_form(as: :api_key_delete)
  end

  def created_secret(%APIKey{} = api_key, raw_key) do
    %{api_key_id: api_key.id, key_prefix: api_key.key_prefix, raw_key: raw_key}
  end

  def maybe_clear_secret(socket, opts) do
    if Keyword.get(opts, :clear_secret, false) do
      Component.assign(socket, :created_secret, nil)
    else
      socket
    end
  end

  @spec error_message(term()) :: String.t()
  def error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&CodexPoolerWeb.CoreComponents.translate_error/1)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &gettext("%{field} %{message}", field: error_field(field), message: &1)) end)
    |> Enum.join(", ")
  end

  def error_message(%{code: :api_key_not_found}), do: gettext("api key was not found")
  def error_message(%{code: :pool_not_found}), do: gettext("pool was not found")
  def error_message(%{code: :api_key_edit_conflict}), do: gettext("API key changed while this form was open. Close and reopen Edit before saving.")
  def error_message(%{code: :api_key_delete_conflict}), do: gettext("api key deletion conflicts with active runtime work")
  def error_message(%{code: :api_key_status_conflict}), do: gettext("api key is not in a status that allows this action")

  def error_message(%{code: :invalid_model_binding_shape, message: message}), do: localized_error_message(message)
  def error_message(%{code: :invalid_scope, message: message}), do: localized_error_message(message)
  def error_message(%{message: message}) when is_binary(message), do: localized_error_message(message)
  def error_message(_reason), do: gettext("Operation failed")

  defp localized_error_message(message) do
    case localized_error_clause(message) do
      nil -> model_error_clause(message)
      translated -> translated
    end
  end

  defp localized_error_clause("only node admins can perform this capability"), do: gettext("only node admins can perform this capability")
  defp localized_error_clause("the actor role cannot perform this capability in the requested scope"), do: gettext("the actor role cannot perform this capability in the requested scope")
  defp localized_error_clause("user scope is required"), do: gettext("user scope is required")
  defp localized_error_clause("this capability requires a Pool scope"), do: gettext("this capability requires a Pool scope")
  defp localized_error_clause("only the instance owner can perform this global capability"), do: gettext("only the instance owner can perform this global capability")
  defp localized_error_clause("assigned-pool admin capabilities require a Pool scope"), do: gettext("assigned-pool admin capabilities require a Pool scope")
  defp localized_error_clause("the assigned-pool admin cannot access the requested Pool"), do: gettext("the assigned-pool admin cannot access the requested Pool")
  defp localized_error_clause("revoked api keys cannot be changed"), do: gettext("revoked api keys cannot be changed")
  defp localized_error_clause("revoked api keys cannot be rotated"), do: gettext("revoked api keys cannot be rotated")
  defp localized_error_clause(_message), do: nil

  defp model_error_clause(message) do
    case model_policy_error(message) do
      nil -> model_identifier_error(message)
      translated -> translated
    end
  end

  defp model_policy_error("expires_at must be an RFC3339 timestamp"), do: gettext("expires_at must be an RFC3339 timestamp")
  defp model_policy_error("selected_models requires at least one selected value"), do: gettext("selected_models requires at least one selected value")
  defp model_policy_error("selected_models has invalid values"), do: gettext("selected_models has invalid values")
  defp model_policy_error("selected requires at least one selected value"), do: gettext("selected requires at least one selected value")
  defp model_policy_error("selected has invalid values"), do: gettext("selected has invalid values")
  defp model_policy_error("unknown models mode"), do: gettext("unknown models mode")
  defp model_policy_error("enforced_model_identifier is invalid"), do: gettext("enforced_model_identifier is invalid")
  defp model_policy_error("enforced_reasoning_effort is invalid"), do: gettext("enforced_reasoning_effort is invalid")
  defp model_policy_error("maximum_reasoning_effort is invalid"), do: gettext("maximum_reasoning_effort is invalid")
  defp model_policy_error("enforced_reasoning_effort and maximum_reasoning_effort cannot both be configured"), do: gettext("enforced_reasoning_effort and maximum_reasoning_effort cannot both be configured")
  defp model_policy_error("enforced_service_tier is invalid"), do: gettext("enforced_service_tier is invalid")
  defp model_policy_error(_message), do: nil
  defp model_identifier_error("model identifiers cannot contain whitespace"), do: gettext("model identifiers cannot contain whitespace")
  defp model_identifier_error("enforced model is not allowed in deny-all mode"), do: gettext("enforced model is not allowed in deny-all mode")
  defp model_identifier_error("enforced model must be included in selected models"), do: gettext("enforced model must be included in selected models")
  defp model_identifier_error("model identifier cannot be blank"), do: gettext("model identifier cannot be blank")
  defp model_identifier_error("model identifier cannot contain whitespace or control characters"), do: gettext("model identifier cannot contain whitespace or control characters")
  defp model_identifier_error("model identifier must be text"), do: gettext("model identifier must be text")
  defp model_identifier_error("default_policy.binding_scope must be default"), do: gettext("default_policy.binding_scope must be default")
  defp model_identifier_error("default_policy.model_identifier is not allowed"), do: gettext("default_policy.model_identifier is not allowed")
  defp model_identifier_error("default_policy must be a map"), do: gettext("default_policy must be a map")
  defp model_identifier_error("model_policies must be a list"), do: gettext("model_policies must be a list")
  defp model_identifier_error(message), do: model_binding_error(message)

  defp model_binding_error(message) do
    case Regex.run(~r/^model_policies\[(\d+)\]\.(binding_scope must be model|model_identifier is required)$/, message) do
      [_, index, "binding_scope must be model"] -> gettext("model_policies[%{index}].binding_scope must be model", index: index)
      [_, index, "model_identifier is required"] -> gettext("model_policies[%{index}].model_identifier is required", index: index)
      nil -> model_binding_shape_error(message)
    end
  end

  defp model_binding_shape_error(message) do
    case Regex.run(~r/^model_policies\[(\d+)\] must be a map$/, message) do
      [_, index] -> gettext("model_policies[%{index}] must be a map", index: index)
      nil -> message
    end
  end

  defp error_field(:display_name), do: gettext("Display name")
  defp error_field(:pool_id), do: gettext("Pool")
  defp error_field(:status), do: gettext("status")
  defp error_field(:dashboard_access), do: gettext("Observatory access")
  defp error_field(:max_active_requests), do: gettext("Maximum active requests")
  defp error_field(:expires_at), do: gettext("Expires")
  defp error_field(:allowed_model_identifiers), do: gettext("Manual model identifiers")
  defp error_field(:enforced_model_identifier), do: gettext("Enforced model")
  defp error_field(:enforced_reasoning_effort), do: gettext("Enforced reasoning effort")
  defp error_field(:maximum_reasoning_effort), do: gettext("Maximum reasoning effort")
  defp error_field(:enforced_service_tier), do: gettext("Enforced service tier")
  defp error_field(:model_identifier), do: gettext("Model identifier")
  defp error_field(:binding_scope), do: gettext("Binding scope")
  defp error_field(:max_requests_per_minute), do: gettext("Requests per minute")
  defp error_field(:max_tokens_per_day), do: gettext("Tokens per day")
  defp error_field(:max_tokens_per_week), do: gettext("Tokens per week")
  defp error_field(:max_input_tokens_per_request), do: gettext("Input tokens per request")
  defp error_field(:max_output_tokens_per_request), do: gettext("Output tokens per request")
  defp error_field(:metadata), do: gettext("Metadata")
  defp error_field(:key_prefix), do: gettext("Prefix")
  defp error_field(:key_hash), do: gettext("Key hash")
  defp error_field(field), do: to_string(field)
end
