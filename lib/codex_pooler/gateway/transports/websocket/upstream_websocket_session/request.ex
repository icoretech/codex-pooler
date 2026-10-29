defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability

  # Keep the typed transient transport contract explicit; the wait observer
  # is independent of provider output and of the existing submission callback.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :url,
    :headers,
    :payload,
    :timeouts,
    :writer,
    :message_mapper,
    :frame_observer,
    :payload_write_observer,
    :submission_observer,
    :compaction_pending_observer,
    :reset_probe,
    :provider_credits_context,
    :native_codex_response_control,
    :native_compaction_capability,
    :native_compaction_metadata,
    :expected_connection_lifecycle,
    :forwarded_owner_send_handoff,
    :forwarded_owner_capability,
    :forwarded_owner,
    :native_replay_binding,
    :native_replay_proof,
    :provisional_token,
    :effective_serving_mode,
    :request_id,
    :attempt_id,
    :native_client_retry_observation,
    :client_retry_dispatch_authority,
    :native_response_steering,
    assignment_advertised?: false,
    connection_bound_continuation?: false,
    websocket_delivery_mode: :relay,
    forward_error_body?: true
  ]

  # Direct requests carry the lane; owner-forwarded requests bind its owner
  # before submission. Neither value is part of the provider payload.
  @type native_response_steering :: pid() | {pid(), pid()} | nil

  # Internal wait control, never a provider event or a collector writer. The
  # recipient binds it to its active socket/task/owner identity before delivery.
  @type compaction_pending :: %{
          request_id: Ecto.UUID.t(),
          attempt_id: Ecto.UUID.t(),
          upstream_pid: pid(),
          token: reference(),
          sequence: pos_integer(),
          remaining_ms: pos_integer()
        }
  @type compaction_pending_observer :: (compaction_pending() -> any()) | nil

  @type writer ::
          (binary() -> any())
          | (binary(), CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator.t() ->
               any())
          | nil
  @type delivery_mode :: :relay | :collect_compaction | :collect_full_history
  @type effective_serving_mode :: String.t() | nil
  # Called once in the upstream session process before the request's payload
  # is written to the provider (`UpstreamWebsocketSession`'s
  # `observe_payload_write/1`): `:ok` lets the write go ahead, any other answer
  # ends the request unsent.
  @type payload_write_observer :: (-> :ok | :refused) | nil
  @type frame_observer ::
          (binary() -> any())
          | (binary(), CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.decoded_frame() ->
               any())
          | nil

  @type t :: %__MODULE__{
          url: binary(),
          headers: [{binary(), binary()}],
          payload: binary(),
          timeouts: map(),
          writer: writer(),
          message_mapper: CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.message_mapper(),
          frame_observer: frame_observer(),
          payload_write_observer: payload_write_observer(),
          submission_observer: (-> any()) | nil,
          compaction_pending_observer: compaction_pending_observer(),
          reset_probe: ResetProbe.t() | nil,
          provider_credits_context: CodexPooler.Gateway.Transports.ProviderCreditsAdmission.Context.t() | nil,
          native_codex_response_control: TurnSnapshot.t() | nil,
          native_compaction_capability: Capability.t() | nil,
          native_compaction_metadata: CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata.t() | nil,
          expected_connection_lifecycle:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.connection_lifecycle_state()
            | nil,
          forwarded_owner_send_handoff: ForwardedOwnerRequestHandoff.t() | nil,
          forwarded_owner_capability: Capability.t() | nil,
          forwarded_owner: pid() | nil,
          native_replay_binding: CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding.t() | nil,
          native_replay_proof: CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof.t() | nil,
          provisional_token: <<_::256>> | nil,
          effective_serving_mode: effective_serving_mode(),
          request_id: Ecto.UUID.t() | nil,
          attempt_id: Ecto.UUID.t() | nil,
          native_client_retry_observation: CodexPooler.Accounting.ClientRetry.Observation.t() | nil,
          client_retry_dispatch_authority: CodexPooler.Accounting.ClientRetry.DispatchAuthority.t() | nil,
          native_response_steering: native_response_steering(),
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
