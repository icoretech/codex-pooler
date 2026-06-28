defmodule CodexPooler.Gateway.Payloads.RequestOptions.RequestMetadata do
  @moduledoc false
  defstruct [
    :request_id,
    :client_request_id,
    :idempotency_key,
    :client_ip,
    :user_agent,
    :request_bytes,
    :upload_bytes,
    :request_content_type
  ]

  @type t :: %__MODULE__{
          request_id: Ecto.UUID.t() | nil,
          client_request_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          client_ip: term(),
          user_agent: String.t() | nil,
          request_bytes: non_neg_integer() | nil,
          upload_bytes: non_neg_integer() | nil,
          request_content_type: String.t() | nil
        }
end
