defmodule CodexPooler.Gateway.Transports.Websocket.OwnerErrorDiagnostics do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  @boundaries [:retarget, :attach, :detach]
  @context_keys [:request_id, :codex_session_id, :owner_instance_id, :proxy_instance_id]

  @type boundary :: :retarget | :attach | :detach
  @type context :: %{
          optional(:request_id) => term(),
          optional(:codex_session_id) => term(),
          optional(:owner_instance_id) => term(),
          optional(:proxy_instance_id) => term()
        }

  @spec normalize(term(), boundary(), context()) ::
          {:error, WebsocketOwnerContract.owner_error()}
  def normalize(reason, boundary, context) when boundary in @boundaries and is_map(context) do
    if WebsocketOwnerContract.owner_error?(reason) do
      {:error, reason}
    else
      Logger.warning(
        "websocket owner reason collapsed " <>
          collapse_metadata(boundary, DiagnosticTaxonomy.reason_code(reason), context)
      )

      {:error, :owner_unavailable}
    end
  end

  defp collapse_metadata(boundary, reason_code, context) do
    fixed = [
      boundary: boundary,
      reason_code: reason_code || "unknown",
      canonical_error: :owner_unavailable
    ]

    correlators =
      Enum.map(@context_keys, fn key ->
        {key, DiagnosticTaxonomy.safe_correlator(Map.get(context, key))}
      end)

    Enum.map_join(fixed ++ correlators, " ", fn {key, value} -> "#{key}=#{value}" end)
  end
end
