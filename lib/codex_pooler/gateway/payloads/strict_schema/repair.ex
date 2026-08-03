defmodule CodexPooler.Gateway.Payloads.StrictSchema.Repair do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @opaque_keys ~w($ref anyOf oneOf allOf)
  @object_evidence_keys ~w(properties required additionalProperties)

  @type validator :: (map(), String.t(), map() -> :ok | {:error, Error.reason()})

  @spec repair(map(), validator()) :: {:ok, map()}
  def repair(%{"tools" => tools} = payload, validator) when is_list(tools) do
    repaired_tools =
      tools
      |> Enum.with_index()
      |> Enum.map(fn {tool, index} -> repair_tool(tool, index, validator) end)

    {:ok, Map.put(payload, "tools", repaired_tools)}
  end

  def repair(payload, _validator), do: {:ok, payload}

  defp repair_tool(%{"type" => "function"} = tool, index, validator) do
    repair_function_tool(tool, "tools.#{index}.parameters", validator)
  end

  defp repair_tool(%{"type" => "namespace", "tools" => tools} = tool, index, validator)
       when is_list(tools) do
    repaired_tools =
      tools
      |> Enum.with_index()
      |> Enum.map(fn {child_tool, child_index} ->
        path = "tools.#{index}.tools.#{child_index}.parameters"
        repair_function_tool(child_tool, path, validator)
      end)

    Map.put(tool, "tools", repaired_tools)
  end

  defp repair_tool(tool, _index, _validator), do: tool

  defp repair_function_tool(
         %{"type" => "function", "name" => name, "parameters" => parameters} = tool,
         path,
         validator
       )
       when is_binary(name) and name != "" and is_map(parameters) do
    if Map.get(tool, "strict") == true do
      repaired_parameters = repair_schema(parameters, 0, path, parameters, validator)
      Map.put(tool, "parameters", repaired_parameters)
    else
      tool
    end
  end

  defp repair_function_tool(tool, _path, _validator), do: tool

  defp repair_schema(schema, depth, path, root_schema, validator) do
    if opaque?(schema) do
      schema
    else
      schema
      |> repair_properties(depth, path, root_schema, validator)
      |> repair_items(depth, path, root_schema, validator)
      |> maybe_repair_type(depth, path, root_schema, validator)
    end
  end

  defp repair_properties(schema, depth, path, root_schema, validator) do
    case Map.get(schema, "properties") do
      properties when is_map(properties) ->
        repaired_properties =
          Map.new(properties, fn {name, child_schema} ->
            {name, repair_property(child_schema, depth, path, name, root_schema, validator)}
          end)

        Map.put(schema, "properties", repaired_properties)

      _properties ->
        schema
    end
  end

  defp repair_property(child_schema, depth, path, name, root_schema, validator)
       when is_map(child_schema) do
    repair_schema(
      child_schema,
      depth + 1,
      path <> ".properties." <> name,
      root_schema,
      validator
    )
  end

  defp repair_property(child_schema, _depth, _path, _name, _root_schema, _validator),
    do: child_schema

  defp repair_items(schema, depth, path, root_schema, validator) do
    case Map.get(schema, "items") do
      items when is_map(items) ->
        Map.put(
          schema,
          "items",
          repair_schema(items, depth + 1, path <> ".items", root_schema, validator)
        )

      _items ->
        schema
    end
  end

  defp maybe_repair_type(schema, depth, path, root_schema, validator) do
    if depth >= 1 and not Map.has_key?(schema, "type") do
      schema
      |> inferred_type()
      |> maybe_insert_type(schema, path, root_schema, validator)
    else
      schema
    end
  end

  defp inferred_type(schema) do
    object_evidence? = Enum.any?(@object_evidence_keys, &Map.has_key?(schema, &1))
    array_evidence? = Map.has_key?(schema, "items")

    case {object_evidence?, array_evidence?} do
      {true, false} -> if strict_object_evidence?(schema), do: "object"
      {false, true} -> if is_map(Map.get(schema, "items")), do: "array"
      _evidence -> nil
    end
  end

  defp strict_object_evidence?(schema) do
    properties = Map.get(schema, "properties")
    required = Map.get(schema, "required")

    is_map(properties) and unique_string_list?(required) and
      MapSet.equal?(MapSet.new(Map.keys(properties)), MapSet.new(required)) and
      Map.get(schema, "additionalProperties") == false
  end

  defp unique_string_list?(values) when is_list(values) do
    Enum.all?(values, &is_binary/1) and MapSet.size(MapSet.new(values)) == length(values)
  end

  defp unique_string_list?(_values), do: false

  defp maybe_insert_type(nil, schema, _path, _root_schema, _validator), do: schema

  defp maybe_insert_type(type, schema, path, root_schema, validator) do
    candidate = Map.put(schema, "type", type)

    case validator.(candidate, path, root_schema) do
      :ok -> candidate
      {:error, _reason} -> schema
    end
  end

  defp opaque?(schema), do: Enum.any?(@opaque_keys, &Map.has_key?(schema, &1))
end
