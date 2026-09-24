defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ResendChainSecondHopTest do
  # The second hop of a resend chain: a turn the provider failed, its resend
  # cut before any output reached the client, then the next resend.
  #
  # Owner forwarding on: the owner's client-retry preflight admits the first
  # resend as the failed request's successor and, when its client leaves before
  # any output, suspends it into a replay the next resend redeems. When that
  # suspension fails (the arm's transaction cannot run), the cut resend is
  # settled `failed client_disconnected` with no replay entitlement: a
  # pre-visible disconnect exactly like the one forwarding off chains onto
  # (findings#206 rows 206-519 and 206-525). The next resend must be served
  # once, as that cut resend's successor, and never dispatched twice.
  #
  # Owner forwarding off: the HTTPS fallback after a websocket chain of two is
  # served once as the cut resend's successor (row 206-526).
  #
  # One node, native websocket `/backend-api/codex/responses` and its native
  # HTTP fallback, the Pool's model forced to Full and to Lite, FakeUpstream.
  # Real sockets for every websocket request; with forwarding on the owner's
  # replay suspender is replaced by one that fails, which is the only fault
  # injected. Turn metadata and frame shapes are the released client's; text
  # and identifiers synthetic.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [with_info_log: 1]

  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket forwarded #{mode}: the resend after a cut resend whose replay suspension failed is served once as its successor", ctx do
      measured = run_forwarded_failed_suspension(ctx.serving_mode)
      CodexPooler.TestDiagnostics.puts(fn -> "second hop forwarded #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.suspension_attempts >= 1
      assert measured.cut_resend == {"failed", "client_disconnected", nil, :no_entitlement}
      assert measured.next_resend == {"response.completed", nil}
      assert measured.requests == [{"failed", "server_error"}, {"failed", "client_disconnected"}, {"succeeded", nil}]
      assert measured.links == [{0, 1}, {1, 2}]
      assert measured.generations == [[0], [0], [0]]
      assert measured.recorded_settlements == [1, 1, 1]
      assert measured.upstream_requests == 3
      assert measured.duplicate_after_success == {"error", "duplicate_turn"}
      assert measured.upstream_requests_after_duplicate == 3
    end
  end

  # Owner forwarding off, the HTTPS fallback after a websocket chain of two: the
  # turn's first request is cut after the provider's lifecycle frames reached
  # the client (a delivered cut, so the native HTTP claim walk judges the chain
  # through the resend policy instead of stepping over it), its websocket
  # resend is chained onto it and cut before any output, and the released
  # client then falls back to HTTPS with the same request. The HTTP walk chains
  # onto the cut resend under the chain-edge rule (findings#206 rows 206-519
  # and 206-526): served once, linked, and one more identical HTTPS resend
  # after it was served stays a duplicate.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket direct #{mode}: the HTTPS fallback after a two-request websocket chain is served once as the cut resend's successor", ctx do
      measured = run_direct_chain(ctx.serving_mode, :lifecycle_cut, :https_twice)
      CodexPooler.TestDiagnostics.puts(fn -> "https fallback direct #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.cut_resend == {"failed", "client_disconnected", nil, :no_entitlement}
      assert measured.first_resend == {200, "response.completed"}
      assert measured.requests == [{"failed", "upstream_stream_error", "websocket"}, {"failed", "client_disconnected", "websocket"}, {"succeeded", nil, "http_sse"}]
      assert measured.links == [{0, 1}, {1, 2}]
      assert measured.client_resend == [nil, 0, 1]
      assert measured.generations == [[0], [0], [0]]
      assert measured.recorded_settlements == [1, 1, 1]
      assert measured.upstream_requests == 3
      assert measured.second_resend == {409, "duplicate_turn", "terminal_predecessor"}
      assert measured.upstream_requests_after_second == 3
    end
  end

  # The same fallback when the turn's first request delivered nothing: the
  # provider failed it at its first event, and the websocket resend chained
  # onto it was cut before any output. The native HTTP claim walk steps over
  # both zero-output requests instead of judging them (findings#212 row
  # 212-50), so the fallback is served under the claim derived from the cut
  # resend without a link, once; one more identical HTTPS resend after it was
  # served stays a duplicate (row 206-526, residual of the HTTPS arm above).
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket direct #{mode}: the HTTPS fallback after a zero-output websocket chain steps over it and is served once", ctx do
      measured = run_direct_chain(ctx.serving_mode, :server_error, :https_twice)
      CodexPooler.TestDiagnostics.puts(fn -> "https fallback zero-output direct #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.cut_resend == {"failed", "client_disconnected", nil, :no_entitlement}
      assert measured.first_resend == {200, "response.completed"}
      assert measured.requests == [{"failed", "server_error", "websocket"}, {"failed", "client_disconnected", "websocket"}, {"succeeded", nil, "http_sse"}]
      assert measured.links == [{0, 1}]
      assert measured.client_resend == [nil, 0, nil]
      assert measured.fallback_claim == :derived_from_cut_resend
      assert measured.generations == [[0], [0], [0]]
      assert measured.recorded_settlements == [1, 1, 1]
      assert measured.upstream_requests == 3
      assert measured.second_resend == {409, "duplicate_turn", "terminal_predecessor"}
      assert measured.upstream_requests_after_second == 3
    end
  end

  # A websocket resend after the fallback was served, forwarding still off:
  # the turn claim walk reaches the served native HTTP request and refuses it
  # as the turn's served predecessor (`terminal_predecessor`, row 206-534),
  # where it read `authorization_changed`; that disposition also looks up a
  # recorded final refusal to relay, and the answer on the wire stays
  # `409 duplicate_turn`.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket direct #{mode}: a websocket resend after the HTTPS fallback was served is refused as its served predecessor", ctx do
      measured = run_direct_chain(ctx.serving_mode, :lifecycle_cut, :https_then_direct_websocket)
      CodexPooler.TestDiagnostics.puts(fn -> "websocket after https direct #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.first_resend == {200, "response.completed"}
      assert measured.second_resend == {"error", "duplicate_turn", "terminal_predecessor"}
      assert measured.links == [{0, 1}, {1, 2}]
      assert measured.upstream_requests_after_second == 3
    end
  end

  # Owner forwarding switched on in the middle of a turn whose chain was built
  # with it off (findings#206 row 206-533). The owner's client-retry preflight
  # judges the newest websocket request of the turn. After an HTTPS fallback
  # that request is the cut websocket resend, which carries both the link from
  # the request before it and the link to the fallback (a native HTTP turn
  # records no semantic digest, so the preflight never picks it), and the
  # preflight's single-row lineage read raised on it and closed the socket
  # `1011`. A request that is itself a successor keeps the preflight's fence:
  # the forwarded resend gets `409 duplicate_turn` and nothing is dispatched.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket #{mode}: a forwarded resend after a direct chain that ended in an HTTPS fallback is refused, not failed", ctx do
      measured = run_direct_chain(ctx.serving_mode, :lifecycle_cut, :https_then_forwarded_websocket)
      CodexPooler.TestDiagnostics.puts(fn -> "mode switch after https #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.first_resend == {200, "response.completed"}
      assert measured.second_resend == {"error", "duplicate_turn"}
      assert measured.requests == [{"failed", "upstream_stream_error", "websocket"}, {"failed", "client_disconnected", "websocket"}, {"succeeded", nil, "http_sse"}]
      assert measured.links == [{0, 1}, {1, 2}]
      assert measured.upstream_requests_after_second == 3
    end
  end

  # The same switch before the fallback: the forwarded resend meets the cut
  # websocket resend, a turn-claim successor, and is refused (a mixed chain is
  # not resumed across the switch); the released client's HTTPS fallback then
  # finishes the turn, chained onto the cut resend and served once.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket #{mode}: a forwarded resend after a direct chain is refused and its HTTPS fallback is served once", ctx do
      measured = run_direct_chain(ctx.serving_mode, :lifecycle_cut, :forwarded_websocket_then_https)
      CodexPooler.TestDiagnostics.puts(fn -> "mode switch before https #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.first_resend == {"error", "duplicate_turn"}
      assert measured.second_resend == {200, "response.completed"}
      assert measured.requests == [{"failed", "upstream_stream_error", "websocket"}, {"failed", "client_disconnected", "websocket"}, {"succeeded", nil, "http_sse"}]
      assert measured.links == [{0, 1}, {1, 2}]
      assert measured.client_resend == [nil, 0, 1]
      assert measured.generations == [[0], [0], [0]]
      assert measured.upstream_requests_after_second == 3
    end
  end

  # Owner forwarding off while the chain is built: the turn's first request
  # ends (`first`), its websocket resend is chained onto it and cut before any
  # output, and then two more resends of the same request follow (`tail`).
  defp run_direct_chain(mode, first, tail) do
    put_owner_forwarding!(false)
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings issue 124 (lifecycle frames, transport close), runbook terminal-failure resend (response.failed server_error) and row 232-231 (the released client's HTTPS fallback of a websocket request); every reply frame synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: first_frames(first)),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            respond: FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic pre-visible loss")
          ),
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.sse_stream(completed_events("resp_https_fallback_served")))
        ])
      )

    setup = gateway_setup(upstream)
    put_serving_mode!(setup, mode)
    port = start_public_endpoint!()
    thread = "ws-https-fallback-#{System.unique_integer([:positive])}"
    frame = setup |> released_frame(thread, Ecto.UUID.generate(), native_text_input("synthetic cut turn")) |> CodexPooler.JSON.encode!()

    # Socket 1: the first request ends; the client drops the socket.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => type} = failure
    assert type in ["error", "response.failed"]
    Mint.HTTP.close(conn)
    assert [{"failed", _code}] = await_rows!(setup, 1)

    # Socket 2: the resend is chained onto it, reaches the provider, which
    # holds it, and the client leaves before any output.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    cut_request = Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress"))
    Mint.HTTP.close(conn)
    await_settled!(cut_request.id)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

    {first_resend, second_resend, upstream_requests} = resend_tail!(tail, port, setup, thread, frame, upstream)
    rows = await_rows!(setup, 3)
    requests = pool_requests(setup)

    %{
      cut_resend: cut_resend_shape(cut_request.id),
      first_resend: first_resend,
      second_resend: second_resend,
      requests: Enum.zip_with(rows, requests, fn {status, code}, request -> {status, code, request.transport} end),
      links: links(requests),
      client_resend: client_resend_indexes(requests),
      fallback_claim: fallback_claim(requests),
      generations: Enum.map(requests, &generations/1),
      recorded_settlements: Enum.map(requests, &recorded_settlements/1),
      upstream_requests: upstream_requests,
      upstream_requests_after_second: FakeUpstream.count(upstream)
    }
  end

  # The second HTTPS resend meets the served fallback; its refusal names that
  # request's disposition (findings#206 row 206-534).
  defp resend_tail!(:https_twice, _port, setup, thread, frame, upstream) do
    first = https_outcome(post_https_fallback!(setup, thread, frame))
    _rows = await_rows!(setup, 3)
    count = FakeUpstream.count(upstream)
    {{status, code}, log} = with_info_log(fn -> https_outcome(post_https_fallback!(setup, thread, frame)) end)
    {first, {status, code, resend_disposition(log, "native_http_turn_claim")}, count}
  end

  defp resend_tail!(:https_then_direct_websocket, port, setup, thread, frame, upstream) do
    first = https_outcome(post_https_fallback!(setup, thread, frame))
    _rows = await_rows!(setup, 3)
    count = FakeUpstream.count(upstream)
    {{type, code}, log} = with_info_log(fn -> websocket_outcome(port, setup, thread, frame) end)
    {first, {type, code, resend_disposition(log, "websocket_turn_claim")}, count}
  end

  defp resend_tail!(:https_then_forwarded_websocket, port, setup, thread, frame, upstream) do
    first = https_outcome(post_https_fallback!(setup, thread, frame))
    _rows = await_rows!(setup, 3)
    count = FakeUpstream.count(upstream)
    put_owner_forwarding!(true)
    {first, websocket_outcome(port, setup, thread, frame), count}
  end

  defp resend_tail!(:forwarded_websocket_then_https, port, setup, thread, frame, upstream) do
    put_owner_forwarding!(true)
    first = websocket_outcome(port, setup, thread, frame)
    count = FakeUpstream.count(upstream)
    put_owner_forwarding!(false)
    {first, https_outcome(post_https_fallback!(setup, thread, frame)), count}
  end

  defp resend_disposition(log, stage) do
    case Regex.scan(~r/stage=#{stage} .*resend_disposition=([a-z_]+)/, log) do
      [[_line, disposition]] -> disposition
      other -> {:unexpected_log_lines, length(other)}
    end
  end

  defp https_outcome({200, body}), do: {200, if(body =~ "response.completed", do: "response.completed", else: :missing)}
  defp https_outcome({status, body}), do: {status, get_in(CodexPooler.JSON.decode!(body), ["error", "code"])}

  # A websocket resend's terminal, or how its socket closed without one.
  defp websocket_outcome(port, setup, thread, frame) do
    terminal = resend!(port, setup, thread, frame)
    {terminal["type"], get_in(terminal, ["error", "code"])}
  rescue
    error in [ExUnit.AssertionError, RuntimeError] -> {:socket_closed, Exception.message(error)}
  end

  # The fallback's claim: the one derived from the cut resend, when the HTTP
  # walk stepped over the chain without linking to it.
  defp fallback_claim([first, cut, fallback]) do
    {:ok, from_first} = ClientRetry.deterministic_failed_predecessor_claim(first.correlation_id, first.id)
    {:ok, from_cut} = ClientRetry.deterministic_failed_predecessor_claim(from_first, cut.id)

    cond do
      cut.correlation_id != from_first -> :cut_resend_not_derived
      fallback.correlation_id == from_cut -> :derived_from_cut_resend
      true -> :other
    end
  end

  defp fallback_claim(_requests), do: :incomplete

  # The released client's HTTPS fallback of the websocket request: the same
  # body without the frame's `type`, the turn state as a header.
  defp post_https_fallback!(setup, thread, frame) do
    body = frame |> CodexPooler.JSON.decode!() |> Map.delete("type")

    conn =
      build_conn()
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-codex-turn-state", thread)
      |> put_req_header("content-type", "application/json")
      |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(body))

    {conn.status, conn.resp_body}
  end

  # For each request, the index of the request its turn claim chained it onto.
  defp client_resend_indexes(requests) do
    index = requests |> Enum.with_index() |> Map.new(fn {request, i} -> {request.id, i} end)
    Enum.map(requests, &Map.get(index, get_in(&1.request_metadata, ["client_resend", "predecessor_request_id"])))
  end

  defp first_frames(:server_error), do: failure_frames()
  defp first_frames(:lifecycle_cut), do: lifecycle_cut_frames()

  defp lifecycle_cut_frames do
    response_id = "resp_https_fallback_cut"

    FakeUpstream.websocket_text_frames_then_abrupt_close([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress"}})
    ])
  end

  defp completed_events(response_id) do
    [
      %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}},
      %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}}
    ]
  end

  # Owner forwarding on, the HTTPS fallback after a forwarded chain: the turn's
  # first request is cut after the provider's lifecycle frames (which a
  # forwarded turn does not count as visible output), the owner's client-retry
  # preflight admits its websocket resend (`client-retry-v1:`), which is cut
  # before any output, and the client then falls back to HTTPS (findings#206
  # row 206-538). `suspension` is how the owner handled the cut resend: its
  # replay armed, or the arm failed. The native HTTP walk steps over the
  # zero-output first request and serves the fallback once. It used to leave
  # the forwarded chain behind it open: a websocket resend of the same request
  # afterwards redeemed the armed replay, or chained onto the cut resend, and
  # the provider generated the served turn a second time. The fallback now
  # retires an armed replay of the chain (as a newer turn does) and the owner's
  # preflight refuses a request whose turn claim already has a successor.
  for mode <- ["full", "lite"], suspension <- [:fails, :arms] do
    @tag serving_mode: mode, suspension: suspension
    test "websocket forwarded #{mode}: the HTTPS fallback after a forwarded chain whose replay suspension #{suspension}", ctx do
      measured = run_forwarded_https_fallback(ctx.serving_mode, ctx.suspension)
      CodexPooler.TestDiagnostics.puts(fn -> "https fallback forwarded #{ctx.serving_mode} #{ctx.suspension}: #{inspect(measured)}" end)
      assert_forwarded_fallback!(ctx.suspension, measured)
    end
  end

  defp assert_forwarded_fallback!(suspension, measured) do
    assert {measured.websocket_after, measured.upstream_requests_after_websocket} == {{"error", "duplicate_turn"}, 3}
    assert measured.fallback == {200, "response.completed"}
    assert measured.fallback_claim == :derived_from_first
    assert measured.first_visible == [false, false, true]
    assert measured.requests == [{"failed", "upstream_stream_error", "websocket"}, cut_resend_row(suspension), {"succeeded", nil, "http_sse"}]
    assert measured.entitlements == [nil, if(suspension == :arms, do: "revoked"), nil]
    assert measured.upstream_requests == 3
    assert measured.attempts_after == [[0], [0], [0]]
  end

  defp cut_resend_row(:fails), do: {"failed", "client_disconnected", "websocket"}
  defp cut_resend_row(:arms), do: {"failed", "websocket_replay_superseded", "websocket"}

  defp run_forwarded_https_fallback(mode, suspension) do
    put_owner_forwarding!(true)
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings issue 124 (lifecycle frames, transport close), the released client's resend cut before output and row 232-231 (its HTTPS fallback); every reply frame synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: lifecycle_cut_frames()),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            respond: FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic pre-visible loss")
          ),
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.sse_stream(completed_events("resp_forwarded_fallback_served"))),
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: completed_frames("resp_forwarded_fallback_second_generation"))
        ])
      )

    setup = gateway_setup(upstream)
    put_serving_mode!(setup, mode)
    port = start_public_endpoint!()
    thread = "ws-forwarded-fallback-#{System.unique_integer([:positive])}"
    frame = setup |> released_frame(thread, Ecto.UUID.generate(), native_text_input("synthetic cut turn")) |> CodexPooler.JSON.encode!()

    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "error"} = failure
    Mint.HTTP.close(conn)
    assert [{"failed", "upstream_stream_error"}] = await_rows!(setup, 1)

    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    cut_request = Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress"))
    codex_session_id = Repo.one!(from(t in CodexTurn, where: t.request_id == ^cut_request.id, select: t.codex_session_id))
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(codex_session_id)
    if suspension == :fails, do: fail_replay_suspension!(owner_pid)
    Mint.HTTP.close(conn)
    cut_resend = await_cut_resend!(cut_request.id)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

    fallback = https_outcome(post_https_fallback!(setup, thread, frame))
    _rows = await_rows!(setup, 3)
    after_fallback = FakeUpstream.count(upstream)

    # A websocket resend of the same request after the fallback was served.
    websocket_after = websocket_outcome(port, setup, thread, frame)
    rows = await_rows!(setup, 3)
    requests = pool_requests(setup)

    %{
      cut_resend: cut_resend,
      cut_claim: if(String.starts_with?(cut_request.correlation_id, "client-retry-v1:"), do: :client_retry, else: :other),
      fallback: fallback,
      requests: Enum.zip_with(rows, requests, fn {status, code}, request -> {status, code, request.transport} end),
      links: links(requests),
      client_resend: client_resend_indexes(requests),
      generations: Enum.map(requests, &generations/1),
      entitlements: Enum.map(requests, &entitlement_status/1),
      first_visible: Enum.map(requests, &first_visible?/1),
      fallback_claim: forwarded_fallback_claim(requests),
      upstream_requests: after_fallback,
      websocket_after: websocket_after,
      upstream_requests_after_websocket: FakeUpstream.count(upstream),
      attempts_after: Enum.map(pool_requests(setup), &generations/1)
    }
  end

  defp first_visible?(%Request{id: id}) do
    case Repo.get_by(CodexTurn, request_id: id) do
      nil -> :no_turn
      %CodexTurn{first_visible_output_at: at} -> not is_nil(at)
    end
  end

  # The fallback's claim relative to the first request: the claim the HTTP walk
  # derives when it steps over it, or anything else.
  defp forwarded_fallback_claim([first, _cut, fallback]) do
    {:ok, from_first} = ClientRetry.deterministic_failed_predecessor_claim(first.correlation_id, first.id)

    cond do
      not String.starts_with?(first.correlation_id, "codex-turn:") -> :first_without_turn_claim
      fallback.correlation_id == from_first -> :derived_from_first
      true -> :other
    end
  end

  defp forwarded_fallback_claim(_requests), do: :incomplete

  # The cut resend once the owner armed its replay or it settled.
  defp await_cut_resend!(request_id) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_cut_resend!(request_id, deadline)
  end

  defp await_cut_resend!(request_id, deadline) do
    case {Repo.get_by(RequestReplayEntitlement, request_id: request_id), Repo.get!(Request, request_id)} do
      {%RequestReplayEntitlement{status: "armed"}, _request} -> :armed
      {_entitlement, %Request{status: status, last_error_code: code}} when status not in ["accepted", "in_progress"] -> {:settled, status, code}
      _pending -> if System.monotonic_time(:millisecond) >= deadline, do: flunk("the cut resend neither armed nor settled"), else: Process.sleep(5) && await_cut_resend!(request_id, deadline)
    end
  end

  defp entitlement_status(%Request{id: id}) do
    case Repo.get_by(RequestReplayEntitlement, request_id: id) do
      nil -> nil
      %RequestReplayEntitlement{status: status} -> status
    end
  end

  defp run_forwarded_failed_suspension(mode) do
    put_owner_forwarding!(true)
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (response.failed server_error) followed by the released client's resend cut before output; every reply frame synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: failure_frames()),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            respond: FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic pre-visible loss")
          ),
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: completed_frames("resp_second_hop_served"))
        ])
      )

    setup = gateway_setup(upstream)
    put_serving_mode!(setup, mode)
    port = start_public_endpoint!()
    thread = "ws-second-hop-#{System.unique_integer([:positive])}"
    frame = setup |> released_frame(thread, Ecto.UUID.generate(), native_text_input("synthetic failed turn")) |> CodexPooler.JSON.encode!()

    # Socket 1: the provider fails the turn; the client drops the socket.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "response.failed"} = failure
    Mint.HTTP.close(conn)
    assert await_rows!(setup, 1) == [{"failed", "server_error"}]

    # Socket 2: the resend reaches the provider, which holds it; the owner's
    # replay suspension is made to fail, and the client leaves before output.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    cut_request = Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress"))
    codex_session_id = Repo.one!(from(t in CodexTurn, where: t.request_id == ^cut_request.id, select: t.codex_session_id))
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(codex_session_id)
    fail_replay_suspension!(owner_pid)
    Mint.HTTP.close(conn)
    await_settled!(cut_request.id)
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    suspension_attempts = count_suspension_attempts(cut_request.id, 0)

    # Socket 3: the next reconnect's resend.
    next = resend!(port, setup, thread, frame)
    rows = await_rows!(setup, 3)
    requests = pool_requests(setup)
    upstream_requests = FakeUpstream.count(upstream)

    # One more identical resend after the turn was served stays a duplicate.
    duplicate = resend!(port, setup, thread, frame)

    %{
      suspension_attempts: suspension_attempts,
      cut_resend: cut_resend_shape(cut_request.id),
      next_resend: {next["type"], get_in(next, ["error", "code"])},
      requests: rows,
      links: links(requests),
      generations: Enum.map(requests, &generations/1),
      recorded_settlements: Enum.map(requests, &recorded_settlements/1),
      upstream_requests: upstream_requests,
      duplicate_after_success: {duplicate["type"], get_in(duplicate, ["error", "code"])},
      upstream_requests_after_duplicate: FakeUpstream.count(upstream)
    }
  end

  # Every arm of the replay the owner attempts for the cut resend fails, as the
  # arm does when its transaction cannot check out a connection.
  defp fail_replay_suspension!(owner_pid) do
    test_pid = self()

    arm = fn input ->
      send(test_pid, {:replay_suspension_attempt, input.request_id})
      {:error, :database_unavailable}
    end

    :sys.replace_state(owner_pid, fn owner_state -> %{owner_state | callbacks: %{owner_state.callbacks | replay_suspender: arm}} end)
    :ok
  end

  defp count_suspension_attempts(request_id, count) do
    receive do
      {:replay_suspension_attempt, ^request_id} -> count_suspension_attempts(request_id, count + 1)
    after
      0 -> count
    end
  end

  defp cut_resend_shape(request_id) do
    request = Repo.get!(Request, request_id)
    turn = Repo.get_by!(CodexTurn, request_id: request_id)
    entitlement = if Repo.get_by(RequestReplayEntitlement, request_id: request_id), do: :entitlement, else: :no_entitlement
    {request.status, request.last_error_code, turn.first_visible_output_at, entitlement}
  end

  # Each link as {predecessor index, successor index} in admission order.
  defp links(requests) do
    index = requests |> Enum.with_index() |> Map.new(fn {request, i} -> {request.id, i} end)
    ids = Map.keys(index)

    from(link in RequestClientRetryLink, where: link.predecessor_request_id in ^ids or link.successor_request_id in ^ids, select: {link.predecessor_request_id, link.successor_request_id})
    |> Repo.all()
    |> Enum.map(fn {predecessor, successor} -> {Map.get(index, predecessor, :foreign), Map.get(index, successor, :foreign)} end)
    |> Enum.sort()
  end

  defp generations(%Request{id: id}), do: Repo.all(from(a in Attempt, where: a.request_id == ^id, order_by: [asc: a.attempt_number], select: a.replay_generation))

  defp recorded_settlements(%Request{id: id}),
    do: Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^id and l.entry_kind == "settlement" and l.amount_status == "recorded"), :count)

  defp resend!(port, setup, thread, frame) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, terminal} = receive_until_terminal(conn, websocket, ref)
    Mint.HTTP.close(conn)
    terminal
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_until_terminal(conn, websocket, ref)
    end
  end

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

  defp await_settled!(request_id) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_settled!(request_id, deadline)
  end

  defp await_settled!(request_id, deadline) do
    case Repo.get!(Request, request_id) do
      %Request{status: status} when status not in ["accepted", "in_progress"] ->
        :ok

      _live ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("the cut resend never settled"), else: Process.sleep(5) && await_settled!(request_id, deadline)
    end
  end

  defp await_rows!(setup, count) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_rows!(setup, count, deadline)
  end

  defp await_rows!(setup, count, deadline) do
    rows = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at], select: {r.status, r.last_error_code}))

    if (length(rows) < count or Enum.any?(rows, &match?({status, _code} when status in ["accepted", "in_progress"], &1))) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_rows!(setup, count, deadline)
    else
      rows
    end
  end

  # The released client's turn frame (`request_kind` turn).
  defp released_frame(setup, thread, turn_id, input) do
    metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id}

    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "generate" => true,
      "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", turn_metadata(thread, turn_id, "turn"))
    }
  end

  defp turn_metadata(thread, turn_id, kind), do: CodexPooler.JSON.encode!(%{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id, "request_kind" => kind})

  defp failure_frames do
    response_id = "resp_second_hop_failed"

    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"id" => response_id, "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}})
    ])
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ])
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    :ok
  end

  defp put_owner_forwarding!(forwarding?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding?)
  end
end
