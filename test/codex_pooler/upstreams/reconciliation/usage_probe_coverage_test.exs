defmodule CodexPooler.Upstreams.Reconciliation.UsageProbeCoverageTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe

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
end
