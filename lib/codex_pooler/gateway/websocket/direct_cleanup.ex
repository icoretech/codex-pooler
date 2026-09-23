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
  @type deferred_success :: {:ok, %{required(:after_commit_markers) => [map()]}}
  @type interrupt_result :: :ok | deferred_success() | {:error, term()}
  @type cleanup_result :: interrupt_result() | :none

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
  def finish(%RequestOptions{runtime: %{direct_cleanup: %{owner_binding: binding} = context}} = options)
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

  @spec cancel(t(), String.t()) :: cleanup_result()
  def cancel(context, reason) do
    case ActivityRegistry.await_direct_cleanup(context) do
      {:ok, receipt} -> interrupt(receipt, Map.get(receipt, :cancel_reason, reason))
      :none -> :none
    end
  end

  @spec cancel_pending(t(), String.t()) :: cleanup_result()
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

  @doc """
  Stops a direct task only while it is blocked on its upstream request, then
  interrupts its request (`terminate_admission/2`). A task doing anything else,
  database work above all, is left running and answers `:busy`: killing a
  process inside a query or a commit drops its connection and can leave its
  own settlement half done (findings#206 row 206-110, measured under load).
  """
  @spec stop_upstream_wait(t(), String.t()) :: cleanup_result() | :busy
  def stop_upstream_wait(context, reason) do
    case ActivityRegistry.stop_direct_upstream_wait(context) do
      :stop -> terminate_admission(context, reason)
      :busy -> :busy
    end
  end

  @doc """
  Runs the direct task's upstream request inside the span `stop_upstream_wait/2`
  may stop it in. A stop granted while the request was running makes the task
  exit before it settles anything; the socket settles the request instead.
  """
  @spec upstream_wait(t() | nil, (-> result)) :: result when result: term()
  def upstream_wait(nil, request), do: request.()

  def upstream_wait(%__MODULE__{} = context, request) do
    with :ok <- ActivityRegistry.enter_direct_upstream_wait(context),
         result = request.(),
         :ok <- ActivityRegistry.leave_direct_upstream_wait(context) do
      result
    else
      {:error, :stopped} -> exit_stopped()
    end
  end

  # Exits with the reason the socket's own stop uses; the signal to self
  # terminates the task before it can reach any settlement.
  @spec exit_stopped() :: no_return()
  defp exit_stopped do
    Process.exit(self(), cancellation_exit_reason("client_disconnected"))
    Process.sleep(:infinity)
  end

  @spec terminate_admission(t(), String.t()) :: cleanup_result()
  def terminate_admission(context, reason) do
    :ok = ActivityRegistry.mark_direct_cleanup_reason(context, reason)
    Process.exit(context.task, cancellation_exit_reason(reason))
    cancel(context, reason)
  end

  defp cancellation_exit_reason("owner_drained"), do: {:shutdown, :owner_drained}
  defp cancellation_exit_reason(_reason), do: {:shutdown, :client_disconnected}

  @spec interrupt(receipt(), String.t()) :: interrupt_result()
  defdelegate interrupt(receipt, reason), to: Interruption, as: :interrupt_direct_request

  # Called by the response task itself after it rescued an exception. The
  # task settles its own pending admission first (idempotent) so the receipt
  # lookup cannot wait on a readiness call only this process could make, then
  # fails the request, attempt, and turn it bound.
  @spec fail_task_exception(t(), String.t()) :: cleanup_result()
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
