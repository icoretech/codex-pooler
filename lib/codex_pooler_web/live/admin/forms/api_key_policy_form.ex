defmodule CodexPoolerWeb.Admin.ApiKeyPolicyForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Pools.Pool

  @type params :: %{String.t() => term()}
  @type attrs :: %{atom() => term()}
  @type option :: {String.t(), String.t()}
  @type review_row :: {String.t(), String.t()}
  @type review_section :: {String.t(), [review_row()]}
  @type selector_state :: map()
  @type selector_attrs :: %{String.t() => term()}
  @type form_error ::
          {:expires_at | :dashboard_access, {String.t(), keyword()}}

  @limit_fields ~w(
    max_requests_per_minute
    max_tokens_per_day
    max_tokens_per_week
    max_input_tokens_per_request
    max_output_tokens_per_request
  )

  @spec limit_fields() :: [String.t()]
  def limit_fields, do: @limit_fields

  @spec empty_params([Pool.t()]) :: params()
  def empty_params([]), do: default_params(%{"pool_id" => ""})
  def empty_params([pool | _pools]), do: default_params(%{"pool_id" => pool.id})

  @spec params_for(APIKey.t(), [APIKeyPolicyBinding.t()]) :: params()
  def params_for(%APIKey{} = api_key, policy_bindings) do
    default_binding = Enum.find(policy_bindings, &(&1.binding_scope == "default"))
    model_binding = Enum.find(policy_bindings, &(&1.binding_scope == "model"))

    default_params(%{
      "id" => api_key.id,
      "display_name" => api_key.display_name,
      "pool_id" => api_key.pool_id,
      "status" => api_key.status,
      "dashboard_access" => api_key.dashboard_access,
      "expires_at" => datetime_local_value(api_key.expires_at),
      "model_mode" => model_mode(api_key.allowed_model_identifiers),
      "allowed_model_identifiers" => api_key.allowed_model_identifiers || [],
      "enforced_model_identifier" => api_key.enforced_model_identifier || "",
      "enforced_reasoning_effort" => api_key.enforced_reasoning_effort || "",
      "maximum_reasoning_effort" => api_key.maximum_reasoning_effort || "",
      "reasoning_policy_mode" => reasoning_policy_mode(api_key),
      "enforced_service_tier" => api_key.enforced_service_tier || "",
      "operator_notes" => operator_notes(api_key)
    })
    |> merge_binding_params("default", default_binding)
    |> merge_binding_params("model", model_binding)
  end

  @spec form(params(), keyword()) :: Phoenix.HTML.Form.t()
  def form(params, opts \\ []) when is_map(params) and is_list(opts) do
    params
    |> default_params()
    |> to_form(as: :api_key, errors: Keyword.get(opts, :errors, []))
  end

  @spec expiry_errors(params()) :: [form_error()]
  def expiry_errors(params) do
    if invalid_expiry?(params["expires_at"]) do
      [expires_at: {"must be a valid date and time", []}]
    else
      []
    end
  end

  @spec input_errors(params()) :: [form_error()]
  def input_errors(params) do
    expiry_errors(params) ++ dashboard_access_errors(params)
  end

  @spec normalize_params(params(), [Pool.t()]) :: params()
  def normalize_params(params, pools) do
    params
    |> default_params()
    |> then(fn params ->
      if blank_to_nil(params["pool_id"]) do
        params
      else
        Map.put(params, "pool_id", pool_id_default(pools))
      end
    end)
    |> normalize_list_param("allowed_model_identifiers")
  end

  @spec merge_params(params() | nil, params() | nil) :: params()
  def merge_params(current_params, incoming_params),
    do: Map.merge(current_params || %{}, incoming_params || %{})

  @spec attrs(params()) :: attrs()
  def attrs(params) do
    pool_id = blank_to_nil(params["pool_id"])
    reasoning_effort_attrs = reasoning_effort_attrs(params)

    %{
      display_name: params |> Map.get("display_name", "") |> to_string() |> String.trim(),
      pool_id: pool_id,
      status: blank_to_nil(params["status"]) || "active",
      dashboard_access: dashboard_access_value(params["dashboard_access"]),
      expires_at: expires_at_value(params["expires_at"]),
      model_mode: params["model_mode"],
      allowed_model_identifiers: policy_model_identifiers(params),
      enforced_model_identifier: blank_to_nil(params["enforced_model_identifier"]),
      enforced_reasoning_effort: reasoning_effort_attrs.enforced_reasoning_effort,
      maximum_reasoning_effort: reasoning_effort_attrs.maximum_reasoning_effort,
      enforced_service_tier: blank_to_nil(params["enforced_service_tier"]),
      default_policy: default_policy_attrs(params),
      model_policies: model_policy_attrs(params),
      metadata: %{
        "labels" => [],
        "operator_notes" => blank_to_nil(params["operator_notes"])
      }
    }
  end

  @spec review_errors(params()) :: [String.t()]
  def review_errors(params) do
    []
    |> maybe_add_error(blank_to_nil(params["display_name"]) == nil, "Display name is required")
    |> maybe_add_error(blank_to_nil(params["pool_id"]) == nil, "Pool is required")
    |> maybe_add_error(
      invalid_dashboard_access?(params["dashboard_access"]),
      "Dashboard access must be enabled or disabled"
    )
    |> maybe_add_error(
      invalid_expiry?(params["expires_at"]),
      "Expiry must be a valid date and time"
    )
    |> maybe_add_error(
      params["model_mode"] == "selected_models" and policy_model_identifiers(params) == [],
      "Selected model mode needs at least one model"
    )
    |> maybe_add_error(enforced_model_conflict?(params), "Enforced model must be allowed")
    |> maybe_add_error(
      incomplete_reasoning_policy?(params),
      "Allow up to needs a maximum reasoning effort"
    )
    |> maybe_add_error(
      incomplete_exact_reasoning_policy?(params),
      "Always use needs a reasoning effort"
    )
    |> Enum.reverse()
  end

  @spec reasoning_effort_options() :: [option()]
  def reasoning_effort_options do
    [
      {"Do not enforce", ""},
      {"None (request no reasoning)", "none"},
      {"Minimal", "minimal"},
      {"Low", "low"},
      {"Medium", "medium"},
      {"High", "high"},
      {"Extra high", "xhigh"},
      {"Max", "max"},
      {"Ultra", "ultra"}
    ]
  end

  @spec service_tier_options() :: [option()]
  def service_tier_options do
    [
      {"Leave unchanged", ""},
      {"Auto - upstream chooses", "auto"},
      {"Default - standard capacity", "default"},
      {"Flex - flexible capacity", "flex"},
      {"Priority - fast responses", "priority"},
      {"Scale - scale capacity", "scale"}
    ]
  end

  @spec enforced_model_options(selector_state(), Phoenix.HTML.Form.t()) :: [option()]
  def enforced_model_options(selector_state, form) do
    selected_values =
      (selector_state.options ++
         selector_state.selected_unavailable_chips ++ selector_state.manual_chips)
      |> Enum.map(& &1.identifier)
      |> Enum.concat(list_input_values(form[:allowed_model_identifiers].value))
      |> Enum.concat(split_allow_list_text(form[:manual_model_identifiers_text].value))
      |> Enum.concat(List.wrap(blank_to_nil(form[:enforced_model_identifier].value)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    [{"Do not enforce", ""} | Enum.map(selected_values, &{&1, &1})]
  end

  @spec review_sections(Phoenix.HTML.Form.t(), selector_state(), Pool.t() | nil) ::
          [review_section()]
  def review_sections(form, selector_state, selected_pool) do
    [
      {"Basics", basics_review_rows(form, selected_pool)},
      {"Models", model_review_rows(form, selector_state)},
      {"Limits", limit_review_rows(form)}
    ]
  end

  @spec model_selector_attrs(params()) :: selector_attrs()
  def model_selector_attrs(params) do
    %{
      "model_mode" => params["model_mode"],
      "allowed_model_identifiers" => policy_model_identifiers(params),
      "manual_model_identifiers" => split_allow_list_text(params["manual_model_identifiers_text"])
    }
  end

  defp policy_model_identifiers(params) do
    (list_input_values(params["allowed_model_identifiers"]) ++
       split_allow_list_text(params["manual_model_identifiers_text"]))
    |> Enum.uniq()
  end

  defp default_policy_attrs(params) do
    Map.new(@limit_fields, fn field ->
      {field, blank_to_nil(params["default_#{field}"])}
    end)
  end

  defp model_policy_attrs(params) do
    model_identifier = blank_to_nil(params["model_policy_model_identifier"])

    policy =
      Map.new(@limit_fields, fn field ->
        {field, blank_to_nil(params["model_#{field}"])}
      end)

    if model_identifier || Enum.any?(policy, fn {_field, value} -> not is_nil(value) end) do
      [Map.put(policy, "model_identifier", model_identifier)]
    else
      []
    end
  end

  defp expires_at_value(nil), do: nil
  defp expires_at_value(""), do: nil

  defp expires_at_value(value) do
    value = String.trim(to_string(value))

    cond do
      value == "" -> nil
      String.ends_with?(value, "Z") -> value
      String.contains?(value, "+") -> value
      String.length(value) == 16 -> value <> ":00Z"
      String.length(value) == 19 -> value <> "Z"
      true -> value
    end
  end

  defp invalid_expiry?(value) do
    case expires_at_value(value) do
      nil -> false
      normalized_value -> not valid_rfc3339_datetime?(normalized_value)
    end
  end

  defp valid_rfc3339_datetime?(value) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  end

  defp split_allow_list_text(value) when is_binary(value) do
    value
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split_allow_list_text(_value), do: []

  defp list_input_values(nil), do: []

  defp list_input_values(value) when is_binary(value), do: split_allow_list_text(value)

  defp list_input_values(values) when is_list(values) do
    values
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp list_input_values(_values), do: []

  defp default_params(params) do
    base = %{
      "id" => "",
      "display_name" => "",
      "pool_id" => "",
      "status" => "active",
      "dashboard_access" => false,
      "expires_at" => "",
      "model_mode" => "all_models",
      "allowed_model_identifiers" => [],
      "manual_model_identifiers_text" => "",
      "enforced_model_identifier" => "",
      "enforced_reasoning_effort" => "",
      "maximum_reasoning_effort" => "",
      "reasoning_policy_mode" => "unrestricted",
      "enforced_service_tier" => "",
      "operator_notes" => "",
      "model_policy_model_identifier" => ""
    }

    limit_defaults =
      Enum.reduce(@limit_fields, %{}, fn field, acc ->
        acc
        |> Map.put("default_#{field}", "")
        |> Map.put("model_#{field}", "")
      end)

    base
    |> Map.merge(limit_defaults)
    |> Map.merge(Map.new(params))
  end

  defp normalize_list_param(params, key), do: Map.put(params, key, list_input_values(params[key]))

  defp pool_id_default([pool | _pools]), do: pool.id
  defp pool_id_default(_pools), do: ""

  defp merge_binding_params(params, _prefix, nil), do: params

  defp merge_binding_params(params, "default", %APIKeyPolicyBinding{} = binding) do
    Enum.reduce(@limit_fields, params, fn field, acc ->
      Map.put(acc, "default_#{field}", binding_value(binding, field))
    end)
  end

  defp merge_binding_params(params, "model", %APIKeyPolicyBinding{} = binding) do
    params = Map.put(params, "model_policy_model_identifier", binding.model_identifier || "")

    Enum.reduce(@limit_fields, params, fn field, acc ->
      Map.put(acc, "model_#{field}", binding_value(binding, field))
    end)
  end

  defp binding_value(binding, field) do
    value = Map.get(binding, String.to_existing_atom(field))
    if is_nil(value), do: "", else: to_string(value)
  end

  defp datetime_local_value(nil), do: ""

  defp datetime_local_value(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  defp model_mode(nil), do: "all_models"
  defp model_mode([]), do: "deny_all_models"
  defp model_mode(_values), do: "selected_models"

  defp reasoning_policy_mode(%APIKey{enforced_reasoning_effort: effort}) when is_binary(effort),
    do: "always_use"

  defp reasoning_policy_mode(%APIKey{maximum_reasoning_effort: effort}) when is_binary(effort),
    do: "allow_up_to"

  defp reasoning_policy_mode(%APIKey{}), do: "unrestricted"

  defp reasoning_effort_attrs(params) do
    case params["reasoning_policy_mode"] do
      "allow_up_to" ->
        %{
          enforced_reasoning_effort: nil,
          maximum_reasoning_effort: blank_to_nil(params["maximum_reasoning_effort"])
        }

      "always_use" ->
        %{
          enforced_reasoning_effort: blank_to_nil(params["enforced_reasoning_effort"]),
          maximum_reasoning_effort: nil
        }

      _other ->
        %{enforced_reasoning_effort: nil, maximum_reasoning_effort: nil}
    end
  end

  defp incomplete_reasoning_policy?(params) do
    params["reasoning_policy_mode"] == "allow_up_to" and
      blank_to_nil(params["maximum_reasoning_effort"]) == nil
  end

  defp incomplete_exact_reasoning_policy?(params) do
    params["reasoning_policy_mode"] == "always_use" and
      blank_to_nil(params["enforced_reasoning_effort"]) == nil
  end

  defp maybe_add_error(errors, true, message), do: [message | errors]
  defp maybe_add_error(errors, false, _message), do: errors

  defp enforced_model_conflict?(params) do
    enforced_model = normalize_model_for_compare(params["enforced_model_identifier"])

    cond do
      is_nil(enforced_model) ->
        false

      params["model_mode"] == "deny_all_models" ->
        true

      params["model_mode"] == "selected_models" ->
        allowed_models =
          Enum.map(policy_model_identifiers(params), &normalize_model_for_compare/1)

        enforced_model not in allowed_models

      true ->
        false
    end
  end

  defp normalize_model_for_compare(value) do
    value
    |> blank_to_nil()
    |> case do
      nil -> nil
      model -> model |> String.trim() |> String.downcase()
    end
  end

  defp basics_review_rows(form, selected_pool) do
    [
      {"Name", blank_to_nil(form[:display_name].value) || "Missing"},
      {"Pool", selected_pool_name(selected_pool)},
      {"Status", form[:status].value || "active"},
      {"Dashboard access", dashboard_access_label(form[:dashboard_access].value)},
      {"Expires", blank_to_nil(form[:expires_at].value) || "Never"}
    ]
  end

  defp model_review_rows(form, selector_state) do
    [
      {"Mode", model_mode_label(form[:model_mode].value)},
      {"Selected", model_selection_summary(form, selector_state)},
      {"Enforced model", blank_to_nil(form[:enforced_model_identifier].value) || "Not enforced"},
      {"Reasoning", reasoning_policy_label(form)},
      {"Service tier", blank_to_nil(form[:enforced_service_tier].value) || "Not enforced"}
    ]
  end

  defp limit_review_rows(form) do
    values =
      @limit_fields
      |> Enum.flat_map(fn field ->
        [
          {"Default #{limit_field_label(field)}",
           normalized_limit_value(form[String.to_atom("default_#{field}")].value)},
          {"Model #{limit_field_label(field)}",
           normalized_limit_value(form[String.to_atom("model_#{field}")].value)}
        ]
      end)
      |> Enum.reject(fn {_label, value} -> is_nil(value) end)

    case values do
      [] -> [{"Limits", "No caps configured"}]
      rows -> rows
    end
  end

  defp selected_pool_name(%Pool{name: name}), do: name
  defp selected_pool_name(_pool), do: "Missing"

  defp normalized_limit_value(value) do
    case value |> blank_to_nil() |> parse_integer() do
      {:ok, integer} -> format_integer(integer)
      :error -> blank_to_nil(value)
    end
  end

  defp parse_integer(nil), do: :error

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp format_integer(integer) do
    integer
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp model_mode_label("selected_models"), do: "Selected models"
  defp model_mode_label("deny_all_models"), do: "Deny all models"
  defp model_mode_label(_mode), do: "All models"

  defp reasoning_policy_label(form) do
    case form[:reasoning_policy_mode].value do
      "allow_up_to" ->
        reasoning_policy_value("Allow up to", form[:maximum_reasoning_effort].value)

      "always_use" ->
        reasoning_policy_value("Always use", form[:enforced_reasoning_effort].value)

      _other ->
        "Unrestricted"
    end
  end

  defp reasoning_policy_value(prefix, value) do
    case blank_to_nil(value) do
      nil -> prefix
      effort -> "#{prefix} #{reasoning_effort_label(effort)}"
    end
  end

  defp reasoning_effort_label("xhigh"), do: "Extra high"
  defp reasoning_effort_label("none"), do: "None"
  defp reasoning_effort_label(effort), do: String.capitalize(effort)

  defp model_selection_summary(form, selector_state) do
    count =
      form[:allowed_model_identifiers].value
      |> list_input_values()
      |> Enum.concat(split_allow_list_text(form[:manual_model_identifiers_text].value))
      |> Enum.uniq()
      |> length()

    cond do
      form[:model_mode].value == "all_models" -> "All current and future models"
      form[:model_mode].value == "deny_all_models" -> "No model access"
      count == 1 -> "1 selected model"
      true -> "#{count} selected models"
    end <> unavailable_suffix(selector_state)
  end

  defp unavailable_suffix(%{selected_unavailable_chips: []}), do: ""

  defp unavailable_suffix(%{selected_unavailable_chips: chips}),
    do: " · #{length(chips)} unavailable saved"

  defp limit_field_label("max_requests_per_minute"), do: "Requests per minute"
  defp limit_field_label("max_tokens_per_day"), do: "Tokens per day"
  defp limit_field_label("max_tokens_per_week"), do: "Tokens per week"
  defp limit_field_label("max_input_tokens_per_request"), do: "Input tokens per request"
  defp limit_field_label("max_output_tokens_per_request"), do: "Output tokens per request"

  defp operator_notes(%APIKey{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("operator_notes", Map.get(metadata, :operator_notes))
    |> blank_to_nil()
    |> case do
      nil -> "No notes"
      notes -> notes
    end
  end

  defp operator_notes(_api_key), do: "No notes"

  defp dashboard_access_errors(params) do
    if invalid_dashboard_access?(params["dashboard_access"]) do
      [dashboard_access: {"must be enabled or disabled", []}]
    else
      []
    end
  end

  defp dashboard_access_value(value) do
    case parse_dashboard_access(value) do
      {:ok, dashboard_access} -> dashboard_access
      :error -> nil
    end
  end

  defp invalid_dashboard_access?(value), do: parse_dashboard_access(value) == :error

  defp dashboard_access_label(value) do
    case parse_dashboard_access(value) do
      {:ok, true} -> "Enabled"
      {:ok, false} -> "Disabled"
      :error -> "Invalid"
    end
  end

  defp parse_dashboard_access(true), do: {:ok, true}
  defp parse_dashboard_access(false), do: {:ok, false}
  defp parse_dashboard_access("true"), do: {:ok, true}
  defp parse_dashboard_access("false"), do: {:ok, false}
  defp parse_dashboard_access(_value), do: :error

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end
end
