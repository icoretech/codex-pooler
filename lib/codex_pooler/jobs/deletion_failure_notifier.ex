defmodule CodexPooler.Jobs.DeletionFailureNotifier do
  @moduledoc """
  Tells open admin pages that a Pool or API key deletion job gave up.

  The pages read a deletion's state from its Oban job, and Oban writes the job's final state
  (`discarded` or `cancelled`) only after `perform/1` has returned. A notice sent from inside the
  job therefore reached the page while the job still read as executing, and the page kept showing
  the Pool as deleting (findings#206 row 206-602). Oban emits its `[:oban, :job, :exception]` and
  `[:oban, :job, :stop]` telemetry events after that write, so the notice goes out from there.
  """

  require Logger

  alias CodexPooler.Access
  alias CodexPooler.Pools

  @handler_id {__MODULE__, :deletion_failure}
  @events [[:oban, :job, :exception], [:oban, :job, :stop]]
  @pool_worker "CodexPooler.Jobs.PoolDeletionWorker"
  @api_key_worker "CodexPooler.Jobs.APIKeyDeletionWorker"

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, :ok) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:oban, :job, :exception], _measurements, %{state: :discard, job: job}, _config), do: notify(job)
  def handle_event([:oban, :job, :stop], _measurements, %{state: state, job: job}, _config) when state in [:discard, :cancelled], do: notify(job)
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # A raising handler is detached by :telemetry for good, so a failed notice is logged instead.
  defp notify(%{worker: @pool_worker, args: %{"pool_id" => pool_id}}) when is_binary(pool_id),
    do: safely(fn -> Pools.broadcast_pool_deletion_failed(pool_id) end)

  defp notify(%{worker: @api_key_worker, args: %{"api_key_id" => api_key_id}}) when is_binary(api_key_id),
    do: safely(fn -> Access.broadcast_api_key_deletion_failed(api_key_id) end)

  defp notify(_job), do: :ok

  defp safely(fun) do
    _ = fun.()
    :ok
  rescue
    error ->
      Logger.warning("deletion failure notice not sent error=#{inspect(error.__struct__)}")
      :ok
  end
end
