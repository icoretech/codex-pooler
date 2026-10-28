defmodule CodexPooler.Gateway.Websocket.DeliveryReceiptHandoff do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Finalization.SettlementRetry
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket.DeliveryReceipt
  alias CodexPooler.Repo

  @supervisor CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor
  @type envelope :: %{registry: GenServer.server(), token: reference(), context: DeliveryReceipt.context(), receipt: DeliveryReceipt.receipt()}

  @doc false
  @spec persistence_timeout_ms(DeliveryReceipt.context()) :: pos_integer()
  def persistence_timeout_ms(%{request_id: request, replay_generation: generation}) when is_binary(request) and is_integer(generation) and generation >= 0,
    do: SettlementRetry.budget_ms()

  def persistence_timeout_ms(context), do: DeliveryReceipt.persistence_timeout_ms(context)

  @spec enroll(pid(), map(), keyword()) :: {:ok, reference()} | {:error, atom()}
  def enroll(socket, identity, opts \\ []) do
    registry = Keyword.get(opts, :name, ActivityRegistry)
    identity = Map.take(identity, [:request_id, :attempt_id, :replay_generation])

    case ActivityRegistry.enroll_delivery_receipt(socket, identity, name: registry) do
      {:ok, _token} = result ->
        result

      error ->
        error
    end
  end

  @spec abandon(reference(), keyword()) :: :ok
  def abandon(token, opts \\ []), do: ActivityRegistry.abandon_delivery_receipt(token, opts)

  @spec publish(reference(), DeliveryReceipt.context(), DeliveryReceipt.receipt(), term(), keyword()) :: :ok | {:error, atom()}
  def publish(token, context, receipt, recipient, opts \\ []) do
    ActivityRegistry.publish_delivery_receipt(token, context, receipt, recipient, opts)
  end

  @spec settle_cleanup(reference(), DeliveryReceipt.context(), DeliveryReceipt.receipt(), keyword()) :: :ok | {:error, term()}
  def settle_cleanup(token, context, receipt, opts \\ []) do
    case ActivityRegistry.take_delivery_cleanup(token, context, receipt, opts) do
      {:ok, envelope} -> settle(envelope)
      {:settled, result} -> result
      {:error, _reason} = error -> error
    end
  end

  @spec settle_pending(keyword()) :: :ok | {:error, term()}
  def settle_pending(opts \\ []) do
    Enum.reduce(ActivityRegistry.assigned_delivery_receipts(opts), :ok, fn envelope, result ->
      case settle(envelope) do
        :ok -> result
        error -> error
      end
    end)
  end

  @spec settle(envelope()) :: :ok | {:error, term()}
  def settle(%{registry: registry, token: token} = envelope) do
    case ActivityRegistry.claim_delivery_receipt(token, name: registry, envelope: envelope) do
      {:ok, remaining_ms} ->
        result = persist_with_remaining_budget(envelope, remaining_ms)
        :ok = ActivityRegistry.finish_delivery_receipt(token, result, name: registry)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_with_remaining_budget(envelope, remaining_ms) do
    if Repo.in_transaction?() do
      {:error, :receipt_uncommitted_transaction}
    else
      DeliveryReceipt.record_result(envelope.context, envelope.receipt, retry_timeout_ms: remaining_ms)
    end
  rescue
    _exception -> {:error, :receipt_not_persisted}
  catch
    :exit, _reason -> {:error, :receipt_not_persisted}
  end

  # The caller registers the waiting process before publishing the envelope.
  # Only bounded delivery metadata reaches it, never a request or socket state.
  @spec start_fallback() :: {:ok, pid()} | {:error, term()}
  def start_fallback do
    registry = self()

    Task.Supervisor.start_child(@supervisor, fn ->
      monitor = Process.monitor(registry)

      receive do
        {:settle_delivery_receipt, %{registry: ^registry} = envelope} ->
          Process.demonitor(monitor, [:flush])
          settle(envelope)

        {:DOWN, ^monitor, :process, ^registry, _reason} ->
          :ok
      end
    end)
  end
end
