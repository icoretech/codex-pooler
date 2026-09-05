defmodule CodexPooler.Dev.SeedsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access.{APIKey, Invite}
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.{Scope, User}

  alias CodexPooler.Admin.{
    UpstreamCircuitReadiness,
    UpstreamQuotaReadiness,
    UpstreamRoutingReadiness
  }

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.{Model, SyncRun}
  alias CodexPooler.Dev.Seeds
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.{CodexSession, RoutingCircuitState}
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Jobs.{AccountReconciliationEnqueueWorker, AccountReconciliationWorker}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingOverride, OperatorPoolAssignment, Pool}
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePath

  import CodexPooler.AccountsFixtures

  @circuit_settings %OperationalSettings{
    circuit_open_seconds: 60,
    circuit_half_open_probe_limit: 1
  }

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
             "active",
             "active",
             "active",
             "active",
             "active",
             "active",
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
             "active",
             "active",
             "active",
             "active",
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

    assert Repo.aggregate(AccountQuotaWindow, :count) == 14

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
    snapshot_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert Enum.map(ready_windows, &{&1.window_kind, &1.window_minutes, &1.freshness_state}) == [
             {"primary", 300, "fresh"},
             {"secondary", 10_080, "fresh"}
           ]

    assert Enum.map(exhausted_windows, &{&1.window_kind, &1.window_minutes, &1.freshness_state}) ==
             [
               {"primary", 300, "fresh"},
               {"secondary", 10_080, "fresh"}
             ]

    assert UpstreamQuotaReadiness.from_windows(ready_windows, snapshot_at).label == "Quota ready"

    assert UpstreamQuotaReadiness.from_windows(exhausted_windows, snapshot_at).label ==
             "Quota exhausted"

    assert Enum.find(exhausted_windows, &(&1.window_kind == "secondary")).credits == 0

    windowless_states =
      for {label, _expected} <- [
            {"Sample Provider Available",
             {"provider_available_no_windows", "Provider available", :warning, true}},
            {"Sample Provider Blocked", {"blocked", "Quota blocked", :warning, false}},
            {"Sample Provider Unknown", {"missing_evidence", "Quota missing", :warning, false}}
          ],
          into: %{} do
        identity = Repo.get_by!(UpstreamIdentity, account_label: label)

        snapshot =
          RoutingQuotaSnapshot.from_identity(identity, quota_windows_for(identity), snapshot_at)

        readiness = UpstreamQuotaReadiness.from_snapshot(snapshot)

        assert readiness.primary_window == nil
        assert readiness.primary_30d_window == nil
        assert readiness.weekly_window == nil

        {label, {readiness.state, readiness.label, readiness.tone, readiness.routing_ready_now?}}
      end

    assert windowless_states == %{
             "Sample Provider Available" =>
               {"provider_available_no_windows", "Provider available", :warning, true},
             "Sample Provider Blocked" => {"blocked", "Quota blocked", :warning, false},
             "Sample Provider Unknown" => {"missing_evidence", "Quota missing", :warning, false}
           }

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

  test "full seed provides exactly four generic expiry fixtures with comparable assignments secrets and reset state" do
    result = Seeds.full()

    expected = %{
      "Expiry Known Future" => "known_future",
      "Expiry Known Past" => "known_past",
      "Expiry Unknown Current" => "unknown_current",
      "Markerless Legacy Writer" => "markerless_legacy_writer"
    }

    expiry_identities =
      Repo.all(
        from identity in UpstreamIdentity,
          where: fragment("?->>?", identity.metadata, "dev_seed_fixture") == "expiry",
          order_by: [asc: identity.account_label]
      )

    assert Map.new(expiry_identities, &{&1.account_label, &1.metadata["expiry_fixture"]}) ==
             expected

    assert length(expiry_identities) == 4

    assert Enum.all?(expiry_identities, fn identity ->
             identity.status == "active" and identity.plan_family == "sample" and
               identity.plan_label == "Sample" and
               get_in(identity.metadata, ["saved_resets", "status"]) == "reported" and
               get_in(identity.metadata, ["saved_resets", "available_count"]) == 1 and
               match?({:ok, _}, Secrets.decrypt_active_secret(identity, "access_token")) and
               match?({:ok, _}, Secrets.decrypt_active_secret(identity, "refresh_token"))
           end)

    assignments =
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          where: assignment.upstream_identity_id in ^Enum.map(expiry_identities, & &1.id),
          order_by: [asc: assignment.assignment_label]
      )

    assert length(assignments) == 4

    assert Enum.all?(assignments, fn assignment ->
             assignment.status == "active" and assignment.health_status == "active" and
               assignment.eligibility_status == "eligible"
           end)

    assert Enum.map(result.expiry_fixtures, & &1.account_label) ==
             Map.keys(expected) |> Enum.sort()
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
             "Example Paused Account",
             "Example Circuit Clear",
             "Example Circuit Absent"
           ]

    assert Enum.map(result.upstream_identities, & &1.chatgpt_account_id) == [
             "sample-account-01",
             "sample-account-02",
             "sample-account-03",
             "sample-account-04",
             "sample-account-05",
             "sample-account-06",
             "sample-account-07",
             "sample-account-08"
           ]

    assert Enum.map(result.assignments, & &1.assignment_label) == [
             "Example Primary Assignment",
             "Example Ready Assignment",
             "Example Exhausted Assignment",
             "Example Cooldown Assignment",
             "Example Reauthentication Assignment",
             "Example Paused Assignment",
             "Example Secondary Assignment",
             "Example Circuit Clear Assignment",
             "Example Circuit Absent Assignment"
           ]

    assert {length(result.upstream_identities), length(result.assignments)} == {8, 9}

    assert {Repo.aggregate(UpstreamIdentity, :count),
            Repo.aggregate(PoolUpstreamAssignment, :count)} ==
             {8, 9}

    refute Enum.any?(result.upstream_identities, &String.starts_with?(&1.account_label, "Dev "))
    refute Enum.any?(result.assignments, &String.starts_with?(&1.assignment_label, "Dev "))

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

  test "full and documentation screenshot seeds preserve their existing ordered shapes" do
    Seeds.full()
    full = Seeds.full()

    assert Enum.take(Enum.map(full.upstream_identities, & &1.chatgpt_account_id), 6) == [
             "dev-acct-active",
             "dev-acct-ready-quota",
             "dev-acct-exhausted-quota",
             "dev-acct-plus",
             "dev-acct-reauth",
             "dev-acct-paused"
           ]

    assert Enum.take(Enum.map(full.assignments, & &1.assignment_label), 7) == [
             "Dev Active Assignment",
             "Dev Ready Assignment",
             "Dev Exhausted Assignment",
             "Dev Cooldown Assignment",
             "Dev Reauth Assignment",
             "Dev Paused Assignment",
             "Dev Active Secondary Assignment"
           ]

    assert {length(full.upstream_identities), length(full.assignments)} == {15, 16}

    assert {Repo.aggregate(UpstreamIdentity, :count),
            Repo.aggregate(PoolUpstreamAssignment, :count)} ==
             {15, 16}

    Seeds.docs_screenshots()
    docs = Seeds.docs_screenshots()

    assert Enum.take(Enum.map(docs.upstream_identities, & &1.chatgpt_account_id), 6) == [
             "sample-account-01",
             "sample-account-02",
             "sample-account-03",
             "sample-account-04",
             "sample-account-05",
             "sample-account-06"
           ]

    assert Enum.take(Enum.map(docs.assignments, & &1.assignment_label), 7) == [
             "Example Primary Assignment",
             "Example Ready Assignment",
             "Example Exhausted Assignment",
             "Example Cooldown Assignment",
             "Example Reauthentication Assignment",
             "Example Paused Assignment",
             "Example Secondary Assignment"
           ]

    assert {length(docs.upstream_identities), length(docs.assignments)} == {8, 9}

    assert {Repo.aggregate(UpstreamIdentity, :count),
            Repo.aggregate(PoolUpstreamAssignment, :count)} ==
             {8, 9}
  end

  test "full seed exposes distinct stable circuit visibility states" do
    Seeds.full()
    result = Seeds.full()
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    later_observed_at = DateTime.add(observed_at, 2, :hour)

    assert {length(result.upstream_identities), length(result.assignments)} == {15, 16}
    assert Repo.aggregate(UpstreamIdentity, :count) == 15
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 16
    assert Repo.aggregate(Model, :count) == 6
    assert Repo.aggregate(AccountQuotaWindow, :count) == 14
    assert Repo.aggregate(RoutingCircuitState, :count) == 3

    assert Enum.map(result.upstream_identities, & &1.chatgpt_account_id) == [
             "dev-acct-active",
             "dev-acct-ready-quota",
             "dev-acct-exhausted-quota",
             "dev-acct-plus",
             "dev-acct-reauth",
             "dev-acct-paused",
             "dev-acct-circuit-clear",
             "dev-acct-circuit-absent",
             "dev-acct-provider-available-no-windows",
             "dev-acct-provider-blocked-no-windows",
             "dev-acct-provider-unknown-no-windows",
             "dev-acct-expiry-known-future",
             "dev-acct-expiry-known-past",
             "dev-acct-expiry-unknown-current",
             "dev-acct-expiry-markerless-legacy-writer"
           ]

    assert Enum.map(result.assignments, & &1.assignment_label) == [
             "Dev Active Assignment",
             "Dev Ready Assignment",
             "Dev Exhausted Assignment",
             "Dev Cooldown Assignment",
             "Dev Reauth Assignment",
             "Dev Paused Assignment",
             "Dev Active Secondary Assignment",
             "Dev Circuit Clear Assignment",
             "Dev Circuit Absent Assignment",
             "Sample Available Assignment",
             "Sample Blocked Assignment",
             "Sample Unknown Assignment",
             "Expiry Known Future Assignment",
             "Expiry Known Past Assignment",
             "Expiry Unknown Current Assignment",
             "Markerless Legacy Writer Assignment"
           ]

    fixtures =
      for {identity_label, assignment_label} <- [
            {"Dev Active Pro", "Dev Active Assignment"},
            {"Dev Ready Quota", "Dev Ready Assignment"},
            {"Dev Circuit Clear", "Dev Circuit Clear Assignment"},
            {"Dev Circuit Absent", "Dev Circuit Absent Assignment"}
          ],
          into: %{} do
        identity = Repo.get_by!(UpstreamIdentity, account_label: identity_label)

        assignment =
          Repo.get_by!(PoolUpstreamAssignment,
            upstream_identity_id: identity.id,
            assignment_label: assignment_label
          )

        {assignment_label, %{identity: identity, assignment: assignment}}
      end

    served_models =
      Map.new(fixtures, fn {_label, %{assignment: assignment}} ->
        {assignment.id, ["gpt-5.4-mini"]}
      end)

    mini_model =
      Enum.find(result.models, fn model ->
        model.exposed_model_id == "gpt-5.4-mini" and model.source_assignment_count == 4
      end)

    assert mini_model

    assert MapSet.subset?(
             served_models |> Map.keys() |> MapSet.new(),
             mini_model.metadata["source_assignment_ids"] |> MapSet.new()
           )

    circuit_at_seed =
      UpstreamCircuitReadiness.by_assignment_id(served_models, @circuit_settings, observed_at)

    circuit_later =
      UpstreamCircuitReadiness.by_assignment_id(
        served_models,
        @circuit_settings,
        later_observed_at
      )

    states_at_seed = circuit_states_by_label(fixtures, circuit_at_seed)
    states_later = circuit_states_by_label(fixtures, circuit_later)

    assert states_at_seed == %{
             "Dev Active Assignment" => :blocked,
             "Dev Ready Assignment" => :recovering,
             "Dev Circuit Clear Assignment" => :closed,
             "Dev Circuit Absent Assignment" => :closed
           }

    assert states_later == %{
             "Dev Active Assignment" => :blocked,
             "Dev Ready Assignment" => :closed,
             "Dev Circuit Clear Assignment" => :closed,
             "Dev Circuit Absent Assignment" => :closed
           }

    blocked = Map.fetch!(fixtures, "Dev Active Assignment")
    recovering = Map.fetch!(fixtures, "Dev Ready Assignment")
    clear = Map.fetch!(fixtures, "Dev Circuit Clear Assignment")
    absent = Map.fetch!(fixtures, "Dev Circuit Absent Assignment")

    refute circuit_at_seed[blocked.assignment.id].ready?
    assert circuit_at_seed[recovering.assignment.id].ready?
    assert circuit_at_seed[clear.assignment.id] == UpstreamCircuitReadiness.clear()
    assert circuit_at_seed[absent.assignment.id] == UpstreamCircuitReadiness.clear()
    assert circuit_at_seed[recovering.assignment.id].blocked_lane_count == 0
    assert circuit_at_seed[recovering.assignment.id].recovering_lane_count == 1
    assert circuit_later[recovering.assignment.id] == UpstreamCircuitReadiness.clear()

    assert Repo.aggregate(
             from(state in RoutingCircuitState,
               where: state.pool_upstream_assignment_id == ^absent.assignment.id
             ),
             :count
           ) == 0

    for %{identity: identity, assignment: assignment} <- Map.values(fixtures) do
      quota_readiness =
        UpstreamQuotaReadiness.from_windows(quota_windows_for(identity), observed_at)

      assert quota_readiness.routing_ready_now?
      assert UpstreamRoutingReadiness.assignment_routing_ready?(assignment)

      assert UpstreamRoutingReadiness.from_inputs(identity, assignment, quota_readiness).routing_ready_now?
    end

    assert circuit_route_count(circuit_at_seed[blocked.assignment.id]) == 3

    for %{assignment: assignment} <- [recovering, clear, absent] do
      assert circuit_route_count(circuit_at_seed[assignment.id]) == 4
    end
  end

  test "full seed rerun recreates and refreshes quota evidence" do
    Seeds.full()
    first_quota_evidence = quota_evidence_by_logical_key()

    Seeds.full()
    second_quota_evidence = quota_evidence_by_logical_key()

    assert map_size(first_quota_evidence) == 14

    assert Map.keys(second_quota_evidence) |> MapSet.new() ==
             Map.keys(first_quota_evidence) |> MapSet.new()

    for {logical_key, first_evidence} <- first_quota_evidence do
      second_evidence = Map.fetch!(second_quota_evidence, logical_key)

      assert DateTime.compare(second_evidence.observed_at, first_evidence.observed_at) == :gt
      assert DateTime.compare(second_evidence.last_sync_at, first_evidence.last_sync_at) == :gt
      assert DateTime.compare(second_evidence.reset_at, first_evidence.reset_at) == :gt
    end
  end

  test "full seed preserves read-model circuit-demo route counts when scheduled reconciliation encounters stale quota evidence" do
    previous_dev_features_enabled = Application.get_env(:codex_pooler, :dev_features_enabled)
    Application.put_env(:codex_pooler, :dev_features_enabled, true)

    on_exit(fn ->
      if is_nil(previous_dev_features_enabled) do
        Application.delete_env(:codex_pooler, :dev_features_enabled)
      else
        Application.put_env(:codex_pooler, :dev_features_enabled, previous_dev_features_enabled)
      end

      InstanceSettings.reset_cache_for_test()
    end)

    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, before_seed} =
             InstanceSettings.update_system_settings(settings, %{
               "development" => %{"account_reconciliation_paused" => false}
             })

    result = Seeds.full()
    persisted_settings = Repo.get!(Settings, true)

    assert persisted_settings.development.account_reconciliation_paused == true

    assert persisted_settings.development.impeccable_live_enabled ==
             before_seed.development.impeccable_live_enabled

    circuit_labels = [
      "Dev Active Assignment",
      "Dev Active Secondary Assignment",
      "Dev Ready Assignment",
      "Dev Circuit Clear Assignment",
      "Dev Circuit Absent Assignment"
    ]

    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-(Evidence.freshness_ttl_seconds() + 1), :second)
      |> DateTime.truncate(:microsecond)

    identity_ids = Enum.map(result.upstream_identities, & &1.id)

    Repo.update_all(
      from(window in AccountQuotaWindow, where: window.upstream_identity_id in ^identity_ids),
      set: [observed_at: stale_at, last_sync_at: stale_at, reset_at: stale_at]
    )

    stale_windows =
      Repo.all(
        from window in AccountQuotaWindow,
          where: window.upstream_identity_id in ^identity_ids,
          select: window
      )

    assert Enum.all?(stale_windows, fn window ->
             DateTime.diff(DateTime.utc_now(), window.observed_at, :second) >=
               Evidence.freshness_ttl_seconds() + 1
           end)

    assert :ok = perform_job(AccountReconciliationEnqueueWorker, %{})
    assert [] = all_enqueued(worker: AccountReconciliationWorker, queue: :jobs)

    owner_scope = Scope.for_user(result.owner, ["instance_owner"])
    assert {:ok, pools} = Pools.list_pools_for_management(owner_scope)

    read_model_assignments =
      UpstreamAccountsReadModel.list_visible_accounts(owner_scope, pools)
      |> Enum.flat_map(& &1.assignments)
      |> Map.new(&{&1.assignment_label, &1})

    persisted_priming_statuses =
      result.assignments
      |> Enum.filter(&(&1.assignment_label in circuit_labels))
      |> Map.new(fn assignment ->
        reloaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
        {assignment.assignment_label, get_in(reloaded.metadata, ["quota_priming", "status"])}
      end)

    assert persisted_priming_statuses == Map.new(circuit_labels, &{&1, "known"})

    actual_route_counts =
      Map.new(circuit_labels, fn label ->
        assignment = Map.fetch!(read_model_assignments, label)

        assert Enum.map(RoutePath.segments(assignment), & &1.label) == [
                 "Assignment",
                 "Health",
                 "Quota",
                 "Circuit"
               ]

        {label, RoutePath.ready_count(assignment)}
      end)

    assert actual_route_counts == %{
             "Dev Active Assignment" => 3,
             "Dev Active Secondary Assignment" => 4,
             "Dev Ready Assignment" => 4,
             "Dev Circuit Clear Assignment" => 4,
             "Dev Circuit Absent Assignment" => 4
           }
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

  defp quota_evidence_by_logical_key do
    Repo.all(
      from(window in AccountQuotaWindow,
        join: identity in UpstreamIdentity,
        on: identity.id == window.upstream_identity_id,
        select: {
          {
            identity.account_label,
            window.quota_scope,
            window.quota_key,
            window.window_kind,
            window.window_minutes,
            window.model
          },
          %{
            observed_at: window.observed_at,
            last_sync_at: window.last_sync_at,
            reset_at: window.reset_at
          }
        }
      )
    )
    |> Map.new()
  end

  defp circuit_states_by_label(fixtures, circuit_readiness) do
    Map.new(fixtures, fn {label, %{assignment: assignment}} ->
      {label, circuit_readiness[assignment.id].state}
    end)
  end

  defp circuit_route_count(circuit_readiness),
    do: 3 + if(circuit_readiness.ready?, do: 1, else: 0)
end
