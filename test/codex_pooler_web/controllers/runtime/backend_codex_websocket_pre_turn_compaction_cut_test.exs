defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketPreTurnCompactionCutTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2]

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.{NativeCompactionAdmission, WebsocketOwnerSession}
  alias CodexPooler.Repo

  # A client cut during an admitted anchored native compaction (findings#206
  # row 206-310). The released client (Codex 0.156.1, observed on the wire in
  # Full and Lite) sends its pre-turn compaction anchored on the previous
  # turn's response, on that turn's connection, with the NEW turn's id and
  # only the `compaction_trigger`; the owner admits it on the first send since
  # `e48cde2f9`. A mid-turn compaction is anchored the same way under its own
  # turn's id and was admitted before, and so is the manual `/compact` of a
  # standalone turn whose anchor resolves to the session (production row
  # `0fd0b900`, Codex Desktop). When the connection is cut, the client
  # drops it and resends the same compaction as full history on a new
  # connection (`compact_remote_v2.rs` retry loop: two websocket retries, then
  # HTTPS). The admitted compaction held no durable claim, so with owner
  # forwarding off that resend found its claim free: after a billed completion
  # it was served and billed again, and while the cut predecessor was still
  # live it hit the active-turn index and left an accepted row behind
  # (`500 websocket_response_task_failed`, then `409 duplicate_turn`). Both
  # forms now derive one compaction claim (findings#206 row 206-310). Every arm
  # drives the released client's whole retry (P69 wire probe): two websocket
  # resends on new connections, then `POST /responses` over SSE with the same
  # body and two HTTP retries, after which the turn fails. A cut after
  # upstream output or after a billed completion used to be refused `409`
  # twice and then bought again, unchained, by that HTTPS fallback; the client
  # resends a compaction only when it did not complete it, so the resend is
  # now the predecessor's successor, one charge per request (rows 206-330 and
  # 206-332). The HTTPS fallback of a compaction whose websocket resends met a
  # live predecessor derives the websocket claim and is chained the same way.
  # Frames keep the released client's key sets; identifiers, prompt text and
  # reply frames are synthetic. One node, owner forwarding on and off; the
  # resend is sent once the predecessor has settled (the released client
  # retries after about 200 ms), except in the `unobserved_cut` arm, where the
  # Pooler has not seen the cut when the websocket resends arrive. The `peer`
  # arms run the Full pre-turn shape with owner forwarding on and the session's
  # owner and its provider connection on a second VM sharing the committed
  # database, the socket on this node, as when a production turn lands on the
  # other web pod (findings#206 row 206-334).
  @thread_id "019a0000-0000-7000-8000-00000000f001"
  @window_id "#{@thread_id}:0"
  @resumed_window_id "#{@thread_id}:1"
  @turn_id "019a0000-0000-7000-8000-00000000f002"
  @next_turn_id "019a0000-0000-7000-8000-00000000f006"
  @installation_id "00000000-0000-4000-8000-00000000f003"
  @context_window_id "00000000-0000-4000-8000-00000000f004"
  @resumed_context_window_id "00000000-0000-4000-8000-00000000f005"
  @anchor "resp_preturn_cut_anchor00000001"
  @cut_response "resp_preturn_cut_compact_cut001"
  @resend_response "resp_preturn_cut_compact_resend"
  @final_response "resp_preturn_cut_final000000001"
  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"
  @compact_endpoint "/backend-api/codex/responses/compact"
  @turn_endpoint "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  @standalone_turn_id "019a0000-0000-7000-8000-00000000f007"
  @arms for mode <- ["full", "lite"], shape <- [:pre_turn, :mid_turn, :standalone_turn], mode == "full" or shape == :pre_turn, do: {mode, shape}

  for {mode, shape} <- @arms, topology <- [:forwarded, :direct], cut <- [:no_cut, :before_output, :after_output, :after_completion, :unobserved_cut] do
    @tag mode: mode, shape: shape, topology: topology, cut: cut
    test "#{mode} #{shape} #{topology} admitted compaction #{cut}: the released client's retries buy the compaction once per request and the turn completes",
         %{mode: mode, shape: shape, topology: topology, cut: cut} do
      assert run_scenario(mode, shape, topology, cut) == expected(cut, topology)
    end
  end

  for cut <- [:no_cut, :before_output, :after_output, :after_completion, :unobserved_cut] do
    @tag mode: "full", shape: :pre_turn, topology: :peer, cut: cut
    test "full pre_turn peer admitted compaction #{cut}: the released client's retries buy the compaction once per request and the turn completes",
         %{mode: mode, shape: shape, topology: topology, cut: cut} do
      assert run_scenario(mode, shape, topology, cut) == expected(cut, topology)
    end
  end

  # Rows are `{endpoint, transport, status, last_error_code, chained?}` in
  # admission order; `compaction_charges` lists each compaction request's
  # charges in the same order, so a request billed twice shows as a 2.
  defp expected(:unobserved_cut, topology), do: expected_unobserved(topology)
  defp expected(cut, _topology), do: expected(cut)

  defp expected(:no_cut),
    do: %{
      retries: nil,
      rows: [{@turn_endpoint, "websocket", "succeeded", nil, false}, {@compact_endpoint, "websocket", "succeeded", nil, false}, {@turn_endpoint, "websocket", "succeeded", nil, false}],
      compaction_charges: [1],
      upstream_compactions: 1,
      live_rows: 0
    }

  # A cut before the provider produced anything: the first websocket resend is
  # served as the predecessor's successor.
  defp expected(:before_output),
    do: %{
      retries: [:served],
      rows: [
        {@turn_endpoint, "websocket", "succeeded", nil, false},
        {@compact_endpoint, "websocket", "failed", "client_disconnected", false},
        {@compact_endpoint, "websocket", "succeeded", nil, true},
        {@turn_endpoint, "websocket", "succeeded", nil, false}
      ],
      compaction_charges: [0, 1],
      upstream_compactions: 2,
      live_rows: 0
    }

  # The provider pushed the compaction item and the Pooler collected it, but
  # nothing reached the client; the first websocket resend is served as the
  # successor (findings#206 rows 206-330, 206-332). It used to be refused twice
  # and bought again, unchained, by the client's HTTPS fallback.
  defp expected(:after_output),
    do: %{
      retries: [:served],
      rows: [
        {@turn_endpoint, "websocket", "succeeded", nil, false},
        {@compact_endpoint, "websocket", "failed", "client_disconnected", false},
        {@compact_endpoint, "websocket", "succeeded", nil, true},
        {@turn_endpoint, "websocket", "succeeded", nil, false}
      ],
      compaction_charges: [0, 1],
      upstream_compactions: 2,
      live_rows: 0
    }

  # The reply was billed and written and the client never read it: the client
  # resends a compaction only when it did not complete it (its window has not
  # advanced), so the resend is served as the successor, one charge per
  # request, instead of two refusals and an unchained HTTPS purchase.
  defp expected(:after_completion),
    do: %{
      retries: [:served],
      rows: [
        {@turn_endpoint, "websocket", "succeeded", nil, false},
        {@compact_endpoint, "websocket", "succeeded", nil, false},
        {@compact_endpoint, "websocket", "succeeded", nil, true},
        {@turn_endpoint, "websocket", "succeeded", nil, false}
      ],
      compaction_charges: [1, 1],
      upstream_compactions: 2,
      live_rows: 0
    }

  # Without owner forwarding both websocket resends race the live predecessor
  # and are refused; the HTTPS fallback, which arrives after the Pooler settled
  # it, derives the predecessor's claim and is served as its successor, and
  # the turn finishes over HTTPS as the released client does.
  defp expected_unobserved(:direct),
    do: %{
      retries: [{409, "duplicate_turn"}, {409, "duplicate_turn"}, :http_served],
      rows: [
        {@turn_endpoint, "websocket", "succeeded", nil, false},
        {@compact_endpoint, "websocket", "failed", "client_disconnected", false},
        {@compact_endpoint, "http_compact_json", "succeeded", nil, true},
        {@turn_endpoint, "http_sse", "succeeded", nil, false}
      ],
      compaction_charges: [0, 1],
      upstream_compactions: 2,
      live_rows: 0
    }

  # With owner forwarding the first resend's socket takes the owner over and
  # the owner cuts the predecessor, so the second resend is its successor.
  defp expected_unobserved(topology) when topology in [:forwarded, :peer],
    do: %{
      retries: [{409, "duplicate_turn"}, :served],
      rows: [
        {@turn_endpoint, "websocket", "succeeded", nil, false},
        {@compact_endpoint, "websocket", "failed", "client_disconnected", false},
        {@compact_endpoint, "websocket", "succeeded", nil, true},
        {@turn_endpoint, "websocket", "succeeded", nil, false}
      ],
      compaction_charges: [0, 1],
      upstream_compactions: 2,
      live_rows: 0
    }

  defp run_scenario(mode, shape, topology, cut) do
    put_owner_forwarding!(topology != :direct)
    release_ref = make_ref()
    ctx = %{mode: mode, shape: shape}

    upstream = start_upstream(FakeUpstream.strict_sequence(upstream_sequence(ctx, cut, topology, release_ref)))
    setup = topology_setup!(topology, upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    ctx = Map.put(ctx, :setup, setup)
    port = start_public_endpoint!()

    first = connect!(port, setup)
    first = ordinary_turn!(first, turn_frame(ctx))
    await_armed!(topology, setup)
    # The strict upstream expects this compaction anchored on the admitted
    # response: it is dispatched on its first send.
    first = send_frame!(first, anchored_compaction_frame(ctx))
    retries = cut_and_resend(cut, ctx, first, port, upstream, release_ref)

    rows = await_settled!(setup.pool.id)
    compactions = Enum.filter(rows, &compaction_row?/1)

    measured = %{
      retries: retries,
      rows: Enum.map(rows, &{&1.endpoint, &1.transport, &1.status, &1.last_error_code, chained?(&1)}),
      compaction_charges: Enum.map(compactions, &charges/1),
      upstream_compactions: upstream |> FakeUpstream.requests() |> Enum.count(&compaction_request?/1),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-330 #{mode} #{shape} #{topology} #{cut}: #{inspect(measured)}" end)
    assert :ok = FakeUpstream.verify!(upstream)
    measured
  end

  # The peer shares the committed database, so its fixture is committed: the
  # sandbox switches to auto mode before anything is written.
  defp topology_setup!(:peer, upstream) do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream, compact?: true)
    Map.put(setup, :peer_owner, start_peer_window_owner!(setup, @window_id))
  end

  defp topology_setup!(_topology, upstream), do: gateway_setup(upstream, compact?: true)

  defp cut_and_resend(:no_cut, ctx, client, _port, _upstream, _release_ref) do
    {client, frames} = receive_until_terminal(client, [])
    assert frames == ["response.output_item.done", "response.completed"]

    try do
      client |> send_frame!(resume_frame(ctx, "served")) |> ordinary_turn!()
    after
      Mint.HTTP.close(client.conn)
    end

    nil
  end

  defp cut_and_resend(:unobserved_cut, ctx, client, port, upstream, release_ref) do
    await_barrier!(0, release_ref)
    # The client gave up on the connection but the Pooler has not seen it close
    # yet: the predecessor is still live when both websocket resends arrive,
    # and the Pooler settles it before the HTTPS fallback.
    settle = fn ->
      Mint.HTTP.close(client.conn)
      await_compaction_settled!(ctx.setup.pool.id, ["succeeded", "failed"])
      release_held_compaction!(upstream, release_ref, 1)
    end

    retries = released_client_retries!(ctx, port, settle)
    if List.last(retries) == :served, do: settle.()
    retries
  end

  defp cut_and_resend(cut, ctx, client, port, upstream, release_ref) do
    await_barrier!(0, release_ref)

    next_barrier =
      case cut do
        :before_output ->
          1

        :after_output ->
          # `response.created` and the compaction item reach the Pooler, which
          # collects a native compaction before it shows the client anything.
          for barrier <- [1, 2] do
            :ok = FakeUpstream.release_frame(upstream, release_ref)
            await_barrier!(barrier, release_ref)
          end

          3

        :after_completion ->
          # The provider completes and the Pooler bills and writes the reply,
          # which the client never reads (the reply is lost with the connection).
          :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
          for barrier <- 1..3, do: await_barrier!(barrier, release_ref)
          await_compaction_settled!(ctx.setup.pool.id, ["succeeded"])
          nil
      end

    Mint.HTTP.close(client.conn)
    await_compaction_settled!(ctx.setup.pool.id, ["succeeded", "failed"])
    retries = released_client_retries!(ctx, port, fn -> :ok end)
    if next_barrier, do: release_held_compaction!(upstream, release_ref, next_barrier)
    retries
  end

  # The released client's retry of a remote compaction it did not complete
  # (`compact_remote_v2.rs`, measured on the wire in P69 with Codex 0.156.1):
  # two websocket retries, each on a new connection with the full history,
  # then `POST /responses` over SSE with the same body (no `type`, no
  # websocket start timestamp, the Lite marker moved to a header) and two
  # more HTTP retries; after those the turn fails and the compaction is lost.
  defp released_client_retries!(ctx, port, before_https) do
    case websocket_retries!(ctx, port, 2, []) do
      {:served, outcomes} ->
        outcomes

      {:refused, outcomes} ->
        before_https.()
        outcomes ++ https_retries!(ctx, 3, [])
    end
  end

  defp websocket_retries!(_ctx, _port, 0, outcomes), do: {:refused, Enum.reverse(outcomes)}

  defp websocket_retries!(ctx, port, remaining, outcomes) do
    case full_history_resend!(ctx, port) do
      :served -> {:served, Enum.reverse([:served | outcomes])}
      refused -> websocket_retries!(ctx, port, remaining - 1, [refused | outcomes])
    end
  end

  # One websocket retry: a new connection and the same compaction as full
  # history; when it is served the turn continues on that connection.
  defp full_history_resend!(ctx, port) do
    client = connect!(port, ctx.setup)

    try do
      client = send_frame!(client, full_history_compaction_frame(ctx))

      case receive_frame!(client) do
        {_client, %{"type" => "error", "status" => status, "error" => %{"code" => code}}} ->
          {status, code}

        {client, %{"type" => "response.output_item.done"}} ->
          {client, ["response.completed"]} = receive_until_terminal(client, [])
          client |> send_frame!(resume_frame(ctx, "resend")) |> ordinary_turn!()
          :served
      end
    after
      Mint.HTTP.close(client.conn)
    end
  end

  defp https_retries!(_ctx, 0, outcomes), do: Enum.reverse(outcomes)

  defp https_retries!(ctx, remaining, outcomes) do
    compaction = post_native!(ctx, https_body(full_history_compaction_payload(ctx)), compaction_metadata(ctx.shape), @window_id)

    if compaction.status == 200 do
      assert compaction.resp_body =~ "response.completed"
      {payload, metadata} = resume_payload(ctx, "https")
      resume = post_native!(ctx, https_body(payload), metadata, @resumed_window_id)
      assert resume.status == 200 and resume.resp_body =~ "response.completed", inspect({resume.status, resume.resp_body})
      Enum.reverse([:http_served | outcomes])
    else
      code = get_in(CodexPooler.JSON.decode!(compaction.resp_body), ["error", "code"])
      https_retries!(ctx, remaining - 1, [{:http, compaction.status, code} | outcomes])
    end
  end

  # The HTTP request the released client builds from the websocket one: the
  # same body without the websocket-only keys, the turn metadata echoed as a
  # header, and in Lite the marker as `x-openai-internal-codex-responses-lite`.
  defp post_native!(ctx, body, metadata, window_id) do
    conn =
      build_conn()
      |> put_req_header("authorization", ctx.setup.authorization)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("session-id", @thread_id)
      |> put_req_header("thread-id", @thread_id)
      |> put_req_header("x-client-request-id", @thread_id)
      |> put_req_header("x-codex-window-id", window_id)
      |> put_req_header("x-codex-turn-metadata", metadata)
      |> put_req_header("originator", "codex_cli_rs")

    conn = if ctx.mode == "lite", do: put_req_header(conn, "x-openai-internal-codex-responses-lite", "true"), else: conn
    post(conn, @turn_endpoint, CodexPooler.JSON.encode!(body))
  end

  defp https_body(payload) do
    payload
    |> Map.delete("type")
    |> Map.update!("client_metadata", &Map.drop(&1, ["x-codex-ws-stream-request-start-ms", @lite_marker]))
  end

  # The provider finishes the cut generation, as a live provider would; the
  # Pooler has already settled it. The Pooler may have closed the provider
  # connection when it abandoned the generation, and then the rest of the reply
  # is never pushed: wait until either the last frame went out or that
  # connection is gone, and only then acknowledge the barriers the closed
  # connection never reached.
  defp release_held_compaction!(upstream, release_ref, next_barrier) do
    connection = held_connection(upstream)
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)

    await!(
      fn ->
        receive do
          {:fake_upstream_frame_barrier, 3, _handler, ^release_ref} -> true
        after
          0 -> not FakeUpstream.websocket_connection_alive?(upstream, connection)
        end
      end,
      "the held provider reply neither finished nor lost its connection"
    )

    for barrier <- next_barrier..3//1, do: FakeUpstream.acknowledge(upstream, {:frame_barrier, release_ref, barrier})
    :ok
  end

  defp held_connection(upstream) do
    %{websocket_connection_id: connection} = Enum.find(FakeUpstream.requests(upstream), &(&1.json["previous_response_id"] == @anchor))
    connection
  end

  defp await_barrier!(barrier, release_ref) do
    receive do
      {:fake_upstream_frame_barrier, ^barrier, _handler, ^release_ref} -> :ok
    after
      @detection_timeout_ms -> flunk("the upstream never reached frame barrier #{barrier}")
    end
  end

  defp upstream_sequence(ctx, cut, topology, release_ref) do
    turn = FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor, t1_output(ctx.shape)))

    anchored =
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        websocket_connection_ordinal: 1,
        json: [valid: true, equals: lite_marker_expectation(%{"type" => "response.create", "previous_response_id" => @anchor}, ctx.mode)],
        respond:
          if(cut == :no_cut,
            do: compaction_frames(compaction_item("served"), @cut_response),
            else: FakeUpstream.barrier_websocket_frames(held_compaction_messages(), notify: self(), release_ref: release_ref)
          )
      )

    resume = FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@final_response, []))

    full_history =
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        json: [valid: true, equals: lite_marker_expectation(%{"type" => "response.create"}, ctx.mode), forbidden: ["previous_response_id"]],
        respond: compaction_frames(compaction_item("resend"), @resend_response)
      )

    case {cut, topology} do
      {:no_cut, _topology} ->
        [turn, anchored, resume]

      {:unobserved_cut, :direct} ->
        https_compaction =
          FakeUpstream.expect_request(
            method: "POST",
            path: @turn_endpoint,
            json: [valid: true, forbidden: ["previous_response_id", "type"]],
            respond: FakeUpstream.sse_stream(compaction_events(compaction_item("https"), @resend_response))
          )

        https_resume =
          FakeUpstream.expect_request(method: "POST", path: @turn_endpoint, json: [valid: true, forbidden: ["previous_response_id"]], respond: FakeUpstream.sse_stream(completed_events(@final_response)))

        [turn, anchored, https_compaction, https_resume]

      _websocket_resend ->
        [turn, anchored, full_history, resume]
    end
  end

  defp lite_marker_expectation(expected, "lite"), do: Map.put(expected, "client_metadata.#{@lite_marker}", "true")
  defp lite_marker_expectation(expected, "full"), do: expected

  defp compaction_request?(%{json: %{"input" => input}}) when is_list(input), do: match?(%{"type" => "compaction_trigger"}, List.last(input))
  defp compaction_request?(_request), do: false

  # A charge is a settlement that billed known usage.
  defp charges(%Request{id: request_id}) do
    Repo.aggregate(
      from(entry in LedgerEntry, where: entry.request_id == ^request_id and entry.entry_kind == "settlement" and entry.usage_status == "usage_known" and entry.settled_cost_micros > 0),
      :count
    )
  end

  # Both a websocket compaction and its HTTPS fallback (which the Pooler
  # bridges to a compact request) are recorded on the compact endpoint.
  defp compaction_row?(%Request{endpoint: endpoint}), do: endpoint == @compact_endpoint

  # Chained to its predecessor: the owner's client-retry link, or the resend
  # policy's `client_resend` marker when owner forwarding is off.
  defp chained?(%Request{request_metadata: %{"client_resend" => %{"predecessor_request_id" => predecessor}}}) when is_binary(predecessor), do: true
  defp chained?(%Request{id: request_id}), do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^request_id))

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id]))

  # Every response task settles its request after the terminal frame, and a
  # cut request after the closing socket's drain; no completion signal reaches
  # the test, so poll the rows within a bounded detection budget.
  defp await_compaction_settled!(pool_id, statuses) do
    await!(fn -> Enum.any?(pool_requests(pool_id), &(&1.endpoint == @compact_endpoint and &1.status in statuses)) end, "the compaction never settled")
  end

  defp await_settled!(pool_id) do
    await!(fn -> Enum.all?(pool_requests(pool_id), &(&1.status not in ["accepted", "in_progress"])) end, "requests did not settle")
    pool_requests(pool_id)
  end

  defp await!(condition, message) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(condition)
    |> Enum.reduce_while(nil, fn
      true, _acc ->
        {:halt, :ok}

      false, _acc ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk(message)
        Process.sleep(10)
        {:cont, nil}
    end)
  end

  defp connect!(port, setup) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", @thread_id},
      {"thread-id", @thread_id},
      {"x-client-request-id", @thread_id},
      {"x-codex-window-id", @window_id}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/backend-api/codex/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp ordinary_turn!(client, frame), do: client |> send_frame!(frame) |> ordinary_turn!()

  defp ordinary_turn!(client) do
    {client, frames} = receive_until_terminal(client, [])
    assert List.last(frames) == "response.completed", inspect(frames)
    client
  end

  defp receive_until_terminal(client, seen) do
    {client, frame} = receive_frame!(client)
    seen = [frame["type"] | seen]

    if frame["type"] in ["response.completed", "error", "response.failed"],
      do: {client, Enum.reverse(seen)},
      else: receive_until_terminal(client, seen)
  end

  defp send_frame!(client, text) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, text)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_frame!(client) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    {%{client | conn: conn, websocket: websocket}, CodexPooler.JSON.decode!(text)}
  end

  # The owner arms a forwarded admission after the terminal frame left it;
  # poll its authoritative state until it is armed for the attached socket.
  # The direct upstream session arms before its turn settles.
  defp await_armed!(:direct, setup), do: await!(fn -> match?([%Request{status: "succeeded"}], pool_requests(setup.pool.id)) end, "the first turn never settled")

  defp await_armed!(:peer, setup), do: await_owner_armed!(setup.peer_owner.owner_pid)

  defp await_armed!(:forwarded, setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    await_owner_armed!(owner)
  end

  defp await_owner_armed!(owner) do
    await!(
      fn ->
        match?(
          %{native_compaction_admission: %NativeCompactionAdmission{phase: :pending_compact}, native_compaction_admission_downstream: %{pid: pid}, downstream: %{pid: pid}},
          :sys.get_state(owner)
        )
      end,
      "the owner never armed the native compaction admission for the attached socket"
    )
  end

  defp put_owner_forwarding!(enabled?) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)

    on_exit(fn ->
      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp compaction_item(label), do: %{"type" => "compaction", "encrypted_content" => "synthetic-preturn-cut-#{label}"}

  defp prompt(label), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{label} prompt"}]}

  defp answer, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

  defp function_call, do: %{"type" => "function_call", "call_id" => "call_preturn_cut", "name" => "shell", "arguments" => "{}"}

  defp function_call_output, do: %{"type" => "function_call_output", "call_id" => "call_preturn_cut", "output" => "synthetic output"}

  defp t1_output(shape) when shape in [:pre_turn, :standalone_turn], do: [answer()]
  defp t1_output(:mid_turn), do: [function_call()]

  # What the compaction adds after the anchor: the pre-turn compaction only the
  # trigger, a mid-turn one the tool round's outputs and the trigger.
  defp compaction_delta(shape) when shape in [:pre_turn, :standalone_turn], do: [%{"type" => "compaction_trigger"}]
  defp compaction_delta(:mid_turn), do: [function_call_output(), %{"type" => "compaction_trigger"}]

  # The pre-turn compaction runs inside the next turn, a mid-turn one inside
  # its own, a manual `/compact` in a standalone turn of its own.
  defp compaction_turn(:pre_turn), do: @next_turn_id
  defp compaction_turn(:mid_turn), do: @turn_id
  defp compaction_turn(:standalone_turn), do: @standalone_turn_id

  # The turn that continues on the compacted history: the pre-turn and
  # mid-turn compaction's own turn, the next user turn after a standalone one.
  defp resume_turn(:standalone_turn), do: @next_turn_id
  defp resume_turn(shape), do: compaction_turn(shape)

  # After a pre-turn or manual compaction the next user turn opens on the
  # compacted history; after a mid-turn one the same turn continues on it with
  # no new user message (one carrying a user message after the compaction item
  # would open a new turn, which a reused turn id is refused over HTTPS).
  defp resume_delta(:mid_turn), do: []
  defp resume_delta(_shape), do: [prompt("next")]

  # The released Lite client opens a provider context with its tool manifest.
  defp context_prefix("lite"), do: [%{"type" => "additional_tools", "role" => "developer", "tools" => []}]
  defp context_prefix("full"), do: []

  defp turn_frame(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first")], @turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  defp anchored_compaction_frame(ctx) do
    ctx
    |> frame(compaction_delta(ctx.shape), compaction_turn(ctx.shape), @window_id)
    |> Map.put("previous_response_id", @anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata(ctx.shape))
    |> CodexPooler.JSON.encode!()
  end

  defp full_history_compaction_frame(ctx), do: ctx |> full_history_compaction_payload() |> CodexPooler.JSON.encode!()

  defp full_history_compaction_payload(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first") | t1_output(ctx.shape)] ++ compaction_delta(ctx.shape), compaction_turn(ctx.shape), @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata(ctx.shape))
  end

  defp resume_frame(ctx, label) do
    {payload, _metadata} = resume_payload(ctx, label)
    CodexPooler.JSON.encode!(payload)
  end

  defp resume_payload(ctx, label) do
    turn_id = resume_turn(ctx.shape)
    metadata = turn_metadata(%{"request_kind" => "turn", "turn_id" => turn_id, "root_turn_id" => turn_id, "window_id" => @resumed_window_id, "window_number" => 1, "context_window_id" => @resumed_context_window_id})

    payload =
      ctx
      |> frame(context_prefix(ctx.mode) ++ [compaction_item(label) | resume_delta(ctx.shape)], turn_id, @resumed_window_id)
      |> put_in(["client_metadata", "x-codex-turn-metadata"], metadata)

    {payload, metadata}
  end

  defp compaction_metadata(shape) do
    turn_id = compaction_turn(shape)
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => Atom.to_string(shape), "strategy" => "memento"}
    compaction = if shape == :standalone_turn, do: %{compaction | "trigger" => "manual", "reason" => "user_requested"}, else: compaction
    turn_metadata(%{"request_kind" => "compaction", "compaction" => compaction, "turn_id" => turn_id, "root_turn_id" => turn_id})
  end

  # Full: the released client's top-level `instructions` and `tools`, parallel
  # tool calls on. Lite (`use_responses_lite` in the catalog): neither
  # top-level key, parallel tool calls off, and the Lite marker in
  # `client_metadata` (P63 wire probe of Codex 0.156.1 on a Lite model).
  defp frame(ctx, input, turn_id, window_id) do
    client_metadata = %{
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "turn_id" => turn_id,
      "root_turn_id" => turn_id,
      "x-codex-installation-id" => @installation_id,
      "x-codex-window-id" => window_id,
      "x-codex-ws-stream-request-start-ms" => Integer.to_string(System.system_time(:millisecond))
    }

    base = %{
      "type" => "response.create",
      "model" => ctx.setup.model.exposed_model_id,
      "input" => input,
      "tool_choice" => "auto",
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "text" => %{"verbosity" => "low"},
      "prompt_cache_key" => @thread_id
    }

    case ctx.mode do
      "full" -> Map.merge(base, %{"instructions" => "synthetic instructions", "tools" => [], "parallel_tool_calls" => true, "client_metadata" => client_metadata})
      "lite" -> Map.merge(base, %{"parallel_tool_calls" => false, "client_metadata" => Map.put(client_metadata, @lite_marker, "true")})
    end
  end

  defp turn_metadata(extra) do
    %{
      "agent_name" => "/root",
      "analytics_enabled" => true,
      "auto_review_enabled" => false,
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "root_turn_id" => @turn_id,
      "sandbox" => "seatbelt",
      "sandbox_mode" => "read-only",
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "turn_id" => @turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "window_id" => @window_id,
      "window_number" => 0,
      "model" => "gpt-test-model",
      "reasoning_effort" => "low"
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  defp usage, do: %{"input_tokens" => 20_000, "output_tokens" => 10, "total_tokens" => 20_010}

  defp completed_frames(response_id, output) do
    FakeUpstream.websocket_text_frames(
      [CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}})] ++
        Enum.map(output, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
        [CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => usage()}})]
    )
  end

  defp held_compaction_messages do
    item = compaction_item("cut")

    [
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => @cut_response, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => @cut_response, "status" => "completed", "output" => [item], "usage" => usage()}})
    ]
  end

  defp compaction_frames(item, response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => usage()}})
    ])
  end

  defp compaction_events(item, response_id) do
    [
      %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}},
      %{"type" => "response.output_item.done", "item" => item},
      %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => usage()}}
    ]
  end

  defp completed_events(response_id) do
    [
      %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}},
      %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => usage()}}
    ]
  end
end
