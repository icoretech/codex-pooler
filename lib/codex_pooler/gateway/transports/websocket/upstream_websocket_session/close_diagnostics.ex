defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.CloseDiagnostics do
  @moduledoc false

  # One bounded info line for every upstream websocket connection the session
  # closes outside a request: a peer Close or TCP/TLS close read while idle, the
  # Pooler's own pong deadline, a control frame that cannot be written, an
  # invalidation, or the next request needing a connection under another
  # reuse key. Before it, such a close left no trace, so the next anchored turn
  # meeting a fresh connection (`previous_response_not_found`,
  # `connection_use=fresh`) could not be attributed (findings#206 row 206-356).
  # The line joins the guard row through `lifecycle_id` and `generation`: the
  # fresh connection carries the same lifecycle at `generation + 1`.
  #
  # Metadata only: fixed cause vocabulary, a bounded close code, the close
  # reason and transport reason through the websocket diagnostics taxonomy
  # (allowlisted ASCII identifiers in cleartext, anything else a 12-character
  # SHA-256 fingerprint), monotonic ages in milliseconds, the connection's
  # request count, and for a reuse-key change only which part changed and the
  # changed header names (the credential header as `credential`), never a
  # header value.

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy

  @type cause ::
          :peer_close_frame
          | :transport_closed
          | :transport_error
          | :pong_deadline
          | :ping_send_failed
          | :pong_send_failed
          | :send_failed
          | :decode_error
          | :frame_error
          | :request_key_changed
          | :invalidated

  @type detail ::
          {:close_code, term()}
          | {:close_reason, term()}
          | {:transport_reason, term()}
          | {:key_change, {term(), term()}}

  @peer_causes [:peer_close_frame, :transport_closed]
  @transport_causes [:transport_error, :ping_send_failed, :pong_send_failed, :send_failed]
  @max_changed_headers 8

  @doc """
  Logs the close of the state's live connection. A state without a connection
  logs nothing: there is nothing to close.
  """
  @spec log_close(map(), cause(), [detail()]) :: :ok
  def log_close(state, cause, details \\ [])

  def log_close(%{conn: _conn} = state, cause, details) when is_atom(cause) and is_list(details) do
    Logger.info(line(state, cause, details, System.monotonic_time(:millisecond)))
  end

  def log_close(_state, _cause, _details), do: :ok

  @doc false
  @spec line(map(), cause(), [detail()], integer()) :: String.t()
  def line(state, cause, details, now_ms) do
    [
      "upstream websocket connection closed between requests",
      field("reason_code", Atom.to_string(cause)),
      field("closed_by", closed_by(cause)),
      field("close_code", close_code(Keyword.get(details, :close_code))),
      field("close_reason", close_reason(Keyword.get(details, :close_reason))),
      field("transport_reason", transport_reason(Keyword.get(details, :transport_reason))),
      key_change_fields(Keyword.get(details, :key_change)),
      field("idle_ms", age(now_ms, Map.get(state, :last_request_completed_at_monotonic_ms))),
      field("connection_age_ms", age(now_ms, Map.get(state, :connection_started_at_monotonic_ms))),
      field("connection_requests", count(Map.get(state, :connection_request_count))),
      field("pong_pending", Atom.to_string(Map.has_key?(state, :keepalive_pong_ref))),
      field("ping_age_ms", age(now_ms, Map.get(state, :last_ping_sent_at_monotonic_ms))),
      field("lifecycle_id", DiagnosticTaxonomy.safe_correlator(Map.get(state, :lifecycle_id))),
      field("generation", count(Map.get(state, :generation)))
    ]
    |> List.flatten()
    |> Enum.join(" ")
  end

  defp field(name, value), do: name <> "=" <> value

  defp closed_by(cause) when cause in @peer_causes, do: "peer"
  defp closed_by(cause) when cause in @transport_causes, do: "transport"
  defp closed_by(_cause), do: "pooler"

  defp close_code(code) when is_integer(code) and code in 1000..4999, do: Integer.to_string(code)
  defp close_code(nil), do: "none"
  defp close_code(_code), do: "invalid"

  defp close_reason(reason) when reason in [nil, ""], do: "none"
  defp close_reason(reason) when is_binary(reason), do: DiagnosticTaxonomy.identifier(reason)
  defp close_reason(_reason), do: "invalid"

  # Mint wraps a transport reason in `Mint.TransportError`/`Mint.HTTPError`;
  # only the leading atom of a reason is kept, never tuple payloads such as the
  # unexpected bytes of `{:unexpected_data, data}`.
  defp transport_reason(nil), do: "none"
  defp transport_reason(%{__struct__: _module, reason: reason}), do: transport_reason(reason)
  defp transport_reason(reason) when is_atom(reason), do: DiagnosticTaxonomy.identifier(reason)
  defp transport_reason({code, _details}) when is_atom(code), do: DiagnosticTaxonomy.identifier(code)
  defp transport_reason(_reason), do: "other"

  defp key_change_fields({{old_url, old_headers}, {new_url, new_headers}}) do
    changed_headers = changed_header_names(old_headers, new_headers)

    part =
      case {old_url != new_url, changed_headers != []} do
        {true, true} -> "url_and_headers"
        {true, false} -> "url"
        {false, true} -> "headers"
        {false, false} -> "none"
      end

    [
      field("key_change", part),
      field("changed_headers", if(changed_headers == [], do: "none", else: Enum.join(changed_headers, ",")))
    ]
  end

  defp key_change_fields(_key_change), do: []

  defp changed_header_names(old_headers, new_headers) when is_list(old_headers) and is_list(new_headers) do
    old = header_values(old_headers)
    new = header_values(new_headers)

    old
    |> Map.keys()
    |> Enum.concat(Map.keys(new))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(old, &1) != Map.get(new, &1)))
    |> Enum.sort()
    |> Enum.take(@max_changed_headers)
    |> Enum.map(&header_label/1)
  end

  defp changed_header_names(_old_headers, _new_headers), do: ["invalid"]

  # The credential header is named by its role, so a changed token reads as a
  # credential change without the log ever carrying the header's own name.
  defp header_label("authorization"), do: "credential"
  defp header_label(name), do: DiagnosticTaxonomy.identifier(name)

  defp header_values(headers) do
    Enum.reduce(headers, %{}, fn
      {name, value}, acc when is_binary(name) ->
        Map.update(acc, String.downcase(name), [value], &[value | &1])

      _other, acc ->
        acc
    end)
  end

  defp age(now_ms, at_ms) when is_integer(at_ms), do: Integer.to_string(max(now_ms - at_ms, 0))
  defp age(_now_ms, _at_ms), do: "none"

  defp count(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp count(_value), do: "none"
end
