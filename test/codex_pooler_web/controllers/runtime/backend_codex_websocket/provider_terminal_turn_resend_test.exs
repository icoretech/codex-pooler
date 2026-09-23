defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ProviderTerminalTurnResendTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  # Detection budget for a settlement the test only observes.
  @settlement_detection_timeout_ms 15_000

  # findings#121 variant B, findings#232 row 232-280: the provider ends the
  # opening request of a turn with `response.failed` `server_error` (here after
  # a visible text delta, and with none). The released client (Codex
  # `rust-v0.156.1`) treats it as retryable, drops the connection and resends
  # the same turn on a new one. With owner forwarding on the owner's
  # client-retry preflight admits the resend; with forwarding off the resend is
  # judged on its turn claim, where a provider-terminal predecessor was never
  # admitted, so every resend met `409 duplicate_turn` and the client finished
  # the turn over HTTPS. Frames carry the released client's turn metadata;
  # identifiers, prompt text and reply frames are synthetic. Full serving mode
  # (the fake catalog model), one node.
  for forwarding? <- [false, true], visible? <- [true, false] do
    test "a provider server_error on a turn's opening request admits the client's resend on a new socket as one successor (owner forwarding #{forwarding?}, visible output #{visible?})" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(forwarding?))

      input = native_text_input("provider terminal")

      upstream =
        start_upstream(
          # The opening request fails at the provider; its resend completes.
          # Nothing else reaches the provider.
          # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error); reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
              respond: provider_failure_frames(unquote(visible?))
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
              respond: completed_frames("resp_ws_provider_terminal_resend")
            )
          ])
        )

      setup = gateway_setup(upstream)
      assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
      port = start_public_endpoint!()
      thread = "ws-provider-terminal-#{System.unique_integer([:positive])}"
      frame = released_client_frame(setup, thread, Ecto.UUID.generate(), input)
      {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
        {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
        assert %{"type" => "response.failed", "response" => %{"error" => %{"code" => "server_error"}}} = failure
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @settlement_detection_timeout_ms

        # The released client drops the connection after the failure and
        # resends the same request on a new one.
        Mint.HTTP.close(conn)
        {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
        {conn, _websocket, terminal} = receive_until_terminal(conn, websocket, ref)
        assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_provider_terminal_resend"}} = terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @settlement_detection_timeout_ms

        assert [failed, resend] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))
        assert {failed.status, failed.last_error_code, resend.status} == {"failed", "server_error", "succeeded"}
        assert linked_successor?(failed, resend)

        for row <- [failed, resend] do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        assert FakeUpstream.http_request_count(upstream) == 0
        assert :ok = FakeUpstream.verify!(upstream)
        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # A `response.create` shaped like the released client's opening request of a
  # turn: its turn metadata names the thread and the turn, so the resend is
  # judged on the turn claim.
  defp released_client_frame(setup, thread, turn_id, input) do
    metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id}

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "generate" => true,
      "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", CodexPooler.JSON.encode!(Map.put(metadata, "request_kind", "turn")))
    })
  end

  # The resend is admitted as the failed request's one successor: through the
  # owner's client-retry preflight (a retry link) or on its turn claim (the
  # predecessor recorded on the resend).
  defp linked_successor?(%Request{id: failed_id}, %Request{id: resend_id} = resend) do
    resend.request_metadata["client_resend"]["predecessor_request_id"] == failed_id or
      Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^failed_id and link.successor_request_id == ^resend_id))
  end

  defp provider_failure_frames(visible?) do
    response_id = "resp_ws_provider_terminal_failed"
    created = CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}})
    delta = CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "item_id" => "msg_provider_terminal", "output_index" => 0, "content_index" => 0, "delta" => "synthetic partial"})

    failed =
      CodexPooler.JSON.encode!(%{
        "type" => "response.failed",
        "response" => %{"id" => response_id, "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}
      })

    FakeUpstream.websocket_text_frames(if(visible?, do: [created, delta, failed], else: [created, failed]))
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}}
      })
    ])
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_until_terminal(conn, websocket, ref)
    end
  end
end
