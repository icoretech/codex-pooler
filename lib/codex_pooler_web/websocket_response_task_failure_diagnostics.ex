defmodule CodexPoolerWeb.WebsocketResponseTaskFailureDiagnostics do
  @moduledoc false

  @safe_identifier ~r/\A[A-Za-z0-9_.-]+\z/
  @max_identifier_bytes 80

  @spec metadata(term(), Exception.stacktrace()) :: keyword()
  def metadata(%Postgrex.Error{postgres: postgres}, stacktrace) do
    [
      postgres_code: postgres_value(postgres, :code),
      failure_operation: failure_operation(stacktrace),
      stacktrace_fingerprint: stacktrace_fingerprint(stacktrace)
    ]
  end

  def metadata(_reason, stacktrace) do
    [
      failure_operation: failure_operation(stacktrace),
      stacktrace_fingerprint: stacktrace_fingerprint(stacktrace)
    ]
  end

  defp postgres_value(postgres, key) when is_map(postgres) do
    postgres
    |> Map.get(key)
    |> safe_identifier()
  end

  defp postgres_value(_postgres, _key), do: nil

  defp failure_operation(stacktrace) do
    Enum.find_value(stacktrace, fn
      {module, function, arity_or_args, _location} ->
        if pooler_module?(module) do
          "#{inspect(module)}.#{function}/#{stacktrace_arity(arity_or_args)}"
        end

      _entry ->
        nil
    end)
  end

  defp pooler_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?(["Elixir.CodexPooler.", "Elixir.CodexPoolerWeb."])
  end

  defp stacktrace_fingerprint(stacktrace) do
    normalized =
      Enum.map_join(stacktrace, ";", fn
        {module, function, arity_or_args, _location} ->
          "#{inspect(module)}.#{function}/#{stacktrace_arity(arity_or_args)}"

        _entry ->
          "unknown/0"
      end)

    :crypto.hash(:sha256, normalized)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp stacktrace_arity(arity) when is_integer(arity), do: arity
  defp stacktrace_arity(args) when is_list(args), do: length(args)
  defp stacktrace_arity(_value), do: 0

  defp safe_identifier(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_identifier()

  defp safe_identifier(value) when is_binary(value) do
    if byte_size(value) <= @max_identifier_bytes and Regex.match?(@safe_identifier, value) do
      value
    end
  end

  defp safe_identifier(_value), do: nil
end
