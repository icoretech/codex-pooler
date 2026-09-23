defmodule CodexPooler.Accounting.RequestLogs.DebugProjection.DownstreamDelivery do
  @moduledoc false

  # Admin-only projection of the `downstream_delivery` attempt receipt written by
  # `CodexPooler.Gateway.Websocket.DeliveryReceipt`. Every field is re-checked
  # against the receipt's fixed vocabulary; any field outside it drops the whole
  # namespace, and nothing beyond the eight allowlisted keys is projected.
  # `highest_frame_class` is optional: only a transport that classifies what it
  # pushed writes it (the native and `/v1` websockets), so an absent field
  # projects as `nil` ("not classified") while an unknown value drops the
  # namespace like any other field outside the vocabulary. `completed_items`
  # (how many items the socket pushed completed, findings#232 row 232-241) and
  # `write_failure` (the class of the connection's first failed write, row
  # 232-256) are optional the same way. The completed items' digests are
  # never projected.

  alias CodexPooler.Gateway.Websocket.DeliveryReceipt

  # The receipt module is consulted at runtime only: a compile-time reference
  # from accounting into the gateway is outside the xref contract.
  @metadata_key "downstream_delivery"

  @type t :: %{
          outcome: String.t(),
          terminal_class: String.t(),
          pushed_at: String.t() | nil,
          frames_after_visible: non_neg_integer(),
          transport: String.t(),
          highest_frame_class: String.t() | nil,
          completed_items: non_neg_integer() | nil,
          write_failure: String.t() | nil
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
           vocabulary(Map.get(receipt, "transport"), DeliveryReceipt.transports()),
         {:ok, highest_frame_class} <- highest_frame_class(receipt),
         {:ok, completed_items} <- completed_items(receipt),
         {:ok, write_failure} <- write_failure(receipt) do
      %{
        outcome: outcome,
        terminal_class: terminal_class,
        pushed_at: pushed_at,
        frames_after_visible: frames,
        transport: transport,
        highest_frame_class: highest_frame_class,
        completed_items: completed_items,
        write_failure: write_failure
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

  defp highest_frame_class(receipt) when not is_map_key(receipt, "highest_frame_class"), do: {:ok, nil}

  defp highest_frame_class(%{"highest_frame_class" => class}) do
    case vocabulary(class, DeliveryReceipt.frame_classes()) do
      nil -> :error
      class -> {:ok, class}
    end
  end

  defp completed_items(receipt) when not is_map_key(receipt, "completed_items"), do: {:ok, nil}
  defp completed_items(%{"completed_items" => count}) when is_integer(count) and count >= 0, do: {:ok, count}
  defp completed_items(_receipt), do: :error

  defp write_failure(receipt) when not is_map_key(receipt, "write_failure"), do: {:ok, nil}

  defp write_failure(%{"write_failure" => failure}) do
    case vocabulary(failure, DeliveryReceipt.write_failures()) do
      nil -> :error
      failure -> {:ok, failure}
    end
  end

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
