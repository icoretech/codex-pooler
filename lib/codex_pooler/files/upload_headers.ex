defmodule CodexPooler.Files.UploadHeaders do
  @moduledoc false

  alias CodexPooler.Files

  @forbidden_names ~w(authorization proxy-authorization chatgpt-account-id cookie cookie2 host content-length transfer-encoding connection keep-alive proxy-connection te trailer upgrade expect x-openai-api-key openai-organization openai-project x-api-key)
  @header_name ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  # Match Mint's HTTP/1 request encoder: visible ASCII, spaces and horizontal tabs.
  @header_value ~r/\A[\x20-\x7E\t]*\z/

  @type t :: [{String.t(), String.t()}]

  @spec normalize(term()) :: {:ok, t()} | {:error, Files.file_error()}
  def normalize(nil), do: {:ok, []}

  def normalize(headers) when is_map(headers) do
    headers
    |> Map.to_list()
    |> Enum.reduce_while({:ok, %{}}, &normalize_header/2)
    |> case do
      {:ok, normalized} -> {:ok, Map.to_list(normalized)}
      {:error, _error} = error -> error
    end
  end

  def normalize(_headers), do: invalid_headers()

  defp normalize_header({name, value}, {:ok, headers}) when is_binary(name) and is_binary(value) do
    if Regex.match?(@header_name, name) and Regex.match?(@header_value, value) do
      name = String.downcase(name, :ascii)

      if name in @forbidden_names or Map.has_key?(headers, name) do
        {:halt, invalid_headers()}
      else
        {:cont, {:ok, Map.put(headers, name, value)}}
      end
    else
      {:halt, invalid_headers()}
    end
  end

  defp normalize_header(_header, _headers), do: {:halt, invalid_headers()}

  defp invalid_headers do
    {:error,
     %{
       status: 502,
       code: :upstream_file_bridge_invalid_response,
       message: "upstream file create returned invalid upload_headers"
     }}
  end
end
