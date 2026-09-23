defmodule CodexPoolerWeb.Runtime.BackendCodexHttpFinalRefusalResendTest do
  # A native HTTP turn the provider refused, resent over HTTP. The native HTTP
  # turn claim steps over a zero-output predecessor (findings#212 row 212-50),
  # so the resend was dispatched again, where the resend of a refused websocket
  # turn, over the websocket or HTTPS, is answered with the recorded refusal
  # (findings#254 rows 254-100 and 254-130). A relayable validation rejection is
  # one the provider repeats for the same body, so its HTTP resend now gets the
  # same refusal back before anything is reserved or dispatched (row 254-141).
  # Every other relayed 4xx keeps the step-over the #212 fence pins ("a resend
  # after a relayed 4xx is served, not refused"), and so does a retryable 429.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, start_upstream: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  # provenance: observed findings#254 rows 254-100 and 254-30 (a codeless provider 404 and a relayable validation 400 refusing a native turn); the HTTP predecessor is row 254-141
  @refusals %{
    validation_400: {400, %{"error" => %{"type" => "invalid_request_error", "code" => "invalid_value", "param" => "input[0].content", "message" => "Invalid value 'private-refusal-sentinel'."}}}
  }
  @stepped_over %{
    codeless_404: {404, %{"error" => %{"type" => "invalid_request_error", "message" => "Refused 'private-refusal-sentinel'."}}},
    rate_limit_429: {429, %{"error" => %{"type" => "rate_limit_error", "code" => "rate_limit_exceeded", "message" => "Slow down."}}}
  }

  test "the HTTP resend of a native HTTP turn refused with a validation 400 gets the same refusal, never a dispatch" do
    {status, body} = Map.fetch!(@refusals, :validation_400)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.json_response(body, status))
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    turn_state = Ecto.UUID.generate()
    payload = native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id)

    original = post_turn!(setup, turn_state, payload)
    assert %{"error" => %{"code" => code}} = CodexPooler.JSON.decode!(original.resp_body)
    refute original.resp_body =~ "private-refusal-sentinel"
    assert [%Request{id: request_id, status: "failed"}] = pool_requests(setup.pool.id)

    resend = post_turn!(setup, turn_state, payload)

    assert resend.status == 400
    assert %{"error" => %{"code" => ^code}} = CodexPooler.JSON.decode!(resend.resp_body)
    refute resend.resp_body =~ "private-refusal-sentinel"
    assert [%Request{id: ^request_id, status: "failed"}, %Request{id: denied_id, status: "rejected", response_status_code: 400}] = pool_requests(setup.pool.id)
    assert Repo.all(from(a in Attempt, where: a.request_id == ^denied_id)) == []
    assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^denied_id)) == []
    assert FakeUpstream.count(upstream) == 1
  end

  for kind <- [:codeless_404, :rate_limit_429] do
    @tag kind: kind
    test "the HTTP resend of a native HTTP turn refused with a #{kind} is dispatched again", %{kind: kind} do
      {status, body} = Map.fetch!(@stepped_over, kind)

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.json_response(body, status)),
            FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.json_response(body, status))
          ])
        )

      setup = gateway_setup(upstream)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
      turn_state = Ecto.UUID.generate()
      payload = native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id)

      _original = post_turn!(setup, turn_state, payload)
      _resend = post_turn!(setup, turn_state, payload)

      assert FakeUpstream.count(upstream) == 2
    end
  end

  defp post_turn!(setup, turn_state, payload) do
    build_conn()
    |> put_req_header("authorization", setup.authorization)
    |> put_req_header("x-codex-turn-state", turn_state)
    |> put_req_header("x-openai-internal-codex-responses-lite", "true")
    |> put_req_header("content-type", "application/json")
    |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(payload))
  end

  defp native_turn_payload(thread_id, model) do
    %{
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "refused-http-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "refused-http-turn", "request_kind" => "turn"})
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic refused http turn"}]}]
    }
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))
end
