defmodule CodexPooler.Dev.SeedsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access.{APIKey, Invite}
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Dev.Seeds
  alias CodexPooler.Gateway.Persistence.{CodexSession, RoutingCircuitState}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingOverride, OperatorPoolAssignment, Pool}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Charts, as: QuotaCharts
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel

  import CodexPooler.AccountsFixtures

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "compact seed creates one owner and four operator accounts idempotently" do
    first = Seeds.compact()
    second = Seeds.compact()

    assert first.owner.email == "dev-owner@example.com"
    assert second.owner.id == first.owner.id
    assert User.valid_password?(second.owner, "dev-password-123")
    assert length(second.operators) == 4

    assert Enum.map(second.operators, & &1.email) == [
             "dev-admin@example.com",
             "dev-password-reset@example.com",
             "dev-disabled@example.com",
             "dev-operator@example.com"
           ]

    assert Repo.aggregate(User, :count) == 5
  end

  test "seeds do not rename or reset an existing non-dev owner" do
    %{user: owner} =
      bootstrap_owner_fixture(%{
        "display_name" => "Existing Owner",
        "email" => "existing-owner@example.com",
        "password" => "existing-owner-pass-123"
      })

    compact = Seeds.compact()
    full = Seeds.full()
    reloaded_owner = Repo.get!(User, owner.id)

    assert compact.owner.id == owner.id
    assert full.owner.id == owner.id
    assert reloaded_owner.email == "existing-owner@example.com"
    assert reloaded_owner.display_name == "Existing Owner"
    assert reloaded_owner.status == "active"
    assert User.valid_password?(reloaded_owner, "existing-owner-pass-123")
    refute User.valid_password?(reloaded_owner, "dev-password-123")
  end

  test "perf seed provides the deterministic dev owner without changing an existing owner" do
    %{user: existing_owner} =
      bootstrap_owner_fixture(%{
        "display_name" => "Existing Owner",
        "email" => "existing-owner@example.com",
        "password" => "existing-owner-pass-123"
      })

    result = Seeds.perf()
    reloaded_owner = Repo.get!(User, existing_owner.id)

    assert result.pool.slug == "dev-perf-pool"

    assert User.valid_password?(
             Repo.get!(User, result.pool.created_by_user_id),
             "dev-password-123"
           )

    assert reloaded_owner.email == "existing-owner@example.com"
    assert reloaded_owner.display_name == "Existing Owner"
    assert User.valid_password?(reloaded_owner, "existing-owner-pass-123")
  end

  test "seeds refuse when development seed gate is disabled" do
    previous = Application.get_env(:codex_pooler, :dev_seeds_enabled)
    Application.put_env(:codex_pooler, :dev_seeds_enabled, false)

    try do
      assert_raise RuntimeError, "development seeds are disabled for this environment", fn ->
        Seeds.compact()
      end

      assert_raise RuntimeError, "development seeds are disabled for this environment", fn ->
        Seeds.full()
      end

      assert_raise RuntimeError, "development seeds are disabled for this environment", fn ->
        Seeds.docs_screenshots()
      end

      assert_raise RuntimeError, "development seeds are disabled for this environment", fn ->
        Seeds.perf()
      end
    after
      Application.put_env(:codex_pooler, :dev_seeds_enabled, previous)
    end
  end

  test "perf seed recreates isolated local gateway performance rows and private bootstrap files" do
    first = Seeds.perf()
    result = Seeds.perf()

    assert result.pool.slug == "dev-perf-pool"
    assert first.pool.id != result.pool.id

    assert Repo.aggregate(from(pool in Pool, where: pool.slug == "dev-perf-pool"), :count) == 1

    assert Repo.aggregate(
             from(identity in UpstreamIdentity,
               where: fragment("?->>?", identity.metadata, "dev_seed") == "codex_pooler_perf_seed"
             ),
             :count
           ) == 12

    assert Enum.map(result.upstream_identities, & &1.account_label) ==
             Enum.map(
               1..12,
               &"perf-upstream-#{String.pad_leading(Integer.to_string(&1), 2, "0")}"
             )

    assert Enum.all?(result.upstream_identities, &(Secrets.secret_status(&1) == :present))

    assert Enum.all?(result.assignments, fn assignment ->
             assignment.metadata["base_url"] == "http://127.0.0.1:4058" and
               assignment.metadata["websocket_url"] == "ws://127.0.0.1:4058/ws" and
               assignment.metadata["cluster_base_url"] ==
                 "http://gateway-perf-fake-upstream.codex-pooler-perf.svc.cluster.local:4058"
           end)

    assert Enum.map(result.models, & &1.exposed_model_id) == [
             "gpt-5.4-mini",
             "gpt-5.4",
             "gpt-5.5"
           ]

    assert Enum.all?(result.models, fn model ->
             model.source_assignment_count == 12 and
               get_in(model.metadata, ["source_assignment_ids"]) ==
                 Enum.map(result.assignments, & &1.id)
           end)

    assert Repo.aggregate(AccountQuotaWindow, :count) == 12
    assert Repo.aggregate(RoutingCircuitState, :count) == 12
    assert Repo.aggregate(CodexSession, :count) == 3

    assert Repo.aggregate(
             from(state in RoutingCircuitState,
               where:
                 state.status == "closed" and is_nil(state.api_key_id) and
                   state.model_identifier == "gpt-5.5"
             ),
             :count
           ) == 12

    circuit_route_classes =
      Repo.all(
        from(state in RoutingCircuitState,
          group_by: state.route_class,
          select: {state.route_class, count(state.id)},
          order_by: state.route_class
        )
      )

    assert circuit_route_classes == [
             {"proxy_http", 4},
             {"proxy_stream", 4},
             {"proxy_websocket", 4}
           ]

    summary = Jason.decode!(File.read!("tmp/gateway-perf/bootstrap/seed-summary.json"))
    env = File.read!("tmp/gateway-perf/bootstrap/perf.env")
    env_stat = File.stat!("tmp/gateway-perf/bootstrap/perf.env")

    assert summary["pool_slug"] == "dev-perf-pool"
    assert summary["api_key_prefix"] == result.api_key.key_prefix
    assert summary["upstream_count"] == 12

    assert summary["http_hosts"] == [
             "127.0.0.1",
             "gateway-perf-fake-upstream.codex-pooler-perf.svc.cluster.local"
           ]

    assert summary["websocket_hosts"] == [
             "127.0.0.1",
             "gateway-perf-fake-upstream.codex-pooler-perf.svc.cluster.local"
           ]

    assert summary["metrics_token_present"] == true

    assert summary["starter_rows"] == %{
             "codex_sessions" => 3,
             "quota_windows" => 12,
             "routing_circuit_states" => 12
           }

    assert env =~ "CODEX_POOLER_PERF_API_KEY=sk-cxp-"
    assert env =~ "CODEX_POOLER_PERF_POOL_SLUG=dev-perf-pool"
    assert env =~ "CODEX_POOLER_PERF_METRICS_TOKEN=dev-perf-metrics-"
    assert env =~ "CODEX_POOLER_PERF_ALLOW_HOSTS="

    raw_api_key =
      env
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "CODEX_POOLER_PERF_API_KEY="))
      |> String.replace_prefix("CODEX_POOLER_PERF_API_KEY=", "")

    refute File.read!("tmp/gateway-perf/bootstrap/seed-summary.json") =~ raw_api_key
    assert Bitwise.band(env_stat.mode, 0o777) == 0o600
  end

  test "full seed recreates representative fake UI states without accumulating rows" do
    Seeds.full()
    result = Seeds.full()

    assert Repo.aggregate(Pool, :count) == 3
    assert statuses_for(Pool) == ["active", "active", "disabled"]

    owner_scope = Scope.for_user(result.owner, ["instance_owner"])

    assert {:ok, pools} = Pools.list_pools_for_management(owner_scope)

    assert length(pools) == 3

    active_pool = Enum.find(pools, &(&1.slug == "dev-primary"))

    assert Repo.aggregate(
             from(assignment in OperatorPoolAssignment,
               where: assignment.pool_id == ^active_pool.id and assignment.status == "active"
             ),
             :count
           ) == 3

    quota_charts = QuotaCharts.quota_remaining_charts_by_pool_ids([active_pool.id])
    primary_chart = get_in(quota_charts, [active_pool.id, :primary_5h])
    weekly_chart = get_in(quota_charts, [active_pool.id, :weekly])

    assert primary_chart.state == "usable"
    assert weekly_chart.state == "usable"
    assert Enum.any?(primary_chart.items, &(&1.label == "Dev Active Assignment"))
    assert Enum.any?(weekly_chart.items, &(&1.label == "Dev Active Assignment"))

    upstream_accounts = UpstreamAccountsReadModel.list_visible_accounts(owner_scope, pools)
    quota_labels = upstream_accounts |> Enum.flat_map(& &1.quota_limits) |> Enum.map(& &1.label)

    assert "5h" in quota_labels
    assert "Weekly" in quota_labels
    refute Enum.any?(quota_labels, &String.contains?(String.downcase(&1), "account primary"))
    refute Enum.any?(quota_labels, &String.contains?(String.downcase(&1), "account 5h"))

    assert statuses_for(APIKey) == ["active", "active", "paused", "revoked"]

    assert statuses_for(UpstreamIdentity) == [
             "active",
             "active",
             "active",
             "paused",
             "reauth_required",
             "refresh_due"
           ]

    assert statuses_for(PoolUpstreamAssignment) == [
             "active",
             "active",
             "active",
             "active",
             "active",
             "paused",
             "reauth_required"
           ]

    assert statuses_for(Request) == [
             "failed",
             "in_progress",
             "rejected",
             "succeeded",
             "succeeded",
             "succeeded",
             "succeeded",
             "succeeded",
             "succeeded",
             "succeeded",
             "succeeded"
           ]

    assert statuses_for(Invite) == ["accepted", "active", "expired", "revoked"]

    assert Repo.aggregate(AccountQuotaWindow, :count) == 10

    account_windows =
      Repo.all(
        from window in AccountQuotaWindow,
          where: window.quota_scope == "account",
          select: {window.quota_key, window.window_kind, window.display_label, window.limit_name}
      )

    assert Enum.all?(account_windows, fn {quota_key, _kind, display_label, limit_name} ->
             quota_key == "account" and is_nil(display_label) and is_nil(limit_name)
           end)

    refute Repo.exists?(
             from window in AccountQuotaWindow, where: window.quota_key == "account_primary"
           )

    ready_identity = Repo.get_by!(UpstreamIdentity, account_label: "Dev Ready Quota")
    exhausted_identity = Repo.get_by!(UpstreamIdentity, account_label: "Dev Exhausted Quota")

    assert Repo.get_by!(PoolUpstreamAssignment,
             upstream_identity_id: ready_identity.id,
             assignment_label: "Dev Ready Assignment",
             status: "active"
           )

    assert Repo.get_by!(PoolUpstreamAssignment,
             upstream_identity_id: exhausted_identity.id,
             assignment_label: "Dev Exhausted Assignment",
             status: "active"
           )

    ready_windows = quota_windows_for(ready_identity)
    exhausted_windows = quota_windows_for(exhausted_identity)

    assert Enum.map(ready_windows, &{&1.window_kind, &1.window_minutes, &1.freshness_state}) == [
             {"primary", 300, "fresh"},
             {"secondary", 10_080, "fresh"}
           ]

    assert Enum.map(exhausted_windows, &{&1.window_kind, &1.window_minutes, &1.freshness_state}) ==
             [
               {"primary", 300, "fresh"},
               {"secondary", 10_080, "fresh"}
             ]

    assert UpstreamQuotaReadiness.from_windows(ready_windows).label == "Quota ready"
    assert UpstreamQuotaReadiness.from_windows(exhausted_windows).label == "Quota exhausted"

    assert Enum.find(exhausted_windows, &(&1.window_kind == "secondary")).credits == 0

    seeded_jobs =
      Repo.all(from job in Oban.Job, where: job.meta["dev_seed"] == "codex_pooler_dev_seed")

    assert Enum.frequencies_by(seeded_jobs, & &1.state) == %{
             "available" => 3,
             "cancelled" => 1,
             "completed" => 2,
             "discarded" => 3,
             "executing" => 2,
             "retryable" => 3,
             "scheduled" => 1
           }

    assert seeded_jobs
           |> Enum.map(& &1.worker)
           |> Enum.uniq()
           |> Enum.sort() ==
             [
               "CodexPooler.Jobs.AccountReconciliationWorker",
               "CodexPooler.Jobs.CatalogSyncWorker",
               "CodexPooler.Jobs.DailyRollupRebuildWorker",
               "CodexPooler.Jobs.RuntimeStateCleanupWorker",
               "CodexPooler.Jobs.TokenRefreshWorker"
             ]

    future_scheduled_job =
      Enum.find(seeded_jobs, fn job ->
        job.state == "scheduled" and DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
      end)

    assert future_scheduled_job
  end

  test "documentation screenshot seed is public-safe and idempotent" do
    first = Seeds.docs_screenshots()
    result = Seeds.docs_screenshots()

    assert first.pools |> Enum.map(& &1.name) == [
             "Example Production",
             "Example Secondary",
             "Example Standby"
           ]

    assert result.pools |> Enum.map(& &1.name) == [
             "Example Production",
             "Example Secondary",
             "Example Standby"
           ]

    assert Enum.map(result.api_keys, &{&1.display_name, &1.key_prefix}) == [
             {"Build automation", "sk-cxp-docs00000001"},
             {"Release assistant", "sk-cxp-docs00000002"},
             {"Paused client", "sk-cxp-docs00000003"},
             {"Retired client", "sk-cxp-docs00000004"}
           ]

    assert Enum.all?(result.api_keys, fn api_key ->
             api_key.metadata["operator_notes"] ==
               "Generated for public documentation screenshots"
           end)

    assert Enum.map(result.upstream_identities, & &1.account_label) == [
             "Example Primary Pro",
             "Example Quota Ready",
             "Example Quota Exhausted",
             "Example Refresh Due",
             "Example Reauthentication",
             "Example Paused Account"
           ]

    assert Enum.all?(result.request_logs, fn request ->
             is_nil(request.upstream_account_label) or
               String.starts_with?(request.upstream_account_label, "Example ")
           end)

    api_key_audit_event = Enum.find(result.audit_events, &(&1.action == "api_key.create"))
    assert api_key_audit_event.details["key_prefix"] == "sk-cxp-docs00000001"

    primary_pool = Enum.find(result.pools, &(&1.name == "Example Production"))
    owner_scope = Scope.for_user(result.owner, ["instance_owner"])

    assert %{status: :synced} = Catalog.catalog_read_state(primary_pool)
    assert {:ok, snapshot} = Pools.model_serving_modes_snapshot(owner_scope, primary_pool)

    projection =
      PoolForm.model_serving_form(snapshot, Catalog.list_visible_models(primary_pool))

    assert Enum.map(projection.rows, fn row ->
             {
               row.exposed_model_id,
               row.configured_mode,
               row.effective_mode,
               row.available?
             }
           end) == [
             {"gpt-5.5", "auto", "full", true},
             {"gpt-5.4-mini", "auto", "lite", true},
             {"gpt-5.4", "full", "full", true},
             {"gpt-5.5-pro", "lite", "lite", false}
           ]

    assert Repo.aggregate(Pool, :count) == 3
    assert Repo.aggregate(APIKey, :count) == 4
    assert Repo.aggregate(SyncRun, :count) == 3
    assert Repo.aggregate(ModelServingOverride, :count) == 2
  end

  defp statuses_for(schema) do
    schema
    |> Repo.all()
    |> Enum.map(& &1.status)
    |> Enum.sort()
  end

  defp quota_windows_for(identity) do
    Repo.all(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id and window.quota_scope == "account",
        order_by: [asc: window.window_kind]
    )
  end
end
