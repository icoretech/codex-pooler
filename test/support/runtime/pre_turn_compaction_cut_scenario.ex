defmodule CodexPoolerWeb.Runtime.PreTurnCompactionCutScenario do
  @moduledoc false

  # The released client's cut, resend and HTTPS fallback of an admitted native
  # compaction (findings#206 rows 206-310, 206-330, 206-332, 206-436, 206-455),
  # shared by `backend_codex_websocket_pre_turn_compaction_cut_test.exs` (one
  # node, owner forwarding on and off) and
  # `backend_codex_websocket_pre_turn_compaction_cut_peer_test.exs` (the
  # session's owner on a peer VM the module boots once, findings#206 row
  # 206-539). Each scenario runs inside the calling test process: its
  # `on_exit` callbacks and assertions belong to that test.

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.ConnTest, only: [build_conn: 0, post: 3]
  import Plug.Conn, only: [put_req_header: 3]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_shared_peer_window_owner!: 3]

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.{NativeCompactionAdmission, WebsocketOwnerSession}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  require Logger

  @endpoint CodexPoolerWeb.Endpoint

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

  # Rows are `{endpoint, transport, status, last_error_code, chained?}` in
  # admission order; `compaction_charges` lists each compaction request's
  # charges in the same order, so a request billed twice shows as a 2.
  def expected(:unobserved_cut, topology), do: expected_unobserved(topology)
  def expected(cut, _topology) when cut in [:observed_cut, :observed_cut_exited], do: expected(:before_output)

  # The cut predecessor's settlement is held past the socket's take-over wait
  # (findings#206 row 206-580): the first retry takes the compaction over but
  # cannot see it settle within the bound (`inherited_turn_unsettled`), meets
  # the still-running predecessor and is refused; the released client's next
  # retry is served as the successor, one generation per request.
  def expected(:observed_cut_settlement_held, _topology),
    do: %{expected(:before_output) | retries: [{409, "duplicate_turn", :inherited_turn_unsettled}, :served]}

  def expected(cut, _topology), do: expected(cut)

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

  # `opts`: `peer_node`, the module's shared peer for the `:peer` topology.
  def run_scenario(mode, shape, topology, cut, dispatch \\ :on_arrival, opts \\ []) do
    put_owner_forwarding!(topology in [:forwarded, :peer])
    release_ref = make_ref()
    ctx = %{mode: mode, shape: shape, topology: topology}

    upstream = start_upstream(FakeUpstream.strict_sequence(upstream_sequence(ctx, cut, topology, release_ref)))
    setup = topology_setup!(topology, upstream, opts)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    ctx = Map.put(ctx, :setup, setup)
    port = start_public_endpoint!()

    settling = if dispatch == :queued, do: hold_turn_task_after_settlement!()
    first = connect!(port, setup)
    first = ordinary_turn!(first, turn_frame(ctx))
    # The owner arms the admission only once the turn's response task is done:
    # a compaction queued behind that task is admitted at its dequeue.
    if dispatch == :on_arrival, do: await_armed!(topology, setup)
    # The strict upstream expects this compaction anchored on the admitted
    # response: it is dispatched on its first send.
    first = send_frame!(first, anchored_compaction_frame(ctx))
    if dispatch == :queued, do: dispatch_queued_compaction!(ctx, settling)
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
  defp topology_setup!(:peer, upstream, opts) do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream, compact?: true)
    Map.put(setup, :peer_owner, start_shared_peer_window_owner!(setup, @window_id, Keyword.fetch!(opts, :peer_node)))
  end

  # Owner forwarding off on committed rows, like the peer topology's, so a held
  # cleanup transaction holds its own connection only.
  defp topology_setup!(:direct_committed, upstream, _opts) do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream, compact?: true)
    register_unboxed_pool_cleanup!(setup)
    setup
  end

  defp topology_setup!(_topology, upstream, _opts), do: gateway_setup(upstream, compact?: true)

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

  defp cut_and_resend(cut, ctx, client, port, upstream, release_ref) when cut in [:observed_cut, :observed_cut_exited, :observed_cut_settlement_held] do
    await_barrier!(0, release_ref)
    closing_socket = if cut == :observed_cut_settlement_held, do: attached_socket!(ctx)
    # The connection closes before the provider produced anything and the
    # Pooler sees it close; its session cleanup is held.
    hold = hold_session_cleanups!(if(cut == :observed_cut_exited, do: 2, else: 1), ctx.topology)
    Mint.HTTP.close(client.conn)
    assert_receive {^hold, :held, cleanup}, @detection_timeout_ms
    # The retries meet a predecessor that is still live.
    assert Enum.any?(pool_requests(ctx.setup.pool.id), &(&1.endpoint == @compact_endpoint and &1.status == "in_progress"))
    cleanups = [cleanup | if(cut == :observed_cut_exited, do: [drop_inheriting_connection!(ctx, port, hold)], else: [])]

    release = fn ->
      release_session_cleanups!(hold, cleanups)
      await_compaction_settled!(ctx.setup.pool.id, ["succeeded", "failed"])
    end

    ctx = if cut == :observed_cut_settlement_held, do: hold_predecessor_settlement!(ctx, closing_socket), else: ctx
    retries = released_client_retries!(ctx, port, release)
    if List.last(retries) == :served, do: release.()
    release_held_compaction!(upstream, release_ref, 1)
    if cut == :observed_cut_settlement_held, do: retries, else: within_settlement_bound(retries, ctx)
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

  # The socket the owner streams the running compaction to, before its client
  # closes it.
  defp attached_socket!(ctx) do
    owner = owner_pid!(ctx.setup)
    %{downstream: %{pid: socket}} = :sys.get_state(owner)
    socket
  end

  # The first retry is served when the predecessor it took over settles within
  # the socket's take-over wait (two seconds). Only the cut request's own
  # settlement decides that, and on a starved machine it can come later: the
  # first retry is then refused with the take-over logged
  # `inherited_turn_unsettled`, and the next one is served, which is the bound
  # the product sets and `:observed_cut_settlement_held` pins with the
  # settlement held (findings#206 row 206-580: once in about 120 runs at a load
  # average of 15-27). Any other refusal, or that one followed by anything but
  # a served retry, stays in the result.
  defp within_settlement_bound([{409, "duplicate_turn", :inherited_turn_unsettled}, :served], ctx) do
    CodexPooler.TestDiagnostics.puts(fn -> "206-580 #{ctx.shape} #{ctx.topology}: the predecessor settled after the take-over wait" end)
    [:served]
  end

  defp within_settlement_bound(retries, _ctx), do: retries

  # Holds the cut request's settlement: the first query the closing socket's
  # own processes (its response task, which settles the request the owner
  # cancelled at the take-over) make once the retries start, other than its
  # session cleanup, which `hold_session_cleanups!/2` holds. Released when the
  # first retry has its answer, which comes only after the take-over wait. The
  # held query keeps its connection, so only the peer topology's committed rows
  # (a pooled connection each) can run it; on the single-node sandbox the held
  # connection is everyone's.
  defp hold_predecessor_settlement!(ctx, closing_socket) do
    hold = make_ref()
    handler_id = {__MODULE__, :settlement_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    config = %{hold: hold, test: self(), socket: closing_socket, claimed: :atomics.new(1, [])}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.hold_settlement_query/4, config)

    Map.put(ctx, :after_first_retry, fn ->
      :telemetry.detach(handler_id)
      assert_received {^hold, :held, settler}, "the cut request's settlement never started while the first retry waited"
      send(settler, {hold, :release})
      await_cut_compaction_settled!(ctx.setup.pool.id)
    end)
  end

  # The held query can be any step of the cut request's settlement, which writes
  # the request and attempt and then the turn. The next retry is sent once the
  # whole settlement is visible, as the released client's retry comes about
  # 400 ms after the refusal: sent at once, it could land between those writes,
  # where the replay preflight closes the still-open turn as orphaned
  # (`orphaned_turn_closed`) and the predecessor is no longer a resendable cut
  # (findings#206 row 206-607, seen on a CI runner).
  defp await_cut_compaction_settled!(pool_id) do
    await!(
      fn ->
        Repo.all(
          from(request in Request,
            join: turn in CodexTurn,
            on: turn.request_id == request.id,
            where: request.pool_id == ^pool_id and request.endpoint == @compact_endpoint,
            select: {request.status, turn.status}
          )
        )
        |> Enum.all?(fn {request_status, turn_status} -> request_status not in ["accepted", "in_progress"] and turn_status != "in_progress" end)
      end,
      "the cut compaction's settlement never finished after its hold was released"
    )
  end

  @doc false
  def hold_settlement_query(_event, _measurements, _metadata, %{hold: hold, test: test, socket: socket, claimed: claimed}) do
    if socket in Process.get(:"$callers", []) and not match?({CodexPoolerWeb.WebsocketControlPath, _function, _arity}, Process.get(:"$initial_call")) and
         :atomics.add_get(claimed, 1, 1) == 1 do
      send(test, {hold, :held, self()})

      receive do
        {^hold, :release} -> :ok
      after
        @detection_timeout_ms -> :ok
      end
    end

    :ok
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
    outcome = full_history_resend!(ctx, port)

    ctx =
      case Map.pop(ctx, :after_first_retry) do
        {nil, ctx} ->
          ctx

        {after_first_retry, ctx} ->
          after_first_retry.()
          ctx
      end

    case outcome do
      :served -> {:served, Enum.reverse([:served | outcomes])}
      refused -> websocket_retries!(ctx, port, remaining - 1, [refused | outcomes])
    end
  end

  # One websocket retry: a new connection and the same compaction as full
  # history; when it is served the turn continues on that connection. The
  # released client waits about 200 ms before its next retry, and what that
  # retry meets depends on the closed connection's session cleanup (its owner
  # detach): the next retry is sent once that cleanup finished, not the moment
  # the connection closed. Sent at once, it met the live predecessor whenever
  # the cleanup outlasted the socket's 100 ms yield (findings#206 row 206-425).
  #
  # A refused retry's own refusal lines (the replay preflight's or the claim's
  # bounded reason codes, info level) are logged again as a warning, so a
  # failing arm's captured log names why the retry was refused (findings#206
  # row 206-580: a peer arm's first retry refused once in about 120 runs
  # under a busy machine, with nothing but `cleanup_deferred` in its log).
  defp full_history_resend!(ctx, port) do
    cleanups = WebsocketCleanupFence.listener_socket_cleanups()
    client = connect!(port, ctx.setup)

    {outcome, log} =
      with_info_log(fn ->
        try do
          client = send_frame!(client, full_history_compaction_frame(ctx))

          case receive_frame!(client) do
            {_client, %{"type" => "error", "status" => status, "error" => %{"code" => code}}} ->
              {status, code, nil}

            {client, %{"type" => "response.output_item.done"}} ->
              {client, ["response.completed"]} = receive_until_terminal(client, [])
              client |> send_frame!(resume_frame(ctx, "resend")) |> ordinary_turn!()
              :served
          end
        after
          Mint.HTTP.close(client.conn)
        end
      end)

    if outcome != :served do
      for line <- String.split(log, "\n"), line =~ ~r/replay rejection|live predecessor|duplicate|reconnect disposition/ do
        Logger.warning("refused compaction retry: " <> String.trim(line))
      end
    end

    :ok = WebsocketCleanupFence.await_listener_socket_cleanups!(cleanups + 1)
    refused_retry(outcome, log)
  end

  # A refused retry names its status and code, and the take-over disposition
  # when the socket took the predecessor over but could not see it settle.
  defp refused_retry({status, code, nil}, log) do
    if log =~ "reconnect_disposition=inherited_turn_unsettled", do: {status, code, :inherited_turn_unsettled}, else: {status, code}
  end

  defp refused_retry(outcome, _log), do: outcome

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

  # A new connection attaches and receives the running compaction, then drops
  # before it sends anything; its cleanup is held as well, so the owner handles
  # its exit (no downstream, the compaction still bound to it) before the retry
  # attaches.
  defp drop_inheriting_connection!(ctx, port, hold) do
    owner = owner_pid!(ctx.setup)
    inheriting = connect!(port, ctx.setup)
    await!(fn -> match?(%{downstream: %{epoch: 2, active_turn_reconnect?: true}, active_turn: %{downstream: %{epoch: 2}}}, :sys.get_state(owner)) end, "the new connection never received the running compaction")
    Mint.HTTP.close(inheriting.conn)
    assert_receive {^hold, :held, cleanup}, @detection_timeout_ms
    await!(fn -> match?(%{downstream: nil, active_turn: %{downstream: %{epoch: 2}}}, :sys.get_state(owner)) end, "the owner never handled the exit of the connection that received the compaction")
    cleanup
  end

  defp owner_pid!(%{peer_owner: %{owner_pid: owner}}), do: owner

  defp owner_pid!(setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    owner
  end

  # Holds the next `count` socket session cleanups that start from here on (the
  # closed connections'; nothing else closes meanwhile) right after their first
  # query made outside a transaction, whose connection is already back in the
  # pool.
  #
  # With owner forwarding off the cleanup's first query opens the transaction
  # that stops the direct task, so there it is held at that query (committed
  # rows: the held connection stalls nobody else) and released as soon as a
  # claim starts waiting for the running request (the claim's
  # `live_predecessor_wait` event); nothing else releases it before the HTTPS
  # fallback.
  defp hold_session_cleanups!(count, topology) do
    hold = make_ref()
    held = :ets.new(:held_session_cleanups, [:public, :set])
    handler_id = {__MODULE__, :session_cleanup_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    config = %{hold: hold, test: self(), count: count, claimed: :atomics.new(1, []), held: held, any_query?: topology == :direct_committed}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.hold_session_cleanup_query/4, config)

    if topology == :direct_committed do
      wait_handler_id = {__MODULE__, :claim_wait_release, hold}
      on_exit(fn -> :telemetry.detach(wait_handler_id) end)
      :ok = :telemetry.attach(wait_handler_id, [:codex_pooler, :accounting, :websocket_turn_claim, :live_predecessor_wait], &__MODULE__.release_on_claim_wait/4, config)
    end

    hold
  end

  @doc false
  def release_on_claim_wait(_event, _measurements, _metadata, %{hold: hold, held: held}) do
    for {cleanup} <- :ets.tab2list(held), do: send(cleanup, {hold, :release})
    :ok
  end

  @doc false
  def hold_session_cleanup_query(_event, _measurements, metadata, %{hold: hold, test: test, count: count, claimed: claimed, held: held, any_query?: any_query?}) do
    if match?({CodexPoolerWeb.WebsocketControlPath, _function, _arity}, Process.get(:"$initial_call")) and (any_query? or (metadata[:query] not in ["begin", "commit"] and not Repo.in_transaction?())) and
         is_nil(Process.get({__MODULE__, hold})) and :atomics.add_get(claimed, 1, 1) <= count do
      Process.put({__MODULE__, hold}, :held)
      :ets.insert(held, {self()})
      send(test, {hold, :held, self()})

      receive do
        {^hold, :release} -> :ok
      after
        @detection_timeout_ms -> :ok
      end
    end

    :ok
  end

  defp release_session_cleanups!(hold, cleanups) do
    :telemetry.detach({__MODULE__, :session_cleanup_hold, hold})
    :telemetry.detach({__MODULE__, :claim_wait_release, hold})

    for cleanup <- cleanups do
      monitor = Process.monitor(cleanup)
      send(cleanup, {hold, :release})
      assert_receive {:DOWN, ^monitor, :process, ^cleanup, _reason}, @detection_timeout_ms
    end

    :ok
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
  defp await_armed!(topology, setup) when topology in [:direct, :direct_committed], do: await!(fn -> match?([%Request{status: "succeeded"}], pool_requests(setup.pool.id)) end, "the first turn never settled")

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

  # Holds the first response task that settles a websocket turn from here on
  # (the previous turn's) right after its settlement, outside any transaction,
  # so its socket still tracks it when the compaction arrives.
  defp hold_turn_task_after_settlement! do
    hold = make_ref()
    handler_id = {__MODULE__, :turn_settlement_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    config = %{hold: hold, test: self(), claimed: :atomics.new(1, [])}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :gateway, :stream, :outcome], &__MODULE__.hold_settled_turn_task/4, config)
    hold
  end

  @doc false
  def hold_settled_turn_task(_event, _measurements, %{outcome: "succeeded", downstream_transport: "websocket"}, %{hold: hold, test: test, claimed: claimed}) do
    if not Repo.in_transaction?() and :atomics.add_get(claimed, 1, 1) == 1 do
      send(test, {hold, :held, self(), Process.get(:"$callers", [])})

      receive do
        {^hold, :release} -> :ok
      after
        @detection_timeout_ms -> :ok
      end
    end

    :ok
  end

  def hold_settled_turn_task(_event, _measurements, _metadata, _config), do: :ok

  # The compaction is queued behind the held task on the socket that started
  # it; the task is then released, and the socket dispatches the compaction
  # when the task ends. With owner forwarding the owner runs it as a turn
  # keyed like the one the owner preflight records for an unqueued frame.
  defp dispatch_queued_compaction!(ctx, hold) do
    assert_receive {^hold, :held, task, callers}, @detection_timeout_ms
    :telemetry.detach({__MODULE__, :turn_settlement_hold, hold})
    await!(fn -> Enum.any?(callers, &compaction_queued?/1) end, "the compaction was never queued behind the settling turn")
    send(task, {hold, :release})

    if ctx.topology in [:forwarded, :peer] do
      owner = owner_pid!(ctx.setup)
      await!(fn -> match?(%{active_turn: %{admission_phase: phase}} when not is_nil(phase), :sys.get_state(owner)) end, "the queued compaction never reached the owner")
      assert %{active_turn: %{descriptor: %{kind: :native, semantic_turn_key: key}}} = :sys.get_state(owner)
      assert key == compaction_turn_key(ctx)
    end

    :ok
  end

  defp compaction_queued?(pid) do
    pid |> :sys.get_state(1_000) |> queued_frames(6) |> Enum.any?(&match?(%{endpoint: @compact_endpoint}, &1))
  catch
    :exit, _not_a_socket -> false
  end

  defp queued_frames(%{queued_response_payloads: queue}, _depth), do: :queue.to_list(queue)
  defp queued_frames(_term, 0), do: []
  defp queued_frames(%_{} = struct, depth), do: struct |> Map.from_struct() |> queued_frames(depth)
  defp queued_frames(map, depth) when is_map(map), do: Enum.flat_map(Map.values(map), &queued_frames(&1, depth - 1))
  defp queued_frames(tuple, depth) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&queued_frames(&1, depth - 1))
  defp queued_frames(_term, _depth), do: []

  # The compaction turn's semantic key under the socket's claim scope (the
  # client thread, bound to the session's Pool and key).
  defp compaction_turn_key(ctx) do
    [session] = Repo.all(from(session in CodexSession, where: session.pool_id == ^ctx.setup.pool.id))
    scope = WebsocketTurnIdentity.claim_scope(session, @thread_id)
    {:ok, %{semantic_turn_key: key}} = WebsocketTurnIdentity.resolve(%{"client_metadata" => %{"turn_id" => compaction_turn(ctx.shape)}}, scope)
    key
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
