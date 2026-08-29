defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract do
  @moduledoc """
  Internal websocket owner contract helpers.

  This module only defines reusable owner-forwarding contracts. It does not start
  owners, route frames, renew leases, or change the active websocket runtime path.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.OwnerDefaults
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2

  @type owner_key :: Ecto.UUID.t()
  @type owner_token :: Ecto.UUID.t()
  @type correlation_id :: binary()
  @type downstream_epoch :: pos_integer()
  @type owner_turn_id :: pid()
  @type encoded_text_frame :: binary()
  @type upstream_request :: WebsocketOwnerRequest.t() | WebsocketOwnerRequestV2.t()

  @type owner_error ::
          :owner_unavailable
          | :stale_owner
          | :owner_forward_timeout
          | :owner_crashed
          | :owner_drained
          | :duplicate_downstream
          | :stale_downstream
          | :owner_forwarding_disabled
          | :owner_busy
          | :client_disconnected
          | :upstream_stream_error
          | :upstream_websocket_terminal_delivery_timeout

  @type request_status :: binary()
  @type attempt_status :: binary()

  @type safe_error_payload :: %{
          required(:status) => pos_integer(),
          required(:code) => binary(),
          required(:message) => binary(),
          required(:request_status) => request_status(),
          required(:attempt_status) => attempt_status(),
          required(:metadata) => %{
            required(:reason) => binary(),
            required(:owner_error) => binary()
          }
        }

  @type downstream_payload ::
          {:data, encoded_text_frame()}
          | {:error, owner_error(), safe_error_payload()}
          | :complete

  @type downstream_message ::
          {:websocket_owner_frame, correlation_id(), downstream_epoch(), downstream_payload()}
          | {:websocket_owner_frame, correlation_id(), downstream_epoch(), owner_turn_id(),
             downstream_payload()}

  @type forwarding_result ::
          :ok
          | {:ok, term()}
          | {:error, owner_error()}

  @type downstream_match_result ::
          {:ok, downstream_payload()} | :drop | {:error, :invalid_downstream_message}
  @type output_commit_probe ::
          {:websocket_owner_output_commit_probe, correlation_id(), downstream_epoch(),
           owner_turn_id(), reference(), pid(), reference()}
  @type output_commit_ack ::
          {:websocket_owner_output_commit_ack, correlation_id(), downstream_epoch(),
           owner_turn_id(), reference(), reference(), boolean()}
  @type handoff_outcome :: :ready | {:failed, :owner_forward_timeout | :owner_drained}
  @type handoff_message ::
          {:websocket_owner_handoff_ready, correlation_id(), downstream_epoch(), owner_turn_id(),
           pid(), reference()}
          | {:websocket_owner_handoff_failed, correlation_id(), downstream_epoch(),
             owner_turn_id(), pid(), reference(), :owner_forward_timeout | :owner_drained}

  @owner_errors CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary.owner_errors()

  @safe_error_payloads %{
    owner_busy: [
      status: 409,
      code: "owner_busy",
      message: "websocket owner is busy",
      reason: "owner_busy_backpressure"
    ],
    owner_forward_timeout: [
      status: 504,
      code: "owner_forward_timeout",
      message: "websocket owner forwarding timed out",
      reason: "owner_forward_timeout"
    ],
    owner_unavailable: [
      status: 503,
      code: "owner_unavailable",
      message: "websocket owner is unavailable",
      reason: "owner_unavailable"
    ],
    owner_crashed: [
      status: 502,
      code: "owner_crashed",
      message: "websocket owner stopped unexpectedly",
      reason: "owner_crashed"
    ],
    owner_drained: [
      status: 503,
      code: "owner_drained",
      message: "websocket owner is draining",
      reason: "owner_drained"
    ],
    client_disconnected: [
      status: 499,
      code: "client_disconnected",
      message: "websocket client disconnected",
      reason: "client_disconnected"
    ],
    upstream_stream_error: [
      status: 502,
      code: "server_error",
      message: :synthetic_public_openai_responses_failure_message,
      reason: "upstream_stream_error"
    ],
    upstream_websocket_terminal_delivery_timeout: [
      status: 502,
      code: "upstream_stream_error",
      message: "upstream websocket terminal delivery timed out",
      reason: "upstream_websocket_terminal_delivery_timeout"
    ],
    stale_owner: [
      status: 409,
      code: "stale_owner",
      message: "websocket owner lease is stale",
      reason: "stale_owner"
    ],
    duplicate_downstream: [
      status: 409,
      code: "duplicate_downstream",
      message: "websocket downstream was replaced",
      reason: "duplicate_downstream"
    ],
    stale_downstream: [
      status: 409,
      code: "stale_downstream",
      message: "websocket downstream is stale",
      reason: "stale_downstream"
    ],
    owner_forwarding_disabled: [
      status: 503,
      code: "owner_forwarding_disabled",
      message: "websocket owner forwarding is disabled",
      reason: "owner_forwarding_disabled"
    ]
  }

  @spec owner_errors() :: [owner_error()]
  def owner_errors, do: @owner_errors

  @spec owner_error?(term()) :: boolean()
  def owner_error?(error), do: error in @owner_errors

  @spec default_forward_timeout_ms() :: pos_integer()
  defdelegate default_forward_timeout_ms(), to: OwnerDefaults, as: :forward_timeout_ms

  @spec default_owner_call_timeout_ms() :: pos_integer()
  defdelegate default_owner_call_timeout_ms(), to: OwnerDefaults, as: :owner_call_timeout_ms

  @spec default_downstream_send_timeout_ms() :: pos_integer()
  defdelegate default_downstream_send_timeout_ms(),
    to: OwnerDefaults,
    as: :downstream_send_timeout_ms

  @spec safe_error_payload(term(), term()) ::
          {:ok, safe_error_payload()} | {:error, :unknown_owner_error}
  def safe_error_payload(error, _unsafe_context) do
    case Map.fetch(@safe_error_payloads, error) do
      {:ok, payload_attrs} -> {:ok, payload(resolve_payload_attrs(payload_attrs))}
      :error -> {:error, :unknown_owner_error}
    end
  end

  @spec downstream_message?(term()) :: boolean()
  def downstream_message?({:websocket_owner_frame, correlation_id, downstream_epoch, payload})
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0,
      do: downstream_payload?(payload)

  def downstream_message?(
        {:websocket_owner_frame, correlation_id, downstream_epoch, owner_turn_id, payload}
      )
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0 and
             is_pid(owner_turn_id),
      do: downstream_payload?(payload)

  def downstream_message?(_message), do: false

  @spec accept_downstream_message(term(), downstream_epoch(), correlation_id()) ::
          downstream_match_result()
  def accept_downstream_message(
        {:websocket_owner_frame, correlation_id, downstream_epoch, payload} = message,
        downstream_epoch,
        correlation_id
      )
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0 do
    if downstream_message?(message),
      do: {:ok, payload},
      else: {:error, :invalid_downstream_message}
  end

  def accept_downstream_message(
        {:websocket_owner_frame, correlation_id, downstream_epoch, _payload} = message,
        current_downstream_epoch,
        current_correlation_id
      )
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0 and
             is_binary(current_correlation_id) and is_integer(current_downstream_epoch) and
             current_downstream_epoch > 0 do
    if downstream_message?(message), do: :drop, else: {:error, :invalid_downstream_message}
  end

  def accept_downstream_message(
        {:websocket_owner_frame, _correlation_id, _downstream_epoch, _owner_turn_id, _payload} =
          message,
        _current_downstream_epoch,
        _current_correlation_id
      ) do
    if downstream_message?(message), do: :drop, else: {:error, :invalid_downstream_message}
  end

  def accept_downstream_message(_message, _current_downstream_epoch, _current_correlation_id),
    do: {:error, :invalid_downstream_message}

  @spec accept_downstream_message(
          term(),
          downstream_epoch(),
          correlation_id(),
          owner_turn_id()
        ) :: downstream_match_result()
  def accept_downstream_message(
        {:websocket_owner_frame, correlation_id, downstream_epoch, owner_turn_id, payload} =
          message,
        downstream_epoch,
        correlation_id,
        owner_turn_id
      )
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0 and
             is_pid(owner_turn_id) do
    if downstream_message?(message),
      do: {:ok, payload},
      else: {:error, :invalid_downstream_message}
  end

  def accept_downstream_message(
        {:websocket_owner_frame, _correlation_id, _downstream_epoch, _owner_turn_id, _payload} =
          message,
        _current_downstream_epoch,
        _current_correlation_id,
        _current_owner_turn_id
      ) do
    if downstream_message?(message), do: :drop, else: {:error, :invalid_downstream_message}
  end

  def accept_downstream_message(
        {:websocket_owner_frame, _correlation_id, _downstream_epoch, _payload} = message,
        _current_downstream_epoch,
        _current_correlation_id,
        _current_owner_turn_id
      ) do
    if downstream_message?(message), do: :drop, else: {:error, :invalid_downstream_message}
  end

  def accept_downstream_message(
        _message,
        _current_downstream_epoch,
        _current_correlation_id,
        _current_owner_turn_id
      ),
      do: {:error, :invalid_downstream_message}

  @spec output_commit_probe?(term()) :: boolean()
  def output_commit_probe?(
        {:websocket_owner_output_commit_probe, correlation_id, downstream_epoch, owner_turn_id,
         active_turn_ref, owner_pid, probe_ref}
      )
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0 and
             is_pid(owner_turn_id) and is_reference(active_turn_ref) and is_pid(owner_pid) and
             is_reference(probe_ref),
      do: true

  def output_commit_probe?(_message), do: false

  @spec accept_output_commit_probe(
          term(),
          downstream_epoch(),
          correlation_id(),
          owner_turn_id()
        ) :: {:ok, reference(), pid(), reference()} | :drop | {:error, :invalid_probe}
  def accept_output_commit_probe(
        {:websocket_owner_output_commit_probe, correlation_id, downstream_epoch, owner_turn_id,
         active_turn_ref, owner_pid, probe_ref} = message,
        downstream_epoch,
        correlation_id,
        owner_turn_id
      ) do
    if output_commit_probe?(message),
      do: {:ok, active_turn_ref, owner_pid, probe_ref},
      else: {:error, :invalid_probe}
  end

  def accept_output_commit_probe(message, _epoch, _correlation_id, _owner_turn_id) do
    if output_commit_probe?(message), do: :drop, else: {:error, :invalid_probe}
  end

  @spec output_commit_ack?(term()) :: boolean()
  def output_commit_ack?(
        {:websocket_owner_output_commit_ack, correlation_id, downstream_epoch, owner_turn_id,
         active_turn_ref, probe_ref, committed?}
      )
      when is_binary(correlation_id) and is_integer(downstream_epoch) and downstream_epoch > 0 and
             is_pid(owner_turn_id) and is_reference(active_turn_ref) and is_reference(probe_ref) and
             is_boolean(committed?),
      do: true

  def output_commit_ack?(_message), do: false

  @spec accept_output_commit_ack(
          term(),
          downstream_epoch(),
          correlation_id(),
          owner_turn_id(),
          reference(),
          reference()
        ) :: {:ok, boolean()} | :drop | {:error, :invalid_ack}
  def accept_output_commit_ack(
        {:websocket_owner_output_commit_ack, correlation_id, downstream_epoch, owner_turn_id,
         active_turn_ref, probe_ref, committed?} = message,
        downstream_epoch,
        correlation_id,
        owner_turn_id,
        active_turn_ref,
        probe_ref
      ) do
    if output_commit_ack?(message), do: {:ok, committed?}, else: {:error, :invalid_ack}
  end

  def accept_output_commit_ack(
        message,
        _epoch,
        _correlation_id,
        _owner_turn_id,
        _active_turn_ref,
        _probe_ref
      ) do
    if output_commit_ack?(message), do: :drop, else: {:error, :invalid_ack}
  end

  @spec accept_handoff_message(
          term(),
          pid(),
          downstream_epoch(),
          correlation_id(),
          owner_turn_id(),
          reference()
        ) :: {:ok, handoff_outcome()} | :drop | {:error, :invalid_handoff_message}
  def accept_handoff_message(
        {:websocket_owner_handoff_ready, correlation_id, epoch, owner_turn_id, downstream_pid,
         control_ref},
        downstream_pid,
        epoch,
        correlation_id,
        owner_turn_id,
        control_ref
      )
      when is_pid(downstream_pid) and is_integer(epoch) and epoch > 0 and
             is_binary(correlation_id) and is_pid(owner_turn_id) and is_reference(control_ref),
      do: {:ok, :ready}

  def accept_handoff_message(
        {:websocket_owner_handoff_failed, correlation_id, epoch, owner_turn_id, downstream_pid,
         control_ref, reason},
        downstream_pid,
        epoch,
        correlation_id,
        owner_turn_id,
        control_ref
      )
      when is_pid(downstream_pid) and is_integer(epoch) and epoch > 0 and
             is_binary(correlation_id) and is_pid(owner_turn_id) and is_reference(control_ref) and
             reason in [:owner_forward_timeout, :owner_drained],
      do: {:ok, {:failed, reason}}

  def accept_handoff_message(message, _pid, _epoch, _correlation_id, _owner_turn_id, _control_ref) do
    if handoff_message?(message), do: :drop, else: {:error, :invalid_handoff_message}
  end

  defp handoff_message?(
         {:websocket_owner_handoff_ready, correlation_id, epoch, owner_turn_id, downstream_pid,
          control_ref}
       ),
       do:
         is_binary(correlation_id) and is_integer(epoch) and epoch > 0 and
           is_pid(owner_turn_id) and is_pid(downstream_pid) and is_reference(control_ref)

  defp handoff_message?(
         {:websocket_owner_handoff_failed, correlation_id, epoch, owner_turn_id, downstream_pid,
          control_ref, reason}
       ),
       do:
         is_binary(correlation_id) and is_integer(epoch) and epoch > 0 and
           is_pid(owner_turn_id) and is_pid(downstream_pid) and is_reference(control_ref) and
           reason in [:owner_forward_timeout, :owner_drained]

  defp handoff_message?(_message), do: false

  defp downstream_payload?({:data, encoded_text_frame}) when is_binary(encoded_text_frame),
    do: true

  defp downstream_payload?({:error, error, payload})
       when error in @owner_errors and is_map(payload) do
    case safe_error_payload(error, nil) do
      {:ok, ^payload} -> true
      {:ok, _expected_payload} -> false
    end
  end

  defp downstream_payload?(:complete), do: true
  defp downstream_payload?(_payload), do: false

  defp resolve_payload_attrs(payload_attrs) do
    Keyword.update!(payload_attrs, :message, &resolve_message/1)
  end

  defp resolve_message(:synthetic_public_openai_responses_failure_message) do
    StreamProtocol.synthetic_public_openai_responses_failure_message()
  end

  defp resolve_message(message), do: message

  defp payload(status: status, code: code, message: message, reason: reason) do
    %{
      status: status,
      code: code,
      message: message,
      request_status: "failed",
      attempt_status: "failed",
      metadata: %{
        reason: reason,
        owner_error: code
      }
    }
  end
end
