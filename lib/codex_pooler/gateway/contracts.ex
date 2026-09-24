defmodule CodexPooler.Gateway.Contracts do
  @moduledoc false

  @pinned_continuation_reauth_required_code "pinned_continuation_reauth_required"
  @pinned_continuation_unavailable_code "pinned_continuation_unavailable"
  @restart_with_full_context_recovery_kind "restart_with_full_context"
  @continuation_anchor_body_fields ["previous_response_id"]
  @continuation_anchor_headers [
    "x-codex-previous-response-id",
    "x-codex-turn-state",
    "x-codex-window-id",
    "x-codex-session-id",
    "session-id",
    "x-session-id",
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
          optional(:continuity_denial) => map(),
          optional(:quota_refresh_attempted) => boolean(),
          optional(:route_class) => String.t(),
          optional(:accounting_disposition) => :zero_work,
          optional(:internal_reason) => String.t(),
          optional(:compaction_invalid_reason) => String.t(),
          optional(:public_compaction_error?) => boolean(),
          optional(:retryable) => boolean(),
          optional(:requires_new_upstream_session) => boolean(),
          optional(:recovery) => recovery_contract(),
          # Set by construction on every Pooler-authored policy denial
          # (`Denials.policy_error/4`); read only by the `/v1` redaction
          # exemption, never rendered or persisted (findings#221).
          optional(:pooler_policy) => true,
          # Set only by quota routing when every candidate is exhausted with a
          # known reset (`CandidateEligibility.UsageLimit`); rendered as the
          # provider's `usage_limit_reached` fields and retry headers, and
          # exempt from the `/v1` redaction (findings#206 row 206-508).
          optional(:usage_limit) => usage_limit(),
          # Set by route filtering on a retryable `503` of a Pool with an
          # open-circuit candidate (findings#206 row 206-532), and on the `/v1`
          # relayed `429` whose Pool advice is withheld (row 206-593): seconds
          # until that circuit admits a probe, 1..60, rendered as `Retry-After`.
          optional(:circuit_retry_after_seconds) => pos_integer()
        }
  @type usage_limit :: %{required(:resets_at) => integer(), required(:resets_in_seconds) => pos_integer()}
  @type body_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:body) => map(),
          optional(:public_full_rejection) => validation_rejection(),
          # Full projection markers read by the public senders: an upstream
          # 404 on an input file reference, and the stream-startup error code.
          optional(:public_input_file_upstream_404?) => boolean(),
          optional(:public_stream_startup_error_code) => String.t() | nil
        }
  # The structured rejection a public `/v1` sender re-renders through the
  # caller-facing parameter mapper: carried as `public_validation_rejection`
  # next to a relayed raw body, and as `public_full_rejection` next to a
  # rendered Full body (codex-pooler-findings#219).
  @type validation_rejection :: %{
          required(:code) => String.t(),
          required(:param) => String.t() | nil,
          required(:supported_values) => [String.t()] | nil,
          required(:supported_values_state) => String.t() | nil
        }
  @type raw_body_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:raw_body) => binary(),
          optional(:public_validation_rejection) => validation_rejection()
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

  @doc """
  The answer to work that met a transient database failure before anything was
  reserved or sent (`CodexPooler.Platform.TransientDatabaseError`): a
  retryable `503` that names no database detail. It used to render as a `500`,
  which the Codex client shows as "high demand" (findings#206 row 206-358).
  """
  @spec database_unavailable_error() :: gateway_error()
  def database_unavailable_error do
    %{status: 503, code: "service_unavailable", message: "Codex Pooler is temporarily unavailable; retry the request"}
  end

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

  @spec pinned_continuation_unavailable_error(map()) :: gateway_error()
  def pinned_continuation_unavailable_error(continuity_metadata \\ %{}) do
    %{
      status: 503,
      code: @pinned_continuation_unavailable_code,
      message:
        "Pinned continuation is not available. " <>
          "Restart with full visible context and remove continuation anchors.",
      param: "model",
      retryable: false,
      requires_new_upstream_session: true,
      recovery: recovery_contract(),
      continuity_denial: sanitize_continuity_metadata(continuity_metadata)
    }
  end

  @spec recovery_response_headers(gateway_error() | map()) :: response_headers()
  def recovery_response_headers(error) do
    if hard_pinned_continuation_recovery?(error) do
      [{"x-codex-recovery-kind", @restart_with_full_context_recovery_kind}]
    else
      []
    end
  end

  @spec recovery_error_fields(gateway_error() | map()) :: client_recovery_fields() | %{}
  def recovery_error_fields(error) do
    if hard_pinned_continuation_recovery?(error) do
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

  @usage_limit_error_type "usage_limit_reached"
  @usage_limit_retry_ceiling_seconds 60

  @doc """
  The provider's own fields for an exhausted account on a Pool whose every
  candidate is exhausted with a known reset: `error.type`
  `usage_limit_reached`, which the released Codex client maps to its terminal
  `UsageLimitReached` and shows with the reset time, plus `resets_at` (epoch
  seconds) and `resets_in_seconds` (findings#206 row 206-508). No
  `plan_type`: a Pool has no single plan, and the client parses the field as
  its own plan enum.
  """
  @spec usage_limit_error_fields(gateway_error() | map()) :: %{optional(String.t()) => String.t() | integer()}
  def usage_limit_error_fields(%{status: 429, usage_limit: %{resets_at: resets_at, resets_in_seconds: seconds}}),
    do: %{"type" => @usage_limit_error_type, "resets_at" => resets_at, "resets_in_seconds" => seconds}

  def usage_limit_error_fields(_error), do: %{}

  @doc """
  The reset an all-exhausted Pool's terminal answer advised, as it was sent,
  for the refused row and the log line (findings#206 row 206-553): the two
  integers only, so the advice a client was told never has to be re-derived
  from the exclusions under a later rule. Empty for every other error.
  """
  @spec usage_limit_record(gateway_error() | map()) :: %{optional(String.t()) => integer()}
  def usage_limit_record(%{status: 429, usage_limit: %{resets_at: resets_at, resets_in_seconds: seconds}})
      when is_integer(resets_at) and is_integer(seconds),
      do: %{"resets_at" => resets_at, "resets_in_seconds" => seconds}

  def usage_limit_record(_error), do: %{}

  @doc """
  The retry advice of the same answer: `Retry-After` in seconds, and
  `x-should-retry: false` once the wait exceeds a minute, so the OpenAI SDKs
  (openai-node honours `retry-after` up to 60 s, openai-python up to 120 s)
  do not resend within seconds a request no shorter wait admits. The same
  rule as a key policy window (findings#206 row 206-427).
  """
  @spec usage_limit_response_headers(gateway_error() | map()) :: response_headers()
  def usage_limit_response_headers(%{status: 429, usage_limit: %{resets_in_seconds: seconds}})
      when seconds > @usage_limit_retry_ceiling_seconds,
      do: [{"retry-after", Integer.to_string(seconds)}, {"x-should-retry", "false"}]

  def usage_limit_response_headers(%{status: 429, usage_limit: %{resets_in_seconds: seconds}}),
    do: [{"retry-after", Integer.to_string(seconds)}]

  def usage_limit_response_headers(_error), do: []

  @doc """
  The retry advice of a retryable `503` whose Pool has an open-circuit
  candidate: `Retry-After` with the seconds until that circuit admits a probe
  (findings#206 row 206-532). No `x-should-retry`: the state is retryable, and
  the OpenAI SDKs honour a `Retry-After` of up to a minute.
  """
  @spec circuit_retry_response_headers(gateway_error() | map()) :: response_headers()
  def circuit_retry_response_headers(%{status: status, circuit_retry_after_seconds: seconds}) when status in [429, 503] and is_integer(seconds) and seconds > 0,
    do: [{"retry-after", Integer.to_string(seconds)}]

  def circuit_retry_response_headers(_error), do: []

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

  @spec hard_pinned_continuation_recovery?(gateway_error() | map()) :: boolean()
  def hard_pinned_continuation_recovery?(%{code: code}) do
    to_string(code) in [
      @pinned_continuation_reauth_required_code,
      @pinned_continuation_unavailable_code
    ]
  end

  def hard_pinned_continuation_recovery?(_error), do: false

  @safe_continuity_metadata_keys ~w(
    denial_family
    continuity_family
    pin_mode
    pin_reason
    internal_reason
    pool_upstream_assignment_id
    upstream_identity_id
  )

  defp sanitize_continuity_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@safe_continuity_metadata_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sanitize_continuity_metadata(_metadata), do: %{}
end
