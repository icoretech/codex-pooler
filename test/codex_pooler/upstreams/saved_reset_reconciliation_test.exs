defmodule CodexPooler.Upstreams.SavedResetReconciliationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets

  test "refresh_quota_from_usage stores sanitized saved reset usage snapshot" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {404, %{}},
           "/backend-api/codex/usage" => {404, %{}},
           "/wham/usage" => {404, %{}},
           "/backend-api/wham/usage" => {200, usage_payload(3)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert %{
             status: "reported",
             available_count: 3,
             available?: true,
             reported?: true,
             expires_reported?: true,
             available_expires_at: [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ],
             next_expires_at: "2026-07-18T00:40:11.968726Z",
             path_style: "chatgpt_api",
             usage_path: "/backend-api/wham/usage"
           } = SavedResets.snapshot(updated_identity)

    assert get_in(updated_identity.metadata, ["saved_resets", "source"]) == "codex_usage_api"
    assert is_binary(get_in(updated_identity.metadata, ["saved_resets", "observed_at"]))
    metadata_json = Jason.encode!(updated_identity.metadata)
    assert metadata_json =~ "available_expires_at"
    assert metadata_json =~ "next_expires_at"
    refute metadata_json =~ "RateLimitResetCredit_"
    refute metadata_json =~ "credit_id"
    refute metadata_json =~ "redeem_request_id"
    refute metadata_json =~ "One free rate limit reset"
    refute metadata_json =~ "Referral reward"
  end

  test "refresh_quota_from_usage fetches reset expirations when Codex usage reports saved resets" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, usage_payload(1)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             available_count: 3,
             expires_reported?: true,
             next_expires_at: "2026-07-18T00:40:11.968726Z",
             path_style: "codex_api",
             usage_path: "/api/codex/usage"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/api/codex/usage",
             "/backend-api/wham/rate-limit-reset-credits"
           ]
  end

  test "refresh_quota_from_usage preserves current first-seen expiration metadata" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, usage_payload(3)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          Map.merge(
            %{"usage_base_url" => FakeUpstream.url(fake)},
            previous_expiration_metadata()
          )
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    saved_resets = Repo.reload!(updated_identity).metadata["saved_resets"]
    observed_at = saved_resets["expires_observed_at"]

    assert saved_resets["available_expires_at"] == [
             "2026-07-18T00:40:11.968726Z",
             "2026-07-20T00:40:11.968726Z"
           ]

    assert saved_resets["available_expirations"] == [
             %{
               "expires_at" => "2026-07-18T00:40:11.968726Z",
               "first_seen_at" => "2026-06-21T09:00:00Z"
             },
             %{
               "expires_at" => "2026-07-20T00:40:11.968726Z",
               "first_seen_at" => observed_at
             }
           ]

    assert saved_resets["next_expires_at"] == "2026-07-18T00:40:11.968726Z"

    refute Enum.any?(saved_resets["available_expirations"], fn row ->
             row["expires_at"] == "2026-07-21T00:40:11.968726Z"
           end)

    refute Jason.encode!(saved_resets) =~ "not-a-date"

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/api/codex/usage",
             "/backend-api/wham/rate-limit-reset-credits"
           ]
  end

  test "refresh_quota_from_usage reuses fresh expiration metadata without polling every time" do
    {:ok, fake} =
      FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(2)}}})

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)}, fresh_expiration_metadata(2))
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             available_count: 2,
             expires_reported?: true,
             available_expires_at: ["2026-07-18T00:40:11.968726Z"],
             available_expirations: [
               %{
                 expires_at: "2026-07-18T00:40:11.968726Z",
                 first_seen_at: "2026-06-21T09:00:00Z"
               }
             ],
             next_expires_at: "2026-07-18T00:40:11.968726Z"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == ["/api/codex/usage"]
  end

  test "refresh_quota_from_usage stores unreported snapshot when usage omits reset credits" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, Map.delete(usage_payload(1), "rate_limit_reset_credits")}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             status: "unreported",
             available_count: nil,
             available?: false,
             reported?: false,
             usage_path: "/api/codex/usage"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))
  end

  defp fresh_expiration_metadata(available_count) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => ["2026-07-18T00:40:11.968726Z"],
        "available_expirations" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z"
          }
        ],
        "next_expires_at" => "2026-07-18T00:40:11.968726Z",
        "expires_observed_at" => observed_at,
        "expires_refresh_attempted_at" => observed_at,
        "reason" => nil
      }
    }
  end

  defp previous_expiration_metadata do
    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => 2,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => "2026-06-22T10:00:00Z",
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => [
          "2026-07-18T00:40:11.968726Z",
          "2026-07-21T00:40:11.968726Z"
        ],
        "available_expirations" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z"
          },
          %{
            "expires_at" => "2026-07-21T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T10:00:00Z"
          }
        ],
        "next_expires_at" => "2026-07-18T00:40:11.968726Z",
        "expires_observed_at" => "2026-06-22T10:00:00Z",
        "expires_refresh_attempted_at" => "2026-06-22T10:00:00Z",
        "reason" => nil
      }
    }
  end

  defp usage_payload(available_count) do
    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }
  end

  defp reset_credits_payload do
    %{
      "available_count" => 3,
      "total_earned_count" => 4,
      "credits" => [
        %{
          "id" => "RateLimitResetCredit_early",
          "reset_type" => "codex_rate_limits",
          "status" => "available",
          "granted_at" => "2026-06-18T00:40:11.968726Z",
          "expires_at" => "2026-07-18T00:40:11.968726Z",
          "title" => "One free rate limit reset"
        },
        %{
          "id" => "RateLimitResetCredit_late",
          "reset_type" => "codex_rate_limits",
          "status" => "available",
          "granted_at" => "2026-06-20T00:40:11.968726Z",
          "expires_at" => "2026-07-20T00:40:11.968726Z",
          "description" => "Referral reward"
        },
        %{
          "id" => "RateLimitResetCredit_redeemed",
          "reset_type" => "codex_rate_limits",
          "status" => "redeemed",
          "expires_at" => "2026-07-10T00:40:11.968726Z"
        },
        %{
          "id" => "RateLimitResetCredit_invalid",
          "reset_type" => "codex_rate_limits",
          "status" => "available",
          "expires_at" => "not-a-date"
        }
      ]
    }
  end
end
