defmodule CodexPooler.Dev.NativePreAttemptDrain do
  @moduledoc false
  use GenServer

  import Ecto.Query
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Dev.NativeCompletionDrain
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @handler {__MODULE__, :reservation}
  @budget 20_000

  @spec arm(Ecto.UUID.t()) :: :ok | {:error, atom()}
  def arm(pool_id) do
    with {:ok, _} <- Ecto.UUID.cast(pool_id),
         {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:arm, pool_id})
    else
      _ -> {:error, :invalid_pool}
    end
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{armed: false, captured: false, drained: false, task_alive: false}
      _ -> GenServer.call(__MODULE__, :status)
    end
  end

  @spec capture_visible(Ecto.UUID.t()) :: :ok | {:error, atom()}
  def capture_visible(pool_id) do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:capture_visible, pool_id})
    end
  end

  @spec capture_idle(Ecto.UUID.t()) :: :ok | {:error, atom()}
  def capture_idle(pool_id) do
    with {:ok, _pid} <- ensure_started(), do: GenServer.call(__MODULE__, {:capture_idle, pool_id})
  end

  @spec drain() :: :ok | {:error, atom()}
  def drain do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :capture_required}
      _ -> GenServer.call(__MODULE__, :drain, @budget + 5_000)
    end
  end

  @spec hold_caller() :: :ok | {:error, atom()}
  def hold_caller do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :capture_required}
      pid -> GenServer.call(pid, :hold_caller)
    end
  end

  @spec authorized_pool?(Ecto.UUID.t()) :: boolean()
  def authorized_pool?(pool_id) do
    case Process.whereis(__MODULE__) do
      nil -> true
      _ -> GenServer.call(__MODULE__, {:authorized_pool, pool_id})
    end
  end

  @spec disarm() :: :ok
  def disarm do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        monitor = Process.monitor(pid)
        :ok = GenServer.call(pid, :disarm)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          @budget -> exit(:drain_control_shutdown_timeout)
        end
    end
  end

  @spec observe(list(), map(), map(), map()) :: :ok
  def observe(_event, _measurements, metadata, config) do
    query = metadata.query

    if String.contains?(query, "INSERT INTO") and String.contains?(query, "codex_turns") do
      remember_insert(query, metadata.params)
    end

    if String.downcase(query) == "commit",
      do: pause_committed_task(config.pid, Process.delete(@handler))

    :ok
  end

  defp remember_insert(query, params) do
    case Regex.run(~r/"?codex_turns"?\s*\(([^)]+)\)/, query) do
      [_, columns] ->
        index =
          columns
          |> String.split(",")
          |> Enum.find_index(&(String.trim(&1) |> String.trim("\"") == "request_id"))

        if index, do: Process.put(@handler, Enum.at(params, index))

      _ ->
        :ok
    end
  end

  defp pause_committed_task(_pid, nil), do: :ok

  defp pause_committed_task(pid, binary) do
    with {:ok, request_id} <- Ecto.UUID.load(binary),
         true <- GenServer.call(pid, {:capture, self(), request_id}) do
      receive do
        {__MODULE__, :release} -> :ok
      after
        @budget -> :ok
      end
    end
  end

  @impl true
  def init(_) do
    :telemetry.detach(@handler)
    {:ok, empty()}
  end

  @impl true
  def handle_call({:arm, pool_id}, _from, %{armed: false} = state) do
    :ok =
      :telemetry.attach(@handler, [:codex_pooler, :repo, :query], &__MODULE__.observe/4, %{
        pid: self()
      })

    {:reply, :ok, %{state | armed: true, pool_id: pool_id}}
  end

  def handle_call({:arm, _}, _from, state), do: {:reply, {:error, :already_armed}, state}

  def handle_call({:capture_idle, pool_id}, _from, %{armed: false} = state) do
    sessions =
      Repo.all(
        from(t in CodexTurn,
          join: r in Request,
          on: r.id == t.request_id,
          where: r.pool_id == ^pool_id and r.status == "succeeded",
          select: t.codex_session_id,
          distinct: true,
          limit: 2
        )
      )

    with [session_id] <- sessions,
         {:ok, owner} <- WebsocketOwnerSession.lookup(session_id),
         {:ok, %{active_turn?: false, draining?: false}} <-
           WebsocketOwnerSession.owner_status(owner) do
      {:reply, :ok, %{state | armed: true, captured: true, pool_id: pool_id, session_id: session_id}}
    else
      _ -> {:reply, {:error, :idle_owner_required}, state}
    end
  end

  def handle_call({:capture_idle, _}, _from, state), do: {:reply, {:error, :already_armed}, state}

  def handle_call({:capture_visible, pool_id}, _from, %{armed: false} = state) do
    sessions =
      Repo.all(
        from(t in CodexTurn,
          join: r in Request,
          on: r.id == t.request_id,
          join: a in Attempt,
          on: a.request_id == r.id,
          where:
            r.pool_id == ^pool_id and r.status == "in_progress" and
              not is_nil(t.first_visible_output_at),
          select: t.codex_session_id,
          distinct: true,
          limit: 2
        )
      )

    case sessions do
      [session_id] ->
        {:reply, :ok, %{state | armed: true, captured: true, pool_id: pool_id, session_id: session_id}}

      _ ->
        {:reply, {:error, :visible_attempt_required}, state}
    end
  end

  def handle_call({:capture_visible, _}, _from, state),
    do: {:reply, {:error, :already_armed}, state}

  def handle_call({:authorized_pool, pool_id}, _from, state),
    do: {:reply, state.pool_id in [nil, pool_id], state}

  def handle_call({:capture, task, request_id}, _from, %{armed: true, task: nil} = state) do
    request = Repo.get(Request, request_id)
    turn = Repo.get_by(CodexTurn, request_id: request_id)

    if request && turn && request.pool_id == state.pool_id && request.status == "in_progress" &&
         Repo.aggregate(from(a in Attempt, where: a.request_id == ^request_id), :count) == 0 do
      {:reply, true, %{state | task: task, session_id: turn.codex_session_id, captured: true}}
    else
      {:reply, false, state}
    end
  end

  def handle_call({:capture, _, _}, _from, state), do: {:reply, false, state}

  def handle_call(:drain, _from, %{captured: true, drained: false} = state) do
    with {:ok, owner} <- WebsocketOwnerSession.lookup(state.session_id),
         :ok <- WebsocketOwnerSession.drain_owner(owner) do
      {:reply, :ok, %{state | drained: true}}
    else
      _ -> {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call(:drain, _from, state), do: {:reply, {:error, :capture_required}, state}

  def handle_call(:hold_caller, _from, %{captured: true} = state) do
    {:reply, NativeCompletionDrain.hold(state.pool_id, state.session_id), state}
  end

  def handle_call(:hold_caller, _from, state),
    do: {:reply, {:error, :capture_required}, state}

  def handle_call(:disarm, _from, state) do
    NativeCompletionDrain.cleanup()
    :telemetry.detach(@handler)
    if is_pid(state.task), do: send(state.task, {__MODULE__, :release})
    {:stop, :normal, :ok, state}
  end

  def handle_call(:status, _from, state) do
    result = Map.take(state, [:armed, :captured, :drained])

    {:reply,
     result
     |> Map.put(:task_alive, is_pid(state.task) && Process.alive?(state.task))
     |> Map.merge(NativeCompletionDrain.status()), state}
  end

  defp empty,
    do: %{armed: false, captured: false, drained: false, task: nil, pool_id: nil, session_id: nil}

  defp ensure_started do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  @impl true
  def terminate(_reason, state) do
    NativeCompletionDrain.cleanup()
    :telemetry.detach(@handler)
    if is_pid(state.task), do: send(state.task, {__MODULE__, :release})
    :ok
  end
end
