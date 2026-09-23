defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.PrevisibleRetryDirectTest do
  # Owner forwarding off (a supported setting): a native tool continuation or
  # post-compaction final whose downstream closes before any output reached
  # the client, then the released client's byte-identical resends on new
  # sockets at its stream-retry backoff. Nothing arms a replay on this
  # topology, and the predecessor settles `client_disconnected`; every resend
  # used to meet `409 duplicate_turn` (five of five), leaving only the HTTPS
  # fallback about six seconds later. The resend is now admitted as a new
  # request chained to the pre-visible predecessor once that predecessor has
  # settled (findings#232 row 232-112). The first retry can still land while
  # the closing socket drains its response task (250 ms) and be refused;
  # the released client hides that first retry notice.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @detection_timeout_ms 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  for {shape, input} <- [
        tool_continuation: [%{"type" => "function_call_output", "call_id" => "call_direct_previsible_retry", "output" => "synthetic direct retry output"}],
        compact_final: [%{"type" => "compaction", "encrypted_content" => "synthetic-direct-previsible-retry-compaction"}],
        opening_turn: [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic direct retry opening turn"}]}]
      ] do
    @tag :replay_matrix
    @tag slow: "waits out the released client's real 200 ms and 400 ms stream-retry backoff around the closing socket's 250 ms response-task drain"
    @tag input: input
    test "direct socket: a pre-visible #{shape} disconnect and the released client's resend", %{input: input} do
      measure_direct_previsible_retry(input)
    end
  end

  defp measure_direct_previsible_retry(input) do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic pre-visible downstream loss")),
          strict_native_request(
            2,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{"id" => "resp_direct_previsible_retry", "status" => "completed", "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
              })
            ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    thread_id = Ecto.UUID.generate()
    turn_state = Ecto.UUID.generate()

    raw_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "direct-previsible-retry", "request_kind" => "turn"})
        },
        "input" => input,
        "stream" => true,
        "generate" => true
      })

    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref}, @detection_timeout_ms
    assert [%Request{id: request_id, status: "in_progress"} = first] = pool_requests(setup.pool.id)
    assert get_in(first.request_metadata, ["websocket_owner_forwarding", "enabled"]) in [false, nil]

    closed_at_ms = System.monotonic_time(:millisecond)
    _result = Mint.HTTP.close(conn)

    # The released client's first two websocket stream retries: backoff 200
    # then 400 ms (the released client's `async-utils/src/backoff.rs`, jitter
    # omitted), each on a new socket; it retries five times before its HTTPS
    # fallback, and before this fix all five were refused. The provider keeps
    # the first request open (the barrier is released only at the end), as a
    # live provider generating the turn would.
    outcomes = released_client_retries(port, setup, turn_state, raw_payload, closed_at_ms, [200, 400], [])
    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    await_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @detection_timeout_ms)

    requests = pool_requests(setup.pool.id)

    measured = %{
      retries: outcomes,
      requests: Enum.map(requests, &{&1.id == request_id, &1.status, &1.response_status_code, &1.last_error_code}),
      attempts: Repo.all(from(attempt in Attempt, join: request in Request, on: request.id == attempt.request_id, where: request.pool_id == ^setup.pool.id, order_by: [attempt.started_at, attempt.replay_generation], select: {attempt.replay_generation, attempt.status})),
      entitlements: Repo.all(from(entitlement in RequestReplayEntitlement, where: entitlement.request_id == ^request_id, select: entitlement.status)),
      ledger: Repo.all(from(entry in LedgerEntry, join: request in Request, on: request.id == entry.request_id, where: request.pool_id == ^setup.pool.id, select: entry.entry_kind)) |> Enum.frequencies(),
      upstream_sends: FakeUpstream.count(upstream)
    }

    CodexPooler.TestDiagnostics.puts("232-112 direct pre-visible retry measured: #{inspect(measured)}")

    {refused, [admitted]} = Enum.split(measured.retries, -1)
    assert admitted == {"response.completed", nil, nil}
    assert length(refused) <= 1
    assert Enum.all?(refused, &(&1 == {"error", "duplicate_turn", 409}))

    assert Map.delete(measured, :retries) == %{
             requests: [{true, "failed", 499, "client_disconnected"}, {false, "succeeded", 200, nil}],
             attempts: [{0, "failed"}, {0, "succeeded"}],
             entitlements: [],
             ledger: %{"reservation" => 2, "settlement" => 2, "release" => 2},
             upstream_sends: 2
           }

    assert [resend] = Enum.reject(requests, &(&1.id == request_id))
    assert resend.request_metadata["client_resend"] == %{"predecessor_request_id" => request_id, "reason" => "failed_predecessor"}
  end

  defp released_client_retries(_port, _setup, _turn_state, _raw_payload, _closed_at_ms, [], outcomes), do: Enum.reverse(outcomes)

  defp released_client_retries(port, setup, turn_state, raw_payload, previous_at_ms, [delay | delays], outcomes) do
    retry_at_ms = previous_at_ms + delay
    Process.sleep(max(retry_at_ms - System.monotonic_time(:millisecond), 0))
    {retry_conn, retry_websocket, retry_ref} = public_websocket_connect!(port, setup, turn_state)
    {retry_conn, retry_websocket} = public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, raw_payload)
    {retry_conn, _retry_websocket, retry_frame} = public_websocket_receive_text!(retry_conn, retry_websocket, retry_ref)
    answered_at_ms = System.monotonic_time(:millisecond)
    _result = Mint.HTTP.close(retry_conn)
    result = CodexPooler.JSON.decode!(retry_frame)
    outcome = {result["type"], get_in(result, ["error", "code"]), result["status"]}

    case outcome do
      {"error", _code, _status} -> released_client_retries(port, setup, turn_state, raw_payload, answered_at_ms, delays, [outcome | outcomes])
      _terminal -> Enum.reverse([outcome | outcomes])
    end
  end

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: request.admitted_at))

  defp await_settled!(pool_id, deadline_ms) do
    cond do
      Enum.all?(pool_requests(pool_id), &(&1.status != "in_progress")) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("requests did not settle: #{inspect(Enum.map(pool_requests(pool_id), & &1.status))}")

      true ->
        Process.sleep(10)
        await_settled!(pool_id, deadline_ms)
    end
  end
end
