defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ExhaustedPinCompactionHistoryTest do
  # A released Codex client that has compacted once keeps the provider's
  # `compaction` item at the head of every full-history request. When the
  # session's account is exhausted, the live upstream websocket used to hard-pin
  # that request to the exhausted account (`503 pinned_continuation_unavailable`,
  # then `409 duplicate_turn` on every identical resend), and the client finished
  # the turn over HTTPS on another account with the same compaction item
  # (production 2026-09-21 19:46 and 2026-09-22 07:43, findings#206 row 206-357).
  # The websocket request now moves like the HTTPS one.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  @moduletag capture_log: true

  # Failure-detection budget for the polling helper below; it returns as soon
  # as the awaited turn row settles.
  @detection_timeout_ms 15_000

  for forwarding <- [:owner_forwarding, :direct], mode <- ["full", "lite"], history_kind <- [:compaction, :agent_handoff] do
    @tag forwarding: forwarding, serving_mode: mode, history_kind: history_kind
    test "a full-history turn with #{history_kind} leaves its exhausted account over the live websocket (#{forwarding}, #{mode})",
         %{forwarding: forwarding, serving_mode: mode, history_kind: history_kind} do
      if forwarding == :owner_forwarding do
        CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
        Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
      else
        CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
        Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
      end

      sticky_upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            strict_native_request(1, completed_frames("resp_compacted_sticky_first", 3, 1))
          ])
        )

      fallback_upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            strict_native_request(1, completed_frames("resp_compacted_fallback", 5, 2))
          ])
        )

      setup = gateway_setup(sticky_upstream)
      fallback = gateway_upstream(setup.pool, fallback_upstream, "upstream-token-compacted-fallback", compact?: false)
      prime_routing_quota!(fallback.identity)
      use_routing_strategy!(setup.pool, "bridge_ring", 2)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      {_server, port} = start_public_endpoint_with_server!()
      {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
      thread_id = Ecto.UUID.generate()

      # Turn 1 binds the session to the sticky account and opens the live
      # upstream websocket there.
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, turn_payload(setup, thread_id, "compacted-opening-turn", native_text_input("synthetic opening turn")))
      {conn, websocket, _types, first_terminal} = receive_until_terminal(conn, websocket, ref, [])
      assert %{"type" => "response.completed"} = first_terminal
      [first] = pool_requests(setup.pool.id)
      await_turn_settled!(first.id)

      # The sticky account runs out and a second account becomes eligible.
      prime_exhausted_routing_quota!(setup.identity)
      put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

      {conn, websocket} =
        if history_kind == :agent_handoff do
          anchored =
            setup
            |> turn_payload(thread_id, "compacted-history-turn", [%{"type" => "custom_tool_call_output", "call_id" => "call_synthetic_patch", "output" => "synthetic result"}])
            |> CodexPooler.JSON.decode!()
            |> Map.put("previous_response_id", "resp_compacted_sticky_first")
            |> CodexPooler.JSON.encode!()

          {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, anchored)
          {conn, websocket, _types, refused} = receive_until_terminal(conn, websocket, ref, [])
          assert %{"type" => "error", "status" => 503, "error" => %{"code" => "pinned_continuation_unavailable"}} = refused
          {conn, websocket}
        else
          {conn, websocket}
        end

      # provenance: shape of the released client's full-history request after
      # one remote compaction (Codex rust-v0.156.0 `ResponseItem::Compaction`:
      # `type`, optional `id`, `encrypted_content`); content synthetic.
      portable_item = portable_item(history_kind)

      compacted_history =
        [
          portable_item,
          %{"type" => "reasoning", "encrypted_content" => "synthetic-reasoning", "content" => nil, "summary" => []}
        ] ++
          native_text_input("synthetic turn after compaction") ++
          [
            %{"type" => "custom_tool_call", "call_id" => "call_synthetic_patch", "name" => "apply_patch", "input" => "synthetic patch"},
            %{"type" => "custom_tool_call_output", "call_id" => "call_synthetic_patch", "output" => "synthetic result"}
          ]

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, turn_payload(setup, thread_id, "compacted-history-turn", compacted_history))
      {conn, _websocket, _types, terminal} = receive_until_terminal(conn, websocket, ref, [])
      Mint.HTTP.close(conn)

      assert %{"type" => "response.completed"} = terminal,
             "the compacted full-history turn must be served on the eligible account, got #{inspect(Map.take(terminal, ["type", "status", "error"]))}"

      assert FakeUpstream.count(sticky_upstream) == 1
      assert FakeUpstream.count(fallback_upstream) == 1
      assert :ok = FakeUpstream.verify!(sticky_upstream)
      assert :ok = FakeUpstream.verify!(fallback_upstream)

      # The provider receives the compaction item unchanged on the new account.
      [%{json: moved}] = FakeUpstream.requests(fallback_upstream)
      refute Map.has_key?(moved, "previous_response_id")

      assert [moved_item] = Enum.filter(moved["input"], &(&1["type"] == portable_item["type"]))
      assert Map.delete(moved_item, "id") == Map.delete(portable_item, "id")

      first_id = first.id
      assert [%Request{id: ^first_id} | later] = pool_requests(setup.pool.id)

      moved_id =
        case {history_kind, later} do
          {:compaction, [%Request{id: moved_id}]} ->
            moved_id

          {:agent_handoff, [%Request{status: "rejected", last_error_code: "pinned_continuation_unavailable"} = denied, %Request{id: moved_id}]} ->
            assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^denied.id), :count) == 0
            assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^denied.id), :count) == 0
            moved_id
        end

      await_turn_settled!(moved_id)
      moved_request = await_request_settled!(moved_id)
      assert moved_request.status == "succeeded"
      assert moved_request.transport == "websocket"
      assert moved_request.request_metadata["codex_session_id"] == first.request_metadata["codex_session_id"]
      refute Map.has_key?(moved_request.request_metadata, "continuity_denial")
      assert get_in(moved_request.request_metadata, ["routing", "model_serving_mode"]) == mode

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^moved_request.id))
      assert attempt.pool_upstream_assignment_id == fallback.assignment.id
      assert attempt.status == "succeeded"

      metadata_text = inspect({moved_request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ "synthetic-compaction-checkpoint"
      refute metadata_text =~ "synthetic-encrypted-handoff"
      refute metadata_text =~ "synthetic turn after compaction"
      refute metadata_text =~ setup.raw_key
      refute metadata_text =~ "upstream-token"
    end
  end

  defp portable_item(:compaction),
    do: %{"type" => "compaction", "id" => "cmp_synthetic_checkpoint", "encrypted_content" => "synthetic-compaction-checkpoint"}

  # Released Desktop multi-agent envelope; the ciphertext is synthetic. Its
  # full-history HTTP fallback already moves this item to another account.
  defp portable_item(:agent_handoff) do
    %{
      "type" => "agent_message",
      "author" => "/root",
      "recipient" => "/root/sample",
      "content" => [
        %{"type" => "input_text", "text" => "Message Type: NEW_TASK\nTask name: /root/sample\nSender: /root\nPayload:\n"},
        %{"type" => "encrypted_content", "encrypted_content" => "synthetic-encrypted-handoff"}
      ]
    }
  end

  # The released client's frame: its turn metadata names the thread and the
  # turn in `client_metadata` (Codex rust-v0.156.0), which is what keys the
  # request claim an identical resend meets.
  defp turn_payload(setup, thread_id, turn_id, input) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => turn_id, "request_kind" => "turn"})
      },
      "input" => input,
      "stream" => true,
      "generate" => true
    })
  end

  defp completed_frames(response_id, input_tokens, output_tokens) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "usage" => %{"input_tokens" => input_tokens, "output_tokens" => output_tokens, "total_tokens" => input_tokens + output_tokens}
        }
      })
    ])
  end

  defp pool_requests(pool_id) do
    Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))
  end

  defp receive_until_terminal(conn, websocket, ref, seen_types) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] ->
        {conn, websocket, Enum.reverse(seen_types), terminal}

      %{"type" => type} ->
        receive_until_terminal(conn, websocket, ref, [type | seen_types])
    end
  end

  defp await_request_settled!(request_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms

    case Repo.get!(Request, request_id) do
      %Request{status: status} = request when status not in ["accepted", "in_progress"] ->
        request

      %Request{status: status} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> await_request_settled!(request_id, deadline)
          end
        else
          flunk("expected the request to settle, got #{status}")
        end
    end
  end

  defp await_turn_settled!(request_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms

    case Repo.all(from(t in CodexTurn, where: t.request_id == ^request_id)) do
      [%CodexTurn{status: status} = turn] when status != "in_progress" ->
        turn

      turns ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> await_turn_settled!(request_id, deadline)
          end
        else
          flunk("expected the turn to settle, got #{inspect(Enum.map(turns, & &1.status))}")
        end
    end
  end
end
