defmodule CodexPooler.Platform.LikePattern do
  @moduledoc """
  Builds SQL `LIKE`/`ILIKE` patterns from operator search text.

  PostgreSQL treats `%` and `_` in a pattern as wildcards and `\\` as the
  default escape character, so search text interpolated as-is matches more
  rows than the operator typed (`gpt_5` also finds `gpt-5`, a lone `%`
  matches everything) or loses its backslashes. Escaping them makes the text
  match literally; the pattern keeps working with the default escape.
  """

  @doc "Returns a pattern matching values that contain `text` literally."
  @spec contains(String.t()) :: String.t()
  def contains(text) when is_binary(text), do: "%" <> escape(text) <> "%"

  @doc "Escapes the `LIKE` metacharacters `\\`, `%` and `_` in `text`."
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
end
