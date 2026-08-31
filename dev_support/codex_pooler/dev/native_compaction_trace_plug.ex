defmodule CodexPooler.Dev.NativeCompactionTrace.Plug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn
  alias CodexPooler.Dev.NativeCompactionTrace

  @impl true
  def init(opts), do: opts

  def call(%Plug.Conn{remote_ip: remote_ip} = conn, _opts)
      when remote_ip not in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}],
      do: json(conn, 403, %{"error" => "loopback_only"})

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: []} = conn, _opts),
    do: json(conn, 200, NativeCompactionTrace.export())

  def call(%Plug.Conn{method: "GET", path_info: ["status"]} = conn, _opts),
    do: json(conn, 200, NativeCompactionTrace.status())

  def call(%Plug.Conn{method: "POST", path_info: ["flush"]} = conn, _opts) do
    case NativeCompactionTrace.flush() do
      :ok -> json(conn, 200, NativeCompactionTrace.status())
      {:error, :trace_truncated} -> json(conn, 507, NativeCompactionTrace.status())
      {:error, :not_started} -> json(conn, 409, %{"error" => "trace_not_started"})
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["start"]} = conn, _opts) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, %{"run" => run} = decoded} <- Jason.decode(body),
         true <- valid_start_keys?(decoded),
         limit when is_integer(limit) and limit > 0 <- Map.get(decoded, "limit", 512),
         {:ok, mode} <- parse_mode(Map.get(decoded, "mode", "safe")),
         {:ok, preset} <- parse_preset(Map.get(decoded, "preset")),
         {:ok, modules} <- parse_module_filters(decoded),
         {:ok, limits} <- parse_full_limits(decoded),
         {:ok, status} <-
           NativeCompactionTrace.start_scope(
             run,
             [limit: limit, mode: mode] ++ preset ++ modules ++ limits
           ) do
      json(conn, 200, status)
    else
      {:error, :full_trace_unavailable} ->
        json(conn, 403, %{"error" => "full_trace_unavailable"})

      {:error, {:trace_modules_unavailable, modules}} ->
        json(conn, 400, %{"error" => "trace_modules_unavailable", "modules" => modules})

      {:error, %{code: :invalid_trace_limit} = error} ->
        json(conn, 400, %{
          "error" => "invalid_trace_limit",
          "field" => to_string(error.field),
          "value" => error.value,
          "minimum" => error.minimum,
          "maximum" => error.maximum
        })

      {:error, :invalid_trace_run_label} ->
        json(conn, 400, %{"error" => "invalid_trace_run_label"})

      _invalid ->
        json(conn, 400, %{"error" => "invalid_trace_scope"})
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["stop"]} = conn, _opts) do
    :ok = NativeCompactionTrace.stop_scope()
    json(conn, 200, NativeCompactionTrace.status())
  end

  def call(conn, _opts), do: json(conn, 404, %{"error" => "not_found"})

  defp parse_mode("safe"), do: {:ok, :safe}
  defp parse_mode("full"), do: {:ok, :full}
  defp parse_mode(_mode), do: {:error, :invalid_trace_mode}

  defp valid_start_keys?(decoded) do
    allowed = ~w(run limit mode preset includeModules excludeModules maxEvents maxBytes)
    Map.has_key?(decoded, "run") and Enum.all?(Map.keys(decoded), &(&1 in allowed))
  end

  defp parse_preset(nil), do: {:ok, []}
  defp parse_preset("f3_happy"), do: {:ok, [preset: :f3_happy]}
  defp parse_preset(_preset), do: {:error, :invalid_trace_preset}

  defp parse_module_filters(decoded) do
    include = Map.get(decoded, "includeModules", [])
    exclude = Map.get(decoded, "excludeModules", [])

    if is_list(include) and is_list(exclude) and
         Enum.all?(include ++ exclude, &is_binary/1) do
      {:ok, [include_modules: include, exclude_modules: exclude]}
    else
      {:error, :invalid_module_filters}
    end
  end

  defp parse_full_limits(decoded) do
    max_events = Map.get(decoded, "maxEvents")
    max_bytes = Map.get(decoded, "maxBytes")

    opts =
      []
      |> maybe_put(:max_events, max_events)
      |> maybe_put(:max_bytes, max_bytes)

    case NativeCompactionTrace.validate_full_limits(opts) do
      :ok -> {:ok, opts}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp json(conn, status, body) do
    conn
    |> put_resp_header("x-native-compaction-trace", "pooler-native-compaction-trace-v1")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
