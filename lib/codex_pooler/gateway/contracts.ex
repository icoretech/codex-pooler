defmodule CodexPooler.Gateway.Contracts do
  @moduledoc false

  @pinned_continuation_reauth_required_code "pinned_continuation_reauth_required"
  @restart_with_full_context_recovery_kind "restart_with_full_context"
  @continuation_anchor_body_fields ["previous_response_id"]
  @continuation_anchor_headers [
    "x-codex-previous-response-id",
    "x-codex-turn-state",
    "x-codex-window-id",
    "x-codex-session-id",
    "session-id",
    "x-session-affinity",
    "session_id",
    "x-codex-conversation-id"
  ]

  @type response_headers :: [{String.t(), String.t()}]
  @type recovery_anchor_guidance :: %{
          required(String.t()) => [String.t()]
        }
  @type recovery_contract :: %{
          required(String.t()) => String.t() | [String.t()] | recovery_anchor_guidance()
        }
  @type client_recovery_fields :: %{
          required(String.t()) => String.t() | boolean() | recovery_contract()
        }
  @type gateway_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t() | atom(),
          required(:message) => String.t(),
          optional(:param) => String.t() | nil,
          optional(:candidate_exclusions) => [map()],
          optional(:quota_refresh_attempted) => boolean(),
          optional(:route_class) => String.t(),
          optional(:retryable) => boolean(),
          optional(:requires_new_upstream_session) => boolean(),
          optional(:recovery) => recovery_contract()
        }
  @type body_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:body) => map()
        }
  @type raw_body_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:raw_body) => binary()
        }
  @type stream_callback :: (Plug.Conn.t() -> {:ok, Plug.Conn.t()} | {:error, gateway_error()})
  @type stream_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:stream) => stream_callback()
        }
  @type websocket_stream_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:websocket_stream) => (-> :ok | {:error, gateway_error()})
        }
  @type websocket_messages_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:websocket_messages) => [binary() | map()]
        }
  @type gateway_result ::
          body_result()
          | raw_body_result()
          | stream_result()
          | websocket_stream_result()
          | websocket_messages_result()

  @spec pinned_continuation_reauth_required_error() :: gateway_error()
  def pinned_continuation_reauth_required_error do
    %{
      status: 503,
      code: @pinned_continuation_reauth_required_code,
      message:
        "Pinned continuation requires upstream reauthentication. " <>
          "Restart with full visible context and remove continuation anchors.",
      retryable: false,
      requires_new_upstream_session: true,
      recovery: recovery_contract()
    }
  end

  @spec recovery_response_headers(gateway_error() | map()) :: response_headers()
  def recovery_response_headers(error) do
    if pinned_continuation_reauth_required?(error) do
      [{"x-codex-recovery-kind", @restart_with_full_context_recovery_kind}]
    else
      []
    end
  end

  @spec recovery_error_fields(gateway_error() | map()) :: client_recovery_fields() | %{}
  def recovery_error_fields(error) do
    if pinned_continuation_reauth_required?(error) do
      %{
        "retryable" => false,
        "requires_new_upstream_session" => true,
        "recovery_kind" => @restart_with_full_context_recovery_kind,
        "recovery" => Map.get(error, :recovery) || recovery_contract()
      }
    else
      %{}
    end
  end

  @spec recovery_contract() :: recovery_contract()
  def recovery_contract do
    %{
      "kind" => @restart_with_full_context_recovery_kind,
      "guidance" => "Restart with full visible context and no continuation anchors.",
      "anchor_removal" => %{
        "body" => @continuation_anchor_body_fields,
        "headers" => @continuation_anchor_headers
      },
      "notes" => [
        "Full visible context means client-visible conversation state and tool results.",
        "Do not replay stored prompts or hidden server state."
      ]
    }
  end

  @spec pinned_continuation_reauth_required?(gateway_error() | map()) :: boolean()
  def pinned_continuation_reauth_required?(%{code: code}) do
    to_string(code) == @pinned_continuation_reauth_required_code
  end

  def pinned_continuation_reauth_required?(_error), do: false
end
