defmodule CodexPooler.RouteClass do
  @moduledoc false

  @proxy_http "proxy_http"
  @proxy_control "proxy_control"
  @proxy_stream "proxy_stream"
  @proxy_websocket "proxy_websocket"
  @proxy_compact "proxy_compact"
  @file_upload "file_upload"
  @audio_transcription "audio_transcription"
  @admin_browser "admin_browser"
  @mcp "mcp"

  @all [
    @proxy_http,
    @proxy_control,
    @proxy_stream,
    @proxy_websocket,
    @proxy_compact,
    @file_upload,
    @audio_transcription,
    @admin_browser,
    @mcp
  ]

  @default_bulkheads %{
    @proxy_http => %{max_concurrency: 32, queue_limit: 128, queue_timeout_ms: 10_000},
    @proxy_control => %{max_concurrency: 8, queue_limit: 16, queue_timeout_ms: 5_000},
    @proxy_stream => %{max_concurrency: 24, queue_limit: 96, queue_timeout_ms: 10_000},
    @proxy_websocket => %{max_concurrency: 24, queue_limit: 96, queue_timeout_ms: 10_000},
    @proxy_compact => %{max_concurrency: 8, queue_limit: 32, queue_timeout_ms: 10_000},
    @file_upload => %{max_concurrency: 4, queue_limit: 8, queue_timeout_ms: 5_000},
    @audio_transcription => %{max_concurrency: 4, queue_limit: 8, queue_timeout_ms: 5_000},
    @admin_browser => %{max_concurrency: 8, queue_limit: 16, queue_timeout_ms: 5_000},
    @mcp => %{max_concurrency: 4, queue_limit: 8, queue_timeout_ms: 5_000}
  }

  @type t :: String.t()

  @spec proxy_http() :: t()
  def proxy_http, do: @proxy_http

  @spec proxy_control() :: t()
  def proxy_control, do: @proxy_control

  @spec proxy_stream() :: t()
  def proxy_stream, do: @proxy_stream

  @spec proxy_websocket() :: t()
  def proxy_websocket, do: @proxy_websocket

  @spec proxy_compact() :: t()
  def proxy_compact, do: @proxy_compact

  @spec file_upload() :: t()
  def file_upload, do: @file_upload

  @spec audio_transcription() :: t()
  def audio_transcription, do: @audio_transcription

  @spec admin_browser() :: t()
  def admin_browser, do: @admin_browser

  @spec mcp() :: t()
  def mcp, do: @mcp

  @spec all() :: [t()]
  def all, do: @all

  @spec default_bulkheads() :: %{t() => map()}
  def default_bulkheads, do: @default_bulkheads

  @spec classify(String.t(), map(), String.t() | nil) :: t()
  def classify(endpoint, payload, transport) do
    cond do
      endpoint in [
        "/backend-api/codex/responses/compact",
        "/backend-api/codex/v1/responses/compact"
      ] ->
        @proxy_compact

      transport == "websocket" ->
        @proxy_websocket

      endpoint == "/backend-api/transcribe" ->
        @audio_transcription

      endpoint in ["/backend-api/files", "/backend-api/files/uploaded"] ->
        @file_upload

      streaming?(payload) ->
        @proxy_stream

      true ->
        @proxy_http
    end
  end

  @spec streaming?(map()) :: boolean()
  def streaming?(payload),
    do: Map.get(payload, "stream") == true or Map.get(payload, :stream) == true
end
