defmodule CodexPoolerWeb.Telemetry.AdmissionSamplerTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Telemetry.AdmissionSampler

  @event [:codex_pooler, :gateway, :admission, :saturation]

  defmodule DelayedAdmission do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid), opts)

    def init(test_pid), do: {:ok, %{test_pid: test_pid, froms: []}}

    def handle_call(:saturation, from, state) do
      send(state.test_pid, {:delayed_saturation_call, from})
      {:noreply, %{state | froms: [from | state.froms]}}
    end

    def handle_call(:reply_late, _from, %{froms: [from | remaining]} = state) do
      GenServer.reply(from, %{"proxy_stream" => %{running: 99, queued: 99}})
      {:reply, :ok, %{state | froms: remaining}}
    end
  end

  test "samples real Admission running and queue lifecycle transitions" do
    attach_saturation_telemetry()
    attach_admission_telemetry()
    admission_name = unique_name(:admission)
    sampler_name = unique_name(:admission_sampler)
    settings = settings(max_concurrency: 1, queue_limit: 1, queue_timeout_ms: 25)
    {:ok, _admission} = start_supervised({Admission, name: admission_name})
    {:ok, sampler} = start_sampler(sampler_name, admission_name)

    sync_sampler(sampler)
    assert_saturation(snapshot(0, 0))

    assert {:ok, running_lease} = acquire(admission_name, settings)
    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 0))

    test_pid = self()

    queued_task =
      Task.async(fn ->
        result = acquire(admission_name, settings)
        send(test_pid, {:queued_acquisition, self(), result})

        receive do
          :finish -> :ok
        end
      end)

    assert_admission_event(:enqueued)
    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 1))

    Admission.release(running_lease)
    queued_task_pid = queued_task.pid
    assert_receive {:queued_acquisition, ^queued_task_pid, {:ok, queued_lease}}
    assert_admission_event(:dequeued)

    assert {:ok, saturation} = Admission.saturation(admission_name)
    assert %{running: 1, queued: 0} = saturation["proxy_stream"]

    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 0))

    Admission.release(queued_lease)
    send(queued_task.pid, :finish)
    assert :ok = Task.await(queued_task, 1_000)

    assert {:ok, saturation} = Admission.saturation(admission_name)
    assert %{running: 0, queued: 0} = saturation["proxy_stream"]

    sample(sampler)
    assert_saturation(snapshot(0, 0))

    assert {:ok, timeout_held_lease} = acquire(admission_name, settings)
    timeout_task = Task.async(fn -> acquire(admission_name, settings) end)
    assert_admission_event(:enqueued)
    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 1))

    assert {:error, %{code: "bulkhead_queue_timeout"}} = Task.await(timeout_task, 1_000)
    assert_admission_event(:timeout)

    assert {:ok, saturation} = Admission.saturation(admission_name)
    assert %{running: 1, queued: 0} = saturation["proxy_stream"]

    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 0))

    Admission.release(timeout_held_lease)

    assert {:ok, saturation} = Admission.saturation(admission_name)
    assert %{running: 0, queued: 0} = saturation["proxy_stream"]

    sample(sampler)
    assert_saturation(snapshot(0, 0))
  end

  test "retains a nonzero snapshot through Admission downtime then refreshes after restart" do
    attach_saturation_telemetry()
    admission_name = unique_name(:admission)
    sampler_name = unique_name(:admission_sampler)
    settings = settings(max_concurrency: 2, queue_limit: 0, queue_timeout_ms: 25)
    {:ok, admission_supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

    {:ok, admission} =
      DynamicSupervisor.start_child(admission_supervisor, {Admission, name: admission_name})

    {:ok, sampler} = start_sampler(sampler_name, admission_name)
    sync_sampler(sampler)
    assert_saturation(snapshot(0, 0))

    assert {:ok, original_lease} = acquire(admission_name, settings)
    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 0))

    monitor = Process.monitor(admission)
    :ok = DynamicSupervisor.terminate_child(admission_supervisor, admission)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :shutdown}

    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 1, 0))

    assert %{last_snapshot: %{"proxy_stream" => %{running: 1, queued: 0}}} =
             :sys.get_state(sampler)

    {:ok, replacement} =
      DynamicSupervisor.start_child(admission_supervisor, {Admission, name: admission_name})

    refute replacement == admission
    assert {:ok, first_replacement_lease} = acquire(admission_name, settings)
    assert {:ok, second_replacement_lease} = acquire(admission_name, settings)
    sample(sampler)
    assert_saturation(snapshot("proxy_stream", 2, 0))

    Admission.release(first_replacement_lease)
    Admission.release(second_replacement_lease)

    assert {:ok, saturation} = Admission.saturation(admission_name)
    assert %{running: 0, queued: 0} = saturation["proxy_stream"]

    sample(sampler)
    assert_saturation(snapshot(0, 0))

    Admission.release(original_lease)
  end

  test "autonomously rearms after timeout, success, and later timeout" do
    attach_saturation_telemetry()
    sampler_name = unique_name(:admission_sampler)
    {:ok, reader_calls} = Agent.start_link(fn -> 0 end)

    {:ok, sampler} =
      start_supervised(
        {AdmissionSampler,
         name: sampler_name, interval_ms: 5, snapshot_reader: reader(reader_calls, self())}
      )

    assert_receive {:reader_called, :timeout}
    assert_saturation(snapshot(0, 0))
    assert_receive {:reader_called, :success}, 1_000
    assert_saturation(snapshot(3, 2))
    assert_receive {:reader_called, :timeout}, 1_000
    assert_saturation(snapshot(3, 2))
    assert Process.alive?(sampler)
  end

  test "late Admission replies do not leave stale sampler mailbox messages" do
    attach_saturation_telemetry()
    delayed_name = unique_name(:delayed_admission)
    sampler_name = unique_name(:admission_sampler)
    {:ok, delayed} = start_supervised({DelayedAdmission, name: delayed_name, test_pid: self()})

    {:ok, sampler} =
      start_supervised(
        {AdmissionSampler,
         name: sampler_name, admission_server: delayed_name, timeout_ms: 1, interval_ms: 60_000}
      )

    sync_sampler(sampler)
    assert_receive {:delayed_saturation_call, _from}
    assert_saturation(snapshot(0, 0))
    assert :ok = GenServer.call(delayed, :reply_late)
    assert {:messages, []} = Process.info(sampler, :messages)
  end

  defp start_sampler(name, admission_name) do
    start_supervised(
      {AdmissionSampler,
       name: name, admission_server: admission_name, interval_ms: 60_000, timeout_ms: 50}
    )
  end

  defp acquire(server, settings),
    do: Admission.acquire("proxy_stream", %{}, %{server: server, settings: settings})

  defp sample(sampler) do
    send(sampler, :sample)
    sync_sampler(sampler)
  end

  defp sync_sampler(sampler), do: :sys.get_state(sampler)

  defp settings(options) do
    bulkhead = %{
      max_concurrency: Keyword.fetch!(options, :max_concurrency),
      queue_limit: Keyword.fetch!(options, :queue_limit),
      queue_timeout_ms: Keyword.fetch!(options, :queue_timeout_ms)
    }

    %OperationalSettings{bulkheads: Map.new(RouteClass.all(), &{&1, bulkhead})}
  end

  defp reader(agent, test_pid) do
    fn ->
      Agent.get_and_update(agent, fn
        0 ->
          send(test_pid, {:reader_called, :timeout})
          {{:error, :timeout}, 1}

        1 ->
          send(test_pid, {:reader_called, :success})
          {{:ok, snapshot(3, 2)}, 2}

        _count ->
          send(test_pid, {:reader_called, :timeout})
          {{:error, :timeout}, 3}
      end)
    end
  end

  defp attach_saturation_telemetry do
    handler_id = {__MODULE__, :saturation, self(), System.unique_integer([:positive])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn @event, measurements, metadata, ^test_pid ->
          send(test_pid, {handler_id, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Process.put(:saturation_handler_id, handler_id)
  end

  defp attach_admission_telemetry do
    handler_id = {__MODULE__, :admission, self(), System.unique_integer([:positive])}
    test_pid = self()

    events =
      Enum.map([:enqueued, :dequeued, :timeout], &[:codex_pooler, :gateway, :admission, &1])

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _measurements, _metadata, ^test_pid ->
          send(test_pid, {handler_id, event})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Process.put(:admission_handler_id, handler_id)
  end

  defp assert_admission_event(event) do
    handler_id = Process.get(:admission_handler_id)
    assert_receive {^handler_id, [:codex_pooler, :gateway, :admission, ^event]}
  end

  defp assert_saturation(expected) do
    handler_id = Process.get(:saturation_handler_id)

    received =
      for _route_class <- RouteClass.all() do
        assert_receive {^handler_id, measurements, %{route_class: route_class}}
        {route_class, measurements}
      end
      |> Map.new()

    assert received == expected
  end

  defp snapshot(running, queued),
    do: Map.new(RouteClass.all(), &{&1, %{running: running, queued: queued}})

  defp snapshot(route_class, running, queued) do
    snapshot(0, 0)
    |> Map.put(route_class, %{running: running, queued: queued})
  end

  defp unique_name(kind), do: {:global, {kind, System.unique_integer([:positive])}}
end
