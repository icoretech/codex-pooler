defmodule CodexPooler.Gateway.Transports.Streaming.RetainedBody do
  @moduledoc false

  @max_bytes 65_536

  @type t :: binary()

  @spec empty() :: t()
  def empty, do: ""

  @spec append(t(), iodata()) :: t()
  def append(body, "") when is_binary(body), do: body

  def append(body, data) when is_binary(body) do
    [body, data]
    |> IO.iodata_to_binary()
    |> suffix(@max_bytes)
  end

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defp suffix(body, max_bytes) when byte_size(body) <= max_bytes, do: body

  defp suffix(body, max_bytes) do
    binary_part(body, byte_size(body) - max_bytes, max_bytes)
  end
end
