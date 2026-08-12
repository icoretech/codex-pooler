defmodule CodexPooler.Gateway.Payloads.PayloadNormalizer do
  @moduledoc false

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
  alias CodexPooler.Gateway.Payloads.ReasoningEffort
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Payloads.ToolSchemaLowering

  @backend_turn_state_client_metadata_key "x-codex-turn-state"
  @backend_codex_agent_path ~r/\A(?:\/morpheus|\/root(?:\/[a-z0-9_]+)*)\z/
  @websocket_responses_lite_client_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"

  @prompt_cache_adaptation_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/responses/compact"
  ]
  @prompt_cache_breakpoint_types ~w(input_text input_image input_file)

  @unsupported_upstream_fields ~w(
    max_output_tokens
    prompt_cache_retention
    safety_identifier
    temperature
    top_p
  )

  @spec upstream_payload(map(), Model.t(), String.t(), RequestOptions.t()) ::
          {:ok, binary() | {:multipart, list()}}
          | {:error, Jason.EncodeError.t() | Error.reason()}
  def upstream_payload(payload, %Model{} = model, endpoint, %RequestOptions{} = request_options) do
    case prepare_upstream_payload(payload, model, endpoint, request_options) do
      {:ok, upstream_payload, _request_options} -> {:ok, upstream_payload}
      {:error, _reason} = error -> error
    end
  end

  @spec prepare_upstream_payload(map(), Model.t(), String.t(), RequestOptions.t()) ::
          {:ok, binary() | {:multipart, list()}, RequestOptions.t()}
          | {:error, Jason.EncodeError.t() | Error.reason()}
  def prepare_upstream_payload(
        payload,
        %Model{} = model,
        endpoint,
        %RequestOptions{} = request_options
      ) do
    if multipart_endpoint?(endpoint) do
      multipart_payload(payload, model, request_options)
    else
      json_payload(payload, model, endpoint, request_options)
    end
  end

  @spec backend_client_metadata_turn_state(map()) :: String.t() | nil
  def backend_client_metadata_turn_state(%{"client_metadata" => %{} = metadata}) do
    metadata
    |> Map.get(@backend_turn_state_client_metadata_key)
    |> clean_string()
  end

  def backend_client_metadata_turn_state(%{}), do: nil

  @spec normalize(map()) :: {:ok, map()}
  def normalize(%{} = payload) do
    {:ok, normalize_backend_codex_websocket_input(payload)}
  end

  @spec validate(map(), RequestOptions.t()) :: :ok | {:error, Error.reason()}
  def validate(
        %{"tool_choice" => tool_choice},
        %RequestOptions{} = request_options
      )
      when is_map(tool_choice) do
    if RequestOptions.use_responses_lite?(request_options),
      do: {:error, Error.unsupported_parameter("tool_choice")},
      else: :ok
  end

  def validate(_payload, %RequestOptions{}), do: :ok

  defp json_payload(payload, model, endpoint, %RequestOptions{} = request_options) do
    payload =
      payload
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> normalize_reasoning_aliases()
      |> Map.put("model", upstream_model_id(model, endpoint, request_options))

    requested_effort = reasoning_effort(payload)

    payload =
      payload
      |> apply_enforced_payload_policy(request_options)
      |> canonicalize_backend_fast_service_tier()
      |> omit_upstream_auto_default_service_tier()

    applied_effort = reasoning_effort(payload)

    payload = normalize_client_reasoning_effort(payload)

    upstream_payload =
      payload
      |> maybe_strip_unsupported_upstream_fields(endpoint, request_options)
      |> remove_client_supplied_responses_lite_metadata()
      |> strip_backend_codex_fields(endpoint, request_options)

    {upstream_payload, prompt_cache_controls_downgraded} =
      adapt_prompt_cache_controls(upstream_payload, request_options)

    debug_payload =
      maybe_record_gateway_debug_payload(endpoint, payload, upstream_payload, request_options)

    reasoning_effort_snapshot =
      reasoning_effort_snapshot(
        requested_effort,
        applied_effort,
        reasoning_effort(upstream_payload),
        request_options
      )

    request_options =
      request_options
      |> put_upstream_previous_response_id(upstream_payload)
      |> put_gateway_debug_payload(debug_payload)
      |> put_reasoning_effort_snapshot(reasoning_effort_snapshot)
      |> RequestOptions.put_runtime_context(
        prompt_cache_controls_downgraded: prompt_cache_controls_downgraded
      )

    with :ok <- validate(payload, request_options),
         {:ok, encoded} <- Jason.encode(upstream_payload) do
      {:ok, encoded, request_options}
    end
  end

  defp multipart_payload(payload, _model, %RequestOptions{} = request_options) do
    upload = request_options.payload_context.media_upload

    with {:ok, array_fields} <- transcription_array_fields(payload, request_options),
         {:ok, stream} <- upload_stream(upload) do
      prompt_fields =
        [{:prompt, Map.get(payload, "prompt")}]
        |> Enum.reject(fn {_key, value} -> blank?(value) end)
        |> Enum.map(fn {key, value} -> {key, to_string(value)} end)

      file_part =
        {:file,
         {stream,
          filename: upload.redacted_filename, content_type: upload.content_type, size: upload.size}}

      {:ok, {:multipart, [file_part | prompt_fields ++ array_fields]}, request_options}
    end
  end

  defp adapt_prompt_cache_controls(
         payload,
         %RequestOptions{transport: %{upstream_endpoint: endpoint}}
       )
       when endpoint in @prompt_cache_adaptation_endpoints do
    top_level_removed? = Map.has_key?(payload, "prompt_cache_options")
    payload = Map.delete(payload, "prompt_cache_options")
    {payload, breakpoint_removed?} = remove_supported_prompt_cache_breakpoints(payload)

    {payload, top_level_removed? or breakpoint_removed?}
  end

  defp adapt_prompt_cache_controls(payload, %RequestOptions{}), do: {payload, false}

  defp remove_supported_prompt_cache_breakpoints(value) when is_list(value) do
    Enum.map_reduce(value, false, fn nested, removed? ->
      {nested, nested_removed?} = remove_supported_prompt_cache_breakpoints(nested)
      {nested, removed? or nested_removed?}
    end)
  end

  defp remove_supported_prompt_cache_breakpoints(%{} = value) do
    remove_here? =
      Map.get(value, "type") in @prompt_cache_breakpoint_types and
        Map.has_key?(value, "prompt_cache_breakpoint")

    value = if remove_here?, do: Map.delete(value, "prompt_cache_breakpoint"), else: value

    Enum.reduce(value, {%{}, remove_here?}, fn {key, nested}, {result, removed?} ->
      {nested, nested_removed?} = remove_supported_prompt_cache_breakpoints(nested)
      {Map.put(result, key, nested), removed? or nested_removed?}
    end)
  end

  defp remove_supported_prompt_cache_breakpoints(value), do: {value, false}

  defp transcription_array_fields(
         payload,
         %RequestOptions{
           openai_compatibility: %{source_endpoint: "/v1/audio/transcriptions"}
         }
       ) do
    Enum.reduce_while(
      [{"keywords", "keywords[]"}, {"languages", "languages[]"}],
      {:ok, []},
      fn {field, part_name}, {:ok, parts} ->
        case append_transcription_array(payload, parts, field, part_name) do
          {:ok, parts} -> {:cont, {:ok, parts}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    )
  end

  defp transcription_array_fields(_payload, %RequestOptions{}), do: {:ok, []}

  defp append_transcription_array(payload, parts, field, part_name) do
    case Map.fetch(payload, field) do
      :error ->
        {:ok, parts}

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, parts ++ Enum.map(values, &{part_name, &1})},
          else: invalid_transcription_array(field)

      {:ok, _value} ->
        invalid_transcription_array(field)
    end
  end

  defp invalid_transcription_array(field) do
    {:error, Error.reason(400, "invalid_request", "#{field} must be a list of strings", field)}
  end

  defp upstream_model_id(
         %Model{},
         endpoint,
         %RequestOptions{
           payload_context: %{native_image_request?: true},
           routing: %{effective_model: effective_model}
         }
       )
       when endpoint in [
              "/backend-api/codex/images/generations",
              "/backend-api/codex/images/edits"
            ] and is_binary(effective_model) and effective_model != "",
       do: effective_model

  defp upstream_model_id(%Model{} = model, _endpoint, %RequestOptions{}),
    do: model.upstream_model_id

  defp upload_stream(%{path: path}) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, :ok} <- File.open(path, [:read], fn _file -> :ok end) do
      {:ok, File.stream!(path, 2048, [])}
    else
      _reason -> unreadable_upload_error()
    end
  rescue
    _error in File.Error -> unreadable_upload_error()
  end

  defp upload_stream(_upload), do: unreadable_upload_error()

  defp unreadable_upload_error do
    {:error, Error.reason(400, "invalid_request", "file upload is not readable", "file")}
  end

  defp strip_backend_codex_fields(
         payload,
         _endpoint,
         %RequestOptions{transport: %{transport: "websocket"}} = request_options
       ) do
    payload
    |> Map.drop(["request_id"])
    |> Map.put_new("type", "response.create")
    |> Map.put_new("instructions", "")
    |> normalize_backend_codex_websocket_input()
    |> normalize_backend_codex_reasoning_effort()
    |> ToolSchemaLowering.lower_backend_non_strict_function_tools()
    |> remove_backend_codex_encrypted_tool_schema_markers()
    |> normalize_backend_codex_responses_lite(request_options)
    |> normalize_backend_codex_responses_lite_input(request_options)
    |> normalize_noncompact_backend_responses_envelope(request_options)
    |> maybe_sanitize_backend_codex_response_item_ids(request_options)
    |> maybe_put_websocket_responses_lite_client_metadata(request_options)
  end

  defp strip_backend_codex_fields(
         payload,
         _endpoint,
         %RequestOptions{
           transport: %{
             upstream_endpoint: "/backend-api/codex/responses/compact"
           }
         } = request_options
       ) do
    normalize_backend_codex_compact_payload(payload, request_options)
  end

  defp strip_backend_codex_fields(
         payload,
         "/backend-api/codex/responses/compact",
         %RequestOptions{} = request_options
       ) do
    normalize_backend_codex_compact_payload(payload, request_options)
  end

  defp strip_backend_codex_fields(
         payload,
         _endpoint,
         %RequestOptions{
           transport: %{
             upstream_endpoint: "/backend-api/codex/responses"
           }
         } = request_options
       ) do
    normalize_backend_codex_http_payload(payload, request_options)
  end

  defp strip_backend_codex_fields(
         payload,
         "/backend-api/codex/responses",
         %RequestOptions{} = request_options
       ) do
    normalize_backend_codex_http_payload(payload, request_options)
  end

  defp strip_backend_codex_fields(payload, _endpoint, _opts), do: payload

  defp normalize_backend_codex_http_payload(payload, opts) do
    payload
    |> Map.drop(["type", "generate"])
    |> maybe_drop_backend_codex_previous_response_id(opts)
    |> Map.put_new("instructions", "")
    |> normalize_backend_codex_http_input()
    |> normalize_backend_codex_reasoning_effort()
    |> ToolSchemaLowering.lower_backend_non_strict_function_tools()
    |> remove_backend_codex_encrypted_tool_schema_markers()
    |> normalize_backend_codex_responses_lite(opts)
    |> normalize_backend_codex_responses_lite_input(opts)
    |> normalize_noncompact_backend_responses_envelope(opts)
    |> sanitize_backend_codex_response_item_ids(opts)
  end

  defp normalize_backend_codex_compact_payload(payload, opts) do
    payload
    |> normalize_backend_codex_reasoning_effort()
    |> normalize_backend_codex_responses_lite(opts)
  end

  defp normalize_backend_codex_responses_lite(
         payload,
         %RequestOptions{} = request_options
       ) do
    if RequestOptions.use_responses_lite?(request_options) do
      reasoning =
        payload |> Map.get("reasoning") |> reasoning_map() |> Map.put("context", "all_turns")

      payload
      |> Map.put("reasoning", reasoning)
      |> Map.put("parallel_tool_calls", false)
    else
      payload
    end
  end

  defp normalize_backend_codex_responses_lite_input(
         payload,
         %RequestOptions{} = request_options
       ) do
    if RequestOptions.use_responses_lite?(request_options) do
      {tools_present?, tools, payload} = pop_responses_lite_tools(payload)
      {instructions, payload} = Map.pop(payload, "instructions")
      input = Map.get(payload, "input", [])
      input = if is_list(input), do: input, else: []
      {prefix, input} = responses_lite_tools_prefix(input, tools_present?, tools)

      input =
        [prefix | maybe_responses_lite_instructions(instructions) ++ input]
        |> Enum.map(&strip_responses_lite_image_details/1)

      Map.put(payload, "input", input)
    else
      payload
    end
  end

  defp normalize_noncompact_backend_responses_envelope(payload, %RequestOptions{} = opts) do
    reasoning = payload |> Map.get("reasoning") |> reasoning_map()

    reasoning =
      if opts.routing.supports_reasoning_summary_parameter? == false,
        do: Map.delete(reasoning, "summary"),
        else: reasoning

    payload
    |> Map.put("reasoning", reasoning)
    |> Map.put("include", normalize_backend_responses_include(Map.get(payload, "include")))
  end

  defp normalize_backend_responses_include(include) when is_list(include) do
    encrypted_include = "reasoning.encrypted_content"

    {normalized, found?} =
      Enum.reduce(include, {[], false}, fn
        ^encrypted_include, {entries, false} -> {[encrypted_include | entries], true}
        ^encrypted_include, {entries, true} -> {entries, true}
        entry, {entries, found?} -> {[entry | entries], found?}
      end)

    normalized = Enum.reverse(normalized)
    if found?, do: normalized, else: normalized ++ [encrypted_include]
  end

  defp normalize_backend_responses_include(_include), do: ["reasoning.encrypted_content"]

  defp pop_responses_lite_tools(payload) do
    case Map.pop(payload, "tools") do
      {tools, payload} when is_list(tools) -> {true, tools, payload}
      {nil, payload} -> {false, [], payload}
      {_tools, payload} -> {true, [], payload}
    end
  end

  defp responses_lite_tools_prefix([first | rest] = input, false, _tools) do
    if canonical_responses_lite_tools_prefix?(first),
      do: {first, rest},
      else: {additional_tools([]), input}
  end

  defp responses_lite_tools_prefix([], false, _tools), do: {additional_tools([]), []}
  defp responses_lite_tools_prefix(input, true, tools), do: {additional_tools(tools), input}

  defp canonical_responses_lite_tools_prefix?(
         %{
           "type" => "additional_tools",
           "role" => "developer",
           "tools" => tools
         } = item
       )
       when is_list(tools),
       do: not Map.has_key?(item, "id")

  defp canonical_responses_lite_tools_prefix?(_item), do: false

  defp additional_tools(tools),
    do: %{"type" => "additional_tools", "role" => "developer", "tools" => tools}

  defp maybe_responses_lite_instructions(instructions) when is_binary(instructions) do
    if String.trim(instructions) == "" do
      []
    else
      [
        %{
          "type" => "message",
          "role" => "developer",
          "content" => [%{"type" => "input_text", "text" => instructions}]
        }
      ]
    end
  end

  defp maybe_responses_lite_instructions(_instructions), do: []

  defp strip_responses_lite_image_details(%{"type" => "message", "content" => content} = item)
       when is_list(content),
       do: Map.put(item, "content", Enum.map(content, &strip_input_image_detail/1))

  defp strip_responses_lite_image_details(%{"type" => type, "output" => output} = item)
       when type in ["function_call_output", "custom_tool_call_output"] and is_list(output),
       do: Map.put(item, "output", Enum.map(output, &strip_input_image_detail/1))

  defp strip_responses_lite_image_details(
         %{"type" => type, "output" => %{"content" => content} = output} = item
       )
       when type in ["function_call_output", "custom_tool_call_output"] and is_list(content) do
    Map.put(
      item,
      "output",
      Map.put(output, "content", Enum.map(content, &strip_input_image_detail/1))
    )
  end

  defp strip_responses_lite_image_details(item), do: item

  defp strip_input_image_detail(%{"type" => "input_image"} = content),
    do: Map.delete(content, "detail")

  defp strip_input_image_detail(content), do: content

  defp remove_backend_codex_encrypted_tool_schema_markers(%{"tools" => tools} = payload)
       when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &remove_backend_tool_encrypted_markers/1))
  end

  defp remove_backend_codex_encrypted_tool_schema_markers(payload), do: payload

  defp remove_backend_tool_encrypted_markers(%{"type" => "namespace"} = tool), do: tool

  defp remove_backend_tool_encrypted_markers(%{"type" => "function"} = tool),
    do: remove_schema_encrypted_markers(tool)

  defp remove_backend_tool_encrypted_markers(tool), do: tool

  defp remove_schema_encrypted_markers(%{} = value) do
    value
    |> Map.delete("encrypted")
    |> Map.new(fn {key, value} -> {key, remove_schema_encrypted_markers(value)} end)
  end

  defp remove_schema_encrypted_markers(value) when is_list(value),
    do: Enum.map(value, &remove_schema_encrypted_markers/1)

  defp remove_schema_encrypted_markers(value), do: value

  defp maybe_drop_backend_codex_previous_response_id(payload, _opts) do
    if backend_codex_tool_result_continuation?(payload),
      do: payload,
      else: Map.delete(payload, "previous_response_id")
  end

  defp backend_codex_tool_result_continuation?(%{"previous_response_id" => response_id} = payload)
       when is_binary(response_id) do
    payload
    |> Map.get("input")
    |> backend_codex_tool_result_input?()
  end

  defp backend_codex_tool_result_continuation?(_payload), do: false

  defp backend_codex_tool_result_input?(input) when is_list(input) do
    ToolResultShape.items(input) != []
  end

  defp backend_codex_tool_result_input?(_input), do: false

  defp put_upstream_previous_response_id(
         %RequestOptions{} = request_options,
         %{"previous_response_id" => response_id}
       )
       when is_binary(response_id) do
    RequestOptions.put_continuity(request_options,
      upstream_previous_response_id?: String.trim(response_id) != ""
    )
  end

  defp put_upstream_previous_response_id(%RequestOptions{} = request_options, _upstream_payload) do
    RequestOptions.put_continuity(request_options, upstream_previous_response_id?: false)
  end

  defp normalize_backend_codex_http_input(%{"input" => input} = payload) when is_list(input) do
    input = Enum.reject(input, &backend_codex_encrypted_only_input_item?/1)
    Map.put(payload, "input", input)
  end

  defp normalize_backend_codex_http_input(payload), do: payload

  defp normalize_backend_codex_websocket_input(%{"input" => input} = payload)
       when is_list(input) do
    input = Enum.reject(input, &backend_codex_encrypted_agent_message?/1)
    Map.put(payload, "input", input)
  end

  defp normalize_backend_codex_websocket_input(payload), do: payload

  defp maybe_sanitize_backend_codex_response_item_ids(
         payload,
         %RequestOptions{
           transport: %{upstream_endpoint: "/backend-api/codex/responses"}
         } = request_options
       ) do
    sanitize_backend_codex_response_item_ids(payload, request_options)
  end

  defp maybe_sanitize_backend_codex_response_item_ids(payload, %RequestOptions{}), do: payload

  @spec sanitize_backend_codex_response_item_ids(map(), RequestOptions.t()) :: map()
  defp sanitize_backend_codex_response_item_ids(
         %{"input" => input} = payload,
         %RequestOptions{} = request_options
       )
       when is_list(input) do
    Map.put(
      payload,
      "input",
      Enum.map(input, &sanitize_backend_codex_response_item_id(&1, request_options))
    )
  end

  defp sanitize_backend_codex_response_item_ids(payload, %RequestOptions{}), do: payload

  @spec sanitize_backend_codex_response_item_id(term(), RequestOptions.t()) :: term()
  defp sanitize_backend_codex_response_item_id(
         %{"type" => "compaction"} = item,
         %RequestOptions{
           openai_compatibility: %{
             source_endpoint: "/v1/responses",
             translated_endpoint: "/backend-api/codex/responses"
           }
         }
       ),
       do: item

  defp sanitize_backend_codex_response_item_id(
         %{"type" => "item_reference"} = item,
         %RequestOptions{}
       ),
       do: item

  defp sanitize_backend_codex_response_item_id(%{"id" => id} = item, %RequestOptions{}) do
    if prefixed_response_item_id?(id), do: item, else: Map.delete(item, "id")
  end

  defp sanitize_backend_codex_response_item_id(item, %RequestOptions{}), do: item

  @spec prefixed_response_item_id?(term()) :: boolean()
  defp prefixed_response_item_id?(id) when is_binary(id) do
    case :binary.match(id, "_") do
      {position, 1} -> position > 0 and position + 1 < byte_size(id)
      :nomatch -> false
    end
  end

  defp prefixed_response_item_id?(_id), do: false

  defp backend_codex_encrypted_agent_message?(
         %{
           "type" => "agent_message",
           "content" => content
         } = item
       )
       when is_list(content) do
    Enum.any?(content, &backend_codex_encrypted_content_marker?/1) and
      not backend_codex_v2_encrypted_handoff?(item)
  end

  defp backend_codex_encrypted_agent_message?(_item), do: false

  defp backend_codex_v2_encrypted_handoff?(%{
         "type" => "agent_message",
         "author" => author,
         "recipient" => recipient,
         "content" => [
           %{"type" => "input_text", "text" => text},
           %{"type" => "encrypted_content", "encrypted_content" => encrypted_content}
         ]
       })
       when is_binary(author) and is_binary(recipient) and is_binary(text) and
              is_binary(encrypted_content) do
    backend_codex_agent_path?(author) and backend_codex_agent_path?(recipient) and
      String.trim(encrypted_content) != "" and
      text in [
        "Message Type: NEW_TASK\nTask name: #{recipient}\nSender: #{author}\nPayload:\n",
        "Message Type: MESSAGE\nTask name: #{recipient}\nSender: #{author}\nPayload:\n"
      ]
  end

  defp backend_codex_v2_encrypted_handoff?(_item), do: false

  defp backend_codex_agent_path?(path), do: Regex.match?(@backend_codex_agent_path, path)

  defp backend_codex_encrypted_content_marker?(%{} = item) do
    Map.get(item, "type") == "encrypted_content" ||
      Map.get(item, :type) == "encrypted_content" ||
      Map.has_key?(item, "encrypted_content") ||
      Map.has_key?(item, :encrypted_content)
  end

  defp backend_codex_encrypted_content_marker?(_item), do: false

  defp backend_codex_encrypted_only_input_item?(%{"content" => nil} = item) do
    Map.has_key?(item, "encrypted_content")
  end

  defp backend_codex_encrypted_only_input_item?(_item), do: false

  defp apply_enforced_payload_policy(payload, %RequestOptions{} = request_options) do
    policy = request_options.routing.api_key_policy || %{}

    payload
    |> apply_reasoning_effort_decision(
      request_options.routing.reasoning_effort_decision,
      Map.get(policy, :enforced_reasoning_effort)
    )
    |> apply_enforced_service_tier(Map.get(policy, :enforced_service_tier))
  end

  defp apply_reasoning_effort_decision(payload, %Decision{applied_effort: effort}, _legacy_effort) do
    apply_enforced_reasoning_effort(payload, effort)
  end

  defp apply_reasoning_effort_decision(payload, nil, legacy_effort) do
    apply_enforced_reasoning_effort(payload, legacy_effort)
  end

  defp apply_enforced_reasoning_effort(payload, effort) when is_binary(effort) do
    reasoning = payload |> Map.get("reasoning") |> reasoning_map() |> Map.put("effort", effort)
    Map.put(payload, "reasoning", reasoning)
  end

  defp apply_enforced_reasoning_effort(payload, _effort), do: payload

  defp apply_enforced_service_tier(payload, tier) when is_binary(tier) do
    case tier |> String.trim() |> String.downcase() do
      tier when tier in ["auto", "default"] -> Map.delete(payload, "service_tier")
      _tier -> Map.put(payload, "service_tier", tier)
    end
  end

  defp apply_enforced_service_tier(payload, _tier), do: payload

  defp canonicalize_backend_fast_service_tier(%{"service_tier" => tier} = payload)
       when is_binary(tier) do
    if tier |> String.trim() |> String.downcase() == "fast" do
      Map.put(payload, "service_tier", "priority")
    else
      payload
    end
  end

  defp canonicalize_backend_fast_service_tier(payload), do: payload

  defp omit_upstream_auto_default_service_tier(%{"service_tier" => tier} = payload)
       when is_binary(tier) do
    case tier |> String.trim() |> String.downcase() do
      tier when tier in ["auto", "default"] -> Map.delete(payload, "service_tier")
      _tier -> payload
    end
  end

  defp omit_upstream_auto_default_service_tier(payload), do: payload

  defp normalize_client_reasoning_effort(payload) do
    case payload do
      %{"reasoning" => %{"effort" => effort} = reasoning} when is_binary(effort) ->
        Map.put(
          payload,
          "reasoning",
          Map.put(reasoning, "effort", ReasoningEffort.rewrite_client_upstream(effort))
        )

      _payload ->
        payload
    end
  end

  defp normalize_backend_codex_reasoning_effort(payload) do
    case payload do
      %{"reasoning" => %{"effort" => effort} = reasoning} when is_binary(effort) ->
        Map.put(
          payload,
          "reasoning",
          Map.put(reasoning, "effort", ReasoningEffort.rewrite_backend_upstream(effort))
        )

      _payload ->
        payload
    end
  end

  defp reasoning_effort(payload) do
    case payload do
      %{"reasoning" => %{"effort" => effort}} -> clean_string(effort)
      _payload -> nil
    end
  end

  defp reasoning_effort_snapshot(
         requested_effort,
         applied_effort,
         effective_effort,
         request_options
       ) do
    decision = request_options.routing.reasoning_effort_decision

    %{}
    |> maybe_put_reasoning_snapshot("policy_mode", decision_mode(decision))
    |> maybe_put_reasoning_snapshot("configured_effort", decision_configured_effort(decision))
    |> maybe_put_reasoning_snapshot("requested_effort", requested_effort)
    |> maybe_put_reasoning_snapshot("applied_effort", applied_effort)
    |> maybe_put_reasoning_snapshot("effective_effort", effective_effort)
    |> maybe_put_reasoning_snapshot(
      "source",
      reasoning_effort_source(requested_effort, request_options)
    )
    |> maybe_put_reasoning_snapshot(
      "rewrite",
      reasoning_effort_rewrite(applied_effort, effective_effort)
    )
  end

  defp reasoning_effort_source(requested_effort, %RequestOptions{
         routing: %{reasoning_effort_decision: %Decision{mode: :unrestricted}}
       }) do
    reasoning_effort_client_source(requested_effort)
  end

  defp reasoning_effort_source(_requested_effort, %RequestOptions{
         routing: %{reasoning_effort_decision: %Decision{mode: mode}}
       })
       when mode in [:allow_up_to, :always_use],
       do: "api_key_policy"

  defp reasoning_effort_source(requested_effort, %RequestOptions{} = request_options) do
    policy = request_options.routing.api_key_policy || %{}

    if is_binary(Map.get(policy, :enforced_reasoning_effort)) do
      "api_key_policy"
    else
      reasoning_effort_client_source(requested_effort)
    end
  end

  defp reasoning_effort_client_source(effort) when is_binary(effort), do: "client"
  defp reasoning_effort_client_source(_effort), do: nil

  defp decision_mode(%Decision{mode: mode}), do: Atom.to_string(mode)
  defp decision_mode(nil), do: nil

  defp decision_configured_effort(%Decision{configured_effort: effort}), do: effort
  defp decision_configured_effort(nil), do: nil

  defp reasoning_effort_rewrite(applied_effort, effective_effort) do
    case {normalize_effort_for_compare(applied_effort),
          normalize_effort_for_compare(effective_effort)} do
      {"minimal", "low"} -> "minimal_to_low"
      {"ultra", "max"} -> "ultra_to_max"
      _efforts -> nil
    end
  end

  defp normalize_effort_for_compare(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_effort_for_compare(_value), do: nil

  defp maybe_put_reasoning_snapshot(snapshot, _key, nil), do: snapshot
  defp maybe_put_reasoning_snapshot(snapshot, key, value), do: Map.put(snapshot, key, value)

  defp maybe_put_websocket_responses_lite_client_metadata(
         payload,
         %RequestOptions{} = request_options
       ) do
    if RequestOptions.use_responses_lite?(request_options) do
      Map.update(
        payload,
        "client_metadata",
        %{@websocket_responses_lite_client_metadata_key => "true"},
        fn
          %{} = metadata ->
            Map.put(metadata, @websocket_responses_lite_client_metadata_key, "true")

          _metadata ->
            %{@websocket_responses_lite_client_metadata_key => "true"}
        end
      )
    else
      payload
    end
  end

  defp remove_client_supplied_responses_lite_metadata(
         %{"client_metadata" => %{} = metadata} = payload
       ) do
    Map.put(
      payload,
      "client_metadata",
      Map.delete(metadata, @websocket_responses_lite_client_metadata_key)
    )
  end

  defp remove_client_supplied_responses_lite_metadata(payload), do: payload

  defp maybe_strip_unsupported_upstream_fields(
         payload,
         "/backend-api/codex/responses",
         %RequestOptions{persona: %Persona{protocol: :openai_completions}}
       ) do
    Map.drop(payload, @unsupported_upstream_fields -- ~w(max_output_tokens temperature top_p))
  end

  defp maybe_strip_unsupported_upstream_fields(
         payload,
         "/backend-api/codex/responses",
         %RequestOptions{persona: %Persona{protocol: protocol}}
       )
       when protocol in [:ollama_chat, :ollama_generate] do
    Map.drop(payload, @unsupported_upstream_fields -- ~w(max_output_tokens temperature top_p))
  end

  defp maybe_strip_unsupported_upstream_fields(
         payload,
         "/backend-api/codex/responses",
         %RequestOptions{}
       ) do
    Map.drop(payload, @unsupported_upstream_fields)
  end

  defp maybe_strip_unsupported_upstream_fields(payload, _endpoint, %RequestOptions{}), do: payload

  defp normalize_reasoning_aliases(payload) do
    canonical_effort = ReasoningEffort.extract_native(payload)
    {reasoning_effort, payload} = pop_first(payload, ["reasoning_effort", "reasoningEffort"])
    payload = Map.drop(payload, ["reasoning_effort", "reasoningEffort"])
    {reasoning_summary, payload} = pop_first(payload, ["reasoning_summary", "reasoningSummary"])
    {thinking, payload} = Map.pop(payload, "thinking")
    {enable_thinking, payload} = Map.pop(payload, "enable_thinking")

    reasoning =
      payload
      |> Map.get("reasoning")
      |> reasoning_map()
      |> maybe_put_reasoning("effort", clean_string(reasoning_effort))
      |> maybe_put_reasoning("summary", clean_string(reasoning_summary))

    reasoning =
      case normalize_thinking_alias(thinking, enable_thinking) do
        nil -> reasoning
        alias_reasoning -> merge_reasoning_alias(reasoning, alias_reasoning)
      end

    reasoning = put_canonical_reasoning_effort(reasoning, canonical_effort)

    if reasoning == %{},
      do: Map.delete(payload, "reasoning"),
      else: Map.put(payload, "reasoning", reasoning)
  end

  defp put_canonical_reasoning_effort(reasoning, nil), do: Map.delete(reasoning, "effort")

  defp put_canonical_reasoning_effort(reasoning, effort),
    do: Map.put(reasoning, "effort", effort)

  defp pop_first(payload, keys) do
    Enum.reduce_while(keys, {nil, payload}, fn key, {_value, payload} ->
      case Map.pop(payload, key) do
        {nil, payload} -> {:cont, {nil, payload}}
        {value, payload} -> {:halt, {value, payload}}
      end
    end)
  end

  defp reasoning_map(%{} = reasoning),
    do: Map.new(reasoning, fn {key, value} -> {to_string(key), value} end)

  defp reasoning_map(_reasoning), do: %{}

  defp maybe_put_reasoning(reasoning, _key, nil), do: reasoning
  defp maybe_put_reasoning(reasoning, key, value), do: Map.put_new(reasoning, key, value)

  defp merge_reasoning_alias(reasoning, alias_reasoning) do
    alias_reasoning
    |> Enum.reduce(reasoning, fn {key, value}, acc -> Map.put_new(acc, key, value) end)
  end

  defp normalize_thinking_alias(thinking, enable_thinking) do
    cond do
      is_boolean(thinking) ->
        if(thinking, do: %{"effort" => "medium"}, else: nil)

      is_binary(thinking) ->
        normalize_thinking_string(thinking)

      is_map(thinking) ->
        normalize_thinking_map(thinking)

      is_boolean(enable_thinking) ->
        if(enable_thinking, do: %{"effort" => "medium"}, else: nil)

      true ->
        nil
    end
  end

  defp normalize_thinking_string(value) do
    case value |> String.trim() |> String.downcase() do
      effort when effort in ["low", "medium", "high", "xhigh", "max", "ultra"] ->
        %{"effort" => effort}

      enabled when enabled in ["enabled", "true", "on"] ->
        %{"effort" => "medium"}

      disabled when disabled in ["disabled", "false", "off"] ->
        nil

      _unknown ->
        nil
    end
  end

  defp normalize_thinking_map(thinking) do
    thinking = Map.new(thinking, fn {key, value} -> {to_string(key), value} end)

    %{}
    |> maybe_put_reasoning("effort", clean_string(thinking["effort"], &String.downcase/1))
    |> maybe_put_reasoning("summary", clean_string(thinking["summary"]))
    |> case do
      empty when empty == %{} -> normalize_thinking_map_enabled(thinking)
      reasoning -> reasoning
    end
  end

  defp normalize_thinking_map_enabled(%{"type" => type}) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "enabled" -> %{"effort" => "medium"}
      "disabled" -> nil
      _unknown -> nil
    end
  end

  defp normalize_thinking_map_enabled(%{"enabled" => enabled}) when is_boolean(enabled) do
    if(enabled, do: %{"effort" => "medium"}, else: nil)
  end

  defp normalize_thinking_map_enabled(_thinking), do: nil

  defp maybe_record_gateway_debug_payload(
         endpoint,
         payload,
         upstream_payload,
         %RequestOptions{} = request_options
       ) do
    transport =
      request_options.transport.transport || RequestOptions.default_transport(endpoint, payload)

    DebugPayloadSummary.record(
      endpoint,
      payload,
      upstream_payload,
      debug_opts(request_options),
      transport
    )
  end

  defp put_gateway_debug_payload(%RequestOptions{} = request_options, nil), do: request_options

  defp put_gateway_debug_payload(%RequestOptions{} = request_options, debug_payload) do
    RequestOptions.put_runtime_context(request_options, gateway_debug_payload: debug_payload)
  end

  defp put_reasoning_effort_snapshot(%RequestOptions{} = request_options, snapshot)
       when map_size(snapshot) > 0 do
    RequestOptions.put_runtime_context(request_options, reasoning_effort_snapshot: snapshot)
  end

  defp put_reasoning_effort_snapshot(%RequestOptions{} = request_options, _snapshot),
    do: request_options

  defp debug_opts(%RequestOptions{} = request_options) do
    %{
      request_id: request_options.request_metadata.request_id,
      codex_session: request_options.continuity.codex_session
    }
  end

  defp multipart_endpoint?("/backend-api/transcribe"), do: true
  defp multipart_endpoint?(_endpoint), do: false

  defp clean_string(value, mapper \\ fn value -> value end)

  defp clean_string(value, mapper) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: mapper.(value)
  end

  defp clean_string(_value, _mapper), do: nil

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
