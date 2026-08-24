defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam do
  @moduledoc false

  @max_bytes 160
  @path_pattern ~r/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]{0,3})\])*\z/

  @type t :: String.t() | nil

  @spec extract(map()) :: t()
  def extract(decoded) when is_map(decoded) do
    decoded
    |> first_present_candidate()
    |> sanitize()
  end

  @spec sanitize(term()) :: t()
  def sanitize(value) when is_binary(value) do
    if String.valid?(value) do
      value = String.trim(value)

      if byte_size(value) in 1..@max_bytes and Regex.match?(@path_pattern, value),
        do: value,
        else: nil
    end
  end

  def sanitize(_value), do: nil

  defp first_present_candidate(decoded) do
    candidates = [
      ["response", "error", "param"],
      ["error", "param"],
      ["response", "status_details", "error", "param"],
      ["status_details", "error", "param"]
    ]

    Enum.find_value(candidates, :absent, fn path -> fetch_path(decoded, path) end)
    |> case do
      :absent -> top_level_error_param(decoded)
      {:present, value} -> value
    end
  end

  defp fetch_path(map, [key]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:present, value}
      :error -> false
    end
  end

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nested} -> fetch_path(nested, rest)
      :error -> false
    end
  end

  defp fetch_path(_value, _path), do: false

  defp top_level_error_param(%{"type" => "error"} = decoded) do
    case Map.fetch(decoded, "param") do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp top_level_error_param(_decoded), do: nil
end
