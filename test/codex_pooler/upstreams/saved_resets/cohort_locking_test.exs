defmodule CodexPooler.Upstreams.SavedResets.CohortLockingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "normalizes a gateway cohort into one ordered identity lock query" do
    {:ok, fake} = codex_reset_fake()
    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: target, assignment: assignment} = assignment_with_fake(fake)
    %{identity: sibling} = assignment_with_fake(fake)
    target = enable_auto_redeem!(target)
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upsert_weekly_exhausted_quota!(target, as_of)

    handler_id = {__MODULE__, System.unique_integer([:positive, :monotonic])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and metadata[:source] == "upstream_identities" and
               is_binary(metadata[:query]) and String.contains?(metadata[:query], "ANY(") and
               String.contains?(metadata[:query], "FOR UPDATE") do
            send(test_pid, {:cohort_lock, metadata[:query], metadata[:params]})
          end
        end,
        nil
      )

    try do
      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context:
                   gateway_context(assignment, target, [sibling.id, target.id, sibling.id]),
                 started_at: as_of
               )

      assert_receive {:cohort_lock, query, [locked_ids]}, 1_000
      assert query =~ ~r/ORDER BY .*\."id" FOR UPDATE/

      assert Enum.sort(Enum.map(locked_ids, &Ecto.UUID.load!/1)) ==
               Enum.sort([target.id, sibling.id])
    after
      :telemetry.detach(handler_id)
    end
  end

  test "rejects an incomplete normalized cohort before provider I/O" do
    {:ok, fake} = codex_reset_fake()
    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: target, assignment: assignment} = assignment_with_fake(fake)
    target = enable_auto_redeem!(target)
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upsert_weekly_exhausted_quota!(target, as_of)

    assert {:ok, %{status: :noop, code: "gateway_auto_context_mismatch"}} =
             SavedResetRedemption.redeem(assignment,
               trigger_kind: "gateway_auto",
               gateway_auto_context:
                 gateway_context(assignment, target, [target.id, Ecto.UUID.generate()]),
               started_at: as_of
             )

    assert [] = FakeUpstream.requests(fake)
  end

  test "blocks a gateway auto claim when a locked cohort sibling has an active consume fence" do
    {:ok, fake} = codex_reset_fake()
    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: target, assignment: assignment} = assignment_with_fake(fake)
    %{identity: sibling} = assignment_with_fake(fake)
    target = enable_auto_redeem!(target)
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upsert_weekly_exhausted_quota!(target, as_of)
    update_redemption!(sibling, applied_redemption(as_of))

    assert {:ok, %{status: :noop, code: "gateway_auto_sibling_consume_barrier"}} =
             SavedResetRedemption.redeem(assignment,
               trigger_kind: "gateway_auto",
               gateway_auto_context: gateway_context(assignment, target, [sibling.id, target.id]),
               started_at: as_of
             )

    assert [] = FakeUpstream.requests(fake)
  end

  defp codex_reset_fake do
    FakeUpstream.start_link(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" => {200, usage_payload()}
       }}
    )
  end

  defp assignment_with_fake(fake) do
    active_upstream_assignment_fixture(pool_fixture(), %{
      metadata: %{
        "usage_base_url" => FakeUpstream.url(fake),
        "saved_resets" => %{
          "status" => "reported",
          "available_count" => 1,
          "source" => "codex_usage_api",
          "path_style" => "codex_api",
          "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "usage_path" => "/api/codex/usage",
          "reason" => nil
        }
      }
    })
  end

  defp enable_auto_redeem!(identity) do
    identity
    |> UpstreamIdentity.changeset(%{
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0
    })
    |> Repo.update!()
  end

  defp update_redemption!(identity, redemption) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(identity.metadata, "saved_reset_redemption", redemption)
    })
    |> Repo.update!()
  end

  defp applied_redemption(as_of) do
    %{
      "status" => "succeeded",
      "phase" => "confirmed_by_quota",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => "gateway_auto",
      "started_at" => DateTime.to_iso8601(as_of),
      "consumed_at" => DateTime.to_iso8601(as_of),
      "finished_at" => DateTime.to_iso8601(as_of),
      "result" => %{"code" => "reset", "applied" => true}
    }
  end

  defp upsert_weekly_exhausted_quota!(identity, as_of) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(as_of, 1, :hour),
                 observed_at: as_of,
                 last_sync_at: as_of,
                 source: "codex_usage_api",
                 source_precision: "authoritative",
                 quota_scope: "account",
                 quota_family: "account"
               }
             ])
  end

  defp gateway_context(assignment, identity, cohort_identity_ids) do
    %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      candidate_assignment_ids: [assignment.id],
      candidate_identity_ids: [identity.id],
      cohort_identity_ids: cohort_identity_ids,
      routable_identity_ids: cohort_identity_ids,
      route_class: "proxy_http",
      quota_scope: %{
        requested_model: "test-model",
        catalog_model: "test-model",
        exposed_model_id: "test-model",
        upstream_model: "test-model",
        upstream_model_id: "test-model"
      },
      session_continuity?: false
    }
  end

  defp usage_payload do
    %{
      "rate_limit" => %{
        "primary_window" => %{"used_percent" => 0, "reset_after_seconds" => 900},
        "secondary_window" => %{"used_percent" => 0, "reset_after_seconds" => 604_800}
      }
    }
  end
end
