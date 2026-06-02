defmodule CodexPoolerWeb.Telemetry.MemorySampler do
  @moduledoc false

  use GenServer

  require Logger

  @event [:vm, :memory]
  @default_threshold_ratio 0.70
  @default_min_interval_ms 60_000
  @default_top_processes 20
  @default_top_ets_tables 20
  @cgroup_limit_paths [
    "/sys/fs/cgroup/memory.max",
    "/sys/fs/cgroup/memory/memory.limit_in_bytes"
  ]
  @cgroup_usage_paths [
    "/sys/fs/cgroup/memory.current",
    "/sys/fs/cgroup/memory/memory.usage_in_bytes"
  ]
  @cgroup_stat_paths [
    "/sys/fs/cgroup/memory.stat",
    "/sys/fs/cgroup/memory/memory.stat"
  ]
  @cgroup_stat_keys ~w(
    anon
    file
    kernel_stack
    slab
    inactive_file
    active_file
    rss
    cache
    total_rss
    total_cache
  )a
  @cgroup_stat_key_map Map.new(@cgroup_stat_keys, &{Atom.to_string(&1), &1})
  @unbounded_cgroup_limit 1_000_000_000_000_000

  @type config :: %{
          enabled?: boolean(),
          attach_id: term(),
          limit_bytes: pos_integer() | nil,
          threshold_ratio: float(),
          min_interval_ms: non_neg_integer(),
          top_processes: pos_integer(),
          top_ets_tables: pos_integer(),
          cgroup_usage_reader: (-> non_neg_integer() | nil),
          cgroup_stat_reader: (-> map()),
          env_reader: (String.t() -> String.t() | nil)
        }

  @type state :: %{
          config: config(),
          last_logged_monotonic_ms: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) when is_list(opts) do
    Process.flag(:trap_exit, true)

    config = config(opts)

    if config.enabled? do
      :ok = attach(config.attach_id, self())
      {:ok, %{config: config, last_logged_monotonic_ms: nil}}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_info({__MODULE__, :vm_memory, measurements}, state) when is_map(measurements) do
    {:noreply, maybe_log_snapshot(measurements, state)}
  end

  @impl GenServer
  def terminate(_reason, %{config: %{attach_id: attach_id}}) do
    :telemetry.detach(attach_id)
    :ok
  end

  @spec handle_memory_event([atom()], map(), map(), pid()) :: :ok
  def handle_memory_event(_event, measurements, _metadata, server) when is_pid(server) do
    send(server, {__MODULE__, :vm_memory, measurements})
    :ok
  end

  defp attach(attach_id, server) do
    case :telemetry.attach(attach_id, @event, &__MODULE__.handle_memory_event/4, server) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp maybe_log_snapshot(measurements, %{config: config} = state) do
    cgroup_usage_bytes = config.cgroup_usage_reader.()

    if threshold_exceeded?(measurements, cgroup_usage_bytes, config) and
         interval_elapsed?(state.last_logged_monotonic_ms, config.min_interval_ms) do
      log_snapshot(measurements, cgroup_usage_bytes, config)
      %{state | last_logged_monotonic_ms: monotonic_ms()}
    else
      state
    end
  end

  defp threshold_exceeded?(_measurements, _cgroup_usage_bytes, %{limit_bytes: nil}), do: false

  defp threshold_exceeded?(measurements, cgroup_usage_bytes, %{
         limit_bytes: limit_bytes,
         threshold_ratio: ratio
       }) do
    observed_bytes =
      [integer_measurement(measurements, :total), cgroup_usage_bytes]
      |> Enum.filter(&is_integer/1)
      |> then(&[0 | &1])
      |> Enum.max()

    observed_bytes >= floor(limit_bytes * ratio)
  end

  defp interval_elapsed?(nil, _min_interval_ms), do: true

  defp interval_elapsed?(last_logged_monotonic_ms, min_interval_ms),
    do: monotonic_ms() - last_logged_monotonic_ms >= min_interval_ms

  defp log_snapshot(measurements, cgroup_usage_bytes, config) do
    memory = sanitized_memory_measurements(measurements)
    role = role_metadata(config.env_reader)
    cgroup_memory_stat = sanitized_cgroup_memory_stat(config.cgroup_stat_reader.())
    top_processes = top_processes(config.top_processes, :memory)
    top_message_queues = top_processes(config.top_processes, :message_queue_len)
    top_ets_tables = top_ets_tables(config.top_ets_tables)

    Logger.warning(fn ->
      [
        "memory sampler threshold exceeded",
        "beam_total_bytes=#{memory[:total] || "unknown"}",
        "cgroup_usage_bytes=#{cgroup_usage_bytes || "unknown"}",
        "limit_bytes=#{config.limit_bytes}",
        "threshold_ratio=#{config.threshold_ratio}",
        "role=#{json!(role)}",
        "process_count=#{:erlang.system_info(:process_count)}",
        "port_count=#{:erlang.system_info(:port_count)}",
        "memory=#{json!(memory)}",
        "cgroup_memory_stat=#{json!(cgroup_memory_stat)}",
        "top_processes=#{json!(top_processes)}",
        "top_message_queues=#{json!(top_message_queues)}",
        "top_ets_tables=#{json!(top_ets_tables)}"
      ]
      |> Enum.join(" ")
    end)
  end

  defp top_processes(limit, sort_key) do
    Process.list()
    |> Enum.flat_map(&process_snapshot/1)
    |> Enum.sort_by(&Map.fetch!(&1, sort_key), :desc)
    |> Enum.take(limit)
  end

  defp process_snapshot(pid) do
    keys = [
      :memory,
      :message_queue_len,
      :initial_call,
      :current_function,
      :current_stacktrace,
      :status,
      :heap_size,
      :total_heap_size,
      :registered_name
    ]

    case Process.info(pid, keys) do
      nil ->
        []

      info ->
        [
          %{
            pid: inspect(pid),
            memory: info_value(info, :memory, 0),
            message_queue_len: info_value(info, :message_queue_len, 0),
            heap_size: info_value(info, :heap_size, 0),
            total_heap_size: info_value(info, :total_heap_size, 0),
            status: info_value(info, :status, :unknown) |> safe_atom(),
            initial_call: info_value(info, :initial_call, nil) |> safe_mfa(),
            current_function: info_value(info, :current_function, nil) |> safe_mfa(),
            current_stacktrace: info_value(info, :current_stacktrace, []) |> safe_stacktrace(),
            registered_name: info_value(info, :registered_name, nil) |> safe_registered_name()
          }
        ]
    end
  end

  defp sanitized_memory_measurements(measurements) do
    measurements
    |> Map.take([
      :total,
      :processes,
      :processes_used,
      :binary,
      :ets,
      :atom,
      :atom_used,
      :code,
      :system
    ])
    |> Map.new(fn {key, value} -> {key, integer_or_nil(value)} end)
  end

  defp role_metadata(env_reader) do
    %{
      oban_mode: safe_string(env_reader.("OBAN_MODE")),
      hostname: safe_string(env_reader.("HOSTNAME")),
      release_node: safe_string(env_reader.("RELEASE_NODE")),
      node: node() |> Atom.to_string() |> safe_string()
    }
  end

  defp top_ets_tables(limit) do
    :ets.all()
    |> Enum.flat_map(&ets_table_snapshot/1)
    |> Enum.sort_by(&Map.fetch!(&1, :memory_words), :desc)
    |> Enum.take(limit)
  end

  defp ets_table_snapshot(table) do
    case :ets.info(table) do
      :undefined ->
        []

      info when is_list(info) ->
        owner = Keyword.get(info, :owner)

        [
          %{
            table: inspect(table),
            name: info |> Keyword.get(:name) |> safe_ets_value(),
            owner: inspect(owner),
            owner_name: owner_registered_name(owner),
            memory_words: info_value(info, :memory, 0),
            size: info_value(info, :size, 0),
            type: info |> Keyword.get(:type) |> safe_atom()
          }
        ]
    end
  end

  defp config(opts) do
    app_config = Application.get_env(:codex_pooler, __MODULE__, [])
    merged = Keyword.merge(app_config, opts)

    %{
      enabled?: option_bool(merged, :enabled?, "CODEX_POOLER_MEMORY_SAMPLER_ENABLED", true),
      attach_id: Keyword.get(merged, :attach_id, {__MODULE__, node()}),
      limit_bytes:
        option_integer(merged, :limit_bytes, "CODEX_POOLER_MEMORY_SAMPLER_LIMIT_BYTES") ||
          cgroup_limit_bytes(),
      threshold_ratio:
        option_float(
          merged,
          :threshold_ratio,
          "CODEX_POOLER_MEMORY_SAMPLER_THRESHOLD_RATIO",
          @default_threshold_ratio
        ),
      min_interval_ms:
        option_integer(
          merged,
          :min_interval_ms,
          "CODEX_POOLER_MEMORY_SAMPLER_MIN_INTERVAL_MS",
          @default_min_interval_ms
        ),
      top_processes:
        option_integer(
          merged,
          :top_processes,
          "CODEX_POOLER_MEMORY_SAMPLER_TOP_PROCESSES",
          @default_top_processes
        ),
      top_ets_tables:
        option_integer(
          merged,
          :top_ets_tables,
          "CODEX_POOLER_MEMORY_SAMPLER_TOP_ETS_TABLES",
          @default_top_ets_tables
        ),
      cgroup_usage_reader: Keyword.get(merged, :cgroup_usage_reader, &cgroup_usage_bytes/0),
      cgroup_stat_reader: Keyword.get(merged, :cgroup_stat_reader, &cgroup_memory_stat/0),
      env_reader: Keyword.get(merged, :env_reader, &System.get_env/1)
    }
  end

  defp option_bool(opts, key, env_name, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> parse_bool(value, default)
      :error -> env_name |> System.get_env() |> parse_bool(default)
    end
  end

  defp option_integer(opts, key, env_name, default \\ nil) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> parse_positive_integer(value, default)
      :error -> env_name |> System.get_env() |> parse_positive_integer(default)
    end
  end

  defp option_float(opts, key, env_name, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> parse_ratio(value, default)
      :error -> env_name |> System.get_env() |> parse_ratio(default)
    end
  end

  defp parse_bool(value, _default) when value in [true, false], do: value

  defp parse_bool(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in ~w(true 1 yes on) -> true
      value when value in ~w(false 0 no off) -> false
      _value -> default
    end
  end

  defp parse_bool(_value, default), do: default

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp parse_ratio(value, _default) when is_float(value) and value > 0 and value <= 1,
    do: value

  defp parse_ratio(value, _default) when is_integer(value) and value > 0 and value <= 1,
    do: value / 1

  defp parse_ratio(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {ratio, ""} when ratio > 0 and ratio <= 1 -> ratio
      _other -> default
    end
  end

  defp parse_ratio(_value, default), do: default

  defp cgroup_limit_bytes do
    @cgroup_limit_paths
    |> Enum.find_value(&read_cgroup_integer/1)
    |> case do
      limit when is_integer(limit) and limit < @unbounded_cgroup_limit -> limit
      _unbounded_or_missing -> nil
    end
  end

  defp cgroup_usage_bytes do
    Enum.find_value(@cgroup_usage_paths, &read_cgroup_integer/1)
  end

  defp cgroup_memory_stat do
    @cgroup_stat_paths
    |> Enum.find_value(&read_cgroup_stat/1)
    |> case do
      stat when is_map(stat) -> stat
      _missing -> %{}
    end
  end

  defp read_cgroup_stat(path) do
    with {:ok, stat} <- File.read(path) do
      stat
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ~r/\s+/, parts: 2, trim: true) do
          [key, value] ->
            with {:ok, key} <- Map.fetch(@cgroup_stat_key_map, key),
                 {integer, ""} when integer >= 0 <- Integer.parse(value) do
              Map.put(acc, key, integer)
            else
              _ignored -> acc
            end

          _other ->
            acc
        end
      end)
    else
      _error -> nil
    end
  end

  defp sanitized_cgroup_memory_stat(stat) when is_map(stat) do
    stat
    |> Map.take(@cgroup_stat_keys)
    |> Map.new(fn {key, value} -> {key, integer_or_nil(value)} end)
  end

  defp sanitized_cgroup_memory_stat(_stat), do: %{}

  defp read_cgroup_integer(path) do
    with {:ok, value} <- File.read(path),
         {integer, ""} <- value |> String.trim() |> Integer.parse(),
         true <- integer > 0 do
      integer
    else
      _error -> nil
    end
  end

  defp integer_measurement(measurements, key) do
    measurements |> Map.get(key) |> integer_or_nil()
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp info_value(info, key, default), do: Keyword.get(info, key, default)

  defp safe_mfa({module, function, arity}) when is_atom(module) and is_atom(function),
    do: "#{inspect(module)}.#{function}/#{arity}"

  defp safe_mfa(_value), do: "unknown"

  defp safe_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_atom(_value), do: "unknown"

  defp safe_registered_name(name) when is_atom(name), do: Atom.to_string(name)
  defp safe_registered_name(_name), do: "unknown"

  defp safe_ets_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_ets_value(value) when is_reference(value), do: inspect(value)
  defp safe_ets_value(_value), do: "unknown"

  defp owner_registered_name(pid) when is_pid(pid) do
    pid
    |> Process.info(:registered_name)
    |> case do
      {:registered_name, name} -> safe_registered_name(name)
      _other -> "unknown"
    end
  end

  defp owner_registered_name(_owner), do: "unknown"

  defp safe_string(value) when is_binary(value) and value != "" do
    value
  end

  defp safe_string(_value), do: "unknown"

  defp safe_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(8)
    |> Enum.map(&safe_stacktrace_entry/1)
  end

  defp safe_stacktrace(_stacktrace), do: []

  defp safe_stacktrace_entry({module, function, arity, location})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    %{
      mfa: safe_mfa({module, function, arity}),
      file: safe_stacktrace_file(location),
      line: safe_stacktrace_line(location)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_stacktrace_entry(_entry), do: %{mfa: "unknown"}

  defp safe_stacktrace_file(location) when is_list(location) do
    case Keyword.get(location, :file) do
      file when is_binary(file) -> file
      file when is_list(file) -> List.to_string(file)
      _file -> nil
    end
  end

  defp safe_stacktrace_file(_location), do: nil

  defp safe_stacktrace_line(location) when is_list(location) do
    case Keyword.get(location, :line) do
      line when is_integer(line) -> line
      _line -> nil
    end
  end

  defp safe_stacktrace_line(_location), do: nil

  defp json!(value), do: Jason.encode!(value)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
