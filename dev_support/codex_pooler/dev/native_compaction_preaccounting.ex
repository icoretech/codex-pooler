defmodule CodexPooler.Dev.NativeCompactionPreaccounting do
  @moduledoc false
  use GenServer
  import Ecto.Query
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @event [:codex_pooler, :gateway, :native_compaction, :authorization_transition]
  @budget 15_000

  @spec arm(Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def arm(pool_id) do
    with nil <- Process.whereis(__MODULE__),
         %Pool{slug: "codex-compact-" <> _} <- Repo.get(Pool, pool_id),
         [session_id] <- session_ids(pool_id),
         {:ok, owner} <- WebsocketOwnerSession.lookup(session_id),
         {:ok, %{active_turn?: false, draining?: false}} <-
           WebsocketOwnerSession.owner_status(owner),
         {:ok, _pid} <-
           GenServer.start(__MODULE__, {pool_id, session_id, owner}, name: __MODULE__) do
      status(pool_id)
    else
      _ -> {:error, :idle_fixture_owner_required}
    end
  end

  @spec status(Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def status(pool_id), do: command(pool_id, :status)
  @spec release(Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def release(pool_id), do: command(pool_id, :release)
  @spec disarm(Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def disarm(pool_id), do: command(pool_id, :disarm)

  defp command(pool_id, action) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok,
         %{
           armed: false,
           captured: false,
           released: false,
           timed_out: false,
           compact_request_count: nil
         }}

      pid ->
        monitor = Process.monitor(pid)
        result = GenServer.call(pid, {pool_id, action}, @budget + 1000)

        if action == :disarm and match?({:ok, _}, result) do
          receive do
            {:DOWN, ^monitor, :process, ^pid, _} -> result
          after
            1000 -> {:error, :cleanup_timeout}
          end
        else
          Process.demonitor(monitor, [:flush])
          result
        end
    end
  end

  @impl true
  def init({pool_id, session_id, owner}) do
    ref = make_ref()
    handler = {__MODULE__, ref}
    control = self()

    :ok =
      :telemetry.attach(handler, @event, &__MODULE__.observe/4, %{
        owner: owner,
        control: control,
        ref: ref
      })

    spawn(fn ->
      monitor = Process.monitor(control)

      receive do
        {:DOWN, ^monitor, :process, ^control, _} -> :telemetry.detach(handler)
      end
    end)

    timer = Process.send_after(self(), :watchdog, @budget)

    {:ok,
     %{
       pool_id: pool_id,
       session_id: session_id,
       owner: owner,
       owner_monitor: Process.monitor(owner),
       ref: ref,
       handler: handler,
       timer: timer,
       captured: false,
       captured_at: nil,
       hold_elapsed_ms: nil,
       released: false,
       timed_out: false,
       compact_request_count: nil,
       waiter: nil
     }}
  end

  @doc false
  def observe(
        _event,
        _measurements,
        %{transition: :compact_owner_issued, topology: :forwarded},
        %{owner: owner, control: control, ref: ref}
      )
      when owner == self() do
    monitor = Process.monitor(control)

    case capture(control, ref) do
      :hold ->
        receive do
          {:preaccounting_release, ^ref} -> send(control, {:released, ref})
          {:DOWN, ^monitor, :process, ^control, _} -> :ok
        after
          @budget -> send(control, {:expired, ref})
        end

      :ignore ->
        :ok
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  def observe(_, _, _, _), do: :ok

  defp capture(control, ref) do
    GenServer.call(control, {:capture, self(), ref})
  catch
    :exit, {:noproc, _} -> :ignore
    :exit, {:normal, _} -> :ignore
    :exit, {:killed, _} -> :ignore
  end

  @impl true
  def handle_call(
        {:capture, owner, ref},
        _from,
        %{owner: owner, ref: ref, captured: false} = state
      ),
      do: {:reply, :hold, %{state | captured: true, captured_at: System.monotonic_time(:millisecond)}}

  def handle_call({:capture, _, _}, _from, state), do: {:reply, :ignore, state}

  def handle_call({pool_id, _}, _from, %{pool_id: owned} = state) when pool_id != owned,
    do: {:reply, {:error, :forbidden}, state}

  def handle_call({_pool, :status}, _from, state), do: {:reply, {:ok, projection(state)}, state}

  def handle_call({_pool, action}, _from, %{waiter: waiter} = state)
      when action in [:release, :disarm] and not is_nil(waiter),
      do: {:reply, {:error, :control_busy}, state}

  def handle_call({_pool, :release}, from, %{captured: true, released: false} = state) do
    count = compact_count(state.pool_id)
    elapsed = System.monotonic_time(:millisecond) - state.captured_at
    send(state.owner, {:preaccounting_release, state.ref})

    {:noreply, %{state | compact_request_count: count, hold_elapsed_ms: elapsed, waiter: {from, :release}}}
  end

  def handle_call({_pool, :release}, _from, state), do: {:reply, {:ok, projection(state)}, state}

  def handle_call({_pool, :disarm}, from, %{captured: true, released: false} = state) do
    send(state.owner, {:preaccounting_release, state.ref})
    {:noreply, %{state | waiter: {from, :disarm}}}
  end

  def handle_call({_pool, :disarm}, _from, state),
    do: {:stop, :normal, {:ok, Map.put(projection(state), :armed, false)}, state}

  @impl true
  def handle_info({:released, ref}, %{ref: ref} = state) do
    state = %{state | released: true}

    case state.waiter do
      {from, :disarm} ->
        GenServer.reply(from, {:ok, Map.put(projection(state), :armed, false)})
        {:stop, :normal, state}

      {from, :release} ->
        GenServer.reply(from, {:ok, projection(state)})
        {:noreply, %{state | waiter: nil}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:watchdog, state) do
    send(state.owner, {:preaccounting_release, state.ref})
    {:noreply, %{state | timed_out: true}}
  end

  def handle_info({:expired, ref}, %{ref: ref} = state),
    do: handle_info({:released, ref}, %{state | timed_out: true})

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner_monitor: monitor, owner: owner} = state
      ),
      do: handle_info({:released, state.ref}, %{state | timed_out: true})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    send(state.owner, {:preaccounting_release, state.ref})
    :telemetry.detach(state.handler)
    Process.cancel_timer(state.timer)
    :ok
  end

  defp projection(state),
    do:
      Map.take(state, [:captured, :released, :timed_out, :compact_request_count, :hold_elapsed_ms])
      |> Map.put(:armed, true)

  defp session_ids(pool_id) do
    Repo.all(
      from(t in CodexTurn,
        join: r in Request,
        on: r.id == t.request_id,
        where:
          r.pool_id == ^pool_id and r.status == "succeeded" and
            r.endpoint == "/backend-api/codex/responses",
        distinct: true,
        select: t.codex_session_id
      )
    )
  end

  defp compact_count(pool_id) do
    Repo.aggregate(
      from(r in Request,
        where: r.pool_id == ^pool_id and r.endpoint == "/backend-api/codex/responses/compact"
      ),
      :count
    )
  end
end
