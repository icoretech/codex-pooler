defmodule CodexPoolerWeb.I18n.Placeholders do
  @moduledoc """
  Compares named Gettext interpolation placeholders without creating atoms.

  Parsing follows Gettext's default interpolation: `%{}` and an unterminated
  `%{name` are literal text; every nonempty name through the next `}` is a
  binding. Repeated bindings and their order do not change the required set.
  """

  @type mismatch :: %{missing: [String.t()], extra: [String.t()]}

  @doc "Returns the set of named placeholders in a message."
  def extract(message) when is_binary(message), do: message |> extract_names([]) |> MapSet.new()

  @doc "Compares the required source bindings to another source or translation."
  @spec compare(String.t(), String.t()) :: :ok | {:error, mismatch()}
  def compare(source, translation) when is_binary(source) and is_binary(translation) do
    expected = extract(source)
    actual = extract(translation)

    if MapSet.equal?(expected, actual) do
      :ok
    else
      {:error,
       %{
         missing: expected |> MapSet.difference(actual) |> Enum.sort(),
         extra: actual |> MapSet.difference(expected) |> Enum.sort()
       }}
    end
  end

  @spec extract_names(String.t(), [String.t()]) :: [String.t()]
  defp extract_names(message, bindings) do
    case :binary.split(message, "%{") do
      [_literal] ->
        bindings

      [_before, "}" <> rest] ->
        extract_names(rest, bindings)

      [_before, binding] ->
        case :binary.split(binding, "}") do
          [_unterminated] -> bindings
          [name, rest] -> extract_names(rest, [name | bindings])
        end
    end
  end
end
