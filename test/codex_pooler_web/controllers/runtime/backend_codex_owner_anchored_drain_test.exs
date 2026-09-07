defmodule CodexPoolerWeb.Runtime.BackendCodexOwnerAnchoredDrainTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.AnchoredOwnerDrainSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.OwnerDrainDeliveryProbe

  @budget 15_000
  @moduletag capture_log: true

  test "visible anchored continuation drains before its retry without orphaning lifecycle rows" do
    {setup, upstream, state, release_ref} = fixture()
    metadata = metadata()
    first = payload(setup, metadata)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {CodexPooler.JSON.encode!(first), [opcode: :text]},
               state
             )

    {anchor, call_id, state} = receive_completed_tool(state)
    assert FakeUpstream.count(upstream) == 1

    continuation =
      Map.merge(first, %{
        "previous_response_id" => anchor,
        "input" => [
          %{"type" => "function_call_output", "call_id" => call_id, "output" => "ok"}
        ]
      })

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {CodexPooler.JSON.encode!(continuation), [opcode: :text]},
               state
             )

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   @budget

    on_exit(fn -> send(upstream_pid, {:fake_upstream_release_timeout, release_ref}) end)
    state = receive_until(state, "response.output_text.delta")
    assert [_, wire] = FakeUpstream.requests(upstream)
    assert wire.json["previous_response_id"] == continuation["previous_response_id"]
    assert [%{"type" => "function_call_output", "call_id" => ^call_id}] = wire.json["input"]

    assert [request] =
             Repo.all(
               from r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress"
             )

    assert %{first_visible_output_at: visible, status: "in_progress"} =
             Repo.get_by!(CodexTurn, request_id: request.id)

    refute is_nil(visible)

    assert [%{status: "in_progress"}] =
             Repo.all(from a in Attempt, where: a.request_id == ^request.id)

    assert_active_semantic_constraint(setup, state, request)

    assert_raise ExUnit.AssertionError,
                 ~r/owner drain has not terminalized the visible request/,
                 fn ->
                   assert_terminal_request(request)
                 end

    owner = state.websocket_owner_pid
    [response_task] = MapSet.to_list(state.tasks)
    task_ref = Process.monitor(response_task)
    assert_rejected_cleanup(owner, request)
    owner_ref = Process.monitor(owner)
    drain_after_commit(owner, response_task, request)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, @budget
    state = receive_until(state, {:error, "owner_drained"})
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert_receive {:DOWN, ^task_ref, :process, ^response_task, _}, @budget
    assert_terminal_request(request)

    assert %{status: "interrupted", first_visible_output_at: ^visible} =
             Repo.get_by!(CodexTurn, request_id: request.id)

    assert [%{status: "failed"}] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)

    assert Enum.sort(
             Repo.all(
               from e in LedgerEntry, where: e.request_id == ^request.id, select: e.entry_kind
             )
           ) == ["release", "reservation", "settlement"]

    assert Repo.aggregate(
             from(l in BridgeOwnerLease,
               where: l.codex_session_id == ^state.codex_session.id and l.status == "active"
             ),
             :count
           ) == 0

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, retry} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: Ecto.UUID.generate(),
          accepted_turn_state: state.opts.accepted_turn_state
        }
      })

    on_exit(fn ->
      if Process.alive?(retry.websocket_owner_pid),
        do: WebsocketOwnerSession.drain_owner(retry.websocket_owner_pid)
    end)

    assert {:ok, retry} =
             CodexResponsesSocket.handle_in(
               {CodexPooler.JSON.encode!(continuation), [opcode: :text]},
               retry
             )

    retry = receive_until(retry, {:error, "duplicate_turn"})
    assert :ok = CodexResponsesSocket.terminate(:closed, retry)
    assert FakeUpstream.count(upstream) == 2

    assert Repo.aggregate(
             from(r in Request,
               where: r.pool_id == ^setup.pool.id and r.status in ["accepted", "in_progress"]
             ),
             :count
           ) == 0
  end

  test "removing the continuation anchor fails the anchored wire witness" do
    {setup, upstream, state, release_ref} = fixture()
    first = payload(setup, metadata())

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {CodexPooler.JSON.encode!(first), [opcode: :text]},
               state
             )

    {_anchor, call_id, state} = receive_completed_tool(state)

    unanchored =
      Map.put(first, "input", [
        %{"type" => "function_call_output", "call_id" => call_id, "output" => "ok"}
      ])

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {CodexPooler.JSON.encode!(unanchored), [opcode: :text]},
               state
             )

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   @budget

    on_exit(fn -> send(upstream_pid, {:fake_upstream_release_timeout, release_ref}) end)
    state = receive_until(state, "response.output_text.delta")
    assert [_, wire] = FakeUpstream.requests(upstream)

    assert_raise ExUnit.AssertionError, ~r/missing anchored upstream dispatch/, fn ->
      assert_wire_anchor(wire)
    end

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    state = receive_until(state, :complete)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert FakeUpstream.count(upstream) == 2

    assert Repo.aggregate(
             from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "succeeded"),
             :count
           ) == 2

    assert Repo.aggregate(
             from(t in CodexTurn,
               join: r in Request,
               on: t.request_id == r.id,
               where: r.pool_id == ^setup.pool.id and t.status == "in_progress"
             ),
             :count
           ) == 0
  end

  defp assert_wire_anchor(wire) do
    assert wire.json["previous_response_id"] == "resp_synthetic_anchor_completed",
           "missing anchored upstream dispatch"
  end

  test "notification witness rejects early task completion and both owner frame shapes" do
    observer = self()

    sink =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(sink, :kill) end)

    for shape <- [:task, :frame, :tagged_frame, :reply] do
      producer =
        spawn(fn ->
          receive do
            :emit ->
              message = early_notification(shape)
              send(sink, message)
              send(observer, {:early_notification_sent, self()})

              receive do
                :stop -> :ok
              end
          end
        end)

      on_exit(fn -> Process.exit(producer, :kill) end)
      :ok = OwnerDrainDeliveryProbe.trace([producer])
      send(producer, :emit)
      assert_receive {:early_notification_sent, ^producer}, @budget

      assert_raise ExUnit.AssertionError,
                   ~r/terminal notification escaped before cleanup commit release/,
                   fn ->
                     OwnerDrainDeliveryProbe.assert_no_terminal([producer])
                   end

      send(producer, :stop)
    end
  end

  defp early_notification(:task), do: {:codex_response_done, self(), {:error, :owner_drained}}

  defp early_notification(:frame),
    do: {:websocket_owner_frame, "synthetic", 1, {:error, :owner_drained, %{}}}

  defp early_notification(:tagged_frame),
    do: {:websocket_owner_frame, "synthetic", 1, self(), {:error, :owner_drained, %{}}}

  defp early_notification(:reply),
    do: {make_ref(), {:websocket_owner_submission_accepted, {:error, :owner_drained}}}

  defp assert_terminal_request(request) do
    assert match?(%{status: "failed", last_error_code: "owner_drained"}, Repo.reload!(request)),
           "owner drain has not terminalized the visible request"
  end

  defp assert_rejected_cleanup(owner, request) do
    snapshot = :sys.get_state(owner)
    invalid = put_in(snapshot.active_turn.cleanup_witness.owner_lease_token, Ecto.UUID.generate())

    assert {:error, :stale_owner_cleanup} =
             Persistence.interrupt_codex_session(invalid, :owner_drained)

    assert_raise ExUnit.AssertionError,
                 ~r/owner drain has not terminalized the visible request/,
                 fn ->
                   assert_terminal_request(request)
                 end

    assert Repo.all(
             from e in LedgerEntry, where: e.request_id == ^request.id, select: e.entry_kind
           ) == ["reservation"]
  end

  defp drain_after_commit(owner, response_task, request) do
    observer = self()
    barrier = make_ref()
    :ok = OwnerDrainDeliveryProbe.trace([owner, response_task])

    :ok =
      :telemetry.attach(
        barrier,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner, do: hold_cleanup_commit(metadata.query, observer, barrier)
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(barrier)
      send(owner, {:release_cleanup_commit, barrier})
    end)

    drain = Task.async(fn -> WebsocketOwnerSession.drain_owner(owner) end)
    assert_receive {:owner_cleanup_committed, ^owner, ^barrier}, @budget
    assert_terminal_request(request)
    :ok = OwnerDrainDeliveryProbe.assert_no_terminal([owner, response_task])
    send(owner, {:release_cleanup_commit, barrier})
    assert :ok = Task.await(drain, @budget)
    :telemetry.detach(barrier)
  end

  defp hold_cleanup_commit(query, observer, barrier) do
    if String.starts_with?(query, "UPDATE \"requests\""), do: Process.put(barrier, :updated)

    if String.downcase(query) == "commit" and Process.delete(barrier) == :updated do
      send(observer, {:owner_cleanup_committed, self(), barrier})

      receive do
        {:release_cleanup_commit, ^barrier} -> :ok
      after
        @budget -> raise "owner cleanup commit barrier timeout"
      end
    end
  end

  defp assert_active_semantic_constraint(setup, state, request) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn = Repo.get_by!(CodexTurn, request_id: request.id)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          {:ok, reserved} =
            Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{
              endpoint: "/backend-api/codex/responses",
              transport: "websocket",
              correlation_id: Ecto.UUID.generate()
            })

          Gateway.start_codex_turn(state.codex_session, reserved.request, %{
            semantic_turn_key: turn.semantic_turn_digest
          })
        end)
      end

    assert error.postgres.code == :unique_violation
    assert error.postgres.constraint == "codex_turns_active_semantic_turn_uq"
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    assert Repo.reload!(turn) == turn
  end
end
