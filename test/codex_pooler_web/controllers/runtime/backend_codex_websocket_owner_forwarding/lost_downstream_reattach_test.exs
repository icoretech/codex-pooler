defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.LostDownstreamReattachTest do
  # A native socket that dies without running `terminate` (its process killed)
  # while the owner is dispatching a turn it has shown nothing of: the owner's
  # monitor marks that generation `:lost` and keeps it running for an
  # identical resend to reattach to. The resend's socket attaches to the owner
  # before it sends its reconnect control, so the control named the current
  # epoch, not the next one the reattach accepted; every real reattach was
  # refused `owner_busy`, the provider's next frame could not be delivered and
  # the turn settled `failed owner_busy`, which no resend path admits
  # (findings#232 row 232-221; the killed socket's submitting task survives it,
  # it settled that failure). The identical resend now reattaches: the running
  # generation delivers its answer to the new socket and settles once, with no
  # second provider dispatch.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, strict_native_request: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @timeout_ms 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  @tag slow: "a real socket killed mid-turn, the owner's loss monitor and a second socket's reattach"
  test "the identical resend of a turn whose socket was killed before any output reattaches to the running generation" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#232 row 232-221 (local owner, the socket process killed while the provider was still answering)
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.barrier_websocket_frames([completed_frame("resp_lost_reattach")], notify: self(), release_ref: release_ref))
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    turn_state = Ecto.UUID.generate()
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
    port = start_public_endpoint!()

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {_conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref}, @timeout_ms

    session_id = Repo.one!(from(s in CodexSession, where: s.pool_id == ^setup.pool.id, select: s.id))
    {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    socket_pid = :sys.get_state(owner).downstream.pid
    monitor = Process.monitor(socket_pid)
    Process.exit(socket_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^socket_pid, :killed}, @timeout_ms
    await_lost_active_turn!(owner, System.monotonic_time(:millisecond) + @timeout_ms)

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    await_reattached_active_turn!(owner, System.monotonic_time(:millisecond) + @timeout_ms)
    :ok = FakeUpstream.release_frame(upstream, release_ref)
    {conn, frame} = receive_terminal!(conn, websocket, ref)
    _closed = Mint.HTTP.close(conn)

    assert frame["type"] == "response.completed"
    assert [%Request{id: request_id, status: "succeeded"}] = await_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    assert [%Attempt{replay_generation: 0, status: "succeeded"}] = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))
    assert Repo.all(RequestClientRetryLink) == []

    assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^request_id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
             %{"reservation" => 1, "settlement" => 1, "release" => 1}

    assert FakeUpstream.count(upstream) == 1
  end

  defp await_lost_active_turn!(owner, deadline_ms) do
    case :sys.get_state(owner) do
      %{active_turn: %{descriptor: %{downstream_status: :lost}}} ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("the owner never marked the killed socket's turn lost"),
          else: Process.sleep(10) && await_lost_active_turn!(owner, deadline_ms)
    end
  end

  # The reattach is decided in the owner; the provider is released only once
  # the running generation is attached to the new socket again, or refused.
  defp await_reattached_active_turn!(owner, deadline_ms) do
    case :sys.get_state(owner) do
      %{active_turn: %{descriptor: %{downstream_status: :attached}}} ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("the identical resend never reattached to the running generation"),
          else: Process.sleep(10) && await_reattached_active_turn!(owner, deadline_ms)
    end
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frame = CodexPooler.JSON.decode!(text)

    if frame["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, frame},
      else: receive_terminal!(conn, websocket, ref)
  end

  defp await_settled!(pool_id, deadline_ms) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^pool_id))

    cond do
      requests != [] and Enum.all?(requests, &(&1.status != "in_progress")) -> requests
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("requests never settled")
      true -> Process.sleep(20) && await_settled!(pool_id, deadline_ms)
    end
  end

  defp completed_frame(response_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
    })
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
        "turn_id" => "lost-reattach-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "lost-reattach-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic lost reattach turn"}]}]
    }
  end
end
