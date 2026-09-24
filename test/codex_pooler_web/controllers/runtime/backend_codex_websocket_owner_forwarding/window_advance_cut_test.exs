defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.WindowAdvanceCutTest do
  # A turn cut on a socket whose session is keyed by an older window than the
  # one its frames carry (findings#206, P109 NEW row; icoretech/codex-pooler#429).
  #
  # The released Codex client (0.156.1) names `<thread>:<n>` in the upgrade's
  # `x-codex-window-id` and in every frame's metadata, and advances `n` after
  # every completed remote compaction. A process that compacts (after a turn,
  # or `thread/compact`) keeps its socket, so the socket's session stays keyed
  # by window n-1 while its frames carry window n. A resumed process that loses
  # the client's startup prewarm race opens its socket on window 0 while its
  # frames carry the restored window, which may already have a session of its
  # own. When a turn is cut on such a socket, the client reconnects with the
  # frames' window and resends the turn as full history; that upgrade joined
  # the other window's session, whose owner holds no replay for the turn, and
  # the resend met `owner_unavailable` at the replay preflight
  # (`public_code=duplicate_turn`) on all five websocket retries, the cut
  # request stayed behind an armed entitlement, and the client finished the
  # process over HTTPS. Measured by P109 with the released client on the
  # isolated runtime (`lite-cutfirst` 2 of 2, `full-cpu1-cut` 2 of 2).
  #
  # Frames keep the released client's key sets; identifiers, prompt text and
  # reply frames are synthetic. Owner forwarding on with the owner on this node
  # (`forwarded`) and on a second VM sharing the committed database (`peer`),
  # and owner forwarding off (`direct`). The resend is sent once the closing
  # socket armed the replay (forwarding on) or settled its turn (forwarding
  # off): the released client retries after about 200 ms and five times.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, stop_websocket_owner_session: 1, native_previous_response_retry_event: 0, with_info_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2]

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  alias Ecto.Adapters.SQL.Sandbox

  @thread_id "019a0000-0000-7000-8000-00000000c001"
  @window_0 "#{@thread_id}:0"
  @window_1 "#{@thread_id}:1"
  @turn_1 "019a0000-0000-7000-8000-00000000c002"
  @manual_turn "019a0000-0000-7000-8000-00000000c003"
  @turn_2 "019a0000-0000-7000-8000-00000000c004"
  @turn_3 "019a0000-0000-7000-8000-00000000c005"
  @installation_id "00000000-0000-4000-8000-00000000c006"
  @context_0 "00000000-0000-4000-8000-00000000c007"
  @context_1 "00000000-0000-4000-8000-00000000c008"
  @anchor "resp_window_advance_anchor_0001"
  @compacted "resp_window_advance_compact_001"
  @resumed "resp_window_advance_resumed_001"
  @cut "resp_window_advance_cut_0000001"
  @served "resp_window_advance_served_0001"
  @later "resp_window_advance_later_00001"
  @turn_4 "019a0000-0000-7000-8000-00000000c009"
  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"
  @websocket_retries 5
  @detection_timeout_ms 15_000

  @arms for(shape <- [:post_turn, :manual, :stale_resume], mode <- ["full", "lite"], topology <- [:forwarded, :direct], do: {shape, mode, topology}) ++
          [{:post_turn, "full", :peer}, {:stale_resume, "full", :peer}]

  setup do
    _previous = TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    :ok
  end

  for {shape, mode, topology} <- @arms do
    @tag shape: shape, serving_mode: mode, topology: topology
    test "#{shape} #{mode} #{topology}: a turn cut on a socket keyed by an older window is served on the reconnect's first websocket send",
         %{shape: shape, serving_mode: mode, topology: topology} do
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology in [:forwarded, :peer])
      release_ref = make_ref()
      upstream = start_upstream(FakeUpstream.strict_sequence(upstream_sequence(shape, release_ref)))
      setup = topology_setup!(topology, upstream)
      if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
      ctx = %{shape: shape, mode: mode, topology: topology, setup: setup}
      port = start_public_endpoint!()

      {cut_socket, cut_frame} = open_cut_socket!(ctx, port)
      outcomes = cut_and_reconnect!(ctx, port, cut_socket, cut_frame, release_ref)
      rows = settled_rows(setup.pool.id)

      measured = %{
        outcomes: outcomes,
        rows: Enum.map(rows, &{&1.transport, &1.status, &1.last_error_code}),
        entitlements: entitlement_statuses(setup.pool.id),
        sessions: session_count(setup.pool.id),
        upstream: FakeUpstream.count(upstream)
      }

      CodexPooler.TestDiagnostics.puts(fn -> "P115 #{shape} #{mode} #{topology}: #{inspect(measured)}" end)
      release_held_turn!(upstream, release_ref, shape)

      # Served on the reconnect's first websocket send: no refusal, no HTTPS.
      assert outcomes == [:served], inspect(measured)
      assert Enum.all?(rows, &(&1.transport == "websocket"))
      refute Enum.any?(rows, &(&1.status in ["accepted", "in_progress"]))
      refute "armed" in measured.entitlements
      # One generation per turn the client sent, plus the cut turn's single
      # re-dispatch: never a second generation of the served turn.
      assert measured.upstream == length(upstream_sequence(shape, release_ref))

      for %Request{status: "succeeded"} = request <- rows, do: assert(charges(request) == 1)
      assert Enum.count(rows, &(&1.status == "succeeded")) == length(upstream_sequence(shape, release_ref)) - 1
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  # What the window's re-pointed lookup leads to afterwards. A later process
  # on the window (a resume after the cut process ended) sends full history
  # on a new connection: it joins a session whose owner holds a live lease
  # and is served on its first send, without a new session, whether the
  # session its window leads to still has its owner (`owner_live`) or lost it
  # (`owner_expired`: the lookup never follows a window alias to a session
  # without a live lease, like every other window alias). `session_open`: the
  # window's own session still has a connection open when the other socket
  # takes the window over; that connection keeps its session, and a
  # continuation anchored on a response it produced rides the provider
  # connection that produced it. `foreign_anchor`: a new connection whose
  # first frame is anchored on a response the window's own session produced
  # (the released client never sends one: after any reconnect it resends full
  # history without the anchor) now joins the session the window leads to,
  # whose provider connection did not produce the anchor; it gets the answer
  # every anchored frame on a foreign connection gets, the provider's refusal
  # relayed as `previous_response_not_found`, once, with no second dispatch.
  @after_arms [
    {:post_turn, "full", :forwarded, :owner_live},
    {:post_turn, "lite", :forwarded, :owner_expired},
    {:stale_resume, "full", :forwarded, :owner_live},
    {:stale_resume, "lite", :forwarded, :owner_expired},
    {:stale_resume, "full", :forwarded, :session_open},
    {:stale_resume, "lite", :direct, :owner_live},
    {:stale_resume, "full", :direct, :session_open},
    {:stale_resume, "full", :peer, :owner_live},
    {:stale_resume, "full", :forwarded, :foreign_anchor},
    {:stale_resume, "lite", :direct, :foreign_anchor}
  ]

  for {shape, mode, topology, later} <- @after_arms do
    @tag shape: shape, serving_mode: mode, topology: topology, later: later
    test "#{shape} #{mode} #{topology} #{later}: after the cut the window leads to a coherent live session",
         %{shape: shape, serving_mode: mode, topology: topology, later: later} do
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology in [:forwarded, :peer])
      release_ref = make_ref()
      sequence = upstream_sequence(shape, release_ref) ++ later_upstream(later, topology)
      upstream = start_upstream(FakeUpstream.strict_sequence(sequence))
      setup = topology_setup!(topology, upstream)
      if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
      ctx = %{shape: shape, mode: mode, topology: topology, setup: setup}
      port = start_public_endpoint!()

      {cut_socket, cut_frame, open} = open_cut_socket_keeping!(ctx, port, later)
      assert cut_and_reconnect!(ctx, port, cut_socket, cut_frame, release_ref) == [:served]
      release_held_turn!(upstream, release_ref, shape)
      %Request{id: cut_request_id} = cut_request(setup.pool.id, shape)
      cut_session_id = request_session_id(cut_request_id)
      sessions = session_count(setup.pool.id)
      assert window_alias_session_id(setup, @window_1) == cut_session_id

      if later == :owner_expired, do: stop_owner!(ctx, cut_session_id)

      later_request =
        case later do
          :foreign_anchor ->
            client = connect!(port, setup, @window_1)
            {client, frames} = client |> send_frame!(anchored_frame(ctx, @turn_4)) |> receive_until_terminal([])
            close!(client)
            expected = if topology == :direct, do: native_previous_response_retry_event(), else: "response.completed"
            assert List.last(frames) == expected or List.last(frames)["type"] == expected, inspect(List.last(frames))
            latest_request(setup.pool.id)

          :session_open ->
            # The window's own session's still-open connection continues its
            # own turn, anchored on the response it produced there.
            open |> send_frame!(anchored_frame(ctx, @turn_2)) |> completed!() |> close!()
            latest_request(setup.pool.id)

          _process ->
            client = connect!(port, setup, @window_1)
            client |> send_frame!(window_1_frame(ctx, @turn_4, later_history(ctx))) |> completed!() |> close!()
            latest_request(setup.pool.id)
        end

      later_session_id = request_session_id(later_request.id)
      later_session = Repo.get!(CodexSession, later_session_id)

      CodexPooler.TestDiagnostics.puts(fn ->
        "P115 after #{shape} #{mode} #{topology} #{later}: #{inspect(%{cut_session: short(cut_session_id), later_session: short(later_session_id), sessions: {sessions, session_count(setup.pool.id)}, later: later_request.status})}"
      end)

      assert later_request.transport == "websocket"

      case later do
        :foreign_anchor when topology == :direct ->
          assert {later_request.status, later_request.last_error_code} == {"failed", "stream_incomplete"}
          refute Enum.any?(FakeUpstream.requests(upstream), &(&1.json["previous_response_id"] == @resumed))

        :foreign_anchor ->
          assert later_request.status == "succeeded"
          refute later_session_id == cut_session_id

        _served ->
          assert later_request.status == "succeeded"
      end

      case later do
        :owner_live ->
          # Joined the session the window leads to, the one that served the cut
          # turn, and no other session was opened.
          assert later_session_id == cut_session_id
          assert session_count(setup.pool.id) == sessions

        :owner_expired ->
          # Never the session whose owner is gone.
          refute later_session_id == cut_session_id

        later when later == :session_open or (later == :foreign_anchor and topology != :direct) ->
          assert later_session_id != cut_session_id
          [resumed, anchored] = upstream |> FakeUpstream.requests() |> Enum.filter(&(&1.json["previous_response_id"] == @resumed or List.last(&1.json["input"] || []) == prompt("second")))
          assert anchored.websocket_connection_id == resumed.websocket_connection_id

        _refused ->
          :ok
      end

      if later != :foreign_anchor or topology != :direct do
        assert later_session.status == "active"
        assert DateTime.compare(later_session.owner_lease_expires_at, DateTime.utc_now()) == :gt
      end

      unless later == :foreign_anchor and topology == :direct, do: assert(:ok = FakeUpstream.verify!(upstream))
    end
  end

  # Two live processes on one thread (findings#206 row 206-501; the client
  # does not do this, but nothing stops two processes resuming one thread).
  # The process holding window 1 has its turn in progress at the provider
  # while a process whose socket is keyed by window 0 sends a turn naming
  # window 1. The window stays with its holder (`kept`): the holder's own
  # reconnect after a cut names window 1 and must reach the owner holding its
  # replay (forwarding on) or its own settled predecessor (forwarding off).
  # The window-0 socket's turn is served on its own session either way.
  @guard_arms [{"lite", :forwarded, :undisturbed}, {"lite", :forwarded, :holder_cut}, {"full", :forwarded, :holder_cut}, {"full", :direct, :holder_cut}]

  for {mode, topology, holder} <- @guard_arms do
    @tag serving_mode: mode, topology: topology, holder: holder
    test "#{mode} #{topology} #{holder}: a frame naming a window whose holder has a turn in progress leaves the window with its holder",
         %{serving_mode: mode, topology: topology, holder: holder} do
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology == :forwarded)
      release_ref = make_ref()
      sequence = [turn_1_upstream(), compaction_upstream(), held_upstream(release_ref), served_upstream()] ++ if(holder == :holder_cut, do: [served_upstream()], else: [])
      upstream = start_upstream(FakeUpstream.strict_sequence(sequence))
      setup = topology_setup!(topology, upstream)
      if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
      ctx = %{shape: :post_turn, mode: mode, topology: topology, setup: setup}
      port = start_public_endpoint!()

      # The window-0 process answers a turn and compacts on its socket; its
      # frames now carry window 1.
      older = connect!(port, setup, @window_0)
      older = older |> send_frame!(turn_1_frame(ctx)) |> completed!()
      older = older |> send_frame!(compaction_frame(ctx, :post_turn)) |> completed!()
      older_session_id = setup.pool.id |> pool_requests() |> hd() |> Map.fetch!(:id) |> request_session_id()

      # The window-1 process's turn is in progress at the provider.
      holder_frame = window_1_frame(ctx, @turn_2, window_1_history(ctx, 2))
      holder_socket = connect!(port, setup, @window_1) |> send_frame!(holder_frame)
      assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref}, @detection_timeout_ms
      assert %Request{id: holder_request_id, status: "in_progress"} = latest_request(setup.pool.id)
      holder_session_id = request_session_id(holder_request_id)
      refute holder_session_id == older_session_id
      assert window_alias_session_id(setup, @window_1) == holder_session_id

      {older, logs} = with_info_log(fn -> older |> send_frame!(window_1_frame(ctx, @turn_3, window_1_history(ctx, 3))) |> completed!() end)
      older_request = latest_request(setup.pool.id)
      await!(fn -> Repo.get!(Request, older_request.id).status == "succeeded" end, "the window-0 socket's turn never settled")
      older_request = Repo.get!(Request, older_request.id)

      window_after_frame = window_alias_session_id(setup, @window_1)
      assert {older_request.status, request_session_id(older_request.id)} == {"succeeded", older_session_id}
      assert Repo.get!(Request, holder_request_id).status == "in_progress"
      assert Repo.one!(from(turn in CodexTurn, where: turn.request_id == ^holder_request_id, select: turn.status)) == "in_progress"

      outcomes =
        case holder do
          :undisturbed ->
            release_held_turn!(upstream, release_ref, sequence)
            holder_socket |> completed!() |> close!()
            []

          :holder_cut ->
            close!(holder_socket)

            if topology == :direct,
              do: await!(fn -> Repo.get!(Request, holder_request_id).status == "failed" end, "the holder's cut turn never settled"),
              else: await!(fn -> entitlement_status(holder_request_id) == "armed" end, "the holder's closing socket never armed its replay")

            outcomes = websocket_retries!(ctx, port, holder_frame, @websocket_retries, [])
            release_held_turn!(upstream, release_ref, sequence)
            outcomes
        end

      close!(older)
      rows = settled_rows(setup.pool.id)

      measured = %{outcomes: outcomes, rows: Enum.map(rows, &{&1.transport, &1.status, &1.last_error_code}), entitlements: entitlement_statuses(setup.pool.id), window_after_frame: short(window_after_frame), holder: short(holder_session_id)}
      CodexPooler.TestDiagnostics.puts(fn -> "P121 guard #{mode} #{topology} #{holder}: #{inspect(measured)}" end)

      case holder do
        :undisturbed ->
          assert {Repo.get!(Request, holder_request_id).status, request_session_id(holder_request_id)} == {"succeeded", holder_session_id}

        :holder_cut when topology == :direct ->
          # The holder's reconnect on window 1 is served on its first send, on
          # the holder's session, after its settled cut.
          assert outcomes == [:served], inspect(measured)
          assert {Repo.get!(Request, holder_request_id).status, length(rows)} == {"failed", 5}
          assert {List.last(rows).status, request_session_id(List.last(rows).id)} == {"succeeded", holder_session_id}

        :holder_cut ->
          # The holder's reconnect on window 1 redeems the replay its owner
          # holds on its first send.
          assert outcomes == [:served], inspect(measured)
          assert {Repo.get!(Request, holder_request_id).status, length(rows)} == {"succeeded", 4}
          assert entitlement_status(holder_request_id) == "consumed"
      end

      assert Enum.all?(rows, &(&1.transport == "websocket"))
      refute Enum.any?(rows, &(&1.status in ["accepted", "in_progress"]))
      refute "armed" in measured.entitlements
      assert FakeUpstream.count(upstream) == length(sequence)
      for %Request{status: "succeeded"} = request <- rows, do: assert(charges(request) == 1)
      assert :ok = FakeUpstream.verify!(upstream)

      # The window stayed with its holder while the holder's turn ran.
      assert window_after_frame == holder_session_id
      assert logs =~ "websocket frame window alias codex_session_id=#{older_session_id} alias_preview=#{window_preview(@window_1)} disposition=kept"
    end
  end

  # The frame's reservation never waits on the window's alias row (findings#206
  # row 206-501): another transaction holding it (an upgrade resolving the
  # window) leaves the alias as it is for this turn (`busy`), the turn is
  # served, and the next turn frame points the window. The fixture is
  # committed so the test's own transaction can hold the row; a watcher on
  # `pg_blocking_pids` records any backend waiting on it and then lets it go.
  for topology <- [:forwarded, :direct] do
    @tag topology: topology
    test "full #{topology} held_alias_row: a frame whose window alias row another transaction holds is served without waiting and leaves the alias",
         %{topology: topology} do
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology == :forwarded)
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_1_upstream(), compaction_upstream(), resumed_upstream(), served_upstream(), served_upstream()]))
      :ok = Sandbox.mode(Repo, :auto)
      on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
      setup = gateway_setup(upstream, compact?: true)
      register_unboxed_pool_cleanup!(setup)
      ctx = %{shape: :stale_resume, mode: "full", topology: topology, setup: setup}
      port = start_public_endpoint!()

      older = connect!(port, setup, @window_0)
      older = older |> send_frame!(turn_1_frame(ctx)) |> completed!()
      older = older |> send_frame!(compaction_frame(ctx, :post_turn)) |> completed!()
      older_session_id = setup.pool.id |> pool_requests() |> hd() |> Map.fetch!(:id) |> request_session_id()

      # Window 1's own session answered a turn and its socket closed: nothing
      # in progress, so without the held row the window would move.
      connect!(port, setup, @window_1) |> send_frame!(window_1_frame(ctx, @turn_2, window_1_history(ctx, 2))) |> completed!() |> close!()
      window_session_id = request_session_id(latest_request(setup.pool.id).id)
      refute window_session_id == older_session_id
      before = window_alias!(setup, @window_1)
      assert before.codex_session_id == window_session_id

      holder = hold_alias_row!(before.id)
      watcher = watch_alias_row_waiters!(holder)

      {older, logs} =
        try do
          with_info_log(fn -> older |> send_frame!(window_1_frame(ctx, @turn_3, window_1_history(ctx, 3))) |> completed!() end)
        after
          waited = stop_watcher!(watcher)
          release_alias_row!(holder)
          assert waited == [], "the reservation waited on the held alias row: #{inspect(waited)}"
        end

      assert logs =~ "websocket frame window alias codex_session_id=#{older_session_id} alias_preview=#{window_preview(@window_1)} disposition=busy"
      %Request{id: busy_request_id} = latest_request(setup.pool.id)
      await!(fn -> Repo.get!(Request, busy_request_id).status == "succeeded" end, "the turn whose window alias row was held never settled")
      assert request_session_id(busy_request_id) == older_session_id
      assert Map.take(window_alias!(setup, @window_1), [:id, :codex_session_id, :expires_at, :last_seen_at, :metadata]) == Map.take(before, [:id, :codex_session_id, :expires_at, :last_seen_at, :metadata])

      # The next turn frame points the window once the row is free.
      {older, logs} = with_info_log(fn -> older |> send_frame!(window_1_frame(ctx, @turn_4, later_history(ctx))) |> completed!() end)
      assert logs =~ "alias_preview=#{window_preview(@window_1)} disposition=moved"
      assert window_alias_session_id(setup, @window_1) == older_session_id
      close!(older)

      rows = settled_rows(setup.pool.id)
      assert Enum.map(rows, & &1.status) == List.duplicate("succeeded", 5)
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  # Holds the alias row in a transaction of its own until released. The
  # holder and the watcher use connections of their own, outside the Repo
  # pool: in the sandbox's auto mode every process that queried keeps its
  # pooled connection, and two more held ones starve the owner-forwarded turn.
  defp hold_alias_row!(alias_id) do
    parent = self()
    connection = start_supervised!(Supervisor.child_spec({Postgrex, raw_connection_options()}, id: :alias_row_holder))

    task =
      Task.async(fn ->
        Postgrex.transaction(connection, fn transaction ->
          %{rows: [[backend_pid]]} = Postgrex.query!(transaction, "SELECT pg_backend_pid()", [])
          %{num_rows: 1} = Postgrex.query!(transaction, "SELECT id FROM bridge_session_aliases WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(alias_id)])
          send(parent, {:alias_row_held, self(), backend_pid})
          receive do: (:release_alias_row -> :ok)
        end)
      end)

    on_exit(fn -> send(task.pid, :release_alias_row) end)
    assert_receive {:alias_row_held, pid, backend_pid}, @detection_timeout_ms
    %{task: task, pid: pid, backend_pid: backend_pid}
  end

  defp release_alias_row!(%{task: task, pid: pid}) do
    send(pid, :release_alias_row)
    assert {:ok, {:ok, :ok}} = Task.yield(task, @detection_timeout_ms)
  end

  # Records every backend `pg_blocking_pids` shows waiting on the holder, and
  # releases the holder when it finds one so the waiter can finish.
  defp watch_alias_row_waiters!(holder) do
    connection = start_supervised!(Supervisor.child_spec({Postgrex, raw_connection_options()}, id: :alias_row_watcher))
    Task.async(fn -> watch_alias_row_waiters(connection, holder, []) end)
  end

  defp watch_alias_row_waiters(connection, %{pid: holder_pid, backend_pid: holder_backend_pid} = holder, waited) do
    receive do
      {:stop_watching, from} -> send(from, {:alias_row_waiters, Enum.reverse(waited)})
    after
      10 ->
        case Postgrex.query!(connection, "SELECT pid, wait_event_type FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))", [holder_backend_pid]).rows do
          [] ->
            watch_alias_row_waiters(connection, holder, waited)

          rows ->
            send(holder_pid, :release_alias_row)
            watch_alias_row_waiters(connection, holder, Enum.reverse(rows) ++ waited)
        end
    end
  end

  defp stop_watcher!(watcher) do
    send(watcher.pid, {:stop_watching, self()})
    assert_receive {:alias_row_waiters, waited}, @detection_timeout_ms
    _ = Task.yield(watcher, @detection_timeout_ms)
    waited
  end

  defp raw_connection_options, do: Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database, :socket, :socket_dir, :ssl, :ssl_opts, :parameters, :connect_timeout])

  defp window_alias!(setup, window) do
    hash = :crypto.hash(:sha256, window)
    Repo.one!(from(alias_record in BridgeSessionAlias, where: alias_record.pool_id == ^setup.pool.id and alias_record.alias_kind == "session_header" and alias_record.alias_hash == ^hash and alias_record.status == "active"))
  end

  defp window_preview(window), do: :sha256 |> :crypto.hash(window) |> Base.encode16(case: :lower) |> String.slice(0, 16)

  # The peer shares the committed database, so its fixture is committed: the
  # sandbox switches to auto mode before anything is written. Its owner is the
  # one the window-0 upgrade resolves.
  defp topology_setup!(:peer, upstream) do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream, compact?: true)
    Map.put(setup, :peer_owner, start_peer_window_owner!(setup, @window_0))
  end

  defp topology_setup!(_topology, upstream), do: gateway_setup(upstream, compact?: true)

  defp open_cut_socket_keeping!(%{shape: :stale_resume} = ctx, port, :session_open) do
    compacting = connect!(port, ctx.setup, @window_0)
    compacting = compacting |> send_frame!(turn_1_frame(ctx)) |> completed!()
    compacting |> send_frame!(compaction_frame(ctx, :post_turn)) |> completed!()
    close!(compacting)

    resumed = connect!(port, ctx.setup, @window_1)
    resumed = resumed |> send_frame!(window_1_frame(ctx, @turn_2, window_1_history(ctx, 2))) |> completed!()
    {cut_socket, cut_frame} = {connect!(port, ctx.setup, @window_0), window_1_frame(ctx, @turn_3, window_1_history(ctx, 3))}
    {cut_socket, cut_frame, resumed}
  end

  defp open_cut_socket_keeping!(ctx, port, _later) do
    {cut_socket, cut_frame} = open_cut_socket!(ctx, port)
    {cut_socket, cut_frame, nil}
  end

  # The socket the cut turn is sent on, and that turn's frame.
  #
  # `post_turn` and `manual`: one process on window 0 answers a turn and
  # compacts on the same socket (the released client's post-turn compaction
  # under the turn's id, or a manual `thread/compact` in a standalone turn);
  # its next turn carries window 1 on that socket.
  #
  # `stale_resume`: after that compaction a resumed process opened window 1's
  # own session and answered a turn there; the next resumed process lost the
  # prewarm race and opened its socket on window 0, while its frames carry
  # the restored window 1.
  defp open_cut_socket!(%{shape: :stale_resume} = ctx, port) do
    compacting = connect!(port, ctx.setup, @window_0)
    compacting = compacting |> send_frame!(turn_1_frame(ctx)) |> completed!()
    compacting |> send_frame!(compaction_frame(ctx, :post_turn)) |> completed!()
    close!(compacting)

    resumed = connect!(port, ctx.setup, @window_1)
    resumed |> send_frame!(window_1_frame(ctx, @turn_2, window_1_history(ctx, 2))) |> completed!()
    close!(resumed)

    {connect!(port, ctx.setup, @window_0), window_1_frame(ctx, @turn_3, window_1_history(ctx, 3))}
  end

  defp open_cut_socket!(ctx, port) do
    compacting = connect!(port, ctx.setup, @window_0)
    compacting = compacting |> send_frame!(turn_1_frame(ctx)) |> completed!()
    compacting = compacting |> send_frame!(compaction_frame(ctx, ctx.shape)) |> completed!()
    {compacting, window_1_frame(ctx, @turn_2, window_1_history(ctx, 2))}
  end

  # Sends the turn on the older window's socket, cuts that connection while
  # the provider holds the turn, waits until the closing socket armed the
  # replay (owner forwarding) or settled the turn (forwarding off), and
  # reconnects like the released client.
  defp cut_and_reconnect!(ctx, port, cut_socket, cut_frame, release_ref) do
    cut_socket = send_frame!(cut_socket, cut_frame)
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref}, @detection_timeout_ms
    assert %Request{id: cut_request_id, status: "in_progress"} = latest_request(ctx.setup.pool.id)
    close!(cut_socket)

    if ctx.topology == :direct,
      do: await!(fn -> Repo.get!(Request, cut_request_id).status == "failed" end, "the cut turn never settled"),
      else: await!(fn -> entitlement_status(cut_request_id) == "armed" end, "the closing socket never armed the cut turn's replay")

    websocket_retries!(ctx, port, cut_frame, @websocket_retries, [])
  end

  # The released client's reconnect after the cut: a new connection named by
  # the frames' window, and the same turn as full history. Up to five
  # websocket attempts; the client then falls back to HTTPS for the rest of
  # the process.
  defp websocket_retries!(_ctx, _port, _frame, 0, outcomes), do: Enum.reverse(outcomes)

  defp websocket_retries!(ctx, port, frame, remaining, outcomes) do
    cleanups = WebsocketCleanupFence.listener_socket_cleanups()
    client = connect!(port, ctx.setup, @window_1)

    outcome =
      try do
        case client |> send_frame!(frame) |> receive_until_terminal([]) do
          {_client, [_ | _] = frames} ->
            case List.last(frames) do
              %{"type" => "response.completed"} -> :served
              %{"type" => "error", "status" => status, "error" => %{"code" => code}} -> {status, code}
              other -> {:terminal, other["type"]}
            end
        end
      after
        Mint.HTTP.close(client.conn)
      end

    :ok = WebsocketCleanupFence.await_listener_socket_cleanups!(cleanups + 1)

    case outcome do
      :served -> Enum.reverse([:served | outcomes])
      refused -> websocket_retries!(ctx, port, frame, remaining - 1, [refused | outcomes])
    end
  end

  defp upstream_sequence(:stale_resume, release_ref), do: [turn_1_upstream(), compaction_upstream(), resumed_upstream(), held_upstream(release_ref), served_upstream()]
  defp upstream_sequence(_compacting, release_ref), do: [turn_1_upstream(), compaction_upstream(), held_upstream(release_ref), served_upstream()]

  # A new connection's anchored first frame. With owner forwarding the anchor
  # resolves to the session that produced it and rides that session's
  # provider connection, which answers it. Without, every socket opens its
  # own provider connection, so the Pooler opens one and refuses the anchor
  # before it sends anything (findings#232 rows 232-275..278), as it did
  # before the window moved; the expectation only lets that connection open.
  defp later_upstream(:foreign_anchor, :direct), do: [later_upstream(:owner_live, :direct) |> hd()]
  defp later_upstream(:foreign_anchor, _owner), do: later_upstream(:session_open, :owner)

  defp later_upstream(:session_open, _topology),
    do: [
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => @resumed}],
        respond: completed_frames(@later, [answer()])
      )
    ]

  defp later_upstream(_process, _topology),
    do: [FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@later, [answer()]))]

  defp turn_1_upstream,
    do: FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor, [answer()]))

  defp compaction_upstream,
    do:
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        websocket_connection_ordinal: 1,
        json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => @anchor, "input.0.type" => "compaction_trigger"}],
        respond: completed_frames(@compacted, [compaction_item()])
      )

  defp resumed_upstream,
    do: FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@resumed, [answer()]))

  # The cut turn reaches the provider, which answers nothing before the
  # client drops the connection.
  defp held_upstream(release_ref),
    do:
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
        respond: FakeUpstream.barrier_websocket_frames(completed_messages(@cut, [answer()]), notify: self(), release_ref: release_ref)
      )

  defp served_upstream,
    do: FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@served, [answer()]))

  # The held reply is released once the test is done with it; its connection
  # may already be gone (the owner stops a cut turn's task).
  defp release_held_turn!(upstream, release_ref, shape) when is_atom(shape), do: release_held_turn!(upstream, release_ref, upstream_sequence(shape, release_ref))

  defp release_held_turn!(upstream, release_ref, sequence) do
    held = Enum.find_index(sequence, &match?({:expect_request, _opts, {:websocket_frame_barrier, _messages, _notify, _ref}}, &1))
    %{websocket_connection_id: connection} = upstream |> FakeUpstream.requests() |> Enum.at(held)
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
    last = length(completed_messages(@cut, [answer()]))

    await!(
      fn ->
        receive do
          {:fake_upstream_frame_barrier, ^last, _handler, ^release_ref} -> true
        after
          0 -> not FakeUpstream.websocket_connection_alive?(upstream, connection)
        end
      end,
      "the held provider reply neither finished nor lost its connection"
    )

    for barrier <- 1..last//1, do: FakeUpstream.acknowledge(upstream, {:frame_barrier, release_ref, barrier})
    :ok
  end

  defp connect!(port, setup, window) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", @thread_id},
      {"thread-id", @thread_id},
      {"x-client-request-id", @thread_id},
      {"x-codex-window-id", window}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/backend-api/codex/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp close!(client) do
    cleanups = WebsocketCleanupFence.listener_socket_cleanups()
    Mint.HTTP.close(client.conn)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanups!(cleanups + 1)
  end

  defp completed!(client) do
    {client, frames} = receive_until_terminal(client, [])
    assert %{"type" => "response.completed"} = List.last(frames), inspect(Enum.map(frames, & &1["type"]))
    client
  end

  defp receive_until_terminal(client, seen) do
    {client, frame} = receive_frame!(client)
    seen = [frame | seen]

    if frame["type"] in ["response.completed", "error", "response.failed", "response.incomplete"],
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

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id]))

  defp latest_request(pool_id), do: pool_id |> pool_requests() |> List.last()

  # A cut turn settles through its socket's cleanup or its replay; no signal
  # reaches the test, so poll the rows within the detection budget and hand
  # back what is there once it is spent (a row left open fails the test).
  defp settled_rows(pool_id), do: settled_rows(pool_id, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp settled_rows(pool_id, deadline) do
    rows = pool_requests(pool_id)

    if Enum.any?(rows, &(&1.status in ["accepted", "in_progress"])) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      settled_rows(pool_id, deadline)
    else
      rows
    end
  end

  defp cut_request(pool_id, shape) do
    index = if shape == :stale_resume, do: 3, else: 2
    pool_id |> pool_requests() |> Enum.at(index)
  end

  defp request_session_id(request_id), do: Repo.one!(from(turn in CodexTurn, where: turn.request_id == ^request_id, select: turn.codex_session_id))

  defp window_alias_session_id(setup, window) do
    hash = :crypto.hash(:sha256, window)

    Repo.one(
      from(alias_record in BridgeSessionAlias,
        where: alias_record.pool_id == ^setup.pool.id and alias_record.alias_kind == "session_header" and alias_record.alias_hash == ^hash and alias_record.status == "active",
        select: alias_record.codex_session_id
      )
    )
  end

  defp stop_owner!(%{topology: :peer}, _session_id), do: flunk("the peer arm keeps its owner")

  # The owner is gone and its lease lapsed, as when an idle owner expires or
  # its VM died a lease ago.
  defp stop_owner!(_ctx, session_id) do
    stop_websocket_owner_session(session_id)
    lapsed = DateTime.utc_now() |> DateTime.add(-1, :millisecond) |> DateTime.truncate(:microsecond)
    {1, _rows} = Repo.update_all(from(session in CodexSession, where: session.id == ^session_id), set: [owner_lease_expires_at: lapsed])
    {_count, _rows} = Repo.update_all(from(lease in BridgeOwnerLease, where: lease.codex_session_id == ^session_id and lease.status == "active"), set: [expires_at: lapsed])
    :ok
  end

  defp short(id), do: String.slice(id, 0, 8)

  defp entitlement_status(request_id), do: Repo.one(from(entitlement in RequestReplayEntitlement, where: entitlement.request_id == ^request_id, select: entitlement.status))

  defp entitlement_statuses(pool_id) do
    Repo.all(
      from(entitlement in RequestReplayEntitlement,
        join: request in Request,
        on: request.id == entitlement.request_id,
        where: request.pool_id == ^pool_id,
        select: entitlement.status
      )
    )
  end

  defp session_count(pool_id), do: Repo.aggregate(from(session in CodexSession, where: session.pool_id == ^pool_id), :count)

  # A charge is a settlement that billed known usage.
  defp charges(%Request{id: request_id}) do
    Repo.aggregate(
      from(entry in LedgerEntry, where: entry.request_id == ^request_id and entry.entry_kind == "settlement" and entry.usage_status == "usage_known" and entry.settled_cost_micros > 0),
      :count
    )
  end

  defp compaction_item, do: %{"type" => "compaction", "encrypted_content" => "synthetic-window-advance-compaction"}

  defp prompt(label), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{label} prompt"}]}

  defp answer, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

  # The released Lite client opens a provider context with its tool manifest.
  defp context_prefix("lite"), do: [%{"type" => "additional_tools", "role" => "developer", "tools" => []}]
  defp context_prefix("full"), do: []

  defp turn_1_frame(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first")], @turn_1, @window_0)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(@turn_1, 0, %{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  # The post-turn compaction runs under the turn it follows, a manual
  # `thread/compact` in a standalone turn of its own; both are anchored on the
  # turn's response with the trigger as their only input.
  defp compaction_frame(ctx, shape) do
    {turn_id, compaction} =
      case shape do
        :post_turn -> {@turn_1, %{"trigger" => "auto", "reason" => "context_limit", "phase" => "post_turn"}}
        :manual -> {@manual_turn, %{"trigger" => "manual", "reason" => "user_requested", "phase" => "standalone_turn"}}
      end

    compaction = Map.merge(compaction, %{"implementation" => "responses_compaction_v2", "strategy" => "memento"})

    ctx
    |> frame([%{"type" => "compaction_trigger"}], turn_id, @window_0)
    |> Map.put("previous_response_id", @anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(turn_id, 0, %{"request_kind" => "compaction", "compaction" => compaction}))
    |> CodexPooler.JSON.encode!()
  end

  # A turn on the compacted history: unanchored full history carrying window 1.
  defp window_1_frame(ctx, turn_id, input) do
    ctx
    |> frame(input, turn_id, @window_1)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(turn_id, 1, %{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  # The window's own session continues its turn on its still-open connection:
  # an anchored delta with the tool round's next user message.
  defp anchored_frame(ctx, turn_id) do
    ctx
    |> frame([prompt("anchored")], turn_id, @window_1)
    |> Map.put("previous_response_id", @resumed)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(turn_id, 1, %{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  defp later_history(%{shape: :stale_resume} = ctx), do: window_1_history(ctx, 3) ++ [answer(), prompt("later")]
  defp later_history(ctx), do: window_1_history(ctx, 2) ++ [answer(), prompt("later")]

  defp window_1_history(ctx, 2), do: context_prefix(ctx.mode) ++ [compaction_item(), prompt("second")]
  defp window_1_history(ctx, 3), do: window_1_history(ctx, 2) ++ [answer(), prompt("third")]

  # Full: the released client's top-level `instructions` and `tools`, parallel
  # tool calls on. Lite (`use_responses_lite` in the catalog): neither
  # top-level key, parallel tool calls off, and the Lite marker in
  # `client_metadata`.
  defp frame(ctx, input, turn_id, window_id) do
    client_metadata = %{
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "turn_id" => turn_id,
      "root_turn_id" => turn_id,
      "x-codex-installation-id" => @installation_id,
      "x-codex-window-id" => window_id,
      "x-codex-ws-stream-request-start-ms" => "1790000000000"
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

  defp turn_metadata(turn_id, window_number, extra) do
    %{
      "agent_name" => "/root",
      "analytics_enabled" => true,
      "auto_review_enabled" => false,
      "context_window_id" => if(window_number == 0, do: @context_0, else: @context_1),
      "installation_id" => @installation_id,
      "root_turn_id" => turn_id,
      "sandbox" => "seatbelt",
      "sandbox_mode" => "read-only",
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "turn_id" => turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "window_id" => "#{@thread_id}:#{window_number}",
      "window_number" => window_number,
      "model" => "gpt-test-model",
      "reasoning_effort" => "low"
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  defp usage, do: %{"input_tokens" => 20_000, "output_tokens" => 10, "total_tokens" => 20_010}

  defp completed_messages(response_id, output) do
    [CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}})] ++
      Enum.map(output, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
      [CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => usage()}})]
  end

  defp completed_frames(response_id, output), do: FakeUpstream.websocket_text_frames(completed_messages(response_id, output))
end
