defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol do
  @moduledoc """
  Public facade for Codex Responses SSE parsing and stream event classification.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.TerminalOutcome
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.WebsocketErrorHeaders

  @type terminal_failure :: %{
          required(:code) => String.t(),
          required(:upstream_code) => String.t() | nil,
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil
        }
  @type terminal_outcome :: %{
          required(:kind) => atom(),
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil,
          optional(:failure) => terminal_failure(),
          optional(:incomplete_reason) => String.t() | nil
        }
  @type public_openai_responses_stream_state :: %{
          required(:buffer) => binary(),
          required(:created?) => boolean(),
          required(:text_delta?) => boolean(),
          required(:passthrough?) => boolean(),
          required(:passthrough_terminal) => PublicResponses.passthrough_terminal_state() | nil,
          required(:passthrough_terminal_kind) => atom() | nil,
          required(:passthrough_terminal_failure) => terminal_failure() | nil,
          required(:passthrough_terminal_seen?) => boolean()
        }
  @type websocket_frame_headers :: %{optional(String.t()) => String.t()}

  @spec public_openai_responses_stream_state() :: public_openai_responses_stream_state()
  def public_openai_responses_stream_state do
    PublicResponses.new_state()
  end

  @spec max_incomplete_sse_block_bytes() :: pos_integer()
  defdelegate max_incomplete_sse_block_bytes, to: SSEParser

  @spec oversized_incomplete_sse_block?(binary()) :: boolean()
  defdelegate oversized_incomplete_sse_block?(buffer), to: SSEParser

  @spec normalize_codex_responses_sse_data(binary()) :: binary()
  defdelegate normalize_codex_responses_sse_data(data),
    to: ErrorCanonicalization,
    as: :normalize_data

  @spec normalize_codex_responses_sse_block(binary(), binary()) :: iodata()
  def normalize_codex_responses_sse_block(block, separator \\ "\n\n"),
    do: ErrorCanonicalization.normalize_block(block, separator)

  @spec normalize_terminal_event(String.t() | nil, map()) :: {String.t() | nil, map()}
  defdelegate normalize_terminal_event(event_type, decoded), to: ErrorCanonicalization

  @spec normalize_public_openai_responses_sse_data(
          binary(),
          public_openai_responses_stream_state()
        ) ::
          {binary(), public_openai_responses_stream_state()}
  def normalize_public_openai_responses_sse_data(data, state),
    do: PublicResponses.normalize_data(data, state)

  @spec public_openai_responses_passthrough_terminal_kind(public_openai_responses_stream_state()) ::
          atom() | nil
  def public_openai_responses_passthrough_terminal_kind(state),
    do: PublicResponses.passthrough_terminal_kind(state)

  @spec public_openai_responses_passthrough_terminal_failure(
          public_openai_responses_stream_state()
        ) ::
          terminal_failure() | nil
  def public_openai_responses_passthrough_terminal_failure(state),
    do: PublicResponses.passthrough_terminal_failure(state)

  @spec synthetic_public_openai_responses_failure_sse(String.t() | nil, term()) :: binary()
  defdelegate synthetic_public_openai_responses_failure_sse(response_id, reason),
    to: ErrorCanonicalization,
    as: :synthetic_public_openai_responses_failure_sse

  @spec canonicalize_codex_responses_json_message(binary()) :: binary()
  defdelegate canonicalize_codex_responses_json_message(data), to: ErrorCanonicalization

  @spec websocket_error_frame_headers(binary()) :: websocket_frame_headers()
  defdelegate websocket_error_frame_headers(data), to: WebsocketErrorHeaders

  @spec complete_sse_blocks(binary(), keyword()) :: {[binary()], binary()}
  defdelegate complete_sse_blocks(data, opts), to: SSEParser

  @spec first_complete_event(binary()) :: {:ok, map()} | :incomplete
  defdelegate first_complete_event(buffer), to: TerminalOutcome

  @spec terminal_outcome(binary()) :: {:ok, terminal_outcome()} | :error
  defdelegate terminal_outcome(data), to: TerminalOutcome

  @spec terminal_outcome_event(map()) :: {:ok, terminal_outcome()} | nil
  defdelegate terminal_outcome_event(event), to: TerminalOutcome

  @spec terminal_failure(binary()) :: {:ok, terminal_failure()} | :error
  defdelegate terminal_failure(data), to: TerminalOutcome

  @spec terminal_outcome(String.t() | nil, map()) :: {:ok, terminal_outcome()} | nil
  defdelegate terminal_outcome(event_type, decoded), to: TerminalOutcome

  @spec terminal_failure_event(map()) :: {:ok, terminal_failure()} | nil
  defdelegate terminal_failure_event(event), to: TerminalOutcome

  @spec retryable_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  defdelegate retryable_first_terminal_failure(event), to: TerminalOutcome

  @spec auth_refresh_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  defdelegate auth_refresh_first_terminal_failure(event), to: TerminalOutcome

  @spec internal_rate_limit_event?(term()) :: boolean()
  defdelegate internal_rate_limit_event?(event), to: TerminalOutcome

  @spec downstream_visible_event?(term()) :: boolean()
  defdelegate downstream_visible_event?(event), to: TerminalOutcome

  @spec stream_data_visible?(term()) :: boolean()
  defdelegate stream_data_visible?(data), to: TerminalOutcome

  @spec terminal_error_code(binary(), String.t() | nil) :: String.t()
  defdelegate terminal_error_code(body, terminal), to: ErrorCanonicalization

  @spec client_visible_error_code(String.t() | nil) :: String.t() | nil
  defdelegate client_visible_error_code(code), to: ErrorCanonicalization

  @spec upstream_error_code(map()) :: String.t() | nil
  defdelegate upstream_error_code(decoded), to: ErrorCanonicalization

  @spec error_code_from_nested_error(map()) :: String.t() | nil
  defdelegate error_code_from_nested_error(error), to: ErrorCanonicalization

  @spec sse_field(binary(), binary()) :: binary() | nil
  defdelegate sse_field(block, name), to: SSEParser

  @spec decode_sse_data(term()) :: map()
  defdelegate decode_sse_data(data), to: SSEParser

  @spec valid_json?(term()) :: boolean()
  defdelegate valid_json?(body), to: SSEParser
end
