defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState do
  @moduledoc false

  defstruct [
    :writer,
    :timeouts,
    :message_mapper,
    :frame_observer,
    :terminal_upstream_error_code,
    :terminal_upstream_error_param,
    assignment_advertised?: false,
    downstream_output_started?: false,
    terminal_seen?: false,
    text_frame_count: 0,
    body: "",
    websocket_frame_headers: %{},
    peer_close_metadata: %{}
  ]

  @type t :: %__MODULE__{
          writer: (binary() -> any()),
          timeouts: map(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.message_mapper(),
          frame_observer:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request.frame_observer(),
          terminal_upstream_error_code: String.t() | nil,
          terminal_upstream_error_param: String.t() | nil,
          assignment_advertised?: boolean(),
          downstream_output_started?: boolean(),
          terminal_seen?: boolean(),
          text_frame_count: non_neg_integer(),
          websocket_frame_headers: %{optional(String.t()) => String.t()},
          peer_close_metadata:
            CodexPooler.Gateway.Transports.TransportFailureReason.transport_failure_metadata(),
          body: binary()
        }
end
