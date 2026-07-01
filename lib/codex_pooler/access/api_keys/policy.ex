defmodule CodexPooler.Access.APIKeys.Policy do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope

  @status_active "active"
  @status_paused "paused"
  @status_revoked "revoked"
  @reasoning_efforts ~w(none minimal low medium high xhigh max ultra)
  @service_tiers ~w(auto default flex priority scale)

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type policy_result :: {:ok, map()} | {:error, atom() | access_error()}

  @spec normalize(term()) :: policy_result()
  def normalize(nil), do: {:error, :api_key_missing}
  def normalize(%APIKey{} = api_key), do: normalize_source(api_key)
  def normalize(policy) when is_map(policy), do: normalize_source(policy)
  def normalize(_policy), do: {:error, :api_key_policy_malformed}

  @spec authorize(term(), map()) :: {:ok, map()} | {:error, atom()}
  def authorize(api_key_or_policy, attrs \\ %{})

  def authorize(api_key_or_policy, attrs) when is_map(attrs) do
    with {:ok, policy} <- normalize(api_key_or_policy) do
      authorize_normalized(policy, attrs)
    end
  end

  def authorize(_api_key_or_policy, _attrs),
    do: {:error, :api_key_policy_malformed}

  @spec allow_list_mode(nil | list(), :models) ::
          :all_models | :deny_all_models | :selected_models
  def allow_list_mode(nil, :models), do: :all_models
  def allow_list_mode([], :models), do: :deny_all_models
  def allow_list_mode(_values, :models), do: :selected_models

  @spec normalize_attrs(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, access_error()}
  def normalize_attrs(%Scope{}, _pool_id, attrs) do
    with {:ok, allowed_model_identifiers} <- normalize_model_mode(attrs),
         {:ok, enforced_model_identifier} <- normalize_enforced_model(attrs),
         :ok <- validate_enforced_model_mode(allowed_model_identifiers, enforced_model_identifier),
         {:ok, enforced_reasoning_effort} <- normalize_enforced_reasoning_effort(attrs),
         {:ok, enforced_service_tier} <- normalize_enforced_service_tier(attrs) do
      {:ok,
       %{
         allowed_model_identifiers: allowed_model_identifiers,
         enforced_model_identifier: enforced_model_identifier,
         enforced_reasoning_effort: enforced_reasoning_effort,
         enforced_service_tier: enforced_service_tier
       }}
    end
  end

  @spec normalize_inputs(map()) :: {:ok, [map()]} | {:error, access_error()}
  def normalize_inputs(attrs) do
    default_policy = Map.get(attrs, :default_policy) || Map.get(attrs, "default_policy") || %{}
    model_policies = Map.get(attrs, :model_policies) || Map.get(attrs, "model_policies") || []

    with {:ok, default_policy} <- normalize_default_policy(default_policy),
         {:ok, model_policies} <- normalize_model_policies(model_policies) do
      {:ok, [default_policy | model_policies]}
    end
  end

  @spec input(term(), [term()]) :: term() | nil
  def input(source, keys) when is_map(source) and is_list(keys) do
    nested_policy = Map.get(source, :policy) || Map.get(source, "policy") || %{}

    Enum.reduce_while(keys, nil, fn key, _acc ->
      cond do
        Map.has_key?(source, key) ->
          {:halt, Map.get(source, key)}

        is_map(nested_policy) and Map.has_key?(nested_policy, key) ->
          {:halt, Map.get(nested_policy, key)}

        true ->
          {:cont, nil}
      end
    end)
  end

  def input(_source, _keys), do: nil

  defp normalize_source(source) do
    with {:ok, status} <-
           normalize_status(input(source, [:status, "status", :enabled, "enabled"])),
         :ok <- ensure_enabled(status),
         {:ok, allowed_model_identifiers} <-
           normalize_model_allow_list(
             input(source, [
               :allowed_model_identifiers,
               "allowed_model_identifiers",
               :allowed_models,
               "allowed_models",
               :allowed_model_ids,
               "allowed_model_ids"
             ])
           ),
         {:ok, enforced_model_identifier} <- normalize_enforced_model(source),
         :ok <- validate_enforced_model_mode(allowed_model_identifiers, enforced_model_identifier),
         {:ok, enforced_reasoning_effort} <- normalize_enforced_reasoning_effort(source),
         {:ok, enforced_service_tier} <- normalize_enforced_service_tier(source),
         {:ok, metadata} <- normalize_metadata(input(source, [:metadata, "metadata"])) do
      {:ok,
       %{
         api_key_id: input(source, [:id, "id", :api_key_id, "api_key_id"]),
         status: status,
         allowed_model_identifiers: allowed_model_identifiers,
         enforced_model_identifier: enforced_model_identifier,
         enforced_reasoning_effort: enforced_reasoning_effort,
         enforced_service_tier: enforced_service_tier,
         metadata: metadata
       }}
    else
      {:error, :api_key_disabled} -> {:error, :api_key_disabled}
      {:error, _reason} -> {:error, :api_key_policy_malformed}
    end
  end

  defp ensure_enabled(@status_active), do: :ok
  defp ensure_enabled(_status), do: {:error, :api_key_disabled}

  defp authorize_normalized(policy, attrs) do
    if model_allowed?(policy.allowed_model_identifiers, requested_model_identifier(attrs)) do
      {:ok, policy}
    else
      {:error, :model_not_allowed}
    end
  end

  defp requested_model_identifier(attrs) do
    input(attrs, [
      :model_identifier,
      "model_identifier",
      :model_id,
      "model_id",
      :model,
      "model"
    ])
  end

  defp normalize_status(nil), do: {:ok, @status_active}
  defp normalize_status(@status_active), do: {:ok, @status_active}
  defp normalize_status("enabled"), do: {:ok, @status_active}
  defp normalize_status(@status_paused), do: {:ok, @status_paused}
  defp normalize_status(@status_revoked), do: {:ok, @status_revoked}
  defp normalize_status("disabled"), do: {:ok, "disabled"}
  defp normalize_status(true), do: {:ok, @status_active}
  defp normalize_status(false), do: {:ok, "disabled"}
  defp normalize_status(_status), do: {:error, :api_key_policy_malformed}

  defp normalize_model_mode(attrs) do
    mode =
      input(attrs, [
        :model_mode,
        "model_mode",
        :allowed_models_mode,
        "allowed_models_mode"
      ])

    values =
      input(attrs, [
        :allowed_model_identifiers,
        "allowed_model_identifiers",
        :allowed_models,
        "allowed_models"
      ])

    normalize_mode_allow_list(mode, values, :models, &normalize_model_allow_list/1)
  end

  defp normalize_model_allow_list(nil), do: {:ok, nil}

  defp normalize_model_allow_list(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        if normalized == "" or Regex.match?(~r/[[:space:][:cntrl:]]/, normalized) do
          {:halt, {:error, :api_key_policy_malformed}}
        else
          {:cont, {:ok, [normalized | acc]}}
        end

      _value, _acc ->
        {:halt, {:error, :api_key_policy_malformed}}
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_model_allow_list(_values), do: {:error, :api_key_policy_malformed}

  defp normalize_mode_allow_list(nil, values, _family, normalizer), do: normalizer.(values)

  defp normalize_mode_allow_list(mode, values, family, normalizer) do
    case normalize_mode(mode, family) do
      {:all, _mode} -> {:ok, nil}
      {:deny_all, _mode} -> {:ok, []}
      {:selected, mode_name} -> normalize_selected_allow_list(values, mode_name, normalizer)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_selected_allow_list(values, mode_name, normalizer) do
    case normalizer.(values) do
      {:ok, normalized} ->
        if normalized in [nil, []] do
          {:error,
           access_error(:invalid_policy, "#{mode_name} requires at least one selected value")}
        else
          {:ok, normalized}
        end

      {:error, _reason} ->
        {:error, access_error(:invalid_policy, "#{mode_name} has invalid values")}
    end
  end

  defp normalize_mode(mode, family) when is_atom(mode),
    do: normalize_mode(Atom.to_string(mode), family)

  defp normalize_mode(mode, family) when is_binary(mode) do
    normalized = mode |> String.trim() |> String.downcase()

    all_modes = ["all", "all_#{family}"]
    selected_modes = ["selected", "selected_#{family}"]
    deny_all_modes = ["deny_all", "deny_all_#{family}", "none"]

    cond do
      normalized in all_modes -> {:all, normalized}
      normalized in selected_modes -> {:selected, normalized}
      normalized in deny_all_modes -> {:deny_all, normalized}
      true -> {:error, access_error(:invalid_policy, "unknown #{family} mode")}
    end
  end

  defp normalize_mode(_mode, family),
    do: {:error, access_error(:invalid_policy, "unknown #{family} mode")}

  defp normalize_enforced_model(attrs) do
    case input(attrs, [:enforced_model_identifier, "enforced_model_identifier"]) do
      nil -> {:ok, nil}
      value when is_binary(value) -> normalize_single_model_identifier(value)
      _value -> {:error, access_error(:invalid_policy, "enforced_model_identifier is invalid")}
    end
  end

  defp normalize_enforced_reasoning_effort(attrs) do
    normalize_enforced_enum(
      input(attrs, [:enforced_reasoning_effort, "enforced_reasoning_effort"]),
      @reasoning_efforts,
      "enforced_reasoning_effort is invalid"
    )
  end

  defp normalize_enforced_service_tier(attrs) do
    normalize_enforced_enum(
      input(attrs, [:enforced_service_tier, "enforced_service_tier"]),
      @service_tiers,
      "enforced_service_tier is invalid"
    )
  end

  defp normalize_enforced_enum(nil, _allowed, _message), do: {:ok, nil}

  defp normalize_enforced_enum(value, allowed, message) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" -> {:ok, nil}
      normalized in allowed -> {:ok, normalized}
      true -> {:error, access_error(:invalid_policy, message)}
    end
  end

  defp normalize_enforced_enum(_value, _allowed, message),
    do: {:error, access_error(:invalid_policy, message)}

  defp normalize_single_model_identifier(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:ok, nil}

      Regex.match?(~r/[[:space:][:cntrl:]]/, normalized) ->
        {:error, access_error(:invalid_policy, "model identifiers cannot contain whitespace")}

      true ->
        {:ok, normalized}
    end
  end

  defp validate_enforced_model_mode([], enforced_model_identifier)
       when is_binary(enforced_model_identifier),
       do:
         {:error, access_error(:invalid_policy, "enforced model is not allowed in deny-all mode")}

  defp validate_enforced_model_mode(allowed_model_identifiers, enforced_model_identifier)
       when is_list(allowed_model_identifiers) and is_binary(enforced_model_identifier) do
    if enforced_model_identifier in allowed_model_identifiers do
      :ok
    else
      {:error,
       access_error(:invalid_policy, "enforced model must be included in selected models")}
    end
  end

  defp validate_enforced_model_mode(_allowed_model_identifiers, _enforced_model_identifier),
    do: :ok

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when metadata == %{}, do: {:ok, %{}}

  defp normalize_metadata(metadata) when is_map(metadata) do
    labels = Map.get(metadata, "labels", Map.get(metadata, :labels, []))
    operator_notes = Map.get(metadata, "operator_notes", Map.get(metadata, :operator_notes))

    cond do
      not is_list(labels) or not Enum.all?(labels, &is_binary/1) ->
        {:error, :api_key_policy_malformed}

      not (is_nil(operator_notes) or is_binary(operator_notes)) ->
        {:error, :api_key_policy_malformed}

      true ->
        {:ok,
         %{
           "labels" =>
             Enum.map(labels, &String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
           "operator_notes" => operator_notes
         }}
    end
  end

  defp normalize_metadata(_metadata), do: {:error, :api_key_policy_malformed}

  defp normalize_default_policy(policy) when is_map(policy) do
    scope = Map.get(policy, :binding_scope) || Map.get(policy, "binding_scope") || "default"
    model_identifier = Map.get(policy, :model_identifier) || Map.get(policy, "model_identifier")

    cond do
      scope != "default" ->
        {:error, access_error(:invalid_scope, "default_policy.binding_scope must be default")}

      present?(model_identifier) ->
        {:error,
         access_error(
           :invalid_model_binding_shape,
           "default_policy.model_identifier is not allowed"
         )}

      true ->
        {:ok, policy_attrs(policy, "default")}
    end
  end

  defp normalize_default_policy(_policy),
    do: {:error, access_error(:invalid_request, "default_policy must be a map")}

  defp normalize_model_policies(policies) when is_list(policies) do
    policies
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {policy, index}, {:ok, acc} ->
      case normalize_model_policy(policy, index) do
        {:ok, policy_attrs} -> {:cont, {:ok, [policy_attrs | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, policies} -> {:ok, Enum.reverse(policies)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_model_policies(_policies),
    do: {:error, access_error(:invalid_request, "model_policies must be a list")}

  defp normalize_model_policy(policy, index) when is_map(policy) do
    scope = Map.get(policy, :binding_scope) || Map.get(policy, "binding_scope") || "model"
    model_identifier = Map.get(policy, :model_identifier) || Map.get(policy, "model_identifier")

    cond do
      scope != "model" ->
        {:error,
         access_error(:invalid_scope, "model_policies[#{index}].binding_scope must be model")}

      not present?(model_identifier) ->
        {:error,
         access_error(
           :invalid_model_binding_shape,
           "model_policies[#{index}].model_identifier is required"
         )}

      true ->
        {:ok, policy_attrs(policy, "model")}
    end
  end

  defp normalize_model_policy(_policy, index),
    do: {:error, access_error(:invalid_request, "model_policies[#{index}] must be a map")}

  defp policy_attrs(policy, scope) do
    %{
      binding_scope: scope,
      model_identifier: Map.get(policy, :model_identifier) || Map.get(policy, "model_identifier"),
      status: Map.get(policy, :status) || Map.get(policy, "status") || @status_active,
      max_requests_per_minute:
        Map.get(policy, :max_requests_per_minute) || Map.get(policy, "max_requests_per_minute"),
      max_tokens_per_day:
        Map.get(policy, :max_tokens_per_day) || Map.get(policy, "max_tokens_per_day"),
      max_tokens_per_week:
        Map.get(policy, :max_tokens_per_week) || Map.get(policy, "max_tokens_per_week"),
      max_input_tokens_per_request:
        Map.get(policy, :max_input_tokens_per_request) ||
          Map.get(policy, "max_input_tokens_per_request"),
      max_output_tokens_per_request:
        Map.get(policy, :max_output_tokens_per_request) ||
          Map.get(policy, "max_output_tokens_per_request")
    }
  end

  defp model_allowed?(nil, _requested_model), do: true
  defp model_allowed?([], _requested_model), do: false

  defp model_allowed?(allowed, requested_model) when is_binary(requested_model) do
    normalized = requested_model |> String.trim() |> String.downcase()
    normalized != "" and normalized in allowed
  end

  defp model_allowed?(_allowed, _requested_model), do: false

  defp present?(value), do: value |> to_string() |> String.trim() != ""
  defp access_error(code, message), do: %{code: code, message: message}
end
