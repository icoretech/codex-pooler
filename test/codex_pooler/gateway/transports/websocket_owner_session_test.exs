defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSessionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession}
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession
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

    request = %UpstreamWebSocketSession.Request{
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

    request = %UpstreamWebSocketSession.Request{
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

    assert {:current_stacktrace, stacktrace} =
             Process.info(submit_task.pid, :current_stacktrace)

    assert stack_has_mfa?(stacktrace, WebsocketOwnerSession, :await_reserved_frame, 3)

    assert {:ok, second_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: second_target,
               correlation_id: "corr-second"
             })

    assert second_downstream.epoch == 2

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

  defp start_owner(context, opts) do
    WebsocketOwnerSession.start_owner(
      Keyword.merge(opts,
        codex_session_id: context.codex_session_id,
        owner_lease_token: context.owner_lease_token,
        owner_instance_id: context.owner_instance_id
      )
    )
  end

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

  defp stack_has_mfa?(stacktrace, module, function, arity) do
    Enum.any?(stacktrace, fn
      {^module, ^function, ^arity, _location} -> true
      _frame -> false
    end)
  end
end
