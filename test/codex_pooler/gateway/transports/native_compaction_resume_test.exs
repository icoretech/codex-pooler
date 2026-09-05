defmodule CodexPooler.Gateway.Transports.NativeCompactionResumeTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Confirmation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1, as: Control
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  test "current direct request cleanup clears its own reserved admission" do
    with_direct(fn owner, upstream ->
      {binding, capability} = reserve_direct(owner, upstream)
      options = direct_options(owner, binding, capability)

      assert :ok = RequestOptions.clear_native_compaction_admission(options)
      assert UpstreamWebsocketSession.compaction_admission_phase(owner) == :cleared
    end)
  end

  test "stale forwarded detach leaves replacement admission usable" do
    with_replacement(fn owner, old, current, _old_binding, binding, capability ->
      assert {:error, :duplicate_downstream} = WebsocketOwnerSession.detach_downstream(owner, old)
      assert_current_forwarded(owner, current, binding, capability)
    end)
  end

  test "delayed direct cleanup cannot clear a reservation on the reconnected generation" do
    with_direct(fn owner, upstream ->
      {old_binding, old_capability} = reserve_direct(owner, upstream)
      old_options = direct_options(owner, old_binding, old_capability)

      delayed =
        delayed_call(fn -> RequestOptions.clear_native_compaction_admission(old_options) end)

      assert :ok = UpstreamWebsocketSession.invalidate_connection(owner)
      {current_binding, current_capability} = reserve_direct(owner, upstream)
      assert current_binding.generation > old_binding.generation
      refute current_binding.semantic_turn_key == old_binding.semantic_turn_key
      assert UpstreamWebsocketSession.compaction_admission_phase(owner) == :reserved_compact
      sends_before_cleanup = FakeUpstream.count(upstream)

      release_call(delayed)

      assert FakeUpstream.count(upstream) == sends_before_cleanup
      phase = UpstreamWebsocketSession.compaction_admission_phase(owner)

      accounting =
        UpstreamWebsocketSession.mark_compaction_accounting_started(
          owner,
          current_capability,
          now_ms()
        )

      assert {phase, accounting} == {:reserved_compact, :ok}
    end)
  end

  for action <- [:snapshot, :mark_accounting_started, :finalization_ack] do
    test "delayed forwarded #{action} from old downstream cannot clear replacement admission" do
      action = unquote(action)

      with_replacement(
        fn owner, _old, current, delayed, binding, capability ->
          assert owner_phase(owner) == :reserved_compact
          assert release_call(delayed) == {:error, :stale_downstream}
          assert_current_forwarded(owner, current, binding, capability)
        end,
        action
      )
    end
  end

  defp assert_current_forwarded(owner, downstream, binding, capability) do
    current = :sys.get_state(owner).native_compaction_admission
    phase = owner_phase(owner)

    accounting =
      WebsocketOwnerSession.admission_control(
        owner,
        control(:mark_accounting_started, downstream,
          capability: capability,
          now_ms: now_ms()
        )
      )

    accounting_status =
      case accounting do
        {:ok, _admission} -> :ok
        {:error, reason} -> {:error, reason}
      end

    assert {phase, accounting_status} == {:reserved_compact, :ok}
    assert current.binding.lifecycle_id == binding.lifecycle_id
    assert current.binding.generation == binding.generation
    assert owner_phase(owner) == :accounting_started_compact
  end

  defp with_direct(fun) do
    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ordinary_fixture", "status" => "completed"}
      })

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([frame]))
    {:ok, owner} = UpstreamWebsocketSession.start_link([])

    try do
      fun.(owner, upstream)
    after
      stop_process(owner)
      FakeUpstream.stop(upstream)
    end
  end

  defp reserve_direct(owner, upstream) do
    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: ~s({"model":"sample-model"}),
      request_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      effective_serving_mode: "full",
      timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
      writer: fn _frame -> :ok end,
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }

    assert {:ok, result} = UpstreamWebsocketSession.request(owner, request)
    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(owner)

    binding = %{
      binding(lifecycle.lifecycle_id, lifecycle.generation, %Direct{})
      | previous_response_digest: result.ordinary_success_result.response_digest
    }

    assert :ok =
             UpstreamWebsocketSession.arm_compact(
               owner,
               binding,
               now_ms() + 30_000,
               result.ordinary_success_result
             )

    assert {:ok, capability} =
             UpstreamWebsocketSession.reserve_compaction(
               owner,
               :compact,
               binding,
               make_ref(),
               now_ms()
             )

    {binding, capability}
  end

  defp direct_options(owner, binding, capability) do
    lifecycle = Map.take(binding, [:lifecycle_id, :generation])

    RequestOptions.for_websocket(%{})
    |> RequestOptions.put_native_compaction_admission(capability, {:direct, owner}, lifecycle)
  end

  defp with_replacement(fun, delayed_action \\ nil) do
    instance = Atom.to_string(node())
    lease = Ecto.UUID.generate()
    session_id = "native-resume-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, owner} =
      WebsocketOwnerSession.start_owner(
        codex_session_id: session_id,
        owner_instance_id: instance,
        owner_lease_token: lease
      )

    old_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    current_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    try do
      {:ok, old} =
        WebsocketOwnerSession.attach_downstream(owner, %{
          pid: old_pid,
          correlation_id: Ecto.UUID.generate()
        })

      {old_binding, old_capability} = reserve_forwarded(owner, old, instance, lease)

      pending =
        if delayed_action do
          stale = stale_control(delayed_action, old, {old_binding, old_capability})
          delayed_call(fn -> WebsocketOwnerSession.admission_control(owner, stale) end)
        else
          {old_binding, old_capability}
        end

      assert :ok = WebsocketOwnerSession.detach_downstream(owner, old)

      {:ok, current} =
        WebsocketOwnerSession.attach_downstream(owner, %{
          pid: current_pid,
          correlation_id: Ecto.UUID.generate()
        })

      {binding, capability} = reserve_forwarded(owner, current, instance, lease)
      assert current.epoch > old.epoch
      assert binding.lifecycle_id == old_binding.lifecycle_id

      fun.(owner, old, current, pending, binding, capability)
    after
      stop_process(owner)
      stop_downstream(old_pid)
      stop_downstream(current_pid)
    end
  end

  defp reserve_forwarded(owner, downstream, instance, lease) do
    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ordinary_fixture", "status" => "completed"}
      })

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([frame]))

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: ~s({"model":"sample-model"}),
      request_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      effective_serving_mode: "full",
      timeouts: %{connect_timeout_ms: 5000, receive_timeout_ms: 5000},
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }

    result =
      try do
        {:ok, result} = WebsocketOwnerSession.submit_request(owner, downstream, request)
        result
      after
        FakeUpstream.stop(upstream)
      end

    receipt = result.ordinary_success_result
    topology = Control.forwarded_topology(instance, lease, downstream.epoch)

    binding = %{
      binding(receipt.lifecycle.lifecycle_id, receipt.lifecycle.generation, topology)
      | previous_response_digest: receipt.response_digest
    }

    assert {:ok, _pending} =
             WebsocketOwnerSession.admission_control(
               owner,
               control(:record_ordinary_success, downstream,
                 binding: binding,
                 first_compact_collection: receipt,
                 expires_at_ms: now_ms() + 30_000
               )
             )

    assert {:ok, capability} =
             WebsocketOwnerSession.admission_control(
               owner,
               control(:reserve, downstream,
                 binding: binding,
                 phase: :compact,
                 control_ref: make_ref(),
                 now_ms: now_ms()
               )
             )

    {binding, capability}
  end

  defp stale_control(:snapshot, downstream, _old), do: control(:snapshot, downstream)

  defp stale_control(:mark_accounting_started, downstream, {_binding, capability}),
    do: control(:mark_accounting_started, downstream, capability: capability, now_ms: now_ms())

  defp stale_control(:finalization_ack, downstream, {binding, capability}) do
    digest = :crypto.hash(:sha256, "synthetic-compaction")

    confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: capability.control_ref,
      binding: %{binding | compaction_item_digest: digest}
    }

    control(:finalization_ack, downstream,
      success?: true,
      compaction_item_digest: digest,
      confirmation: confirmation,
      expires_at_ms: now_ms() + 30_000
    )
  end

  defp control(action, downstream, attrs \\ []) do
    {:ok, control} =
      Control.new(
        Map.merge(
          Map.merge(Map.from_struct(struct(Control)), %{
            version: 1,
            action: action,
            downstream: Map.take(downstream, [:pid, :epoch, :correlation_id])
          }),
          Map.new(attrs)
        )
      )

    control
  end

  defp binding(lifecycle_id, generation, topology) do
    %Binding{
      semantic_turn_key: :crypto.hash(:sha256, Ecto.UUID.generate()),
      window_digest: :crypto.hash(:sha256, Ecto.UUID.generate()),
      context_digest: :crypto.hash(:sha256, Ecto.UUID.generate()),
      window_number: 1,
      serving_mode: :full,
      topology: topology,
      lifecycle_id: lifecycle_id,
      generation: generation
    }
  end

  defp delayed_call(fun) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        send(parent, {:delayed_control_ready, ref})

        receive do
          {:release_control, ^ref} -> fun.()
        after
          @detection_timeout_ms -> raise "control barrier was not released"
        end
      end)

    assert_receive {:delayed_control_ready, ^ref}, @detection_timeout_ms
    {task, ref}
  end

  defp release_call({task, ref}) do
    send(task.pid, {:release_control, ref})
    Task.await(task, @detection_timeout_ms)
  end

  defp owner_phase(owner) do
    case :sys.get_state(owner).native_compaction_admission do
      nil -> :cleared
      admission -> admission.phase
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, @detection_timeout_ms)
  end

  defp stop_downstream(pid) do
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @detection_timeout_ms
  end

  defp now_ms, do: System.system_time(:millisecond)
end
