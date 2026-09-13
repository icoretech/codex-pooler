defmodule CodexPooler.Gateway.Transports.Websocket.ResponseProcessed do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata, as: FinalizationMetadata
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Repo
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

    handle_prepared(auth, payload, request_options)
  end

  @spec handle_prepared(auth(), map(), RequestOptions.t()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def handle_prepared(auth, payload, %RequestOptions{} = request_options)
      when is_map(payload) do
    with :ok <- authorize_api_key(auth, request_options) do
      forward_and_record(auth, payload, request_options)
    end
  end

  defp forward_and_record(auth, payload, %RequestOptions{} = request_options) do
    case UpstreamDispatch.forward_response_processed(payload, request_options) do
      :ok ->
        with :ok <- record_processed_ack(auth, payload, request_options) do
          {:ok, WebsocketCodec.ack_result()}
        end

      {:error, reason} ->
        {:error, forward_error(reason)}
    end
  end

  # An acknowledgement has no turn claim or reservation behind it, so nothing
  # else fences the forward. The socket rereads authorization when a frame
  # arrives, but a frame that waited in the queue behind an admitted turn, or
  # one an owner node runs for another node's socket, reaches this point long
  # after that check. The reader-mode authorization the websocket claim uses
  # therefore runs here, before the frame can reach the upstream websocket, and
  # a refusal returns the runtime disposition unchanged so the socket latches
  # revocation and closes with 1008. A database exception propagates: the
  # response task fails and nothing is forwarded.
  #
  # A context without an API key id or a captured epoch cannot come from a live
  # socket. It is refused as a gateway error that carries no disabling epoch,
  # because an invented epoch or a missing-key disposition would latch
  # revocation and close a socket whose key is still usable.
  defp authorize_api_key(auth, %RequestOptions{} = request_options) do
    with {:ok, api_key_id} <- auth_api_key_id(auth),
         {:ok, captured_epoch} <- captured_api_key_epoch(auth, request_options) do
      authorize_turn_for_read(api_key_id, captured_epoch)
    end
  end

  defp authorize_turn_for_read(api_key_id, captured_epoch) do
    case Repo.transact(fn ->
           Access.authorize_api_key_runtime_turn_for_read(api_key_id, captured_epoch)
         end) do
      {:ok, %{api_key: _api_key, runtime_revocation_epoch: _epoch}} -> :ok
      {:error, disposition} -> {:error, disposition}
    end
  end

  defp auth_api_key_id(%{api_key: %{id: api_key_id}}) when is_binary(api_key_id),
    do: {:ok, api_key_id}

  defp auth_api_key_id(_auth), do: {:error, authorization_context_error()}

  defp captured_api_key_epoch(_auth, %RequestOptions{runtime: %{api_key_runtime_epoch: epoch}})
       when is_integer(epoch) and epoch >= 0,
       do: {:ok, epoch}

  defp captured_api_key_epoch(%{api_key: %{runtime_revocation_epoch: epoch}}, _request_options)
       when is_integer(epoch) and epoch >= 0,
       do: {:ok, epoch}

  defp captured_api_key_epoch(_auth, _request_options),
    do: {:error, authorization_context_error()}

  defp authorization_context_error do
    error(
      500,
      "api_key_authorization_context_missing",
      "response.processed has no API key authorization context"
    )
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
           websocket_owner: %{
             enabled?: true,
             downstream_epoch: downstream_epoch,
             proxy_instance_id: proxy_instance_id,
             owner_instance_id: owner_instance_id
           }
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
