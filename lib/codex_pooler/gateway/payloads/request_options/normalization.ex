defmodule CodexPooler.Gateway.Payloads.RequestOptions.Normalization do
  @moduledoc false

  @spec optional_positive_integer(term()) :: pos_integer() | nil
  def optional_positive_integer(value) when is_integer(value) and value > 0, do: value
  def optional_positive_integer(_value), do: nil

  @spec optional_non_negative_integer(term()) :: non_neg_integer() | nil
  def optional_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  def optional_non_negative_integer(_value), do: nil

  @spec forwarded_headers(term()) :: [{String.t(), String.t()}]
  def forwarded_headers(headers) when is_list(headers) do
    Enum.filter(headers, fn
      {name, value} -> is_binary(name) and is_binary(value)
      _other -> false
    end)
  end

  def forwarded_headers(_headers), do: []

  @spec forwarded_headers_update(term()) :: [{String.t(), String.t()}] | nil
  def forwarded_headers_update(headers) do
    case forwarded_headers(headers) do
      [] -> nil
      headers -> headers
    end
  end

  @spec safe_endpoint(term()) :: String.t() | nil
  def safe_endpoint(value) when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 160)

    if String.starts_with?(value, "/") and value != "/" do
      value
    else
      nil
    end
  end

  def safe_endpoint(_value), do: nil

  @spec normalize_optional_update(map(), atom(), (term() -> term())) :: map()
  def normalize_optional_update(updates, key, normalizer) when is_map(updates) and is_atom(key) do
    if Map.has_key?(updates, key) do
      case normalizer.(Map.fetch!(updates, key)) do
        nil -> Map.delete(updates, key)
        value -> Map.put(updates, key, value)
      end
    else
      updates
    end
  end
end
