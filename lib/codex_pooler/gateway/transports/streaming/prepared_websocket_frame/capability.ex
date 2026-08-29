defmodule CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability do
  @moduledoc false

  use GenServer

  @timeout_ms 30_000

  @enforce_keys [:server, :reference]
  defstruct [:server, :reference]

  @opaque t :: %__MODULE__{server: pid(), reference: reference()}

  @spec issue() :: t()
  def issue do
    reference = make_ref()
    {:ok, server} = GenServer.start(__MODULE__, {self(), reference})
    %__MODULE__{server: server, reference: reference}
  end

  @spec seal(t(), binary()) :: :ok
  def seal(%__MODULE__{server: server, reference: reference}, frame_token)
      when is_pid(server) and is_reference(reference) and is_binary(frame_token) do
    GenServer.call(server, {:seal, reference, frame_token}, 1_000)
  end

  @spec consume(t(), binary()) :: :ok | {:error, :consumed | :invalid}
  def consume(%__MODULE__{server: server, reference: reference}, frame_token)
      when is_pid(server) and is_reference(reference) and is_binary(frame_token) do
    GenServer.call(server, {:consume, reference, frame_token}, 1_000)
  catch
    :exit, _reason -> {:error, :invalid}
  end

  @spec digest_identity(t()) :: {pid(), reference()}
  def digest_identity(%__MODULE__{server: server, reference: reference}),
    do: {server, reference}

  @impl true
  def init({owner, reference}) do
    owner_monitor = Process.monitor(owner)

    {:ok,
     %{
       owner_monitor: owner_monitor,
       reference: reference,
       frame_token: nil,
       consumed?: false
     }, @timeout_ms}
  end

  @impl true
  def handle_call(
        {:seal, reference, frame_token},
        _from,
        %{reference: reference, frame_token: nil, consumed?: false} = state
      ) do
    {:reply, :ok, %{state | frame_token: frame_token}, @timeout_ms}
  end

  def handle_call(
        {:consume, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: false} = state
      ) do
    {:reply, :ok, %{state | consumed?: true}}
  end

  def handle_call(
        {:consume, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: true} = state
      ) do
    {:reply, {:error, :consumed}, state}
  end

  def handle_call({:consume, _reference, _frame_token}, _from, state) do
    {:reply, {:error, :invalid}, state, @timeout_ms}
  end

  @impl true
  def handle_info({:DOWN, owner_monitor, :process, _owner, _reason}, %{
        owner_monitor: owner_monitor
      }) do
    {:stop, :normal, %{}}
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}
end
