defmodule CodexPooler.Gateway.Runtime.Dispatch.PreparedContext do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  defstruct [
    :context,
    :url,
    :token,
    :upstream_payload,
    :routing_hint_authorized?
  ]

  @type t :: %__MODULE__{
          context: SelectedCandidateContext.t(),
          url: String.t(),
          token: String.t(),
          upstream_payload: binary() | {:multipart, list()},
          routing_hint_authorized?: boolean()
        }
end
