defmodule CodexPooler.Dev.GatewayPerfProbe do
  @moduledoc """
  Opt-in local gateway performance evidence collector.

  The probe records metadata-only Phoenix endpoint, Ecto query, and BEAM memory
  summaries for local performance runs. It is intentionally disabled unless
  `CODEX_POOLER_PERF_PROBE=1` is set at runtime boot.
  """

  use GenServer

  alias CodexPooler.Repo

  @endpoint_start_event [:phoenix, :endpoint, :start]
  @endpoint_stop_event [:phoenix, :endpoint, :stop]
  @repo_query_event [:codex_pooler, :repo, :query]
  @handler_id {__MODULE__, :telemetry}
  @process_context_key {__MODULE__, :request_context}
  @default_root Path.join(["tmp", "gateway-perf"])
  @default_phase "measured"
  @unknown "unknown"

  @type context :: %{
          required(:run_id) => String.t(),
          required(:scenario) => String.t(),
          required(:route_family) => String.t(),
          required(:route_path) => String.t(),
          required(:profile) => String.t(),
          required(:phase) => String.t(),
          required(:request_index) => non_neg_integer() | nil,
          required(:request_id) => String.t() | nil,
          required(:started_at) => String.t()
        }
  @type query_entry :: %{
          command: String.t(),
          source_table: String.t(),
          query_time_ms: float(),
          checkout_ms: float()
        }
  @type request_entry :: %{
          run_id: String.t(),
          request_index: non_neg_integer() | nil,
          route_family: String.t(),
          route_path: String.t(),
          scenario: String.t(),
          profile: String.t(),
          phase: String.t(),
          status: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          attempt_count: non_neg_integer(),
          retry_count: non_neg_integer(),
          outcome: String.t(),
          request_id: String.t() | nil,
          started_at: String.t(),
          finished_at: String.t()
        }
  @type run_state :: %{
          run_id: String.t(),
          dir: String.t(),
          started_at: String.t(),
          finished_at: String.t() | nil,
          queries: [query_entry()],
          requests: [request_entry()],
          before_memory: map(),
          after_memory: map() | nil
        }

  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("CODEX_POOLER_PERF_PROBE") == "1"

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec handle_event(list(atom()), map(), map(), term()) :: :ok
  def handle_event(@endpoint_start_event, _measurements, %{conn: conn}, server) do
    with true <- is_pid(server),
         {:ok, context} <- request_context(conn) do
      Process.put(@process_context_key, context)
      GenServer.cast(server, {:ensure_run, context})
    end

    :ok
  end

  def handle_event(@repo_query_event, measurements, metadata, server) do
    with true <- is_pid(server),
         %{run_id: run_id} <- Process.get(@process_context_key) do
      GenServer.cast(server, {:query, run_id, query_entry(measurements, metadata)})
    end

    :ok
  end

  def handle_event(@endpoint_stop_event, %{duration: duration}, %{conn: conn}, server) do
    with true <- is_pid(server),
         %{run_id: run_id} = context <- Process.get(@process_context_key) do
      Process.delete(@process_context_key)
      GenServer.cast(server, {:request, run_id, request_entry(context, conn, duration)})
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _server), do: :ok

  @spec flush(pid() | atom(), String.t()) :: :ok | {:error, :not_found}
  def flush(server \\ __MODULE__, run_id) when is_binary(run_id) do
    GenServer.call(server, {:flush, run_id})
  end

  @impl true
  def init(opts) do
    server = self()

    # Event names are locked from `CodexPoolerWeb.Telemetry.metrics/0` and
    # `CodexPooler.Repo`'s default Ecto telemetry prefix: endpoint start/stop and repo query.
    :ok = attach(server)

    {:ok, %{root: Keyword.get(opts, :root, @default_root), runs: %{}}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @impl true
  def handle_call({:flush, run_id}, _from, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} ->
        write_run!(run)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:ensure_run, context}, state) do
    {:noreply, ensure_run(state, context)}
  end

  def handle_cast({:query, run_id, query}, state) do
    {:noreply, update_run(state, run_id, fn run -> %{run | queries: [query | run.queries]} end)}
  end

  def handle_cast({:request, run_id, request}, state) do
    state =
      state
      |> update_run(run_id, fn run ->
        %{
          run
          | requests: [request | run.requests],
            finished_at: request.finished_at,
            after_memory: memory_row(request)
        }
      end)
      |> tap(fn state -> write_run!(Map.fetch!(state.runs, run_id)) end)

    {:noreply, state}
  end

  defp attach(server) do
    events = [@endpoint_start_event, @endpoint_stop_event, @repo_query_event]

    case :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, server) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp request_context(conn) do
    scenario = header(conn, "x-codex-pooler-perf-scenario")

    if present?(scenario) do
      run_id =
        header(conn, "x-codex-pooler-perf-run-id") ||
          System.get_env("CODEX_POOLER_PERF_RUN_ID") || "local"

      route_path = conn.request_path

      {:ok,
       %{
         run_id: safe_label(run_id),
         scenario: safe_label(scenario),
         route_family: route_family(route_path),
         route_path: safe_path(route_path),
         profile:
           safe_label(
             header(conn, "x-gateway-perf-profile") || header(conn, "x-codex-pooler-perf-profile") ||
               @unknown
           ),
         phase: safe_label(header(conn, "x-codex-pooler-perf-phase") || @default_phase),
         request_index:
           header(conn, "x-codex-pooler-perf-request-index") |> parse_non_negative_integer(),
         request_id: request_id(conn),
         started_at: now_iso8601()
       }}
    else
      :ignore
    end
  end

  defp query_entry(measurements, metadata) do
    {command, source_table} = query_fingerprint(metadata)

    %{
      command: command,
      source_table: source_table,
      query_time_ms: duration_ms(Map.get(measurements, :query_time)),
      checkout_ms: duration_ms(Map.get(measurements, :queue_time))
    }
  end

  defp request_entry(context, conn, duration) do
    request_log = request_log_metadata(context.request_id)
    status = conn.status

    %{
      run_id: context.run_id,
      request_index: context.request_index,
      route_family: context.route_family,
      route_path: context.route_path,
      scenario: context.scenario,
      profile: context.profile,
      phase: context.phase,
      status: status,
      duration_ms: round(duration_ms(duration)),
      attempt_count: Map.get(request_log, :attempt_count, 0),
      retry_count: Map.get(request_log, :retry_count, 0),
      outcome: outcome(status),
      request_id: context.request_id,
      started_at: context.started_at,
      finished_at: now_iso8601()
    }
  end

  defp request_log_metadata(nil), do: %{}

  defp request_log_metadata(request_id) do
    import Ecto.Query

    query =
      from request in CodexPooler.Accounting.Request,
        left_join: attempt in CodexPooler.Accounting.Attempt,
        on: attempt.request_id == request.id,
        where:
          request.correlation_id == ^request_id or
            fragment("?->>? = ?", request.request_metadata, "request_id", ^request_id) or
            fragment("?->>? = ?", request.request_metadata, "client_request_id", ^request_id),
        group_by: [request.id, request.retry_count],
        select: %{retry_count: coalesce(request.retry_count, 0), attempt_count: count(attempt.id)}

    case Repo.one(query) do
      nil -> %{}
      row -> %{retry_count: row.retry_count || 0, attempt_count: row.attempt_count || 0}
    end
  rescue
    _error -> %{}
  end

  defp ensure_run(%{runs: runs} = state, context) do
    if Map.has_key?(runs, context.run_id) do
      state
    else
      run = new_run(state.root, context)
      write_initial_files!(run)
      %{state | runs: Map.put(runs, context.run_id, run)}
    end
  end

  defp update_run(%{runs: runs} = state, run_id, fun) do
    case Map.fetch(runs, run_id) do
      {:ok, run} -> %{state | runs: Map.put(runs, run_id, fun.(run))}
      :error -> state
    end
  end

  defp new_run(root, context) do
    dir = Path.join([root, context.run_id, "probe"])
    before_memory = memory_row(context)

    %{
      run_id: context.run_id,
      dir: dir,
      started_at: before_memory.timestamp,
      finished_at: nil,
      queries: [],
      requests: [],
      before_memory: before_memory,
      after_memory: nil
    }
  end

  defp write_initial_files!(run) do
    File.mkdir_p!(run.dir)
    File.write!(Path.join(run.dir, "metrics-before.txt"), metrics_text(run.before_memory))
    write_memory_csv!(run)
  end

  defp write_run!(run) do
    File.mkdir_p!(run.dir)

    File.write!(
      Path.join(run.dir, "query-summary.json"),
      Jason.encode_to_iodata!(query_summary(run), pretty: true)
    )

    File.write!(
      Path.join(run.dir, "request-summary.json"),
      Jason.encode_to_iodata!(request_summary(run), pretty: true)
    )

    File.write!(
      Path.join(run.dir, "metrics-after.txt"),
      metrics_text(run.after_memory || memory_row(run))
    )

    write_memory_csv!(run)
  end

  defp query_summary(run) do
    queries = Enum.reverse(run.queries)
    requests = Enum.reverse(run.requests)
    request_count = length(requests)
    query_count = length(queries)
    query_total = sum_by(queries, :query_time_ms)
    checkouts = Enum.map(queries, & &1.checkout_ms)

    Map.merge(run_group_fields(run), %{
      request_count: request_count,
      query_count_total: query_count,
      query_count_per_request: ratio(query_count, request_count),
      query_time_ms_total: rounded(query_total),
      query_time_ms_per_request: rounded(ratio(query_total, request_count)),
      max_checkout_ms: rounded(max_value(checkouts)),
      p95_checkout_ms: rounded(percentile(checkouts, 95)),
      fingerprints: fingerprints(queries),
      started_at: run.started_at,
      finished_at: finished_at(run)
    })
  end

  defp request_summary(run) do
    requests = Enum.reverse(run.requests)
    durations = Enum.map(requests, & &1.duration_ms)

    Map.merge(run_group_fields(run), %{
      request_count: length(requests),
      success_count: Enum.count(requests, &(&1.outcome == "success")),
      failure_count: Enum.count(requests, &(&1.outcome == "failure")),
      status_counts: status_counts(requests),
      p50_duration_ms: rounded(percentile(durations, 50)),
      p95_duration_ms: rounded(percentile(durations, 95)),
      p99_duration_ms: rounded(percentile(durations, 99)),
      attempt_count_total: sum_by(requests, :attempt_count),
      retry_count_total: sum_by(requests, :retry_count),
      requests: Enum.map(requests, &request_json/1),
      started_at: run.started_at,
      finished_at: finished_at(run)
    })
  end

  defp run_group_fields(run) do
    requests = Enum.reverse(run.requests)

    %{
      run_id: run.run_id,
      scenario: common_value(requests, :scenario, @unknown),
      route_family: common_value(requests, :route_family, @unknown),
      profile: common_value(requests, :profile, @unknown),
      phase: common_value(requests, :phase, @default_phase)
    }
  end

  defp request_json(request) do
    request
    |> Map.take([
      :request_index,
      :route_family,
      :route_path,
      :profile,
      :phase,
      :status,
      :duration_ms,
      :attempt_count,
      :retry_count,
      :outcome
    ])
  end

  defp fingerprints(queries) do
    queries
    |> Enum.group_by(&{&1.command, &1.source_table})
    |> Enum.map(fn {{command, source_table}, entries} ->
      %{
        command: command,
        source_table: source_table,
        count: length(entries),
        total_time_ms: rounded(sum_by(entries, :query_time_ms)),
        max_time_ms: rounded(max_value(Enum.map(entries, & &1.query_time_ms)))
      }
    end)
    |> Enum.sort_by(&{&1.command, &1.source_table})
  end

  defp write_memory_csv!(run) do
    rows = [run.before_memory, run.after_memory || memory_row(run)]

    header =
      "timestamp,run_id,scenario,phase,beam_total_bytes,processes_bytes,binary_bytes,ets_bytes,atom_bytes,system_bytes,process_count,ets_table_count\n"

    body =
      Enum.map_join(rows, "\n", fn row ->
        [
          row.timestamp,
          row.run_id,
          row.scenario,
          row.phase,
          row.beam_total_bytes,
          row.processes_bytes,
          row.binary_bytes,
          row.ets_bytes,
          row.atom_bytes,
          row.system_bytes,
          row.process_count,
          row.ets_table_count
        ]
        |> Enum.join(",")
      end)

    File.write!(Path.join(run.dir, "memory.csv"), header <> body <> "\n")
  end

  defp memory_row(%{run_id: run_id} = source) do
    memory = :erlang.memory()

    %{
      timestamp: now_iso8601(),
      run_id: run_id,
      scenario: Map.get(source, :scenario, @unknown),
      phase: Map.get(source, :phase, @default_phase),
      beam_total_bytes: Keyword.get(memory, :total, 0),
      processes_bytes: Keyword.get(memory, :processes, 0),
      binary_bytes: Keyword.get(memory, :binary, 0),
      ets_bytes: Keyword.get(memory, :ets, 0),
      atom_bytes: Keyword.get(memory, :atom, 0),
      system_bytes: Keyword.get(memory, :system, 0),
      process_count: :erlang.system_info(:process_count),
      ets_table_count: length(:ets.all())
    }
  end

  defp metrics_text(row) do
    [
      "timestamp=#{row.timestamp}",
      "run_id=#{row.run_id}",
      "scenario=#{row.scenario}",
      "phase=#{row.phase}",
      "beam_total_bytes=#{row.beam_total_bytes}",
      "processes_bytes=#{row.processes_bytes}",
      "binary_bytes=#{row.binary_bytes}",
      "ets_bytes=#{row.ets_bytes}",
      "atom_bytes=#{row.atom_bytes}",
      "system_bytes=#{row.system_bytes}",
      "process_count=#{row.process_count}",
      "ets_table_count=#{row.ets_table_count}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp query_fingerprint(%{query: query} = metadata) when is_binary(query) do
    command = query |> String.trim_leading() |> String.split(~r/\s+/, parts: 2) |> List.first()
    source = metadata[:source] || source_table_from_query(query)
    {safe_command(command), safe_table(source)}
  end

  defp query_fingerprint(metadata) do
    source = metadata[:source]
    {@unknown, safe_table(source)}
  end

  defp source_table_from_query(query) do
    case Regex.run(~r/\b(?:FROM|JOIN|UPDATE|INTO)\s+"?([A-Za-z0-9_]+)"?/i, query) do
      [_match, table] -> table
      _other -> @unknown
    end
  end

  defp safe_command(command) when is_binary(command) do
    command
    |> String.upcase()
    |> String.replace(~r/[^A-Z_]/, "")
    |> blank_to_unknown()
  end

  defp safe_command(_command), do: @unknown

  defp safe_table(table) when is_binary(table) do
    table
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> blank_to_unknown()
  end

  defp safe_table(_table), do: @unknown

  defp route_family(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/backend-api/codex") -> "backend_codex"
      String.starts_with?(path, "/backend-api") -> "backend"
      String.starts_with?(path, "/v1") -> "v1"
      String.starts_with?(path, "/api/codex") -> "usage"
      true -> "other"
    end
  end

  defp status_counts(requests) do
    requests
    |> Enum.group_by(&(&1.status || 0))
    |> Map.new(fn {status, entries} -> {to_string(status), length(entries)} end)
  end

  defp common_value([], _key, default), do: default

  defp common_value(items, key, default) do
    values = items |> Enum.map(&Map.get(&1, key)) |> Enum.uniq()

    case values do
      [value] when not is_nil(value) -> value
      [] -> default
      _values -> "multiple"
    end
  end

  defp percentile([], _percent), do: 0.0

  defp percentile(values, percent) do
    sorted = Enum.sort(values)
    index = ceil(length(sorted) * percent / 100) - 1
    Enum.at(sorted, max(index, 0), 0)
  end

  defp max_value([]), do: 0.0
  defp max_value(values), do: Enum.max(values)

  defp sum_by(items, key), do: Enum.reduce(items, 0, &(&2 + (Map.get(&1, key) || 0)))
  defp ratio(_value, 0), do: 0.0
  defp ratio(value, count), do: value / count

  defp rounded(value) when is_float(value), do: Float.round(value, 3)
  defp rounded(value) when is_integer(value), do: value
  defp rounded(_value), do: 0

  defp duration_ms(nil), do: 0.0

  defp duration_ms(value) when is_integer(value) do
    System.convert_time_unit(value, :native, :microsecond) / 1000
  end

  defp outcome(status) when is_integer(status) and status >= 200 and status < 400, do: "success"
  defp outcome(_status), do: "failure"

  defp finished_at(%{finished_at: nil}), do: now_iso8601()
  defp finished_at(%{finished_at: finished_at}), do: finished_at

  defp header(conn, name),
    do: conn |> Plug.Conn.get_req_header(name) |> List.first() |> blank_to_nil()

  defp request_id(conn) do
    Plug.Conn.get_req_header(conn, "x-request-id") |> List.first() ||
      Plug.Conn.get_resp_header(conn, "x-request-id") |> List.first()
  end

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp safe_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.:-]/, "_")
    |> String.slice(0, 120)
    |> blank_to_unknown()
  end

  defp safe_label(_value), do: @unknown

  defp safe_path(value) when is_binary(value) do
    value
    |> String.replace(~r/[[:cntrl:]]+/, "_")
    |> String.slice(0, 200)
    |> blank_to_unknown()
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp blank_to_unknown(""), do: @unknown
  defp blank_to_unknown(value), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
end
