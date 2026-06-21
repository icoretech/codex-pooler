defmodule CodexPooler.Gateway.OpenAICompatibility.Responses do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Matrix, Validation}
  alias CodexPooler.Gateway.OpenAICompatibility.Responses.{Input, SSE}

  alias CodexPooler.Gateway.Payloads.{
    InputShape,
    RequestOptions,
    StrictSchema,
    ToolSchemaLowering
  }

  @reasoning_contexts ~w(auto current_turn all_turns)
  @reasoning_summaries ~w(auto concise detailed)
  @service_tiers ~w(auto default flex priority scale)
  @truncation_modes ~w(auto disabled)
  @locally_unsupported_fields ~w(background context_management conversation max_tool_calls prompt top_logprobs user)

  @endpoint "/backend-api/codex/responses"

  @spec validate(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :responses),
         :ok <- Validation.require_model(payload),
         :ok <- reject_locally_unsupported_fields(payload),
         {:ok, payload} <- Input.normalize_recoverable_opencode_replay_call_ids(payload),
         {:ok, payload} <- Input.normalize_list_input(payload),
         payload = ToolSchemaLowering.lower_non_strict_function_tools(payload),
         :ok <- Input.validate_input(payload),
         :ok <- Input.validate_previous_response_continuation(payload),
         :ok <- validate_tools(payload),
         :ok <- validate_tool_choice(payload),
         :ok <- validate_max_output_tokens(payload),
         :ok <- validate_reasoning(payload),
         :ok <- validate_moderation(payload),
         :ok <- validate_service_tier(payload),
         :ok <- validate_truncation(payload),
         :ok <- validate_stream_options(payload),
         :ok <- StrictSchema.validate(payload),
         :ok <- InputShape.validate(payload) do
      {:ok, payload}
    end
  end

  @spec coerce(term(), map() | keyword()) ::
          {:ok, %{endpoint: String.t(), payload: map(), request_options: RequestOptions.t()}}
          | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, payload} <- validate(payload),
         {:ok, payload} <-
           payload
           |> Map.take(Matrix.forwarded_fields(:responses))
           |> normalize_forwarded_enums()
           |> Input.normalize_input() do
      payload =
        maybe_force_backend_streaming(payload, opts)

      request_options = RequestOptions.build(opts, @endpoint, payload)
      {:ok, %{endpoint: @endpoint, payload: payload, request_options: request_options}}
    end
  end

  @spec response_from_sse(binary()) :: {:ok, map()} | {:error, Error.reason()}
  def response_from_sse(body) when is_binary(body), do: SSE.response_from_sse(body)

  defp maybe_force_backend_streaming(payload, opts) do
    if backend_streaming_required?(opts) do
      payload
      |> Map.put("stream", true)
      |> Map.put("store", false)
    else
      payload
    end
  end

  defp backend_streaming_required?(%RequestOptions{openai_compatibility: compatibility}) do
    compatibility.collect_openai_response_stream or compatibility.public_openai_responses_stream or
      compatibility.public_openai_chat_stream
  end

  defp backend_streaming_required?(opts) when is_map(opts) do
    Enum.any?(
      [
        :collect_openai_response_stream,
        :public_openai_responses_stream,
        :public_openai_chat_stream
      ],
      &Map.get(opts, &1)
    )
  end

  defp backend_streaming_required?(opts) when is_list(opts),
    do: backend_streaming_required?(Map.new(opts))

  defp backend_streaming_required?(_opts), do: false

  defp reject_locally_unsupported_fields(payload) do
    payload
    |> Map.keys()
    |> Enum.find(&(&1 in @locally_unsupported_fields))
    |> case do
      nil -> :ok
      field -> {:error, Error.unsupported_parameter(field)}
    end
  end

  defp validate_reasoning(%{"reasoning" => reasoning}) when is_map(reasoning) do
    reasoning
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> validate_reasoning_map()
  end

  defp validate_reasoning(%{"reasoning" => _reasoning}),
    do: {:error, Error.invalid_request("reasoning must be an object", "reasoning")}

  defp validate_reasoning(_payload), do: :ok

  defp validate_max_output_tokens(%{"max_output_tokens" => value})
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_max_output_tokens(%{"max_output_tokens" => _value}),
    do:
      {:error,
       Error.invalid_request("max_output_tokens must be a positive integer", "max_output_tokens")}

  defp validate_max_output_tokens(_payload), do: :ok

  defp validate_reasoning_map(reasoning) do
    with :ok <- validate_reasoning_keys(reasoning),
         :ok <- validate_reasoning_effort(Map.get(reasoning, "effort")),
         :ok <- validate_reasoning_summary(Map.get(reasoning, "summary")) do
      validate_reasoning_context(Map.get(reasoning, "context"))
    end
  end

  defp validate_reasoning_keys(reasoning) do
    case reasoning |> Map.keys() |> Enum.reject(&(&1 in ["effort", "summary", "context"])) do
      [] ->
        :ok

      [key | _rest] ->
        {:error, Error.invalid_request("reasoning field is not supported", "reasoning." <> key)}
    end
  end

  defp validate_reasoning_effort(nil), do: :ok

  defp validate_reasoning_effort(effort),
    do: Validation.validate_reasoning_effort_token(effort, "reasoning.effort")

  defp validate_reasoning_summary(nil), do: :ok

  defp validate_reasoning_summary(summary) when is_binary(summary) do
    normalized = summary |> String.trim() |> String.downcase()

    if normalized in @reasoning_summaries do
      :ok
    else
      {:error, Error.invalid_request("reasoning summary is not supported", "reasoning.summary")}
    end
  end

  defp validate_reasoning_summary(_summary),
    do: {:error, Error.invalid_request("reasoning summary is not supported", "reasoning.summary")}

  defp validate_reasoning_context(nil), do: :ok

  defp validate_reasoning_context(context) when is_binary(context) do
    if normalize_enum(context) in @reasoning_contexts do
      :ok
    else
      {:error, Error.invalid_request("reasoning context is not supported", "reasoning.context")}
    end
  end

  defp validate_reasoning_context(_context),
    do: {:error, Error.invalid_request("reasoning context is not supported", "reasoning.context")}

  defp validate_moderation(%{"moderation" => moderation}) when is_map(moderation) do
    with :ok <- validate_moderation_keys(moderation),
         model when is_binary(model) <- Map.get(moderation, "model"),
         true <- String.trim(model) != "" do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      _value ->
        {:error, Error.invalid_request("moderation model is required", "moderation.model")}
    end
  end

  defp validate_moderation(%{"moderation" => _moderation}),
    do: {:error, Error.invalid_request("moderation must be an object", "moderation")}

  defp validate_moderation(_payload), do: :ok

  defp validate_moderation_keys(moderation) do
    case moderation |> Map.keys() |> Enum.reject(&(&1 == "model")) do
      [] ->
        :ok

      [key | _rest] ->
        {:error, Error.invalid_request("moderation field is not supported", "moderation." <> key)}
    end
  end

  defp validate_service_tier(%{"service_tier" => tier}) when is_binary(tier) do
    normalized = tier |> String.trim() |> String.downcase()

    if normalized in @service_tiers do
      :ok
    else
      {:error, Error.invalid_request("service_tier is not supported", "service_tier")}
    end
  end

  defp validate_service_tier(%{"service_tier" => _tier}),
    do: {:error, Error.invalid_request("service_tier is not supported", "service_tier")}

  defp validate_service_tier(_payload), do: :ok

  defp validate_truncation(%{"truncation" => truncation}) when is_binary(truncation) do
    normalized = truncation |> String.trim() |> String.downcase()

    if normalized in @truncation_modes do
      :ok
    else
      {:error, Error.invalid_request("truncation is not supported", "truncation")}
    end
  end

  defp validate_truncation(%{"truncation" => _truncation}),
    do: {:error, Error.invalid_request("truncation is not supported", "truncation")}

  defp validate_truncation(_payload), do: :ok

  defp validate_stream_options(%{"stream_options" => options}) when is_map(options) do
    with :ok <- validate_stream_option_keys(options, ["include_obfuscation"]) do
      case Map.get(options, "include_obfuscation") do
        nil ->
          :ok

        value when is_boolean(value) ->
          :ok

        _value ->
          {:error,
           Error.invalid_request(
             "stream_options.include_obfuscation must be a boolean",
             "stream_options.include_obfuscation"
           )}
      end
    end
  end

  defp validate_stream_options(%{"stream_options" => _options}),
    do: {:error, Error.invalid_request("stream_options must be an object", "stream_options")}

  defp validate_stream_options(_payload), do: :ok

  defp validate_stream_option_keys(options, allowed_keys) do
    case options |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) do
      [] ->
        :ok

      [key | _rest] ->
        {:error,
         Error.invalid_request("stream_options field is not supported", "stream_options." <> key)}
    end
  end

  defp normalize_forwarded_enums(payload) do
    payload
    |> normalize_string_field("service_tier")
    |> normalize_reasoning_fields()
  end

  defp normalize_string_field(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} when is_binary(value) -> Map.put(payload, field, normalize_enum(value))
      _other -> payload
    end
  end

  defp normalize_reasoning_fields(%{"reasoning" => reasoning} = payload) when is_map(reasoning) do
    reasoning =
      reasoning
      |> normalize_string_field("effort")
      |> normalize_string_field("summary")
      |> normalize_string_field("context")

    Map.put(payload, "reasoning", reasoning)
  end

  defp normalize_reasoning_fields(payload), do: payload

  defp normalize_enum(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp validate_tools(%{"tools" => tools}) when is_list(tools) do
    Enum.reduce_while(tools, :ok, fn tool, _acc ->
      case validate_tool(tool) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_tools(%{"tools" => _tools}),
    do: {:error, Error.invalid_request("tools must be an array", "tools")}

  defp validate_tools(_payload), do: :ok

  defp validate_tool(%{"type" => "namespace"} = tool) do
    with :ok <- validate_exact_tool_keys(tool, ["type", "name", "description", "tools"]),
         :ok <-
           validate_nonblank_tool_field(tool, "name", "namespace tool requires a non-empty name"),
         :ok <-
           validate_nonblank_tool_field(
             tool,
             "description",
             "namespace tool requires a non-empty description"
           ) do
      validate_namespace_tools(Map.get(tool, "tools"))
    end
  end

  defp validate_tool(%{"type" => "mcp"}),
    do: {:error, Error.invalid_request("remote MCP tools are not supported", "tools")}

  defp validate_tool(%{"namespace" => _namespace}),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_tool(%{"deferred" => _deferred}),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_tool(%{"type" => "function", "name" => name, "parameters" => parameters})
       when is_binary(name) and is_map(parameters) do
    if String.trim(name) == "",
      do: {:error, Error.invalid_request("function tool requires a non-empty name", "tools")},
      else: :ok
  end

  defp validate_tool(%{"type" => "function"}),
    do:
      {:error, Error.invalid_request("function tool requires flat name and parameters", "tools")}

  defp validate_tool(%{"type" => "web_search_preview"} = tool),
    do: validate_exact_builtin_tool(tool, ["type"])

  defp validate_tool(%{"type" => "web_search"} = tool) do
    with :ok <-
           validate_exact_builtin_tool(tool, [
             "type",
             "external_web_access",
             "index_gated_web_access"
           ]),
         :ok <- validate_required_boolean_tool_field(tool, "external_web_access"),
         :ok <- validate_optional_boolean_tool_field(tool, "index_gated_web_access") do
      validate_index_gated_web_access(tool)
    end
  end

  defp validate_tool(
         %{"type" => "image_generation", "model" => model, "size" => size, "quality" => quality} =
           tool
       )
       when is_binary(model) and is_binary(size) and is_binary(quality),
       do:
         validate_exact_builtin_tool(tool, [
           "type",
           "model",
           "size",
           "quality",
           "background",
           "input_fidelity",
           "output_format"
         ])

  defp validate_tool(%{"type" => "image_generation"} = tool),
    do: validate_exact_builtin_tool(tool, ["type"])

  defp validate_tool(_tool),
    do: {:error, Error.invalid_request("tool shape is not translatable", "tools")}

  defp validate_namespace_tools(tools) when is_list(tools) and tools != [] do
    Enum.reduce_while(tools, :ok, fn tool, _acc ->
      case validate_namespace_function_tool(tool) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_namespace_tools(_tools),
    do: {:error, Error.invalid_request("namespace tool requires function tools", "tools")}

  defp validate_namespace_function_tool(
         %{"type" => "function", "name" => name, "parameters" => parameters} = tool
       )
       when is_binary(name) and is_map(parameters) do
    with :ok <-
           validate_exact_tool_keys(tool, [
             "type",
             "name",
             "description",
             "parameters",
             "strict",
             "defer_loading"
           ]),
         :ok <-
           validate_nonblank_tool_field(tool, "name", "function tool requires a non-empty name"),
         :ok <- validate_optional_boolean_tool_field(tool, "strict") do
      validate_optional_boolean_tool_field(tool, "defer_loading")
    end
  end

  defp validate_namespace_function_tool(_tool),
    do: {:error, Error.invalid_request("namespace tool requires function tools", "tools")}

  defp validate_nonblank_tool_field(tool, field, message) do
    case Map.get(tool, field) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, Error.invalid_request(message, "tools")},
          else: :ok

      _value ->
        {:error, Error.invalid_request(message, "tools")}
    end
  end

  defp validate_optional_boolean_tool_field(tool, field) do
    case Map.fetch(tool, field) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, Error.invalid_request("tool shape is not translatable", "tools")}
      :error -> :ok
    end
  end

  defp validate_required_boolean_tool_field(tool, field) do
    case Map.fetch(tool, field) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, Error.invalid_request("tool shape is not translatable", "tools")}
      :error -> {:error, Error.invalid_request("tool shape is not translatable", "tools")}
    end
  end

  defp validate_index_gated_web_access(%{
         "external_web_access" => false,
         "index_gated_web_access" => true
       }) do
    {:error, Error.invalid_request("tool shape is not translatable", "tools")}
  end

  defp validate_index_gated_web_access(_tool), do: :ok

  defp validate_exact_builtin_tool(tool, allowed_keys) do
    validate_exact_tool_keys(tool, allowed_keys)
  end

  defp validate_exact_tool_keys(tool, allowed_keys) do
    case tool |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) do
      [] -> :ok
      [_key | _rest] -> {:error, Error.invalid_request("tool shape is not translatable", "tools")}
    end
  end

  defp validate_tool_choice(%{"tool_choice" => choice})
       when choice in ["auto", "none", "required"],
       do: :ok

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "function", "name" => name}} = payload)
       when is_binary(name) do
    validate_named_tool_choice(payload, name)
  end

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "image_generation"}}), do: :ok

  defp validate_tool_choice(%{"tool_choice" => %{"type" => "function"}}),
    do:
      {:error,
       Error.invalid_request("tool_choice function requires a non-empty name", "tool_choice")}

  defp validate_tool_choice(%{"tool_choice" => _choice}),
    do: {:error, Error.invalid_request("tool_choice shape is not translatable", "tool_choice")}

  defp validate_tool_choice(_payload), do: :ok

  defp validate_named_tool_choice(payload, name) do
    cond do
      String.trim(name) == "" ->
        {:error,
         Error.invalid_request("tool_choice function requires a non-empty name", "tool_choice")}

      name in function_tool_names(payload) ->
        :ok

      true ->
        {:error,
         Error.invalid_request("tool_choice references unknown function tool", "tool_choice")}
    end
  end

  defp function_tool_names(%{"tools" => tools}) when is_list(tools) do
    Enum.flat_map(tools, fn
      %{"type" => "function", "name" => name} when is_binary(name) ->
        [name]

      %{"type" => "namespace", "tools" => namespace_tools} when is_list(namespace_tools) ->
        Enum.flat_map(namespace_tools, fn
          %{"type" => "function", "name" => name} when is_binary(name) -> [name]
          _tool -> []
        end)

      _tool ->
        []
    end)
  end

  defp function_tool_names(_payload), do: []
end
