defmodule CodexPooler.Gateway.Runtime.SparkPermissionDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  @endpoint_path "/backend-api/codex/responses"
  @spark "gpt-5.3-codex-spark"

  test "canonical Spark permission dispatches while ordinary weekly is denied" do
    {upstream, setup} =
      reconciled_setup(spark_usage(), exposed_model_id: @spark, upstream_model_id: @spark)

    {auth, payload, options} = request_context(setup)
    assert {:ok, %{status: 200}} = Service.execute(auth, @endpoint_path, payload, options)
    assert generation_count(upstream) == 1
  end

  test "ordinary capacity never overrides an explicit Spark denial" do
    usage =
      blocked_spark_usage(:spark_denied)
      |> Map.delete("rate_limit_reached_type")
      |> put_in(["rate_limit", "allowed"], true)
      |> put_in(["rate_limit", "limit_reached"], false)
      |> put_in(["rate_limit", "primary_window", "used_percent"], 10)

    {upstream, setup} =
      reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
    assert generation_count(upstream) == 0
  end

  test "Spark's explicit permission remains authoritative at rounded 100 percent" do
    usage =
      update_in(spark_usage(), ["additional_rate_limits"], fn [meter] ->
        [
          put_in(meter, ["rate_limit", "primary_window", "used_percent"], 100)
          |> put_in(["rate_limit", "secondary_window", "used_percent"], 100)
        ]
      end)

    {upstream, setup} =
      reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert generation_count(upstream) == 1
  end

  test "canonical header meter preserves permission for consecutive dispatches" do
    usage = spark_usage()

    {upstream, setup} =
      reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

    [meter] = usage["additional_rate_limits"]
    {:path_json, responses} = routes(usage)

    headers =
      Enum.flat_map([{"primary", 300}, {"secondary", 10_080}], fn {kind, minutes} ->
        prefix = "x-codex-bengalfox-#{kind}"

        [
          {"#{prefix}-used-percent", "1"},
          {"#{prefix}-window-minutes", to_string(minutes)},
          {"#{prefix}-reset-at", to_string(meter["rate_limit"]["#{kind}_window"]["reset_at"])}
        ]
      end)

    FakeUpstream.set_mode(
      upstream,
      {:path_json,
       Map.put(
         responses,
         @endpoint_path,
         FakeUpstream.json_response_with_headers(
           %{"id" => "resp_spark_headers", "object" => "response", "output" => []},
           headers
         )
       )}
    )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert generation_count(upstream) == 2
  end

  test "fresh permission remains usable when the measurement is retained" do
    usage = spark_usage()

    {upstream, setup} =
      reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

    alias CodexPooler.Upstreams.Quota.{RoutingQuotaSnapshot, Windows}

    snapshot =
      RoutingQuotaSnapshot.load_by_identity_ids([setup.identity.id], DateTime.utc_now())[
        setup.identity.id
      ]

    older = DateTime.add(snapshot.availability.observed_at, -30, :second)

    retained = %{
      snapshot
      | raw_windows:
          Enum.map(snapshot.raw_windows, fn window ->
            if window.model == @spark, do: %{window | observed_at: older}, else: window
          end)
    }

    assert Windows.routing_quota_eligibility_from_snapshot(retained,
             model: @spark,
             upstream_model: @spark
           ).eligible?

    FakeUpstream.set_mode(upstream, routes(blocked_spark_usage(:spark_denied)))

    assert {:ok, _} =
             PoolReconciliation.refresh_quota_from_usage(
               Repo.reload!(setup.identity),
               setup.assignment
             )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
  end

  for blocker <- [:spend, :workspace, :spark_denied, :missing_flags, :wrong_meter] do
    test "Spark cannot bypass #{blocker}" do
      usage = blocked_spark_usage(unquote(blocker))

      {upstream, setup} =
        reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

      assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
      assert generation_count(upstream) == 0
    end
  end

  test "a later workspace denial revokes an existing Spark grant" do
    {upstream, setup} =
      reconciled_setup(spark_usage(), exposed_model_id: @spark, upstream_model_id: @spark)

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    FakeUpstream.set_mode(upstream, routes(blocked_spark_usage(:workspace)))

    assert {:ok, _identity} =
             PoolReconciliation.refresh_quota_from_usage(
               Repo.reload!(setup.identity),
               setup.assignment
             )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
    assert generation_count(upstream) == 1
  end

  test "stale or previous credential epoch Spark grants cannot route" do
    {_upstream, setup} =
      reconciled_setup(spark_usage(), exposed_model_id: @spark, upstream_model_id: @spark)

    alias CodexPooler.Upstreams.Quota.{RoutingQuotaSnapshot, Windows}
    now = DateTime.utc_now()

    snapshot =
      RoutingQuotaSnapshot.load_by_identity_ids([setup.identity.id], now)[setup.identity.id]

    opts = [model: @spark, upstream_model: @spark]
    assert Windows.routing_quota_eligibility_from_snapshot(snapshot, opts).eligible?

    refute Windows.routing_quota_eligibility_from_snapshot(
             %{snapshot | credential_epoch: snapshot.credential_epoch + 1},
             opts
           ).eligible?

    refute Windows.routing_quota_eligibility_from_snapshot(
             %{snapshot | as_of: DateTime.add(now, 3600, :second)},
             opts
           ).eligible?
  end

  test "Spark stays routable after its runtime meter event" do
    usage = spark_usage()

    {upstream, setup} =
      reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    [meter] = usage["additional_rate_limits"]

    event = %{
      "type" => "codex.rate_limits",
      "metered_feature" => "codex_bengalfox",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => 1,
          "window_minutes" => 300,
          "reset_at" => meter["rate_limit"]["primary_window"]["reset_at"]
        },
        "secondary" => %{
          "used_percent" => 1,
          "window_minutes" => 10_080,
          "reset_at" => meter["rate_limit"]["secondary_window"]["reset_at"]
        }
      }
    }

    alias CodexPooler.Gateway.Runtime.RateLimitObserver

    assert {:ok, state} =
             RateLimitObserver.collect_events(
               "data: " <> CodexPooler.JSON.encode!(event) <> "\n\n",
               RateLimitObserver.event_state()
             )

    assert :ok = RateLimitObserver.commit_events(Repo.reload!(setup.identity), state)
    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert generation_count(upstream) == 2
    FakeUpstream.set_mode(upstream, routes(blocked_spark_usage(:spark_denied)))

    assert {:ok, _} =
             PoolReconciliation.refresh_quota_from_usage(
               Repo.reload!(setup.identity),
               setup.assignment
             )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
    assert generation_count(upstream) == 2
  end

  test "Spark permission never grants an ordinary model" do
    {upstream, setup} = reconciled_setup(spark_usage())
    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
    assert generation_count(upstream) == 0
  end

  defp spark_usage do
    denied_payload(:denied)
    |> Map.put("rate_limit_reached_type", %{"type" => "rate_limit_reached"})
    |> Map.put("spend_control", %{"reached" => false})
    |> Map.put("additional_rate_limits", [
      %{
        "limit_name" => "GPT-5.3-Codex-Spark",
        "metered_feature" => "codex_bengalfox",
        "rate_limit" => %{
          "allowed" => true,
          "limit_reached" => false,
          "primary_window" => Map.put(window(18_000), "used_percent", 0),
          "secondary_window" => Map.put(window(604_800), "used_percent", 0)
        }
      }
    ])
  end

  defp blocked_spark_usage(:spend),
    do: Map.put(spark_usage(), "spend_control", %{"reached" => true})

  defp blocked_spark_usage(:workspace),
    do:
      Map.put(spark_usage(), "rate_limit_reached_type", %{
        "type" => "workspace_owner_credits_depleted"
      })

  defp blocked_spark_usage(kind) do
    update_in(spark_usage(), ["additional_rate_limits"], fn [limit] ->
      [
        case kind do
          :spark_denied ->
            put_in(
              limit,
              ["rate_limit"],
              Map.merge(limit["rate_limit"], %{"allowed" => false, "limit_reached" => true})
            )

          :missing_flags ->
            update_in(limit, ["rate_limit"], &Map.drop(&1, ["allowed", "limit_reached"]))

          :wrong_meter ->
            Map.put(limit, "metered_feature", "unknown_meter")
        end
      ]
    end)
  end

  defp reconciled_setup(usage, opts \\ []) do
    upstream = start_upstream(routes(usage))
    setup = gateway_setup(upstream, Keyword.put(opts, :quota?, false))

    identity =
      setup.identity
      |> Ecto.Changeset.change(
        metadata: Map.put(setup.identity.metadata, "usage_base_url", FakeUpstream.url(upstream))
      )
      |> Repo.update!()

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, setup.assignment)

    assert Enum.any?(FakeUpstream.requests(upstream), &String.ends_with?(&1.path, "/usage"))
    {upstream, %{setup | identity: identity}}
  end

  defp request_context(setup) do
    assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    assert {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    payload = %{"model" => setup.model.exposed_model_id, "input" => []}
    options = RequestOptions.build(%{api_key_policy: policy}, @endpoint_path, payload)
    {auth, payload, options}
  end

  defp dispatch(conn, setup) do
    conn
    |> put_req_header("authorization", setup.authorization)
    |> post(@endpoint_path, %{"model" => setup.model.exposed_model_id, "input" => []})
  end

  defp generation_count(upstream) do
    Enum.count(FakeUpstream.requests(upstream), &(&1.method == "POST"))
  end

  defp routes(usage) do
    {:path_json,
     %{
       "/api/codex/usage" => {200, usage},
       "/backend-api/codex/usage" => {200, usage},
       "/wham/usage" => {200, usage},
       "/backend-api/wham/usage" => {200, usage},
       @endpoint_path =>
         {200, %{"id" => "resp_permission_fixture", "object" => "response", "output" => []}}
     }}
  end

  defp usage_payload(shape) do
    rate_limit = %{
      "allowed" => true,
      "limit_reached" => false,
      "primary_window" => window(if(shape == :weekly_primary, do: 604_800, else: 18_000)),
      "secondary_window" => if(shape == :weekly_primary, do: nil, else: window(604_800))
    }

    %{
      "plan_type" => "plus",
      "rate_limit" => rate_limit,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}
    }
  end

  defp denied_payload(:denied) do
    usage_payload(:weekly_primary)
    |> put_in(["rate_limit", "allowed"], false)
    |> put_in(["rate_limit", "limit_reached"], true)
  end

  defp window(seconds) do
    %{
      "used_percent" => 100,
      "limit_window_seconds" => seconds,
      "reset_after_seconds" => seconds,
      "reset_at" => DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_unix()
    }
  end
end
