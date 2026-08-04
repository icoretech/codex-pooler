defmodule CodexPooler.Jobs.SavedResetRedemptionWorkerTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.{SavedResetRedemption, SavedResets}
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  describe "perform/1" do
    test "classifies stale consuming recovery at the age and due-time boundaries" do
      now = ~U[2026-08-04 12:00:00Z]
      receive_timeout = 15_000

      stale_after = receive_timeout + SavedResets.redemption_stale_grace_ms()

      started_at = DateTime.add(now, -stale_after, :millisecond)
      attempt_id = Ecto.UUID.generate()

      identity = %UpstreamIdentity{
        metadata: %{
          "saved_reset_redemption" =>
            stale_consuming_redemption(started_at, attempt_id, 7,
              next_action_at: DateTime.to_iso8601(now)
            )
        }
      }

      assert %{attempt_id: ^attempt_id, generation: 7} =
               SavedResetRedemption.stale_consuming_recovery_candidate(identity,
                 now: now,
                 receive_timeout: receive_timeout
               )

      not_old_enough =
        put_in(
          identity.metadata["saved_reset_redemption"]["started_at"],
          now
          |> DateTime.add(-stale_after + 1, :millisecond)
          |> DateTime.to_iso8601()
        )

      assert SavedResetRedemption.stale_consuming_recovery_candidate(not_old_enough,
               now: now,
               receive_timeout: receive_timeout
             ) == nil

      not_due =
        put_in(
          identity.metadata["saved_reset_redemption"]["provider_replay"]["next_action_at"],
          now |> DateTime.add(1, :millisecond) |> DateTime.to_iso8601()
        )

      assert SavedResetRedemption.stale_consuming_recovery_candidate(not_due,
               now: now,
               receive_timeout: receive_timeout
             ) == nil
    end

    test "discovers replay and legacy consuming classes but rejects malformed and settled records" do
      now = ~U[2026-08-04 12:00:00Z]
      started_at = DateTime.add(now, -2, :minute)
      attempt_id = Ecto.UUID.generate()

      for extra <- [
            %{},
            %{"legacy_recovery" => %{"version" => 1, "state" => "unresolved"}},
            %{
              "provider_replay" => %{
                "version" => 1,
                "provider_dispatches" => 0,
                "mode" => "replay"
              }
            },
            %{
              "provider_replay" => %{
                "version" => 1,
                "provider_dispatches" => 6,
                "mode" => "observe_only"
              }
            }
          ] do
        identity = %UpstreamIdentity{
          metadata: %{
            "saved_reset_redemption" =>
              Map.merge(stale_consuming_redemption(started_at, attempt_id, 3), extra)
          }
        }

        assert %{attempt_id: ^attempt_id, generation: 3} =
                 SavedResetRedemption.stale_consuming_recovery_candidate(identity,
                   now: now,
                   receive_timeout: 0
                 )
      end

      base = stale_consuming_redemption(started_at, attempt_id, 3)

      for invalid <- [
            nil,
            %{},
            Map.put(base, "status", "succeeded"),
            Map.put(base, "phase", "reblocked"),
            Map.put(base, "attempt_id", "invalid"),
            Map.put(base, "generation", -1),
            Map.put(base, "started_at", "invalid"),
            put_in(base, ["provider_replay", "next_action_at"], "invalid")
          ] do
        identity = %UpstreamIdentity{metadata: %{"saved_reset_redemption" => invalid}}

        assert SavedResetRedemption.stale_consuming_recovery_candidate(identity,
                 now: now,
                 receive_timeout: 0
               ) == nil
      end
    end

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

    @tag :scheduled_expiry_stale_claim_residual
    test "discards a generic job for stale phase-bearing consuming redemption" do
      Repo.delete_all(Oban.Job)
      {:ok, fake} = codex_reset_fake()
      started_at = DateTime.utc_now() |> DateTime.add(-5, :minute)

      redemption =
        started_at
        |> redemption_metadata()
        |> Map.put("phase", "consuming")

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, 1, redemption: redemption)

      assert {:error, :saved_reset_redemption_in_progress} =
               perform_job(SavedResetRedemptionWorker, %{
                 "pool_upstream_assignment_id" => assignment.id,
                 "trigger_kind" => "admin_manual"
               })

      assert {:ok, job} = Jobs.enqueue_saved_reset_redemption(assignment)
      assert %{discard: 1, success: 0} = Oban.drain_queue(queue: :jobs)

      assert Repo.get!(Oban.Job, job.id).state == "discarded"
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == redemption
      assert FakeUpstream.requests(fake) == []
    end
  end

  describe "scheduled expiry rescue" do
    @describetag :scheduled_expiry_worker

    test "maps malformed scheduled decision evidence to one terminal cancellation" do
      assert {:cancel, :scheduled_expiry_decision_evidence_invalid} =
               SavedResetRedemptionWorker.map_scheduled_result(
                 {:ok,
                  %{
                    status: :noop,
                    applied?: false,
                    code: "scheduled_expiry_decision_evidence_invalid"
                  }}
               )

      assert :ok =
               SavedResetRedemptionWorker.map_scheduled_result(
                 {:ok,
                  %{
                    status: :noop,
                    applied?: false,
                    code: "scheduled_expiry_burn_not_ready"
                  }}
               )
    end

    test "cancelled scheduled job releases the incomplete-only unique slot" do
      Repo.delete_all(Oban.Job)
      %{fake: fake, assignment: assignment} = scheduled_expiry_fixture()

      assert {:ok, first_job} = Jobs.enqueue_scheduled_saved_reset_redemption(assignment)
      refute first_job.conflict?

      assert :ok = Oban.cancel_job(first_job)

      first_job = Repo.reload!(first_job)
      assert first_job.state == "cancelled"
      assert %DateTime{} = first_job.cancelled_at

      assert {:ok, second_job} = Jobs.enqueue_scheduled_saved_reset_redemption(assignment)
      refute second_job.conflict?
      assert second_job.id != first_job.id
      assert second_job.state == "available"
      assert FakeUpstream.requests(fake) == []
    end

    test "completes eligible scheduled rescue after one consume without a probe" do
      %{fake: fake, identity: identity, assignment: assignment} = scheduled_expiry_fixture()

      assert :ok =
               perform_scheduled_job(assignment.id, identity.id)

      assert [
               %{method: "POST", path: "/api/codex/rate-limit-reset-credits/consume"},
               %{method: "GET", path: "/api/codex/usage"}
             ] = FakeUpstream.requests(fake)

      redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
      assert redemption["status"] == "succeeded"
      assert redemption["trigger_kind"] == "scheduled_expiry_rescue"
      refute Map.has_key?(redemption, "probe")
    end

    test "completes pending-confirmation scheduled rescue after one consume without a probe" do
      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(usage_response: {503, %{"error" => "temporarily unavailable"}})

      assert :ok =
               perform_scheduled_job(assignment.id, identity.id)

      assert [
               %{method: "POST", path: "/api/codex/rate-limit-reset-credits/consume"},
               %{method: "GET", path: "/api/codex/usage"}
             ] = FakeUpstream.requests(fake)

      redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
      assert redemption["phase"] == "consumed_pending_probe"
      refute Map.has_key?(redemption, "probe")
    end

    test "completes stable policy noop without provider request" do
      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(policy_enabled?: false)

      assert :ok =
               perform_scheduled_job(assignment.id, identity.id)

      assert FakeUpstream.requests(fake) == []
    end

    test "completes stale fail-closed lifecycle noop without provider request" do
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          as_of: as_of,
          redemption:
            redemption_metadata(
              DateTime.add(as_of, -5, :minute),
              "scheduled_expiry_rescue"
            )
        )

      assert :ok =
               perform_scheduled_job(assignment.id, identity.id)

      assert FakeUpstream.requests(fake) == []
    end

    test "snoozes a fresh competing scheduled claim without provider request" do
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          as_of: as_of,
          redemption: redemption_metadata(as_of, "scheduled_expiry_rescue")
        )

      assert {:snooze, 5} =
               perform_scheduled_job(assignment.id, identity.id)

      assert FakeUpstream.requests(fake) == []
    end

    test "cancels missing or reassigned scheduled targets without provider request" do
      %{fake: fake, identity: identity, assignment: assignment} = scheduled_expiry_fixture()
      foreign_identity = active_upstream_identity_fixture()

      update_assignment!(assignment, %{upstream_identity_id: foreign_identity.id})

      assert {:cancel, :scheduled_expiry_identity_mismatch} =
               perform_scheduled_job(assignment.id, identity.id)

      assert {:cancel, :scheduled_expiry_assignment_unavailable} =
               perform_scheduled_job(Ecto.UUID.generate(), identity.id)

      assert FakeUpstream.requests(fake) == []
    end

    test "scheduled trigger with missing or invalid expected identity cancels without manual fallback" do
      %{fake: fake, assignment: assignment} = scheduled_expiry_fixture()

      for args <- [
            %{
              "pool_upstream_assignment_id" => assignment.id,
              "trigger_kind" => "scheduled_expiry_rescue"
            },
            %{
              "pool_upstream_assignment_id" => assignment.id,
              "trigger_kind" => "scheduled_expiry_rescue",
              "upstream_identity_id" => ""
            }
          ] do
        assert {:cancel, :scheduled_expiry_target_invalid} =
                 perform_job(SavedResetRedemptionWorker, args)
      end

      assert {:cancel, :scheduled_expiry_identity_unavailable} =
               perform_scheduled_job(assignment.id, "not-a-uuid")

      assert FakeUpstream.requests(fake) == []
    end

    test "returns a sanitized retryable provider failure" do
      raw_body = "provider-body-must-not-leak"
      raw_token = "provider-token-must-not-leak"

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          consume_response: {502, %{"code" => raw_token, "detail" => raw_body}}
        )

      result = perform_scheduled_job(assignment.id, identity.id)

      assert {:error, "saved reset redemption failed"} = result
      refute inspect(result) =~ raw_body
      refute inspect(result) =~ raw_token

      assert [%{method: "POST", path: "/api/codex/rate-limit-reset-credits/consume"}] =
               FakeUpstream.requests(fake)
    end
  end

  defp perform_scheduled_job(assignment_id, identity_id) do
    perform_job(SavedResetRedemptionWorker, %{
      "pool_upstream_assignment_id" => assignment_id,
      "upstream_identity_id" => identity_id,
      "target_kind" => "upstream_identity",
      "trigger_kind" => "scheduled_expiry_rescue"
    })
  end

  defp codex_reset_fake(opts \\ []) do
    FakeUpstream.start_link(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" =>
           Keyword.get(opts, :consume_response, {200, %{"code" => "reset"}}),
         "/api/codex/usage" => Keyword.get(opts, :usage_response, {200, usage_payload(0)})
       }}
    )
  end

  defp scheduled_expiry_fixture(opts \\ []) do
    as_of =
      Keyword.get_lazy(opts, :as_of, fn ->
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      end)

    {:ok, fake} = codex_reset_fake(opts)

    %{identity: identity, assignment: assignment} =
      assignment_with_fake(fake, 1,
        saved_resets: scheduled_saved_resets(as_of),
        redemption: Keyword.get(opts, :redemption)
      )

    identity =
      if Keyword.get(opts, :policy_enabled?, true) do
        update_identity!(identity, %{
          saved_reset_auto_redeem_enabled: true,
          saved_reset_auto_redeem_min_blocked_minutes: 60,
          saved_reset_auto_redeem_keep_credits: 0
        })
      else
        identity
      end

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_quota_attrs(as_of)
             ])

    %{as_of: as_of, fake: fake, identity: identity, assignment: assignment}
  end

  defp assignment_with_fake(fake, available_count, opts \\ []) do
    saved_resets =
      Keyword.get(opts, :saved_resets, %{
        "status" => Keyword.get(opts, :saved_reset_status, "reported"),
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      })

    metadata = %{
      "usage_base_url" => FakeUpstream.url(fake),
      "saved_resets" => saved_resets
    }

    metadata =
      case Keyword.get(opts, :redemption) do
        nil -> metadata
        redemption -> Map.put(metadata, "saved_reset_redemption", redemption)
      end

    active_upstream_assignment_fixture(pool_fixture(), %{metadata: metadata})
  end

  defp redemption_metadata(started_at, trigger_kind \\ "admin_manual") do
    %{
      "status" => "redeeming",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => trigger_kind,
      "started_at" => started_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "finished_at" => nil,
      "result" => nil
    }
  end

  defp stale_consuming_redemption(started_at, attempt_id, generation, opts \\ []) do
    %{
      "status" => "redeeming",
      "phase" => "consuming",
      "attempt_id" => attempt_id,
      "generation" => generation,
      "trigger_kind" => "scheduled_expiry_rescue",
      "started_at" => started_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "finished_at" => nil,
      "result" => nil,
      "provider_replay" =>
        %{
          "version" => 1,
          "provider_dispatches" => 1,
          "mode" => "replay"
        }
        |> maybe_put_next_action_at(Keyword.get(opts, :next_action_at))
    }
  end

  defp maybe_put_next_action_at(replay, nil), do: replay

  defp maybe_put_next_action_at(replay, next_action_at),
    do: Map.put(replay, "next_action_at", next_action_at)

  defp scheduled_saved_resets(as_of) do
    observed_at = DateTime.to_iso8601(as_of)
    expires_at = as_of |> DateTime.add(1, :hour) |> DateTime.to_iso8601()

    %{
      "status" => "reported",
      "available_count" => 1,
      "source" => "codex_usage_api",
      "path_style" => "codex_api",
      "observed_at" => observed_at,
      "usage_path" => "/api/codex/usage",
      "available_expires_at" => [expires_at],
      "available_expirations" => [
        %{"expires_at" => expires_at, "first_seen_at" => observed_at}
      ],
      "next_expires_at" => expires_at,
      "expires_observed_at" => observed_at,
      "expires_refresh_attempted_at" => observed_at,
      "reason" => nil
    }
  end

  defp weekly_quota_attrs(as_of) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("25"),
      reset_at: DateTime.add(as_of, 2, :hour),
      observed_at: as_of,
      last_sync_at: as_of,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
  end

  defp update_identity!(%UpstreamIdentity{} = identity, attrs) do
    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update!()
  end

  defp update_assignment!(%PoolUpstreamAssignment{} = assignment, attrs) do
    assignment
    |> PoolUpstreamAssignment.changeset(attrs)
    |> Repo.update!()
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
