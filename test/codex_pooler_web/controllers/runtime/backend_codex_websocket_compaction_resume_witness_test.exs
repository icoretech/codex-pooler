defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionResumeWitnessTest do
  # The production shape of the findings#225 witness gap (row 225-86): a
  # mid-turn websocket compaction admitted through the native compaction
  # admission, then the resume of the SAME turn. The resume carries the
  # compaction's turn_id, so it is not an explicit turn claim: it is admitted by
  # redeeming the runtime proof the prepared frame was sealed with, which minted
  # a UUID correlation and took no turn claim (row 225-87 made it take the
  # durable resume claim as well). Until 8d999798 that reservation
  # insert stored no native client-retry witness, so an identical resend of an
  # interrupted resume could only be refused as `missing_witness`. The existing
  # final-frame witness assertion sends a new turn_id and takes the claim path
  # instead, which never had the gap.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Dev.NativeCompactionAuthorizationObserver
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  # The released client names its thread in the turn metadata; the duplicate
  # turn claim is scoped on it (findings#250), and the compaction admission must
  # derive the same turn key or the mid-turn compaction fails `binding_mismatch`
  # (row 225-90). Both shapes are kept.
  for topology <- [:direct, :forwarded], thread <- [:without_thread_id, :with_thread_id] do
    @tag slow: "drives an anchor turn, a mid-turn compaction and its resume through the real public listener (0.3-0.6 s alone, over 1 s under partition load)"
    test "#{topology} resume of a mid-turn compaction with the same turn_id stores its retry witness (#{thread})" do
      assert_resume_witness(unquote(topology), unquote(thread) == :with_thread_id)
    end
  end

  defp assert_resume_witness(topology, thread?) do
    put_owner_forwarding!(topology == :forwarded)
    :ok = NativeCompactionAuthorizationObserver.arm()
    on_exit(fn -> NativeCompactionAuthorizationObserver.disarm() end)

    turn = "resume-witness-#{topology}-#{System.unique_integer([:positive])}"
    thread = if thread?, do: "thread-#{turn}"
    context = "00000000-0000-4000-8000-000000000a01"
    item = %{"type" => "compaction", "encrypted_content" => "synthetic-resume-witness"}

    upstream =
      start_upstream(
        # Strict finite scenario: the anchor turn, the mid-turn compact and the
        # resume of the same turn are the only sends.
        # provenance: synthetic, shaped after the released Codex client's remote compaction v2 request
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
            respond: completed_frames("resp_resume_witness_anchor")
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_resume_witness_anchor",
                "input.0.type" => "function_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{"id" => "resp_resume_witness_compact", "status" => "completed", "output" => [item]}
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
            respond: completed_frames("resp_resume_witness_final")
          )
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "resume-witness-upgrade", "/backend-api/codex/responses")

    try do
      anchor = frame(setup, %{"input" => [%{"type" => "message", "role" => "user", "content" => "anchor"}]}, turn_metadata(turn, thread, context, 1, :turn))
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, anchor)
      {conn, websocket, _created} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, _completed} = public_websocket_receive_text!(conn, websocket, ref)

      compact =
        frame(
          setup,
          %{
            "previous_response_id" => "resp_resume_witness_anchor",
            "input" => [
              %{"type" => "function_call_output", "call_id" => "synthetic", "output" => "ok"},
              %{"type" => "compaction_trigger"}
            ]
          },
          turn_metadata(turn, thread, context, 1, :compaction)
        )

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, compact)
      {conn, websocket, _done} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, _compacted} = public_websocket_receive_text!(conn, websocket, ref)

      # The released client resumes the same turn after a remote compaction:
      # same turn_id, the window advanced, the compacted history as input.
      resume = frame(setup, %{"input" => [item]}, turn_metadata(turn, thread, "00000000-0000-4000-8000-000000000a02", 2, :turn))
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, resume)
      {conn, websocket, created} = public_websocket_receive_text!(conn, websocket, ref)
      {_conn, _websocket, completed} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_resume_witness_final"}} = CodexPooler.JSON.decode!(completed)

      # The resume took the native-compaction runtime-proof admission, not a turn claim.
      counts = NativeCompactionAuthorizationObserver.captures()["counts"]
      assert counts["final_runtime_proof_redeemed"] == 1

      assert [anchor_row, compact_row, resume_row] =
               settled_pool_requests!(setup.pool.id, 3)

      assert String.starts_with?(anchor_row.correlation_id, "codex-")
      assert compact_row.endpoint == "/backend-api/codex/responses/compact"
      assert resume_row.endpoint == "/backend-api/codex/responses"
      assert resume_row.transport == "websocket"
      # Admitted by the runtime proof, and since row 225-87 it also holds the
      # durable resume claim an identical resend meets (it was a bare UUID).
      assert String.starts_with?(resume_row.correlation_id, "codex-resume:")

      [compact_turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^compact_row.id))
      [resume_turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^resume_row.id))
      assert byte_size(resume_turn.semantic_turn_digest) == 32
      assert resume_turn.semantic_turn_digest == compact_turn.semantic_turn_digest

      # The witness an identical resend of this resume is judged by.
      assert resume_row.native_client_retry_version == 1
      assert byte_size(resume_row.native_client_retry_digest) == 32
      assert resume_row.native_client_retry_auth_epoch == setup.api_key.runtime_revocation_epoch

      assert :ok = FakeUpstream.verify!(upstream)
    after
      Mint.HTTP.close(conn)
    end
  end

  # The resume's response task settles it after the terminal frame reaches the
  # client, in a transaction on the shared sandbox connection, so reading the
  # rows right after the frame can queue behind it. No completion signal
  # reaches the test, so wait, within a bounded detection budget, for the
  # resume to be settled before reading.
  @settlement_budget_ms 15_000

  defp settled_pool_requests!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + @settlement_budget_ms
    await_settled_pool_requests(pool_id, count, deadline)
  end

  defp await_settled_pool_requests(pool_id, count, deadline) do
    rows =
      try do
        Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at, asc: r.id]))
      rescue
        DBConnection.ConnectionError -> :busy
      end

    cond do
      is_list(rows) and length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) ->
        rows

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{count} settled requests, got #{inspect(if is_list(rows), do: Enum.map(rows, & &1.status), else: rows)}")

      true ->
        Process.sleep(10)
        await_settled_pool_requests(pool_id, count, deadline)
    end
  end

  defp frame(setup, fields, metadata) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "stream" => true, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}
    |> Map.merge(fields)
    |> CodexPooler.JSON.encode!()
  end

  defp turn_metadata(turn_id, thread, context_window_id, window_number, kind) do
    base = %{
      "turn_id" => turn_id,
      # The released client names the window `<thread_id>:<window_number>`, so
      # the window id changes with the number a remote compaction advances.
      "window_id" => "thread-#{turn_id}:#{window_number}",
      "context_window_id" => context_window_id,
      "window_number" => window_number,
      "request_kind" => Atom.to_string(kind)
    }

    base
    |> then(&if thread, do: Map.put(&1, "thread_id", thread), else: &1)
    |> then(fn metadata ->
      if kind == :compaction,
        do:
          Map.put(metadata, "compaction", %{
            "trigger" => "auto",
            "reason" => "context_limit",
            "implementation" => "responses_compaction_v2",
            "phase" => "mid_turn",
            "strategy" => "memento"
          }),
        else: metadata
    end)
    |> CodexPooler.JSON.encode!()
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        }
      })
    ])
  end

  defp put_owner_forwarding!(enabled?) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)

    on_exit(fn ->
      stop_owner_sessions()

      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)
  end

  defp stop_owner_sessions do
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

          assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason}, @detection_timeout_ms

        {:error, :owner_unavailable} ->
          :ok
      end
    end)
  end
end
