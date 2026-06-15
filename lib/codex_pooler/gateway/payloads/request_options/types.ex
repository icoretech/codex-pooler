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

defmodule CodexPooler.Gateway.Payloads.RequestOptions.WebsocketOwnerContext do
  @moduledoc false

  defstruct [
    :session,
    :lease_token,
    :downstream,
    :downstream_epoch,
    :proxy_instance_id,
    :owner_instance_id,
    enabled?: false,
    forwarder_opts: []
  ]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          session: term(),
          lease_token: String.t() | nil,
          downstream: map() | nil,
          downstream_epoch: pos_integer() | nil,
          proxy_instance_id: String.t() | nil,
          owner_instance_id: String.t() | nil,
          forwarder_opts: keyword()
        }
end

defmodule CodexPooler.Gateway.Payloads.RequestOptions.Transport do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.WebsocketOwnerContext

  defstruct [
    :transport,
    :upstream_endpoint,
    :websocket_writer,
    :upstream_websocket_session,
    :websocket_owner,
    :route_class,
    forwarded_metadata_headers: []
  ]

  @type websocket_writer :: (binary() -> any()) | nil

  @type t :: %__MODULE__{
          transport: String.t() | nil,
          upstream_endpoint: String.t() | nil,
          websocket_writer: websocket_writer(),
          forwarded_metadata_headers: [{String.t(), String.t()}],
          upstream_websocket_session: term(),
          websocket_owner: WebsocketOwnerContext.t(),
          route_class: String.t() | nil
        }
end

defmodule CodexPooler.Gateway.Payloads.RequestOptions.Continuity do
  @moduledoc false
  defstruct [
    :accepted_turn_state,
    :previous_response_id,
    :response_id,
    :session_header,
    :session_header_source,
    :session_key,
    :conversation_key,
    :owner_instance_id,
    :bridge_owner_lease_ttl_seconds,
    :reconnect_window_seconds,
    :codex_session,
    :codex_turn_id,
    :authenticated_owner_attach
  ]

  @type t :: %__MODULE__{
          accepted_turn_state: String.t() | nil,
          previous_response_id: String.t() | nil,
          response_id: String.t() | nil,
          session_header: String.t() | nil,
          session_header_source: String.t() | nil,
          session_key: String.t() | nil,
          conversation_key: String.t() | nil,
          owner_instance_id: String.t() | nil,
          bridge_owner_lease_ttl_seconds: pos_integer() | nil,
          reconnect_window_seconds: non_neg_integer() | nil,
          codex_session: term(),
          codex_turn_id: Ecto.UUID.t() | nil,
          authenticated_owner_attach: boolean()
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

defmodule CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig do
  @moduledoc false
  defstruct [:connect_timeout_ms, :pool_timeout_ms, :receive_timeout_ms]

  @type t :: %__MODULE__{
          connect_timeout_ms: non_neg_integer(),
          pool_timeout_ms: non_neg_integer(),
          receive_timeout_ms: non_neg_integer()
        }
end

defmodule CodexPooler.Gateway.Payloads.RequestOptions.PayloadContext do
  @moduledoc false
  defstruct [:media_upload, :forced_transcription_model]

  @type t :: %__MODULE__{
          media_upload: map() | nil,
          forced_transcription_model: String.t() | nil
        }
end

defmodule CodexPooler.Gateway.Payloads.RequestOptions.RuntimeContext do
  @moduledoc false
  defstruct [:now, :interrupt_reason, :gateway_debug_payload, :payload_compression]

  @type t :: %__MODULE__{
          now: DateTime.t() | nil,
          interrupt_reason: String.t() | nil,
          gateway_debug_payload: map() | nil,
          payload_compression: map() | nil
        }
end

defmodule CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility do
  @moduledoc false
  defstruct public_openai_responses_stream: false,
            public_openai_chat_stream: false,
            collect_openai_response_stream: false,
            collect_openai_image_stream: false,
            openai_chat_payload: nil,
            source_endpoint: nil,
            translated_endpoint: nil

  @type t :: %__MODULE__{
          public_openai_responses_stream: boolean(),
          public_openai_chat_stream: boolean(),
          collect_openai_response_stream: boolean(),
          collect_openai_image_stream: boolean(),
          openai_chat_payload: map() | nil,
          source_endpoint: String.t() | nil,
          translated_endpoint: String.t() | nil
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

defmodule CodexPooler.Gateway.Payloads.RequestOptions.FileBridgeContext do
  @moduledoc false
  defstruct [
    :operation,
    :endpoint,
    :route_metadata,
    :pool_upstream_assignment_id,
    :upstream_identity_id,
    :defer_create_request,
    :finalize_retry_timeout_ms,
    :finalize_retry_interval_ms,
    forwarded_headers: []
  ]

  @type t :: %__MODULE__{
          operation: atom() | String.t() | nil,
          endpoint: String.t() | nil,
          route_metadata: map() | nil,
          pool_upstream_assignment_id: Ecto.UUID.t() | nil,
          upstream_identity_id: Ecto.UUID.t() | nil,
          defer_create_request: boolean() | nil,
          finalize_retry_timeout_ms: non_neg_integer() | nil,
          finalize_retry_interval_ms: non_neg_integer() | nil,
          forwarded_headers: [{String.t(), String.t()}]
        }
end
