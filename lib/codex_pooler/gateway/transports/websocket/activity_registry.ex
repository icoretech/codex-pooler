defmodule CodexPooler.Gateway.Transports.Websocket.ActivityRegistry do
  @moduledoc false

  use GenServer

  require Logger

  alias __MODULE__.{Drain, Entry}
  alias CodexPooler.Gateway.Websocket.DeliveryReceiptHandoff
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Platform.ExecutionRegistry

  @spec begin_direct_cleanup(DirectCleanup.t()) :: :ok | {:error, :cancelled}
  def begin_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_begin, context})

  @spec bind_direct_cleanup(DirectCleanup.t(), DirectCleanup.receipt()) :: :ok
  def bind_direct_cleanup(context, receipt),
    do: GenServer.call(context.registry, {:direct_bind, context, receipt})

  @spec ready_direct_cleanup(DirectCleanup.t()) :: :ok | {:error, :cancelled}
  def ready_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_ready, context})

  @spec await_direct_cleanup(DirectCleanup.t()) :: {:ok, DirectCleanup.receipt()} | :none
  def await_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_await, context}, 30_000)

  @spec cancel_pending_direct_cleanup(DirectCleanup.t()) :: :pending | :not_pending
  def cancel_pending_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_cancel_pending, context})

  @spec mark_direct_cleanup_reason(DirectCleanup.t(), String.t()) :: :ok
  def mark_direct_cleanup_reason(context, reason),
    do: GenServer.call(context.registry, {:direct_cancel_reason, context, reason})

  @spec handoff_direct_cleanup(DirectCleanup.t()) :: :ok
  def handoff_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_handoff, context})

  @doc """
  The direct task marks the span it spends blocked on its upstream request,
  the one point where stopping it touches no database work in flight
  (`stop_direct_upstream_wait/1`). Leaving the span after a stop was granted
  answers `{:error, :stopped}`: the task must then exit without settling.
  """
  @spec enter_direct_upstream_wait(DirectCleanup.t()) :: :ok | {:error, :stopped | :stale_direct_cleanup}
  def enter_direct_upstream_wait(context),
    do: GenServer.call(context.registry, {:direct_upstream_wait, context, true})

  # A stopped admitted executor waits on the receipt's registry-owned finite deadline,
  # not a fresh GenServer call timeout. Every success, failure, expiry and force cut replies.
  @spec leave_direct_upstream_wait(DirectCleanup.t()) :: :ok | {:error, :stopped | :stale_direct_cleanup | {:stopped, atom()}}
  def leave_direct_upstream_wait(context),
    do: GenServer.call(context.registry, {:direct_upstream_wait, context, false}, :infinity)

  @spec stop_direct_upstream_wait(DirectCleanup.t()) :: :stop | :busy | {:error, :delivery_identity_unavailable}
  def stop_direct_upstream_wait(context),
    do: GenServer.call(context.registry, {:direct_stop_upstream_wait, context})

  @spec stop_direct_upstream_wait(DirectCleanup.t(), {map(), map()} | nil) :: {:stop, DeliveryReceiptHandoff.envelope()} | :busy | {:error, atom()}
  def stop_direct_upstream_wait(context, packet), do: GenServer.call(context.registry, {:direct_stop_upstream_wait, context, packet})

  @type activity_kind :: Entry.kind()
  @type outcome :: :completed | :aborted | :failed
  @type token :: reference()
  @type drain_entry :: Drain.entry()

  @type receipt_identity :: %{request_id: String.t(), attempt_id: String.t(), replay_generation: non_neg_integer()}
  @type receipt_disposition :: :inserted | :reused | :replaced | :superseded | :failed | :aborted

  # Called only by the accepting owner, before it exposes the accepted turn.
  # The capability carries original admission identity; it never admits provider work.
  @spec begin_receipt_producer(receipt_identity(), keyword()) :: {:ok, token()} | {:error, :owner_drained | :invalid_identity}
  def begin_receipt_producer(identity, opts \\ []),
    do: GenServer.call(server(opts), {:begin_receipt_producer, identity})

  @spec register_receipt_settlement(token(), receipt_identity(), pid(), keyword()) :: {:ok, token()} | {:error, :producer_closed | :identity_mismatch | :already_registered}
  def register_receipt_settlement(producer, identity, worker, opts \\ []) when is_reference(producer) and is_pid(worker),
    do: GenServer.call(server(opts), {:register_receipt_settlement, producer, identity, worker})

  @spec finish_receipt_producer(token(), keyword()) :: :ok | {:error, :producer_closed}
  def finish_receipt_producer(producer, opts \\ []),
    do: GenServer.call(server(opts), {:finish_receipt_producer, producer})

  @spec complete_receipt_settlement(token(), receipt_disposition(), keyword()) :: :ok | {:error, :unknown_activity}
  def complete_receipt_settlement(token, disposition, opts \\ []) when disposition in [:inserted, :reused, :replaced, :superseded, :failed, :aborted],
    do: GenServer.call(server(opts), {:complete_receipt_settlement, token, disposition})

  @spec receipt_cohort(keyword()) :: %{closed?: boolean(), entries: [Drain.entry()], pending_producers: non_neg_integer(), producers_failed?: boolean()}
  def receipt_cohort(opts \\ []), do: GenServer.call(server(opts), :receipt_cohort)

  @spec force_receipt_cohort(keyword()) :: :ok
  def force_receipt_cohort(opts \\ []), do: GenServer.call(server(opts), :force_receipt_cohort)

  @spec enroll_delivery_receipt(pid(), receipt_identity(), keyword()) :: {:ok, token()} | {:error, atom()}
  def enroll_delivery_receipt(socket, identity, opts \\ []), do: GenServer.call(server(opts), {:enroll_delivery_receipt, socket, identity})

  @spec abandon_delivery_receipt(token(), keyword()) :: :ok
  def abandon_delivery_receipt(token, opts \\ []), do: GenServer.call(server(opts), {:abandon_delivery_receipt, token})

  @spec delivery_settling?(pid(), keyword()) :: boolean()
  def delivery_settling?(pid, opts \\ []), do: GenServer.call(server(opts), {:delivery_settling, pid})

  @spec protect_response_settlement(token(), non_neg_integer(), keyword()) :: :ok
  def protect_response_settlement(token, budget_ms, opts \\ []),
    do: GenServer.call(server(opts), {:protect_response_settlement, token, budget_ms})

  @spec cancel_unless_settling(pid(), atom(), keyword()) :: :cancelled | {:settling, integer()}
  def cancel_unless_settling(task, reason, opts \\ []),
    do: GenServer.call(server(opts), {:cancel_unless_settling, task, reason})

  @spec acknowledge_retired_delivery(pid(), token(), keyword()) :: :ok | {:error, atom()}
  def acknowledge_retired_delivery(task, activity, opts \\ []), do: GenServer.call(server(opts), {:acknowledge_retired_delivery, task, activity})

  @spec delivery_receipt_token(receipt_identity(), keyword()) :: {:ok, token()} | :unknown
  def delivery_receipt_token(identity, opts \\ []), do: GenServer.call(server(opts), {:delivery_receipt_token, identity})

  @doc false
  @spec accepted_delivery_receipt(token(), map(), keyword()) :: {:accepted, :pending | :finished} | :unpublished | {:error, atom()}
  def accepted_delivery_receipt(token, context, opts \\ []), do: GenServer.call(server(opts), {:accepted_delivery_receipt, token, context})

  @spec publish_delivery_receipt(token(), map(), map(), term(), keyword()) :: :ok | {:error, atom()}
  def publish_delivery_receipt(token, context, receipt, recipient, opts \\ []), do: GenServer.call(server(opts), {:publish_delivery_receipt, token, context, receipt, recipient})

  @spec take_delivery_cleanup(token(), map(), map(), keyword()) :: {:ok, DeliveryReceiptHandoff.envelope()} | {:settled, term()} | {:error, atom()}
  def take_delivery_cleanup(token, context, receipt, opts \\ []) do
    timeout = DeliveryReceiptHandoff.persistence_timeout_ms(context) + 5_000
    GenServer.call(server(opts), {:take_delivery_cleanup, token, context, receipt}, timeout)
  end

  @spec assigned_delivery_receipts(keyword()) :: [DeliveryReceiptHandoff.envelope()]
  def assigned_delivery_receipts(opts \\ []), do: GenServer.call(server(opts), :assigned_delivery_receipts)

  @spec claim_delivery_receipt(token(), keyword()) :: :ok | {:ok, pos_integer()} | {:error, atom()}
  def claim_delivery_receipt(token, opts \\ []), do: GenServer.call(server(opts), {:claim_delivery_receipt, token, Keyword.get(opts, :envelope)})

  @spec finish_delivery_receipt(token(), term(), keyword()) :: :ok
  def finish_delivery_receipt(token, result, opts \\ []), do: GenServer.call(server(opts), {:finish_delivery_receipt, token, result})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec register(activity_kind(), pid(), keyword()) :: {:ok, token()}
  def register(kind, pid \\ self(), opts \\ [])
      when kind in [:direct, :proxy, :local_owner] and is_pid(pid) do
    GenServer.call(
      server(opts),
      {:register, kind, pid, Keyword.take(opts, [:direct_cleanup_ref, :direct_cleanup_parent])}
    )
  end

  @spec admit(token(), keyword()) :: :ok | {:error, :owner_drained | :unknown_activity}
  def admit(token, opts \\ []) when is_reference(token) do
    GenServer.call(server(opts), {:admit, token})
  end

  @spec unregister(token(), outcome(), keyword()) :: :ok
  def unregister(token, outcome, opts \\ [])
      when is_reference(token) and outcome in [:completed, :aborted, :failed] do
    GenServer.call(server(opts), {:unregister, token, outcome})
  end

  @spec complete(token(), outcome(), keyword()) :: :ok
  def complete(token, outcome, opts \\ [])
      when is_reference(token) and outcome in [:completed, :aborted, :failed] do
    GenServer.call(server(opts), {:complete, token, outcome})
  end

  @spec set_cancel_recipient(token(), pid(), keyword()) :: :ok | {:error, :unknown_activity}
  def set_cancel_recipient(token, pid, opts \\ []) when is_reference(token) and is_pid(pid) do
    GenServer.call(server(opts), {:set_cancel_recipient, token, pid})
  end

  @spec handoff_cancel_recipient(token(), pid(), pid(), keyword()) ::
          :ok | {:cancelled, :owner_drained, pid()} | {:error, :unknown_activity}
  def handoff_cancel_recipient(token, from_pid, to_pid, opts \\ [])
      when is_reference(token) and is_pid(from_pid) and is_pid(to_pid) do
    GenServer.call(server(opts), {:handoff_cancel_recipient, token, from_pid, to_pid})
  end

  @spec delivery_target(pid(), keyword()) ::
          {:ok, token(), pid(), :registered | :admitted | :cancelling} | :unknown
  def delivery_target(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(server(opts), {:delivery_target, pid})
  end

  @spec begin_drain(keyword()) :: {reference(), [Drain.entry()]}
  def begin_drain(opts \\ []), do: GenServer.call(server(opts), :begin_drain)

  @spec complete_drain(reference(), keyword()) :: :ok | {:error, :receipt_work_pending}
  def complete_drain(epoch, opts \\ []) when is_reference(epoch) do
    GenServer.call(server(opts), {:complete_drain, epoch})
  end

  @doc """
  Cancels an admitted activity for a drain. An activity whose terminal the
  socket already pushed (`mark_terminal_delivered/2`) is left alone and
  answered `:terminal_delivered`, unless `force: true`: the drain's cut once
  the task had its time to settle.
  """
  @spec cancel(token(), :owner_drained, keyword()) :: :ok | :terminal_delivered
  def cancel(token, :owner_drained = reason, opts \\ []) when is_reference(token) do
    GenServer.call(server(opts), {:cancel, token, reason, Keyword.get(opts, :force, false)})
  end

  @doc """
  The socket is pushing the terminal of the turn `pid` runs (findings#287):
  from now on the client holds the turn's outcome and only its settlement is
  left, so a drain's `cancel/3` leaves that activity to settle
  (`ActivityDrain`); cancelling it had recorded a turn the client completed as
  `owner_drained` and put an error frame after its terminal. An unknown `pid`
  is a no-op.
  """
  @spec mark_terminal_delivered(pid(), keyword()) :: :ok
  def mark_terminal_delivered(pid, opts \\ []) when is_pid(pid),
    do: GenServer.call(server(opts), {:mark_terminal_delivered, pid})

  @spec status(token(), keyword()) ::
          {:active, :registered | :admitted | :cancelling}
          | {:finished, outcome()}
          | :unknown
  def status(token, opts \\ []) when is_reference(token) do
    GenServer.call(server(opts), {:status, token})
  end

  @spec activities(keyword()) :: [Entry.t()]
  def activities(opts \\ []), do: GenServer.call(server(opts), :activities)

  @spec draining?(keyword()) :: boolean()
  def draining?(opts \\ []), do: GenServer.call(server(opts), :draining?)

  @impl GenServer
  def init(:ok) do
    {:ok, %{activities: %{}, monitors: %{}, draining?: false, drain: nil, finished_direct: %{}, receipt_producers: %{}, receipt_producer_monitors: %{}, delivery_receipts: %{}, delivery_monitors: %{}, delivery_failed?: false}}
  end

  @impl GenServer
  def handle_call({:enroll_delivery_receipt, socket, %{request_id: request, attempt_id: attempt, replay_generation: generation} = identity}, {task, _}, state)
      when is_pid(socket) and is_binary(request) and is_binary(attempt) and is_integer(generation) and generation >= 0 and map_size(identity) == 3 do
    if delivery_enrollment_allowed?(state, task, socket) do
      enroll_delivery_receipt_state(state, task, socket, identity)
    else
      {:reply, {:error, :owner_drained}, state}
    end
  end

  def handle_call({:enroll_delivery_receipt, _socket, _identity}, _from, state), do: {:reply, {:error, :invalid_identity}, state}

  def handle_call({:abandon_delivery_receipt, token}, {task, _}, state) do
    case Map.get(state.delivery_receipts, token) do
      %{task: ^task, envelope: nil} -> {:reply, :ok, state |> remove_delivery_receipt(token) |> mark_delivery_failure()}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:delivery_settling, task}, _from, state) do
    stopped? = match?({_token, %{direct_cleanup: %{upstream_stop?: true}}}, direct_entry(state, task))
    pending? = Enum.any?(state.delivery_receipts, fn {_token, entry} -> (entry.actor == task or (entry.task == task and stopped?)) and not is_nil(entry.envelope) and not entry.finished? end)
    {:reply, pending?, state}
  end

  # The executor claims protection before its first terminal transaction.
  # Socket cancellation and this claim share the registry mailbox: a socket
  # cannot observe "not settling" and then kill an executor that entered the
  # phase between the observation and its exit signal. The deadline never
  # renews, and rollout drain's separate absolute cutoff remains authoritative.
  def handle_call({:protect_response_settlement, token, budget_ms}, {task, _}, state) do
    case Map.get(state.activities, token) do
      %{pid: ^task} = entry ->
        entry = Map.put_new(entry, :settlement_deadline, System.monotonic_time(:millisecond) + budget_ms)
        {:reply, :ok, %{state | activities: Map.put(state.activities, token, entry)}}

      _unknown ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:cancel_unless_settling, task, reason}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case direct_entry(state, task) do
      {_token, %{settlement_deadline: deadline}} when deadline > now ->
        {:reply, {:settling, deadline}, state}

      _other ->
        Process.exit(task, {:shutdown, reason})
        {:reply, :cancelled, state}
    end
  end

  def handle_call({:acknowledge_retired_delivery, task, activity}, {socket, _}, state) do
    case Enum.find(state.delivery_receipts, fn {_token, entry} -> entry.socket == socket and entry.task == task and is_map(entry.envelope) end) do
      {token, entry} -> {:reply, :ok, remember_delivery_ack(state, token, entry, {:response_task, task, activity, :aborted})}
      nil -> {:reply, {:error, :unknown_delivery}, state}
    end
  end

  def handle_call({:delivery_receipt_token, identity}, {socket, _}, state) do
    result =
      Enum.find_value(state.delivery_receipts, :unknown, fn
        {token, %{socket: ^socket, identity: ^identity}} -> {:ok, token}
        _ -> nil
      end)

    {:reply, result, state}
  end

  def handle_call({:accepted_delivery_receipt, token, context}, {socket, _}, state) do
    result =
      case Map.get(state.delivery_receipts, token) do
        %{socket: ^socket, envelope: %{context: ^context}, finished?: false} ->
          {:accepted, :pending}

        %{socket: ^socket, envelope: %{context: ^context}, finished?: true, result: :ok} ->
          {:accepted, :finished}

        %{socket: ^socket, envelope: %{context: ^context}, finished?: true} ->
          {:error, :receipt_not_persisted}

        %{socket: ^socket, identity: identity, envelope: nil} ->
          if Map.take(context, [:request_id, :attempt_id, :replay_generation]) == identity, do: :unpublished, else: {:error, :identity_mismatch}

        _ ->
          {:error, :unknown_delivery}
      end

    {:reply, result, state}
  end

  def handle_call({:publish_delivery_receipt, token, context, receipt, recipient}, {socket, _}, state) do
    case Map.get(state.delivery_receipts, token) do
      %{socket: ^socket, identity: identity, envelope: nil} = entry ->
        if Map.take(context, [:request_id, :attempt_id, :replay_generation]) == identity do
          envelope = %{registry: self(), token: token, context: context, receipt: receipt}
          entry = start_delivery_deadline(entry, envelope)
          {result, state} = assign_delivery_receipt(state, token, entry, recipient)
          {:reply, result, state}
        else
          {:reply, {:error, :identity_mismatch}, state}
        end

      %{socket: ^socket, envelope: %{context: ^context, receipt: ^receipt}} = entry ->
        {:reply, :ok, remember_delivery_ack(state, token, entry, recipient)}

      _ ->
        {:reply, {:error, :unknown_delivery}, state}
    end
  end

  def handle_call({:take_delivery_cleanup, token, context, receipt}, {actor, _} = from, state) do
    case Map.get(state.delivery_receipts, token) do
      %{identity: identity, envelope: nil} = entry ->
        if Map.take(context, [:request_id, :attempt_id, :replay_generation]) == identity do
          envelope = %{registry: self(), token: token, context: context, receipt: receipt}
          monitor = Process.monitor(actor)
          entry = entry |> start_delivery_deadline(envelope) |> Map.merge(%{actor: actor, actor_monitor: monitor})
          state = %{state | delivery_receipts: Map.put(state.delivery_receipts, token, entry), delivery_monitors: Map.put(state.delivery_monitors, monitor, {token, :actor})}
          {:reply, {:ok, envelope}, state}
        else
          {:reply, {:error, :identity_mismatch}, state}
        end

      %{envelope: %{context: ^context, receipt: ^receipt} = envelope, actor: ^actor, finished?: false} ->
        {:reply, {:ok, envelope}, state}

      %{envelope: %{context: ^context, receipt: ^receipt}, finished?: true, result: result} ->
        {:reply, {:settled, result}, state}

      %{envelope: %{context: ^context, receipt: ^receipt}} = entry ->
        {:noreply, put_in(state.delivery_receipts[token].waiters, [from | entry.waiters])}

      _ ->
        {:reply, {:error, :unknown_delivery}, state}
    end
  end

  def handle_call(:assigned_delivery_receipts, {actor, _}, state) do
    envelopes =
      Enum.flat_map(state.delivery_receipts, fn
        {_token, %{actor: ^actor, finished?: false, envelope: envelope}} when is_map(envelope) -> [envelope]
        _ -> []
      end)

    {:reply, envelopes, state}
  end

  def handle_call({:claim_delivery_receipt, token, envelope}, {actor, _}, state) do
    result =
      case Map.get(state.delivery_receipts, token) do
        %{actor: ^actor, finished?: false, envelope: expected, deadline_ms: deadline} when is_nil(envelope) or envelope == expected ->
          delivery_claim_result(envelope, deadline)

        _ ->
          {:error, :stale_delivery}
      end

    {:reply, result, state}
  end

  def handle_call({:finish_delivery_receipt, token, result}, {actor, _}, state) do
    result = if result == :ok, do: :ok, else: {:error, :receipt_not_persisted}

    case Map.get(state.delivery_receipts, token) do
      %{actor: ^actor, finished?: false} = entry ->
        Process.demonitor(entry.actor_monitor, [:flush])
        cancel_delivery_deadline(entry)
        reply_executor_waiters(entry, result)
        Enum.each(entry.waiters, &GenServer.reply(&1, {:settled, result}))
        Enum.each(entry.acks, &send_delivery_ack(&1, result))
        entry = %{entry | finished?: true, actor_monitor: nil, waiters: [], acks: [], executor_waiters: [], result: result}
        state = %{state | delivery_monitors: Map.delete(state.delivery_monitors, Map.get(state.delivery_receipts[token], :actor_monitor)), delivery_failed?: state.delivery_failed? or (state.draining? and result != :ok)}
        state = put_in(state.delivery_receipts[token], entry)
        state = if Process.alive?(entry.socket), do: state, else: remove_delivery_receipt(state, token)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:direct_handoff, context}, _from, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context} = cleanup}} ->
        cleanup = %{cleanup | receipt: nil, pending?: false}
        cleanup = Map.put(cleanup, :consumed?, true)
        {:reply, :ok, put_in(state.activities[token].direct_cleanup, cleanup)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:direct_cancel_reason, context, reason}, _from, state)
      when reason in [
             "owner_drained",
             "owner_unavailable",
             "owner_crashed",
             "stale_owner",
             "client_disconnected"
           ] do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context} = cleanup}} ->
        receipt = if cleanup.receipt, do: Map.put_new(cleanup.receipt, :cancel_reason, reason)
        cleanup = Map.put_new(cleanup, :cancel_reason, reason)

        {:reply, :ok, put_in(state.activities[token].direct_cleanup, %{cleanup | receipt: receipt})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:direct_upstream_wait, context, waiting?}, {caller, _} = from, state) do
    case direct_entry(state, context.task) do
      {_token, %{direct_cleanup: %{context: ^context, upstream_stop?: true, delivery_token: receipt_token}}} when caller == context.task and not waiting? ->
        wait_for_stopped_delivery(state, receipt_token, context, from)

      {_token, %{direct_cleanup: %{context: ^context, upstream_stop?: true}}} when caller == context.task ->
        {:reply, {:error, :stopped}, state}

      {token, %{direct_cleanup: %{context: ^context} = cleanup}} when caller == context.task ->
        {:reply, :ok, put_in(state.activities[token].direct_cleanup, Map.put(cleanup, :upstream_wait?, waiting?))}

      _ ->
        {:reply, {:error, :stale_direct_cleanup}, state}
    end
  end

  def handle_call({:direct_stop_upstream_wait, context, packet}, {actor, _}, state) do
    case direct_entry(state, context.task) do
      {activity, %{direct_cleanup: %{context: ^context, upstream_wait?: true} = cleanup}} ->
        grant_stopped_delivery(state, activity, cleanup, context, packet, actor)

      _ ->
        {:reply, :busy, state}
    end
  end

  def handle_call({:direct_stop_upstream_wait, context}, _from, state) do
    case direct_entry(state, context.task) do
      {_token, %{direct_cleanup: %{context: ^context, upstream_wait?: true, receipt: %{attempt_id: attempt}}}} when is_binary(attempt) ->
        {:reply, {:error, :delivery_identity_unavailable}, state}

      {token, %{direct_cleanup: %{context: ^context, upstream_wait?: true} = cleanup}} ->
        {:reply, :stop, put_in(state.activities[token].direct_cleanup, Map.put(cleanup, :upstream_stop?, true))}

      _ ->
        {:reply, :busy, state}
    end
  end

  def handle_call({:direct_cancel_pending, context}, _from, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context, pending?: true}} = entry} ->
        {:reply, :pending, put_in(state.activities[token], Map.put(entry, :direct_cancelled?, true))}

      _ ->
        {:reply, :not_pending, state}
    end
  end

  def handle_call({:direct_begin, context}, {caller, _}, state) do
    case direct_entry(state, context.task) do
      {token, %{status: :admitted, direct_ref: ref, direct_parent: parent} = entry}
      when caller == context.task and ref == context.ref and parent == context.parent and
             not is_map_key(entry, :direct_cancelled?) and not is_map_key(entry, :direct_cleanup) ->
        cleanup = %{context: context, pending?: true, receipt: nil, waiters: []}
        {:reply, :ok, put_in(state.activities[token], Map.put(entry, :direct_cleanup, cleanup))}

      _ ->
        {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:direct_bind, context, receipt}, {caller, _}, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context} = cleanup}} when caller == context.task ->
        receipt =
          case Map.get(cleanup, :cancel_reason) do
            nil -> receipt
            reason -> Map.put(receipt, :cancel_reason, reason)
          end

        send(context.parent, {:direct_request_cleanup, context.task, context.ref, receipt})

        {:reply, :ok, put_in(state.activities[token].direct_cleanup, %{cleanup | receipt: receipt})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:direct_ready, context}, {caller, _}, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context} = cleanup} = entry}
      when caller == context.task ->
        reply_direct_waiters(cleanup)

        result =
          if entry.status == :cancelling or cleanup.waiters != [] or
               Map.get(entry, :direct_cancelled?, false),
             do: {:error, :cancelled},
             else: :ok

        {:reply, result, put_in(state.activities[token].direct_cleanup, %{cleanup | pending?: false, waiters: []})}

      _ ->
        {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:direct_await, context}, from, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context, pending?: true} = cleanup}} ->
        {:noreply,
         put_in(state.activities[token].direct_cleanup, %{
           cleanup
           | waiters: [from | cleanup.waiters]
         })}

      {token, %{direct_cleanup: %{context: ^context} = cleanup}} ->
        {:reply, direct_receipt(cleanup), put_in(state.activities[token].direct_cleanup, Map.put(cleanup, :consumed?, true))}

      {token, %{direct_ref: ref, direct_parent: parent} = entry}
      when entry.pid == context.task and ref == context.ref and parent == context.parent ->
        {:reply, :none, put_in(state.activities[token], Map.put(entry, :direct_cancelled?, true))}

      _ ->
        case Map.get(state.finished_direct, context.ref) do
          %{context: ^context} = completed ->
            Process.demonitor(completed.monitor, [:flush])

            {:reply, {:ok, completed.receipt}, %{state | finished_direct: Map.delete(state.finished_direct, context.ref)}}

          _ ->
            {:reply, :none, state}
        end
    end
  end

  def handle_call({:begin_receipt_producer, _identity}, _from, %{draining?: true} = state),
    do: {:reply, {:error, :owner_drained}, state}

  def handle_call({:begin_receipt_producer, identity}, {owner, _}, state) do
    case identity do
      %{request_id: request, attempt_id: attempt, replay_generation: generation}
      when is_binary(request) and byte_size(request) > 0 and is_binary(attempt) and byte_size(attempt) > 0 and is_integer(generation) and generation >= 0 and map_size(identity) == 3 ->
        token = make_ref()
        monitor = Process.monitor(owner)
        producer = %{owner: owner, identity: identity, monitor: monitor, worker: nil}
        state = %{state | receipt_producers: Map.put(state.receipt_producers, token, producer), receipt_producer_monitors: Map.put(state.receipt_producer_monitors, monitor, token)}
        {:reply, {:ok, token}, state}

      _invalid ->
        {:reply, {:error, :invalid_identity}, state}
    end
  end

  def handle_call({:register_receipt_settlement, producer, identity, worker}, {owner, _}, state) do
    case Map.get(state.receipt_producers, producer) do
      %{owner: ^owner, identity: ^identity, worker: nil} ->
        token = make_ref()
        monitor = Process.monitor(worker)
        entry = Entry.new(token, :receipt_settlement, worker, monitor) |> Map.put(:status, :admitted) |> Map.put(:receipt_identity, identity)
        state = %{state | activities: Map.put(state.activities, token, entry), monitors: Map.put(state.monitors, monitor, token), drain: Drain.join_receipt(state.drain, token)}
        state = put_in(state.receipt_producers[producer].worker, {worker, token})
        {:reply, {:ok, token}, state}

      %{owner: ^owner, identity: ^identity, worker: {^worker, token}} ->
        {:reply, {:ok, token}, state}

      %{owner: ^owner, identity: ^identity} ->
        {:reply, {:error, :already_registered}, state}

      %{owner: ^owner} ->
        {:reply, {:error, :identity_mismatch}, state}

      _closed_or_wrong_owner ->
        {:reply, {:error, :producer_closed}, state}
    end
  end

  def handle_call({:finish_receipt_producer, token}, {owner, _}, state) do
    case Map.get(state.receipt_producers, token) do
      %{owner: ^owner} -> {:reply, :ok, finish_receipt_producer_state(state, token, false)}
      _closed_or_wrong_owner -> {:reply, {:error, :producer_closed}, state}
    end
  end

  def handle_call({:complete_receipt_settlement, token, disposition}, {worker, _}, state) do
    case Map.get(state.activities, token) do
      %{kind: :receipt_settlement, pid: ^worker} ->
        state = put_in(state.activities[token][:receipt_disposition], disposition)
        outcome = if disposition in [:failed, :aborted], do: disposition, else: :completed
        {:reply, :ok, finish_activity(state, token, outcome, true, true)}

      nil ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call(:receipt_cohort, _from, state) do
    drain = Drain.close_receipts(state.drain, map_size(state.receipt_producers) == 0 and pending_deliveries(state) == 0)
    cohort = %{closed?: not is_nil(drain) and drain.receipts_closed?, entries: Drain.receipt_entries(drain, state.activities), pending_producers: map_size(state.receipt_producers) + pending_deliveries(state), producers_failed?: state.delivery_failed? or (not is_nil(drain) and drain.receipt_producers_failed?)}
    {:reply, cohort, %{state | drain: drain}}
  end

  def handle_call(:force_receipt_cohort, _from, state) do
    state = Enum.reduce(Map.keys(state.receipt_producers), state, &finish_receipt_producer_state(&2, &1, true))

    state =
      Enum.reduce(state.activities, state, fn
        {token, %{kind: :receipt_settlement, pid: pid}}, acc ->
          Process.exit(pid, :kill)
          finish_activity(acc, token, :aborted, true, true)

        _other, acc ->
          acc
      end)

    state =
      Enum.reduce(state.delivery_receipts, state, fn
        {token, %{finished?: false} = entry}, acc ->
          if is_pid(entry.actor), do: Process.exit(entry.actor, :kill)
          acc |> remove_delivery_receipt(token) |> mark_delivery_failure()

        _, acc ->
          acc
      end)

    {:reply, :ok, %{state | drain: Drain.close_receipts(state.drain, true)}}
  end

  def handle_call({:register, kind, pid, opts}, _from, state) do
    token = make_ref()
    monitor = Process.monitor(pid)

    entry = Entry.new(token, kind, pid, monitor)

    entry =
      case {Keyword.get(opts, :direct_cleanup_ref), Keyword.get(opts, :direct_cleanup_parent)} do
        {ref, parent} when is_reference(ref) and is_pid(parent) ->
          Map.merge(entry, %{direct_ref: ref, direct_parent: parent})

        _ ->
          entry
      end

    state = %{
      state
      | activities: Map.put(state.activities, token, entry),
        monitors: Map.put(state.monitors, monitor, token)
    }

    {:reply, {:ok, token}, state}
  end

  def handle_call({:admit, token}, _from, %{draining?: true} = state) do
    reply =
      if Map.has_key?(state.activities, token),
        do: {:error, :owner_drained},
        else: {:error, :unknown_activity}

    {:reply, reply, state}
  end

  def handle_call({:admit, token}, _from, state) do
    case Map.fetch(state.activities, token) do
      {:ok, entry} ->
        activities = Map.put(state.activities, token, %{entry | status: :admitted})
        {:reply, :ok, %{state | activities: activities}}

      :error ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:unregister, token, outcome}, _from, state) do
    {:reply, :ok, finish_activity(state, token, outcome)}
  end

  def handle_call({:complete, token, outcome}, _from, state) do
    {:reply, :ok, finish_activity(state, token, outcome, true, true)}
  end

  def handle_call({:set_cancel_recipient, token, pid}, _from, state) do
    case Map.fetch(state.activities, token) do
      {:ok, entry} ->
        entry = Entry.set_recipient(entry, pid)
        activities = Map.put(state.activities, token, entry)
        {:reply, :ok, %{state | activities: activities}}

      :error ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:handoff_cancel_recipient, token, from_pid, to_pid}, _from, state) do
    case Map.get(state.activities, token) do
      entry when is_map(entry) ->
        case Entry.handoff(entry, from_pid, to_pid) do
          {:ok, entry} ->
            {:reply, :ok, put_in(state.activities[token], entry)}

          {:cancelled, reason, ack_pid} ->
            {:reply, {:cancelled, reason, ack_pid}, state}

          :stale ->
            {:reply, {:error, :unknown_activity}, state}
        end

      nil ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:delivery_target, pid}, _from, state) do
    reply =
      Enum.find_value(state.activities, :unknown, fn {token, entry} ->
        if entry.pid == pid do
          {token, ack_pid, status} = Entry.delivery_target(entry, token)
          {:ok, token, ack_pid, status}
        end
      end)

    {:reply, reply, state}
  end

  def handle_call(:begin_drain, _from, %{drain: nil} = state) do
    {drain, epoch, entries} = Drain.begin(nil, state.activities)
    state = %{state | draining?: true, drain: drain}
    {:reply, {epoch, entries}, state}
  end

  def handle_call(:begin_drain, _from, state) do
    {drain, epoch, entries} = Drain.begin(state.drain, state.activities)
    {:reply, {epoch, entries}, %{state | drain: drain}}
  end

  def handle_call({:complete_drain, epoch}, _from, %{drain: %{epoch: epoch}} = state) do
    pending? = pending_deliveries(state) > 0 or map_size(state.receipt_producers) > 0 or Enum.any?(Drain.receipt_entries(state.drain, state.activities), &(&1.status == :active))

    if pending?, do: {:reply, {:error, :receipt_work_pending}, state}, else: {:reply, :ok, %{state | drain: nil}}
  end

  def handle_call({:complete_drain, _epoch}, _from, state), do: {:reply, :ok, state}

  def handle_call({:mark_terminal_delivered, pid}, _from, state) do
    activities =
      Map.new(state.activities, fn
        {token, %{pid: ^pid} = entry} -> {token, Map.put(entry, :terminal_delivered?, true)}
        other -> other
      end)

    {:reply, :ok, %{state | activities: activities}}
  end

  def handle_call({:cancel, token, reason, force?}, _from, state) do
    case Map.get(state.activities, token) do
      %{terminal_delivered?: true, status: status} when status in [:registered, :admitted] and not force? ->
        {:reply, :terminal_delivered, state}

      %{status: status} = entry when status in [:registered, :admitted] ->
        _marked = ExecutionRegistry.mark_interruption(entry.pid, "owner_drained")
        {cancel_pid, entry} = Entry.cancel(entry, reason)
        send(cancel_pid, {:websocket_activity_cancel, token, reason})
        activities = Map.put(state.activities, token, entry)

        {:reply, :ok, %{state | activities: activities}}

      _finished_unknown_or_cancelling ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:status, token}, _from, state) do
    reply =
      case Map.get(state.activities, token) do
        %{status: status} -> {:active, status}
        nil -> Drain.outcome(state.drain, token)
      end

    {:reply, reply, state}
  end

  def handle_call(:activities, _from, state) do
    entries = Enum.map(state.activities, fn {_token, entry} -> Map.drop(entry, [:monitor]) end)
    {:reply, entries, state}
  end

  def handle_call(:draining?, _from, state), do: {:reply, state.draining?, state}

  @impl GenServer
  def handle_info({:delivery_receipt_deadline, token, deadline}, state) do
    case Map.get(state.delivery_receipts, token) do
      %{finished?: false, deadline_ms: ^deadline} = entry ->
        {:noreply, expire_delivery_at_deadline(state, token, entry, deadline)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{delivery_monitors: monitors} = state) when is_map_key(monitors, monitor) do
    {token, role} = Map.fetch!(monitors, monitor)
    entry = state.delivery_receipts[token]
    state = %{state | delivery_monitors: Map.delete(monitors, monitor)}

    case {role, entry} do
      {:socket, %{finished?: true}} ->
        {:noreply, remove_delivery_receipt(state, token)}

      {:socket, %{envelope: nil}} ->
        {:noreply, state |> remove_delivery_receipt(token) |> mark_delivery_failure()}

      {:socket, _submitted} ->
        {:noreply, state}

      {:actor, %{finished?: false, fallback?: false}} ->
        {_result, state} = assign_delivery_receipt(state, token, entry, :fallback)
        {:noreply, state}

      {:actor, %{finished?: false}} ->
        {:noreply, state |> remove_delivery_receipt(token) |> mark_delivery_failure()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{receipt_producer_monitors: monitors} = state) when is_map_key(monitors, monitor) do
    token = Map.fetch!(monitors, monitor)
    failed? = is_nil(state.receipt_producers[token].worker)
    {:noreply, finish_receipt_producer_state(state, token, failed?)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        finished =
          Map.reject(state.finished_direct, fn {_ref, completed} ->
            completed.monitor == monitor
          end)

        {:noreply, %{state | finished_direct: finished}}

      {token, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, finish_activity(state, token, :failed, false)}
    end
  end

  defp finish_activity(
         state,
         token,
         outcome,
         demonitor? \\ true,
         honor_outcome? \\ false
       ) do
    case Map.pop(state.activities, token) do
      {nil, _activities} ->
        state

      {entry, activities} ->
        if cleanup = Map.get(entry, :direct_cleanup), do: reply_direct_waiters(cleanup)
        state = retain_direct_cleanup(state, Map.get(entry, :direct_cleanup))

        if demonitor?, do: Process.demonitor(entry.monitor, [:flush])
        monitors = Map.delete(state.monitors, entry.monitor)

        outcome =
          if not honor_outcome? and entry.status == :cancelling,
            do: :aborted,
            else: outcome

        state = %{state | activities: activities, monitors: monitors}

        %{state | drain: Drain.record_outcome(state.drain, token, entry, outcome)}
    end
  end

  defp finish_receipt_producer_state(state, token, failed?) do
    {producer, producers} = Map.pop(state.receipt_producers, token)
    Process.demonitor(producer.monitor, [:flush])
    drain = if failed? and state.drain, do: %{state.drain | receipt_producers_failed?: true}, else: state.drain
    %{state | receipt_producers: producers, receipt_producer_monitors: Map.delete(state.receipt_producer_monitors, producer.monitor), drain: drain}
  end

  defp retain_direct_cleanup(state, %{consumed?: true}), do: state

  defp retain_direct_cleanup(state, %{context: context, receipt: receipt})
       when not is_nil(receipt) do
    completed = %{context: context, receipt: receipt, monitor: Process.monitor(context.parent)}
    %{state | finished_direct: Map.put(state.finished_direct, context.ref, completed)}
  end

  defp retain_direct_cleanup(state, _cleanup), do: state

  defp delivery_claim_result(envelope, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 -> {:error, :receipt_deadline_expired}
      is_nil(envelope) -> :ok
      true -> {:ok, remaining}
    end
  end

  defp bound_receipt_matches?(%{session_id: session} = bound, %{codex_session_id: session} = context, %{session_id: session}) do
    Map.take(bound, [:request_id, :attempt_id, :replay_generation]) == Map.take(context, [:request_id, :attempt_id, :replay_generation])
  end

  defp bound_receipt_matches?(_bound, _receipt, _context), do: false

  defp grant_stopped_delivery(state, activity, cleanup, context, {receipt_context, receipt}, actor) when is_map(receipt_context) and is_map(receipt) do
    identity = Map.take(receipt_context, [:request_id, :attempt_id, :replay_generation])
    valid? = bound_receipt_matches?(cleanup.receipt, receipt_context, context)
    found = if valid?, do: Enum.find(state.delivery_receipts, fn {_token, entry} -> entry.task == context.task and entry.socket == context.parent and entry.identity == identity end)

    case found do
      {token, %{envelope: nil} = entry} ->
        envelope = %{registry: self(), token: token, context: receipt_context, receipt: receipt}
        monitor = Process.monitor(actor)
        entry = entry |> start_delivery_deadline(envelope) |> Map.merge(%{actor: actor, actor_monitor: monitor})
        state = %{state | delivery_receipts: Map.put(state.delivery_receipts, token, entry), delivery_monitors: Map.put(state.delivery_monitors, monitor, {token, :actor})}
        cleanup = Map.merge(cleanup, %{upstream_stop?: true, delivery_token: token})
        {:reply, {:stop, envelope}, put_in(state.activities[activity].direct_cleanup, cleanup)}

      {token, %{envelope: %{context: ^receipt_context, receipt: ^receipt} = envelope}} ->
        cleanup = Map.merge(cleanup, %{upstream_stop?: true, delivery_token: token})
        {:reply, {:stop, envelope}, put_in(state.activities[activity].direct_cleanup, cleanup)}

      _ ->
        {:reply, {:error, :delivery_identity_unavailable}, state}
    end
  end

  defp grant_stopped_delivery(state, _activity, _cleanup, _context, _packet, _actor), do: {:reply, {:error, :delivery_identity_unavailable}, state}

  defp wait_for_stopped_delivery(state, token, context, {caller, _} = from) do
    case Map.get(state.delivery_receipts, token) do
      %{task: ^caller, socket: socket, finished?: true, result: result} when socket == context.parent ->
        {:reply, stopped_delivery_result(result), state}

      %{task: ^caller, socket: socket, envelope: envelope, deadline_ms: deadline} = entry when socket == context.parent and is_map(envelope) and is_integer(deadline) ->
        {:noreply, put_in(state.delivery_receipts[token].executor_waiters, [from | entry.executor_waiters])}

      _ ->
        {:reply, {:error, {:stopped, :delivery_identity_unavailable}}, state}
    end
  end

  defp start_delivery_deadline(entry, envelope) do
    timeout = DeliveryReceiptHandoff.persistence_timeout_ms(envelope.context)
    deadline = System.monotonic_time(:millisecond) + timeout
    timer = Process.send_after(self(), {:delivery_receipt_deadline, envelope.token, deadline}, timeout)
    %{entry | envelope: envelope, deadline_ms: deadline, deadline_timer: timer}
  end

  defp expire_delivery_at_deadline(state, token, entry, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.warning("websocket delivery receipt deadline expired outcome=aborted")
      if is_pid(entry.actor), do: Process.exit(entry.actor, :kill)
      state |> remove_delivery_receipt(token) |> mark_delivery_failure()
    else
      state
    end
  end

  defp cancel_delivery_deadline(%{deadline_timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_delivery_deadline(_entry), do: :ok
  defp stopped_delivery_result(:ok), do: {:error, :stopped}
  defp stopped_delivery_result({:error, reason}), do: {:error, {:stopped, reason}}
  defp reply_executor_waiters(entry, result), do: Enum.each(entry.executor_waiters, &GenServer.reply(&1, stopped_delivery_result(result)))

  defp delivery_enrollment_allowed?(%{draining?: false}, _task, _socket), do: true

  defp delivery_enrollment_allowed?(%{drain: %{receipts_closed?: false}} = state, task, socket) do
    case direct_entry(state, task) do
      {_token, %{status: status, direct_parent: ^socket, direct_ref: ref}} when status in [:admitted, :cancelling] and is_reference(ref) -> true
      _ -> false
    end
  end

  defp delivery_enrollment_allowed?(_state, _task, _socket), do: false

  defp enroll_delivery_receipt_state(state, task, socket, identity) do
    case Enum.find(state.delivery_receipts, fn {_token, entry} -> entry.task == task and entry.identity == identity end) do
      {token, _entry} ->
        {:reply, {:ok, token}, state}

      nil ->
        state =
          Enum.reduce(state.delivery_receipts, state, fn
            {token, %{socket: ^socket, finished?: true, task: previous_task}}, acc -> prune_finished_delivery(acc, token, previous_task, task)
            _, acc -> acc
          end)

        token = make_ref()
        monitor = Process.monitor(socket)
        entry = %{socket: socket, task: task, identity: identity, socket_monitor: monitor, actor: nil, actor_monitor: nil, envelope: nil, finished?: false, fallback?: false, waiters: [], acks: [], executor_waiters: [], result: nil, deadline_ms: nil, deadline_timer: nil}
        state = %{state | delivery_receipts: Map.put(state.delivery_receipts, token, entry), delivery_monitors: Map.put(state.delivery_monitors, monitor, {token, :socket})}
        send(socket, {:downstream_receipt_enrolled, task, identity, token})
        {:reply, {:ok, token}, state}
    end
  end

  defp prune_finished_delivery(state, token, previous_task, task) do
    if previous_task == task or not Process.alive?(previous_task), do: remove_delivery_receipt(state, token), else: state
  end

  defp remember_delivery_ack(state, token, %{task: task} = entry, {:response_task, task, activity, outcome} = recipient) when is_reference(activity) do
    if entry.finished? do
      send_delivery_ack(recipient, entry.result)
      state
    else
      put_in(state.delivery_receipts[token].acks, Enum.uniq([{:response_task, task, activity, outcome} | entry.acks]))
    end
  end

  defp remember_delivery_ack(state, _token, _entry, _recipient), do: state

  defp send_delivery_ack({:response_task, task, activity, outcome}, result) do
    outcome = if result == :ok and outcome != :aborted, do: :completed, else: :aborted
    send(task, {:websocket_response_delivery_ack, activity, outcome})
  end

  defp assign_delivery_receipt(state, token, entry, recipient) do
    case delivery_actor(state, entry, recipient) do
      {:ok, actor, message} ->
        monitor = Process.monitor(actor)
        entry = %{entry | actor: actor, actor_monitor: monitor}
        state = %{state | delivery_receipts: Map.put(state.delivery_receipts, token, entry), delivery_monitors: Map.put(state.delivery_monitors, monitor, {token, :actor})}
        send(actor, message.(entry.envelope))
        {:ok, state}

      :fallback ->
        case DeliveryReceiptHandoff.start_fallback() do
          {:ok, actor} ->
            monitor = Process.monitor(actor)
            entry = %{entry | actor: actor, actor_monitor: monitor, fallback?: true}
            state = %{state | delivery_receipts: Map.put(state.delivery_receipts, token, entry), delivery_monitors: Map.put(state.delivery_monitors, monitor, {token, :actor})}
            send(actor, {:settle_delivery_receipt, entry.envelope})
            {:ok, state}

          {:error, _reason} ->
            {{:error, :worker_unavailable}, state |> mark_delivery_failure() |> remove_delivery_receipt(token)}
        end
    end
  end

  defp delivery_actor(state, entry, {:response_task, actor, activity, outcome}) do
    case Map.get(state.activities, activity) do
      %{pid: task, ack_pid: ^actor, status: status} when task == entry.task and (actor == task or status == :cancelling) ->
        {:ok, actor, fn envelope -> {:websocket_response_delivery_ack, activity, outcome, envelope} end}

      nil when actor == entry.task ->
        {:ok, actor, fn envelope -> {:websocket_response_delivery_ack, activity, outcome, envelope} end}

      _ ->
        :fallback
    end
  end

  defp delivery_actor(_state, %{task: lane, identity: identity}, {:native, lane, identity, outcome}),
    do: {:ok, lane, fn envelope -> {:"$gen_cast", {:delivery_complete, identity, outcome, envelope}} end}

  defp delivery_actor(_state, _entry, _recipient), do: :fallback

  defp mark_delivery_failure(state), do: %{state | delivery_failed?: state.delivery_failed? or state.draining?}

  defp pending_deliveries(state), do: Enum.count(state.delivery_receipts, fn {_token, entry} -> not entry.finished? end)

  defp remove_delivery_receipt(state, token) do
    case Map.pop(state.delivery_receipts, token) do
      {nil, _} ->
        state

      {entry, entries} ->
        cancel_delivery_deadline(entry)
        reply_executor_waiters(entry, {:error, :receipt_aborted})
        Enum.each(entry.waiters, &GenServer.reply(&1, {:settled, {:error, :delivery_aborted}}))
        monitors = Enum.reject([entry.socket_monitor, entry.actor_monitor], &is_nil/1)
        Enum.each(monitors, &Process.demonitor(&1, [:flush]))
        %{state | delivery_receipts: entries, delivery_monitors: Map.drop(state.delivery_monitors, monitors)}
    end
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp direct_entry(state, pid),
    do: Enum.find(state.activities, fn {_token, entry} -> entry.pid == pid end)

  defp direct_receipt(%{receipt: nil}), do: :none
  defp direct_receipt(%{receipt: receipt}), do: {:ok, receipt}

  defp reply_direct_waiters(cleanup),
    do: Enum.each(cleanup.waiters, &GenServer.reply(&1, direct_receipt(cleanup)))
end
