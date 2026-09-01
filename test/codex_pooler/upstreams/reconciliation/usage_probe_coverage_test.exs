defmodule CodexPooler.Upstreams.Reconciliation.UsageProbeCoverageTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  # The provider suspended the anchored 5h windows on 2026-07-13 (announced as
  # temporary): while suspended, the usage payload reports each family as a
  # weekly `primary_window` plus an explicit `"secondary_window" => nil`.
  # Descriptor coverage must treat that declared-null window as absent (nothing
  # to parse) rather than unparseable (cover nothing), or stale vanished usage
  # rows are never cleaned up. If the 5h windows return, both windows are
  # non-null maps and coverage behaves exactly as before.

  defp new_shape_payload(observed_at, opts \\ []) do
    account_window =
      Keyword.get(opts, :account_window, %{
        "used_percent" => 0,
        "limit_window_seconds" => 604_800,
        "reset_after_seconds" => 604_800,
        "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 7, :day))
      })

    %{
      "plan_type" => Keyword.get(opts, :plan_type, "pro"),
      "rate_limit" => %{
        "primary_window" => account_window,
        "secondary_window" => nil
      },
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => 1,
              "limit_window_seconds" => 604_800,
              "reset_after_seconds" => 480_000,
              "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 480_000, :second))
            },
            "secondary_window" => nil
          }
        }
      ],
      "rate_limit_reset_credits" => %{"available_count" => 3}
    }
  end

  defp fake_with_payload(payload) do
    FakeUpstream.start_link(
      {:path_json,
       %{
         "/api/codex/usage" => {200, payload},
         "/backend-api/codex/usage" => {200, payload},
         "/wham/usage" => {404, %{}},
         "/backend-api/wham/usage" => {404, %{}}
       }}
    )
  end

  defp assignment_with_fake(fake) do
    active_upstream_assignment_fixture(pool_fixture(), %{
      metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
    })
  end

  defp stale_legacy_5h_row!(identity, observed_at) do
    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("12"),
                 reset_at: DateTime.add(observed_at, 2, :hour),
                 observed_at: observed_at,
                 last_sync_at: observed_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               },
               observed_at
             )
  end

  defp account_rows(identity) do
    Repo.all(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "account" and
            w.source == "codex_usage_api",
        order_by: [asc: w.window_kind]
    )
  end

  test "the new payload shape with explicit null secondary covers its descriptors" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {:ok, fake} = fake_with_payload(new_shape_payload(observed_at))
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, %UsageProbe.Result{} = probe} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert length(probe.windows) == 2
    assert MapSet.size(probe.covered_descriptors) == 2
  end

  test "a stale legacy 5h usage row is deleted once the account descriptor is covered" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {:ok, fake} = fake_with_payload(new_shape_payload(observed_at))
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    stale_legacy_5h_row!(identity, DateTime.add(observed_at, -2, :day))

    assert {:ok, _identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    rows = account_rows(identity)
    # The vanished 5h primary is gone; only the weekly secondary remains.
    refute Enum.any?(rows, &(&1.window_kind == "primary" and &1.window_minutes == 300))
    assert Enum.any?(rows, &(&1.window_kind == "secondary" and &1.window_minutes == 10_080))
  end

  test "a canonical provider plan label is persisted with its normalized family" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, fake} =
      fake_with_payload(new_shape_payload(observed_at, plan_type: "enterprise_cbp_automation"))

    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, refreshed_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    reloaded_identity = Repo.reload!(refreshed_identity)
    assert reloaded_identity.plan_label == "enterprise_cbp_automation"
    assert reloaded_identity.plan_family == "enterprise-cbp-automation"
  end

  test "a malformed account window still covers nothing and preserves stale rows" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    payload =
      new_shape_payload(observed_at,
        account_window: %{
          "used_percent" => "garbage",
          "limit_window_seconds" => 604_800
        }
      )

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    stale_legacy_5h_row!(identity, DateTime.add(observed_at, -2, :day))

    assert {:ok, %UsageProbe.Result{} = probe} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    # The account descriptor failed to parse safely: it must not be covered.
    refute Enum.any?(probe.covered_descriptors, fn descriptor ->
             elem(descriptor, 4) == "account"
           end)

    assert {:ok, _identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    rows = account_rows(identity)
    assert Enum.any?(rows, &(&1.window_kind == "primary" and &1.window_minutes == 300))
  end

  test "a rate limit with only null windows covers nothing" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    payload =
      observed_at
      |> new_shape_payload()
      |> put_in(["rate_limit"], %{"primary_window" => nil, "secondary_window" => nil})

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, %UsageProbe.Result{} = probe} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    refute Enum.any?(probe.covered_descriptors, fn descriptor ->
             elem(descriptor, 4) == "account"
           end)
  end

  test "an affirmative no-window observation carries the supplied timestamp and covers the account" do
    observed_at = ~U[2026-08-20 10:11:12.123456Z]

    payload = %{
      "plan_type" => "future-plan",
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => nil,
        "secondary_window" => nil
      }
    }

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, %UsageProbe.Result{} = probe} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert probe.observed_at == observed_at
    assert probe.account_availability.state == :available
    assert probe.account_availability.account_windows == :absent
    assert Enum.any?(probe.covered_descriptors, &(elem(&1, 4) == "account"))
  end

  test "conflict beats available in either path order and removes account coverage" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    available = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false}
    }

    conflict = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => true}
    }

    for {first, second} <- [{available, conflict}, {conflict, available}] do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {200, first},
             "/backend-api/codex/usage" => {200, second}
           }}
        )

      %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

      assert {:ok, %UsageProbe.Result{} = probe} =
               UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

      assert probe.account_availability.state == :unknown
      refute Enum.any?(probe.covered_descriptors, &(elem(&1, 4) == "account"))
    end
  end

  test "malformed selected windows beat available across paths and cannot clear prior evidence" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    available = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false}
    }

    for invalid_window <- malformed_selected_windows() do
      malformed = %{
        "plan_type" => "plus",
        "rate_limit" => %{
          "allowed" => true,
          "limit_reached" => false,
          "primary_window" => invalid_window
        }
      }

      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {200, available},
             "/backend-api/codex/usage" => {200, malformed}
           }}
        )

      %{identity: identity, assignment: assignment} = assignment_with_fake(fake)
      stale_legacy_5h_row!(identity, DateTime.add(observed_at, -2, :day))

      assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
      assert probe.account_availability.state == :unknown
      assert probe.windows == []
      refute Enum.any?(probe.covered_descriptors, &(elem(&1, 4) == "account"))

      assert {:ok, _identity} =
               PoolReconciliation.refresh_quota_from_usage(identity, assignment,
                 observed_at: observed_at
               )

      assert [%AccountQuotaWindow{window_minutes: 300}] = account_rows(identity)
    end
  end

  test "malformed selected account slot suppresses a valid sibling window and account coverage" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]
    reset_at = DateTime.to_unix(DateTime.add(observed_at, 7, :day))

    for rate_limit <- [
          %{
            "primary_window" => %{
              "used_percent" => 25,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => 900
            },
            "secondary_window" => %{
              "used_percent" => 30,
              "limit_window_seconds" => 604_800,
              "reset_after_seconds" => 604_800,
              "reset_at" => reset_at
            }
          },
          %{
            "primary_window" => %{
              "used_percent" => 25,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => 900,
              "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 900, :second))
            },
            "secondary_window" => %{
              "used_percent" => 30,
              "limit_window_seconds" => 604_800,
              "reset_after_seconds" => 604_800
            }
          }
        ] do
      payload = %{"plan_type" => "plus", "rate_limit" => rate_limit}
      {:ok, fake} = fake_with_payload(payload)
      %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

      assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
      assert probe.account_availability.state == :unknown
      assert probe.account_availability.basis == :conflict
      assert probe.account_availability.account_windows == :unknown
      assert probe.windows == []
      refute Enum.any?(probe.covered_descriptors, &(elem(&1, 4) == "account"))
    end
  end

  test "account conflict suppression preserves model-scoped evidence whose quota key is account" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => %{
          "used_percent" => 25,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      },
      "additional_rate_limits" => [
        %{
          "limit_name" => "Account",
          "metered_feature" => "account",
          "rate_limit" => %{
            "allowed" => true,
            "limit_reached" => false,
            "primary_window" => %{
              "used_percent" => 100,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => 3_600,
              "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 1, :hour))
            }
          }
        }
      ]
    }

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, _account_baseline} =
             Windows.record_evidence(
               identity,
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("10"),
                 reset_at: DateTime.add(observed_at, 2, :hour),
                 observed_at: observed_at,
                 last_sync_at: observed_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               },
               observed_at
             )

    assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
    assert probe.account_availability.state == :unknown
    assert probe.account_availability.basis == :conflict

    assert [model_window] = probe.windows
    assert model_window.quota_key == "account"
    assert model_window.quota_scope == "model"
    assert model_window.quota_family == "codex_model"
    assert model_window.model == "Account"

    assert {:ok, _identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               observed_at: observed_at
             )

    assert [persisted] = account_rows(identity)
    assert persisted.quota_scope == "model"
    assert persisted.quota_family == "codex_model"
    assert persisted.model == "Account"

    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], observed_at)[identity.id]

    classified =
      snapshot
      |> RoutingQuotaSnapshot.time_visible_raw_windows()
      |> Enum.find(&(&1.quota_scope == "model" and &1.quota_key == "account"))

    assert classified.quota_scope == "model"
    assert classified.quota_family == "codex_model"
    assert classified.quota_key == "account"

    assert %{eligible?: false, exclusions: exclusions} =
             Windows.routing_quota_eligibility_from_snapshot(snapshot,
               model: "Account",
               model_aliases: ["Account"]
             )

    assert Enum.any?(exclusions, fn exclusion ->
             "exhausted" in Map.get(exclusion, :reason_codes, []) and
               Map.get(exclusion, :quota_scope) == "model" and
               Map.get(exclusion, :quota_key) == "account"
           end)

    rows =
      QuotaProjection.quota_limit_rows(
        RoutingQuotaSnapshot.effective_windows(snapshot),
        DateTimeDisplay.preferences_for_user(nil),
        observed_at
      )

    assert Enum.any?(rows, fn row ->
             row.label == "Account 5h" and row.key == "model-account-primary-300" and
               row.percent_value == 0
           end)

    snapshot = Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()]
    assert snapshot["state"] == "unknown"
  end

  test "malformed additional collections fail closed without crashing descriptor coverage" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    for malformed <- ["account", 42, %{"unexpected" => "map"}] do
      payload = %{
        "plan_type" => "plus",
        "rate_limit" => %{"allowed" => true, "limit_reached" => false},
        "additional_rate_limits" => malformed
      }

      {:ok, fake} = fake_with_payload(payload)
      %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

      assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
      assert probe.account_availability.state == :unknown
      assert probe.account_availability.basis == :conflict
      assert probe.windows == []
      refute Enum.any?(probe.covered_descriptors, &(elem(&1, 0) == "account"))

      assert {:ok, _identity} =
               PoolReconciliation.refresh_quota_from_usage(identity, assignment,
                 observed_at: observed_at
               )

      assert account_rows(identity) == []

      assert Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()]["state"] ==
               "unknown"
    end
  end

  test "missing null and empty additional collections remain neutral" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    for additional <- [:missing, nil, []] do
      payload = %{
        "plan_type" => "plus",
        "rate_limit" => %{"allowed" => true, "limit_reached" => false}
      }

      payload =
        if additional == :missing,
          do: payload,
          else: Map.put(payload, "additional_rate_limits", additional)

      {:ok, fake} = fake_with_payload(payload)
      %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

      assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
      assert probe.account_availability.state == :available
      assert probe.account_availability.basis == :affirmative
      assert probe.windows == []
    end
  end

  test "no-proof is neutral beside available in either order and alone becomes unknown" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    available = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false}
    }

    no_proof = %{
      "plan_type" => "plus",
      "credits" => %{"has_credits" => false, "unlimited" => false}
    }

    for {first, second} <- [{available, no_proof}, {no_proof, available}] do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {200, first},
             "/backend-api/codex/usage" => {200, second}
           }}
        )

      %{identity: identity, assignment: assignment} = assignment_with_fake(fake)
      assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
      assert probe.account_availability.state == :available
      assert Enum.any?(probe.covered_descriptors, &(elem(&1, 4) == "account"))
    end

    {:ok, fake} = fake_with_payload(no_proof)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)
    assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
    assert probe.account_availability.state == :unknown
    refute Enum.any?(probe.covered_descriptors, &(elem(&1, 4) == "account"))
  end

  test "saved reset enrichment runs once for each accepted path and not during reduction" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false},
      "rate_limit_reset_credits" => %{"available_count" => 1}
    }

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload},
           "/backend-api/codex/usage" => {200, payload},
           "/backend-api/wham/rate-limit-reset-credits" => {200, %{"items" => []}}
         }}
      )

    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)
    assert {:ok, _probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    requests = FakeUpstream.requests(fake)
    assert Enum.count(requests, &(&1.path == "/backend-api/wham/rate-limit-reset-credits")) == 2
  end

  test "available no-window persistence prunes usage account rows and keeps unrelated metadata" do
    observed_at = ~U[2026-08-20 10:11:12Z]

    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false}
    }

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    identity =
      identity
      |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "other", %{"kept" => true}))
      |> Repo.update!()

    stale_legacy_5h_row!(identity, DateTime.add(observed_at, -2, :day))

    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    snapshot = Repo.reload!(refreshed).metadata[AccountAvailabilityStore.metadata_key()]

    assert snapshot["state"] == "available"
    assert snapshot["credential_epoch"] == 1
    assert Repo.reload!(refreshed).metadata["other"] == %{"kept" => true}
    assert account_rows(identity) == []
  end

  test "no-window account coverage preserves every non-usage source and model descriptor" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false}
    }

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    for source <- [
          "codex_usage_api",
          "codex_response_headers",
          "codex_rate_limit_event",
          "codex_rate_limit_error",
          "local_reconciliation",
          "future_source"
        ] do
      assert {:ok, _row} =
               Windows.record_evidence(
                 identity,
                 %{
                   quota_key: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("12"),
                   reset_at: DateTime.add(observed_at, 2, :hour),
                   observed_at: observed_at,
                   last_sync_at: observed_at,
                   source: source,
                   source_precision: "observed",
                   quota_scope: "account",
                   quota_family: "account",
                   freshness_state: "fresh"
                 },
                 observed_at
               )
    end

    assert {:ok, _model_row} =
             Windows.record_evidence(
               identity,
               %{
                 quota_key: "model-a",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("12"),
                 reset_at: DateTime.add(observed_at, 2, :hour),
                 observed_at: observed_at,
                 last_sync_at: observed_at,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "model-a",
                 freshness_state: "fresh"
               },
               observed_at
             )

    assert {:ok, _identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               observed_at: DateTime.add(observed_at, 1, :second)
             )

    rows = Windows.list_evidence(identity)
    refute Enum.any?(rows, &(&1.source == "codex_usage_api" and &1.quota_key == "account"))

    assert Enum.sort(for(row <- rows, row.quota_key == "account", do: row.source)) ==
             Enum.sort([
               "codex_response_headers",
               "codex_rate_limit_event",
               "codex_rate_limit_error",
               "local_reconciliation",
               "future_source"
             ])

    assert Enum.any?(rows, &(&1.source == "codex_usage_api" and &1.quota_key == "model_a"))
  end

  test "fenced persistence preserves blockers through ambiguity and failure, then replaces or clears them" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    blocked = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => false, "limit_reached" => true}
    }

    available = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false}
    }

    conflict = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => true}
    }

    no_proof = %{
      "plan_type" => "plus",
      "credits" => %{"has_credits" => false, "unlimited" => false}
    }

    {:ok, fake} = fake_with_payload(blocked)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               observed_at: observed_at
             )

    blocked_snapshot = Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()]
    assert blocked_snapshot["observed_at"] == "2026-08-20T10:11:12.000000Z"

    for payload <- [conflict, no_proof] do
      FakeUpstream.set_mode(
        fake,
        {:path_json,
         %{
           (identity.metadata["usage_path"] || "/backend-api/wham/usage") => {200, payload},
           "/backend-api/codex/usage" => {200, payload}
         }}
      )

      assert {:ok, identity} =
               PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), assignment,
                 observed_at: DateTime.add(observed_at, 1, :second)
               )

      assert Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()] ==
               blocked_snapshot
    end

    FakeUpstream.set_mode(fake, {:json_error, 503, %{}})

    assert {:error, _reason} =
             PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), assignment)

    assert Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()] ==
             blocked_snapshot

    FakeUpstream.set_mode(
      fake,
      {:path_json,
       %{
         "/backend-api/wham/usage" => {200, available},
         "/backend-api/codex/usage" => {200, available}
       }}
    )

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), assignment,
               observed_at: DateTime.add(observed_at, 2, :second)
             )

    assert get_in(Repo.reload!(identity).metadata, [
             AccountAvailabilityStore.metadata_key(),
             "state"
           ]) ==
             "available"

    ordinary_payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 1,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 3_600,
          "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 1, :hour))
        }
      }
    }

    FakeUpstream.set_mode(
      fake,
      {:path_json,
       %{
         "/backend-api/wham/usage" => {200, ordinary_payload},
         "/backend-api/codex/usage" => {200, ordinary_payload}
       }}
    )

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), assignment,
               observed_at: DateTime.add(observed_at, 3, :second)
             )

    refute Map.has_key?(Repo.reload!(identity).metadata, AccountAvailabilityStore.metadata_key())
  end

  test "an enclosing transaction rollback reverts the complete fenced persistence bundle" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]
    prior_observed_at = DateTime.add(observed_at, -1, :hour)

    payload = %{
      "plan_type" => "enterprise-next",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false},
      "additional_rate_limits" => [
        %{
          "limit_name" => "Model A",
          "metered_feature" => "model_a",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => 4,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => 3_600,
              "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 1, :hour))
            }
          }
        }
      ],
      "rate_limit_reset_credits" => %{"available_count" => 0}
    }

    {:ok, fake} = fake_with_payload(payload)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    identity =
      identity
      |> Ecto.Changeset.change(
        plan_family: "legacy-plan",
        plan_label: "legacy_plan",
        metadata:
          Map.merge(identity.metadata, %{
            AccountAvailabilityStore.metadata_key() =>
              AccountAvailabilityStore.encode!(:blocked, prior_observed_at, 1),
            "saved_resets" => %{
              "version" => 1,
              "observed_at" => DateTime.to_iso8601(prior_observed_at),
              "status" => "reported",
              "available_count" => 2
            },
            "coexists" => %{"kept" => true}
          })
      )
      |> Repo.update!()

    stale_legacy_5h_row!(identity, prior_observed_at)
    before_identity = Repo.reload!(identity)
    before_windows = Windows.list_evidence(identity)

    assert {:error, :forced_bundle_rollback} =
             Repo.transaction(fn ->
               assert {:ok, _identity} =
                        PoolReconciliation.refresh_quota_from_usage(identity, assignment,
                          observed_at: observed_at
                        )

               Repo.rollback(:forced_bundle_rollback)
             end)

    after_identity = Repo.reload!(identity)
    assert after_identity.plan_family == before_identity.plan_family
    assert after_identity.plan_label == before_identity.plan_label
    assert after_identity.metadata == before_identity.metadata
    assert Windows.list_evidence(identity) == before_windows
  end

  test "blocked snapshot survives a later malformed accepted observation byte-identically" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    blocked = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => false, "limit_reached" => true}
    }

    malformed = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => "yes", "limit_reached" => false}
    }

    {:ok, fake} = fake_with_payload(blocked)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               observed_at: observed_at
             )

    prior = Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()]

    FakeUpstream.set_mode(
      fake,
      {:path_json,
       %{
         "/backend-api/wham/usage" => {200, malformed},
         "/backend-api/codex/usage" => {200, malformed}
       }}
    )

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               observed_at: DateTime.add(observed_at, 1, :second)
             )

    assert Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()] == prior
  end

  test "blocked snapshot survives a later absent observation byte-identically" do
    observed_at = ~U[2026-08-20 10:11:12.000000Z]

    blocked = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => false, "limit_reached" => true}
    }

    absent = %{"plan_type" => "plus"}

    {:ok, fake} = fake_with_payload(blocked)
    %{identity: identity, assignment: assignment} = assignment_with_fake(fake)

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               observed_at: observed_at
             )

    prior = Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()]

    FakeUpstream.set_mode(
      fake,
      {:path_json,
       %{"/backend-api/wham/usage" => {200, absent}, "/backend-api/codex/usage" => {200, absent}}}
    )

    assert {:error, _reason} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert Repo.reload!(identity).metadata[AccountAvailabilityStore.metadata_key()] == prior
  end

  defp malformed_selected_windows do
    valid = %{
      "used_percent" => 25,
      "limit_window_seconds" => 18_000,
      "reset_after_seconds" => 3_600,
      "reset_at" => 1_787_655_600
    }

    for field <- ~w(limit_window_seconds reset_after_seconds reset_at),
        mutation <- [:missing, :wrong_type] do
      case mutation do
        :missing -> Map.delete(valid, field)
        :wrong_type -> Map.put(valid, field, "invalid")
      end
    end
  end
end
