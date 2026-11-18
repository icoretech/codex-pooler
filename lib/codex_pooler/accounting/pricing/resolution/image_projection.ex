defmodule CodexPooler.Accounting.PricingResolution.ImageProjection do
  @moduledoc """
  Creates an estimation-only copy of supported image-bearing inputs.

  Returns the count of semantic image occurrences without retaining media
  references separately. This copy must never be sent upstream.
  """

  alias CodexPooler.Gateway.Payloads.ToolResultShape

  @native_image_endpoints ["/backend-api/codex/images/edits", "/backend-api/codex/images/generations"]
  @message_roles [nil, "user", "assistant", "system", "developer", "tool"]

  @type context :: %{optional(:source_endpoint) => String.t()}

  @spec project(map(), context()) :: {map(), non_neg_integer()}
  def project(payload, context) when is_map(payload) and is_map(context) do
    {payload, image_count} = project_field(payload, :input, 0, &project_input/2)
    {payload, image_count} = project_field(payload, :tools, image_count, &project_tools/2)

    {payload, image_count} =
      if context[:source_endpoint] in @native_image_endpoints do
        project_field(payload, :images, image_count, &project_list(&1, &2, fn image, acc -> project_locators(image, [:image_url], acc) end))
      else
        {payload, image_count}
      end

    {payload, image_count}
  end

  defp project_input(input, image_count),
    do: project_list(input, image_count, &project_item/2)

  defp project_item(item, image_count) when is_map(item) do
    cond do
      tool_result?(item) ->
        {item, image_count} = project_field(item, :output, image_count, &project_output/2)
        project_field(item, :result, image_count, &project_output/2)

      value(item, :type) in [nil, "message"] and value(item, :role) in @message_roles ->
        project_field(item, :content, image_count, &project_parts/2)

      value(item, :type) == "image_generation_call" ->
        project_field(item, :result, image_count, &project_generated_image/2)

      true ->
        {item, image_count}
    end
  end

  defp project_item(item, image_count), do: {item, image_count}

  # A replayed hosted image generation carries the generated image as base64 in `result`; read as JSON text, a
  # 1.2 MB item reserved about 300k input tokens. It is one semantic image, estimated like an `input_image` with the
  # fixed allowance (Codex budgets one resized image for it too). `gpt-6-luna` billed the replayed bytes as nothing
  # (direct probe 2026-11-18), so the allowance only over-reserves, and settlement uses the reported usage.
  defp project_generated_image(result, image_count) when is_binary(result) do
    if String.trim(result) == "", do: {result, image_count}, else: {"", image_count + 1}
  end

  defp project_generated_image(result, image_count), do: {result, image_count}

  defp tool_result?(item) do
    # Match the gateway's semantic contract while accommodating internal atom keys.
    [:type, :call_id, :name, :output, :result]
    |> Enum.reduce(%{}, fn key, normalized ->
      case fetch(item, key) do
        {:ok, value} -> Map.put(normalized, Atom.to_string(key), value)
        :error -> normalized
      end
    end)
    |> ToolResultShape.tool_result?()
  end

  defp project_output(output, image_count) when is_map(output),
    do: project_field(output, :content, image_count, &project_parts/2)

  defp project_output(output, image_count), do: project_parts(output, image_count)

  defp project_parts(parts, image_count),
    do: project_list(parts, image_count, &project_part/2)

  defp project_part(part, image_count) when is_map(part) do
    if value(part, :type) == "input_image" do
      project_locators(part, [:image_url, :file_id], image_count)
    else
      {part, image_count}
    end
  end

  defp project_part(part, image_count), do: {part, image_count}

  defp project_tools(tools, image_count),
    do: project_list(tools, image_count, &project_tool/2)

  defp project_tool(tool, image_count) when is_map(tool) do
    if value(tool, :type) == "image_generation" do
      project_field(tool, :input_image_mask, image_count, &project_locators(&1, [:image_url], &2))
    else
      {tool, image_count}
    end
  end

  defp project_tool(tool, image_count), do: {tool, image_count}

  defp project_locators(image, fields, image_count) when is_map(image) do
    keys = Enum.flat_map(fields, &[Atom.to_string(&1), &1])

    if Enum.any?(keys, &nonblank_binary?(Map.get(image, &1))) do
      {Enum.reduce(keys, image, &neutralize_locator/2), image_count + 1}
    else
      {image, image_count}
    end
  end

  defp project_locators(image, _fields, image_count), do: {image, image_count}

  defp nonblank_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_binary?(_value), do: false

  defp neutralize_locator(key, image) do
    if is_binary(Map.get(image, key)), do: Map.put(image, key, ""), else: image
  end

  defp project_list(items, image_count, projector) when is_list(items), do: Enum.map_reduce(items, image_count, projector)
  defp project_list(items, image_count, _projector), do: {items, image_count}

  defp project_field(map, key, image_count, projector) do
    Enum.reduce([Atom.to_string(key), key], {map, image_count}, fn field, {current, acc} ->
      case Map.fetch(current, field) do
        {:ok, original} ->
          {projected, acc} = projector.(original, acc)
          {Map.put(current, field, projected), acc}

        :error ->
          {current, acc}
      end
    end)
  end

  defp value(map, key), do: Map.get(map, Atom.to_string(key), Map.get(map, key))

  defp fetch(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      :error -> Map.fetch(map, key)
      found -> found
    end
  end
end
