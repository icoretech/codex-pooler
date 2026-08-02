defmodule CodexPooler.Gateway.Payloads.ToolSchemaLowering do
  @moduledoc false

  @schema_list_keys ~w(anyOf oneOf allOf)
  @definition_keys ~w($defs definitions)

  @spec lower_non_strict_function_tools(map()) :: map()
  def lower_non_strict_function_tools(%{"tools" => tools} = payload) when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &lower_tool/1))
  end

  def lower_non_strict_function_tools(payload), do: payload

  @spec lower_backend_non_strict_function_tools(map()) :: map()
  def lower_backend_non_strict_function_tools(%{"tools" => tools} = payload)
      when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &lower_backend_tool/1))
  end

  def lower_backend_non_strict_function_tools(payload), do: payload

  defp lower_backend_tool(%{"type" => "namespace"} = tool), do: tool
  defp lower_backend_tool(tool), do: lower_tool(tool)

  defp lower_tool(%{"type" => "function", "function" => %{} = function} = tool) do
    function =
      if strict_function_tool?(function, tool) do
        repair_strict_function_parameters(function)
      else
        lower_function_parameters(function)
      end

    Map.put(tool, "function", function)
  end

  defp lower_tool(%{"type" => "function"} = tool) do
    if strict_function_tool?(tool, tool) do
      repair_strict_function_parameters(tool)
    else
      lower_function_parameters(tool)
    end
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

  defp repair_strict_function_parameters(%{"parameters" => parameters} = function)
       when is_map(parameters) do
    Map.put(function, "parameters", repair_strict_schema_types(parameters))
  end

  defp repair_strict_function_parameters(function), do: function

  defp repair_strict_schema_types(%{} = schema) do
    schema
    |> update_existing("properties", &repair_strict_named_schemas/1)
    |> update_existing("items", &repair_strict_schema_value/1)
    |> update_existing("additionalProperties", &repair_strict_schema_value/1)
    |> repair_strict_schema_lists()
    |> update_existing("$defs", &repair_strict_named_schemas/1)
    |> update_existing("definitions", &repair_strict_named_schemas/1)
    |> infer_repairable_schema_type()
  end

  defp repair_strict_schema_types(schema), do: schema

  defp repair_strict_named_schemas(schemas) when is_map(schemas) do
    Map.new(schemas, fn {name, schema} -> {name, repair_strict_schema_types(schema)} end)
  end

  defp repair_strict_named_schemas(schemas), do: schemas

  defp repair_strict_schema_value(schema) when is_map(schema),
    do: repair_strict_schema_types(schema)

  defp repair_strict_schema_value(schemas) when is_list(schemas),
    do: Enum.map(schemas, &repair_strict_schema_types/1)

  defp repair_strict_schema_value(schema), do: schema

  defp update_existing(schema, key, fun) do
    if Map.has_key?(schema, key), do: Map.update!(schema, key, fun), else: schema
  end

  defp repair_strict_schema_lists(schema) do
    Enum.reduce(@schema_list_keys, schema, fn key, acc ->
      update_existing(acc, key, &repair_strict_schema_value/1)
    end)
  end

  defp infer_repairable_schema_type(%{"$ref" => _ref} = schema), do: schema

  defp infer_repairable_schema_type(%{} = schema) do
    type = Map.get(schema, "type")

    if is_list(type) or (is_binary(type) and String.trim(type) != "") do
      schema
    else
      case schema_structure_type(schema) do
        :object -> Map.put(schema, "type", "object")
        :array -> Map.put(schema, "type", "array")
        :ambiguous -> schema
        :unknown -> schema
      end
    end
  end

  defp schema_structure_type(schema) do
    object? =
      Map.has_key?(schema, "properties") or Map.has_key?(schema, "required") or
        Map.has_key?(schema, "additionalProperties")

    array? = Map.has_key?(schema, "items")

    case {object?, array?} do
      {true, false} -> :object
      {false, true} -> :array
      {true, true} -> :ambiguous
      {false, false} -> :unknown
    end
  end

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
