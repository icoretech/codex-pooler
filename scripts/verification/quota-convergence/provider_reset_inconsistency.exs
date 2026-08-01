defmodule CodexPooler.Verification.ProviderResetInconsistency do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.{Evidence, ModelWeeklyResetSemantics}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @receipt_schema_version 1
  @assert_failure_injection_env "CODEX_POOLER_QUOTA_HELPER_ASSERT_FAILURE"
  @forbidden_receipt_identifier_fields MapSet.new([
                                         "candidate_order",
                                         "card_selector",
                                         "chosen_id",
                                         "chosen_ids",
                                         "expected_id",
                                         "expected_winner_id",
                                         "floating_competitor_id",
                                         "identity_uuid",
                                         "post_snapshot_id",
                                         "reset_selector"
                                       ])
  @uuid_pattern ~r/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/i
  @pool_slug "provider-reset-proof"
  @historical_as_of ~U[2026-07-25 12:00:00.000000Z]
  @old_reset ~U[2026-07-25 03:24:36.000000Z]
  @new_reset ~U[2026-07-28 17:04:16.000000Z]
  @confirmation_key "__quota_cycle_confirmation_v1"
  @spark_limit_key "model-codex_spark-secondary-10080"

  @roles %{
    forward: "forward",
    equivalent: "equivalent",
    legacy: "legacy",
    anchored: "anchored",
    floating: "floating",
    unknown: "unknown",
    qf: "qf",
    issue_234: "issue_234",
    pressure_positive: "pressure_positive",
    pressure_exhausted: "pressure_exhausted"
  }
  @account_roles [
    :forward,
    :equivalent,
    :legacy,
    :anchored,
    :floating,
    :unknown,
    :qf,
    :issue_234,
    :pressure_positive,
    :pressure_exhausted
  ]

  @account_ids [
    "provider-reset-proof-forward",
    "provider-reset-proof-equivalent",
    "provider-reset-proof-legacy",
    "provider-reset-proof-spark-anchored",
    "provider-reset-proof-spark-floating",
    "provider-reset-proof-spark-unknown",
    "provider-reset-proof-spark-qf",
    "provider-reset-proof-issue-234-same-anchor",
    "provider-reset-proof-spark-pressure-positive",
    "provider-reset-proof-spark-pressure-exhausted"
  ]

  @qf_historical_ids %{
    floating: "10000000-0000-4000-8000-000000000001",
    markerless: "ffffffff-ffff-4fff-bfff-ffffffffffff",
    post_snapshot: "20000000-0000-4000-8000-000000000001"
  }
  @qf_browser_ids %{
    floating: "30000000-0000-4000-8000-000000000001",
    markerless: "30000000-0000-4000-8000-000000000002"
  }
  @pressure_ids %{
    positive: "40000000-0000-4000-8000-000000000001",
    positive_floating: "40000000-0000-4000-8000-000000000002",
    exhausted: "50000000-0000-4000-8000-000000000001",
    exhausted_floating: "50000000-0000-4000-8000-000000000002"
  }
  @expected_fixture_counts %{
    "pools" => 1,
    "identities" => 10,
    "pool_assignments" => 10,
    "quota_windows" => 18
  }

  @spec run([String.t()]) :: :ok
  def run(["--" | args]), do: run(args)

  def run(["seed"]) do
    cleanup()
    browser_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    try do
      seed!(browser_now)
      expected_fixture_counts!()

      emit_receipt!("seed", %{
        "browser_now" => DateTime.to_iso8601(browser_now),
        "expected_fixture_counts" => @expected_fixture_counts,
        "actual_fixture_counts" => fixture_counts()
      })

      :ok
    rescue
      error ->
        retained_fixture_counts!("seed_retained", failure_class(error))
        reraise error, __STACKTRACE__
    end
  end

  def run(["assert"]) do
    try do
      assert_convergence!()
      emit_receipt!("assert", %{"fixture_counts" => fixture_counts()})
      :ok
    rescue
      error ->
        retained_fixture_counts!("assert_retained", failure_class(error))
        reraise error, __STACKTRACE__
    end
  end

  def run(["cleanup"]), do: cleanup()

  def run(_args), do: raise("usage: provider_reset_inconsistency.exs -- seed|assert|cleanup")

  defp seed!(browser_now) do
    pool =
      %Pool{}
      |> Pool.changeset(%{
        slug: @pool_slug,
        name: "Provider reset proof",
        status: "active",
        created_at: @historical_as_of,
        updated_at: @historical_as_of
      })
      |> Repo.insert!()

    identities =
      @account_roles
      |> Enum.into(%{}, fn role -> {role, create_identity!(pool, account_id!(role))} end)

    seed_forward_transition!(identities.forward)
    seed_equivalent_transition!(identities.equivalent)
    seed_legacy_transition!(identities.legacy)
    seed_issue_234_same_anchor_transition!(identities.issue_234)
    seed_historical_qf!(identities.qf)
    seed_browser_fixtures!(identities, browser_now)
  end

  defp seed_forward_transition!(identity) do
    initial_at = ~U[2026-07-21 17:00:00.000000Z]
    candidate_at = ~U[2026-07-21 17:04:00.000000Z]
    confirmed_at = ~U[2026-07-21 17:08:00.000000Z]
    runtime_at = ~U[2026-07-21 17:09:00.000000Z]

    record_provider!(identity, initial_at, "54", @old_reset, initial_at)
    record_runtime!(identity, initial_at, "54", @old_reset)
    record_provider!(identity, candidate_at, "0", @new_reset, candidate_at)

    candidate = provider_row!(identity)

    expect!(
      Decimal.equal?(candidate.used_percent, Decimal.new("54")),
      "candidate changed pressure"
    )

    expect!(
      match?({:ok, _candidate}, EvidenceStore.parse_candidate(candidate.metadata)),
      "candidate missing"
    )

    record_provider!(identity, confirmed_at, "0", @new_reset, confirmed_at)
    confirmed = provider_row!(identity)
    marker = confirmed.metadata[@confirmation_key]

    expect!(confirmed.metadata["reset_state"] == "anchored", "cycle not anchored")
    expect!(is_map(marker), "confirmation marker missing")
    expect!(marker["source_class"] == "provider_usage", "confirmation source mismatch")

    selection = Windows.quota_window_selection_data(identity, at: confirmed_at)
    expect!(selection.secondary.id == confirmed.id, "confirmed provider cycle not selected")

    matching_runtime = record_runtime!(identity, runtime_at, "1", @new_reset)
    runtime_selection = Windows.quota_window_selection_data(identity, at: runtime_at)

    expect!(
      runtime_selection.secondary.id == matching_runtime.id,
      "same-cycle runtime precedence not restored"
    )
  end

  defp seed_equivalent_transition!(identity) do
    accepted_at = ~U[2026-07-21 17:06:00.000000Z]
    accepted_reset = ~U[2026-07-28 17:06:01.000000Z]
    equivalent_at = ~U[2026-07-22 01:14:00.000000Z]
    equivalent_reset = ~U[2026-07-28 17:09:00.000000Z]

    record_provider!(identity, accepted_at, "0", accepted_reset, ~U[2026-07-21 17:06:01.000000Z])
    record_provider!(identity, equivalent_at, "0", equivalent_reset, equivalent_at)
    maintained = provider_row!(identity)

    expect!(
      DateTime.compare(maintained.reset_at, equivalent_reset) == :eq,
      "equivalent reset not refreshed"
    )

    expect!(
      not Map.has_key?(maintained.metadata, "__quota_confirmed_candidate_v1"),
      "equivalent candidate persisted"
    )
  end

  defp seed_legacy_transition!(identity) do
    legacy_at = DateTime.add(@historical_as_of, -2 * Evidence.freshness_ttl_seconds(), :second)
    current_at = DateTime.add(legacy_at, Evidence.freshness_ttl_seconds(), :second)

    insert_window!(identity, "primary", "codex_response_headers", legacy_at, @old_reset, "2")
    insert_window!(identity, "secondary", "codex_usage_api", current_at, @new_reset, "0")
  end

  defp seed_issue_234_same_anchor_transition!(identity) do
    canonical_at = ~U[2026-07-21 17:00:00.000000Z]
    candidate_at = ~U[2026-07-21 17:05:00.000000Z]
    confirmed_at = ~U[2026-07-21 17:08:00.000000Z]
    fixed_anchor = ~U[2026-07-26 17:00:00.000000Z]

    {:ok, canonical} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_usage_api", canonical_at, "100", fixed_anchor)
        |> Map.merge(%{active_limit: 243, credits: 0}),
        canonical_at,
        canonical_at
      )

    record_safe_fixed_zero!(identity, candidate_at, fixed_anchor)
    pending = Repo.get!(AccountQuotaWindow, canonical.id)
    assert_issue_234_pending!(identity, pending, candidate_at, fixed_anchor)

    record_safe_fixed_zero!(identity, confirmed_at, fixed_anchor)
    confirmed = Repo.get!(AccountQuotaWindow, canonical.id)
    assert_issue_234_confirmed!(identity, confirmed, confirmed_at, fixed_anchor)

    emit_receipt!("issue_234_same_anchor", %{
      "candidate_span_seconds" => DateTime.diff(confirmed_at, candidate_at, :second),
      "canonical_percent" => 100,
      "pending_percent" => 100,
      "pending_capacity_preserved" => true,
      "pending_routing_eligible" => false,
      "confirmed_percent" => 0,
      "confirmed_capacity_state" => "absent",
      "confirmed_cycle_state" => "anchored",
      "confirmed_routing_state" => "weekly_only_probe",
      "compatibility_allowed" => true,
      "compatibility_limit_reached" => false
    })
  end

  defp seed_historical_qf!(identity) do
    floating =
      insert_spark_window!(identity, %{
        id: @qf_historical_ids.floating,
        source: "codex_usage_api",
        used_percent: "0",
        reset_at: ~U[2026-08-01 12:00:00.000000Z],
        observed_at: ~U[2026-07-25 11:59:00.000000Z],
        last_sync_at: ~U[2026-07-25 11:59:00.000000Z],
        merge_precedence: 60,
        metadata: %{"reset_state" => "floating"},
        raw_limit_id: "qf001-usage"
      })

    markerless =
      insert_spark_window!(identity, %{
        id: @qf_historical_ids.markerless,
        source: "codex_response_headers",
        used_percent: "0",
        reset_at: ~U[2026-08-01 12:30:00.000000Z],
        observed_at: ~U[2026-07-25 11:59:30.000000Z],
        last_sync_at: ~U[2026-07-25 11:59:30.000000Z],
        merge_precedence: 80,
        metadata: %{},
        raw_limit_id: "qf001-header"
      })

    post_snapshot =
      insert_spark_window!(identity, %{
        id: @qf_historical_ids.post_snapshot,
        source: "codex_rate_limit_event",
        used_percent: "0",
        reset_at: ~U[2026-08-01 13:00:00.000000Z],
        observed_at: ~U[2026-07-25 12:00:00.000001Z],
        last_sync_at: ~U[2026-07-25 12:00:00.000001Z],
        merge_precedence: 90,
        metadata: %{"reset_state" => "anchored"},
        raw_limit_id: "qf001-post-snapshot"
      })

    expect!(floating.id != markerless.id, "QF evidence identities must differ")

    expect!(
      post_snapshot.id != floating.id and post_snapshot.id != markerless.id,
      "QF post-snapshot identity must differ"
    )
  end

  defp seed_browser_fixtures!(identities, browser_now) do
    browser_reset = DateTime.add(browser_now, 7, :day)

    record_spark!(identities.anchored, browser_now, browser_reset, %{"reset_state" => "anchored"})
    record_spark!(identities.floating, browser_now, browser_reset, %{"reset_state" => "floating"})
    record_spark!(identities.unknown, browser_now, browser_reset, %{})

    insert_spark_window!(identities.qf, %{
      id: @qf_browser_ids.floating,
      source: "codex_usage_api",
      used_percent: "0",
      reset_at: browser_reset,
      observed_at: DateTime.add(browser_now, -1, :microsecond),
      last_sync_at: DateTime.add(browser_now, -1, :microsecond),
      merge_precedence: 60,
      metadata: %{"reset_state" => "floating"},
      raw_limit_id: "qf-browser-usage"
    })

    insert_spark_window!(identities.qf, %{
      id: @qf_browser_ids.markerless,
      source: "codex_response_headers",
      used_percent: "0",
      reset_at: DateTime.add(browser_reset, 30, :minute),
      observed_at: browser_now,
      last_sync_at: browser_now,
      merge_precedence: 80,
      metadata: %{},
      raw_limit_id: "qf-browser-header"
    })

    seed_pressure_pair!(
      identities.pressure_positive,
      @pressure_ids.positive,
      @pressure_ids.positive_floating,
      "54",
      browser_now,
      browser_reset
    )

    seed_pressure_pair!(
      identities.pressure_exhausted,
      @pressure_ids.exhausted,
      @pressure_ids.exhausted_floating,
      "100",
      browser_now,
      browser_reset
    )
  end

  defp seed_pressure_pair!(
         identity,
         pressure_id,
         floating_id,
         pressure_percent,
         browser_now,
         browser_reset
       ) do
    insert_spark_window!(identity, %{
      id: pressure_id,
      source: "codex_usage_api",
      active_limit: 100,
      credits: 0,
      used_percent: pressure_percent,
      reset_at: browser_reset,
      observed_at: DateTime.add(browser_now, -1, :microsecond),
      last_sync_at: DateTime.add(browser_now, -1, :microsecond),
      merge_precedence: 60,
      metadata: %{"reset_state" => "floating"},
      raw_limit_id: "pressure-#{pressure_percent}-usage"
    })

    insert_spark_window!(identity, %{
      id: floating_id,
      source: "codex_response_headers",
      active_limit: 100,
      credits: 0,
      used_percent: "0",
      reset_at: DateTime.add(browser_reset, 30, :minute),
      observed_at: browser_now,
      last_sync_at: browser_now,
      merge_precedence: 80,
      metadata: %{"reset_state" => "floating"},
      raw_limit_id: "pressure-#{pressure_percent}-header"
    })
  end

  defp assert_convergence! do
    maybe_inject_assert_failure!()

    forward = identity!(account_id!(:forward))
    equivalent = identity!(account_id!(:equivalent))
    legacy = identity!(account_id!(:legacy))
    anchored = identity!(account_id!(:anchored))
    floating = identity!(account_id!(:floating))
    unknown = identity!(account_id!(:unknown))
    qf = identity!(account_id!(:qf))
    issue_234 = identity!(account_id!(:issue_234))
    pressure_positive = identity!(account_id!(:pressure_positive))
    pressure_exhausted = identity!(account_id!(:pressure_exhausted))

    assert_forward_transition!(forward)
    assert_equivalent_transition!(equivalent)
    assert_legacy_transition!(legacy)

    assert_issue_234_confirmed!(
      issue_234,
      provider_row!(issue_234),
      ~U[2026-07-21 17:08:00.000000Z],
      ~U[2026-07-26 17:00:00.000000Z]
    )

    assert_historical_qf!(qf)

    browser_now = browser_now!(anchored)
    assert_selector_contract!(anchored, browser_now, @roles.anchored, :running)
    assert_selector_contract!(floating, browser_now, @roles.floating, :waiting)
    assert_selector_contract!(unknown, browser_now, @roles.unknown, :absent)
    assert_selector_contract!(qf, browser_now, @roles.qf, :waiting)
    assert_pressure_selection!(pressure_positive, browser_now, :positive)
    assert_selector_contract!(pressure_positive, browser_now, @roles.pressure_positive, :absent)
    assert_pressure_selection!(pressure_exhausted, browser_now, :exhausted)

    assert_selector_contract!(
      pressure_exhausted,
      browser_now,
      @roles.pressure_exhausted,
      :absent
    )
  end

  defp assert_forward_transition!(identity) do
    confirmed_at = ~U[2026-07-21 17:08:00.000000Z]
    runtime_at = ~U[2026-07-21 17:09:00.000000Z]
    confirmed = provider_row!(identity)
    marker = confirmed.metadata[@confirmation_key]

    expect!(confirmed.metadata["reset_state"] == "anchored", "cycle not anchored")
    expect!(is_map(marker), "confirmation marker missing")
    expect!(marker["source_class"] == "provider_usage", "confirmation source mismatch")

    confirmed_selection = Windows.quota_window_selection_data(identity, at: confirmed_at)

    expect!(
      confirmed_selection.secondary.id == confirmed.id,
      "confirmed provider cycle not selected"
    )

    runtime_selection = Windows.quota_window_selection_data(identity, at: runtime_at)

    expect!(
      runtime_selection.secondary.source == "codex_rate_limit_event",
      "runtime precedence missing"
    )
  end

  defp assert_equivalent_transition!(identity) do
    maintained = provider_row!(identity)
    expected_reset = ~U[2026-07-28 17:09:00.000000Z]

    expect!(
      DateTime.compare(maintained.reset_at, expected_reset) == :eq,
      "equivalent reset not retained"
    )

    expect!(
      not Map.has_key?(maintained.metadata, "__quota_confirmed_candidate_v1"),
      "equivalent candidate persisted"
    )
  end

  defp assert_legacy_transition!(identity) do
    effective = Windows.list_quota_windows(identity, @historical_as_of)
    expect!(length(effective) == 1, "legacy effective row count mismatch")
    [current] = effective
    expect!(current.window_kind == "secondary", "legacy primary survived")

    readiness = UpstreamQuotaReadiness.from_windows(effective, @historical_as_of)
    routing = Windows.routing_quota_eligibility(identity, at: @historical_as_of)

    expect!(readiness.state == "weekly_only_probe", "legacy readiness mismatch")
    expect!(routing.eligible?, "legacy routing not ready")
  end

  defp assert_issue_234_pending!(identity, pending, candidate_at, fixed_anchor) do
    expect!(
      Decimal.equal?(pending.used_percent, Decimal.new("100")),
      "issue 234 pressure changed"
    )

    expect!(pending.active_limit == 243, "issue 234 stale active limit changed")
    expect!(pending.credits == 0, "issue 234 stale credits changed")

    {:ok, candidate} = EvidenceStore.parse_candidate(pending.metadata)

    expect!(
      Decimal.equal?(candidate.used_percent, Decimal.new("0")),
      "issue 234 candidate percent mismatch"
    )

    expect!(
      DateTime.compare(candidate.reset_at, fixed_anchor) == :eq,
      "issue 234 candidate anchor mismatch"
    )

    expect!(
      DateTime.compare(candidate.observed_at, candidate_at) == :eq,
      "issue 234 candidate time mismatch"
    )

    expect!(
      match?(
        {:ok, %{allowed: true, limit_reached: false, observed_at: ^candidate_at}},
        EvidenceStore.parse_candidate_provider_status(pending.metadata)
      ),
      "issue 234 candidate status missing"
    )

    routing = Windows.routing_quota_eligibility(identity, at: candidate_at)
    compatibility = codex_rate_limit(identity, candidate_at)

    expect!(
      not routing.eligible? and routing.routing_state == :blocked,
      "issue 234 quarantine routed"
    )

    expect!(routing.selection.secondary.id == pending.id, "issue 234 quarantine row not selected")
    expect!(compatibility.allowed == false, "issue 234 quarantine compatibility allowed")
    expect!(compatibility.limit_reached == true, "issue 234 quarantine limit not reached")

    expect!(
      compatibility.secondary_window.used_percent == 100,
      "issue 234 quarantine percent changed"
    )
  end

  defp assert_issue_234_confirmed!(identity, confirmed, confirmed_at, fixed_anchor) do
    marker = confirmed.metadata[@confirmation_key]

    expect!(Decimal.equal?(confirmed.used_percent, Decimal.new("0")), "issue 234 did not reset")
    expect!(is_nil(confirmed.active_limit), "issue 234 retained stale active limit")
    expect!(is_nil(confirmed.credits), "issue 234 retained stale credits")
    expect!(DateTime.compare(confirmed.reset_at, fixed_anchor) == :eq, "issue 234 anchor changed")

    expect!(
      DateTime.compare(confirmed.observed_at, confirmed_at) == :eq,
      "issue 234 observation stale"
    )

    expect!(
      confirmed.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(confirmed_at),
      "issue 234 watermark did not advance"
    )

    expect!(confirmed.metadata["reset_state"] == "anchored", "issue 234 row not anchored")
    expect!(is_map(marker), "issue 234 cycle marker missing")
    expect!(marker["scope"] == "account", "issue 234 marker scope mismatch")
    expect!(marker["family"] == "account", "issue 234 marker family mismatch")
    expect!(marker["key"] == "account", "issue 234 marker key mismatch")
    expect!(marker["kind"] == "secondary", "issue 234 marker kind mismatch")
    expect!(marker["minutes"] == 10_080, "issue 234 marker duration mismatch")
    expect!(is_nil(marker["model"]), "issue 234 marker model mismatch")
    expect!(is_nil(marker["upstream_model"]), "issue 234 marker upstream model mismatch")

    expect!(
      marker["reset_at"] == DateTime.to_iso8601(fixed_anchor),
      "issue 234 marker reset mismatch"
    )

    expect!(
      marker["provider_observed_at"] == DateTime.to_iso8601(confirmed_at),
      "issue 234 marker watermark mismatch"
    )

    expect!(
      marker["confirmed_at"] == DateTime.to_iso8601(confirmed_at),
      "issue 234 confirmation time mismatch"
    )

    expect!(marker["source_class"] == "provider_usage", "issue 234 marker source mismatch")

    expect!(
      not Map.has_key?(confirmed.metadata, "__quota_confirmed_candidate_v1"),
      "issue 234 candidate survived"
    )

    expect!(
      not Map.has_key?(confirmed.metadata, "__quota_candidate_provider_status_v1"),
      "issue 234 candidate status survived"
    )

    routing = Windows.routing_quota_eligibility(identity, at: confirmed_at)
    compatibility = codex_rate_limit(identity, confirmed_at)

    expect!(routing.eligible?, "issue 234 routing remained blocked")
    expect!(routing.routing_state == :weekly_only_probe, "issue 234 routing state mismatch")

    expect!(
      routing.selection.secondary.id == confirmed.id,
      "issue 234 confirmed row not selected"
    )

    expect!(compatibility.allowed == true, "issue 234 compatibility remained blocked")

    expect!(
      compatibility.limit_reached == false,
      "issue 234 compatibility limit remained reached"
    )

    expect!(
      compatibility.secondary_window.used_percent == 0,
      "issue 234 compatibility percent stale"
    )
  end

  defp assert_historical_qf!(identity) do
    historical_rows = Windows.list_quota_windows(identity, @historical_as_of)
    persisted_rows = historical_qf_rows(identity)
    rows_by_id = Map.new(persisted_rows, &{&1.id, &1})
    floating = Map.fetch!(rows_by_id, @qf_historical_ids.floating)
    markerless = Map.fetch!(rows_by_id, @qf_historical_ids.markerless)
    post_snapshot = Map.fetch!(rows_by_id, @qf_historical_ids.post_snapshot)
    selection = Windows.quota_window_selection_data(identity, at: @historical_as_of)

    expect!(length(persisted_rows) == 3, "QF physical row count mismatch")
    expect!(length(historical_rows) == 1, "QF effective row count mismatch")
    [winner] = selection.routing_windows
    expect!(winner.id == @qf_historical_ids.floating, "QF floating winner mismatch")

    [floating_first_winner] =
      WindowSelector.logical_windows([floating, markerless], @historical_as_of)

    [markerless_first_winner] =
      WindowSelector.logical_windows([markerless, floating], @historical_as_of)

    expect!(
      floating_first_winner.id == @qf_historical_ids.floating,
      "QF floating-first winner mismatch"
    )

    expect!(
      markerless_first_winner.id == @qf_historical_ids.floating,
      "QF markerless-first winner mismatch"
    )

    expect!(
      WindowSelector.logical_windows([post_snapshot, floating], @historical_as_of) == [floating],
      "QF post-snapshot row was not excluded"
    )

    emit_receipt!("qf_ordering", %{
      "input_order" => "floating_first",
      "candidate_count" => 2,
      "chosen_role" => "floating",
      "expected_role" => "floating",
      "ordering_passed" => true,
      "post_snapshot_excluded" => true
    })

    emit_receipt!("qf_ordering", %{
      "input_order" => "markerless_first",
      "candidate_count" => 2,
      "chosen_role" => "floating",
      "expected_role" => "floating",
      "ordering_passed" => true,
      "post_snapshot_excluded" => true
    })
  end

  defp assert_pressure_selection!(identity, at, contest) do
    {expected_winner_id, floating_competitor_id, expected_percent} =
      case contest do
        :positive ->
          {@pressure_ids.positive, @pressure_ids.positive_floating, "54"}

        :exhausted ->
          {@pressure_ids.exhausted, @pressure_ids.exhausted_floating, "100"}
      end

    rows =
      Repo.all(
        from window in AccountQuotaWindow,
          where: window.upstream_identity_id == ^identity.id,
          where: window.id in ^[expected_winner_id, floating_competitor_id]
      )

    rows_by_id = Map.new(rows, &{&1.id, &1})
    pressure = Map.fetch!(rows_by_id, expected_winner_id)
    floating = Map.fetch!(rows_by_id, floating_competitor_id)
    winner_semantics = ModelWeeklyResetSemantics.classify(pressure)
    competitor_semantics = ModelWeeklyResetSemantics.classify(floating)

    expect!(length(rows) == 2, "pressure fixture row count mismatch")
    expect!(winner_semantics == :unknown, "pressure winner semantic rank is not lower")
    expect!(competitor_semantics == :floating, "pressure competitor semantics mismatch")
    expect!(pressure.active_limit == floating.active_limit, "pressure active limits differ")
    expect!(pressure.credits == floating.credits, "pressure credits differ")

    expect!(
      Evidence.current_freshness_state(pressure, at) == "fresh" and
        Evidence.current_freshness_state(floating, at) == "fresh",
      "pressure freshness ranks differ"
    )

    expect!(
      Evidence.reset_bearing?(pressure) and Evidence.reset_bearing?(floating),
      "pressure reset-bearing ranks differ"
    )

    expect!(
      pressure.source_precision == floating.source_precision and
        floating.merge_precedence > pressure.merge_precedence and
        DateTime.after?(floating.observed_at, pressure.observed_at) and
        DateTime.after?(floating.last_sync_at, pressure.last_sync_at) and
        DateTime.after?(floating.updated_at, pressure.updated_at) and
        DateTime.after?(floating.reset_at, pressure.reset_at) and
        floating.id > pressure.id,
      "pressure post-semantic ranks do not favor the competitor"
    )

    [pressure_first_winner] = WindowSelector.logical_windows([pressure, floating], at)
    [floating_first_winner] = WindowSelector.logical_windows([floating, pressure], at)

    expect!(pressure_first_winner.id == expected_winner_id, "pressure-first winner mismatch")
    expect!(floating_first_winner.id == expected_winner_id, "floating-first winner mismatch")

    expect!(
      Decimal.equal?(pressure_first_winner.used_percent, Decimal.new(expected_percent)),
      "pressure winner mismatch"
    )

    emit_receipt!("pressure_ordering", %{
      "contest" => Atom.to_string(contest),
      "candidate_count" => 2,
      "expected_winner_role" => "pressure",
      "competitor_role" => "floating",
      "both_input_orders_passed" => true,
      "winner_semantics" => Atom.to_string(winner_semantics),
      "competitor_semantics" => Atom.to_string(competitor_semantics),
      "measurement_rank_tied" => true,
      "winner_measurement" => expected_percent,
      "competitor_measurement" => "0"
    })
  end

  defp assert_selector_contract!(identity, at, role, expected) do
    limit = spark_limit!(identity, at)

    case expected do
      :running ->
        expect!(limit.reset_semantics == :anchored, "anchored semantics mismatch")
        expect!(is_binary(limit.reset_label), "anchored reset label missing")
        expect!(is_binary(limit.reset_title), "anchored reset title missing")
        expect!(match?(%DateTime{}, limit.reset_at), "anchored reset timestamp missing")

        emit_receipt!("selector", %{
          "role" => role,
          "card_contract_checked" => true,
          "reset_contract_checked" => true,
          "reset_present" => true,
          "countdown_state" => "running",
          "countdown_hook" => "RelativeCountdown",
          "countdown_at" => DateTime.to_iso8601(limit.reset_at)
        })

      :waiting ->
        expect!(limit.reset_semantics == :floating, "floating semantics mismatch")
        expect!(limit.reset_label == "starts on use", "floating reset label mismatch")
        expect!(is_binary(limit.reset_title), "floating reset title missing")

        emit_receipt!("selector", %{
          "role" => role,
          "card_contract_checked" => true,
          "reset_contract_checked" => true,
          "reset_present" => true,
          "countdown_state" => "waiting",
          "countdown_hook" => nil,
          "countdown_at" => nil
        })

      :absent ->
        expect!(limit.reset_semantics == :unknown, "unknown semantics mismatch")
        expect!(is_nil(limit.reset_label), "unknown reset label present")
        expect!(is_nil(limit.reset_title), "unknown reset title present")
        expect!(is_nil(limit.reset_at), "unknown reset timestamp present")

        emit_receipt!("selector", %{
          "role" => role,
          "card_contract_checked" => true,
          "reset_contract_checked" => true,
          "reset_present" => false,
          "countdown_state" => "unknown",
          "countdown_hook" => nil,
          "countdown_at" => nil
        })
    end
  end

  defp cleanup do
    pool_ids = namespace_pool_ids()
    identity_ids = namespace_identity_ids()
    before = fixture_counts()

    deleted_assignments =
      delete_count(
        from assignment in PoolUpstreamAssignment,
          where:
            assignment.pool_id in ^pool_ids or assignment.upstream_identity_id in ^identity_ids
      )

    deleted_windows =
      delete_count(
        from window in AccountQuotaWindow,
          where: window.upstream_identity_id in ^identity_ids
      )

    deleted_identities =
      delete_count(
        from identity in UpstreamIdentity,
          where: identity.id in ^identity_ids,
          where: identity.chatgpt_account_id in ^@account_ids
      )

    deleted_pools =
      delete_count(from pool in Pool, where: pool.id in ^pool_ids, where: pool.slug == @pool_slug)

    deleted = %{
      "pool_assignments" => deleted_assignments,
      "quota_windows" => deleted_windows,
      "identities" => deleted_identities,
      "pools" => deleted_pools
    }

    remaining = fixture_counts()
    cleanup_mode = cleanup_mode(before)
    expect!(cleanup_counts_compatible?(before, deleted, cleanup_mode), "cleanup count mismatch")
    expect!(Enum.all?(remaining, fn {_key, count} -> count == 0 end), "cleanup left fixtures")

    emit_receipt!("cleanup", %{
      "before" => before,
      "deleted" => deleted,
      "remaining" => remaining,
      "cleanup_mode" => cleanup_mode
    })

    :ok
  end

  defp create_identity!(pool, account_id) do
    {:ok, identity} =
      IdentityLifecycle.create_upstream_identity(%{
        chatgpt_account_id: account_id,
        account_label: "Synthetic quota fixture",
        onboarding_method: "import",
        metadata: %{}
      })

    {:ok, identity} = IdentityLifecycle.activate_upstream_identity(identity)
    {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity)
    {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)
    identity
  end

  defp record_provider!(identity, observed_at, percent, reset_at, provider_at) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_usage_api", observed_at, percent, reset_at)
        |> put_in(
          [:metadata, "reset_after_seconds"],
          DateTime.diff(reset_at, provider_at, :second)
        ),
        observed_at,
        observed_at
      )

    row
  end

  defp record_runtime!(identity, observed_at, percent, reset_at) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_rate_limit_event", observed_at, percent, reset_at),
        observed_at,
        observed_at
      )

    row
  end

  defp record_safe_fixed_zero!(identity, observed_at, fixed_anchor) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_usage_api", observed_at, "0", fixed_anchor)
        |> Map.put(:metadata, %{
          "rate_limit_allowed" => true,
          "rate_limit_reached" => false,
          "reset_after_seconds" => DateTime.diff(fixed_anchor, observed_at, :second)
        }),
        observed_at,
        observed_at
      )

    row
  end

  defp record_spark!(identity, observed_at, reset_at, metadata) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        %{
          quota_key: "codex_spark",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("0"),
          reset_at: reset_at,
          observed_at: observed_at,
          last_sync_at: observed_at,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          freshness_state: "fresh",
          metadata: Map.put(metadata, "reset_after_seconds", 604_800)
        },
        observed_at,
        observed_at
      )

    row
  end

  defp insert_window!(identity, kind, source, observed_at, reset_at, percent) do
    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(
      weekly_attrs(source, observed_at, percent, reset_at)
      |> Map.put(:upstream_identity_id, identity.id)
      |> Map.put(:window_kind, kind)
      |> Map.put(:created_at, observed_at)
      |> Map.put(:updated_at, observed_at)
    )
    |> Repo.insert!()
  end

  defp insert_spark_window!(identity, attrs) do
    window =
      %AccountQuotaWindow{id: Map.fetch!(attrs, :id)}
      |> AccountQuotaWindow.changeset(
        attrs
        |> Map.delete(:id)
        |> Map.merge(%{
          upstream_identity_id: identity.id,
          quota_key: "codex_spark",
          window_kind: "secondary",
          window_minutes: 10_080,
          active_limit: Map.get(attrs, :active_limit),
          credits: Map.get(attrs, :credits),
          display_label: "GPT-5.3-Codex-Spark",
          limit_name: "gpt-5.3-codex-spark",
          metered_feature: "codex_spark",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          upstream_model: nil,
          raw_limit_name: "gpt-5.3-codex-spark",
          raw_metered_feature: "codex_spark",
          freshness_state: "fresh"
        })
        |> Map.update!(:used_percent, &Decimal.new/1)
        |> Map.put_new_lazy(:created_at, fn -> Map.fetch!(attrs, :observed_at) end)
        |> Map.put_new_lazy(:updated_at, fn -> Map.fetch!(attrs, :observed_at) end)
      )

    expect!(window.valid?, "invalid Spark fixture")
    Repo.insert!(window)
  end

  defp weekly_attrs(source, observed_at, percent, reset_at) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: source,
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: %{}
    }
  end

  defp spark_limit!(identity, at) do
    windows = Windows.list_quota_windows(identity, at)

    QuotaProjection.quota_limit_rows(windows, DateTimeDisplay.preferences_for_user(nil), at)
    |> Enum.find(&(&1.key == @spark_limit_key))
    |> case do
      nil -> raise("Spark limit missing")
      limit -> limit
    end
  end

  defp codex_rate_limit(identity, at) do
    identity
    |> Windows.list_quota_windows(at)
    |> UsageResponses.account_usage_windows(at)
    |> then(fn {primary, secondary} -> UsageResponses.codex_rate_limit(primary, secondary) end)
  end

  defp browser_now!(identity) do
    Repo.one!(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id,
        where: window.quota_key == "codex_spark",
        where: window.source == "codex_usage_api",
        select: window.observed_at
    )
  end

  defp historical_qf_rows(identity) do
    Repo.all(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id,
        where: window.id in ^Map.values(@qf_historical_ids)
    )
  end

  defp fixture_counts do
    pool_ids = namespace_pool_ids()
    identity_ids = namespace_identity_ids()

    %{
      "pools" =>
        count(from pool in Pool, where: pool.id in ^pool_ids, where: pool.slug == @pool_slug),
      "identities" =>
        count(
          from identity in UpstreamIdentity,
            where: identity.id in ^identity_ids,
            where: identity.chatgpt_account_id in ^@account_ids
        ),
      "pool_assignments" =>
        count(
          from assignment in PoolUpstreamAssignment,
            where:
              assignment.pool_id in ^pool_ids or assignment.upstream_identity_id in ^identity_ids
        ),
      "quota_windows" =>
        count(
          from window in AccountQuotaWindow,
            where: window.upstream_identity_id in ^identity_ids
        )
    }
  end

  defp namespace_pool_ids do
    Repo.all(from pool in Pool, where: pool.slug == @pool_slug, select: pool.id)
  end

  defp namespace_identity_ids do
    Repo.all(
      from identity in UpstreamIdentity,
        where: identity.chatgpt_account_id in ^@account_ids,
        select: identity.id
    )
  end

  defp count(query), do: Repo.aggregate(query, :count)
  defp delete_count(query), do: query |> Repo.delete_all() |> elem(0)

  defp expected_fixture_counts! do
    expect!(fixture_counts() == @expected_fixture_counts, "seeded fixture counts mismatch")
  end

  defp cleanup_mode(counts) when counts == @expected_fixture_counts, do: "seeded"

  defp cleanup_mode(counts) do
    if Enum.all?(counts, fn {_key, count} -> count == 0 end), do: "empty", else: "partial"
  end

  defp cleanup_counts_compatible?(_before, deleted, "seeded"),
    do: deleted == @expected_fixture_counts

  defp cleanup_counts_compatible?(before, deleted, "empty") do
    before == deleted and Enum.all?(deleted, fn {_key, count} -> count == 0 end)
  end

  defp cleanup_counts_compatible?(before, deleted, "partial") do
    Enum.all?(deleted, fn {key, count} -> count >= 0 and count <= Map.fetch!(before, key) end)
  end

  defp retained_fixture_counts!(phase, failure_class)
       when phase in ["seed_retained", "assert_retained"] and is_binary(failure_class) do
    emit_receipt!(phase, %{
      "failure_class" => failure_class,
      "fixture_counts" => fixture_counts()
    })
  end

  defp failure_class(%RuntimeError{message: "test-only assert failure injection"}),
    do: "injected_assertion"

  defp failure_class(%RuntimeError{message: message}) do
    cond do
      String.starts_with?(message, "issue 234") -> "issue_234_same_anchor"
      String.starts_with?(message, "QF") -> "qf_ordering"
      String.starts_with?(message, "pressure") -> "pressure_ordering"
      String.contains?(message, "semantics mismatch") -> "selector_contract"
      String.contains?(message, "reset label") -> "selector_contract"
      String.contains?(message, "reset title") -> "selector_contract"
      String.contains?(message, "reset timestamp") -> "selector_contract"
      String.starts_with?(message, "receipt ") -> "receipt_contract"
      true -> "convergence_assertion"
    end
  end

  defp failure_class(_error), do: "helper_internal"

  defp maybe_inject_assert_failure! do
    if Mix.env() == :test and System.get_env(@assert_failure_injection_env) == "1" do
      raise("test-only assert failure injection")
    end
  end

  defp account_id!(role) do
    case role do
      :forward -> "provider-reset-proof-forward"
      :equivalent -> "provider-reset-proof-equivalent"
      :legacy -> "provider-reset-proof-legacy"
      :anchored -> "provider-reset-proof-spark-anchored"
      :floating -> "provider-reset-proof-spark-floating"
      :unknown -> "provider-reset-proof-spark-unknown"
      :qf -> "provider-reset-proof-spark-qf"
      :issue_234 -> "provider-reset-proof-issue-234-same-anchor"
      :pressure_positive -> "provider-reset-proof-spark-pressure-positive"
      :pressure_exhausted -> "provider-reset-proof-spark-pressure-exhausted"
    end
  end

  defp identity!(account_id), do: Repo.get_by!(UpstreamIdentity, chatgpt_account_id: account_id)

  defp provider_row!(identity) do
    Repo.one!(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id,
        where: window.source == "codex_usage_api",
        where: window.quota_key == "account",
        where: window.window_kind == "secondary"
    )
  end

  defp emit_receipt!(phase, fields) do
    payload =
      Map.merge(
        %{
          "schema_version" => @receipt_schema_version,
          "phase" => phase
        },
        fields
      )

    ensure_identifier_free_receipt!(payload)
    IO.puts("quota-helper\t" <> Jason.encode!(payload))
  end

  defp ensure_identifier_free_receipt!(value) when is_map(value) do
    Enum.each(value, fn {key, nested_value} ->
      expect!(
        not MapSet.member?(@forbidden_receipt_identifier_fields, key),
        "receipt identifier field forbidden"
      )

      ensure_identifier_free_receipt!(nested_value)
    end)
  end

  defp ensure_identifier_free_receipt!(values) when is_list(values),
    do: Enum.each(values, &ensure_identifier_free_receipt!/1)

  defp ensure_identifier_free_receipt!(value) when is_binary(value) do
    expect!(not Regex.match?(@uuid_pattern, value), "receipt UUID forbidden")
  end

  defp ensure_identifier_free_receipt!(_value), do: :ok

  defp expect!(true, _message), do: :ok
  defp expect!(false, message), do: raise(message)
end

Logger.configure(level: :warning)
{:ok, _started} = Application.ensure_all_started(:codex_pooler)
CodexPooler.Verification.ProviderResetInconsistency.run(System.argv())
