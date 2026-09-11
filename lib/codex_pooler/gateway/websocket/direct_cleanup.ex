defmodule CodexPooler.Gateway.Websocket.DirectCleanup do
  @moduledoc false

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder

  @task_receipt_key {__MODULE__, :task_receipt}
  @enforce_keys [:registry, :task, :ref, :parent, :session_id]
  defstruct @enforce_keys ++ [:before_ready, :owner_binding, :owner_pid]

  @type t :: %__MODULE__{
          registry: GenServer.server(),
          task: pid(),
          ref: reference(),
          parent: pid(),
          session_id: Ecto.UUID.t(),
          owner_binding: owner_binding() | nil,
          owner_pid: pid() | nil,
          before_ready: (-> term()) | nil
        }
  @type owner_binding :: %{
          owner_instance_id: String.t(),
          owner_lease_token: Ecto.UUID.t(),
          downstream_epoch: pos_integer()
        }
  @type receipt :: %{
          required(:session_id) => Ecto.UUID.t(),
          required(:request_id) => Ecto.UUID.t(),
          required(:correlation_id) => String.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          optional(:owner_binding) => owner_binding() | nil,
          optional(:attempt_id) => Ecto.UUID.t(),
          optional(:replay_generation) => non_neg_integer(),
          optional(:cancel_reason) => String.t()
        }

  @spec begin(RequestOptions.t()) ::
          :ok | {:error, :cancelled | :owner_unavailable | :stale_owner}
  def begin(%RequestOptions{runtime: %{direct_cleanup: nil}}), do: :ok

  def begin(%RequestOptions{runtime: %{direct_cleanup: context}} = options) do
    with :ok <- ActivityRegistry.begin_direct_cleanup(context) do
      case register_owner_admission(context, options) do
        :ok ->
          :ok

        {:error, _reason} = error ->
          ActivityRegistry.ready_direct_cleanup(context)
          error
      end
    end
  end

  defp register_owner_admission(%{owner_binding: binding} = context, options)
       when is_map(binding) do
    case WebsocketOwnerForwarder.register_pre_attempt_admission(
           options.continuity.codex_session,
           context,
           options.transport.websocket_owner.forwarder_opts
         ) do
      :ok -> :ok
      {:error, :stale_owner} -> {:error, :stale_owner}
      _ -> {:error, :owner_unavailable}
    end
  catch
    _, _ -> {:error, :owner_unavailable}
  end

  defp register_owner_admission(%{owner_binding: nil}, _options), do: :ok

  @spec finish(RequestOptions.t()) :: :ok
  def finish(
        %RequestOptions{runtime: %{direct_cleanup: %{owner_binding: binding} = context}} = options
      )
      when is_map(binding) do
    WebsocketOwnerForwarder.finish_pre_attempt_admission(
      options.continuity.codex_session,
      context,
      options.transport.websocket_owner.forwarder_opts
    )

    :ok
  end

  def finish(_request_options), do: :ok

  @spec bind(t() | nil, Request.t()) :: :ok
  def bind(nil, _request), do: :ok

  def bind(%__MODULE__{} = context, %Request{} = request) do
    receipt = receipt(context, request)
    remember_task_receipt(context, receipt)
    ActivityRegistry.bind_direct_cleanup(context, receipt)
  end

  @spec attempt_callback(t() | nil, Request.t()) :: (map() -> :ok) | nil
  def attempt_callback(nil, _request), do: nil

  def attempt_callback(context, request) do
    fn attempt ->
      receipt =
        Map.merge(receipt(context, request), %{
          attempt_id: attempt.id,
          replay_generation: attempt.replay_generation
        })

      remember_task_receipt(context, receipt)
      ActivityRegistry.bind_direct_cleanup(context, receipt)
    end
  end

  # The response task keeps its own copy of the receipt it bound. Once the
  # owner accepts the submission, the registry hands the receipt off to the
  # owner witness, and that witness cannot close a turn whose task died while
  # the owner stayed current.
  defp remember_task_receipt(%__MODULE__{task: task}, receipt) do
    if self() == task, do: Process.put(@task_receipt_key, receipt)
    :ok
  end

  defp task_receipt(%__MODULE__{task: task, session_id: session_id}) do
    case Process.get(@task_receipt_key) do
      %{session_id: ^session_id} = receipt when self() == task -> {:ok, receipt}
      _absent_or_foreign -> nil
    end
  end

  defp receipt(context, request) do
    %{
      session_id: context.session_id,
      request_id: request.id,
      correlation_id: request.correlation_id,
      api_key_id: request.api_key_id,
      owner_binding: context.owner_binding
    }
  end

  @spec ready(RequestOptions.t()) :: :ok | {:error, :cancelled}
  def ready(%RequestOptions{runtime: %{direct_cleanup: nil}}), do: :ok

  def ready(%RequestOptions{runtime: %{direct_cleanup: context}}) do
    if is_function(context.before_ready, 0), do: context.before_ready.()
    ActivityRegistry.ready_direct_cleanup(context)
  end

  @spec cancel(t(), String.t()) :: :ok | :none | {:error, term()}
  def cancel(context, reason) do
    case ActivityRegistry.await_direct_cleanup(context) do
      {:ok, receipt} -> interrupt(receipt, Map.get(receipt, :cancel_reason, reason))
      :none -> :none
    end
  end

  @spec cancel_pending(t(), String.t()) :: :ok | :none | {:error, term()}
  def cancel_pending(context, reason) do
    :ok = ActivityRegistry.mark_direct_cleanup_reason(context, reason)

    case ActivityRegistry.cancel_pending_direct_cleanup(context) do
      :pending ->
        Process.exit(context.task, cancellation_exit_reason(reason))
        cancel(context, reason)

      :not_pending ->
        :none
    end
  end

  @spec terminate_admission(t(), String.t()) :: :ok | :none | {:error, term()}
  def terminate_admission(context, reason) do
    :ok = ActivityRegistry.mark_direct_cleanup_reason(context, reason)
    Process.exit(context.task, cancellation_exit_reason(reason))
    cancel(context, reason)
  end

  defp cancellation_exit_reason("owner_drained"), do: {:shutdown, :owner_drained}
  defp cancellation_exit_reason(_reason), do: {:shutdown, :client_disconnected}

  @spec interrupt(receipt(), String.t()) :: :ok | {:error, term()}
  defdelegate interrupt(receipt, reason), to: Interruption, as: :interrupt_direct_request

  # Called by the response task itself after it rescued an exception. The
  # task settles its own pending admission first (idempotent) so the receipt
  # lookup cannot wait on a readiness call only this process could make, then
  # fails the request, attempt, and turn it bound.
  @spec fail_task_exception(t(), String.t()) :: :ok | :none | {:error, term()}
  def fail_task_exception(%__MODULE__{} = context, reason) do
    case task_receipt(context) || registry_receipt(context) do
      {:ok, receipt} -> Interruption.finalize_task_exception_request(receipt, reason)
      :none -> :none
    end
  end

  defp registry_receipt(context) do
    _readiness = ActivityRegistry.ready_direct_cleanup(context)
    ActivityRegistry.await_direct_cleanup(context)
  end
end
