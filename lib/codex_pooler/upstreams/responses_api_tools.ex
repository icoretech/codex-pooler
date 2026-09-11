defmodule CodexPooler.Upstreams.ResponsesAPITools do
  @moduledoc """
  Translate native additional_tools, namespaces and custom inputs to JSON functions.
  The reverse map is request-local and is never persisted with request metadata.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  def prepare(payload) do
    input = Map.get(payload, "input", [])

    declarations =
      if is_list(input),
        do: Enum.filter(input, &match?(%{"type" => "additional_tools"}, &1)),
        else: []

    tools =
      case Map.fetch(payload, "tools") do
        {:ok, tools} -> tools || []
        :error -> Enum.flat_map(declarations, &Map.get(&1, "tools", []))
      end

    pairs =
      tools
      |> Enum.flat_map(&lower_tool(&1, nil))
      |> Enum.reverse()
      |> Enum.uniq_by(fn {tool, _binding} -> tool["name"] end)
      |> Enum.reverse()

    bindings = Map.new(pairs, fn {tool, binding} -> {tool["name"], binding} end)

    payload =
      if pairs == [], do: payload, else: Map.put(payload, "tools", Enum.map(pairs, &elem(&1, 0)))

    payload =
      if is_list(input),
        do: Map.put(payload, "input", Enum.flat_map(input, &lower_item/1)),
        else: payload

    {lower_choice(payload), bindings}
  end

  defp lower_tool(%{"type" => "namespace", "name" => namespace, "tools" => tools}, _parent),
    do: Enum.flat_map(tools, &lower_tool(&1, namespace))

  defp lower_tool(%{"type" => type, "name" => name} = tool, namespace)
       when type in ["function", "custom"] do
    binding = %{name: name, namespace: namespace, custom?: type == "custom"}
    api_name = api_name(name, namespace)
    lowered = if type == "custom", do: custom_function(tool), else: tool
    [{lowered |> Map.put("name", api_name) |> Map.delete("namespace"), binding}]
  end

  defp lower_tool(_unsupported_hosted_tool, _namespace), do: []

  defp custom_function(tool) do
    %{
      "type" => "function",
      "description" =>
        "Supply the exact custom-tool source as the input string.\n" <>
          Map.get(tool, "description", ""),
      "parameters" => %{
        "type" => "object",
        "properties" => %{"input" => %{"type" => "string"}},
        "required" => ["input"],
        "additionalProperties" => false
      }
    }
  end

  defp api_name(name, nil), do: name

  defp api_name(name, namespace) do
    digest =
      :crypto.hash(:sha256, JSON.encode!([namespace, name]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    stem =
      Regex.replace(~r/[^a-zA-Z0-9_-]/, namespace <> "__" <> name, "_") |> String.slice(0, 110)

    stem <> "_" <> digest
  end

  defp lower_choice(
         %{"tool_choice" => %{"type" => "function", "name" => name} = choice} = payload
       ) do
    Map.put(
      payload,
      "tool_choice",
      choice |> Map.put("name", api_name(name, choice["namespace"])) |> Map.delete("namespace")
    )
  end

  defp lower_choice(payload), do: payload

  defp lower_item(%{"type" => "additional_tools"}), do: []

  defp lower_item(%{"type" => "custom_tool_call", "name" => name} = item) do
    [
      item
      |> Map.put("type", "function_call")
      |> Map.put("name", api_name(name, item["namespace"]))
      |> Map.put("arguments", JSON.encode!(%{"input" => item["input"]}))
      |> Map.drop(["input", "namespace"])
    ]
  end

  defp lower_item(%{"type" => "custom_tool_call_output"} = item),
    do: [item |> Map.put("type", "function_call_output") |> Map.drop(["name", "namespace"])]

  defp lower_item(%{"type" => "function_call", "name" => name} = item),
    do: [item |> Map.put("name", api_name(name, item["namespace"])) |> Map.delete("namespace")]

  defp lower_item(item), do: [item]

  def response(%Req.Response{body: body} = response, bindings)
      when is_binary(body) and map_size(bindings) > 0 do
    case JSON.decode(body) do
      {:ok, %{} = decoded} ->
        %{response | body: JSON.encode!(restore_response(decoded, bindings))}

      _other ->
        response
    end
  end

  def response(response, _bindings), do: response

  defp restore_response(%{"output" => output} = response, bindings) when is_list(output),
    do: Map.put(response, "output", Enum.map(output, &restore_item(&1, bindings)))

  defp restore_response(response, _bindings), do: response

  defp restore_item(%{"type" => "function_call", "name" => name} = item, bindings) do
    case Map.get(bindings, name) do
      nil ->
        item

      binding ->
        item = put_name(item, binding)

        if binding.custom?,
          do:
            item
            |> Map.put("type", "custom_tool_call")
            |> Map.put("input", custom_input(item["arguments"]))
            |> Map.delete("arguments"),
          else: item
    end
  end

  defp restore_item(item, _bindings), do: item

  defp put_name(item, binding) do
    item = Map.put(item, "name", binding.name)

    if binding.namespace,
      do: Map.put(item, "namespace", binding.namespace),
      else: Map.delete(item, "namespace")
  end

  defp custom_input(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, %{"input" => input}} when is_binary(input) -> input
      _invalid -> ""
    end
  end

  defp custom_input(_arguments), do: ""

  def stream(data, bindings, state \\ nil) do
    state =
      state ||
        %{
          sse: StreamProtocol.new_sse_block_state(),
          items: %{},
          sequence: 0,
          completed_response: nil
        }

    {blocks, sse} = StreamProtocol.complete_sse_blocks(state.sse, data, bounded?: true)

    {parts, state} =
      Enum.map_reduce(blocks, %{state | sse: sse}, &translate_block(&1, bindings, &2))

    {IO.iodata_to_binary(parts), state}
  end

  defp translate_block(block, bindings, state) do
    data =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(String.replace_prefix(&1, "data:", "") |> String.trim_leading()))

    case JSON.decode(data) do
      {:ok, %{} = event} ->
        {events, state} = translate_event(event, bindings, state)

        Enum.map_reduce(events, state, fn event, acc ->
          event = Map.put(event, "sequence_number", acc.sequence)

          {"event: " <> event["type"] <> "\ndata: " <> JSON.encode!(event) <> "\n\n",
           %{acc | sequence: acc.sequence + 1}}
        end)

      _other ->
        {block <> "\n\n", state}
    end
  end

  defp translate_event(
         %{"type" => type, "item" => %{"name" => name, "id" => id} = item} = event,
         bindings,
         state
       )
       when type in ["response.output_item.added", "response.output_item.done"] do
    state =
      case Map.get(bindings, name) do
        nil -> state
        binding -> %{state | items: Map.put(state.items, id, binding)}
      end

    {[Map.put(event, "item", restore_item(item, bindings))], state}
  end

  defp translate_event(%{"type" => type, "item_id" => id} = event, _bindings, state)
       when type in [
              "response.function_call_arguments.delta",
              "response.function_call_arguments.done"
            ] do
    case Map.get(state.items, id) do
      %{custom?: true} when type == "response.function_call_arguments.delta" ->
        {[], state}

      %{custom?: true} ->
        input = custom_input(event["arguments"])
        base = Map.drop(event, ["arguments", "name"])

        {[
           %{base | "type" => "response.custom_tool_call_input.delta"} |> Map.put("delta", input),
           %{base | "type" => "response.custom_tool_call_input.done"} |> Map.put("input", input)
         ], state}

      _ordinary ->
        {[event], state}
    end
  end

  defp translate_event(%{"response" => %{} = response} = event, bindings, state) do
    response = restore_response(response, bindings)

    state =
      if event["type"] == "response.completed",
        do: %{state | completed_response: response},
        else: state

    {[Map.put(event, "response", response)], state}
  end

  defp translate_event(event, _bindings, state), do: {[event], state}
end
