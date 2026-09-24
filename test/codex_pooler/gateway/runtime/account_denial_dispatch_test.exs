defmodule CodexPooler.Gateway.Runtime.AccountDenialDispatchTest do
  # A provider 429 whose `x-codex-rate-limit-reached-type` names a workspace
  # level denial blocks the whole account, whatever model the request named and
  # however far the reported windows are from 100%. On a real install (findings#206 row
  # 206-509) the first such 429 did not remove the identity: three more requests
  # on two models and from two Pools reached it within 10 s, because an
  # account-scope window below 100% stayed usable even with the marker on it,
  # and the per-model circuit only closed the one model after three failures.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, pricing_snapshot!: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  @endpoint_path "/backend-api/codex/responses"
  @account_denials ~w(workspace_member_credits_depleted workspace_owner_credits_depleted workspace_member_usage_limit_reached workspace_owner_usage_limit_reached)

  for denial <- @account_denials do
    test "the first #{denial} 429 below 100 percent removes the identity from every model and Pool",
         %{conn: conn} do
      %{upstream: upstream, pool_a: pool_a, pool_b: pool_b, identity: identity} =
        shared_identity_setup(unquote(denial))

      assert {:ok, %{state: :available}} =
               identity |> Repo.reload!() |> Map.fetch!(:metadata) |> AccountAvailabilityStore.load()

      assert dispatch(conn, pool_a, pool_a.model).status == 429
      assert generation_count(upstream) == 1

      header_windows =
        Repo.all(
          from w in AccountQuotaWindow,
            where: w.upstream_identity_id == ^identity.id and w.source == "codex_response_headers"
        )

      assert header_windows != []
      assert Enum.all?(header_windows, &(&1.metadata["rate_limit_reached_type"] == unquote(denial)))
      assert Enum.all?(header_windows, &(Decimal.compare(&1.used_percent, Decimal.new(100)) == :lt))

      # Another Pool, another model: never dispatched to the denied account.
      assert_refused_before_dispatch(dispatch(Phoenix.ConnTest.build_conn(), pool_b, pool_b.model))
      assert generation_count(upstream) == 1

      # The same Pool on its second model, and the model that was refused.
      assert_refused_before_dispatch(dispatch(Phoenix.ConnTest.build_conn(), pool_a, pool_a.second_model))
      assert_refused_before_dispatch(dispatch(Phoenix.ConnTest.build_conn(), pool_a, pool_a.model))
      assert generation_count(upstream) == 1
      assert Repo.aggregate(Attempt, :count) == 1

      # The exclusion came from quota evidence, not from a per-model circuit.
      assert Repo.all(from c in RoutingCircuitState, where: c.status == "open") == []
    end
  end

  test "a prior usage reading above the header percentage, which wins window selection, does not keep the account routable",
       %{conn: conn} do
    %{upstream: upstream, pool_a: pool_a, pool_b: pool_b} =
      shared_identity_setup("workspace_member_credits_depleted", usage_percent: 99)

    assert dispatch(conn, pool_a, pool_a.model).status == 429
    assert_refused_before_dispatch(dispatch(Phoenix.ConnTest.build_conn(), pool_b, pool_b.model))
    assert_refused_before_dispatch(dispatch(Phoenix.ConnTest.build_conn(), pool_a, pool_a.second_model))
    assert generation_count(upstream) == 1
  end

  test "a later affirmative usage reading lifts the account denial", %{conn: conn} do
    %{upstream: upstream, pool_a: pool_a, pool_b: pool_b, identity: identity} =
      shared_identity_setup("workspace_member_credits_depleted")

    assert dispatch(conn, pool_a, pool_a.model).status == 429
    assert_refused_before_dispatch(dispatch(Phoenix.ConnTest.build_conn(), pool_b, pool_b.model))
    assert generation_count(upstream) == 1

    # The operator restores the workspace's credits; the next usage poll says so.
    FakeUpstream.set_mode(upstream, routes(usage_payload(), {200, success_body()}))

    assert {:ok, _identity} =
             PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), pool_a.assignment)

    assert dispatch(Phoenix.ConnTest.build_conn(), pool_b, pool_b.model).status == 200
    assert generation_count(upstream) == 2
  end

  test "an ordinary rate_limit_reached marker below 100 percent keeps the account routable", %{conn: conn} do
    %{upstream: upstream, pool_a: pool_a, pool_b: pool_b} = shared_identity_setup("rate_limit_reached")

    assert dispatch(conn, pool_a, pool_a.model).status == 429
    assert generation_count(upstream) == 1

    FakeUpstream.set_mode(upstream, routes(usage_payload(), {200, success_body()}))
    assert dispatch(Phoenix.ConnTest.build_conn(), pool_b, pool_b.model).status == 200
    assert generation_count(upstream) == 2
  end

  defp shared_identity_setup(denial, opts \\ []) do
    usage_percent = Keyword.get(opts, :usage_percent, 95)
    upstream = start_upstream(routes(usage_payload(usage_percent), denial_response(denial)))

    setup =
      gateway_setup(upstream,
        quota?: false,
        exposed_model_id: "gpt-denial-sol",
        upstream_model_id: "provider-denial-sol"
      )

    identity =
      setup.identity
      |> Ecto.Changeset.change(metadata: Map.put(setup.identity.metadata, "usage_base_url", FakeUpstream.url(upstream)))
      |> Repo.update!()

    # The prior usage reading says the account is allowed, as the observed install's last poll before the refusal did.
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, setup.assignment)

    second_model_a = model_for(setup.pool, setup.assignment, setup.model, "gpt-denial-luna", "provider-denial-luna")

    key_b = active_api_key_fixture()
    assignment_b = shared_assignment!(key_b.pool, identity, upstream)
    model_b = model_for(key_b.pool, assignment_b, setup.model, "gpt-denial-luna", "provider-denial-luna")

    %{
      upstream: upstream,
      identity: identity,
      pool_a: %{authorization: setup.authorization, assignment: setup.assignment, model: setup.model, second_model: second_model_a},
      pool_b: %{authorization: key_b.authorization, assignment: assignment_b, model: model_b}
    }
  end

  defp shared_assignment!(pool, identity, upstream) do
    metadata = %{"base_url" => FakeUpstream.url(upstream)}

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{assignment_label: "Shared assignment", metadata: metadata})

    assert {:ok, assignment} = PoolAssignments.activate_pool_assignment(assignment)
    assignment
  end

  defp model_for(pool, assignment, template, exposed_model_id, upstream_model_id) do
    source =
      template.metadata
      |> get_in(["source_assignment_models"])
      |> Map.values()
      |> hd()
      |> Map.merge(%{"slug" => exposed_model_id, "upstream_model_id" => upstream_model_id})

    model =
      model_fixture(pool, %{
        exposed_model_id: exposed_model_id,
        upstream_model_id: upstream_model_id,
        display_name: exposed_model_id,
        pricing_ref: upstream_model_id,
        metadata: %{
          "source_assignment_ids" => [assignment.id],
          "source_assignment_models" => %{assignment.id => source}
        },
        supports_responses: true,
        supports_streaming: true
      })

    pricing_snapshot!(model)
    model
  end

  # The Pooler's own quota refusal, whichever public shape the exhausted-Pool
  # answer takes (findings#206 row 206-508 moves it from 503 to 429); the
  # generation count next to each call is what proves nothing was dispatched.
  defp assert_refused_before_dispatch(conn) do
    assert conn.status in [429, 503]
    assert %{"error" => %{"code" => code}} = CodexPooler.JSON.decode!(conn.resp_body)
    assert code in ["quota_exhausted", "usage_limit_reached"]
  end

  defp dispatch(conn, pool, model) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> post(@endpoint_path, %{"model" => model.exposed_model_id, "input" => [], "stream" => true})
  end

  defp generation_count(upstream) do
    Enum.count(FakeUpstream.requests(upstream), &(&1.method == "POST" and &1.path == @endpoint_path))
  end

  defp routes(usage, generation) do
    {:path_json,
     %{
       "/api/codex/usage" => {200, usage},
       "/backend-api/codex/usage" => {200, usage},
       "/wham/usage" => {200, usage},
       "/backend-api/wham/usage" => {200, usage},
       @endpoint_path => generation
     }}
  end

  # The shape an observed Team account answered: a 429 whose windows sit
  # below 100% and whose reached-type header carries the workspace denial.
  defp denial_response(denial) do
    FakeUpstream.json_response_with_headers(
      %{"error" => %{"code" => "rate_limit_exceeded", "message" => "synthetic workspace denial"}},
      [
        {"x-codex-primary-used-percent", "97"},
        {"x-codex-primary-window-minutes", "300"},
        {"x-codex-primary-reset-at", Integer.to_string(reset_unix(3 * 3_600))},
        {"x-codex-secondary-used-percent", "96"},
        {"x-codex-secondary-window-minutes", "10080"},
        {"x-codex-secondary-reset-at", Integer.to_string(reset_unix(3 * 86_400))},
        {"x-codex-rate-limit-reached-type", denial}
      ],
      429
    )
  end

  defp success_body do
    %{"id" => "resp_account_denial_fixture", "object" => "response", "output" => []}
  end

  defp usage_payload(primary_percent \\ 95) do
    %{
      "plan_type" => "team",
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => window(18_000, primary_percent, 3 * 3_600),
        "secondary_window" => window(604_800, 94, 3 * 86_400)
      },
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}
    }
  end

  defp window(limit_seconds, used_percent, reset_after_seconds) do
    %{
      "used_percent" => used_percent,
      "limit_window_seconds" => limit_seconds,
      "reset_after_seconds" => reset_after_seconds,
      "reset_at" => reset_unix(reset_after_seconds)
    }
  end

  defp reset_unix(seconds), do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_unix()
end
