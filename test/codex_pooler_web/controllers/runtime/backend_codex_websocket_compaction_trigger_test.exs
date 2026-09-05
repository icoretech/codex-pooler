defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Dev.NativeCompactionAuthorizationObserver
  alias CodexPooler.Dev.NativeCompactionTrace
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.NativeCompactionTraceTestExport
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPoolerWeb.CodexResponsesSocket

  @turn_state_param "client_metadata.x-codex-turn-state"
  @detection_timeout_ms 15_000
  @stale_native_content "stale-native-content-must-not-succeed"
  @remote_compaction_v2_fixture_path Path.expand(
                                       "../../../fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/remote_compaction_v2_request.json",
                                       __DIR__
                                     )
  @external_resource @remote_compaction_v2_fixture_path
  @incremental_compaction_fixture_path Path.expand(
                                         "../../../fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/remote_compaction_v2_incremental_request.json",
                                         __DIR__
                                       )
  @external_resource @incremental_compaction_fixture_path

  for topology <- [:direct, :forwarded], flip? <- [false, true] do
    @tag :queued_lite_compaction
    @tag capture_log: true
    test "#{topology} queued Lite compact #{if flip?, do: "rejects a current mode flip", else: "uses unresolved owner mode"}" do
      queued_lite_compaction_case(unquote(topology), unquote(flip?))
    end
  end

  defp queued_lite_compaction_case(topology, flip?) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(
      :codex_pooler,
      :websocket_owner_forwarding_enabled,
      topology == :forwarded
    )

    on_exit(fn ->
      case previous do
        :error ->
          Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)

        {:ok, value} ->
          Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    item = incremental_compaction_item("queued-lite")

    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_completed_response("resp_queued_lite_seed"),
           FakeUpstream.websocket_text_frames([
             Jason.encode!(%{"type" => "response.output_item.done", "item" => item}),
             Jason.encode!(%{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_queued_lite_compact",
                 "status" => "completed",
                 "output" => [item]
               }
             })
           ])
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)
    %{user: user} = CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    scope = Scope.for_user(user, ["instance_owner"])
    {:ok, snapshot} = CodexPooler.Pools.model_serving_modes_snapshot(scope, setup.pool)

    assert {:ok, changed} =
             CodexPooler.Pools.update_model_serving_modes(
               scope,
               setup.pool,
               [%{exposed_model_id: setup.model.exposed_model_id, mode: "lite"}],
               snapshot.revision
             )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = direct_socket(auth, "queued-lite-#{topology}-#{flip?}")
    Process.put(:queued_lite_socket_state, state)
    turn_id = "queued-lite-turn"
    context_id = "00000000-0000-4000-8000-000000000871"

    seed =
      ordinary_payload(setup, %{
        "client_metadata" => %{
          "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_id, :turn)
        }
      })

    try do
      assert {:ok, state} = CodexResponsesSocket.handle_in({seed, [opcode: :text]}, state)
      Process.put(:queued_lite_socket_state, state)
      assert {:push, {:text, _created}, state} = receive_queued_lite_message(state)
      assert {:push, {:text, terminal}, state} = receive_queued_lite_message(state)
      Process.put(:queued_lite_socket_state, state)
      assert %{"type" => "response.completed"} = Jason.decode!(terminal)
      assert MapSet.size(state.tasks) == 1

      assert is_nil(Adapter.response_options(state, true, nil).routing.model_serving_mode)

      before_requests = Repo.aggregate(Request, :count)
      before_attempts = Repo.aggregate(Attempt, :count)
      handler_id = "queued-lite-reserved-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :gateway, :native_compaction, :authorization_transition],
          fn _, _, metadata, _ ->
            if metadata.transition == :compact_reserved do
              if flip? do
                {:ok, _} =
                  CodexPooler.Pools.update_model_serving_modes(
                    scope,
                    setup.pool,
                    [%{exposed_model_id: setup.model.exposed_model_id, mode: "full"}],
                    changed.revision
                  )
              end

              send(parent, {:queued_lite_reserved, flip?})
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      compact =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_queued_lite_seed",
          "input" => [
            %{"type" => "function_call_output", "call_id" => "synthetic-call", "output" => "ok"},
            %{"type" => "compaction_trigger"}
          ],
          "stream" => true,
          "client_metadata" => %{
            "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_id, :compaction)
          }
        })

      assert {:ok, queued} = CodexResponsesSocket.handle_in({compact, [opcode: :text]}, state)
      Process.put(:queued_lite_socket_state, queued)
      assert :queue.len(queued.queued_response_payloads) == 1
      assert {:push, {:text, first}, next} = receive_queued_lite_message(queued)
      Process.put(:queued_lite_socket_state, next)
      assert Process.delete(:queued_lite_reserved) == flip?

      if flip? do
        assert %{"type" => "error"} = Jason.decode!(first)
        assert FakeUpstream.count(upstream) == 1
        assert Repo.aggregate(Request, :count) == before_requests
        assert Repo.aggregate(Attempt, :count) == before_attempts
      else
        assert %{"type" => "response.output_item.done", "item" => ^item} = Jason.decode!(first)
        assert {:push, {:text, done}, next} = receive_queued_lite_message(next)
        Process.put(:queued_lite_socket_state, next)
        assert %{"type" => "response.completed"} = Jason.decode!(done)
        assert FakeUpstream.count(upstream) == 2
        assert Repo.aggregate(Attempt, :count) == before_attempts + 1

        compact_row =
          Repo.one!(
            from r in Request, where: r.endpoint == "/backend-api/codex/responses/compact"
          )

        assert compact_row.request_metadata["routing"]["model_serving_mode"] == "lite"
      end

      assert {:ok, done_state} =
               complete_queued_lite_socket(Process.get(:queued_lite_socket_state))

      Process.put(:queued_lite_socket_state, done_state)
    after
      final_state = Process.delete(:queued_lite_socket_state)
      CodexResponsesSocket.terminate(:closed, final_state)
      if topology == :forwarded, do: cleanup_trace_owner_sessions()
    end
  end

  defp complete_queued_lite_socket(state) do
    if MapSet.size(state.tasks) == 0, do: {:ok, state}, else: receive_socket_completion(state)
  end

  defp receive_queued_lite_message(state) do
    receive do
      {:queued_lite_reserved, flipped?} ->
        Process.put(:queued_lite_reserved, flipped?)
        receive_queued_lite_message(state)

      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:push, {:text, frame}, next} = result ->
            if StreamProtocol.internal_control_event?(frame),
              do: receive_queued_lite_message(next),
              else: result

          {:ok, next} ->
            receive_queued_lite_message(next)
        end
    after
      @detection_timeout_ms -> flunk("expected queued compact result")
    end
  end

  test "forwarded final validates the submitted compaction item instead of the stored digest" do
    enable_owner_forwarding_for_trace!()
    turn = "final-digest-check"
    context = "00000000-0000-4000-8000-000000000991"
    item = incremental_compaction_item("final-digest-check")

    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_completed_response("resp_final_digest_anchor"),
           FakeUpstream.websocket_text_frames([
             Jason.encode!(%{"type" => "response.output_item.done", "item" => item}),
             Jason.encode!(%{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_final_digest_compact",
                 "status" => "completed",
                 "output" => [item]
               }
             })
           ]),
           websocket_completed_response("resp_forbidden_final")
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "final-digest-upgrade",
        "/backend-api/codex/responses"
      )

    try do
      seed =
        ordinary_payload(setup, %{
          "client_metadata" => %{
            "x-codex-turn-metadata" => native_turn_metadata(turn, context, :turn)
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, seed)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)

      compact =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_final_digest_anchor",
          "input" => [
            %{"type" => "function_call_output", "call_id" => "synthetic", "output" => "ok"},
            %{"type" => "compaction_trigger"}
          ],
          "stream" => true,
          "client_metadata" => %{
            "x-codex-turn-metadata" => native_turn_metadata(turn, context, :compaction)
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)

      metadata =
        native_turn_metadata(turn, "00000000-0000-4000-8000-000000000992", :turn)
        |> Jason.decode!()
        |> Map.merge(%{"window_id" => "final-window", "window_number" => 2})
        |> Jason.encode!()

      final =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{item | "encrypted_content" => "different-synthetic"}],
          "stream" => true,
          "client_metadata" => %{"x-codex-turn-metadata" => metadata}
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, final)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"type" => "error"} = Jason.decode!(frame)
      assert FakeUpstream.count(upstream) == 2
    after
      Mint.HTTP.close(conn)
    end
  end

  test "forwarded prewarm between compact and final preserves the owning final capability" do
    enable_owner_forwarding_for_trace!()
    turn = "final-digest-check"
    context = "00000000-0000-4000-8000-000000000991"
    item = incremental_compaction_item("final-digest-check")

    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_completed_response("resp_final_digest_anchor"),
           FakeUpstream.websocket_text_frames([
             Jason.encode!(%{"type" => "response.output_item.done", "item" => item}),
             Jason.encode!(%{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_final_digest_compact",
                 "status" => "completed",
                 "output" => [item]
               }
             })
           ]),
           websocket_completed_response("resp_forbidden_final")
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "final-digest-upgrade",
        "/backend-api/codex/responses"
      )

    try do
      seed =
        ordinary_payload(setup, %{
          "client_metadata" => %{
            "x-codex-turn-metadata" => native_turn_metadata(turn, context, :turn)
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, seed)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)

      compact =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_final_digest_anchor",
          "input" => [
            %{"type" => "function_call_output", "call_id" => "synthetic", "output" => "ok"},
            %{"type" => "compaction_trigger"}
          ],
          "stream" => true,
          "client_metadata" => %{
            "x-codex-turn-metadata" => native_turn_metadata(turn, context, :compaction)
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, _} = public_websocket_receive_text!(conn, websocket, ref)

      prewarm =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "generate" => false,
          "input" => [],
          "client_metadata" => %{
            "x-codex-turn-metadata" => Jason.encode!(%{"request_kind" => "prewarm"})
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, prewarm)
      {conn, websocket, _prewarm_created} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, prewarm_completed} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"type" => "response.completed"} = Jason.decode!(prewarm_completed)
      assert FakeUpstream.count(upstream) == 2

      metadata =
        native_turn_metadata(turn, "00000000-0000-4000-8000-000000000992", :turn)
        |> Jason.decode!()
        |> Map.merge(%{"window_id" => "final-window", "window_number" => 2})
        |> Jason.encode!()

      final =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{item | "encrypted_content" => "synthetic-incremental-final-digest-check"}],
          "stream" => true,
          "client_metadata" => %{"x-codex-turn-metadata" => metadata}
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, final)
      {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"type" => "response.created"} = Jason.decode!(frame)
      {_conn, _websocket, terminal} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"type" => "response.completed"} = Jason.decode!(terminal)
      assert FakeUpstream.count(upstream) == 3
    after
      Mint.HTTP.close(conn)
    end
  end

  test "full trace records a real socket owner compact lifecycle without injected events" do
    assert_real_trace_fixture_has_no_manual_emits!()
    enable_owner_forwarding_for_trace!()
    root = trace_root("real-socket-success")
    fixture = incremental_compaction_fixture!()
    turn_id = "trace-real-turn"
    context_window_id = "00000000-0000-4000-8000-000000000591"
    compact_item = incremental_compaction_item("trace-real-success")
    compact_release_ref = make_ref()
    response_id = fixture["provider_response_id"]

    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_completed_response(response_id),
           delayed_incremental_compaction_response(
             compact_item,
             "resp_trace_real_compact",
             self(),
             compact_release_ref
           )
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    assert {:ok, %{"path" => trace_path}} =
             NativeCompactionTrace.start_scope("real-socket-success",
               root: root,
               preset: :f3_happy
             )

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "trace-real-upgrade",
        "/backend-api/codex/responses"
      )

    source_frame =
      fixture
      |> get_in([
        "scenarios",
        "anchored_tool_output_and_trigger",
        "projection_relevant_frame_subset"
      ])
      |> put_in(["client_metadata"], %{
        "turn_id" => turn_id,
        "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_window_id, :compaction)
      })

    try do
      lineage_payload =
        ordinary_payload(setup, %{
          "client_metadata" => %{
            "turn_id" => turn_id,
            "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_window_id, :turn)
          }
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)
      {conn, websocket, _lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)

      {conn, websocket, lineage_terminal} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} =
               Jason.decode!(lineage_terminal)

      compact_payload =
        source_frame
        |> Map.put("previous_response_id", response_id)
        |> then(&incremental_compact_payload(setup, &1, "trace-real-compact"))

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)

      assert_receive {:fake_upstream_timeout_barrier, :before_terminal, compact_upstream_pid,
                      ^compact_release_ref},
                     @detection_timeout_ms

      send(compact_upstream_pid, {:fake_upstream_release_timeout, compact_release_ref})

      {conn, websocket, done_frame} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, _websocket, completed_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.output_item.done", "item" => ^compact_item} =
               Jason.decode!(done_frame)

      assert %{
               "type" => "response.completed",
               "response" => %{"status" => "completed", "output" => [^compact_item]}
             } = Jason.decode!(completed_frame)

      assert FakeUpstream.websocket_connection_count(upstream) == 1
      assert [ordinary_request, compact_request] = FakeUpstream.requests(upstream)
      assert ordinary_request.method == "WEBSOCKET"
      assert compact_request.method == "WEBSOCKET"

      assert ordinary_request.websocket_connection_id ==
               compact_request.websocket_connection_id

      {:ok, _conn} = Mint.HTTP.close(conn)
      await_trace_event!("cleanup_finished")
      cleanup_trace_owner_sessions()
      assert :ok = NativeCompactionTrace.flush()
      status = NativeCompactionTrace.status()
      assert status["preset"] == "f3_happy"
      assert status["maxEvents"] == 250_000
      assert status["maxBytes"] == 128 * 1024 * 1024
      refute status["truncated"]
      assert status["writtenEvents"] < status["maxEvents"]
      assert status["writtenBytes"] < status["maxBytes"]
      assert :ok = NativeCompactionTrace.stop_scope()

      trace = File.read!(trace_path)

      for role <- ~w(socket response_task owner_session upstream_session) do
        assert trace =~ "\"pid_role\":\"#{role}\""
      end

      for event <-
            ~w(downstream_websocket_frame_received downstream_websocket_frame_sent upstream_websocket_frame_sent upstream_websocket_frame_received response_task_started capability_reserve_started capability_reserve_finished capability_reserved accounting_started runtime_proof_redeemed capability_consumed capability_acknowledged owner_terminal finalization_finished delivery_finished cleanup_finished beam_call beam_return beam_receive beam_send beam_spawn) do
        assert trace =~ "\"event\":\"#{event}\""
      end

      assert trace =~ "CodexPoolerWeb.CodexResponsesSocket.handle_in/2"

      assert trace =~
               "CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.handle_call/3"

      assert trace =~
               "CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.handle_call/3"

      assert trace =~ "duration_us"
      assert trace =~ "systemTimeUs"
      assert trace =~ "monotonicTimeUs"
      assert trace =~ "forwarded_owner"
      _export = NativeCompactionTraceTestExport.maybe_export(trace_path, :success)
    after
      _result = Mint.HTTP.close(conn)
      _result = NativeCompactionTrace.stop_scope()
    end
  end

  test "full trace attributes a real rejected socket request without injected events" do
    assert_real_trace_fixture_has_no_manual_emits!()
    enable_owner_forwarding_for_trace!()
    root = trace_root("real-socket-failure")
    upstream = start_upstream(ordinary_response("resp_trace_failure_unused"))
    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    assert {:ok, %{"path" => trace_path}} =
             NativeCompactionTrace.start_scope("real-socket-failure",
               mode: :full,
               root: root
             )

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "trace-failure-upgrade",
        "/backend-api/codex/responses"
      )

    invalid_payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "client_metadata" => %{"x-codex-turn-metadata" => "not-json"}
      })

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, invalid_payload)
      {conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"status" => 400, "error" => %{"param" => param}} = Jason.decode!(error_frame)
      assert param =~ "x-codex-turn-metadata"
      assert FakeUpstream.count(upstream) == 0

      {:ok, _conn} = Mint.HTTP.close(conn)
      await_trace_event!("cleanup_finished")
      cleanup_trace_owner_sessions()
      assert :ok = NativeCompactionTrace.flush()
      assert :ok = NativeCompactionTrace.stop_scope()

      trace = File.read!(trace_path)
      assert trace =~ "\"event\":\"socket_request_rejected\""
      assert trace =~ "prepared_response_rejected"
      assert trace =~ "state_before"
      assert trace =~ "state_after"
      assert trace =~ "x-codex-turn-metadata"
      assert trace =~ "CodexPoolerWeb.CodexResponsesSocket.reject_prepared_response/2"
      assert trace =~ "\"event\":\"downstream_websocket_frame_received\""
      assert trace =~ "\"event\":\"downstream_websocket_frame_sent\""
      assert trace =~ "\"event\":\"cleanup_finished\""
      assert trace =~ "duration_us"
      assert trace =~ "\"pid_role\":\"socket\""
      _export = NativeCompactionTraceTestExport.maybe_export(trace_path, :failure)
    after
      _result = Mint.HTTP.close(conn)
      _result = NativeCompactionTrace.stop_scope()
    end
  end

  for {path, transport, optional_metadata} <- [
        {"/backend-api/codex/responses", :buffered, :valid},
        {"/backend-api/codex/v1/responses", :buffered, :malformed},
        {"/backend-api/codex/responses", :sse, :valid},
        {"/backend-api/codex/v1/responses", :sse, :malformed}
      ] do
    if transport == :sse do
      @tag :codex_remote_compaction_v2
    end

    test "#{path} completes #{transport} native compaction and reuses the downstream socket" do
      path = unquote(path)
      transport = unquote(transport)
      optional_metadata = unquote(optional_metadata)
      admission_events = attach_admission_telemetry()

      fixture = native_compaction_fixture(transport, optional_metadata)

      upstream =
        start_upstream(
          {:sequence,
           [
             fixture.upstream_mode,
             FakeUpstream.json_response(%{
               "id" => fixture.follow_up_response_id,
               "object" => "response",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
             })
           ]}
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()
      upgrade_turn_state = "upgrade-#{fixture.case_id}"
      frame_turn_state = "frame-#{fixture.case_id}"

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, upgrade_turn_state, path)

      try do
        payload = compact_payload(setup, frame_turn_state, transport)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, websocket, done_frame} = public_websocket_receive_text!(conn, websocket, ref)

        {conn, websocket, completed_frame} = public_websocket_receive_text!(conn, websocket, ref)

        item = fixture.expected_item

        assert Jason.decode!(done_frame) == %{
                 "type" => "response.output_item.done",
                 "item" => item
               }

        assert Jason.decode!(completed_frame) == %{
                 "type" => "response.completed",
                 "response" => %{
                   "id" => fixture.response_id,
                   "status" => "completed",
                   "output" => [item],
                   "usage" => %{
                     "input_tokens" => 6,
                     "output_tokens" => 2,
                     "total_tokens" => 8
                   }
                 }
               }

        refute done_frame =~ fixture.omitted_sentinel
        refute completed_frame =~ fixture.omitted_sentinel

        assert_admission_events(admission_events, ["proxy_websocket", "proxy_compact"])

        assert [compact_request] = FakeUpstream.requests(upstream)
        assert compact_request.method == compact_expected(transport, :method)

        assert FakeUpstream.http_request_count(upstream) ==
                 compact_expected(transport, :http_count)

        assert Map.has_key?(compact_request, :websocket_connection_id) ==
                 compact_expected(transport, :websocket?)

        assert compact_request.path == "/backend-api/codex/responses"
        assert compact_request.json["store"] == false
        assert compact_request.json["model"] == setup.model.upstream_model_id
        assert List.last(compact_request.json["input"]) == %{"type" => "compaction_trigger"}

        assert Enum.map(compact_request.json["input"], & &1["type"]) == [
                 "message",
                 "compaction_trigger"
               ]

        assert_compact_transport_payload(compact_request.json, transport)

        refute Map.has_key?(compact_request.json, "type")
        refute Map.has_key?(compact_request.json, "generate")
        refute Map.has_key?(compact_request.json, "client_metadata")

        assert_compact_turn_state_header(compact_request.headers, transport, frame_turn_state)

        assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
        assert request.endpoint == "/backend-api/codex/responses/compact"

        assert request.transport ==
                 compact_expected(transport, :transport)

        assert request.status == "succeeded"
        assert request.request_metadata["codex_session_id"]

        assert request.request_metadata["compaction_bridge"] == %{
                 "applied" => true,
                 "result_transport" => Atom.to_string(transport)
               }

        assert get_in(request.request_metadata, ["reservation_snapshot_inputs", "route_class"]) ==
                 "proxy_compact"

        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
        assert attempt.request_id == request.id

        assert attempt.transport == compact_expected(transport, :transport)

        assert attempt.status == "succeeded"
        assert attempt.pool_upstream_assignment_id == setup.assignment.id
        assert attempt.upstream_identity_id == setup.identity.id
        assert settlement_count(request.id) == 1

        assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
        assert turn.codex_session_id == request.request_metadata["codex_session_id"]
        assert turn.status == "succeeded"
        assert turn.transport_kind == compact_expected(transport, :turn_transport)
        assert turn.final_attempt_id == attempt.id
        assert turn.completed_at

        assert %CodexSession{id: session_id, status: "active"} =
                 Repo.get!(CodexSession, turn.codex_session_id)

        assert Repo.exists?(
                 from(alias_record in BridgeSessionAlias,
                   where:
                     alias_record.codex_session_id == ^session_id and
                       alias_record.alias_kind == "turn_state" and
                       alias_record.alias_hash == ^:crypto.hash(:sha256, frame_turn_state) and
                       alias_record.status == "active"
                 )
               )

        assert_no_raw_compaction_persistence(setup, [
          fixture.encrypted_content,
          fixture.response_id,
          fixture.item_id,
          fixture.turn_id,
          fixture.omitted_sentinel,
          frame_turn_state
        ])

        follow_up_payload = ordinary_payload(setup)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, follow_up_payload)

        {_conn, _websocket, follow_up_frame} =
          public_websocket_receive_text!(conn, websocket, ref)

        assert %{"id" => follow_up_response_id} = Jason.decode!(follow_up_frame)
        assert follow_up_response_id == fixture.follow_up_response_id

        assert [^compact_request, ordinary_request] = FakeUpstream.requests(upstream)
        assert ordinary_request.method == "WEBSOCKET"
        assert ordinary_request.path == "/backend-api/codex/responses"
        assert FakeUpstream.websocket_connection_count(upstream) == 1

        assert [compact_log, ordinary_log] =
                 Repo.all(
                   from(r in Request,
                     where: r.pool_id == ^setup.pool.id,
                     order_by: [asc: r.admitted_at, asc: r.id]
                   )
                 )

        assert compact_log.id == request.id
        assert ordinary_log.endpoint == "/backend-api/codex/responses"
        assert ordinary_log.transport == "websocket"
        assert ordinary_log.request_metadata["codex_session_id"] == session_id
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "source-derived incremental compaction stays on the response lineage assignment and reuses the socket" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    on_exit(fn -> NativeCompactionAuthorizationObserver.disarm() end)
    fixture = incremental_compaction_fixture!()

    anchored_tool_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_tool_output_and_trigger",
        "projection_relevant_frame_subset"
      ])

    scenarios =
      [
        {"anchored_tool_output_and_trigger", anchored_tool_frame, :incremental, 1},
        {"anchored_trigger_only",
         get_in(fixture, [
           "scenarios",
           "anchored_trigger_only",
           "projection_relevant_frame_subset"
         ]), :incremental, 2},
        {"anchored_custom_tool_output_and_future_suffix",
         anchored_tool_frame
         |> update_in(["input"], fn input ->
           [first, trigger] = input

           [
             Map.put(first, "type", "custom_tool_call_output"),
             %{
               "type" => "future_tool_output",
               "call_id" => "call_fixture_future",
               "output" => "synthetic future output"
             },
             trigger
           ]
         end), :incremental, 3}
      ]

    for {scenario_name, source_frame, input_mode, scenario_index} <- scenarios do
      turn_id = "incremental-shared-turn"
      context_window_id = "00000000-0000-4000-8000-000000000501"

      source_frame =
        put_in(source_frame, ["client_metadata"], %{
          "turn_id" => turn_id,
          "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_window_id, :compaction)
        })

      compact_item = incremental_compaction_item("success-#{scenario_name}")
      compact_release_ref = make_ref()

      assignment_a_upstream =
        start_upstream(
          {:sequence,
           [
             websocket_completed_response(fixture["provider_response_id"]),
             delayed_incremental_compaction_response(
               compact_item,
               "resp_compact_#{scenario_name}",
               self(),
               compact_release_ref
             ),
             ordinary_response("resp_follow_up_#{scenario_name}")
           ]}
        )

      assignment_b_upstream =
        start_upstream(ordinary_response("resp_assignment_b_should_not_run_#{scenario_name}"))

      setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)
      admission_events = attach_admission_telemetry()
      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(
          port,
          setup,
          "incremental-#{scenario_name}",
          "/backend-api/codex/responses"
        )

      try do
        lineage_payload =
          ordinary_payload(setup, %{
            "client_metadata" => %{
              "turn_id" => turn_id,
              "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_window_id, :turn)
            }
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)
        {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)

        {conn, websocket, lineage_terminal_frame} =
          public_websocket_receive_text!(conn, websocket, ref)

        assert %{"response" => %{"id" => response_id}} = Jason.decode!(lineage_frame)
        assert response_id == fixture["provider_response_id"]

        assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} =
                 Jason.decode!(lineage_terminal_frame)

        setup = activate_assignment_b(setup)

        source_frame = Map.put(source_frame, "previous_response_id", response_id)

        compact_payload =
          incremental_compact_payload(
            setup,
            source_frame,
            "compact-#{scenario_name}"
          )

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)

        assert_receive {:fake_upstream_timeout_barrier, :before_terminal, compact_upstream_pid,
                        ^compact_release_ref},
                       @detection_timeout_ms

        send(compact_upstream_pid, {:fake_upstream_release_timeout, compact_release_ref})

        {conn, websocket, done_frame} = public_websocket_receive_text!(conn, websocket, ref)
        {conn, websocket, completed_frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert Jason.decode!(done_frame) == %{
                 "type" => "response.output_item.done",
                 "item" => compact_item
               }

        assert %{
                 "type" => "response.completed",
                 "response" => %{"status" => "completed", "output" => [^compact_item]}
               } = Jason.decode!(completed_frame)

        authorization_counts = NativeCompactionAuthorizationObserver.captures()["counts"]

        for transition <- [
              "compact_owner_issued",
              "compact_reserved",
              "compact_accounting_started",
              "compact_runtime_proof_redeemed",
              "compact_consumed",
              "compact_acknowledged"
            ] do
          assert authorization_counts[transition] == scenario_index
        end

        for transition <- [
              "final_owner_issued",
              "final_reserved",
              "final_accounting_started",
              "final_runtime_proof_redeemed",
              "final_consumed",
              "final_acknowledged"
            ] do
          assert authorization_counts[transition] == 0
        end

        assert [lineage_request, compact_request] =
                 FakeUpstream.requests(assignment_a_upstream)

        assert lineage_request.method == "WEBSOCKET"

        expected_method = if input_mode == :incremental, do: "WEBSOCKET", else: "POST"
        assert compact_request.method == expected_method
        assert compact_request.path == "/backend-api/codex/responses"
        assert compact_request.json["input"] == source_frame["input"]

        if scenario_name == "anchored_tool_output_and_trigger" do
          assert compact_request.json["input"] |> List.first() |> Map.fetch!("output") == ""
        end

        assert compact_request.json["store"] == false
        assert compact_request.json["stream"] == true

        assert Map.get(compact_request.json, "previous_response_id") ==
                 Map.get(source_frame, "previous_response_id")

        assert %{
                 "request_kind" => "compaction",
                 "turn_id" => ^turn_id,
                 "compaction" => %{"implementation" => "responses_compaction_v2"}
               } =
                 source_frame
                 |> get_in(["client_metadata", "x-codex-turn-metadata"])
                 |> Jason.decode!()

        assert FakeUpstream.count(assignment_b_upstream) == 0

        assert_admission_events(admission_events, [
          "proxy_websocket",
          "proxy_websocket",
          "proxy_compact"
        ])

        compact_log =
          Repo.one!(
            from(request in Request,
              where:
                request.pool_id == ^setup.pool.id and
                  request.endpoint == "/backend-api/codex/responses/compact"
            )
          )

        expected_transport =
          if input_mode == :incremental, do: "websocket", else: "http_compact_json"

        assert compact_log.transport == expected_transport
        assert compact_log.status == "succeeded"
        assert compact_log.retry_count == 0

        assert compact_log.request_metadata["compaction_bridge"] == %{
                 "applied" => true,
                 "result_transport" => "sse"
               }

        assert [compact_attempt] =
                 Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

        assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id
        assert compact_attempt.upstream_identity_id == setup.identity.id
        assert compact_attempt.transport == expected_transport
        assert compact_attempt.status == "succeeded"
        refute compact_attempt.retryable
        assert compact_attempt.response_metadata["fallback_used"] in [nil, false]
        assert settlement_count(compact_log.id) == 1

        assert [compact_turn] =
                 Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

        assert compact_turn.status == "succeeded"
        assert compact_turn.final_attempt_id == compact_attempt.id

        if input_mode == :incremental do
          assert lineage_request.websocket_connection_id ==
                   compact_request.websocket_connection_id

          lineage_attempt =
            Repo.one!(
              from(attempt in Attempt,
                join: request in Request,
                on: request.id == attempt.request_id,
                where:
                  request.pool_id == ^setup.pool.id and
                    request.endpoint == "/backend-api/codex/responses"
              )
            )

          lineage_connection =
            lineage_attempt.response_metadata["upstream_websocket_connection"]

          compact_connection =
            compact_attempt.response_metadata["upstream_websocket_connection"]

          assert %{"lifecycle_id" => lifecycle_id, "generation" => generation} =
                   lineage_connection

          assert compact_connection == %{
                   "lifecycle_id" => lifecycle_id,
                   "generation" => generation,
                   "reused" => true,
                   "reconnected" => false
                 }

          assert is_integer(generation)
        end

        follow_up_payload =
          ordinary_payload(setup, %{
            "request_id" => "full-follow-up-#{scenario_name}",
            "input" => [
              %{
                "type" => "message",
                "role" => "user",
                "content" => "full follow-up after #{scenario_name}"
              }
            ]
          })

        {conn, websocket} =
          public_websocket_send_text!(conn, websocket, ref, follow_up_payload)

        {_conn, _websocket, follow_up_frame} =
          public_websocket_receive_text!(conn, websocket, ref)

        assert %{"id" => "resp_follow_up_" <> ^scenario_name} = Jason.decode!(follow_up_frame)

        assert [^lineage_request, ^compact_request, follow_up_request] =
                 FakeUpstream.requests(assignment_a_upstream)

        assert follow_up_request.method == "WEBSOCKET"

        assert follow_up_request.websocket_connection_id ==
                 compact_request.websocket_connection_id

        refute Map.has_key?(follow_up_request.json, "previous_response_id")
        assert FakeUpstream.websocket_connection_count(assignment_a_upstream) == 1
        assert FakeUpstream.count(assignment_b_upstream) == 0
      after
        receive do
          {:fake_upstream_timeout_barrier, :before_terminal, compact_upstream_pid,
           ^compact_release_ref} ->
            send(compact_upstream_pid, {:fake_upstream_release_timeout, compact_release_ref})
        after
          0 -> :ok
        end

        Mint.HTTP.close(conn)
      end
    end
  end

  @tag :replay_race
  test "provider terminal rejection on pinned incremental compaction is safe and leaves the socket reusable" do
    fixture = incremental_compaction_fixture!()

    source_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_tool_output_and_trigger",
        "projection_relevant_frame_subset"
      ])

    provider_message = "synthetic private provider rejection"

    provider_error = %{
      "code" => "invalid_request_error",
      "type" => "invalid_request_error",
      "param" => "input",
      "message" => provider_message
    }

    assignment_a_upstream =
      start_upstream(
        {:sequence,
         [
           websocket_completed_response(fixture["provider_response_id"]),
           websocket_provider_failure(provider_error),
           ordinary_response("resp_after_compact_provider_400")
         ]}
      )

    assignment_b_upstream =
      start_upstream(ordinary_response("resp_provider_400_fallback_should_not_run"))

    setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)

    {lineage_payload, source_frame} =
      canonical_incremental_pair(setup, source_frame, "provider-400-turn")

    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "provider-400-compact")

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)
      {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)

      {conn, websocket, lineage_terminal_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"response" => %{"id" => response_id}} = Jason.decode!(lineage_frame)
      assert response_id == fixture["provider_response_id"]

      assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} =
               Jason.decode!(lineage_terminal_frame)

      setup = activate_assignment_b(setup)
      source_frame = Map.put(source_frame, "previous_response_id", response_id)

      compact_payload = incremental_compact_payload(setup, source_frame, "provider-400-compact")
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
      {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "invalid_request_error",
                 "type" => "invalid_request_error",
                 "param" => "input"
               }
             } = Jason.decode!(error_frame)

      refute error_frame =~ provider_message
      assert [lineage_request, compact_request] = FakeUpstream.requests(assignment_a_upstream)
      assert compact_request.method == "WEBSOCKET"
      assert compact_request.json["previous_response_id"] == fixture["provider_response_id"]
      assert FakeUpstream.count(assignment_b_upstream) == 0

      compact_log =
        Repo.one!(
          from(request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                request.endpoint == "/backend-api/codex/responses/compact"
          )
        )

      assert compact_log.status == "failed"
      assert compact_log.response_status_code == 400
      assert compact_log.retry_count == 0

      assert [compact_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

      assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert compact_attempt.status == "failed"
      assert compact_attempt.network_error_code == "invalid_request_error"
      refute compact_attempt.retryable
      assert compact_attempt.response_metadata["upstream_error_param"] == "input"
      assert settlement_count(compact_log.id) == 1

      assert [compact_turn] =
               Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

      assert compact_turn.status == "failed"
      assert compact_turn.final_attempt_id == compact_attempt.id
      refute inspect({compact_log, compact_attempt, compact_turn}) =~ provider_message

      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          ordinary_payload(setup, %{"request_id" => "full-after-provider-400"})
        )

      {_conn, _websocket, follow_up_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_after_compact_provider_400"} = Jason.decode!(follow_up_frame)

      assert [^lineage_request, ^compact_request, follow_up_request] =
               FakeUpstream.requests(assignment_a_upstream)

      assert follow_up_request.method == "WEBSOCKET"
      refute Map.has_key?(follow_up_request.json, "previous_response_id")
      assert FakeUpstream.websocket_connection_count(assignment_a_upstream) == 1
      assert FakeUpstream.count(assignment_b_upstream) == 0
    after
      Mint.HTTP.close(conn)
    end
  end

  test "misalignment provider rejection uses bounded native compact error without message leakage" do
    fixture = incremental_compaction_fixture!()

    source_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_tool_output_and_trigger",
        "projection_relevant_frame_subset"
      ])

    provider_message = "private-misalignment-message-must-not-reach-native-wire"

    provider_error = %{
      "code" => "misalignment_policy_violation",
      "type" => "invalid_request_error",
      "param" => "input",
      "message" => provider_message
    }

    assignment_a_upstream =
      start_upstream(
        {:sequence,
         [
           websocket_completed_response(fixture["provider_response_id"]),
           websocket_provider_failure(provider_error)
         ]}
      )

    assignment_b_upstream =
      start_upstream(ordinary_response("resp_misalignment_fallback_should_not_run"))

    setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)

    {lineage_payload, source_frame} =
      canonical_incremental_pair(setup, source_frame, "misalignment-turn")

    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "misalignment-compact")

    try do
      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, lineage_payload)

      {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)

      {conn, websocket, lineage_terminal_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"response" => %{"id" => response_id}} = Jason.decode!(lineage_frame)
      assert response_id == fixture["provider_response_id"]

      assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} =
               Jason.decode!(lineage_terminal_frame)

      setup = activate_assignment_b(setup)
      source_frame = Map.put(source_frame, "previous_response_id", response_id)

      compact_payload = incremental_compact_payload(setup, source_frame, "misalignment-compact")
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
      {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "misalignment_policy_violation",
                 "type" => "invalid_request_error",
                 "param" => "input",
                 "message" => "upstream rejected the compact request"
               }
             } = Jason.decode!(error_frame)

      refute error_frame =~ provider_message
      assert FakeUpstream.count(assignment_b_upstream) == 0

      compact_log =
        Repo.one!(
          from(request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                request.endpoint == "/backend-api/codex/responses/compact"
          )
        )

      assert compact_log.status == "failed"
      assert compact_log.response_status_code == 400
      assert compact_log.retry_count == 0

      assert [compact_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

      assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert compact_attempt.network_error_code == "misalignment_policy_violation"

      assert settlement_count(compact_log.id) == 1

      refute inspect({compact_log.request_metadata, compact_attempt.response_metadata}) =~
               provider_message
    after
      Mint.HTTP.close(conn)
    end
  end

  for upstream_code <- ["previous_response_not_found", "invalid_previous_response_id"] do
    @upstream_code upstream_code
    test "provider #{upstream_code} on pinned incremental compaction stays terminal without fallback" do
      upstream_code = @upstream_code
      fixture = incremental_compaction_fixture!()

      source_frame =
        get_in(fixture, [
          "scenarios",
          "anchored_tool_output_and_trigger",
          "projection_relevant_frame_subset"
        ])

      provider_message = "private previous-response provider message"

      provider_error = %{
        "code" => upstream_code,
        "type" => "invalid_request_error",
        "param" => "previous_response_id",
        "message" => provider_message
      }

      assignment_a_upstream =
        start_upstream(
          {:sequence,
           [
             websocket_completed_response(fixture["provider_response_id"]),
             websocket_provider_failure(provider_error)
           ]}
        )

      assignment_b_upstream =
        start_upstream(ordinary_response("resp_previous_response_fallback_should_not_run"))

      setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)

      {lineage_payload, source_frame} =
        canonical_incremental_pair(setup, source_frame, "provider-#{upstream_code}-turn")

      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "provider-#{upstream_code}-compact")

      try do
        {conn, websocket} =
          public_websocket_send_text!(conn, websocket, ref, lineage_payload)

        {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)

        {conn, websocket, lineage_terminal_frame} =
          public_websocket_receive_text!(conn, websocket, ref)

        assert %{"response" => %{"id" => response_id}} = Jason.decode!(lineage_frame)
        assert response_id == fixture["provider_response_id"]

        assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} =
                 Jason.decode!(lineage_terminal_frame)

        setup = activate_assignment_b(setup)
        source_frame = Map.put(source_frame, "previous_response_id", response_id)

        compact_payload =
          incremental_compact_payload(
            setup,
            source_frame,
            "provider-#{upstream_code}-compact"
          )

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)
        {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{
                 "type" => "error",
                 "status" => 400,
                 "error" => %{
                   "code" => "stream_incomplete",
                   "type" => "invalid_request_error",
                   "param" => "previous_response_id"
                 }
               } = Jason.decode!(error_frame)

        refute error_frame =~ provider_message
        assert [lineage_request, compact_request] = FakeUpstream.requests(assignment_a_upstream)
        assert lineage_request.method == "WEBSOCKET"
        assert compact_request.method == "WEBSOCKET"
        assert compact_request.json["previous_response_id"] == fixture["provider_response_id"]
        assert FakeUpstream.count(assignment_b_upstream) == 0

        compact_log =
          Repo.one!(
            from(request in Request,
              where:
                request.pool_id == ^setup.pool.id and
                  request.endpoint == "/backend-api/codex/responses/compact"
            )
          )

        assert compact_log.status == "failed"
        assert compact_log.response_status_code == 400
        assert compact_log.last_error_code == "stream_incomplete"
        assert compact_log.retry_count == 0

        assert [compact_attempt] =
                 Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

        assert compact_attempt.status == "failed"
        assert compact_attempt.network_error_code == "stream_incomplete"
        refute compact_attempt.retryable
        assert compact_attempt.response_metadata["upstream_error_code"] == upstream_code
        assert compact_attempt.response_metadata["masked_error_code"] == "stream_incomplete"

        assert compact_attempt.response_metadata["upstream_error_param"] ==
                 "previous_response_id"

        assert settlement_count(compact_log.id) == 1

        assert [compact_turn] =
                 Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

        assert compact_turn.status == "failed"
        assert compact_turn.error_code == "stream_incomplete"
        assert compact_turn.final_attempt_id == compact_attempt.id

        refute inspect({compact_log, compact_attempt, compact_turn}) =~ provider_message
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "unavailable pinned assignment fails closed without fallback" do
    fixture = incremental_compaction_fixture!()

    source_frame =
      get_in(fixture, [
        "scenarios",
        "anchored_trigger_only",
        "projection_relevant_frame_subset"
      ])

    release_ref = make_ref()

    assignment_a_upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.delayed_terminal_sse_stream(
             [
               %{
                 "type" => "response.created",
                 "response" => %{"id" => fixture["provider_response_id"]}
               }
             ],
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => fixture["provider_response_id"],
                 "status" => "completed",
                 "output" => []
               }
             },
             notify: self(),
             release_ref: release_ref
           ),
           ordinary_response(fixture["provider_response_id"])
         ]}
      )

    assignment_b_upstream = start_upstream(ordinary_response("resp_full_request_on_assignment_b"))
    setup = two_assignment_setup_with_b_disabled(assignment_a_upstream, assignment_b_upstream)

    {lineage_payload, source_frame} =
      canonical_incremental_pair(setup, source_frame, "unavailable-pinned-turn")

    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "unavailable-pinned-compact")

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, lineage_payload)

      assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid,
                      ^release_ref},
                     1_000

      {conn, websocket, lineage_frame} = public_websocket_receive_text!(conn, websocket, ref)
      assert %{"response" => %{"id" => response_id}} = Jason.decode!(lineage_frame)
      assert response_id == fixture["provider_response_id"]

      setup = activate_assignment_b(setup)
      source_frame = Map.put(source_frame, "previous_response_id", response_id)

      assert {:ok, _assignment} = PoolAssignments.disable_pool_assignment(setup.assignment)

      compact_payload =
        incremental_compact_payload(setup, source_frame, "unavailable-pinned-compact")

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact_payload)

      assert [_lineage_request] = FakeUpstream.requests(assignment_a_upstream)
      assert FakeUpstream.count(assignment_b_upstream) == 0

      assert Repo.aggregate(
               from(request in Request,
                 where:
                   request.pool_id == ^setup.pool.id and
                     request.endpoint == "/backend-api/codex/responses/compact"
               ),
               :count
             ) == 0

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      {conn, websocket, lineage_terminal_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.completed"} = Jason.decode!(lineage_terminal_frame)

      {_conn, _websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 503,
               "error" => %{"code" => "pinned_continuation_unavailable"}
             } = Jason.decode!(error_frame)

      assert [_lineage_request] = FakeUpstream.requests(assignment_a_upstream)
      assert FakeUpstream.count(assignment_b_upstream) == 0

      denied_request =
        Repo.one!(
          from(request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                request.endpoint == "/backend-api/codex/responses/compact"
          )
        )

      assert denied_request.endpoint == "/backend-api/codex/responses/compact"
      assert denied_request.status == "rejected"
      assert denied_request.last_error_code == "pinned_continuation_unavailable"
      assert denied_request.retry_count == 0

      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^denied_request.id), :count) ==
               0

      assert settlement_count(denied_request.id) == 0

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.request_id == ^denied_request.id),
               :count
             ) == 0

      assert FakeUpstream.requests(assignment_b_upstream) == []
    after
      receive do
        {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref} ->
          send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      after
        0 -> :ok
      end

      Mint.HTTP.close(conn)
    end
  end

  test "ordinary native frames keep permissive malformed turn-state behavior" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ordinary_permissive_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Websocket.start_codex_session(auth, %{})

    assert :ok =
             Service.execute_websocket_response(
               auth,
               ordinary_payload(setup, %{
                 "client_metadata" => %{"x-codex-turn-state" => ["still-permissive"]}
               }),
               RequestOptions.for_websocket(%{codex_session: session}),
               fn frame ->
                 unless StreamProtocol.internal_control_event?(frame) do
                   send(self(), {:frame, frame})
                 end
               end
             )

    assert_receive {:frame, frame}, @detection_timeout_ms
    assert %{"id" => "resp_ordinary_permissive_turn_state"} = Jason.decode!(frame)
    assert FakeUpstream.count(upstream) == 1
  end

  test "direct socket rejects malformed bridge turn state before side effects and remains reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_invalid_bridge_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = direct_socket(auth, "direct-invalid-bridge-turn-state")

    try do
      state =
        Enum.reduce(invalid_turn_states(), state, fn turn_state, state ->
          assert {:push, {:text, error_frame}, next_state} =
                   CodexResponsesSocket.handle_in(
                     {compact_payload(setup, turn_state), [opcode: :text]},
                     state
                   )

          assert_invalid_turn_state_error(error_frame)
          assert FakeUpstream.count(upstream) == 0
          assert Repo.aggregate(Request, :count) == 0
          assert Repo.aggregate(Attempt, :count) == 0
          assert Repo.aggregate(LedgerEntry, :count) == 0
          next_state
        end)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {ordinary_payload(setup), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_socket_message(state)
      assert %{"id" => "resp_after_invalid_bridge_turn_state"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert FakeUpstream.count(upstream) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded socket rejects malformed bridge turn state before retarget and remains reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_after_invalid_bridge_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "owner-invalid-bridge-turn-state",
          accepted_turn_state: "owner-upgrade-turn-state",
          client_ip: "127.0.0.1"
        }
      })

    original_session_id = state.codex_session.id

    try do
      state =
        Enum.reduce(edge_wrapped_invalid_turn_states(), state, fn turn_state, state ->
          {:ok, target_state} =
            CodexResponsesSocket.init(%{
              auth: auth,
              opts: %{
                request_id:
                  "owner-invalid-bridge-turn-state-target-#{System.unique_integer([:positive])}",
                accepted_turn_state: turn_state,
                client_ip: "127.0.0.1"
              }
            })

          target_session_id = target_state.codex_session.id

          try do
            assert {:push, {:text, error_frame}, next_state} =
                     CodexResponsesSocket.handle_in(
                       {compact_payload(setup, turn_state), [opcode: :text]},
                       state
                     )

            assert next_state.codex_session.id == original_session_id
            refute next_state.codex_session.id == target_session_id
            assert_invalid_turn_state_error(error_frame)
            assert next_state.codex_session.id == original_session_id
            refute next_state.codex_session.id == target_session_id
            assert_no_invalid_turn_state_side_effects(upstream)
            next_state
          after
            CodexResponsesSocket.terminate(:closed, target_state)
          end
        end)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {ordinary_payload(setup), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_socket_message(state)
      assert %{"id" => "resp_owner_after_invalid_bridge_turn_state"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_completion(state)
      assert FakeUpstream.count(upstream) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "buffered native bridge forwards one validated frame turn state and adapts once after settlement" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_native_buffered_compaction",
          "output" => [
            %{
              "type" => "compaction",
              "encrypted_content" => "synthetic-native-buffered-encrypted"
            }
          ],
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      direct_socket(auth, "native-buffered-success",
        accepted_turn_state: "upgrade-turn-state",
        forwarded_headers: [
          {"X-Codex-Turn-State", "stale-one"},
          {"x-codex-turn-state", "stale-two"}
        ]
      )

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {compact_payload(setup, "  frame-turn-state  "), [opcode: :text]},
                 state
               )

      assert {:push, {:text, done_frame}, state} = receive_socket_message(state)
      assert {:push, {:text, completed_frame}, state} = receive_socket_message(state)
      assert {:ok, _state} = receive_socket_done(state)

      assert %{"type" => "response.output_item.done", "item" => item} = Jason.decode!(done_frame)

      assert %{
               "type" => "response.completed",
               "response" => %{"output" => [^item]}
             } = Jason.decode!(completed_frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "POST"
      assert captured.path == "/backend-api/codex/responses"

      assert Enum.filter(captured.headers, fn {name, _value} ->
               String.downcase(name) == "x-codex-turn-state"
             end) == [{"x-codex-turn-state", "frame-turn-state"}]

      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "succeeded"
      assert settlement_count(request.id) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "invalid buffered native compact bodies fail before success settlement" do
    cases = [
      {FakeUpstream.malformed_json("{malformed-native-compact", 200),
       "upstream compact response was not valid JSON"},
      {FakeUpstream.json_response(%{"id" => "resp_missing_native_compact_content"}),
       "upstream compact response did not include encrypted compaction content"},
      {buffered_native_compaction_response("resp_empty_native_compact_content", "", :output),
       "upstream compact response did not include encrypted compaction content"},
      {buffered_native_compaction_response(
         "resp_blank_native_compact_content",
         " \t\r\n",
         :top_level
       ), "upstream compact response did not include encrypted compaction content"}
    ]

    for {mode, expected_message} <- cases do
      upstream = start_upstream(mode)
      setup = gateway_setup(upstream, compact?: true)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Websocket.start_codex_session(auth, %{})

      assert {:error, error} =
               Service.execute_websocket_response(
                 auth,
                 compact_payload(setup, nil),
                 RequestOptions.for_websocket(%{codex_session: session}),
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      assert error.status == 502
      assert error.code == "invalid_compaction_response"
      assert error.message == expected_message
      refute_received {:unexpected_frame, _frame}

      assert [request] =
               Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

      assert request.status == "failed"
      assert request.last_error_code == "invalid_compaction_response"
      assert request.retry_count == 0

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "failed"
      assert attempt.network_error_code == "invalid_compaction_response"
      refute attempt.retryable

      assert [turn] =
               Repo.all(
                 from(turn in CodexTurn,
                   where: turn.codex_session_id == ^session.id and turn.request_id == ^request.id
                 )
               )

      assert turn.status == "failed"
      assert turn.error_code == "invalid_compaction_response"
      assert turn.final_attempt_id == attempt.id
      assert settlement_count(request.id) == 1
      refute inspect({request, attempt, turn}) =~ @stale_native_content
    end
  end

  test "native compact saturation emits one error, releases admission, and keeps the socket reusable" do
    unrelated_lease_holder = hold_admission_lease("proxy_http")
    configure_compact_saturation()

    assert {:ok, saturation} = Admission.saturation()
    assert saturation["proxy_http"] == %{running: 1, queued: 0}

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_native_compact_saturation",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()
    compact_lease_holder = hold_admission_lease("proxy_compact")

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "native-compact-saturation",
        "/backend-api/codex/responses"
      )

    try do
      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          compact_payload(setup, "native-compact-saturation", :buffered)
        )

      {conn, websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert Jason.decode!(error_frame) == %{
               "type" => "error",
               "status" => 503,
               "error" => %{
                 "code" => "server_is_overloaded",
                 "message" => "gateway route class is temporarily overloaded",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      assert_no_invalid_turn_state_side_effects(upstream)
      assert {:ok, saturation} = Admission.saturation()
      assert saturation["proxy_compact"] == %{running: 1, queued: 0}
      assert saturation["proxy_websocket"] == %{running: 0, queued: 0}

      release_admission_lease(compact_lease_holder)
      assert_admission_released("proxy_compact")

      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, ordinary_payload(setup))

      {_conn, _websocket, follow_up_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_after_native_compact_saturation"} = Jason.decode!(follow_up_frame)
      assert FakeUpstream.count(upstream) == 1

      assert [request] = Repo.all(Request)
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
    after
      release_admission_lease(compact_lease_holder)
      release_admission_lease(unrelated_lease_holder)
      Mint.HTTP.close(conn)
    end
  end

  test "malformed native compact triggers dispatch nothing and keep the downstream socket reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_malformed_native_compact",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(
        port,
        setup,
        "malformed-native-compact",
        "/backend-api/codex/v1/responses"
      )

    try do
      {conn, websocket} =
        Enum.reduce(malformed_compact_payloads(setup), {conn, websocket}, fn payload,
                                                                             {conn, websocket} ->
          {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
          {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

          assert %{
                   "type" => "error",
                   "status" => 400,
                   "error" => %{"code" => "invalid_request", "param" => "input"}
                 } = Jason.decode!(frame)

          assert_no_invalid_turn_state_side_effects(upstream)
          {conn, websocket}
        end)

      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, ordinary_payload(setup))

      {_conn, _websocket, follow_up_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_after_malformed_native_compact"} = Jason.decode!(follow_up_frame)
      assert FakeUpstream.count(upstream) == 1
    after
      Mint.HTTP.close(conn)
    end
  end

  defp direct_socket(auth, request_id, extra_opts \\ []) do
    CodexResponsesSocket.init(%{
      auth: auth,
      opts:
        Map.merge(
          %{request_id: request_id, client_ip: "127.0.0.1"},
          Map.new(extra_opts)
        )
    })
  end

  defp compact_expected(:sse, key),
    do:
      Map.fetch!(
        %{
          method: "WEBSOCKET",
          http_count: 0,
          websocket?: true,
          transport: "websocket",
          turn_transport: "websocket"
        },
        key
      )

  defp compact_expected(:buffered, key),
    do:
      Map.fetch!(
        %{
          method: "POST",
          http_count: 1,
          websocket?: false,
          transport: "http_compact_json",
          turn_transport: "http_json"
        },
        key
      )

  defp assert_compact_turn_state_header(headers, :buffered, frame_turn_state),
    do: assert(header_values(headers, "x-codex-turn-state") == [frame_turn_state])

  defp assert_compact_turn_state_header(headers, :sse, _frame_turn_state),
    do: assert(header_values(headers, "x-codex-turn-state") == [])

  defp compact_payload(setup, turn_state, transport \\ :buffered) do
    client_metadata =
      if is_nil(turn_state), do: %{}, else: %{"x-codex-turn-state" => turn_state}

    client_metadata =
      if transport == :sse do
        remote_compaction_v2_client_metadata()
        |> Map.merge(client_metadata)
      else
        client_metadata
      end

    Jason.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "synthetic compact input"},
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true,
      "generate" => true,
      "client_metadata" => client_metadata
    })
  end

  defp incremental_compact_payload(setup, source_frame, request_id) do
    source_frame
    |> Map.put("model", setup.model.exposed_model_id)
    |> Map.put("generate", true)
    |> Map.put("request_id", request_id)
    |> Jason.encode!()
  end

  defp canonical_incremental_pair(setup, source_frame, turn_id) do
    context_window_id = "00000000-0000-4000-8000-000000000506"

    anchor =
      ordinary_payload(setup, %{
        "client_metadata" => %{
          "turn_id" => turn_id,
          "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_window_id, :turn)
        }
      })

    compact =
      put_in(source_frame, ["client_metadata"], %{
        "turn_id" => turn_id,
        "x-codex-turn-metadata" => native_turn_metadata(turn_id, context_window_id, :compaction)
      })

    {anchor, compact}
  end

  defp native_turn_metadata(turn_id, context_window_id, :turn) do
    Jason.encode!(%{
      "turn_id" => turn_id,
      "window_id" => "window-#{turn_id}",
      "context_window_id" => context_window_id,
      "window_number" => 1,
      "request_kind" => "turn"
    })
  end

  defp native_turn_metadata(turn_id, context_window_id, :compaction) do
    Jason.encode!(%{
      "turn_id" => turn_id,
      "window_id" => "window-#{turn_id}",
      "context_window_id" => context_window_id,
      "window_number" => 1,
      "request_kind" => "compaction",
      "compaction" => %{
        "trigger" => "auto",
        "reason" => "context_limit",
        "implementation" => "responses_compaction_v2",
        "phase" => "mid_turn",
        "strategy" => "memento"
      }
    })
  end

  defp incremental_compaction_fixture! do
    @incremental_compaction_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("contract")
  end

  defp incremental_compaction_item(suffix) do
    %{
      "type" => "compaction",
      "encrypted_content" => "synthetic-incremental-#{suffix}"
    }
  end

  defp delayed_incremental_compaction_response(item, response_id, notify, release_ref) do
    FakeUpstream.delayed_terminal_sse_stream(
      [%{"type" => "response.output_item.done", "item" => item}],
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "output" => [item]
        }
      },
      notify: notify,
      release_ref: release_ref
    )
  end

  defp ordinary_response(response_id) do
    FakeUpstream.json_response(%{
      "id" => response_id,
      "object" => "response",
      "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
    })
  end

  defp websocket_completed_response(response_id) do
    FakeUpstream.sse_stream([
      {"response.created",
       %{
         "type" => "response.created",
         "response" => %{"id" => response_id, "status" => "in_progress"}
       }},
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
         }
       }}
    ])
  end

  defp websocket_provider_failure(provider_error) do
    FakeUpstream.sse_stream(
      [
        {"response.failed",
         %{
           "type" => "response.failed",
           "response" => %{
             "status" => "failed",
             "error" => provider_error
           }
         }}
      ],
      done: false
    )
  end

  defp two_assignment_setup_with_b_disabled(setup_upstream, assignment_b_upstream) do
    setup = gateway_setup(setup_upstream, compact?: true)

    assignment_b =
      gateway_upstream(
        setup.pool,
        assignment_b_upstream,
        "upstream-token-incremental-assignment-b",
        compact?: true
      )

    prime_routing_quota!(assignment_b.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    assert {:ok, assignment_b_record} =
             PoolAssignments.disable_pool_assignment(assignment_b.assignment)

    model =
      put_model_source_assignments!(setup.model, [setup.assignment, assignment_b.assignment])

    setup
    |> Map.put(:model, model)
    |> Map.put(:assignment_b, assignment_b_record)
    |> Map.put(:identity_b, assignment_b.identity)
  end

  defp activate_assignment_b(setup) do
    assert {:ok, assignment_b} = PoolAssignments.activate_pool_assignment(setup.assignment_b)
    %{setup | assignment_b: assignment_b}
  end

  defp remote_compaction_v2_client_metadata do
    @remote_compaction_v2_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["request", "client_metadata"])
  end

  defp ordinary_payload(setup, extra \\ %{}) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "ordinary turn"}],
      "stream" => true,
      "generate" => true
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp buffered_native_compaction_response(response_id, encrypted_content, :output) do
    FakeUpstream.json_response(%{
      "id" => response_id,
      "output" => [
        %{"type" => "compaction", "encrypted_content" => encrypted_content},
        %{"type" => "compaction_summary", "encrypted_content" => @stale_native_content}
      ],
      "compaction_summary" => %{"encrypted_content" => @stale_native_content}
    })
  end

  defp buffered_native_compaction_response(response_id, encrypted_content, :top_level) do
    FakeUpstream.json_response(%{
      "id" => response_id,
      "compaction_summary" => %{"encrypted_content" => encrypted_content}
    })
  end

  defp invalid_turn_states do
    [
      ["wrong-type"],
      "   ",
      "control\tvalue",
      "non-ascii-\u00e9",
      String.duplicate("a", 4_097)
    ] ++ edge_wrapped_invalid_turn_states()
  end

  defp edge_wrapped_invalid_turn_states do
    [
      "\tvalid",
      "valid\t",
      "\rvalid",
      "valid\r",
      "\nvalid",
      "valid\n",
      "\r\nvalid",
      "valid\r\n",
      "\u00A0valid",
      "valid\u00A0",
      "\u00A0valid\u00A0"
    ]
  end

  defp malformed_compact_payloads(setup) do
    visible = %{"type" => "message", "role" => "user", "content" => "synthetic visible"}
    trigger = %{"type" => "compaction_trigger"}

    for input <- [
          [visible, trigger, visible],
          [visible, trigger, trigger]
        ] do
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => input,
        "stream" => true,
        "generate" => true
      })
    end
  end

  defp assert_invalid_turn_state_error(frame) do
    assert %{
             "type" => "error",
             "error" => %{
               "code" => "invalid_request",
               "param" => @turn_state_param
             }
           } = Jason.decode!(frame)

    refute frame =~ "wrong-type"
    refute frame =~ "control"
    refute frame =~ "non-ascii"
  end

  defp assert_no_invalid_turn_state_side_effects(upstream) do
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  defp settlement_count(request_id) do
    Repo.aggregate(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
      ),
      :count
    )
  end

  defp native_compaction_fixture(transport, optional_metadata) do
    suffix = "#{transport}_#{optional_metadata}"
    encrypted_content = "synthetic-native-#{suffix}-encrypted"
    item_id = "cmp_native_#{suffix}"
    turn_id = "turn_native_#{suffix}"
    omitted_sentinel = "native-#{suffix}-must-not-survive"
    response_id = "resp_native_#{suffix}"

    source_item =
      %{
        "type" => "compaction",
        "encrypted_content" => encrypted_content,
        "summary" => omitted_sentinel
      }
      |> put_optional_metadata(optional_metadata, item_id, turn_id, omitted_sentinel)

    expected_item =
      %{
        "type" => "compaction",
        "encrypted_content" => encrypted_content
      }
      |> put_expected_metadata(optional_metadata, item_id, turn_id)

    response = %{
      "id" => response_id,
      "output" => [source_item],
      "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
    }

    upstream_mode =
      case transport do
        :buffered ->
          FakeUpstream.json_response(response)

        :sse ->
          FakeUpstream.sse_stream([
            {"response.output_item.done",
             %{"type" => "response.output_item.done", "item" => source_item}},
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => Map.put(response, "status", "completed")
             }}
          ])
      end

    %{
      case_id: suffix,
      encrypted_content: encrypted_content,
      expected_item: expected_item,
      follow_up_response_id: "resp_native_#{suffix}_follow_up",
      item_id: item_id,
      omitted_sentinel: omitted_sentinel,
      response_id: response_id,
      turn_id: turn_id,
      upstream_mode: upstream_mode
    }
  end

  defp trace_root(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "native-trace-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp await_trace_event!(event, attempts \\ 200)
  defp await_trace_event!(_event, 0), do: flunk("trace event was not observed")

  defp await_trace_event!(event, attempts) do
    if Enum.any?(NativeCompactionTrace.export()["events"], &(&1["event"] == event)) do
      :ok
    else
      receive after: (10 -> :ok)
      await_trace_event!(event, attempts - 1)
    end
  end

  defp assert_real_trace_fixture_has_no_manual_emits! do
    source = File.read!(__ENV__.file)

    for forbidden <- [
          Enum.join(["Trace", "Event", ".", "emit"]),
          Enum.join(["NativeCompaction", "Trace", ".", "emit"])
        ] do
      refute source =~ forbidden
    end
  end

  defp enable_owner_forwarding_for_trace! do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_trace_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  defp cleanup_trace_owner_sessions do
    WebsocketOwnerSession.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(fn codex_session_id ->
      case WebsocketOwnerSession.lookup(codex_session_id) do
        {:ok, owner_pid} ->
          monitor = Process.monitor(owner_pid)

          try do
            GenServer.stop(owner_pid, :shutdown, @detection_timeout_ms)
          catch
            :exit, {:noproc, _details} -> :ok
          end

          assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason},
                         @detection_timeout_ms

        {:error, :owner_unavailable} ->
          :ok
      end

      assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(codex_session_id)
    end)

    :ok
  end

  defp put_optional_metadata(item, :valid, item_id, turn_id, omitted_sentinel) do
    item
    |> Map.put("id", item_id)
    |> Map.put("internal_chat_message_metadata_passthrough", %{
      "turn_id" => turn_id,
      "unknown" => omitted_sentinel
    })
  end

  defp put_optional_metadata(item, :malformed, _item_id, _turn_id, omitted_sentinel) do
    item
    |> Map.put("id", 17)
    |> Map.put("internal_chat_message_metadata_passthrough", %{
      "turn_id" => [omitted_sentinel]
    })
  end

  defp put_expected_metadata(item, :valid, item_id, turn_id) do
    item
    |> Map.put("id", item_id)
    |> Map.put("internal_chat_message_metadata_passthrough", %{"turn_id" => turn_id})
  end

  defp put_expected_metadata(item, :malformed, _item_id, _turn_id), do: item

  defp header_values(headers, target_name) do
    for {name, value} <- headers, String.downcase(name) == target_name, do: value
  end

  defp assert_no_raw_compaction_persistence(setup, forbidden_values) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from(a in Attempt, where: a.request_id in ^request_ids))
    ledger_entries = Repo.all(from(e in LedgerEntry, where: e.request_id in ^request_ids))
    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    session_ids = Enum.map(sessions, & &1.id)
    turns = Repo.all(from(t in CodexTurn, where: t.codex_session_id in ^session_ids))
    aliases = Repo.all(from(a in BridgeSessionAlias, where: a.codex_session_id in ^session_ids))
    durable_text = inspect({requests, attempts, ledger_entries, sessions, turns, aliases})

    for value <- forbidden_values, is_binary(value) do
      refute durable_text =~ value
    end
  end

  defp attach_admission_telemetry do
    {:ok, event_store} = Agent.start_link(fn -> [] end)
    handler_id = "native-compact-admission-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :admission, :accepted],
        fn _event, _measurements, metadata, event_store ->
          Agent.get_and_update(event_store, fn events -> {:ok, [metadata | events]} end)
        end,
        event_store
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if Process.alive?(event_store) do
        Agent.stop(event_store)
      end
    end)

    event_store
  end

  defp assert_admission_events(event_store, expected_route_classes) do
    _ = :sys.get_state(Admission)

    route_classes =
      Agent.get(event_store, fn events ->
        events
        |> Enum.reverse()
        |> Enum.map(& &1.route_class)
      end)

    assert route_classes == expected_route_classes
    assert Enum.frequencies(route_classes) == Enum.frequencies(expected_route_classes)
  end

  defp assert_compact_transport_payload(payload, :buffered) do
    refute Map.has_key?(payload, "stream")
  end

  defp assert_compact_transport_payload(payload, :sse) do
    assert payload["stream"] == true
  end

  defp configure_compact_saturation do
    old_config = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: compact_saturation_settings()
    )

    on_exit(fn ->
      if old_config do
        Application.put_env(:codex_pooler, OperationalSettings, old_config)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  defp compact_saturation_settings do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class, %{max_concurrency: 4, queue_limit: 4, queue_timeout_ms: 1_000}}
        end)
        |> Map.put("proxy_compact", %{
          max_concurrency: 1,
          queue_limit: 0,
          queue_timeout_ms: 1_000
        })
    }
  end

  defp assert_admission_released(route_class) do
    _ = :sys.get_state(Admission)
    assert {:ok, saturation} = Admission.saturation()
    assert saturation[route_class] == %{running: 0, queued: 0}
  end

  defp hold_admission_lease(route_class) do
    parent = self()
    holder_ref = make_ref()

    holder_pid =
      spawn_link(fn ->
        {:ok, lease} = Admission.acquire(route_class, %{request_id: "held-#{route_class}"})
        send(parent, {:admission_lease_held, holder_ref})

        receive do
          {:release_admission_lease, ^holder_ref} -> Admission.release(lease)
        after
          @detection_timeout_ms -> Admission.release(lease)
        end
      end)

    assert_receive {:admission_lease_held, ^holder_ref}, @detection_timeout_ms
    {holder_pid, holder_ref}
  end

  defp release_admission_lease({holder_pid, holder_ref}) do
    if Process.alive?(holder_pid) do
      monitor = Process.monitor(holder_pid)
      send(holder_pid, {:release_admission_lease, holder_ref})
      assert_receive {:DOWN, ^monitor, :process, ^holder_pid, :normal}, @detection_timeout_ms
    end

    :ok
  end

  defp receive_socket_message(state) do
    receive do
      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:push, {:text, frame}, next_state} = result ->
            if StreamProtocol.internal_control_event?(frame) do
              receive_socket_message(next_state)
            else
              result
            end

          {:ok, next_state} ->
            receive_socket_message(next_state)
        end
    after
      @detection_timeout_ms -> flunk("expected websocket frame")
    end
  end

  defp receive_socket_completion(state) do
    receive do
      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:ok, next_state} = result ->
            if MapSet.size(Map.get(next_state, :tasks, MapSet.new())) == 0 do
              result
            else
              receive_socket_completion(next_state)
            end

          {:push, _frame, next_state} ->
            receive_socket_completion(next_state)
        end
    after
      @detection_timeout_ms -> flunk("expected websocket completion")
    end
  end
end
