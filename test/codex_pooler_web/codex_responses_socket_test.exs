defmodule CodexPoolerWeb.CodexResponsesSocketTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Events
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, RolloutDrain}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Websocket.{Adapter, ResponseTask}
  alias CodexPooler.InstanceSettings.{Cache, Settings}
  alias CodexPooler.Pools.Membership
  alias CodexPoolerWeb.CodexResponsesSocket

  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 0]

  @applied_message_tag Cache
  @cache_key {Cache, :current}
  @cache_version 1
  @revocation_close {1008, "client IP is no longer allowed"}
  @api_key_revocation_close {1008, "api key is no longer active"}

  test "matching newer API-key event closes once without firewall telemetry or content leakage" do
    api_key_id = Ecto.UUID.generate()
    pool_id = Ecto.UUID.generate()
    state = api_key_socket_state(api_key_id, pool_id, 4)
    telemetry_id = attach_firewall_telemetry()
    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    event = api_key_event(api_key_id, pool_id, "paused", 5)

    assert {:stop, :normal, @api_key_revocation_close, closed_state} =
             CodexResponsesSocket.handle_info({Events, event}, state)

    assert closed_state.api_key_revoked?
    assert closed_state.api_key_close_sent?
    assert closed_state.api_key_disabling_epoch == 5
    refute_receive {:firewall_denied, _, _}

    assert {:ok, ^closed_state} = CodexResponsesSocket.handle_info({Events, event}, closed_state)

    assert {:ok, ^closed_state} =
             CodexResponsesSocket.handle_in(
               {~s({"input":"credential-bearing queued content"}), [opcode: :text]},
               closed_state
             )

    refute inspect(closed_state) =~ "credential-bearing queued content"
    refute_receive {:firewall_denied, _, _}
  end

  test "pool-scoped PubSub delivers the disabling event to a socket process" do
    api_key_id = Ecto.UUID.generate()
    pool_id = Ecto.UUID.generate()
    parent = self()
    state = api_key_socket_state(api_key_id, pool_id, 0)

    socket_pid =
      spawn(fn ->
        :ok = Events.subscribe_pool(pool_id, "pools")
        send(parent, {:socket_subscribed, self()})

        receive do
          message ->
            send(parent, {:socket_result, CodexResponsesSocket.handle_info(message, state)})
        end
      end)

    monitor = Process.monitor(socket_pid)
    assert_receive {:socket_subscribed, ^socket_pid}

    assert {:ok, _event} =
             Events.broadcast_pools(pool_id, "api_key_status_updated", %{
               api_key_id: api_key_id,
               pool_id: pool_id,
               status: "paused",
               runtime_revocation_epoch: 1
             })

    assert_receive {:socket_result,
                    {:stop, :normal, @api_key_revocation_close,
                     %{api_key_close_sent?: true, api_key_disabling_epoch: 1}}}

    assert_receive {:DOWN, ^monitor, :process, ^socket_pid, :normal}
  end

  test "unrelated stale and non-disabling API-key events leave a fresh socket active" do
    api_key_id = Ecto.UUID.generate()
    pool_id = Ecto.UUID.generate()
    state = api_key_socket_state(api_key_id, pool_id, 7)

    events = [
      api_key_event(Ecto.UUID.generate(), pool_id, "paused", 8),
      api_key_event(api_key_id, Ecto.UUID.generate(), "paused", 8),
      api_key_event(api_key_id, pool_id, "paused", 7),
      api_key_event(api_key_id, pool_id, "active", 8)
    ]

    final_state =
      Enum.reduce(events, state, fn event, current_state ->
        assert {:ok, next_state} =
                 CodexResponsesSocket.handle_info({Events, event}, current_state)

        refute next_state.api_key_revoked?
        refute next_state.api_key_close_sent?
        next_state
      end)

    assert final_state.api_key_runtime_epoch == 7
  end

  test "epoch-less legacy pause re-reads durable authorization and ignores delayed post-resume event" do
    setup = active_api_key_fixture()
    scope = fixture_owner_scope()
    state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
    legacy_event = api_key_event(setup.api_key.id, setup.pool.id, "paused", :legacy)

    assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)
    assert paused_key.runtime_revocation_epoch == 1

    assert {:stop, :normal, @api_key_revocation_close, paused_state} =
             CodexResponsesSocket.handle_info({Events, legacy_event}, state)

    assert paused_state.api_key_disabling_epoch == 1

    assert {:ok, resumed_key} = Access.resume_api_key(scope, paused_key)
    assert resumed_key.status == "active"

    fresh_state = api_key_socket_state(setup.api_key.id, setup.pool.id, 1)

    assert {:ok, checked_state} =
             CodexResponsesSocket.handle_info({Events, legacy_event}, fresh_state)

    refute checked_state.api_key_revoked?
    refute checked_state.api_key_close_sent?
  end

  test "missed event closes on the next frame without starting queued work" do
    setup = active_api_key_fixture()
    scope = fixture_owner_scope()
    state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
    secret_payload = ~s({"input":"must-not-reach-upstream","token":"frame-secret"})

    assert {:ok, paused_key} = Access.pause_api_key(scope, setup.api_key)

    assert {:stop, :normal, @api_key_revocation_close, closed_state} =
             CodexResponsesSocket.handle_in({secret_payload, [opcode: :text]}, state)

    assert closed_state.api_key_disabling_epoch == paused_key.runtime_revocation_epoch
    assert MapSet.size(closed_state.tasks) == 0
    assert :queue.is_empty(closed_state.queued_response_payloads)
    refute inspect(closed_state) =~ "must-not-reach-upstream"
    refute inspect(closed_state) =~ "frame-secret"
  end

  test "revocation drops queued work while an admitted turn drains final bytes before close" do
    api_key_id = Ecto.UUID.generate()
    pool_id = Ecto.UUID.generate()
    task_pid = self()

    state =
      api_key_socket_state(api_key_id, pool_id, 2, %{
        tasks: MapSet.new([task_pid]),
        queued_response_payloads: :queue.from_list(["queued-secret-content"])
      })

    event = api_key_event(api_key_id, pool_id, "revoked", 3)

    assert {:ok, revoked_state} = CodexResponsesSocket.handle_info({Events, event}, state)
    assert revoked_state.api_key_revoked?
    refute revoked_state.api_key_close_sent?
    assert :queue.is_empty(revoked_state.queued_response_payloads)

    final_frame = ~s({"type":"response.done","response":{"id":"resp_final_safe"}})

    assert {:push, {:text, ^final_frame}, draining_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, final_frame},
               revoked_state
             )

    assert {:stop, :normal, @api_key_revocation_close, closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid, :ok},
               draining_state
             )

    assert closed_state.api_key_close_sent?
    assert MapSet.size(closed_state.tasks) == 0
    refute inspect(closed_state) =~ "queued-secret-content"
  end

  test "internal stale authorization result maps to close-only without a synthetic error frame" do
    task_pid = self()

    state =
      api_key_socket_state(Ecto.UUID.generate(), Ecto.UUID.generate(), 9, %{
        tasks: MapSet.new([task_pid])
      })

    result =
      {:socket_response_result, :local_complete,
       {:error,
        %{
          code: :api_key_runtime_epoch_stale,
          message: "must remain internal",
          disabling_epoch: 10
        }}}

    assert {:stop, :normal, @api_key_revocation_close, closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid, result},
               state
             )

    assert closed_state.api_key_disabling_epoch == 10
    assert closed_state.api_key_close_sent?
    refute inspect(closed_state) =~ "must remain internal"
  end

  test "native and public websocket overload terminals use the shared Codex error vocabulary" do
    for internal_reason <- ["bulkhead_rejected", "bulkhead_queue_timeout"] do
      payload =
        internal_reason
        |> then(&Admission.overload_error(%{code: &1, route_class: "proxy_websocket"}))
        |> Adapter.websocket_error()

      assert payload == %{
               "type" => "error",
               "status" => 503,
               "error" => %{
                 "code" => "server_is_overloaded",
                 "message" => "gateway route class is temporarily overloaded",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      refute Jason.encode!(payload) =~ internal_reason
    end
  end

  test "future applied metadata evaluates only the current published snapshot" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()

    allowed = firewall_settings(original, original.lock_version + 1, ["127.0.0.1"])
    :ok = publish_cache_snapshot(allowed)
    state = firewall_socket_state(original.lock_version)

    assert {:ok, future_event_state} =
             CodexResponsesSocket.handle_info(
               applied_message(allowed.lock_version + 1),
               state
             )

    refute future_event_state.firewall_revoked?
    assert future_event_state.firewall_applied_version == allowed.lock_version

    assert {:ok, allowed_state} =
             CodexResponsesSocket.handle_info(
               applied_message(allowed.lock_version),
               future_event_state
             )

    refute allowed_state.firewall_revoked?
    assert allowed_state.firewall_applied_version == allowed.lock_version
  end

  @tag :socket_request_regression
  test "stale and duplicate applied metadata re-evaluate only the current allowed snapshot" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()
    allowed = firewall_settings(original, 8, ["127.0.0.1"])
    :ok = publish_cache_snapshot(allowed)

    for applied_version <- [2, 7] do
      state = firewall_socket_state(7)

      assert {:ok, evaluated_state} =
               CodexResponsesSocket.handle_info(applied_message(applied_version), state)

      refute evaluated_state.firewall_revoked?
      refute evaluated_state.firewall_close_sent?
      assert evaluated_state.firewall_applied_version == allowed.lock_version
    end
  end

  @tag :socket_request_regression
  test "lower applied version revokes a higher-watermark socket from the current snapshot" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()
    denied = firewall_settings(original, 2, ["203.0.113.10"])
    :ok = publish_cache_snapshot(denied)

    state =
      firewall_socket_state(7, %{
        queued_response_payloads: :queue.from_list(["queued payload"])
      })

    telemetry_id = attach_firewall_telemetry()
    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {result, logs} =
      ExUnit.CaptureLog.with_log([level: :warning], fn ->
        CodexResponsesSocket.handle_info(applied_message(2), state)
      end)

    assert {:stop, :normal, @revocation_close, revoked_state} = result
    assert revoked_state.firewall_applied_version == 7
    assert revoked_state.firewall_revoked?
    assert revoked_state.firewall_close_sent?
    assert MapSet.size(revoked_state.tasks) == 0
    assert :queue.is_empty(revoked_state.queued_response_payloads)

    assert_receive {:firewall_denied, measurements, metadata}
    assert measurements == %{count: 1}
    assert metadata == %{scope: "runtime", reason: "websocket_revoked"}

    assert length(Regex.scan(~r/ingress firewall denied/, logs)) == 1
    refute logs =~ "127.0.0.1"
    refute logs =~ "203.0.113.10"
    refute logs =~ "not_allowed"

    assert {:ok, ^revoked_state} =
             CodexResponsesSocket.handle_in({"must not dispatch", [opcode: :text]}, revoked_state)

    assert {:ok, ^revoked_state} =
             CodexResponsesSocket.handle_info(applied_message(2), revoked_state)

    allowed = firewall_settings(denied, 3, ["127.0.0.1"])
    :ok = publish_cache_snapshot(allowed)

    assert {:ok, ^revoked_state} =
             CodexResponsesSocket.handle_info(applied_message(3), revoked_state)

    refute_receive {:firewall_denied, _, _}
  end

  @tag :capture_log
  test "a locally applied cold-cache snapshot revokes an existing websocket" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    cold = Settings.fallback_default()
    :persistent_term.put(@cache_key, {@cache_version, cold})

    assert %Settings{source: :fallback_defaults, db_available?: false} = cold

    state = firewall_socket_state(0)

    assert {:stop, :normal, @revocation_close, revoked_state} =
             CodexResponsesSocket.handle_info(applied_message(cold.lock_version), state)

    assert revoked_state.firewall_revoked?
    assert revoked_state.firewall_close_sent?
    assert :queue.is_empty(revoked_state.queued_response_payloads)
  end

  test "idle revocation closes once and later reallow cannot reopen the latch" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()
    denied = firewall_settings(original, original.lock_version + 1, ["203.0.113.10"])
    :ok = publish_cache_snapshot(denied)
    state = firewall_socket_state(original.lock_version)

    telemetry_id = attach_firewall_telemetry()
    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {result, logs} =
      ExUnit.CaptureLog.with_log([level: :warning], fn ->
        CodexResponsesSocket.handle_info(applied_message(denied.lock_version), state)
      end)

    assert {:stop, :normal, @revocation_close, revoked_state} = result

    assert revoked_state.firewall_revoked?
    assert revoked_state.firewall_close_sent?

    assert_receive {:firewall_denied, %{count: 1},
                    %{scope: "runtime", reason: "websocket_revoked"}}

    assert length(Regex.scan(~r/ingress firewall denied/, logs)) == 1
    refute logs =~ "127.0.0.1"
    refute logs =~ "not_allowed"

    allowed = firewall_settings(denied, denied.lock_version + 1, ["127.0.0.1"])
    :ok = publish_cache_snapshot(allowed)

    assert {:ok, ^revoked_state} =
             CodexResponsesSocket.handle_info(
               applied_message(allowed.lock_version),
               revoked_state
             )

    assert {:ok, ^revoked_state} =
             CodexResponsesSocket.handle_in({"new frame", [opcode: :text]}, revoked_state)

    refute_receive {:firewall_denied, _, _}
  end

  @tag :capture_log
  test "busy revocation drains the admitted task, flushes its final frame, and drops queued work" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()
    denied = firewall_settings(original, original.lock_version + 1, ["203.0.113.10"])
    :ok = publish_cache_snapshot(denied)

    state =
      firewall_socket_state(original.lock_version, %{
        tasks: MapSet.new([self()]),
        queued_response_payloads: :queue.from_list(["queued payload"])
      })

    assert {:ok, revoked_state} =
             CodexResponsesSocket.handle_info(applied_message(denied.lock_version), state)

    assert revoked_state.firewall_revoked?
    refute revoked_state.firewall_close_sent?
    assert :queue.is_empty(revoked_state.queued_response_payloads)

    error = %{status: 500, code: :upstream_failed, message: "safe failure", param: nil}

    assert {:stop, :normal, @revocation_close, [{:text, final_frame}], closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, self(), {:error, error}},
               revoked_state
             )

    assert Jason.decode!(final_frame)["error"]["code"] == "upstream_failed"
    assert closed_state.firewall_close_sent?
    assert MapSet.size(closed_state.tasks) == 0
    assert :queue.is_empty(closed_state.queued_response_payloads)
  end

  @tag :capture_log
  test "busy public revocation retains the active stream id through the final error frame" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()
    denied = firewall_settings(original, original.lock_version + 1, ["203.0.113.10"])
    :ok = publish_cache_snapshot(denied)
    task_pid = owner_turn_pid()

    state =
      public_turn_state(task_pid, %{
        firewall_client_ip: {127, 0, 0, 1},
        firewall_applied_version: original.lock_version,
        firewall_revoked?: false,
        firewall_close_sent?: false,
        public_response_stream_id: "lane-revoked",
        queued_response_payloads:
          :queue.from_list([public_create_payload("lane-dropped", "dropped")])
      })

    assert {:ok, revoked_state} =
             CodexResponsesSocket.handle_info(applied_message(denied.lock_version), state)

    assert revoked_state.firewall_revoked?
    assert revoked_state.public_response_stream_id == "lane-revoked"
    assert :queue.is_empty(revoked_state.queued_response_payloads)

    error = %{status: 502, code: :upstream_failed, message: "safe failure", param: nil}

    {_result, logs} =
      with_native_turn_log(:info, fn ->
        assert {:stop, :normal, @revocation_close, [{:text, payload}], closed_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, task_pid, {:error, error}},
                   revoked_state
                 )

        assert Jason.decode!(payload)["stream_id"] == "lane-revoked"
        assert closed_state.public_response_stream_id == nil
        assert closed_state.public_responses_websocket_state == nil
        assert closed_state.firewall_close_sent?
      end)

    assert_native_turn_logs(logs, 1, "upstream_failed")
  end

  @tag :capture_log
  test "revoked task DOWN cannot start queued work or close twice" do
    snapshot = Cache.snapshot_for_test()
    on_exit(fn -> Cache.restore_for_test(snapshot) end)
    original = cached_settings()
    denied = firewall_settings(original, original.lock_version + 1, ["203.0.113.10"])
    :ok = publish_cache_snapshot(denied)

    task_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(task_pid), do: send(task_pid, :stop) end)
    monitor = Process.monitor(task_pid)

    state =
      firewall_socket_state(original.lock_version, %{
        tasks: MapSet.new([task_pid]),
        task_monitors: %{task_pid => monitor},
        queued_response_payloads: :queue.from_list(["queued payload"])
      })

    assert {:ok, revoked_state} =
             CodexResponsesSocket.handle_info(applied_message(denied.lock_version), state)

    assert {:stop, :normal, @revocation_close, closed_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, monitor, :process, task_pid, :normal},
               revoked_state
             )

    assert closed_state.firewall_close_sent?
    assert MapSet.size(closed_state.tasks) == 0
    assert :queue.is_empty(closed_state.queued_response_payloads)

    assert {:ok, ^closed_state} =
             CodexResponsesSocket.handle_info(
               {:DOWN, monitor, :process, task_pid, :normal},
               closed_state
             )
  end

  @tag :socket_lifecycle_pin
  test "PIN-P03 backend GET websocket preserves done and legacy JSON frame bytes" do
    task_pid = self()

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      native_turn_output_task_pids: MapSet.new()
    }

    frames = [
      ~s({"type":"response.done","response":{"id":"resp_pin_backend_get_done"}}),
      ~s({ "id" : "resp_pin_backend_get_legacy" }),
      ~s({"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_native_encrypted_args","name":"lookup_fixture","arguments":"{}","encrypted_function_args":[]}}),
      ~s({"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_native_encrypted_args_ordered","name":"lookup_fixture","arguments":"{}","encrypted_function_args":["a","bb"]}})
    ]

    for frame <- frames do
      assert {:push, {:text, pushed}, next_state} =
               CodexResponsesSocket.handle_info({:codex_response_chunk, task_pid, frame}, state)

      assert pushed == frame
      assert next_state.native_turn_output_task_pids == MapSet.new([task_pid])

      assert Map.drop(next_state, [
               :native_turn_output_task_pids,
               :response_task_terminals_accepted,
               :response_task_completed_terminals
             ]) ==
               Map.drop(state, [
                 :native_turn_output_task_pids,
                 :response_task_terminals_accepted,
                 :response_task_completed_terminals
               ])
    end
  end

  test "native socket keeps only provider-visible frames in its turn visibility latch" do
    task_pid = self()

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      native_turn_output_task_pids: MapSet.new()
    }

    for control_type <- ["codex.rate_limits", "codex.response.metadata"] do
      control = Jason.encode!(%{"type" => control_type})

      assert {:push, {:text, ^control}, control_state} =
               CodexResponsesSocket.handle_info({:codex_response_chunk, task_pid, control}, state)

      assert control_state.native_turn_output_task_pids == MapSet.new()
    end

    unknown_control = Jason.encode!(%{"type" => "codex.future_control"})

    assert {:push, {:text, ^unknown_control}, visible_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, unknown_control},
               state
             )

    assert visible_state.native_turn_output_task_pids == MapSet.new([task_pid])
  end

  @tag :socket_lifecycle_regression
  test "RED-R02 public GET wraps exact legacy success as response.completed" do
    task_pid = self()
    legacy_response = %{"id" => "resp_red_public_legacy", "custom" => %{"kept" => true}}
    state = public_turn_state(task_pid)

    assert {:push, {:text, payload}, _next_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, Jason.encode!(legacy_response)},
               state
             )

    assert Jason.decode!(payload) == %{
             "type" => "response.completed",
             "sequence_number" => 0,
             "response" => Map.put_new(legacy_response, "status", "completed")
           }

    refute Map.has_key?(Jason.decode!(payload), "stream_id")
  end

  test "public GET echoes the active accepted stream id" do
    suppress_response_task_logs(fn ->
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {public_create_payload("lane-active", "normal"), [opcode: :text]},
                 public_socket_state()
               )

      task_pid = state.public_response_task_pid
      assert is_pid(task_pid)

      frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "visible"})

      assert {:push, {:text, payload}, next_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_chunk, task_pid, frame},
                 state
               )

      assert Jason.decode!(payload)["stream_id"] == "lane-active"
      assert next_state.public_response_stream_id == "lane-active"
      cleanup_response_task(next_state, task_pid)
    end)
  end

  test "public response.create validates before dispatch and never echoes a rejected stream id" do
    invalid_payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => "gpt-test",
        "input" => "ignored",
        "stream_id" => "invalid/id"
      })

    state = public_socket_state()

    assert {:push, {:text, payload}, settled_state} =
             CodexResponsesSocket.handle_in({invalid_payload, [opcode: :text]}, state)

    decoded = Jason.decode!(payload)
    assert decoded["status"] == 400
    assert decoded["error"]["param"] == "stream_id"
    refute Map.has_key?(decoded, "stream_id")
    refute payload =~ "invalid/id"
    assert MapSet.size(settled_state.tasks) == 0
    assert settled_state.public_response_task_pid == nil
    assert settled_state.public_response_start_error_ref == nil
  end

  test "queued public creates keep stream ids isolated and start in FIFO order" do
    first = public_create_payload("lane-first", "first")
    second = public_create_payload("lane-second", "second")
    state = public_socket_state()

    assert {:ok, first_state} = CodexResponsesSocket.handle_in({first, [opcode: :text]}, state)
    first_task_pid = first_state.public_response_task_pid
    assert is_pid(first_task_pid)
    assert first_state.public_response_stream_id == "lane-first"

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in({second, [opcode: :text]}, first_state)

    assert [%{variant: :public_response_create, payload: %{"input" => [queued_input]}}] =
             :queue.to_list(queued_state.queued_response_payloads)

    assert queued_input["content"] |> Enum.at(0) |> Map.fetch!("text") == "second"
    assert queued_state.public_response_stream_id == "lane-first"
    cleanup_response_task(queued_state, first_task_pid)

    assert {:ok, second_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, first_task_pid, :ok},
               queued_state
             )

    second_task_pid = second_state.public_response_task_pid
    assert is_pid(second_task_pid)
    refute second_task_pid == first_task_pid
    assert second_state.public_response_stream_id == "lane-second"
    assert :queue.is_empty(second_state.queued_response_payloads)

    cleanup_response_task(second_state, second_task_pid)
  end

  test "anchored trigger-only native compact queues behind active lineage work" do
    lineage_task_pid = owner_turn_pid()
    on_exit(fn -> send(lineage_task_pid, :stop) end)

    payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => "gpt-test",
        "previous_response_id" => "resp_fixture_anchor",
        "input" => [%{"type" => "compaction_trigger"}],
        "stream" => true
      })

    state =
      public_turn_state(lineage_task_pid, %{
        opts: RequestOptions.for_websocket(%{}),
        public_response_task_pid: nil
      })

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    on_exit(fn ->
      Enum.each(queued_state.tasks, fn task_pid ->
        if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
      end)
    end)

    assert queued_state.tasks == MapSet.new([lineage_task_pid])

    assert [%{variant: :native_response_create, endpoint: "/backend-api/codex/responses/compact"}] =
             :queue.to_list(queued_state.queued_response_payloads)
  end

  test "two creates sharing a stream id retain FIFO turn ownership" do
    first = public_create_payload("lane-shared", "first")
    second = public_create_payload("lane-shared", "second")
    state = public_socket_state()

    assert {:ok, first_state} = CodexResponsesSocket.handle_in({first, [opcode: :text]}, state)
    first_task_pid = first_state.public_response_task_pid

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in({second, [opcode: :text]}, first_state)

    assert queued_state.public_response_stream_id == "lane-shared"

    assert [%{variant: :public_response_create, payload: %{"input" => [queued_input]}}] =
             :queue.to_list(queued_state.queued_response_payloads)

    assert queued_input["content"] |> Enum.at(0) |> Map.fetch!("text") == "second"
    cleanup_response_task(queued_state, first_task_pid)

    assert {:ok, second_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, first_task_pid, :ok},
               queued_state
             )

    assert second_state.public_response_stream_id == "lane-shared"
    assert second_state.public_response_task_pid != first_task_pid
    cleanup_response_task(second_state, second_state.public_response_task_pid)
  end

  test "public task failures echo the accepted stream id before cleanup" do
    error = %{status: 502, code: :synthetic_failure, message: "safe failure", param: nil}

    results = [
      {:response_task_failure, {:error, error}},
      {:response_task_result, {:error, error}, false},
      {:error, error}
    ]

    {_results, logs} =
      with_native_turn_log(:info, fn ->
        Enum.map(results, fn result ->
          task_pid = owner_turn_pid()
          state = public_turn_state(task_pid, %{public_response_stream_id: "lane-error"})

          assert {:push, {:text, payload}, settled_state} =
                   CodexResponsesSocket.handle_info(
                     {:codex_response_done, task_pid, result},
                     state
                   )

          assert Jason.decode!(payload)["stream_id"] == "lane-error"
          assert settled_state.public_response_stream_id == nil
          assert settled_state.public_responses_websocket_state == nil
          assert settled_state.public_response_task_pid == nil
        end)
      end)

    assert_native_turn_logs(logs, 2, "synthetic_failure")
  end

  test "prepared validation rejects an invalid previous response before owner retarget" do
    payload =
      %{
        "type" => "response.create",
        "model" => "gpt-test",
        "input" => "retarget",
        "stream_id" => "lane-retarget",
        "previous_response_id" => "resp_missing_owner"
      }
      |> Jason.encode!()

    state =
      public_socket_state(%{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 31,
          correlation_id: "corr-retarget",
          active_turn_reconnect?: false
        }
      })

    assert {:push, {:text, error_payload}, settled_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert %{"status" => 400, "error" => %{"param" => "previous_response_id"}} =
             Jason.decode!(error_payload)

    assert settled_state.public_response_task_pid == nil
    assert settled_state.public_response_stream_id == nil
    assert MapSet.size(settled_state.tasks) == 0
  end

  @tag :socket_lifecycle_regression
  test "RED-R03 public GET isolates active task identity and sequence state by turn" do
    first_task_pid = self()

    second_task_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(second_task_pid, :stop) end)

    first_frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "first"})
    second_frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "second"})
    first_state = public_turn_state(first_task_pid)

    assert {:push, {:text, first_payload}, first_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, first_task_pid, first_frame},
               first_state
             )

    assert Jason.decode!(first_payload)["sequence_number"] == 0

    second_state =
      first_state
      |> Map.put(:tasks, MapSet.new([second_task_pid]))
      |> Map.put(:public_response_task_pid, second_task_pid)
      |> Map.put(:public_responses_websocket_state, nil)

    assert {:ok, ^second_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, first_task_pid, first_frame},
               second_state
             )

    assert {:push, {:text, second_payload}, _second_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, second_task_pid, second_frame},
               second_state
             )

    assert Jason.decode!(second_payload)["sequence_number"] == 0
  end

  @tag :socket_lifecycle_regression
  test "RED-R04 owner task done waits for matching owner complete before queued turn starts" do
    task_pid = self()

    state =
      public_turn_state(task_pid, %{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 1,
          correlation_id: "corr-red-owner-barrier"
        },
        queued_response_payloads: :queue.from_list([{:owner_retarget_error, :owner_unavailable}])
      })

    assert {:ok, next_state} =
             CodexResponsesSocket.handle_info({:codex_response_done, task_pid, :ok}, state)

    assert Map.get(next_state, :public_turn_task_done?) == true
    assert Map.get(next_state, :public_turn_owner_complete?) == false
    assert MapSet.size(next_state.tasks) == 0
    assert :queue.len(next_state.queued_response_payloads) == 1
  end

  test "owner socket local completion closes the turn without an owner complete frame" do
    task_pid = self()

    state =
      public_turn_state(task_pid, %{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 1,
          correlation_id: "corr-local-completion"
        }
      })

    assert {:ok, next_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid, {:socket_response_result, :local_complete, :ok}},
               state
             )

    assert next_state.public_response_task_pid == nil
    refute next_state.public_turn_task_done?
    refute next_state.public_turn_owner_complete?
  end

  test "owner socket submitted completion keeps the real owner barrier" do
    task_pid = self()

    state =
      public_turn_state(task_pid, %{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 1,
          correlation_id: "corr-owner-submitted"
        }
      })

    assert {:ok, next_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               state
             )

    assert next_state.public_response_task_pid == task_pid
    assert next_state.public_turn_task_done?
    refute next_state.public_turn_owner_complete?
  end

  test "legacy remote owner acceptance keeps turn two queued until matching owner complete" do
    first_task_pid = owner_turn_pid()
    on_exit(fn -> send(first_task_pid, :stop) end)
    correlation_id = "corr-legacy-owner-pending"
    epoch = 3
    queued_payload = ~s({"type":"response.create","model":"gpt-test","input":"queued"})

    state =
      public_turn_state(first_task_pid, %{
        auth: nil,
        websocket_owner_downstream: %{
          pid: self(),
          epoch: epoch,
          correlation_id: correlation_id,
          active_turn_reconnect?: false
        },
        queued_response_payloads: :queue.from_list([queued_payload])
      })

    assert {:ok, waiting_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, first_task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               state
             )

    assert waiting_state.public_response_task_pid == first_task_pid
    assert waiting_state.public_turn_task_done?
    refute waiting_state.public_turn_owner_complete?
    assert :queue.len(waiting_state.queued_response_payloads) == 1

    assert {:ok, turn_two_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, correlation_id, epoch, first_task_pid, :complete},
               waiting_state
             )

    second_task_pid = turn_two_state.public_response_task_pid
    assert is_pid(second_task_pid)
    refute second_task_pid == first_task_pid
    assert :queue.is_empty(turn_two_state.queued_response_payloads)
    cleanup_response_task(turn_two_state, second_task_pid)
  end

  test "public owner completion barrier closes in either signal order" do
    correlation_id = "corr-public-barrier"
    epoch = 4

    for order <- [:task_done_first, :owner_complete_first] do
      task_pid = owner_turn_pid()
      on_exit(fn -> send(task_pid, :stop) end)

      state =
        public_turn_state(task_pid, %{
          websocket_owner_downstream: %{
            pid: self(),
            epoch: epoch,
            correlation_id: correlation_id,
            active_turn_reconnect?: false
          }
        })

      complete =
        {:websocket_owner_frame, correlation_id, epoch, task_pid, :complete}

      closed_state =
        case order do
          :task_done_first ->
            assert {:ok, waiting_state} =
                     CodexResponsesSocket.handle_info(
                       {:codex_response_done, task_pid, :ok},
                       state
                     )

            assert waiting_state.public_turn_task_done?
            refute waiting_state.public_turn_owner_complete?
            assert waiting_state.public_response_task_pid == task_pid

            assert {:ok, closed_state} =
                     CodexResponsesSocket.handle_info(complete, waiting_state)

            closed_state

          :owner_complete_first ->
            assert {:ok, waiting_state} = CodexResponsesSocket.handle_info(complete, state)
            refute waiting_state.public_turn_task_done?
            assert waiting_state.public_turn_owner_complete?
            assert waiting_state.public_response_task_pid == task_pid

            assert {:ok, closed_state} =
                     CodexResponsesSocket.handle_info(
                       {:codex_response_done, task_pid, :ok},
                       waiting_state
                     )

            closed_state
        end

      assert closed_state.public_response_task_pid == nil
      assert closed_state.public_response_stream_id == nil
      assert closed_state.public_responses_websocket_state == nil
      refute closed_state.public_turn_task_done?
      refute closed_state.public_turn_owner_complete?
      refute closed_state.public_turn_aborted?
    end
  end

  @tag :socket_lifecycle_regression
  test "public owner barrier starts queued turn two and rejects stale turn one traffic" do
    correlation_id = "corr-public-queued"
    epoch = 5
    queued_payload = ~s({"type":"response.create","model":"gpt-test","input":"queued"})

    for order <- [:task_done_first, :owner_complete_first] do
      first_task_pid = owner_turn_pid()
      on_exit(fn -> send(first_task_pid, :stop) end)

      state =
        public_turn_state(first_task_pid, %{
          auth: nil,
          websocket_owner_downstream: %{
            pid: self(),
            epoch: epoch,
            correlation_id: correlation_id,
            active_turn_reconnect?: false
          }
        })

      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in({queued_payload, [opcode: :text]}, state)

      assert :queue.len(queued_state.queued_response_payloads) == 1

      complete =
        {:websocket_owner_frame, correlation_id, epoch, first_task_pid, :complete}

      turn_two_state =
        case order do
          :task_done_first ->
            assert {:ok, waiting_state} =
                     CodexResponsesSocket.handle_info(
                       {:codex_response_done, first_task_pid, :ok},
                       queued_state
                     )

            assert {:ok, turn_two_state} =
                     CodexResponsesSocket.handle_info(complete, waiting_state)

            turn_two_state

          :owner_complete_first ->
            assert {:ok, waiting_state} =
                     CodexResponsesSocket.handle_info(complete, queued_state)

            assert {:ok, turn_two_state} =
                     CodexResponsesSocket.handle_info(
                       {:codex_response_done, first_task_pid, :ok},
                       waiting_state
                     )

            turn_two_state
        end

      second_task_pid = turn_two_state.public_response_task_pid
      assert is_pid(second_task_pid)
      refute second_task_pid == first_task_pid
      assert MapSet.member?(turn_two_state.tasks, second_task_pid)
      assert :queue.len(turn_two_state.queued_response_payloads) == 0

      assert turn_two_state.public_responses_websocket_state == %{
               max_seen: nil,
               terminal_latched?: false,
               overflow_latched?: false
             }

      frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "current"})

      assert {:ok, ^turn_two_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_chunk, first_task_pid, frame},
                 turn_two_state
               )

      assert {:ok, ^turn_two_state} =
               CodexResponsesSocket.handle_info(
                 {:websocket_owner_frame, correlation_id, epoch, first_task_pid, {:data, frame}},
                 turn_two_state
               )

      assert {:push, {:text, direct_payload}, turn_two_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_chunk, second_task_pid, frame},
                 turn_two_state
               )

      assert Jason.decode!(direct_payload)["sequence_number"] == 0

      assert {:push, {:text, owner_payload}, turn_two_state} =
               CodexResponsesSocket.handle_info(
                 {:websocket_owner_frame, correlation_id, epoch, second_task_pid, {:data, frame}},
                 turn_two_state
               )

      assert Jason.decode!(owner_payload)["sequence_number"] == 1
      cleanup_response_task(turn_two_state, second_task_pid)
    end
  end

  test "public owner frames drop stale turn ids and legacy tuples on the current epoch" do
    active_task_pid = self()
    stale_task_pid = owner_turn_pid()
    on_exit(fn -> send(stale_task_pid, :stop) end)

    state =
      public_turn_state(active_task_pid, %{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 8,
          correlation_id: "corr-shared",
          active_turn_reconnect?: false
        }
      })

    data = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "current"})

    stale_frame =
      {:websocket_owner_frame, "corr-shared", 8, stale_task_pid, {:data, data}}

    legacy_frame = {:websocket_owner_frame, "corr-shared", 8, {:data, data}}

    assert {:ok, ^state} = CodexResponsesSocket.handle_info(stale_frame, state)
    assert {:ok, ^state} = CodexResponsesSocket.handle_info(legacy_frame, state)

    assert {:push, {:text, payload}, state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-shared", 8, active_task_pid, {:data, data}},
               state
             )

    assert Jason.decode!(payload)["sequence_number"] == 0

    assert {:ok, completed_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-shared", 8, active_task_pid, :complete},
               state
             )

    assert completed_state.public_turn_owner_complete?

    assert {:ok, ^completed_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-shared", 8, active_task_pid, {:data, data}},
               completed_state
             )

    assert {:ok, ^completed_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-shared", 8, active_task_pid, :complete},
               completed_state
             )

    non_public_state = %{
      opts: RequestOptions.for_websocket(%{}),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 8,
        correlation_id: "corr-shared",
        active_turn_reconnect?: false
      },
      tasks: MapSet.new(),
      task_monitors: %{}
    }

    assert {:push, {:text, ^data}, ^non_public_state} =
             CodexResponsesSocket.handle_info(legacy_frame, non_public_state)
  end

  test "public websocket sequence overflow emits one error envelope and then latches drops" do
    task_pid = self()

    tracker = %{
      max_seen: PublicResponsesSequence.max_safe_integer() - 1,
      terminal_latched?: false,
      overflow_latched?: false
    }

    state =
      public_turn_state(task_pid, %{
        public_response_stream_id: "lane-overflow",
        public_responses_websocket_state: Map.put(tracker, :stream_id, "lane-overflow")
      })

    frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "overflow"})

    assert {:push, {:text, payload}, state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, frame},
               state
             )

    assert %{
             "type" => "error",
             "status" => 500,
             "stream_id" => "lane-overflow",
             "error" => %{"code" => "websocket_sequence_exhausted"}
           } = Jason.decode!(payload)

    assert state.public_responses_websocket_state.overflow_latched?
    assert state.public_responses_websocket_state.terminal_latched?

    assert {:ok, ^state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, frame},
               state
             )
  end

  test "public socket records only client-committed output" do
    task_pid = self()
    state = public_turn_state(task_pid)

    visible = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "visible"})

    assert {:push, {:text, _payload}, visible_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, visible},
               state
             )

    assert visible_state.public_turn_output_committed?

    rate_limits = Jason.encode!(%{"type" => "codex.rate_limits", "remaining" => 1})

    assert {:push, {:text, _payload}, rate_limit_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, rate_limits},
               state
             )

    refute rate_limit_state.public_turn_output_committed?

    dropped =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_drop", "status" => "in_progress"}
      })

    assert {:ok, dropped_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, dropped},
               state
             )

    refute dropped_state.public_turn_output_committed?

    overflow_state =
      public_turn_state(task_pid, %{
        public_responses_websocket_state: %{
          max_seen: PublicResponsesSequence.max_safe_integer() - 1,
          terminal_latched?: false,
          overflow_latched?: false
        }
      })

    assert {:push, {:text, _payload}, error_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_chunk, task_pid, visible},
               overflow_state
             )

    assert error_state.public_turn_output_committed?
  end

  test "public socket acknowledges commitment to the probe-carried owner pid" do
    task_pid = self()
    active_turn_ref = make_ref()
    probe_ref = make_ref()

    state =
      public_turn_state(task_pid, %{
        public_turn_output_committed?: true,
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 21,
          correlation_id: "corr-probe",
          active_turn_reconnect?: false
        }
      })

    owner_pid =
      spawn(fn ->
        receive do
          message -> send(task_pid, {:carried_owner_ack, message})
        end
      end)

    probe =
      {:websocket_owner_output_commit_probe, "corr-probe", 21, task_pid, active_turn_ref,
       owner_pid, probe_ref}

    assert {:ok, ^state} = CodexResponsesSocket.handle_info(probe, state)

    assert_receive {:carried_owner_ack,
                    {:websocket_owner_output_commit_ack, "corr-probe", 21, ^task_pid,
                     ^active_turn_ref, ^probe_ref, true}}
  end

  test "native owner-forwarded socket acknowledges a probe for the exact tracked task" do
    task_pid = owner_turn_pid()
    other_task_pid = owner_turn_pid()
    owner_pid = self()
    on_exit(fn -> send(task_pid, :stop) end)
    on_exit(fn -> send(other_task_pid, :stop) end)
    active_turn_ref = make_ref()
    probe_ref = make_ref()

    for {visible_task_pids, expected_visible?} <- [
          {MapSet.new(), false},
          {MapSet.new([task_pid]), true}
        ] do
      state = %{
        opts: RequestOptions.for_websocket(%{}),
        tasks: MapSet.new([task_pid, other_task_pid]),
        public_response_task_pid: nil,
        public_turn_aborted?: false,
        public_turn_owner_complete?: false,
        native_turn_output_task_pids: visible_task_pids,
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 31,
          correlation_id: "corr-native-probe",
          active_turn_reconnect?: false
        }
      }

      probe =
        {:websocket_owner_output_commit_probe, "corr-native-probe", 31, task_pid, active_turn_ref,
         owner_pid, probe_ref}

      assert {:ok, ^state} = CodexResponsesSocket.handle_info(probe, state)

      assert_receive {:websocket_owner_output_commit_ack, "corr-native-probe", 31, ^task_pid,
                      ^active_turn_ref, ^probe_ref, ^expected_visible?}
    end
  end

  test "native output probe rejects missing stale and non-owner task state" do
    task_pid = owner_turn_pid()
    other_task_pid = owner_turn_pid()
    owner_pid = self()
    on_exit(fn -> send(task_pid, :stop) end)
    on_exit(fn -> send(other_task_pid, :stop) end)
    active_turn_ref = make_ref()
    probe_ref = make_ref()

    base = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      public_response_task_pid: nil,
      public_turn_aborted?: false,
      public_turn_owner_complete?: false,
      native_turn_output_task_pids: MapSet.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 32,
        correlation_id: "corr-native-probe-reject",
        active_turn_reconnect?: false
      }
    }

    probe = fn correlation_id, epoch, owner_turn_id, carried_owner_pid ->
      {:websocket_owner_output_commit_probe, correlation_id, epoch, owner_turn_id,
       active_turn_ref, carried_owner_pid, probe_ref}
    end

    for state <- [
          %{base | tasks: MapSet.new()},
          Map.delete(base, :websocket_owner_downstream)
        ] do
      assert {:ok, ^state} =
               CodexResponsesSocket.handle_info(
                 probe.("corr-native-probe-reject", 32, task_pid, owner_pid),
                 state
               )
    end

    for invalid_probe <- [
          probe.("wrong-correlation", 32, task_pid, owner_pid),
          probe.("corr-native-probe-reject", 33, task_pid, owner_pid),
          probe.("corr-native-probe-reject", 32, other_task_pid, owner_pid),
          probe.("corr-native-probe-reject", 32, task_pid, :not_a_pid)
        ] do
      assert {:ok, ^base} = CodexResponsesSocket.handle_info(invalid_probe, base)
    end

    refute_received {:websocket_owner_output_commit_ack, _, _, _, _, _, _}
  end

  test "public socket refuses commitment probes for stale aborted or completed turns" do
    task_pid = self()
    active_turn_ref = make_ref()
    probe_ref = make_ref()

    base =
      public_turn_state(task_pid, %{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 22,
          correlation_id: "corr-probe-refuse",
          active_turn_reconnect?: false
        }
      })

    probe = fn owner_turn_id ->
      {:websocket_owner_output_commit_probe, "corr-probe-refuse", 22, owner_turn_id,
       active_turn_ref, self(), probe_ref}
    end

    assert {:ok, ^base} =
             CodexResponsesSocket.handle_info(probe.(owner_turn_pid()), base)

    assert {:ok, aborted} =
             CodexResponsesSocket.handle_info(probe.(task_pid), %{
               base
               | public_turn_aborted?: true
             })

    assert aborted.public_turn_aborted?

    assert {:ok, completed} =
             CodexResponsesSocket.handle_info(
               probe.(task_pid),
               %{base | public_turn_owner_complete?: true}
             )

    assert completed.public_turn_owner_complete?
    refute_received {:websocket_owner_output_commit_ack, _, _, _, _, _, _}
  end

  test "owner-forwarded upstream interruption logs once before task completion" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)

    state =
      public_turn_state(task_pid, %{
        public_response_stream_id: "lane-owner-upstream",
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 23,
          correlation_id: "corr-upstream-interruption",
          active_turn_reconnect?: false
        }
      })

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:upstream_stream_error, nil)

    owner_error =
      {:websocket_owner_frame, "corr-upstream-interruption", 23, task_pid,
       {:error, :upstream_stream_error, safe_payload}}

    {_result, logs} =
      with_native_turn_log(:info, fn ->
        assert {:push, {:text, payload}, pushed_state} =
                 CodexResponsesSocket.handle_info(owner_error, state)

        assert Jason.decode!(payload) == %{
                 "type" => "error",
                 "status" => 502,
                 "stream_id" => "lane-owner-upstream",
                 "error" => %{
                   "type" => "invalid_request_error",
                   "code" => "server_error",
                   "message" =>
                     "upstream request failed: stream interrupted before terminal response event",
                   "param" => nil
                 }
               }

        assert {:ok, _done_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, task_pid,
                    {:response_task_result, {:error, :upstream_stream_error}, true}},
                   pushed_state
                 )
      end)

    assert_native_turn_logs(logs, 1, "server_error")
  end

  test "generic owner errors echo the active accepted stream id without ending the turn" do
    task_pid = self()

    state =
      public_turn_state(task_pid, %{
        public_response_stream_id: "lane-owner-generic",
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 25,
          correlation_id: "corr-owner-generic",
          active_turn_reconnect?: false
        }
      })

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:owner_unavailable, nil)

    frame =
      {:websocket_owner_frame, "corr-owner-generic", 25, task_pid,
       {:error, :owner_unavailable, safe_payload}}

    assert {:push, {:text, payload}, ^state} =
             CodexResponsesSocket.handle_info(frame, state)

    assert Jason.decode!(payload)["stream_id"] == "lane-owner-generic"
  end

  test "successful public completion clears the active accepted stream id" do
    task_pid = owner_turn_pid()
    state = public_turn_state(task_pid, %{public_response_stream_id: "lane-complete"})

    assert {:ok, settled_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid, :ok},
               state
             )

    assert settled_state.public_response_stream_id == nil
    assert settled_state.public_responses_websocket_state == nil
    assert settled_state.public_response_task_pid == nil
  end

  test "socket termination completes with an active accepted stream id remaining transient" do
    state =
      public_socket_state(%{
        public_response_stream_id: "lane-terminate",
        public_responses_websocket_state: Adapter.public_responses_turn_state("lane-terminate"),
        request_response_work_started?: true,
        codex_session: nil
      })

    assert :ok = CodexResponsesSocket.terminate(:normal, state)

    fresh_state = public_socket_state()
    assert fresh_state.public_response_stream_id == nil
    assert fresh_state.public_responses_websocket_state == nil
  end

  test "owner-forwarded liveness failure closes without fabricating a terminal" do
    task_pid = self()

    state =
      public_turn_state(task_pid, %{
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 24,
          correlation_id: "corr-dead-owner",
          active_turn_reconnect?: false
        }
      })

    assert {:stop, :normal, {1011, "websocket owner crashed"}, closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:response_task_result, {:error, :owner_crashed}, true}},
               state
             )

    assert closed_state.public_response_task_pid == nil
    refute_received {:websocket_owner_frame, _, _, _, _}
  end

  test "active public task down aborts without starting queued work in both owner signal orders" do
    for owner_complete_first? <- [false, true] do
      task_pid = self()
      monitor = make_ref()

      state =
        public_turn_state(task_pid, %{
          public_response_stream_id: "lane-abort",
          task_monitors: %{task_pid => monitor},
          websocket_owner_downstream: %{
            pid: self(),
            epoch: 12,
            correlation_id: "corr-abort",
            active_turn_reconnect?: false
          },
          queued_response_payloads: :queue.from_list([~s({"type":"response.create"})])
        })

      state =
        if owner_complete_first? do
          assert {:ok, state} =
                   CodexResponsesSocket.handle_info(
                     {:websocket_owner_frame, "corr-abort", 12, task_pid, :complete},
                     state
                   )

          assert state.public_turn_owner_complete?
          state
        else
          state
        end

      assert {:stop, :normal, {1011, "websocket response task failed"}, aborted_state} =
               CodexResponsesSocket.handle_info(
                 {:DOWN, monitor, :process, task_pid, :shutdown},
                 state
               )

      assert aborted_state.public_turn_aborted?
      assert aborted_state.public_response_stream_id == nil
      assert aborted_state.public_responses_websocket_state == nil
      assert :queue.len(aborted_state.queued_response_payloads) == 0
      assert MapSet.size(aborted_state.tasks) == 0

      assert {:ok, ^aborted_state} =
               CodexResponsesSocket.handle_info(
                 {:websocket_owner_frame, "corr-abort", 12, task_pid, :complete},
                 aborted_state
               )
    end
  end

  test "owner drain aborts once, clears queued work, and ignores late done and complete" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)

    state =
      public_turn_state(task_pid, %{
        public_response_stream_id: "lane-drain",
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 15,
          correlation_id: "corr-drain",
          active_turn_reconnect?: false
        },
        queued_response_payloads: :queue.from_list([~s({"type":"response.create"})])
      })

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

    drain_frame =
      {:websocket_owner_frame, "corr-drain", 15, task_pid, {:error, :owner_drained, safe_payload}}

    {_done_state, logs} =
      with_native_turn_log(:info, fn ->
        assert {:push, {:text, payload}, aborted_state} =
                 CodexResponsesSocket.handle_info(drain_frame, state)

        assert Jason.decode!(payload)["error"]["code"] == "owner_drained"
        assert Jason.decode!(payload)["stream_id"] == "lane-drain"
        assert aborted_state.public_turn_aborted?
        assert aborted_state.public_response_stream_id == nil
        assert aborted_state.public_responses_websocket_state == nil
        assert aborted_state.websocket_owner_drain_observed?
        assert :queue.len(aborted_state.queued_response_payloads) == 0

        assert {:ok, done_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, task_pid, {:error, :owner_drained}},
                   aborted_state
                 )

        assert done_state.public_turn_aborted?
        assert :queue.len(done_state.queued_response_payloads) == 0

        assert {:ok, ^done_state} =
                 CodexResponsesSocket.handle_info(
                   {:websocket_owner_frame, "corr-drain", 15, task_pid, :complete},
                   done_state
                 )

        assert {:ok, ^done_state} = CodexResponsesSocket.handle_info(drain_frame, done_state)
        done_state
      end)

    assert_native_turn_logs(logs, 1, "owner_drained")
  end

  test "owner drain logs one native turn failure before its late task completion" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)

    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_request_metadata(request_id: "ws-owner-drain-native-log")
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    state =
      public_turn_state(task_pid, %{
        opts: opts,
        websocket_owner_downstream: %{
          pid: self(),
          epoch: 19,
          correlation_id: "corr-drain-native-log",
          active_turn_reconnect?: false
        }
      })

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

    drain_frame =
      {:websocket_owner_frame, "corr-drain-native-log", 19, task_pid,
       {:error, :owner_drained, safe_payload}}

    {_result, logs} =
      with_native_turn_log(:info, fn ->
        assert {:push, {:text, payload}, drained_state} =
                 CodexResponsesSocket.handle_info(drain_frame, state)

        assert Jason.decode!(payload)["error"]["code"] == "owner_drained"

        assert {:ok, done_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, task_pid, {:error, :owner_drained}},
                   drained_state
                 )

        assert done_state.public_turn_aborted?
        assert MapSet.size(done_state.tasks) == 0
      end)

    assert_native_turn_logs(logs, 1, "owner_drained")
    assert logs =~ "request_id=ws-owner-drain-native-log"
  end

  test "non-public owner drain logs one native turn failure from its late task completion" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)

    state = %{
      opts:
        %{}
        |> RequestOptions.for_websocket()
        |> RequestOptions.put_request_metadata(request_id: "ws-owner-drain-late-native-log"),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 20,
        correlation_id: "corr-drain-late-native-log",
        active_turn_reconnect?: false
      }
    }

    assert {:ok, safe_payload} =
             WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

    drain_frame =
      {:websocket_owner_frame, "corr-drain-late-native-log", 20,
       {:error, :owner_drained, safe_payload}}

    {_result, logs} =
      with_native_turn_log(:info, fn ->
        assert {:push, {:text, payload}, drained_state} =
                 CodexResponsesSocket.handle_info(drain_frame, state)

        assert Jason.decode!(payload)["error"]["code"] == "owner_drained"

        assert {:ok, done_state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, task_pid, {:error, :owner_drained}},
                   drained_state
                 )

        assert MapSet.size(done_state.tasks) == 0
      end)

    assert_native_turn_logs(logs, 1, "owner_drained")
    assert logs =~ "request_id=ws-owner-drain-late-native-log"
  end

  test "rollout drain waits after proxy task result until the native owner terminal is delivered" do
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    parent = self()

    {:ok, task_pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid -> {:socket_response_result, :owner_completion_pending, :ok} end,
        fn _task_pid, _reason -> :kill_worker end,
        activity_registry: harness.activity_registry
      )

    task_monitor = Process.monitor(task_pid)

    assert_receive {:websocket_response_activity, ^task_pid, activity_token}

    assert_receive {:codex_response_done, ^task_pid,
                    {:socket_response_result, :owner_completion_pending, :ok}}

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{task_pid => task_monitor},
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 21,
        correlation_id: "corr-rollout-terminal-delivery",
        active_turn_reconnect?: false
      },
      native_turn_output_task_pids: MapSet.new()
    }

    assert {:ok, activity_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_activity, task_pid, activity_token},
               state
             )

    assert {:ok, result_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               activity_state
             )

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, _deadline, _wait_ms}
    assert Process.alive?(drain_task.pid)

    terminal = ~s({"type":"response.completed","response":{"id":"resp_terminal_safe"}})

    assert {:push, {:text, ^terminal}, terminal_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-rollout-terminal-delivery", 21, task_pid,
                {:data, terminal}},
               result_state
             )

    assert Process.alive?(drain_task.pid)

    assert {:ok, completed_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-rollout-terminal-delivery", 21, task_pid,
                :complete},
               terminal_state
             )

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                     delivery_ack

    assert {:ok, final_state} = CodexResponsesSocket.handle_info(delivery_ack, completed_state)

    assert %{proxy_turns_seen: 1, proxy_turns_completed: 1, proxy_turns_aborted: 0} =
             Task.await(drain_task, 5_000)

    assert MapSet.size(final_state.tasks) == 0
  end

  test "native owner terminal waits for gateway finalization before releasing the next queued turn" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)
    activity_token = make_ref()

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      response_task_activities: %{task_pid => activity_token},
      response_task_results_ready: MapSet.new(),
      response_task_terminals_accepted: MapSet.new(),
      queued_response_payloads: :queue.from_list(["queued-final-turn"]),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 24,
        correlation_id: "corr-owner-terminal-before-finalization",
        active_turn_reconnect?: false
      },
      native_turn_output_task_pids: MapSet.new()
    }

    terminal = ~s({"type":"response.completed","response":{"id":"resp_compact_terminal"}})

    assert {:push, {:text, ^terminal}, terminal_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-owner-terminal-before-finalization", 24, task_pid,
                {:data, terminal}},
               state
             )

    assert {:ok, owner_complete_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-owner-terminal-before-finalization", 24, task_pid,
                :complete},
               terminal_state
             )

    refute_received {:websocket_response_delivery_complete, ^task_pid, ^activity_token}
    assert owner_complete_state.tasks == MapSet.new([task_pid])
    assert :queue.len(owner_complete_state.queued_response_payloads) == 1

    assert {:ok, finalized_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               owner_complete_state
             )

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token}
    assert finalized_state.tasks == MapSet.new([task_pid])
    assert :queue.len(finalized_state.queued_response_payloads) == 1
  end

  test "local native owner releases a finalized terminal without forwarded owner completion" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)
    activity_token = make_ref()

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      codex_session: %{owner_instance_id: Atom.to_string(node())},
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      response_task_activities: %{task_pid => activity_token},
      response_task_results_ready: MapSet.new(),
      response_task_terminals_accepted: MapSet.new([task_pid]),
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 25,
        correlation_id: "corr-local-owner-finalized-terminal",
        active_turn_reconnect?: false
      },
      native_turn_output_task_pids: MapSet.new()
    }

    assert {:ok, finalized_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               state
             )

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token}
    assert finalized_state.tasks == MapSet.new([task_pid])
  end

  test "local native owner releases when the activity token arrives after terminal and finalization" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)
    activity_token = make_ref()

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      codex_session: %{owner_instance_id: Atom.to_string(node())},
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      response_task_activities: %{},
      response_task_results_ready: MapSet.new(),
      response_task_terminals_accepted: MapSet.new(),
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 26,
        correlation_id: "corr-local-owner-late-activity",
        active_turn_reconnect?: false
      },
      native_turn_output_task_pids: MapSet.new()
    }

    terminal = ~s({"type":"response.completed","response":{"id":"resp_late_activity"}})

    assert {:push, {:text, ^terminal}, terminal_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-local-owner-late-activity", 26, task_pid,
                {:data, terminal}},
               state
             )

    assert {:ok, finalized_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               terminal_state
             )

    assert MapSet.member?(finalized_state.response_task_results_ready, task_pid)
    assert MapSet.member?(finalized_state.response_task_terminals_accepted, task_pid)

    assert {:ok, activity_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_activity, task_pid, activity_token},
               finalized_state
             )

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token}
    assert activity_state.tasks == MapSet.new()
    assert :queue.is_empty(activity_state.queued_response_payloads)
  end

  test "reconnected socket joins the inherited owner terminal and task result before delivery" do
    task_pid = owner_turn_pid()
    on_exit(fn -> send(task_pid, :stop) end)
    activity_token = make_ref()

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new(),
      task_monitors: %{},
      response_task_activities: %{task_pid => activity_token},
      response_task_results_ready: MapSet.new(),
      response_task_terminals_accepted: MapSet.new(),
      queued_response_payloads: :queue.new(),
      websocket_owner_active_turn_reconnect?: true,
      websocket_owner_reconnect_turn_pid: nil,
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 27,
        correlation_id: "corr-reconnected-owner-barrier",
        active_turn_reconnect?: true
      },
      native_turn_output_task_pids: MapSet.new()
    }

    terminal = ~s({"type":"response.completed","response":{"id":"resp_reconnected"}})

    assert {:push, {:text, ^terminal}, terminal_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-reconnected-owner-barrier", 27, task_pid,
                {:data, terminal}},
               state
             )

    assert terminal_state.websocket_owner_reconnect_turn_pid == task_pid
    assert MapSet.member?(terminal_state.response_task_terminals_accepted, task_pid)

    assert {:ok, finalized_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               terminal_state
             )

    assert MapSet.member?(finalized_state.response_task_results_ready, task_pid)

    assert {:ok, owner_complete_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-reconnected-owner-barrier", 27, task_pid,
                :complete},
               finalized_state
             )

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token}
    refute owner_complete_state.websocket_owner_active_turn_reconnect?
  end

  test "natural proxy terminal already scheduled for delivery wins a concurrent drain cancellation" do
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    parent = self()

    {:ok, task_pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid -> {:socket_response_result, :owner_completion_pending, :ok} end,
        fn cancelled_pid, reason ->
          send(parent, {:scheduled_terminal_cancel_started, cancelled_pid, reason})
        end,
        activity_registry: harness.activity_registry
      )

    task_monitor = Process.monitor(task_pid)
    observer_monitor = Process.monitor(task_pid)
    assert_receive {:websocket_response_activity, ^task_pid, activity_token}

    assert_receive {:codex_response_done, ^task_pid,
                    {:socket_response_result, :owner_completion_pending, :ok}} = done_message

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{task_pid => task_monitor},
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 23,
        correlation_id: "corr-rollout-terminal-cancel-race",
        active_turn_reconnect?: false
      },
      native_turn_output_task_pids: MapSet.new()
    }

    assert {:ok, activity_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_activity, task_pid, activity_token},
               state
             )

    assert {:ok, result_state} = CodexResponsesSocket.handle_info(done_message, activity_state)

    terminal = ~s({"type":"response.completed","response":{"id":"resp_terminal_race"}})

    assert {:push, {:text, ^terminal}, terminal_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-rollout-terminal-cancel-race", 23, task_pid,
                {:data, terminal}},
               result_state
             )

    assert {:ok, completed_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, "corr-rollout-terminal-cancel-race", 23, task_pid,
                :complete},
               terminal_state
             )

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                     delivery_ack

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [
            name: harness.name,
            timeout_ms: 25,
            deadline_margin_ms: 20,
            deadline_floor_ms: 10
          ] ++ WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, deadline, 10}
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)
    assert_receive {:scheduled_terminal_cancel_started, ^task_pid, :owner_drained}

    assert_receive {:websocket_response_activity_cancelled, ^task_pid, ^activity_token,
                    :owner_drained} = cancellation

    assert {:ok, cancellation_state} =
             CodexResponsesSocket.handle_info(cancellation, completed_state)

    assert {:ok, final_state} = CodexResponsesSocket.handle_info(delivery_ack, cancellation_state)

    assert %{proxy_turns_seen: 1, proxy_turns_completed: 1, proxy_turns_aborted: 0} =
             Task.await(drain_task, 5_000)

    assert_receive {:DOWN, ^observer_monitor, :process, ^task_pid, :normal}
    refute_received {:codex_response_done, ^task_pid, {:error, :owner_drained}}
    assert MapSet.size(final_state.tasks) == 0
  end

  test "rollout deadline after proxy task result delivers one owner_drained terminal before abort completes" do
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    parent = self()

    {:ok, task_pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid -> {:socket_response_result, :owner_completion_pending, :ok} end,
        fn cancelled_pid, reason ->
          send(parent, {:terminal_wait_cancelled, cancelled_pid, reason})
        end,
        activity_registry: harness.activity_registry
      )

    task_monitor = Process.monitor(task_pid)
    assert_receive {:websocket_response_activity, ^task_pid, activity_token}

    assert_receive {:codex_response_done, ^task_pid,
                    {:socket_response_result, :owner_completion_pending, :ok}}

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{task_pid => task_monitor},
      queued_response_payloads: :queue.new(),
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 22,
        correlation_id: "corr-rollout-terminal-deadline",
        active_turn_reconnect?: false
      },
      native_turn_output_task_pids: MapSet.new()
    }

    assert {:ok, activity_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_activity, task_pid, activity_token},
               state
             )

    assert {:ok, result_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, task_pid,
                {:socket_response_result, :owner_completion_pending, :ok}},
               activity_state
             )

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [
            name: harness.name,
            timeout_ms: 25,
            deadline_margin_ms: 20,
            deadline_floor_ms: 10
          ] ++ WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, deadline, 10}
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)
    assert_receive {:terminal_wait_cancelled, ^task_pid, :owner_drained}

    assert_receive {:websocket_response_activity_cancelled, ^task_pid, ^activity_token,
                    :owner_drained} = cancellation

    assert {:push, {:text, terminal}, cancelled_state} =
             CodexResponsesSocket.handle_info(cancellation, result_state)

    assert Jason.decode!(terminal)["error"]["code"] == "owner_drained"
    assert Process.alive?(drain_task.pid)

    assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                     delivery_ack

    assert {:ok, final_state} = CodexResponsesSocket.handle_info(delivery_ack, cancelled_state)

    assert %{proxy_turns_seen: 1, proxy_turns_completed: 0, proxy_turns_aborted: 1} =
             Task.await(drain_task, 5_000)

    refute_received {:terminal_wait_cancelled, ^task_pid, :owner_drained}
    assert MapSet.size(final_state.tasks) == 0
  end

  test "socket termination acknowledges a task already waiting only for terminal cleanup" do
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    parent = self()

    {:ok, task_pid} =
      ResponseTask.start(
        parent,
        :direct,
        fn _task_pid -> :ok end,
        fn _task_pid, _reason -> :kill_worker end,
        activity_registry: harness.activity_registry
      )

    task_monitor = Process.monitor(task_pid)
    assert_receive {:websocket_response_activity, ^task_pid, activity_token}
    assert_receive {:codex_response_done, ^task_pid, :ok}

    state = %{
      auth: nil,
      opts: RequestOptions.for_websocket(%{}),
      codex_session: nil,
      upstream_websocket_session: nil,
      request_response_work_started?: true,
      tasks: MapSet.new([task_pid]),
      task_monitors: %{task_pid => task_monitor},
      response_task_activities: %{task_pid => activity_token}
    }

    assert {_epoch, [%{token: ^activity_token, pid: ^task_pid}]} =
             ActivityRegistry.begin_drain(name: harness.activity_registry)

    assert :ok = CodexResponsesSocket.terminate(:normal, state)
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :normal}

    assert {:finished, :aborted} =
             ActivityRegistry.status(activity_token, name: harness.activity_registry)

    assert ActivityRegistry.activities(name: harness.activity_registry) == []
  end

  test "socket termination acknowledges the authoritative cancellation watcher before handoff is consumed" do
    harness = WebsocketRolloutDrainSupport.start_rollout_drain_harness(self())
    parent = self()

    {:ok, task_pid} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid ->
          send(parent, :termination_race_callback_started)

          receive do
            :never_release -> :ok
          end
        end,
        fn cancelled_pid, reason ->
          send(parent, {:termination_race_cancelled, cancelled_pid, reason})
        end,
        activity_registry: harness.activity_registry
      )

    task_monitor = Process.monitor(task_pid)
    assert_receive :termination_race_callback_started

    assert {_epoch, [%{token: token, pid: ^task_pid}]} =
             ActivityRegistry.begin_drain(name: harness.activity_registry)

    assert :ok = ActivityRegistry.cancel(token, :owner_drained, name: harness.activity_registry)
    assert_receive {:termination_race_cancelled, ^task_pid, :owner_drained}
    assert_receive {:websocket_response_activity, ^task_pid, ^token}

    assert_receive {:websocket_response_activity_cancelled, ^task_pid, ^token, watcher,
                    :owner_drained}

    watcher_monitor = Process.monitor(watcher)

    state = %{
      auth: nil,
      opts: RequestOptions.for_websocket(%{}),
      codex_session: nil,
      upstream_websocket_session: nil,
      request_response_work_started?: true,
      tasks: MapSet.new([task_pid]),
      task_monitors: %{task_pid => task_monitor},
      response_task_activity_registry: harness.activity_registry
    }

    assert :ok = CodexResponsesSocket.terminate(:normal, state)
    assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, :normal}
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}

    assert {:finished, :aborted} =
             ActivityRegistry.status(token, name: harness.activity_registry)

    refute_received {:codex_response_done, ^task_pid, {:error, :owner_drained}}
    refute_received {:termination_race_cancelled, ^task_pid, :owner_drained}
    assert ActivityRegistry.activities(name: harness.activity_registry) == []
  end

  @tag :socket_lifecycle_regression
  test "owner drain schedules stay aborted through final owner down" do
    for order <- [:task_done_first, :owner_complete_first] do
      task_pid = owner_turn_pid()
      owner_pid = owner_turn_pid()
      owner_monitor = Process.monitor(owner_pid)
      on_exit(fn -> send(task_pid, :stop) end)
      on_exit(fn -> send(owner_pid, :stop) end)

      state =
        public_turn_state(task_pid, %{
          websocket_owner_pid: owner_pid,
          websocket_owner_monitor: owner_monitor,
          websocket_owner_downstream: %{
            pid: self(),
            epoch: 16,
            correlation_id: "corr-drain-down",
            active_turn_reconnect?: false
          },
          queued_response_payloads:
            :queue.from_list([
              ~s({"type":"response.create","model":"gpt-test","input":"must-not-start"})
            ])
        })

      assert {:ok, safe_payload} =
               WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

      drain_frame =
        {:websocket_owner_frame, "corr-drain-down", 16, task_pid,
         {:error, :owner_drained, safe_payload}}

      complete =
        {:websocket_owner_frame, "corr-drain-down", 16, task_pid, :complete}

      {final_signal_state, native_turn_logs} =
        with_native_turn_log(:info, fn ->
          assert {:push, {:text, error_payload}, aborted_state} =
                   CodexResponsesSocket.handle_info(drain_frame, state)

          assert Jason.decode!(error_payload)["error"]["code"] == "owner_drained"
          assert aborted_state.public_turn_aborted?
          assert aborted_state.websocket_owner_drain_observed?
          assert :queue.len(aborted_state.queued_response_payloads) == 0

          final_signal_state =
            case order do
              :task_done_first ->
                assert {:ok, done_state} =
                         CodexResponsesSocket.handle_info(
                           {:codex_response_done, task_pid, {:error, :owner_drained}},
                           aborted_state
                         )

                assert {:ok, final_signal_state} =
                         CodexResponsesSocket.handle_info(complete, done_state)

                final_signal_state

              :owner_complete_first ->
                assert {:ok, complete_state} =
                         CodexResponsesSocket.handle_info(complete, aborted_state)

                assert {:ok, final_signal_state} =
                         CodexResponsesSocket.handle_info(
                           {:codex_response_done, task_pid, {:error, :owner_drained}},
                           complete_state
                         )

                final_signal_state
            end

          assert final_signal_state.public_turn_aborted?
          assert :queue.len(final_signal_state.queued_response_payloads) == 0
          assert MapSet.size(final_signal_state.tasks) == 0
          assert final_signal_state.public_response_task_pid == task_pid

          assert {:ok, ^final_signal_state} =
                   CodexResponsesSocket.handle_info(drain_frame, final_signal_state)

          assert {:ok, ^final_signal_state} =
                   CodexResponsesSocket.handle_info(complete, final_signal_state)

          final_signal_state
        end)

      assert_native_turn_logs(native_turn_logs, 1, "owner_drained")

      send(owner_pid, :stop)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal}

      {handle_result, warning_logs} =
        ExUnit.CaptureLog.with_log([level: :warning], fn ->
          CodexResponsesSocket.handle_info(
            {:DOWN, owner_monitor, :process, owner_pid, :normal},
            final_signal_state
          )
        end)

      assert warning_logs =~ "websocket owner monitor lease release failed"
      assert warning_logs =~ "failure_reason=owner_unavailable"

      assert {:ok, down_state} = handle_result

      refute Map.has_key?(down_state, :websocket_owner_pid)
      refute Map.has_key?(down_state, :websocket_owner_monitor)
      assert down_state.public_turn_aborted?
      assert :queue.len(down_state.queued_response_payloads) == 0
      assert MapSet.size(down_state.tasks) == 0
      assert down_state.public_response_task_pid == task_pid
    end
  end

  test "websocket error frames carry pinned continuation recovery fields" do
    {_result, logs} =
      with_native_turn_log(:warning, fn ->
        for error <- [
              Contracts.pinned_continuation_reauth_required_error(),
              Contracts.pinned_continuation_unavailable_error(%{
                "internal_reason" => "quota_exhausted"
              })
            ] do
          state = %{tasks: MapSet.new(), task_monitors: %{}}

          assert {:push, {:text, payload}, ^state} =
                   CodexResponsesSocket.handle_info(
                     {:codex_response_done, self(), {:error, error}},
                     state
                   )

          assert %{
                   "type" => "error",
                   "status" => 503,
                   "error" => %{
                     "code" => code,
                     "retryable" => false,
                     "requires_new_upstream_session" => true,
                     "recovery_kind" => "restart_with_full_context",
                     "recovery" => recovery
                   }
                 } = Jason.decode!(payload)

          assert code in [
                   "pinned_continuation_reauth_required",
                   "pinned_continuation_unavailable"
                 ]

          assert recovery["kind"] == "restart_with_full_context"
          assert recovery["anchor_removal"]["body"] == ["previous_response_id"]

          assert recovery["anchor_removal"]["headers"] == [
                   "x-codex-previous-response-id",
                   "x-codex-turn-state",
                   "x-codex-window-id",
                   "x-codex-session-id",
                   "session-id",
                   "x-session-id",
                   "x-session-affinity",
                   "session_id",
                   "x-codex-conversation-id"
                 ]
        end
      end)

    assert_native_turn_logs(logs, 2, [
      "pinned_continuation_reauth_required",
      "pinned_continuation_unavailable"
    ])
  end

  test "websocket error frames leave unrelated errors without recovery fields" do
    {_result, logs} =
      with_native_turn_log(:warning, fn ->
        for reason <- [
              %{
                status: 503,
                code: "session_assignment_unavailable",
                message: "session unavailable"
              },
              %{status: 400, code: "unsupported_model_capability", message: "model unsupported"},
              %{status: 400, code: "invalid_request", message: "request invalid"}
            ] do
          assert {:push, {:text, payload}, _state} =
                   CodexResponsesSocket.handle_info(
                     {:codex_response_done, self(), {:error, reason}},
                     %{tasks: MapSet.new(), task_monitors: %{}}
                   )

          decoded = Jason.decode!(payload)

          assert decoded["error"] == %{
                   "message" => reason.message,
                   "type" => "invalid_request_error",
                   "code" => reason.code,
                   "param" => nil
                 }

          refute Map.has_key?(decoded["error"], "recovery")
          refute Map.has_key?(decoded["error"], "recovery_kind")
          refute Map.has_key?(decoded["error"], "requires_new_upstream_session")
          refute Map.has_key?(decoded["error"], "retryable")
        end
      end)

    assert_native_turn_logs(logs, 3, [
      "session_assignment_unavailable",
      "unsupported_model_capability",
      "invalid_request"
    ])
  end

  test "websocket client error frames classify prompt token and idempotency-bearing terms" do
    secret_reason = %{
      idempotency_key: "raw-idempotency-key-secret",
      prompt: "raw websocket prompt",
      token: "Bearer websocket-secret-token"
    }

    state = %{tasks: MapSet.new(), task_monitors: %{}}

    {_result, logs} =
      with_native_turn_log(:warning, fn ->
        assert {:push, {:text, payload}, ^state} =
                 CodexResponsesSocket.handle_info(
                   {:codex_response_done, self(), {:error, secret_reason}},
                   state
                 )

        decoded = Jason.decode!(payload)
        assert decoded["type"] == "error"
        assert decoded["status"] == 500
        assert decoded["error"]["message"] == "websocket request failed: non_atom_reason"
        assert decoded["error"]["code"] == "websocket_request_failed"
        assert decoded["error"]["type"] == "invalid_request_error"

        refute payload =~ "raw-idempotency-key-secret"
        refute payload =~ "raw websocket prompt"
        refute payload =~ "websocket-secret-token"
      end)

    assert_native_turn_logs(logs, 1, "websocket_request_failed")
  end

  defp api_key_socket_state(api_key_id, pool_id, captured_epoch, overrides \\ %{}) do
    Map.merge(
      %{
        opts:
          RequestOptions.for_websocket(%{})
          |> RequestOptions.put_runtime_context(api_key_runtime_epoch: captured_epoch),
        api_key_id: api_key_id,
        api_key_pool_id: pool_id,
        api_key_runtime_epoch: captured_epoch,
        api_key_revoked?: false,
        api_key_close_sent?: false,
        firewall_revoked?: false,
        firewall_close_sent?: false,
        tasks: MapSet.new(),
        task_monitors: %{},
        queued_response_payloads: :queue.new(),
        public_response_task_pid: nil,
        public_response_stream_id: nil,
        public_response_start_error_ref: nil,
        public_responses_websocket_state: nil,
        public_turn_task_done?: false,
        public_turn_owner_complete?: false,
        public_turn_aborted?: false,
        public_turn_output_committed?: false,
        native_turn_output_task_pids: MapSet.new(),
        auth: %{pool: %{id: pool_id}, api_key: %{id: api_key_id}}
      },
      overrides
    )
  end

  defp api_key_event(api_key_id, pool_id, status, epoch) do
    payload = %{
      "api_key_id" => api_key_id,
      "pool_id" => pool_id,
      "status" => status
    }

    payload =
      if is_integer(epoch),
        do: Map.put(payload, "runtime_revocation_epoch", epoch),
        else: payload

    %Events.Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      topics: ["pools"],
      reason: "api_key_status_updated",
      emitted_at: DateTime.utc_now(),
      payload: payload
    }
  end

  defp fixture_owner_scope do
    owner =
      Repo.one!(
        from membership in Membership,
          join: user in User,
          on: user.id == membership.user_id,
          where: membership.role == "instance_owner" and membership.status == "active",
          select: user,
          limit: 1
      )

    Scope.for_user(owner, ["instance_owner"])
  end

  defp public_turn_state(task_pid, overrides \\ %{}) when is_pid(task_pid) do
    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    Map.merge(
      %{
        opts: opts,
        tasks: MapSet.new([task_pid]),
        task_monitors: %{},
        queued_response_payloads: :queue.new(),
        public_response_task_pid: task_pid,
        public_response_stream_id: nil,
        public_response_start_error_ref: nil,
        public_responses_websocket_state: nil,
        public_turn_task_done?: false,
        public_turn_owner_complete?: false,
        public_turn_aborted?: false,
        public_turn_output_committed?: false
      },
      overrides
    )
  end

  defp public_socket_state(overrides \\ %{}) do
    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    Map.merge(
      %{
        auth: nil,
        opts: opts,
        tasks: MapSet.new(),
        task_monitors: %{},
        queued_response_payloads: :queue.new(),
        public_response_task_pid: nil,
        public_response_stream_id: nil,
        public_response_start_error_ref: nil,
        public_responses_websocket_state: nil,
        public_turn_task_done?: false,
        public_turn_owner_complete?: false,
        public_turn_aborted?: false,
        public_turn_output_committed?: false,
        native_turn_output_task_pids: MapSet.new(),
        firewall_revoked?: false
      },
      overrides
    )
  end

  defp public_create_payload(stream_id, input) do
    %{
      "type" => "response.create",
      "model" => "gpt-test",
      "input" => input
    }
    |> then(fn payload ->
      if is_binary(stream_id), do: Map.put(payload, "stream_id", stream_id), else: payload
    end)
    |> Jason.encode!()
  end

  defp firewall_socket_state(applied_version, overrides \\ %{}) do
    Map.merge(
      %{
        opts: RequestOptions.for_websocket(%{client_ip: "127.0.0.1"}),
        firewall_client_ip: {127, 0, 0, 1},
        firewall_applied_version: applied_version,
        firewall_revoked?: false,
        firewall_close_sent?: false,
        tasks: MapSet.new(),
        task_monitors: %{},
        queued_response_payloads: :queue.new(),
        public_response_task_pid: nil,
        native_turn_output_task_pids: MapSet.new()
      },
      overrides
    )
  end

  defp cached_settings do
    case :persistent_term.get(@cache_key, :missing) do
      {@cache_version, %Settings{} = settings} -> settings
      _missing_or_stale -> Settings.default()
    end
  end

  defp publish_cache_snapshot(%Settings{} = settings) do
    Cache.restore_for_test({@cache_version, settings})
  end

  defp firewall_settings(settings, lock_version, allowlist) do
    {:ok, _compiled} = IPRules.compile(allowlist)

    %{
      settings
      | lock_version: lock_version,
        ingress: %{settings.ingress | firewall_allowlist: allowlist}
    }
  end

  defp applied_message(version), do: {@applied_message_tag, {:applied, version}}

  defp attach_firewall_telemetry do
    test_pid = self()
    handler_id = "socket-firewall-revocation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :ingress, :firewall, :denied],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:firewall_denied, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  defp owner_turn_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp cleanup_response_task(state, task_pid) when is_pid(task_pid) do
    if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)

    case Map.get(state.task_monitors, task_pid) do
      monitor when is_reference(monitor) -> Process.demonitor(monitor, [:flush])
      _missing -> :ok
    end
  end

  defp with_native_turn_log(level, fun) when level in [:info, :warning] and is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: level)

    try do
      ExUnit.CaptureLog.with_log([level: level], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp suppress_response_task_logs(fun) when is_function(fun, 0) do
    {result, _logs} = ExUnit.CaptureLog.with_log([level: :error], fun)
    result
  end

  defp assert_native_turn_logs(logs, expected_count, cleartext_codes)
       when is_list(cleartext_codes) do
    assert length(Regex.scan(~r/websocket native turn failed/, logs)) == expected_count

    Enum.each(cleartext_codes, fn code ->
      assert logs =~ "error_code=#{code}"
    end)

    refute logs =~ "error_code=sha256_"
  end

  defp assert_native_turn_logs(logs, expected_count, known_error_code) do
    assert_native_turn_logs(logs, expected_count, [known_error_code])
  end
end
