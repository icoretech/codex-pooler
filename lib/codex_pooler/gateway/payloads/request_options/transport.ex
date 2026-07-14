defmodule CodexPooler.Gateway.Payloads.RequestOptions.Transport do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization
  alias CodexPooler.Gateway.Payloads.RequestOptions.WebsocketOwnerContext
  alias CodexPooler.RouteClass

  defstruct [
    :transport,
    :upstream_endpoint,
    :websocket_writer,
    :upstream_websocket_session,
    :websocket_owner,
    :route_class,
    forwarded_metadata_headers: [],
    upstream_websocket_bridge?: false
  ]

  @type websocket_writer :: (binary() -> any()) | nil

  @type t :: %__MODULE__{
          transport: String.t() | nil,
          upstream_endpoint: String.t() | nil,
          websocket_writer: websocket_writer(),
          forwarded_metadata_headers: [{String.t(), String.t()}],
          upstream_websocket_session: term(),
          websocket_owner: WebsocketOwnerContext.t(),
          route_class: String.t() | nil,
          upstream_websocket_bridge?: boolean()
        }

  @spec build(map() | keyword(), String.t(), map()) :: t()
  def build(opts, endpoint, payload) when is_map(payload) do
    opts = Map.new(opts)

    %__MODULE__{
      transport: Map.get(opts, :transport) || default(endpoint, payload),
      upstream_endpoint: Map.get(opts, :upstream_endpoint) || endpoint,
      websocket_writer: Map.get(opts, :websocket_writer),
      forwarded_metadata_headers:
        Normalization.forwarded_headers(Map.get(opts, :forwarded_headers, [])),
      upstream_websocket_session: Map.get(opts, :upstream_websocket_session),
      websocket_owner: WebsocketOwnerContext.build(opts),
      route_class: route_class(opts, endpoint, payload)
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = transport, updates) do
    updates = Map.new(updates)

    {owner_updates, transport_updates} =
      Map.split(updates, [
        :websocket_owner,
        :websocket_owner_forwarding_enabled?,
        :websocket_owner_reject_if_busy?,
        :websocket_owner_session,
        :websocket_owner_lease_token,
        :websocket_owner_downstream,
        :websocket_owner_downstream_epoch,
        :websocket_owner_proxy_instance_id,
        :websocket_owner_instance_id,
        :websocket_owner_forwarder_opts
      ])

    transport =
      transport_updates
      |> Normalization.normalize_optional_update(
        :forwarded_metadata_headers,
        &Normalization.forwarded_headers_update/1
      )
      |> then(&struct!(transport, &1))

    if map_size(owner_updates) == 0 do
      transport
    else
      owner = transport.websocket_owner || %WebsocketOwnerContext{}
      %{transport | websocket_owner: WebsocketOwnerContext.update(owner, owner_updates)}
    end
  end

  @spec retarget(t(), String.t(), map()) :: t()
  def retarget(%__MODULE__{} = transport, endpoint, payload) when is_map(payload) do
    transport_name = transport.transport || default(endpoint, payload)

    %__MODULE__{
      transport
      | transport: transport_name,
        upstream_endpoint: endpoint,
        route_class: route_class(%{transport: transport_name}, endpoint, payload)
    }
  end

  @spec route_class(map() | keyword(), String.t(), map()) :: String.t() | nil
  def route_class(opts, endpoint, payload) when is_map(payload) do
    opts = Map.new(opts)
    transport = Map.get(opts, :transport) || Map.get(opts, "transport")
    RouteClass.classify(endpoint, payload, transport)
  end

  @spec default(String.t(), map()) :: String.t()
  def default("/backend-api/transcribe", _payload), do: "http_multipart"

  def default(endpoint, payload) when is_map(payload) do
    if RouteClass.streaming?(payload), do: "http_sse", else: compact_transport(endpoint)
  end

  defp compact_transport(endpoint)
       when endpoint in [
              "/backend-api/codex/responses/compact",
              "/backend-api/codex/v1/responses/compact"
            ],
       do: "http_compact_json"

  defp compact_transport(_endpoint), do: "http_json"
end
