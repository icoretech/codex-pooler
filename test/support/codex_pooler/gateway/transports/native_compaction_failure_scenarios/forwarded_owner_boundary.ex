defmodule CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.ForwardedOwnerBoundary do
  @moduledoc false

  import ExUnit.Assertions

  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.AccountingLifecycle
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Context
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Observed
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.RuntimeBoundary
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  @detection_timeout_ms 15_000
  @post_accounting_variants [
    :caller_death_after_accounting,
    :socket_disconnect,
    :owner_timeout,
    :owner_crash,
    :owner_drain,
    :handoff_absolute_timeout
  ]

  @type variant ::
          :caller_death_after_accounting
          | :socket_disconnect
          | :owner_timeout
          | :owner_crash
          | :owner_drain
          | :pending_handoff
          | :handoff_soft_timeout
          | :handoff_absolute_timeout
          | :stale_lease
          | :stale_epoch
          | :stale_control

  @spec run(variant(), Context.t()) :: Observed.t()
  for variant <- @post_accounting_variants do
    def run(unquote(variant), %Context{} = context),
      do: run_post_accounting(unquote(variant), context)
  end

  defp run_post_accounting(variant, context) do
    accounting = RuntimeBoundary.open_accounted_lifecycle!(context, variant)
    observed = execute(variant, context, accounting)
    lifecycle = RuntimeBoundary.settle_accounted_lifecycle!(accounting, variant)
    %{observed | accounting_lifecycle: lifecycle}
  end

  for variant <- [
        :pending_handoff,
        :handoff_soft_timeout,
        :stale_lease,
        :stale_epoch,
        :stale_control
      ] do
    def run(unquote(variant), %Context{} = context),
      do: run_zero_accounting(unquote(variant), context)
  end

  defp run_zero_accounting(variant, context) do
    observed = execute(variant, context, nil)
    correlation = RuntimeBoundary.empty_accounting_handle(context, variant)
    %{observed | accounting_lifecycle: RuntimeBoundary.observe_accounting!(correlation)}
  end

  defp execute(:caller_death_after_accounting, context, _accounting) do
    fixture = start_accounted_owner(context, :caller_death_after_accounting)
    submitter = blocking_submitter(fixture)
    block_ref = fixture.block_ref
    assert_receive {:forwarded_provider_send_blocked, worker, ^block_ref}, @detection_timeout_ms
    submitter_monitor = Process.monitor(submitter)
    Process.exit(submitter, :shutdown)
    assert_down(submitter_monitor, submitter)
    assert_down(Process.monitor(worker), worker)
    observe_survivor(fixture)
  end

  defp execute(:socket_disconnect, context, _accounting) do
    fixture = start_accounted_owner(context, :socket_disconnect)
    downstream_monitor = Process.monitor(fixture.downstream_pid)
    Process.exit(fixture.downstream_pid, :shutdown)
    assert_down(downstream_monitor, fixture.downstream_pid)
    assert %{active_turn: nil, native_compaction_admission: nil} = await_cleared(fixture.owner)
    observe_survivor(fixture)
  end

  defp execute(:owner_timeout, context, accounting) do
    remote_node = :"codex_pooler@forwarded-provider-timeout.example"
    session = accounting.resource.session
    remote_owner_instance_id = Atom.to_string(remote_node)

    fixture =
      start_accounted_owner(context, :owner_timeout,
        codex_session_id: session.id,
        owner_instance_id: remote_owner_instance_id,
        owner_lease_token: session.owner_lease_token
      )

    release_ref = make_ref()

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:delayed_success, context.test_pid, release_ref}}
      )

    assert {:error, :owner_forward_timeout} =
             WebsocketOwnerForwarder.submit_frame(
               %{session | owner_instance_id: remote_owner_instance_id},
               fixture.owner_lease_token,
               fixture.downstream,
               "forwarded-provider-timeout",
               Keyword.put(opts, :timeout, 25)
             )

    assert_receive {:websocket_owner_harness_delayed_started, delayed_pid, ^release_ref},
                   @detection_timeout_ms

    assert :ok =
             WebsocketOwnerForwarder.remote_cancel_downstream(
               session.id,
               fixture.downstream
             )

    assert %{active_turn: nil, native_compaction_admission: nil} = await_cleared(fixture.owner)
    send(delayed_pid, {:websocket_owner_harness_release_delayed, release_ref})

    assert_receive {:websocket_owner_harness_delayed_result, ^release_ref,
                    {:error, :stale_downstream}},
                   @detection_timeout_ms

    assert {:ok, _status} = WebsocketOwnerSession.owner_status(fixture.owner)
    observe_survivor(fixture)
  end

  defp execute(:owner_crash, context, _accounting) do
    fixture = start_accounted_owner(context, :owner_crash)
    owner_monitor = Process.monitor(fixture.owner)
    Process.exit(fixture.upstream_pid, :shutdown)
    assert_down(owner_monitor, fixture.owner)
    observe_retired(fixture)
  end

  defp execute(:owner_drain, context, _accounting) do
    fixture = start_accounted_owner(context, :owner_drain)
    owner_monitor = Process.monitor(fixture.owner)
    assert :ok = WebsocketOwnerSession.drain_owner(fixture.owner)
    assert_down(owner_monitor, fixture.owner)
    observe_retired(fixture)
  end

  defp execute(:pending_handoff, context, _accounting) do
    fixture = start_waiting_handoff(context, :pending_handoff)
    assert :ok = WebsocketOwnerSession.detach_downstream(fixture.owner, fixture.replacement)

    assert %{pending_handoff: nil, native_compaction_admission: nil} =
             await_handoff_cleared(fixture.owner)

    observe_survivor(fixture)
  end

  defp execute(:handoff_soft_timeout, context, _accounting) do
    fixture = start_waiting_handoff(context, :handoff_soft_timeout)
    pending = fixture.pending

    send(
      fixture.owner,
      {:websocket_owner_handoff_soft_timeout, pending.control_ref, pending.soft_token}
    )

    assert %{native_compaction_admission: nil} = await_admission_cleared(fixture.owner)
    observe_survivor(fixture)
  end

  defp execute(:handoff_absolute_timeout, context, _accounting) do
    fixture = start_waiting_handoff(context, :handoff_absolute_timeout)
    pending = fixture.pending
    owner_monitor = Process.monitor(fixture.owner)

    send(
      fixture.owner,
      {:websocket_owner_handoff_absolute_timeout, pending.control_ref, pending.absolute_token}
    )

    assert_down(owner_monitor, fixture.owner)
    observe_retired(fixture)
  end

  defp execute(:stale_lease, context, _accounting) do
    fixture =
      start_reserved_owner(context, :stale_lease,
        persistence: WebsocketOwnerNodeHarness.fake_persistence_boundary()
      )

    owner_monitor = Process.monitor(fixture.owner)
    send(fixture.owner, :renew_owner_lease)
    assert_down(owner_monitor, fixture.owner)
    observe_retired(fixture)
  end

  defp execute(:stale_epoch, context, _accounting) do
    fixture = start_reserved_owner(context, :stale_epoch)
    stale_downstream_monitor = Process.monitor(fixture.downstream_pid)
    Process.exit(fixture.downstream_pid, :shutdown)
    assert_down(stale_downstream_monitor, fixture.downstream_pid)

    assert %{downstream: nil, native_compaction_admission: nil} =
             await_downstream_cleared(fixture.owner)

    current_pid = downstream_process()

    {:ok, current} =
      WebsocketOwnerSession.attach_downstream(
        fixture.owner,
        downstream_target(context, :stale_epoch_current, current_pid)
      )

    assert current.epoch > 0
    assert current.pid == current_pid
    assert {:error, :stale_downstream} = snapshot(fixture.owner, fixture.downstream)
    assert %{native_compaction_admission: nil} = await_admission_cleared(fixture.owner)
    observe_survivor(%{fixture | downstream_pid: current_pid})
  end

  defp execute(:stale_control, context, _accounting) do
    fixture = start_waiting_handoff(context, :stale_control)
    pending = fixture.pending
    send(fixture.owner, {:websocket_owner_handoff_soft_timeout, pending.control_ref, make_ref()})

    send(
      fixture.owner,
      {:websocket_owner_handoff_absolute_timeout, pending.control_ref, make_ref()}
    )

    assert %{pending_handoff: %{status: :waiting}} = :sys.get_state(fixture.owner)
    assert :ok = WebsocketOwnerSession.detach_downstream(fixture.owner, fixture.replacement)

    assert %{pending_handoff: nil, native_compaction_admission: nil} =
             await_handoff_cleared(fixture.owner)

    observe_survivor(fixture)
  end

  defp start_accounted_owner(context, variant, opts \\ []) do
    fixture = start_reserved_owner(context, variant, opts)
    now = System.system_time(:millisecond)

    assert {:ok, _accounted} =
             WebsocketOwnerSession.admission_control(
               fixture.owner,
               control(:mark_accounting_started, fixture.downstream,
                 capability: fixture.capability,
                 now_ms: now
               )
             )

    fixture
  end

  defp start_reserved_owner(context, variant, opts \\ []) do
    block_ref = make_ref()
    send_receipt_ref = make_ref()
    parent = context.test_pid
    retain_cancelled_worker? = Keyword.get(opts, :retain_cancelled_worker, false)

    upstream = %{
      start: fn -> Agent.start_link(fn -> [] end) end,
      send: fn upstream_pid, payload, _writer ->
        if retain_cancelled_worker?, do: Process.flag(:trap_exit, true)
        send(parent, {:forwarded_provider_send_blocked, self(), block_ref})

        receive do
          {:forwarded_provider_release_send, ^block_ref} ->
            Agent.update(upstream_pid, &[payload | &1])
            send(parent, {:forwarded_provider_upstream_sent, send_receipt_ref})
            :ok

          {:EXIT, _from, :shutdown} when retain_cancelled_worker? ->
            receive do
              {:forwarded_provider_release_cancelled_worker, ^block_ref} -> :ok
            end
        after
          @detection_timeout_ms -> {:error, :owner_forward_timeout}
        end
      end,
      invalidate: fn _pid -> :ok end,
      close: fn pid -> if Process.alive?(pid), do: Agent.stop(pid) end
    }

    codex_session_id = Keyword.get(opts, :codex_session_id, scenario_id(context, variant))

    owner_lease_token =
      Keyword.get(opts, :owner_lease_token, "owner-lease-#{context.scenario_namespace}")

    owner_instance_id = Keyword.get(opts, :owner_instance_id, Atom.to_string(node()))

    owner_opts =
      opts
      |> Keyword.drop([
        :codex_session_id,
        :owner_lease_token,
        :owner_instance_id,
        :retain_cancelled_worker
      ])
      |> Keyword.merge(
        codex_session_id: codex_session_id,
        owner_lease_token: owner_lease_token,
        owner_instance_id: owner_instance_id,
        upstream: upstream,
        handoff_soft_timeout_ms: 30_000,
        handoff_absolute_timeout_ms: 60_000
      )

    {:ok, owner} = WebsocketOwnerSession.start_owner(owner_opts)
    %{upstream_pid: upstream_pid} = :sys.get_state(owner)
    downstream_pid = downstream_process()

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: downstream_pid,
        correlation_id: "#{context.scenario_namespace}-#{variant}"
      })

    binding = forwarded_binding(owner_instance_id, owner_lease_token, downstream)
    now = System.system_time(:millisecond)

    assert {:ok, _pending} =
             WebsocketOwnerSession.admission_control(
               owner,
               control(:record_ordinary_success, downstream,
                 binding: binding,
                 expires_at_ms: now + 30_000
               )
             )

    assert {:ok, capability} =
             WebsocketOwnerSession.admission_control(
               owner,
               control(:reserve, downstream,
                 binding: binding,
                 phase: :compact,
                 control_ref: make_ref(),
                 now_ms: now
               )
             )

    %{
      block_ref: block_ref,
      binding: binding,
      capability: capability,
      codex_session_id: codex_session_id,
      context: context,
      downstream: downstream,
      downstream_pid: downstream_pid,
      owner: owner,
      owner_instance_id: owner_instance_id,
      owner_lease_token: owner_lease_token,
      send_receipt_ref: send_receipt_ref,
      upstream_pid: upstream_pid
    }
  end

  defp start_waiting_handoff(context, variant) do
    fixture = start_reserved_owner(context, variant, retain_cancelled_worker: true)
    submitter = blocking_submitter(fixture)
    block_ref = fixture.block_ref
    assert_receive {:forwarded_provider_send_blocked, worker, ^block_ref}, @detection_timeout_ms
    assert :ok = WebsocketOwnerSession.detach_downstream(fixture.owner, fixture.downstream)
    replacement_pid = downstream_process()

    {:ok, replacement} =
      WebsocketOwnerSession.attach_downstream(
        fixture.owner,
        %{pid: replacement_pid, correlation_id: "#{context.scenario_namespace}-replacement"}
      )

    control_ref = make_ref()

    assert {:ok, :replacement_handoff, ^control_ref} =
             WebsocketOwnerSession.preflight_reconnect(
               fixture.owner,
               replacement,
               :crypto.hash(:sha256, context.scenario_namespace),
               control_ref
             )

    %{pending_handoff: pending} = :sys.get_state(fixture.owner)

    Map.merge(fixture, %{
      pending: pending,
      replacement: replacement,
      replacement_pid: replacement_pid,
      submitter: submitter,
      worker: worker
    })
  end

  defp blocking_submitter(fixture) do
    spawn(fn ->
      result =
        WebsocketOwnerSession.submit_request(
          fixture.owner,
          fixture.downstream,
          native_request(fixture.context.scenario_namespace)
        )

      send(fixture.context.test_pid, {:forwarded_provider_submitter_result, self(), result})

      receive do
        :forwarded_provider_release_submitter -> :ok
      end
    end)
  end

  defp native_request(turn_id) do
    %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: Jason.encode!(%{"type" => "response.create", "turn_id" => turn_id}),
      timeouts: %{},
      writer: fn _frame -> :ok end,
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }
  end

  defp observe_survivor(fixture) do
    owner_monitor = Process.monitor(fixture.owner)
    assert {:ok, _status} = WebsocketOwnerSession.owner_status(fixture.owner)

    receive do
      {:DOWN, ^owner_monitor, :process, _pid, reason} ->
        flunk("owner retired before cleanup: #{inspect(reason)}")
    after
      0 -> :ok
    end

    observed = observed(fixture, phase(fixture.owner), :survived)
    Process.demonitor(owner_monitor, [:flush])
    cleanup(fixture)
    observed
  end

  defp observe_retired(fixture) do
    observed = observed(fixture, :destroyed_with_owner, :retired)
    cleanup(fixture)
    observed
  end

  defp observed(fixture, admission_phase, owner_fate) do
    %Observed{
      admission_phase: admission_phase,
      upstream_send_count: drain_send_receipts(fixture.send_receipt_ref),
      accounting_lifecycle: zero_lifecycle(),
      owner_fate: owner_fate,
      metadata: %{observation_sources: "monitor,repo,owner,upstream"}
    }
  end

  defp drain_send_receipts(send_receipt_ref, count \\ 0) do
    receive do
      {:forwarded_provider_upstream_sent, ^send_receipt_ref} ->
        drain_send_receipts(send_receipt_ref, count + 1)
    after
      0 -> count
    end
  end

  defp phase(owner) do
    case :sys.get_state(owner).native_compaction_admission do
      nil -> :cleared
      admission -> NativeCompactionAdmission.phase(admission)
    end
  end

  defp snapshot(owner, downstream),
    do: WebsocketOwnerSession.admission_control(owner, control(:snapshot, downstream, []))

  defp cleanup(fixture) do
    if is_pid(fixture[:worker]) and Process.alive?(fixture.worker) do
      send(
        fixture.worker,
        {:forwarded_provider_release_cancelled_worker, fixture.block_ref}
      )
    end

    if Process.alive?(fixture.owner) do
      monitor = Process.monitor(fixture.owner)
      _ = GenServer.stop(fixture.owner, :normal, @detection_timeout_ms)
      assert_down(monitor, fixture.owner)
    end

    Enum.each(
      [
        fixture[:downstream_pid],
        fixture[:replacement_pid],
        fixture[:submitter],
        fixture[:worker]
      ],
      fn
        pid when is_pid(pid) -> if Process.alive?(pid), do: Process.exit(pid, :kill)
        _other -> :ok
      end
    )
  end

  defp await_cleared(owner),
    do: await_state(owner, &(is_nil(&1.active_turn) and is_nil(&1.native_compaction_admission)))

  defp await_handoff_cleared(owner),
    do:
      await_state(owner, &(is_nil(&1.pending_handoff) and is_nil(&1.native_compaction_admission)))

  defp await_downstream_cleared(owner),
    do: await_state(owner, &(is_nil(&1.downstream) and is_nil(&1.native_compaction_admission)))

  defp await_admission_cleared(owner),
    do: await_state(owner, &is_nil(&1.native_compaction_admission))

  defp await_state(owner, predicate, attempts \\ 1_000)

  defp await_state(owner, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(owner)

    if predicate.(state) do
      state
    else
      :erlang.yield()
      await_state(owner, predicate, attempts - 1)
    end
  end

  defp await_state(owner, _predicate, 0), do: :sys.get_state(owner)

  defp assert_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @detection_timeout_ms -> flunk("process did not retire")
    end
  end

  defp downstream_process do
    spawn(fn -> receive_loop() end)
  end

  defp receive_loop do
    receive do
      _message -> receive_loop()
    end
  end

  defp downstream_target(context, variant, pid),
    do: %{pid: pid, correlation_id: "#{context.scenario_namespace}-#{variant}"}

  defp scenario_id(context, variant), do: "#{context.scenario_namespace}-#{variant}"

  defp forwarded_binding(owner_instance_id, owner_lease_token, downstream) do
    %NativeCompactionAdmission.Binding{
      semantic_turn_key: :crypto.hash(:sha256, "semantic"),
      window_digest: :crypto.hash(:sha256, "window"),
      context_digest: :crypto.hash(:sha256, "context"),
      window_number: 1,
      previous_response_digest: nil,
      serving_mode: :full,
      topology:
        WebsocketOwnerAdmissionControlV1.forwarded_topology(
          owner_instance_id,
          owner_lease_token,
          downstream.epoch
        ),
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }
  end

  defp control(action, downstream, attrs) do
    defaults = %{
      version: 1,
      action: action,
      downstream: Map.take(downstream, [:pid, :epoch, :correlation_id]),
      binding: nil,
      phase: nil,
      control_ref: nil,
      capability: nil,
      disposition: nil,
      success?: nil,
      compaction_item_digest: nil,
      confirmation: nil,
      first_compact_collection: nil,
      expires_at_ms: nil,
      now_ms: nil
    }

    {:ok, control} =
      defaults |> Map.merge(Map.new(attrs)) |> WebsocketOwnerAdmissionControlV1.new()

    control
  end

  defp zero_lifecycle do
    %AccountingLifecycle{requests: 0, attempts: 0, turns: 0, reservations: 0, settlements: 0}
  end
end
