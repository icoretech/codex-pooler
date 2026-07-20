defmodule CodexPooler.Gateway.Routing.ModelMetadata do
  @moduledoc """
  Codex-compatible model metadata and capability helpers for gateway routing.
  """

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.MetadataProjection
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.ReasoningEffort

  @short_context_price_bucket "short_context"
  @long_context_price_bucket "long_context"
  @short_context_advertised_window 128_000
  @atom_metadata_keys Map.new(
                        ~w[
                          audio
                          audio_input
                          audio_transcription
                          capabilities
                          input_modalities
                          modalities
                          modes
                          output_modalities
                          supported_input_modalities
                          supported_modalities
                          supported_modes
                          supported_output_modalities
                          supports_reasoning_summaries
                          supports_reasoning_summary_parameter
                          transcription
                          transcriptions
                          upstream_model
                        ],
                        fn key -> {key, String.to_atom(key)} end
                      )

  @type metadata :: map()
  @type metadata_input :: Model.t() | metadata()
  @type pricing_buckets :: Catalog.pricing_bucket_map()
  @type context_window_overrides :: %{optional(String.t()) => pos_integer()}
  @type effective_model_serving_mode :: String.t() | nil

  @spec codex_model_payload(Model.t(), pricing_buckets()) :: map()
  def codex_model_payload(%Model{} = model, pricing_buckets),
    do: codex_model_payload(model, pricing_buckets, nil)

  @spec codex_model_payload(Model.t(), pricing_buckets(), MetadataProjection.t() | nil) :: map()
  def codex_model_payload(%Model{} = model, pricing_buckets, reasoning_projection) do
    settings = OperationalSettings.current()

    codex_model_payload(
      model,
      pricing_buckets,
      reasoning_projection,
      settings.model_context_window_overrides
    )
  end

  @spec codex_model_payload(
          Model.t(),
          pricing_buckets(),
          MetadataProjection.t() | nil,
          context_window_overrides()
        ) :: map()
  def codex_model_payload(
        %Model{} = model,
        pricing_buckets,
        reasoning_projection,
        context_window_overrides
      )
      when is_map(context_window_overrides) do
    metadata =
      model
      |> metadata()
      |> apply_context_window_policy(model, pricing_buckets, context_window_overrides)

    model
    |> base_codex_model_payload(metadata, reasoning_projection)
    |> maybe_put_reasoning_summary_capabilities(metadata)
    |> maybe_put_comp_hash(metadata)
  end

  @spec codex_model_payload(
          Model.t(),
          pricing_buckets(),
          MetadataProjection.t() | nil,
          context_window_overrides(),
          effective_model_serving_mode()
        ) :: map()
  def codex_model_payload(
        %Model{} = model,
        pricing_buckets,
        reasoning_projection,
        context_window_overrides,
        effective_model_serving_mode
      )
      when is_map(context_window_overrides) do
    model
    |> codex_model_payload(pricing_buckets, reasoning_projection, context_window_overrides)
    |> Map.put("use_responses_lite", effective_model_serving_mode == "lite")
  end

  defp base_codex_model_payload(model, metadata, reasoning_projection) do
    %{
      "slug" => model.exposed_model_id,
      "display_name" => model.display_name,
      "description" => metadata["description"] || model.display_name,
      "default_reasoning_level" =>
        projected_default_reasoning_level(reasoning_projection, model, metadata),
      "supported_reasoning_levels" =>
        projected_reasoning_levels(reasoning_projection, model, metadata),
      "shell_type" => "shell_command",
      "visibility" => "list",
      "priority" => int_metadata(metadata, "priority", 0),
      "additional_speed_tiers" => list_metadata(metadata, "additional_speed_tiers"),
      "service_tiers" => list_metadata(metadata, "service_tiers"),
      "available_in_plans" => list_metadata(metadata, "available_in_plans"),
      "default_service_tier" => string_metadata(metadata, "default_service_tier"),
      "minimal_client_version" => json_metadata(metadata, "minimal_client_version"),
      "availability_nux" => nil,
      "upgrade" => nil,
      "base_instructions" => metadata["base_instructions"] || "",
      "default_reasoning_summary" => metadata["default_reasoning_summary"] || "auto",
      "support_verbosity" => bool_metadata(metadata, "support_verbosity"),
      "default_verbosity" => metadata["default_verbosity"],
      "apply_patch_tool_type" => metadata["apply_patch_tool_type"],
      "web_search_tool_type" => metadata["web_search_tool_type"] || "text",
      "truncation_policy" =>
        metadata["truncation_policy"] ||
          %{
            "mode" => "bytes",
            "limit" => int_metadata(metadata, "truncation_limit", 10_000)
          },
      "supports_parallel_tool_calls" => model.supports_tools,
      "supports_image_detail_original" => supports_image_detail_original?(metadata),
      "model_messages" => map_metadata(metadata, "model_messages"),
      "include_skills_usage_instructions" =>
        bool_metadata(metadata, "include_skills_usage_instructions"),
      "prefer_websockets" => bool_metadata(metadata, "prefer_websockets"),
      "reasoning_summary_format" => string_metadata(metadata, "reasoning_summary_format"),
      "context_window" => metadata["context_window"],
      "max_context_window" => metadata["max_context_window"],
      "auto_compact_token_limit" => metadata["auto_compact_token_limit"],
      "effective_context_window_percent" =>
        int_metadata(metadata, "effective_context_window_percent", 95),
      "experimental_supported_tools" => list_metadata(metadata, "experimental_supported_tools"),
      "input_modalities" => input_modalities(metadata),
      "supports_search_tool" => bool_metadata(metadata, "supports_search_tool"),
      "tool_mode" => tool_mode_metadata(metadata),
      "upstream_model_id" => model.upstream_model_id,
      "exposed_model_id" => model.exposed_model_id,
      "status" => model.status,
      "supported_in_api" => model.supports_responses,
      "supports_responses" => model.supports_responses,
      "supports_streaming" => model.supports_streaming,
      "supports_tools" => model.supports_tools,
      "supports_reasoning" => model.supports_reasoning,
      "use_responses_lite" => bool_metadata(metadata, "use_responses_lite")
    }
  end

  defp maybe_put_reasoning_summary_capabilities(payload, metadata) do
    payload =
      if supports_reasoning_summary_parameter?(metadata) do
        payload
      else
        Map.put(payload, "supports_reasoning_summary_parameter", false)
      end

    case literal_boolean_metadata(metadata, "supports_reasoning_summaries") do
      value when is_boolean(value) -> Map.put(payload, "supports_reasoning_summaries", value)
      nil -> payload
    end
  end

  defp maybe_put_comp_hash(payload, metadata) do
    case optional_string_metadata(metadata, "comp_hash") do
      nil -> payload
      comp_hash -> Map.put(payload, "comp_hash", comp_hash)
    end
  end

  @spec supports_reasoning_summary_parameter?(metadata_input()) :: boolean()
  def supports_reasoning_summary_parameter?(%Model{} = model) do
    model
    |> metadata()
    |> supports_reasoning_summary_parameter?()
  end

  def supports_reasoning_summary_parameter?(metadata) when is_map(metadata) do
    metadata =
      case metadata_value(metadata, "upstream_model") do
        %{} = upstream_model -> Map.merge(upstream_model, metadata)
        _value -> metadata
      end

    metadata_value(metadata, "supports_reasoning_summary_parameter") != false
  end

  def supports_reasoning_summary_parameter?(_metadata), do: true

  @spec selected_assignment_metadata(Model.t(), Ecto.UUID.t()) :: metadata()
  def selected_assignment_metadata(%Model{} = model, assignment_id)
      when is_binary(assignment_id) do
    get_in(model.metadata || %{}, ["source_assignment_models", assignment_id]) || metadata(model)
  end

  @spec assignment_source?(Model.t(), Ecto.UUID.t()) :: boolean()
  def assignment_source?(%Model{} = model, assignment_id) when is_binary(assignment_id) do
    metadata = model.metadata || %{}
    source_assignment_ids = Map.get(metadata, "source_assignment_ids")
    source_assignment_models = Map.get(metadata, "source_assignment_models")

    (is_list(source_assignment_ids) and assignment_id in source_assignment_ids) or
      (is_map(source_assignment_models) and Map.has_key?(source_assignment_models, assignment_id))
  end

  def assignment_source?(%Model{}, _assignment_id), do: false

  defp projected_default_reasoning_level(
         %MetadataProjection{default_effort: default_effort},
         _model,
         _metadata
       ),
       do: default_effort

  defp projected_default_reasoning_level(nil, model, metadata),
    do: default_reasoning_level(model, metadata)

  defp projected_reasoning_levels(%MetadataProjection{levels: levels}, _model, _metadata),
    do: levels

  defp projected_reasoning_levels(nil, model, metadata),
    do: supported_reasoning_levels(model, metadata)

  @spec default_reasoning_level(Model.t(), metadata()) :: String.t() | nil
  def default_reasoning_level(%Model{supports_reasoning: true}, metadata) do
    string_metadata(metadata, "default_reasoning_level") ||
      metadata
      |> reasoning_level_values()
      |> List.first()
      |> case do
        nil -> "medium"
        level -> level
      end
  end

  def default_reasoning_level(%Model{}, _metadata), do: nil

  @spec supported_reasoning_levels(Model.t(), metadata()) :: [map()]
  def supported_reasoning_levels(%Model{supports_reasoning: true}, metadata) do
    case reasoning_level_values(metadata) do
      [] -> fallback_reasoning_levels()
      levels -> Enum.map(levels, &%{"effort" => &1, "description" => &1})
    end
  end

  def supported_reasoning_levels(%Model{}, _metadata), do: []

  @spec reasoning_levels_and_default(Model.t()) :: {[String.t()], String.t() | nil}
  def reasoning_levels_and_default(%Model{} = model) do
    metadata = metadata(model)

    levels =
      model
      |> supported_reasoning_levels(metadata)
      |> Enum.map(&Map.fetch!(&1, "effort"))

    {levels, default_reasoning_level(model, metadata)}
  end

  @spec reasoning_level_maps_and_default(Model.t()) :: {[map()], String.t() | nil}
  def reasoning_level_maps_and_default(%Model{} = model) do
    metadata = metadata(model)

    {effective_reasoning_level_maps(model, metadata),
     canonical_default_reasoning_level(model, metadata)}
  end

  defp canonical_default_reasoning_level(%Model{} = model, metadata) do
    model
    |> default_reasoning_level(metadata)
    |> case do
      value when is_binary(value) -> clean_reasoning_level(value)
      nil -> nil
    end
  end

  defp fallback_reasoning_levels do
    [
      %{"effort" => "low", "description" => "low"},
      %{"effort" => "medium", "description" => "medium"},
      %{"effort" => "high", "description" => "high"},
      %{"effort" => "xhigh", "description" => "xhigh"}
    ]
  end

  defp effective_reasoning_level_maps(%Model{supports_reasoning: true}, metadata) do
    case reasoning_level_maps(metadata) do
      [] -> fallback_reasoning_levels()
      levels -> levels
    end
  end

  defp effective_reasoning_level_maps(%Model{}, _metadata), do: []

  defp reasoning_level_maps(metadata) do
    metadata
    |> metadata_values(["supported_reasoning_levels", "reasoning_efforts"])
    |> Enum.map(&reasoning_level_map/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&Map.fetch!(&1, "effort"))
  end

  defp reasoning_level_map(%{"effort" => effort} = level) when is_binary(effort) do
    case clean_reasoning_level(effort) do
      nil -> nil
      canonical_effort -> Map.put(level, "effort", canonical_effort)
    end
  end

  defp reasoning_level_map(%{effort: effort} = level) when is_binary(effort) do
    case clean_reasoning_level(effort) do
      nil -> nil
      canonical_effort -> level |> Map.delete(:effort) |> Map.put("effort", canonical_effort)
    end
  end

  defp reasoning_level_map(value) when is_binary(value) do
    case clean_reasoning_level(value) do
      nil -> nil
      effort -> %{"effort" => effort, "description" => effort}
    end
  end

  defp reasoning_level_map(_value), do: nil

  defp reasoning_level_values(metadata) do
    metadata
    |> metadata_values(["supported_reasoning_levels", "reasoning_efforts"])
    |> Enum.map(&reasoning_level_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reasoning_level_value(%{"effort" => effort}) when is_binary(effort),
    do: clean_reasoning_level(effort)

  defp reasoning_level_value(%{effort: effort}) when is_binary(effort),
    do: clean_reasoning_level(effort)

  defp reasoning_level_value(value) when is_binary(value), do: clean_reasoning_level(value)
  defp reasoning_level_value(_value), do: nil

  defp clean_reasoning_level(value) do
    case String.trim(value) do
      "" -> nil
      effort -> ReasoningEffort.normalize_known(effort) || effort
    end
  end

  @spec list_metadata(metadata(), String.t(), list()) :: list()
  def list_metadata(metadata, key, default \\ []) do
    case Map.get(metadata, key) do
      values when is_list(values) -> values
      _value -> default
    end
  end

  @spec string_metadata(metadata(), String.t()) :: String.t() | nil
  defp string_metadata(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  @spec optional_string_metadata(metadata(), String.t()) :: String.t() | nil
  defp optional_string_metadata(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  @spec tool_mode_metadata(metadata()) :: String.t() | nil
  defp tool_mode_metadata(metadata) do
    case string_metadata(metadata, "tool_mode") do
      value when value in ["direct", "code_mode", "code_mode_only"] -> value
      _value -> nil
    end
  end

  @spec map_metadata(metadata(), String.t()) :: metadata() | nil
  defp map_metadata(metadata, key) do
    case Map.get(metadata, key) do
      %{} = map -> map
      _value -> nil
    end
  end

  @spec json_metadata(metadata(), String.t()) :: term() | nil
  defp json_metadata(metadata, key) do
    case Map.get(metadata, key) do
      value
      when is_binary(value) or is_boolean(value) or is_number(value) or is_list(value) or
             is_map(value) or is_nil(value) ->
        value

      _value ->
        nil
    end
  end

  @spec int_metadata(metadata(), String.t(), integer()) :: integer()
  def int_metadata(metadata, key, default) do
    case Map.get(metadata, key) do
      value when is_integer(value) -> value
      _value -> default
    end
  end

  @spec bool_metadata(metadata(), String.t()) :: boolean()
  def bool_metadata(metadata, key) do
    case Map.get(metadata, key) do
      value when is_boolean(value) -> value
      _value -> false
    end
  end

  @spec input_modalities(metadata()) :: [String.t()]
  def input_modalities(metadata) do
    explicit_modalities =
      metadata
      |> metadata_values(["input_modalities", "supported_input_modalities"])
      |> normalize_modalities()

    cond do
      explicit_modalities != [] ->
        explicit_modalities

      supports_image_input?(metadata) ->
        ["text", "image"]

      true ->
        ["text"]
    end
  end

  @spec supports_image_detail_original?(metadata()) :: boolean()
  def supports_image_detail_original?(metadata) do
    case metadata_value(metadata, "supports_image_detail_original") do
      value when is_boolean(value) -> value
      _value -> supports_image_input?(metadata)
    end
  end

  @spec has_capability_evidence?(metadata_input()) :: boolean()
  def has_capability_evidence?(%Model{} = model) do
    model
    |> metadata()
    |> has_capability_evidence?()
  end

  def has_capability_evidence?(metadata) when is_map(metadata) do
    capabilities = metadata_map(metadata, "capabilities")

    capabilities != %{} or
      metadata_values(metadata, [
        "input_modalities",
        "supported_input_modalities",
        "output_modalities",
        "supported_output_modalities",
        "modalities",
        "supported_modalities",
        "modes",
        "supported_modes"
      ]) != []
  end

  def has_capability_evidence?(_metadata), do: false

  @spec supports_audio_transcription?(metadata_input()) :: boolean()
  def supports_audio_transcription?(%Model{} = model) do
    model
    |> metadata()
    |> supports_audio_transcription?()
  end

  def supports_audio_transcription?(metadata) when is_map(metadata) do
    capabilities = metadata_map(metadata, "capabilities")

    audio_input? =
      metadata_includes?(metadata, ["input_modalities", "supported_input_modalities"], "audio") or
        metadata_includes?(metadata, ["modalities", "supported_modalities"], "audio") or
        metadata_truthy?(capabilities, ["audio", "audio_input"])

    transcription? =
      metadata_includes?(metadata, ["modes", "supported_modes"], "transcription") or
        metadata_truthy?(capabilities, ["transcription", "transcriptions", "audio_transcription"])

    audio_input? and transcription?
  end

  def supports_audio_transcription?(_metadata), do: false

  @spec supports_image_input?(metadata_input()) :: boolean()
  def supports_image_input?(%Model{} = model) do
    model
    |> metadata()
    |> supports_image_input?()
  end

  def supports_image_input?(metadata) when is_map(metadata) do
    capabilities = metadata_map(metadata, "capabilities")

    metadata_includes?(metadata, ["input_modalities", "supported_input_modalities"], "image") or
      metadata_truthy?(capabilities, ["image", "image_input", "vision", "vision_input"])
  end

  def supports_image_input?(_metadata), do: false

  @spec streaming_explicitly_unsupported?(term()) :: boolean()
  def streaming_explicitly_unsupported?(metadata) when is_map(metadata) do
    capabilities = metadata_map(metadata, "capabilities")

    metadata_falsey?(capabilities, ["streaming"]) or
      metadata_falsey?(metadata, ["streaming", "supports_streaming", "supports_stream"])
  end

  def streaming_explicitly_unsupported?(_metadata), do: false

  @spec supports_tools?(term()) :: boolean()
  def supports_tools?(metadata) when is_map(metadata) do
    capabilities = metadata_map(metadata, "capabilities")

    metadata_truthy?(capabilities, ["tools", "tool_calls", "function_calling"]) or
      metadata_truthy?(metadata, [
        "tools",
        "tool_calls",
        "function_calling",
        "supports_tools",
        "supports_tool_calls",
        "supports_parallel_tool_calls"
      ])
  end

  def supports_tools?(_metadata), do: false

  @spec supports_reasoning?(term()) :: boolean()
  def supports_reasoning?(metadata) when is_map(metadata) do
    capabilities = metadata_map(metadata, "capabilities")

    metadata_truthy?(capabilities, ["reasoning"]) or
      metadata_values(metadata, ["supported_reasoning_levels", "reasoning_efforts"]) != [] or
      metadata_truthy?(metadata, ["reasoning", "supports_reasoning"])
  end

  def supports_reasoning?(_metadata), do: false

  @spec metadata(Model.t()) :: metadata()
  def metadata(%Model{} = model) do
    metadata = model.metadata || %{}

    case metadata_value(metadata, "upstream_model") do
      %{} = upstream_model -> Map.merge(upstream_model, metadata)
      _value -> model.metadata || %{}
    end
  end

  @spec apply_context_window_policy(metadata(), Model.t(), pricing_buckets()) :: metadata()
  def apply_context_window_policy(metadata, %Model{} = model, pricing_buckets)
      when is_map(metadata) do
    settings = OperationalSettings.current()

    apply_context_window_policy(
      metadata,
      model,
      pricing_buckets,
      settings.model_context_window_overrides
    )
  end

  @spec apply_context_window_policy(
          metadata(),
          Model.t(),
          pricing_buckets(),
          context_window_overrides()
        ) :: metadata()
  def apply_context_window_policy(
        metadata,
        %Model{} = model,
        pricing_buckets,
        context_window_overrides
      )
      when is_map(metadata) and is_map(context_window_overrides) do
    case Map.get(context_window_overrides, model.exposed_model_id) do
      context_window when is_integer(context_window) and context_window > 0 ->
        put_context_window(metadata, context_window)

      _value ->
        metadata
        |> maybe_apply_pricing_context_window(model, pricing_buckets)
        |> apply_effective_context_window()
    end
  end

  @spec metadata_map(metadata(), String.t()) :: metadata()
  def metadata_map(%{} = metadata, key) do
    case metadata_value(metadata, key) do
      %{} = map -> map
      _value -> %{}
    end
  end

  def metadata_map(_metadata, _key), do: %{}

  @spec metadata_falsey?(metadata(), [String.t()]) :: boolean()
  def metadata_falsey?(metadata, keys) do
    Enum.any?(keys, fn key ->
      value = metadata_value(metadata, key)
      value in [false, "false", "unsupported", "disabled"]
    end)
  end

  @spec normalize_capability_value(term()) :: String.t()
  def normalize_capability_value(value)
      when is_binary(value) or is_atom(value) or is_number(value) or is_boolean(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  def normalize_capability_value(_value), do: ""

  defp normalize_modalities(values) do
    values
    |> Enum.map(fn value -> value |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_apply_pricing_context_window(metadata, %Model{} = model, pricing_buckets) do
    case Catalog.pricing_buckets_for_model(model, pricing_buckets) do
      [] ->
        metadata

      buckets ->
        cond do
          @long_context_price_bucket in buckets ->
            maybe_promote_long_context_window(metadata)

          @short_context_price_bucket in buckets ->
            maybe_cap_short_context_window(metadata)

          true ->
            metadata
        end
    end
  end

  defp maybe_promote_long_context_window(metadata) do
    with context_window when is_integer(context_window) <- metadata["context_window"],
         max_context_window
         when is_integer(max_context_window) and
                max_context_window > context_window <-
           metadata["max_context_window"] do
      put_context_window(metadata, max_context_window)
    else
      _value -> metadata
    end
  end

  defp maybe_cap_short_context_window(metadata) do
    case metadata["context_window"] do
      context_window
      when is_integer(context_window) and context_window > @short_context_advertised_window ->
        put_context_window(metadata, @short_context_advertised_window)

      _value ->
        metadata
    end
  end

  defp put_context_window(metadata, context_window) do
    auto_compact_limit = div(context_window * 9, 10)

    metadata
    |> Map.put("context_window", context_window)
    |> Map.put("max_context_window", context_window)
    |> Map.update("auto_compact_token_limit", auto_compact_limit, fn
      value when is_integer(value) and value > 0 -> min(value, auto_compact_limit)
      _value -> auto_compact_limit
    end)
  end

  defp apply_effective_context_window(metadata) do
    context_window = metadata["context_window"]
    percent = int_metadata(metadata, "effective_context_window_percent", 95)

    if is_integer(context_window) and context_window > 0 and percent in 1..99 do
      effective_context_window = max(1, div(context_window * percent, 100))
      auto_compact_limit = div(effective_context_window * 9, 10)

      metadata
      |> Map.put("context_window", effective_context_window)
      |> Map.update("max_context_window", context_window, fn
        value when is_integer(value) and value > 0 -> max(value, context_window)
        _value -> context_window
      end)
      |> Map.update("auto_compact_token_limit", auto_compact_limit, fn
        value when is_integer(value) and value > 0 -> min(value, auto_compact_limit)
        _value -> auto_compact_limit
      end)
    else
      metadata
    end
  end

  defp metadata_includes?(metadata, keys, expected) do
    expected = normalize_capability_value(expected)

    metadata
    |> metadata_values(keys)
    |> Enum.any?(&(normalize_capability_value(&1) == expected))
  end

  defp metadata_values(%{} = metadata, keys) do
    Enum.flat_map(keys, fn key -> metadata |> metadata_value(key) |> list_metadata_value() end)
  end

  defp metadata_values(_metadata, _keys), do: []

  defp list_metadata_value(values) when is_list(values), do: values

  defp list_metadata_value(%{} = values),
    do: values |> Map.values() |> Enum.flat_map(&list_metadata_value/1)

  defp list_metadata_value(nil), do: []
  defp list_metadata_value(value), do: [value]

  defp metadata_truthy?(metadata, keys) do
    Enum.any?(keys, fn key ->
      value = metadata_value(metadata, key)
      value in [true, "true", "supported", "enabled"]
    end)
  end

  defp literal_boolean_metadata(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_boolean(value) -> value
      _value -> nil
    end
  end

  defp metadata_value(%{} = metadata, key) do
    if Map.has_key?(metadata, key) do
      Map.get(metadata, key)
    else
      metadata_atom_value(metadata, key)
    end
  end

  defp metadata_value(_metadata, _key), do: nil

  defp metadata_atom_value(metadata, key) do
    case Map.fetch(@atom_metadata_keys, key) do
      {:ok, atom_key} -> Map.get(metadata, atom_key)
      :error -> nil
    end
  end
end
