defmodule CodexPooler.Gateway.Runtime.DuplicateTurnTelemetry do
  @moduledoc false

  # A `409 duplicate_turn` refusal is client-visible, but none of the stages
  # that answer it writes a request row for the refused request: the replay
  # preflight, the websocket and native HTTP turn claims, the native replay
  # dispatch, and the client-retry and compaction-retry claims. Request-log
  # counts, admin stats and every other database-derived signal therefore never
  # see one, and the only trace was an info-level log line (findings#225).
  #
  # This counter makes each refusal countable where operators already look.
  # Labels are the refusing stage and the transport class, both closed sets.
  # The reason stays in the log line: its vocabulary is open (claim errors pass
  # through), so it cannot be a label.

  @event [:codex_pooler, :gateway, :duplicate_turn, :refused]
  @stages ~w(
    runtime_replay_preflight
    websocket_turn_claim
    native_replay_dispatch
    native_http_turn_claim
    client_retry_claim
    compaction_retry_claim
  )
  @transports ~w(websocket http)
  @http_transports ~w(http_json http_sse http_compact_json)

  @type stage :: String.t()
  @type transport :: String.t()

  @spec event() :: [atom()]
  def event, do: @event

  @spec stages() :: [stage()]
  def stages, do: @stages

  @spec transports() :: [transport()]
  def transports, do: @transports

  @doc """
  Counts one `duplicate_turn` refusal.

  Always returns `:ok`: the refusal is already decided, and a handler that
  raises, throws or exits must not turn it into a different failure. Labels are
  normalized to the closed sets, anything else becomes `unknown`.
  """
  @spec emit_refused(term(), term()) :: :ok
  def emit_refused(stage, transport) do
    try do
      :telemetry.execute(@event, %{count: 1}, %{stage: stage(stage), transport: transport(transport)})
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp stage(stage) when stage in @stages, do: stage
  defp stage(_stage), do: "unknown"

  defp transport("websocket"), do: "websocket"
  defp transport(transport) when transport in @http_transports, do: "http"
  defp transport(_transport), do: "unknown"
end
