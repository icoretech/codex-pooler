defmodule CodexPooler.Gateway.Routing.QuotaWindowRoutingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  import CodexPooler.PoolerFixtures

  @observed_at ~U[2026-05-22 12:00:00Z]
  @spark_weekly_seconds 604_800

  describe "lifecycle routing eligibility" do
    test "definitive provider rejection excludes retained high-percent quota immediately" do
      upstream = start_upstream(unavailable_usage_paths(401))
      %{pool: pool, identity: identity, assignment: assignment} = routing_fixture(upstream)
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 persisted_account_window("primary", 300, observed_at,
                   used_percent: Decimal.new("1")
                 )
               ])

      model = routing_model(pool, assignment)
      assert {:ok, [_candidate]} = CandidateEligibility.routable_candidates(model)

      assert {:error, :definitive_provider_auth_rejected} =
               PoolReconciliation.refresh_quota_from_usage(identity, assignment)

      assert [_retained_window] = QuotaWindows.list_quota_windows(identity)

      assert {:error, %{code: "no_eligible_backend"}} =
               CandidateEligibility.routable_candidates(model)
    end

    test "non-definitive idle failures retain weekly-only probe eligibility" do
      upstream = start_upstream(unavailable_usage_paths(404))
      %{pool: pool, identity: identity, assignment: assignment} = routing_fixture(upstream)
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, [_weekly]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 persisted_account_window("secondary", 10_080, observed_at)
               ])

      assert {:error, :not_found} =
               PoolReconciliation.refresh_quota_from_usage(identity, assignment)

      model = routing_model(pool, assignment)

      assert {:ok, [{current_assignment, current_identity}]} =
               CandidateEligibility.routable_candidates(model)

      assert current_assignment.id == assignment.id
      assert current_identity.id == identity.id

      assert %{eligible?: true, routing_state: :weekly_only_probe} =
               QuotaWindows.routing_quota_eligibility(current_identity,
                 at: observed_at,
                 model: model.exposed_model_id,
                 requested_model: model.exposed_model_id,
                 upstream_model: model.upstream_model_id
               )
    end
  end

  describe "parser-to-Postgres model routing" do
    test "one qualifying-looking zero preserves exhausted Spark routing pressure" do
      %{identity: identity, model: model} = parser_routing_fixture()
      observed_at = ~U[2026-07-25 12:00:00Z]
      reset_at = DateTime.add(observed_at, @spark_weekly_seconds, :second)

      exhausted =
        identity
        |> record_usage_payload!(spark_usage_payload(100, observed_at, reset_at), observed_at)
        |> spark_weekly_row!()
        |> reload_window!()

      assert Decimal.equal?(exhausted.used_percent, Decimal.new("100"))
      assert DateTime.compare(exhausted.reset_at, reset_at) == :eq
      assert exhausted.metadata["reset_state"] == "anchored"

      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [%{reason_codes: ["exhausted"]}],
               selection: %{blocked_windows: [%AccountQuotaWindow{id: exhausted_id}]}
             } = routing_eligibility(identity, model, observed_at)

      assert exhausted_id == exhausted.id

      zero_at = DateTime.add(observed_at, 104, :second)

      returned_zero =
        identity
        |> record_usage_payload!(
          spark_usage_payload(
            0,
            zero_at,
            reset_at,
            @spark_weekly_seconds - 104
          ),
          zero_at
        )
        |> spark_weekly_row!()

      persisted = reload_window!(returned_zero)

      assert persisted.id == exhausted.id
      assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))
      assert DateTime.compare(persisted.reset_at, exhausted.reset_at) == :eq
      assert DateTime.compare(persisted.observed_at, exhausted.observed_at) == :eq
      assert persisted.metadata["reset_state"] == "anchored"

      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [%{reason_codes: ["exhausted"]}],
               selection: %{blocked_windows: [%AccountQuotaWindow{id: persisted_id}]}
             } = routing_eligibility(identity, model, zero_at)

      assert persisted_id == persisted.id
    end

    test "a bounded immediate Spark anchor is selected for its model and restores eligibility" do
      %{identity: identity, model: model} = parser_routing_fixture()
      started_at = ~U[2026-07-25 13:00:00Z]

      floating =
        Enum.reduce([0, 60, 300], nil, fn offset, _previous ->
          observed_at = DateTime.add(started_at, offset, :second)
          reset_at = DateTime.add(observed_at, @spark_weekly_seconds, :second)

          identity
          |> record_usage_payload!(spark_usage_payload(0, observed_at, reset_at), observed_at)
          |> spark_weekly_row!()
        end)
        |> reload_window!()

      assert floating.metadata["reset_state"] == "floating"

      anchored_at = DateTime.add(floating.observed_at, 104, :second)

      returned_anchor =
        identity
        |> record_usage_payload!(
          spark_usage_payload(
            0,
            anchored_at,
            floating.reset_at,
            @spark_weekly_seconds - 104
          ),
          anchored_at
        )
        |> spark_weekly_row!()

      persisted = reload_window!(returned_anchor)

      assert persisted.id == floating.id
      assert Decimal.equal?(persisted.used_percent, Decimal.new("0"))
      assert persisted.freshness_state == "fresh"
      assert persisted.metadata["reset_state"] == "anchored"
      assert DateTime.compare(persisted.reset_at, floating.reset_at) == :eq
      assert DateTime.compare(persisted.observed_at, anchored_at) == :eq

      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{routing_windows: routing_windows, blocked_windows: []}
             } = routing_eligibility(identity, model, anchored_at)

      assert Enum.any?(routing_windows, &(&1.id == persisted.id))

      assert %{
               eligible?: true,
               exclusions: [],
               selection: %{routing_windows: wrong_model_windows}
             } =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: anchored_at,
                 model: "sample-codex-other",
                 requested_model: "sample-codex-other",
                 upstream_model: "sample-codex-other-upstream"
               )

      refute Enum.any?(wrong_model_windows, &(&1.id == persisted.id))
    end
  end

  describe "routing_quota_eligibility_from_windows/2" do
    test "ordinary models stay eligible when Spark quota evidence is absent" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{primary: %AccountQuotaWindow{}, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows([account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "ordinary models ignore unusable Spark quota evidence that is out of model scope" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), exhausted_spark_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "Spark model routing blocks when in-scope Spark quota evidence is unusable" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "sample-codex-spark",
                   reason_codes: ["exhausted"]
                 }
               ],
               selection: %{blocked_windows: [%AccountQuotaWindow{quota_key: "codex_spark"}]}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), exhausted_spark_window()],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "Spark model routing does not fail closed solely because no Spark-specific window exists" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{primary: %AccountQuotaWindow{}, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows([account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "two preserved fresh in-scope meters remain eligible under all-windows policy" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{routing_windows: routing_windows, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(),
                   metered_model_window("feature-alpha", used_percent: Decimal.new("20")),
                   metered_model_window("feature-beta", used_percent: Decimal.new("80"))
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )

      assert Enum.map(routing_windows, &Evidence.additional_meter_token/1) == [
               nil,
               "feature-alpha",
               "feature-beta"
             ]
    end

    test "one preserved exhausted in-scope meter blocks otherwise usable windows" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   quota_key: "shared_feature_limit",
                   quota_scope: "model",
                   model: "sample-codex-spark",
                   reason_codes: ["exhausted"]
                 }
               ],
               selection: %{
                 routing_windows: routing_windows,
                 blocked_windows: [blocked_window]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(),
                   metered_model_window("feature-alpha", used_percent: Decimal.new("20")),
                   metered_model_window("feature-beta", used_percent: Decimal.new("100"))
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )

      assert length(routing_windows) == 3
      assert Evidence.additional_meter_token(blocked_window) == "feature-beta"
    end

    test "out-of-scope and stale meter evidence does not affect current ranking" do
      stale_observed_at =
        DateTime.add(@observed_at, -Evidence.freshness_ttl_seconds() - 1, :second)

      fresh_meter = metered_model_window("feature-alpha", used_percent: Decimal.new("20"))

      stale_meter =
        metered_model_window("feature-alpha",
          source: "codex_response_headers",
          used_percent: Decimal.new("100"),
          freshness_state: "stale",
          observed_at: stale_observed_at
        )

      out_of_scope_meter =
        metered_model_window("feature-beta",
          model: "sample-codex-other",
          upstream_model: "sample-codex-other-upstream",
          used_percent: Decimal.new("100")
        )

      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{routing_windows: routing_windows, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), stale_meter, fresh_meter, out_of_scope_meter],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )

      assert [selected_meter] =
               Enum.filter(routing_windows, &(Evidence.additional_meter_token(&1) != nil))

      assert selected_meter == fresh_meter
    end

    test "missing meter evidence does not block but account baseline remains required" do
      present_meter = metered_model_window("feature-alpha")

      assert %{eligible?: true, routing_state: :precise, exclusions: []} =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), present_meter],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )

      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_account_primary_missing",
                   message: "account primary quota evidence is required for routing"
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows([present_meter],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "account primary routing blocks resetless quota evidence" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   reason_codes: ["reset_missing"]
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(reset_at: nil, source_precision: "inferred")],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "account primary routing blocks exhausted quota evidence" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   reason_codes: ["exhausted"]
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(used_percent: Decimal.new("100"))],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "monthly account primary evidence routes as precise quota when fresh reset-bearing and not exhausted" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 43_200},
                 secondary: nil,
                 blocked_windows: []
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [monthly_account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "fresh monthly account primary evidence supersedes stale legacy 5h primary evidence" do
      stale_5h_observed_at =
        DateTime.add(
          @observed_at,
          -Evidence.freshness_ttl_seconds() - 1,
          :second
        )

      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 43_200},
                 blocked_windows: [],
                 routing_windows: [
                   %AccountQuotaWindow{window_kind: "primary", window_minutes: 43_200}
                 ]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(observed_at: stale_5h_observed_at),
                   monthly_account_primary_window()
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "monthly account primary exhaustion is rejected as exhausted instead of missing primary" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   reason_codes: ["exhausted"]
                 }
               ],
               selection: %{
                 primary: %AccountQuotaWindow{window_minutes: 43_200},
                 blocked_windows: [%AccountQuotaWindow{window_minutes: 43_200}]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [monthly_account_primary_window(used_percent: Decimal.new("100"))],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "monthly account primary routing blocks stale resetless and expired quota evidence" do
      stale_observed_at =
        DateTime.add(
          @observed_at,
          -Evidence.freshness_ttl_seconds() - 1,
          :second
        )

      scenarios = [
        {monthly_account_primary_window(reset_at: nil), ["reset_missing"]},
        {monthly_account_primary_window(observed_at: stale_observed_at), ["not_fresh"]},
        {monthly_account_primary_window(freshness_state: "stale"), ["not_fresh"]},
        {monthly_account_primary_window(reset_at: DateTime.add(@observed_at, -60, :second)),
         ["expired", "not_fresh"]}
      ]

      for {window, reason_codes} <- scenarios do
        assert %{
                 eligible?: false,
                 routing_state: :blocked,
                 exclusions: [
                   %{
                     code: "quota_window_unusable",
                     quota_key: "account",
                     window_kind: "primary",
                     reason_codes: ^reason_codes
                   }
                 ],
                 selection: %{primary: %AccountQuotaWindow{window_minutes: 43_200}}
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   [window],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 )
      end
    end

    test "account primary routing blocks stale and unknown freshness quota evidence" do
      for freshness_state <- ["stale", "unknown"] do
        assert %{
                 eligible?: false,
                 routing_state: :blocked,
                 exclusions: [
                   %{
                     code: "quota_window_unusable",
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     freshness_state: ^freshness_state,
                     reason_codes: ["not_fresh"]
                   }
                 ]
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   [account_primary_window(freshness_state: freshness_state)],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 )
      end
    end

    test "model-scoped routing evidence for the wrong model stays out of scope" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_evidence_out_of_scope",
                   message: "recorded quota evidence does not match the requested model scope"
                 }
               ],
               selection: %{routing_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   model_window(
                     model: "sample-codex-other",
                     upstream_model: "sample-codex-other-upstream"
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "account secondary weekly exhaustion with positive credits routes as credit-backed probe" do
      assert %{
               eligible?: true,
               routing_state: :credit_backed_probe,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{},
                 secondary: %AccountQuotaWindow{credits: 42},
                 blocked_windows: [
                   %AccountQuotaWindow{window_kind: "secondary", used_percent: used_percent}
                 ]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(),
                   account_secondary_window(used_percent: Decimal.new("100"), credits: 42)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )

      assert Decimal.equal?(used_percent, Decimal.new("100"))
    end

    test "credit-backed probe requires fresh reset-bearing unexpired positive-credit exhaustion" do
      stale_observed_at =
        DateTime.add(
          @observed_at,
          -Evidence.freshness_ttl_seconds() - 1,
          :second
        )

      scenarios = [
        account_secondary_window(used_percent: Decimal.new("100"), credits: nil),
        account_secondary_window(used_percent: Decimal.new("100"), credits: 0),
        account_secondary_window(used_percent: Decimal.new("100"), credits: 42, reset_at: nil),
        account_secondary_window(
          used_percent: Decimal.new("100"),
          credits: 42,
          reset_at: DateTime.add(@observed_at, -60, :second)
        ),
        account_secondary_window(
          used_percent: Decimal.new("100"),
          credits: 42,
          observed_at: stale_observed_at
        ),
        account_secondary_window(
          used_percent: Decimal.new("100"),
          credits: 42,
          freshness_state: "stale"
        )
      ]

      for window <- scenarios do
        assert %{eligible?: false, routing_state: :blocked} =
                 Windows.routing_quota_eligibility_from_windows(
                   [account_primary_window(), window],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 )
      end
    end

    test "frozen 5h primary superseded by later-synced weekly evidence recovers as weekly-only probe" do
      frozen_observed_at = DateTime.add(@observed_at, -3_600, :second)

      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: [],
               warnings: [%{code: "quota_account_primary_unknown"}],
               selection: %{
                 primary: nil,
                 secondary: %AccountQuotaWindow{window_kind: "secondary"},
                 routing_windows: [%AccountQuotaWindow{window_kind: "secondary"}]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(
                     observed_at: frozen_observed_at,
                     reset_at: DateTime.add(@observed_at, -900, :second)
                   ),
                   account_secondary_window(observed_at: @observed_at)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "stale 5h primary without a full freshness-TTL sync gap keeps routing blocked" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "account",
                   window_kind: "primary",
                   reason_codes: ["not_fresh"]
                 }
               ]
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(
                     observed_at: DateTime.add(@observed_at, -1_200, :second)
                   ),
                   account_secondary_window(
                     observed_at: DateTime.add(@observed_at, -400, :second)
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "superseded 5h primary does not fabricate eligibility when weekly evidence is stale and imprecise" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_account_primary_missing",
                   message: "account primary quota evidence is required for routing"
                 }
               ],
               selection: %{primary: nil}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(
                     observed_at: DateTime.add(@observed_at, -4_000, :second)
                   ),
                   account_secondary_window(
                     observed_at: DateTime.add(@observed_at, -3_000, :second),
                     source_precision: "inferred"
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "legacy frozen weekly-duration primary rows are superseded by fresh weekly evidence" do
      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: [],
               selection: %{
                 primary: nil,
                 secondary: %AccountQuotaWindow{window_kind: "secondary"},
                 routing_windows: [%AccountQuotaWindow{window_kind: "secondary"}]
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_secondary_window(
                     window_kind: "primary",
                     source: "codex_response_headers",
                     observed_at: DateTime.add(@observed_at, -3_600, :second)
                   ),
                   account_secondary_window(observed_at: @observed_at)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "exhausted Spark weekly evidence blocks the weekly-only probe for Spark models" do
      assert %{
               eligible?: false,
               routing_state: :blocked
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_secondary_window(observed_at: @observed_at),
                   model_window(
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("100"),
                     reset_at: DateTime.add(@observed_at, 6, :day)
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "usable Spark weekly evidence keeps the weekly-only probe eligible for Spark models" do
      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: []
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_secondary_window(observed_at: @observed_at),
                   model_window(
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("12"),
                     reset_at: DateTime.add(@observed_at, 6, :day)
                   )
                 ],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "evidence observed after as_of cannot supersede the primary selected at that instant" do
      # adversarial: strictly non-future — evidence one second past as_of is
      # already excluded, so both the sub-skew band (1..300s) and a two-hour
      # gap behave identically
      for future_offset_seconds <- [1, 60, 299, 2 * 3600] do
        assert %{
                 eligible?: true,
                 routing_state: :precise,
                 selection: %{
                   primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 300},
                   secondary: nil
                 }
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   [
                     account_primary_window(),
                     account_secondary_window(
                       observed_at: DateTime.add(@observed_at, future_offset_seconds, :second)
                     )
                   ],
                   at: @observed_at,
                   model: "sample-codex-standard",
                   requested_model: "sample-codex-standard",
                   upstream_model: "sample-codex-standard-upstream"
                 ),
               "future offset #{future_offset_seconds}s"
      end
    end

    test "fresh 5h primary beside fresh weekly evidence stays precise" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{
                 primary: %AccountQuotaWindow{window_kind: "primary", window_minutes: 300},
                 blocked_windows: []
               }
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [
                   account_primary_window(),
                   account_secondary_window(observed_at: @observed_at)
                 ],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    @tag :quota_reversible_provider_shape
    test "provider 5h to weekly-only to 5h shape is reversible and excludes superseded evidence" do
      frozen_at = DateTime.add(@observed_at, -3_600, :second)
      future_at = DateTime.add(@observed_at, 1, :second)

      initial = [
        account_primary_window(),
        account_secondary_window(observed_at: @observed_at),
        model_window([]),
        model_window(
          window_kind: "secondary",
          window_minutes: 10_080,
          reset_at: DateTime.add(@observed_at, 6, :day)
        )
      ]

      assert %{eligible?: true, routing_state: :precise, selection: initial_selection} =
               routing_shape(initial)

      assert window_shape(initial_selection.routing_windows) == [
               {"account", "primary", 300},
               {"account", "secondary", 10_080},
               {"codex_spark", "primary", 300},
               {"codex_spark", "secondary", 10_080}
             ]

      weekly_only = [
        account_primary_window(observed_at: frozen_at),
        account_secondary_window(observed_at: @observed_at),
        model_window(observed_at: frozen_at),
        model_window(
          window_kind: "secondary",
          window_minutes: 10_080,
          reset_at: DateTime.add(@observed_at, 6, :day)
        ),
        account_primary_window(observed_at: future_at),
        model_window(observed_at: future_at)
      ]

      assert %{eligible?: true, routing_state: :weekly_only_probe, selection: weekly_selection} =
               routing_shape(weekly_only)

      assert window_shape(weekly_selection.routing_windows) == [
               {"account", "secondary", 10_080},
               {"codex_spark", "secondary", 10_080}
             ]

      restored = [
        account_primary_window(),
        account_secondary_window(observed_at: @observed_at),
        model_window([]),
        model_window(
          window_kind: "secondary",
          window_minutes: 10_080,
          reset_at: DateTime.add(@observed_at, 6, :day)
        )
      ]

      assert %{eligible?: true, routing_state: :precise, selection: restored_selection} =
               routing_shape(restored)

      assert window_shape(restored_selection.routing_windows) ==
               window_shape(initial_selection.routing_windows)
    end

    test "positive credits do not revive primary model upstream-model or additional exhaustion" do
      scenarios = [
        [account_primary_window(used_percent: Decimal.new("100"), credits: 42)],
        [
          account_primary_window(),
          model_window(used_percent: Decimal.new("100"), credits: 42)
        ],
        [
          account_primary_window(),
          upstream_model_window(used_percent: Decimal.new("100"), credits: 42)
        ],
        [
          account_primary_window(),
          additional_limit_window(used_percent: Decimal.new("100"), credits: 42)
        ]
      ]

      for windows <- scenarios do
        assert %{
                 eligible?: false,
                 routing_state: :blocked,
                 exclusions: [%{reason_codes: reason_codes} | _]
               } =
                 Windows.routing_quota_eligibility_from_windows(
                   windows,
                   at: @observed_at,
                   model: "sample-codex-spark",
                   requested_model: "sample-codex-spark",
                   upstream_model: "sample-codex-spark-upstream"
                 )

        assert "exhausted" in reason_codes
      end
    end
  end

  defp account_primary_window(attrs \\ []) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: DateTime.add(@observed_at, 900, :second),
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh",
          observed_at: @observed_at
        ],
        attrs
      )
    )
  end

  defp monthly_account_primary_window(attrs \\ []) do
    account_primary_window(
      Keyword.merge(
        [
          window_minutes: 43_200,
          used_percent: Decimal.new("42.5"),
          reset_at: DateTime.add(@observed_at, 30, :day),
          source: "codex_usage_api"
        ],
        attrs
      )
    )
  end

  defp exhausted_spark_window do
    model_window(used_percent: Decimal.new("100"))
  end

  defp account_secondary_window(attrs) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("12"),
          reset_at: DateTime.add(@observed_at, 604_800, :second),
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh",
          observed_at: @observed_at
        ],
        attrs
      )
    )
  end

  defp upstream_model_window(attrs) do
    model_window(
      Keyword.merge(
        [
          quota_key: "provider_gpt_5_3_codex_spark",
          quota_scope: "upstream_model",
          upstream_model: "sample-codex-spark-upstream"
        ],
        attrs
      )
    )
  end

  defp additional_limit_window(attrs) do
    model_window(
      Keyword.merge(
        [
          quota_key: "codex_feature_limit",
          quota_scope: "feature",
          quota_family: "codex_feature",
          model: nil,
          upstream_model: nil
        ],
        attrs
      )
    )
  end

  defp model_window(attrs) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "codex_spark",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new("12"),
          reset_at: DateTime.add(@observed_at, 900, :second),
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "sample-codex-spark",
          upstream_model: "sample-codex-spark-upstream",
          freshness_state: "fresh",
          observed_at: @observed_at
        ],
        attrs
      )
    )
  end

  defp metered_model_window(meter_token, attrs \\ []) do
    model_window(
      Keyword.merge(
        [
          quota_key: "shared_feature_limit",
          quota_family: "codex_feature",
          metered_feature: meter_token,
          raw_metered_feature: meter_token,
          raw_limit_id: "shared-feature-limit"
        ],
        attrs
      )
    )
  end

  defp routing_shape(windows) do
    Windows.routing_quota_eligibility_from_windows(windows,
      at: @observed_at,
      model: "sample-codex-spark",
      requested_model: "sample-codex-spark",
      upstream_model: "sample-codex-spark-upstream"
    )
  end

  defp window_shape(windows) do
    windows
    |> Enum.map(&{&1.quota_key, &1.window_kind, &1.window_minutes})
    |> Enum.sort()
  end

  defp parser_routing_fixture do
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-5.3-codex-spark",
        upstream_model_id: "gpt-5.3-codex-spark",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    %{identity: identity, assignment: assignment, model: model}
  end

  defp record_usage_payload!(identity, payload, observed_at) do
    assert {:ok, parsed_windows} =
             Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    Enum.map(parsed_windows, fn parsed_window ->
      assert {:ok, row} =
               EvidenceStore.record_evidence(
                 identity,
                 parsed_window,
                 observed_at,
                 observed_at
               )

      row
    end)
  end

  defp spark_weekly_row!(windows) do
    assert [spark_weekly] =
             Enum.filter(
               windows,
               &(&1.quota_key == "codex_spark" and &1.window_kind == "secondary" and
                   &1.window_minutes == 10_080)
             )

    spark_weekly
  end

  defp reload_window!(%AccountQuotaWindow{id: id}), do: Repo.get!(AccountQuotaWindow, id)

  defp routing_eligibility(identity, model, observed_at) do
    QuotaWindows.routing_quota_eligibility(identity,
      at: observed_at,
      model: model.exposed_model_id,
      requested_model: model.exposed_model_id,
      upstream_model: model.upstream_model_id
    )
  end

  defp spark_usage_payload(used_percent, observed_at, reset_at) do
    spark_usage_payload(used_percent, observed_at, reset_at, @spark_weekly_seconds)
  end

  defp spark_usage_payload(used_percent, observed_at, reset_at, reset_after_seconds) do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900,
          "reset_at" => DateTime.to_iso8601(DateTime.add(observed_at, 900, :second))
        }
      },
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => @spark_weekly_seconds,
              "reset_after_seconds" => reset_after_seconds,
              "reset_at" => DateTime.to_iso8601(reset_at)
            }
          }
        }
      ]
    }
  end

  defp routing_fixture(upstream) do
    pool = pool_fixture()
    base_url = FakeUpstream.url(upstream)

    routed =
      upstream_assignment_fixture(pool, %{
        identity_metadata: %{
          "base_url" => base_url,
          "access_token_expires_at" =>
            DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.to_iso8601()
        },
        assignment_metadata: %{"base_url" => base_url}
      })

    configure_upstream_secret_key!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(routed.identity, %{
               secret_kind: "access_token",
               plaintext: "synthetic-routing-token"
             })

    Map.put(routed, :pool, pool)
  end

  defp routing_model(pool, assignment) do
    model_fixture(pool, %{
      exposed_model_id: "sample-routing-model-#{System.unique_integer([:positive])}",
      upstream_model_id: "sample-routing-upstream-model",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })
  end

  defp persisted_account_window(window_kind, window_minutes, observed_at, attrs \\ []) do
    Map.merge(
      %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: window_kind,
        window_minutes: window_minutes,
        used_percent: Decimal.new("12"),
        reset_at: DateTime.add(observed_at, 3_600, :second),
        source: "codex_usage_api",
        source_precision: "observed",
        freshness_state: "fresh",
        observed_at: observed_at
      },
      Map.new(attrs)
    )
  end

  defp unavailable_usage_paths(status) do
    {:path_json,
     %{
       "/api/codex/usage" => {status, %{"error" => "unavailable"}},
       "/backend-api/codex/usage" => {status, %{"error" => "unavailable"}},
       "/wham/usage" => {status, %{"error" => "unavailable"}},
       "/backend-api/wham/usage" => {status, %{"error" => "unavailable"}}
     }}
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "routing-test-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end
end
