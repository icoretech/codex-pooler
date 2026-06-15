defmodule CodexPooler.Gateway.RequestCompression.Eligibility do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.RouteClass

  @backend_responses_endpoint "/backend-api/codex/responses"
  @backend_responses_alias_endpoint "/backend-api/codex/v1/responses"
  @backend_chat_alias_endpoint "/backend-api/codex/v1/chat/completions"
  @public_responses_endpoint "/v1/responses"
  @public_chat_endpoint "/v1/chat/completions"

  @backend_compact_endpoint "/backend-api/codex/responses/compact"
  @backend_compact_alias_endpoint "/backend-api/codex/v1/responses/compact"
  @public_unsupported_compact_endpoint "/v1/responses/compact"

  @eligible_route_classes MapSet.new([
                            RouteClass.proxy_http(),
                            RouteClass.proxy_stream(),
                            RouteClass.proxy_compact(),
                            RouteClass.proxy_websocket()
                          ])

  @eligible_transports MapSet.new(~w(http http_json http_sse http_compact_json websocket))

  @responses_source_endpoints [
    @backend_responses_endpoint,
    @backend_responses_alias_endpoint,
    @backend_chat_alias_endpoint,
    @public_responses_endpoint,
    @public_chat_endpoint
  ]

  @compact_source_endpoints [
    @backend_compact_endpoint,
    @backend_compact_alias_endpoint
  ]

  @type decision :: {:eligible, map()} | {:skip, atom(), map()}

  @spec check(term(), term(), RequestOptions.t()) :: decision()
  def check(upstream_payload, context, %RequestOptions{} = request_options) do
    metadata = base_metadata(upstream_payload, context, request_options)

    cond do
      not metadata.enabled ->
        {:skip, :pool_disabled, metadata}

      payload_kind(upstream_payload) != :json ->
        {:skip, :payload_kind_ineligible, metadata}

      not eligible_route_class?(metadata.route_class) ->
        {:skip, :route_ineligible, metadata}

      not eligible_transport?(metadata.transport) ->
        {:skip, :transport_ineligible, metadata}

      not eligible_endpoint?(context, request_options, metadata.route_class) ->
        {:skip, :route_ineligible, metadata}

      true ->
        {:eligible, metadata}
    end
  end

  defp base_metadata(upstream_payload, context, %RequestOptions{} = request_options) do
    bytes = payload_bytes(upstream_payload)

    %{
      enabled: pool_enabled?(context),
      route_class: route_class(context, request_options),
      transport: transport(request_options),
      original_bytes: bytes,
      compressed_bytes: bytes
    }
  end

  defp pool_enabled?(context) do
    context
    |> field(:route_state)
    |> field(:routing_settings)
    |> field(:request_compression_enabled)
    |> Kernel.==(true)
  end

  defp payload_kind(payload) when is_binary(payload), do: :json
  defp payload_kind({:multipart, parts}) when is_list(parts), do: :multipart
  defp payload_kind(_payload), do: :unsupported

  defp payload_bytes(payload) when is_binary(payload), do: byte_size(payload)
  defp payload_bytes(_payload), do: nil

  defp route_class(context, %RequestOptions{} = request_options) do
    field(context, :route_class) ||
      field(request_options.transport, :route_class) ||
      RequestOptions.route_class(request_options)
  end

  defp transport(%RequestOptions{} = request_options) do
    field(request_options.transport, :transport)
  end

  defp eligible_route_class?(route_class) when is_binary(route_class) do
    MapSet.member?(@eligible_route_classes, route_class)
  end

  defp eligible_route_class?(_route_class), do: false

  defp eligible_transport?(transport) when is_binary(transport) do
    MapSet.member?(@eligible_transports, transport)
  end

  defp eligible_transport?(_transport), do: false

  defp eligible_endpoint?(context, %RequestOptions{} = request_options, route_class) do
    endpoints = endpoint_metadata(context, request_options)

    cond do
      public_unsupported_compact?(endpoints) ->
        false

      route_class == RouteClass.proxy_compact() ->
        compact_endpoint?(source_endpoint(endpoints)) and
          endpoints.upstream_endpoint == @backend_compact_endpoint

      route_class == RouteClass.proxy_websocket() ->
        responses_endpoint?(source_endpoint(endpoints)) and
          endpoints.upstream_endpoint == @backend_responses_endpoint

      route_class in [RouteClass.proxy_http(), RouteClass.proxy_stream()] ->
        responses_endpoint?(source_endpoint(endpoints)) and
          endpoints.upstream_endpoint == @backend_responses_endpoint

      true ->
        false
    end
  end

  defp endpoint_metadata(context, %RequestOptions{} = request_options) do
    compatibility = request_options.openai_compatibility

    %{
      endpoint: safe_endpoint(field(context, :endpoint)),
      source_endpoint: safe_endpoint(field(compatibility, :source_endpoint)),
      translated_endpoint: safe_endpoint(field(compatibility, :translated_endpoint)),
      upstream_endpoint: safe_endpoint(field(request_options.transport, :upstream_endpoint))
    }
  end

  defp source_endpoint(%{source_endpoint: source_endpoint}) when is_binary(source_endpoint),
    do: source_endpoint

  defp source_endpoint(%{endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp source_endpoint(%{translated_endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp source_endpoint(_endpoints), do: nil

  defp responses_endpoint?(endpoint) when endpoint in @responses_source_endpoints, do: true
  defp responses_endpoint?(_endpoint), do: false

  defp compact_endpoint?(endpoint) when endpoint in @compact_source_endpoints, do: true
  defp compact_endpoint?(_endpoint), do: false

  defp public_unsupported_compact?(endpoints) do
    endpoints
    |> Map.values()
    |> Enum.any?(&(&1 == @public_unsupported_compact_endpoint))
  end

  defp safe_endpoint(value) when is_binary(value) do
    if String.starts_with?(value, "/"), do: value
  end

  defp safe_endpoint(_value), do: nil

  defp field(value, key) when is_map(value) and is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, value} -> value
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil
end
