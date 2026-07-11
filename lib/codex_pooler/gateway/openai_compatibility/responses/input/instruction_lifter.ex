defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.InstructionLifter do
  @moduledoc false

  def lift(%{"input" => input} = payload) when is_list(input) do
    {input, instruction_texts} =
      Enum.reduce(input, {[], []}, fn item, {items, instruction_texts} ->
        case lift_instruction_item(item) do
          {:ok, texts, nil} ->
            {items, Enum.reverse(texts, instruction_texts)}

          {:ok, texts, residual_item} ->
            {[residual_item | items], Enum.reverse(texts, instruction_texts)}

          :ignore ->
            {[item | items], instruction_texts}
        end
      end)

    payload
    |> Map.put("input", Enum.reverse(input))
    |> put_lifted_instruction_text(Enum.reverse(instruction_texts))
  end

  def lift(payload), do: payload

  defp lift_instruction_item(%{"type" => "message", "role" => role, "content" => content} = item)
       when role in ["system", "developer"] do
    {texts, preserved_content} = lift_instruction_content(content)

    residual_item =
      case preserved_content do
        [] -> nil
        content -> item |> Map.put("role", "developer") |> Map.put("content", content)
      end

    {:ok, texts, residual_item}
  end

  defp lift_instruction_item(_item), do: :ignore

  defp lift_instruction_content(content) when is_binary(content) do
    case clean_string(content) do
      nil -> {[], []}
      text -> {[text], []}
    end
  end

  defp lift_instruction_content(content) when is_list(content) do
    content
    |> Enum.reduce({[], []}, fn part, {texts, preserved_content} ->
      case instruction_content_text(part) do
        {:ok, nil} -> {texts, preserved_content}
        {:ok, text} -> {[text | texts], preserved_content}
        :error -> {texts, [part | preserved_content]}
      end
    end)
    |> then(fn {texts, preserved_content} ->
      {Enum.reverse(texts), Enum.reverse(preserved_content)}
    end)
  end

  defp lift_instruction_content(content), do: {[], [content]}

  defp instruction_content_text(%{"prompt_cache_breakpoint" => _breakpoint}), do: :error

  defp instruction_content_text(%{"type" => type, "text" => text})
       when type in ["input_text", "text"] and is_binary(text) do
    {:ok, clean_string(text)}
  end

  defp instruction_content_text(text) when is_binary(text), do: {:ok, clean_string(text)}
  defp instruction_content_text(_part), do: :error

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp put_lifted_instruction_text(payload, []), do: payload

  defp put_lifted_instruction_text(payload, instruction_texts) do
    existing_text =
      payload
      |> Map.get("instructions")
      |> clean_string()

    instructions =
      [existing_text | instruction_texts]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if instructions == "" do
      payload
    else
      Map.put(payload, "instructions", instructions)
    end
  end
end
