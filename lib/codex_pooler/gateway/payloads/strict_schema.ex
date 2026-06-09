defmodule CodexPooler.Gateway.Payloads.StrictSchema do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @error_code "invalid_json_schema"
  @error_message_prefix "strict json_schema"
  @function_error_code "invalid_function_parameters"

  @spec validate(term()) :: :ok | {:error, Error.reason()}
  def validate(payload) when is_map(payload) do
    payload
    |> strict_schema_targets()
    |> Enum.reduce_while(:ok, fn target, _acc ->
      case validate_target(target) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def validate(_payload), do: :ok

  defp strict_schema_targets(payload) do
    [text_format_target(payload), response_format_target(payload)]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(function_tool_targets(payload))
  end

  defp function_tool_targets(%{"tools" => tools}) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce([], fn {tool, index}, acc ->
      case function_tool_target(tool, index) do
        nil -> acc
        targets when is_list(targets) -> targets ++ acc
        target -> [target | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp function_tool_targets(_payload), do: []

  defp function_tool_target(%{"type" => "function", "function" => function} = tool, index)
       when is_map(function) do
    name = Map.get(function, "name")
    parameters = Map.get(function, "parameters")

    if strict_function_tool?(name, function, tool) do
      {parameters, "tools." <> Integer.to_string(index) <> ".function.parameters", name}
    else
      nil
    end
  end

  defp function_tool_target(%{"type" => "function", "name" => name} = tool, index) do
    if strict_function_tool?(name, tool, tool) do
      {Map.get(tool, "parameters"), "tools." <> Integer.to_string(index) <> ".parameters", name}
    else
      nil
    end
  end

  defp function_tool_target(%{"type" => "namespace", "tools" => tools}, index)
       when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.flat_map(fn {tool, tool_index} ->
      case namespace_function_tool_target(tool, index, tool_index) do
        nil -> []
        target -> [target]
      end
    end)
  end

  defp function_tool_target(_tool, _index), do: nil

  defp namespace_function_tool_target(
         %{"type" => "function", "name" => name} = tool,
         namespace_index,
         tool_index
       ) do
    if strict_function_tool?(name, tool, tool) do
      path =
        "tools." <>
          Integer.to_string(namespace_index) <>
          ".tools." <> Integer.to_string(tool_index) <> ".parameters"

      {Map.get(tool, "parameters"), path, name}
    else
      nil
    end
  end

  defp namespace_function_tool_target(_tool, _namespace_index, _tool_index), do: nil

  defp strict_function_tool?(name, function, tool) do
    is_binary(name) and name != "" and
      (Map.get(function, "strict") == true or Map.get(tool, "strict") == true)
  end

  defp text_format_target(%{
         "text" => %{"format" => %{"type" => "json_schema", "strict" => true} = format}
       }) do
    {Map.get(format, "schema"), "text.format.schema"}
  end

  defp text_format_target(_payload), do: nil

  defp response_format_target(%{
         "response_format" => %{
           "type" => "json_schema",
           "json_schema" => %{"strict" => true} = format
         }
       }) do
    {Map.get(format, "schema"), "response_format.json_schema.schema"}
  end

  defp response_format_target(_payload), do: nil

  defp validate_target({schema, param}) when is_map(schema), do: validate_schema(schema, param)

  defp validate_target({schema, param, function_name}) when is_map(schema) do
    case validate_schema(schema, param) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         reason
         |> Map.put(:code, @function_error_code)
         |> Map.put(
           :message,
           "Invalid schema for function '" <> function_name <> "': " <> reason.message
         )}
    end
  end

  defp validate_target({_schema, param, function_name}) do
    {:error, invalid_function_schema(param, function_name, "schema must be an object")}
  end

  defp validate_target({_schema, param}) do
    {:error, invalid_schema(param, "schema must be an object")}
  end

  defp validate_schema(schema, path) when is_map(schema) do
    validate_schema(schema, path, schema, [])
  end

  defp validate_schema(schema, path, root_schema, ref_stack) when is_map(schema) do
    if Map.has_key?(schema, "$ref") do
      validate_ref_schema(schema, path, root_schema, ref_stack)
    else
      schema
      |> validation_steps(path, root_schema, ref_stack)
      |> run_validation_steps()
    end
  end

  defp validate_schema(_schema, path, _root_schema, _ref_stack) do
    {:error, invalid_schema(path, "schema node must be an object")}
  end

  defp validate_ref_schema(%{"$ref" => ref} = schema, path, root_schema, ref_stack) do
    with :ok <- validate_ref_only_schema(schema, path),
         {:ok, tokens, canonical_ref} <- parse_local_ref(ref, path),
         :ok <- validate_ref_not_circular(canonical_ref, path, ref_stack),
         {:ok, target_schema} <- resolve_ref_target(root_schema, tokens, path) do
      validate_schema(target_schema, path, root_schema, [canonical_ref | ref_stack])
    end
  end

  defp validate_ref_schema(_schema, path, _root_schema, _ref_stack) do
    {:error, invalid_schema(path <> ".$ref", "$ref must be a string local JSON Pointer")}
  end

  defp validate_ref_only_schema(schema, path) do
    keys = Map.keys(schema)

    cond do
      keys == ["$ref"] ->
        :ok

      root_schema_path?(path) and Enum.all?(keys, &(&1 in ["$ref", "$defs", "definitions"])) ->
        :ok

      true ->
        {:error, invalid_schema(path, "$ref schema nodes must contain only $ref")}
    end
  end

  defp root_schema_path?("text.format.schema"), do: true
  defp root_schema_path?("response_format.json_schema.schema"), do: true

  defp root_schema_path?(path) do
    String.starts_with?(path, "tools.") and String.ends_with?(path, ".parameters")
  end

  defp parse_local_ref(ref, path) when is_binary(ref) do
    with {"#", fragment} <- String.split_at(ref, 1),
         {:ok, decoded_fragment} <- percent_decode(fragment),
         {:ok, tokens} <- parse_json_pointer(decoded_fragment),
         :ok <- validate_supported_definition_pointer(tokens) do
      {:ok, tokens, canonical_ref(tokens)}
    else
      {prefix, _fragment} when prefix != "#" ->
        {:error, invalid_schema(path <> ".$ref", "$ref must be a local JSON Pointer fragment")}

      {:error, detail} ->
        {:error, invalid_schema(path <> ".$ref", detail)}
    end
  end

  defp parse_local_ref(_ref, path) do
    {:error, invalid_schema(path <> ".$ref", "$ref must be a string local JSON Pointer")}
  end

  defp percent_decode(fragment), do: percent_decode(fragment, <<>>)

  defp percent_decode("", acc), do: {:ok, acc}

  defp percent_decode(<<"%", hex::binary-size(2), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {value, ""} -> percent_decode(rest, acc <> <<value>>)
      _other -> {:error, "malformed local $ref fragment"}
    end
  end

  defp percent_decode(<<"%", _rest::binary>>, _acc), do: {:error, "malformed local $ref fragment"}

  defp percent_decode(<<byte, rest::binary>>, acc), do: percent_decode(rest, acc <> <<byte>>)

  defp parse_json_pointer(""), do: {:error, "$ref must point into $defs or definitions"}

  defp parse_json_pointer("/" <> pointer) do
    pointer
    |> String.split("/", trim: false)
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case unescape_json_pointer_token(token) do
        {:ok, unescaped_token} -> {:cont, {:ok, [unescaped_token | acc]}}
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
    |> case do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      {:error, detail} -> {:error, detail}
    end
  end

  defp parse_json_pointer(_pointer), do: {:error, "$ref must be a JSON Pointer fragment"}

  defp unescape_json_pointer_token(token) do
    if Regex.match?(~r/~($|[^01])/, token) do
      {:error, "malformed local $ref JSON Pointer"}
    else
      {:ok, token |> String.replace("~1", "/") |> String.replace("~0", "~")}
    end
  end

  defp validate_supported_definition_pointer([table, name | _rest])
       when table in ["$defs", "definitions"] and is_binary(name) and name != "" do
    :ok
  end

  defp validate_supported_definition_pointer(_tokens) do
    {:error, "$ref must point into $defs or definitions"}
  end

  defp canonical_ref(tokens),
    do: "#/" <> Enum.map_join(tokens, "/", &escape_pointer_token/1)

  defp escape_pointer_token(token) do
    token |> String.replace("~", "~0") |> String.replace("/", "~1")
  end

  defp validate_ref_not_circular(canonical_ref, path, ref_stack) do
    if canonical_ref in ref_stack do
      {:error, invalid_schema(path <> ".$ref", "circular local $ref is not supported")}
    else
      :ok
    end
  end

  defp resolve_ref_target(root_schema, tokens, path) do
    case resolve_tokens(root_schema, tokens) do
      {:ok, target_schema} when is_map(target_schema) ->
        {:ok, target_schema}

      {:ok, _target} ->
        {:error, invalid_schema(path <> ".$ref", "$ref target must be a schema object")}

      :error ->
        {:error, invalid_schema(path <> ".$ref", "$ref target could not be resolved")}
    end
  end

  defp resolve_tokens(value, []), do: {:ok, value}

  defp resolve_tokens(value, [token | rest]) when is_map(value) do
    case Map.fetch(value, token) do
      {:ok, child} -> resolve_tokens(child, rest)
      :error -> :error
    end
  end

  defp resolve_tokens(_value, _tokens), do: :error

  defp validation_steps(schema, path, root_schema, ref_stack) do
    [
      fn -> validate_type(schema, path) end,
      fn -> validate_object_constraints(schema, path) end,
      fn -> validate_properties(schema, path, root_schema, ref_stack) end,
      fn ->
        validate_named_schemas(Map.get(schema, "$defs"), path <> ".$defs", root_schema, ref_stack)
      end,
      fn ->
        validate_named_schemas(
          Map.get(schema, "definitions"),
          path <> ".definitions",
          root_schema,
          ref_stack
        )
      end,
      fn ->
        validate_items(Map.get(schema, "items"), path <> ".items", root_schema, ref_stack)
      end,
      fn ->
        validate_schema_list(Map.get(schema, "anyOf"), path <> ".anyOf", root_schema, ref_stack)
      end,
      fn ->
        validate_schema_list(Map.get(schema, "oneOf"), path <> ".oneOf", root_schema, ref_stack)
      end,
      fn ->
        validate_schema_list(Map.get(schema, "allOf"), path <> ".allOf", root_schema, ref_stack)
      end
    ]
  end

  defp run_validation_steps(steps) do
    Enum.reduce_while(steps, :ok, fn step, _acc ->
      case step.() do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_type(schema, path) do
    case Map.get(schema, "type") do
      type when is_binary(type) and type != "" ->
        :ok

      types when is_list(types) ->
        if types != [] and Enum.all?(types, &(is_binary(&1) and &1 != "")) do
          :ok
        else
          {:error,
           invalid_schema(
             path <> ".type",
             "type must be a string or a non-empty array of strings"
           )}
        end

      _other ->
        {:error,
         invalid_schema(path <> ".type", "type must be a string or a non-empty array of strings")}
    end
  end

  defp validate_object_constraints(schema, path) do
    if object_schema?(schema),
      do: run_validation_steps(object_constraint_steps(schema, path)),
      else: :ok
  end

  defp object_constraint_steps(schema, path) do
    [
      fn -> validate_additional_properties(schema, path) end,
      fn -> validate_required_properties(schema, path) end
    ]
  end

  defp validate_additional_properties(schema, path) do
    if Map.get(schema, "additionalProperties") == false do
      :ok
    else
      {:error, invalid_schema(path, "object schemas must set additionalProperties to false")}
    end
  end

  defp validate_required_properties(schema, path) do
    properties = Map.get(schema, "properties")
    required = Map.get(schema, "required", [])

    with :ok <- validate_required_shape(properties, required, path) do
      validate_required_coverage(properties, required, path)
    end
  end

  defp validate_required_shape(nil, required, _path) when is_list(required), do: :ok

  defp validate_required_shape(nil, _required, path) do
    {:error, invalid_schema(path <> ".required", "required must be an array of property names")}
  end

  defp validate_required_shape(properties, _required, path) when not is_map(properties) do
    {:error, invalid_schema(path <> ".properties", "properties must be an object")}
  end

  defp validate_required_shape(_properties, required, path) do
    if is_list(required) and Enum.all?(required, &is_binary/1) do
      :ok
    else
      {:error, invalid_schema(path <> ".required", "required must be an array of property names")}
    end
  end

  defp validate_required_coverage(nil, _required, _path), do: :ok

  defp validate_required_coverage(properties, required, path) do
    missing_properties = missing_required_properties(properties, required)
    extra_required = extra_required_properties(properties, required)

    required_coverage_result(missing_properties, extra_required, path)
  end

  defp missing_required_properties(properties, required) do
    properties
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&(&1 in required))
  end

  defp extra_required_properties(properties, required) do
    property_names = Map.keys(properties)

    required
    |> Enum.sort()
    |> Enum.reject(&(&1 in property_names))
  end

  defp required_coverage_result([], [], _path), do: :ok

  defp required_coverage_result([property | _rest], _extra_required, path) do
    {:error,
     invalid_schema(
       path <> ".required",
       "object schemas must list every property in required (missing #{property})"
     )}
  end

  defp required_coverage_result([], [property | _rest], path) do
    {:error,
     invalid_schema(
       path <> ".required",
       "object schemas must not list required entries missing from properties (extra #{property})"
     )}
  end

  defp validate_property_schemas(properties, path, root_schema, ref_stack) do
    properties
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.reduce_while(:ok, fn {name, child_schema}, _acc ->
      case validate_schema(child_schema, path <> ".properties." <> name, root_schema, ref_stack) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_properties(schema, path, root_schema, ref_stack) do
    case Map.get(schema, "properties") do
      nil ->
        :ok

      properties when is_map(properties) ->
        validate_property_schemas(properties, path, root_schema, ref_stack)

      _other ->
        {:error, invalid_schema(path <> ".properties", "properties must be an object")}
    end
  end

  defp validate_named_schemas(nil, _path, _root_schema, _ref_stack), do: :ok

  defp validate_named_schemas(schemas, path, root_schema, ref_stack) when is_map(schemas) do
    schemas
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.reduce_while(:ok, fn {name, child_schema}, _acc ->
      case validate_schema(child_schema, path <> "." <> name, root_schema, ref_stack) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_named_schemas(_schemas, path, _root_schema, _ref_stack) do
    {:error, invalid_schema(path, "definitions must be an object")}
  end

  defp validate_items(nil, _path, _root_schema, _ref_stack), do: :ok

  defp validate_items(schema, path, root_schema, ref_stack) when is_map(schema) do
    validate_schema(schema, path, root_schema, ref_stack)
  end

  defp validate_items(schemas, path, root_schema, ref_stack) when is_list(schemas) do
    schemas
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child_schema, index}, _acc ->
      case validate_schema(
             child_schema,
             path <> "." <> Integer.to_string(index),
             root_schema,
             ref_stack
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_items(_schemas, path, _root_schema, _ref_stack) do
    {:error, invalid_schema(path, "items must be a schema or an array of schemas")}
  end

  defp validate_schema_list(nil, _path, _root_schema, _ref_stack), do: :ok

  defp validate_schema_list(schemas, path, root_schema, ref_stack) when is_list(schemas) do
    schemas
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child_schema, index}, _acc ->
      case validate_schema(
             child_schema,
             path <> "." <> Integer.to_string(index),
             root_schema,
             ref_stack
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_schema_list(_schemas, path, _root_schema, _ref_stack) do
    keyword = path |> String.split(".") |> List.last()
    {:error, invalid_schema(path, "#{keyword} must be an array of schemas")}
  end

  defp object_schema?(schema) do
    type_includes_object?(Map.get(schema, "type")) or
      Map.has_key?(schema, "properties") or
      Map.has_key?(schema, "required") or
      Map.has_key?(schema, "additionalProperties")
  end

  defp type_includes_object?("object"), do: true
  defp type_includes_object?(types) when is_list(types), do: "object" in types
  defp type_includes_object?(_type), do: false

  defp invalid_function_schema(param, function_name, detail) do
    %{
      status: 400,
      code: @function_error_code,
      message: "Invalid schema for function '" <> function_name <> "': " <> detail,
      param: param
    }
  end

  defp invalid_schema(param, detail) do
    %{
      status: 400,
      code: @error_code,
      message: @error_message_prefix <> " " <> detail,
      param: param
    }
  end
end
