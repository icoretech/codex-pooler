defmodule CodexPoolerWeb.Mcp.Headers do
  @moduledoc false

  alias Plug.Conn

  @type header_error :: {:error, :header_mismatch}
  @type protocol_version_result :: {:ok, nil | String.t()} | header_error()

  @spec protocol_version(Conn.t()) :: protocol_version_result()
  def protocol_version(conn), do: decoded_header(conn, "mcp-protocol-version")

  @spec validate_modern(Conn.t(), String.t(), %{optional(String.t()) => term()}) ::
          :ok | header_error()
  def validate_modern(conn, method, params) when is_binary(method) and is_map(params) do
    with :ok <- matches_header(conn, "mcp-method", method) do
      validate_tool_name(conn, method, params)
    end
  end

  @spec decode_value(binary()) :: {:ok, binary()} | header_error()
  def decode_value("=?base64?" <> encoded_value), do: decode_base64_value(encoded_value)

  def decode_value(value) when is_binary(value) do
    if safe_plain_value?(value), do: {:ok, value}, else: {:error, :header_mismatch}
  end

  @spec validate_tool_name(Conn.t(), String.t(), %{optional(String.t()) => term()}) ::
          :ok | header_error()
  defp validate_tool_name(_conn, method, _params) when method != "tools/call", do: :ok

  defp validate_tool_name(conn, "tools/call", %{"name" => name}) when is_binary(name) do
    matches_header(conn, "mcp-name", name)
  end

  defp validate_tool_name(_conn, "tools/call", _params), do: {:error, :header_mismatch}

  @spec matches_header(Conn.t(), String.t(), String.t()) :: :ok | header_error()
  defp matches_header(conn, header, expected_value) do
    case decoded_header(conn, header) do
      {:ok, ^expected_value} -> :ok
      _result -> {:error, :header_mismatch}
    end
  end

  @spec decoded_header(Conn.t(), String.t()) :: protocol_version_result()
  defp decoded_header(conn, header) do
    case Conn.get_req_header(conn, header) do
      [] -> {:ok, nil}
      [value] -> decode_value(value)
      _values -> {:error, :header_mismatch}
    end
  end

  @spec decode_base64_value(binary()) :: {:ok, binary()} | header_error()
  defp decode_base64_value(encoded_value) do
    if String.ends_with?(encoded_value, "?=") do
      encoded_value
      |> binary_part(0, byte_size(encoded_value) - 2)
      |> Base.decode64()
      |> decoded_utf8_value()
    else
      {:error, :header_mismatch}
    end
  end

  @spec decoded_utf8_value({:ok, binary()} | :error) :: {:ok, binary()} | header_error()
  defp decoded_utf8_value({:ok, value}) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :header_mismatch}
  end

  defp decoded_utf8_value(:error), do: {:error, :header_mismatch}

  @spec safe_plain_value?(binary()) :: boolean()
  defp safe_plain_value?(<<first_byte, _rest::binary>> = value) do
    first_byte != 0x20 and :binary.last(value) != 0x20 and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))
  end

  defp safe_plain_value?(""), do: false
end
