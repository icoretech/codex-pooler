defmodule CodexPooler.Gateway.Websocket.DirectCleanup do
  @moduledoc false

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry

  @enforce_keys [:registry, :task, :ref, :parent, :session_id]
  defstruct @enforce_keys ++ [:before_ready]

  @type t :: %__MODULE__{
          registry: GenServer.server(),
          task: pid(),
          ref: reference(),
          parent: pid(),
          session_id: Ecto.UUID.t(),
          before_ready: (-> term()) | nil
        }
  @type receipt :: %{
          session_id: Ecto.UUID.t(),
          request_id: Ecto.UUID.t(),
          correlation_id: String.t(),
          api_key_id: Ecto.UUID.t()
        }

  @spec begin(RequestOptions.t()) :: :ok | {:error, :cancelled}
  def begin(%RequestOptions{runtime: %{direct_cleanup: nil}}), do: :ok

  def begin(%RequestOptions{runtime: %{direct_cleanup: context}}),
    do: ActivityRegistry.begin_direct_cleanup(context)

  @spec bind(t() | nil, Request.t()) :: :ok
  def bind(nil, _request), do: :ok

  def bind(%__MODULE__{} = context, %Request{} = request) do
    ActivityRegistry.bind_direct_cleanup(context, %{
      session_id: context.session_id,
      request_id: request.id,
      correlation_id: request.correlation_id,
      api_key_id: request.api_key_id
    })
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
      {:ok, receipt} -> interrupt(receipt, reason)
      :none -> :none
    end
  end

  @spec interrupt(receipt(), String.t()) :: :ok | {:error, term()}
  defdelegate interrupt(receipt, reason), to: Interruption, as: :interrupt_direct_request
end
