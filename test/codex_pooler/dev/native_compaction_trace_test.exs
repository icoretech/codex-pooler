defmodule CodexPooler.Dev.NativeCompactionTraceTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Dev.NativeCompactionTrace
  alias CodexPooler.Dev.NativeCompactionTrace.Plug, as: TracePlug
  alias CodexPooler.FakeUpstream

  alias CodexPooler.Gateway.Payloads.RequestOptions.NativeCompactionAdmission,
    as: RequestAdmission

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, as: NativeAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace, as: TraceEvent
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket.ResponseTask

  setup do
    original = Application.get_env(:codex_pooler, TraceEvent)
    NativeCompactionTrace.stop_scope()

    on_exit(fn ->
      NativeCompactionTrace.stop_scope()

      case original do
        nil -> Application.delete_env(:codex_pooler, TraceEvent)
        config -> Application.put_env(:codex_pooler, TraceEvent, config)
      end
    end)

    :ok
  end

  test "disabled tracing emits no telemetry and starts no collector" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: false)
    assert :ignored = TraceEvent.emit(:prepared_frame, %{phase: :compact})
    assert NativeCompactionTrace.export()["events"] == []
    assert NativeCompactionTrace.status()["running"] == false
  end

  test "enabled scope retains fixed sanitized events and bounds the ring" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)
    assert {:ok, _status} = NativeCompactionTrace.start_scope("run-secret", limit: 2)

    for number <- 1..3 do
      assert :ok =
               TraceEvent.emit(:prepared_frame, %{
                 phase: :compact,
                 window_number: number,
                 semantic_turn_key: "private-turn",
                 token: "forbidden-token",
                 prompt: "forbidden-prompt"
               })
    end

    export = await_event_count(2)
    assert export["eventCount"] == 2
    assert Enum.map(export["events"], &get_in(&1, ["fields", "window_number"])) == [2, 3]
    assert inspect(export) =~ TraceEvent.fingerprint("private-turn")
    refute inspect(export) =~ "private-turn"
    refute inspect(export) =~ "forbidden-token"
    refute inspect(export) =~ "forbidden-prompt"
  end

  test "reset isolates stale generations and stop tears down handler" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)
    assert {:ok, _status} = NativeCompactionTrace.start_scope("old")
    old_pid = Process.whereis(NativeCompactionTrace)
    %{generation: old_generation} = :sys.get_state(old_pid)

    assert {:ok, _status} = NativeCompactionTrace.reset_scope("new")
    new_pid = Process.whereis(NativeCompactionTrace)
    GenServer.cast(new_pid, {:pooler_event, old_generation, :prepared_frame, %{phase: :compact}})
    assert NativeCompactionTrace.export()["events"] == []

    assert :ok = NativeCompactionTrace.stop_scope()
    assert Process.whereis(NativeCompactionTrace) == nil
    assert :telemetry.list_handlers(TraceEvent.event()) == []
  end

  test "BEAM tracing is limited to enrolled processes and sanitizes message shapes" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)
    worker = spawn(fn -> beam_loop() end)
    outsider = spawn(fn -> beam_loop() end)
    on_exit(fn -> Process.exit(outsider, :kill) end)

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("beam", pids: [response_task: worker])

    monitor = Process.monitor(worker)
    send(worker, {:private_payload, "secret-body"})
    send(outsider, {:outsider_payload, "other-secret"})
    send(worker, :stop)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 15_000

    export = await_event(&(&1["event"] == "beam_process_down"))
    rendered = inspect(export)
    assert rendered =~ "private_payload"
    refute rendered =~ "secret-body"
    refute rendered =~ "outsider_payload"
    refute rendered =~ "other-secret"
    assert NativeCompactionTrace.status()["tracedPids"] == 0
  end

  test "collector death removes the telemetry handler and does not alter caller behavior" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)
    assert {:ok, _status} = NativeCompactionTrace.start_scope("death")
    collector = Process.whereis(NativeCompactionTrace)
    monitor = Process.monitor(collector)
    Process.exit(collector, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^collector, :killed}, 15_000

    assert :ok = TraceEvent.enroll(:owner_session, self())
    assert :ok = TraceEvent.emit(:cleanup_finished, %{outcome: :ok})
    assert NativeCompactionTrace.status()["running"] == false
    assert :ok = NativeCompactionTrace.stop_scope()
    assert :telemetry.list_handlers(TraceEvent.event()) == []
  end

  test "BEAM call tracing records only fingerprinted MFA classes" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)

    worker =
      spawn(fn ->
        receive do
          {:run, caller} ->
            binding = admission_binding()

            {:ok, admission} =
              CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.ordinary_success(
                binding
              )

            {:ok, admission} =
              CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.arm_compact(
                admission,
                10
              )

            result =
              CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.reserve(
                admission,
                :compact,
                binding,
                make_ref(),
                1
              )

            send(caller, {:beam_call_result, result})
        end
      end)

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("beam-call", pids: [owner_session: worker])

    send(worker, {:run, self()})
    assert_receive {:beam_call_result, {:ok, _admission, _capability}}, 15_000

    export = await_event(&(&1["event"] == "beam_call"))
    rendered = inspect(export)
    assert rendered =~ "beam_call"
    refute rendered =~ "NativeCompactionAdmission"
    refute rendered =~ "semantic-turn"
  end

  test "full trace streams readable calls arguments returns messages frames and secrets only redacted" do
    Application.put_env(:codex_pooler, TraceEvent, mode: :off)
    root = Path.join(System.tmp_dir!(), "native-trace-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    worker =
      spawn(fn ->
        receive do
          {:run, caller} ->
            binding =
              receive do
                {:binding, binding} -> binding
              end

            {:ok, admission} = NativeAdmission.ordinary_success(binding)
            {:ok, admission} = NativeAdmission.arm_compact(admission, 100)
            result = NativeAdmission.reserve(admission, :compact, binding, make_ref(), 1)

            send(
              caller,
              {:full_result, result, %{authorization: "Bearer top-secret", branch: :direct}}
            )
        end
      end)

    assert {:ok, %{"mode" => "full", "path" => path}} =
             NativeCompactionTrace.start_scope("full-readable",
               mode: :full,
               root: root,
               pids: [owner_session: worker]
             )

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    send(worker, {:binding, admission_binding()})
    send(worker, {:run, self()})
    assert_receive {:full_result, {:ok, _state, _capability}, _metadata}, 15_000

    assert :ok =
             TraceEvent.emit_full(:upstream_websocket_frame_received, %{
               frame_json: %{
                 "type" => "response.completed",
                 "output" => [%{"text" => "visible-debug-content"}],
                 "authorization" => "Bearer decoded-secret",
                 "nested" => %{
                   "cookie" => "session=secret",
                   "access_token" => "access-secret",
                   "api_key" => "api-secret",
                   "error_id" => "visible-error-id"
                 }
               },
               raw_frame_text:
                 Jason.encode!(%{
                   "type" => "response.completed",
                   "authorization" => "Bearer raw-secret",
                   "cookie" => "session=raw-cookie",
                   "access_token" => "raw-access",
                   "api_key" => "raw-api",
                   "output" => "visible-output",
                   "error_id" => "visible-error-id"
                 }),
               authorization: "Bearer forbidden"
             })

    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()
    content = File.read!(path)

    assert content =~ "NativeCompactionAdmission.reserve/5"
    assert content =~ "semantic_turn_key"
    assert content =~ "beam_return"
    assert content =~ "duration_us"
    assert content =~ "full_result"
    assert content =~ "response.completed"
    assert content =~ "visible-debug-content"
    assert content =~ "visible-output"
    assert content =~ "visible-error-id"
    assert content =~ "[REDACTED_SECRET]"
    refute content =~ "Bearer forbidden"
    refute content =~ "top-secret"
    refute content =~ "decoded-secret"
    refute content =~ "raw-secret"
    refute content =~ "raw-cookie"
    refute content =~ "raw-access"
    refute content =~ "raw-api"
    assert Process.whereis(NativeCompactionTrace) == nil
    assert :telemetry.list_handlers(TraceEvent.event()) == []
    assert :erlang.trace_info({NativeAdmission, :reserve, 5}, :traced) == {:traced, false}
    assert File.rename(path, path <> ".closed") == :ok
  end

  test "full trace enables every critical module with local public and private function patterns" do
    root = private_root("critical-coverage")

    assert {:ok, status} =
             NativeCompactionTrace.start_scope("critical-coverage", mode: :full, root: root)

    expected = [
      CodexPoolerWeb.CodexResponsesSocket,
      ResponseTask,
      CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession,
      CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession,
      NativeAdmission,
      RequestAdmission,
      WebsocketCodec,
      RuntimeAdmissionProof,
      CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1,
      CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3,
      CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder,
      CodexPooler.Gateway.Runtime.Service,
      CodexPooler.Gateway.Runtime.Dispatch.PreDispatch,
      CodexPooler.Gateway.Runtime.Finalization,
      CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector
    ]

    assert Enum.all?(expected, &(inspect(&1) in status["traceModules"]))
    assert length(status["tracePatterns"]) == length(status["traceModules"])
    assert Enum.all?(status["tracePatterns"], &(&1.matched_functions > 0))

    assert Enum.any?(
             status["tracePatterns"],
             &(&1.pattern == "CodexPoolerWeb.CodexResponsesSocket.*/*")
           )

    assert :erlang.trace_info(
             {CodexPoolerWeb.CodexResponsesSocket, :handle_unrevoked_in, 2},
             :traced
           ) == {:traced, :local}

    assert :ok = NativeCompactionTrace.stop_scope()

    assert :erlang.trace_info(
             {CodexPoolerWeb.CodexResponsesSocket, :handle_unrevoked_in, 2},
             :traced
           ) == {:traced, false}
  end

  test "full trace module filters are explicit and unavailable modules fail visibly" do
    root = private_root("module-filters")

    assert {:ok, status} =
             NativeCompactionTrace.start_scope("module-filters",
               mode: :full,
               root: root,
               include_modules: [NativeAdmission, WebsocketCodec],
               exclude_modules: [WebsocketCodec]
             )

    assert status["traceModules"] == [inspect(NativeAdmission)]
    assert status["excludedModules"] == [inspect(WebsocketCodec)]
    assert [%{pattern: pattern, matched_functions: count}] = status["tracePatterns"]
    assert pattern == "#{inspect(NativeAdmission)}.*/*"
    assert count > 10

    assert {:error, {:unknown_trace_module, "Elixir.Does.Not.Exist"}} =
             NativeCompactionTrace.start_scope("unavailable",
               mode: :full,
               root: root,
               include_modules: ["Does.Not.Exist"]
             )
  end

  test "full trace records representative readable MFAs arguments returns and descendant lineage" do
    root = private_root("representative-mfas")

    worker =
      spawn(fn ->
        receive do
          {:trace_representatives, caller, binding} ->
            child =
              spawn(fn ->
                result = NativeAdmission.ordinary_success(binding)
                send(caller, {:child_result, self(), result})
              end)

            {:ok, ordinary} = NativeAdmission.ordinary_success(binding)
            {:ok, pending} = NativeAdmission.arm_compact(ordinary, 100)

            {:ok, _reserved, capability} =
              NativeAdmission.reserve(pending, :compact, binding, make_ref(), 0)

            lifecycle = %{lifecycle_id: binding.lifecycle_id, generation: binding.generation}

            {:ok, request_admission} =
              RequestAdmission.new(capability, {:direct, self()}, lifecycle)

            turn_claim_key = Ecto.UUID.generate()

            {:ok, binding_digest} =
              RequestAdmission.binding_digest(
                request_admission,
                binding.semantic_turn_key,
                turn_claim_key,
                :codex,
                :full,
                :direct
              )

            proof =
              RuntimeAdmissionProof.new(
                self(),
                make_ref(),
                make_ref(),
                binding_digest
              )

            prepared = %PreparedWebsocketFrame{
              variant: :native_response_create,
              endpoint: "/backend-api/codex/responses",
              payload: %{},
              request_options:
                RequestOptions.build(
                  %{},
                  "/backend-api/codex/responses",
                  %{}
                )
            }

            digest = WebsocketCodec.runtime_admission_binding_digest(prepared)
            send(caller, {:representative_result, child, request_admission, proof, digest})
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("representative-mfas",
               mode: :full,
               root: root,
               include_modules: [
                 NativeAdmission,
                 RequestAdmission,
                 RuntimeAdmissionProof,
                 WebsocketCodec
               ],
               pids: [response_task: worker]
             )

    binding = admission_binding()
    send(worker, {:trace_representatives, self(), binding})

    assert_receive {:representative_result, child, %RequestAdmission{}, %RuntimeAdmissionProof{},
                    _},
                   15_000

    assert_receive {:child_result, ^child, {:ok, %NativeAdmission{}}}, 15_000
    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()

    entries = read_entries(path)
    rendered = Jason.encode!(entries)

    for mfa <- [
          "#{inspect(RequestAdmission)}.new/3",
          "#{inspect(RuntimeAdmissionProof)}.new/4",
          "#{inspect(WebsocketCodec)}.runtime_admission_binding_digest/1",
          "#{inspect(NativeAdmission)}.ordinary_success/1"
        ] do
      assert rendered =~ mfa
    end

    assert Enum.any?(entries, &(&1["event"] == "beam_spawn"))

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "beam_pid_enrolled" and
               get_in(entry, ["fields", "parent_pid"]) in [inspect(worker), nil]
           end)

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "beam_spawn" and
               get_in(entry, ["fields", "child_pid"]) == inspect(child) and
               get_in(entry, ["fields", "pid"]) == inspect(worker)
           end)

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "beam_call" and is_list(get_in(entry, ["fields", "arguments"]))
           end)

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "beam_return" and
               Map.has_key?(entry["fields"], "return") and
               is_integer(get_in(entry, ["fields", "duration_us"]))
           end)
  end

  test "full trace follows ResponseTask and an upstream session through real process callbacks" do
    root = private_root("process-callbacks")
    parent = self()

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("process-callbacks",
               mode: :full,
               root: root,
               include_modules: [
                 ResponseTask,
                 UpstreamWebsocketSession,
                 NativeAdmission
               ],
               pids: [socket: self()]
             )

    assert {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()
    _status = await_status(&(&1["tracedPids"] >= 2))

    assert %{generation: generation} =
             UpstreamWebsocketSession.connection_lifecycle_snapshot(upstream_pid)

    assert generation >= 0

    assert {:ok, task_pid} =
             ResponseTask.start(
               parent,
               :local_owner,
               fn pid ->
                 send(parent, {:response_task_callback, pid})
                 {:ok, :trace_result}
               end,
               fn _pid, _reason -> :ok end
             )

    assert_receive {:response_task_callback, ^task_pid}, 15_000
    assert_receive {:codex_response_done, ^task_pid, {:ok, :trace_result}}, 15_000
    assert :ok = UpstreamWebsocketSession.close(upstream_pid)
    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()

    content = File.read!(path)
    assert content =~ "CodexPooler.Gateway.Websocket.ResponseTask"

    assert content =~
             "CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.connection_lifecycle_snapshot/1"

    assert content =~
             "CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.handle_call/3"

    assert content =~ "response_task_callback"
    assert content =~ "codex_response_done"
  end

  test "full trace controls pre-existing owner and upstream sessions and restores sensitivity" do
    root = private_root("preexisting-processes")
    parent = self()

    {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()

    upstream_boundary = %{
      start: fn ->
        {:ok,
         spawn(fn ->
           receive do
             :stop -> :ok
           end
         end)}
      end,
      send: fn _pid, _request, _writer -> :ok end,
      close: fn pid -> send(pid, :stop) end
    }

    persistence = %{
      release_owner_lease: fn _session_id, _lease, _reason, _cause -> :ok end,
      interrupt_codex_session: fn _session_id, _opts -> {:ok, :interrupted} end,
      renew_owner_token: fn _session_id, lease, _opts ->
        {:ok, %{owner_lease_token: lease, owner_instance_id: Atom.to_string(node())}}
      end
    }

    {:ok, owner_pid} =
      WebsocketOwnerSession.start(
        codex_session_id: "trace-owner-#{System.unique_integer([:positive])}",
        owner_lease_token: "owner-lease",
        owner_instance_id: Atom.to_string(node()),
        upstream: upstream_boundary,
        persistence: persistence,
        owner_renewal_ms: 60_000
      )

    on_exit(fn ->
      if Process.alive?(upstream_pid), do: UpstreamWebsocketSession.close(upstream_pid)
      if Process.alive?(owner_pid), do: GenServer.stop(owner_pid)
    end)

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("preexisting-processes",
               mode: :full,
               root: root,
               include_modules: [UpstreamWebsocketSession, WebsocketOwnerSession],
               pids: [upstream_session: upstream_pid, owner_session: owner_pid]
             )

    status = NativeCompactionTrace.status()
    assert sensitivity_state(status, upstream_pid) == :observable
    assert sensitivity_state(status, owner_pid) == :observable

    assert %{generation: 0} = UpstreamWebsocketSession.connection_lifecycle_snapshot(upstream_pid)
    assert {:ok, owner_status} = WebsocketOwnerSession.owner_status(owner_pid)
    assert owner_status.codex_session_id =~ "trace-owner-"
    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()

    content = File.read!(path)
    assert content =~ "UpstreamWebsocketSession.handle_call/3"
    assert content =~ "WebsocketOwnerSession.handle_call/3"
    assert content =~ "connection_lifecycle_snapshot"
    assert content =~ "owner_status"

    upstream_mfa = {UpstreamWebsocketSession, :connection_lifecycle_snapshot, 1}
    owner_mfa = {WebsocketOwnerSession, :owner_status, 1}
    :erlang.trace_pattern(upstream_mfa, true, [:local])
    :erlang.trace_pattern(owner_mfa, true, [:local])
    :erlang.trace(upstream_pid, true, [:call, {:tracer, parent}])
    :erlang.trace(owner_pid, true, [:call, {:tracer, parent}])

    assert %{generation: 0} = UpstreamWebsocketSession.connection_lifecycle_snapshot(upstream_pid)
    assert {:ok, _status} = WebsocketOwnerSession.owner_status(owner_pid)
    refute_receive {:trace, ^upstream_pid, :call, _mfa}, 100
    refute_receive {:trace, ^owner_pid, :call, _mfa}, 100

    :erlang.trace(upstream_pid, false, [:call])
    :erlang.trace(owner_pid, false, [:call])
    :erlang.trace_pattern(upstream_mfa, false, [:local])
    :erlang.trace_pattern(owner_mfa, false, [:local])
  end

  test "collector crash triggers cooperative sensitivity restoration" do
    root = private_root("collector-crash")
    {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()

    on_exit(fn ->
      if Process.alive?(upstream_pid), do: UpstreamWebsocketSession.close(upstream_pid)
    end)

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("collector-crash",
               mode: :full,
               root: root,
               include_modules: [UpstreamWebsocketSession],
               pids: [upstream_session: upstream_pid]
             )

    assert sensitivity_state(NativeCompactionTrace.status(), upstream_pid) == :observable
    collector = Process.whereis(NativeCompactionTrace)
    monitor = Process.monitor(collector)
    Process.exit(collector, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^collector, :killed}, 15_000

    assert eventually(fn ->
             :sys.get_state(upstream_pid).native_compaction_trace_sensitivity == :sensitive
           end)

    assert :ok = NativeCompactionTrace.stop_scope()
    assert :erlang.trace_info(upstream_pid, :flags) == {:flags, []}

    assert :erlang.trace_info({UpstreamWebsocketSession, :handle_call, 3}, :traced) ==
             {:traced, false}

    assert :telemetry.list_handlers(TraceEvent.event()) == []
    assert TraceEvent.mode() == :off
  end

  test "collector crash force-terminates a blocked real ResponseTask after preserving cleanup" do
    root = private_root("collector-blocked-task")
    parent = self()

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("collector-blocked-task",
               mode: :full,
               root: root,
               include_modules: [ResponseTask]
             )

    assert {:ok, task_pid} =
             ResponseTask.start(
               parent,
               :local_owner,
               fn pid ->
                 send(parent, {:collector_blocked_task, pid})

                 receive do
                   :never -> :ok
                 end
               end,
               fn _pid, _reason -> :ok end
             )

    assert_receive {:collector_blocked_task, ^task_pid}, 15_000
    collector = Process.whereis(NativeCompactionTrace)
    collector_monitor = Process.monitor(collector)
    task_monitor = Process.monitor(task_pid)
    Process.exit(collector, :kill)
    assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :killed}, 15_000
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}, 15_000
    assert eventually(fn -> Process.whereis(NativeCompactionTrace.SensitivityRestorer) == nil end)
    assert TraceEvent.mode() == :off
    assert :telemetry.list_handlers(TraceEvent.event()) == []

    assert :erlang.trace_info(
             {ResponseTask, :run_callback_result, 2},
             :traced
           ) ==
             {:traced, false}

    assert File.stat!(path).size > 0
  end

  test "blocked connected upstream is force-terminated before stop succeeds" do
    root = private_root("blocked-connected-upstream")

    {:ok, fake} =
      FakeUpstream.start_link(
        FakeUpstream.websocket_text_frames([
          Jason.encode!(%{"id" => "resp_trace_connected", "object" => "response"})
        ])
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("blocked-connected-upstream",
               mode: :full,
               root: root,
               include_modules: [UpstreamWebsocketSession]
             )

    {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()
    Process.unlink(upstream_pid)

    request = %Request{
      url: FakeUpstream.url(fake) <> "/backend-api/codex/responses",
      headers: [],
      payload: Jason.encode!(%{"type" => "response.create", "input" => []}),
      timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000},
      writer: fn _frame -> :ok end,
      message_mapper: nil
    }

    assert {:ok, _result} = UpstreamWebsocketSession.request(upstream_pid, request)
    assert Map.has_key?(:sys.get_state(upstream_pid), :conn)
    :ok = :sys.suspend(upstream_pid)
    monitor = Process.monitor(upstream_pid)
    assert :ok = NativeCompactionTrace.stop_scope()
    assert_receive {:DOWN, ^monitor, :process, ^upstream_pid, :killed}, 15_000
    assert TraceEvent.mode() == :off

    assert :erlang.trace_info({UpstreamWebsocketSession, :handle_info, 2}, :traced) ==
             {:traced, false}

    assert File.read!(path) =~ "trace_process_forced_termination"
  end

  test "watchdog death still permits guardian restore and a later scope recreates watchdogs" do
    root = private_root("watchdog-restart")
    {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()

    on_exit(fn ->
      if Process.alive?(upstream_pid), do: UpstreamWebsocketSession.close(upstream_pid)
    end)

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("watchdog-restart",
               mode: :full,
               root: root,
               include_modules: [UpstreamWebsocketSession],
               pids: [upstream_session: upstream_pid]
             )

    {:observable, _generation, _monitor, _authorization, _restorer, _collector, watchdog} =
      :sys.get_state(upstream_pid).native_compaction_trace_sensitivity

    watchdog_monitor = Process.monitor(watchdog)
    Process.exit(watchdog, :kill)
    assert_receive {:DOWN, ^watchdog_monitor, :process, ^watchdog, :killed}, 15_000
    assert :ok = NativeCompactionTrace.stop_scope()

    assert Map.get(
             :sys.get_state(upstream_pid),
             :native_compaction_trace_sensitivity,
             :sensitive
           ) == :sensitive

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("watchdog-recreated",
               mode: :full,
               root: root,
               include_modules: [UpstreamWebsocketSession],
               pids: [upstream_session: upstream_pid]
             )

    {:observable, _, _, _, _, _, recreated} =
      :sys.get_state(upstream_pid).native_compaction_trace_sensitivity

    assert is_pid(recreated) and recreated != watchdog
    assert :ok = NativeCompactionTrace.stop_scope()
  end

  test "restorer crash makes live critical processes restore themselves" do
    root = private_root("restorer-crash")
    {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()

    upstream_boundary = %{
      start: fn ->
        {:ok,
         spawn(fn ->
           receive do
             :stop -> :ok
           end
         end)}
      end,
      send: fn _pid, _request, _writer -> :ok end,
      close: fn pid -> send(pid, :stop) end
    }

    persistence = %{
      release_owner_lease: fn _session_id, _lease, _reason, _cause -> :ok end,
      interrupt_codex_session: fn _session_id, _opts -> {:ok, :interrupted} end,
      renew_owner_token: fn _session_id, lease, _opts ->
        {:ok, %{owner_lease_token: lease, owner_instance_id: Atom.to_string(node())}}
      end
    }

    {:ok, owner_pid} =
      WebsocketOwnerSession.start(
        codex_session_id: "restorer-owner-#{System.unique_integer([:positive])}",
        owner_lease_token: "owner-lease",
        owner_instance_id: Atom.to_string(node()),
        upstream: upstream_boundary,
        persistence: persistence,
        owner_renewal_ms: 60_000
      )

    on_exit(fn ->
      if Process.alive?(upstream_pid), do: UpstreamWebsocketSession.close(upstream_pid)
      if Process.alive?(owner_pid), do: GenServer.stop(owner_pid)
    end)

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("restorer-crash",
               mode: :full,
               root: root,
               include_modules: [UpstreamWebsocketSession, WebsocketOwnerSession],
               pids: [upstream_session: upstream_pid, owner_session: owner_pid]
             )

    restorer = Process.whereis(NativeCompactionTrace.SensitivityRestorer)
    monitor = Process.monitor(restorer)
    Process.exit(restorer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^restorer, :killed}, 15_000

    assert eventually(fn ->
             :sys.get_state(upstream_pid).native_compaction_trace_sensitivity == :sensitive and
               :sys.get_state(owner_pid).native_compaction_trace_sensitivity == :sensitive
           end)

    assert :ok = NativeCompactionTrace.stop_scope()
    assert TraceEvent.mode() == :off
  end

  test "blocked ResponseTask is force-terminated after bounded restore attempts" do
    root = private_root("retry-restore")
    parent = self()

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("retry-restore",
               mode: :full,
               root: root,
               include_modules: [ResponseTask]
             )

    assert {:ok, blocker} =
             ResponseTask.start(
               parent,
               :local_owner,
               fn pid ->
                 send(parent, {:retry_observable, pid})

                 receive do
                   :never -> :ok
                 end
               end,
               fn _pid, _reason -> :ok end
             )

    assert_receive {:retry_observable, ^blocker}, 15_000
    monitor = Process.monitor(blocker)
    assert :ok = NativeCompactionTrace.stop_scope()
    assert_receive {:DOWN, ^monitor, :process, ^blocker, :killed}, 15_000
    assert TraceEvent.mode() == :off
    content = File.read!(path)
    assert content =~ "trace_process_forced_termination"
    assert content =~ "sensitivity_restore_unresponsive"
  end

  test "initial enrollment failure unwinds mode handler patterns collector and file" do
    root = private_root("enrollment-unwind")
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}, 15_000

    assert {:error, {:pid_enrollment_failed, :owner_session, ^dead, _reason}} =
             NativeCompactionTrace.start_scope("enrollment-unwind",
               mode: :full,
               root: root,
               include_modules: [NativeAdmission],
               pids: [owner_session: dead]
             )

    assert Process.whereis(NativeCompactionTrace) == nil
    assert Process.whereis(NativeCompactionTrace.SensitivityRestorer) == nil
    assert :telemetry.list_handlers(TraceEvent.event()) == []
    assert TraceEvent.mode() == :off
    assert :erlang.trace_info({NativeAdmission, :reserve, 5}, :traced) == {:traced, false}

    [path] = Path.wildcard(Path.join(root, "*.jsonl"))
    assert File.rename(path, path <> ".closed") == :ok
    assert File.rm(path <> ".closed") == :ok
  end

  test "full stop safe stop off lifecycle captures safe events with no full file" do
    root = private_root("full-safe-off")

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("full-safe-off", mode: :full, root: root)

    assert is_binary(path)
    assert :ok = NativeCompactionTrace.stop_scope()
    assert TraceEvent.mode() == :off

    assert {:ok, %{"mode" => "safe", "path" => nil}} =
             NativeCompactionTrace.start_scope("safe-after-full", mode: :safe, limit: 2)

    assert :ok = TraceEvent.emit(:prepared_frame, %{phase: :compact})
    export = await_event(&(&1["event"] == "prepared_frame"))
    assert export["path"] == nil
    assert export["retainedCount"] == 1
    assert :ok = NativeCompactionTrace.stop_scope()
    assert TraceEvent.mode() == :off
    assert :ignored = TraceEvent.emit(:prepared_frame, %{phase: :compact})
  end

  test "owner and upstream reject spoofed and replayed sensitivity controls" do
    {:ok, upstream_pid} = UpstreamWebsocketSession.start_link()

    on_exit(fn ->
      if Process.alive?(upstream_pid), do: UpstreamWebsocketSession.close(upstream_pid)
    end)

    generation = make_ref()
    authorization = make_ref()
    wrong_restorer = self()

    assert {:error, :unauthorized} =
             GenServer.call(
               upstream_pid,
               {:native_compaction_trace_sensitivity, :observe, generation, authorization,
                wrong_restorer}
             )

    assert Map.get(
             :sys.get_state(upstream_pid),
             :native_compaction_trace_sensitivity,
             :sensitive
           ) == :sensitive

    send(
      upstream_pid,
      {:native_compaction_trace_sensitivity, :restore, generation, authorization, wrong_restorer}
    )

    assert eventually(fn ->
             Map.get(
               :sys.get_state(upstream_pid),
               :native_compaction_trace_sensitivity,
               :sensitive
             ) == :sensitive
           end)
  end

  test "full trace truncation is recorded once and flush fails visibly" do
    root = private_root("truncation")

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("truncation",
               mode: :full,
               root: root,
               include_modules: [NativeAdmission],
               max_events: 2,
               max_bytes: 64_000
             )

    assert :ok = TraceEvent.emit_full(:debug_one, %{state: :before})
    assert :ok = TraceEvent.emit_full(:debug_two, %{state: :during})
    assert :ok = TraceEvent.emit_full(:debug_three, %{state: :after})
    _status = await_status(& &1["truncated"])
    assert {:error, :trace_truncated} = NativeCompactionTrace.flush()
    status = NativeCompactionTrace.status()
    assert status["truncated"]
    assert status["truncationReason"] == "max_events"
    assert :ok = NativeCompactionTrace.stop_scope()

    entries = read_entries(path)
    assert Enum.count(entries, &(&1["event"] == "trace_truncated")) == 1
  end

  test "full trace redacts secrets embedded in JSON and non-JSON frame text only" do
    root = private_root("raw-frame-redaction")

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("raw-frame-redaction",
               mode: :full,
               root: root,
               include_modules: [NativeAdmission]
             )

    json_frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "authorization" => "Bearer secret-auth",
        "cookie" => "session=secret-cookie",
        "nested" => %{
          "access_token" => "secret-access",
          "api_key" => "secret-api"
        },
        "prompt" => "visible-prompt",
        "output" => "visible-output",
        "error" => %{"id" => "visible-error-id"}
      })

    assert :ok =
             TraceEvent.emit_full(:downstream_websocket_frame_received, %{
               frame_text: json_frame,
               frame_json: Jason.decode!(json_frame)
             })

    assert :ok =
             TraceEvent.emit_full(:upstream_websocket_frame_sent, %{
               raw_frame_text:
                 "Authorization: Bearer header-secret Cookie=session-cookie api_key=header-api visible=keep"
             })

    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()
    content = File.read!(path)
    assert content =~ "visible-prompt"
    assert content =~ "visible-output"
    assert content =~ "visible-error-id"
    assert content =~ "visible=keep"
    assert content =~ "[REDACTED_SECRET]"

    for secret <-
          ~w(secret-auth secret-cookie secret-access secret-api header-secret session-cookie header-api) do
      refute content =~ secret
    end
  end

  test "output-open failure unwinds every diagnostic process and active control" do
    parent = private_root("output-open-failure")
    blocked = Path.join(parent, "not-a-directory")
    File.write!(blocked, "occupied")

    assert {:error, _reason} =
             NativeCompactionTrace.start_scope("output-open-failure",
               mode: :full,
               root: blocked,
               include_modules: [NativeAdmission]
             )

    assert Process.whereis(NativeCompactionTrace) == nil
    assert Process.whereis(NativeCompactionTrace.SensitivityRestorer) == nil
    assert TraceEvent.mode() == :off
    assert TraceEvent.sensitivity_control() == :inactive
    assert :telemetry.list_handlers(TraceEvent.event()) == []
    assert :erlang.trace_info({NativeAdmission, :reserve, 5}, :traced) == {:traced, false}
  end

  test "dev trace endpoint accepts full filters and reports truncation as visible failure" do
    root = private_root("endpoint-full")

    started =
      :post
      |> Plug.Test.conn(
        "/start",
        Jason.encode!(%{
          "run" => "endpoint-full",
          "mode" => "full",
          "includeModules" => [inspect(NativeAdmission)],
          "maxEvents" => 1,
          "maxBytes" => 64_000
        })
      )
      |> TracePlug.call([])

    assert started.status == 200
    body = Jason.decode!(started.resp_body)
    assert body["traceModules"] == [inspect(NativeAdmission)]
    assert :ok = NativeCompactionTrace.stop_scope()

    assert {:ok, _status} =
             NativeCompactionTrace.start_scope("endpoint-full",
               mode: :full,
               root: root,
               include_modules: [NativeAdmission],
               max_events: 1,
               max_bytes: 64_000
             )

    assert :ok = TraceEvent.emit_full(:first, %{state: :one})
    assert :ok = TraceEvent.emit_full(:second, %{state: :two})
    _status = await_status(& &1["truncated"])

    flushed = :post |> Plug.Test.conn("/flush") |> TracePlug.call([])
    assert flushed.status == 507
    assert Jason.decode!(flushed.resp_body)["truncated"]
  end

  test "full trace records exception class value and duration from an allowlisted call" do
    root =
      Path.join(System.tmp_dir!(), "native-trace-exception-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    worker =
      spawn(fn ->
        receive do
          {:raise, caller} ->
            result =
              try do
                raise_traced_exception()
              rescue
                error -> {:raised, error.__struct__}
              end

            send(caller, result)
        end
      end)

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("exception",
               mode: :full,
               root: root,
               include_modules: [__MODULE__],
               pids: [owner_session: worker]
             )

    send(worker, {:raise, self()})
    assert_receive {:raised, ArgumentError}, 15_000
    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()
    content = File.read!(path)
    assert content =~ "beam_exception"
    assert content =~ "ArgumentError"
    assert content =~ "duration_us"
  end

  test "full mode fails closed when the build does not allow it" do
    assert {:error, :full_trace_unavailable} =
             NativeCompactionTrace.validate_requested_mode(:full, false)

    assert :ok = NativeCompactionTrace.validate_requested_mode(:safe, false)
    assert TraceEvent.runtime_mode("full", :prod) == :off
    assert TraceEvent.runtime_mode("full", :dev) == :full
    assert TraceEvent.runtime_mode("safe", :prod) == :safe
  end

  test "full trace reconstructs reserve accounting consume send terminal and finalize in order" do
    root =
      Path.join(System.tmp_dir!(), "native-trace-timeline-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    worker =
      spawn(fn ->
        receive do
          {:timeline, caller, binding} ->
            {:ok, admission} = NativeAdmission.ordinary_success(binding)
            {:ok, admission} = NativeAdmission.arm_compact(admission, 100)

            {:ok, admission, capability} =
              NativeAdmission.reserve(admission, :compact, binding, make_ref(), 1)

            :ok =
              TraceEvent.emit_capability(:capability_reserved, capability, %{
                branch: :direct_owner
              })

            {:ok, admission} = NativeAdmission.mark_accounting_started(admission, capability, 2)

            :ok =
              TraceEvent.emit_capability(:accounting_started, capability, %{branch: :direct_owner})

            {:ok, _admission} = NativeAdmission.consume(admission, capability, 3)

            :ok =
              TraceEvent.emit_capability(:capability_consumed, capability, %{
                branch: :direct_owner
              })

            :ok = TraceEvent.emit(:physical_send_started, %{phase: :compact, outcome: :started})

            :ok =
              TraceEvent.emit_full(:upstream_websocket_frame_sent, %{
                frame_json: %{"type" => "response.create", "input" => "debug-visible"}
              })

            :ok = TraceEvent.emit(:physical_send_finished, %{phase: :compact, outcome: :ok})

            :ok =
              TraceEvent.emit_full(:upstream_websocket_frame_received, %{
                frame_json: %{"type" => "response.completed", "status" => "completed"}
              })

            :ok = TraceEvent.emit(:owner_terminal, %{phase: :compact, outcome: :ok})
            :ok = TraceEvent.emit(:finalization_finished, %{phase: :compact, outcome: :ok})
            send(caller, :timeline_done)
        end
      end)

    assert {:ok, %{"path" => path}} =
             NativeCompactionTrace.start_scope("timeline",
               mode: :full,
               root: root,
               pids: [owner_session: worker]
             )

    send(worker, {:timeline, self(), admission_binding()})
    assert_receive :timeline_done, 15_000
    assert :ok = NativeCompactionTrace.flush()
    assert :ok = NativeCompactionTrace.stop_scope()

    entries = path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    events = Enum.map(entries, & &1["event"])

    assert ordered?(events, [
             "beam_call",
             "capability_reserved",
             "accounting_started",
             "capability_consumed",
             "physical_send_started",
             "upstream_websocket_frame_sent",
             "physical_send_finished",
             "upstream_websocket_frame_received",
             "owner_terminal",
             "finalization_finished"
           ])

    assert Enum.all?(
             entries,
             &(is_integer(&1["systemTimeUs"]) and is_integer(&1["monotonicTimeUs"]))
           )

    assert Enum.any?(
             entries,
             &(&1["event"] == "beam_return" and is_integer(get_in(&1, ["fields", "duration_us"])))
           )
  end

  test "recursive redaction preserves operational state and removes credential values" do
    redacted =
      NativeCompactionTrace.redact_secrets(%{
        branch: :binding_mismatch,
        frame: %{"type" => "response.failed", "error" => "actual-state-error"},
        headers: %{"authorization" => "Bearer hidden", "x-request-id" => "request-visible"},
        auth_json: %{"access_token" => "hidden", "account_id" => "visible-account"},
        capability: %{token: "capability-hidden", phase: :compact},
        payload: [tool: %{output: "visible-tool-output"}]
      })

    assert redacted.branch == :binding_mismatch
    assert redacted.frame["error"] == "actual-state-error"
    assert redacted.headers["x-request-id"] == "request-visible"
    assert redacted.headers["authorization"] == "[REDACTED_SECRET]"
    assert redacted.auth_json == "[REDACTED_SECRET]"
    assert redacted.capability == %{token: "[REDACTED_SECRET]", phase: :compact}

    assert redacted.payload == [tool: %{output: "visible-tool-output"}]
  end

  test "enrollment control traces only the explicitly announced process" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)
    worker = spawn(fn -> beam_loop() end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    assert {:ok, _status} = NativeCompactionTrace.start_scope("automatic-enrollment")
    assert :ok = TraceEvent.enroll(:owner_session, worker)
    send(worker, {:owner_private_message, "never-retain-this"})

    export = await_event(&(&1["event"] == "beam_receive"))
    assert NativeCompactionTrace.status()["tracedPids"] == 1
    assert inspect(export) =~ "owner_private_message"
    refute inspect(export) =~ "never-retain-this"
  end

  test "dev trace endpoint exposes a deterministic start capture status and stop lifecycle" do
    Application.put_env(:codex_pooler, TraceEvent, enabled: true)

    started =
      :post
      |> Plug.Test.conn("/start", Jason.encode!(%{"run" => "endpoint-run", "limit" => 3}))
      |> TracePlug.call([])

    assert started.status == 200
    assert Jason.decode!(started.resp_body)["running"]
    assert :ok = TraceEvent.emit(:prepared_frame, %{phase: :compact})
    _export = await_event(&(&1["event"] == "prepared_frame"))

    captured = :get |> Plug.Test.conn("/") |> TracePlug.call([])
    assert captured.status == 200
    assert Jason.decode!(captured.resp_body)["eventCount"] == 1

    stopped = :post |> Plug.Test.conn("/stop") |> TracePlug.call([])
    assert stopped.status == 200
    assert Jason.decode!(stopped.resp_body)["running"] == false
  end

  test "dev trace endpoint rejects non-loopback callers" do
    conn =
      :get
      |> Plug.Test.conn("/status")
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> TracePlug.call([])

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "loopback_only"}
  end

  defp beam_loop do
    receive do
      :stop -> :ok
      _message -> beam_loop()
    end
  end

  defp raise_traced_exception, do: raise(ArgumentError, "synthetic traced exception")

  defp admission_binding do
    %CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding{
      semantic_turn_key: :crypto.hash(:sha256, "semantic-turn"),
      window_digest: :crypto.hash(:sha256, "window"),
      context_digest: :crypto.hash(:sha256, "context"),
      window_number: 1,
      serving_mode: :full,
      topology:
        %CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct{},
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }
  end

  defp await_event_count(count), do: await_export(fn export -> export["eventCount"] == count end)

  defp await_event(predicate),
    do: await_export(fn export -> Enum.any?(export["events"], predicate) end)

  defp await_status(predicate, attempts \\ 100)
  defp await_status(_predicate, 0), do: flunk("trace status did not reach expected state")

  defp await_status(predicate, attempts) do
    status = NativeCompactionTrace.status()

    if predicate.(status) do
      status
    else
      receive after: (10 -> :ok)
      await_status(predicate, attempts - 1)
    end
  end

  defp await_export(predicate, attempts \\ 100)
  defp await_export(_predicate, 0), do: flunk("trace export did not reach expected state")

  defp await_export(predicate, attempts) do
    export = NativeCompactionTrace.export()

    if predicate.(export) do
      export
    else
      receive after: (10 -> :ok)
      await_export(predicate, attempts - 1)
    end
  end

  defp ordered?(events, expected) do
    {_rest, found} =
      Enum.reduce(events, {expected, []}, fn event, {remaining, found} ->
        case remaining do
          [^event | tail] -> {tail, [event | found]}
          _other -> {remaining, found}
        end
      end)

    Enum.reverse(found) == expected
  end

  defp private_root(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "native-trace-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp read_entries(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp sensitivity_state(status, pid),
    do:
      get_in(status, ["processSensitivity", inspect(pid), "state"]) ||
        get_in(status, ["processSensitivity", inspect(pid), :state])

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      receive after: (10 -> :ok)
      eventually(fun, attempts - 1)
    end
  end
end
