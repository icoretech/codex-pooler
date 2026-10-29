defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionPendingOwnerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket.DirectCleanup

  defp fixture do
    task = self()
    ref = make_ref()
    capability = make_ref()
    event = %{request_id: Ecto.UUID.generate(), attempt_id: Ecto.UUID.generate(), upstream_pid: self(), token: make_ref(), sequence: 1, remaining_ms: 1_000}
    context = %DirectCleanup{registry: self(), task: task, ref: make_ref(), parent: self(), session_id: Ecto.UUID.generate()}
    downstream = %{pid: self(), owner_turn_id: task, correlation_id: "synthetic", epoch: 1}
    active = %{ref: ref, writer_capability: capability, collect?: true, terminal_forwarded?: false, task_settled?: false, pending_result: nil, compaction_pending_context: context, downstream: downstream, upstream_pid: self(), admission_request_id: event.request_id, admission_attempt_id: event.attempt_id, compaction_pending_sequence: 0, compaction_pending_probe: nil}
    state = %WebsocketOwnerSession{draining?: false, active_turn: active, downstream: downstream}
    {event, context, state}
  end

  test "owner routes the exact bound pulse and challenge without producing a frame" do
    {event, context, state} = fixture()
    assert {:noreply, next} = WebsocketOwnerSession.handle_info({:owner_compaction_pending, state.active_turn.ref, state.active_turn.writer_capability, event}, state)
    assert_receive {:native_compaction_pending, task, ref, source, ^event}
    assert {task, ref} == {context.task, context.ref}
    challenge = make_ref()
    assert {:noreply, pending} = WebsocketOwnerSession.handle_info({:owner_compaction_pending_probe, task, ref, source, event, challenge, self()}, next)
    assert_receive {:compaction_pending_probe, receiver, ^challenge, token, request_id, attempt_id, sequence}
    assert receiver == self()
    ack = {:compaction_pending_ack, challenge, token, request_id, attempt_id, sequence, 900}
    assert {:noreply, confirmed} = WebsocketOwnerSession.handle_info(ack, pending)
    assert_receive ^ack
    assert confirmed.active_turn.compaction_pending_probe == nil
    refute_received {:websocket_owner_frame, _, _, _, _}
  end

  test "drain cancellation terminal stale downstream and wrong binding suppress pulses" do
    {event, _context, state} = fixture()
    message = {:owner_compaction_pending, state.active_turn.ref, state.active_turn.writer_capability, event}

    for candidate <- [
          %{state | draining?: true},
          put_in(state.active_turn.terminal_forwarded?, true),
          put_in(state.active_turn.task_settled?, true),
          put_in(state.active_turn.collect?, false),
          put_in(state.downstream.epoch, 2),
          put_in(state.active_turn.admission_attempt_id, Ecto.UUID.generate()),
          %{state | active_turn: Map.put(state.active_turn, :canceled_result, {:error, :cancelled})},
          %{state | active_turn: nil}
        ] do
      assert {:noreply, ^candidate} = WebsocketOwnerSession.handle_info(message, candidate)
      refute_received {:native_compaction_pending, _, _, _, _}
    end

    assert {:noreply, ^state} = WebsocketOwnerSession.handle_info({:owner_compaction_pending, state.active_turn.ref, make_ref(), event}, state)
    refute_received {:native_compaction_pending, _, _, _, _}
  end

  test "a challenge acknowledgement after owner state changed cannot reach the socket" do
    {event, context, state} = fixture()
    challenge = make_ref()
    probe = %{challenge: challenge, caller: self(), event: event, started_at: System.monotonic_time(:millisecond)}
    state = put_in(state.active_turn.compaction_pending_probe, probe)
    ack = {:compaction_pending_ack, challenge, event.token, event.request_id, event.attempt_id, event.sequence, 900}

    for candidate <- [%{state | draining?: true}, put_in(state.downstream.epoch, 2), %{state | active_turn: nil}, put_in(state.active_turn.compaction_pending_probe.started_at, System.monotonic_time(:millisecond) - 1_001)] do
      assert {:noreply, ^candidate} = WebsocketOwnerSession.handle_info(ack, candidate)
      refute_received ^ack
    end

    assert context.parent == self()
  end
end
