defmodule CodexPooler.Accounting.RequestLogs.CompactionBridgeProjection do
  @moduledoc false

  @type t :: %{required(:applied) => true, required(:result_transport) => String.t()}

  @spec build(map()) :: t() | nil
  def build(%{
        "compaction_bridge" =>
          %{
            "applied" => true,
            "result_transport" => result_transport
          } = bridge
      })
      when map_size(bridge) == 2 and result_transport in ["buffered", "sse"] do
    %{applied: true, result_transport: result_transport}
  end

  def build(_metadata), do: nil
end
