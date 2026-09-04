defmodule CodexPooler.Gateway.Runtime.Finalization.SettlementAttrs do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  @type attrs :: map()
  @type opts :: keyword()

  @spec success(SelectedCandidateContext.t(), pos_integer(), map(), opts()) :: attrs()
  def success(%SelectedCandidateContext{} = context, status, attempt_metadata, opts) do
    attrs = %{
      response_status_code: status,
      retry_count: context.retry_count || context.index,
      latency_ms: latency(context, opts),
      attempt_metadata: attempt_metadata
    }

    put_before_finalize(attrs, Keyword.get(opts, :before_finalize))
  end

  @spec failure(
          SelectedCandidateContext.t(),
          pos_integer(),
          String.t(),
          String.t(),
          map(),
          opts()
        ) ::
          attrs()
  def failure(
        %SelectedCandidateContext{} = context,
        status,
        code,
        message,
        attempt_metadata,
        opts
      ) do
    attrs = %{
      response_status_code: status,
      retry_count: context.retry_count || context.index,
      last_error_code: code,
      error_message: message,
      latency_ms: latency(context, opts),
      usage: Keyword.get(opts, :usage, %{status: "usage_unknown", source: code}),
      attempt_metadata: attempt_metadata
    }

    put_before_finalize(attrs, Keyword.get(opts, :before_finalize))
  end

  @spec partial_stream_failure(
          SelectedCandidateContext.t(),
          pos_integer(),
          String.t(),
          String.t(),
          map(),
          opts()
        ) :: attrs()
  def partial_stream_failure(
        %SelectedCandidateContext{} = context,
        status,
        code,
        message,
        attempt_metadata,
        opts \\ []
      ) do
    attrs = %{
      response_status_code: status,
      retry_count: context.retry_count || context.index,
      latency_ms: latency(context, opts),
      last_error_code: code,
      error_message: message,
      attempt_metadata: attempt_metadata
    }

    put_before_finalize(attrs, Keyword.get(opts, :before_finalize))
  end

  @spec chain_before_finalize((-> term()), (-> term())) :: (-> term())
  def chain_before_finalize(first, second)
      when is_function(first, 0) and is_function(second, 0) do
    fn ->
      with :ok <- normalize_before_finalize(first.()) do
        normalize_before_finalize(second.())
      end
    end
  end

  @spec chain_before_finalize(map(), (-> term())) :: map()
  def chain_before_finalize(attrs, callback) when is_map(attrs) and is_function(callback, 0) do
    Map.update(attrs, :before_finalize, callback, &chain_before_finalize(&1, callback))
  end

  @spec latency(SelectedCandidateContext.t(), opts()) :: non_neg_integer()
  def latency(%SelectedCandidateContext{} = context, opts) do
    cond do
      Keyword.has_key?(opts, :latency_ms) -> Keyword.fetch!(opts, :latency_ms)
      Keyword.has_key?(opts, :started) -> elapsed_ms(Keyword.fetch!(opts, :started))
      true -> elapsed_ms(context.started)
    end
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp put_before_finalize(attrs, callback) when is_function(callback, 0),
    do: Map.put(attrs, :before_finalize, callback)

  defp put_before_finalize(attrs, _callback), do: attrs

  defp normalize_before_finalize(:ok), do: :ok
  defp normalize_before_finalize({:ok, _value}), do: :ok
  defp normalize_before_finalize({:error, _reason} = error), do: error
end
