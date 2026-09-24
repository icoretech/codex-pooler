defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.Normalization do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.OpenAICompatibility.Responses.Input.Audio
  alias CodexPooler.Gateway.OpenAICompatibility.Responses.Input.InstructionLifter
  alias CodexPooler.Gateway.Payloads.CompactionTrigger
  alias CodexPooler.Gateway.Payloads.ToolResultShape

  @metadata_passthrough_key "internal_chat_message_metadata_passthrough"
  @known_input_item_types ~w(
    additional_tools
    message
    reasoning
    compaction
    compaction_trigger
    program
    program_output
    function_call
    custom_tool_call
    custom_tool_call_output
    function_call_output
    input_file
    item_reference
    shell_call
    shell_call_output
  )

  @call_id_named_item_types ~w(function_call custom_tool_call shell_call shell_call_output)

  # The provider's `input_image.detail` enum, in the order its refusal lists it.
  @image_details ~w(low high auto original)

  @typep audio_normalization_result :: {:ok, map()} | {:error, Error.reason()}

  def normalize_input(%{"input" => input} = payload) when is_binary(input) do
    {:ok, Map.put(payload, "input", [input_text_message(input)])}
  end

  def normalize_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok,
       payload
       |> Map.put("input", input)
       |> drop_stateless_reasoning_replay()
       |> InstructionLifter.lift()}
    end
  end

  def normalize_input(payload), do: {:ok, payload}

  def finalize_normalized_input(%{"input" => input} = payload) when is_binary(input),
    do: {:ok, Map.put(payload, "input", [input_text_message(input)])}

  def finalize_normalized_input(%{"input" => input} = payload) when is_list(input),
    do: {:ok, InstructionLifter.lift(payload)}

  def finalize_normalized_input(payload), do: {:ok, payload}

  @spec normalize_audio_input(map()) :: audio_normalization_result()
  def normalize_audio_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_audio_input_items(input) do
      {:ok, Map.put(payload, "input", input)}
    end
  end

  def normalize_audio_input(payload), do: {:ok, payload}

  def normalize_list_input(%{"input" => input} = payload) when is_list(input) do
    with {:ok, input} <- normalize_input_items(input) do
      {:ok, payload |> Map.put("input", input) |> drop_stateless_reasoning_replay()}
    end
  end

  def normalize_list_input(payload), do: {:ok, payload}

  # An id-less call item is named by its own `call_id` on the public surface
  # (`PublicResponses.ensure_output_item_id/2`). The Codex backend refuses a
  # replayed `function_call` whose id equals its `call_id` (400
  # `invalid_value` on `input[i].id`) and accepts it without an id, so that
  # exact id is dropped from every call item whose id is optional (findings#254).
  # A provider id (`fc_`, `ctc_`) never equals the provider's `call_id`
  # (`call_`), and a `program` item keeps its required id. This runs on the
  # input as the client sent it, before the OpenCode repair below copies a
  # provider id into a blank `call_id`.
  def drop_public_call_id_item_ids(%{"input" => input} = payload) when is_list(input) do
    {:ok, Map.put(payload, "input", Enum.map(input, &drop_public_call_id_item_id/1))}
  end

  def drop_public_call_id_item_ids(payload), do: {:ok, payload}

  defp drop_public_call_id_item_id(%{"type" => type, "id" => id, "call_id" => id} = item)
       when type in @call_id_named_item_types and is_binary(id),
       do: Map.delete(item, "id")

  defp drop_public_call_id_item_id(item), do: item

  def normalize_recoverable_opencode_replay_call_ids(%{"input" => input} = payload)
      when is_list(input) do
    {:ok, Map.put(payload, "input", normalize_recoverable_opencode_replay_items(input))}
  end

  def normalize_recoverable_opencode_replay_call_ids(payload), do: {:ok, payload}

  defp normalize_recoverable_opencode_replay_items(input) do
    input
    |> do_normalize_recoverable_opencode_replay_items(0, [])
    |> Enum.reverse()
  end

  defp do_normalize_recoverable_opencode_replay_items([call, output | rest], index, acc)
       when is_map(call) and is_map(output) do
    if recoverable_opencode_tool_replay_pair?(call, output) do
      call_id = opencode_replay_call_id(call, index)

      do_normalize_recoverable_opencode_replay_items(
        rest,
        index + 2,
        [Map.put(output, "call_id", call_id), Map.put(call, "call_id", call_id) | acc]
      )
    else
      do_normalize_recoverable_opencode_replay_items([output | rest], index + 1, [call | acc])
    end
  end

  defp do_normalize_recoverable_opencode_replay_items([item | rest], index, acc),
    do: do_normalize_recoverable_opencode_replay_items(rest, index + 1, [item | acc])

  defp do_normalize_recoverable_opencode_replay_items([], _index, acc), do: acc

  defp recoverable_opencode_tool_replay_pair?(call, output) do
    function_call_replay_shape?(call) and function_call_output_replay_shape?(output) and
      blank_call_id?(output) and recoverable_opencode_call_id?(call)
  end

  defp function_call_replay_shape?(%{
         "type" => "function_call",
         "name" => name,
         "arguments" => arguments
       })
       when is_binary(name) and name != "" and is_binary(arguments),
       do: true

  defp function_call_replay_shape?(_item), do: false

  defp function_call_output_replay_shape?(%{"type" => "function_call_output"} = item),
    do: Map.has_key?(item, "output") or Map.has_key?(item, "result")

  defp function_call_output_replay_shape?(_item), do: false

  defp opencode_replay_call_id(call, _index) do
    clean_string(Map.get(call, "call_id")) || clean_string(Map.get(call, "id"))
  end

  defp blank_call_id?(item), do: is_nil(clean_string(Map.get(item, "call_id")))

  defp recoverable_opencode_call_id?(call), do: is_binary(opencode_replay_call_id(call, 0))

  defp drop_stateless_reasoning_replay(%{"input" => input} = payload) when is_list(input) do
    if previous_response_id?(payload) do
      payload
    else
      Map.put(payload, "input", Enum.reject(input, &reasoning_replay_item?/1))
    end
  end

  defp drop_stateless_reasoning_replay(payload), do: payload

  defp previous_response_id?(%{"previous_response_id" => value}) when is_binary(value),
    do: String.trim(value) != ""

  defp previous_response_id?(_payload), do: false

  defp reasoning_replay_item?(%{"type" => "reasoning"}), do: true
  defp reasoning_replay_item?(_item), do: false

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  # The public stream names an output item the upstream sent without an id
  # `<type>_<output_index>` (or `<type>` without an index; see
  # `PublicResponses.fallback_output_item_id/2`). Replayed into a `store:
  # false` turn, the Codex backend rejects that id for a message or a
  # compaction (400 `invalid_value` on `input[i].id`) and accepts the item
  # without one; provider ids are a short prefix plus an opaque suffix
  # (`msg_`, `rs_`, `cmp_`, `fc_`) and never the item type itself. The input
  # adapter therefore drops exactly the item's own fallback id before
  # normalization, so the upstream receives the item as it produced it
  # (findings#254). A reasoning item keeps its id unless it carries encrypted
  # content, the only form that stays valid without one.
  defp drop_public_fallback_item_id(%{"type" => type, "id" => id} = item)
       when type in ["message", "compaction"] and is_binary(id) do
    if public_fallback_item_id?(type, id), do: Map.delete(item, "id"), else: item
  end

  defp drop_public_fallback_item_id(%{"type" => "reasoning", "id" => id, "encrypted_content" => content} = item)
       when is_binary(id) and is_binary(content) do
    if public_fallback_item_id?("reasoning", id) and String.trim(content) != "",
      do: Map.delete(item, "id"),
      else: item
  end

  defp drop_public_fallback_item_id(item), do: item

  defp public_fallback_item_id?(type, type), do: true

  defp public_fallback_item_id?(type, id) do
    prefix = type <> "_"

    String.starts_with?(id, prefix) and
      Regex.match?(~r/\A[0-9]+\z/, binary_part(id, byte_size(prefix), byte_size(id) - byte_size(prefix)))
  end

  defp normalize_input_items(input) do
    with :ok <- validate_input_image_details(input) do
      normalize_valid_input_items(input)
    end
  end

  defp normalize_valid_input_items(input) do
    Enum.reduce_while(input, {:ok, []}, fn item, {:ok, acc} ->
      case item |> drop_public_fallback_item_id() |> normalize_input_item() do
        {:ok, items} when is_list(items) -> {:cont, {:ok, Enum.reverse(items) ++ acc}}
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, input} -> {:ok, Enum.reverse(input)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The provider validates `detail` on every input image, in a message and in
  # a tool output alike, and refuses a value outside its enum with 400
  # `invalid_value` on the field path (findings#206 row 206-476, probed on the
  # Codex backend and the public API). A Full model receives `detail`, so such
  # a value is refused here with the same code and path, on the input as the
  # client sent it, before reservation or dispatch; Lite would strip it, and
  # the serving mode does not decide whether a request is valid. A null detail
  # counts as absent.
  defp validate_input_image_details(input) do
    input
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {item, index} -> invalid_input_image_detail(item, index) end)
  end

  defp invalid_input_image_detail(%{"type" => type, "output" => output}, index)
       when type in ["function_call_output", "custom_tool_call_output"] and is_list(output),
       do: invalid_image_detail_in(output, "input[#{index}].output")

  # A Chat-style `image_url` part is translated only in a `role: "tool"`
  # item, where it becomes a tool-output `input_image` carrying
  # `image_url.detail`, so only there is that detail checked, under the field
  # the client sent (findings#206 row 206-494).
  defp invalid_input_image_detail(%{"role" => "tool", "content" => content}, index) when is_list(content),
    do: invalid_image_detail_in(content, "input[#{index}].content", true)

  defp invalid_input_image_detail(%{"content" => content}, index) when is_list(content),
    do: invalid_image_detail_in(content, "input[#{index}].content")

  defp invalid_input_image_detail(_item, _index), do: nil

  defp invalid_image_detail_in(parts, path, chat_image_url? \\ false) do
    parts
    |> Enum.with_index()
    |> Enum.find_value(fn
      {%{"type" => "input_image", "detail" => detail}, part_index} when not is_nil(detail) and detail not in @image_details ->
        {:error, invalid_image_detail("#{path}[#{part_index}].detail")}

      {%{"type" => "image_url", "image_url" => %{"detail" => detail}}, part_index} when chat_image_url? and not is_nil(detail) and detail not in @image_details ->
        {:error, invalid_image_detail("#{path}[#{part_index}].image_url.detail")}

      _part ->
        nil
    end)
  end

  @doc """
  Whether `detail` is absent (nil) or one of the provider's `input_image.detail`
  values. Shared with the Chat adapter, which validates `image_url.detail`
  against the same enum under its own field path.
  """
  @spec valid_image_detail?(term()) :: boolean()
  def valid_image_detail?(detail), do: is_nil(detail) or detail in @image_details

  @doc "The Pooler-authored refusal of an image `detail` outside the provider enum, at `param`."
  @spec invalid_image_detail(String.t()) :: Error.reason()
  def invalid_image_detail(param) do
    Error.reason(400, "invalid_value", "invalid value for parameter #{param} (invalid_value); supported values: #{Enum.join(@image_details, ", ")}", param)
  end

  @spec normalize_audio_input_items([map()]) ::
          {:ok, [map()]} | {:error, Error.reason()}
  defp normalize_audio_input_items(input) do
    input
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_audio_input_item(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, input} -> {:ok, Enum.reverse(input)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_audio_input_item(map()) :: {:ok, map()} | {:error, Error.reason()}
  defp normalize_audio_input_item(%{"content" => content} = item) when is_list(content) do
    with {:ok, content} <- normalize_audio_content_parts(content) do
      {:ok, Map.put(item, "content", content)}
    end
  end

  defp normalize_audio_input_item(item), do: {:ok, item}

  @spec normalize_audio_content_parts([map()]) ::
          {:ok, [map()]} | {:error, Error.reason()}
  defp normalize_audio_content_parts(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "input_audio"} = part, {:ok, acc} ->
        case Audio.normalize_part(part) do
          {:ok, part} -> {:cont, {:ok, [part | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      part, {:ok, acc} ->
        {:cont, {:ok, [part | acc]}}
    end)
    |> case do
      {:ok, content} -> {:ok, Enum.reverse(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_input_item(%{"type" => "additional_tools"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => type}) when type not in @known_input_item_types,
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp normalize_input_item(%{"role" => "assistant", "tool_calls" => tool_calls} = item)
       when is_list(tool_calls) do
    with {:ok, parent_metadata_passthrough} <- optional_metadata_passthrough(item) do
      normalize_assistant_tool_calls(
        tool_calls,
        Map.get(item, "metadata"),
        parent_metadata_passthrough
      )
    end
  end

  defp normalize_input_item(%{"role" => "tool"} = item) do
    with {:ok, call_id} <- tool_call_id(item),
         {:ok, output} <- tool_output(item),
         {:ok, metadata_passthrough} <- optional_metadata_passthrough(item) do
      {:ok,
       %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
       |> put_optional_metadata(Map.get(item, "metadata"))
       |> put_optional_metadata_passthrough(metadata_passthrough)}
    end
  end

  defp normalize_input_item(%{"type" => "reasoning", "encrypted_content" => nil} = item) do
    {:ok, Map.delete(item, "encrypted_content")}
  end

  defp normalize_input_item(%{"type" => "reasoning"} = item), do: {:ok, item}

  defp normalize_input_item(
         %{
           "type" => "compaction",
           @metadata_passthrough_key => %{"turn_id" => turn_id}
         } = item
       )
       when is_binary(turn_id) do
    if Map.has_key?(item, "id") do
      {:ok, item}
    else
      {:ok, Map.delete(item, @metadata_passthrough_key)}
    end
  end

  # A compaction id the public surface derived for an upstream item that had
  # none is dropped on replay, so the upstream receives the item as it
  # produced it (findings#254).
  defp normalize_input_item(%{"type" => "compaction", "id" => id, "encrypted_content" => content} = item) do
    if CompactionTrigger.derived_public_compaction_item_id?(id, content),
      do: {:ok, Map.delete(item, "id")},
      else: {:ok, item}
  end

  defp normalize_input_item(%{"type" => "compaction"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "compaction_trigger"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "program"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "program_output"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "shell_call"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "shell_call_output"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "function_call", "status" => status} = item)
       when status in ["completed", "incomplete"],
       do: {:ok, Map.delete(item, "status")}

  defp normalize_input_item(%{"type" => "function_call"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "custom_tool_call", "status" => status} = item)
       when status in ["completed", "incomplete"],
       do: {:ok, Map.delete(item, "status")}

  defp normalize_input_item(%{"type" => "custom_tool_call"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "custom_tool_call_output"} = item), do: {:ok, item}

  defp normalize_input_item(%{"type" => "function_call_output", "output" => output} = item)
       when is_list(output) do
    with {:ok, output} <- normalize_function_call_output_parts(output) do
      {:ok, Map.put(item, "output", output)}
    end
  end

  defp normalize_input_item(%{"type" => "function_call_output"} = item), do: {:ok, item}

  defp normalize_input_item(%{"role" => "assistant", "content" => content} = item)
       when is_binary(content) do
    {:ok,
     item
     |> Map.put("type", "message")
     |> Map.put("content", [%{"type" => "output_text", "text" => content}])}
  end

  defp normalize_input_item(%{"role" => "assistant", "content" => content} = item)
       when is_list(content) do
    with {:ok, content} <- normalize_assistant_replay_content(content) do
      {:ok,
       item
       |> Map.put("type", "message")
       |> Map.put("content", content)}
    end
  end

  defp normalize_input_item(%{"content" => content} = item) when is_binary(content) do
    item =
      item
      |> Map.put("type", "message")
      |> Map.put_new("role", "user")
      |> Map.put("content", [%{"type" => "input_text", "text" => content}])
      |> normalize_message_role()

    {:ok, item}
  end

  defp normalize_input_item(%{"content" => content} = item) when is_list(content) do
    {:ok,
     item
     |> Map.put("type", "message")
     |> Map.put_new("role", "user")
     |> Map.put("content", Enum.map(content, &drop_null_image_detail/1))
     |> normalize_message_role()}
  end

  defp normalize_input_item(%{"role" => _role} = item),
    do: {:ok, item |> Map.put_new("type", "message") |> normalize_message_role()}

  defp normalize_input_item(%{"type" => "input_file"} = item), do: {:ok, item}
  defp normalize_input_item(%{"type" => "item_reference"} = item), do: {:ok, item}

  defp normalize_input_item(%{} = item) do
    if ToolResultShape.tool_result?(item) do
      {:ok, item}
    else
      {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp normalize_assistant_tool_calls(tool_calls, parent_metadata, parent_metadata_passthrough) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize_assistant_tool_call(tool_call, parent_metadata, parent_metadata_passthrough) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_assistant_tool_call(
         %{"function" => %{"name" => name, "arguments" => arguments}} = item,
         parent_metadata,
         parent_metadata_passthrough
       )
       when is_binary(name) and is_binary(arguments) do
    with {:ok, metadata_passthrough} <- optional_metadata_passthrough(item) do
      case clean_string(Map.get(item, "call_id")) || clean_string(Map.get(item, "id")) do
        nil ->
          {:error, Error.invalid_request("input item shape is not translatable", "input")}

        call_id ->
          {:ok,
           %{
             "type" => "function_call",
             "call_id" => call_id,
             "name" => name,
             "arguments" => arguments
           }
           |> put_optional_id(Map.get(item, "response_item_id"))
           |> put_optional_metadata(Map.get(item, "metadata") || parent_metadata)
           |> put_optional_metadata_passthrough(metadata_passthrough || parent_metadata_passthrough)}
      end
    end
  end

  defp normalize_assistant_tool_call(_item, _parent_metadata, _parent_metadata_passthrough),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp normalize_assistant_replay_content(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case normalize_assistant_replay_content_part(part) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, [%{"type" => "output_text", "text" => ""}]}
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_assistant_replay_content_part(%{"type" => "output_text", "text" => text} = part)
       when is_binary(text) do
    case Map.fetch(part, "logprobs") do
      {:ok, logprobs} when is_list(logprobs) -> {:ok, Map.delete(part, "logprobs")}
      {:ok, _logprobs} -> {:ok, part}
      :error -> {:ok, part}
    end
  end

  defp normalize_assistant_replay_content_part(%{
         "type" => "text",
         "annotations" => _annotations
       }),
       do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp normalize_assistant_replay_content_part(%{"type" => "text", "text" => text})
       when is_binary(text) do
    {:ok, %{"type" => "output_text", "text" => text}}
  end

  defp normalize_assistant_replay_content_part(%{"type" => "thinking", "thinking" => thinking})
       when is_binary(thinking) do
    {:ok, nil}
  end

  defp normalize_assistant_replay_content_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp put_optional_id(item, value) do
    case clean_string(value) do
      nil -> item
      id -> Map.put(item, "id", id)
    end
  end

  defp put_optional_metadata(item, metadata) when is_map(metadata),
    do: Map.put(item, "metadata", metadata)

  defp put_optional_metadata(item, _metadata), do: item

  defp optional_metadata_passthrough(%{@metadata_passthrough_key => nil}), do: {:ok, nil}

  defp optional_metadata_passthrough(%{@metadata_passthrough_key => metadata})
       when is_map(metadata),
       do: {:ok, metadata}

  defp optional_metadata_passthrough(%{@metadata_passthrough_key => _metadata}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp optional_metadata_passthrough(_item), do: {:ok, nil}

  defp put_optional_metadata_passthrough(item, metadata) when is_map(metadata),
    do: Map.put(item, @metadata_passthrough_key, metadata)

  defp put_optional_metadata_passthrough(item, _metadata), do: item

  defp input_text_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp tool_call_id(item) do
    case clean_string(Map.get(item, "tool_call_id")) || clean_string(Map.get(item, "call_id")) do
      nil -> {:error, Error.invalid_request("input item shape is not translatable", "input")}
      call_id -> {:ok, call_id}
    end
  end

  defp normalize_function_call_output_parts(output) do
    output
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "input_image"} = part, {:ok, acc} ->
        case normalize_tool_output_part(part) do
          {:ok, part} -> {:cont, {:ok, [part | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      part, {:ok, acc} ->
        {:cont, {:ok, [part | acc]}}
    end)
    |> case do
      {:ok, output} -> {:ok, Enum.reverse(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_output(%{"content" => content}) when is_binary(content), do: {:ok, content}

  defp tool_output(%{"content" => content}) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case normalize_tool_output_part(part) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_output(%{"content" => nil}), do: {:ok, ""}

  defp tool_output(%{"content" => %{"output" => output}}) when is_binary(output),
    do: {:ok, output}

  defp tool_output(%{"content" => _content}),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp tool_output(_item), do: {:ok, ""}

  defp normalize_tool_output_part(part) when is_binary(part) do
    {:ok, %{"type" => "input_text", "text" => part}}
  end

  defp normalize_tool_output_part(%{"type" => type, "text" => text} = part)
       when type in ["text", "input_text"] and is_binary(text) do
    {:ok,
     %{"type" => "input_text", "text" => text}
     |> maybe_put_prompt_cache_breakpoint(part)}
  end

  defp normalize_tool_output_part(%{"type" => "input_image", "image_url" => image_url} = part)
       when is_binary(image_url) do
    {:ok,
     %{"type" => "input_image", "image_url" => image_url}
     |> maybe_put_image_detail(part)
     |> maybe_put_prompt_cache_breakpoint(part)}
  end

  defp normalize_tool_output_part(%{"type" => "input_image", "file_id" => file_id} = part)
       when is_binary(file_id) and file_id != "" do
    {:ok,
     %{"type" => "input_image", "file_id" => file_id}
     |> maybe_put_image_detail(part)
     |> maybe_put_prompt_cache_breakpoint(part)}
  end

  defp normalize_tool_output_part(%{"type" => "image_url"} = part) do
    case Map.get(part, "image_url") do
      %{"url" => image_url} = image when is_binary(image_url) ->
        {:ok, %{"type" => "input_image", "image_url" => image_url} |> maybe_put_image_detail(image)}

      image_url when is_binary(image_url) ->
        {:ok, %{"type" => "input_image", "image_url" => image_url}}

      _value ->
        {:error, Error.invalid_request("input item shape is not translatable", "input")}
    end
  end

  defp normalize_tool_output_part(_part),
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}

  defp maybe_put_prompt_cache_breakpoint(acc, %{
         "prompt_cache_breakpoint" => breakpoint
       }),
       do: Map.put(acc, "prompt_cache_breakpoint", breakpoint)

  defp maybe_put_prompt_cache_breakpoint(acc, _part), do: acc

  # A tool-output image keeps its `detail` as the native client sends it on a
  # Full model; the Lite payload normalizer removes it later. Only an enum
  # value reaches here (`validate_input_image_details/1`), and a null detail
  # stays absent (findings#206 row 206-476).
  defp maybe_put_image_detail(acc, %{"detail" => detail}) when is_binary(detail),
    do: Map.put(acc, "detail", detail)

  defp maybe_put_image_detail(acc, _part), do: acc

  # A message image passes through as sent except for a null `detail`, which
  # is absent here as on a tool-output image: the Codex backend accepts null
  # (probed 2026-09-24) but the native client never serializes one
  # (findings#206 row 206-488).
  defp drop_null_image_detail(%{"type" => "input_image", "detail" => nil} = part),
    do: Map.delete(part, "detail")

  defp drop_null_image_detail(part), do: part

  defp normalize_message_role(%{"type" => "message", "role" => "system"} = item),
    do: Map.put(item, "role", "developer")

  defp normalize_message_role(item), do: item
end
