defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Callbacks do
  @moduledoc false

  alias CodexPooler.Accounting.RequestReplay
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @enforce_keys [
    :upstream_sender,
    :upstream_closer,
    :upstream_invalidator,
    :downstream_sender,
    :monotonic_now_ms,
    :replay_suspender,
    :replay_status_reader
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          upstream_sender: (pid(), Request.t() | binary(), function() | nil ->
                              WebsocketOwnerSession.request_result()),
          upstream_closer: (pid() -> :ok),
          upstream_invalidator: (pid() -> :ok | {:error, atom()}),
          downstream_sender: (pid(), tuple() -> :ok | {:error, atom()}),
          monotonic_now_ms: (-> integer()),
          replay_suspender: (RequestReplay.arm_input() -> {:ok, map()} | {:error, term()}),
          replay_status_reader: (map() -> term())
        }
end
