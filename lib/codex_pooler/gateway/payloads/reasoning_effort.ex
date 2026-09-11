defmodule CodexPooler.Gateway.Payloads.ReasoningEffort do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @known_efforts ~w(none minimal low medium high xhigh max ultra)
  @non_ultra_targets ~w(none minimal ultra)

  @spec extract(map(), RequestOptions.t()) :: String.t() | nil
  def extract(payload, %RequestOptions{} = request_options) when is_map(payload) do
    case request_options.openai_compatibility.source_endpoint do
      source_endpoint when is_binary(source_endpoint) ->
        extract_compatible(payload, request_options, source_endpoint)

      _source_endpoint ->
        extract_native(payload)
    end
  end

  @spec extract_native(map()) :: String.t() | nil
  def extract_native(payload) when is_map(payload) do
    with :absent <- present_nested_effort(payload),
         :absent <- present_clean_string(payload, "reasoning_effort"),
         :absent <- present_clean_string(payload, "reasoningEffort"),
         :absent <- present_thinking_effort(payload),
         :absent <- present_enabled_effort(payload, "enable_thinking") do
      nil
    else
      {:present, effort} -> effort
    end
  end

  @spec parameter(RequestOptions.t()) :: String.t()
  def parameter(%RequestOptions{} = request_options) do
    case request_options.openai_compatibility.source_endpoint do
      source_endpoint when is_binary(source_endpoint) ->
        if String.ends_with?(source_endpoint, "/chat/completions"),
          do: "reasoning_effort",
          else: "reasoning.effort"

      _source_endpoint ->
        "reasoning.effort"
    end
  end

  @spec normalize_known(term()) :: String.t() | nil
  def normalize_known(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @known_efforts, do: normalized
  end

  def normalize_known(_value), do: nil

  @spec rewrite_client_upstream(term()) :: term()
  def rewrite_client_upstream(value) when is_binary(value) do
    if normalize_for_compare(value) == "minimal", do: "low", else: value
  end

  def rewrite_client_upstream(value), do: value

  # The backend rejects the literal `ultra`, and it rejects `max` on models whose
  # catalog omits it. The alias lands on `max`, or on the highest listed level when
  # known catalog levels exclude `max`; it never targets `none` or `minimal`.
  @spec rewrite_backend_upstream(term(), [term()] | nil) :: term()
  def rewrite_backend_upstream(value, catalog_levels \\ nil)

  def rewrite_backend_upstream(value, catalog_levels) when is_binary(value) do
    if normalize_for_compare(value) == "ultra",
      do: backend_ultra_target(catalog_levels),
      else: value
  end

  def rewrite_backend_upstream(value, _catalog_levels), do: value

  defp extract_compatible(payload, request_options, source_endpoint) do
    if String.ends_with?(source_endpoint, "/chat/completions") do
      request_options.openai_compatibility.openai_chat_payload
      |> field("reasoning_effort")
      |> clean_string()
    else
      payload |> field("reasoning") |> field("effort") |> clean_string()
    end
  end

  defp present_nested_effort(payload) do
    case fetch_field(payload, "reasoning") do
      {:ok, reasoning} when is_map(reasoning) ->
        case fetch_field(reasoning, "effort") do
          {:ok, value} -> {:present, clean_string(value)}
          :error -> :absent
        end

      {:ok, _reasoning} ->
        :absent

      :error ->
        :absent
    end
  end

  defp present_clean_string(payload, key) do
    case fetch_field(payload, key) do
      {:ok, value} -> {:present, clean_string(value)}
      :error -> :absent
    end
  end

  defp present_thinking_effort(payload) do
    case fetch_field(payload, "thinking") do
      {:ok, value} -> {:present, thinking_effort(value)}
      :error -> :absent
    end
  end

  defp present_enabled_effort(payload, key) do
    case fetch_field(payload, key) do
      {:ok, value} -> {:present, enabled_effort(value)}
      :error -> :absent
    end
  end

  defp thinking_effort(value) when is_boolean(value), do: enabled_effort(value)

  defp thinking_effort(value) when is_binary(value) do
    case normalize_for_compare(value) do
      effort when effort in ~w(low medium high xhigh max ultra) -> effort
      enabled when enabled in ~w(enabled true on) -> "medium"
      _value -> nil
    end
  end

  defp thinking_effort(value) when is_map(value) do
    clean_string(field(value, "effort"), &String.downcase/1) ||
      thinking_map_enabled_effort(value)
  end

  defp thinking_effort(_value), do: nil

  defp thinking_map_enabled_effort(value) do
    case field(value, "type") do
      type when is_binary(type) ->
        if normalize_for_compare(type) == "enabled", do: "medium"

      _type ->
        enabled_effort(field(value, "enabled"))
    end
  end

  defp enabled_effort(true), do: "medium"
  defp enabled_effort(_enabled), do: nil

  defp field(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, field_value} -> field_value
      :error -> Map.get(value, atom_key(key))
    end
  end

  defp field(_value, _key), do: nil

  defp fetch_field(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, field_value} -> {:ok, field_value}
      :error -> Map.fetch(value, atom_key(key))
    end
  end

  defp atom_key("reasoning"), do: :reasoning
  defp atom_key("effort"), do: :effort
  defp atom_key("reasoning_effort"), do: :reasoning_effort
  defp atom_key("reasoningEffort"), do: :reasoningEffort
  defp atom_key("thinking"), do: :thinking
  defp atom_key("enable_thinking"), do: :enable_thinking
  defp atom_key("type"), do: :type
  defp atom_key("enabled"), do: :enabled
  defp atom_key(_key), do: nil

  defp clean_string(value, mapper \\ &Function.identity/1)

  defp clean_string(value, mapper) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> mapper.(trimmed)
    end
  end

  defp clean_string(_value, _mapper), do: nil

  defp normalize_for_compare(value), do: value |> String.trim() |> String.downcase()

  defp backend_ultra_target(catalog_levels) when is_list(catalog_levels) do
    targets =
      catalog_levels
      |> Enum.map(&normalize_known/1)
      |> Enum.reject(&(is_nil(&1) or &1 in @non_ultra_targets))

    cond do
      targets == [] -> "max"
      "max" in targets -> "max"
      true -> Enum.max_by(targets, &effort_rank/1)
    end
  end

  defp backend_ultra_target(_catalog_levels), do: "max"

  defp effort_rank(effort), do: Enum.find_index(@known_efforts, &(&1 == effort))
end
