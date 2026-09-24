defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ClaimlessDenialResendTest do
  # A websocket refusal recorded without a turn claim (a frame that names no
  # Codex turn, from an SDK or a third-party client, or the released client's
  # frame refused before its turn is claimed) used to take the socket's
  # handshake request id as its correlation id, which every frame of the socket
  # shares, so the second such refusal on the socket met
  # `requests_correlation_id_uq` and the client got `500
  # websocket_response_task_failed` instead of the refusal (findings#206 row
  # 206-361). Each such refusal is now its own rejected request, as each
  # unclaimed admission already is, so a resend gets the same typed refusal
  # again. A refusal recorded on the released client's turn claim gives that
  # claim up (findings#206 row 206-420): nothing reached the provider, so the
  # resend gets the same typed refusal as well, where it used to meet a
  # permanent `409 duplicate_turn`.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  # Failure-detection budget for the polling helper below; it returns as soon
  # as the awaited request row settles.
  @detection_timeout_ms 15_000

  @opening_response_id "resp_claimless_opening_turn"

  for forwarding <- [:owner_forwarding, :direct], client <- [:claimless, :released] do
    @tag forwarding: forwarding, client: client
    test "an identical resend of a refused anchored frame gets a typed refusal, never a 500 (#{client}, #{forwarding})",
         %{forwarding: forwarding, client: client} do
      %{conn: conn, websocket: websocket, ref: ref, setup: setup, sticky: sticky, fallback: fallback} =
        opened_session!(forwarding, client)

      # The session's account is exhausted, so the anchored request, bound to
      # the live upstream websocket that produced its anchor, cannot move.
      prime_exhausted_routing_quota!(setup.identity)

      frame = frame(setup, client, "anchored-turn", native_text_input("synthetic anchored turn"), @opening_response_id)

      {conn, codes} = send_times(conn, websocket, ref, frame, 3)
      Mint.HTTP.close(conn)

      assert codes == List.duplicate("error:503:pinned_continuation_unavailable", 3)

      assert FakeUpstream.count(sticky) == 1
      assert FakeUpstream.count(fallback) == 0

      rows = pool_requests(setup.pool.id)
      assert [%Request{status: "succeeded"} | rejected] = rows

      assert Enum.map(rejected, &{&1.status, &1.last_error_code, &1.transport}) ==
               List.duplicate({"rejected", "pinned_continuation_unavailable", "websocket"}, 3)

      correlation_ids = Enum.map(rows, & &1.correlation_id)
      assert correlation_ids == Enum.uniq(correlation_ids)
    end

    # The session's account leaves the model's sources, so the anchored request
    # is refused while its candidates are prepared, before any turn claim: the
    # released client's frame is recorded without its claim too.
    @tag forwarding: forwarding, client: client
    test "a resend refused before its turn is claimed gets the same typed refusal again (#{client}, #{forwarding})",
         %{forwarding: forwarding, client: client} do
      %{conn: conn, websocket: websocket, ref: ref, setup: setup, sticky: sticky, fallback: fallback, fallback_assignment: fallback_assignment} =
        opened_session!(forwarding, client)

      put_model_source_assignments!(setup.model, [fallback_assignment])

      frame = frame(setup, client, "anchored-turn", native_text_input("synthetic anchored turn"), @opening_response_id)

      {conn, codes} = send_times(conn, websocket, ref, frame, 3)
      Mint.HTTP.close(conn)

      assert codes == List.duplicate("error:503:pinned_continuation_unavailable", 3)
      assert FakeUpstream.count(sticky) == 1
      assert FakeUpstream.count(fallback) == 0

      rows = pool_requests(setup.pool.id)
      assert [%Request{status: "succeeded"} | rejected] = rows

      assert Enum.map(rejected, &{&1.status, &1.last_error_code, &1.transport}) ==
               List.duplicate({"rejected", "pinned_continuation_unavailable", "websocket"}, 3)

      correlation_ids = Enum.map(rows, & &1.correlation_id)
      assert correlation_ids == Enum.uniq(correlation_ids)
    end

    @tag forwarding: forwarding, client: client
    test "two different refused frames on one socket each get their own refusal (#{client}, #{forwarding})",
         %{forwarding: forwarding, client: client} do
      %{conn: conn, websocket: websocket, ref: ref, setup: setup, sticky: sticky, fallback: fallback} =
        opened_session!(forwarding, client)

      prime_exhausted_routing_quota!(setup.identity)

      first = frame(setup, client, "anchored-turn-one", native_text_input("synthetic anchored turn one"), @opening_response_id)
      second = frame(setup, client, "anchored-turn-two", native_text_input("synthetic anchored turn two"), @opening_response_id)

      {conn, first_codes} = send_times(conn, websocket, ref, first, 1)
      {conn, second_codes} = send_times(conn, websocket, ref, second, 1)
      Mint.HTTP.close(conn)

      assert first_codes ++ second_codes == List.duplicate("error:503:pinned_continuation_unavailable", 2)
      assert FakeUpstream.count(sticky) == 1
      assert FakeUpstream.count(fallback) == 0

      rows = pool_requests(setup.pool.id)
      assert [%Request{status: "succeeded"}, %Request{status: "rejected"}, %Request{status: "rejected"}] = rows
      correlation_ids = Enum.map(rows, & &1.correlation_id)
      assert correlation_ids == Enum.uniq(correlation_ids)
    end
  end

  # A refusal made before the released client's request is claimed is recorded
  # without that request's claim: the row used to take the `codex-request:`
  # claim, so the same request, resent once the refusal's cause was gone, met
  # it and got `409 duplicate_turn` for good (findings#206 row 206-429).
  for forwarding <- [:owner_forwarding, :direct] do
    @tag forwarding: forwarding
    test "a released request refused before its claim is served once the cause is gone, never fenced (#{forwarding})", %{forwarding: forwarding} do
      restored = strict_native_request(1, completed_frames("resp_claimless_restored", 4, 1))

      %{conn: conn, websocket: websocket, ref: ref, setup: setup, sticky: sticky, fallback: fallback, fallback_assignment: fallback_assignment} =
        opened_session!(forwarding, :released, [restored])

      # A tool result anchored on the opening response: claimed under
      # `codex-request:`, not the turn's `codex-turn:`.
      put_model_source_assignments!(setup.model, [fallback_assignment])
      tool_output = [%{"type" => "function_call_output", "call_id" => "call_claimless_anchored", "output" => "synthetic tool output"}]
      frame = frame(setup, :released, "opening-turn", tool_output, @opening_response_id)
      {conn, refused} = send_times(conn, websocket, ref, frame, 1)
      [_opening, refused_row] = pool_requests(setup.pool.id)

      put_model_source_assignments!(setup.model, [setup.assignment, fallback_assignment])
      {conn, resent} = send_times(conn, websocket, ref, frame, 1)
      Mint.HTTP.close(conn)

      assert %{
               refused: refused,
               refused_row_claim: claim_prefix(refused_row.correlation_id),
               resent: resent,
               sticky: FakeUpstream.count(sticky),
               fallback: FakeUpstream.count(fallback)
             } == %{
               refused: ["error:503:pinned_continuation_unavailable"],
               refused_row_claim: nil,
               resent: ["response.completed::"],
               sticky: 2,
               fallback: 0
             }
    end
  end

  defp claim_prefix(claim), do: Enum.find(["codex-turn:", "codex-request:", "codex-resume:", "codex-request-retry:", "client-retry-v1:"], &String.starts_with?(claim, &1))

  # Turn 1 binds the session to the sticky account and opens the live upstream
  # websocket there; a second account is eligible from then on.
  defp opened_session!(forwarding, client, sticky_later \\ []) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :owner_forwarding)

    sticky = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, completed_frames(@opening_response_id, 3, 1)) | sticky_later]))
    # The fallback account must never be asked: the anchored request cannot move.
    fallback = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, completed_frames("resp_claimless_fallback_unused", 5, 2))]))

    setup = gateway_setup(sticky)
    fallback_upstream = gateway_upstream(setup.pool, fallback, "upstream-token-claimless-fallback", compact?: false)
    prime_routing_quota!(fallback_upstream.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())

    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, client, "opening-turn", native_text_input("synthetic opening turn"), nil))
    {conn, websocket, terminal} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "response.completed"} = terminal
    [opening] = pool_requests(setup.pool.id)
    await_request_settled!(opening.id)

    put_model_source_assignments!(setup.model, [setup.assignment, fallback_upstream.assignment])

    %{conn: conn, websocket: websocket, ref: ref, setup: setup, sticky: sticky, fallback: fallback, fallback_assignment: fallback_upstream.assignment}
  end

  defp send_times(conn, websocket, ref, frame, times) do
    {conn, _websocket, codes} =
      Enum.reduce(1..times, {conn, websocket, []}, fn _n, {conn, websocket, codes} ->
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
        {conn, websocket, terminal} = receive_until_terminal(conn, websocket, ref)
        {conn, websocket, [terminal_code(terminal) | codes]}
      end)

    {conn, Enum.reverse(codes)}
  end

  defp terminal_code(terminal),
    do: Enum.join([terminal["type"], terminal["status"], get_in(terminal, ["error", "code"])], ":")

  # A claimless frame carries no turn metadata; the released client's frame
  # names the thread and the turn in `client_metadata` (Codex rust-v0.156.0).
  defp frame(setup, client, turn_id, input, previous_response_id) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => input, "stream" => true, "generate" => true}
    |> put_turn_metadata(client, setup, turn_id)
    |> then(fn payload -> if previous_response_id, do: Map.put(payload, "previous_response_id", previous_response_id), else: payload end)
    |> CodexPooler.JSON.encode!()
  end

  defp put_turn_metadata(payload, :claimless, _setup, _turn_id), do: payload

  defp put_turn_metadata(payload, :released, setup, turn_id) do
    thread_id = setup.pool.id

    Map.put(payload, "client_metadata", %{
      "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => turn_id, "request_kind" => "turn"})
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
    Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at, asc: r.id]))
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] ->
        {conn, websocket, terminal}

      %{"type" => _type} ->
        receive_until_terminal(conn, websocket, ref)
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
end
