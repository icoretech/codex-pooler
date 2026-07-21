defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract do
  @moduledoc """
  Internal websocket owner contract helpers.

  This module only defines reusable owner-forwarding contracts. It does not start
  owners, route frames, renew leases, or change the active websocket runtime path.
  """

  @type owner_key :: Ecto.UUID.t()
  @type owner_token :: Ecto.UUID.t()
  @type correlation_id :: binary()
  @type downstream_epoch :: pos_integer()
  @type owner_turn_id :: pid()
  @type encoded_text_frame :: binary()

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

  @owner_errors [
    :owner_unavailable,
    :stale_owner,
    :owner_forward_timeout,
    :owner_crashed,
    :owner_drained,
    :duplicate_downstream,
    :stale_downstream,
    :owner_forwarding_disabled,
    :owner_busy,
    :client_disconnected
  ]

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

  @default_forward_timeout_ms 5_000
  @default_owner_call_timeout_ms 5_000
  @default_downstream_send_timeout_ms 1_000

  @spec owner_errors() :: [owner_error()]
  def owner_errors, do: @owner_errors

  @spec owner_error?(term()) :: boolean()
  def owner_error?(error), do: error in @owner_errors

  @spec default_forward_timeout_ms() :: pos_integer()
  def default_forward_timeout_ms, do: @default_forward_timeout_ms

  @spec default_owner_call_timeout_ms() :: pos_integer()
  def default_owner_call_timeout_ms, do: @default_owner_call_timeout_ms

  @spec default_downstream_send_timeout_ms() :: pos_integer()
  def default_downstream_send_timeout_ms, do: @default_downstream_send_timeout_ms

  @spec safe_error_payload(term(), term()) ::
          {:ok, safe_error_payload()} | {:error, :unknown_owner_error}
  def safe_error_payload(error, _unsafe_context) do
    case Map.fetch(@safe_error_payloads, error) do
      {:ok, payload_attrs} -> {:ok, payload(payload_attrs)}
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
