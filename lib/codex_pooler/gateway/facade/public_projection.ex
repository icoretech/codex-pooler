defmodule CodexPooler.Gateway.Facade.PublicProjection do
  @moduledoc """
  Projects gateway-owned response metadata into the public facade identity.

  Projection is deliberately limited to documented response envelopes. User
  and assistant content, tool arguments, filenames, and arbitrary nested data
  are never searched or rewritten.
  """

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Error
  alias CodexPooler.Gateway.Facade.FileCapability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser

  @response_keys ~w(
    id object created_at status background completed_at error incomplete_details
    max_output_tokens max_tool_calls model output output_text parallel_tool_calls
    previous_response_id prompt_cache_retention reasoning store temperature
    top_logprobs top_p truncation usage service_tier
  )
  @response_item_keys %{
    "message" => ~w(id type status role content),
    "reasoning" => ~w(id type status summary content encrypted_content),
    "function_call" => ~w(id type status call_id name namespace arguments caller),
    "function_call_output" => ~w(id type status call_id namespace output caller),
    "custom_tool_call" => ~w(id type status call_id name namespace input),
    "custom_tool_call_output" => ~w(id type status call_id namespace output),
    "computer_call" => ~w(id type status call_id action pending_safety_checks),
    "computer_call_output" => ~w(id type status call_id output acknowledged_safety_checks),
    "file_search_call" => ~w(id type status queries results),
    "web_search_call" => ~w(id type status action),
    "code_interpreter_call" => ~w(id type status code container_id outputs),
    "image_generation_call" => ~w(id type status result),
    "local_shell_call" => ~w(id type status call_id action),
    "local_shell_call_output" => ~w(id type status call_id output),
    "mcp_list_tools" => ~w(id type status server_label tools error),
    "mcp_call" => ~w(id type status approval_request_id arguments error name output server_label),
    "mcp_approval_request" => ~w(id type arguments name server_label),
    "mcp_approval_response" => ~w(id type approval_request_id approve reason),
    "apply_patch_call" => ~w(id type status call_id operation),
    "apply_patch_call_output" => ~w(id type status call_id output),
    "program" => ~w(id type status call_id code fingerprint),
    "program_output" => ~w(id type status call_id result),
    "compaction" => ~w(id type encrypted_content internal_chat_message_metadata_passthrough)
  }
  @content_part_keys %{
    "output_text" => ~w(type text annotations logprobs),
    "input_text" => ~w(type text),
    "refusal" => ~w(type refusal),
    "summary_text" => ~w(type text),
    "reasoning_text" => ~w(type text),
    "input_image" => ~w(type image_url detail),
    "input_file" => ~w(type file_id file_data file_url filename)
  }
  @response_event_types ~w(
    response.created response.in_progress response.queued response.completed response.done response.incomplete
    response.failed response.output_item.added response.output_item.done
    response.content_part.added response.content_part.done response.output_text.delta
    response.output_text.done response.refusal.delta response.refusal.done
    response.function_call_arguments.delta response.function_call_arguments.done
    response.custom_tool_call_input.delta response.custom_tool_call_input.done
    response.reasoning_summary.delta response.reasoning_summary.done
    response.reasoning_summary_part.added response.reasoning_summary_part.done
    response.reasoning_summary_text.delta response.reasoning_summary_text.done
    response.reasoning_text.delta response.reasoning_text.done
    response.image_generation_call.completed response.image_generation_call.generating
    response.image_generation_call.in_progress response.image_generation_call.partial_image
    response.file_search_call.completed response.file_search_call.in_progress
    response.file_search_call.searching response.web_search_call.completed
    response.web_search_call.in_progress response.web_search_call.searching
    response.code_interpreter_call.completed response.code_interpreter_call.in_progress
    response.code_interpreter_call.interpreting response.code_interpreter_call_code.delta
    response.code_interpreter_call_code.done response.mcp_call.completed response.mcp_call.failed
    response.mcp_call.in_progress response.mcp_call_arguments.delta response.mcp_call_arguments.done
    response.mcp_list_tools.completed response.mcp_list_tools.failed response.mcp_list_tools.in_progress
    response.moderation.started response.moderation.completed keepalive codex.rate_limits error
  )
  @event_identity_keys ~w(type sequence_number model)
  @catalog_boolean_keys ~w(
    include_skills_usage_instructions supports_parallel_tool_calls supported_in_api
    supports_responses supports_streaming supports_tools supports_reasoning use_responses_lite
    supports_image_detail_original prefer_websockets supports_reasoning_summary_parameter
    supports_reasoning_summaries supports_search_tool support_verbosity
  )
  @catalog_positive_integer_keys ~w(
    context_window max_context_window auto_compact_token_limit
    effective_context_window_percent
  )
  @safe_catalog_shell_types ~w(shell_command command)
  @safe_catalog_summary_formats ~w(auto concise detailed json)
  @safe_catalog_tool_modes ~w(default code_mode_only)
  @safe_catalog_service_tiers ~w(auto default priority fast flex)
  @safe_public_service_tiers ~w(auto default priority fast flex)
  @safe_catalog_modalities ~w(text image audio)
  @safe_usage_limit_types ~w(credits percent request_count total_tokens)
  @safe_usage_cost_statuses ~w(priced unpriced)
  @safe_ollama_capabilities ~w(completion tools vision thinking)
  @v1_usage_bucket_number_keys ~w(
    request_count input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens
    total_cost_usd
  )

  @spec openai_response(map()) :: map()
  def openai_response(%{} = response) do
    case openai_response_result(response) do
      {:ok, projected} -> projected
      :error -> sanitized_failure_event()
    end
  end

  @spec identity_item(map()) :: map()
  def identity_item(%{} = item) do
    case identity_item_result(item) do
      {:ok, projected} -> projected
      :error -> %{"type" => "error", "error" => sanitized_error()}
    end
  end

  @spec responses_event(map()) :: map()
  def responses_event(%{} = event) do
    case responses_event_result(event) do
      {:ok, projected} -> projected
      :error -> sanitized_failure_event()
    end
  end

  @spec chat_completion(map()) :: map()
  def chat_completion(%{} = completion) do
    completion
    |> Map.take(~w(id object created model choices usage service_tier))
    |> Map.put("model", Facade.public_model())
    |> drop_container_values(~w(id object created service_tier))
    |> keep_enum_value("service_tier", @safe_public_service_tiers)
    |> update_list_value("choices", &project_chat_choice/1)
    |> update_map_value("usage", &project_usage/1)
  end

  @spec gateway_body(map()) :: map()
  def gateway_body(%{"object" => "text_completion"} = body) do
    case project_text_completion_result(body) do
      {:ok, projected} -> projected
      :error -> sanitized_failure_event()
    end
  end

  def gateway_body(%{"object" => object} = body)
      when object in ["chat.completion", "chat.completion.chunk"] do
    chat_completion(body)
  end

  def gateway_body(%{"object" => "response"} = body), do: openai_response(body)
  def gateway_body(%{"object" => "response.compaction"} = body), do: project_compaction(body)
  def gateway_body(%{"object" => "file"} = body), do: project_file_object(body)

  def gateway_body(%{"object" => "model"} = body) do
    case project_openai_model_result(body) do
      {:ok, projected} -> projected
      :error -> sanitized_failure_event()
    end
  end

  def gateway_body(%{"object" => "list"} = body) do
    case project_list_body_result(body) do
      {:ok, projected} -> projected
      :error -> sanitized_failure_event()
    end
  end

  def gateway_body(%{"file_id" => _file_id, "upload_url" => _url} = body),
    do: project_file_create(body)

  def gateway_body(%{"status" => _status, "download_url" => _url} = body),
    do: project_file_finalize(body)

  def gateway_body(%{"status" => status} = body) when status == "retry",
    do: Map.take(body, ~w(status))

  def gateway_body(%{"type" => type} = body) when is_binary(type) do
    if type in @response_event_types do
      responses_event(body)
    else
      sanitized_failure_event()
    end
  end

  def gateway_body(%{"response" => %{} = _response} = body), do: responses_event(body)
  def gateway_body(%{}), do: sanitized_failure_event()

  @spec error_body(Error.protocol(), pos_integer(), map()) :: map()
  def error_body(protocol, status, %{} = error),
    do: Error.body(protocol, status, error, origin: :untrusted)

  @spec json_message(binary()) :: binary()
  def json_message(data) when is_binary(data) do
    case json_message_result(data) do
      {:ok, encoded, _projected} -> encoded
      {:error, encoded} -> encoded
    end
  end

  @spec json_message_result(binary()) ::
          {:ok, binary(), map()} | {:error, binary()}
  def json_message_result(data) when is_binary(data) do
    with {:ok, %{} = decoded} <- Jason.decode(data),
         {:ok, projected} <- gateway_body_result(decoded) do
      {:ok, Jason.encode!(projected), projected}
    else
      _invalid -> {:error, Jason.encode!(sanitized_failure_event())}
    end
  end

  @spec json_message(binary(), map()) :: {binary(), map()}
  def json_message(data, %{} = decoded) when is_binary(data) do
    projected = gateway_body(decoded)
    encoded = Jason.encode!(projected)
    {encoded, projected}
  end

  @spec sse_block(iodata()) :: iodata()
  def sse_block(block) do
    case sse_block_result(block) do
      {:ok, projected} -> projected
      {:error, projected} -> projected
    end
  end

  @spec sse_block_result(iodata()) :: {:ok, binary()} | {:error, binary()}
  def sse_block_result(block) do
    block = IO.iodata_to_binary(block)

    case SSEParser.sse_field(block, "data") do
      nil ->
        {:ok, ""}

      "[DONE]" ->
        {:ok, "data: [DONE]\n\n"}

      data ->
        with {:ok, %{} = decoded} <- Jason.decode(data),
             {:ok, decoded} <- prepare_sse_event(block, decoded),
             {:ok, projected} <- responses_event_result(decoded) do
          {:ok, canonical_sse_block(projected)}
        else
          _invalid -> {:error, sanitized_failure_sse()}
        end
    end
  end

  @spec gateway_body_result(map()) :: {:ok, map()} | :error
  def gateway_body_result(%{"object" => "text_completion"} = body),
    do: project_text_completion_result(body)

  def gateway_body_result(%{"object" => object} = body)
      when object in ["chat.completion", "chat.completion.chunk"],
      do: {:ok, chat_completion(body)}

  def gateway_body_result(%{"object" => "response"} = body),
    do: openai_response_result(body)

  def gateway_body_result(%{"object" => "response.compaction"} = body),
    do: project_compaction_result(body)

  def gateway_body_result(%{"object" => "file"} = body),
    do: {:ok, project_file_object(body)}

  def gateway_body_result(%{"object" => "model"} = body),
    do: project_openai_model_result(body)

  def gateway_body_result(%{"object" => "list"} = body),
    do: project_list_body_result(body)

  def gateway_body_result(%{"models" => models}) when is_list(models),
    do: project_codex_catalog_result(models)

  def gateway_body_result(%{"created" => created, "data" => data} = body)
      when is_integer(created) and is_list(data),
      do: project_image_body_result(body)

  def gateway_body_result(%{"file_id" => file_id, "upload_url" => url} = body)
      when is_binary(file_id) and is_binary(url) do
    if FileCapability.local_url?(url, :upload), do: {:ok, project_file_create(body)}, else: :error
  end

  def gateway_body_result(%{"status" => status, "download_url" => url} = body)
      when is_binary(status) and is_binary(url) do
    if FileCapability.local_url?(url, :download),
      do: {:ok, project_file_finalize(body)},
      else: :error
  end

  def gateway_body_result(%{"status" => "retry"} = body),
    do: {:ok, Map.take(body, ~w(status))}

  def gateway_body_result(%{} = body)
      when is_map_key(body, :request_count) or is_map_key(body, "request_count"),
      do: project_v1_usage_result(body)

  def gateway_body_result(%{"type" => type} = body) when type in @response_event_types,
    do: responses_event_result(body)

  def gateway_body_result(%{"response" => %{} = _response} = body),
    do: responses_event_result(body)

  def gateway_body_result(%{"id" => id} = body) when is_binary(id),
    do: openai_response_result(body)

  def gateway_body_result(%{"error" => %{} = error}),
    do: {:ok, %{"error" => public_error(error)}}

  def gateway_body_result(_body), do: :error

  @doc false
  @spec websocket_source_result(map()) ::
          {:ok, :projected | :canonical_response_failed} | :error
  def websocket_source_result(%{} = body) do
    case gateway_body_result(body) do
      {:ok, _projected} ->
        {:ok, :projected}

      :error ->
        websocket_specialized_terminal_source_result(body)
    end
  end

  defp websocket_specialized_terminal_source_result(%{
         "type" => "response.failed",
         "response" => %{}
       }),
       do: {:ok, :canonical_response_failed}

  defp websocket_specialized_terminal_source_result(_body), do: :error

  @spec ollama_body_result(String.t(), map()) :: {:ok, map()} | :error
  def ollama_body_result(path, body) when is_binary(path) and is_map(body) do
    case path do
      "/api/tags" -> project_ollama_models_result(body, false)
      "/api/ps" -> project_ollama_models_result(body, true)
      "/api/show" -> project_ollama_show_result(body)
      "/api/version" -> project_single_string_result(body, "version")
      "/api/pull" -> project_single_string_result(body, "status")
      _path -> :error
    end
  end

  @spec transcription_body_result(map()) :: {:ok, map()} | :error
  def transcription_body_result(%{"text" => text}) when is_binary(text),
    do: {:ok, %{"text" => text}}

  def transcription_body_result(_body), do: :error

  @spec gateway_body_result(map(), pos_integer()) :: {:ok, map()} | :error
  def gateway_body_result(%{} = body, status) when is_integer(status) and status >= 400 do
    error =
      case body do
        %{"error" => %{} = error} -> error
        _body -> %{}
      end

    {:ok, %{"error" => public_error(error, status)}}
  end

  def gateway_body_result(%{} = body, _status), do: gateway_body_result(body)

  defp prepare_sse_event(block, decoded) do
    case {SSEParser.sse_field(block, "event"), Map.fetch(decoded, "type")} do
      {nil, {:ok, type}} when type in @response_event_types ->
        {:ok, decoded}

      {event, :error} when event in @response_event_types ->
        {:ok, Map.put(decoded, "type", event)}

      {event, {:ok, event}} when event in @response_event_types ->
        {:ok, decoded}

      {nil, :error} ->
        prepare_legacy_sse_response(decoded)

      _mismatch ->
        :error
    end
  end

  defp prepare_legacy_sse_response(%{"id" => id} = response) when is_binary(id) do
    case Map.fetch(response, "status") do
      :error ->
        {:ok,
         %{
           "type" => "response.completed",
           "response" => Map.put(response, "status", "completed")
         }}

      {:ok, "completed"} ->
        {:ok, %{"type" => "response.completed", "response" => response}}

      _invalid_status ->
        :error
    end
  end

  defp prepare_legacy_sse_response(_response), do: :error

  defp canonical_sse_block(projected) do
    "event: #{projected["type"]}\ndata: #{Jason.encode!(projected)}\n\n"
  end

  defp project_file_create(body) do
    body
    |> Map.take(~w(file_id upload_url))
    |> drop_container_values(~w(file_id upload_url))
  end

  defp project_file_finalize(body) do
    body
    |> Map.take(~w(status download_url file_name mime_type))
    |> drop_container_values(~w(status download_url file_name mime_type))
  end

  defp project_file_object(body) do
    body
    |> Map.take(~w(id object bytes created_at filename purpose status expires_at))
    |> drop_container_values(~w(id object bytes created_at filename purpose status expires_at))
  end

  defp project_compaction(body) do
    case project_compaction_result(body) do
      {:ok, projected} -> projected
      :error -> sanitized_failure_event()
    end
  end

  defp project_compaction_result(body) do
    projected =
      body
      |> Map.take(~w(id object created_at output usage))
      |> drop_container_values(~w(id object created_at))

    with {:ok, projected} <- project_output(projected) do
      {:ok, update_map_value(projected, "usage", &project_usage/1)}
    end
  end

  defp project_list_body_result(%{"data" => data}) when is_list(data) do
    case map_results(data, &project_list_item_result/1) do
      {:ok, projected} -> {:ok, %{"object" => "list", "data" => projected}}
      :error -> :error
    end
  end

  defp project_list_body_result(_body), do: :error

  defp project_list_item_result(%{"object" => "file"} = item),
    do: {:ok, project_file_object(item)}

  defp project_list_item_result(%{"object" => "model"} = item) do
    project_openai_model_result(item)
  end

  defp project_list_item_result(_item), do: :error

  defp project_openai_model_result(%{"object" => "model", "id" => id} = item)
       when is_binary(id) do
    projected = %{
      "id" => Facade.public_model(),
      "object" => "model",
      "owned_by" => "ollama",
      "permission" => [],
      "display_name" => Facade.public_model()
    }

    projected =
      case Map.get(item, "created") do
        value when is_integer(value) and value >= 0 -> Map.put(projected, "created", value)
        _value -> projected
      end

    projected =
      Enum.reduce(~w(supports_streaming supports_tools supports_reasoning), projected, fn key,
                                                                                          result ->
        case Map.get(item, key) do
          value when is_boolean(value) -> Map.put(result, key, value)
          _value -> result
        end
      end)

    projected =
      case Map.get(item, "input_modalities") do
        values when is_list(values) ->
          Map.put(
            projected,
            "input_modalities",
            values |> Enum.filter(&(&1 in @safe_catalog_modalities)) |> Enum.uniq()
          )

        _value ->
          projected
      end

    projected =
      case Map.get(item, "context_length") do
        value when is_integer(value) and value > 0 -> Map.put(projected, "context_length", value)
        _value -> projected
      end

    {:ok, projected}
  end

  defp project_openai_model_result(_item), do: :error

  defp project_text_completion_result(
         %{
           "id" => id,
           "object" => "text_completion",
           "choices" => choices
         } = body
       )
       when is_binary(id) and is_list(choices) do
    with {:ok, projected_choices} <- map_results(choices, &project_text_completion_choice/1) do
      projected = %{
        "id" => id,
        "object" => "text_completion",
        "model" => Facade.public_model(),
        "choices" => projected_choices
      }

      projected =
        case Map.get(body, "created") do
          value when is_integer(value) and value >= 0 -> Map.put(projected, "created", value)
          _value -> projected
        end

      {:ok, update_map_value(projected, "usage", &project_usage/1)}
      |> then(fn
        {:ok, without_usage} when is_map_key(body, "usage") ->
          {:ok,
           update_map_value(
             Map.put(without_usage, "usage", body["usage"]),
             "usage",
             &project_usage/1
           )}

        result ->
          result
      end)
    end
  end

  defp project_text_completion_result(_body), do: :error

  defp project_text_completion_choice(
         %{
           "text" => text,
           "index" => index,
           "finish_reason" => finish_reason
         } = choice
       )
       when is_binary(text) and is_integer(index) and
              (is_binary(finish_reason) or is_nil(finish_reason)) do
    projected = %{
      "text" => text,
      "index" => index,
      "finish_reason" => finish_reason
    }

    projected =
      if Map.get(choice, "logprobs") == nil,
        do: Map.put(projected, "logprobs", nil),
        else: projected

    {:ok, projected}
  end

  defp project_text_completion_choice(_choice), do: :error

  defp project_ollama_models_result(%{"models" => models}, running?) when is_list(models) do
    case map_results(models, &project_ollama_model_result(&1, running?)) do
      {:ok, projected} -> {:ok, %{"models" => projected}}
      :error -> :error
    end
  end

  defp project_ollama_models_result(_body, _running?), do: :error

  defp project_ollama_model_result(
         %{
           "name" => name,
           "model" => model,
           "modified_at" => modified_at,
           "size" => size,
           "digest" => digest,
           "details" => details
         } = item,
         running?
       )
       when is_binary(name) and is_binary(model) and is_binary(modified_at) and
              is_integer(size) and size >= 0 and is_binary(digest) and is_map(details) do
    with {:ok, details} <- project_ollama_details_result(details) do
      projected = %{
        "name" => Facade.public_model(),
        "model" => Facade.public_model(),
        "modified_at" => modified_at,
        "size" => size,
        "digest" => digest,
        "details" => details
      }

      if running? do
        with expires_at when is_binary(expires_at) <- Map.get(item, "expires_at"),
             size_vram when is_integer(size_vram) and size_vram >= 0 <-
               Map.get(item, "size_vram") do
          {:ok,
           projected
           |> Map.put("expires_at", expires_at)
           |> Map.put("size_vram", size_vram)}
        else
          _invalid -> :error
        end
      else
        {:ok, projected}
      end
    end
  end

  defp project_ollama_model_result(_item, _running?), do: :error

  defp project_ollama_details_result(%{
         "family" => family,
         "parameter_size" => parameter_size
       })
       when is_binary(family) and is_binary(parameter_size) do
    {:ok, %{"family" => Facade.public_model(), "parameter_size" => parameter_size}}
  end

  defp project_ollama_details_result(_details), do: :error

  defp project_ollama_show_result(%{
         "model" => model,
         "modified_at" => modified_at,
         "digest" => digest,
         "license" => license,
         "modelfile" => modelfile,
         "parameters" => parameters,
         "template" => template,
         "details" => details,
         "model_info" => model_info,
         "capabilities" => capabilities
       })
       when is_binary(model) and is_binary(modified_at) and is_binary(digest) and
              is_binary(license) and is_binary(modelfile) and is_binary(parameters) and
              is_binary(template) and is_map(details) and is_map(model_info) and
              is_list(capabilities) do
    with {:ok, details} <- project_ollama_details_result(details),
         architecture when is_binary(architecture) <-
           Map.get(model_info, "general.architecture"),
         parameter_count when is_integer(parameter_count) and parameter_count >= 0 <-
           Map.get(model_info, "general.parameter_count"),
         true <- Enum.all?(capabilities, &(&1 in @safe_ollama_capabilities)) do
      {:ok,
       %{
         "model" => Facade.public_model(),
         "modified_at" => modified_at,
         "digest" => digest,
         "license" => license,
         "modelfile" => modelfile,
         "parameters" => parameters,
         "template" => template,
         "details" => details,
         "model_info" => %{
           "general.architecture" => Facade.public_model(),
           "general.parameter_count" => parameter_count
         },
         "capabilities" => capabilities
       }}
    else
      _invalid -> :error
    end
  end

  defp project_ollama_show_result(_body), do: :error

  defp project_single_string_result(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) -> {:ok, %{key => value}}
      _value -> :error
    end
  end

  defp project_codex_catalog_result(models) do
    case map_results(models, &project_codex_model_result/1) do
      {:ok, projected} -> {:ok, %{"models" => projected}}
      :error -> :error
    end
  end

  defp project_codex_model_result(%{"slug" => slug} = source) when is_binary(slug) do
    projected = %{
      "slug" => Facade.public_model(),
      "display_name" => Facade.public_model(),
      "description" => Facade.public_model(),
      "default_reasoning_level" => Facade.reasoning_effort(),
      "supported_reasoning_levels" => [
        %{"effort" => Facade.reasoning_effort(), "description" => "Maximum"}
      ],
      "shell_type" => safe_enum(Map.get(source, "shell_type"), @safe_catalog_shell_types),
      "visibility" => "list",
      "base_instructions" => ""
    }

    projected =
      Enum.reduce(@catalog_boolean_keys, projected, fn key, result ->
        case Map.get(source, key) do
          value when is_boolean(value) -> Map.put(result, key, value)
          _value -> result
        end
      end)

    projected =
      Enum.reduce(@catalog_positive_integer_keys, projected, fn key, result ->
        case Map.get(source, key) do
          value when is_integer(value) and value > 0 -> Map.put(result, key, value)
          _value -> result
        end
      end)

    projected =
      projected
      |> maybe_put_catalog_enum(
        "reasoning_summary_format",
        source,
        @safe_catalog_summary_formats
      )
      |> maybe_put_catalog_enum("tool_mode", source, @safe_catalog_tool_modes)
      |> maybe_put_catalog_enum(
        "default_service_tier",
        source,
        @safe_catalog_service_tiers
      )
      |> maybe_put_catalog_truncation(source)
      |> maybe_put_catalog_modalities(source)
      |> maybe_put_catalog_service_tiers(source)
      |> maybe_put_catalog_speed_tiers(source)

    {:ok, projected}
  end

  defp project_codex_model_result(_model), do: :error

  defp safe_enum(value, [fallback | _allowed] = allowed) do
    if value in allowed, do: value, else: fallback
  end

  defp maybe_put_catalog_enum(projected, key, source, allowed) do
    case Map.get(source, key) do
      value -> if value in allowed, do: Map.put(projected, key, value), else: projected
    end
  end

  defp maybe_put_catalog_truncation(projected, source) do
    case Map.get(source, "truncation_policy") do
      %{"mode" => mode, "limit" => limit}
      when mode in ["bytes", "tokens"] and is_integer(limit) and limit > 0 ->
        Map.put(projected, "truncation_policy", %{"mode" => mode, "limit" => limit})

      _policy ->
        projected
    end
  end

  defp maybe_put_catalog_modalities(projected, source) do
    case Map.get(source, "input_modalities") do
      modalities when is_list(modalities) ->
        safe = modalities |> Enum.filter(&(&1 in @safe_catalog_modalities)) |> Enum.uniq()
        Map.put(projected, "input_modalities", safe)

      _modalities ->
        projected
    end
  end

  defp maybe_put_catalog_service_tiers(projected, source) do
    case Map.get(source, "service_tiers") do
      tiers when is_list(tiers) ->
        safe =
          tiers
          |> Enum.flat_map(fn
            %{"id" => id} when id in @safe_catalog_service_tiers ->
              [%{"id" => id, "name" => public_service_tier_name(id)}]

            _tier ->
              []
          end)
          |> Enum.uniq_by(& &1["id"])

        Map.put(projected, "service_tiers", safe)

      _tiers ->
        projected
    end
  end

  defp maybe_put_catalog_speed_tiers(projected, source) do
    case Map.get(source, "additional_speed_tiers") do
      tiers when is_list(tiers) ->
        Map.put(projected, "additional_speed_tiers", Enum.filter(tiers, &(&1 == "fast")))

      _tiers ->
        projected
    end
  end

  defp public_service_tier_name("priority"), do: "Priority"
  defp public_service_tier_name("fast"), do: "Fast"
  defp public_service_tier_name("flex"), do: "Flex"
  defp public_service_tier_name(value), do: String.capitalize(value)

  defp project_image_body_result(%{"data" => data} = body) do
    with {:ok, projected_data} <- map_results(data, &project_image_data_result/1) do
      projected =
        body
        |> Map.take(~w(created background output_format quality size usage))
        |> keep_image_scalar_values()
        |> Map.put("data", projected_data)
        |> update_map_value("usage", &project_usage/1)

      {:ok, projected}
    end
  end

  defp project_image_data_result(%{"b64_json" => encoded} = data) when is_binary(encoded) do
    projected = %{"b64_json" => encoded}

    projected =
      case Map.get(data, "revised_prompt") do
        value when is_binary(value) -> Map.put(projected, "revised_prompt", value)
        _value -> projected
      end

    {:ok, projected}
  end

  defp project_image_data_result(_data), do: :error

  defp keep_image_scalar_values(body) do
    body
    |> keep_integer_value("created")
    |> keep_enum_value("background", ~w(auto opaque transparent))
    |> keep_enum_value("output_format", ~w(png jpeg webp))
    |> keep_enum_value("quality", ~w(auto low medium high))
    |> keep_enum_value("size", ~w(auto 256x256 512x512 1024x1024 1024x1536 1536x1024))
  end

  defp keep_integer_value(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> map
      _value -> Map.delete(map, key)
    end
  end

  defp keep_enum_value(map, key, allowed) do
    case Map.get(map, key) do
      value -> if value in allowed, do: map, else: Map.delete(map, key)
    end
  end

  defp project_present_model(event) do
    if Map.has_key?(event, "model") do
      Map.put(event, "model", Facade.public_model())
    else
      event
    end
  end

  defp openai_response_result(response) do
    projected = Map.take(response, @response_keys)

    with {:ok, projected} <- project_output(projected),
         {:ok, projected} <- project_optional_response_error(projected) do
      projected =
        projected
        |> project_present_model()
        |> update_map_value("incomplete_details", fn details ->
          details |> Map.take(~w(reason)) |> drop_container_values(~w(reason))
        end)
        |> update_map_value(
          "reasoning",
          &(&1
            |> Map.take(~w(effort summary generate_summary summary_format))
            |> drop_container_values(~w(effort summary generate_summary summary_format)))
        )
        |> update_map_value("usage", &project_usage/1)
        |> keep_enum_value("service_tier", @safe_public_service_tiers)
        |> drop_container_values(
          ~w(id object created_at status background completed_at max_output_tokens max_tool_calls
             output_text parallel_tool_calls previous_response_id prompt_cache_retention store
             temperature top_logprobs top_p truncation)
        )

      {:ok, projected}
    end
  end

  defp project_v1_usage_result(body) do
    with {:ok, request_count} <- required_non_negative_integer(body, :request_count),
         {:ok, total_tokens} <- required_non_negative_integer(body, :total_tokens),
         {:ok, cached_input_tokens} <-
           required_non_negative_integer(body, :cached_input_tokens),
         {:ok, total_cost_usd} <- required_non_negative_number(body, :total_cost_usd),
         total_cost_status when total_cost_status in @safe_usage_cost_statuses <-
           field_value(body, :total_cost_status),
         {:ok, limits} <- project_v1_usage_limits(field_value(body, :limits), "pool_limit"),
         {:ok, upstream_limits} <-
           project_v1_usage_limits(field_value(body, :upstream_limits), "pool_capacity"),
         {:ok, model_buckets} <- project_v1_usage_model_buckets(body) do
      projected = %{
        "request_count" => request_count,
        "total_tokens" => total_tokens,
        "cached_input_tokens" => cached_input_tokens,
        "total_cost_usd" => total_cost_usd,
        "total_cost_status" => total_cost_status,
        "limits" => limits,
        "upstream_limits" => upstream_limits
      }

      {:ok,
       if(model_buckets == nil,
         do: projected,
         else: Map.put(projected, "model_buckets", model_buckets)
       )}
    else
      _invalid -> :error
    end
  end

  defp required_non_negative_integer(body, key) do
    case field_value(body, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> :error
    end
  end

  defp required_non_negative_number(body, key) do
    case field_value(body, key) do
      value when is_number(value) and value >= 0 -> {:ok, value}
      _value -> :error
    end
  end

  defp project_v1_usage_limits(limits, source) when is_list(limits) do
    map_results(limits, &project_v1_usage_limit(&1, source))
  end

  defp project_v1_usage_limits(_limits, _source), do: :error

  defp project_v1_usage_limit(%{} = limit, source) do
    with type when type in @safe_usage_limit_types <- field_value(limit, :limit_type),
         window when is_binary(window) <- field_value(limit, :limit_window),
         true <- safe_usage_window?(window),
         {:ok, max_value} <- optional_non_negative_number(field_value(limit, :max_value)),
         {:ok, current_value} <- optional_non_negative_number(field_value(limit, :current_value)),
         {:ok, remaining_value} <-
           optional_non_negative_number(field_value(limit, :remaining_value)),
         {:ok, reset_at} <- optional_iso8601(field_value(limit, :reset_at)) do
      {:ok,
       %{
         "limit_type" => type,
         "limit_window" => window,
         "max_value" => max_value,
         "current_value" => current_value,
         "remaining_value" => remaining_value,
         "model_filter" => public_usage_model_filter(field_value(limit, :model_filter)),
         "reset_at" => reset_at,
         "source" => source
       }}
    else
      _invalid -> :error
    end
  end

  defp project_v1_usage_limit(_limit, _source), do: :error

  defp safe_usage_window?(window) do
    window in ~w(minute daily weekly) or Regex.match?(~r/^\d{1,5}[mhd]$/, window)
  end

  defp optional_non_negative_number(nil), do: {:ok, nil}

  defp optional_non_negative_number(value) when is_number(value) and value >= 0,
    do: {:ok, value}

  defp optional_non_negative_number(_value), do: :error

  defp optional_iso8601(nil), do: {:ok, nil}

  defp optional_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      _invalid -> :error
    end
  end

  defp optional_iso8601(_value), do: :error

  defp public_usage_model_filter(nil), do: nil
  defp public_usage_model_filter(_model), do: Facade.public_model()

  defp project_v1_usage_model_buckets(body) do
    case fetch_field(body, :model_buckets) do
      :error ->
        {:ok, nil}

      {:ok, buckets} when is_list(buckets) ->
        map_results(buckets, &project_v1_usage_model_bucket/1)

      {:ok, _wrong_type} ->
        :error
    end
  end

  defp project_v1_usage_model_bucket(%{} = bucket) do
    numbers =
      Enum.reduce(@v1_usage_bucket_number_keys, %{}, fn key, projected ->
        case field_value(bucket, String.to_existing_atom(key)) do
          value when is_number(value) and value >= 0 -> Map.put(projected, key, value)
          _value -> projected
        end
      end)

    {:ok, Map.put(numbers, "model", Facade.public_model())}
  end

  defp project_v1_usage_model_bucket(_bucket), do: :error

  defp field_value(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp project_output(%{"output" => output} = response) when is_list(output) do
    case map_results(output, &identity_item_result/1) do
      {:ok, projected} -> {:ok, Map.put(response, "output", projected)}
      :error -> :error
    end
  end

  defp project_output(response) when not is_map_key(response, "output"), do: {:ok, response}
  defp project_output(_response), do: :error

  defp identity_item_result(%{"type" => type} = item) when is_binary(type) do
    case Map.fetch(@response_item_keys, type) do
      {:ok, keys} ->
        projected =
          item
          |> Map.take(keys)
          |> drop_container_values(
            ~w(id type status call_id name namespace server_label approval_request_id approve reason)
          )
          |> then(fn projected ->
            if Map.has_key?(item, "model"),
              do: Map.put(projected, "model", Facade.public_model()),
              else: projected
          end)

        with {:ok, projected} <- project_item_content(projected),
             {:ok, projected} <- project_item_nested(type, projected),
             {:ok, projected} <- project_item_error(projected) do
          {:ok, projected}
        end

      :error ->
        :error
    end
  end

  defp identity_item_result(_item), do: :error

  defp project_item_content(%{"content" => content} = item) when is_list(content) do
    case map_results(content, &content_part_result/1) do
      {:ok, projected} -> {:ok, Map.put(item, "content", projected)}
      :error -> :error
    end
  end

  defp project_item_content(item) when not is_map_key(item, "content"), do: {:ok, item}
  defp project_item_content(_item), do: :error

  defp project_item_nested("computer_call", item) do
    item =
      item
      |> update_map_value("action", &project_computer_action/1)
      |> update_list_value("pending_safety_checks", &project_safety_check/1)

    {:ok, item}
  end

  defp project_item_nested("computer_call_output", item) do
    {:ok, update_list_value(item, "acknowledged_safety_checks", &project_safety_check/1)}
  end

  defp project_item_nested(type, item)
       when type in ["function_call", "function_call_output"] do
    {:ok, update_map_value(item, "caller", &project_program_caller/1)}
  end

  defp project_item_nested(type, item)
       when type in ["custom_tool_call", "custom_tool_call_output"] do
    {:ok, item}
  end

  defp project_item_nested("file_search_call", item) do
    item =
      item
      |> update_string_list_value("queries")
      |> update_list_value("results", &project_file_search_result/1)

    {:ok, item}
  end

  defp project_item_nested("web_search_call", item) do
    {:ok, update_map_value(item, "action", &project_web_search_action/1)}
  end

  defp project_item_nested("code_interpreter_call", item) do
    item =
      item
      |> drop_container_values(~w(code container_id))
      |> update_list_value("outputs", &project_code_interpreter_output/1)

    {:ok, item}
  end

  defp project_item_nested("image_generation_call", item),
    do: {:ok, drop_container_values(item, ~w(result))}

  defp project_item_nested("reasoning", item) do
    item =
      item
      |> drop_container_values(~w(encrypted_content))
      |> update_list_value("summary", fn part ->
        case content_part_result(part) do
          {:ok, projected} -> projected
          :error -> %{}
        end
      end)

    {:ok, item}
  end

  defp project_item_nested("program", item),
    do: {:ok, drop_container_values(item, ~w(code fingerprint))}

  defp project_item_nested("program_output", item), do: {:ok, item}

  defp project_item_nested("local_shell_call", item) do
    {:ok, update_map_value(item, "action", &project_shell_action/1)}
  end

  defp project_item_nested("mcp_list_tools", item) do
    {:ok, update_list_value(item, "tools", &project_mcp_tool/1)}
  end

  defp project_item_nested("apply_patch_call", item) do
    {:ok, update_map_value(item, "operation", &project_patch_operation/1)}
  end

  defp project_item_nested("compaction", item) do
    item =
      update_map_value(item, "internal_chat_message_metadata_passthrough", fn metadata ->
        metadata
        |> Map.take(~w(turn_id))
        |> drop_container_values(~w(turn_id))
      end)

    {:ok, drop_container_values(item, ~w(encrypted_content))}
  end

  defp project_item_nested(_type, item), do: {:ok, item}

  defp project_program_caller(%{"type" => type} = caller)
       when type in ["direct", "program"] do
    caller
    |> Map.take(~w(type caller_id))
    |> drop_container_values(~w(type caller_id))
  end

  defp project_program_caller(_caller), do: %{}

  defp project_computer_action(action) do
    action
    |> Map.take(~w(type button x y keys text scroll_x scroll_y path command timeout_ms))
    |> drop_container_values(~w(type button x y text scroll_x scroll_y timeout_ms))
    |> update_string_list_value("keys")
    |> update_string_list_value("command")
    |> update_point_list_value("path")
  end

  defp project_safety_check(check),
    do: check |> Map.take(~w(id code message)) |> drop_container_values(~w(id code message))

  defp project_file_search_result(result) do
    result
    |> Map.take(~w(file_id filename score text))
    |> drop_container_values(~w(file_id filename score text))
  end

  defp project_web_search_action(action) do
    action
    |> Map.take(~w(type query queries url sources))
    |> drop_container_values(~w(type query url))
    |> update_string_list_value("queries")
    |> update_list_value("sources", fn source ->
      source |> Map.take(~w(type url title)) |> drop_container_values(~w(type url title))
    end)
  end

  defp project_code_interpreter_output(output) do
    output |> Map.take(~w(type logs text)) |> drop_container_values(~w(type logs text))
  end

  defp project_shell_action(action) do
    action
    |> Map.take(~w(type command commands timeout_ms user working_directory))
    |> drop_container_values(~w(type timeout_ms user working_directory))
    |> update_string_list_value("command")
    |> update_string_list_value("commands")
  end

  defp project_mcp_tool(tool),
    do: tool |> Map.take(~w(name title)) |> drop_container_values(~w(name title))

  defp project_patch_operation(operation) do
    operation
    |> Map.take(~w(type path diff old_path new_path))
    |> drop_container_values(~w(type path diff old_path new_path))
  end

  defp content_part_result(%{"type" => type} = part) when is_binary(type) do
    case Map.fetch(@content_part_keys, type) do
      {:ok, keys} ->
        projected = Map.take(part, keys)

        projected =
          if type == "output_text" do
            projected
            |> update_list_value("annotations", &project_annotation/1)
            |> Map.delete("logprobs")
          else
            projected
          end

        {:ok,
         drop_container_values(
           projected,
           ~w(type text refusal image_url detail file_id file_data file_url filename)
         )}

      :error ->
        :error
    end
  end

  defp content_part_result(_part), do: :error

  defp project_annotation(%{"type" => type} = annotation)
       when type in ["file_citation", "container_file_citation", "file_path"] do
    annotation
    |> Map.take(~w(type index start_index end_index file_id container_id filename))
    |> drop_container_values(~w(type index start_index end_index file_id container_id filename))
  end

  defp project_annotation(%{"type" => "url_citation"} = annotation) do
    annotation
    |> Map.take(~w(type start_index end_index title url))
    |> drop_container_values(~w(type start_index end_index title url))
  end

  defp project_annotation(_annotation), do: %{}

  defp project_item_error(%{"error" => %{} = error} = item),
    do: {:ok, Map.put(item, "error", public_error(error))}

  defp project_item_error(item) when not is_map_key(item, "error"), do: {:ok, item}
  defp project_item_error(_item), do: :error

  defp project_optional_response_error(%{"error" => nil} = response), do: {:ok, response}

  defp project_optional_response_error(%{"error" => %{} = error} = response),
    do: {:ok, Map.put(response, "error", public_error(error))}

  defp project_optional_response_error(response) when not is_map_key(response, "error"),
    do: {:ok, response}

  defp project_optional_response_error(_response), do: :error

  defp responses_event_result(%{"type" => "error"} = event),
    do: project_native_error_event(event)

  defp responses_event_result(%{"type" => "codex.rate_limits"} = event),
    do: project_codex_rate_limits_event(event)

  defp responses_event_result(%{"id" => id} = response)
       when is_binary(id) and not is_map_key(response, "type"),
       do: openai_response_result(response)

  defp responses_event_result(%{"type" => type} = event) when type in @response_event_types do
    projected =
      event
      |> Map.take(event_keys(type))
      |> drop_container_values(event_scalar_keys(type))

    with {:ok, projected} <- project_event_response(projected),
         {:ok, projected} <- project_event_item(projected),
         {:ok, projected} <- project_event_part(projected),
         {:ok, projected} <- project_event_error_result(projected),
         {:ok, projected} <- project_event_top_level_error_result(projected) do
      {:ok, project_present_model(projected)}
    end
  end

  defp responses_event_result(_event), do: :error

  defp event_scalar_keys(type) do
    event_keys(type) -- ~w(response item part error)
  end

  defp event_keys(type) do
    @event_identity_keys ++
      cond do
        type in ~w(response.created response.in_progress response.queued response.completed response.done response.incomplete) ->
          ~w(response)

        type == "response.failed" ->
          ~w(response error status code message param)

        type in ~w(response.output_item.added response.output_item.done) ->
          ~w(output_index item)

        type in ~w(response.content_part.added response.content_part.done) ->
          ~w(item_id output_index content_index part)

        type in ~w(response.output_text.delta response.refusal.delta response.function_call_arguments.delta response.custom_tool_call_input.delta response.reasoning_summary.delta response.reasoning_summary_text.delta response.reasoning_text.delta response.code_interpreter_call_code.delta response.mcp_call_arguments.delta) ->
          ~w(item_id output_index content_index delta)

        type in ~w(response.output_text.done response.refusal.done response.function_call_arguments.done response.custom_tool_call_input.done response.reasoning_summary.done response.reasoning_summary_text.done response.reasoning_text.done response.code_interpreter_call_code.done response.mcp_call_arguments.done) ->
          ~w(item_id output_index content_index text arguments input code)

        type in ~w(response.reasoning_summary_part.added response.reasoning_summary_part.done) ->
          ~w(item_id output_index summary_index part)

        type in ~w(response.image_generation_call.partial_image) ->
          ~w(item_id output_index partial_image_b64 partial_image_index)

        type in ~w(response.moderation.started response.moderation.completed) ->
          ~w(check_id status)

        type == "error" ->
          ~w(error)

        true ->
          ~w(item_id output_index)
      end
  end

  defp project_event_response(%{"response" => %{} = response} = event) do
    case openai_response_result(response) do
      {:ok, projected} -> {:ok, Map.put(event, "response", projected)}
      :error -> :error
    end
  end

  defp project_event_response(event) when not is_map_key(event, "response"), do: {:ok, event}
  defp project_event_response(_event), do: :error

  defp project_event_item(%{"item" => %{} = item} = event) do
    case identity_item_result(item) do
      {:ok, projected} -> {:ok, Map.put(event, "item", projected)}
      :error -> :error
    end
  end

  defp project_event_item(event) when not is_map_key(event, "item"), do: {:ok, event}
  defp project_event_item(_event), do: :error

  defp project_event_part(%{"part" => %{} = part} = event) do
    case content_part_result(part) do
      {:ok, projected} -> {:ok, Map.put(event, "part", projected)}
      :error -> :error
    end
  end

  defp project_event_part(event) when not is_map_key(event, "part"), do: {:ok, event}
  defp project_event_part(_event), do: :error

  defp project_event_error_result(%{"error" => %{} = error} = event) do
    public = public_error(error, 502)
    {:ok, Map.put(event, "error", public)}
  end

  defp project_event_error_result(event) when not is_map_key(event, "error"), do: {:ok, event}
  defp project_event_error_result(_event), do: :error

  defp project_event_top_level_error_result(%{"type" => "response.failed"} = event) do
    source = Map.take(event, ~w(status code message param))

    if map_size(source) == 0 do
      {:ok, event}
    else
      status = integer_field(source, "status") || 502
      public = public_error(source, status)

      projected =
        event
        |> Map.drop(~w(status code message param))
        |> Map.put("code", public["code"])
        |> Map.put("message", public["message"])
        |> maybe_put_public_param(public)

      {:ok, projected}
    end
  end

  defp project_event_top_level_error_result(event), do: {:ok, event}

  defp project_native_error_event(event) do
    status = integer_field(event, "status") || 502
    nested = Map.get(event, "error")
    source = if is_map(nested), do: nested, else: event
    public = public_error(source, status)

    projected = %{"type" => "error"}

    projected =
      if integer_field(event, "status"), do: Map.put(projected, "status", status), else: projected

    projected =
      if is_map(nested) do
        Map.put(projected, "error", public)
      else
        projected
        |> Map.put("code", public["code"])
        |> Map.put("message", public["message"])
        |> maybe_put_public_param(public)
      end

    {:ok, projected}
  end

  defp maybe_put_public_param(projected, %{"param" => param}),
    do: Map.put(projected, "param", param)

  defp maybe_put_public_param(projected, _public), do: projected

  defp project_codex_rate_limits_event(%{"rate_limits" => %{} = rate_limits}) do
    with {:ok, projected} <- project_rate_limit_windows(rate_limits) do
      {:ok, %{"type" => "codex.rate_limits", "rate_limits" => projected}}
    else
      _invalid -> :error
    end
  end

  defp project_codex_rate_limits_event(_event), do: :error

  defp project_rate_limit_windows(rate_limits) do
    Enum.reduce_while(~w(primary secondary), {:ok, %{}}, fn key, {:ok, projected} ->
      case Map.fetch(rate_limits, key) do
        :error ->
          {:cont, {:ok, projected}}

        {:ok, %{} = window} ->
          {:cont, {:ok, Map.put(projected, key, project_rate_limit_window(window))}}

        {:ok, _wrong_type} ->
          {:halt, :error}
      end
    end)
  end

  defp project_rate_limit_window(window) do
    window
    |> Map.take(~w(used_percent window_minutes reset_at reset_after_seconds))
    |> keep_number_values()
  end

  defp project_chat_choice(%{} = choice) do
    choice
    |> Map.take(~w(index finish_reason message delta))
    |> drop_container_values(~w(index finish_reason))
    |> update_map_value("message", &project_chat_message/1)
    |> update_map_value("delta", &project_chat_message/1)
  end

  defp project_chat_choice(_choice), do: %{}

  defp project_chat_message(%{} = message) do
    message
    |> Map.take(~w(role content refusal annotations audio tool_calls function_call))
    |> drop_container_values(~w(role refusal))
    |> project_chat_content()
    |> update_list_value("annotations", &project_annotation/1)
    |> update_map_value("audio", fn audio ->
      audio
      |> Map.take(~w(id data transcript expires_at))
      |> drop_container_values(~w(id data transcript expires_at))
    end)
    |> update_list_value("tool_calls", &project_chat_tool_call/1)
    |> update_map_value("function_call", fn function ->
      function
      |> Map.take(~w(name arguments))
      |> drop_container_values(~w(name arguments))
    end)
  end

  defp project_chat_content(%{"content" => content} = message) when is_binary(content),
    do: message

  defp project_chat_content(%{"content" => content} = message) when is_list(content) do
    projected =
      Enum.flat_map(content, fn
        %{} = part ->
          case content_part_result(part) do
            {:ok, value} -> [value]
            :error -> []
          end

        _part ->
          []
      end)

    Map.put(message, "content", projected)
  end

  defp project_chat_content(message), do: Map.delete(message, "content")

  defp project_chat_tool_call(%{} = tool_call) do
    tool_call
    |> Map.take(~w(index id type function custom))
    |> drop_container_values(~w(index id type))
    |> update_map_value("function", fn function ->
      function
      |> Map.take(~w(name arguments))
      |> drop_container_values(~w(name arguments))
    end)
    |> update_map_value("custom", fn custom ->
      custom
      |> Map.take(~w(name input))
      |> drop_container_values(~w(name input))
    end)
  end

  defp project_chat_tool_call(_tool_call), do: %{}

  defp project_usage(%{} = usage) do
    usage
    |> Map.take(~w(input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens
         input_tokens_details output_tokens_details prompt_tokens completion_tokens
         prompt_tokens_details completion_tokens_details))
    |> update_map_value(
      "input_tokens_details",
      &Map.take(&1, ~w(cached_tokens audio_tokens text_tokens image_tokens))
    )
    |> update_map_value(
      "output_tokens_details",
      &Map.take(
        &1,
        ~w(reasoning_tokens audio_tokens accepted_prediction_tokens rejected_prediction_tokens)
      )
    )
    |> update_map_value(
      "prompt_tokens_details",
      &Map.take(&1, ~w(cached_tokens audio_tokens text_tokens image_tokens))
    )
    |> update_map_value(
      "completion_tokens_details",
      &Map.take(
        &1,
        ~w(reasoning_tokens audio_tokens accepted_prediction_tokens rejected_prediction_tokens)
      )
    )
    |> drop_container_values(
      ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens prompt_tokens
         completion_tokens)
    )
    |> keep_usage_number_values()
    |> update_map_value("input_tokens_details", &keep_number_values/1)
    |> update_map_value("output_tokens_details", &keep_number_values/1)
    |> update_map_value("prompt_tokens_details", &keep_number_values/1)
    |> update_map_value("completion_tokens_details", &keep_number_values/1)
  end

  defp keep_usage_number_values(usage) do
    scalar_keys =
      ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens prompt_tokens
         completion_tokens)

    Enum.reduce(scalar_keys, usage, fn key, projected ->
      case Map.fetch(projected, key) do
        {:ok, value} when is_number(value) -> projected
        {:ok, _wrong_type} -> Map.delete(projected, key)
        :error -> projected
      end
    end)
  end

  defp keep_number_values(map) do
    Enum.reduce(Map.keys(map), map, fn key, projected ->
      if is_number(Map.get(projected, key)), do: projected, else: Map.delete(projected, key)
    end)
  end

  defp sanitized_failure_event do
    error = sanitized_error()

    %{
      "type" => "error",
      "code" => error["code"],
      "message" => error["message"],
      "param" => nil,
      "error" => error
    }
  end

  defp sanitized_error do
    %{
      "type" => "server_error",
      "code" => "server_error",
      "message" => "gemma3 request failed",
      "param" => nil
    }
  end

  defp sanitized_failure_sse do
    "event: error\ndata: " <> Jason.encode!(sanitized_failure_event()) <> "\n\n"
  end

  defp public_error(error), do: public_error(error, integer_field(error, "status") || 502)

  defp public_error(error, status) do
    public_error =
      Error.body(:openai, status, atomize_known_error(error), origin: :untrusted)["error"]

    if Map.has_key?(error, "param") or Map.has_key?(error, :param) do
      public_error
    else
      Map.delete(public_error, "param")
    end
  end

  defp atomize_known_error(error) do
    %{
      code: Map.get(error, "code") || Map.get(error, :code),
      type: Map.get(error, "type") || Map.get(error, :type),
      message: Map.get(error, "message") || Map.get(error, :message),
      param: Map.get(error, "param") || Map.get(error, :param)
    }
  end

  defp integer_field(map, key) do
    atom_value = if key == "status", do: Map.get(map, :status), else: nil

    case Map.get(map, key) || atom_value do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp update_map_value(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, %{} = nested} -> Map.put(map, key, fun.(nested))
      {:ok, _wrong_type} -> Map.delete(map, key)
      :error -> map
    end
  end

  defp update_list_value(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, list} when is_list(list) ->
        projected =
          Enum.flat_map(list, fn
            %{} = item -> [fun.(item)]
            _wrong_type -> []
          end)

        Map.put(map, key, projected)

      {:ok, _wrong_type} ->
        Map.delete(map, key)

      :error ->
        map
    end
  end

  defp update_string_list_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> map
      {:ok, list} when is_list(list) -> Map.put(map, key, Enum.filter(list, &is_binary/1))
      {:ok, _wrong_type} -> Map.delete(map, key)
      :error -> map
    end
  end

  defp update_point_list_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, list} when is_list(list) ->
        points =
          Enum.flat_map(list, fn
            %{} = point ->
              [point |> Map.take(~w(x y)) |> drop_container_values(~w(x y))]

            _wrong_type ->
              []
          end)

        Map.put(map, key, points)

      {:ok, _wrong_type} ->
        Map.delete(map, key)

      :error ->
        map
    end
  end

  defp drop_container_values(map, keys) do
    Enum.reduce(keys, map, fn key, projected ->
      case Map.get(projected, key) do
        value when is_map(value) or is_list(value) -> Map.delete(projected, key)
        _value -> projected
      end
    end)
  end

  defp map_results(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, projected} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, [item | projected]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      :error -> :error
    end
  end
end
