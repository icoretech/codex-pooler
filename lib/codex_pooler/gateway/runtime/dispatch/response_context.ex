defmodule CodexPooler.Gateway.Runtime.Dispatch.ResponseContext do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  defstruct [
    :context,
    :response,
    :response_usage,
    upstream_transport: nil,
    upstream_websocket_connection: nil
  ]

  @type t :: %__MODULE__{
          context: SelectedCandidateContext.t(),
          response: Req.Response.t(),
          response_usage: map() | nil,
          upstream_transport: :websocket | nil,
          upstream_websocket_connection: map() | nil
        }
end
