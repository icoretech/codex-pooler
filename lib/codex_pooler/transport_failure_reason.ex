defmodule CodexPooler.TransportFailureReason do
  @moduledoc false

  @max_reason_length 96

  @spec safe_reason(term()) :: String.t() | nil
  def safe_reason(%Finch.TransportError{source: %Mint.TransportError{} = source}),
    do: safe_reason(source)

  def safe_reason(%Finch.HTTPError{source: %Mint.HTTPError{} = source}), do: safe_reason(source)
  def safe_reason(%{__struct__: _module, reason: reason}), do: safe_reason(reason)
  def safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def safe_reason(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> truncate_reason()
    |> blank_to_nil()
  end

  def safe_reason(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&safe_tuple_reason/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
    |> Enum.join("_")
    |> blank_to_nil()
  end

  def safe_reason(_reason), do: nil

  @spec safe_exception(term()) :: String.t() | nil
  def safe_exception(%module{}) when is_atom(module), do: inspect(module)
  def safe_exception(_reason), do: nil

  defp safe_tuple_reason(value) when is_atom(value), do: safe_reason(value)
  defp safe_tuple_reason(value) when is_tuple(value), do: safe_reason(value)
  defp safe_tuple_reason(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_tuple_reason(_value), do: nil

  defp truncate_reason(reason) when byte_size(reason) > @max_reason_length,
    do: binary_part(reason, 0, @max_reason_length)

  defp truncate_reason(reason), do: reason

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
