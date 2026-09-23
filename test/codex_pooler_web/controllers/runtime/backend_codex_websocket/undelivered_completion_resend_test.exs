defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.UndeliveredCompletionResendTest do
  # A native websocket turn the provider completed after its client was already
  # gone: the socket acknowledged it aborted and pushed nothing of it, not even a
  # lifecycle event, so its receipt reads `outcome=aborted terminal_class=none
  # frames_after_visible=0`. The answer was billed, the client saw nothing and
  # resent the same request, and every resend (five on the websocket, six over
  # HTTPS) was refused `409 duplicate_turn`: the turn failed (findings#232 row
  # 232-201, production 1 of 11 first-frame cuts, and locally with the released Codex client
  # whenever the provider answered before the closing socket reached its owner).
  # The resend is now admitted as one successor, a new dispatch as a direct
  # connection would make; each request keeps its single settlement.
  #
  # The first turn runs through the real listener; only its receipt is rewritten
  # to the production shape, because which side wins that race is timing on the
  # real path. The unrewritten receipt is the control: a turn the socket pushed
  # stays refused.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, stop_registered_websocket_owner_sessions: 0, strict_native_request: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @timeout_ms 15_000
  # provenance: observed findings#232 row 232-201 (production receipt of request fdc13999, rev 25)
  @undelivered %{"outcome" => "aborted", "terminal_class" => "none", "frames_after_visible" => 0, "pushed_at" => nil, "transport" => "websocket"}

  for forwarding <- [true, false] do
    @tag :websocket_direct
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: the resend of a completed turn the socket pushed nothing of is served as one successor", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :undelivered)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)

      for id <- [request_id, successor_id] do
        assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
                 %{"reservation" => 1, "settlement" => 1, "release" => 1}
      end

      assert FakeUpstream.count(upstream) == 2
    end

    @tag :websocket_direct
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: the resend of a completed turn the socket pushed stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :delivered)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert FakeUpstream.count(upstream) == 1
    end
  end

  defp scenario!(forwarding, receipt) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
    if forwarding, do: on_exit(&stop_registered_websocket_owner_sessions/0)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.websocket_text_frames([completed_frame("resp_undelivered_original")])),
          # The owner keeps its upstream connection; a direct socket opens its own.
          strict_native_request(if(forwarding, do: 1, else: 2), FakeUpstream.websocket_text_frames([completed_frame("resp_undelivered_successor")]))
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    turn_state = Ecto.UUID.generate()
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
    port = start_public_endpoint!()

    assert %{"type" => "response.completed"} = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
    assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
    assert [%Attempt{id: attempt_id}] = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    if receipt == :undelivered do
      {1, _rows} =
        Repo.update_all(
          from(a in Attempt, where: a.id == ^attempt_id, update: [set: [response_metadata: fragment("jsonb_set(?, '{downstream_delivery}', ?::jsonb)", a.response_metadata, ^@undelivered)]]),
          []
        )
    end

    resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
    await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    %{setup: setup, upstream: upstream, request_id: request_id, resend: resend}
  end

  defp completed_frame(response_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
    })
  end

  defp send_and_receive_terminal!(port, setup, turn_state, raw_payload) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    {conn, frame} = receive_terminal!(conn, websocket, ref)
    _closed = Mint.HTTP.close(conn)
    frame
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frame = CodexPooler.JSON.decode!(text)

    if frame["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, frame},
      else: receive_terminal!(conn, websocket, ref)
  end

  defp native_turn_payload(thread_id, model) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "undelivered-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "undelivered-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic undelivered turn"}]}]
    }
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  # The closing socket's own cleanup can hold the shared sandbox connection
  # longer than a checkout waits under load; a dropped checkout is retried.
  defp await_receipt!(request_id, deadline_ms) do
    attempts = safe_all(from(a in Attempt, where: a.request_id == ^request_id))

    cond do
      match?([%Attempt{response_metadata: %{"downstream_delivery" => %{}}}], attempts) -> attempts
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("no delivery receipt for #{request_id}")
      true -> Process.sleep(20) && await_receipt!(request_id, deadline_ms)
    end
  end

  defp await_all_settled!(pool_id, deadline_ms) do
    requests = safe_all(from(r in Request, where: r.pool_id == ^pool_id))

    cond do
      requests != [] and Enum.all?(requests, &(&1.status != "in_progress")) -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("requests never settled")
      true -> Process.sleep(20) && await_all_settled!(pool_id, deadline_ms)
    end
  end

  defp safe_all(query) do
    Repo.all(query)
  rescue
    DBConnection.ConnectionError -> []
  end
end
