defmodule CodexPooler.Jobs.FailureLog do
  @moduledoc """
  Writes one bounded warning line for every Oban job that fails or is discarded.

  Oban prunes finished jobs after a day and the job roles run no Prometheus
  reporter, so without this line a failed or discarded job leaves no trace once
  its row is pruned. The line carries metadata only: the worker, queue, job id,
  attempt, the Oban outcome, the error's class and, when the job returned one,
  a bounded identifier-shaped reason code. Job args, exception messages,
  returned strings and stacktraces are never written, because any of them can
  carry request, account or secret material.
  """

  require Logger

  @handler_id {__MODULE__, :job_failure}
  @events [[:oban, :job, :exception], [:oban, :job, :stop]]
  @identifier ~r/\A[A-Za-z0-9_.-]{1,80}\z/
  @worker ~r/\A[A-Za-z0-9_.]{1,160}\z/

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, :ok) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:oban, :job, :exception], measurements, %{state: state} = metadata, _config)
      when state in [:failure, :discard] do
    log(measurements, metadata, outcome(state), Map.get(metadata, :kind), error_class(metadata[:reason]), reason_code(metadata[:reason]))
  end

  # A worker that returns `{:discard, reason}` finishes through the stop event.
  def handle_event([:oban, :job, :stop], measurements, %{state: :discard} = metadata, _config) do
    log(measurements, metadata, "discarded", nil, nil, reason_code(metadata[:result]))
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec log_line(map(), map(), String.t(), term(), String.t() | nil, String.t() | nil) :: String.t()
  defp log_line(measurements, metadata, outcome, kind, error_class, reason_code) do
    job = Map.get(metadata, :job) || %{}

    [
      "oban job #{outcome}",
      "worker=#{worker(Map.get(job, :worker))}",
      "queue=#{identifier(Map.get(job, :queue)) || "unknown"}",
      "job_id=#{integer(Map.get(job, :id))}",
      "attempt=#{integer(Map.get(job, :attempt))}",
      "max_attempts=#{integer(Map.get(job, :max_attempts))}",
      kind_field(kind),
      error_class && "error=#{error_class}",
      reason_code && "reason=#{reason_code}",
      "duration_ms=#{duration_ms(measurements)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # The handler must never raise: :telemetry detaches a handler that does, and
  # every later failure would then go unlogged.
  defp log(measurements, metadata, outcome, kind, error_class, reason_code) do
    Logger.warning(log_line(measurements, metadata, outcome, kind, error_class, reason_code))
  rescue
    _exception -> :ok
  end

  defp outcome(:failure), do: "failed"
  defp outcome(:discard), do: "discarded"

  defp kind_field(kind) when kind in [:error, :exit, :throw], do: "kind=#{kind}"
  defp kind_field(_kind), do: nil

  defp error_class(%{__struct__: module}) when is_atom(module), do: worker(inspect(module))
  defp error_class(_reason), do: nil

  defp reason_code(%Oban.PerformError{reason: reason}), do: reason_code(reason)
  defp reason_code({tag, reason}) when tag in [:error, :discard, :cancel], do: reason_code(reason)
  defp reason_code(%Oban.TimeoutError{}), do: "timeout"
  defp reason_code(%{__exception__: true}), do: nil
  defp reason_code(reason) when is_atom(reason) and not is_nil(reason) and not is_boolean(reason), do: identifier(reason)
  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)), do: reason_code(elem(reason, 0))
  defp reason_code(%{code: code}) when is_atom(code) or is_binary(code), do: identifier(code)
  defp reason_code(_reason), do: nil

  defp identifier(value) when is_atom(value) and not is_nil(value), do: identifier(Atom.to_string(value))

  defp identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: value
  end

  defp identifier(_value), do: nil

  defp worker(value) when is_binary(value) do
    value = String.replace_prefix(value, "Elixir.", "")
    if Regex.match?(@worker, value), do: value, else: "unknown"
  end

  defp worker(_value), do: "unknown"

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: "unknown"

  defp duration_ms(%{duration: duration}) when is_integer(duration), do: System.convert_time_unit(duration, :native, :millisecond)
  defp duration_ms(_measurements), do: "unknown"
end
