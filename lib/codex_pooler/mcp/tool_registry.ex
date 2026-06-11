defmodule CodexPooler.MCP.ToolRegistry do
  @moduledoc """
  Owns the metadata-only MCP tool catalog.
  """

  @type tool :: %{
          required(:name) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map(),
          required(:output_schema) => map(),
          required(:annotations) => map(),
          required(:handler) => {module(), atom()}
        }

  @description_sections ["Use when", "Returns", "Never returns", "Filters/limits"]
  @common_never_returns "raw secrets, credentials, tokens, cookies, headers, prompts, request bodies, response bodies, raw emails, raw IPs, raw domain structs, or provider payloads"
  @family_modules [
    CodexPooler.MCP.Tools.Foundation,
    CodexPooler.MCP.Tools.PoolMetadata,
    CodexPooler.MCP.Tools.QuotaMetadata,
    CodexPooler.MCP.Tools.OperatorMetadata,
    CodexPooler.MCP.Tools.LogMetadata
  ]

  @spec all_tools() :: [tool()]
  def all_tools, do: tools_from_families(@family_modules)

  @spec family_modules() :: [module()]
  def family_modules, do: @family_modules

  @spec tools_from_families([module()]) :: [tool()]
  def tools_from_families(family_modules) when is_list(family_modules) do
    Enum.flat_map(family_modules, &tools_from_family!/1)
  end

  @spec get_tool(String.t()) :: {:ok, tool()} | {:error, map()}
  def get_tool(name) when is_binary(name) do
    case Enum.find(all_tools(), &(&1.name == name)) do
      nil -> {:error, %{code: :tool_not_found, message: "MCP tool was not found"}}
      tool -> {:ok, tool}
    end
  end

  def get_tool(_name), do: {:error, %{code: :tool_not_found, message: "MCP tool was not found"}}

  @spec list_tools(map()) :: {:ok, %{tools: [map()], next_cursor: nil}}
  def list_tools(params) when is_map(params) do
    {:ok, %{tools: all_tools() |> Enum.map(&public_tool/1), next_cursor: nil}}
  end

  @spec metadata_description(keyword()) :: String.t()
  def metadata_description(fields) when is_list(fields) do
    """
    Use when #{description_sentence(Keyword.fetch!(fields, :use_when))}
    Returns #{description_sentence(Keyword.fetch!(fields, :returns))}
    Never returns #{never_returns_sentence(Keyword.get(fields, :never_returns))}
    Filters/limits: #{description_sentence(Keyword.fetch!(fields, :filters_limits))}
    """
  end

  @spec validate_tools([tool()]) :: :ok | {:error, term()}
  def validate_tools(tools) when is_list(tools) do
    case reject_duplicate_names(tools) do
      :ok -> validate_each_tool(tools)
      error -> error
    end
  end

  @spec public_tool(tool()) :: map()
  def public_tool(tool) do
    %{
      "name" => tool.name,
      "title" => tool.title,
      "description" => compact_description(tool.description),
      "inputSchema" => tool.input_schema,
      "outputSchema" => tool.output_schema,
      "annotations" => tool.annotations
    }
  end

  defp tools_from_family!(family_module) when is_atom(family_module) do
    if Code.ensure_loaded?(family_module) and function_exported?(family_module, :tools, 0) do
      family_module.tools()
    else
      raise ArgumentError, "MCP tool family #{inspect(family_module)} must define tools/0"
    end
  end

  defp reject_duplicate_names(tools) do
    duplicates =
      tools
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)
      |> Enum.sort()

    if duplicates == [], do: :ok, else: {:error, {:duplicate_tool_names, duplicates}}
  end

  defp validate_each_tool([]), do: :ok

  defp validate_each_tool([tool | rest]) do
    case validate_tool(tool) do
      :ok -> validate_each_tool(rest)
      error -> error
    end
  end

  defp validate_tool(tool) do
    validators = [
      &validate_required_metadata/1,
      &validate_description/1,
      &validate_input_schema/1,
      &validate_output_schema/1,
      &validate_annotations/1,
      &validate_handler/1
    ]

    Enum.find_value(validators, :ok, fn validator ->
      case validator.(tool) do
        :ok -> false
        error -> error
      end
    end)
  end

  defp validate_required_metadata(tool) do
    required = [
      :name,
      :title,
      :description,
      :input_schema,
      :output_schema,
      :annotations,
      :handler
    ]

    if Enum.all?(required, &Map.has_key?(tool, &1)) do
      :ok
    else
      {:error, {:invalid_tool_metadata, Map.get(tool, :name)}}
    end
  end

  defp validate_description(tool) do
    missing = Enum.reject(@description_sections, &String.contains?(tool.description, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:invalid_description, tool.name, missing}}
  end

  defp validate_input_schema(tool) do
    if strict_object_schema?(tool.input_schema) do
      :ok
    else
      {:error, {:invalid_input_schema, tool.name, "input schema must be a strict object"}}
    end
  end

  defp validate_output_schema(tool) do
    if is_map(tool.output_schema) and tool.output_schema["type"] == "object" do
      :ok
    else
      {:error, {:invalid_output_schema, tool.name, "output schema must be an object"}}
    end
  end

  defp validate_annotations(tool) do
    expected = %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    }

    if Map.take(tool.annotations, Map.keys(expected)) == expected do
      :ok
    else
      {:error, {:invalid_annotations, tool.name}}
    end
  end

  defp validate_handler(%{handler: {module, function}, name: _name})
       when is_atom(module) and is_atom(function),
       do: :ok

  defp validate_handler(tool), do: {:error, {:invalid_handler, tool.name}}

  defp strict_object_schema?(%{"type" => "object", "properties" => properties} = schema)
       when is_map(properties) do
    Map.get(schema, "additionalProperties") == false and is_list(Map.get(schema, "required"))
  end

  defp strict_object_schema?(_schema), do: false

  defp never_returns_sentence(nil), do: @common_never_returns

  defp never_returns_sentence(value) do
    value
    |> description_sentence()
    |> case do
      "" -> @common_never_returns
      sentence -> "#{sentence}; also never returns #{@common_never_returns}"
    end
  end

  defp description_sentence(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp compact_description(description) do
    description
    |> String.split("\n", trim: true)
    |> Enum.map_join(" ", &String.trim/1)
  end
end
