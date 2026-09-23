defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.FinalRefusalResendTest do
  # With owner forwarding off (the runtime default for one replica) the resend
  # of a turn whose provider refusal went out as the final wrapped 400 meets the
  # websocket turn claim, not the owner replay preflight. It used to be refused
  # `409 duplicate_turn`, and the released Codex client's in-band compaction,
  # which resends a refused compaction frame five more times, ended showing that
  # duplicate refusal instead of the provider's (findings#254 row 254-100,
  # released Codex client, measured with forwarding on and off). The resend gets the same
  # refusal back, without a dispatch, a reservation or a request row.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, strict_native_request: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @timeout_ms 15_000

  @tag :websocket_direct
  test "the resend of a finally refused turn gets the same refusal again with owner forwarding off, never a dispatch" do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)

    refusal = CodexPooler.JSON.encode!(%{"type" => "error", "status" => 404, "error" => %{"type" => "invalid_request_error", "message" => "Refused 'private-refusal-sentinel'."}})

    upstream =
      start_upstream(
        # provenance: observed findings#254 row 254-100 (released Codex client in-band compaction refused by the provider, resent five times, forwarding off)
        FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([refusal]))])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    thread_id = Ecto.UUID.generate()
    turn_state = Ecto.UUID.generate()
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(thread_id, setup.model.exposed_model_id))
    port = start_public_endpoint!()

    original = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
    assert %{"type" => "error", "status" => 400, "error" => %{"code" => "invalid_request"}} = original
    refute CodexPooler.JSON.encode!(original) =~ "private-refusal-sentinel"
    assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
    await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    resends = for _resend <- 1..2, do: send_and_receive_terminal!(port, setup, turn_state, raw_payload)

    assert resends == [original, original]
    assert [%Request{id: ^request_id, status: "failed"}] = pool_requests(setup.pool.id)
    assert [%Attempt{status: "failed"}] = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))
    assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^request_id, select: l.entry_kind)) |> Enum.frequencies() == %{"reservation" => 1, "settlement" => 1, "release" => 1}
    assert FakeUpstream.count(upstream) == 1
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The same turn resent over HTTPS, the released client's fallback after its
  # websocket retries fail (findings#254 row 254-130): the opening request
  # carries the websocket request's witness (row 232-231), so it finds the
  # refused websocket turn and gets its refusal as the HTTP error, never a
  # dispatch.
  for forwarding <- [true, false] do
    @tag forwarding: forwarding
    @tag slow: "a real websocket turn refused and settled through the owner or the direct task, then its HTTPS resend"
    test "owner forwarding #{forwarding}: the HTTPS resend of a finally refused websocket turn gets the same refusal, never a dispatch", %{forwarding: forwarding} do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)

      refusal = CodexPooler.JSON.encode!(%{"type" => "error", "status" => 404, "error" => %{"type" => "invalid_request_error", "message" => "Refused 'private-refusal-sentinel'."}})

      upstream =
        start_upstream(
          # provenance: observed findings#254 row 254-100 (codeless provider 404 refusing a native websocket turn); the HTTPS resend is row 254-130
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: FakeUpstream.websocket_text_frames([refusal]))
          ])
        )

      setup = gateway_setup(upstream)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
      turn_state = Ecto.UUID.generate()
      raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
      port = start_public_endpoint!()

      original = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      assert %{"type" => "error", "status" => 400, "error" => %{"code" => code, "message" => message}} = original
      assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
      await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

      body =
        raw_payload
        |> CodexPooler.JSON.decode!()
        |> Map.delete("type")
        |> Map.update!("client_metadata", &Map.delete(&1, "x-codex-ws-stream-request-start-ms"))

      conn =
        build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> put_req_header("x-codex-turn-state", turn_state)
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(body))

      assert conn.status == 400
      assert %{"error" => %{"code" => ^code, "message" => ^message}} = CodexPooler.JSON.decode!(conn.resp_body)
      refute conn.resp_body =~ "private-refusal-sentinel"
      # The HTTP route records its refusal as a denied request row, with no
      # attempt and no reservation; the refused original is untouched.
      assert [%Request{id: ^request_id, status: "failed"}, %Request{id: denied_id, status: "rejected", response_status_code: 400}] = pool_requests(setup.pool.id)
      assert Repo.all(from(a in Attempt, where: a.request_id == ^denied_id)) == []
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^denied_id)) == []
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^request_id, select: l.entry_kind)) |> Enum.frequencies() == %{"reservation" => 1, "settlement" => 1, "release" => 1}
      assert FakeUpstream.count(upstream) == 1
    end
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
        "turn_id" => "refused-direct-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "refused-direct-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic refused direct turn"}]}]
    }
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  defp await_settled!(request_id, deadline_ms) do
    status = Repo.get!(Request, request_id).status

    cond do
      status != "in_progress" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("request #{request_id} never settled")

      true ->
        Process.sleep(20)
        await_settled!(request_id, deadline_ms)
    end
  end
end
