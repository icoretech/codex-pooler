defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSessionTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias CodexPooler.AgentV2ContractFixture
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Confirmation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketFrameWriter
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  import ExUnit.CaptureLog

  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}

  # Detection budget for observing a call the session itself already bounds by
  # @timeouts. It has to stay above those scenario timeouts, or a loaded run
  # gives up on a request that was still allowed to be in flight.
  @detection_timeout_ms 5_000

  defmodule ForwardedHandoffProbe do
    use GenServer

    def start_link({expected_lifecycle, expected_mode, observer}) do
      GenServer.start_link(__MODULE__, {expected_lifecycle, expected_mode, observer})
    end

    @impl GenServer
    def init({expected_lifecycle, expected_mode, observer}) do
      {:ok,
       %{
         expected_lifecycle: expected_lifecycle,
         expected_mode: expected_mode,
         observer: observer,
         redeemed?: false
       }}
    end

    @impl GenServer
    def handle_call(
          {:redeem_forwarded_send_v1, _witness, lifecycle, mode},
          _from,
          %{redeemed?: true, observer: observer} = state
        ) do
      send(observer, {:forwarded_handoff_replay, lifecycle, mode})
      {:reply, {:error, :forwarded_send_witness_rejected}, state}
    end

    def handle_call(
          {:redeem_forwarded_send_v1, _witness, lifecycle, mode},
          _from,
          %{expected_lifecycle: lifecycle, expected_mode: mode, observer: observer} = state
        ) do
      send(observer, {:forwarded_handoff_redeemed, lifecycle, mode})
      {:reply, :ok, %{state | redeemed?: true}}
    end

    def handle_call(
          {:redeem_forwarded_send_v1, _witness, lifecycle, mode},
          _from,
          %{observer: observer} = state
        ) do
      send(observer, {:forwarded_handoff_stale, lifecycle, mode})
      {:reply, {:error, :forwarded_send_witness_rejected}, state}
    end
  end

  test "characterization exposes the initial websocket lifecycle through OTP status" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    status = :sys.get_status(session)

    assert Map.take(status_state(status), [:lifecycle_id, :generation]) ==
             lifecycle_state(session)

    assert status_logged_events(status) == []
  end

  test "OTP status and transient request inspection expose only safe projections" do
    header_marker = private_marker(:header)
    payload_marker = private_marker(:payload)
    transport_marker = private_marker(:transport)
    send_text_marker = private_marker(:send_text)

    upstream = start_upstream(websocket_success("resp_ws_status_projection"))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | headers: [{"x-private-status", header_marker}],
        payload: Jason.encode!(%{"input" => payload_marker})
    }

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, request)

    assert {:ok, :sent} =
             UpstreamWebsocketSession.send_request_frame(session, send_text_marker)

    send(session, {:private_transport_message, transport_marker})
    _state_after_transport_message = :sys.get_state(session)

    status = :sys.get_status(session)

    assert status_state(status) == %{
             lifecycle_id: lifecycle_state(session).lifecycle_id,
             generation: 1,
             connected?: true,
             reconnect_pending?: false,
             request_active?: false,
             keepalive_pending?: true,
             pong_pending?: false,
             admission_phase: :cleared
           }

    assert status_logged_events(status) == []

    assert inspect(request) ==
             "#CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request<redacted>"

    dispatch_request = %UpstreamDispatch.Request{
      url: header_marker,
      token: payload_marker,
      upstream_payload: transport_marker,
      original_payload: %{"private" => send_text_marker}
    }

    assert inspect(dispatch_request) ==
             "#CodexPooler.Gateway.Transports.UpstreamDispatch.Request<redacted>"

    formatted =
      UpstreamWebsocketSession.format_status(%{
        reason: RuntimeError.exception(payload_marker),
        message: {:request, request},
        state: :sys.get_state(session),
        log: [{:in, {:private_transport_message, transport_marker}}]
      })

    assert formatted.reason == {:exception, RuntimeError}
    assert formatted.message == :request
    assert formatted.state == status_state(status)
    assert formatted.log == []

    assert %{message: :send_text} =
             UpstreamWebsocketSession.format_status(%{message: {:send_text, send_text_marker}})

    assert %{message: :transport_message} =
             UpstreamWebsocketSession.format_status(%{
               message: {:private_transport_message, transport_marker}
             })

    for marker <- [header_marker, payload_marker, transport_marker, send_text_marker] do
      refute inspect(status) =~ marker
      refute inspect(request) =~ marker
      refute inspect(dispatch_request) =~ marker
      refute inspect(formatted) =~ marker
    end
  end

  test "direct accounting rejection logs the admission state before clearing it" do
    upstream = start_upstream(websocket_success("resp_ws_admission_diagnostics"))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    binding = direct_admission_binding(lifecycle_state(session))
    now_ms = System.system_time(:millisecond)
    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, now_ms + 30_000)

    assert {:ok, capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               make_ref(),
               now_ms
             )

    assert :ok =
             UpstreamWebsocketSession.mark_compaction_accounting_started(
               session,
               capability,
               now_ms
             )

    payload = %{"model" => "gpt-test"}

    request_options =
      %{request_id: "admission-diagnostic-request"}
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.put_native_compaction_admission(
        capability,
        {:direct, session},
        lifecycle_state(session)
      )

    for current_state <- [:accounting_started_compact, :cleared] do
      log =
        capture_log(fn ->
          assert {:error, :invalid_transition} =
                   UpstreamWebsocketSession.mark_compaction_accounting_started(
                     session,
                     capability,
                     now_ms
                   )

          assert AccountingReservation.pre_attempt_failure(:invalid_transition, request_options) ==
                   %{
                     status: 500,
                     code: "gateway_reservation_failed",
                     message: "gateway request reservation failed",
                     retryable: false
                   }
        end)

      assert [line, reservation_line] = String.split(log, "\n", trim: true)
      assert line =~ "native compaction admission rejected"
      assert line =~ "step=mark_accounting_started"
      assert line =~ "phase=compact"
      assert line =~ "current_state=#{current_state}"
      assert line =~ "expected_state=reserved_compact"
      assert line =~ "topology=direct"
      assert line =~ "reason=invalid_transition"
      assert line =~ "native_lifecycle_id=#{binding.lifecycle_id}"
      assert reservation_line =~ "native_lifecycle_id=#{binding.lifecycle_id}"
      assert reservation_line =~ "request_id=admission-diagnostic-request"
      refute log =~ Base.encode16(capability.token)
    end

    malformed_capability = %{capability | phase: :private_phase_sentinel, binding: nil}

    malformed_log =
      capture_log(fn ->
        assert {:error, :invalid_transition} =
                 UpstreamWebsocketSession.mark_compaction_accounting_started(
                   session,
                   malformed_capability,
                   now_ms
                 )
      end)

    assert malformed_log =~ "phase=unknown"
    assert malformed_log =~ "native_lifecycle_id=none"
    refute malformed_log =~ "private_phase_sentinel"
  end

  test "direct admission reserves once, consumes immediately before send, and acknowledges compact collection" do
    observer = attach_native_compaction_observer()
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert %{generation: 0} = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    assert_receive {:upstream_websocket_frame, _warmup_frame}, @detection_timeout_ms

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    binding = direct_admission_binding(lifecycle)
    expires_at_ms = System.system_time(:millisecond) + 30_000

    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, expires_at_ms)
    control_ref = make_ref()

    assert {:ok, %Capability{} = capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               control_ref,
               System.system_time(:millisecond)
             )

    assert :ok =
             UpstreamWebsocketSession.mark_compaction_accounting_started(
               session,
               capability,
               System.system_time(:millisecond)
             )

    request = %{
      raw_websocket_request(peer.url, self())
      | native_compaction_capability: capability,
        expected_connection_lifecycle: lifecycle
    }

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, request)

    assert :collected_unconfirmed = UpstreamWebsocketSession.compaction_admission_phase(session)

    digest = :crypto.hash(:sha256, "synthetic-compaction-item")

    confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: control_ref,
      binding: %{binding | compaction_item_digest: digest}
    }

    assert :ok =
             UpstreamWebsocketSession.acknowledge_compact_finalization(
               session,
               {:success, digest, confirmation, expires_at_ms}
             )

    assert :pending_final = UpstreamWebsocketSession.compaction_admission_phase(session)

    final_binding = %{
      binding
      | window_digest: :crypto.hash(:sha256, "next-window"),
        context_digest: :crypto.hash(:sha256, "next-context"),
        window_number: binding.window_number + 1,
        compaction_item_digest: digest
    }

    assert {:ok, final_capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :final,
               final_binding,
               make_ref(),
               System.system_time(:millisecond)
             )

    assert :ok =
             UpstreamWebsocketSession.mark_compaction_accounting_started(
               session,
               final_capability,
               System.system_time(:millisecond)
             )

    final_request = %{
      raw_websocket_request(peer.url, self())
      | native_compaction_capability: final_capability,
        expected_connection_lifecycle: lifecycle
    }

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, final_request)

    assert :consumed_final = UpstreamWebsocketSession.compaction_admission_phase(session)
    assert :ok = UpstreamWebsocketSession.acknowledge_final_response(session, :success)
    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)

    assert observer.() ==
             expected_native_compaction_counts()
             |> Map.drop([:compact_runtime_proof_redeemed, :final_runtime_proof_redeemed])
  end

  test "direct admission failures and replay emit no successful transition facts" do
    observer = attach_native_compaction_observer()
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    binding = direct_admission_binding(lifecycle)
    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, 30_000)

    assert {:error, :expired} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               make_ref(),
               30_001
             )

    assert observer.() == %{}
  end

  test "direct admission rejects stale capability without bytes and releases only pre-accounting cancellation" do
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    binding = direct_admission_binding(lifecycle)
    expires_at_ms = System.system_time(:millisecond) + 30_000
    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, expires_at_ms)

    assert {:ok, capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               make_ref(),
               System.system_time(:millisecond)
             )

    assert :ok =
             UpstreamWebsocketSession.cancel_compaction_reservation(
               session,
               capability,
               System.system_time(:millisecond)
             )

    assert :pending_compact = UpstreamWebsocketSession.compaction_admission_phase(session)

    assert {:ok, capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               make_ref(),
               System.system_time(:millisecond)
             )

    assert :ok =
             UpstreamWebsocketSession.mark_compaction_accounting_started(
               session,
               capability,
               System.system_time(:millisecond)
             )

    stale_capability =
      NativeCompactionAdmission.Capability.replace_token(
        capability,
        :crypto.strong_rand_bytes(32)
      )

    request = %{
      raw_websocket_request(peer.url, self())
      | native_compaction_capability: stale_capability,
        expected_connection_lifecycle: lifecycle
    }

    assert {:error, %{reason: :native_compaction_capability_rejected}} =
             UpstreamWebsocketSession.request(session, request)

    refute_received {:raw_upstream_websocket_request, 1, 2}
    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)
  end

  test "direct admission clears on finalization failure, invalidation, reconnect, and caller death" do
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    binding = direct_admission_binding(lifecycle)
    expires_at_ms = System.system_time(:millisecond) + 30_000
    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, expires_at_ms)
    assert :ok = UpstreamWebsocketSession.acknowledge_compact_finalization(session, :failure)
    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)

    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, expires_at_ms)
    assert :ok = UpstreamWebsocketSession.invalidate_connection(session)
    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    replacement_lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    assert replacement_lifecycle.generation == lifecycle.generation + 1
    refute replacement_lifecycle == lifecycle

    replacement_binding = direct_admission_binding(replacement_lifecycle)
    assert :ok = UpstreamWebsocketSession.arm_compact(session, replacement_binding, expires_at_ms)

    Agent.update(peer.state, &%{&1 | response_mode: :hold})

    owner = self()

    request_pid =
      spawn(fn ->
        UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, owner))
      end)

    request_monitor = Process.monitor(request_pid)

    assert_receive {:raw_upstream_websocket_request, 2, 2}, @detection_timeout_ms
    Process.exit(request_pid, :kill)

    assert_receive {:DOWN, ^request_monitor, :process, ^request_pid, :killed},
                   @detection_timeout_ms

    _ = :sys.get_state(session)
    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)
  end

  test "direct admission rejects malformed controls and stale lifecycle before upstream send" do
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:error, :invalid_input} = UpstreamWebsocketSession.arm_compact(session, %{}, -1)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.reserve_compaction(session, :unknown, %{}, nil, -1)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    binding = direct_admission_binding(lifecycle)
    expires_at_ms = System.system_time(:millisecond) + 30_000
    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, expires_at_ms)

    assert {:ok, capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               make_ref(),
               System.system_time(:millisecond)
             )

    assert :ok =
             UpstreamWebsocketSession.mark_compaction_accounting_started(
               session,
               capability,
               System.system_time(:millisecond)
             )

    stale_lifecycle = %{lifecycle | generation: lifecycle.generation + 1}

    request = %{
      raw_websocket_request(peer.url, self())
      | native_compaction_capability: capability,
        expected_connection_lifecycle: stale_lifecycle
    }

    assert {:error, %{reason: :native_compaction_capability_rejected}} =
             UpstreamWebsocketSession.request(session, request)

    assert Agent.get(peer.state, & &1.connection_count) == 1
    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)
  end

  test "direct admission clears a reserved capability after a stale reserve attempt" do
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    binding = direct_admission_binding(lifecycle)
    now_ms = System.system_time(:millisecond)
    assert :ok = UpstreamWebsocketSession.arm_compact(session, binding, now_ms + 30_000)

    assert {:ok, capability} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               binding,
               make_ref(),
               now_ms
             )

    stale_binding = %{binding | generation: binding.generation + 1}

    assert {:error, :binding_mismatch} =
             UpstreamWebsocketSession.reserve_compaction(
               session,
               :compact,
               stale_binding,
               make_ref(),
               now_ms
             )

    assert :cleared = UpstreamWebsocketSession.compaction_admission_phase(session)

    request = %{
      raw_websocket_request(peer.url, self())
      | native_compaction_capability: capability,
        expected_connection_lifecycle: lifecycle
    }

    assert {:error, %{reason: :native_compaction_capability_rejected}} =
             UpstreamWebsocketSession.request(session, request)

    refute_received {:raw_upstream_websocket_request, 1, 2}
  end

  test "public admission APIs return bounded errors for every malformed call shape" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:error, :invalid_input} = UpstreamWebsocketSession.connection_lifecycle_snapshot(:bad)
    assert {:error, :invalid_input} = UpstreamWebsocketSession.arm_compact(:bad, %{}, -1)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.authorize_first_compact_collection(:bad, %{}, nil)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.record_first_compact_collected(:bad, %{})

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.reserve_compaction(:bad, :unknown, %{}, nil, -1)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.mark_compaction_accounting_started(:bad, %{}, -1)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.cancel_compaction_reservation(:bad, %{}, -1)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.acknowledge_compact_finalization(:bad, :failure)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.acknowledge_compact_finalization(session, :invalid)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.acknowledge_final_response(session, :invalid)

    assert {:error, :invalid_input} =
             UpstreamWebsocketSession.acknowledge_final_response(:bad, :success)

    assert {:error, :invalid_input} = UpstreamWebsocketSession.clear_compaction_admission(:bad)
    assert {:error, :invalid_input} = UpstreamWebsocketSession.compaction_admission_phase(:bad)
  end

  test "forwarded handoff redeems on the live generation immediately before one physical send" do
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    assert_receive {:upstream_websocket_frame, _warmup_frame}, @detection_timeout_ms

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    handoff = forwarded_handoff_probe(lifecycle, :full, self())

    request = %{
      raw_websocket_request(peer.url, self())
      | forwarded_owner_send_handoff: handoff,
        effective_serving_mode: "full"
    }

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:forwarded_handoff_redeemed, ^lifecycle, :full}, @detection_timeout_ms
    assert_receive {:upstream_websocket_frame, _accepted_frame}, @detection_timeout_ms

    assert {:error, %{reason: :native_compaction_capability_rejected}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:forwarded_handoff_replay, ^lifecycle, :full}, @detection_timeout_ms
    refute_received {:upstream_websocket_frame, _extra_frame}
  end

  test "forwarded handoff rejects replacement generation and mixed direct authorization with zero bytes" do
    peer = start_raw_websocket_peer(response_mode: :terminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    assert_receive {:upstream_websocket_frame, _warmup_frame}, @detection_timeout_ms

    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    stale_handoff = forwarded_handoff_probe(lifecycle, :full, self())

    assert :ok = UpstreamWebsocketSession.invalidate_connection(session)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    assert_receive {:upstream_websocket_frame, _replacement_frame}, @detection_timeout_ms

    replacement_lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(session)
    assert replacement_lifecycle.generation == lifecycle.generation + 1

    stale_request = %{
      raw_websocket_request(peer.url, self())
      | forwarded_owner_send_handoff: stale_handoff,
        effective_serving_mode: "full"
    }

    assert {:error, %{reason: :native_compaction_capability_rejected}} =
             UpstreamWebsocketSession.request(session, stale_request)

    assert_receive {:forwarded_handoff_stale, ^replacement_lifecycle, :full},
                   @detection_timeout_ms

    refute_received {:upstream_websocket_frame, _stale_frame}

    mixed_handoff = forwarded_handoff_probe(replacement_lifecycle, :full, self())
    mixed_binding = direct_admission_binding(replacement_lifecycle)

    mixed_capability = %Capability{
      phase: :compact,
      binding: mixed_binding,
      control_ref: make_ref(),
      token: :crypto.strong_rand_bytes(32),
      expires_at_ms: System.system_time(:millisecond) + 30_000
    }

    mixed_request = %{
      stale_request
      | forwarded_owner_send_handoff: mixed_handoff,
        native_compaction_capability: mixed_capability,
        expected_connection_lifecycle: replacement_lifecycle
    }

    assert {:error, %{reason: :native_compaction_capability_rejected}} =
             UpstreamWebsocketSession.request(session, mixed_request)

    refute_received {:forwarded_handoff_redeemed, _lifecycle, _mode}
    refute_received {:upstream_websocket_frame, _mixed_frame}
  end

  test "OTP termination report redacts installed request state and crashing transport message" do
    header_marker = private_marker(:crash_header)
    payload_marker = private_marker(:crash_payload)
    transport_marker = private_marker(:crash_transport)

    upstream = start_upstream(websocket_success("resp_ws_crash_projection"))
    {:ok, session} = GenServer.start(UpstreamWebsocketSession, :new)
    monitor = Process.monitor(session)
    :ok = :sys.log(session, true)

    send(session, {:private_transport_message, transport_marker})
    _state_after_transport_message = :sys.get_state(session)

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | headers: [{"x-private-crash", header_marker}],
        payload: Jason.encode!(%{"input" => payload_marker}),
        writer: fn _text -> raise "synthetic writer crash" end
    }

    captured_log =
      capture_log(fn ->
        assert {:error, %{reason: :upstream_websocket_session_unavailable}} =
                 UpstreamWebsocketSession.request(session, request)

        assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, @detection_timeout_ms
      end)

    assert captured_log =~ "GenServer"
    assert captured_log =~ "terminating"
    assert captured_log =~ "RuntimeError"
    assert captured_log =~ "UpstreamWebsocketSession.handle_text_frame"

    for marker <- [header_marker, payload_marker, transport_marker] do
      refute captured_log =~ marker
    end
  end

  @tag :websocket_owner_pin
  test "PIN-P02 exact legacy typeless binary id remains terminal without status or object" do
    frame = ~s({"id":"resp_pin_legacy_typeless"})
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert body == "data: #{frame}\n\n"
  end

  test "public mapper classifies a canonicalized typeless detail as a terminal failure" do
    detail = ~s({"detail":"synthetic terminal detail"})
    upstream = start_upstream(FakeUpstream.websocket_text_frames([detail]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | message_mapper: &StreamProtocol.normalize_public_openai_responses_json_message/1,
        writer: fn frame -> send(parent, {:mapped_terminal_frame, frame}) end
    }

    assert {:ok, %{body: body, terminal: "response.failed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:mapped_terminal_frame, frame}

    assert %{"type" => "response.failed", "error" => %{"code" => "upstream_terminal_failure"}} =
             Jason.decode!(frame)

    assert body =~ "upstream_terminal_failure"
    refute body =~ "synthetic terminal detail"
  end

  @tag :websocket_owner_regression
  test "RED-R01 response.done followed by clean close completes before close classification" do
    frame =
      Jason.encode!(%{
        "type" => "response.done",
        "response" => %{"id" => "resp_red_done", "status" => "completed"}
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert body == "data: #{frame}\n\n"
  end

  test "malformed response.done stays nonterminal until a valid terminal arrives" do
    malformed =
      Jason.encode!(%{
        "type" => "response.done",
        "response" => %{"id" => "resp_malformed_done", "status" => "failed"}
      })

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_after_malformed", "status" => "completed"}
      })

    upstream =
      start_upstream(FakeUpstream.websocket_text_frames([malformed, completed]))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert body == "data: #{malformed}\n\ndata: #{completed}\n\n"
  end

  test "characterization preserves websocket result body status headers and frame metadata" do
    frame = %{
      "type" => "response.failed",
      "response" => %{
        "id" => "resp_ws_result_characterization",
        "error" => %{"code" => "rate_limit_exceeded"}
      },
      "headers" => %{
        "openai-request-id" => "frame-request-characterization",
        "x-private-header" => "private-header-characterization"
      }
    }

    upstream = start_upstream(FakeUpstream.websocket_text_frames([Jason.encode!(frame)]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | writer: fn text -> send(parent, {:characterization_writer_frame, text}) end
    }

    assert {:ok, result} =
             UpstreamWebsocketSession.request(session, request)

    expected_frame = Map.delete(frame, "headers")

    assert Map.take(result, [:body, :status, :terminal, :websocket_frame_headers]) == %{
             body: "data: #{Jason.encode!(frame)}\n\n",
             status: 200,
             terminal: "response.failed",
             websocket_frame_headers: %{
               "openai-request-id" => "frame-request-characterization"
             }
           }

    assert Enum.all?(result.headers, fn {name, value} ->
             is_binary(name) and is_binary(value)
           end)

    assert Enum.any?(result.headers, fn {name, value} ->
             name == "sec-websocket-accept" and byte_size(value) > 0
           end)

    assert_receive {:characterization_writer_frame, downstream_frame}
    assert Jason.decode!(downstream_frame) == expected_frame
    refute downstream_frame =~ "private-header-characterization"
  end

  test "decoded observer sees raw frames while retained body keeps mapped provider bytes" do
    rate_limit = ~s({"type":"codex.rate_limits","rate_limits":{}})
    malformed = ~s({"type":"response.output_text.delta")

    terminal =
      Jason.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "id" => "resp_decoded_observer",
          "status" => "failed",
          "error" => %{"code" => "server_error"}
        },
        "headers" => %{"openai-request-id" => "observer-request"}
      })

    upstream =
      start_upstream(FakeUpstream.websocket_text_frames([rate_limit, malformed, terminal]))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | message_mapper: &StreamProtocol.normalize_public_openai_responses_json_message/1,
        frame_observer: fn frame, decoded ->
          send(parent, {:observed_frame, byte_size(frame), decoded})
        end
    }

    assert {:ok, result} = UpstreamWebsocketSession.request(session, request)

    assert_receive {:observed_frame, rate_limit_bytes, %{"type" => "codex.rate_limits"}}
    assert rate_limit_bytes == byte_size(rate_limit)
    assert_receive {:observed_frame, malformed_bytes, :undecodable}
    assert malformed_bytes == byte_size(malformed)

    assert_receive {:observed_frame, terminal_bytes,
                    %{
                      "type" => "response.failed",
                      "response" => %{"status" => "failed"},
                      "headers" => %{"openai-request-id" => "observer-request"}
                    }}

    assert terminal_bytes == byte_size(terminal)
    assert result.terminal == "response.failed"
    assert result.websocket_frame_headers == %{"openai-request-id" => "observer-request"}
    assert result.body =~ "data: #{rate_limit}\n\ndata: #{malformed}\n\n"
    refute result.body =~ "observer-request"
  end

  test "mapper and writer callback failures remain terminal for the upstream session" do
    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_mandatory_callback_failure", "status" => "completed"}
      })

    Enum.each([:mapper, :writer], fn callback_kind ->
      upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
      {:ok, session} = GenServer.start(UpstreamWebsocketSession, :new)
      monitor = Process.monitor(session)
      parent = self()

      request =
        case callback_kind do
          :mapper ->
            %{
              websocket_request(FakeUpstream.url(upstream))
              | message_mapper: fn _text -> raise "synthetic mapper callback failure" end,
                writer: fn _text -> send(parent, :mapper_writer_called) end
            }

          :writer ->
            %{
              websocket_request(FakeUpstream.url(upstream))
              | writer: fn _text -> raise "synthetic writer callback failure" end
            }
        end

      capture_log(fn ->
        assert {:error, %{reason: :upstream_websocket_session_unavailable}} =
                 UpstreamWebsocketSession.request(session, request)

        assert_receive {:DOWN, ^monitor, :process, ^session,
                        {%RuntimeError{}, callback_stacktrace}},
                       @detection_timeout_ms

        {expected_function, expected_arity} =
          if callback_kind == :mapper, do: {:map_message, 3}, else: {:handle_text_frame, 6}

        assert stack_has_mfa?(
                 callback_stacktrace,
                 UpstreamWebsocketSession,
                 expected_function,
                 expected_arity
               )
      end)

      refute_received :mapper_writer_called
    end)
  end

  test "observer exception throw and exit are contained before exactly-once terminal delivery" do
    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_optional_observer_failure", "status" => "completed"}
      })

    Enum.each(
      [
        {:error, "Elixir.RuntimeError", fn marker -> raise RuntimeError, marker end},
        {:throw, "none", fn marker -> throw({:observer_throw, marker}) end},
        {:exit, "none", fn marker -> exit({:observer_exit, marker}) end}
      ],
      fn {failure_kind, exception_class, fail_observer} ->
        marker = private_marker(failure_kind)

        upstream =
          start_upstream(
            {:sequence,
             [
               FakeUpstream.websocket_text_frames([terminal]),
               websocket_success("resp_after_optional_observer_failure")
             ]}
          )

        {:ok, session} = GenServer.start(UpstreamWebsocketSession, :new)
        monitor = Process.monitor(session)
        parent = self()

        request = %{
          websocket_request(FakeUpstream.url(upstream))
          | frame_observer: fn _text, _decoded ->
              send(parent, {:observer_called, failure_kind})
              fail_observer.(marker)
            end,
            writer: fn frame, discriminator ->
              send(parent, {:observer_failure_writer, failure_kind, frame, discriminator})
            end
        }

        {result, logs} =
          with_log(fn ->
            UpstreamWebsocketSession.request(session, request)
          end)

        assert {:ok, %{terminal: "response.completed", status: 200}} = result
        assert_receive {:observer_called, ^failure_kind}

        assert_receive {:observer_failure_writer, ^failure_kind, ^terminal,
                        %{terminal: "response.completed"}}

        refute_received {:observer_called, ^failure_kind}
        refute_received {:observer_failure_writer, ^failure_kind, _frame, _discriminator}
        refute_received {:DOWN, ^monitor, :process, ^session, _reason}
        assert Process.alive?(session)

        assert length(Regex.scan(~r/upstream websocket frame observer failed/, logs)) == 1
        assert logs =~ "operation=observe_frame"
        assert logs =~ "failure_kind=#{failure_kind}"
        assert logs =~ "exception_class=#{exception_class}"
        refute logs =~ marker

        assert {:ok, %{terminal: "response.completed", status: 200}} =
                 UpstreamWebsocketSession.request(
                   session,
                   websocket_request(FakeUpstream.url(upstream))
                 )

        assert Process.alive?(session)
        :ok = UpstreamWebsocketSession.close(session)
      end
    )
  end

  test "two-argument writers receive the mapped terminal discriminator" do
    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_writer_discriminator", "status" => "completed"}
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | writer: fn frame, discriminator ->
          send(parent, {:classified_writer_frame, frame, discriminator})
        end
    }

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:classified_writer_frame, ^terminal, %{terminal: "response.completed"}}
  end

  test "native snapshot emits metadata before a sanitized terminal failure while observers retain raw data" do
    terminal =
      Jason.encode!(%{
        "type" => "response.failed",
        "headers" => %{
          "openai-model" => "frame-model",
          "x-models-etag" => "provider-etag",
          "authorization" => "hostile-auth"
        },
        "response" => %{
          "status" => "failed",
          "error" => %{"code" => "server_error"},
          "headers" => %{
            "x-reasoning-included" => true,
            "cookie" => "hostile-cookie"
          }
        }
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | native_codex_response_control: %TurnSnapshot{models_etag: "pooler-etag"},
        writer: fn frame -> send(parent, {:native_metadata_frame, frame}) end,
        frame_observer: fn frame, decoded ->
          send(parent, {:native_metadata_observer, frame, decoded})
        end
    }

    assert {:ok, %{terminal: "response.failed"} = result} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:native_metadata_frame, metadata}
    assert metadata_event(metadata) == %{"x-models-etag" => "pooler-etag"}
    assert_receive {:native_metadata_frame, sanitized_terminal}

    assert Jason.decode!(sanitized_terminal) == %{
             "type" => "response.failed",
             "headers" => %{"openai-model" => "frame-model"},
             "response" => %{
               "status" => "failed",
               "error" => %{"code" => "server_error"},
               "headers" => %{"x-reasoning-included" => "true"}
             }
           }

    assert_receive {:native_metadata_observer, ^terminal, observed}
    assert observed["headers"]["authorization"] == "hostile-auth"
    assert observed["response"]["headers"]["cookie"] == "hostile-cookie"
    assert result.body == "data: #{terminal}\n\n"
    assert result.body =~ "hostile-auth"
    assert result.body =~ "hostile-cookie"
    assert result.body =~ "provider-etag"
    refute sanitized_terminal =~ "hostile-auth"
    refute sanitized_terminal =~ "hostile-cookie"
    refute sanitized_terminal =~ "provider-etag"
    refute_received {:native_metadata_frame, _extra}
  end

  test "native snapshot takes model only from successful handshake headers" do
    peer =
      start_raw_websocket_peer(
        upgrade_headers: [
          {"OpenAI-Model", "handshake-model"},
          {"x-models-etag", "provider-etag"},
          {"set-cookie", "hostile-cookie"},
          {"openai-request-id", "hostile-request-id"}
        ]
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | native_codex_response_control: %TurnSnapshot{models_etag: "pooler-etag"}
    }

    assert {:ok, _result} = UpstreamWebsocketSession.request(session, request)
    assert_receive {:upstream_websocket_frame, metadata}

    assert metadata_event(metadata) == %{
             "openai-model" => "handshake-model",
             "x-models-etag" => "pooler-etag"
           }

    assert_receive {:upstream_websocket_frame, accepted}
    assert %{"id" => _id} = Jason.decode!(accepted)
    refute metadata =~ "provider-etag"
    refute metadata =~ "hostile-cookie"
    refute metadata =~ "hostile-request-id"

    assert {:ok, reused_result} = UpstreamWebsocketSession.request(session, request)
    assert reused_result.upstream_websocket_connection.reused
    assert_receive {:upstream_websocket_frame, reused_metadata}
    assert metadata_event(reused_metadata) == metadata_event(metadata)
    assert_receive {:upstream_websocket_frame, reused_accepted}
    assert %{"id" => _id} = Jason.decode!(reused_accepted)
    refute_received {:upstream_websocket_frame, _extra}
  end

  test "native snapshot removes malformed top-level and nested header containers" do
    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "headers" => ["invalid-container"],
        "response" => %{"status" => "completed", "headers" => "invalid-container"}
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | native_codex_response_control: %TurnSnapshot{models_etag: "pooler-etag"},
        writer: fn frame -> send(parent, {:malformed_metadata_frame, frame}) end,
        frame_observer: fn frame, decoded ->
          send(parent, {:malformed_metadata_observer, frame, decoded})
        end
    }

    assert {:ok, _result} = UpstreamWebsocketSession.request(session, request)
    assert_receive {:malformed_metadata_frame, metadata}
    assert metadata_event(metadata) == %{"x-models-etag" => "pooler-etag"}
    assert_receive {:malformed_metadata_frame, sanitized}

    assert Jason.decode!(sanitized) == %{
             "type" => "response.completed",
             "response" => %{"status" => "completed"}
           }

    assert_receive {:malformed_metadata_observer, ^terminal, observed}
    assert observed["headers"] == ["invalid-container"]
    assert observed["response"]["headers"] == "invalid-container"
    refute_received {:malformed_metadata_frame, _extra}
  end

  test "native snapshot emits none for retryable first output and once for later accepted output" do
    retryable =
      Jason.encode!(%{
        "type" => "error",
        "status" => 400,
        "headers" => %{"authorization" => "retry-hostile-auth"},
        "response" => %{"headers" => %{"cookie" => "retry-hostile-cookie"}},
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "invalid_api_key"
        }
      })

    accepted =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_text_frames([retryable]),
           FakeUpstream.websocket_text_frames([accepted])
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | native_codex_response_control: %TurnSnapshot{models_etag: "retry-etag"},
        writer: fn frame -> send(parent, {:retry_metadata_frame, frame}) end,
        frame_observer: fn frame, decoded ->
          send(parent, {:retry_metadata_observer, frame, decoded})
        end
    }

    assert {:error, %{reason: {:auth_refresh_first_event, _failure}} = retry_result} =
             UpstreamWebsocketSession.request(session, request)

    assert retry_result.body == "data: #{retryable}\n\n"
    assert retry_result.body =~ "retry-hostile-auth"
    assert retry_result.body =~ "retry-hostile-cookie"
    refute_received {:retry_metadata_frame, _frame}
    refute_received {:retry_metadata_observer, _frame, _decoded}

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:retry_metadata_frame, metadata}
    assert metadata_event(metadata) == %{"x-models-etag" => "retry-etag"}
    assert_receive {:retry_metadata_frame, ^accepted}
    assert_receive {:retry_metadata_observer, ^accepted, %{"type" => "response.completed"}}
    refute_received {:retry_metadata_frame, _extra}
  end

  test "native websocket preserves a structural child text delta byte-for-byte" do
    child_delta =
      ~s({"type":"response.output_text.delta","output_index":1,"content_index":0,"sequence_number":7,"delta":"sanitized-child-delta"})

    terminal =
      ~s({"type":"response.completed","response":{"id":"resp_sanitized_child_delta","status":"completed"}})

    upstream = start_upstream(FakeUpstream.websocket_text_frames([child_delta, terminal]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    parent = self()

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | writer: fn frame -> send(parent, {:native_child_delta_frame, frame}) end,
        message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:native_child_delta_frame, ^child_delta}
    assert_receive {:native_child_delta_frame, terminal_frame}
    assert %{"type" => "response.completed"} = Jason.decode!(terminal_frame)
  end

  test "same-key requests reuse one FakeUpstream connection and process replacement opens another" do
    upstream =
      start_upstream(
        {:sequence,
         Enum.map(1..3, fn index ->
           FakeUpstream.json_response(%{
             "id" => "resp_ws_connection_characterization_#{index}",
             "object" => "response"
           })
         end)}
      )

    request = websocket_request(FakeUpstream.url(upstream))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    initial_lifecycle = lifecycle_state(session)
    assert initial_lifecycle.generation == 0

    assert {:ok, first_result} = UpstreamWebsocketSession.request(session, request)

    first_lifecycle = lifecycle_state(session)
    assert first_lifecycle == %{initial_lifecycle | generation: 1}
    assert_connection_metadata(first_result, first_lifecycle, false, false)

    assert {:ok, reused_result} = UpstreamWebsocketSession.request(session, request)

    assert lifecycle_state(session) == first_lifecycle
    assert_connection_metadata(reused_result, first_lifecycle, true, false)
    assert [first_request, second_request] = FakeUpstream.requests(upstream)
    assert first_request.websocket_connection_id == second_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    monitor = Process.monitor(session)
    :ok = UpstreamWebsocketSession.close(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000

    {:ok, replacement} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(replacement) end)
    replacement_initial_lifecycle = lifecycle_state(replacement)

    assert replacement_initial_lifecycle.generation == 0
    assert replacement_initial_lifecycle.lifecycle_id != initial_lifecycle.lifecycle_id

    assert {:ok, replacement_result} = UpstreamWebsocketSession.request(replacement, request)

    replacement_lifecycle = %{replacement_initial_lifecycle | generation: 1}
    assert lifecycle_state(replacement) == replacement_lifecycle
    assert_connection_metadata(replacement_result, replacement_lifecycle, false, false)

    assert [first_request, second_request, replacement_request] =
             FakeUpstream.requests(upstream)

    assert first_request.websocket_connection_id == second_request.websocket_connection_id
    assert replacement_request.websocket_connection_id != first_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "characterization reconnects the same session lifecycle after a preterminal peer close" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_characterized_initial"),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success("resp_ws_characterized_reconnect")
         ]}
      )

    request = websocket_request(FakeUpstream.url(upstream))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:ok, first_result} = UpstreamWebsocketSession.request(session, request)
    generation_one = %{initial_lifecycle | generation: 1}
    assert_connection_metadata(first_result, generation_one, false, false)

    assert {:ok, second_result} = UpstreamWebsocketSession.request(session, request)
    generation_two = %{initial_lifecycle | generation: 2}
    assert_connection_metadata(second_result, generation_two, false, true)
    assert lifecycle_state(session) == generation_two
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "controlled terminal-plus-close releases the terminal before the peer close" do
    release_ref = make_ref()

    terminal = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_ws_controlled_terminal", "status" => "completed"}
    }

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    parent = self()
    request = websocket_request(FakeUpstream.url(upstream))

    request = %{
      request
      | writer: fn frame -> send(parent, {:controlled_terminal_frame, frame}) end
    }

    request_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, request)
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                    ^release_ref},
                   1_000

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

    assert_receive {:controlled_terminal_frame, frame}, 1_000
    assert %{"type" => "response.completed"} = Jason.decode!(frame)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             Task.await(request_task, 1_000)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, close_barrier_pid,
                    ^release_ref},
                   1_000

    send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})

    assert Process.alive?(session)
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
  end

  test "controlled close-without-terminal returns a bounded failure without stopping the session" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.websocket_close_without_terminal_barrier(
          notify: self(),
          release_ref: release_ref
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, websocket_request(FakeUpstream.url(upstream)))
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, barrier_pid, ^release_ref},
                   1_000

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

    assert {:error,
            %{
              body: "",
              reason: :upstream_websocket_closed_before_terminal,
              transport_failure: %{
                "phase" => "upstream_close",
                "termination_source" => "peer_close_frame",
                "transport_signal" => "tcp_data",
                "connection_use" => "fresh",
                "connection_request_bucket" => "first",
                "connection_age_bucket" => "under_1m",
                "connection_idle_bucket" => "first_request",
                "websocket_buffer_bucket" => "empty",
                "websocket_fragment_open" => false,
                "last_upstream_event_type" => "none",
                "last_upstream_event_class" => "none",
                "terminal_candidate_seen" => false
              }
            }} = Task.await(request_task, 1_000)

    assert Process.alive?(session)
    assert lifecycle_state(session).generation == 1
    assert FakeUpstream.http_request_count(upstream) == 0
  end

  test "peer close after an arbitrary nonterminal event records only bounded protocol buckets" do
    raw_event_type = "response.private_event_sentinel_deadbeef"
    raw_payload = "private-frame-sentinel-cafefeed"
    raw_close_reason = "private-close-sentinel-feedface"

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            %{
              "type" => raw_event_type,
              "delta" => raw_payload
            }
          ],
          code: 1000,
          reason: raw_close_reason
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    {result, captured_log} =
      with_log(fn ->
        UpstreamWebsocketSession.request(
          session,
          websocket_request(FakeUpstream.url(upstream))
        )
      end)

    assert {:error, failure} = result

    assert Map.take(failure.transport_failure, [
             "last_upstream_event_type",
             "last_upstream_event_class",
             "terminal_candidate_seen"
           ]) == %{
             "last_upstream_event_type" => "response.unknown",
             "last_upstream_event_class" => "response_unknown_event",
             "terminal_candidate_seen" => false
           }

    refute Map.has_key?(failure.transport_failure, "terminal_candidate_type")
    refute Map.has_key?(failure.transport_failure, "terminal_candidate_class")
    refute Map.has_key?(failure.transport_failure, "terminal_candidate_rejection")

    for sentinel <- [raw_event_type, raw_payload, raw_close_reason] do
      refute inspect(failure.transport_failure) =~ sentinel
      refute captured_log =~ sentinel
    end
  end

  test "peer close after a rejected terminal candidate records the bounded rejection reason" do
    raw_status = "private-status-sentinel-deadbeef"
    raw_response_id = "private-response-sentinel-cafefeed"
    raw_close_reason = "private-close-sentinel-feedface"

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            %{
              "type" => "response.done",
              "response" => %{
                "id" => raw_response_id,
                "status" => raw_status
              }
            }
          ],
          code: 1000,
          reason: raw_close_reason
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    {result, captured_log} =
      with_log(fn ->
        UpstreamWebsocketSession.request(
          session,
          websocket_request(FakeUpstream.url(upstream))
        )
      end)

    assert {:error, failure} = result

    assert Map.take(failure.transport_failure, [
             "last_upstream_event_type",
             "last_upstream_event_class",
             "terminal_candidate_seen",
             "terminal_candidate_type",
             "terminal_candidate_class",
             "terminal_candidate_rejection"
           ]) == %{
             "last_upstream_event_type" => "response.done",
             "last_upstream_event_class" => "terminal_success_candidate",
             "terminal_candidate_seen" => true,
             "terminal_candidate_type" => "response.done",
             "terminal_candidate_class" => "success",
             "terminal_candidate_rejection" => "invalid_response_status"
           }

    for sentinel <- [raw_status, raw_response_id, raw_close_reason] do
      refute inspect(failure.transport_failure) =~ sentinel
      refute captured_log =~ sentinel
    end
  end

  test "terminal handed back beside a coalesced transport error completes the turn" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.websocket_close_without_terminal_barrier(
          notify: self(),
          release_ref: release_ref
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    parent = self()
    request = websocket_request(FakeUpstream.url(upstream))
    request = %{request | writer: fn frame -> send(parent, {:coalesced_frame, frame}) end}

    request_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, request)
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, barrier_pid, ^release_ref},
                   1_000

    socket = session_socket(session)
    :ok = :gen_tcp.close(socket)

    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ws_coalesced_terminal", "status" => "completed"}
      })

    send(session, {:tcp, socket, server_text_frame(terminal)})

    assert {:ok, %{terminal: "response.completed", status: 200, body: body}} =
             Task.await(request_task, 1_000)

    assert body =~ "resp_ws_coalesced_terminal"
    assert_receive {:coalesced_frame, frame}, 1_000
    assert %{"type" => "response.completed"} = Jason.decode!(frame)
    assert Process.alive?(session)

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})
  end

  test "frames handed back beside a coalesced transport error keep a truthful failure" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.websocket_close_without_terminal_barrier(
          notify: self(),
          release_ref: release_ref
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    parent = self()
    request = websocket_request(FakeUpstream.url(upstream))
    request = %{request | writer: fn frame -> send(parent, {:coalesced_delta_frame, frame}) end}

    request_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, request)
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, barrier_pid, ^release_ref},
                   1_000

    socket = session_socket(session)
    :ok = :gen_tcp.close(socket)

    delta =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "coalesced partial output"
      })

    send(session, {:tcp, socket, server_text_frame(delta)})

    assert {:error,
            %{
              body: body,
              reason: %Mint.TransportError{},
              transport_failure: %{"phase" => "receive", "terminal_seen" => false} = failure
            }} = Task.await(request_task, 1_000)

    assert body =~ "coalesced partial output"
    assert failure["termination_source"] == "mint_transport_error"
    assert failure["transport_signal"] == "tcp_data"
    assert failure["websocket_buffer_bucket"] == "empty"
    assert failure["websocket_fragment_open"] == false
    assert failure["text_frame_count"] == 1
    assert_receive {:coalesced_delta_frame, delta_frame}, 1_000
    assert delta_frame =~ "coalesced partial output"

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})
  end

  test "transport close during a fragmented websocket message records bounded decoder state" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.websocket_close_without_terminal_barrier(
          notify: self(),
          release_ref: release_ref
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, websocket_request(FakeUpstream.url(upstream)))
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, barrier_pid, ^release_ref},
                   1_000

    socket = session_socket(session)
    send(session, {:tcp, socket, <<0x01, 3, "abc", 0x80, 10, "def">>})
    send(session, {:tcp_closed, socket})

    assert {:error,
            %{
              reason: %Mint.TransportError{reason: :closed},
              transport_failure: %{
                "termination_source" => "mint_transport_error",
                "transport_signal" => "tcp_closed",
                "websocket_buffer_bucket" => "bytes_1_125",
                "websocket_fragment_open" => true
              }
            }} = Task.await(request_task, 1_000)

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})
  end

  test "reused failure records finite connection age ordinal and idle buckets" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_before_reused_close"),
           FakeUpstream.websocket_sse_then_close([
             %{"type" => "response.created", "response" => %{"id" => "resp_ws_reused_close"}}
           ])
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    request = websocket_request(FakeUpstream.url(upstream))

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, request)

    assert {:error, %{transport_failure: failure}} =
             UpstreamWebsocketSession.request(session, request)

    assert Map.take(failure, [
             "termination_source",
             "transport_signal",
             "connection_use",
             "connection_request_bucket",
             "connection_age_bucket",
             "connection_idle_bucket"
           ]) == %{
             "termination_source" => "peer_close_frame",
             "transport_signal" => "tcp_data",
             "connection_use" => "reused",
             "connection_request_bucket" => "requests_2_5",
             "connection_age_bucket" => "under_1m",
             "connection_idle_bucket" => "under_5s"
           }
  end

  test "invalidation closes only the current connection and reconnects on the next explicit request" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_before_invalidation"),
           websocket_success("resp_ws_after_invalidation"),
           websocket_success("resp_ws_reused_after_invalidation")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    monitor = Process.monitor(session)
    request = websocket_request(FakeUpstream.url(upstream))
    initial_lifecycle = lifecycle_state(session)

    assert {:ok, first_result} = UpstreamWebsocketSession.request(session, request)
    generation_one = %{initial_lifecycle | generation: 1}
    assert_connection_metadata(first_result, generation_one, false, false)

    assert :ok = UpstreamWebsocketSession.invalidate_connection(session)
    assert Process.alive?(session)
    refute_received {:DOWN, ^monitor, :process, ^session, _reason}
    assert lifecycle_state(session) == generation_one

    assert {:ok, second_result} = UpstreamWebsocketSession.request(session, request)
    generation_two = %{initial_lifecycle | generation: 2}
    assert_connection_metadata(second_result, generation_two, false, true)
    assert lifecycle_state(session) == generation_two

    assert {:ok, third_result} = UpstreamWebsocketSession.request(session, request)
    assert_connection_metadata(third_result, generation_two, true, false)
    assert lifecycle_state(session) == generation_two

    assert [first_request, second_request, third_request] = FakeUpstream.requests(upstream)
    assert first_request.websocket_connection_id != second_request.websocket_connection_id
    assert second_request.websocket_connection_id == third_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "invalidation without a current connection returns a bounded error and preserves lifecycle" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    initial_lifecycle = lifecycle_state(session)

    assert {:error, :upstream_websocket_not_connected} =
             UpstreamWebsocketSession.invalidate_connection(session)

    assert Process.alive?(session)
    assert lifecycle_state(session) == initial_lifecycle
  end

  test "two-sender owner harness releases every race input independently" do
    parent = self()
    controls = WebsocketOwnerNodeHarness.two_sender_controls()

    upstream =
      WebsocketOwnerNodeHarness.two_sender_upstream_boundary(self(), controls,
        nonterminal_frames: ["nonterminal"],
        terminal_frames: ["terminal"],
        task_result: {:ok, :task_result}
      )

    assert {:ok, upstream_pid} = upstream.start.()
    writer = fn frame -> send(parent, {:controlled_owner_frame, frame}) end
    send_task = Task.async(fn -> upstream.send.(upstream_pid, "request", writer) end)

    assert_receive {:websocket_owner_harness_controlled_barrier, :task_result, task_barrier,
                    task_ref},
                   1_000

    assert task_ref == controls.task_result

    assert_receive {:websocket_owner_harness_controlled_barrier, :nonterminal_frames,
                    nonterminal_barrier, nonterminal_ref},
                   1_000

    assert nonterminal_ref == controls.nonterminal_frames

    :ok =
      WebsocketOwnerNodeHarness.release_controlled(
        nonterminal_barrier,
        controls,
        :nonterminal_frames
      )

    assert_receive {:controlled_owner_frame, "nonterminal"}, 1_000

    assert_receive {:websocket_owner_harness_controlled_barrier, :terminal_frames,
                    terminal_barrier, terminal_ref},
                   1_000

    assert terminal_ref == controls.terminal_frames

    :ok =
      WebsocketOwnerNodeHarness.release_controlled(terminal_barrier, controls, :terminal_frames)

    assert_receive {:controlled_owner_frame, "terminal"}, 1_000

    :ok = WebsocketOwnerNodeHarness.release_controlled(task_barrier, controls, :task_result)
    assert Task.await(send_task, 1_000) == {:ok, :task_result}

    for {stage, expected} <- [
          downstream_send_result: :downstream_sent,
          invalidation_result: :invalidated
        ] do
      result_task =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.controlled_result(parent, controls, stage, expected)
        end)

      assert_receive {:websocket_owner_harness_controlled_barrier, ^stage, barrier_pid,
                      release_ref},
                     1_000

      assert release_ref == Map.fetch!(controls, stage)
      :ok = WebsocketOwnerNodeHarness.release_controlled(barrier_pid, controls, stage)
      assert Task.await(result_task, 1_000) == expected
    end

    timer_target = self()

    timer_task =
      Task.async(fn ->
        WebsocketOwnerNodeHarness.controlled_timer_message(
          parent,
          timer_target,
          controls,
          {:controlled_timer, controls.timer_message}
        )
      end)

    assert_receive {:websocket_owner_harness_controlled_barrier, :timer_message, timer_barrier,
                    timer_ref},
                   1_000

    assert timer_ref == controls.timer_message
    :ok = WebsocketOwnerNodeHarness.release_controlled(timer_barrier, controls, :timer_message)
    assert_receive {:controlled_timer, ^timer_ref}, 1_000
    assert Task.await(timer_task, 1_000) == :ok

    upstream.close.(upstream_pid)
  end

  test "advances generations 1,1,2 through reuse and transparent reconnect" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_generation_1"),
           websocket_success("resp_ws_generation_1_reused"),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success("resp_ws_generation_2")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    handoff = AgentV2ContractFixture.handoff!(:followup_task)

    request = %{
      websocket_request(FakeUpstream.url(upstream))
      | payload: Jason.encode!(%{"type" => "response.create", "input" => [handoff]})
    }

    initial_lifecycle = lifecycle_state(session)

    assert {:ok, initial_result} = UpstreamWebsocketSession.request(session, request)

    generation_one = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == generation_one
    assert_connection_metadata(initial_result, generation_one, false, false)

    assert {:ok, reused_result} = UpstreamWebsocketSession.request(session, request)

    assert lifecycle_state(session) == generation_one
    assert_connection_metadata(reused_result, generation_one, true, false)

    assert {:ok, reconnected_result} = UpstreamWebsocketSession.request(session, request)

    generation_two = %{initial_lifecycle | generation: 2}
    assert lifecycle_state(session) == generation_two
    assert_connection_metadata(reconnected_result, generation_two, false, true)

    assert [first_request, second_request, interrupted_request, reconnected_request] =
             FakeUpstream.requests(upstream)

    assert first_request.websocket_connection_id == second_request.websocket_connection_id
    assert interrupted_request.websocket_connection_id == first_request.websocket_connection_id
    assert reconnected_request.websocket_connection_id != first_request.websocket_connection_id

    assert Enum.map([first_request, second_request, interrupted_request, reconnected_request], fn
             captured -> captured.json["input"]
           end) == List.duplicate([handoff], 4)

    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "request_once uses an invocation-scoped lifecycle and reaches generation one" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_once_first"),
           websocket_success("resp_ws_once_second")
         ]}
      )

    request = websocket_request(FakeUpstream.url(upstream))

    assert {{:ok, first_result}, first_trace} = request_once_lifecycle_trace(request)

    assert {{:ok, second_result}, second_trace} = request_once_lifecycle_trace(request)

    assert [%{generation: 0} = first_initial, %{generation: 1} = first_connected] =
             first_trace

    assert first_connected.lifecycle_id == first_initial.lifecycle_id
    assert_connection_metadata(first_result, first_connected, false, false)

    assert [%{generation: 0} = second_initial, %{generation: 1} = second_connected] =
             second_trace

    assert second_connected.lifecycle_id == second_initial.lifecycle_id
    assert_connection_metadata(second_result, second_connected, false, false)
    assert second_initial.lifecycle_id != first_initial.lifecycle_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "does not advance generation when TCP connection fails" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: %Mint.TransportError{reason: :econnrefused}}} =
             UpstreamWebsocketSession.request(session, websocket_request(closed_tcp_url()))

    assert_disconnected_lifecycle(session, initial_lifecycle)
  end

  test "does not advance generation when FakeUpstream rejects the websocket upgrade" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{"error" => %{"code" => "upgrade_rejected"}},
          status: 403
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, failure} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert %{body: "", reason: {:websocket_upgrade_failed, 403, _headers}} = failure
    refute Map.has_key?(failure, :upstream_websocket_connection)

    assert_disconnected_lifecycle(session, initial_lifecycle)
    assert FakeUpstream.websocket_connection_count(upstream) == 0
  end

  test "does not advance generation for a malformed HTTP upgrade response" do
    peer = start_raw_websocket_peer(upgrade_mode: :malformed_response)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: %Mint.HTTPError{reason: :invalid_status_line}}} =
             UpstreamWebsocketSession.request(session, websocket_request(peer.url))

    assert_disconnected_lifecycle(session, initial_lifecycle)

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  @tag :fragmented_upgrade_boundary
  test "Mint rejects upgrade headers without a status line before response completion" do
    peer = start_raw_websocket_peer(upgrade_mode: :missing_status)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: %Mint.HTTPError{reason: :invalid_status_line}}} =
             UpstreamWebsocketSession.request(session, websocket_request(peer.url))

    assert_disconnected_lifecycle(session, initial_lifecycle)

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  @tag :fragmented_upgrade_boundary
  test "Mint emits a split upgrade status before the terminal headers and done batch" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_status)
    uri = URI.parse(peer.url)

    {:ok, conn} =
      Mint.HTTP.connect(:http, uri.host, uri.port, protocols: [:http1], mode: :passive)

    on_exit(fn -> Mint.HTTP.close(conn) end)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, uri.path, [])

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :status, peer_pid},
                   @detection_timeout_ms

    assert {:ok, conn, [{:status, ^ref, 101}]} =
             Mint.WebSocket.recv(conn, 0, @detection_timeout_ms)

    send(peer_pid, :release_raw_upstream_websocket_upgrade)

    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    {conn, responses} = receive_mint_upgrade_until_done(conn, ref, deadline, [])
    assert [{:headers, ^ref, headers}, {:done, ^ref}] = responses
    assert {"upgrade", "websocket"} in headers

    {:ok, _conn} = Mint.HTTP.close(conn)
    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "an intact raw HTTP websocket upgrade establishes generation one" do
    peer = start_raw_websocket_peer(upgrade_mode: :valid)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:ok, result} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    assert_connection_metadata(result, %{initial_lifecycle | generation: 1}, false, false)
    assert_receive {:upstream_websocket_frame, _frame}, @detection_timeout_ms

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  @tag :fragmented_upgrade_boundary
  test "retains a status 101 emitted in a Mint batch before the terminal headers batch" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_status)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)
    owner = self()

    request_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, owner))
      end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :status, peer_pid},
                   @detection_timeout_ms

    assert_stack_eventually_in(session, ConnectionUpgrade, :await_upgrade, 5)
    send(peer_pid, :release_raw_upstream_websocket_upgrade)

    assert {:ok, result} = Task.await(request_task, @detection_timeout_ms)
    assert_connection_metadata(result, %{initial_lifecycle | generation: 1}, false, false)
    assert_receive {:upstream_websocket_frame, _frame}, @detection_timeout_ms

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "retains status across a partial header line before final upgrade headers" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_partial_headers)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    owner = self()

    task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, owner))
      end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :partial_headers, peer_pid},
                   @detection_timeout_ms

    send(peer_pid, :release_raw_upstream_websocket_upgrade)
    assert {:ok, _result} = Task.await(task, @detection_timeout_ms)
    assert_receive {:upstream_websocket_frame, _frame}, @detection_timeout_ms
  end

  @tag :fragmented_upgrade_boundary
  test "uses the completed final block when informational and final responses share one Mint batch" do
    peer =
      start_raw_websocket_peer(
        upgrade_mode: :informational_then_valid,
        upgrade_headers: [{"x-final-upgrade", "present"}]
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, _result} =
             UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, self()))

    state = :sys.get_state(session)
    assert {"x-final-upgrade", "present"} in state.headers
    refute Enum.any?(state.headers, fn {name, _value} -> name == "x-informational-sentinel" end)
  end

  test "retains a fragmented non-101 status for the terminal upgrade failure" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_forbidden)
    owner = self()

    result_task =
      Task.async(fn ->
        UpstreamWebsocketSession.request_once(raw_websocket_request(peer.url, owner))
      end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :forbidden_status, peer_pid},
                   @detection_timeout_ms

    send(peer_pid, :release_raw_upstream_websocket_upgrade)

    assert {:error, %{body: "", reason: {:websocket_upgrade_failed, 403, headers}}} =
             Task.await(result_task, @detection_timeout_ms)

    assert {"content-length", "0"} in headers
    refute_received {:raw_upstream_websocket_upgrade_payload, 1, _bytes}
  end

  test "caller death after the first upgrade fragment closes without sending payload" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_status)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    owner = self()

    task =
      Task.async(fn ->
        UpstreamWebsocketSession.request(session, raw_websocket_request(peer.url, owner))
      end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :status, peer_pid},
                   @detection_timeout_ms

    assert Task.shutdown(task, :brutal_kill) == nil
    send(peer_pid, :release_raw_upstream_websocket_upgrade)
    assert :closed = wait_for_raw_websocket_connection_closed(1, 500)
    refute_received {:raw_upstream_websocket_upgrade_payload, 1, _bytes}
  end

  test "queued terminal upgrade data wins at an expired monotonic deadline" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_status)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 80, receive_timeout_ms: 1_000}
    }

    owner = self()
    request = %{request | writer: fn text -> send(owner, {:upstream_websocket_frame, text}) end}

    task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :status, peer_pid},
                   @detection_timeout_ms

    :erlang.suspend_process(session)

    try do
      send(peer_pid, :release_raw_upstream_websocket_upgrade)

      assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :terminal_queued},
                     @detection_timeout_ms

      await_test_timer(120)
    after
      :erlang.resume_process(session)
    end

    assert {:ok, _result} = Task.await(task, @detection_timeout_ms)
    assert_receive {:upstream_websocket_frame, _frame}, @detection_timeout_ms
  end

  test "queued nonterminal upgrade data folds once and then respects the expired deadline" do
    peer = start_raw_websocket_peer(upgrade_mode: :split_nonterminal_headers)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 80, receive_timeout_ms: 1_000}
    }

    task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :status, peer_pid},
                   @detection_timeout_ms

    :erlang.suspend_process(session)

    try do
      send(peer_pid, :release_raw_upstream_websocket_upgrade)

      assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :nonterminal_queued},
                     @detection_timeout_ms

      await_test_timer(120)
    after
      :erlang.resume_process(session)
    end

    assert {:error, %{reason: :upstream_websocket_upgrade_timeout}} =
             Task.await(task, @detection_timeout_ms)

    refute_received {:raw_upstream_websocket_upgrade_payload, 1, _bytes}
  end

  test "nonterminal trickle fragments cannot extend the websocket upgrade deadline" do
    peer = start_raw_websocket_peer(upgrade_mode: :trickle_nonterminal)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 120, receive_timeout_ms: 1_000}
    }

    task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :trickle_status, peer_pid},
                   @detection_timeout_ms

    :erlang.suspend_process(session)

    try do
      release_raw_websocket_trickle(peer_pid, 10)
      await_test_timer(160)
    after
      :erlang.resume_process(session)
    end

    assert {:error, %{reason: :upstream_websocket_upgrade_timeout}} =
             Task.await(task, @detection_timeout_ms)

    refute_received {:raw_upstream_websocket_upgrade_payload, 1, _bytes}
  end

  test "does not advance generation when Mint rejects websocket creation after status 101" do
    peer = start_raw_websocket_peer(upgrade_mode: :invalid_accept)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: :invalid_nonce}} =
             UpstreamWebsocketSession.request(session, websocket_request(peer.url))

    assert_disconnected_lifecycle(session, initial_lifecycle)

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "failed reconnect preserves the last successful generation" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_before_failed_reconnect"),
           FakeUpstream.websocket_sse_then_close([]),
           FakeUpstream.websocket_upgrade_error(
             %{"error" => %{"code" => "reconnect_rejected"}},
             status: 503
           ),
           websocket_success("resp_ws_after_failed_reconnect")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    initial_lifecycle = lifecycle_state(session)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    established_lifecycle = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == established_lifecycle

    assert {:error, failed_reconnect} = UpstreamWebsocketSession.request(session, request)

    assert %{body: "", reason: {:websocket_upgrade_failed, 503, _headers}} = failed_reconnect
    assert_connection_metadata(failed_reconnect, established_lifecycle, true, false)

    assert_disconnected_lifecycle(session, established_lifecycle)
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [initial_request, interrupted_request] = FakeUpstream.requests(upstream)
    assert initial_request.websocket_connection_id == interrupted_request.websocket_connection_id

    assert {:ok, recovered_result} = UpstreamWebsocketSession.request(session, request)

    recovered_lifecycle = %{initial_lifecycle | generation: 2}
    assert lifecycle_state(session) == recovered_lifecycle
    assert_connection_metadata(recovered_result, recovered_lifecycle, false, false)
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "failure after a successful initial send carries only safe connection metadata" do
    upstream = start_upstream(FakeUpstream.websocket_sse_then_close([]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, failure} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert %{
             body: "",
             reason: :upstream_websocket_closed_before_terminal,
             websocket_frame_headers: %{}
           } = failure

    established_lifecycle = %{initial_lifecycle | generation: 1}
    assert_connection_metadata(failure, established_lifecycle, false, false)
    refute inspect(failure.upstream_websocket_connection) =~ "pid"
    refute inspect(failure.upstream_websocket_connection) =~ "node"
    refute inspect(failure.upstream_websocket_connection) =~ "socket"
  end

  test "peer close exposes only bounded diagnostics and discards the raw reason immediately" do
    raw_reason = "peer-close-private-sentinel-deadbeefcafefeed"

    upstream =
      start_upstream(FakeUpstream.websocket_sse_then_close([], code: 1000, reason: raw_reason))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    {result, captured_log} =
      with_log(fn ->
        UpstreamWebsocketSession.request(
          session,
          websocket_request(FakeUpstream.url(upstream))
        )
      end)

    assert {:error, failure} = result
    assert failure.reason == :upstream_websocket_closed_before_terminal

    assert Map.take(failure.transport_failure, [
             "peer_close_code",
             "peer_close_reason_present",
             "peer_close_reason_bytes"
           ]) == %{
             "peer_close_code" => 1000,
             "peer_close_reason_present" => true,
             "peer_close_reason_bytes" => byte_size(raw_reason)
           }

    session_state = :sys.get_state(session)
    exception_text = Exception.format(:error, RuntimeError.exception(inspect(failure)), [])

    for surface <- [failure, session_state, exception_text, captured_log] do
      refute inspect(surface) =~ raw_reason
    end

    assert Enum.sort(Map.keys(failure.upstream_websocket_connection)) ==
             [:generation, :lifecycle_id, :reconnected, :reused]
  end

  test "reused request returns unavailable error when session process is gone" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    :ok = UpstreamWebsocketSession.close(session)

    request = %Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }

    assert {:error, %{body: "", headers: [], reason: :upstream_websocket_session_unavailable}} =
             UpstreamWebsocketSession.request(session, request)
  end

  test "frame writer preserves websocket send failure reason and updated state" do
    ref = make_ref()
    updated_conn = {:updated_conn, make_ref()}

    state = %{
      conn: :original_conn,
      ref: ref,
      websocket: %Mint.WebSocket{},
      retained_field: :kept
    }

    stream_request_body = fn conn, request_ref, data ->
      assert conn == :original_conn
      assert request_ref == ref
      assert is_binary(data)

      {:error, updated_conn, :synthetic_write_failure}
    end

    assert {:error, :synthetic_write_failure, updated_state} =
             WebsocketFrameWriter.send_frame(
               state,
               {:pong, "codex-pooler"},
               stream_request_body
             )

    assert updated_state.conn == updated_conn
    assert %Mint.WebSocket{} = updated_state.websocket
    assert updated_state.retained_field == :kept
  end

  test "keeps queued GenServer calls while collecting upstream websocket frames" do
    parent = self()
    first_release_ref = make_ref()
    second_release_ref = make_ref()

    events = [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_ws_mailbox"}
      },
      %{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ws_mailbox"}
      }
    ]

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(events,
             notify: parent,
             release_ref: first_release_ref,
             barrier_after: 1
           ),
           FakeUpstream.barrier_sse_stream(events,
             notify: parent,
             release_ref: second_release_ref,
             barrier_after: 1
           )
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])

    request =
      %Request{
        url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
        headers: [{"authorization", "Bearer synthetic-upstream-token"}],
        payload:
          Jason.encode!(%{
            "model" => "upstream-test-model",
            "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
            "stream" => true
          }),
        timeouts: @timeouts,
        writer: fn text -> send(parent, {:upstream_websocket_frame, text}) end,
        message_mapper: nil
      }

    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:fake_upstream_chunk_sent, 1}, 1_000
    assert_receive {:fake_upstream_chunk_barrier, 1, barrier_pid, ^first_release_ref}, 1_000

    # The fake's barrier notification races the session's own send path: the
    # server can announce the barrier while the client is still streaming the
    # request body, so a single stack snapshot flakes under CI load. Poll until
    # the session parks in await_sent_request instead.
    assert_stack_eventually_in(session, UpstreamWebsocketSession, :await_sent_request, 2)

    send_task =
      Task.async(fn ->
        UpstreamWebsocketSession.send_request_frame(
          session,
          Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_ws_mailbox"})
        )
      end)

    send(barrier_pid, {:fake_upstream_release_chunk, first_release_ref})

    assert {:ok, %{terminal: "response.completed", status: 200}} = Task.await(request_task, 1_000)
    assert_receive {:fake_upstream_chunk_sent, 2}, 1_000
    assert_receive {:fake_upstream_chunk_sent, 3}, 1_000

    assert {:ok, :sent} = Task.await(send_task, 1_000)
    assert_receive {:fake_upstream_chunk_sent, 1}, 1_000
    assert_receive {:fake_upstream_chunk_barrier, 1, barrier_pid, ^second_release_ref}, 1_000

    send(barrier_pid, {:fake_upstream_release_chunk, second_release_ref})

    assert_receive {:fake_upstream_chunk_sent, 2}, 1_000
    assert_receive {:fake_upstream_chunk_sent, 3}, 1_000
  end

  test "opens a new upstream websocket connection when bearer changes between turns" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_ws_old_token", "object" => "response"}),
           FakeUpstream.json_response(%{"id" => "resp_ws_new_token", "object" => "response"})
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    parent = self()
    url = FakeUpstream.url(upstream) <> "/backend-api/codex/responses"
    initial_lifecycle = lifecycle_state(session)

    request = fn label, bearer, content ->
      %Request{
        url: url,
        headers: [{"authorization", "Bearer #{bearer}"}],
        payload:
          Jason.encode!(%{
            "model" => "upstream-test-model",
            "input" => [%{"type" => "message", "role" => "user", "content" => content}],
            "stream" => true
          }),
        timeouts: @timeouts,
        writer: fn text -> send(parent, {:upstream_websocket_frame, label, text}) end,
        message_mapper: nil
      }
    end

    assert {:ok, old_key_result} =
             UpstreamWebsocketSession.request(
               session,
               request.(:old_token_turn, "old-upstream-token", "first turn")
             )

    assert_receive {:upstream_websocket_frame, :old_token_turn, old_frame}, 1_000
    assert %{"id" => "resp_ws_old_token"} = Jason.decode!(old_frame)
    generation_one = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == generation_one
    assert_connection_metadata(old_key_result, generation_one, false, false)

    assert {:ok, new_key_result} =
             UpstreamWebsocketSession.request(
               session,
               request.(:new_token_turn, "new-upstream-token", "second turn")
             )

    assert_receive {:upstream_websocket_frame, :new_token_turn, new_frame}, 1_000
    assert %{"id" => "resp_ws_new_token"} = Jason.decode!(new_frame)
    generation_two = %{initial_lifecycle | generation: 2}
    assert lifecycle_state(session) == generation_two
    assert_connection_metadata(new_key_result, generation_two, false, false)

    assert [first_request, second_request] = FakeUpstream.requests(upstream)
    assert first_request.websocket_connection_id != second_request.websocket_connection_id
    assert Map.new(first_request.headers)["authorization"] == "Bearer old-upstream-token"
    assert Map.new(second_request.headers)["authorization"] == "Bearer new-upstream-token"
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "opens a new upstream websocket connection after missing keepalive pong deadline" do
    with_short_keepalive(keepalive_interval_ms: 80, keepalive_pong_timeout_ms: 35)

    peer = start_raw_websocket_peer()
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())
    initial_lifecycle = lifecycle_state(session)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    established_lifecycle = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == established_lifecycle
    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)
    assert_disconnected_lifecycle(session, established_lifecycle)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert lifecycle_state(session) == %{initial_lifecycle | generation: 2}
    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "does not close outstanding keepalive before a longer pong timeout expires" do
    with_short_keepalive(keepalive_interval_ms: 25, keepalive_pong_timeout_ms: 120)

    peer = start_raw_websocket_peer()
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    assert :timeout = wait_for_raw_websocket_connection_closed(1, 40)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert raw_websocket_peer_connection_count(peer) == 1
    assert :closed = wait_for_raw_websocket_connection_closed(1, 200)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "keeps upstream websocket connection reusable after exact keepalive pong" do
    with_short_keepalive()

    peer = start_raw_websocket_peer(pong_mode: :match_active_ping)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 2, _payload_bytes}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 3, _payload_bytes}, 1_000

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 1
  end

  @tag :upstream_websocket_pong_liveness
  test "opens a new upstream websocket connection after mismatched keepalive pong deadline" do
    with_short_keepalive(keepalive_interval_ms: 80, keepalive_pong_timeout_ms: 35)

    peer = start_raw_websocket_peer(pong_mode: :send_mismatched_pong)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000
    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "opens a new upstream websocket connection after stale old-payload keepalive pong deadline" do
    with_short_keepalive(keepalive_interval_ms: 80, keepalive_pong_timeout_ms: 35)

    peer = start_raw_websocket_peer(pong_mode: :match_active_ping)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    set_raw_websocket_peer_pong_mode(peer, :send_first_ping_payload)

    assert_receive {:raw_upstream_websocket_control, :ping, 1, 2, _payload_bytes}, 1_000
    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "active receive loop fails promptly when pong deadline fires during an in-flight request" do
    with_short_keepalive(keepalive_interval_ms: 25, keepalive_pong_timeout_ms: 150)

    peer = start_raw_websocket_peer()
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:upstream_websocket_frame, terminal_frame}, 1_000
    assert %{"id" => _id} = Jason.decode!(terminal_frame)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    set_raw_websocket_peer_response_mode(peer, :hold_after_created)
    started_at = System.monotonic_time(:millisecond)
    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:upstream_websocket_frame, created_frame}, 1_000
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)

    result =
      case Task.yield(request_task, 600) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(request_task, :brutal_kill)
          :request_still_waiting
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert {:error,
            %{
              body: body,
              reason: :upstream_websocket_pong_deadline,
              transport_failure: %{
                "termination_source" => "pooler_pong_deadline",
                "pre_visible_output" => false,
                "terminal_seen" => false,
                "text_frame_count" => 1
              }
            }} = result

    assert elapsed_ms < 600
    assert body =~ "response.created"
    assert Process.alive?(session)
    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)

    set_raw_websocket_peer_response_mode(peer, :terminal)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  test "request caller exit closes the active upstream websocket before the receive timeout" do
    peer = start_raw_websocket_peer(response_mode: :hold)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: 5_000}
    }

    initial_lifecycle = lifecycle_state(session)
    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_request, 1, 1}, 1_000

    assert Task.shutdown(request_task, :brutal_kill) == nil
    assert :closed = wait_for_raw_websocket_connection_closed(1, 200)
    assert lifecycle_state(session) == %{initial_lifecycle | generation: 1}

    set_raw_websocket_peer_response_mode(peer, :terminal)

    assert {:ok, result} = UpstreamWebsocketSession.request(session, request)
    assert_receive {:raw_upstream_websocket_connection, 2}, 1_000

    generation_two = %{initial_lifecycle | generation: 2}
    assert_connection_metadata(result, generation_two, false, true)
    assert raw_websocket_peer_connection_count(peer) == 2
  end

  test "request caller exit during websocket upgrade closes before payload send and reconnects" do
    peer = start_raw_websocket_peer(upgrade_mode: :hold)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: 5_000}
    }

    initial_lifecycle = lifecycle_state(session)
    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert Task.shutdown(request_task, :brutal_kill) == nil

    assert :closed = wait_for_raw_websocket_connection_closed(1, 200)
    refute_received {:raw_upstream_websocket_upgrade_payload, 1, _bytes}

    canceled_state = :sys.get_state(session)
    assert lifecycle_from_state(canceled_state) == initial_lifecycle
    refute Map.has_key?(canceled_state, :conn)
    assert canceled_state.reconnect_pending?

    set_raw_websocket_peer_upgrade_mode(peer, :valid)

    assert {:ok, result} = UpstreamWebsocketSession.request(session, request)
    assert_receive {:raw_upstream_websocket_connection, 2}, 1_000
    assert_receive {:upstream_websocket_frame, _frame}, 1_000

    generation_one = %{initial_lifecycle | generation: 1}
    assert_connection_metadata(result, generation_one, false, true)
    assert raw_websocket_peer_connection_count(peer) == 2

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "request caller exit during TLS connect closes before the connect timeout" do
    peer = start_raw_websocket_peer(connection_mode: :hold_tcp, scheme: "https")
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000}
    }

    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_tls_client_hello, 1, bytes} when bytes > 0, 1_000
    assert Task.shutdown(request_task, :brutal_kill) == nil

    assert :closed = wait_for_raw_websocket_connection_closed(1, 200)

    canceled_state = :sys.get_state(session)
    refute Map.has_key?(canceled_state, :conn)
    assert canceled_state.reconnect_pending?

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "receive timeout invalidates the websocket before the next request" do
    peer = start_raw_websocket_peer(response_mode: :hold)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = %{
      raw_websocket_request(peer.url, self())
      | timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: 100}
    }

    initial_lifecycle = lifecycle_state(session)

    assert {:error,
            %{
              reason: :upstream_websocket_receive_timeout,
              transport_failure: %{
                "termination_source" => "pooler_receive_timeout",
                "pre_visible_output" => true,
                "terminal_seen" => false
              }
            }} = UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_request, 1, 1}, 1_000
    assert :closed = wait_for_raw_websocket_connection_closed(1, 200)

    set_raw_websocket_peer_response_mode(peer, :terminal)

    assert {:ok, result} = UpstreamWebsocketSession.request(session, request)
    assert_receive {:raw_upstream_websocket_connection, 2}, 1_000

    generation_two = %{initial_lifecycle | generation: 2}
    assert_connection_metadata(result, generation_two, false, true)
    assert raw_websocket_peer_connection_count(peer) == 2
  end

  test "does not treat response.created as upstream websocket terminal success" do
    parent = self()

    upstream =
      start_upstream(
        FakeUpstream.delayed_sse_stream(
          [
            %{
              "type" => "response.created",
              "response" => %{"id" => "resp_ws_created_only"}
            },
            %{
              "type" => "response.completed",
              "response" => %{"id" => "resp_ws_created_only"}
            }
          ],
          done: false,
          interval_ms: 250
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload:
        Jason.encode!(%{
          "model" => "upstream-test-model",
          "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
          "stream" => true
        }),
      timeouts: @timeouts,
      writer: fn text -> send(parent, {:upstream_websocket_frame, text}) end,
      message_mapper: nil
    }

    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:upstream_websocket_frame, created_frame}, 1_000
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)
    refute Task.yield(request_task, 50)

    assert {:ok, %{terminal: "response.completed", status: 200}} = Task.await(request_task, 1_000)
    assert_receive {:upstream_websocket_frame, completed_frame}, 1_000
    assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)
  end

  test "returns only bounded retained body while writing every upstream websocket frame" do
    parent = self()

    events =
      [
        %{"type" => "response.created", "response" => %{"id" => "resp_ws_bounded_body"}},
        %{
          "type" => "item/started",
          "item" => %{
            "type" => "sleep",
            "id" => "item_sleep_fixture",
            "duration_ms" => 25
          }
        }
      ] ++
        for index <- 1..240 do
          %{
            "type" => "response.output_text.delta",
            "sequence_number" => index,
            "delta" => String.duplicate("bounded-websocket-retained-body-sentinel", 16)
          }
        end ++
        [
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_ws_bounded_body",
              "usage" => %{
                "input_tokens" => 1,
                "output_tokens" => 1,
                "total_tokens" => 2
              }
            }
          }
        ]

    upstream = start_upstream(FakeUpstream.sse_stream(events))
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload:
        Jason.encode!(%{
          "model" => "upstream-test-model",
          "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
          "stream" => true
        }),
      timeouts: @timeouts,
      writer: fn text -> send(parent, {:upstream_websocket_frame, text}) end,
      message_mapper: nil
    }

    assert {:ok, %{body: retained_body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    written_frames =
      1..length(events)
      |> Enum.map(fn _index ->
        assert_receive {:upstream_websocket_frame, frame}, 1_000
        frame
      end)

    assert Enum.map(written_frames, &Jason.decode!/1) == events

    full_body =
      written_frames
      |> Enum.map(&["data: ", &1, "\n\n"])
      |> IO.iodata_to_binary()

    assert byte_size(retained_body) <= 65_536
    assert byte_size(retained_body) < byte_size(full_body)
    assert String.ends_with?(full_body, retained_body)
  end

  test "retains an early response identity after a large body suffix evicts its frame" do
    response_id = "response-identity-early"

    frames = [
      Jason.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => response_id}
      }),
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => String.duplicate("x", 70_000)
      }),
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })
    ]

    assert {:ok, %{body: body, response_id: ^response_id}} = request_websocket_frames(frames)
    refute String.contains?(body, response_id)
  end

  test "captures nested identities from each allowlisted typed lifecycle or success frame" do
    Enum.each(
      [
        "response.created",
        "response.in_progress",
        "response.queued",
        "response.completed",
        "response.done"
      ],
      fn type ->
        response_id = "response-identity-#{type}"

        frames =
          [
            Jason.encode!(%{
              "type" => type,
              "response" => %{"id" => "  #{response_id}  ", "status" => "completed"}
            })
          ]
          |> maybe_append_terminal_frame(type)

        assert {:ok, %{response_id: ^response_id}} = request_websocket_frames(frames)
      end
    )
  end

  test "propagates a response.done identity in the successful structured result" do
    response_id = "response-identity-done"

    frame =
      Jason.encode!(%{
        "type" => "response.done",
        "response" => %{"id" => response_id, "status" => "completed"}
      })

    assert {:ok, %{response_id: ^response_id, terminal: "response.completed"}} =
             request_websocket_frames([frame])
  end

  test "ignores malformed, disallowed, repeated, and conflicting response identities" do
    first_response_id = "response-identity-first"

    frames = [
      ~s({"type":"response.created","id":"typed-top-level-id"}),
      ~s({"type":"response.metadata","response_id":"metadata-response-id"}),
      ~s({"response_id":"typeless-response-id"}),
      ~s({"type":"response.created","response":{"id":"   "}}),
      Jason.encode!(%{"type" => "response.created", "response" => %{"id" => 1}}),
      Jason.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => String.duplicate("x", 1_025)}
      }),
      ~s({"type":"response.created","response":{"id":"unterminated"),
      ~s(["not-an-object"]),
      Jason.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => first_response_id}
      }),
      Jason.encode!(%{
        "type" => "response.in_progress",
        "response" => %{"id" => first_response_id}
      }),
      Jason.encode!(%{
        "type" => "response.queued",
        "response" => %{"id" => "response-identity-conflict"}
      }),
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })
    ]

    assert {:ok, %{response_id: ^first_response_id}} = request_websocket_frames(frames)
  end

  test "captures a typeless whole-response id but omits identities from failures" do
    typeless_id = "response-identity-typeless"
    typeless_frame = Jason.encode!(%{"id" => "  #{typeless_id}  "})

    assert {:ok, %{response_id: ^typeless_id, terminal: "response.completed"}} =
             request_websocket_frames([typeless_frame])

    created =
      Jason.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => "response-identity-failure"}
      })

    upstream = start_upstream(FakeUpstream.websocket_sse_then_close([Jason.decode!(created)]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:error, failure} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    refute Map.has_key?(failure, :response_id)
  end

  test "omits a captured identity from failed and incomplete terminal results" do
    Enum.each(
      [
        {"response.failed", "failed"},
        {"response.incomplete", "incomplete"}
      ],
      fn {type, status} ->
        frames = [
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "response-identity-semantic-#{status}"}
          }),
          Jason.encode!(%{
            "type" => type,
            "response" => %{"status" => status}
          })
        ]

        assert {:ok, result} = request_websocket_frames(frames)
        assert result.terminal == type
        refute Map.has_key?(result, :response_id)
      end
    )
  end

  test "captures the raw lifecycle identity when the mapped frame strips its response object" do
    response_id = "response-identity-raw"

    mapper = fn text ->
      case Jason.decode!(text) do
        %{"type" => "response.created"} -> ~s({"type":"response.created"})
        _frame -> text
      end
    end

    frames = [
      Jason.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => response_id}
      }),
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })
    ]

    assert {:ok, %{body: body, response_id: ^response_id}} =
             request_websocket_frames(frames, message_mapper: mapper)

    refute String.contains?(body, response_id)
  end

  test "completes without a response identity when no valid identity was captured" do
    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })

    assert {:ok, %{terminal: "response.completed"} = result} = request_websocket_frames([frame])
    refute Map.has_key?(result, :response_id)
  end

  test "non-101 websocket upgrade failure preserves the leaf reason and drops the body" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{
            "error" => %{
              "code" => "upgrade_rejected",
              "message" => "upgrade body sentinel"
            }
          },
          status: 403,
          headers: [{"x-upstream-status", "upgrade-denied-sentinel"}]
        )
      )

    parent = self()

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn frame -> send(parent, {:failed_upgrade_frame, frame}) end,
      message_mapper: nil,
      native_codex_response_control: %TurnSnapshot{models_etag: "upgrade-etag"}
    }

    result = UpstreamWebsocketSession.request_once(request)

    assert {:error,
            %{
              body: "",
              headers: [],
              reason: {:websocket_upgrade_failed, 403, reason_headers},
              websocket_frame_headers: %{}
            }} = result

    assert [
             {"date", _},
             {"content-length", _},
             {"vary", _},
             {"cache-control", _},
             {"x-upstream-status", "upgrade-denied-sentinel"},
             {"content-type", _}
           ] = reason_headers

    refute inspect({reason_headers, result}) =~ "upgrade body sentinel"
    refute_received {:failed_upgrade_frame, _frame}
  end

  @tag :continuation_generation_boundary
  test "marked continuation forwards unchanged on a reused connection" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           websocket_success_without_id()
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    marked_request = %{request | connection_bound_continuation?: true}

    assert {:ok, _warmup} = UpstreamWebsocketSession.request(session, request)
    assert {:ok, result} = UpstreamWebsocketSession.request(session, marked_request)

    assert result.upstream_websocket_connection.reused
    refute result.upstream_websocket_connection.reconnected
    assert [warmup_request, continuation_request] = FakeUpstream.requests(upstream)
    assert continuation_request.body == marked_request.payload
    assert warmup_request.websocket_connection_id == continuation_request.websocket_connection_id
  end

  @tag :collect_compaction
  test "collect compaction retains frames without a writer on a reused matching-mode connection" do
    item =
      Jason.encode!(%{
        "type" => "response.output_item.done",
        "item" => %{"type" => "compaction", "encrypted_content" => "opaque-compact"}
      })

    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_collect_matching", "status" => "completed"}
      })

    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           FakeUpstream.websocket_text_frames([item, terminal])
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    warmup = struct(request, effective_serving_mode: "full")

    collect =
      struct(request,
        writer: nil,
        websocket_delivery_mode: :collect_compaction,
        effective_serving_mode: "full"
      )

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, warmup)

    assert {:ok, result} = UpstreamWebsocketSession.request(session, collect)
    assert result.upstream_websocket_connection.reused
    assert result.body == "data: #{item}\n\ndata: #{terminal}\n\n"

    assert [warmup_request, collect_request] = FakeUpstream.requests(upstream)
    assert warmup_request.websocket_connection_id == collect_request.websocket_connection_id
    assert collect_request.body == collect.payload
  end

  @tag :collect_compaction
  test "collect compaction rejects fresh mode-mismatched and invalidated connections without send or reconnect" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           websocket_success_without_id()
         ]}
      )

    request = websocket_request(FakeUpstream.url(upstream))

    {:ok, fresh_session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(fresh_session) end)
    fresh_lifecycle = lifecycle_state(fresh_session)

    fresh_collect =
      struct(request,
        writer: nil,
        websocket_delivery_mode: :collect_compaction,
        effective_serving_mode: "full"
      )

    assert_collect_guard_result(
      UpstreamWebsocketSession.request(fresh_session, fresh_collect),
      :fresh
    )

    assert FakeUpstream.requests(upstream) == []
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert_disconnected_lifecycle(fresh_session, fresh_lifecycle)

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, _warmup} =
             UpstreamWebsocketSession.request(
               session,
               struct(request, effective_serving_mode: "full")
             )

    lite_collect =
      struct(request,
        writer: nil,
        websocket_delivery_mode: :collect_compaction,
        effective_serving_mode: "lite"
      )

    assert_collect_guard_result(
      UpstreamWebsocketSession.request(session, lite_collect),
      :reused
    )

    assert [_warmup_request] = FakeUpstream.requests(upstream)
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert :ok = UpstreamWebsocketSession.invalidate_connection(session)

    assert_collect_guard_result(
      UpstreamWebsocketSession.request(session, fresh_collect),
      :reconnected
    )

    assert [_warmup_request] = FakeUpstream.requests(upstream)
    assert FakeUpstream.websocket_connection_count(upstream) == 1
  end

  @tag :collect_compaction
  test "collect compaction does not reconnect after a preterminal close" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success_without_id()
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))

    assert {:ok, _warmup} =
             UpstreamWebsocketSession.request(
               session,
               struct(request, effective_serving_mode: "full")
             )

    collect =
      struct(request,
        writer: nil,
        websocket_delivery_mode: :collect_compaction,
        effective_serving_mode: "full"
      )

    assert {:error, %{reason: :upstream_websocket_closed_before_terminal}} =
             UpstreamWebsocketSession.request(session, collect)

    assert [_warmup_request, collect_request] = FakeUpstream.requests(upstream)
    assert collect_request.body == collect.payload
    assert FakeUpstream.websocket_connection_count(upstream) == 1
  end

  @tag :continuation_generation_boundary
  test "marked continuation on a replacement connection writes one retry terminal and keeps it reusable" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           websocket_success_without_id()
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    warmup_request = websocket_request(FakeUpstream.url(upstream))
    replacement_request = %{warmup_request | url: warmup_request.url <> "?scope=replacement"}

    assert {:ok, _warmup} = UpstreamWebsocketSession.request(session, warmup_request)

    assert_guard_terminal(
      session,
      %{replacement_request | connection_bound_continuation?: true},
      :replacement_guard,
      :fresh
    )

    assert [_warmup] = FakeUpstream.requests(upstream)

    assert {:ok, later_result} =
             UpstreamWebsocketSession.request(session, replacement_request)

    assert later_result.upstream_websocket_connection.reused
    assert [warmup, later_full_request] = FakeUpstream.requests(upstream)
    assert warmup.websocket_connection_id != later_full_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  @tag :continuation_generation_boundary
  test "marked continuation after invalidation writes one retry terminal and keeps reconnect reusable" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           websocket_success_without_id()
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    assert {:ok, _warmup} = UpstreamWebsocketSession.request(session, request)
    assert :ok = UpstreamWebsocketSession.invalidate_connection(session)

    assert_guard_terminal(
      session,
      %{request | connection_bound_continuation?: true},
      :invalidation_guard,
      :reconnected
    )

    assert [_warmup] = FakeUpstream.requests(upstream)

    assert {:ok, later_result} = UpstreamWebsocketSession.request(session, request)
    assert later_result.upstream_websocket_connection.reused
    assert length(FakeUpstream.requests(upstream)) == 2
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  @tag :continuation_generation_boundary
  test "transparent reconnect never replays a marked continuation on the next generation" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success_without_id(),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success_without_id()
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    assert {:ok, _warmup} = UpstreamWebsocketSession.request(session, request)

    assert_guard_terminal(
      session,
      %{request | connection_bound_continuation?: true},
      :transparent_reconnect_guard,
      :reconnected
    )

    assert [warmup, continuation] = FakeUpstream.requests(upstream)
    assert warmup.websocket_connection_id == continuation.websocket_connection_id

    assert {:ok, later_result} = UpstreamWebsocketSession.request(session, request)
    assert later_result.upstream_websocket_connection.reused

    assert [_warmup, continuation, later_full_request] = FakeUpstream.requests(upstream)
    assert later_full_request.websocket_connection_id != continuation.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  @tag :continuation_generation_boundary
  test "request_once writes one retry terminal without sending marked continuation bytes" do
    upstream = start_upstream(websocket_success_without_id())
    parent = self()

    request =
      FakeUpstream.url(upstream)
      |> websocket_request()
      |> Map.put(:connection_bound_continuation?, true)
      |> Map.put(:writer, fn frame -> send(parent, {:guard_frame, :request_once_guard, frame}) end)

    assert_guard_result(
      UpstreamWebsocketSession.request_once(request),
      :request_once_guard,
      :fresh
    )

    # The guard aborts before any bytes are sent, so this is the one connection
    # assertion in this file with no recorded request to serve as its barrier —
    # every other one reads `requests/1` first, and a recorded request is proof
    # the handler's `init/1` has already run.
    assert FakeUpstream.requests(upstream) == []
    assert FakeUpstream.await_websocket_connection_count(upstream, 1) == 1
  end

  @tag :fake_upstream_lifecycle_regression
  test "owner shutdown keeps FakeUpstream state alive through websocket initialization" do
    parent = self()
    release_ref = make_ref()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, upstream} =
          FakeUpstream.start_link(
            FakeUpstream.websocket_init_barrier(websocket_success_without_id(),
              notify: parent,
              release_ref: release_ref
            )
          )

        send(parent, {:fake_upstream_started, self(), upstream})

        receive do
          :stop_fake_upstream_owner -> exit(:shutdown)
        end
      end)

    assert_receive {:fake_upstream_started, ^owner, upstream}, 1_000
    supervisor_monitor = Process.monitor(upstream.supervisor)

    request_task =
      Task.async(fn ->
        request = %{
          websocket_request(FakeUpstream.url(upstream))
          | connection_bound_continuation?: true
        }

        UpstreamWebsocketSession.request_once(request)
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_init, websocket_pid, ^release_ref},
                   1_000

    send(owner, :stop_fake_upstream_owner)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}, 1_000
    assert Process.alive?(upstream.pid)
    send(websocket_pid, {:fake_upstream_release_websocket, release_ref})

    assert_receive {:fake_upstream_websocket_initialized, ^websocket_pid, ^release_ref}, 1_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, _, :shutdown}, 5_000

    terminal = native_retry_terminal()

    assert {:ok,
            %{
              body: "data: " <> ^terminal <> "\n\n",
              terminal: "error",
              status: 200,
              upstream_error_code: "previous_response_not_found",
              upstream_error_param: "previous_response_id"
            }} = Task.await(request_task, 1_000)
  end

  @tag :fake_upstream_lifecycle_regression
  test "top-level FakeUpstream server failure terminates its lifecycle without replacement" do
    parent = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, upstream} = FakeUpstream.start_link(websocket_success_without_id())
        send(parent, {:fake_upstream_started, self(), upstream})

        receive do
          :stop_fake_upstream_owner -> FakeUpstream.stop(upstream)
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: send(owner, :stop_fake_upstream_owner)
    end)

    assert_receive {:fake_upstream_started, ^owner, upstream}, 1_000
    server_monitor = Process.monitor(upstream.server)
    supervisor_monitor = Process.monitor(upstream.supervisor)
    state_monitor = Process.monitor(upstream.pid)

    capture_log(fn ->
      Supervisor.stop(upstream.server, :synthetic_failure)

      assert_receive {:DOWN, ^server_monitor, :process, _, :synthetic_failure}, 1_000
      assert_receive {:DOWN, ^supervisor_monitor, :process, _, :shutdown}, 1_000
      assert_receive {:DOWN, ^state_monitor, :process, _, :shutdown}, 1_000
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}, 1_000
    end)

    assert {:error, %{body: "", reason: %Mint.TransportError{reason: :econnrefused}}} =
             UpstreamWebsocketSession.request_once(websocket_request(FakeUpstream.url(upstream)))
  end

  defp assert_guard_terminal(session, request, label, connection_use) do
    parent = self()
    request = %{request | writer: fn frame -> send(parent, {:guard_frame, label, frame}) end}

    assert_guard_result(UpstreamWebsocketSession.request(session, request), label, connection_use)
  end

  defp assert_guard_result(result, label, connection_use) do
    terminal = native_retry_terminal()

    assert {:ok,
            %{
              body: "data: " <> ^terminal <> "\n\n",
              terminal: "error",
              status: 200,
              headers: headers,
              upstream_error_code: "previous_response_not_found",
              upstream_error_param: "previous_response_id",
              websocket_frame_headers: %{},
              transport_failure: transport_failure,
              upstream_websocket_connection: connection
            }} = result

    assert transport_failure ==
             TransportFailureReason.continuation_generation_guard_metadata(connection_use)

    assert connection.reused == false
    assert connection.reconnected == (connection_use == :reconnected)

    assert Enum.any?(headers, fn {name, value} ->
             name == "sec-websocket-accept" and byte_size(value) > 0
           end)

    assert_receive {:guard_frame, ^label, ^terminal}, 1_000
    refute_received {:guard_frame, ^label, _extra_terminal}
  end

  defp native_retry_terminal do
    Jason.encode!(%{
      "type" => "error",
      "status" => 400,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "message" => "Previous response was not found. Retrying the full request."
      }
    })
  end

  defp assert_collect_guard_result(result, connection_use) do
    terminal = native_retry_terminal()

    assert {:ok,
            %{
              body: "data: " <> ^terminal <> "\n\n",
              terminal: "error",
              status: 200,
              upstream_error_code: "previous_response_not_found",
              upstream_error_param: "previous_response_id",
              transport_failure: transport_failure,
              upstream_websocket_connection: connection
            }} = result

    assert transport_failure ==
             TransportFailureReason.continuation_generation_guard_metadata(connection_use)

    assert connection.reused == (connection_use == :reused)
    assert connection.reconnected == (connection_use == :reconnected)
  end

  defp websocket_success_without_id do
    FakeUpstream.websocket_text_frames([
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed"}
      })
    ])
  end

  defp websocket_success(response_id) do
    FakeUpstream.json_response(%{"id" => response_id, "object" => "response"})
  end

  defp request_websocket_frames(frames, request_opts \\ []) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames(frames))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request =
      request_opts
      |> Enum.into(%{})
      |> then(&struct(websocket_request(FakeUpstream.url(upstream)), &1))

    UpstreamWebsocketSession.request(session, request)
  end

  defp maybe_append_terminal_frame(frames, type)
       when type in ["response.completed", "response.done"],
       do: frames

  defp maybe_append_terminal_frame(frames, _type) do
    frames ++
      [
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed"}
        })
      ]
  end

  defp websocket_request(base_url) do
    url =
      if String.ends_with?(base_url, "/backend-api/codex/responses") do
        base_url
      else
        base_url <> "/backend-api/codex/responses"
      end

    %Request{
      url: url,
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }
  end

  defp metadata_event(frame) do
    assert %{"type" => "codex.response.metadata", "headers" => headers} = Jason.decode!(frame)
    headers
  end

  defp lifecycle_state(session) do
    session
    |> :sys.get_state()
    |> lifecycle_from_state()
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

  defp forwarded_handoff_probe(lifecycle, mode, observer) do
    child_spec = %{
      id: {ForwardedHandoffProbe, make_ref()},
      start: {ForwardedHandoffProbe, :start_link, [{lifecycle, mode, observer}]},
      restart: :temporary
    }

    owner = start_supervised!(child_spec)

    witness = %CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1{
      version: 1,
      phase: :compact,
      binding: direct_admission_binding(lifecycle),
      control_ref: make_ref(),
      capability_digest: <<0::256>>,
      correlation_digest: <<1::256>>,
      downstream_epoch: 1,
      expires_at_ms: System.system_time(:millisecond) + 30_000,
      nonce: <<2::256>>,
      signature: <<3::256>>
    }

    ForwardedOwnerRequestHandoff.new(owner, witness)
  end

  defp status_state(
         {:status, _pid, {:module, :gen_server}, [_pdict, _running, _parent, _debug, status]}
       ) do
    status
    |> Keyword.get_values(:data)
    |> Enum.flat_map(& &1)
    |> Enum.find_value(fn
      {~c"State", state} -> state
      _entry -> nil
    end)
  end

  defp status_logged_events(
         {:status, _pid, {:module, :gen_server}, [_pdict, _running, _parent, _debug, status]}
       ) do
    status
    |> Keyword.get_values(:data)
    |> Enum.flat_map(& &1)
    |> Enum.find_value(fn
      {~c"Logged events", events} -> events
      _entry -> nil
    end)
  end

  defp private_marker(label) do
    "private-#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp lifecycle_from_state(state) do
    lifecycle = Map.take(state, [:lifecycle_id, :generation])

    assert %{lifecycle_id: lifecycle_id, generation: generation} = lifecycle
    assert is_integer(generation) and generation >= 0
    assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)
    refute Map.has_key?(state, :pid)
    refute Map.has_key?(state, :node)
    refute Map.has_key?(state, :socket)

    lifecycle
  end

  defp assert_disconnected_lifecycle(session, expected_lifecycle) do
    state = :sys.get_state(session)

    assert lifecycle_from_state(state) == expected_lifecycle
    assert Enum.sort(Map.keys(state)) == [:generation, :lifecycle_id]
  end

  defp assert_connection_metadata(result, lifecycle, reused, reconnected) do
    assert Map.fetch!(result, :upstream_websocket_connection) == %{
             lifecycle_id: lifecycle.lifecycle_id,
             generation: lifecycle.generation,
             reused: reused,
             reconnected: reconnected
           }
  end

  defp closed_tcp_url do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    "http://127.0.0.1:#{port}"
  end

  defp session_socket(session) do
    Enum.find(Port.list(), fn port ->
      :erlang.port_info(port, :connected) == {:connected, session}
    end) || flunk("no socket port owned by the websocket session")
  end

  defp server_text_frame(payload) when is_binary(payload) and byte_size(payload) < 126 do
    <<0x81, byte_size(payload), payload::binary>>
  end

  defp request_once_lifecycle_trace(request) do
    parent = self()
    start_ref = make_ref()
    release_ref = make_ref()
    traced_mfa = {ConnectionUpgrade, :connect_state, 6}
    match_spec = [{:_, [], [{:return_trace}]}]

    {:module, ConnectionUpgrade} = Code.ensure_loaded(ConnectionUpgrade)
    :erlang.trace_pattern(traced_mfa, match_spec, [])

    task =
      Task.async(fn ->
        receive do
          {:start_request_once, ^start_ref} -> :ok
        end

        result = UpstreamWebsocketSession.request_once(request)
        send(parent, {:request_once_complete, self(), result})

        receive do
          {:release_request_once, ^release_ref} -> result
        end
      end)

    try do
      :erlang.trace(task.pid, true, [:call, {:tracer, parent}])
      send(task.pid, {:start_request_once, start_ref})

      result =
        receive do
          {:request_once_complete, pid, result} when pid == task.pid -> result
        after
          @detection_timeout_ms -> flunk("request_once did not complete")
        end

      delivered_ref = :erlang.trace_delivered(task.pid)

      assert_receive {:trace_delivered, pid, ^delivered_ref} when pid == task.pid,
                     @detection_timeout_ms

      trace = collect_lifecycle_trace(task.pid, [])
      send(task.pid, {:release_request_once, release_ref})
      assert Task.await(task, @detection_timeout_ms) == result

      {result, trace}
    after
      :erlang.trace_pattern(traced_mfa, false, [])

      if Process.alive?(task.pid) do
        :erlang.trace(task.pid, false, [:call])
        send(task.pid, {:release_request_once, release_ref})
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp collect_lifecycle_trace(pid, acc) do
    receive do
      {:trace, ^pid, :call, {ConnectionUpgrade, :connect_state, [state | _arguments]}} ->
        collect_lifecycle_trace(pid, [lifecycle_from_state(state) | acc])

      {:trace, ^pid, :return_from, {ConnectionUpgrade, :connect_state, 6}, {:ok, state}} ->
        collect_lifecycle_trace(pid, [lifecycle_from_state(state) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp with_short_keepalive(opts \\ []) do
    original_env = Application.get_env(:codex_pooler, UpstreamWebsocketSession, [])

    settings =
      Keyword.merge(
        [
          keepalive_interval_ms: Keyword.get(opts, :keepalive_interval_ms, 25),
          keepalive_pong_timeout_ms: Keyword.get(opts, :keepalive_pong_timeout_ms, 50)
        ],
        opts
      )

    Application.put_env(
      :codex_pooler,
      UpstreamWebsocketSession,
      Keyword.merge(original_env, settings)
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, UpstreamWebsocketSession, original_env)
    end)
  end

  defp start_raw_websocket_peer(opts \\ []) do
    owner = self()
    supervisor = raw_websocket_peer_supervisor()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             listen_socket: listen_socket,
             accept_pid: nil,
             client_sockets: MapSet.new(),
             connection_count: 0,
             connection_pids: MapSet.new(),
             upgrade_mode: Keyword.get(opts, :upgrade_mode, :valid),
             connection_mode: Keyword.get(opts, :connection_mode, :websocket),
             pong_mode: Keyword.get(opts, :pong_mode, :ignore_ping),
             response_mode: Keyword.get(opts, :response_mode, :terminal),
             upgrade_headers: Keyword.get(opts, :upgrade_headers, []),
             stopped?: false
           }
         end}
      )

    peer = %{
      url:
        "#{Keyword.get(opts, :scheme, "http")}://127.0.0.1:#{port}/backend-api/codex/responses",
      state: state,
      supervisor: supervisor
    }

    {:ok, accept_pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        raw_websocket_peer_accept_loop(peer, listen_socket, owner)
      end)

    Agent.update(state, &%{&1 | accept_pid: accept_pid})
    on_exit(fn -> stop_raw_websocket_peer(peer) end)

    peer
  end

  defp raw_websocket_peer_supervisor do
    name = :"raw_websocket_peer_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: name})
    name
  end

  defp raw_websocket_request(url, owner) do
    %Request{
      url: url,
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload:
        Jason.encode!(%{
          "model" => "upstream-test-model",
          "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
          "stream" => true
        }),
      timeouts: @timeouts,
      writer: fn text -> send(owner, {:upstream_websocket_frame, text}) end,
      message_mapper: nil
    }
  end

  defp raw_websocket_peer_accept_loop(
         %{state: state, supervisor: supervisor} = peer,
         socket,
         owner
       ) do
    case :gen_tcp.accept(socket, 100) do
      {:ok, client_socket} ->
        connection_id = raw_websocket_peer_track_connection(state, client_socket)
        send(owner, {:raw_upstream_websocket_connection, connection_id})

        {:ok, pid} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              {:raw_websocket_peer_socket_ready, ^client_socket} ->
                raw_websocket_peer_connection_loop(state, client_socket, connection_id, owner)
            end
          end)

        :ok = :gen_tcp.controlling_process(client_socket, pid)
        send(pid, {:raw_websocket_peer_socket_ready, client_socket})

        Agent.update(state, fn current ->
          %{current | connection_pids: MapSet.put(current.connection_pids, pid)}
        end)

        raw_websocket_peer_accept_loop(peer, socket, owner)

      {:error, :timeout} ->
        unless Agent.get(state, & &1.stopped?) do
          raw_websocket_peer_accept_loop(peer, socket, owner)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp raw_websocket_peer_track_connection(state, socket) do
    Agent.get_and_update(state, fn current ->
      connection_id = current.connection_count + 1

      updated = %{
        current
        | client_sockets: MapSet.put(current.client_sockets, socket),
          connection_count: connection_id
      }

      {connection_id, updated}
    end)
  end

  defp raw_websocket_peer_connection_loop(state, socket, connection_id, owner) do
    case Agent.get(state, & &1.connection_mode) do
      :hold_tcp ->
        case raw_tcp_peer_hold_connection(socket, connection_id, owner, false) do
          {:error, reason} -> send(owner, {:raw_upstream_websocket_error, connection_id, reason})
        end

      :websocket ->
        upgrade_mode = Agent.get(state, & &1.upgrade_mode)

        case raw_websocket_peer_upgrade(state, socket, upgrade_mode, connection_id, owner) do
          :ok -> raw_websocket_peer_frame_loop(state, socket, connection_id, owner, 0, nil, 0)
          {:error, reason} -> send(owner, {:raw_upstream_websocket_error, connection_id, reason})
        end
    end
  after
    safe_tcp_close(socket)

    if Process.alive?(state) do
      Agent.update(state, fn current ->
        %{
          current
          | client_sockets: MapSet.delete(current.client_sockets, socket),
            connection_pids: MapSet.delete(current.connection_pids, self())
        }
      end)
    end

    send(owner, {:raw_upstream_websocket_connection_closed, connection_id})
  end

  defp raw_websocket_peer_upgrade(state, socket, mode, connection_id, owner) do
    with {:ok, headers} <- raw_websocket_peer_read_headers(socket),
         {:ok, key} <- raw_websocket_peer_header(headers, "sec-websocket-key") do
      send_raw_websocket_upgrade(state, socket, key, mode, connection_id, owner)
    end
  end

  defp raw_tcp_peer_hold_connection(socket, connection_id, owner, client_hello_seen?) do
    :ok = :inet.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        unless client_hello_seen? do
          send(owner, {:raw_upstream_tls_client_hello, connection_id, byte_size(data)})
        end

        raw_tcp_peer_hold_connection(socket, connection_id, owner, true)

      {:tcp_closed, ^socket} ->
        {:error, :closed}

      {:tcp_error, ^socket, reason} ->
        {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp send_raw_websocket_upgrade(
         _state,
         socket,
         _key,
         :malformed_response,
         _connection_id,
         _owner
       ) do
    :gen_tcp.send(socket, "not-an-http-upgrade\r\n\r\n")
  end

  defp send_raw_websocket_upgrade(_state, socket, _key, :hold, connection_id, owner) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:error, :closed} ->
        {:error, :closed}

      {:error, reason} ->
        {:error, reason}

      {:ok, data} ->
        send(owner, {:raw_upstream_websocket_upgrade_payload, connection_id, byte_size(data)})
        {:error, :unexpected_upgrade_payload}
    end
  end

  defp send_raw_websocket_upgrade(state, socket, key, :missing_status, _connection_id, _owner) do
    send_raw_websocket_upgrade_headers(state, socket, key)
  end

  defp send_raw_websocket_upgrade(state, socket, key, :split_status, connection_id, owner) do
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    send(owner, {:raw_upstream_websocket_upgrade_fragment, connection_id, :status, self()})

    receive do
      :release_raw_upstream_websocket_upgrade ->
        result = send_raw_websocket_upgrade_headers(state, socket, key)
        send(owner, {:raw_upstream_websocket_upgrade_fragment, connection_id, :terminal_queued})
        result
    after
      @detection_timeout_ms -> {:error, :upgrade_fragment_release_timeout}
    end
  end

  defp send_raw_websocket_upgrade(
         _state,
         socket,
         key,
         :split_partial_headers,
         connection_id,
         owner
       ) do
    :ok = :gen_tcp.send(socket, ["HTTP/1.1 101 Switching Protocols\r\n", "upgrade: web"])

    send(
      owner,
      {:raw_upstream_websocket_upgrade_fragment, connection_id, :partial_headers, self()}
    )

    receive do
      :release_raw_upstream_websocket_upgrade ->
        accept = websocket_accept(key)

        :gen_tcp.send(socket, [
          "socket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
          accept,
          "\r\n\r\n"
        ])
    after
      @detection_timeout_ms -> {:error, :upgrade_fragment_release_timeout}
    end
  end

  defp send_raw_websocket_upgrade(
         state,
         socket,
         key,
         :informational_then_valid,
         _connection_id,
         _owner
       ) do
    final_headers = raw_websocket_upgrade_headers(state, key, websocket_accept(key))

    :gen_tcp.send(socket, [
      "HTTP/1.1 103 Early Hints\r\nx-informational-sentinel: excluded\r\n\r\n",
      "HTTP/1.1 101 Switching Protocols\r\n",
      final_headers
    ])
  end

  defp send_raw_websocket_upgrade(_state, socket, _key, :split_forbidden, connection_id, owner) do
    :ok = :gen_tcp.send(socket, "HTTP/1.1 403 Forbidden\r\n")

    send(
      owner,
      {:raw_upstream_websocket_upgrade_fragment, connection_id, :forbidden_status, self()}
    )

    receive do
      :release_raw_upstream_websocket_upgrade ->
        :gen_tcp.send(socket, "content-length: 0\r\n\r\n")
    after
      @detection_timeout_ms -> {:error, :upgrade_fragment_release_timeout}
    end
  end

  defp send_raw_websocket_upgrade(
         _state,
         socket,
         _key,
         :split_nonterminal_headers,
         connection_id,
         owner
       ) do
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    send(owner, {:raw_upstream_websocket_upgrade_fragment, connection_id, :status, self()})

    receive do
      :release_raw_upstream_websocket_upgrade ->
        result = :gen_tcp.send(socket, "upgrade: web")

        send(
          owner,
          {:raw_upstream_websocket_upgrade_fragment, connection_id, :nonterminal_queued}
        )

        result
    after
      @detection_timeout_ms -> {:error, :upgrade_fragment_release_timeout}
    end
  end

  defp send_raw_websocket_upgrade(
         _state,
         socket,
         _key,
         :trickle_nonterminal,
         connection_id,
         owner
       ) do
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")

    send(
      owner,
      {:raw_upstream_websocket_upgrade_fragment, connection_id, :trickle_status, self()}
    )

    send_raw_websocket_trickle(socket, owner, connection_id, [
      "x",
      "-",
      "t",
      "r",
      "i",
      "c",
      "k",
      "l",
      "e",
      ":"
    ])
  end

  defp send_raw_websocket_upgrade(state, socket, key, mode, _connection_id, _owner)
       when mode in [:valid, :invalid_accept] do
    accept = if mode == :valid, do: websocket_accept(key), else: "invalid-websocket-accept"

    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    send_raw_websocket_upgrade_headers(state, socket, key, accept)
  end

  defp send_raw_websocket_trickle(_socket, _owner, _connection_id, []), do: :ok

  defp send_raw_websocket_trickle(socket, owner, connection_id, [fragment | rest]) do
    receive do
      :release_raw_upstream_websocket_trickle -> :ok
    end

    case :gen_tcp.send(socket, fragment) do
      :ok ->
        send(owner, {:raw_upstream_websocket_upgrade_fragment, connection_id, :trickle, self()})
        send_raw_websocket_trickle(socket, owner, connection_id, rest)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_raw_websocket_upgrade_headers(state, socket, key) do
    send_raw_websocket_upgrade_headers(state, socket, key, websocket_accept(key))
  end

  defp websocket_accept(key) do
    :sha
    |> :crypto.hash(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    |> Base.encode64()
  end

  defp send_raw_websocket_upgrade_headers(state, socket, _key, accept) do
    :gen_tcp.send(socket, raw_websocket_upgrade_headers(state, nil, accept))
  end

  defp raw_websocket_upgrade_headers(state, _key, accept) do
    upgrade_headers =
      state
      |> Agent.get(& &1.upgrade_headers)
      |> Enum.map(fn {name, value} -> [name, ": ", value, "\r\n"] end)

    [
      "upgrade: websocket\r\n",
      "connection: Upgrade\r\n",
      "sec-websocket-accept: ",
      accept,
      "\r\n",
      upgrade_headers,
      "\r\n"
    ]
  end

  defp raw_websocket_peer_read_headers(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> raw_websocket_peer_read_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp raw_websocket_peer_header(headers, name) do
    name = String.downcase(name)

    headers
    |> String.split("\r\n")
    |> Enum.find_value(&raw_websocket_peer_matching_header(&1, name))
    |> case do
      {:ok, value} -> {:ok, value}
      nil -> {:error, :missing_websocket_key}
    end
  end

  defp raw_websocket_peer_matching_header(line, name) do
    case String.split(line, ":", parts: 2) do
      [header_name, value] when header_name != "" ->
        if String.downcase(header_name) == name, do: {:ok, String.trim(value)}

      _line ->
        nil
    end
  end

  defp raw_websocket_peer_frame_loop(
         state,
         socket,
         connection_id,
         owner,
         request_count,
         first_ping_payload,
         ping_count
       ) do
    case raw_websocket_peer_recv_frame(socket) do
      {:ok, :text, _payload} ->
        request_count = request_count + 1
        send_raw_websocket_peer_response(state, socket, connection_id, request_count, owner)

        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )

      {:ok, :ping, payload} ->
        ping_count = ping_count + 1
        first_ping_payload = first_ping_payload || payload
        maybe_send_raw_websocket_peer_pong(state, socket, payload, first_ping_payload)

        send(
          owner,
          {:raw_upstream_websocket_control, :ping, connection_id, ping_count, byte_size(payload)}
        )

        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )

      {:ok, :pong, payload} ->
        send(
          owner,
          {:raw_upstream_websocket_control, :pong, connection_id, ping_count, byte_size(payload)}
        )

        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )

      {:ok, :close, _payload} ->
        :ok

      {:error, reason} when reason in [:closed, :einval] ->
        :ok

      {:error, reason} ->
        send(owner, {:raw_upstream_websocket_error, connection_id, reason})

      _other ->
        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )
    end
  end

  defp send_raw_websocket_peer_response(state, socket, connection_id, request_count, owner) do
    case Agent.get(state, & &1.response_mode) do
      :hold ->
        send(owner, {:raw_upstream_websocket_request, connection_id, request_count})
        :ok

      :hold_after_created ->
        response = %{
          "type" => "response.created",
          "response" => %{"id" => "resp_raw_ws_#{connection_id}_#{request_count}"}
        }

        :gen_tcp.send(socket, raw_websocket_server_text_frame(Jason.encode!(response)))

      :terminal ->
        response = %{"id" => "resp_raw_ws_#{connection_id}_#{request_count}"}
        :gen_tcp.send(socket, raw_websocket_server_text_frame(Jason.encode!(response)))
    end
  end

  defp maybe_send_raw_websocket_peer_pong(state, socket, payload, first_ping_payload) do
    case Agent.get(state, & &1.pong_mode) do
      :match_active_ping ->
        :ok = :gen_tcp.send(socket, raw_websocket_server_pong_frame(payload))

      :send_mismatched_pong ->
        :ok = :gen_tcp.send(socket, raw_websocket_server_pong_frame("mismatched-pong"))

      :send_first_ping_payload ->
        :ok = :gen_tcp.send(socket, raw_websocket_server_pong_frame(first_ping_payload))

      :ignore_ping ->
        :ok
    end
  end

  defp raw_websocket_peer_recv_frame(socket) do
    with {:ok, <<first, second>>} <- :gen_tcp.recv(socket, 2, 1_000),
         opcode <- Bitwise.band(first, 0x0F),
         masked? <- Bitwise.band(second, 0x80) == 0x80,
         {:ok, payload_length} <-
           raw_websocket_peer_payload_length(socket, Bitwise.band(second, 0x7F)),
         {:ok, mask} <- raw_websocket_peer_mask(socket, masked?),
         {:ok, payload} <- raw_websocket_peer_payload(socket, payload_length) do
      {:ok, raw_websocket_peer_opcode(opcode), raw_websocket_peer_unmask(payload, mask)}
    end
  end

  defp raw_websocket_peer_payload_length(_socket, length) when length < 126, do: {:ok, length}

  defp raw_websocket_peer_payload_length(socket, 126) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 1_000), do: {:ok, length}
  end

  defp raw_websocket_peer_payload_length(socket, 127) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, 1_000), do: {:ok, length}
  end

  defp raw_websocket_peer_mask(socket, true), do: :gen_tcp.recv(socket, 4, 1_000)
  defp raw_websocket_peer_mask(_socket, false), do: {:ok, nil}

  defp raw_websocket_peer_payload(_socket, 0), do: {:ok, ""}
  defp raw_websocket_peer_payload(socket, length), do: :gen_tcp.recv(socket, length, 1_000)

  defp raw_websocket_peer_unmask(payload, nil), do: payload

  defp raw_websocket_peer_unmask(payload, mask) do
    mask
    |> :binary.copy(div(byte_size(payload) + 3, 4))
    |> binary_part(0, byte_size(payload))
    |> :crypto.exor(payload)
  end

  defp raw_websocket_peer_opcode(0x1), do: :text
  defp raw_websocket_peer_opcode(0x8), do: :close
  defp raw_websocket_peer_opcode(0x9), do: :ping
  defp raw_websocket_peer_opcode(0xA), do: :pong
  defp raw_websocket_peer_opcode(_opcode), do: :unknown

  defp raw_websocket_server_text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload), payload::binary>>
  end

  defp raw_websocket_server_text_frame(payload) when byte_size(payload) <= 65_535 do
    <<0x81, 126, byte_size(payload)::16, payload::binary>>
  end

  defp raw_websocket_server_text_frame(payload) do
    <<0x81, 127, byte_size(payload)::64, payload::binary>>
  end

  defp raw_websocket_server_pong_frame(payload) when byte_size(payload) < 126 do
    <<0x8A, byte_size(payload), payload::binary>>
  end

  defp set_raw_websocket_peer_pong_mode(%{state: state}, mode) do
    Agent.update(state, &%{&1 | pong_mode: mode})
  end

  defp set_raw_websocket_peer_response_mode(%{state: state}, mode) do
    Agent.update(state, &%{&1 | response_mode: mode})
  end

  defp set_raw_websocket_peer_upgrade_mode(%{state: state}, mode) do
    Agent.update(state, &%{&1 | upgrade_mode: mode})
  end

  defp raw_websocket_peer_connection_count(%{state: state}) do
    Agent.get(state, & &1.connection_count)
  end

  defp wait_for_raw_websocket_connection_closed(connection_id, timeout_ms) do
    receive do
      {:raw_upstream_websocket_connection_closed, ^connection_id} -> :closed
    after
      timeout_ms -> :timeout
    end
  end

  defp receive_mint_upgrade_until_done(conn, ref, deadline, accumulated) do
    timeout_ms = max(deadline - System.monotonic_time(:millisecond), 0)
    assert {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, timeout_ms)
    accumulated = accumulated ++ responses

    if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
      {conn, accumulated}
    else
      receive_mint_upgrade_until_done(conn, ref, deadline, accumulated)
    end
  end

  defp await_test_timer(timeout_ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {:test_timer_elapsed, timer_ref}, timeout_ms)

    receive do
      {:test_timer_elapsed, ^timer_ref} -> :ok
    end
  end

  defp release_raw_websocket_trickle(_peer_pid, 0), do: :ok

  defp release_raw_websocket_trickle(peer_pid, remaining) do
    send(peer_pid, :release_raw_upstream_websocket_trickle)

    assert_receive {:raw_upstream_websocket_upgrade_fragment, 1, :trickle, ^peer_pid},
                   @detection_timeout_ms

    release_raw_websocket_trickle(peer_pid, remaining - 1)
  end

  defp stop_raw_websocket_peer(%{state: state}) do
    if Process.alive?(state) do
      snapshot =
        Agent.get_and_update(state, fn current ->
          safe_tcp_close(current.listen_socket)
          Enum.each(current.client_sockets, &safe_tcp_close/1)

          {%{
             accept_pid: current.accept_pid,
             connection_pids: MapSet.to_list(current.connection_pids)
           }, %{current | stopped?: true}}
        end)

      pids = [snapshot.accept_pid | snapshot.connection_pids] |> Enum.filter(&is_pid/1)
      Enum.each(pids, &wait_for_process_stop/1)

      %{
        alive_tasks: Enum.filter(pids, &Process.alive?/1),
        client_socket_count: Agent.get(state, &MapSet.size(&1.client_sockets))
      }
    else
      %{alive_tasks: [], client_socket_count: 0}
    end
  end

  defp wait_for_process_stop(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> Process.demonitor(ref, [:flush])
      end
    end
  end

  defp safe_tcp_close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  defp safe_tcp_close(_socket), do: :ok

  defp attach_native_compaction_observer do
    handler_id = "direct-native-compaction-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :native_compaction, :authorization_transition],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:native_event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fn -> drain_native_compaction_events(%{}) end
  end

  defp drain_native_compaction_events(counts) do
    receive do
      {:native_event, %{transition: transition, topology: :direct}} ->
        drain_native_compaction_events(Map.update(counts, transition, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp expected_native_compaction_counts do
    NativeCompactionAuthorizationObservation.transitions()
    |> Map.new(&{&1, 1})
  end

  defp stack_has_mfa?(stacktrace, module, function, arity) do
    Enum.any?(stacktrace, fn
      {^module, ^function, ^arity, _location} -> true
      _frame -> false
    end)
  end

  defp assert_stack_eventually_in(pid, module, function, arity, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    unless poll_stack_until(pid, module, function, arity, deadline) do
      flunk("expected #{inspect(module)}.#{function}/#{arity} on the stack of #{inspect(pid)}")
    end
  end

  defp poll_stack_until(pid, module, function, arity, deadline) do
    parked? =
      case Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, stacktrace} -> stack_has_mfa?(stacktrace, module, function, arity)
        _dead -> false
      end

    cond do
      parked? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          10 -> :ok
        end

        poll_stack_until(pid, module, function, arity, deadline)
    end
  end
end
