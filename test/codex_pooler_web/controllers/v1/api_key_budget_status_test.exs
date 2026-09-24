defmodule CodexPoolerWeb.V1.APIKeyBudgetStatusTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  import CodexPooler.AccountingTestSupport, only: [hold_key_reservation!: 3]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  for endpoint <- ["/backend-api/codex/responses", "/v1/responses"],
      stream? <- [false, true] do
    # A daily token window is a rate limit: 429 with its reset as the hint, and
    # no SDK retry within seconds (findings#206 row 206-427; it was 403). The
    # window is exhausted by another in-flight request of the key; the request
    # fits under the window's max on its own.
    test "#{endpoint} stream=#{stream?} rejects a valid key's exhausted budget as a policy rate limit",
         %{
           conn: conn
         } do
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream)
      holder = hold_key_reservation!(setup.authorization, setup.model, 10_000)
      put_daily_budget!(setup, 10_000)

      conn = post_budget_request(conn, setup, unquote(endpoint), unquote(stream?))

      assert %{"error" => %{"code" => "api_key_policy_limit_exceeded", "type" => "rate_limit_error"}} =
               json_response(conn, 429)

      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..86_400
      assert get_resp_header(conn, "x-should-retry") == ["false"]

      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Attempt, :count) == 0
      assert refused_request_ledger_entries(setup, holder) == 0
    end

    # A daily window whose max is below the request's own estimate never
    # admits that request, however long the client waits: a per-request 400
    # with no hint, not a 429 promising the next 00:00 UTC (findings#206 row
    # 206-448).
    test "#{endpoint} stream=#{stream?} rejects a request above a key's whole daily budget as an invalid request",
         %{
           conn: conn
         } do
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream)
      put_daily_budget!(setup, 1)

      conn = post_budget_request(conn, setup, unquote(endpoint), unquote(stream?))

      assert %{"error" => %{"code" => "api_key_policy_limit_exceeded", "type" => "invalid_request_error", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "max_tokens_per_day"
      assert message =~ ~r/request estimate \d+ exceeds max 1/
      assert get_resp_header(conn, "retry-after") == []
      assert get_resp_header(conn, "x-should-retry") == []

      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
    end
  end

  defp put_daily_budget!(setup, max_tokens_per_day) do
    owner = Repo.get!(User, setup.api_key.created_by_user_id)
    scope = Scope.for_user(owner, ["instance_owner"])

    assert {:ok, _updated} =
             Access.update_api_key_with_policy(scope, setup.api_key, %{
               default_policy: %{max_tokens_per_day: max_tokens_per_day}
             })

    assert {:ok, _auth} = Access.authenticate_authorization_header(setup.authorization)
  end

  defp post_budget_request(conn, setup, endpoint, stream?) do
    conn
    |> put_req_header("authorization", setup.authorization)
    |> post(endpoint, %{
      "model" => setup.model.exposed_model_id,
      "input" => [%{"role" => "user", "content" => "synthetic budget fixture"}],
      "stream" => stream?
    })
  end

  defp refused_request_ledger_entries(setup, holder) do
    Repo.aggregate(from(entry in LedgerEntry, where: entry.api_key_id == ^setup.api_key.id and entry.request_id != ^holder.id), :count)
  end
end
