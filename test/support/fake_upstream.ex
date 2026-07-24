defmodule CodexPooler.FakeUpstream do
  @moduledoc """
  Local HTTP fake for gateway contract tests.

  The fake runs through Bandit and Plug so gateway tests exercise real local HTTP
  request/response behavior instead of mocking the client boundary.
  """

  @max_body_bytes 30 * 1024 * 1024

  defstruct [:pid, :server, :url]

  @type t :: %__MODULE__{pid: pid(), server: pid(), url: String.t()}

  @type mode ::
          {:json, non_neg_integer(), map()}
          | {:json_headers, non_neg_integer(), map(), [{String.t(), String.t()}]}
          | {:raw_body, non_neg_integer(), binary(), [{String.t(), String.t()}]}
          | {:chunked_body, non_neg_integer(), [binary()], [{String.t(), String.t()}]}
          | {:barrier_json, non_neg_integer(), map(), pid(), reference()}
          | {:path_json, map()}
          | {:file_protocol, map()}
          | {:reject_json_field, String.t(), non_neg_integer(), map(), non_neg_integer(), map()}
          | {:require_json_field, String.t(), non_neg_integer(), map(), non_neg_integer(), map()}
          | {:sse, [String.t()]}
          | {:sse_headers, [String.t()], [{String.t(), String.t()}]}
          | {:delayed_sse, [String.t()], pos_integer(), pid() | nil}
          | {:delayed_terminal_sse, [String.t()], [String.t()], pid(), reference()}
          | {:abrupt_close_mid_stream, [String.t()]}
          | :close_before_headers
          | {:websocket_text, [String.t()]}
          | {:websocket_sse_then_close, [String.t()], non_neg_integer(), String.t()}
          | {:websocket_terminal_then_close_barrier, String.t(), non_neg_integer(), String.t(),
             pid(), reference()}
          | {:websocket_close_without_terminal_barrier, non_neg_integer(), String.t(), pid(),
             reference()}
          | {:sequence, [mode()]}
          | {:barrier_sse, [String.t()], non_neg_integer(), pid(), reference()}
          | {:malformed_json, non_neg_integer(), String.t()}
          | {:json_error, non_neg_integer(), map()}
          | {:non_json_error, non_neg_integer(), String.t()}
          | {:timeout_before_headers, pid() | nil, reference()}
          | {:timeout_after_sse_headers, pid() | nil, reference()}
          | {:timeout_mid_stream, String.t(), pid() | nil, reference()}
          | {:websocket_upgrade_timeout, pid() | nil, reference()}
          | {:websocket_upgrade_error, non_neg_integer(), map(), [{String.t(), String.t()}],
             pid() | nil, reference() | nil}

  @doc "Starts a local fake upstream server for the given response mode."
  def start_link(mode, opts \\ []) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          mode: mode,
          requests: [],
          route_counts: %{},
          websocket_connection_count: 0,
          websocket_connection_ids: [],
          websocket_pids: MapSet.new(),
          websocket_control_notify: nil,
          websocket_control_frames: []
        }
      end)

    bandit_options = [
      plug: {CodexPooler.FakeUpstream.Plug, pid},
      port: 0,
      ip: {127, 0, 0, 1},
      startup_log: false
    ]

    {:ok, server} = Bandit.start_link(Keyword.merge(bandit_options, opts))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, %__MODULE__{pid: pid, server: server, url: "http://127.0.0.1:#{port}"}}
  end

  @doc "Stops the fake upstream server."
  def stop(%__MODULE__{server: server, pid: pid}) do
    safe_stop(fn -> ThousandIsland.stop(server) end)
    safe_stop(fn -> Agent.stop(pid) end)
    :ok
  end

  @doc "Returns the base URL for the fake upstream."
  def url(%__MODULE__{url: url}), do: url

  @doc "Returns captured requests in request order."
  def requests(%__MODULE__{pid: pid}) do
    Agent.get(pid, fn state -> Enum.reverse(state.requests) end)
  end

  @doc "Returns the captured request count."
  def count(fake), do: fake |> requests() |> length()

  @doc "Returns the captured non-websocket request count."
  @spec http_request_count(t()) :: non_neg_integer()
  def http_request_count(fake) do
    fake
    |> requests()
    |> Enum.count(&(&1.method != "WEBSOCKET"))
  end

  def notify_websocket_controls(%__MODULE__{pid: pid}, notify) when is_pid(notify) do
    Agent.update(pid, &%{&1 | websocket_control_notify: notify})
  end

  def websocket_control_frames(%__MODULE__{pid: pid}) do
    Agent.get(pid, fn state -> Enum.reverse(state.websocket_control_frames || []) end)
  end

  def websocket_connection_count(%__MODULE__{pid: pid}) do
    Agent.get(pid, fn state -> Map.get(state, :websocket_connection_count, 0) end)
  end

  @spec websocket_connection_ids(t()) :: [reference()]
  def websocket_connection_ids(%__MODULE__{pid: pid}) do
    Agent.get(pid, fn state -> Enum.reverse(Map.get(state, :websocket_connection_ids, [])) end)
  end

  def close_websocket_connections(%__MODULE__{pid: pid}) do
    pids = Agent.get(pid, fn state -> Map.get(state, :websocket_pids, MapSet.new()) end)
    Enum.each(pids, &send(&1, :fake_upstream_close_websocket))
    :ok
  end

  def set_mode(%__MODULE__{pid: pid}, mode) do
    Agent.update(pid, &%{&1 | mode: mode})
  end

  def json_response(payload, status \\ 200), do: {:json, status, payload}

  def json_response_with_headers(payload, headers, status \\ 200),
    do: {:json_headers, status, payload, headers}

  def raw_response(body, opts \\ []) when is_binary(body) and is_list(opts) do
    {:raw_body, Keyword.get(opts, :status, 200), body, Keyword.get(opts, :headers, [])}
  end

  def chunked_response(chunks, opts \\ []) when is_list(chunks) and is_list(opts) do
    {:chunked_body, Keyword.get(opts, :status, 200), chunks, Keyword.get(opts, :headers, [])}
  end

  def barrier_json_response(payload, opts) when is_map(payload) and is_list(opts) do
    {:barrier_json, Keyword.get(opts, :status, 200), payload, Keyword.fetch!(opts, :notify),
     Keyword.fetch!(opts, :release_ref)}
  end

  def reject_json_field(
        field,
        success_payload,
        error_payload,
        success_status \\ 200,
        error_status \\ 400
      )
      when is_binary(field) and is_map(success_payload) and is_map(error_payload) do
    {:reject_json_field, field, success_status, success_payload, error_status, error_payload}
  end

  def require_json_field(
        field,
        success_payload,
        error_payload,
        success_status \\ 200,
        error_status \\ 400
      )
      when is_binary(field) and is_map(success_payload) and is_map(error_payload) do
    {:require_json_field, field, success_status, success_payload, error_status, error_payload}
  end

  def file_protocol_success(opts \\ []), do: {:file_protocol, file_protocol_config(opts)}

  def file_protocol_unauthorized(opts \\ []) do
    {:file_protocol, opts |> file_protocol_config() |> Map.put(:mode, :unauthorized)}
  end

  def file_protocol_non_json_error(opts \\ []) do
    {:file_protocol, opts |> file_protocol_config() |> Map.put(:mode, :non_json_error)}
  end

  def file_protocol_finalize_retry(opts \\ []) do
    {:file_protocol, opts |> file_protocol_config() |> Map.put(:mode, :finalize_retry)}
  end

  def sse_stream(events, opts \\ []) do
    include_done? = Keyword.get(opts, :done, true)
    headers = Keyword.get(opts, :headers, [])

    chunks = Enum.map(events, &sse_chunk/1)
    chunks = if include_done?, do: chunks ++ ["data: [DONE]\n\n"], else: chunks

    if headers == [] do
      {:sse, chunks}
    else
      {:sse_headers, chunks, headers}
    end
  end

  @spec websocket_text_frames([iodata()]) :: mode()
  def websocket_text_frames(messages) when is_list(messages) do
    {:websocket_text, Enum.map(messages, &IO.iodata_to_binary/1)}
  end

  def quota_exhausted_429(opts \\ []) when is_list(opts) do
    quota_type = Keyword.get(opts, :quota_type, "workspace_owner_usage_limit_reached")

    {:json_headers, 429,
     %{
       "error" => %{
         "code" => "rate_limit_exceeded",
         "message" => "synthetic account quota exhausted"
       }
     }, [{"x-codex-rate-limit-reached-type", quota_type}]}
  end

  def generic_429 do
    {:json_error, 429,
     %{
       "error" => %{
         "code" => "rate_limit_exceeded",
         "message" => "synthetic rate limit"
       }
     }}
  end

  def generic_5xx(status \\ 503) when status in 500..599 do
    {:json_error, status,
     %{"error" => %{"code" => "server_error", "message" => "synthetic server failure"}}}
  end

  def delayed_sse_stream(events, opts) do
    include_done? = Keyword.get(opts, :done, true)
    interval_ms = Keyword.fetch!(opts, :interval_ms)
    notify = Keyword.get(opts, :notify)

    chunks = Enum.map(events, &sse_chunk/1)
    chunks = if include_done?, do: chunks ++ ["data: [DONE]\n\n"], else: chunks

    {:delayed_sse, chunks, interval_ms, notify}
  end

  def delayed_terminal_sse_stream(events, terminal_event, opts)
      when is_list(events) and is_list(opts) do
    notify = Keyword.fetch!(opts, :notify)
    release_ref = Keyword.fetch!(opts, :release_ref)
    before_terminal = Enum.map(events, &sse_chunk/1)
    terminal = [sse_chunk(terminal_event), "data: [DONE]\n\n"]

    {:delayed_terminal_sse, before_terminal, terminal, notify, release_ref}
  end

  def abrupt_close_mid_stream(events) when is_list(events) do
    {:abrupt_close_mid_stream, Enum.map(events, &sse_chunk/1)}
  end

  def close_before_headers, do: :close_before_headers

  def barrier_sse_stream(events, opts) do
    include_done? = Keyword.get(opts, :done, true)
    barrier_after = Keyword.get(opts, :barrier_after, 1)
    notify = Keyword.fetch!(opts, :notify)
    release_ref = Keyword.fetch!(opts, :release_ref)

    chunks = Enum.map(events, &sse_chunk/1)
    chunks = if include_done?, do: chunks ++ ["data: [DONE]\n\n"], else: chunks

    {:barrier_sse, chunks, barrier_after, notify, release_ref}
  end

  def websocket_sse_then_close(events, opts \\ []) do
    code = Keyword.get(opts, :code, 1001)
    reason = Keyword.get(opts, :reason, "fake upstream closed websocket")
    chunks = Enum.map(events, &sse_chunk/1)

    {:websocket_sse_then_close, chunks, code, reason}
  end

  @spec websocket_terminal_then_close_barrier(map() | binary(), keyword()) :: mode()
  def websocket_terminal_then_close_barrier(terminal, opts)
      when (is_map(terminal) or is_binary(terminal)) and is_list(opts) do
    terminal = if is_map(terminal), do: Jason.encode!(terminal), else: terminal

    {:websocket_terminal_then_close_barrier, terminal, Keyword.get(opts, :code, 1000),
     Keyword.get(opts, :reason, "synthetic terminal close"), Keyword.fetch!(opts, :notify),
     Keyword.fetch!(opts, :release_ref)}
  end

  @spec websocket_close_without_terminal_barrier(keyword()) :: mode()
  def websocket_close_without_terminal_barrier(opts) when is_list(opts) do
    {:websocket_close_without_terminal_barrier, Keyword.get(opts, :code, 1000),
     Keyword.get(opts, :reason, "synthetic close without terminal"),
     Keyword.fetch!(opts, :notify), Keyword.fetch!(opts, :release_ref)}
  end

  def websocket_terminal_failure(code \\ "server_error") when is_binary(code) do
    websocket_text_frames([
      Jason.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "status" => "failed",
          "error" => %{"code" => code, "message" => "synthetic terminal failure"}
        }
      })
    ])
  end

  def websocket_close(opts \\ []) when is_list(opts) do
    websocket_sse_then_close([],
      code: Keyword.get(opts, :code, 1011),
      reason: Keyword.get(opts, :reason, "synthetic websocket close")
    )
  end

  def malformed_json(body \\ "{not-json", status \\ 200), do: {:malformed_json, status, body}

  def http_500_json_error(payload \\ %{"error" => %{"code" => "server_error"}}) do
    {:json_error, 500, payload}
  end

  def non_json_502(body \\ "bad gateway"), do: {:non_json_error, 502, body}

  def timeout_before_headers(opts \\ []) when is_list(opts) do
    {:timeout_before_headers, Keyword.get(opts, :notify),
     Keyword.get(opts, :release_ref, make_ref())}
  end

  def timeout_after_sse_headers(opts \\ []) when is_list(opts) do
    {:timeout_after_sse_headers, Keyword.get(opts, :notify),
     Keyword.get(opts, :release_ref, make_ref())}
  end

  def timeout_mid_stream(first_chunk \\ "data: partial\n\n", opts \\ []) do
    {:timeout_mid_stream, first_chunk, Keyword.get(opts, :notify),
     Keyword.get(opts, :release_ref, make_ref())}
  end

  def websocket_upgrade_timeout(opts \\ []) when is_list(opts) do
    {:websocket_upgrade_timeout, Keyword.get(opts, :notify),
     Keyword.get(opts, :release_ref, make_ref())}
  end

  def websocket_upgrade_error(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    {:websocket_upgrade_error, Keyword.get(opts, :status, 401), payload,
     Keyword.get(opts, :headers, []), Keyword.get(opts, :notify), Keyword.get(opts, :release_ref)}
  end

  def handle(pid, conn) do
    if websocket_upgrade?(conn) do
      mode = Agent.get(pid, & &1.mode)

      handle_websocket(pid, conn, mode)
    else
      handle_http(pid, conn)
    end
  end

  defp handle_websocket(pid, conn, {:websocket_upgrade_timeout, notify, release_ref}) do
    wait_for_timeout_release(:websocket_upgrade, notify, release_ref)

    WebSockAdapter.upgrade(
      conn,
      CodexPooler.FakeUpstream.Websocket,
      %{pid: pid, mode: Agent.get(pid, & &1.mode), headers: conn.req_headers},
      []
    )
  end

  defp handle_websocket(
         pid,
         conn,
         {:websocket_upgrade_error, status, payload, headers, notify, release_ref}
       ) do
    Agent.update(pid, fn state ->
      {_mode, next_mode} = next_response_mode(state.mode)
      %{state | mode: next_mode}
    end)

    if is_pid(notify) do
      wait_for_timeout_release(:before_headers, notify, release_ref)
    end

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_resp_header(conn, key, value)
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp handle_websocket(
         pid,
         conn,
         {:sequence,
          [{:websocket_upgrade_error, _status, _payload, _headers, _notify, _ref} = mode | _rest]}
       ) do
    handle_websocket(pid, conn, mode)
  end

  defp handle_websocket(pid, conn, mode) do
    WebSockAdapter.upgrade(
      conn,
      CodexPooler.FakeUpstream.Websocket,
      %{pid: pid, mode: mode, headers: conn.req_headers},
      []
    )
  end

  defp handle_http(pid, conn) do
    {:ok, body, conn} = read_body(conn)

    request = %{
      method: conn.method,
      path: conn.request_path,
      query_string: conn.query_string,
      headers: conn.req_headers,
      body: body,
      json: decode_json(body)
    }

    mode =
      Agent.get_and_update(pid, fn state ->
        {mode, next_mode} = next_response_mode(state.mode)
        {mode, %{state | mode: next_mode, requests: [request | state.requests]}}
      end)

    respond(pid, conn, mode, request)
  end

  defp read_body(conn), do: read_body(conn, [])

  defp read_body(conn, chunks) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([body | chunks])), conn}
      {:more, body, conn} -> read_body(conn, [body | chunks])
    end
  end

  defp websocket_upgrade?(conn) do
    conn
    |> Plug.Conn.get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp next_response_mode({:sequence, [mode]}), do: {mode, mode}

  defp next_response_mode({:sequence, [mode | remaining]}), do: {mode, {:sequence, remaining}}

  defp next_response_mode(mode), do: {mode, mode}

  defp respond(_pid, conn, {:json, status, payload}, _request) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp respond(_pid, conn, {:json_headers, status, payload, headers}, _request) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_resp_header(conn, key, value)
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp respond(_pid, conn, {:raw_body, status, body, headers}, _request) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_resp_header(conn, key, value)
      end)

    Plug.Conn.send_resp(conn, status, body)
  end

  defp respond(_pid, conn, {:chunked_body, status, chunks, headers}, _request) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_resp_header(conn, key, value)
      end)

    conn = Plug.Conn.send_chunked(conn, status)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  defp respond(_pid, conn, {:barrier_json, status, payload, notify, release_ref}, _request) do
    wait_for_timeout_release(:before_headers, notify, release_ref)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp respond(pid, conn, {:path_json, routes}, request) do
    case Map.get(routes, conn.request_path) do
      {status, payload} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(payload))

      nil ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not found"}))

      mode ->
        respond(pid, conn, mode, request)
    end
  end

  defp respond(pid, conn, {:file_protocol, config}, request) do
    file_id = config.file_id

    case {request.method, request.path} do
      {"POST", "/backend-api/files"} ->
        file_protocol_create_response(conn, config)

      {"POST", "/backend-api/files/" <> rest} ->
        case String.split(rest, "/") do
          [^file_id, "uploaded"] ->
            file_protocol_finalize_response(pid, conn, config, request)

          _other ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              404,
              Jason.encode!(%{"error" => %{"code" => "file_not_found"}})
            )
        end

      {"PUT", "/upload/" <> rest} ->
        if String.split(rest, "?") |> List.first() == file_id do
          Plug.Conn.send_resp(conn, config.upload_status, config.upload_body)
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"code" => "file_not_found"}}))
        end

      _other ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not found"}))
    end
  end

  defp respond(
         _pid,
         conn,
         {:reject_json_field, field, success_status, success_payload, error_status,
          error_payload},
         request
       ) do
    if is_map(request.json) and Map.has_key?(request.json, field) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(error_status, Jason.encode!(error_payload))
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(success_status, Jason.encode!(success_payload))
    end
  end

  defp respond(
         _pid,
         conn,
         {:require_json_field, field, success_status, success_payload, error_status,
          error_payload},
         request
       ) do
    if is_map(request.json) and Map.has_key?(request.json, field) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(success_status, Jason.encode!(success_payload))
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(error_status, Jason.encode!(error_payload))
    end
  end

  defp respond(_pid, conn, {:sse, chunks}, _request) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  defp respond(pid, conn, {:sse_headers, chunks, headers}, request) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_resp_header(conn, key, value)
      end)

    respond(pid, conn, {:sse, chunks}, request)
  end

  defp respond(_pid, conn, {:delayed_sse, chunks, interval_ms, notify}, _request) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    chunks
    |> Enum.with_index(1)
    |> Enum.reduce(conn, fn {chunk, index}, conn ->
      if index > 1, do: wait_for_delay(interval_ms)
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      notify_chunk_sent(notify, index)
      conn
    end)
  end

  defp respond(
         _pid,
         conn,
         {:delayed_terminal_sse, before_terminal, terminal, notify, release_ref},
         _request
       ) do
    conn = start_sse_response(conn)

    conn =
      Enum.reduce(before_terminal, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)

    wait_for_timeout_release(:before_terminal, notify, release_ref)

    Enum.reduce(terminal, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  defp respond(_pid, conn, {:abrupt_close_mid_stream, chunks}, _request) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.each(chunks, fn chunk ->
      {:ok, _conn} = Plug.Conn.chunk(conn, chunk)
    end)

    Process.exit(self(), :kill)
  end

  defp respond(_pid, _conn, :close_before_headers, _request) do
    Process.exit(self(), :kill)
  end

  defp respond(_pid, conn, {:barrier_sse, chunks, barrier_after, notify, release_ref}, _request) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    maybe_wait_for_sse_barrier(0, barrier_after, notify, release_ref)

    chunks
    |> Enum.with_index(1)
    |> Enum.reduce(conn, fn {chunk, index}, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      notify_chunk_sent(notify, index)
      maybe_wait_for_sse_barrier(index, barrier_after, notify, release_ref)

      conn
    end)
  end

  defp respond(_pid, conn, {:malformed_json, status, body}, _request) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp respond(_pid, conn, {:json_error, status, payload}, _request) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp respond(_pid, conn, {:non_json_error, status, body}, _request) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end

  defp respond(_pid, conn, {:timeout_before_headers, notify, release_ref}, _request) do
    wait_for_timeout_release(:before_headers, notify, release_ref)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"late" => true}))
  end

  defp respond(_pid, conn, {:timeout_after_sse_headers, notify, release_ref}, _request) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    wait_for_timeout_release(:after_sse_headers, notify, release_ref)
    conn
  end

  defp respond(_pid, conn, {:timeout_mid_stream, first_chunk, notify, release_ref}, _request) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, first_chunk)
    wait_for_timeout_release(:mid_stream, notify, release_ref)
    {:ok, conn} = Plug.Conn.chunk(conn, "data: late\n\n")

    conn
  end

  defp sse_chunk(chunk) when is_binary(chunk), do: chunk

  defp sse_chunk({event, payload}) when is_binary(event) do
    "event: #{event}\ndata: #{Jason.encode!(payload)}\n\n"
  end

  defp sse_chunk(payload) when is_map(payload) do
    "data: #{Jason.encode!(payload)}\n\n"
  end

  defp start_sse_response(conn) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
  end

  defp decode_json(""), do: nil

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, payload} -> payload
      {:error, _} -> nil
    end
  end

  defp file_protocol_config(opts) do
    opts = Map.new(opts)
    file_id = Map.get(opts, :file_id, "file_fake_upload")

    %{
      mode: :success,
      file_id: file_id,
      file_name: Map.get(opts, :file_name, "fixture-upload.txt"),
      mime_type: Map.get(opts, :mime_type, "text/plain"),
      upload_url:
        Map.get(
          opts,
          :upload_url,
          "https://fake-upload.invalid/upload/#{file_id}?sig=fake-upload"
        ),
      download_url:
        Map.get(
          opts,
          :download_url,
          "https://fake-download.invalid/download/#{file_id}?sig=fake-download"
        ),
      upload_status: Map.get(opts, :upload_status, 201),
      upload_body: Map.get(opts, :upload_body, ""),
      unauthorized_payload:
        Map.get(opts, :unauthorized_payload, %{"error" => %{"code" => "invalid_api_key"}}),
      error_body: Map.get(opts, :error_body, "fake upstream file finalize failure")
    }
  end

  defp file_protocol_create_response(conn, %{mode: :unauthorized, unauthorized_payload: payload}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(payload))
  end

  defp file_protocol_create_response(conn, %{mode: :non_json_error, error_body: body}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(502, body)
  end

  defp file_protocol_create_response(conn, config) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{"file_id" => config.file_id, "upload_url" => config.upload_url})
    )
  end

  defp file_protocol_finalize_response(
         _pid,
         conn,
         %{mode: :unauthorized, unauthorized_payload: payload},
         _request
       ) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(payload))
  end

  defp file_protocol_finalize_response(
         _pid,
         conn,
         %{mode: :non_json_error, error_body: body},
         _request
       ) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(502, body)
  end

  defp file_protocol_finalize_response(pid, conn, %{mode: :finalize_retry} = config, request) do
    finalize_call = bump_route_count(pid, {request.method, request.path})

    if finalize_call == 1 do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "retry"}))
    else
      file_protocol_finalize_success(conn, config)
    end
  end

  defp file_protocol_finalize_response(_pid, conn, config, _request) do
    file_protocol_finalize_success(conn, config)
  end

  defp file_protocol_finalize_success(conn, config) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "status" => "success",
        "download_url" => config.download_url,
        "file_name" => config.file_name,
        "mime_type" => config.mime_type
      })
    )
  end

  defp bump_route_count(pid, key) do
    Agent.get_and_update(pid, fn state ->
      route_counts = Map.get(state, :route_counts, %{})
      count = Map.get(route_counts, key, 0) + 1
      {count, %{state | route_counts: Map.put(route_counts, key, count)}}
    end)
  end

  defp notify_chunk_sent(nil, _index), do: :ok
  defp notify_chunk_sent(pid, index), do: send(pid, {:fake_upstream_chunk_sent, index})

  defp wait_for_delay(interval_ms) do
    receive do
    after
      interval_ms -> :ok
    end
  end

  defp maybe_wait_for_sse_barrier(index, index, notify, release_ref) when is_pid(notify) do
    send(notify, {:fake_upstream_chunk_barrier, index, self(), release_ref})

    receive do
      {:fake_upstream_release_chunk, ^release_ref} -> :ok
    after
      30_000 -> raise "timed out waiting for fake upstream SSE barrier release"
    end
  end

  defp maybe_wait_for_sse_barrier(_index, _barrier_after, _notify, _release_ref), do: :ok

  defp wait_for_timeout_release(stage, notify, release_ref) do
    if is_pid(notify) do
      send(notify, {:fake_upstream_timeout_barrier, stage, self(), release_ref})
    end

    receive do
      {:fake_upstream_release_timeout, ^release_ref} -> :ok
    after
      30_000 -> raise "timed out waiting for fake upstream timeout release"
    end
  end

  defp safe_stop(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defmodule Websocket do
    @moduledoc false

    @behaviour WebSock

    @impl WebSock
    def init(%{pid: pid} = state) do
      websocket_pid = self()

      {connection_id, _opaque_connection_id} =
        Agent.get_and_update(pid, fn agent_state ->
          connection_count = Map.get(agent_state, :websocket_connection_count, 0) + 1
          opaque_connection_id = make_ref()

          agent_state = %{
            agent_state
            | websocket_connection_count: connection_count,
              websocket_connection_ids: [
                opaque_connection_id | Map.get(agent_state, :websocket_connection_ids, [])
              ],
              websocket_pids:
                MapSet.put(Map.get(agent_state, :websocket_pids, MapSet.new()), websocket_pid)
          }

          {{connection_count, opaque_connection_id}, agent_state}
        end)

      {:ok, Map.put(state, :connection_id, connection_id)}
    end

    @impl WebSock
    def handle_info(:fake_upstream_close_websocket, state),
      do: {:stop, :normal, {1001, "fake upstream closed websocket"}, state}

    def handle_info({:fake_upstream_close_websocket, code, reason}, state),
      do: {:stop, :normal, {code, reason}, state}

    def handle_info(
          {:fake_upstream_delayed_websocket_message, message, remaining, interval_ms},
          state
        ) do
      schedule_delayed_websocket_message(remaining, interval_ms)
      {:push, {:text, message}, state}
    end

    def handle_info(
          {:fake_upstream_release_timeout, release_ref},
          %{delayed_terminal: %{release_ref: release_ref, messages: messages}} = state
        ) do
      {:push, Enum.map(messages, &{:text, &1}), Map.delete(state, :delayed_terminal)}
    end

    def handle_info(
          {:fake_upstream_terminal_close_barrier, code, reason, notify, release_ref},
          state
        ) do
      await_websocket_barrier(:before_close, notify, release_ref)
      {:stop, :normal, {code, reason}, state}
    end

    def handle_info(_message, state), do: {:ok, state}

    @impl WebSock
    def terminate(_reason, %{pid: pid}) do
      websocket_pid = self()

      Agent.update(pid, fn agent_state ->
        %{
          agent_state
          | websocket_pids:
              MapSet.delete(Map.get(agent_state, :websocket_pids, MapSet.new()), websocket_pid)
        }
      end)

      :ok
    catch
      :exit, _reason -> :ok
    end

    @impl WebSock
    def handle_control({_payload, opcode: opcode}, %{pid: pid} = state)
        when opcode in [:ping, :pong] do
      frame = %{opcode: opcode, websocket_connection_id: state.connection_id}

      notify =
        Agent.get_and_update(pid, fn agent_state ->
          notify = Map.get(agent_state, :websocket_control_notify)

          {notify,
           %{
             agent_state
             | websocket_control_frames: [
                 frame | Map.get(agent_state, :websocket_control_frames, [])
               ]
           }}
        end)

      if is_pid(notify) do
        send(notify, {:fake_upstream_websocket_control, opcode, state.connection_id})
      end

      {:ok, state}
    end

    @impl WebSock
    def handle_in({payload, [opcode: :text]}, %{pid: pid} = state) do
      request = %{
        method: "WEBSOCKET",
        path: "/backend-api/codex/responses",
        query_string: "",
        headers: Map.get(state, :headers, []),
        websocket_connection_id: state.connection_id,
        body: payload,
        json: decode_json(payload)
      }

      mode =
        Agent.get_and_update(pid, fn agent_state ->
          {mode, next_mode} = next_response_mode(agent_state.mode)
          {mode, %{agent_state | mode: next_mode, requests: [request | agent_state.requests]}}
        end)

      case websocket_messages(mode, request) do
        {:close, code, reason} ->
          {:stop, reason, {code, reason}, state}

        {:push_then_close, messages, code, reason} ->
          send(self(), {:fake_upstream_close_websocket, code, reason})
          {:push, Enum.map(messages, &{:text, &1}), state}

        {:barrier_push_then_close, terminal, code, reason, notify, release_ref} ->
          await_websocket_barrier(:before_terminal, notify, release_ref)

          send(
            self(),
            {:fake_upstream_terminal_close_barrier, code, reason, notify, release_ref}
          )

          {:push, {:text, terminal}, state}

        {:barrier_close, code, reason, notify, release_ref} ->
          await_websocket_barrier(:before_close, notify, release_ref)
          {:stop, :normal, {code, reason}, state}

        {:delayed_push, messages, interval_ms} ->
          schedule_delayed_websocket_message(messages, interval_ms)
          {:ok, state}

        {:delayed_terminal, messages, terminal, notify, release_ref} ->
          if is_pid(notify) do
            send(notify, {:fake_upstream_timeout_barrier, :before_terminal, self(), release_ref})
          end

          next_state =
            Map.put(state, :delayed_terminal, %{release_ref: release_ref, messages: terminal})

          {:push, Enum.map(messages, &{:text, &1}), next_state}

        messages ->
          {:push, Enum.map(messages, &{:text, &1}), state}
      end
    end

    def handle_in({_payload, [opcode: :binary]}, state), do: {:stop, :unsupported_binary, state}

    defp websocket_messages({:json, _status, payload}, _request), do: [Jason.encode!(payload)]

    defp websocket_messages({:json_headers, _status, payload, _headers}, _request),
      do: [Jason.encode!(payload)]

    defp websocket_messages(
           {:reject_json_field, field, _success_status, success_payload, error_status,
            error_payload},
           request
         ) do
      if is_map(request.json) and Map.has_key?(request.json, field) do
        [
          Jason.encode!(%{
            "type" => "error",
            "status" => error_status,
            "error" => error_payload["error"] || error_payload
          })
        ]
      else
        [Jason.encode!(success_payload)]
      end
    end

    defp websocket_messages(
           {:require_json_field, field, _success_status, success_payload, error_status,
            error_payload},
           request
         ) do
      if is_map(request.json) and Map.has_key?(request.json, field) do
        [Jason.encode!(success_payload)]
      else
        [
          Jason.encode!(%{
            "type" => "error",
            "status" => error_status,
            "error" => error_payload["error"] || error_payload
          })
        ]
      end
    end

    defp websocket_messages({:sse, chunks}, _request),
      do: messages_from_sse_chunk(Enum.join(chunks))

    defp websocket_messages({:sse_headers, chunks, _headers}, _request),
      do: messages_from_sse_chunk(Enum.join(chunks))

    defp websocket_messages({:delayed_sse, chunks, interval_ms, _notify}, _request),
      do: {:delayed_push, Enum.flat_map(chunks, &messages_from_sse_chunk/1), interval_ms}

    defp websocket_messages(
           {:delayed_terminal_sse, before_terminal, terminal, notify, release_ref},
           _request
         ) do
      {:delayed_terminal, Enum.flat_map(before_terminal, &messages_from_sse_chunk/1),
       Enum.flat_map(terminal, &messages_from_sse_chunk/1), notify, release_ref}
    end

    defp websocket_messages({:timeout_mid_stream, first_chunk, notify, release_ref}, _request) do
      if is_pid(notify) do
        send(notify, {:fake_upstream_timeout_barrier, :mid_stream, self(), release_ref})
      end

      messages_from_sse_chunk(first_chunk)
    end

    defp websocket_messages({:websocket_text, messages}, _request), do: messages

    defp websocket_messages({:websocket_sse_then_close, chunks, code, reason}, _request) do
      {:push_then_close, messages_from_sse_chunk(Enum.join(chunks)), code, reason}
    end

    defp websocket_messages(
           {:websocket_terminal_then_close_barrier, terminal, code, reason, notify, release_ref},
           _request
         ) do
      {:barrier_push_then_close, terminal, code, reason, notify, release_ref}
    end

    defp websocket_messages(
           {:websocket_close_without_terminal_barrier, code, reason, notify, release_ref},
           _request
         ) do
      {:barrier_close, code, reason, notify, release_ref}
    end

    defp websocket_messages({:barrier_sse, chunks, barrier_after, notify, release_ref}, _request) do
      maybe_wait_for_sse_barrier(0, barrier_after, notify, release_ref)

      chunks
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {chunk, index} ->
        if is_pid(notify), do: send(notify, {:fake_upstream_chunk_sent, index})
        maybe_wait_for_sse_barrier(index, barrier_after, notify, release_ref)

        messages_from_sse_chunk(chunk)
      end)
    end

    defp websocket_messages({:json_error, status, payload}, _request),
      do: [
        Jason.encode!(%{
          "type" => "error",
          "status" => status,
          "error" => payload["error"] || payload
        })
      ]

    defp websocket_messages({:non_json_error, status, body}, _request),
      do: [
        Jason.encode!(%{"type" => "error", "status" => status, "error" => %{"message" => body}})
      ]

    defp websocket_messages(_mode, _request),
      do: {:close, 1011, "unsupported fake websocket mode"}

    defp next_response_mode({:sequence, [mode]}), do: {mode, mode}

    defp next_response_mode({:sequence, [mode | remaining]}), do: {mode, {:sequence, remaining}}

    defp next_response_mode(mode), do: {mode, mode}

    defp messages_from_sse_chunk(chunk) do
      chunk
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
      |> Enum.reject(&(&1 in ["", "[DONE]"]))
    end

    defp schedule_delayed_websocket_message([], _interval_ms), do: :ok

    defp schedule_delayed_websocket_message([message | remaining], interval_ms) do
      Process.send_after(
        self(),
        {:fake_upstream_delayed_websocket_message, message, remaining, interval_ms},
        interval_ms
      )

      :ok
    end

    defp maybe_wait_for_sse_barrier(index, index, notify, release_ref) when is_pid(notify) do
      send(notify, {:fake_upstream_chunk_barrier, index, self(), release_ref})

      receive do
        {:fake_upstream_release_chunk, ^release_ref} -> :ok
      after
        30_000 -> raise "timed out waiting for fake upstream websocket SSE barrier release"
      end
    end

    defp maybe_wait_for_sse_barrier(_index, _barrier_after, _notify, _release_ref), do: :ok

    defp await_websocket_barrier(stage, notify, release_ref) do
      send(notify, {:fake_upstream_websocket_barrier, stage, self(), release_ref})

      receive do
        {:fake_upstream_release_websocket, ^release_ref} -> :ok
      after
        30_000 -> raise "timed out waiting for fake upstream websocket barrier release"
      end
    end

    defp decode_json(""), do: nil

    defp decode_json(body) do
      case Jason.decode(body) do
        {:ok, payload} -> payload
        {:error, _} -> nil
      end
    end
  end
end
