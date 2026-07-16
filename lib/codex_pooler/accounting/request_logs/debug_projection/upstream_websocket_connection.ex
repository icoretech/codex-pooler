defmodule CodexPooler.Accounting.RequestLogs.DebugProjection.UpstreamWebsocketConnection do
  @moduledoc false

  @canonical_uuid_byte_size 36

  @type t :: %{
          lifecycle_id: Ecto.UUID.t(),
          generation: pos_integer(),
          reused: boolean(),
          reconnected: boolean()
        }

  @spec build(map() | nil) :: t() | nil
  def build(%{"upstream_websocket_connection" => connection}) when is_map(connection) do
    with {:ok, lifecycle_id} <- canonical_uuid(Map.get(connection, "lifecycle_id")),
         generation when is_integer(generation) and generation > 0 <-
           Map.get(connection, "generation"),
         reused when is_boolean(reused) <- Map.get(connection, "reused"),
         reconnected when is_boolean(reconnected) <- Map.get(connection, "reconnected") do
      %{
        lifecycle_id: lifecycle_id,
        generation: generation,
        reused: reused,
        reconnected: reconnected
      }
    else
      _invalid -> nil
    end
  end

  def build(_metadata), do: nil

  defp canonical_uuid(value)
       when is_binary(value) and byte_size(value) == @canonical_uuid_byte_size do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> :error
    end
  end

  defp canonical_uuid(_value), do: :error
end
