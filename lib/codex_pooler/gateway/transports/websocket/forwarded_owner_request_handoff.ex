defmodule CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @redeem_timeout_ms 5_000
  @enforce_keys [:owner, :witness]
  defstruct [:owner, :witness]

  @type t :: %__MODULE__{
          owner: GenServer.server(),
          witness: ForwardedSendWitnessV1.t()
        }

  @spec new(GenServer.server(), ForwardedSendWitnessV1.t()) :: t()
  def new(owner, %ForwardedSendWitnessV1{} = witness),
    do: %__MODULE__{owner: owner, witness: witness}

  @spec redeem(t(), map(), :full | :lite) :: :ok | {:error, atom()}
  def redeem(%__MODULE__{} = handoff, live_lifecycle_snapshot, serving_mode) do
    redeem(handoff, live_lifecycle_snapshot, serving_mode, @redeem_timeout_ms)
  end

  @doc false
  @spec redeem(t(), map(), :full | :lite, pos_integer()) :: :ok | {:error, atom()}
  def redeem(
        %__MODULE__{owner: owner, witness: witness},
        live_lifecycle_snapshot,
        serving_mode,
        timeout_ms
      )
      when is_integer(timeout_ms) and timeout_ms > 0 do
    WebsocketOwnerSession.redeem_forwarded_send(
      owner,
      witness,
      live_lifecycle_snapshot,
      serving_mode,
      timeout_ms
    )
  end
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff do
  def inspect(_handoff, _opts), do: "#ForwardedOwnerRequestHandoff<redacted>"
end
