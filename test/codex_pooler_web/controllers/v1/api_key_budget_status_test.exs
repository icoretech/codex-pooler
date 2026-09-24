defmodule CodexPoolerWeb.V1.APIKeyBudgetStatusTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  for endpoint <- ["/backend-api/codex/responses", "/v1/responses"],
      stream? <- [false, true] do
    # A daily token window is a rate limit: 429 with its reset as the hint, and
    # no SDK retry within seconds (findings#206 row 206-427; it was 403).
    test "#{endpoint} stream=#{stream?} rejects a valid key's exhausted budget as a policy rate limit",
         %{
           conn: conn
         } do
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream)
      owner = Repo.get!(User, setup.api_key.created_by_user_id)
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, _updated} =
               Access.update_api_key_with_policy(scope, setup.api_key, %{
                 default_policy: %{max_tokens_per_day: 1}
               })

      assert {:ok, _auth} = Access.authenticate_authorization_header(setup.authorization)

      conn =
        conn
        |> put_req_header("authorization", setup.authorization)
        |> post(unquote(endpoint), %{
          "model" => setup.model.exposed_model_id,
          "input" => [%{"role" => "user", "content" => "synthetic budget fixture"}],
          "stream" => unquote(stream?)
        })

      assert %{"error" => %{"code" => "api_key_policy_limit_exceeded", "type" => "rate_limit_error"}} =
               json_response(conn, 429)

      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..86_400
      assert get_resp_header(conn, "x-should-retry") == ["false"]

      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
    end
  end
end
