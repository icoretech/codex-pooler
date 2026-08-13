defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody

  defstruct [
    :writer,
    :timeouts,
    :message_mapper,
    :frame_observer,
    :native_codex_response_control,
    :response_id,
    :terminal_upstream_error_code,
    :terminal_upstream_error_param,
    :termination_source,
    :transport_signal,
    :connection_use,
    :connection_request_bucket,
    :connection_age_bucket,
    :connection_idle_bucket,
    :request_caller_pid,
    :request_caller_monitor,
    assignment_advertised?: false,
    native_metadata_emitted?: false,
    downstream_output_started?: false,
    terminal_seen?: false,
    last_upstream_event_type: "none",
    last_upstream_event_class: "none",
    terminal_candidate_seen?: false,
    terminal_candidate_type: nil,
    terminal_candidate_class: nil,
    terminal_candidate_rejection: nil,
    text_frame_count: 0,
    body: {[], 0},
    websocket_frame_headers: %{},
    peer_close_metadata: %{}
  ]

  @type t :: %__MODULE__{
          writer:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request.writer(),
          timeouts: map(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.message_mapper(),
          frame_observer:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request.frame_observer(),
          native_codex_response_control: TurnSnapshot.t() | nil,
          response_id: String.t() | nil,
          terminal_upstream_error_code: String.t() | nil,
          terminal_upstream_error_param: String.t() | nil,
          termination_source: atom() | nil,
          transport_signal: atom() | nil,
          connection_use: atom() | nil,
          connection_request_bucket: atom() | nil,
          connection_age_bucket: atom() | nil,
          connection_idle_bucket: atom() | nil,
          request_caller_pid: pid() | nil,
          request_caller_monitor: reference() | nil,
          assignment_advertised?: boolean(),
          native_metadata_emitted?: boolean(),
          downstream_output_started?: boolean(),
          terminal_seen?: boolean(),
          last_upstream_event_type: String.t(),
          last_upstream_event_class: String.t(),
          terminal_candidate_seen?: boolean(),
          terminal_candidate_type: String.t() | nil,
          terminal_candidate_class: String.t() | nil,
          terminal_candidate_rejection: String.t() | nil,
          text_frame_count: non_neg_integer(),
          websocket_frame_headers: %{optional(String.t()) => String.t()},
          peer_close_metadata:
            CodexPooler.Gateway.Transports.TransportFailureReason.transport_failure_metadata(),
          body: RetainedBody.t()
        }
end
