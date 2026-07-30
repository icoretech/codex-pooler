defmodule CodexPooler.Gateway.Payloads.ToolResultShape do
  @moduledoc false

  @type item :: %{type: String.t(), call_id: String.t()}

  @spec items(term()) :: [item()]
  def items(input), do: input |> collect_items([]) |> Enum.reverse()

  @spec any?(term()) :: boolean()
  def any?(%{} = item),
    do: tool_result?(item) or Enum.any?(Map.values(item), &any?/1)

  def any?(items) when is_list(items), do: Enum.any?(items, &any?/1)
  def any?(_input), do: false

  @spec tool_result?(term()) :: boolean()
  def tool_result?(%{} = item) do
    is_binary(call_id(item)) and tool_result_type?(Map.get(item, "type"), item)
  end

  def tool_result?(_item), do: false

  defp tool_result_type?(type, item) when is_binary(type) do
    normalized = type |> String.trim() |> String.downcase()

    String.ends_with?(normalized, "_output") or Map.has_key?(item, "output") or
      Map.has_key?(item, "result")
  end

  defp tool_result_type?(_type, item),
    do: Map.has_key?(item, "output") or Map.has_key?(item, "result")

  defp call_id(%{} = item), do: clean_string(Map.get(item, "call_id"))

  defp collect_items(%{} = item, acc) do
    acc =
      if tool_result?(item) do
        [
          %{
            type: clean_string(Map.get(item, "type")) || "unknown_tool_output",
            call_id: call_id(item)
          }
          | acc
        ]
      else
        acc
      end

    Enum.reduce(Map.values(item), acc, &collect_items/2)
  end

  defp collect_items(items, acc) when is_list(items),
    do: Enum.reduce(items, acc, &collect_items/2)

  defp collect_items(_input, acc), do: acc

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil
end
