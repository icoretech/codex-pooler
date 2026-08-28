defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot

  defstruct [
    :url,
    :headers,
    :payload,
    :timeouts,
    :writer,
    :message_mapper,
    :frame_observer,
    :submission_observer,
    :reset_probe,
    :native_codex_response_control,
    :effective_serving_mode,
    assignment_advertised?: false,
    connection_bound_continuation?: false,
    websocket_delivery_mode: :relay,
    forward_error_body?: true
  ]

  @type writer ::
          (binary() -> any())
          | (binary(),
             CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator.t() ->
               any())
          | nil
  @type delivery_mode :: :relay | :collect_compaction
  @type effective_serving_mode :: String.t() | nil
  @type frame_observer ::
          (binary() -> any())
          | (binary(),
             CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.decoded_frame() ->
               any())
          | nil

  @type t :: %__MODULE__{
          url: binary(),
          headers: [{binary(), binary()}],
          payload: binary(),
          timeouts: map(),
          writer: writer(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.message_mapper(),
          frame_observer: frame_observer(),
          submission_observer: (-> any()) | nil,
          reset_probe: ResetProbe.t() | nil,
          native_codex_response_control: TurnSnapshot.t() | nil,
          effective_serving_mode: effective_serving_mode(),
          assignment_advertised?: boolean(),
          connection_bound_continuation?: boolean(),
          websocket_delivery_mode: delivery_mode(),
          forward_error_body?: boolean()
        }
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request do
  def inspect(_request, _opts) do
    "#CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request<redacted>"
  end
end
