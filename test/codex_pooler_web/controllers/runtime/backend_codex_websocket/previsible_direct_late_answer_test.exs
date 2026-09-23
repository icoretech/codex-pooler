defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.PrevisibleDirectLateAnswerTest do
  # Owner forwarding off (the runtime default for one app replica): the client
  # leaves before any output, the closing socket settles its request
  # `client_disconnected`, and the provider answers afterwards. Measured with
  # the released Codex client: the late answer settled the same request a
  # second time and turned it `succeeded` (findings#232 row 232-172).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  @detection_timeout_ms 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  @tag slow: "waits out the closing socket's 250 ms response-task drain and then a late provider answer"
  test "a provider answer that arrives after the closing socket settled a pre-visible turn does not settle it again" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#232 row 232-172 (released client, owner forwarding off, provider answering after the cut)
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.barrier_websocket_frames(
              [
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{"id" => "resp_direct_late_answer", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
                })
              ],
              notify: self(),
              release_ref: release_ref
            )
          )
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    thread_id = Ecto.UUID.generate()

    raw_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "direct-late-answer", "request_kind" => "turn"})
        },
        "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic late answer"}]}],
        "stream" => true
      })

    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref}, @detection_timeout_ms
    assert [%Request{id: request_id, status: "in_progress"}] = pool_requests(setup.pool.id)

    _result = Mint.HTTP.close(conn)
    settled = await_request_terminal!(request_id, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    _released = FakeUpstream.release_frame(upstream, release_ref)
    # A task left running settles its request within milliseconds of the answer.
    Process.sleep(300)

    request = Repo.get!(Request, request_id)
    turn = Repo.get_by!(CodexTurn, request_id: request_id)

    measured = %{
      first_settle: {settled.status, settled.last_error_code},
      request: {request.status, request.last_error_code, request.usage_status},
      turn: {turn.status, turn.error_code},
      attempts: Repo.all(from(a in Attempt, where: a.request_id == ^request_id, select: {a.status, a.usage_status})),
      ledger: Repo.all(from(l in LedgerEntry, where: l.request_id == ^request_id, select: {l.entry_kind, l.usage_status, l.settled_cost_micros, l.input_tokens}))
    }

    CodexPooler.TestDiagnostics.puts("232-172 direct late answer measured: #{inspect(measured)}")

    assert measured.first_settle == {"failed", "client_disconnected"}
    assert measured.request == {"failed", "client_disconnected", "usage_unknown"}
    assert Enum.count(measured.ledger, &(elem(&1, 0) == "settlement")) == 1
  end

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: request.admitted_at))

  defp await_request_terminal!(request_id, deadline_ms) do
    request = Repo.get!(Request, request_id)

    cond do
      request.status != "in_progress" -> request
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("request did not settle")
      true -> Process.sleep(10) && await_request_terminal!(request_id, deadline_ms)
    end
  end
end
