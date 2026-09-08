defmodule CodexPoolerWeb.Telemetry.HistogramCollector do
  @moduledoc false
  use GenServer

  alias TelemetryMetricsPrometheus.Core

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def metrics(name), do: :persistent_term.get({__MODULE__, name})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)
    metrics = Keyword.fetch!(opts, :metrics)
    %{aggregates_table_id: table} = Core.Registry.config(name)
    table = :ets.whereis(table)

    # Validate everything before attaching the first handler.
    Enum.each(metrics, &Core.Registry.validate_distribution_buckets!/1)

    handlers =
      Enum.map(metrics, fn metric ->
        id = {__MODULE__, name, metric.name}
        # A killed process cannot run terminate/2; replace its stale handler.
        :telemetry.detach(id)
        boundaries = Core.Registry.validate_distribution_buckets!(metric)
        config = %{metric: metric, table: table, buckets: boundaries}
        :ok = :telemetry.attach(id, metric.event_name, &__MODULE__.handle_event/4, config)
        id
      end)

    :persistent_term.put({__MODULE__, name}, metrics)
    {:ok, %{name: name, handlers: handlers}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handlers, &:telemetry.detach/1)
    :persistent_term.erase({__MODULE__, state.name})
    :ok
  end

  @doc false
  def handle_event(_event, measurements, metadata, config) do
    case observation(config.metric, measurements, metadata) do
      {:ok, key, value} ->
        head_key = if match_variable?(key), do: :"$2", else: key
        update(config.table, key, head_key, value, config.buckets)

      :skip ->
        :ok
    end
  end

  defp observation(metric, measurements, metadata) do
    with true <- Core.EventHandler.keep?(metric.keep, metadata),
         {:ok, value} <-
           Core.EventHandler.get_measurement(measurements, metadata, metric.measurement),
         tags when is_map(tags) <- metric.tag_values.(metadata),
         :ok <- Core.EventHandler.validate_tags_in_tag_values(metric.tags, tags) do
      {:ok, {metric.name, Map.take(tags, metric.tags)}, value}
    else
      _missing_or_invalid -> :skip
    end
  rescue
    # Unit conversion can raise before Core validates malformed input. Only
    # callback extraction is guarded; aggregation bugs must remain visible.
    _error in [ArithmeticError, ArgumentError, BadMapError, KeyError] -> :skip
  end

  # Normal string labels retain ETS's bound-key fast path. Unusual literal
  # match-variable atoms must be compared through a constant guard instead.
  defp match_variable?(value) when is_atom(value) do
    value == :_ or String.starts_with?(Atom.to_string(value), "$")
  end

  defp match_variable?(value) when is_list(value), do: Enum.any?(value, &match_variable?/1)

  defp match_variable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> match_variable?()

  defp match_variable?(value) when is_map(value), do: value |> Map.to_list() |> match_variable?()
  defp match_variable?(_value), do: false

  defp update(table, key, head_key, value, boundaries) do
    case :ets.lookup(table, key) do
      [] ->
        buckets = Enum.map(boundaries, &{to_string(&1), if(value <= &1, do: 1, else: 0)})
        initial = {buckets ++ [{"+Inf", 1}], 1, value}

        if :ets.insert_new(table, {key, initial}),
          do: :ok,
          else: update(table, key, head_key, value, boundaries)

      [{^key, {buckets, count, sum} = previous}] ->
        updated = {increment_buckets(buckets, boundaries, value), count + 1, sum + value}

        match_spec = [
          {{head_key, :"$1"},
           [{:"=:=", {:element, 1, :"$_"}, {:const, key}}, {:"=:=", :"$1", {:const, previous}}],
           [{{{:element, 1, :"$_"}, {:const, updated}}}]}
        ]

        case :ets.select_replace(table, match_spec) do
          1 -> :ok
          0 -> update(table, key, head_key, value, boundaries)
        end
    end
  rescue
    error in ArgumentError ->
      # An event already executing during registry shutdown can outlive detach.
      # Its old table id must never write into the replacement registry.
      if :ets.info(table) == :undefined, do: :ok, else: reraise(error, __STACKTRACE__)
  end

  defp increment_buckets(buckets, boundaries, value) do
    Enum.zip_with(boundaries ++ [:infinity], buckets, fn boundary, {label, count} ->
      {label, count + if(boundary == :infinity or value <= boundary, do: 1, else: 0)}
    end)
  end
end
