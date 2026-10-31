defmodule CodexPoolerWeb.SafeRedirect do
  @moduledoc "Validates untrusted browser redirect destinations as local absolute paths."

  @unsafe_characters ~r/[\x00-\x1f\x7f-\x9f\\]/u

  @doc "Returns the original local path, or nil when browser parsing could reinterpret it."
  @spec local_path(term()) :: String.t() | nil
  def local_path(path) when is_binary(path) do
    if safe_path?(path), do: path
  rescue
    ArgumentError -> nil
  end

  def local_path(_path), do: nil

  defp safe_path?("//" <> _rest), do: false

  defp safe_path?("/" <> _rest = path) do
    if String.valid?(path) and not Regex.match?(@unsafe_characters, path) do
      decoded = URI.decode(path)
      decoded == path or safe_path?(decoded)
    else
      false
    end
  end

  defp safe_path?(_path), do: false
end
