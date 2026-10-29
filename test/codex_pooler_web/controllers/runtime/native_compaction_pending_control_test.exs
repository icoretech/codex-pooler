defmodule CodexPoolerWeb.Runtime.NativeCompactionPendingControlTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Websocket.DownstreamProgress
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketDownstreamWriteWatch

  defp fixture do
    task = self()
    ref = make_ref()
    event = %{request_id: Ecto.UUID.generate(), attempt_id: Ecto.UUID.generate(), upstream_pid: self(), token: make_ref(), sequence: 1, remaining_ms: 1_000}

    state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task]),
      direct_cleanup_contexts: %{task => %{ref: ref}},
      response_task_compaction_collectors: MapSet.new([task]),
      downstream_delivery_evidence: %{}
    }

    {task, ref, event, state}
  end

  defp challenge(task, ref, event, state) do
    assert {:ok, next} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, ref, :direct, event}, state)
    assert_receive {:compaction_pending_probe, receiver, challenge, token, request_id, attempt_id, sequence}
    assert receiver == self()
    assert {token, request_id, attempt_id, sequence} == {event.token, event.request_id, event.attempt_id, event.sequence}
    {next, {:compaction_pending_ack, challenge, token, request_id, attempt_id, sequence, event.remaining_ms}}
  end

  test "fresh live challenge produces control without response output or receipts" do
    {task, ref, event, state} = fixture()
    {next, ack} = challenge(task, ref, event, state)
    assert {:push, {:text, control}, next} = CodexResponsesSocket.handle_info(ack, next)
    assert CodexPooler.JSON.decode!(control) == %{"type" => "codex.compaction.pending"}
    assert next.downstream_delivery_evidence == %{}
    assert Map.get(next, :native_turn_output_task_pids, MapSet.new()) == MapSet.new()
    assert Map.get(next, :response_task_terminals_accepted, MapSet.new()) == MapSet.new()
    assert {:ok, ^next} = CodexResponsesSocket.handle_info(ack, next)
  end

  test "unbound, noncompact, revoked, terminal and stale owner pulses never challenge" do
    {task, ref, event, state} = fixture()

    for {candidate_ref, source, candidate} <- [
          {make_ref(), :direct, state},
          {ref, :direct, %{state | tasks: MapSet.new()}},
          {ref, :direct, %{state | response_task_compaction_collectors: MapSet.new()}},
          {ref, :direct, Map.put(state, :api_key_revoked?, true)},
          {ref, :direct, put_in(state.opts.openai_compatibility.public_openai_responses_stream, true)},
          {ref, :direct, Map.put(state, :response_task_terminals_accepted, MapSet.new([task]))},
          {ref, {self(), "synthetic", 2}, state}
        ] do
      assert {:ok, ^candidate} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, candidate_ref, source, event}, candidate)
      refute_received {:compaction_pending_probe, _, _, _, _, _, _}
    end
  end

  test "late acknowledgement, terminal winner and replaced capability cannot push" do
    {task, ref, event, state} = fixture()
    {next, ack} = challenge(task, ref, event, state)
    late = put_in(next.native_compaction_pending[task].started_at, System.monotonic_time(:millisecond) - 1_001)
    terminal = Map.put(next, :response_task_terminals_accepted, MapSet.new([task]))
    replaced = put_in(next.direct_cleanup_contexts[task].ref, make_ref())

    for candidate <- [late, terminal, replaced] do
      assert {:ok, ^candidate} = CodexResponsesSocket.handle_info(ack, candidate)
    end
  end

  test "duplicate sequence and foreign upstream binding never renew a challenge" do
    {task, ref, event, state} = fixture()
    {next, _ack} = challenge(task, ref, event, state)

    for candidate <- [event, %{event | token: make_ref(), sequence: 2}, %{event | attempt_id: Ecto.UUID.generate(), sequence: 2}] do
      assert {:ok, ^next} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, ref, :direct, candidate}, next)
      refute_received {:compaction_pending_probe, _, _, _, _, _, _}
    end
  end

  test "owner pending progress is confirmed only after a successful control write" do
    {task, ref, event, state} = fixture()
    source = {self(), "synthetic", 1}
    state = Map.merge(state, %{websocket_owner_pid: self(), websocket_owner_downstream: %{epoch: 1, correlation_id: "synthetic"}})
    assert {:ok, waiting} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, ref, source, event}, state)
    assert_receive {:owner_compaction_pending_probe, ^task, ^ref, ^source, ^event, challenge, receiver}
    assert receiver == self()
    ack = {:compaction_pending_ack, challenge, event.token, event.request_id, event.attempt_id, event.sequence, 500}
    assert {:push, {:text, _control}, pushed} = CodexResponsesSocket.handle_info(ack, waiting)
    assert DownstreamProgress.drain_budget(1_000) == nil
    assert_receive {:compaction_pending_written, ^task, token, sequence}
    assert {:push, {:ping, ""}, confirmed} = CodexResponsesSocket.handle_info({:compaction_pending_written, task, token, sequence}, pushed)
    budget = DownstreamProgress.drain_budget(1_000)
    assert budget > 0 and budget <= 500
    assert {:ok, ^confirmed} = CodexResponsesSocket.handle_info({:compaction_pending_written, task, token, sequence}, confirmed)
    assert DownstreamProgress.drain_budget(1_000) == nil

    expired = put_in(pushed.native_compaction_pending[task].deadline, System.monotonic_time(:millisecond) - 1)
    assert {:ok, ^expired} = CodexResponsesSocket.handle_info({:compaction_pending_written, task, token, sequence}, expired)
    assert DownstreamProgress.drain_budget(1_000) == nil
  end

  test "a failed control write neither pings nor renews an owner wait" do
    {task, ref, event, state} = fixture()
    source = {self(), "synthetic", 1}
    state = Map.merge(state, %{websocket_owner_pid: self(), websocket_owner_downstream: %{epoch: 1, correlation_id: "synthetic"}})
    assert {:ok, waiting} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, ref, source, event}, state)
    assert_receive {:owner_compaction_pending_probe, ^task, ^ref, ^source, ^event, challenge, _receiver}
    ack = {:compaction_pending_ack, challenge, event.token, event.request_id, event.attempt_id, event.sequence, 500}
    assert {:push, {:text, _control}, pushed} = CodexResponsesSocket.handle_info(ack, waiting)
    :ok = WebsocketDownstreamWriteWatch.watch()
    :ok = WebsocketDownstreamWriteWatch.handle_event([:thousand_island, :connection, :send_error], %{error: :closed}, %{}, :ok)
    assert_receive {:compaction_pending_written, ^task, token, sequence}
    assert {:ok, ^pushed} = CodexResponsesSocket.handle_info({:compaction_pending_written, task, token, sequence}, pushed)
    assert DownstreamProgress.drain_budget(1_000) == nil
  end

  test "only a trusted attempt receipt rebinds pending controls within one response task" do
    {task, ref, event, state} = fixture()
    context = %DirectCleanup{registry: self(), task: task, ref: ref, parent: self(), session_id: Ecto.UUID.generate()}
    state = put_in(state.direct_cleanup_contexts[task], context)
    receipt = %{session_id: context.session_id, request_id: event.request_id, attempt_id: event.attempt_id}
    assert {:ok, state} = CodexResponsesSocket.handle_info({:direct_request_cleanup, task, ref, receipt}, state)
    {pending, old_ack} = challenge(task, ref, event, state)
    successor = %{event | attempt_id: Ecto.UUID.generate(), token: make_ref()}
    next_receipt = %{receipt | attempt_id: successor.attempt_id}
    assert {:ok, ^pending} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, ref, :direct, successor}, pending)
    assert {:ok, ^pending} = CodexResponsesSocket.handle_info({:direct_request_cleanup, task, make_ref(), next_receipt}, pending)
    assert {:ok, rebound} = CodexResponsesSocket.handle_info({:direct_request_cleanup, task, ref, next_receipt}, pending)
    assert {:ok, ^rebound} = CodexResponsesSocket.handle_info(old_ack, rebound)
    assert {:ok, ^rebound} = CodexResponsesSocket.handle_info({:native_compaction_pending, task, ref, :direct, event}, rebound)
    {current, ack} = challenge(task, ref, successor, rebound)
    assert {:push, {:text, _control}, _state} = CodexResponsesSocket.handle_info(ack, current)
  end
end
