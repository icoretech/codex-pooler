defmodule CodexPooler.Gateway.Runtime.Finalization.InterruptionTelemetryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, SessionContinuity}

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @task_timeout 15_000

  test "outermost active-attempt interruption emits once after commit and repeated interruption is silent" do
    fixture = committed_interruption_fixture!(:active_attempt)

    try do
      capture_outcomes(fn ->
        result = run_unboxed(fn -> interrupt_turn(fixture) end)

        assert result == {:ok, %{interrupted_turn_count: 1}}

        assert_receive {:stream_outcome,
                        %{
                          outcome: "interrupted",
                          downstream_transport: "websocket",
                          upstream_transport: "websocket"
                        }}

        assert committed_interruption_state(fixture) == %{
                 request_status: "failed",
                 attempt_status: "failed",
                 turn_status: "interrupted",
                 settlement_count: 1
               }

        assert run_unboxed(fn -> interrupt_turn(fixture) end) ==
                 {:ok, %{interrupted_turn_count: 0}}

        refute_received {:stream_outcome, _metadata}
      end)
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "outermost no-attempt interruption emits unknown upstream after commit" do
    fixture = committed_interruption_fixture!(:without_attempt)

    try do
      capture_outcomes(fn ->
        assert run_unboxed(fn -> interrupt_turn(fixture) end) ==
                 {:ok, %{interrupted_turn_count: 1}}

        assert_receive {:stream_outcome,
                        %{
                          outcome: "interrupted",
                          downstream_transport: "websocket",
                          upstream_transport: "unknown"
                        }}

        refute_received {:stream_outcome, _metadata}
      end)
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "interruption-first and transport-finalizer-first orderings emit one total outcome each" do
    for ordering <- [:interruption_first, :transport_finalizer_first] do
      fixture = committed_interruption_fixture!(:active_attempt)

      try do
        capture_outcomes(fn ->
          results =
            case ordering do
              :interruption_first ->
                run_ordered_operations(
                  fn -> interrupt_turn(fixture) end,
                  fn -> transport_finalize(fixture) end
                )

              :transport_finalizer_first ->
                run_ordered_operations(
                  fn -> transport_finalize(fixture) end,
                  fn -> interrupt_turn(fixture) end
                )
            end

          assert Enum.count(results, &match?({:error, %{code: "client_disconnected"}}, &1)) == 1

          expected_interruption_result =
            case ordering do
              :interruption_first -> {:ok, %{interrupted_turn_count: 1}}
              :transport_finalizer_first -> {:ok, %{interrupted_turn_count: 0}}
            end

          assert Enum.find(results, &match?({:ok, %{interrupted_turn_count: _}}, &1)) ==
                   expected_interruption_result

          assert_receive {:stream_outcome,
                          %{
                            outcome: "interrupted",
                            downstream_transport: "websocket",
                            upstream_transport: "websocket"
                          }}

          refute_received {:stream_outcome, _metadata}
        end)
      after
        cleanup_committed_fixture!(fixture)
      end
    end
  end

  test "outermost accounting rollback emits one settlement failure and preserves exact tuple" do
    fixture = committed_interruption_fixture!(:accounting_failure)

    try do
      capture_outcomes(fn ->
        result = run_unboxed(fn -> interrupt_turn(fixture) end)

        assert {:error, {:interrupt_accounting_failed, %Ecto.NoResultsError{}}} = result

        assert_receive {:stream_outcome,
                        %{
                          outcome: "settlement_failed",
                          downstream_transport: "websocket",
                          upstream_transport: "websocket"
                        }}

        refute_received {:stream_outcome, _metadata}
      end)

      assert committed_interruption_state(fixture) == %{
               request_status: "in_progress",
               attempt_status: "in_progress",
               turn_status: "in_progress",
               settlement_count: 0
             }

      assert run_unboxed(fn -> Repo.get!(CodexSession, fixture.session.id).status end) == "active"
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "caller-owned transaction commit and rollback emit zero outcomes permanently" do
    for outer_result <- [:commit, :rollback] do
      fixture = committed_interruption_fixture!(:active_attempt)

      try do
        capture_outcomes(fn ->
          result =
            run_unboxed(fn ->
              Repo.transaction(fn ->
                assert interrupt_turn(fixture) == {:ok, %{interrupted_turn_count: 1}}

                case outer_result do
                  :commit -> :committed
                  :rollback -> Repo.rollback(:caller_rollback)
                end
              end)
            end)

          expected_result =
            case outer_result do
              :commit -> {:ok, :committed}
              :rollback -> {:error, :caller_rollback}
            end

          assert result == expected_result

          refute_received {:stream_outcome, _metadata}
        end)

        state = committed_interruption_state(fixture)

        expected_state =
          case outer_result do
            :commit ->
              %{
                request_status: "failed",
                attempt_status: "failed",
                turn_status: "interrupted",
                settlement_count: 1
              }

            :rollback ->
              %{
                request_status: "in_progress",
                attempt_status: "in_progress",
                turn_status: "in_progress",
                settlement_count: 0
              }
          end

        assert state == expected_state
      after
        cleanup_committed_fixture!(fixture)
      end
    end
  end

  test "caller-owned accounting rollback preserves the exact error and emits zero" do
    fixture = committed_interruption_fixture!(:accounting_failure)

    try do
      capture_outcomes(fn ->
        result =
          run_unboxed(fn ->
            Repo.transaction(fn ->
              result = interrupt_turn(fixture)
              assert {:error, {:interrupt_accounting_failed, %Ecto.NoResultsError{}}} = result
              :caller_callback_returned
            end)
          end)

        assert result == {:error, :rollback}
        refute_received {:stream_outcome, _metadata}
      end)

      assert committed_interruption_state(fixture) == %{
               request_status: "in_progress",
               attempt_status: "in_progress",
               turn_status: "in_progress",
               settlement_count: 0
             }
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  defp committed_interruption_fixture!(mode) do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive, :monotonic])
      setup = accounting_setup(%{account_label: "Interruption telemetry #{unique}"})

      assert {:ok, session} =
               Gateway.start_codex_session(setup.auth, %{
                 accepted_turn_state: "interruption-telemetry-#{unique}"
               })

      correlation_id = "interruption-telemetry-request-#{unique}"

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{
                   endpoint: "/backend-api/codex/responses",
                   transport: "websocket",
                   correlation_id: correlation_id,
                   request_metadata: %{"codex_session_id" => session.id}
                 }
               )

      attempt =
        if mode == :without_attempt do
          nil
        else
          assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

          maybe_delete_reservation_ledger_entry!(mode, reserved.request)

          attempt
        end

      request_options =
        RequestOptions.for_websocket(%{
          request_id: correlation_id,
          interrupt_reason: "client_disconnected",
          reconnect_window_seconds: 300
        })

      assert {:ok, turn} =
               SessionContinuity.start_codex_turn(session, reserved.request, request_options)

      Map.merge(setup, %{
        session: session,
        request: reserved.request,
        attempt: attempt,
        turn: turn,
        request_options: request_options,
        selected_context: selected_context(setup, reserved, attempt, request_options)
      })
    end)
  end

  defp maybe_delete_reservation_ledger_entry!(:accounting_failure, request) do
    Repo.delete_all(
      from entry in LedgerEntry,
        where: entry.source_event_id == ^"request:#{request.id}:reservation"
    )
  end

  defp maybe_delete_reservation_ledger_entry!(_mode, _request), do: :ok

  defp selected_context(setup, reserved, attempt, request_options) do
    %SelectedCandidateContext{
      auth: setup.auth,
      endpoint: "/backend-api/codex/responses",
      payload: %{"model" => setup.model.exposed_model_id},
      model: setup.model,
      reserved: reserved,
      request_options: request_options,
      route_plan: %{affinity: %{enabled?: false}, demotions: %{}},
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      attempt: attempt,
      started: System.monotonic_time(:millisecond)
    }
  end

  defp interrupt_turn(fixture) do
    Interruption.interrupt_codex_turn(fixture.session, fixture.request_options)
  end

  defp transport_finalize(fixture) do
    Finalization.finalize_failed_websocket_response(fixture.selected_context, %{
      body: "",
      headers: [],
      reason: :client_disconnected,
      started: System.monotonic_time(:millisecond)
    })
  end

  defp committed_interruption_state(fixture) do
    run_unboxed(fn ->
      %{
        request_status: Repo.get!(Request, fixture.request.id).status,
        attempt_status: fixture.attempt && Repo.get!(Attempt, fixture.attempt.id).status,
        turn_status: Repo.get!(CodexTurn, fixture.turn.id).status,
        settlement_count:
          Repo.aggregate(
            from(entry in LedgerEntry,
              where: entry.request_id == ^fixture.request.id and entry.entry_kind == "settlement"
            ),
            :count,
            :id
          )
      }
    end)
  end

  defp cleanup_committed_fixture!(fixture) do
    run_unboxed(fn ->
      Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)

      Repo.delete_all(
        from identity in UpstreamIdentity, where: identity.id == ^fixture.identity.id
      )

      Repo.delete_all(
        from pricing in CodexPooler.Catalog.PricingSnapshot,
          where: pricing.id == ^fixture.pricing.id
      )

      :ok
    end)
  end

  defp capture_outcomes(fun) do
    handler_id = "interruption-outcome-#{System.unique_integer([:positive, :monotonic])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp run_unboxed(fun) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(@task_timeout)
  end

  defp run_ordered_operations(first_fun, second_fun) do
    parent = self()
    barrier = make_ref()

    tasks =
      for {position, operation} <- [first: first_fun, second: second_fun] do
        Task.async(fn ->
          send(parent, {barrier, position, :ready})

          receive do
            {^barrier, ^position, :run} -> Sandbox.unboxed_run(Repo, operation)
          after
            @task_timeout -> flunk("#{position} interruption ordering task was not released")
          end
        end)
      end

    [first_task, second_task] = tasks

    try do
      assert_receive {^barrier, :first, :ready}, @task_timeout
      assert_receive {^barrier, :second, :ready}, @task_timeout

      send(first_task.pid, {barrier, :first, :run})
      first_result = Task.await(first_task, @task_timeout)

      send(second_task.pid, {barrier, :second, :run})
      second_result = Task.await(second_task, @task_timeout)

      [first_result, second_result]
    after
      Enum.each(tasks, fn task ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)
    end
  end
end
