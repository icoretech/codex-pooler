defmodule CodexPooler.Upstreams.SavedResets.ResetResourceBindingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.{FakeUpstream, ProviderCreditsFixtures, Repo}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.{Convergence, RedemptionLifecycle}

  for {resource, kind, minutes} <- [{:weekly, "secondary", 10_080}, {:monthly, "primary", 43_200}] do
    @tag :credits_negative
    test "a fresh runtime #{resource} report cannot erase the Usage API resource captured before consume" do
      fixture = reset_fixture!(unquote(resource), :applied)
      usage_window = usage_window!(fixture.identity)
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, _runtime} =
               Windows.record_evidence(
                 fixture.identity,
                 quota_attrs(usage_window)
                 |> Map.merge(%{
                   source: "codex_rate_limit_event",
                   observed_at: observed_at,
                   last_sync_at: observed_at,
                   metadata: %{}
                 }),
                 observed_at
               )

      assert [%{source: "codex_rate_limit_event"}] = Windows.list_quota_windows(fixture.identity, observed_at)

      assert {:ok, %{applied?: true, phase: "consumed_pending_probe"}} =
               SavedResetRedemption.redeem(fixture.assignment)

      pending = redemption(fixture.identity)
      expected = [%{"window_kind" => unquote(kind), "window_minutes" => unquote(minutes)}]
      assert pending["included_window_descriptors"] == expected
      prove_matching_resource_convergence!(fixture, pending, expected)
    end
  end

  @tag :credits_negative
  test "missing or unqualified long-window evidence cannot spend a reset or create a claim" do
    for invalid <- [:missing, :short_only, :inferred, :wrong_family, :wrong_slot] do
      fixture = reset_fixture!(:weekly, :applied)
      window = usage_window!(fixture.identity)

      case invalid do
        :missing -> Repo.delete!(window)
        :short_only -> window |> change(window_kind: "primary", window_minutes: 300) |> Repo.update!()
        :inferred -> window |> change(source_precision: "inferred") |> Repo.update!()
        :wrong_family -> window |> change(quota_family: "additional") |> Repo.update!()
        :wrong_slot -> window |> change(window_kind: "secondary", window_minutes: 43_200) |> Repo.update!()
      end

      assert {:error, %{code: :saved_reset_confirmation_unavailable}} =
               SavedResetRedemption.ensure_manual_available(fixture.assignment)

      assert {:error, %{code: :saved_reset_confirmation_unavailable}} =
               SavedResetRedemption.redeem(fixture.assignment)

      refute redemption(fixture.identity)
      assert FakeUpstream.physical_counts(fixture.fake).consume == 0
      assert FakeUpstream.physical_counts(fixture.fake).http_generation == 0
      assert FakeUpstream.physical_counts(fixture.fake).websocket_generation == 0
    end
  end

  for {label, descriptors} <- [
        {"empty", []},
        {"missing", nil},
        {"malformed", [%{"window_kind" => "secondary", "window_minutes" => 10_080, "extra" => true}]},
        {"replaced", [%{"window_kind" => "primary", "window_minutes" => 43_200}]}
      ] do
    @tag :credits_negative
    test "a #{label} captured binding discovered at dispatch cannot spend a reset" do
      fixture = reset_fixture!(:weekly, :applied)
      release_ref = make_ref()

      FakeUpstream.set_mode(
        fixture.fake,
        {:path_json,
         ProviderCreditsFixtures.usage_routes(omitted_usage())
         |> Map.put(
           "/backend-api/wham/rate-limit-reset-credits",
           FakeUpstream.gated_json_headers(
             %{"available_count" => 1, "credits" => [%{"id" => "synthetic-resource-reset", "status" => "available"}]},
             notify: self(),
             release_ref: release_ref
           )
         )
         |> Map.put("/backend-api/wham/rate-limit-reset-credits/consume", {200, %{"code" => "reset"}})}
      )

      task = Task.async(fn -> SavedResetRedemption.redeem(fixture.assignment) end)
      assert_receive {:fake_upstream_gate, :before_headers, gate_pid, ^release_ref}, 15_000

      try do
        identity = Repo.reload!(fixture.identity)
        captured = identity.metadata["saved_reset_redemption"]
        assert captured["included_window_descriptors"] == [%{"window_kind" => "secondary", "window_minutes" => 10_080}]
        changed = put_in(identity.metadata, ["saved_reset_redemption", "included_window_descriptors"], unquote(Macro.escape(descriptors)))
        identity |> change(metadata: changed) |> Repo.update!()
      after
        send(gate_pid, {:fake_upstream_release_gate, release_ref})
      end

      assert {:ok, %{status: :noop, applied?: false, code: "saved_reset_confirmation_unavailable"}} = Task.await(task, 15_000)
      settled = redemption(fixture.identity)
      assert settled["phase"] == "consume_not_applied"
      assert settled["included_window_descriptors"] == unquote(Macro.escape(descriptors))
      assert settled["provider_replay"]["provider_dispatches"] == 0
      assert FakeUpstream.physical_counts(fixture.fake).consume == 0
    end
  end

  @tag :credits_negative
  test "ambiguous recovery never backfills an invalid original binding or sends another consume" do
    fixture = reset_fixture!(:weekly, :ambiguous)
    assert {:error, :saved_reset_consume_outcome_ambiguous} = SavedResetRedemption.redeem(fixture.assignment)
    identity = Repo.reload!(fixture.identity)
    consuming = identity.metadata["saved_reset_redemption"]
    metadata = put_in(identity.metadata, ["saved_reset_redemption", "included_window_descriptors"], [])
    identity |> change(metadata: metadata) |> Repo.update!()

    FakeUpstream.set_mode(
      fixture.fake,
      {:path_json,
       ProviderCreditsFixtures.usage_routes(omitted_usage())
       |> Map.put("/backend-api/wham/rate-limit-reset-credits", {200, %{"available_count" => 1, "credits" => [%{"id" => "synthetic-resource-reset", "status" => "available"}]}})
       |> Map.put("/backend-api/wham/rate-limit-reset-credits/consume", {200, %{"code" => "reset"}})}
    )

    recovery_at = DateTime.add(DateTime.utc_now(), 90, :second)

    assert {:ok, %{status: :noop, code: "recovery_target_invalid"}} =
             SavedResetRedemption.resume_stale_consuming(
               fixture.assignment,
               fixture.identity.id,
               consuming["attempt_id"],
               consuming["generation"],
               now: recovery_at,
               clock: fn -> recovery_at end,
               receive_timeout: 1_000
             )

    retained = redemption(fixture.identity)
    assert retained["phase"] == "consuming"
    assert retained["included_window_descriptors"] == []
    assert retained["provider_replay"]["provider_dispatches"] == 1
    assert Map.take(retained, ["attempt_id", "generation"]) == Map.take(consuming, ["attempt_id", "generation"])
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
  end

  for {resource, kind, minutes} <- [{:weekly, "secondary", 10_080}, {:monthly, "primary", 43_200}] do
    @tag :credits_negative
    test "an applied #{resource} consume stays pending for unrelated 5h evidence and confirms its captured resource" do
      fixture = reset_fixture!(unquote(resource), :applied)
      expected = [%{"window_kind" => unquote(kind), "window_minutes" => unquote(minutes)}]

      assert {:ok, %{applied?: true, phase: "consumed_pending_probe"}} =
               SavedResetRedemption.redeem(fixture.assignment)

      pending = redemption(fixture.identity)
      assert pending["included_window_descriptors"] == expected
      assert pending["result"]["applied"] == true
      assert RedemptionLifecycle.gateway_auto_latch(pending, DateTime.utc_now()) == :blocked_awaiting_quota

      prove_matching_resource_convergence!(fixture, pending, expected)
    end
  end

  @tag :credits_negative
  test "an actual ambiguous consume recovered from the same redeemed bank item keeps its original weekly binding" do
    fixture = reset_fixture!(:weekly, :ambiguous)

    assert {:error, :saved_reset_consume_outcome_ambiguous} = SavedResetRedemption.redeem(fixture.assignment)
    consuming = redemption(fixture.identity)
    expected = [%{"window_kind" => "secondary", "window_minutes" => 10_080}]
    assert consuming["phase"] == "consuming"
    assert consuming["included_window_descriptors"] == expected

    recovery_at = DateTime.add(DateTime.utc_now(), 90, :second)

    FakeUpstream.set_mode(
      fixture.fake,
      {:path_json,
       ProviderCreditsFixtures.usage_routes(omitted_usage())
       |> Map.put(
         "/backend-api/wham/rate-limit-reset-credits",
         {200,
          %{
            "available_count" => 0,
            "credits" => [%{"id" => "synthetic-resource-reset", "status" => "redeemed", "redeemed_at" => consuming["provider_replay"]["last_provider_dispatched_at"]}]
          }}
       )}
    )

    assert {:ok, %{applied?: true, phase: "consumed_pending_probe"}} =
             SavedResetRedemption.resume_stale_consuming(
               fixture.assignment,
               fixture.identity.id,
               consuming["attempt_id"],
               consuming["generation"],
               now: recovery_at,
               clock: fn -> recovery_at end,
               receive_timeout: 1_000
             )

    pending = redemption(fixture.identity)
    assert pending["included_window_descriptors"] == expected
    assert Map.take(pending, ["attempt_id", "generation"]) == Map.take(consuming, ["attempt_id", "generation"])
    assert pending["provider_replay"]["provider_dispatches"] == 1

    prove_matching_resource_convergence!(fixture, pending, expected)
  end

  defp reset_fixture!(resource, outcome) do
    supervisor_name = String.to_atom("reset_resource_binding_#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn ->
      case Process.whereis(supervisor_name) do
        pid when is_pid(pid) -> FakeUpstream.stop(%FakeUpstream{supervisor: pid})
        nil -> :ok
      end
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    initial = usage(resource, false, now, 1)
    {:ok, fake} = FakeUpstream.start_link({:path_json, ProviderCreditsFixtures.usage_routes(initial)}, supervisor_name: supervisor_name)

    %{assignment: assignment, identity: identity} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "base_url" => FakeUpstream.url(fake),
          "usage_base_url" => FakeUpstream.url(fake),
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "source" => "codex_usage_api",
            "path_style" => "chatgpt_api",
            "usage_path" => "/backend-api/wham/usage",
            "observed_at" => DateTime.to_iso8601(now)
          }
        }
      })

    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment, observed_at: now)
    assert Enum.any?(Windows.list_evidence(identity), &(&1.window_minutes in [10_080, 43_200] and Decimal.equal?(&1.used_percent, 100)))

    consume = if outcome == :applied, do: {200, %{"code" => "reset"}}, else: :close_before_headers

    FakeUpstream.set_mode(
      fake,
      {:path_json,
       ProviderCreditsFixtures.usage_routes(omitted_usage())
       |> Map.put("/backend-api/wham/rate-limit-reset-credits", {200, %{"available_count" => 1, "credits" => [%{"id" => "synthetic-resource-reset", "status" => "available"}]}})
       |> Map.put("/backend-api/wham/rate-limit-reset-credits/consume", consume)}
    )

    %{fake: fake, identity: identity, assignment: assignment, resource: resource}
  end

  defp prove_matching_resource_convergence!(fixture, pending, expected) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    FakeUpstream.set_mode(fixture.fake, {:path_json, ProviderCreditsFixtures.usage_routes(usage(:short, true, observed_at, 0))})

    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(fixture.identity), fixture.assignment, observed_at: observed_at)
    assert {:ok, :unchanged} = Convergence.converge(identity, observed_at, "reconciliation")
    unrelated = redemption(identity)
    assert unrelated["phase"] == "consumed_pending_probe"
    assert unrelated["included_window_descriptors"] == expected

    assert Map.take(unrelated, ["attempt_id", "generation", "consumed_at", "result"]) ==
             Map.take(pending, ["attempt_id", "generation", "consumed_at", "result"])

    assert RedemptionLifecycle.gateway_auto_latch(unrelated, observed_at) == :blocked_awaiting_quota
    assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(fixture.assignment)

    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    FakeUpstream.set_mode(fixture.fake, {:path_json, ProviderCreditsFixtures.usage_routes(usage(fixture.resource, true, observed_at, 0))})

    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), fixture.assignment, observed_at: observed_at)
    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity, observed_at, "reconciliation")
    confirmed = redemption(identity)
    assert confirmed["phase"] == "confirmed_by_quota"
    assert confirmed["included_window_descriptors"] == expected

    assert Map.take(confirmed, ["attempt_id", "generation", "consumed_at", "result"]) ==
             Map.take(pending, ["attempt_id", "generation", "consumed_at", "result"])

    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
    assert FakeUpstream.physical_counts(fixture.fake).http_generation == 0
    assert FakeUpstream.physical_counts(fixture.fake).websocket_generation == 0
  end

  defp usage(resource, available?, now, reset_count) do
    state = if available?, do: :included, else: :weekly_credit_only
    # The restored long window reports a forward cycle, not a same-cycle lower snapshot that the evidence store must quarantine.
    reset_after = if available? and resource in [:weekly, :monthly], do: 14_400, else: 7_200

    ProviderCreditsFixtures.usage_payload(state, now: now, window: resource, credits: :none, reset_after: reset_after)
    |> Map.put("rate_limit_reset_credits", %{"available_count" => reset_count})
  end

  defp omitted_usage, do: %{"plan_type" => "synthetic", "rate_limit_reset_credits" => %{"available_count" => 0}}
  defp redemption(identity), do: Repo.reload!(identity).metadata["saved_reset_redemption"]

  defp usage_window!(identity) do
    Repo.one!(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id and window.source == "codex_usage_api")
  end

  defp quota_attrs(window) do
    Map.take(window, [:quota_key, :quota_scope, :quota_family, :window_kind, :window_minutes, :used_percent, :reset_at, :source_precision, :freshness_state])
  end
end
