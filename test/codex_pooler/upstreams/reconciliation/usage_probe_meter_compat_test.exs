defmodule CodexPooler.Upstreams.Reconciliation.UsageProbeMeterCompatTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe

  test "a successful metered weekly descriptor covers a legacy primary row with the same provider token" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 67,
          "limit_window_seconds" => 604_800
        }
      },
      "additional_rate_limits" => [
        %{
          "limit_name" => "Provider limit alpha",
          "metered_feature" => "example_meter",
          "rate_limit" => %{
            "secondary_window" => %{
              "used_percent" => 42,
              "limit_window_seconds" => 604_800,
              "reset_after_seconds" => 3_600
            }
          }
        }
      ]
    }

    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload},
           "/backend-api/codex/usage" => {503, %{"error" => "unavailable"}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{"base_url" => FakeUpstream.url(upstream)}
      })

    assignment =
      assignment
      |> Ecto.Changeset.change(metadata: %{})
      |> Repo.update!()

    legacy_primary = %{
      quota_key: "provider_limit_alpha",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "Provider limit alpha",
      raw_limit_id: "example_meter",
      raw_limit_name: "Provider limit alpha",
      raw_metered_feature: "example_meter",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("22"),
      reset_at: DateTime.add(observed_at, 2, :hour),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: observed_at
    }

    assert {:ok, existing} = Windows.record_evidence(identity, legacy_primary, observed_at)

    assert {:ok, probe} = UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert Evidence.descriptor_key(existing) in probe.covered_descriptors

    assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)
    refute Enum.any?(Windows.list_evidence(identity), &(&1.id == existing.id))
  end
end
