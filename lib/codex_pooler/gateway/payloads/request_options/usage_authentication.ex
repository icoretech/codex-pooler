defmodule CodexPooler.Gateway.Payloads.RequestOptions.UsageAuthentication do
  @moduledoc false
  defstruct [:authorization_header, :chatgpt_account_id]

  @type t :: %__MODULE__{
          authorization_header: String.t() | nil,
          chatgpt_account_id: String.t() | nil
        }
end
