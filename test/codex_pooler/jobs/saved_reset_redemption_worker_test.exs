defmodule CodexPooler.Jobs.SavedResetRedemptionWorkerTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.SavedResetRedemptionWorker

  describe "perform/1" do
    test "cancels queued job when persisted available_count is zero without provider request" do
      {:ok, fake} = codex_reset_fake()
      %{assignment: assignment} = assignment_with_fake(fake, 0)

      assert {:cancel, :saved_reset_unavailable} =
               perform_job(SavedResetRedemptionWorker, %{
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "admin_manual"
               })

      assert FakeUpstream.requests(fake) == []
    end

    test "cancels queued job when persisted count is unreported without provider request" do
      {:ok, fake} = codex_reset_fake()

      %{assignment: assignment} =
        assignment_with_fake(fake, nil, saved_reset_status: "unreported")

      assert {:cancel, :saved_reset_unavailable} =
               perform_job(SavedResetRedemptionWorker, %{
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "admin_manual"
               })

      assert FakeUpstream.requests(fake) == []
    end

    test "cancels queued job when saved reset state is unavailable without provider request" do
      {:ok, fake} = codex_reset_fake()

      %{assignment: assignment} =
        assignment_with_fake(fake, nil, saved_reset_status: "unavailable")

      assert {:cancel, :saved_reset_unavailable} =
               perform_job(SavedResetRedemptionWorker, %{
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "admin_manual"
               })

      assert FakeUpstream.requests(fake) == []
    end

    test "snoozes fresh in-progress redemption without provider request" do
      {:ok, fake} = codex_reset_fake()

      %{assignment: assignment} =
        assignment_with_fake(fake, 1, redemption: redemption_metadata(DateTime.utc_now()))

      assert {:snooze, 5} =
               perform_job(SavedResetRedemptionWorker, %{
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "admin_manual"
               })

      assert FakeUpstream.requests(fake) == []
    end
  end

  defp codex_reset_fake do
    FakeUpstream.start_link(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" => {200, usage_payload(0)}
       }}
    )
  end

  defp assignment_with_fake(fake, available_count, opts \\ []) do
    metadata = %{
      "usage_base_url" => FakeUpstream.url(fake),
      "saved_resets" => %{
        "status" => Keyword.get(opts, :saved_reset_status, "reported"),
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      }
    }

    metadata =
      case Keyword.get(opts, :redemption) do
        nil -> metadata
        redemption -> Map.put(metadata, "saved_reset_redemption", redemption)
      end

    active_upstream_assignment_fixture(pool_fixture(), %{metadata: metadata})
  end

  defp redemption_metadata(started_at) do
    %{
      "status" => "redeeming",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => "admin_manual",
      "started_at" => started_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "finished_at" => nil,
      "result" => nil
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
end
