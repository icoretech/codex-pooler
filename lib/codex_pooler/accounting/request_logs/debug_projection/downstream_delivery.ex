defmodule CodexPooler.Accounting.RequestLogs.DebugProjection.DownstreamDelivery do
  @moduledoc false

  # Admin-only projection of the `downstream_delivery` attempt receipt written by
  # `CodexPooler.Gateway.Websocket.DeliveryReceipt`. Every field is re-checked
  # against the receipt's fixed vocabulary; any field outside it drops the whole
  # namespace, and nothing beyond the five allowlisted keys is projected.

  alias CodexPooler.Gateway.Websocket.DeliveryReceipt

  # The receipt module is consulted at runtime only: a compile-time reference
  # from accounting into the gateway is outside the xref contract.
  @metadata_key "downstream_delivery"

  @type t :: %{
          outcome: String.t(),
          terminal_class: String.t(),
          pushed_at: String.t() | nil,
          frames_after_visible: non_neg_integer(),
          transport: String.t()
        }

  @spec build(map() | nil) :: t() | nil
  def build(%{@metadata_key => receipt}) when is_map(receipt) do
    with outcome when is_binary(outcome) <-
           vocabulary(Map.get(receipt, "outcome"), DeliveryReceipt.outcomes()),
         terminal_class when is_binary(terminal_class) <-
           vocabulary(Map.get(receipt, "terminal_class"), DeliveryReceipt.terminal_class_values()),
         {:ok, pushed_at} <- pushed_at(Map.get(receipt, "pushed_at")),
         frames when is_integer(frames) <- frame_count(Map.get(receipt, "frames_after_visible")),
         transport when is_binary(transport) <-
           vocabulary(Map.get(receipt, "transport"), DeliveryReceipt.transports()) do
      %{
        outcome: outcome,
        terminal_class: terminal_class,
        pushed_at: pushed_at,
        frames_after_visible: frames,
        transport: transport
      }
    else
      _invalid -> nil
    end
  end

  def build(_metadata), do: nil

  defp vocabulary(value, allowed) when is_binary(value) do
    if value in allowed, do: value, else: nil
  end

  defp vocabulary(_value, _allowed), do: nil

  defp pushed_at(nil), do: {:ok, nil}

  defp pushed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} ->
        {:ok, datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()}

      _invalid ->
        :error
    end
  end

  defp pushed_at(_value), do: :error

  defp frame_count(count) when is_integer(count) and count >= 0, do: count
  defp frame_count(_count), do: nil
end
