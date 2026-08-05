defmodule CodexPooler.Catalog.ModelSelectorState do
  @moduledoc """
  Pure builder for API key model selector state.
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Catalog.ModelInfo

  @type catalog_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type catalog_state :: %{
          required(:status) => atom(),
          required(:reason) => String.t() | atom() | nil
        }

  @spec build(map(), catalog_state(), [Model.t()]) :: map()
  def build(attrs, catalog_state, visible_models)
      when is_map(attrs) and is_list(visible_models) do
    model_options = Enum.map(visible_models, &model_selector_option/1)
    option_ids = MapSet.new(model_options, & &1.identifier)
    manual_ids = selector_manual_identifiers(attrs)
    selected_ids = selector_selected_identifiers(attrs)

    selected_options =
      model_options
      |> Enum.filter(&(&1.identifier in selected_ids))
      |> Enum.map(&Map.put(&1, :selected?, true))

    selected_unavailable_chips =
      selected_ids
      |> Enum.reject(&(MapSet.member?(option_ids, &1) or &1 in manual_ids))
      |> Enum.map(&unavailable_model_chip(&1, catalog_state))

    manual_chips =
      manual_ids
      |> Enum.reject(&MapSet.member?(option_ids, &1))
      |> Enum.map(&manual_model_chip(&1, catalog_state))

    %{
      catalog: catalog_selector_metadata(catalog_state),
      mode: selector_model_mode(attrs),
      options: model_options,
      selected_options: selected_options,
      selected_unavailable_chips: selected_unavailable_chips,
      manual_chips: manual_chips,
      selected_identifiers: selected_ids,
      manual_identifiers: manual_ids,
      warnings: selector_warnings(catalog_state)
    }
  end

  @spec validate_manual_model_identifier(term()) :: {:ok, String.t()} | {:error, catalog_error()}
  def validate_manual_model_identifier(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:error, catalog_error(:invalid_model_identifier, "model identifier cannot be blank")}

      Regex.match?(~r/[[:space:][:cntrl:]]/, normalized) ->
        {:error,
         catalog_error(
           :invalid_model_identifier,
           "model identifier cannot contain whitespace or control characters"
         )}

      true ->
        {:ok, normalized}
    end
  end

  def validate_manual_model_identifier(_value),
    do: {:error, catalog_error(:invalid_model_identifier, "model identifier must be text")}

  @spec validate_manual_model_identifiers(term()) ::
          {:ok, [String.t()]} | {:error, catalog_error()}
  def validate_manual_model_identifiers(values) do
    values
    |> list_input_values()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case validate_manual_model_identifier(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, identifiers} -> {:ok, identifiers |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp model_selector_option(%Model{} = model) do
    %{
      identifier: normalize_token(model.exposed_model_id),
      display_name: model.display_name,
      upstream_model_id: model.upstream_model_id,
      source_assignment_count: model.source_assignment_count,
      source_assignment_ids: source_assignment_ids(model),
      model_info: ModelInfo.from_model(model, source_assignment_ids(model)),
      supports_responses: model.supports_responses,
      supports_streaming: model.supports_streaming,
      supports_tools: model.supports_tools,
      supports_reasoning: model.supports_reasoning,
      status: :available,
      selected?: false
    }
  end

  defp source_assignment_ids(%Model{} = model) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      ids when is_list(ids) -> ids
      _ids -> []
    end
  end

  defp unavailable_model_chip(identifier, catalog_state) do
    %{
      identifier: identifier,
      label: identifier,
      source: :saved_selection,
      status: unavailable_chip_status(catalog_state.status),
      warning: "Saved model is not available in the current routable catalog"
    }
  end

  defp manual_model_chip(identifier, catalog_state) do
    %{
      identifier: identifier,
      label: identifier,
      source: :manual,
      status: manual_chip_status(catalog_state.status),
      warning: manual_chip_warning(catalog_state.status)
    }
  end

  defp unavailable_chip_status(:synced), do: :unavailable
  defp unavailable_chip_status(:empty), do: :unavailable
  defp unavailable_chip_status(_status), do: :stale

  defp manual_chip_status(:synced), do: :custom
  defp manual_chip_status(_status), do: :manual_unverified

  defp manual_chip_warning(:synced),
    do: "Manual model will be allowed even though it is not in the catalog"

  defp manual_chip_warning(_status),
    do: "Manual model cannot be verified until the catalog is available"

  defp catalog_selector_metadata(%{status: status, reason: reason}) do
    %{
      status: status,
      reason: reason,
      severity: catalog_warning_severity(status),
      message: catalog_warning_message(status, reason),
      requires_acknowledgement?: catalog_requires_acknowledgement?(status)
    }
  end

  defp catalog_warning_severity(:synced), do: :ok
  defp catalog_warning_severity(:syncing), do: :info
  defp catalog_warning_severity(:empty), do: :warning
  defp catalog_warning_severity(_status), do: :warning

  defp catalog_warning_message(:synced, _reason), do: nil
  defp catalog_warning_message(:syncing, _reason), do: "Model catalog sync is still running"
  defp catalog_warning_message(:stale, _reason), do: "Model catalog is stale"
  defp catalog_warning_message(:failed, reason), do: reason || "Model catalog sync failed"
  defp catalog_warning_message(:unavailable, _reason), do: "Model catalog has not been synced yet"
  defp catalog_warning_message(:empty, _reason), do: "Model catalog has no routable models"

  defp catalog_requires_acknowledgement?(:synced), do: false
  defp catalog_requires_acknowledgement?(:syncing), do: true
  defp catalog_requires_acknowledgement?(:stale), do: true
  defp catalog_requires_acknowledgement?(:failed), do: true
  defp catalog_requires_acknowledgement?(:unavailable), do: true
  defp catalog_requires_acknowledgement?(:empty), do: true

  defp selector_warnings(%{status: :synced}), do: []

  defp selector_warnings(%{status: status, reason: reason}) do
    [
      %{
        code: status,
        reason: reason,
        severity: catalog_warning_severity(status),
        message: catalog_warning_message(status, reason),
        requires_acknowledgement?: catalog_requires_acknowledgement?(status)
      }
    ]
  end

  defp selector_model_mode(attrs) do
    mode =
      policy_input(attrs, [
        :model_mode,
        "model_mode",
        :allowed_models_mode,
        "allowed_models_mode"
      ])

    case mode do
      mode when mode in [:selected, :selected_models, "selected", "selected_models"] ->
        :selected_models

      mode when mode in [:deny_all, :deny_all_models, "deny_all", "deny_all_models", "none"] ->
        :deny_all_models

      _mode ->
        :all_models
    end
  end

  defp selector_selected_identifiers(attrs) do
    attrs
    |> policy_input([
      :selected_model_identifiers,
      "selected_model_identifiers",
      :allowed_model_identifiers,
      "allowed_model_identifiers",
      :allowed_models,
      "allowed_models"
    ])
    |> normalize_model_identifier_values()
  end

  defp selector_manual_identifiers(attrs) do
    attrs
    |> policy_input([
      :manual_model_identifiers,
      "manual_model_identifiers",
      :manual_models,
      "manual_models"
    ])
    |> normalize_model_identifier_values()
  end

  defp normalize_model_identifier_values(values) do
    values
    |> list_input_values()
    |> Enum.reduce([], fn value, acc ->
      case validate_manual_model_identifier(value) do
        {:ok, normalized} -> [normalized | acc]
        {:error, _reason} -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp list_input_values(nil), do: []

  defp list_input_values(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_input_values(values) when is_list(values), do: values
  defp list_input_values(_value), do: []

  defp policy_input(source, keys) when is_map(source) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(source, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_token(value), do: value

  defp catalog_error(code, message), do: %{code: code, message: message}
end
