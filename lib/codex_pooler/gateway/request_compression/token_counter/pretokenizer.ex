defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.Pretokenizer do
  @moduledoc false

  @type encoding :: :cl100k_base | :o200k_base

  @cl100k_pattern ~r/(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+/u

  @o200k_pattern ~r/[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n\/]*|\s*[\r\n]+|\s+(?!\S)|\s+/u

  @spec split(binary(), encoding()) :: [binary()]
  def split("", _encoding), do: []

  def split(text, :cl100k_base) when is_binary(text),
    do: scan(@cl100k_pattern, text)

  def split(text, :o200k_base) when is_binary(text),
    do: scan(@o200k_pattern, text)

  defp scan(pattern, text) do
    pattern
    |> Regex.scan(text)
    |> List.flatten()
  end
end
