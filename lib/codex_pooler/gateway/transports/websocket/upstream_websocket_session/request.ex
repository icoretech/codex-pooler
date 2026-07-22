defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe

  defstruct [
    :url,
    :headers,
    :payload,
    :timeouts,
    :writer,
    :message_mapper,
    :frame_observer,
    :reset_probe,
    assignment_advertised?: false,
    forward_error_body?: true
  ]

  @type writer :: (binary() -> any())
  @type frame_observer :: (binary() -> any()) | nil

  @type t :: %__MODULE__{
          url: binary(),
          headers: [{binary(), binary()}],
          payload: binary(),
          timeouts: map(),
          writer: writer(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.message_mapper(),
          frame_observer: frame_observer(),
          reset_probe: ResetProbe.t() | nil,
          assignment_advertised?: boolean(),
          forward_error_body?: boolean()
        }
end
