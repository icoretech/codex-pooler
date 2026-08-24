defmodule CodexPooler.MCP.ToolDispatch do
  @moduledoc """
  Dispatches registry-owned MCP tools and validates shared envelopes.
  """

  alias CodexPooler.MCP.ToolRegistry

  require Logger

  @type call_context :: %{optional(:auth) => map()}

  @spec call(String.t() | map(), map(), call_context()) :: {:ok, map()} | {:error, map()}
  def call(name, arguments, context) when is_binary(name) do
    with {:ok, tool} <- ToolRegistry.get_tool(name) do
      call(tool, arguments, context)
    end
  end

  def call(%{} = tool, arguments, context) when is_map(arguments) and is_map(context) do
    with :ok <- validate_input(tool, arguments),
         {:ok, structured_content, text} <- invoke(tool, arguments, context),
         :ok <- validate_output(tool, structured_content) do
      {:ok, success_result(structured_content, text)}
    else
      {:error, %{code: :invalid_arguments} = error} -> {:ok, error_result(error)}
      {:error, %{code: :invalid_tool_output} = error} -> {:ok, error_result(error)}
      {:error, %{code: :tool_execution_failed} = error} -> {:ok, error_result(error)}
      {:error, %{code: :tool_not_found} = error} -> {:error, error}
      {:error, error} when is_map(error) -> {:ok, error_result(error)}
    end
  end

  def call(%{} = tool, _arguments, _context) do
    {:ok,
     error_result(%{code: :invalid_arguments, message: "Invalid tool arguments", tool: tool.name})}
  end

  defp invoke(%{handler: {module, function}} = tool, arguments, context) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 2) do
      apply(module, function, [arguments, Map.put(context, :tool, tool)])
    else
      {:error,
       %{
         code: :tool_execution_failed,
         message: "MCP tool handler is unavailable",
         tool: tool.name
       }}
    end
  rescue
    exception ->
      log_handler_exception(tool, module, function, exception)

      {:error,
       %{code: :tool_execution_failed, message: "MCP tool execution failed", tool: tool.name}}
  end

  defp log_handler_exception(tool, module, function, exception) do
    Logger.warning(fn ->
      [
        "mcp tool handler failed",
        "tool=#{safe_log_value(tool.name)}",
        "handler=#{safe_log_value("#{inspect(module)}.#{function}")}",
        "exception=#{safe_log_value(inspect(exception.__struct__))}",
        "reason=handler_exception"
      ]
      |> Enum.join(" ")
    end)
  end

  defp validate_input(tool, arguments) do
    schema = tool.input_schema
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    additional? = Map.get(schema, "additionalProperties", true)

    cond do
      not is_map(arguments) ->
        {:error, invalid_arguments(tool)}

      Enum.any?(required, &(not Map.has_key?(arguments, &1))) ->
        {:error, invalid_arguments(tool)}

      additional? == false and Enum.any?(Map.keys(arguments), &(not Map.has_key?(properties, &1))) ->
        {:error, invalid_arguments(tool)}

      Enum.all?(properties, fn {name, property_schema} ->
        valid_property?(arguments, name, property_schema)
      end) ->
        :ok

      true ->
        {:error, invalid_arguments(tool)}
    end
  end

  defp validate_output(tool, structured_content) do
    if valid_output?(structured_content, tool.output_schema) do
      :ok
    else
      {:error,
       %{
         code: :invalid_tool_output,
         message: "MCP tool output failed schema validation",
         tool: tool.name
       }}
    end
  end

  defp valid_output?(value, %{"type" => "object"} = schema) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    additional? = Map.get(schema, "additionalProperties", true)

    Enum.all?(required, &Map.has_key?(value, &1)) and
      (additional? != false or Enum.all?(Map.keys(value), &Map.has_key?(properties, &1))) and
      Enum.all?(properties, fn {name, property_schema} ->
        valid_property?(value, name, property_schema)
      end)
  end

  defp valid_output?(_value, _schema), do: false

  defp valid_property?(container, name, schema) do
    not Map.has_key?(container, name) or valid_value?(Map.get(container, name), schema)
  end

  defp valid_value?(value, %{"const" => const}), do: value == const

  defp valid_value?(value, %{"enum" => values} = schema) when is_list(values),
    do: value in values and valid_value?(value, Map.delete(schema, "enum"))

  defp valid_value?(value, %{"type" => types}) when is_list(types),
    do: Enum.any?(types, &valid_type?(value, &1))

  defp valid_value?(value, %{"type" => "string"}), do: is_binary(value)
  defp valid_value?(value, %{"type" => "integer"}), do: is_integer(value)
  defp valid_value?(value, %{"type" => "boolean"}), do: is_boolean(value)
  defp valid_value?(value, %{"type" => "object"} = schema), do: valid_output?(value, schema)
  defp valid_value?(value, %{"type" => "array"}), do: is_list(value)
  defp valid_value?(_value, _schema), do: true

  defp valid_type?(nil, "null"), do: true
  defp valid_type?(value, "string"), do: is_binary(value)
  defp valid_type?(value, "integer"), do: is_integer(value)
  defp valid_type?(value, "boolean"), do: is_boolean(value)
  defp valid_type?(value, "object"), do: is_map(value)
  defp valid_type?(value, "array"), do: is_list(value)
  defp valid_type?(_value, _type), do: false

  defp success_result(structured_content, text) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "structuredContent" => structured_content,
      "isError" => false
    }
  end

  defp error_result(error) do
    message = Map.get(error, :message, "MCP tool failed")
    code = error |> Map.get(:code, :tool_execution_failed) |> to_string()

    %{
      "content" => [%{"type" => "text", "text" => "#{code}: #{message}"}],
      "isError" => true
    }
  end

  defp invalid_arguments(tool) do
    %{code: :invalid_arguments, message: "Invalid tool arguments", tool: tool.name}
  end

  defp safe_log_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_log_value()

  defp safe_log_value(value) when is_binary(value) do
    String.replace(value, ~r/[^A-Za-z0-9_.:-]/, "_")
  end

  defp safe_log_value(_value), do: "unknown"
end
