defmodule CodexPoolerWeb.Runtime.BackendCodexOwnerCompletionDrainTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.AnchoredOwnerDrainSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @budget 15_000
  @moduletag capture_log: true

  for disposition <- [:complete, :deadline] do
    test "normal drain retains cleanup authority before caller #{disposition}" do
      {setup, upstream, state, release_ref} =
        fixture(completed_responses: Enum.map(1..7, &custom_response/1))

      Repo.insert!(%CodexPooler.Pools.ModelServingOverride{
        pool_id: setup.pool.id,
        exposed_model_id: setup.model.exposed_model_id,
        mode: "lite"
      })

      first =
        payload(setup, metadata())
        |> Map.put("tools", [
          %{"type" => "custom", "name" => "synthetic_tool", "format" => %{"type" => "text"}}
        ])

      {:ok, state} =
        CodexResponsesSocket.handle_in({CodexPooler.JSON.encode!(first), [opcode: :text]}, state)

      {_anchor, _call_id, state} = receive_custom_completed(state)
      first_owner = state.websocket_owner_pid
      WebsocketOwnerSession.begin_drain(first_owner)
      assert :ok = WebsocketOwnerSession.drain_owner(first_owner)
      state = receive_until(state, {:error, "owner_drained"})
      assert :ok = CodexResponsesSocket.terminate(:closed, state)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, state} =
        CodexResponsesSocket.init(%{
          auth: auth,
          opts: %{
            request_id: Ecto.UUID.generate(),
            accepted_turn_state: state.opts.accepted_turn_state
          }
        })

      refute state.websocket_owner_pid == first_owner

      on_exit(fn ->
        if Process.alive?(state.websocket_owner_pid),
          do: WebsocketOwnerSession.drain_owner(state.websocket_owner_pid)
      end)

      {anchor, call_id, state} =
        Enum.reduce(2..7, {nil, nil, state}, fn _, {anchor, call_id, state} ->
          next =
            first
            |> Map.put("client_metadata", %{
              "x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata())
            })

          next = if anchor, do: continuation(next, anchor, call_id), else: next

          {:ok, state} =
            CodexResponsesSocket.handle_in(
              {CodexPooler.JSON.encode!(next), [opcode: :text]},
              state
            )

          receive_custom_completed(state)
        end)

      prior_witness = :sys.get_state(state.websocket_owner_pid).termination_cleanup_witness
      continuation = continuation(first, anchor, call_id)

      {:ok, state} =
        CodexResponsesSocket.handle_in(
          {CodexPooler.JSON.encode!(continuation), [opcode: :text]},
          state
        )

      assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid,
                      ^release_ref},
                     @budget

      state = receive_until(state, "response.output_text.delta")
      assert FakeUpstream.count(upstream) == 8
      wire = List.last(FakeUpstream.requests(upstream))
      assert wire.json["previous_response_id"] == anchor

      assert [%{"type" => "custom_tool_call_output", "call_id" => ^call_id}] =
               Enum.filter(wire.json["input"], &(&1["type"] == "custom_tool_call_output"))

      owner = state.websocket_owner_pid
      [caller] = MapSet.to_list(state.tasks)
      snapshot = :sys.get_state(owner)
      witness = snapshot.active_turn.cleanup_witness
      request = Repo.get!(Request, witness.request_id)
      assert request.status == "in_progress"
      assert request.request_metadata["routing"]["model_serving_mode"] == "lite"
      assert Repo.get_by!(CodexTurn, request_id: request.id).first_visible_output_at

      assert {:error, :stale_owner_cleanup} =
               Persistence.interrupt_codex_session(
                 put_in(snapshot.active_turn.cleanup_witness, prior_witness),
                 :owner_drained
               )

      assert Repo.reload!(request).status == "in_progress"

      assert Interruption.owner_finalization_pending?(%{
               witness
               | session_id: Ecto.UUID.generate()
             })

      assert {:error, :probe_complete} =
               Repo.transaction(fn ->
                 Repo.update_all(from(r in Request, where: r.id == ^request.id),
                   set: [status: "succeeded"]
                 )

                 Repo.update_all(from(t in CodexTurn, where: t.request_id == ^request.id),
                   set: [status: "succeeded"]
                 )

                 Repo.update_all(from(a in Attempt, where: a.id == ^witness.attempt_id),
                   set: [status: "queued"]
                 )

                 assert Interruption.owner_finalization_pending?(witness)

                 Repo.update_all(from(a in Attempt, where: a.id == ^witness.attempt_id),
                   set: [status: "succeeded"]
                 )

                 refute Interruption.owner_finalization_pending?(witness)
                 Repo.rollback(:probe_complete)
               end)

      assert :erlang.suspend_process(caller)

      on_exit(fn ->
        send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
        if Process.alive?(caller), do: Process.exit(caller, :kill)
      end)

      WebsocketOwnerSession.begin_drain(owner)
      assert :sys.get_state(owner).draining?
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      state = receive_until(state, "response.completed")
      assert_receive {:websocket_owner_frame, _, _, ^caller, :complete} = complete, @budget
      {:ok, state} = CodexResponsesSocket.handle_info(complete, state)
      assert is_nil(:sys.get_state(owner).active_turn)
      assert {:ok, %{active_turn?: true}} = WebsocketOwnerSession.owner_status(owner)
      assert Repo.reload!(request).status == "in_progress"

      state =
        if unquote(disposition) == :complete do
          assert :erlang.resume_process(caller)
          state = receive_until(state, :complete)
          assert {:ok, %{active_turn?: false}} = WebsocketOwnerSession.owner_status(owner)
          state
        else
          state
        end

      owner_ref = Process.monitor(owner)
      assert :ok = WebsocketOwnerSession.drain_owner(owner)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, @budget

      assert Repo.aggregate(
               from(lease in BridgeOwnerLease,
                 where:
                   lease.codex_session_id == ^state.codex_session.id and lease.status == "active"
               ),
               :count
             ) == 0

      if unquote(disposition) == :complete do
        assert %{status: "succeeded", last_error_code: nil} = Repo.reload!(request)
        assert %{status: "succeeded"} = Repo.get_by!(CodexTurn, request_id: request.id)

        assert [%{status: "succeeded"}] =
                 Repo.all(from a in Attempt, where: a.request_id == ^request.id)
      else
        assert %{
                 status: "failed",
                 last_error_code: "owner_drained",
                 usage_status: "usage_unknown"
               } = Repo.reload!(request)

        assert %{status: "interrupted"} = Repo.get_by!(CodexTurn, request_id: request.id)

        assert [%{status: "failed"}] =
                 Repo.all(from a in Attempt, where: a.request_id == ^request.id)

        caller_ref = Process.monitor(caller)
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @budget
      end

      assert :ok = CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp continuation(first, anchor, call_id),
    do:
      Map.merge(first, %{
        "previous_response_id" => anchor,
        "input" => [
          %{"type" => "custom_tool_call_output", "call_id" => call_id, "output" => "ok"}
        ]
      })

  defp custom_response(index) do
    item = %{
      "type" => "custom_tool_call",
      "id" => "ct_synthetic_#{index}",
      "call_id" => "call_synthetic_#{index}",
      "name" => "synthetic_tool",
      "input" => "synthetic",
      "status" => "completed"
    }

    FakeUpstream.sse_stream([
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_synthetic_completed_#{index}",
          "object" => "response",
          "status" => "completed",
          "output" => [item]
        }
      }
    ])
  end

  defp receive_custom_completed(state) do
    {event, state} = receive_until(state, {:event, "response.output_item.done"})
    assert %{"item" => %{"type" => "custom_tool_call", "call_id" => call_id} = item} = event
    {event, state} = receive_until(state, {:event, "response.completed"})
    assert event["response"]["output"] == [item]
    {event["response"]["id"], call_id, receive_until(state, :complete)}
  end
end
