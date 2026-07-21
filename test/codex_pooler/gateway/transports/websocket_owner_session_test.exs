defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSessionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession}
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway

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
    previous_level = Logger.level()

    Logger.configure(level: :info)

    on_exit(fn -> Logger.configure(level: previous_level) end)

    logs =
      capture_log([level: :info], fn ->
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

  defp start_owner(context, opts) do
    WebsocketOwnerSession.start_owner(
      Keyword.merge(opts,
        codex_session_id: context.codex_session_id,
        owner_lease_token: context.owner_lease_token,
        owner_instance_id: context.owner_instance_id
      )
    )
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

  defp set_owner_lease_expiry!(session_id, expires_at) do
    Repo.get!(CodexSession, session_id)
    |> Ecto.Changeset.change(%{owner_lease_expires_at: expires_at, updated_at: expires_at})
    |> Repo.update!()

    active_lease!(session_id)
    |> Ecto.Changeset.change(%{expires_at: expires_at, updated_at: expires_at})
    |> Repo.update!()
  end

  defp downstream_target(correlation_id), do: %{pid: self(), correlation_id: correlation_id}

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
