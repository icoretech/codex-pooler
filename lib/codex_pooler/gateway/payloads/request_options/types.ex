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

defmodule CodexPooler.Gateway.Payloads.RequestOptions.Routing do
  @moduledoc false
  defstruct [
    :requested_model,
    :effective_model,
    :api_key_policy,
    :file_affinity_assignment_id,
    :prompt_cache_key,
    :quota_decision,
    :routing_attempt_metadata,
    :routing_circuit_state,
    :use_responses_lite?
  ]

  @type t :: %__MODULE__{
          requested_model: String.t() | nil,
          effective_model: String.t() | nil,
          api_key_policy: map() | nil,
          file_affinity_assignment_id: Ecto.UUID.t() | nil,
          prompt_cache_key: String.t() | nil,
          quota_decision: map() | nil,
          routing_attempt_metadata: map() | nil,
          routing_circuit_state: term(),
          use_responses_lite?: boolean()
        }
end

defmodule CodexPooler.Gateway.Payloads.RequestOptions.UsageAuthentication do
  @moduledoc false
  defstruct [:authorization_header, :chatgpt_account_id]

  @type t :: %__MODULE__{
          authorization_header: String.t() | nil,
          chatgpt_account_id: String.t() | nil
        }
end
