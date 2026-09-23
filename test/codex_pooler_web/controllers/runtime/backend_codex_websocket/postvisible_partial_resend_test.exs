defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.PostvisiblePartialResendTest do
  # A native websocket turn cut after its socket pushed the client only
  # lifecycle frames, `response.output_item.added` and, in the delta shape,
  # `response.content_part.added` and a first `response.output_text.delta`.
  # The released Codex client (measured) discards that partial output and
  # resends the identical request once; after a completed item it sends a
  # different request. A direct provider serves the identical resend; the Pooler
  # refused it `409 duplicate_turn` on every websocket retry and over HTTPS,
  # and the turn failed (findings#232 row 232-203). The resend is now admitted
  # as one linked successor, each request with its own single settlement, and a
  # completed item pushed before the cut keeps the fence.
  #
  # Everything runs through the real listener and the real owner (forwarding
  # on) or direct task (forwarding off); the fake provider holds its stream at a
  # frame barrier, so what the socket pushed is exactly the cut shape. Only the
  # resend timing is simplified: it is sent once the original settled and its
  # receipt was recorded (the released client's own retries are the real-client
  # lanes' job).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, stop_registered_websocket_owner_sessions: 0]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  @timeout_ms 15_000
  # With owner forwarding off the closing socket used to leave a direct task it
  # had shown output running for its whole 5 s post-cleanup grace after the
  # 250 ms drain, so with the provider held its receipt could not exist before
  # about 5.25 s; a resendable task is now stopped at the cleanup. The budget
  # sits below that floor and far above the stop's own cost.
  @stopped_receipt_budget_ms 4_000

  # provenance: observed findings#232 row 232-203 (the released Codex client through a cutting proxy: the frames it had received before the cut)
  @cuts %{
    item_added: %{hold_at: 3, last: "response.output_item.added", class: "item_added"},
    delta: %{hold_at: 5, last: "response.output_text.delta", class: "delta"},
    item_done: %{hold_at: 9, last: "response.output_item.done", class: "item_done"}
  }

  for forwarding <- [true, false] do
    for cut <- [:item_added, :delta] do
      @tag forwarding: forwarding
      @tag cut: cut
      @tag slow: "a real socket cut, its owner or direct cleanup, the recorded receipt and a second socket's resend"
      test "owner forwarding #{forwarding}: the identical resend after a #{cut} cut whose provider was still generating is served as one successor", %{forwarding: forwarding, cut: cut} do
        %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt} = scenario!(forwarding, cut, :held)

        assert resend["type"] == "response.completed"
        assert [%Request{id: ^request_id, status: "failed", last_error_code: "client_disconnected"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
        assert %CodexTurn{status: "interrupted", first_visible_output_at: %DateTime{}} = Repo.get_by!(CodexTurn, request_id: request_id)
        assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
        assert_one_settlement_each!([request_id, successor_id])
        assert FakeUpstream.count(upstream) == 2
        assert %{"outcome" => "aborted", "terminal_class" => "none"} = receipt
        assert receipt["highest_frame_class"] == @cuts[cut].class
      end
    end

    @tag forwarding: forwarding
    @tag cut: :item_added
    @tag slow: "a real socket cut, the provider completing after it, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: the identical resend after an item_added cut the provider completed afterwards is served as one successor", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt} = scenario!(forwarding, :item_added, :completes)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_added"} = receipt
    end

    @tag forwarding: forwarding
    @tag cut: :item_done
    @tag slow: "a real socket cut after a completed item, its cleanup, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: a resend after a completed item reached the client stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt} = scenario!(forwarding, :item_done, :held)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id}] = pool_requests(setup.pool.id)
      assert Repo.all(RequestClientRetryLink) == []
      assert FakeUpstream.count(upstream) == 1
      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done"} = receipt
    end
  end

  defp scenario!(forwarding, cut, provider) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
    if forwarding, do: on_exit(&stop_registered_websocket_owner_sessions/0)
    %{hold_at: hold_at, last: last} = Map.fetch!(@cuts, cut)
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.barrier_websocket_frames(stream_frames("resp_partial_original"), notify: self(), release_ref: release_ref)),
          native_request(FakeUpstream.websocket_text_frames(stream_frames("resp_partial_successor")))
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    turn_state = Ecto.UUID.generate()
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
    port = start_public_endpoint!()

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

    for ordinal <- 0..(hold_at - 1) do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @timeout_ms
      :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    # The barrier notification is read before any socket frame: the socket
    # helpers consume every message they do not recognise.
    assert_receive {:fake_upstream_frame_barrier, ^hold_at, _handler, ^release_ref}, @timeout_ms
    conn = receive_until!(conn, websocket, ref, last)
    assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
    _closed = Mint.HTTP.close(conn)
    closed_at = System.monotonic_time(:millisecond)

    if provider == :completes, do: :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)

    receipt =
      if provider == :held and cut != :item_done do
        # Nothing released the provider: the receipt exists only once the
        # original's generation was stopped (the owner's detach, or the closing
        # socket's cleanup with forwarding off).
        receipt = await_receipt!(request_id, closed_at + @stopped_receipt_budget_ms)
        :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
        receipt
      else
        _settled = await_settled!(request_id, closed_at + @timeout_ms)
        if provider == :held, do: :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
        await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
      end

    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)

    await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt}
  end

  defp assert_one_settlement_each!(request_ids) do
    for id <- request_ids do
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
               %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end
  end

  defp native_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp stream_frames(response_id) do
    item_id = "msg_" <> response_id
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "partial answer", "annotations" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}},
        %{"type" => "response.content_part.added", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "", "annotations" => []}},
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => "partial "},
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => "answer"},
        %{"type" => "response.output_text.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "text" => "partial answer"},
        %{"type" => "response.content_part.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "partial answer", "annotations" => []}},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
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
        "turn_id" => "partial-output-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "partial-output-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic partial output turn"}]}]
    }
  end

  defp send_and_receive_terminal!(port, setup, turn_state, raw_payload) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    {conn, frame} = receive_terminal!(conn, websocket, ref)
    _closed = Mint.HTTP.close(conn)
    frame
  end

  defp receive_until!(conn, websocket, ref, type) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    if CodexPooler.JSON.decode!(text)["type"] == type, do: conn, else: receive_until!(conn, websocket, ref, type)
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frame = CodexPooler.JSON.decode!(text)

    if frame["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, frame},
      else: receive_terminal!(conn, websocket, ref)
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  # The closing socket's own cleanup can hold the shared sandbox connection
  # longer than a checkout waits under load; a dropped checkout is retried.
  defp await_receipt!(request_id, deadline_ms) do
    case safe_all(from(a in Attempt, where: a.request_id == ^request_id)) do
      [%Attempt{response_metadata: %{"downstream_delivery" => %{} = receipt}}] ->
        receipt

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("no delivery receipt for #{request_id} within the budget"),
          else: Process.sleep(20) && await_receipt!(request_id, deadline_ms)
    end
  end

  defp await_settled!(request_id, deadline_ms) do
    case safe_all(from(r in Request, where: r.id == ^request_id and r.status != "in_progress")) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("request never settled"),
          else: Process.sleep(20) && await_settled!(request_id, deadline_ms)
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
