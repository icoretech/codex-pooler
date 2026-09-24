defmodule CodexPoolerWeb.V1.APIKeyOutputBudgetCharacterizationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  # Characterizes current Full-mode accounting with synthetic terminal usage.
  # It does not establish what quantity any real provider can generate.
  for endpoint <- ["/backend-api/codex/responses", "/v1/responses"],
      stream? <- [false, true] do
    test "#{endpoint} stream=#{stream?} settles synthetic usage above the budget before denying the next request",
         %{conn: conn} do
      upstream =
        start_upstream(
          terminal_response(unquote(endpoint), unquote(stream?), %{
            "id" => "resp_synthetic_output_budget",
            "status" => "completed",
            "output" => [],
            "usage" => %{
              "input_tokens" => 16,
              "output_tokens" => 4_096,
              "total_tokens" => 4_112
            }
          })
        )

      setup = gateway_setup(upstream)
      owner = Repo.get!(User, setup.api_key.created_by_user_id)
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, _updated} =
               Access.update_api_key_with_policy(scope, setup.api_key, %{
                 default_policy: %{
                   max_tokens_per_day: 2_048,
                   max_output_tokens_per_request: 512
                 }
               })

      assert {:ok, _auth} = Access.authenticate_authorization_header(setup.authorization)

      payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"role" => "user", "content" => "synthetic budget fixture"}],
        "max_output_tokens" => 512,
        "stream" => unquote(stream?)
      }

      completed =
        conn
        |> put_req_header("authorization", setup.authorization)
        |> post(unquote(endpoint), payload)

      assert completed.status == 200

      if unquote(stream?) do
        assert completed.resp_body =~ "response.completed"
      else
        assert %{"status" => "completed", "usage" => %{"output_tokens" => 4_096}} =
                 json_response(completed, 200)
      end

      assert [captured] = FakeUpstream.requests(upstream)
      refute Map.has_key?(captured.json, "max_output_tokens")

      assert [request] = Repo.all(from(r in Request, where: r.api_key_id == ^setup.api_key.id))
      assert request.status == "succeeded"
      assert request.request_metadata["routing"]["model_serving_mode"] == "full"

      reservation = Repo.get_by!(LedgerEntry, request_id: request.id, entry_kind: "reservation")
      assert reservation.output_tokens == 512
      assert reservation.total_tokens <= 2_048

      settlement =
        Repo.get_by!(LedgerEntry,
          request_id: request.id,
          entry_kind: "settlement",
          amount_status: "recorded"
        )

      assert settlement.output_tokens == 4_096
      assert settlement.total_tokens == 4_112
      assert settlement.total_tokens > 2_048
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1

      denied =
        build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> post(unquote(endpoint), payload)

      assert %{"error" => %{"code" => "api_key_policy_limit_exceeded"}} =
               json_response(denied, 429)

      assert length(FakeUpstream.requests(upstream)) == 1

      assert Repo.aggregate(
               from(a in Attempt,
                 join: r in Request,
                 on: r.id == a.request_id,
                 where: r.api_key_id == ^setup.api_key.id
               ),
               :count
             ) == 1
    end
  end

  for endpoint <- ["/backend-api/codex/responses", "/v1/responses"],
      stream? <- [false, true] do
    test "#{endpoint} stream=#{stream?} completed response without usage retains provisional pressure and denies another request" do
      upstream =
        start_upstream(
          terminal_response(unquote(endpoint), unquote(stream?), %{
            "id" => "resp_synthetic_missing_usage",
            "status" => "completed",
            "output" => []
          })
        )

      setup = gateway_setup(upstream)
      owner = Repo.get!(User, setup.api_key.created_by_user_id)
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, _updated} =
               Access.update_api_key_with_policy(scope, setup.api_key, %{
                 default_policy: %{
                   max_tokens_per_day: 600,
                   max_output_tokens_per_request: 512
                 }
               })

      payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"role" => "user", "content" => "synthetic fixture"}],
        "max_output_tokens" => 512,
        "stream" => unquote(stream?)
      }

      completed =
        build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> post(unquote(endpoint), payload)

      assert completed.status == 200
      assert length(FakeUpstream.requests(upstream)) == 1
      assert [request] = Repo.all(from(r in Request, where: r.api_key_id == ^setup.api_key.id))
      assert request.status == "succeeded"
      assert request.usage_status == "usage_unknown"
      assert request.request_metadata["routing"]["model_serving_mode"] == "full"

      assert [settlement] =
               Repo.all(
                 from(l in LedgerEntry,
                   where: l.api_key_id == ^setup.api_key.id and l.entry_kind == "settlement"
                 )
               )

      assert settlement.usage_status == "usage_unknown"
      assert settlement.total_tokens >= 512
      assert Accounting.LedgerReads.outstanding_reservation_count(setup.api_key.id) == 0
      windows = [{:daily, DateTime.add(DateTime.utc_now(), -86_400, :second)}]

      assert %{
               effective_total_tokens: pressure,
               effective_request_count: 1,
               known_total_tokens: 0
             } = Map.fetch!(LedgerEntries.window_usages(setup.api_key.id, windows), :daily)

      assert pressure >= 512

      denied =
        build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> post(unquote(endpoint), payload)

      assert %{"error" => %{"code" => "api_key_policy_limit_exceeded"}} =
               json_response(denied, 429)

      assert length(FakeUpstream.requests(upstream)) == 1
    end
  end

  defp terminal_response("/backend-api/codex/responses", false, response),
    do: FakeUpstream.json_response(response)

  defp terminal_response(_endpoint, _stream?, response) do
    FakeUpstream.sse_stream([
      {"response.completed", %{"type" => "response.completed", "response" => response}}
    ])
  end
end
