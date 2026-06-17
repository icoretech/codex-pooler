defmodule CodexPooler.Gateway.Payloads.ToolSchemaLowering do
  @moduledoc false

  @schema_list_keys ~w(anyOf oneOf allOf)
  @definition_keys ~w($defs definitions)

  @spec lower_non_strict_function_tools(map()) :: map()
  def lower_non_strict_function_tools(%{"tools" => tools} = payload) when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &lower_tool/1))
  end

  def lower_non_strict_function_tools(payload), do: payload

  defp lower_tool(%{"type" => "function", "function" => %{} = function} = tool) do
    if strict_function_tool?(function, tool) do
      tool
    else
      Map.put(tool, "function", lower_function_parameters(function))
    end
  end

  defp lower_tool(%{"type" => "function"} = tool) do
    if strict_function_tool?(tool, tool), do: tool, else: lower_function_parameters(tool)
  end

  defp lower_tool(%{"type" => "namespace", "tools" => tools} = tool) when is_list(tools) do
    Map.put(tool, "tools", Enum.map(tools, &lower_tool/1))
  end

  defp lower_tool(tool), do: tool

  defp strict_function_tool?(function, tool) do
    Map.get(function, "strict") == true or Map.get(tool, "strict") == true
  end

  defp lower_function_parameters(%{"parameters" => parameters} = function)
       when is_map(parameters) or is_boolean(parameters) do
    Map.put(function, "parameters", lower_function_parameters_schema(parameters))
  end

  defp lower_function_parameters(function), do: function

  defp lower_function_parameters_schema(schema) do
    schema
    |> lower_schema()
    |> ensure_function_parameters_object()
  end

  defp lower_schema(schema) when is_boolean(schema), do: %{}

  defp lower_schema(%{} = schema) do
    schema
    |> Enum.reduce(%{}, fn {key, value}, acc -> lower_schema_key(acc, to_string(key), value) end)
    |> maybe_put_const_enum(schema)
    |> infer_schema_type()
    |> ensure_object_properties()
    |> ensure_array_items()
  end

  defp lower_schema(_schema), do: %{}

  defp lower_schema_key(acc, "$ref", value) when is_binary(value), do: Map.put(acc, "$ref", value)

  defp lower_schema_key(acc, "description", value) when is_binary(value),
    do: Map.put(acc, "description", value)

  defp lower_schema_key(acc, "type", value) do
    if valid_type?(value), do: Map.put(acc, "type", value), else: acc
  end

  defp lower_schema_key(acc, "enum", value) when is_list(value), do: Map.put(acc, "enum", value)

  defp lower_schema_key(acc, "required", value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: Map.put(acc, "required", value), else: acc
  end

  defp lower_schema_key(acc, "properties", value) when is_map(value) do
    properties =
      Map.new(value, fn {name, schema} ->
        {to_string(name), lower_schema(schema)}
      end)

    Map.put(acc, "properties", properties)
  end

  defp lower_schema_key(acc, "items", value) when is_map(value) or is_boolean(value),
    do: Map.put(acc, "items", lower_schema(value))

  defp lower_schema_key(acc, "items", value) when is_list(value),
    do: Map.put(acc, "items", Enum.map(value, &lower_schema/1))

  defp lower_schema_key(acc, "additionalProperties", value) when is_boolean(value),
    do: Map.put(acc, "additionalProperties", value)

  defp lower_schema_key(acc, "additionalProperties", value) when is_map(value),
    do: Map.put(acc, "additionalProperties", lower_schema(value))

  defp lower_schema_key(acc, key, value) when key in @schema_list_keys and is_list(value),
    do: Map.put(acc, key, Enum.map(value, &lower_schema/1))

  defp lower_schema_key(acc, key, value) when key in @definition_keys and is_map(value) do
    definitions =
      Map.new(value, fn {name, schema} ->
        {to_string(name), lower_schema(schema)}
      end)

    Map.put(acc, key, definitions)
  end

  defp lower_schema_key(acc, _key, _value), do: acc

  defp maybe_put_const_enum(acc, schema) do
    if Map.has_key?(schema, "const") or Map.has_key?(schema, :const) do
      Map.put(acc, "enum", [Map.get(schema, "const", Map.get(schema, :const))])
    else
      acc
    end
  end

  defp infer_schema_type(%{"$ref" => _ref} = schema), do: schema

  defp infer_schema_type(%{} = schema) do
    cond do
      Map.has_key?(schema, "type") ->
        schema

      Map.has_key?(schema, "properties") or Map.has_key?(schema, "required") or
          Map.has_key?(schema, "additionalProperties") ->
        Map.put(schema, "type", "object")

      Map.has_key?(schema, "items") ->
        Map.put(schema, "type", "array")

      true ->
        schema
    end
  end

  defp ensure_function_parameters_object(%{"$ref" => _ref} = schema), do: schema

  defp ensure_function_parameters_object(%{} = schema) do
    schema
    |> Map.put_new("type", "object")
    |> ensure_object_properties()
    |> ensure_array_items()
  end

  defp ensure_object_properties(%{} = schema) do
    if type_includes?(Map.get(schema, "type"), "object") do
      Map.put_new(schema, "properties", %{})
    else
      schema
    end
  end

  defp ensure_array_items(%{} = schema) do
    if type_includes?(Map.get(schema, "type"), "array") do
      Map.put_new(schema, "items", %{})
    else
      schema
    end
  end

  defp valid_type?(value) when is_binary(value), do: String.trim(value) != ""

  defp valid_type?(value) when is_list(value),
    do: value != [] and Enum.all?(value, &valid_type?/1)

  defp valid_type?(_value), do: false

  defp type_includes?(type, expected) when is_binary(type), do: type == expected
  defp type_includes?(types, expected) when is_list(types), do: expected in types
  defp type_includes?(_type, _expected), do: false
end
