defmodule CodexPoolerWeb.Runtime.BackendCodexSsePrevisibleTimeoutResendTest do
  # The Pooler's own upstream receive timeout can fail a native Codex HTTP SSE
  # turn while the provider has sent nothing but its lifecycle preamble, which
  # the Pooler withholds for the first-event retry window. The client saw no
  # output, so its identical resend is not a duplicate of anything it was shown:
  # the released Codex client resends it and, before this was fixed, met
  # `409 duplicate_turn` on every attempt and the turn failed, where the same
  # client against the provider directly recovered with one resend
  # (findings#225 row 225-191, measured with the released Codex client).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, native_text_input: 1, start_public_endpoint!: 0, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  @native_path "/backend-api/codex/responses"
  @detection_timeout_ms 15_000
  @response_id "resp_previsible_timeout"

  setup do
    previous = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings, settings: %OperationalSettings{sse_keepalive_interval_ms: 50, upstream_receive_timeout_ms: 300})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    :ok
  end

  test "an identical resend after the Pooler's own receive timeout before any output is served" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#225 row 225-191 (S10 P300 arm: response.created at once,
        # then the provider stays silent past the receive timeout; payload values invented)
        FakeUpstream.strict_sequence([
          FakeUpstream.barrier_sse_stream([created_event(), completed_event("resp_previsible_timeout_late")],
            barrier_after: 1,
            notify: self(),
            release_ref: release_ref
          ),
          FakeUpstream.sse_stream([created_event(), completed_event("resp_previsible_timeout_resend")])
        ])
      )

    setup = gateway_setup(upstream)
    thread_id = Ecto.UUID.generate()
    payload = native_payload(setup, thread_id)

    {status, first_body} = post_stream!(setup, payload, thread_id)
    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref}, @detection_timeout_ms
    assert status == 200
    refute first_body =~ "response.completed"

    assert [%Request{id: first_id, status: "failed", last_error_code: "stream_idle_timeout"}] = pool_requests(setup)
    first_visible = Repo.get_by!(CodexTurn, request_id: first_id).first_visible_output_at

    {resend_status, resend_body} = post_stream!(setup, payload, thread_id)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    assert {resend_status, resend_body =~ "resp_previsible_timeout_resend"} == {200, true}
    assert is_nil(first_visible)

    assert [%Request{id: ^first_id, status: "failed"}, %Request{status: "succeeded"} = resend] = pool_requests(setup)
    assert [%Attempt{status: "succeeded"}] = Repo.all(from(a in Attempt, where: a.request_id == ^resend.id))

    ledger =
      Repo.all(from(l in LedgerEntry, where: l.request_id in ^[first_id, resend.id], select: {l.request_id, l.entry_kind}))

    assert Enum.frequencies(ledger) == %{
             {first_id, "reservation"} => 1,
             {first_id, "settlement"} => 1,
             {first_id, "release"} => 1,
             {resend.id, "reservation"} => 1,
             {resend.id, "settlement"} => 1,
             {resend.id, "release"} => 1
           }

    assert FakeUpstream.count(upstream) == 2
  end

  defp native_payload(setup, thread_id) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("synthetic previsible timeout resend fixture"),
      "stream" => true,
      "client_metadata" => %{
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "previsible-timeout-turn", "request_kind" => "turn"})
      }
    }
  end

  # One request over a real listener, read until the stream ends: the status and
  # the body the client received.
  defp post_stream!(setup, payload, thread_id) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "POST",
        @native_path,
        [
          {"authorization", setup.authorization},
          {"content-type", "application/json"},
          {"session-id", thread_id},
          {"originator", "codex_cli_rs"}
        ],
        CodexPooler.JSON.encode!(payload)
      )

    try do
      receive_all(conn, ref, nil, "")
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_all(conn, ref, status, body) do
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @detection_timeout_ms)

    {status, body, done?} =
      Enum.reduce(responses, {status, body, false}, fn
        {:status, ^ref, status}, {_status, body, done?} -> {status, body, done?}
        {:data, ^ref, data}, {status, body, done?} -> {status, body <> data, done?}
        {:done, ^ref}, {status, body, _done?} -> {status, body, true}
        _other, acc -> acc
      end)

    if done?, do: {status, body}, else: receive_all(conn, ref, status, body)
  end

  defp pool_requests(setup),
    do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

  defp created_event,
    do: {"response.created", %{"type" => "response.created", "response" => %{"id" => @response_id, "status" => "in_progress"}}}

  defp completed_event(id),
    do:
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => id,
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
         }
       }}
end
