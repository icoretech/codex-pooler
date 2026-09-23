defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.CompactionLockingTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.{Access, FakeUpstream, Repo, TestAppEnv}
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Persistence.SessionContinuity

  alias CodexPooler.Gateway.Transports.Websocket.{
    NativeCompactionAdmission,
    WebsocketOwnerAdmissionControlV1,
    WebsocketOwnerSession
  }

  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout 15_000

  for scenario <- [:renewal, :rollback, :cancel, :expiry] do
    test "anchored compaction reservation remains safe under #{scenario}" do
      run_compaction_scenario(unquote(scenario))
    end
  end

  defp run_compaction_scenario(scenario) do
    # The RED spends the production five-second owner call timeout proving the cycle.
    TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    Sandbox.mode(Repo, :auto)

    compact_item = %{"type" => "compaction", "encrypted_content" => "synthetic-locked-summary"}

    terminal = fn id, output ->
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => id, "status" => "completed", "output" => output}
      })
    end

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence(
          Enum.take(
            [
              FakeUpstream.expect_request(
                method: "WEBSOCKET",
                json: [valid: true, forbidden: ["previous_response_id"]],
                respond: FakeUpstream.websocket_text_frames([terminal.("resp_locking_anchor", [])])
              ),
              FakeUpstream.expect_request(
                method: "WEBSOCKET",
                json: [valid: true, equals: %{"previous_response_id" => "resp_locking_anchor"}],
                respond:
                  FakeUpstream.websocket_text_frames([
                    CodexPooler.JSON.encode!(%{
                      "type" => "response.output_item.done",
                      "item" => compact_item
                    }),
                    terminal.("resp_locking_compact", [compact_item])
                  ])
              )
            ],
            if(scenario == :renewal, do: 2, else: 1)
          )
        )
      )

    {:ok, setup} =
      Repo.transaction(fn ->
        fixture =
          gateway_setup(upstream,
            compact?: true,
            upstream_model_id: "locking-#{System.unique_integer([:positive])}"
          )

        on_exit(fn -> cleanup_unboxed_pool!(fixture) end)
        fixture
      end)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "locking-compact", "locking-compact-session")
    session_id = state.codex_session.id
    on_exit(fn -> stop_websocket_owner_session(session_id) end)

    metadata = %{
      "turn_id" => "locking-turn",
      "window_id" => "locking-window",
      "context_window_id" => Ecto.UUID.generate(),
      "window_number" => 1,
      "request_kind" => "turn"
    }

    ordinary =
      websocket_payload(setup, "synthetic history", %{
        "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata)}
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({ordinary, [opcode: :text]}, state)
    assert {:push, {:text, _frame}, state} = receive_owner_socket_push(state)
    assert {:ok, state} = receive_socket_turn_done(state)
    {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    parent = self()
    barrier = make_ref()

    observe_renewal(owner, parent, barrier)

    handler = {__MODULE__, barrier}
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, event, _ ->
          if String.starts_with?(event.query, "INSERT INTO") and
               String.contains?(event.query, "codex_turns") and self() != parent do
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:reservation_locked, barrier, self(), backend})

            receive do
              {:release_reservation, ^barrier} -> :ok
            after
              @detection_timeout -> raise "reservation barrier not released"
            end
          end
        end,
        nil
      )

    compact_metadata =
      Map.merge(metadata, %{
        "request_kind" => "compaction",
        "compaction" => %{
          "trigger" => "auto",
          "reason" => "context_limit",
          "implementation" => "responses_compaction_v2",
          "phase" => "mid_turn",
          "strategy" => "memento"
        }
      })

    compact =
      websocket_input_payload(
        setup,
        [
          %{"type" => "function_call_output", "call_id" => "call_locking", "output" => ""},
          %{"type" => "compaction_trigger"}
        ],
        %{
          "previous_response_id" => "resp_locking_anchor",
          "client_metadata" => %{
            "x-codex-turn-metadata" => CodexPooler.JSON.encode!(compact_metadata)
          }
        }
      )

    assert {:ok, state} = CodexResponsesSocket.handle_in({compact, [opcode: :text]}, state)

    assert_receive {:reservation_locked, ^barrier, caller, reservation_backend},
                   @detection_timeout

    monitor = Process.monitor(caller)

    on_exit(fn ->
      send(caller, {:release_reservation, barrier})
      task_monitor = Process.monitor(caller)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      assert_receive {:DOWN, ^task_monitor, :process, ^caller, _}, @detection_timeout
    end)

    disturb_reservation(scenario, owner, barrier, reservation_backend)

    {{frame, state}, logs} =
      with_info_log(fn ->
        send(caller, {:release_reservation, barrier})
        assert {:push, {:text, frame}, next_state} = receive_native_collect_socket_push(state)
        {frame, next_state}
      end)

    state = assert_compaction_result(scenario, frame, state, logs)

    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert_receive {:DOWN, ^monitor, :process, ^caller, _}, @detection_timeout

    if scenario != :renewal,
      do: assert(is_nil(:sys.get_state(owner).native_compaction_admission))

    stop_websocket_owner_session(session_id)
    assert_accounting(scenario, setup)

    assert FakeUpstream.http_request_count(upstream) == 0
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp observe_renewal(owner, parent, barrier) do
    :sys.replace_state(owner, fn owner_state ->
      persistence =
        Map.put(owner_state.persistence, :renew_owner_token, fn id, token, opts ->
          renew_with_backend(parent, barrier, id, token, opts)
        end)

      %{owner_state | persistence: persistence}
    end)
  end

  defp renew_with_backend(parent, barrier, id, token, opts) do
    Repo.checkout(fn ->
      [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(parent, {:renewal_backend, barrier, backend})
      SessionContinuity.renew_owner_token(id, token, opts)
    end)
  end

  defp disturb_reservation(scenario, owner, barrier, reservation_backend) do
    case scenario do
      :renewal ->
        send(owner, :renew_owner_lease)
        assert_receive {:renewal_backend, ^barrier, renewal_backend}, @detection_timeout
        refute renewal_backend == reservation_backend

        assert_blocked!(
          renewal_backend,
          reservation_backend,
          System.monotonic_time(:millisecond) + @detection_timeout
        )

      :rollback ->
        assert :sys.get_state(owner).native_compaction_admission.phase ==
                 :accounting_started_compact

        assert [[true]] =
                 Repo.query!("SELECT pg_terminate_backend($1)", [reservation_backend]).rows

      :expiry ->
        :sys.replace_state(owner, fn owner_state ->
          admission = owner_state.native_compaction_admission
          assert admission.phase == :accounting_started_compact

          assert {:expired, expired} =
                   NativeCompactionAdmission.expire(
                     admission,
                     admission.expires_at_ms + 1
                   )

          %{owner_state | native_compaction_admission: expired}
        end)

      :cancel ->
        owner_state = :sys.get_state(owner)
        assert owner_state.native_compaction_admission.phase == :accounting_started_compact

        attrs =
          Map.from_keys(
            [
              :binding,
              :phase,
              :control_ref,
              :disposition,
              :success?,
              :compaction_item_digest,
              :confirmation,
              :first_compact_collection,
              :expires_at_ms,
              :now_ms
            ],
            nil
          )

        attrs =
          Map.merge(attrs, %{
            version: 1,
            action: :cancel,
            disposition: :pre_accounting,
            now_ms: System.system_time(:millisecond),
            downstream: Map.take(owner_state.downstream, [:pid, :epoch, :correlation_id]),
            capability: owner_state.native_compaction_admission.capability
          })

        assert {:ok, control} =
                 WebsocketOwnerAdmissionControlV1.new(attrs)

        assert {:error, :committed} = WebsocketOwnerSession.admission_control(owner, control)
    end
  end

  defp assert_compaction_result(scenario, frame, state, logs) do
    if scenario == :renewal do
      assert CodexPooler.JSON.decode!(frame)["type"] == "response.output_item.done", logs
      assert {:push, {:text, frame}, next_state} = receive_native_collect_socket_push(state)
      assert CodexPooler.JSON.decode!(frame)["type"] == "response.completed"
      assert {:ok, next_state} = receive_socket_turn_done(next_state)
      next_state
    else
      decoded = CodexPooler.JSON.decode!(frame)
      assert decoded["type"] == "error"

      # A database connection lost during the reservation is a transient
      # failure before dispatch: the client gets the retryable 503.
      assert decoded["error"]["code"] ==
               if(scenario == :rollback,
                 do: "service_unavailable",
                 else: "upstream_request_failed"
               )

      assert logs =~
               if(scenario == :rollback, do: "reason_class=postgres_admin_shutdown", else: "native")

      state
    end
  end

  defp assert_accounting(scenario, setup) do
    expected = if scenario == :renewal, do: 2, else: 1

    assert Repo.aggregate(
             from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "succeeded"),
             :count
           ) == expected

    if scenario == :rollback,
      do: assert(Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1)

    compact_requests =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id and r.endpoint == "/backend-api/codex/responses/compact"
        )
      )

    if scenario == :rollback do
      assert compact_requests == []
    else
      assert [request] = compact_requests
      assert request.status == if(scenario == :renewal, do: "succeeded", else: "failed")
      entries = pool_ledger_entries(setup.pool.id) |> Enum.filter(&(&1.request_id == request.id))
      assert Enum.count(entries, &(&1.entry_kind == "settlement")) == 1
      assert Enum.count(entries, &(&1.entry_kind == "release")) == 1
      assert Enum.count(entries, &(&1.entry_kind == "reservation")) == 1
    end
  end

  defp assert_blocked!(waiter, blocker, deadline) do
    [[blocked]] = Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, blocker]).rows

    if blocked do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "owner renewal did not block on reservation"

      receive do
      after
        10 -> assert_blocked!(waiter, blocker, deadline)
      end
    end
  end
end
