defmodule CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.RouteClass

  @type auth :: Access.auth_context()

  @spec attrs(auth(), map(), String.t(), RequestOptions.t()) :: map()
  def attrs(auth, payload, endpoint, %RequestOptions{} = request_options) when is_map(payload) do
    %RequestOptions{
      request_metadata: request_metadata,
      transport: transport
    } = request_options

    %{
      endpoint: endpoint,
      transport: transport.transport,
      correlation_id: RequestOptions.server_correlation_id(request_options),
      idempotency_key: request_metadata.idempotency_key,
      client_ip: request_metadata.client_ip,
      user_agent: request_metadata.user_agent,
      api_key_policy: request_options.routing.api_key_policy,
      request_metadata: request_metadata_attrs(auth, payload, endpoint, request_options)
    }
  end

  defp request_metadata_attrs(auth, payload, endpoint, request_options) do
    %RequestOptions{
      request_metadata: request_metadata,
      transport: transport,
      routing: routing
    } = request_options

    %{
      "key_prefix" => auth.key_prefix,
      "transport" => transport.transport,
      "requested_stream" => RouteClass.streaming?(payload),
      "endpoint" => endpoint,
      "requested_model" => routing.requested_model,
      "effective_model" => routing.effective_model,
      "enforced_model" => Denials.enforced_model_metadata(request_options),
      "request_bytes" => request_metadata.request_bytes,
      "upload_bytes" => request_metadata.upload_bytes,
      "request_content_type" => request_metadata.request_content_type,
      "quota_decision" => routing.quota_decision
    }
    |> Map.merge(RequestOptions.client_request_metadata(request_options))
    |> Map.merge(RequestOptions.openai_compatibility_metadata(request_options))
    |> Map.merge(owner_forwarding_metadata(request_options))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> SessionContinuity.put_session_metadata(request_options)
  end

  defp owner_forwarding_metadata(%RequestOptions{
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

  defp owner_forwarding_metadata(_request_options), do: %{}
end
