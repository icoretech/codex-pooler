defmodule CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame do
  @moduledoc """
  A validated websocket frame ready for local handling or gateway execution.

  Native turn identity is represented only by the opaque keys already stored in
  `RequestOptions`; raw client identity never crosses this boundary.

  Its capability is owned by the process that prepared the frame and is
  addressable through its distributed pid. A proxy socket can therefore retain
  one pending frame across a remote-owner handoff without sending the frame or
  capability through the data-only owner control protocol. Owner exit or the
  bounded capability lifetime invalidates pending execution.
  """

  alias __MODULE__.Capability
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @type variant ::
          :native_response_create
          | :public_response_create
          | :prewarm
          | :response_processed

  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}

  @enforce_keys [:variant, :endpoint, :payload, :request_options]
  defstruct [
    :variant,
    :endpoint,
    :payload,
    :request_options,
    :semantic_turn_key,
    :turn_claim_key,
    :result_adapter,
    :provenance
  ]

  @type t :: %__MODULE__{
          variant: variant(),
          endpoint: String.t(),
          payload: map(),
          request_options: RequestOptions.t(),
          semantic_turn_key: <<_::256>> | nil,
          turn_claim_key: String.t() | nil,
          result_adapter: (gateway_call_result() -> gateway_call_result()) | nil,
          provenance:
            %{
              required(:frame) => binary(),
              required(:validation) => binary(),
              required(:capability) => Capability.t()
            }
            | nil
        }
end
