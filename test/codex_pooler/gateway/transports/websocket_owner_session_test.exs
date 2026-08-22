defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSessionTest do
  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPoolerWeb.CodexResponsesSocket

  defmodule RetiringRegisteredOwner do
    use GenServer

    def start_link(context, parent) do
      GenServer.start_link(__MODULE__, {context, parent})
    end

    @impl GenServer
    def init({context, parent}) do
      {:ok, _owner} =
        Registry.register(WebsocketOwnerSession.Registry, context.codex_session_id, nil)

      send(parent, {:retiring_registered_owner_ready, self()})
      {:ok, context}
    end

    @impl GenServer
    def handle_call(:owner_status, _from, context) do
      {:stop, :normal,
       {:ok,
        %{
          codex_session_id: context.codex_session_id,
          owner_lease_token: context.owner_lease_token,
          owner_instance_id: context.owner_instance_id,
          upstream_alive?: false,
          draining?: false,
          active_turn?: false
        }}, context}
    end
  end

  @pending_terminal_observation_timeout_ms 5_000
  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"

  setup do
    codex_session_id = "codex-session-#{System.unique_integer([:positive])}"

    on_exit(fn -> cleanup_owner_session(codex_session_id) end)

    {:ok,
     codex_session_id: codex_session_id,
     owner_lease_token: "owner-token-#{System.unique_integer([:positive])}",
     owner_instance_id: Atom.to_string(node())}
  end

  test "starts one local registered owner per codex_session_id", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert {:ok, ^owner, :existing} = start_owner(context, upstream: upstream)
    refute_receive {:websocket_owner_harness_upstream_started, _second_upstream}

    assert WebsocketOwnerSession.lookup(context.codex_session_id) == {:ok, owner}
    assert Process.alive?(upstream_pid)

    owner_monitor = Process.monitor(owner)
    :ok = GenServer.stop(owner)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
    assert await_owner_unavailable(context.codex_session_id) == {:error, :owner_unavailable}

    assert {:ok, fresh_owner} = await_fresh_owner(context, upstream, owner)
    assert fresh_owner != owner
    assert_receive {:websocket_owner_harness_upstream_started, fresh_upstream_pid}
    assert fresh_upstream_pid != upstream_pid
  end

  test "replaces a stale registered owner that retires after reporting its status", context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    on_exit(fn -> cleanup_owner_session(context.codex_session_id) end)
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    persistence = owner_exit_persistence_spy(self(), context)

    {:ok, stale_owner} = RetiringRegisteredOwner.start_link(context, self())
    assert_receive {:retiring_registered_owner_ready, ^stale_owner}
    stale_owner_ref = Process.monitor(stale_owner)

    assert {:ok, replacement_owner} =
             start_owner(context, upstream: upstream, persistence: persistence)

    assert_receive {:DOWN, ^stale_owner_ref, :process, ^stale_owner, :normal}
    assert_receive {:websocket_owner_harness_upstream_started, replacement_upstream_pid}
    assert replacement_owner != stale_owner
    assert Process.alive?(replacement_owner)
    assert Process.alive?(replacement_upstream_pid)
    assert WebsocketOwnerSession.lookup(context.codex_session_id) == {:ok, replacement_owner}
  end

  @tag :rollout_drain_t3
  test "T3 marker refuses owner creation and reuse while an existing turn still completes",
       context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["in-flight-delta", "in-flight-terminal"]
      )

    assert {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("marker-in-flight"))

    submit_task =
      Task.async(fn -> WebsocketOwnerSession.submit_frame(owner, downstream, "in-flight") end)

    assert_receive {:websocket_owner_frame, "marker-in-flight", 1, {:data, "in-flight-delta"}}
    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}

    _marker_path = WebsocketRolloutDrainSupport.configure_drain_marker!()

    fresh_context = unique_owner_context(context, "marker-refusal")
    fresh_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:error, :owner_drained} = start_owner(fresh_context, upstream: fresh_upstream)
    assert {:error, :owner_drained} = start_owner(context, upstream: upstream)
    assert Process.alive?(owner)
    refute_received {:websocket_owner_harness_upstream_started, _fresh_upstream_pid}

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})

    assert :ok = Task.await(submit_task, 1_000)
    assert_receive {:websocket_owner_frame, "marker-in-flight", 1, {:data, "in-flight-terminal"}}
    assert_receive {:websocket_owner_frame, "marker-in-flight", 1, :complete}
    assert Process.alive?(owner)
  end

  @tag :rollout_drain_t3
  test "T3 a draining existing owner refuses reuse without stopping its active turn", context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["draining-owner-delta", "draining-owner-terminal"]
      )

    assert {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("draining-owner"))

    submit_task =
      Task.async(fn -> WebsocketOwnerSession.submit_frame(owner, downstream, "in-flight") end)

    assert_receive {:websocket_owner_frame, "draining-owner", 1, {:data, "draining-owner-delta"}}

    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}

    assert :ok = WebsocketOwnerSession.begin_drain(owner)

    assert {:ok, %{active_turn?: true, draining?: true}} =
             WebsocketOwnerSession.owner_status(owner)

    assert {:error, :owner_drained} = start_owner(context, upstream: upstream)
    assert Process.alive?(owner)

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})

    assert :ok = Task.await(submit_task, 1_000)

    assert_receive {:websocket_owner_frame, "draining-owner", 1,
                    {:data, "draining-owner-terminal"}}

    assert_receive {:websocket_owner_frame, "draining-owner", 1, :complete}
    assert Process.alive?(owner)
  end

  @tag :rollout_drain_t3
  test "T3 runtime rollout drain refuses fresh owner creation", context do
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    WebsocketRolloutDrainSupport.configure_rollout_drain_server(harness.name)

    assert %{result: :ok, owners_seen: 0} =
             RolloutDrain.start_drain(name: harness.name, timeout_ms: 100)

    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:error, :owner_drained} = start_owner(context, upstream: upstream)
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(context.codex_session_id)
    refute_received {:websocket_owner_harness_upstream_started, _upstream_pid}
  end

  test "owner survives caller shutdown so websocket cleanup can detach", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    parent = self()

    caller =
      spawn(fn ->
        result = start_owner(context, upstream: upstream)
        send(parent, {:websocket_owner_started_from_caller, self(), result})

        receive do
          :shutdown_caller -> exit(:shutdown)
        end
      end)

    assert_receive {:websocket_owner_started_from_caller, ^caller, {:ok, owner}}
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    caller_ref = Process.monitor(caller)
    send(caller, :shutdown_caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :shutdown}

    assert {:ok, ^owner} = WebsocketOwnerSession.lookup(context.codex_session_id)
    assert Process.alive?(owner)
    assert Process.alive?(upstream_pid)

    owner_ref = Process.monitor(owner)
    :ok = GenServer.stop(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
  end

  test "unrelated exit messages do not retire the owner", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    send(owner, {:EXIT, self(), :shutdown})

    assert {:ok, %{upstream_alive?: true}} = WebsocketOwnerSession.owner_status(owner)
    assert Process.alive?(upstream_pid)
  end

  test "idle owner retires when its current upstream exits", context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    {upstream, upstream_pid} = exit_controlled_upstream(self(), :idle)
    persistence = owner_exit_persistence_spy(self(), context)

    assert {:ok, owner} =
             start_owner(context, upstream: upstream, persistence: persistence)

    assert_receive {:exit_controlled_upstream_started, :idle, ^upstream_pid}
    owner_ref = Process.monitor(owner)

    Process.exit(upstream_pid, :shutdown)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :owner_crashed}
    assert_owner_exit_persisted_once(context)
    assert_receive {:exit_controlled_upstream_closed, :idle, ^upstream_pid}
    assert await_owner_unavailable(context.codex_session_id) == {:error, :owner_unavailable}
  end

  test "pre-visible active owner settles once and retires when its current upstream exits",
       context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    {upstream, upstream_pid} = exit_controlled_upstream(self(), :pre_visible)
    persistence = owner_exit_persistence_spy(self(), context)

    assert {:ok, owner} =
             start_owner(context, upstream: upstream, persistence: persistence)

    assert_receive {:exit_controlled_upstream_started, :pre_visible, ^upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("upstream-exit-pre")
             )

    submitter = owner_exit_submitter(self(), owner, downstream, :pre_visible)
    assert_receive {:exit_controlled_upstream_send, :pre_visible, ^upstream_pid, 1}
    owner_ref = Process.monitor(owner)

    Process.exit(upstream_pid, :shutdown)

    assert_receive {:websocket_owner_frame, "upstream-exit-pre", 1,
                    {:error, :owner_crashed, safe_payload}}

    assert safe_payload.code == "owner_crashed"
    assert_receive {:websocket_owner_frame, "upstream-exit-pre", 1, :complete}

    assert_receive {:owner_exit_submitter_outcome, :pre_visible,
                    {:return, {:error, :owner_crashed}}}

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :owner_crashed}
    assert_owner_exit_persisted_once(context)
    assert_receive {:exit_controlled_upstream_closed, :pre_visible, ^upstream_pid}
    assert await_owner_unavailable(context.codex_session_id) == {:error, :owner_unavailable}
    refute_received {:exit_controlled_upstream_send, :pre_visible, _upstream_pid, 2}
    refute_received {:websocket_owner_frame, "upstream-exit-pre", 1, _duplicate}
    refute Process.alive?(submitter)
  end

  test "post-visible active owner preserves the commit barrier before retiring", context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    {upstream, upstream_pid} = exit_controlled_upstream(self(), :post_visible)
    persistence = owner_exit_persistence_spy(self(), context)

    assert {:ok, owner} =
             start_owner(context, upstream: upstream, persistence: persistence)

    assert_receive {:exit_controlled_upstream_started, :post_visible, ^upstream_pid}

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("upstream-exit-post")
             )

    submitter = owner_exit_submitter(self(), owner, stable_downstream, :post_visible, true)

    assert_receive {:websocket_owner_frame, "upstream-exit-post", 1, ^submitter,
                    {:data, "visible-before-upstream-exit"}}

    assert_receive {:exit_controlled_upstream_send, :post_visible, ^upstream_pid, 1}
    owner_ref = Process.monitor(owner)

    Process.exit(upstream_pid, :shutdown)

    assert_receive {:websocket_owner_output_commit_probe, "upstream-exit-post", 1, ^submitter,
                    active_turn_ref, ^owner, probe_ref}

    refute_received {:websocket_owner_frame, "upstream-exit-post", 1, ^submitter, :complete}
    refute_received {:owner_exit_release, _session_id, _lease_token, _reason, _cause}

    send(
      owner,
      {:websocket_owner_output_commit_ack, "upstream-exit-post", 1, submitter, active_turn_ref,
       probe_ref, true}
    )

    assert_receive {:websocket_owner_frame, "upstream-exit-post", 1, ^submitter,
                    {:error, :upstream_stream_error, safe_payload}}

    assert safe_payload.code == "server_error"
    assert_receive {:websocket_owner_frame, "upstream-exit-post", 1, ^submitter, :complete}

    assert_receive {:owner_exit_submitter_outcome, :post_visible,
                    {:return, {:error, %{reason: :owner_crashed}}}}

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :owner_crashed}
    assert_owner_exit_persisted_once(context)
    assert_receive {:exit_controlled_upstream_closed, :post_visible, ^upstream_pid}
    assert await_owner_unavailable(context.codex_session_id) == {:error, :owner_unavailable}
    refute_received {:exit_controlled_upstream_send, :post_visible, _upstream_pid, 2}
    refute_received {:websocket_owner_frame, "upstream-exit-post", 1, ^submitter, _duplicate}
    refute Process.alive?(submitter)
  end

  @tag :owner_exit_settlement_fix
  test "post-visible owner retires when downstream detaches during the commit probe", context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    {upstream, upstream_pid} = exit_controlled_upstream(self(), :post_visible)
    persistence = owner_exit_persistence_spy(self(), context)

    assert {:ok, owner} =
             start_owner(context, upstream: upstream, persistence: persistence)

    assert_receive {:exit_controlled_upstream_started, :post_visible, ^upstream_pid}

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("upstream-exit-probe-detach")
             )

    submitter =
      owner_exit_submitter(self(), owner, stable_downstream, :probe_detach, true)

    assert_receive {:websocket_owner_frame, "upstream-exit-probe-detach", 1, ^submitter,
                    {:data, "visible-before-upstream-exit"}}

    assert_receive {:exit_controlled_upstream_send, :post_visible, ^upstream_pid, 1}
    owner_ref = Process.monitor(owner)

    Process.exit(upstream_pid, :shutdown)

    assert_receive {:websocket_owner_output_commit_probe, "upstream-exit-probe-detach", 1,
                    ^submitter, _active_turn_ref, ^owner, _probe_ref}

    refute_received {:owner_exit_release, _session_id, _lease_token, _reason, _cause}
    assert :ok = WebsocketOwnerSession.detach_downstream(owner, stable_downstream)

    assert_receive {:owner_exit_submitter_outcome, :probe_detach,
                    {:return, {:error, :client_disconnected}}}

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :owner_crashed}
    assert_owner_exit_persisted_once(context)
    assert_receive {:exit_controlled_upstream_closed, :post_visible, ^upstream_pid}
    assert WebsocketOwnerSession.lookup(context.codex_session_id) == {:error, :owner_unavailable}

    refute_received {:websocket_owner_frame, "upstream-exit-probe-detach", 1, ^submitter,
                     :complete}
  end

  @tag :owner_exit_settlement_fix
  test "post-visible owner retires when its submitter dies during the commit probe", context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    {upstream, upstream_pid} = exit_controlled_upstream(self(), :post_visible)
    persistence = owner_exit_persistence_spy(self(), context)

    assert {:ok, owner} =
             start_owner(context, upstream: upstream, persistence: persistence)

    assert_receive {:exit_controlled_upstream_started, :post_visible, ^upstream_pid}

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("upstream-exit-submitter-death")
             )

    submitter =
      owner_exit_submitter(self(), owner, stable_downstream, :submitter_death, true)

    assert_receive {:websocket_owner_frame, "upstream-exit-submitter-death", 1, ^submitter,
                    {:data, "visible-before-upstream-exit"}}

    assert_receive {:exit_controlled_upstream_send, :post_visible, ^upstream_pid, 1}
    owner_ref = Process.monitor(owner)

    Process.exit(upstream_pid, :shutdown)

    assert_receive {:websocket_owner_output_commit_probe, "upstream-exit-submitter-death", 1,
                    ^submitter, _active_turn_ref, ^owner, _probe_ref}

    refute_received {:owner_exit_release, _session_id, _lease_token, _reason, _cause}
    submitter_ref = Process.monitor(submitter)
    Process.exit(submitter, :shutdown)
    assert_receive {:DOWN, ^submitter_ref, :process, ^submitter, :shutdown}

    assert_receive {:websocket_owner_frame, "upstream-exit-submitter-death", 1, ^submitter,
                    {:error, :client_disconnected, safe_payload}}

    assert safe_payload.code == "client_disconnected"

    assert_receive {:websocket_owner_frame, "upstream-exit-submitter-death", 1, ^submitter,
                    :complete}

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :owner_crashed}
    assert_owner_exit_persisted_once(context)
    assert_receive {:exit_controlled_upstream_closed, :post_visible, ^upstream_pid}
    assert WebsocketOwnerSession.lookup(context.codex_session_id) == {:error, :owner_unavailable}
    refute_received {:owner_exit_submitter_outcome, :submitter_death, _outcome}
  end

  @tag :owner_exit_settlement_fix
  test "post-visible owner retires when commit probe delivery fails", context do
    context = %{context | codex_session_id: Ecto.UUID.generate()}
    {upstream, upstream_pid} = exit_controlled_upstream(self(), :post_visible)
    persistence = owner_exit_persistence_spy(self(), context)
    parent = self()

    downstream_sender = fn
      _pid, {:websocket_owner_output_commit_probe, _, _, _, _, _, _} ->
        send(parent, :owner_exit_probe_delivery_failed)
        {:error, :owner_unavailable}

      pid, message ->
        send(pid, message)
        :ok
    end

    assert {:ok, owner} =
             start_owner(context,
               upstream: upstream,
               persistence: persistence,
               downstream_sender: downstream_sender
             )

    assert_receive {:exit_controlled_upstream_started, :post_visible, ^upstream_pid}

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("upstream-exit-probe-failure")
             )

    submitter =
      owner_exit_submitter(self(), owner, stable_downstream, :probe_failure, true)

    assert_receive {:websocket_owner_frame, "upstream-exit-probe-failure", 1, ^submitter,
                    {:data, "visible-before-upstream-exit"}}

    assert_receive {:exit_controlled_upstream_send, :post_visible, ^upstream_pid, 1}
    owner_ref = Process.monitor(owner)

    Process.exit(upstream_pid, :shutdown)

    assert_receive :owner_exit_probe_delivery_failed

    assert_receive {:owner_exit_submitter_outcome, :probe_failure,
                    {:return, {:error, %{reason: :owner_crashed}}}}

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :owner_crashed}
    assert_owner_exit_persisted_once(context)
    assert_receive {:exit_controlled_upstream_closed, :post_visible, ^upstream_pid}
    assert WebsocketOwnerSession.lookup(context.codex_session_id) == {:error, :owner_unavailable}

    refute_received {:websocket_owner_frame, "upstream-exit-probe-failure", 1, ^submitter,
                     :complete}
  end

  test "reject_if_busy attach refuses to steal an attached downstream", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert {:ok, first} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("bridge-first"))

    # A second bridge turn on the same session must not steal the downstream.
    assert {:error, :owner_busy} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("bridge-second"),
               reject_if_busy: true
             )

    assert %{downstream: ^first} = :sys.get_state(owner)

    # The native path (no reject_if_busy) still replaces for reconnect.
    assert {:ok, replacement} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("native-reconnect"))

    assert replacement.epoch > first.epoch
    assert %{downstream: ^replacement} = :sys.get_state(owner)
  end

  test "detached idle owner stops after reconnect window", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, owner} = start_owner(context, upstream: upstream, idle_shutdown_ms: 1)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("idle-detach"))

    assert :ok = WebsocketOwnerSession.detach_downstream(owner, downstream)

    owner_ref = Process.monitor(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
  end

  test "reattach cancels the captured idle timer before the final detach", context do
    idle_shutdown_ms = 100

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), messages: ["reattached-delta"])

    assert {:ok, owner} =
             start_owner(context, upstream: upstream, idle_shutdown_ms: idle_shutdown_ms)

    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert {:ok, first_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("idle-first"))

    assert :ok = WebsocketOwnerSession.detach_downstream(owner, first_downstream)

    assert %{idle_shutdown_ms: ^idle_shutdown_ms, idle_shutdown_ref: first_timer_ref} =
             :sys.get_state(owner)

    assert is_reference(first_timer_ref)
    timer_remaining_ms = Process.read_timer(first_timer_ref)
    assert is_integer(timer_remaining_ms)
    assert timer_remaining_ms in 0..idle_shutdown_ms

    assert {:ok, second_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("idle-second"))

    assert %{idle_shutdown_ms: ^idle_shutdown_ms, idle_shutdown_ref: nil} =
             :sys.get_state(owner)

    assert Process.read_timer(first_timer_ref) == false
    assert :ok = WebsocketOwnerSession.submit_frame(owner, second_downstream, @sentinel)
    assert_receive {:websocket_owner_frame, "idle-second", 1, {:data, "reattached-delta"}}
    assert_receive {:websocket_owner_frame, "idle-second", 1, :complete}

    owner_ref = Process.monitor(owner)
    assert :ok = WebsocketOwnerSession.detach_downstream(owner, second_downstream)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
  end

  test "local gateway owners capture node settings only when each owner starts" do
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings)

    previous_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    on_exit(fn ->
      restore_operational_settings(previous_operational_settings)
      restore_owner_forwarding(previous_forwarding)
    end)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    auth = auth_context()
    first_timeout = 80
    second_timeout = 160
    put_owner_idle_timeout(first_timeout)

    first_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, first_runtime} =
             Gateway.prepare_websocket_session(auth, %{
               accepted_turn_state: "owner-idle-first-#{System.unique_integer([:positive])}",
               websocket_owner_forwarder_opts: [upstream: first_upstream]
             })

    first_session_id = first_runtime.codex_session.id
    on_exit(fn -> cleanup_owner_session(first_session_id) end)
    assert_receive {:websocket_owner_harness_upstream_started, _first_upstream_pid}
    assert {:ok, first_owner} = WebsocketOwnerSession.lookup(first_session_id)
    assert %{idle_shutdown_ms: ^first_timeout} = :sys.get_state(first_owner)

    put_owner_idle_timeout(second_timeout)

    assert %{idle_shutdown_ms: ^first_timeout} = :sys.get_state(first_owner)

    second_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    assert {:ok, second_runtime} =
             Gateway.prepare_websocket_session(auth, %{
               accepted_turn_state: "owner-idle-second-#{System.unique_integer([:positive])}",
               websocket_owner_forwarder_opts: [upstream: second_upstream]
             })

    second_session_id = second_runtime.codex_session.id
    on_exit(fn -> cleanup_owner_session(second_session_id) end)
    assert_receive {:websocket_owner_harness_upstream_started, _second_upstream_pid}
    assert {:ok, second_owner} = WebsocketOwnerSession.lookup(second_session_id)
    assert %{idle_shutdown_ms: ^second_timeout} = :sys.get_state(second_owner)
  end

  test "owner lifecycle logs start reuse lookup miss and terminate metadata", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    request_id = "req-owner-lifecycle-#{System.unique_integer([:positive])}"

    logs =
      capture_info_log(fn ->
        assert {:ok, owner} = start_owner(context, upstream: upstream, request_id: request_id)
        assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

        assert {:ok, ^owner, :existing} =
                 start_owner(context, upstream: upstream, request_id: request_id)

        owner_monitor = Process.monitor(owner)
        :ok = GenServer.stop(owner)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
        assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}

        assert WebsocketOwnerSession.lookup(context.codex_session_id,
                 owner_instance_id: context.owner_instance_id,
                 request_id: request_id
               ) == {:error, :owner_unavailable}
      end)

    assert logs =~ "websocket owner started"
    assert logs =~ "websocket owner reused"
    assert logs =~ "websocket owner terminated"
    assert logs =~ "websocket owner lookup missed"
    assert logs =~ "codex_session_id=#{context.codex_session_id}"
    assert logs =~ "owner_instance_id=#{String.replace(context.owner_instance_id, "@", "_")}"
    assert logs =~ "request_id=#{request_id}"
    assert logs =~ ~r/reason=(dead_pid|not_registered)/
    assert logs =~ "owner_exit_reason=owner_drained"
    refute logs =~ context.owner_lease_token
    refute logs =~ @sentinel
  end

  test "uses the renewal delay policy for every owner lease cycle" do
    context = db_owner_context()
    on_exit(fn -> cleanup_owner_session(context.codex_session_id) end)

    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    test_pid = self()
    delay_ref = make_ref()

    owner_renewal_delay = fn timeout ->
      send(test_pid, {:websocket_owner_renewal_delay, delay_ref, timeout})
      45_000
    end

    assert {:ok, owner} =
             start_owner(context,
               upstream: upstream,
               owner_renewal_ms: 60_000,
               owner_renewal_delay: owner_renewal_delay
             )

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}
    assert_receive {:websocket_owner_renewal_delay, ^delay_ref, 60_000}

    assert %{owner_renewal_ref: first_timer_ref} = :sys.get_state(owner)
    assert is_reference(first_timer_ref)
    assert Process.read_timer(first_timer_ref) in 0..45_000
    cancel_owner_timer(first_timer_ref)

    send(owner, :renew_owner_lease)

    assert_receive {:websocket_owner_renewal_delay, ^delay_ref, 60_000}
  end

  test "renews persisted owner lease while owner remains alive" do
    context = db_owner_context()
    on_exit(fn -> cleanup_owner_session(context.codex_session_id) end)

    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    stale_soon = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.truncate(:microsecond)
    set_owner_lease_expiry!(context.session.id, stale_soon)
    stale_session = Repo.get!(CodexSession, context.session.id)

    assert {:ok, owner} = start_owner(context, upstream: upstream, owner_renewal_ms: 60_000)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    send(owner, :renew_owner_lease)
    _state = :sys.get_state(owner)

    renewed_session = Repo.get!(CodexSession, context.session.id)
    renewed_lease = active_lease!(context.session.id)

    assert renewed_lease.lease_token == context.owner_lease_token
    assert renewed_lease.owner_instance_id == context.owner_instance_id
    assert DateTime.compare(renewed_lease.expires_at, stale_soon) == :gt
    assert renewed_session.owner_lease_token == context.owner_lease_token
    assert renewed_session.owner_instance_id == context.owner_instance_id
    assert DateTime.compare(renewed_session.owner_lease_expires_at, stale_soon) == :gt

    assert DateTime.compare(renewed_session.last_heartbeat_at, stale_session.last_heartbeat_at) ==
             :gt

    assert {:ok, ^owner, :existing} = start_owner(context, upstream: upstream)
  end

  test "stops as stale owner when renewal token is no longer current", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    parent = self()

    persistence = %{
      renew_owner_token: fn session_id, owner_lease_token, %RequestOptions{} ->
        send(parent, {:websocket_owner_renewal_attempt, session_id, owner_lease_token})
        {:error, :stale_owner}
      end,
      release_owner_lease: fn _session_id, _owner_lease_token, _reason ->
        send(parent, :unexpected_owner_release)
        :ok
      end,
      interrupt_codex_session: fn _session_id, _opts ->
        send(parent, :unexpected_owner_interrupt)
        :ok
      end
    }

    assert {:ok, owner} = start_owner(context, upstream: upstream, persistence: persistence)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    owner_ref = Process.monitor(owner)

    logs =
      capture_log(fn ->
        send(owner, :renew_owner_lease)

        codex_session_id = context.codex_session_id
        owner_lease_token = context.owner_lease_token

        assert_receive {:websocket_owner_renewal_attempt, ^codex_session_id, ^owner_lease_token}
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, {:shutdown, :stale_owner}}
      end)

    assert logs =~ "websocket owner renewal stale"
    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
    refute_received :unexpected_owner_release
    refute_received :unexpected_owner_interrupt
  end

  test "serializes accepted frame sends in upstream writer order", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("ordering"))

    assert :ok = WebsocketOwnerSession.submit_frame(owner, downstream, "frame-a")
    assert :ok = WebsocketOwnerSession.submit_frame(owner, downstream, "frame-b")

    assert WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid) == ["frame-a", "frame-b"]
  end

  test "restore accepts only the exact stable boundary and computes reconnect state", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    restore_input = %{pid: self(), epoch: 9, correlation_id: "restore-exact"}

    assert {:ok, stable_downstream} =
             WebsocketOwnerSession.restore_downstream(owner, restore_input)

    assert MapSet.new(Map.keys(stable_downstream)) ==
             MapSet.new([:pid, :epoch, :correlation_id, :active_turn_reconnect?])

    assert stable_downstream.active_turn_reconnect? == false
    assert :sys.get_state(owner).downstream == stable_downstream

    assert WebsocketOwnerSession.restore_downstream(
             owner,
             Map.put(restore_input, :owner_turn_id, self())
           ) == {:error, :stale_downstream}

    assert :sys.get_state(owner).downstream == stable_downstream
  end

  test "public active turn keeps identity only in per-call state and emits five-element frames",
       context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["public-delta-a", "public-delta-b"]
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, stable_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("public-owner-turn"))

    owner_turn_id = self()
    per_call_downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_frame(owner, per_call_downstream, "public-request")
      end)

    assert_receive {:websocket_owner_frame, "public-owner-turn", 1, ^owner_turn_id,
                    {:data, "public-delta-a"}}

    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}

    owner_state = :sys.get_state(owner)

    assert MapSet.new(Map.keys(owner_state.downstream)) ==
             MapSet.new([:pid, :epoch, :correlation_id, :active_turn_reconnect?])

    refute Map.has_key?(owner_state.downstream, :owner_turn_id)

    assert MapSet.new(Map.keys(owner_state.active_turn.downstream)) ==
             MapSet.new([
               :pid,
               :epoch,
               :correlation_id,
               :active_turn_reconnect?,
               :owner_turn_id
             ])

    assert owner_state.active_turn.downstream.owner_turn_id == owner_turn_id

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})
    assert :ok = Task.await(submit_task, 1_000)

    assert_receive {:websocket_owner_frame, "public-owner-turn", 1, ^owner_turn_id,
                    {:data, "public-delta-b"}}

    assert_receive {:websocket_owner_frame, "public-owner-turn", 1, ^owner_turn_id, :complete}
    refute_received {:websocket_owner_frame, "public-owner-turn", 1, _legacy_payload}
  end

  test "returns upstream request result while completing the active downstream", context do
    terminal_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_owner_result",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        }
      })

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("request-result"))

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "request-frame",
      timeouts: %{},
      writer: fn _frame -> :ok end
    }

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             WebsocketOwnerSession.submit_request(owner, downstream, request)

    assert body =~ "resp_owner_result"

    assert_receive {:websocket_owner_frame, "request-result", 1, {:data, ^terminal_frame}}
    assert_receive {:websocket_owner_frame, "request-result", 1, :complete}
  end

  test "observer-bearing requests return owner acceptance through the call result", context do
    terminal_frame = terminal_frame("response.completed", "resp_owner_acceptance")

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        messages: [terminal_frame],
        return_request_result?: true
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("owner-acceptance"))

    test_pid = self()

    request = %{
      websocket_request()
      | submission_observer: fn ->
          send(test_pid, {:owner_submission_observer_ran, self()})
        end
    }

    assert {:websocket_owner_submission_accepted,
            {:ok, %{terminal: "response.completed", status: 200}}} =
             WebsocketOwnerSession.submit_request(owner, downstream, request)

    refute_received {:owner_submission_observer_ran, _observer_pid}
    assert_receive {:websocket_owner_frame, "owner-acceptance", 1, {:data, ^terminal_frame}}
    assert_receive {:websocket_owner_frame, "owner-acceptance", 1, :complete}
  end

  test "terminal-first delivery waits for the matching upstream task result", context do
    terminal_frame = terminal_frame("response.completed", "resp_terminal_first")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("terminal-first"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)

    assert_receive {:websocket_owner_frame, "terminal-first", 1, {:data, ^terminal_frame}}

    assert %{active_turn: %{terminal_forwarded?: true, pending_result: nil}} =
             :sys.get_state(owner)

    refute_received {:websocket_owner_frame, "terminal-first", 1, :complete}

    release_controlled(barriers, controls, :task_result)

    assert Task.await(submit_task, 1_000) == terminal_result(terminal_frame, "response.completed")
    assert_receive {:websocket_owner_frame, "terminal-first", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  test "result-first settlement waits until the matching terminal reaches the downstream",
       context do
    terminal_frame = terminal_frame("response.completed", "resp_result_first")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("result-first"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)

    assert %{active_turn: %{terminal_forwarded?: false, pending_result: pending_result}} =
             await_pending_terminal_result(owner)

    assert pending_result == terminal_result(terminal_frame, "response.completed")
    assert Task.yield(submit_task, 0) == nil
    refute_received {:websocket_owner_frame, "result-first", 1, :complete}

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)

    assert_receive {:websocket_owner_frame, "result-first", 1, {:data, ^terminal_frame}}
    assert Task.await(submit_task, 1_000) == terminal_result(terminal_frame, "response.completed")
    assert_receive {:websocket_owner_frame, "result-first", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  test "local owner preserves the structured response identity through terminal settlement",
       context do
    response_id = "resp_local_owner_identity"
    terminal_frame = terminal_frame("response.completed", response_id)

    expected_result =
      terminal_result(terminal_frame, "response.completed")
      |> elem(1)
      |> Map.put(:response_id, response_id)

    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: {:ok, expected_result}
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("local-response-identity"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)
    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)

    assert Task.await(submit_task, 1_000) == {:ok, expected_result}

    assert_receive {:websocket_owner_frame, "local-response-identity", 1,
                    {:data, ^terminal_frame}}

    assert_receive {:websocket_owner_frame, "local-response-identity", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  test "classified terminal delivery does not reparse a non-JSON downstream frame", context do
    terminal_frame = "terminal-frame-already-classified"
    terminal_result = terminal_result(terminal_frame, "response.completed")

    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, writer ->
        writer.(
          terminal_frame,
          %TerminalDiscriminator{terminal: "response.completed"}
        )

        terminal_result
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }

    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("classified-terminal"))

    assert WebsocketOwnerSession.submit_request(owner, downstream, websocket_request()) ==
             terminal_result

    assert_receive {:websocket_owner_frame, "classified-terminal", 1, {:data, ^terminal_frame}}
    assert_receive {:websocket_owner_frame, "classified-terminal", 1, :complete}
    refute_received {:websocket_owner_frame, "classified-terminal", 1, {:data, ^terminal_frame}}
    refute_received {:websocket_owner_frame, "classified-terminal", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  test "result-first settlement preserves every normalized terminal class exactly once",
       context do
    for {frame_type, result_type} <- [
          {"response.completed", "response.completed"},
          {"response.done", "response.completed"},
          {"response.failed", "response.failed"},
          {"response.incomplete", "response.incomplete"},
          {"error", "error"}
        ] do
      case_id = String.replace(frame_type, ".", "-")
      terminal_frame = terminal_frame(frame_type, "resp_#{case_id}")
      controls = WebsocketOwnerNodeHarness.two_sender_controls()
      owner_context = unique_owner_context(context, case_id)

      upstream =
        WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
          terminal_frames: [terminal_frame],
          task_result: terminal_result(terminal_frame, result_type)
        )

      {:ok, owner} = start_owner(owner_context, upstream: upstream)
      assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

      {:ok, downstream} =
        WebsocketOwnerSession.attach_downstream(owner, downstream_target(case_id))

      submit_task =
        Task.async(fn ->
          WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
        end)

      barriers = await_two_sender_barriers(controls)
      release_controlled(barriers, controls, :task_result)

      assert %{active_turn: %{pending_result: pending_result}} =
               await_pending_terminal_result(owner)

      assert pending_result == terminal_result(terminal_frame, result_type)

      release_controlled(barriers, controls, :nonterminal_frames)
      terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
      release_controlled(terminal_barrier, controls, :terminal_frames)

      assert_receive {:websocket_owner_frame, ^case_id, 1, {:data, ^terminal_frame}}
      assert Task.await(submit_task, 1_000) == terminal_result(terminal_frame, result_type)
      assert_receive {:websocket_owner_frame, ^case_id, 1, :complete}
      refute_received {:websocket_owner_frame, ^case_id, 1, {:data, ^terminal_frame}}
      refute_received {:websocket_owner_frame, ^case_id, 1, :complete}
      assert %{active_turn: nil} = :sys.get_state(owner)
    end
  end

  test "nonterminal task results retain eager settlement", context do
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        task_result: {:ok, %{status: 200, terminal: nil}}
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("nonterminal-result"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)

    assert Task.await(submit_task, 1_000) == {:ok, %{status: 200, terminal: nil}}
    assert_receive {:websocket_owner_frame, "nonterminal-result", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
  end

  test "public interrupted turns preserve ack ordering and consume a prior socket terminal",
       context do
    for committed? <- [false, true] do
      owner_context = unique_owner_context(context, "commit-#{committed?}")
      visible_frame = "visible-#{committed?}"
      upstream = interrupted_upstream(self(), visible_frame)
      {:ok, owner} = start_owner(owner_context, upstream: upstream)

      {:ok, stable_downstream} =
        WebsocketOwnerSession.attach_downstream(
          owner,
          downstream_target("commit-#{committed?}")
        )

      owner_turn_id = self()
      downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

      submit_task =
        Task.async(fn ->
          WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
        end)

      assert_receive {:websocket_owner_frame, correlation_id, epoch, ^owner_turn_id,
                      {:data, ^visible_frame}}

      assert_receive {:websocket_owner_output_commit_probe, ^correlation_id, ^epoch,
                      ^owner_turn_id, active_turn_ref, ^owner, probe_ref}

      assert Task.yield(submit_task, 0) == nil

      send(
        owner,
        {:websocket_owner_output_commit_ack, correlation_id, epoch, owner_turn_id,
         active_turn_ref, probe_ref, committed?}
      )

      if committed? do
        assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, ^owner_turn_id,
                        {:error, :upstream_stream_error, safe_payload}}

        assert safe_payload.code == "server_error"
      else
        refute_received {:websocket_owner_frame, ^correlation_id, ^epoch, ^owner_turn_id,
                         {:error, :upstream_stream_error, _payload}}
      end

      assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, ^owner_turn_id, :complete}
      assert Task.await(submit_task, 1_000) == interrupted_result()
      assert %{active_turn: nil} = :sys.get_state(owner)
    end

    visible_frame =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "visible-before-overflow",
        "sequence_number" => PublicResponsesSequence.max_safe_integer() - 1
      })

    overflow_frame =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "overflow"
      })

    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, writer ->
        _result = writer.(visible_frame, TerminalDiscriminator.classify(visible_frame))
        _result = writer.(overflow_frame, TerminalDiscriminator.classify(overflow_frame))
        interrupted_result()
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }

    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, stable_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("socket-overflow"))

    submit_task =
      Task.async(fn ->
        receive do
          {:submit_owner_turn, downstream} ->
            WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
        end
      end)

    owner_turn_id = submit_task.pid
    downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)
    send(owner_turn_id, {:submit_owner_turn, downstream})

    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    socket_state = %{
      opts: opts,
      tasks: MapSet.new([owner_turn_id]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: owner_turn_id,
      public_responses_websocket_state: nil,
      public_turn_task_done?: false,
      public_turn_owner_complete?: false,
      public_turn_aborted?: false,
      public_turn_output_committed?: false,
      websocket_owner_downstream: stable_downstream
    }

    assert_receive {:websocket_owner_frame, "socket-overflow", 1, ^owner_turn_id,
                    {:data, ^visible_frame}}

    assert {:push, {:text, visible_payload}, socket_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "socket-overflow", 1, owner_turn_id,
                {:data, visible_frame}},
               socket_state
             )

    assert Jason.decode!(visible_payload)["type"] == "response.output_text.delta"

    assert_receive {:websocket_owner_frame, "socket-overflow", 1, ^owner_turn_id,
                    {:data, ^overflow_frame}}

    assert {:push, {:text, overflow_payload}, socket_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "socket-overflow", 1, owner_turn_id,
                {:data, overflow_frame}},
               socket_state
             )

    assert Jason.decode!(overflow_payload)["error"]["code"] == "websocket_sequence_exhausted"

    assert_receive {:websocket_owner_output_commit_probe, "socket-overflow", 1, ^owner_turn_id,
                    active_turn_ref, ^owner, probe_ref} = probe

    assert {:ok, ^socket_state} = CodexResponsesSocket.handle_info(probe, socket_state)

    assert_receive {:websocket_owner_frame, "socket-overflow", 1, ^owner_turn_id,
                    {:error, :upstream_stream_error, safe_payload}} = owner_error

    {{:ok, socket_state}, logs} =
      with_log([level: :warning], fn ->
        CodexResponsesSocket.handle_info(owner_error, socket_state)
      end)

    assert length(Regex.scan(~r/websocket native turn failed/, logs)) == 1
    refute logs =~ "owner_forward_timeout"
    refute Jason.encode!(safe_payload) =~ "owner_forward_timeout"

    assert_receive {:websocket_owner_frame, "socket-overflow", 1, ^owner_turn_id, :complete} =
                     owner_complete

    assert {:ok, completed_state} =
             CodexResponsesSocket.handle_info(owner_complete, socket_state)

    assert Task.await(submit_task, 1_000) == interrupted_result()
    assert %{active_turn: nil} = :sys.get_state(owner)

    assert {:ok, final_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, owner_turn_id,
                {:response_task_result, interrupted_result(), true}},
               completed_state
             )

    assert final_state.public_response_task_pid == nil
    refute final_state.public_turn_output_committed?

    refute_received {:websocket_owner_frame, "socket-overflow", 1, ^owner_turn_id,
                     {:error, :owner_forward_timeout, _payload}}

    refute_received {:websocket_owner_frame, "socket-overflow", 1, ^owner_turn_id, _payload}

    assert is_reference(active_turn_ref)
    assert is_reference(probe_ref)
  end

  test "public interrupted turn pins probe ref and times out with a safe error", context do
    upstream = interrupted_upstream(self(), "visible-timeout")
    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, stable_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("commit-timeout"))

    owner_turn_id = self()
    downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    assert_receive {:websocket_owner_frame, correlation_id, epoch, ^owner_turn_id,
                    {:data, "visible-timeout"}}

    assert_receive {:websocket_owner_output_commit_probe, ^correlation_id, ^epoch, ^owner_turn_id,
                    active_turn_ref, ^owner, probe_ref}

    send(
      owner,
      {:websocket_owner_output_commit_ack, correlation_id, epoch, owner_turn_id, active_turn_ref,
       make_ref(), true}
    )

    assert Task.yield(submit_task, 0) == nil

    %{active_turn: %{output_commit_probe: probe_state}} = :sys.get_state(owner)
    Process.cancel_timer(probe_state.timer_ref)
    send(owner, {:websocket_owner_output_commit_timeout, active_turn_ref, probe_ref})

    assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, ^owner_turn_id,
                    {:error, :owner_forward_timeout, timeout_payload}}

    assert timeout_payload.code == "owner_forward_timeout"
    assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, ^owner_turn_id, :complete}
    assert Task.await(submit_task, 1_000) == interrupted_result()

    send(
      owner,
      {:websocket_owner_output_commit_ack, correlation_id, epoch, owner_turn_id, active_turn_ref,
       probe_ref, true}
    )

    refute_received {:websocket_owner_frame, ^correlation_id, ^epoch, ^owner_turn_id, _payload}
  end

  test "native owner interruption probe is acknowledged by the sole socket task", context do
    upstream = interrupted_upstream(self(), "visible-native-ack")
    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, stable_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("native-probe-ack"))

    owner_turn_id = self()
    downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    assert_receive {:websocket_owner_frame, "native-probe-ack", epoch, ^owner_turn_id,
                    {:data, "visible-native-ack"}}

    assert_receive {:websocket_owner_output_commit_probe, "native-probe-ack", ^epoch,
                    ^owner_turn_id, _active_turn_ref, ^owner, _probe_ref} = probe

    socket_state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([owner_turn_id]),
      public_response_task_pid: nil,
      public_turn_aborted?: false,
      public_turn_owner_complete?: false,
      native_turn_output_task_pids: MapSet.new([owner_turn_id]),
      websocket_owner_downstream: stable_downstream
    }

    assert {:ok, ^socket_state} = CodexResponsesSocket.handle_info(probe, socket_state)
    assert_receive {:websocket_owner_frame, "native-probe-ack", ^epoch, ^owner_turn_id, :complete}
    assert Task.await(submit_task, 1_000) == interrupted_result()

    refute_received {:websocket_owner_frame, "native-probe-ack", ^epoch, ^owner_turn_id,
                     {:error, :owner_forward_timeout, _payload}}
  end

  test "reconnect while probing settles the old turn without downstream delivery", context do
    upstream = interrupted_upstream(self(), "visible-reconnect")
    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, first} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("commit-reconnect-old"))

    downstream = Map.put(first, :owner_turn_id, self())

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    assert_receive {:websocket_owner_frame, "commit-reconnect-old", 1, _owner_turn_id,
                    {:data, "visible-reconnect"}}

    assert_receive {:websocket_owner_output_commit_probe, "commit-reconnect-old", 1,
                    _owner_turn_id, _active_turn_ref, ^owner, _probe_ref}

    assert {:ok, second} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("commit-reconnect-new")
             )

    assert second.epoch == 2
    refute second.active_turn_reconnect?
    assert Task.await(submit_task, 1_000) == interrupted_result()
    refute_received {:websocket_owner_frame, "commit-reconnect-old", 1, _owner_turn_id, :complete}
    refute_received {:websocket_owner_frame, "commit-reconnect-new", 2, _payload}
    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  test "probing turn stays busy and graceful drain lets the acknowledgement finish", context do
    probe = start_output_commit_probe(context, "probe-busy")

    assert WebsocketOwnerSession.submit_frame(
             probe.owner,
             probe.downstream,
             "overlapping-request"
           ) == {:error, :owner_busy}

    assert :ok = WebsocketOwnerSession.begin_drain(probe.owner)

    send(
      probe.owner,
      {:websocket_owner_output_commit_ack, probe.correlation_id, probe.epoch, probe.owner_turn_id,
       probe.active_turn_ref, probe.probe_ref, false}
    )

    assert_receive {:websocket_owner_frame, "probe-busy", 1, _owner_turn_id, :complete}
    assert Task.await(probe.submit_task, 1_000) == interrupted_result()
    assert %{active_turn: nil, draining?: true} = :sys.get_state(probe.owner)
  end

  test "explicit detach cancels a probe and ignores its late acknowledgement", context do
    probe = start_output_commit_probe(context, "probe-detach")
    %{active_turn: %{output_commit_probe: %{timer_ref: timer_ref}}} = :sys.get_state(probe.owner)

    assert :ok = WebsocketOwnerSession.detach_downstream(probe.owner, probe.stable_downstream)
    assert Task.await(probe.submit_task, 1_000) == {:error, :client_disconnected}
    assert Process.read_timer(timer_ref) == false
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(probe.owner)

    send(
      probe.owner,
      {:websocket_owner_output_commit_ack, probe.correlation_id, probe.epoch, probe.owner_turn_id,
       probe.active_turn_ref, probe.probe_ref, true}
    )

    refute_received {:websocket_owner_frame, "probe-detach", 1, _owner_turn_id, _payload}
  end

  test "downstream death settles the retained interruption without delivery", context do
    parent = self()

    downstream_pid =
      spawn(fn ->
        receive_probe_messages(parent)
      end)

    upstream = interrupted_upstream(self(), "visible-downstream-death")
    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, stable_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: downstream_pid,
        correlation_id: "probe-downstream-death"
      })

    owner_turn_id = self()
    downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    assert_receive {:probe_downstream_message,
                    {:websocket_owner_frame, "probe-downstream-death", 1, ^owner_turn_id,
                     {:data, "visible-downstream-death"}}}

    assert_receive {:probe_downstream_message,
                    {:websocket_owner_output_commit_probe, "probe-downstream-death", 1,
                     ^owner_turn_id, _active_turn_ref, ^owner, _probe_ref}}

    downstream_ref = Process.monitor(downstream_pid)
    Process.exit(downstream_pid, :shutdown)
    assert_receive {:DOWN, ^downstream_ref, :process, ^downstream_pid, :shutdown}

    assert Task.await(submit_task, 1_000) == interrupted_result()
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(owner)
    refute_received {:probe_downstream_message, {:websocket_owner_frame, _, _, _, :complete}}
  end

  test "exact terminal timeout invalidates upstream and emits one committed failure", context do
    terminal_frame = terminal_frame("response.completed", "resp_timeout")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()
    parent = self()

    upstream =
      self()
      |> WebsocketOwnerNodeHarness.two_sender_upstream_boundary(controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )
      |> Map.put(:invalidate, fn upstream_pid ->
        send(parent, {:terminal_timeout_invalidation, upstream_pid})
        WebsocketOwnerNodeHarness.controlled_result(parent, controls, :invalidation_result, :ok)
      end)

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("terminal-timeout"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)

    %{active_turn: active_turn} = await_pending_terminal_result(owner)
    cancel_owner_timer(active_turn.terminal_delivery_timer_ref)
    {turn_ref, timer_token} = active_turn.terminal_delivery_timeout

    send(owner, {:websocket_owner_terminal_delivery_timeout, turn_ref, make_ref()})
    assert %{active_turn: %{pending_result: pending_result}} = :sys.get_state(owner)
    assert pending_result == terminal_result(terminal_frame, "response.completed")

    timer_task = controlled_timer_task(self(), owner, controls, {turn_ref, timer_token})
    timer_barrier = await_controlled_barrier(:timer_message, controls)
    release_controlled(timer_barrier, controls, :timer_message)
    assert Task.await(timer_task, 1_000) == :ok

    assert_receive {:terminal_timeout_invalidation, ^upstream_pid}
    invalidation_barrier = await_controlled_barrier(:invalidation_result, controls)
    release_controlled(invalidation_barrier, controls, :invalidation_result)

    assert {:error, timeout_result} = Task.await(submit_task, 1_000)
    assert timeout_result.reason == :upstream_websocket_terminal_delivery_timeout
    assert timeout_result.transport_failure["phase"] == "terminal_delivery"
    assert timeout_result.transport_failure["upstream_committed"] == true
    assert timeout_result.transport_failure["terminal_seen"] == true
    assert timeout_result.transport_failure["terminal_forwarded"] == false

    assert_receive {:websocket_owner_frame, "terminal-timeout", 1,
                    {:error, :upstream_websocket_terminal_delivery_timeout, safe_payload}}

    assert safe_payload.code == "upstream_stream_error"
    assert safe_payload.metadata.reason == "upstream_websocket_terminal_delivery_timeout"
    assert_receive {:websocket_owner_frame, "terminal-timeout", 1, :complete}
    refute_received {:websocket_owner_frame, "terminal-timeout", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
    refute_receive {:websocket_owner_frame, "terminal-timeout", 1, {:data, ^terminal_frame}}
  end

  test "terminal timeout keeps invalidation failure precedence", context do
    terminal_frame = terminal_frame("response.completed", "resp_invalidation_failure")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()
    parent = self()

    upstream =
      self()
      |> WebsocketOwnerNodeHarness.two_sender_upstream_boundary(controls,
        task_result: terminal_result(terminal_frame, "response.completed")
      )
      |> Map.put(:invalidate, fn _upstream_pid ->
        WebsocketOwnerNodeHarness.controlled_result(
          parent,
          controls,
          :invalidation_result,
          {:error, :upstream_websocket_not_connected}
        )
      end)

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("invalidation-failure"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)
    %{active_turn: active_turn} = await_pending_terminal_result(owner)
    cancel_owner_timer(active_turn.terminal_delivery_timer_ref)
    {turn_ref, timer_token} = active_turn.terminal_delivery_timeout
    send(owner, {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token})

    invalidation_barrier = await_controlled_barrier(:invalidation_result, controls)
    release_controlled(invalidation_barrier, controls, :invalidation_result)

    assert Task.await(submit_task, 1_000) == {:error, :upstream_websocket_not_connected}

    assert_receive {:websocket_owner_frame, "invalidation-failure", 1,
                    {:error, :owner_crashed, safe_payload}}

    assert safe_payload.code == "owner_crashed"
    assert_receive {:websocket_owner_frame, "invalidation-failure", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
  end

  test "terminal downstream send failure settles once before a late task result", context do
    terminal_frame = terminal_frame("response.completed", "resp_send_failure")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    downstream_sender =
      controlled_terminal_downstream_sender(self(), controls, {:error, :owner_unavailable})

    {:ok, owner} = start_owner(context, upstream: upstream, downstream_sender: downstream_sender)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("send-failure"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)

    send_barrier = await_controlled_barrier(:downstream_send_result, controls)
    release_controlled(send_barrier, controls, :downstream_send_result)

    assert Task.await(submit_task, 1_000) == {:error, :owner_unavailable}

    assert_receive {:websocket_owner_frame, "send-failure", 1,
                    {:error, :owner_unavailable, safe_payload}}

    assert safe_payload.code == "owner_unavailable"
    assert_receive {:websocket_owner_frame, "send-failure", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)

    release_controlled(barriers, controls, :task_result)
    refute_received {:websocket_owner_frame, "send-failure", 1, :complete}
  end

  test "duplicate terminal and stale timeout messages cannot settle the next turn", context do
    terminal_frame = terminal_frame("response.completed", "resp_duplicate_terminal")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame, terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("duplicate-terminal"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    assert %{active_turn: %{task_ref: stale_task_ref}} = :sys.get_state(owner)
    release_controlled(barriers, controls, :task_result)
    %{active_turn: active_turn} = await_pending_terminal_result(owner)
    stale_timeout = active_turn.terminal_delivery_timeout
    stale_result = active_turn.pending_result
    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)

    assert_receive {:websocket_owner_frame, "duplicate-terminal", 1, {:data, ^terminal_frame}}
    assert {:ok, result} = Task.await(submit_task, 1_000)
    assert result == terminal_result(terminal_frame, "response.completed") |> elem(1)
    refute Map.has_key?(result, :response_id)
    assert_receive {:websocket_owner_frame, "duplicate-terminal", 1, :complete}
    refute_received {:websocket_owner_frame, "duplicate-terminal", 1, {:data, ^terminal_frame}}

    {stale_turn_ref, stale_timer_token} = stale_timeout
    send(owner, {:websocket_owner_terminal_delivery_timeout, stale_turn_ref, stale_timer_token})
    assert %{active_turn: nil} = :sys.get_state(owner)

    {:ok, reconnected_downstream} =
      WebsocketOwnerSession.attach_downstream(
        owner,
        downstream_target("reconnect-after-terminal")
      )

    assert reconnected_downstream.epoch == downstream.epoch + 1

    next_submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_frame(owner, reconnected_downstream, "next-turn")
      end)

    next_barriers = await_two_sender_barriers(controls)
    assert %{active_turn: %{ref: next_turn_ref}} = :sys.get_state(owner)

    send(owner, {stale_task_ref, stale_result})
    send(owner, {:websocket_owner_terminal_delivery_timeout, stale_turn_ref, stale_timer_token})
    send(owner, {:websocket_owner_upstream_frame, active_turn.ref, terminal_frame})

    assert %{active_turn: %{ref: ^next_turn_ref, pending_result: nil}} = :sys.get_state(owner)

    release_controlled(next_barriers, controls, :nonterminal_frames)
    next_terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(next_terminal_barrier, controls, :terminal_frames)
    release_controlled(next_barriers, controls, :task_result)

    assert Task.await(next_submit_task, 1_000) ==
             terminal_result(terminal_frame, "response.completed")

    assert_receive {:websocket_owner_frame, "reconnect-after-terminal", 2, :complete}

    refute_received {:websocket_owner_frame, "reconnect-after-terminal", 2,
                     {:error, :upstream_websocket_terminal_delivery_timeout, _payload}}

    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  test "detach while a terminal result is pending keeps client disconnect precedence", context do
    terminal_frame = terminal_frame("response.completed", "resp_detach_pending")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("detach-pending"))

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)
    %{active_turn: active_turn} = await_pending_terminal_result(owner)
    timer_ref = active_turn.terminal_delivery_timer_ref

    assert :ok = WebsocketOwnerSession.detach_downstream(owner, downstream)
    assert Task.await(submit_task, 1_000) == {:error, :client_disconnected}
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(owner)
    assert Process.read_timer(timer_ref) == false
    refute_received {:websocket_owner_frame, "detach-pending", 1, _payload}

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
  end

  test "downstream death while a terminal result is pending preserves the upstream result",
       context do
    terminal_frame = terminal_frame("response.completed", "resp_downstream_death_pending")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}
    target = collector(self(), :pending_downstream_death)

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: target,
        correlation_id: "downstream-death-pending"
      })

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    release_controlled(barriers, controls, :task_result)
    %{active_turn: active_turn} = await_pending_terminal_result(owner)
    timer_ref = active_turn.terminal_delivery_timer_ref
    target_ref = Process.monitor(target)
    Process.unlink(target)
    Process.exit(target, :shutdown)
    assert_receive {:DOWN, ^target_ref, :process, ^target, :shutdown}

    assert Task.await(submit_task, 1_000) == terminal_result(terminal_frame, "response.completed")
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(owner)
    assert Process.read_timer(timer_ref) == false
    refute_received {:collected_owner_frame, :pending_downstream_death, _message}

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
  end

  @tag :rollout_drain_deadline_contract
  test "rollout drain deadline aborts a pending terminal result irreversibly", context do
    pending = start_pending_terminal_turn(context, "pending-drain")
    owner = pending.owner
    terminal_frame = pending.terminal_frame
    cancel_owner_timer(pending.active_turn.terminal_delivery_timer_ref)
    owner_ref = Process.monitor(owner)

    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    on_exit(fn ->
      frame_sender = pending.barriers.nonterminal_frames
      if Process.alive?(frame_sender), do: Process.exit(frame_sender, :kill)

      if Process.alive?(pending.submitter), do: Process.exit(pending.submitter, :kill)
    end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, wait_ms}
    refute_received {:websocket_owner_frame, "pending-drain", 1, {:error, :owner_drained, _}}
    assert Process.alive?(owner)

    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(harness.deadline, wait_ms)

    assert_receive {:websocket_owner_frame, "pending-drain", 1,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.code == "owner_drained"
    assert safe_payload.message == "websocket owner is draining"
    assert safe_payload.metadata.reason == "owner_drained"
    assert_receive {:websocket_owner_frame, "pending-drain", 1, :complete}
    assert_receive {:pending_submitter_outcome, "pending-drain", {:exit, _reason}}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert Process.read_timer(pending.active_turn.terminal_delivery_timer_ref) == false

    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 1_000)

    release_pending_terminal_sender(pending)
    refute_received {:websocket_owner_frame, "pending-drain", 1, {:data, ^terminal_frame}}
    refute_received {:websocket_owner_frame, "pending-drain", 1, :complete}
    refute_received {:pending_submitter_outcome, "pending-drain", _outcome}

    assert_stale_messages_do_not_settle_fresh_turn(context, pending, "after-drain")
  end

  test "direct drain characterizes the current immediate active-turn abort contract", context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["characterization-delta", "unreachable-after-drain"]
      )

    assert {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("direct-drain-characterization")
             )

    parent = self()

    spawn(fn ->
      outcome =
        try do
          {:return,
           WebsocketOwnerSession.submit_frame(owner, downstream, "characterization-request")}
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:direct_drain_characterization_outcome, outcome})
    end)

    assert_receive {:websocket_owner_frame, "direct-drain-characterization", 1,
                    {:data, "characterization-delta"}}

    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}
    owner_ref = Process.monitor(owner)

    assert :ok = WebsocketOwnerSession.drain_owner(owner)

    assert_receive {:websocket_owner_frame, "direct-drain-characterization", 1,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.code == "owner_drained"
    assert_receive {:websocket_owner_frame, "direct-drain-characterization", 1, :complete}
    assert_receive {:direct_drain_characterization_outcome, {:exit, _reason}}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})

    refute_received {:websocket_owner_frame, "direct-drain-characterization", 1,
                     {:data, "unreachable-after-drain"}}
  end

  @tag :owner_exit_reason_label_baseline
  test "idle expiry and rollout deadline cut retain existing owner-exit metadata" do
    idle_context = db_owner_context()
    drain_context = db_owner_context()

    on_exit(fn -> cleanup_owner_session(idle_context.codex_session_id) end)
    on_exit(fn -> cleanup_owner_session(drain_context.codex_session_id) end)

    idle_exit = observe_owner_exit(idle_context, :idle_expiry)
    drain_exit = observe_owner_exit(drain_context, :rollout_deadline_cut)

    assert Map.take(idle_exit.metadata, [:owner_exit_reason, :release_reason]) == %{
             owner_exit_reason: "owner_drained",
             release_reason: "owner_drained"
           }

    assert Map.take(drain_exit.metadata, [:owner_exit_reason, :release_reason]) ==
             Map.take(idle_exit.metadata, [:owner_exit_reason, :release_reason])
  end

  @tag :owner_exit_reason_label_red
  test "owner exit metadata adds a bounded cause without replacing owner_drained" do
    idle_context = db_owner_context()
    drain_context = db_owner_context()

    on_exit(fn -> cleanup_owner_session(idle_context.codex_session_id) end)
    on_exit(fn -> cleanup_owner_session(drain_context.codex_session_id) end)

    idle_exit = observe_owner_exit(idle_context, :idle_expiry)
    drain_exit = observe_owner_exit(drain_context, :rollout_deadline_cut)

    assert idle_exit.metadata.owner_exit_reason == "owner_drained"
    assert drain_exit.metadata.owner_exit_reason == "owner_drained"
    assert idle_exit.metadata.owner_exit_cause == "idle_expiry"
    assert drain_exit.metadata.owner_exit_cause == "drain_cut"
    assert idle_exit.metadata.persisted_owner_exit_cause == "idle_expiry"
    assert drain_exit.metadata.persisted_owner_exit_cause == "drain_cut"
  end

  test "lease loss while a terminal result is pending stops stale without terminalization",
       context do
    parent = self()

    persistence = %{
      renew_owner_token: fn session_id, owner_lease_token, %RequestOptions{} ->
        send(parent, {:pending_owner_renewal_attempt, session_id, owner_lease_token})
        {:error, :stale_owner}
      end,
      release_owner_lease: fn _session_id, _owner_lease_token, _reason ->
        send(parent, :unexpected_pending_owner_release)
        :ok
      end,
      interrupt_codex_session: fn _session_id, _opts ->
        send(parent, :unexpected_pending_owner_interrupt)
        :ok
      end
    }

    pending =
      start_pending_terminal_turn(context, "pending-lease-loss", persistence: persistence)

    owner = pending.owner
    cancel_owner_timer(pending.active_turn.terminal_delivery_timer_ref)
    owner_ref = Process.monitor(owner)

    codex_session_id = context.codex_session_id
    owner_lease_token = context.owner_lease_token

    logs =
      capture_log(fn ->
        send(owner, :renew_owner_lease)

        assert_receive {:pending_owner_renewal_attempt, ^codex_session_id, ^owner_lease_token}
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, {:shutdown, :stale_owner}}
      end)

    assert logs =~ "websocket owner renewal stale"
    assert logs =~ "reason=stale_owner"
    assert_receive {:pending_submitter_outcome, "pending-lease-loss", {:exit, _reason}}
    assert Process.read_timer(pending.active_turn.terminal_delivery_timer_ref) == false

    release_abandoned_terminal_sender(pending)

    refute_received {:websocket_owner_frame, "pending-lease-loss", 1, _payload}
    refute_received {:pending_submitter_outcome, "pending-lease-loss", _outcome}
    refute_received :unexpected_pending_owner_release
    refute_received :unexpected_pending_owner_interrupt

    assert_stale_messages_do_not_settle_fresh_turn(context, pending, "after-lease-loss")
  end

  test "late upstream task DOWN cannot displace a pending terminal result", context do
    pending = start_pending_terminal_turn(context, "pending-task-down")
    pending_result = pending.active_turn.pending_result
    terminal_frame = pending.terminal_frame
    cancel_owner_timer(pending.active_turn.terminal_delivery_timer_ref)

    send(
      pending.owner,
      {:DOWN, pending.task_ref, :process, pending.task_pid, :shutdown}
    )

    assert %{active_turn: active_turn} = :sys.get_state(pending.owner)
    assert active_turn.ref == pending.active_turn.ref
    assert active_turn.pending_result == pending_result
    refute_received {:websocket_owner_frame, "pending-task-down", 1, _payload}

    release_pending_terminal_sender(pending)

    assert_receive {:websocket_owner_frame, "pending-task-down", 1, {:data, ^terminal_frame}}

    assert_receive {:pending_submitter_outcome, "pending-task-down", {:return, ^pending_result}}

    assert_receive {:websocket_owner_frame, "pending-task-down", 1, :complete}
    refute_received {:websocket_owner_frame, "pending-task-down", 1, :complete}
    assert %{active_turn: nil} = :sys.get_state(pending.owner)

    assert_stale_messages_do_not_settle_next_turn(
      pending.owner,
      pending.downstream,
      pending.controls,
      pending,
      pending.terminal_frame
    )
  end

  test "forwards a terminal failure body when the upstream request returns an error", context do
    terminal_frame =
      Jason.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "id" => "resp_owner_failure",
          "error" => %{"code" => "model_not_found"}
        }
      })

    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        {:error, %{body: terminal_frame, reason: :model_not_found}}
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }

    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("terminal-failure"))

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "request-frame",
      timeouts: %{},
      writer: fn _frame -> :ok end
    }

    assert {:error, %{body: ^terminal_frame, reason: :model_not_found}} =
             WebsocketOwnerSession.submit_request(owner, downstream, request)

    assert_receive {:websocket_owner_frame, "terminal-failure", 1, {:data, ^terminal_frame}}
    assert_receive {:websocket_owner_frame, "terminal-failure", 1, :complete}
  end

  test "latest reconnect increments downstream epoch and fences old downstream sends", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    {:ok, first_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("first"))

    {:ok, second_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("second"))

    assert first_downstream.epoch == 1
    assert second_downstream.epoch == 2

    assert WebsocketOwnerSession.submit_frame(owner, first_downstream, "old-frame") ==
             {:error, :duplicate_downstream}

    assert :ok = WebsocketOwnerSession.submit_frame(owner, second_downstream, "new-frame")
    assert WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid) == ["new-frame"]

    assert WebsocketOwnerSession.detach_downstream(owner, first_downstream) ==
             {:error, :duplicate_downstream}
  end

  test "latest reconnect fences old downstream request submissions", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    {:ok, first_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("first-request"))

    {:ok, second_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("second-request"))

    request = %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "stale-request-frame",
      timeouts: %{},
      writer: fn _frame -> :ok end
    }

    assert WebsocketOwnerSession.submit_request(owner, first_downstream, request) ==
             {:error, :duplicate_downstream}

    assert WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid) == []

    assert :ok = WebsocketOwnerSession.submit_request(owner, second_downstream, request)
    assert [forwarded_request] = WebsocketOwnerNodeHarness.fake_upstream_frames(upstream_pid)
    assert forwarded_request.payload == "stale-request-frame"
  end

  test "sends owner frames only to the active downstream epoch", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    stale_target = collector(self(), :stale)
    active_target = collector(self(), :active)

    {:ok, stale_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: stale_target,
        correlation_id: "corr-stale"
      })

    {:ok, active_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: active_target,
        correlation_id: "corr-active"
      })

    assert :ok = WebsocketOwnerSession.push_downstream(owner, {:data, "encoded-response"})
    assert {:ok, safe_payload} = WebsocketOwnerContract.safe_error_payload(:owner_busy, @sentinel)
    assert :ok = WebsocketOwnerSession.push_downstream(owner, {:error, :owner_busy, safe_payload})
    assert :ok = WebsocketOwnerSession.push_downstream(owner, :complete)

    assert_receive {:collected_owner_frame, :active,
                    {:websocket_owner_frame, "corr-active", 2, {:data, "encoded-response"}}}

    assert_receive {:collected_owner_frame, :active,
                    {:websocket_owner_frame, "corr-active", 2,
                     {:error, :owner_busy, ^safe_payload}}}

    assert_receive {:collected_owner_frame, :active,
                    {:websocket_owner_frame, "corr-active", 2, :complete}}

    refute_receive {:collected_owner_frame, :stale, _message}
    assert stale_downstream.epoch == 1
    assert active_downstream.epoch == 2
  end

  test "stays responsive while upstream worker is active and routes later frames to latest downstream",
       context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["delta-a", "delta-b"]
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    first_target = collector(self(), :first)
    second_target = collector(self(), :second)

    {:ok, first_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: first_target,
        correlation_id: "corr-first"
      })

    submit_task =
      Task.async(fn -> WebsocketOwnerSession.submit_frame(owner, first_downstream, @sentinel) end)

    assert_receive {:collected_owner_frame, :first,
                    {:websocket_owner_frame, "corr-first", 1, {:data, "delta-a"}}}

    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}

    owner_state = :sys.get_state(owner)

    assert %{active_turn: %{task_pid: task_pid, submitter_monitor: submitter_monitor}} =
             owner_state

    assert is_pid(task_pid)
    assert is_reference(submitter_monitor)
    assert task_pid != submit_task.pid

    assert {:ok, second_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: second_target,
               correlation_id: "corr-second"
             })

    assert second_downstream.epoch == 2
    assert second_downstream.active_turn_reconnect? == true

    assert WebsocketOwnerSession.submit_frame(owner, second_downstream, "overlap-frame") ==
             {:error, :owner_busy}

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})
    assert :ok = Task.await(submit_task, 1_000)

    assert_receive {:collected_owner_frame, :second,
                    {:websocket_owner_frame, "corr-second", 2, {:data, "delta-b"}}}

    assert_receive {:collected_owner_frame, :second,
                    {:websocket_owner_frame, "corr-second", 2, :complete}}

    refute_receive {:collected_owner_frame, :first,
                    {:websocket_owner_frame, "corr-first", 1, {:data, "delta-b"}}}

    owner_state = :sys.get_state(owner)
    refute inspect(owner_state) =~ @sentinel
  end

  test "submitter exit while upstream worker is blocked clears active turn", context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["delta-before-submitter-exit", "delta-after-submitter-exit"]
      )

    {:ok, owner} = start_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target("submitter-exit"))

    parent = self()

    submitter =
      spawn(fn ->
        result = WebsocketOwnerSession.submit_frame(owner, downstream, @sentinel)
        send(parent, {:websocket_owner_submitter_result, result})
      end)

    assert_receive {:websocket_owner_frame, "submitter-exit", 1,
                    {:data, "delta-before-submitter-exit"}}

    assert_receive {:websocket_owner_harness_barrier, upstream_worker_pid, ^block_ref}

    upstream_worker_ref = Process.monitor(upstream_worker_pid)
    submitter_ref = Process.monitor(submitter)

    Process.exit(submitter, :shutdown)
    assert_receive {:DOWN, ^submitter_ref, :process, ^submitter, :shutdown}
    assert_receive {:DOWN, ^upstream_worker_ref, :process, ^upstream_worker_pid, :shutdown}

    assert_receive {:websocket_owner_frame, "submitter-exit", 1,
                    {:error, :client_disconnected, safe_payload}}

    assert safe_payload.code == "client_disconnected"
    assert_receive {:websocket_owner_frame, "submitter-exit", 1, :complete}
    assert %{active_turn: nil} = await_active_turn_cleared(owner)
    refute_received {:websocket_owner_submitter_result, _result}

    refute_receive {:websocket_owner_frame, "submitter-exit", 1,
                    {:data, "delta-after-submitter-exit"}}
  end

  test "local bridge submitter exit cancels the default upstream websocket request", context do
    release_ref = make_ref()
    parent = self()

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.timeout_mid_stream(
          ~s({"type":"response.created","response":{"id":"resp_detach_local_owner","status":"in_progress"}}),
          notify: self(),
          release_ref: release_ref
        )
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    {:ok, owner} = start_owner(context, [])

    submitter =
      spawn(fn ->
        send(parent, {:local_owner_bridge_submitter_ready, self()})

        receive do
          {:submit_local_owner_bridge, downstream, request} ->
            result = WebsocketOwnerSession.submit_request(owner, downstream, request)
            send(parent, {:local_owner_bridge_submitter_result, result})
        end
      end)

    assert_receive {:local_owner_bridge_submitter_ready, ^submitter}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: submitter,
        correlation_id: "detach-local-owner"
      })

    send(
      submitter,
      {:submit_local_owner_bridge, downstream,
       %{
         websocket_request()
         | url: FakeUpstream.url(upstream),
           timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}
       }}
    )

    submitter_ref = Process.monitor(submitter)

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, socket_pid, ^release_ref},
                   1_000

    assert %{active_turn: %{task_pid: active_turn_worker_pid}} = :sys.get_state(owner)

    active_turn_worker_ref = Process.monitor(active_turn_worker_pid)
    socket_ref = Process.monitor(socket_pid)

    Process.exit(submitter, :shutdown)

    assert_receive {:DOWN, ^submitter_ref, :process, ^submitter, :shutdown}, 1_000

    assert_receive {:DOWN, ^active_turn_worker_ref, :process, ^active_turn_worker_pid, :shutdown},
                   1_000

    assert_receive {:DOWN, ^socket_ref, :process, ^socket_pid, _reason}, 1_000
    assert %{active_turn: nil, downstream: nil} = await_owner_cleared(owner)
    refute_received {:local_owner_bridge_submitter_result, _result}
  end

  test "active upstream request completes when downstream exits first", context do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["delta-before-exit", "delta-after-exit"]
      )

    {:ok, owner} = start_owner(context, upstream: upstream, idle_shutdown_ms: 1)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    target = collector(self(), :downstream_exit)

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: target,
        correlation_id: "corr-downstream-exit"
      })

    submit_task =
      Task.async(fn -> WebsocketOwnerSession.submit_frame(owner, downstream, @sentinel) end)

    assert_receive {:collected_owner_frame, :downstream_exit,
                    {:websocket_owner_frame, "corr-downstream-exit", 1,
                     {:data, "delta-before-exit"}}}

    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}

    target_ref = Process.monitor(target)
    Process.unlink(target)
    Process.exit(target, :shutdown)
    assert_receive {:DOWN, ^target_ref, :process, ^target, :shutdown}

    assert %{active_turn: active_turn, downstream: nil, idle_shutdown_ref: nil} =
             :sys.get_state(owner)

    assert is_map(active_turn)
    assert Process.alive?(owner)

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})
    assert :ok = Task.await(submit_task, 1_000)

    owner_ref = Process.monitor(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
    refute_received {:collected_owner_frame, :downstream_exit, _message}
  end

  @tag :owner_exit_persistence_failure
  test "owner exit persistence failure emits sanitized observability", context do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    codex_session_id = Ecto.UUID.generate()
    owner_lease_token = "owner-token-#{@sentinel}"

    persistence = %{
      release_owner_lease: fn ^codex_session_id, ^owner_lease_token, "owner_drained" ->
        {:error, :owner_unavailable}
      end,
      interrupt_codex_session: fn ^codex_session_id,
                                  %RequestOptions{
                                    runtime: %{interrupt_reason: "owner_drained"},
                                    continuity: %{reconnect_window_seconds: 300}
                                  } ->
        raise "#{@sentinel} interrupt failure"
      end
    }

    logs =
      capture_log(fn ->
        assert {:ok, owner} =
                 WebsocketOwnerSession.start_owner(
                   codex_session_id: codex_session_id,
                   owner_lease_token: owner_lease_token,
                   owner_instance_id: context.owner_instance_id,
                   upstream: upstream,
                   persistence: persistence
                 )

        assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

        owner_ref = Process.monitor(owner)
        assert :ok = GenServer.stop(owner)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
      end)

    assert logs =~ "websocket owner exit persistence failed"
    assert logs =~ "codex_session_id=#{codex_session_id}"
    assert logs =~ "operation=release_owner_lease"
    assert logs =~ "reason_class=owner_unavailable"
    assert logs =~ "operation=interrupt_codex_session"
    assert logs =~ "reason_class=RuntimeError"
    assert logs =~ "owner_exit_reason=owner_drained"
    assert logs =~ "recovery_hint=task_7_owner_exit_recovery"
    refute logs =~ owner_lease_token
    refute logs =~ context.owner_lease_token
    refute logs =~ @sentinel
  end

  defp await_owner_unavailable(codex_session_id, attempts \\ 100)

  defp await_owner_unavailable(codex_session_id, attempts) when attempts > 0 do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:error, :owner_unavailable} = unavailable ->
        unavailable

      {:ok, _pid} ->
        yield_once({:await_owner_unavailable, codex_session_id, attempts})
        await_owner_unavailable(codex_session_id, attempts - 1)
    end
  end

  defp await_owner_unavailable(codex_session_id, 0),
    do: WebsocketOwnerSession.lookup(codex_session_id)

  defp await_fresh_owner(context, upstream, old_owner, attempts \\ 100)

  defp await_fresh_owner(context, upstream, old_owner, attempts) when attempts > 0 do
    case start_owner(context, upstream: upstream) do
      {:ok, fresh_owner} when fresh_owner != old_owner ->
        {:ok, fresh_owner}

      {:ok, owner, :existing} when owner != old_owner and is_pid(owner) ->
        if Process.alive?(owner) do
          {:ok, owner}
        else
          yield_once({:await_fresh_owner, context.codex_session_id, attempts})
          await_fresh_owner(context, upstream, old_owner, attempts - 1)
        end

      _other ->
        yield_once({:await_fresh_owner, context.codex_session_id, attempts})
        await_fresh_owner(context, upstream, old_owner, attempts - 1)
    end
  end

  defp await_fresh_owner(context, upstream, _old_owner, 0),
    do: start_owner(context, upstream: upstream)

  defp cleanup_owner_session(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner} ->
        owner_ref = Process.monitor(owner)
        _result = GenServer.stop(owner, :normal, 1_000)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        after
          1_000 -> :ok
        end

      {:error, :owner_unavailable} ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp yield_once(message) do
    send(self(), message)

    receive do
      ^message -> :ok
    end
  end

  defp await_active_turn_cleared(owner, attempts \\ 100)

  defp await_active_turn_cleared(owner, attempts) when attempts > 0 do
    case :sys.get_state(owner) do
      %{active_turn: nil} = state ->
        state

      _state ->
        yield_once({:await_active_turn_cleared, owner, attempts})
        await_active_turn_cleared(owner, attempts - 1)
    end
  end

  defp await_active_turn_cleared(owner, 0), do: :sys.get_state(owner)

  defp await_owner_cleared(owner, attempts \\ 100)

  defp await_owner_cleared(owner, attempts) when attempts > 0 do
    case :sys.get_state(owner) do
      %{active_turn: nil, downstream: nil} = state ->
        state

      _state ->
        yield_once({:await_owner_cleared, owner, attempts})
        await_owner_cleared(owner, attempts - 1)
    end
  end

  defp await_owner_cleared(owner, 0), do: :sys.get_state(owner)

  defp await_pending_terminal_result(owner) do
    deadline =
      System.monotonic_time(:millisecond) + @pending_terminal_observation_timeout_ms

    await_pending_terminal_result_until(owner, deadline)
  end

  defp await_pending_terminal_result_until(owner, deadline) do
    state = :sys.get_state(owner)

    case state do
      %{active_turn: %{pending_result: pending_result}} = state when not is_nil(pending_result) ->
        state

      _state ->
        if System.monotonic_time(:millisecond) >= deadline do
          state
        else
          receive do
          after
            1 -> await_pending_terminal_result_until(owner, deadline)
          end
        end
    end
  end

  defp start_pending_terminal_turn(context, label, owner_opts \\ []) do
    terminal_frame = terminal_frame("response.completed", "resp_#{label}")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    {:ok, owner} = start_owner(context, Keyword.put(owner_opts, :upstream, upstream))
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target(label))

    submitter = pending_submitter(self(), owner, downstream, label)
    barriers = await_two_sender_barriers(controls)

    assert %{active_turn: %{task_ref: task_ref, task_pid: task_pid}} = :sys.get_state(owner)
    release_controlled(barriers, controls, :task_result)
    %{active_turn: active_turn} = await_pending_terminal_result(owner)

    assert active_turn.pending_result ==
             terminal_result(terminal_frame, "response.completed")

    assert active_turn.task_ref == nil

    %{
      active_turn: active_turn,
      barriers: barriers,
      context: context,
      controls: controls,
      downstream: downstream,
      label: label,
      owner: owner,
      submitter: submitter,
      task_pid: task_pid,
      task_ref: task_ref,
      terminal_frame: terminal_frame
    }
  end

  defp pending_submitter(parent, owner, downstream, label) do
    spawn(fn ->
      outcome =
        try do
          {:return, WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())}
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:pending_submitter_outcome, label, outcome})
    end)
  end

  defp release_pending_terminal_sender(pending) do
    release_controlled(pending.barriers, pending.controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, pending.controls)
    release_controlled(terminal_barrier, pending.controls, :terminal_frames)
  end

  defp release_abandoned_terminal_sender(pending) do
    release_pending_terminal_sender(pending)
    refute Process.alive?(pending.submitter)
  end

  defp assert_stale_messages_do_not_settle_fresh_turn(context, stale, label) do
    terminal_frame = terminal_frame("response.completed", "resp_#{label}")
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        terminal_frames: [terminal_frame],
        task_result: terminal_result(terminal_frame, "response.completed")
      )

    assert {:ok, owner} = await_fresh_owner(context, upstream, stale.owner)
    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target(label))

    assert_stale_messages_do_not_settle_next_turn(
      owner,
      downstream,
      controls,
      stale,
      terminal_frame
    )
  end

  defp assert_stale_messages_do_not_settle_next_turn(
         owner,
         downstream,
         controls,
         stale,
         terminal_frame
       ) do
    correlation_id = downstream.correlation_id
    epoch = downstream.epoch

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    barriers = await_two_sender_barriers(controls)
    assert %{active_turn: %{ref: next_turn_ref}} = :sys.get_state(owner)

    send(owner, {:websocket_owner_upstream_frame, stale.active_turn.ref, stale.terminal_frame})

    {stale_turn_ref, stale_timer_token} = stale.active_turn.terminal_delivery_timeout
    send(owner, {:websocket_owner_terminal_delivery_timeout, stale_turn_ref, stale_timer_token})
    send(owner, {:DOWN, stale.task_ref, :process, stale.task_pid, :shutdown})

    assert %{active_turn: %{ref: ^next_turn_ref, pending_result: nil}} = :sys.get_state(owner)
    refute_received {:websocket_owner_frame, ^correlation_id, ^epoch, _payload}

    release_controlled(barriers, controls, :nonterminal_frames)
    terminal_barrier = await_controlled_barrier(:terminal_frames, controls)
    release_controlled(terminal_barrier, controls, :terminal_frames)
    release_controlled(barriers, controls, :task_result)

    assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, {:data, ^terminal_frame}}

    assert Task.await(submit_task, 1_000) ==
             terminal_result(terminal_frame, "response.completed")

    assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, :complete}
    refute_received {:websocket_owner_frame, ^correlation_id, ^epoch, :complete}
    assert %{active_turn: nil} = :sys.get_state(owner)
  end

  defp await_two_sender_barriers(controls) do
    task_result = await_controlled_barrier(:task_result, controls)
    nonterminal_frames = await_controlled_barrier(:nonterminal_frames, controls)
    %{task_result: task_result, nonterminal_frames: nonterminal_frames}
  end

  defp await_controlled_barrier(stage, controls) do
    release_ref = Map.fetch!(controls, stage)

    assert_receive {:websocket_owner_harness_controlled_barrier, ^stage, barrier_pid,
                    ^release_ref},
                   1_000

    barrier_pid
  end

  defp release_controlled(barriers, controls, stage) when is_map(barriers) do
    barriers
    |> Map.fetch!(stage)
    |> release_controlled(controls, stage)
  end

  defp release_controlled(barrier_pid, controls, stage) when is_pid(barrier_pid) do
    WebsocketOwnerNodeHarness.release_controlled(barrier_pid, controls, stage)
  end

  defp controlled_timer_task(test_pid, owner, controls, {turn_ref, timer_token}) do
    Task.async(fn ->
      WebsocketOwnerNodeHarness.controlled_timer_message(
        test_pid,
        owner,
        controls,
        {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token}
      )
    end)
  end

  defp controlled_terminal_downstream_sender(test_pid, controls, result) do
    fn pid, message ->
      if terminal_downstream_message?(message) do
        WebsocketOwnerNodeHarness.controlled_result(
          test_pid,
          controls,
          :downstream_send_result,
          result
        )
      else
        send(pid, message)
        :ok
      end
    end
  end

  defp terminal_downstream_message?(
         {:websocket_owner_frame, _correlation_id, _epoch, {:data, payload}}
       ),
       do: terminal_payload?(payload)

  defp terminal_downstream_message?(_message), do: false

  defp terminal_payload?(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type}} ->
        type in [
          "response.completed",
          "response.done",
          "response.failed",
          "response.incomplete",
          "error"
        ]

      _result ->
        false
    end
  end

  defp cancel_owner_timer(timer_ref) when is_reference(timer_ref) do
    assert Process.cancel_timer(timer_ref) != false
  end

  defp unique_owner_context(context, label) do
    codex_session_id = "#{context.codex_session_id}-#{label}"
    on_exit(fn -> cleanup_owner_session(codex_session_id) end)
    %{context | codex_session_id: codex_session_id}
  end

  defp start_owner(context, opts) do
    WebsocketOwnerSession.start_owner(
      Keyword.merge(opts,
        codex_session_id: context.codex_session_id,
        owner_lease_token: context.owner_lease_token,
        owner_instance_id: context.owner_instance_id
      )
    )
  end

  defp start_supervised_owner(context, opts) do
    start_supervised!(%{
      id: {WebsocketOwnerSession, context.codex_session_id},
      restart: :temporary,
      start:
        {WebsocketOwnerSession, :start_link,
         [
           Keyword.merge(opts,
             codex_session_id: context.codex_session_id,
             owner_lease_token: context.owner_lease_token,
             owner_instance_id: context.owner_instance_id
           )
         ]}
    })
  end

  # Raises the primary Logger level only inside the capture window so nothing
  # emitted outside it (owner startup, on_exit cleanup) can leak to the
  # console; capture_log's :level option alone does not raise the primary
  # level, so info-level lines would otherwise never fire.
  defp capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()

    try do
      Logger.configure(level: :info)
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp observe_owner_exit(context, :idle_expiry) do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    owner = start_supervised_owner(context, upstream: upstream, idle_shutdown_ms: 1)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("idle-exit-metadata")
             )

    owner_ref = Process.monitor(owner)

    logs =
      capture_info_log(fn ->
        assert :ok = WebsocketOwnerSession.detach_downstream(owner, downstream)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
      end)

    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
    owner_exit_observation(logs, context.codex_session_id)
  end

  defp observe_owner_exit(context, :rollout_deadline_cut) do
    block_ref = make_ref()

    upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(),
        block_ref: block_ref,
        messages: ["rollout-cut-before-deadline", "unreachable-after-rollout-cut"]
      )

    owner = start_supervised_owner(context, upstream: upstream)
    assert_receive {:websocket_owner_harness_upstream_started, upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("rollout-deadline-cut-metadata")
             )

    parent = self()

    submitter =
      spawn(fn ->
        outcome =
          try do
            {:return,
             WebsocketOwnerSession.submit_frame(owner, downstream, "rollout-cut-request")}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {:rollout_deadline_cut_submitter_outcome, outcome})
      end)

    submitter_ref = Process.monitor(submitter)

    assert_receive {:websocket_owner_frame, "rollout-deadline-cut-metadata", 1,
                    {:data, "rollout-cut-before-deadline"}}

    assert_receive {:websocket_owner_harness_barrier, barrier_pid, ^block_ref}

    owner_ref = Process.monitor(owner)
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    deadline = harness.deadline

    logs =
      capture_info_log(fn ->
        drain_task =
          Task.async(fn ->
            RolloutDrain.start_drain(
              [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
                WebsocketRolloutDrainSupport.deadline_options(deadline)
            )
          end)

        assert_receive {:rollout_drain_deadline_wait, ^deadline, 10}

        refute_received {:websocket_owner_frame, "rollout-deadline-cut-metadata", 1,
                         {:error, :owner_drained, _safe_payload}}

        assert Process.alive?(owner)
        assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)

        assert_receive {:websocket_owner_frame, "rollout-deadline-cut-metadata", 1,
                        {:error, :owner_drained, _safe_payload}}

        assert_receive {:websocket_owner_frame, "rollout-deadline-cut-metadata", 1, :complete}
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

        assert %{
                 result: :ok,
                 owners_seen: 1,
                 owners_drained: 1,
                 owners_idle: 0,
                 owners_failed: 0,
                 turns_completed: 0,
                 turns_aborted: 1,
                 timeout_ms: 25,
                 already_draining?: false
               } = Task.await(drain_task, 1_000)

        assert WebsocketRolloutDrainSupport.VirtualDeadline.waiter_pids(deadline) == []
      end)

    assert_receive {:websocket_owner_harness_upstream_closed, ^upstream_pid}
    assert_receive {:rollout_deadline_cut_submitter_outcome, {:exit, _reason}}
    assert_receive {:DOWN, ^submitter_ref, :process, ^submitter, _reason}

    send(barrier_pid, {:websocket_owner_harness_release, block_ref})

    refute_received {:websocket_owner_frame, "rollout-deadline-cut-metadata", 1,
                     {:data, "unreachable-after-rollout-cut"}}

    owner_exit_observation(logs, context.codex_session_id)
  end

  defp owner_exit_observation(logs, codex_session_id) do
    assert logs =~ "websocket owner terminated"
    assert logs =~ "codex_session_id=#{codex_session_id}"

    %{
      logs: logs,
      metadata: %{
        owner_exit_reason: logged_owner_exit_reason(logs),
        owner_exit_cause: logged_owner_exit_cause(logs),
        release_reason: released_lease!(codex_session_id).metadata["release_reason"],
        persisted_owner_exit_cause: released_lease!(codex_session_id).metadata["owner_exit_cause"]
      }
    }
  end

  defp logged_owner_exit_reason(logs) do
    assert [_, reason] = Regex.run(~r/owner_exit_reason=([a-z_]+)/, logs)
    reason
  end

  defp logged_owner_exit_cause(logs) do
    case Regex.run(~r/owner_exit_cause=([a-z_]+)/, logs) do
      [_, cause] -> cause
      nil -> nil
    end
  end

  defp auth_context do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp put_owner_idle_timeout(timeout) do
    settings = OperationalSettings.current()

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %{settings | websocket_owner_idle_timeout_ms: timeout}
    )
  end

  defp restore_operational_settings(nil),
    do: Application.delete_env(:codex_pooler, OperationalSettings)

  defp restore_operational_settings(previous_settings),
    do: Application.put_env(:codex_pooler, OperationalSettings, previous_settings)

  defp restore_owner_forwarding(nil),
    do: Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)

  defp restore_owner_forwarding(previous_forwarding),
    do:
      Application.put_env(
        :codex_pooler,
        :websocket_owner_forwarding_enabled,
        previous_forwarding
      )

  defp db_owner_context do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(%{pool: pool, api_key: api_key}, %{
               accepted_turn_state: "owner-renewal-#{System.unique_integer([:positive])}",
               owner_instance_id: Atom.to_string(node())
             })

    session = Repo.get!(CodexSession, session.id)

    %{
      codex_session_id: session.id,
      owner_lease_token: session.owner_lease_token,
      owner_instance_id: session.owner_instance_id,
      session: session
    }
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        limit: 1
    )
  end

  defp released_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "released",
        limit: 1
    )
  end

  defp set_owner_lease_expiry!(session_id, expires_at) do
    Repo.get!(CodexSession, session_id)
    |> Ecto.Changeset.change(%{owner_lease_expires_at: expires_at, updated_at: expires_at})
    |> Repo.update!()

    active_lease!(session_id)
    |> Ecto.Changeset.change(%{expires_at: expires_at, updated_at: expires_at})
    |> Repo.update!()
  end

  defp downstream_target(correlation_id), do: %{pid: self(), correlation_id: correlation_id}

  defp websocket_request do
    %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "request-frame",
      timeouts: %{},
      writer: fn _frame -> :ok end
    }
  end

  defp terminal_frame(type, response_id) do
    response =
      if type in ["response.completed", "response.done"] do
        %{"id" => response_id, "status" => "completed"}
      else
        %{"id" => response_id, "status" => String.replace_prefix(type, "response.", "")}
      end

    Jason.encode!(%{"type" => type, "response" => response})
  end

  defp terminal_result(terminal_frame, terminal) do
    {:ok,
     %{
       body: "data: #{terminal_frame}\n\n",
       terminal: terminal,
       status: 200,
       headers: [],
       websocket_frame_headers: %{}
     }}
  end

  defp interrupted_upstream(parent, frame) do
    %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, writer ->
        send(parent, {:interrupted_upstream_writer, frame})
        _message = writer.(frame, TerminalDiscriminator.classify(frame))
        interrupted_result()
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp interrupted_result do
    {:error,
     %{
       body: "",
       forward_error_body?: true,
       reason: :upstream_stream_error,
       transport_failure: %{"reason" => "upstream_stream_error"}
     }}
  end

  defp exit_controlled_upstream(parent, scenario) do
    start = fn ->
      {:ok, upstream_pid} = Agent.start_link(fn -> 0 end)
      send(parent, {:exit_controlled_upstream_started, scenario, upstream_pid})
      {:ok, upstream_pid}
    end

    send_request = fn upstream_pid, _request, writer ->
      send_count = Agent.get_and_update(upstream_pid, fn count -> {count + 1, count + 1} end)

      if scenario == :post_visible do
        writer.(
          "visible-before-upstream-exit",
          %TerminalDiscriminator{terminal: nil}
        )
      end

      send(parent, {:exit_controlled_upstream_send, scenario, upstream_pid, send_count})
      Process.monitor(upstream_pid)

      receive do
        {:DOWN, _ref, :process, ^upstream_pid, reason} -> {:error, reason}
      end
    end

    close = fn upstream_pid ->
      send(parent, {:exit_controlled_upstream_closed, scenario, upstream_pid})
      if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      :ok
    end

    upstream = %{start: start, send: send_request, close: close}
    {:ok, upstream_pid} = start.()
    Process.unlink(upstream_pid)

    wrapped_upstream = %{
      upstream
      | start: fn ->
          Process.link(upstream_pid)
          {:ok, upstream_pid}
        end
    }

    {wrapped_upstream, upstream_pid}
  end

  defp owner_exit_submitter(parent, owner, downstream, scenario, public? \\ false) do
    spawn(fn ->
      downstream = if public?, do: Map.put(downstream, :owner_turn_id, self()), else: downstream

      outcome =
        try do
          {:return, WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())}
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:owner_exit_submitter_outcome, scenario, outcome})
    end)
  end

  defp owner_exit_persistence_spy(parent, context) do
    %{
      release_owner_lease: fn session_id, lease_token, reason, cause ->
        send(parent, {:owner_exit_release, session_id, lease_token, reason, cause})
        :ok
      end,
      interrupt_codex_session: fn session_id, %RequestOptions{} = opts ->
        send(parent, {:owner_exit_interrupt, session_id, opts.runtime.interrupt_reason})
        {:ok, :interrupted}
      end,
      renew_owner_token: fn _session_id, _lease_token, _opts ->
        {:ok,
         %{
           owner_lease_token: context.owner_lease_token,
           owner_instance_id: context.owner_instance_id
         }}
      end
    }
  end

  defp assert_owner_exit_persisted_once(context) do
    assert_receive {:owner_exit_release, session_id, lease_token, "owner_crashed", nil}
    assert session_id == context.codex_session_id
    assert lease_token == context.owner_lease_token
    assert_receive {:owner_exit_interrupt, ^session_id, "owner_crashed"}
    refute_received {:owner_exit_release, _session_id, _lease_token, _reason, _cause}
    refute_received {:owner_exit_interrupt, _session_id, _reason}
  end

  defp start_output_commit_probe(context, label) do
    upstream = interrupted_upstream(self(), "visible-#{label}")
    {:ok, owner} = start_owner(context, upstream: upstream)

    {:ok, stable_downstream} =
      WebsocketOwnerSession.attach_downstream(owner, downstream_target(label))

    owner_turn_id = self()
    downstream = Map.put(stable_downstream, :owner_turn_id, owner_turn_id)

    submit_task =
      Task.async(fn ->
        WebsocketOwnerSession.submit_request(owner, downstream, websocket_request())
      end)

    assert_receive {:websocket_owner_frame, ^label, epoch, ^owner_turn_id,
                    {:data, "visible-" <> ^label}}

    assert_receive {:websocket_owner_output_commit_probe, ^label, ^epoch, ^owner_turn_id,
                    active_turn_ref, ^owner, probe_ref}

    %{
      owner: owner,
      stable_downstream: stable_downstream,
      downstream: downstream,
      owner_turn_id: owner_turn_id,
      correlation_id: label,
      epoch: epoch,
      active_turn_ref: active_turn_ref,
      probe_ref: probe_ref,
      submit_task: submit_task
    }
  end

  defp receive_probe_messages(parent) do
    receive do
      message ->
        send(parent, {:probe_downstream_message, message})
        receive_probe_messages(parent)
    end
  end

  defp collector(parent, label) do
    spawn_link(fn -> collector_loop(parent, label) end)
  end

  defp collector_loop(parent, label) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        send(parent, {:collected_owner_frame, label, message})
        collector_loop(parent, label)
    end
  end
end
