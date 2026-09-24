defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketFullHistoryCompactionCutTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2]

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  # A NON-admitted native compaction cut before the client saw anything
  # (findings#206 row 206-333). The released client (Codex 0.156.1) sends a
  # compaction as full history on a connection that cannot resolve the
  # anchor (after any `503` refusal of the anchored one, or on a new
  # connection); when that connection is cut it resends the same full history
  # twice on new connections and then falls back to HTTPS (P69 wire probe).
  # With owner forwarding on, the owner armed the cut compaction for replay
  # like an ordinary pre-visible turn, but no resend of a compaction can
  # redeem that replay: the resend policy refuses a predecessor with a replay
  # entitlement, so both websocket resends met `409 duplicate_turn` and the
  # compaction stayed `in_progress` for more than 118 s (until the replay
  # expired), while the HTTPS fallback bought it again. The owner no longer
  # arms a compaction for replay: the cut compaction settles when its socket's
  # detach arrives and the first resend is its successor, one charge per
  # request.
  # Without forwarding the closing socket settles it within its drain. The
  # ordinary Responses turn keeps its replay (the last test). The provider
  # finishes the cut generation right after the cut; frames keep the released
  # client's key sets and identifiers, prompt text and reply frames are
  # synthetic. One node.
  @thread_id "019a0000-0000-7000-8000-00000000f101"
  @window_id "#{@thread_id}:0"
  @resumed_window_id "#{@thread_id}:1"
  @turn_id "019a0000-0000-7000-8000-00000000f102"
  @next_turn_id "019a0000-0000-7000-8000-00000000f106"
  @installation_id "00000000-0000-4000-8000-00000000f103"
  @context_window_id "00000000-0000-4000-8000-00000000f104"
  @resumed_context_window_id "00000000-0000-4000-8000-00000000f105"
  @anchor "resp_fullhist_cut_anchor0000001"
  @cut_response "resp_fullhist_cut_compact_cut01"
  @resend_response "resp_fullhist_cut_compact_resnd"
  @final_response "resp_fullhist_cut_final00000001"
  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"
  @compact_endpoint "/backend-api/codex/responses/compact"
  @turn_endpoint "/backend-api/codex/responses"
  @detection_timeout_ms 5_000
  # Detection budget for every counted row to settle; no signal reaches the test.
  @settle_timeout_ms 15_000

  for mode <- ["full", "lite"], topology <- [:forwarded, :direct], cut <- [:before_output, :after_output] do
    @tag mode: mode, topology: topology, cut: cut
    test "#{mode} #{topology} full-history compaction cut #{cut}: it settles and the first resend is its successor",
         %{mode: mode, topology: topology, cut: cut} do
      assert run_scenario(mode, topology, cut) == %{
               predecessor_settled?: true,
               retries: [:served],
               successor_chained?: true,
               max_charges_per_request: 1,
               upstream_compactions: 2,
               replay_entitlements: [],
               live_rows: 0
             }
    end
  end

  # The released client retries a compaction stream that failed on a new
  # connection about 200 ms after the failure (`compact_remote_v2.rs`, two
  # websocket retries). The cut socket's owner detach comes from its session
  # cleanup, after a 250 ms drain and a cleanup the socket waits on for 100 ms
  # only; here that cleanup is held at its first query until the retries
  # resolved. A full-history compaction is collected with its request identity,
  # so the retry's attach is handed only the next epoch and the cut socket
  # stays the owner's downstream until its detach arrives (findings#206 row
  # 206-454): the retry met the owner busy (`409 duplicate_turn`) and so did
  # the second one, and the compaction was bought again over HTTPS.
  # The `peer` arm runs the session's owner and its provider connection on a
  # second VM sharing the committed database, the sockets on this node (Full
  # only: the Lite override commits an owner session).
  for {mode, topology} <- [{"full", :forwarded}, {"lite", :forwarded}, {"full", :peer}] do
    @tag mode: mode, topology: topology, cut: :observed_cut
    test "#{mode} #{topology} full-history compaction cut with the closed socket's cleanup held: the released client's first retry is served", %{mode: mode, topology: topology} do
      assert run_scenario(mode, topology, :observed_cut) == %{
               predecessor_settled?: true,
               retries: [:served],
               successor_chained?: true,
               max_charges_per_request: 1,
               upstream_compactions: 2,
               replay_entitlements: [],
               live_rows: 0
             }
    end
  end

  # The same collection handed on from a connection the Pooler has not seen
  # close keeps the refusal: both websocket retries meet the running
  # collection, and the HTTPS fallback, which arrives after the Pooler settled
  # it, is its successor.
  for {mode, topology} <- [{"full", :forwarded}, {"lite", :forwarded}, {"full", :peer}] do
    @tag mode: mode, topology: topology, cut: :unobserved_cut
    test "#{mode} #{topology} full-history compaction whose connection the Pooler has not seen close: the retries are refused until it settles", %{mode: mode, topology: topology} do
      assert run_scenario(mode, topology, :unobserved_cut) == %{
               predecessor_settled?: true,
               retries: [{409, "duplicate_turn"}, {409, "duplicate_turn"}, :http_served],
               successor_chained?: true,
               max_charges_per_request: 1,
               upstream_compactions: 2,
               replay_entitlements: [],
               live_rows: 0
             }
    end
  end

  # The ordinary Responses turn keeps its replay: the owner arms a turn cut
  # before any output reached the client and the released client's identical
  # resend redeems it on the owner (findings#232), with no second request.
  for mode <- ["full", "lite"] do
    @tag mode: mode
    test "#{mode} forwarded ordinary turn cut before output: the owner still arms its replay and the resend redeems it", %{mode: mode} do
      assert run_ordinary_replay(mode) == %{
               retries: [:served],
               rows: [{@turn_endpoint, "succeeded"}, {@turn_endpoint, "succeeded"}],
               replay_entitlements: ["consumed"],
               upstream_turns: 3,
               live_rows: 0
             }
    end
  end

  defp run_ordinary_replay(mode) do
    put_owner_forwarding!(true)
    release_ref = make_ref()
    ctx = %{mode: mode}
    held = FakeUpstream.barrier_websocket_frames(held_turn_messages(), notify: self(), release_ref: release_ref)
    turn = [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]]

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: turn, respond: completed_frames(@anchor, [answer()])),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: turn, respond: held),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: turn, respond: completed_frames(@final_response, [answer()]))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    ctx = Map.put(ctx, :setup, setup)
    port = start_public_endpoint!()

    first = connect!(port, setup)
    first = ordinary_turn!(first, turn_frame(ctx))
    Mint.HTTP.close(first.conn)
    await!(fn -> match?([%Request{status: "succeeded"}], pool_requests(setup.pool.id)) end, "the first turn never settled")

    second = connect!(port, setup)
    second = send_frame!(second, next_turn_frame(ctx))
    await_barrier!(0, release_ref)
    Mint.HTTP.close(second.conn)
    await!(fn -> replay_entitlements(setup.pool.id) != [] end, "the owner never armed the cut turn's replay")
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)

    third = connect!(port, setup)

    retries =
      try do
        case third |> send_frame!(next_turn_frame(ctx)) |> receive_until_terminal([]) do
          {_client, frames} -> if List.last(frames) == "response.completed", do: [:served], else: [frames]
        end
      after
        Mint.HTTP.close(third.conn)
      end

    rows = await_no_live_requests(setup.pool.id)

    measured = %{
      retries: retries,
      rows: Enum.map(rows, &{&1.endpoint, &1.status}),
      replay_entitlements: replay_entitlements(setup.pool.id),
      upstream_turns: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-333 ordinary replay #{mode}: #{inspect(measured)}" end)
    measured
  end

  defp replay_entitlements(pool_id), do: Repo.all(from(entitlement in RequestReplayEntitlement, where: entitlement.pool_id == ^pool_id, select: entitlement.status))

  defp next_turn_frame(ctx) do
    metadata = %{"request_kind" => "turn", "turn_id" => @next_turn_id, "root_turn_id" => @next_turn_id}

    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first"), answer(), prompt("next")], @next_turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(metadata))
    |> CodexPooler.JSON.encode!()
  end

  defp held_turn_messages do
    [
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => @cut_response, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => answer()}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => @cut_response, "status" => "completed", "output" => [answer()], "usage" => usage()}})
    ]
  end

  defp run_scenario(mode, topology, cut) do
    put_owner_forwarding!(topology in [:forwarded, :peer])
    release_ref = make_ref()
    ctx = %{mode: mode}

    held = FakeUpstream.barrier_websocket_frames(held_compaction_messages(), notify: self(), release_ref: release_ref)
    compaction = [valid: true, equals: lite_marker_expectation(%{"type" => "response.create"}, mode), forbidden: ["previous_response_id"]]

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}], respond: completed_frames(@anchor, [answer()])),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: compaction, respond: held)
          | resend_expectations(cut, compaction)
        ])
      )

    setup = topology_setup!(topology, upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    ctx = Map.put(ctx, :setup, setup)
    port = start_public_endpoint!()

    # The first turn on its own connection, which the client then leaves: the
    # compaction goes out as full history on a new one and is not admitted.
    first = connect!(port, setup)
    first = ordinary_turn!(first, turn_frame(ctx))
    Mint.HTTP.close(first.conn)
    await!(fn -> match?([%Request{status: "succeeded"}], pool_requests(setup.pool.id)) end, "the first turn never settled")

    second = connect!(port, setup)
    second = send_frame!(second, full_history_compaction_frame(ctx))
    await_barrier!(0, release_ref)

    if cut == :after_output do
      for barrier <- [1, 2] do
        :ok = FakeUpstream.release_frame(upstream, release_ref)
        await_barrier!(barrier, release_ref)
      end
    end

    {settled?, retries} =
      case cut do
        :observed_cut ->
          cut_with_cleanup_held(ctx, second, port, upstream, release_ref)

        :unobserved_cut ->
          unobserved_cut(ctx, second, port, upstream, release_ref)

        _cut ->
          Mint.HTTP.close(second.conn)
          _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
          settled? = settled_within?(setup.pool.id, @detection_timeout_ms)
          {settled?, released_client_retries!(ctx, port, fn -> :ok end)}
      end

    rows = await_no_live_requests(setup.pool.id)
    compactions = Enum.filter(rows, &(&1.endpoint == @compact_endpoint))

    measured = %{
      predecessor_settled?: settled?,
      retries: retries,
      successor_chained?: match?([_predecessor, successor] when is_struct(successor, Request), compactions) and chained?(List.last(compactions)),
      max_charges_per_request: compactions |> Enum.map(&charges/1) |> Enum.max(),
      upstream_compactions: upstream |> FakeUpstream.requests() |> Enum.count(&compaction_request?/1),
      replay_entitlements: replay_entitlements(setup.pool.id),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-333 #{mode} #{topology} #{cut}: #{inspect(measured)}" end)
    if measured.predecessor_settled?, do: assert(:ok = FakeUpstream.verify!(upstream))
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

  defp resend_expectations(:unobserved_cut, _compaction) do
    [
      FakeUpstream.expect_request(method: "POST", path: @turn_endpoint, json: [valid: true, forbidden: ["previous_response_id", "type"]], respond: FakeUpstream.sse_stream(compaction_events(compaction_item("https"), @resend_response))),
      FakeUpstream.expect_request(method: "POST", path: @turn_endpoint, json: [valid: true, forbidden: ["previous_response_id"]], respond: FakeUpstream.sse_stream(completed_events(@final_response)))
    ]
  end

  defp resend_expectations(_cut, compaction) do
    [
      FakeUpstream.expect_request(method: "WEBSOCKET", json: compaction, respond: compaction_frames(compaction_item("resend"), @resend_response)),
      FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@final_response, []))
    ]
  end

  # The client gave up on the connection but the Pooler has not seen it close
  # yet: the collection is still live when both websocket retries arrive, and
  # the Pooler settles it before the HTTPS fallback.
  defp unobserved_cut(ctx, client, port, upstream, release_ref) do
    settle = fn ->
      Mint.HTTP.close(client.conn)
      release_held_compaction!(upstream, release_ref)
      await!(fn -> Enum.any?(pool_requests(ctx.setup.pool.id), &(&1.endpoint == @compact_endpoint and &1.status not in ["accepted", "in_progress"])) end, "the collection never settled")
    end

    retries = released_client_retries!(ctx, port, settle)
    {settled_within?(ctx.setup.pool.id, @detection_timeout_ms), retries}
  end

  # The connection closes before the provider produced anything and the
  # Pooler sees it close; its session cleanup is held, so the retries meet a
  # predecessor that is still live. The provider finishes the cut generation
  # once the retries resolved.
  defp cut_with_cleanup_held(ctx, client, port, upstream, release_ref) do
    hold = hold_session_cleanup!()
    Mint.HTTP.close(client.conn)
    assert_receive {^hold, :held, cleanup}, @settle_timeout_ms
    assert Enum.any?(pool_requests(ctx.setup.pool.id), &(&1.endpoint == @compact_endpoint and &1.status == "in_progress"))

    release = fn ->
      release_session_cleanup!(hold, cleanup)
      :ok
    end

    retries = released_client_retries!(ctx, port, release)
    if List.last(retries) == :served, do: release.()
    release_held_compaction!(upstream, release_ref)
    {settled_within?(ctx.setup.pool.id, @detection_timeout_ms), retries}
  end

  # The provider finishes the cut generation, as a live provider would. The
  # Pooler may have closed that provider connection when it cancelled the
  # generation, and then the rest of the reply is never pushed: wait until
  # either the last frame went out or the connection is gone, and only then
  # acknowledge the barriers the closed connection never reached.
  defp release_held_compaction!(upstream, release_ref) do
    %{websocket_connection_id: connection} = upstream |> FakeUpstream.requests() |> Enum.find(&compaction_request?/1)
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

    for barrier <- 1..3, do: FakeUpstream.acknowledge(upstream, {:frame_barrier, release_ref, barrier})
    :ok
  end

  # Holds the next socket session cleanup that starts from here on (the closed
  # connection's; nothing else closes meanwhile) right after its first query
  # made outside a transaction, whose connection is already back in the pool.
  defp hold_session_cleanup! do
    hold = make_ref()
    handler_id = {__MODULE__, :session_cleanup_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    config = %{hold: hold, test: self(), claimed: :atomics.new(1, [])}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.hold_session_cleanup_query/4, config)
    hold
  end

  @doc false
  def hold_session_cleanup_query(_event, _measurements, metadata, %{hold: hold, test: test, claimed: claimed}) do
    if match?({CodexPoolerWeb.WebsocketControlPath, _function, _arity}, Process.get(:"$initial_call")) and metadata[:query] not in ["begin", "commit"] and
         not Repo.in_transaction?() and :atomics.add_get(claimed, 1, 1) == 1 do
      send(test, {hold, :held, self()})

      receive do
        {^hold, :release} -> :ok
      after
        @settle_timeout_ms -> :ok
      end
    end

    :ok
  end

  defp release_session_cleanup!(hold, cleanup) do
    :telemetry.detach({__MODULE__, :session_cleanup_hold, hold})
    monitor = Process.monitor(cleanup)
    send(cleanup, {hold, :release})
    assert_receive {:DOWN, ^monitor, :process, ^cleanup, _reason}, @settle_timeout_ms
    :ok
  end

  # No completion signal reaches the test: poll the compaction row within a
  # bounded detection budget.
  defp settled_within?(pool_id, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms

    Stream.repeatedly(fn -> Enum.find(pool_requests(pool_id), &(&1.endpoint == @compact_endpoint)) end)
    |> Enum.reduce_while(false, fn request, _acc ->
      cond do
        match?(%Request{status: status} when status not in ["accepted", "in_progress"], request) -> {:halt, true}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, false}
        true -> Process.sleep(10) && {:cont, false}
      end
    end)
  end

  # Every row the scenario counts must have settled before it is counted: poll
  # until no request of the Pool is live, within the detection budget, and
  # return the rows either way for the caller's assertion. It replaced a wait
  # for the first compaction row only, which the ordinary scenario (no
  # compaction row) waited out in full every run and the compaction scenarios
  # passed at once on the already settled predecessor while the last turn
  # could still be running (findings#206 rows 206-417, 206-422).
  defp await_no_live_requests(pool_id) do
    deadline = System.monotonic_time(:millisecond) + @settle_timeout_ms

    Stream.repeatedly(fn -> pool_requests(pool_id) end)
    |> Enum.reduce_while([], fn rows, _acc ->
      cond do
        rows != [] and not Enum.any?(rows, &(&1.status in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, rows}
      end
    end)
  end

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id]))

  defp compaction_request?(%{json: %{"input" => input}}) when is_list(input), do: match?(%{"type" => "compaction_trigger"}, List.last(input))
  defp compaction_request?(_request), do: false

  defp compaction_metadata do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}
    turn_metadata(%{"request_kind" => "compaction", "compaction" => compaction, "turn_id" => @next_turn_id, "root_turn_id" => @next_turn_id})
  end

  defp held_compaction_messages do
    item = compaction_item("cut")

    [
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => @cut_response, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => @cut_response, "status" => "completed", "output" => [item], "usage" => usage()}})
    ]
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
    compaction = post_native!(ctx, https_body(full_history_compaction_payload(ctx)), compaction_metadata(), @window_id)

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

  defp await_barrier!(barrier, release_ref) do
    receive do
      {:fake_upstream_frame_barrier, ^barrier, _handler, ^release_ref} -> :ok
    after
      @detection_timeout_ms -> flunk("the upstream never reached frame barrier #{barrier}")
    end
  end

  defp lite_marker_expectation(expected, "lite"), do: Map.put(expected, "client_metadata.#{@lite_marker}", "true")
  defp lite_marker_expectation(expected, "full"), do: expected

  # A charge is a settlement that billed known usage.
  defp charges(%Request{id: request_id}) do
    Repo.aggregate(
      from(entry in LedgerEntry, where: entry.request_id == ^request_id and entry.entry_kind == "settlement" and entry.usage_status == "usage_known" and entry.settled_cost_micros > 0),
      :count
    )
  end

  # Chained to its predecessor: the owner's client-retry link, or the resend
  # policy's `client_resend` marker when owner forwarding is off.
  defp chained?(%Request{request_metadata: %{"client_resend" => %{"predecessor_request_id" => predecessor}}}) when is_binary(predecessor), do: true
  defp chained?(%Request{id: request_id}), do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^request_id))

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

  # The released Lite client opens a provider context with its tool manifest.
  defp context_prefix("lite"), do: [%{"type" => "additional_tools", "role" => "developer", "tools" => []}]
  defp context_prefix("full"), do: []

  defp turn_frame(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first")], @turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  defp full_history_compaction_frame(ctx), do: ctx |> full_history_compaction_payload() |> CodexPooler.JSON.encode!()

  defp full_history_compaction_payload(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first"), answer(), %{"type" => "compaction_trigger"}], @next_turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata())
  end

  defp resume_frame(ctx, label) do
    {payload, _metadata} = resume_payload(ctx, label)
    CodexPooler.JSON.encode!(payload)
  end

  defp resume_payload(ctx, label) do
    turn_id = @next_turn_id
    metadata = turn_metadata(%{"request_kind" => "turn", "turn_id" => turn_id, "root_turn_id" => turn_id, "window_id" => @resumed_window_id, "window_number" => 1, "context_window_id" => @resumed_context_window_id})

    payload =
      ctx
      |> frame(context_prefix(ctx.mode) ++ [compaction_item(label), prompt("next")], turn_id, @resumed_window_id)
      |> put_in(["client_metadata", "x-codex-turn-metadata"], metadata)

    {payload, metadata}
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

  defp compaction_frames(item, response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => usage()}})
    ])
  end
end
