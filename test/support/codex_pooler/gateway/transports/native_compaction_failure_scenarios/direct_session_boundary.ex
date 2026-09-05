defmodule CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.DirectSessionBoundary do
  @moduledoc false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.AccountingLifecycle
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Context
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Observed
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.RuntimeBoundary
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Confirmation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request

  @detection_timeout_ms 15_000
  @post_accounting_variants [
    :caller_death_after_send,
    :stale_token,
    :reconnect_before_send,
    :generation_replacement_before_send,
    :send_failure,
    :terminal_failure,
    :finalization_failure,
    :compact_collection,
    :compact_ack_success,
    :compact_ack_failure,
    :final_success,
    :final_failure
  ]

  @type variant :: atom()

  @spec run(variant(), Context.t()) :: Observed.t()
  def run(:pre_commit_cancellation, %Context{} = context) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      baseline = FakeUpstream.count(upstream)
      capability = reserve!(session, :compact, binding)
      :ok = UpstreamWebsocketSession.cancel_compaction_reservation(session, capability, now_ms())
      observe(session, upstream, baseline, zero_accounting(), %{boundary: :pre_accounting_cancel})
    end)
  end

  for variant <- @post_accounting_variants do
    def run(unquote(variant), %Context{} = context),
      do: run_post_accounting(unquote(variant), context)
  end

  defp run_post_accounting(variant, context) do
    handle = RuntimeBoundary.open_accounted_lifecycle!(Map.from_struct(context), variant)

    observed = run_post_accounting_variant(variant, context, handle)

    RuntimeBoundary.settle_accounted_lifecycle!(handle, variant)
    %{observed | accounting_lifecycle: RuntimeBoundary.observe_accounting!(handle)}
  end

  defp run_post_accounting_variant(:caller_death_after_send, context, handle),
    do: caller_death_after_send(context, handle)

  defp run_post_accounting_variant(:stale_token, context, handle),
    do: stale_token(context, handle)

  defp run_post_accounting_variant(:reconnect_before_send, context, handle),
    do: reconnect_before_send(context, handle)

  defp run_post_accounting_variant(:generation_replacement_before_send, context, handle),
    do: generation_replacement_before_send(context, handle)

  defp run_post_accounting_variant(:send_failure, context, handle),
    do: send_failure(context, handle)

  defp run_post_accounting_variant(:terminal_failure, context, handle),
    do: terminal_failure(context, handle)

  defp run_post_accounting_variant(:finalization_failure, context, handle),
    do: finalization_failure(context, handle)

  defp run_post_accounting_variant(:compact_collection, context, handle),
    do: compact_collection(context, handle)

  defp run_post_accounting_variant(:compact_ack_success, context, handle),
    do: compact_ack_success(context, handle)

  defp run_post_accounting_variant(:compact_ack_failure, context, handle),
    do: compact_ack_failure(context, handle)

  defp run_post_accounting_variant(:final_success, context, handle),
    do: final_response(context, handle, :success)

  defp run_post_accounting_variant(:final_failure, context, handle),
    do: final_response(context, handle, :failure)

  defp caller_death_after_send(context, _handle) do
    release_ref = make_ref()

    mode =
      {:sequence,
       [
         success_mode(),
         FakeUpstream.websocket_terminal_then_close_barrier(completed_frame(),
           notify: context.test_pid,
           release_ref: release_ref
         )
       ]}

    with_session(context, mode, fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)

      task =
        Task.async(fn ->
          UpstreamWebsocketSession.request(session, request(upstream, capability, binding))
        end)

      barrier_pid =
        receive do
          {:fake_upstream_websocket_barrier, :before_terminal, pid, ^release_ref} -> pid
        after
          @detection_timeout_ms -> raise "direct provider caller-death barrier timed out"
        end

      nil = Task.shutdown(task, :brutal_kill)
      send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

      close_barrier_pid =
        receive do
          {:fake_upstream_websocket_barrier, :before_close, pid, ^release_ref} -> pid
        after
          @detection_timeout_ms -> raise "direct provider caller-death close barrier timed out"
        end

      send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})
      _ = :sys.get_state(session)

      observe(session, upstream, baseline, zero_accounting(), %{
        boundary: :caller_down_after_peer_receipt
      })
    end)
  end

  defp stale_token(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      stale = Capability.replace_token(capability, :crypto.strong_rand_bytes(32))
      baseline = FakeUpstream.count(upstream)

      {:error, %{reason: :native_compaction_capability_rejected}} =
        UpstreamWebsocketSession.request(session, request(upstream, stale, binding))

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :capability_token})
    end)
  end

  defp reconnect_before_send(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      _capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)
      :ok = UpstreamWebsocketSession.invalidate_connection(session)

      observe(session, upstream, baseline, zero_accounting(), %{
        boundary: :connection_invalidation
      })
    end)
  end

  defp generation_replacement_before_send(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)
      :ok = UpstreamWebsocketSession.invalidate_connection(session)
      {:ok, _result} = UpstreamWebsocketSession.request(session, request(upstream))
      replacement = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)

      {:error, %{reason: :native_compaction_capability_rejected}} =
        UpstreamWebsocketSession.request(session, request(upstream, capability, replacement))

      observe(session, upstream, baseline + 1, zero_accounting(), %{
        boundary: :generation_replacement
      })
    end)
  end

  defp send_failure(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)
      :ok = FakeUpstream.close_websocket_connections(upstream)
      _ = :sys.get_state(session)

      {:error, _failure} =
        UpstreamWebsocketSession.request(session, request(upstream, capability, binding))

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :websocket_payload_send})
    end)
  end

  defp terminal_failure(context, _handle) do
    with_session(context, {:sequence, [success_mode(), terminal_failure_mode()]}, fn session,
                                                                                     upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)

      {:ok, %{terminal: "response.failed"}} =
        UpstreamWebsocketSession.request(session, request(upstream, capability, binding))

      :ok = UpstreamWebsocketSession.acknowledge_compact_finalization(session, :failure)

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :provider_terminal})
    end)
  end

  defp finalization_failure(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)

      {:ok, _result} =
        UpstreamWebsocketSession.request(session, request(upstream, capability, binding))

      :ok = UpstreamWebsocketSession.acknowledge_compact_finalization(session, :failure)

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :compact_finalization})
    end)
  end

  defp compact_collection(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      capability = reserve_accounted!(session, :compact, binding)
      baseline = FakeUpstream.count(upstream)

      {:ok, _result} =
        UpstreamWebsocketSession.request(session, request(upstream, capability, binding))

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :compact_collection})
    end)
  end

  defp compact_ack_success(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      {binding, capability, baseline} = collect_compact!(session, upstream)
      acknowledge_compact!(session, binding, capability)

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :compact_ack})
    end)
  end

  defp compact_ack_failure(context, _handle) do
    with_session(context, success_mode(), fn session, upstream ->
      {_binding, _capability, baseline} = collect_compact!(session, upstream)
      :ok = UpstreamWebsocketSession.acknowledge_compact_finalization(session, :failure)

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :compact_ack})
    end)
  end

  defp final_response(context, _handle, outcome) do
    final_mode = if outcome == :success, do: success_mode(), else: terminal_failure_mode()
    mode = {:sequence, [success_mode(), success_mode(), final_mode]}

    with_session(context, mode, fn session, upstream ->
      binding = arm_direct_after_warmup!(session, upstream)
      compact_capability = reserve_accounted!(session, :compact, binding)

      {:ok, _result} =
        UpstreamWebsocketSession.request(session, request(upstream, compact_capability, binding))

      digest = acknowledge_compact!(session, binding, compact_capability)
      final_binding = final_binding(binding, digest)
      final_capability = reserve_accounted!(session, :final, final_binding)
      baseline = FakeUpstream.count(upstream)

      {:ok, _result} =
        UpstreamWebsocketSession.request(session, request(upstream, final_capability, binding))

      :ok = UpstreamWebsocketSession.acknowledge_final_response(session, outcome)

      observe(session, upstream, baseline, zero_accounting(), %{boundary: :final_response})
    end)
  end

  defp with_session(_context, mode, fun) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    monitor = Process.monitor(session)

    try do
      fun.(session, upstream)
    after
      cleanup_session(session, monitor)
      FakeUpstream.stop(upstream)
    end
  end

  defp arm_direct_after_warmup!(session, upstream) do
    {:ok, %{terminal: "response.completed", ordinary_success_result: receipt}} =
      UpstreamWebsocketSession.request(session, request(upstream))

    arm_direct!(session, receipt)
  end

  defp arm_direct!(session, receipt) do
    binding =
      session
      |> UpstreamWebsocketSession.connection_lifecycle_snapshot()
      |> direct_admission_binding()
      |> Map.put(:previous_response_digest, receipt.response_digest)

    :ok = UpstreamWebsocketSession.arm_compact(session, binding, now_ms() + 30_000, receipt)
    binding
  end

  defp collect_compact!(session, upstream) do
    binding = arm_direct_after_warmup!(session, upstream)
    capability = reserve_accounted!(session, :compact, binding)
    baseline = FakeUpstream.count(upstream)

    {:ok, _result} =
      UpstreamWebsocketSession.request(session, request(upstream, capability, binding))

    {binding, capability, baseline}
  end

  defp acknowledge_compact!(session, binding, capability) do
    digest = :crypto.hash(:sha256, "synthetic-compaction-item")

    confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: capability.control_ref,
      binding: %{binding | compaction_item_digest: digest}
    }

    :ok =
      UpstreamWebsocketSession.acknowledge_compact_finalization(
        session,
        {:success, digest, confirmation, now_ms() + 30_000}
      )

    digest
  end

  defp reserve_accounted!(session, phase, binding) do
    capability = reserve!(session, phase, binding)

    :ok =
      UpstreamWebsocketSession.mark_compaction_accounting_started(session, capability, now_ms())

    capability
  end

  defp reserve!(session, phase, binding) do
    {:ok, capability} =
      UpstreamWebsocketSession.reserve_compaction(session, phase, binding, make_ref(), now_ms())

    capability
  end

  defp request(upstream, capability \\ nil, lifecycle_or_binding \\ nil) do
    lifecycle =
      case lifecycle_or_binding do
        %Binding{} = binding ->
          %{lifecycle_id: binding.lifecycle_id, generation: binding.generation}

        %{lifecycle_id: _, generation: _} = snapshot ->
          snapshot

        nil ->
          nil
      end

    %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: Jason.encode!(%{"model" => "gpt-test"}),
      request_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      effective_serving_mode: "full",
      timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
      writer: fn _frame -> :ok end,
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1,
      native_compaction_capability: capability,
      expected_connection_lifecycle: lifecycle
    }
  end

  defp observe(session, upstream, baseline, accounting, metadata) do
    phase = UpstreamWebsocketSession.compaction_admission_phase(session)
    owner_fate = owner_fate(session)

    %Observed{
      admission_phase: phase,
      upstream_send_count: FakeUpstream.count(upstream) - baseline,
      accounting_lifecycle: accounting,
      owner_fate: owner_fate,
      metadata: Map.merge(%{sources: "session,upstream,repo,monitor"}, metadata)
    }
  end

  defp owner_fate(session) do
    monitor = Process.monitor(session)

    case UpstreamWebsocketSession.connection_lifecycle_snapshot(session) do
      %{generation: generation} when is_integer(generation) ->
        Process.demonitor(monitor, [:flush])
        :survived

      _unavailable ->
        receive do
          {:DOWN, ^monitor, :process, ^session, _reason} -> :retired
        after
          0 ->
            Process.demonitor(monitor, [:flush])
            :retired
        end
    end
  end

  defp cleanup_session(session, monitor) do
    if Process.alive?(session), do: UpstreamWebsocketSession.close(session)

    receive do
      {:DOWN, ^monitor, :process, ^session, _reason} -> :ok
    after
      @detection_timeout_ms -> raise "direct provider session cleanup timed out"
    end
  end

  defp direct_admission_binding(%{lifecycle_id: lifecycle_id, generation: generation}) do
    %Binding{
      semantic_turn_key: :crypto.hash(:sha256, "semantic-turn"),
      window_digest: :crypto.hash(:sha256, "window"),
      context_digest: :crypto.hash(:sha256, "context"),
      window_number: 1,
      previous_response_digest: nil,
      serving_mode: :full,
      topology: %Direct{},
      lifecycle_id: lifecycle_id,
      generation: generation
    }
  end

  defp final_binding(binding, digest) do
    %{
      binding
      | window_digest: :crypto.hash(:sha256, "next-window"),
        context_digest: :crypto.hash(:sha256, "next-context"),
        window_number: binding.window_number + 1,
        compaction_item_digest: digest
    }
  end

  defp success_mode do
    FakeUpstream.websocket_text_frames([completed_frame()])
  end

  defp terminal_failure_mode do
    FakeUpstream.websocket_text_frames([
      Jason.encode!(%{
        "type" => "response.failed",
        "response" => %{"status" => "failed", "error" => %{"code" => "server_error"}}
      })
    ])
  end

  defp completed_frame do
    Jason.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => "resp_direct_boundary", "status" => "completed"}
    })
  end

  defp zero_accounting do
    %AccountingLifecycle{requests: 0, attempts: 0, turns: 0, reservations: 0, settlements: 0}
  end

  defp now_ms, do: System.system_time(:millisecond)
end
