defmodule CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting.PricingResolution
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.RouteClass

  @type auth :: Access.auth_context()

  @spec attrs(auth(), map(), String.t(), RequestOptions.t()) :: map()
  def attrs(auth, payload, endpoint, %RequestOptions{} = request_options) when is_map(payload) do
    attrs(auth, payload, endpoint, request_options, nil)
  end

  @spec attrs(auth(), map(), String.t(), RequestOptions.t(), RouteState.t() | nil) :: map()
  def attrs(auth, payload, endpoint, %RequestOptions{} = request_options, route_state)
      when is_map(payload) do
    %RequestOptions{
      request_metadata: request_metadata,
      transport: transport
    } = request_options

    accounting_endpoint = accounting_endpoint(endpoint, request_options)

    %{
      endpoint: accounting_endpoint,
      transport: transport.transport,
      correlation_id: RequestOptions.server_correlation_id(request_options),
      idempotency_key: request_metadata.idempotency_key,
      client_ip: request_metadata.client_ip,
      user_agent: request_metadata.user_agent,
      api_key_policy: request_options.routing.api_key_policy,
      request_metadata:
        request_metadata_attrs(auth, payload, accounting_endpoint, request_options, route_state)
    }
  end

  @spec reservation_snapshot_inputs(auth(), Model.t(), map(), String.t(), RequestOptions.t()) ::
          RouteState.reservation_snapshot_inputs()
  def reservation_snapshot_inputs(
        %{pool: pool, api_key: api_key},
        %Model{} = model,
        payload,
        endpoint,
        %RequestOptions{} = request_options
      )
      when is_map(payload) do
    effective_model = request_options.routing.effective_model || model.exposed_model_id

    {:ok, estimate} =
      PricingResolution.reservation_estimate(
        payload,
        nil,
        nil
      )

    %{}
    |> Map.put(:pool_id, pool.id)
    |> Map.put(:api_key_id, api_key.id)
    |> Map.put(:effective_model, effective_model)
    |> Map.put(:route_class, RequestOptions.route_class(request_options))
    |> Map.put(:request_class, request_class(endpoint, request_options))
    |> Map.put(:estimated_input_tokens, estimate.input_tokens)
    |> Map.put(:estimated_output_tokens, estimate.output_tokens)
    |> Map.put(:estimated_total_tokens, estimate.total_tokens)
    |> Map.put(:quota_window_dimension_keys, quota_window_dimension_keys(api_key.id))
  end

  defp accounting_endpoint(
         _endpoint,
         %RequestOptions{
           transport: %{transport: "websocket"},
           openai_compatibility: %{source_endpoint: source_endpoint}
         }
       )
       when is_binary(source_endpoint),
       do: source_endpoint

  defp accounting_endpoint(endpoint, _request_options), do: endpoint

  defp request_metadata_attrs(auth, payload, endpoint, request_options, route_state) do
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
    |> Map.merge(reservation_snapshot_metadata(route_state))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> SessionContinuity.put_session_metadata(request_options)
  end

  defp reservation_snapshot_metadata(%RouteState{reservation_snapshot_inputs: snapshot_inputs})
       when is_map(snapshot_inputs) do
    %{
      "reservation_snapshot_inputs" => %{
        "pool_id" => snapshot_inputs.pool_id,
        "api_key_id" => snapshot_inputs.api_key_id,
        "effective_model" => snapshot_inputs.effective_model,
        "route_class" => snapshot_inputs.route_class,
        "request_class" => snapshot_inputs.request_class,
        "estimated_input_tokens" => snapshot_inputs.estimated_input_tokens,
        "estimated_output_tokens" => snapshot_inputs.estimated_output_tokens,
        "estimated_total_tokens" => snapshot_inputs.estimated_total_tokens,
        "quota_window_dimension_keys" => snapshot_inputs.quota_window_dimension_keys
      }
    }
  end

  defp reservation_snapshot_metadata(_route_state), do: %{}

  defp request_class(
         _endpoint,
         %RequestOptions{transport: %{transport: transport}}
       )
       when is_binary(transport),
       do: transport

  defp request_class(endpoint, _request_options), do: endpoint

  defp quota_window_dimension_keys(api_key_id) do
    [
      %{
        api_key_id: api_key_id,
        window_kind: "minute",
        metric: "request_count",
        policy_field: "max_requests_per_minute"
      },
      %{
        api_key_id: api_key_id,
        window_kind: "daily",
        metric: "total_tokens",
        policy_field: "max_tokens_per_day"
      },
      %{
        api_key_id: api_key_id,
        window_kind: "weekly",
        metric: "total_tokens",
        policy_field: "max_tokens_per_week"
      }
    ]
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
