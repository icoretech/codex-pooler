defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.SettlementWindowResendTest do
  # A websocket turn's settlement writes the request, its attempt and its
  # ledger entries in one transaction and completes the turn row in a second
  # one. The released client (Codex 0.156.1) resends a turn the provider failed
  # (`response.failed` `server_error`) on a new connection about 200 ms after
  # the failure frame, and on a slow database that resend can arrive between
  # the two commits: the request is already `failed`, the turn still
  # `in_progress`.
  #
  # With owner forwarding on, the owner's replay preflight met that turn,
  # judged it orphaned (a terminal request behind an open turn) and closed it
  # `failed orphaned_turn_closed`, which no resend policy admits: the resend
  # and every later one met `409 duplicate_turn` and the client finished the
  # turn over HTTPS, buying it again (findings#206 row 206-609). The preflight
  # now completes such a turn the way its settlement would (the request's own
  # outcome and error code), so the resend is admitted as the failed request's
  # one successor. With owner forwarding off the turn claim sees the open turn
  # as a live predecessor and waits, bounded, for its settlement.
  #
  # The settling process is held between its two commits (at the start of its
  # turn transaction) until the resend has its answer, or, with forwarding off,
  # until the resend's claim starts waiting for it. One node, committed rows,
  # native websocket `/backend-api/codex/responses`, the Pool's model forced to
  # Full and to Lite, FakeUpstream. Turn metadata and frame shapes are the
  # released client's; text and identifiers synthetic.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  for forwarding <- [:forwarded, :direct], mode <- ["full", "lite"] do
    @tag forwarding: forwarding, serving_mode: mode
    test "websocket #{forwarding} #{mode}: a resend arriving between a provider-failed turn's request and turn commits is served as its one successor", ctx do
      measured = run(ctx.forwarding, ctx.serving_mode)
      CodexPooler.TestDiagnostics.puts(fn -> "settlement window #{ctx.forwarding} #{ctx.serving_mode}: #{inspect(measured)}" end)

      assert measured.window == {"failed", "in_progress"}
      assert measured.resend == {"response.completed", nil}
      assert measured.requests == [{"failed", "server_error"}, {"succeeded", nil}]
      assert measured.failed_turn == {"failed", "server_error"}
      assert measured.linked? == true
      assert measured.recorded_settlements == [1, 1]
      assert measured.upstream_requests == 2
    end
  end

  defp run(forwarding, mode) do
    put_owner_forwarding!(forwarding)
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (response.failed server_error, the released client's resend on a new connection); reply frames synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: failure_frames()),
          FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", respond: completed_frames("resp_settlement_window_resend"))
        ])
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    put_serving_mode!(setup, mode)
    port = start_public_endpoint!()
    thread = "ws-settlement-window-#{System.unique_integer([:positive])}"
    frame = released_frame(setup, thread)
    hold = hold_turn_completion!()

    # The provider fails the turn; the settling process stops between its
    # request commit and its turn transaction.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
    {conn, _websocket, failure} = receive_until_terminal(conn, websocket, ref)
    assert %{"type" => "response.failed"} = failure
    assert_receive {^hold, :held, settler}, @detection_timeout_ms
    [failed] = pool_requests(setup)
    window = {failed.status, Repo.get_by!(CodexTurn, request_id: failed.id).status}
    Mint.HTTP.close(conn)

    # The resend, on a new connection, inside the window. With forwarding off
    # its claim waits for the open turn, and the settler is released when it
    # starts waiting; otherwise when the resend has its answer.
    if forwarding == :direct, do: release_on_claim_wait!(hold, settler)
    resend = resend!(port, setup, thread, frame)
    send(settler, {hold, :release})
    await_settled!(setup)
    [failed | later] = requests = pool_requests(setup)
    failed_turn = Repo.get_by!(CodexTurn, request_id: failed.id)

    %{
      window: window,
      resend: {resend["type"], get_in(resend, ["error", "code"])},
      requests: Enum.map(requests, &{&1.status, &1.last_error_code}),
      failed_turn: {failed_turn.status, failed_turn.error_code},
      linked?: match?([successor] when is_struct(successor, Request), later) and linked_successor?(failed, hd(later)),
      recorded_settlements: Enum.map(requests, &recorded_settlements/1),
      upstream_requests: FakeUpstream.count(upstream)
    }
  end

  # Holds the first process that commits a settlement ledger entry (the failed
  # request's settlement) at the start of its next transaction, the one that
  # completes the turn: the request and attempt are committed, the turn is
  # still `in_progress`, and the held connection holds no row lock.
  defp hold_turn_completion! do
    hold = make_ref()
    handler_id = {__MODULE__, :turn_completion_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    config = %{hold: hold, test: self(), claimed: :atomics.new(1, [])}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.hold_turn_completion_query/4, config)
    hold
  end

  @doc false
  def hold_turn_completion_query(_event, _measurements, %{query: query} = metadata, %{hold: hold} = config) do
    key = {__MODULE__, hold}

    case {settlement_step(query, metadata), Process.get(key)} do
      {:settlement_insert, nil} -> Process.put(key, :settlement)
      {:commit, :settlement} -> Process.put(key, :committed)
      {:begin, :committed} -> maybe_hold_settler(key, config)
      _other -> :ok
    end
  end

  def hold_turn_completion_query(_event, _measurements, _metadata, _config), do: :ok

  defp settlement_step(query, metadata) do
    cond do
      String.contains?(query, ~s(INSERT INTO "ledger_entries")) and "settlement" in List.wrap(metadata[:params]) -> :settlement_insert
      String.downcase(query) == "commit" -> :commit
      String.downcase(query) == "begin" -> :begin
      true -> :other
    end
  end

  defp maybe_hold_settler(key, %{hold: hold, test: test, claimed: claimed}) do
    if :atomics.add_get(claimed, 1, 1) == 1 do
      Process.put(key, :held)
      send(test, {hold, :held, self()})

      receive do
        {^hold, :release} -> :ok
      after
        @detection_timeout_ms -> :ok
      end
    end

    :ok
  end

  # With forwarding off the resend's claim waits for the live predecessor; the
  # settler is released as soon as that wait starts.
  defp release_on_claim_wait!(hold, settler) do
    handler_id = {__MODULE__, :claim_wait_release, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :accounting, :websocket_turn_claim, :live_predecessor_wait],
        fn _event, _measurements, _metadata, _config -> send(settler, {hold, :release}) end,
        nil
      )
  end

  defp resend!(port, setup, thread, frame) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      {_conn, _websocket, terminal} = receive_until_terminal(conn, websocket, ref)
      terminal
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_until_terminal(conn, websocket, ref)
    end
  end

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

  defp await_settled!(setup) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_settled!(setup, deadline)
  end

  defp await_settled!(setup, deadline) do
    turns = Repo.all(from(t in CodexTurn, join: r in Request, on: r.id == t.request_id, where: r.pool_id == ^setup.pool.id, select: t.status))
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, select: r.status))

    cond do
      Enum.all?(requests ++ turns, &(&1 not in ["accepted", "in_progress"])) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :ok
      true -> Process.sleep(10) && await_settled!(setup, deadline)
    end
  end

  defp linked_successor?(%Request{id: failed_id}, %Request{id: successor_id} = successor) do
    successor.request_metadata["client_resend"]["predecessor_request_id"] == failed_id or
      Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^failed_id and link.successor_request_id == ^successor_id))
  end

  defp recorded_settlements(%Request{id: id}),
    do: Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^id and l.entry_kind == "settlement" and l.amount_status == "recorded"), :count)

  # The released client's turn frame (`request_kind` turn).
  defp released_frame(setup, thread) do
    turn_id = Ecto.UUID.generate()
    metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id}

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("synthetic settlement window turn"),
      "stream" => true,
      "generate" => true,
      "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", CodexPooler.JSON.encode!(Map.put(metadata, "request_kind", "turn")))
    })
  end

  defp failure_frames do
    response_id = "resp_settlement_window_failed"

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

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
