defmodule CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold do
  @moduledoc false

  @enforce_keys [:owner, :ref]
  defstruct [:owner, :ref]

  @type t :: %__MODULE__{owner: pid(), ref: reference()}

  @spec new() :: t()
  def new, do: %__MODULE__{owner: self(), ref: make_ref()}

  @spec valid_shape?(term()) :: boolean()
  def valid_shape?(%__MODULE__{owner: owner, ref: ref}),
    do: is_pid(owner) and is_reference(ref)

  def valid_shape?(_hold), do: false
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold do
  def inspect(_hold, _opts), do: "#CompactionRetrySubmitHold<redacted>"
end
