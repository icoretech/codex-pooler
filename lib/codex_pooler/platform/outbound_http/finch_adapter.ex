defmodule CodexPooler.Platform.OutboundHTTP.FinchAdapter do
  @moduledoc false

  @queue_exception [:finch, :queue, :exception]
  @owner_key :codex_pooler_finch_stream_owner

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(__MODULE__, @queue_exception, &__MODULE__.handle_queue_exception/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{into: :self} = request) do
    private = Map.new(Req.Request.get_option(request, :finch_private) || [])

    request
    |> Req.Request.put_option(:finch_private, Map.put(private, @owner_key, self()))
    |> Req.Finch.run()
  end

  def run(%Req.Request{} = request) do
    Req.Finch.run(request)
  rescue
    error in RuntimeError ->
      # Finch reraises the NimblePool checkout expiry with its original stack.
      # Errors in a response collector or any other callback must still propagate.
      case __STACKTRACE__ do
        [{NimblePool, :exit!, 3, _}, {Finch.HTTP1.Pool, :request, 6, _} | _] ->
          {request, checkout_timeout()}

        stack ->
          reraise error, stack
      end
  end

  @doc false
  @spec handle_queue_exception([atom()], map(), map(), term()) :: :ok
  def handle_queue_exception(
        @queue_exception,
        _measurements,
        %{kind: :exit, pool: pool, reason: {:timeout, {NimblePool, :checkout, [pool]}}, request: %Finch.Request{private: %{@owner_key => owner}}},
        _config
      )
      when is_pid(pool) and is_pid(owner) and owner != self() do
    # Finch 0.25 runs HTTP/1 async requests in a dedicated helper linked to and
    # monitoring its caller. Req waits for {ref, {:error, exception}} before
    # headers. At this event NimblePool has already cancelled the queued checkout.
    # Complete the helper with its normal reply protocol before Finch reraises
    # into the link. The normal exit ends this worker's telemetry dispatch too.
    {:links, links} = Process.info(self(), :links)
    {:monitors, monitors} = Process.info(self(), :monitors)

    if owner in links and {:process, owner} in monitors do
      Process.unlink(owner)
      send(owner, {{Finch.HTTP1.Pool, self()}, {:error, checkout_timeout()}})
      Process.exit(self(), :normal)
    end

    :ok
  end

  def handle_queue_exception(_event, _measurements, _metadata, _config), do: :ok

  defp checkout_timeout, do: %Req.TransportError{reason: :pool_checkout_timeout}
end
