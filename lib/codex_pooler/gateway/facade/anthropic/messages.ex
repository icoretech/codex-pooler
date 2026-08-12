defmodule CodexPooler.Gateway.Facade.Anthropic.Messages do
  @moduledoc """
  Translates Anthropic Messages input into canonical Responses work.

  Client model and thinking-budget selectors are deliberately not carried into
  the canonical request. The fixed facade persona installs the effective model
  and reasoning effort when the request is coerced through Responses.
  """

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @backend_endpoint "/backend-api/codex/responses"
  @create_fields ~w(
    cache_control
    max_tokens
    messages
    metadata
    model
    service_tier
    stop_sequences
    stream
    system
    temperature
    thinking
    tool_choice
    tools
    top_p
  )
  @count_fields ~w(cache_control messages model system thinking tool_choice tools)
  @image_mimes ~w(image/gif image/jpeg image/png image/webp)
  @max_messages 100_000
  @max_content_blocks 10_000
  @max_tools 128
  @max_stop_sequences 16

  @type formatting :: %{
          required(:stream?) => boolean(),
          required(:think?) => boolean(),
          required(:stops) => [String.t()],
          required(:max_tokens) => pos_integer() | nil
        }

  @type normalized :: %{
          required(:canonical) => map(),
          required(:formatting) => formatting()
        }

  @spec backend_endpoint() :: String.t()
  def backend_endpoint, do: @backend_endpoint

  @spec to_responses(term()) ::
          {:ok, map(), formatting()} | {:error, Error.reason()}
  def to_responses(payload) do
    with {:ok, %{canonical: canonical, formatting: formatting}} <- normalize(payload, :create) do
      {:ok, canonical, formatting}
    end
  end

  @doc false
  @spec normalize_for_count(term()) :: {:ok, normalized()} | {:error, Error.reason()}
  def normalize_for_count(payload), do: normalize(payload, :count)

  @spec coerce(term(), map() | keyword() | RequestOptions.t()) ::
          {:ok, map()} | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, canonical, formatting} <- to_responses(payload),
         {:ok, coerced} <- Responses.coerce(canonical, stream_options(opts, formatting)) do
      {:ok, Map.put(coerced, :anthropic_formatting, formatting)}
    end
  end

  defp normalize(payload, mode) when mode in [:create, :count] do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- reject_unknown_fields(payload, mode),
         :ok <- validate_metadata(payload),
         :ok <- validate_service_tier(payload),
         {:ok, system_items, system_cached?} <- translate_system(payload),
         {:ok, message_items, message_cached?} <- translate_messages(payload),
         {:ok, tools, tools_cached?} <- translate_tools(payload),
         {:ok, tool_choice, parallel_tool_calls} <- translate_tool_choice(payload, tools),
         {:ok, max_tokens} <- output_limit(payload, mode),
         {:ok, stream?} <- stream_mode(payload, mode),
         {:ok, stops} <- stop_sequences(payload, mode),
         {:ok, think?} <- thinking_requested(payload),
         {:ok, sampling} <- sampling_options(payload, mode),
         {:ok, top_level_cached?} <- top_level_cache_control(payload) do
      canonical =
        %{"input" => system_items ++ message_items}
        |> maybe_put("tools", tools)
        |> maybe_put("tool_choice", tool_choice)
        |> maybe_put("parallel_tool_calls", parallel_tool_calls)
        |> maybe_put("max_output_tokens", max_tokens)
        |> maybe_put("stream", if(mode == :create, do: stream?))
        |> maybe_put("reasoning", if(think?, do: %{"summary" => "detailed"}))
        |> Map.merge(sampling)
        |> maybe_put_cache_options(
          system_cached? or message_cached? or tools_cached?,
          top_level_cached?
        )

      formatting = %{
        stream?: stream?,
        think?: think?,
        stops: stops,
        max_tokens: max_tokens
      }

      {:ok, %{canonical: canonical, formatting: formatting}}
    end
  end

  defp reject_unknown_fields(payload, :create), do: reject_unknown_fields(payload, @create_fields)
  defp reject_unknown_fields(payload, :count), do: reject_unknown_fields(payload, @count_fields)

  defp reject_unknown_fields(payload, supported) when is_list(supported) do
    case payload |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in supported)) do
      nil -> :ok
      field -> {:error, Error.unsupported_parameter(field)}
    end
  end

  defp validate_metadata(%{"metadata" => metadata}) when is_map(metadata) do
    case Map.keys(metadata) do
      [] -> :ok
      ["user_id"] -> validate_optional_string(metadata, "user_id", "metadata.user_id")
      keys -> {:error, Error.unsupported_parameter("metadata." <> hd(Enum.sort(keys)))}
    end
  end

  defp validate_metadata(%{"metadata" => _metadata}),
    do: invalid("metadata must be an object", "metadata")

  defp validate_metadata(_payload), do: :ok

  defp validate_service_tier(%{"service_tier" => tier}) when tier in ["auto", "standard_only"],
    do: :ok

  defp validate_service_tier(%{"service_tier" => _tier}),
    do: invalid("service_tier is not supported", "service_tier")

  defp validate_service_tier(_payload), do: :ok

  defp validate_optional_string(map, key, param) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> :ok
      _value -> invalid("#{param} must be a non-empty string", param)
    end
  end

  defp translate_system(%{"system" => system}) when is_binary(system) do
    if system == "" do
      invalid("system must not be empty", "system")
    else
      {:ok, [message_item("system", [%{"type" => "input_text", "text" => system}])], false}
    end
  end

  defp translate_system(%{"system" => blocks}) when is_list(blocks) and blocks != [] do
    blocks
    |> bounded_list(@max_content_blocks, "system")
    |> then(fn
      :ok -> translate_system_blocks(blocks)
      {:error, reason} -> {:error, reason}
    end)
  end

  defp translate_system(%{"system" => _system}),
    do: invalid("system must be a non-empty string or text-block array", "system")

  defp translate_system(_payload), do: {:ok, [], false}

  defp translate_system_blocks(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], false}, fn {block, index}, {:ok, parts, cached?} ->
      param = "system[#{index}]"

      case translate_text_block(block, "input_text", param, true) do
        {:ok, part, marked?} -> {:cont, {:ok, [part | parts], cached? or marked?}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts, cached?} -> {:ok, [message_item("system", Enum.reverse(parts))], cached?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_messages(%{"messages" => messages}) when is_list(messages) and messages != [] do
    with :ok <- bounded_list(messages, @max_messages, "messages") do
      messages
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], false}, fn {message, index}, {:ok, items, cached?} ->
        case translate_message(message, index) do
          {:ok, translated, marked?} ->
            {:cont, {:ok, Enum.reverse(translated, items), cached? or marked?}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, [], _cached?} -> invalid("messages must contain representable content", "messages")
        {:ok, items, cached?} -> {:ok, Enum.reverse(items), cached?}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp translate_messages(%{"messages" => _messages}),
    do: invalid("messages must be a non-empty array", "messages")

  defp translate_messages(_payload), do: invalid("messages is required", "messages")

  defp translate_message(%{"role" => role, "content" => content}, index)
       when role in ["user", "assistant"] do
    param = "messages[#{index}].content"

    with {:ok, blocks} <- normalize_message_content(content, param),
         :ok <- bounded_list(blocks, @max_content_blocks, param),
         {:ok, items, cached?} <- translate_message_blocks(blocks, role, index) do
      if items == [] do
        invalid("message content must contain a supported block", param)
      else
        {:ok, items, cached?}
      end
    end
  end

  defp translate_message(%{"role" => _role}, index),
    do: invalid("message role must be user or assistant", "messages[#{index}].role")

  defp translate_message(_message, index),
    do: invalid("message must contain role and content", "messages[#{index}]")

  defp normalize_message_content(content, _param) when is_binary(content),
    do: {:ok, [%{"type" => "text", "text" => content}]}

  defp normalize_message_content(content, _param) when is_list(content) and content != [],
    do: {:ok, content}

  defp normalize_message_content(_content, param),
    do: invalid("message content must be a non-empty string or block array", param)

  defp translate_message_blocks(blocks, role, message_index) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], [], false}, fn {block, block_index},
                                                  {:ok, items, parts, cached?} ->
      case translate_message_block(block, role, message_index, block_index) do
        {:part, part, marked?} ->
          {:cont, {:ok, items, [part | parts], cached? or marked?}}

        {:item, item, marked?} ->
          items = [item | flush_message(parts, role, items)]
          {:cont, {:ok, items, [], cached? or marked?}}

        {:ignore, marked?} ->
          {:cont, {:ok, items, parts, cached? or marked?}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items, parts, cached?} ->
        {:ok, Enum.reverse(flush_message(parts, role, items)), cached?}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flush_message([], _role, items), do: items

  defp flush_message(parts, role, items),
    do: [message_item(role, Enum.reverse(parts)) | items]

  defp translate_message_block(%{"type" => "text"} = block, role, message_index, block_index) do
    output_type = if role == "assistant", do: "output_text", else: "input_text"
    param = block_param(message_index, block_index)

    case translate_text_block(block, output_type, param, role != "assistant") do
      {:ok, part, marked?} -> {:part, part, marked?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_block(%{"type" => "image"} = block, "user", message_index, block_index) do
    param = block_param(message_index, block_index)

    case translate_image_block(block, param, true) do
      {:ok, part, marked?} -> {:part, part, marked?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_block(%{"type" => "image"}, _role, message_index, block_index),
    do: {:error, Error.unsupported_parameter(block_param(message_index, block_index))}

  defp translate_message_block(
         %{"type" => "tool_use"} = block,
         "assistant",
         message_index,
         block_index
       ) do
    param = block_param(message_index, block_index)

    case translate_tool_use(block, param) do
      {:ok, item, marked?} -> {:item, item, marked?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_block(%{"type" => "tool_use"}, _role, message_index, block_index),
    do: {:error, Error.unsupported_parameter(block_param(message_index, block_index))}

  defp translate_message_block(
         %{"type" => "tool_result"} = block,
         "user",
         message_index,
         block_index
       ) do
    param = block_param(message_index, block_index)

    case translate_tool_result(block, param) do
      {:ok, item, marked?} -> {:item, item, marked?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_block(%{"type" => "tool_result"}, _role, message_index, block_index),
    do: {:error, Error.unsupported_parameter(block_param(message_index, block_index))}

  defp translate_message_block(
         %{"type" => type} = block,
         "assistant",
         _message_index,
         _block_index
       )
       when type in ["thinking", "redacted_thinking"] do
    case cache_control(block, "thinking") do
      {:ok, marked?} -> {:ignore, marked?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_block(_block, _role, message_index, block_index),
    do: {:error, Error.unsupported_parameter(block_param(message_index, block_index))}

  defp translate_text_block(
         %{"type" => "text", "text" => text} = block,
         output_type,
         param,
         mark?
       )
       when is_binary(text) and text != "" do
    allowed = ["type", "text", "cache_control", "citations"]

    with :ok <- exact_keys(block, allowed, param),
         {:ok, marked?} <- cache_control(block, param) do
      part =
        %{"type" => output_type, "text" => text}
        |> maybe_put_breakpoint(marked? and mark?)

      {:ok, part, marked?}
    end
  end

  defp translate_text_block(_block, _output_type, param, _mark?),
    do: invalid("text block requires non-empty text", param <> ".text")

  defp translate_image_block(
         %{
           "type" => "image",
           "source" =>
             %{
               "type" => "base64",
               "media_type" => media_type,
               "data" => data
             } = source
         } = block,
         param,
         mark?
       )
       when is_binary(media_type) and is_binary(data) do
    media_type = String.downcase(media_type)

    with :ok <- exact_keys(block, ["type", "source", "cache_control"], param),
         :ok <- exact_keys(source, ["type", "media_type", "data"], param <> ".source"),
         :ok <- validate_image_media_type(media_type, param <> ".source.media_type"),
         {:ok, encoded} <- normalize_base64_image(data, media_type, param <> ".source.data"),
         {:ok, marked?} <- cache_control(block, param) do
      part =
        %{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{encoded}"}
        |> maybe_put_breakpoint(marked? and mark?)

      {:ok, part, marked?}
    end
  end

  defp translate_image_block(_block, param, _mark?),
    do:
      invalid(
        "image block requires a supported base64 source",
        param <> ".source"
      )

  defp validate_image_media_type(media_type, _param) when media_type in @image_mimes, do: :ok

  defp validate_image_media_type(_media_type, param),
    do: invalid("image media_type is not supported", param)

  defp normalize_base64_image(data, media_type, param) do
    with {:ok, bytes} when byte_size(bytes) > 0 <- Base.decode64(data, ignore: :whitespace),
         true <- image_media_type(bytes) == media_type do
      {:ok, Base.encode64(bytes)}
    else
      _result -> invalid("image data must be valid base64 matching media_type", param)
    end
  end

  defp image_media_type(<<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>),
    do: "image/png"

  defp image_media_type(<<255, 216, 255, _rest::binary>>), do: "image/jpeg"
  defp image_media_type(<<"GIF87a", _rest::binary>>), do: "image/gif"
  defp image_media_type(<<"GIF89a", _rest::binary>>), do: "image/gif"
  defp image_media_type(<<"RIFF", _size::little-32, "WEBP", _rest::binary>>), do: "image/webp"
  defp image_media_type(_bytes), do: nil

  defp translate_tool_use(
         %{"id" => id, "name" => name, "input" => input} = block,
         param
       )
       when is_binary(id) and is_binary(name) and is_map(input) do
    with :ok <- exact_keys(block, ["type", "id", "name", "input", "cache_control"], param),
         :ok <- nonblank(id, param <> ".id"),
         :ok <- nonblank(name, param <> ".name"),
         {:ok, marked?} <- cache_control(block, param),
         {:ok, arguments} <- encode_json(input, param <> ".input") do
      {:ok,
       %{
         "type" => "function_call",
         "call_id" => id,
         "name" => name,
         "arguments" => arguments
       }, marked?}
    end
  end

  defp translate_tool_use(_block, param),
    do: invalid("tool_use requires id, name, and object input", param)

  defp translate_tool_result(%{"tool_use_id" => call_id} = block, param)
       when is_binary(call_id) do
    with :ok <-
           exact_keys(
             block,
             ["type", "tool_use_id", "content", "is_error", "cache_control"],
             param
           ),
         :ok <- nonblank(call_id, param <> ".tool_use_id"),
         :ok <- validate_is_error(block, param),
         {:ok, marked?} <- cache_control(block, param),
         {:ok, output, output_cached?} <-
           tool_result_output(Map.get(block, "content", ""), block, param, marked?) do
      {:ok,
       %{
         "type" => "function_call_output",
         "call_id" => call_id,
         "output" => output
       }, marked? or output_cached?}
    end
  end

  defp translate_tool_result(_block, param),
    do: invalid("tool_result requires a non-empty tool_use_id", param <> ".tool_use_id")

  defp validate_is_error(%{"is_error" => value}, _param) when is_boolean(value), do: :ok

  defp validate_is_error(%{"is_error" => _value}, param),
    do: invalid("is_error must be a boolean", param <> ".is_error")

  defp validate_is_error(_block, _param), do: :ok

  defp tool_result_output(content, block, _param, marked?) when is_binary(content) do
    if marked? or Map.get(block, "is_error") == true do
      parts = [%{"type" => "input_text", "text" => content}]
      {:ok, decorate_tool_error(parts, block) |> mark_parts(marked?), marked?}
    else
      {:ok, content, false}
    end
  end

  defp tool_result_output(content, block, param, marked?)
       when is_list(content) and content != [] do
    content
    |> bounded_list(@max_content_blocks, param <> ".content")
    |> then(fn
      :ok -> translate_tool_result_parts(content, block, param, marked?)
      {:error, reason} -> {:error, reason}
    end)
  end

  defp tool_result_output(_content, _block, param, _marked?),
    do:
      invalid(
        "tool_result content must be a string or non-empty block array",
        param <> ".content"
      )

  defp translate_tool_result_parts(content, block, param, marked?) do
    content
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], marked?}, fn {part, index}, {:ok, parts, cached?} ->
      part_param = "#{param}.content[#{index}]"

      result =
        case part do
          %{"type" => "text"} -> translate_text_block(part, "input_text", part_param, true)
          %{"type" => "image"} -> translate_image_block(part, part_param, true)
          _part -> {:error, Error.unsupported_parameter(part_param)}
        end

      case result do
        {:ok, translated, part_cached?} ->
          {:cont, {:ok, [translated | parts], cached? or part_cached?}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts, cached?} ->
        parts = parts |> Enum.reverse() |> decorate_tool_error(block) |> mark_parts(marked?)
        {:ok, parts, cached?}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decorate_tool_error(parts, %{"is_error" => true}),
    do: [%{"type" => "input_text", "text" => "Tool execution failed."} | parts]

  defp decorate_tool_error(parts, _block), do: parts

  defp mark_parts(parts, true),
    do: Enum.map(parts, &Map.put(&1, "prompt_cache_breakpoint", breakpoint()))

  defp mark_parts(parts, false), do: parts

  defp translate_tools(%{"tools" => tools}) when is_list(tools) do
    with :ok <- bounded_list(tools, @max_tools, "tools") do
      tools
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], false}, fn {tool, index}, {:ok, translated, cached?} ->
        case translate_tool(tool, index) do
          {:ok, tool, marked?} ->
            {:cont, {:ok, [tool | translated], cached? or marked?}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, translated, cached?} -> {:ok, Enum.reverse(translated), cached?}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp translate_tools(%{"tools" => _tools}), do: invalid("tools must be an array", "tools")
  defp translate_tools(_payload), do: {:ok, nil, false}

  defp translate_tool(%{"name" => name, "input_schema" => schema} = tool, index)
       when is_binary(name) and is_map(schema) do
    param = "tools[#{index}]"

    with :ok <-
           exact_keys(
             tool,
             ["name", "description", "input_schema", "cache_control", "strict"],
             param
           ),
         :ok <- nonblank(name, param <> ".name"),
         :ok <- validate_optional_description(tool, param),
         :ok <- validate_optional_strict(tool, param),
         {:ok, marked?} <- cache_control(tool, param) do
      translated =
        %{"type" => "function", "name" => name, "parameters" => schema}
        |> maybe_copy(tool, "description")
        |> maybe_copy(tool, "strict")

      {:ok, translated, marked?}
    end
  end

  defp translate_tool(_tool, index),
    do: invalid("tool requires a name and input_schema object", "tools[#{index}]")

  defp validate_optional_description(%{"description" => value}, _param) when is_binary(value),
    do: :ok

  defp validate_optional_description(%{"description" => _value}, param),
    do: invalid("tool description must be a string", param <> ".description")

  defp validate_optional_description(_tool, _param), do: :ok

  defp validate_optional_strict(%{"strict" => value}, _param) when is_boolean(value), do: :ok

  defp validate_optional_strict(%{"strict" => _value}, param),
    do: invalid("tool strict must be a boolean", param <> ".strict")

  defp validate_optional_strict(_tool, _param), do: :ok

  defp translate_tool_choice(%{"tool_choice" => choice}, tools) when is_map(choice) do
    allowed = ["type", "name", "disable_parallel_tool_use"]

    with :ok <- exact_keys(choice, allowed, "tool_choice"),
         {:ok, parallel} <- parallel_tool_choice(choice),
         {:ok, translated} <- do_translate_tool_choice(choice, tools) do
      {:ok, translated, parallel}
    end
  end

  defp translate_tool_choice(%{"tool_choice" => _choice}, _tools),
    do: invalid("tool_choice must be an object", "tool_choice")

  defp translate_tool_choice(_payload, _tools), do: {:ok, nil, nil}

  defp do_translate_tool_choice(%{"type" => "auto"}, _tools), do: {:ok, "auto"}

  defp do_translate_tool_choice(%{"type" => "any"}, tools) do
    if present_tools?(tools),
      do: {:ok, "required"},
      else: invalid("tool_choice requires tools", "tool_choice")
  end

  defp do_translate_tool_choice(%{"type" => "none"}, _tools), do: {:ok, "none"}

  defp do_translate_tool_choice(%{"type" => "tool", "name" => name}, tools)
       when is_binary(name) do
    if Enum.any?(tools || [], &(&1["name"] == name)) do
      {:ok, %{"type" => "function", "name" => name}}
    else
      invalid("tool_choice references an unknown tool", "tool_choice")
    end
  end

  defp do_translate_tool_choice(_choice, _tools),
    do: invalid("tool_choice type is not supported", "tool_choice")

  defp parallel_tool_choice(%{"disable_parallel_tool_use" => value}) when is_boolean(value),
    do: {:ok, not value}

  defp parallel_tool_choice(%{"disable_parallel_tool_use" => _value}),
    do:
      invalid(
        "disable_parallel_tool_use must be a boolean",
        "tool_choice.disable_parallel_tool_use"
      )

  defp parallel_tool_choice(_choice), do: {:ok, nil}

  defp present_tools?(tools), do: is_list(tools) and tools != []

  defp output_limit(%{"max_tokens" => value}, :create) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp output_limit(%{"max_tokens" => _value}, :create),
    do: invalid("max_tokens must be a positive integer", "max_tokens")

  defp output_limit(_payload, :create), do: invalid("max_tokens is required", "max_tokens")
  defp output_limit(_payload, :count), do: {:ok, nil}

  defp stream_mode(%{"stream" => value}, :create) when is_boolean(value), do: {:ok, value}

  defp stream_mode(%{"stream" => _value}, :create),
    do: invalid("stream must be a boolean", "stream")

  defp stream_mode(_payload, _mode), do: {:ok, false}

  defp stop_sequences(%{"stop_sequences" => stops}, :create) when is_list(stops) do
    if stops != [] and length(stops) <= @max_stop_sequences and
         Enum.all?(stops, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 1_024)) do
      {:ok, stops}
    else
      invalid(
        "stop_sequences must contain one to sixteen bounded non-empty strings",
        "stop_sequences"
      )
    end
  end

  defp stop_sequences(%{"stop_sequences" => _stops}, :create),
    do: invalid("stop_sequences must be an array", "stop_sequences")

  defp stop_sequences(_payload, _mode), do: {:ok, []}

  defp thinking_requested(%{
         "thinking" => %{"type" => "enabled", "budget_tokens" => budget} = thinking
       })
       when is_integer(budget) and budget > 0 do
    with :ok <- exact_keys(thinking, ["type", "budget_tokens"], "thinking") do
      {:ok, true}
    end
  end

  defp thinking_requested(%{"thinking" => %{"type" => "enabled"}}),
    do: invalid("thinking budget_tokens must be a positive integer", "thinking.budget_tokens")

  defp thinking_requested(%{"thinking" => %{"type" => "adaptive"} = thinking}) do
    with :ok <- exact_keys(thinking, ["type"], "thinking"), do: {:ok, true}
  end

  defp thinking_requested(%{"thinking" => %{"type" => "disabled"} = thinking}) do
    with :ok <- exact_keys(thinking, ["type"], "thinking"), do: {:ok, false}
  end

  defp thinking_requested(%{"thinking" => _thinking}),
    do: invalid("thinking shape is not supported", "thinking")

  defp thinking_requested(_payload), do: {:ok, false}

  defp sampling_options(payload, :create) do
    with :ok <- validate_temperature(payload),
         :ok <- validate_top_p(payload) do
      {:ok,
       %{}
       |> maybe_copy(payload, "temperature")
       |> maybe_copy(payload, "top_p")}
    end
  end

  defp sampling_options(_payload, :count), do: {:ok, %{}}

  defp validate_temperature(%{"temperature" => value})
       when is_number(value) and value >= 0 and value <= 1,
       do: :ok

  defp validate_temperature(%{"temperature" => _value}),
    do: invalid("temperature must be between 0 and 1", "temperature")

  defp validate_temperature(_payload), do: :ok

  defp validate_top_p(%{"top_p" => value}) when is_number(value) and value >= 0 and value <= 1,
    do: :ok

  defp validate_top_p(%{"top_p" => _value}),
    do: invalid("top_p must be between 0 and 1", "top_p")

  defp validate_top_p(_payload), do: :ok

  defp top_level_cache_control(%{"cache_control" => _cache} = payload) do
    cache_control(payload, "request")
  end

  defp top_level_cache_control(_payload), do: {:ok, false}

  defp cache_control(%{"cache_control" => control}, param) when is_map(control) do
    with :ok <- exact_keys(control, ["type", "ttl"], param <> ".cache_control"),
         true <- Map.get(control, "type") == "ephemeral",
         true <- Map.get(control, "ttl") in [nil, "5m", "1h"] do
      {:ok, true}
    else
      false ->
        invalid("cache_control must be ephemeral with a supported ttl", param <> ".cache_control")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cache_control(%{"cache_control" => _control}, param),
    do: invalid("cache_control must be an object", param <> ".cache_control")

  defp cache_control(_value, _param), do: {:ok, false}

  defp exact_keys(map, allowed, param) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _rest] -> {:error, Error.unsupported_parameter(param <> "." <> key)}
    end
  end

  defp nonblank(value, param) when is_binary(value) do
    if String.trim(value) == "", do: invalid("value must be non-empty", param), else: :ok
  end

  defp encode_json(value, param) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> invalid("value must be valid JSON", param)
    end
  end

  defp bounded_list(list, maximum, param) do
    if length(list) <= maximum,
      do: :ok,
      else: invalid("array exceeds the supported bound", param)
  end

  defp block_param(message_index, block_index),
    do: "messages[#{message_index}].content[#{block_index}]"

  defp message_item(role, content),
    do: %{"type" => "message", "role" => role, "content" => content}

  defp breakpoint, do: %{"mode" => "explicit"}

  defp maybe_put_breakpoint(part, true),
    do: Map.put(part, "prompt_cache_breakpoint", breakpoint())

  defp maybe_put_breakpoint(part, false), do: part

  defp maybe_put_cache_options(payload, true, _automatic?),
    do: Map.put(payload, "prompt_cache_options", %{"mode" => "explicit"})

  defp maybe_put_cache_options(payload, false, true),
    do: Map.put(payload, "prompt_cache_options", %{"mode" => "implicit"})

  defp maybe_put_cache_options(payload, false, false), do: payload

  defp stream_options(%RequestOptions{} = opts, %{stream?: stream?}) do
    RequestOptions.put_openai_compatibility(opts,
      collect_openai_response_stream: not stream?
    )
  end

  defp stream_options(opts, %{stream?: stream?}) when is_list(opts),
    do: Keyword.put(opts, :collect_openai_response_stream, not stream?)

  defp stream_options(opts, %{stream?: stream?}) when is_map(opts),
    do: Map.put(opts, :collect_openai_response_stream, not stream?)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_copy(target, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(target, key, value)
      :error -> target
    end
  end

  defp invalid(message, param), do: {:error, Error.invalid_request(message, param)}
end
