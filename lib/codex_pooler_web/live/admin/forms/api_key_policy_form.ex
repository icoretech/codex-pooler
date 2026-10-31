defmodule CodexPoolerWeb.Admin.ApiKeyPolicyForm do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Access.APIKeys.PolicyPersistence
  alias CodexPooler.Pools.Pool
  alias CodexPooler.ServiceTier
  alias CodexPoolerWeb.DateTimeInput

  @type params :: %{String.t() => term()}
  @type attrs :: %{atom() => term()}
  @type option :: {String.t(), String.t()}
  @type review_row :: {String.t(), String.t()}
  @type review_section :: {String.t(), [review_row()]}
  @type selector_state :: map()
  @type selector_attrs :: %{String.t() => term()}
  @type form_error ::
          {:expires_at | :dashboard_access | :max_active_requests, {String.t(), keyword()}}

  @limit_fields ~w(
    max_requests_per_minute
    max_tokens_per_day
    max_tokens_per_week
    max_input_tokens_per_request
    max_output_tokens_per_request
  )

  # Stored values the form carries unedited from `params_for/2` to `attrs/1`:
  # the key's metadata (its labels) and every model override after the one
  # the form edits. They never come from a submission (findings#206 row
  # 206-504).
  @carried_keys ~w(stored_metadata retained_model_policies stored_expires_at expiry_timezone stored_edit_revision)

  @spec limit_fields() :: [String.t()]
  def limit_fields, do: @limit_fields

  @spec empty_params([Pool.t()], String.t()) :: params()
  def empty_params(pools, timezone \\ "Etc/UTC"),
    do: default_params(%{"pool_id" => pool_id_default(pools), "expiry_timezone" => timezone})

  @spec params_for(APIKey.t(), [APIKeyPolicyBinding.t()], String.t()) :: params()
  def params_for(%APIKey{} = api_key, policy_bindings, timezone \\ "Etc/UTC") do
    default_binding = Enum.find(policy_bindings, &(&1.binding_scope == "default"))
    {model_binding, retained_model_bindings} = split_model_bindings(policy_bindings)

    default_params(%{
      "id" => api_key.id,
      "stored_edit_revision" => PolicyPersistence.edit_revision(api_key, policy_bindings),
      "display_name" => api_key.display_name,
      "pool_id" => api_key.pool_id,
      "status" => api_key.status,
      "dashboard_access" => api_key.dashboard_access,
      "max_active_requests" => api_key.max_active_requests || "",
      "expires_at" => DateTimeInput.local_value(api_key.expires_at, timezone),
      "stored_expires_at" => api_key.expires_at,
      "expiry_timezone" => timezone,
      "model_mode" => model_mode(api_key.allowed_model_identifiers),
      "allowed_model_identifiers" => api_key.allowed_model_identifiers || [],
      "enforced_model_identifier" => api_key.enforced_model_identifier || "",
      "enforced_reasoning_effort" => api_key.enforced_reasoning_effort || "",
      "maximum_reasoning_effort" => api_key.maximum_reasoning_effort || "",
      "reasoning_policy_mode" => reasoning_policy_mode(api_key),
      "enforced_service_tier" => api_key.enforced_service_tier || "",
      "operator_notes" => operator_notes(api_key),
      "stored_metadata" => stored_metadata(api_key),
      "retained_model_policies" => Enum.map(retained_model_bindings, &retained_model_policy/1)
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
    case parsed_expiry(params) do
      {:ok, _datetime} -> []
      {:error, reason} -> [expires_at: expiry_error(reason, expiry_timezone(params))]
    end
  end

  @spec expiry_timezone(params()) :: String.t()
  def expiry_timezone(params), do: Map.get(params, "expiry_timezone", "Etc/UTC")

  @spec expiry_summary(params(), DateTime.t()) :: String.t()
  def expiry_summary(params, now \\ DateTime.utc_now()) do
    case parsed_expiry(params) do
      {:ok, nil} ->
        gettext("Never")

      {:ok, datetime} ->
        description = DateTimeInput.describe(datetime, expiry_timezone(params))

        if DateTime.compare(datetime, now) != :gt,
          do: gettext("Expires immediately on save (%{description})", description: description),
          else: gettext("%{description} (in %{duration})", description: description, duration: expiry_duration(DateTime.diff(datetime, now)))

      {:error, reason} ->
        reason |> expiry_error(expiry_timezone(params)) |> CodexPoolerWeb.CoreComponents.translate_error()
    end
  end

  @spec input_errors(params()) :: [form_error()]
  def input_errors(params) do
    expiry_errors(params) ++ dashboard_access_errors(params) ++ active_request_errors(params)
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
    |> Map.update!("max_active_requests", &active_request_input/1)
  end

  @spec merge_params(params() | nil, params() | nil) :: params()
  def merge_params(current_params, incoming_params) do
    # LiveView omits this marker after the operator touches the field. Keeping
    # the old marker would hide its validation error on every later change.
    current_params
    |> Kernel.||(%{})
    |> Map.delete("_unused_expires_at")
    |> Map.merge(Map.drop(incoming_params || %{}, @carried_keys))
  end

  @spec attrs(params()) :: attrs()
  def attrs(params) do
    pool_id = blank_to_nil(params["pool_id"])
    reasoning_effort_attrs = reasoning_effort_attrs(params)

    %{
      display_name: params |> Map.get("display_name", "") |> to_string() |> String.trim(),
      pool_id: pool_id,
      status: blank_to_nil(params["status"]) || "active",
      dashboard_access: dashboard_access_value(params["dashboard_access"]),
      max_active_requests: blank_to_nil(params["max_active_requests"]),
      expires_at: expires_at_value(params),
      model_mode: params["model_mode"],
      allowed_model_identifiers: policy_model_identifiers(params),
      enforced_model_identifier: blank_to_nil(params["enforced_model_identifier"]),
      enforced_reasoning_effort: reasoning_effort_attrs.enforced_reasoning_effort,
      maximum_reasoning_effort: reasoning_effort_attrs.maximum_reasoning_effort,
      enforced_service_tier: canonicalize_service_tier(params["enforced_service_tier"]),
      default_policy: default_policy_attrs(params),
      model_policies: model_policy_attrs(params) ++ retained_model_policies(params),
      metadata: metadata_attrs(params)
    }
    |> put_edit_revision(params)
  end

  defp put_edit_revision(attrs, params) do
    if blank_to_nil(params["id"]) do
      Map.put(attrs, :expected_edit_revision, params["stored_edit_revision"])
    else
      attrs
    end
  end

  @doc """
  The stored model overrides the form keeps unedited: every model binding
  after the one it shows, in the order `params_for/2` read them.
  """
  @spec retained_model_policies(params()) :: [params()]
  def retained_model_policies(%{"retained_model_policies" => policies}) when is_list(policies),
    do: Enum.filter(policies, &is_map/1)

  def retained_model_policies(_params), do: []

  @spec review_errors(params()) :: [String.t()]
  def review_errors(params) do
    []
    |> maybe_add_error(blank_to_nil(params["display_name"]) == nil, gettext("Display name is required"))
    |> maybe_add_error(blank_to_nil(params["pool_id"]) == nil, gettext("Pool is required"))
    |> maybe_add_error(
      active_request_errors(params) != [],
      gettext("Active request limit must be a positive whole number")
    )
    |> maybe_add_error(
      invalid_dashboard_access?(params["dashboard_access"]),
      gettext("Observatory access must be enabled or disabled")
    )
    |> maybe_add_error(
      expiry_errors(params) != [],
      expiry_review_error(params)
    )
    |> maybe_add_error(
      params["model_mode"] == "selected_models" and policy_model_identifiers(params) == [],
      gettext("Selected model mode needs at least one model")
    )
    |> maybe_add_error(enforced_model_conflict?(params), gettext("Enforced model must be allowed"))
    |> add_duplicate_model_override_error(params)
    |> maybe_add_error(
      incomplete_reasoning_policy?(params),
      gettext("Allow up to needs a maximum reasoning effort")
    )
    |> maybe_add_error(
      incomplete_exact_reasoning_policy?(params),
      gettext("Always use needs a reasoning effort")
    )
    |> Enum.reverse()
  end

  @spec reasoning_effort_options() :: [option()]
  def reasoning_effort_options do
    [
      {gettext("Do not enforce"), ""},
      {gettext("None (request no reasoning)"), "none"},
      {gettext("Minimal"), "minimal"},
      {gettext("Low"), "low"},
      {gettext("Medium"), "medium"},
      {gettext("High"), "high"},
      {gettext("Extra high"), "xhigh"},
      {gettext("Max"), "max"},
      {gettext("Ultra"), "ultra"}
    ]
  end

  @spec service_tier_options() :: [option()]
  def service_tier_options do
    [
      {gettext("Leave unchanged"), ""},
      {gettext("Auto - upstream chooses"), "auto"},
      {gettext("Default - standard capacity"), "default"},
      {gettext("Flex - flexible capacity"), "flex"},
      {gettext("Fast/Priority mode"), "priority"},
      {gettext("Ultrafast mode"), "ultrafast"},
      {gettext("Scale - scale capacity"), "scale"}
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

    [{gettext("Do not enforce"), ""} | Enum.map(selected_values, &{&1, &1})]
  end

  @spec review_sections(Phoenix.HTML.Form.t(), selector_state(), Pool.t() | nil) ::
          [review_section()]
  def review_sections(form, selector_state, selected_pool) do
    [
      {gettext("Basics"), basics_review_rows(form, selected_pool)},
      {gettext("Models"), model_review_rows(form, selector_state)},
      {gettext("Limits"), limit_review_rows(form)}
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

  defp split_model_bindings(policy_bindings) do
    case Enum.filter(policy_bindings, &(&1.binding_scope == "model")) do
      [] -> {nil, []}
      [shown | retained] -> {shown, retained}
    end
  end

  defp retained_model_policy(%APIKeyPolicyBinding{} = binding) do
    Map.new(["model_identifier", "status" | @limit_fields], fn field ->
      {field, Map.get(binding, String.to_existing_atom(field))}
    end)
  end

  defp stored_metadata(%APIKey{metadata: metadata}) when is_map(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  defp stored_metadata(_api_key), do: %{}

  # The stored metadata with the edited note: a key's labels and any other
  # stored entry stay as they are, and a key that never had a note keeps no
  # note entry, so an unchanged edit writes the metadata it read.
  defp metadata_attrs(params) do
    notes = blank_to_nil(params["operator_notes"])

    metadata =
      case params["stored_metadata"] do
        metadata when is_map(metadata) -> metadata
        _other -> %{}
      end

    if notes || Map.has_key?(metadata, "operator_notes"),
      do: Map.put(metadata, "operator_notes", notes),
      else: metadata
  end

  defp add_duplicate_model_override_error(errors, params) do
    shown_model = normalize_model_for_compare(params["model_policy_model_identifier"])

    duplicate =
      shown_model &&
        Enum.find(retained_model_policies(params), &(normalize_model_for_compare(&1["model_identifier"]) == shown_model))

    case duplicate do
      nil -> errors
      policy -> [gettext("%{model} already has its own model override", model: policy["model_identifier"]) | errors]
    end
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

  defp expires_at_value(params) do
    case parsed_expiry(params) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> params["expires_at"]
    end
  end

  defp parsed_expiry(params) do
    value = params["expires_at"]
    timezone = expiry_timezone(params)

    case params["stored_expires_at"] do
      %DateTime{} = stored ->
        if value == DateTimeInput.local_value(stored, timezone),
          do: {:ok, stored},
          else: DateTimeInput.parse(value, timezone)

      _missing ->
        DateTimeInput.parse(value, timezone)
    end
  end

  defp expiry_review_error(params) do
    case expiry_errors(params) do
      [expires_at: error] -> gettext("Expiry %{message}", message: CodexPoolerWeb.CoreComponents.translate_error(error))
      [] -> ""
    end
  end

  defp expiry_error(:ambiguous, timezone), do: {"occurs twice in %{timezone}; choose a time outside the repeated hour", [timezone: timezone]}
  defp expiry_error(:gap, timezone), do: {"does not exist in %{timezone} because the clocks move forward", [timezone: timezone]}
  defp expiry_error(:unknown_timezone, _timezone), do: {"needs a valid account timezone", []}
  defp expiry_error(:invalid, _timezone), do: {"must be a valid date and time", []}

  defp expiry_duration(seconds) when seconds < 60, do: gettext("less than a minute")
  defp expiry_duration(seconds) when seconds < 3_600, do: gettext("%{minutes} min", minutes: div(seconds, 60))
  defp expiry_duration(seconds) when seconds < 86_400, do: gettext("%{hours} h %{minutes} min", hours: div(seconds, 3_600), minutes: div(rem(seconds, 3_600), 60))
  defp expiry_duration(seconds), do: ngettext("%{count} days", "%{count} days", div(seconds, 86_400))

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
      "max_active_requests" => "",
      "expires_at" => "",
      "stored_expires_at" => nil,
      "expiry_timezone" => "Etc/UTC",
      "model_mode" => "all_models",
      "allowed_model_identifiers" => [],
      "manual_model_identifiers_text" => "",
      "enforced_model_identifier" => "",
      "enforced_reasoning_effort" => "",
      "maximum_reasoning_effort" => "",
      "reasoning_policy_mode" => "unrestricted",
      "enforced_service_tier" => "",
      "operator_notes" => "",
      "model_policy_model_identifier" => "",
      "stored_metadata" => %{"labels" => []},
      "retained_model_policies" => []
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
      {gettext("Name"), blank_to_nil(form[:display_name].value) || gettext("Missing")},
      {gettext("Pool"), selected_pool_name(selected_pool)},
      {gettext("Status"), status_label(form[:status].value || "active")},
      {gettext("Observatory access"), dashboard_access_label(form[:dashboard_access].value)},
      {gettext("Expires"), expiry_summary(form.params)}
    ]
  end

  defp model_review_rows(form, selector_state) do
    [
      {gettext("Mode"), model_mode_label(form[:model_mode].value)},
      {gettext("Selected"), model_selection_summary(form, selector_state)},
      {gettext("Enforced model"), blank_to_nil(form[:enforced_model_identifier].value) || gettext("Not enforced")},
      {gettext("Reasoning"), reasoning_policy_label(form)},
      {gettext("Service tier"), blank_to_nil(form[:enforced_service_tier].value) || gettext("Not enforced")}
    ]
  end

  defp limit_review_rows(form) do
    values =
      @limit_fields
      |> Enum.flat_map(fn field ->
        [
          {gettext("Default %{limit}", limit: limit_field_label(field)), normalized_limit_value(form[String.to_atom("default_#{field}")].value)},
          {gettext("Model %{limit}", limit: limit_field_label(field)), normalized_limit_value(form[String.to_atom("model_#{field}")].value)}
        ]
      end)
      |> Enum.reject(fn {_label, value} -> is_nil(value) end)

    key_wide =
      {gettext("Active requests across all models"), normalized_limit_value(form[:max_active_requests].value) || gettext("Disabled")}

    model = blank_to_nil(form[:model_policy_model_identifier].value)
    model_rows = if model, do: [{gettext("Model override"), model}], else: []

    model_rows =
      case form.params |> retained_model_policies() |> Enum.map(& &1["model_identifier"]) do
        [] -> model_rows
        models -> model_rows ++ [{gettext("Other model overrides"), gettext("%{models} (kept as saved)", models: Enum.join(models, ", "))}]
      end

    case values do
      [] -> [key_wide | model_rows] ++ [{gettext("Token and rate limits"), gettext("No caps configured")}]
      rows -> [key_wide | model_rows] ++ rows
    end
  end

  defp selected_pool_name(%Pool{name: name}), do: name
  defp selected_pool_name(_pool), do: gettext("Missing")

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

  defp model_mode_label("selected_models"), do: gettext("Selected models")
  defp model_mode_label("deny_all_models"), do: gettext("Deny all models")
  defp model_mode_label(_mode), do: gettext("All models")

  defp reasoning_policy_label(form) do
    case form[:reasoning_policy_mode].value do
      "allow_up_to" ->
        reasoning_policy_value(:allow_up_to, form[:maximum_reasoning_effort].value)

      "always_use" ->
        reasoning_policy_value(:always_use, form[:enforced_reasoning_effort].value)

      _other ->
        gettext("Unrestricted")
    end
  end

  defp reasoning_policy_value(mode, value) do
    case blank_to_nil(value) do
      nil ->
        if mode == :allow_up_to, do: gettext("Allow up to"), else: gettext("Always use")

      effort ->
        if mode == :allow_up_to,
          do: gettext("Allow up to %{effort}", effort: reasoning_effort_label(effort)),
          else: gettext("Always use %{effort}", effort: reasoning_effort_label(effort))
    end
  end

  defp reasoning_effort_label("xhigh"), do: gettext("Extra high")
  defp reasoning_effort_label("none"), do: gettext("None")
  defp reasoning_effort_label("minimal"), do: gettext("Minimal")
  defp reasoning_effort_label("low"), do: gettext("Low")
  defp reasoning_effort_label("medium"), do: gettext("Medium")
  defp reasoning_effort_label("high"), do: gettext("High")
  defp reasoning_effort_label("max"), do: gettext("Max")
  defp reasoning_effort_label("ultra"), do: gettext("Ultra")
  defp reasoning_effort_label(effort), do: String.capitalize(effort)

  defp model_selection_summary(form, selector_state) do
    count =
      form[:allowed_model_identifiers].value
      |> list_input_values()
      |> Enum.concat(split_allow_list_text(form[:manual_model_identifiers_text].value))
      |> Enum.uniq()
      |> length()

    selection =
      cond do
        form[:model_mode].value == "all_models" -> gettext("All current and future models")
        form[:model_mode].value == "deny_all_models" -> gettext("No model access")
        true -> ngettext("%{count} selected model", "%{count} selected models", count)
      end

    model_selection_with_unavailable(selection, selector_state)
  end

  defp model_selection_with_unavailable(selection, %{selected_unavailable_chips: []}), do: selection

  defp model_selection_with_unavailable(selection, %{selected_unavailable_chips: chips}),
    do: gettext("%{selection} · %{unavailable}", selection: selection, unavailable: ngettext("%{count} unavailable saved", "%{count} unavailable saved", length(chips)))

  defp status_label("active"), do: gettext("active")
  defp status_label("paused"), do: gettext("paused")
  defp status_label("revoked"), do: gettext("revoked")
  defp status_label(status), do: status

  defp limit_field_label("max_requests_per_minute"), do: gettext("Requests per minute")
  defp limit_field_label("max_tokens_per_day"), do: gettext("Tokens per day")
  defp limit_field_label("max_tokens_per_week"), do: gettext("Tokens per week")
  defp limit_field_label("max_input_tokens_per_request"), do: gettext("Input tokens per request")
  defp limit_field_label("max_output_tokens_per_request"), do: gettext("Output tokens per request")

  # An empty note stays empty: the textarea shows its own placeholder, and a
  # placeholder seeded as the value was saved as the note on the next edit
  # (findings#206 row 206-503).
  defp operator_notes(%APIKey{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("operator_notes", Map.get(metadata, :operator_notes))
    |> blank_to_nil()
    |> Kernel.||("")
  end

  defp operator_notes(_api_key), do: ""

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

  defp active_request_errors(params) do
    case blank_to_nil(params["max_active_requests"]) do
      nil ->
        []

      value ->
        case parse_integer(value) do
          {:ok, count} when count > 0 and count <= 2_147_483_647 -> []
          _invalid -> [max_active_requests: {"must be a positive whole number", []}]
        end
    end
  end

  defp active_request_input(value) when is_binary(value) or is_integer(value) or is_nil(value),
    do: value

  defp active_request_input(_value), do: "invalid"

  defp invalid_dashboard_access?(value), do: parse_dashboard_access(value) == :error

  defp dashboard_access_label(value) do
    case parse_dashboard_access(value) do
      {:ok, true} -> gettext("Enabled")
      {:ok, false} -> gettext("Disabled")
      :error -> gettext("Invalid")
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

  defp canonicalize_service_tier(value) when is_binary(value), do: ServiceTier.canonicalize(value)
  defp canonicalize_service_tier(value), do: value
end
