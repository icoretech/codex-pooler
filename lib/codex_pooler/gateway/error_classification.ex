defmodule CodexPooler.Gateway.ErrorClassification do
  @moduledoc false

  # One classifier for every error envelope Codex Pooler authors itself, on
  # every public transport.
  #
  # An OpenAI-compatible SDK branches on `type`, not on `status`.
  # `invalid_request_error` is the terminal, do-not-retry class: it says the
  # caller's request was malformed and will fail identically forever. Both
  # renderers used to reach that answer by defaulting to it — the websocket
  # adapter and `GatewayControllerHelpers.send_error/2` each special-cased one
  # code and let everything else fall through — so an owner-lifecycle 503 told
  # the client never to retry the one failure worth retrying
  # (findings#184, findings#191).
  #
  # A default is how both surfaces got there, so there is no default here: the
  # vocabulary is enumerated, a compile-time guard below fails the build when an
  # owner error code is added without a class, and anything outside the
  # vocabulary is classified from the status the error already carries.
  #
  # Net invariant, enforced by `ErrorClassificationTest` and by the per-surface
  # renderer tests: a 5xx response or frame is never typed
  # `invalid_request_error`.

  alias CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary

  @server_error_type "server_error"
  @client_error_type "invalid_request_error"

  # OpenAI's own vocabulary for a throttle, and the honest answer for a 429:
  # neither existing type is. `invalid_request_error` says the request was
  # malformed and will fail identically forever, which is the opposite of what a
  # throttle means, and `server_error` says something broke when nothing did.
  #
  # This is reachable today, not theoretical: the file bridge relays an upstream
  # create status verbatim (`FileBridge.json_success/2`), so a throttled upstream
  # becomes a Codex Pooler-authored 429 envelope, and it used to carry the
  # terminal class. Provider 429 bodies relayed whole are untouched by this --
  # their own `error` object goes out as the upstream wrote it.
  @rate_limit_error_type "rate_limit_error"
  @rate_limit_status 429

  @overload_code "server_is_overloaded"

  # Server class: the turn failed for a reason on this side of the wire, and the
  # same request can succeed on a retry. Enumerated because the status alone
  # would answer wrong for some of them — `owner_busy` is backpressure and
  # `stale_owner` is a lease that moved, both 409 and both client-retryable —
  # and because the guard below demands a decision for every owner code rather
  # than a silent inheritance.
  #
  # `upstream_websocket_terminal_delivery_timeout` is a vocabulary name that is
  # never emitted as a wire code (it renders as `upstream_stream_error`); it is
  # classified so the exhaustiveness check covers the whole vocabulary.
  @server_error_codes [
    @overload_code,
    "owner_busy",
    "owner_crashed",
    "owner_drained",
    "owner_forward_timeout",
    "owner_forwarding_disabled",
    "owner_unavailable",
    "server_error",
    "stale_owner",
    "upstream_stream_error",
    "upstream_websocket_terminal_delivery_timeout",
    "websocket_request_failed"
  ]

  # Client class: this connection or this submission is the problem, and
  # retrying the same thing cannot work. A downstream that was replaced or is
  # speaking on a superseded epoch was superseded by the client's own newer
  # connection, and `client_disconnected` cannot reach a live client at all.
  @client_error_codes [
    "client_disconnected",
    "duplicate_downstream",
    "stale_downstream"
  ]

  @unclassified_owner_error_codes OwnerErrorVocabulary.owner_error_codes() --
                                    (@server_error_codes ++ @client_error_codes)

  if @unclassified_owner_error_codes != [] do
    raise "owner error codes are unclassified in ErrorClassification: " <>
            Enum.join(@unclassified_owner_error_codes, ", ") <>
            ". Classify each one as server or client class rather than letting it " <>
            "inherit a default (findings#184, findings#191)."
  end

  @ambiguous_error_codes @server_error_codes -- (@server_error_codes -- @client_error_codes)

  if @ambiguous_error_codes != [] do
    raise "error codes are classified as both server and client class in " <>
            "ErrorClassification: " <> Enum.join(@ambiguous_error_codes, ", ")
  end

  @spec server_error_type() :: String.t()
  def server_error_type, do: @server_error_type

  @spec client_error_type() :: String.t()
  def client_error_type, do: @client_error_type

  @spec rate_limit_error_type() :: String.t()
  def rate_limit_error_type, do: @rate_limit_error_type

  @spec server_error_codes() :: [String.t()]
  def server_error_codes, do: @server_error_codes

  @spec client_error_codes() :: [String.t()]
  def client_error_codes, do: @client_error_codes

  @doc """
  The public `error.type` for an error Codex Pooler authored itself.

  The enumerated vocabulary decides first, because a handful of codes carry a
  status their class contradicts. Everything else is classified from the status:
  a 5xx is a failure on this side of the wire whatever raised it, and only a
  non-5xx, non-vocabulary code — a relayed provider rejection or a local
  validation rejection — is the caller's to fix.

  A 429 is its own class, `rate_limit_error`, because neither of the other two
  is honest about a throttle.

  Deliberately not consulted: an error map's `retryable` field. It means
  "Codex Pooler will not route around this itself" rather than "the caller must
  not retry", and the two differ: a pre-attempt reservation failure is a 500
  carrying `retryable: false`, and a pinned-continuation denial is a 503 whose
  own operator action is to wait for the upstream to recover and then restart.
  Typing either from that field would reintroduce exactly the 5xx-typed-as-a-
  client-error defect this module exists to prevent. A client that needs the
  finer answer reads the `recovery` contract, which rides in the same envelope.
  """
  @spec error_type(term(), integer() | nil) :: String.t()
  def error_type(code, status) do
    code = to_string(code)

    cond do
      code in @server_error_codes -> @server_error_type
      code in @client_error_codes -> @client_error_type
      status == @rate_limit_status -> @rate_limit_error_type
      is_integer(status) and status >= 500 -> @server_error_type
      true -> @client_error_type
    end
  end
end
