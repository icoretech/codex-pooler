defmodule CodexPooler.Gateway.Transports.Websocket.ResponseProcessed do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata, as: FinalizationMetadata
  alias CodexPooler.Gateway.Transports.Streaming.WebSocketCodec
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.RouteClass

  @endpoint "/backend-api/codex/responses"

  @type auth :: Access.auth_context()
  @type gateway_result :: Contracts.gateway_result()
  @type gateway_error :: Contracts.gateway_error()

  @spec handle(auth(), map(), RequestOptions.t()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def handle(auth, payload, %RequestOptions{} = opts) when is_map(payload) do
    request_options =
      opts
      |> RequestOptions.for_payload(@endpoint, payload)
      |> RequestOptions.put_transport(
        transport: "websocket",
        upstream_endpoint: @endpoint,
        route_class: RouteClass.proxy_websocket()
      )

    case UpstreamDispatch.forward_response_processed(payload, request_options) do
      :ok ->
        with :ok <- record_processed_ack(auth, payload, request_options) do
          {:ok, WebSocketCodec.ack_result()}
        end

      {:error, reason} ->
        {:error, forward_error(reason)}
    end
  end

  defp record_processed_ack(auth, payload, %RequestOptions{} = request_options) do
    attrs = %{
      endpoint: @endpoint,
      transport: "websocket",
      status: "succeeded",
      correlation_id: correlation_id(payload, request_options),
      client_ip: request_options.request_metadata.client_ip,
      user_agent: request_options.request_metadata.user_agent,
      request_metadata: metadata(auth, request_options),
      response_status_code: 200
    }

    case Accounting.record_metadata_request(auth, attrs) do
      {:ok, %{request: _request}} -> :ok
      {:error, reason} -> {:error, accounting_failure_error(reason)}
    end
  end

  defp metadata(auth, request_options) do
    %{
      "key_prefix" => auth.key_prefix,
      "transport" => "websocket",
      "requested_stream" => false,
      "endpoint" => @endpoint,
      "request_bytes" => request_options.request_metadata.request_bytes,
      "response_processed" => true
    }
    |> Map.merge(websocket_owner_forwarding_metadata(request_options))
    |> maybe_put_codex_session_metadata(request_options)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp websocket_owner_forwarding_metadata(%RequestOptions{
         transport: %{
           websocket_owner_forwarding_enabled?: true,
           websocket_owner_downstream_epoch: downstream_epoch,
           websocket_owner_proxy_instance_id: proxy_instance_id,
           websocket_owner_instance_id: owner_instance_id
         }
       }) do
    %{
      "websocket_owner_forwarding" => %{
        "enabled" => true,
        "downstream_epoch" => downstream_epoch,
        "proxy_instance_id" => proxy_instance_id,
        "owner_instance_id" => owner_instance_id
      }
    }
  end

  defp websocket_owner_forwarding_metadata(_request_options), do: %{}

  defp maybe_put_codex_session_metadata(metadata, %RequestOptions{
         continuity: %{codex_session: %CodexSession{} = session}
       }) do
    metadata
    |> Map.put("codex_session_id", session.id)
    |> Map.put("codex_session_key", session.session_key)
  end

  defp maybe_put_codex_session_metadata(metadata, %RequestOptions{}), do: metadata

  defp correlation_id(payload, request_options) do
    SessionContinuity.websocket_turn_id(payload) || request_options.request_metadata.request_id ||
      Ecto.UUID.generate()
  end

  defp accounting_failure_error(reason) do
    error(500, "gateway_accounting_failed", "gateway accounting failed", nil, %{
      accounting_error: FinalizationMetadata.safe_reason(reason)
    })
  end

  defp forward_error(:missing_response_id) do
    error(400, "invalid_request", "response.processed requires response_id")
  end

  defp forward_error(reason) do
    error(
      502,
      "upstream_websocket_forward_failed",
      "response.processed could not be forwarded upstream: #{FinalizationMetadata.safe_reason(reason)}"
    )
  end

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
