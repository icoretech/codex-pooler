defmodule CodexPooler.Gateway.Payloads.PayloadNormalizer do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Payloads.ToolSchemaLowering

  @backend_turn_state_client_metadata_key "x-codex-turn-state"
  @websocket_responses_lite_client_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"

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

  defp json_payload(payload, model, endpoint, %RequestOptions{} = request_options) do
    payload =
      payload
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> normalize_reasoning_aliases()
      |> Map.put("model", model.upstream_model_id)

    requested_effort = reasoning_effort(payload)

    payload =
      payload
      |> apply_enforced_payload_policy(request_options)
      |> omit_upstream_auto_default_service_tier()

    applied_effort = reasoning_effort(payload)

    payload = normalize_client_reasoning_effort(payload)

    upstream_payload =
      payload
      |> maybe_strip_unsupported_upstream_fields(endpoint)
      |> strip_backend_codex_fields(endpoint, request_options)

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
      |> put_gateway_debug_payload(debug_payload)
      |> put_reasoning_effort_snapshot(reasoning_effort_snapshot)

    with {:ok, encoded} <- Jason.encode(upstream_payload) do
      {:ok, encoded, request_options}
    end
  end

  defp multipart_payload(payload, _model, %RequestOptions{} = request_options) do
    upload = request_options.payload_context.media_upload

    fields =
      [
        {:prompt, Map.get(payload, "prompt")}
      ]
      |> Enum.reject(fn {_key, value} -> blank?(value) end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)

    with {:ok, stream} <- upload_stream(upload) do
      file_part =
        {:file,
         {stream,
          filename: upload.redacted_filename, content_type: upload.content_type, size: upload.size}}

      {:ok, {:multipart, [file_part | fields]}, request_options}
    end
  end

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
    |> normalize_backend_codex_responses_lite(request_options)
    |> ToolSchemaLowering.lower_non_strict_function_tools()
    |> remove_backend_codex_encrypted_tool_schema_markers()
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
    |> normalize_backend_codex_responses_lite(opts)
    |> ToolSchemaLowering.lower_non_strict_function_tools()
    |> remove_backend_codex_encrypted_tool_schema_markers()
  end

  defp normalize_backend_codex_compact_payload(payload, opts) do
    payload
    |> normalize_backend_codex_reasoning_effort()
    |> normalize_backend_codex_responses_lite(opts)
  end

  defp normalize_backend_codex_responses_lite(
         payload,
         %RequestOptions{routing: %{use_responses_lite?: true}}
       ) do
    reasoning =
      payload |> Map.get("reasoning") |> reasoning_map() |> Map.put("context", "all_turns")

    payload
    |> Map.put("reasoning", reasoning)
    |> Map.put("parallel_tool_calls", false)
  end

  defp normalize_backend_codex_responses_lite(payload, %RequestOptions{}), do: payload

  defp remove_backend_codex_encrypted_tool_schema_markers(%{"tools" => tools} = payload)
       when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &remove_schema_encrypted_markers/1))
  end

  defp remove_backend_codex_encrypted_tool_schema_markers(payload), do: payload

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

  defp backend_codex_encrypted_agent_message?(%{
         "type" => "agent_message",
         "content" => content
       })
       when is_list(content) do
    Enum.any?(content, &backend_codex_encrypted_content_marker?/1)
  end

  defp backend_codex_encrypted_agent_message?(_item), do: false

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
    |> apply_enforced_reasoning_effort(Map.get(policy, :enforced_reasoning_effort))
    |> apply_enforced_service_tier(Map.get(policy, :enforced_service_tier))
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
        if String.downcase(String.trim(effort)) == "minimal" do
          Map.put(payload, "reasoning", Map.put(reasoning, "effort", "low"))
        else
          payload
        end

      _payload ->
        payload
    end
  end

  defp normalize_backend_codex_reasoning_effort(payload) do
    case payload do
      %{"reasoning" => %{"effort" => effort} = reasoning} when is_binary(effort) ->
        if String.downcase(String.trim(effort)) == "ultra" do
          Map.put(payload, "reasoning", Map.put(reasoning, "effort", "max"))
        else
          payload
        end

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
    %{}
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
         %RequestOptions{routing: %{use_responses_lite?: true}}
       ) do
    Map.update(
      payload,
      "client_metadata",
      %{@websocket_responses_lite_client_metadata_key => "true"},
      fn
        %{} = metadata -> Map.put(metadata, @websocket_responses_lite_client_metadata_key, "true")
        _metadata -> %{@websocket_responses_lite_client_metadata_key => "true"}
      end
    )
  end

  defp maybe_put_websocket_responses_lite_client_metadata(payload, %RequestOptions{}), do: payload

  defp maybe_strip_unsupported_upstream_fields(payload, "/backend-api/codex/responses") do
    Map.drop(payload, @unsupported_upstream_fields)
  end

  defp maybe_strip_unsupported_upstream_fields(payload, _endpoint), do: payload

  defp normalize_reasoning_aliases(payload) do
    {reasoning_effort, payload} = pop_first(payload, ["reasoning_effort", "reasoningEffort"])
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

    if reasoning == %{},
      do: Map.delete(payload, "reasoning"),
      else: Map.put(payload, "reasoning", reasoning)
  end

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
