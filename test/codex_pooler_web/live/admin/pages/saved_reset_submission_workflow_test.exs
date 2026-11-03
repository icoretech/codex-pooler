defmodule CodexPoolerWeb.Admin.SavedResetSubmissionWorkflowTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.SavedResets.CreditLocator
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @worker "CodexPooler.Jobs.SavedResetRedemptionWorker"
  @confirmation_copy "Redeem one saved reset for this account? The provider may apply it before quota checks finish. Verification can take a few minutes. You can leave this view and return to check the status."

  setup :register_and_log_in_user

  setup %{scope: scope} do
    pool = pool_fixture(%{created_by_user_id: scope.user.id})
    now = DateTime.utc_now()
    {:ok, fake} = FakeUpstream.start_link({:json_response, 500, %{"error" => "sample-private-provider-response"}})
    on_exit(fn -> FakeUpstream.stop(fake) end)

    fixture =
      active_upstream_assignment_fixture(pool,
        account_label: "Sample saved reset account",
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :hour)),
          "token_refresh" => %{"status" => "succeeded", "finished_at" => DateTime.to_iso8601(now)},
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "observed_at" => DateTime.to_iso8601(now),
            "source" => "codex_usage_api",
            "available_expirations" => [
              %{"expires_at" => DateTime.to_iso8601(DateTime.add(now, 7, :day)), "first_seen_at" => DateTime.to_iso8601(now)}
            ]
          }
        }
      )

    assert {:ok, _} = QuotaWindows.record_evidence(fixture.identity, %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, used_percent: Decimal.new("100"), reset_at: DateTime.add(now, 5, :day), observed_at: now, last_sync_at: now, source: "codex_usage_api", source_precision: "observed", freshness_state: "fresh"}, now)

    Map.merge(fixture, %{pool: pool, fake: fake})
  end

  for surface <- [:bank, :cockpit] do
    @surface surface

    test "#{surface} a later exhausted cycle permits one manual request without rewriting the expired receipt", context do
      %{conn: conn, assignment: assignment, pool: pool} = context
      {identity, original} = historical_redemption(context.identity)
      view = mount_surface(conn, identity.id, @surface)
      params = %{"id" => identity.id, "pool-id" => pool.id}

      assert has_element?(view, redeem_control(@surface, identity.id) <> ":not([disabled])")
      assert has_element?(view, heading(@surface, identity.id), "Quota confirmation timed out")
      capture_html(@surface, "later-cycle-ready", render(view))
      render_click(view, "open_saved_reset_redemption_confirmation", params)
      assert has_element?(view, confirmation(@surface), @confirmation_copy)
      view |> element(confirm(@surface)) |> render_click()

      assert [job] = jobs(assignment.id)
      assert job.args["trigger_kind"] == "admin_manual"
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == original
      assert Repo.reload!(identity).metadata["saved_resets"]["available_count"] == 2
      assert has_element?(view, heading(@surface, identity.id), "Request accepted")
      render_click(view, "redeem_saved_reset", params)
      assert [same_job] = jobs(assignment.id)
      assert same_job.id == job.id
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == original
      capture_html(@surface, "later-cycle-queued", render(view))
      finish_scenario(context.fake, @surface, "later-cycle", %{jobs: 1, repeated_jobs: 1, historical_receipt_unchanged?: true, available_count: 2})
    end

    for blocker <- [:floating, :no_anchor, :same_cycle, :inflight, :ambiguous, :old_credentials, :old_window_epoch] do
      @blocker blocker

      test "#{surface} historical receipt with #{blocker} evidence keeps manual redemption disabled", context do
        {identity, _original} = historical_redemption(context.identity, @blocker)
        view = mount_surface(context.conn, identity.id, @surface)
        assert has_element?(view, redeem_control(@surface, identity.id) <> "[disabled]")
        render_click(view, "open_saved_reset_redemption_confirmation", %{"id" => identity.id, "pool-id" => context.pool.id})
        refute has_element?(view, confirmation(@surface))
        assert jobs(context.assignment.id) == []
        finish_scenario(context.fake, @surface, "historical-#{@blocker}", %{jobs: 0, manual_disabled?: true})
      end
    end

    for {locale, message} <- [
          {"en", "Quota details are unavailable. No reset was spent. Wait for the next quota check and try again."},
          {"zh-CN", "配额详情暂不可用。未消耗任何已保存的重置。请等待下次配额检查后重试。"}
        ] do
      @locale locale
      @message message

      test "#{surface} #{@locale} missing quota details refuses redemption with a clear next step", context do
        %{conn: conn, identity: identity, assignment: assignment, pool: pool} = context
        Repo.delete_all(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id)
        view = mount_surface(put_locale(conn, @locale), identity.id, @surface)
        render_click(view, "open_saved_reset_redemption_confirmation", %{"id" => identity.id, "pool-id" => pool.id})
        view |> element(confirm(@surface)) |> render_click()

        assert has_element?(view, "#flash-error", @message)
        assert jobs(assignment.id) == []
        current = Repo.get!(UpstreamIdentity, identity.id)
        assert current.metadata["saved_resets"]["available_count"] == 1
        refute current.metadata["saved_reset_redemption"]
        finish_scenario(context.fake, @surface, "missing-quota-#{@locale}", %{jobs: 0, available_count: 1, redemption_absent?: true, localized_error?: true})
      end
    end

    test "#{surface} confirmation enqueues one request and duplicate/remount resumes persisted status", context do
      %{conn: conn, identity: identity, assignment: assignment, pool: pool} = context
      view = mount_surface(conn, identity.id, @surface)
      params = %{"id" => identity.id, "pool-id" => pool.id}

      render_click(view, "redeem_saved_reset", params)
      assert jobs(assignment.id) == []

      render_click(view, "open_saved_reset_redemption_confirmation", params)
      assert has_element?(view, confirmation(@surface), @confirmation_copy)
      assert has_element?(view, confirm(@surface) <> "[phx-disable-with='Requesting...']", "Redeem one reset")
      capture_html(@surface, "confirmation", render(view))

      view |> element(confirm(@surface)) |> render_click()
      assert [job] = jobs(assignment.id)
      assert job.args["manual_request_target"] == %{"upstream_identity_id" => identity.id, "pool_id" => pool.id}
      assert job.args["trigger_kind"] == "admin_manual"
      assert has_element?(view, heading(@surface, identity.id), "Request accepted")
      assert has_element?(view, receipt(@surface, identity.id) <> " [data-role='saved-reset-request']", "Queued. Nothing has been sent to the provider yet.")
      refute has_element?(view, receipt(@surface, identity.id) <> " [data-role='saved-reset-latest']")
      refute has_element?(view, confirmation(@surface))
      capture_html(@surface, "queued", render(view))

      render_click(view, "redeem_saved_reset", params)
      assert [same_job] = jobs(assignment.id)
      assert same_job.id == job.id
      assert Phoenix.Flash.get(:sys.get_state(view.pid).socket.assigns.flash, :error) == nil
      assert has_element?(view, heading(@surface, identity.id), "Request accepted")

      Process.unlink(view.pid)
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
      remounted = mount_surface(conn, identity.id, @surface)
      assert has_element?(remounted, heading(@surface, identity.id), "Request accepted")
      refute has_element?(remounted, receipt(@surface, identity.id) <> " [data-role='saved-reset-latest']")
      assert [retained_job] = jobs(assignment.id)
      assert retained_job.id == job.id
      capture_html(@surface, "remount", render(remounted))
      finish_scenario(context.fake, @surface, "one-request", %{unconfirmed_jobs: 0, confirmed_jobs: 1, repeated_jobs: 1, remounted_jobs: 1, target_binding_matches?: true})
    end

    test "#{surface} cancel and stale target retain policy without enqueue", context do
      %{conn: conn, identity: identity, assignment: assignment, pool: pool} = context
      view = mount_surface(conn, identity.id, @surface)
      draft = %{"auto_redeem_enabled" => "true", "trigger_mode" => "threshold", "quota_threshold_percent" => "87", "min_blocked_minutes" => "31", "keep_credits" => "1"}
      view |> element("#saved-reset-policy-form") |> render_change(%{"saved_reset_policy" => draft})
      params = %{"id" => identity.id, "pool-id" => pool.id}
      render_click(view, "open_saved_reset_redemption_confirmation", params)
      view |> element(cancel(@surface)) |> render_click()
      refute has_element?(view, confirmation(@surface))
      assert has_element?(view, "#saved-reset-policy-min-blocked-minutes[value='31']")
      refute Repo.get!(UpstreamIdentity, identity.id).saved_reset_auto_redeem_enabled
      assert jobs(assignment.id) == []

      render_click(view, "open_saved_reset_redemption_confirmation", params)
      render_click(view, "redeem_saved_reset", %{"id" => Ecto.UUID.generate(), "pool-id" => pool.id})
      assert jobs(assignment.id) == []
      assert has_element?(view, "#saved-reset-policy-min-blocked-minutes[value='31']")

      current = Repo.get!(UpstreamIdentity, identity.id)
      metadata = put_in(current.metadata, ["saved_resets", "available_count"], 0)
      current |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
      render_click(view, "redeem_saved_reset", params)
      assert jobs(assignment.id) == []
      assert has_element?(view, confirm(@surface) <> "[disabled]")
      assert has_element?(view, "#saved-reset-policy-min-blocked-minutes[value='31']")
      capture_html(@surface, "stale", render(view))
      finish_scenario(context.fake, @surface, "stale", %{jobs: 0, dirty_form_retained?: true, auto_policy_unchanged?: true})
    end

    test "#{surface} unknown provider outcome resumes status without another redemption", context do
      %{conn: conn, identity: identity, assignment: assignment, pool: pool} = context
      sentinel = "sample-private-provider-result"
      current = Repo.get!(UpstreamIdentity, identity.id)

      redemption = %{
        "status" => "redeeming",
        "phase" => "consuming",
        "started_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -10, :minute)),
        "result" => %{"applied" => true, "code" => sentinel, "body" => sentinel},
        "attempt_id" => Ecto.UUID.generate()
      }

      current |> Ecto.Changeset.change(metadata: Map.put(current.metadata, "saved_reset_redemption", redemption)) |> Repo.update!()
      view = mount_surface(conn, identity.id, @surface)
      params = %{"id" => identity.id, "pool-id" => pool.id}
      render_click(view, "open_saved_reset_redemption_confirmation", params)
      refute has_element?(view, confirmation(@surface))
      render_click(view, "redeem_saved_reset", params)
      assert jobs(assignment.id) == []
      assert has_element?(view, receipt(@surface, identity.id) <> "[data-provider-outcome='unknown']")
      assert has_element?(view, heading(@surface, identity.id), "Reset outcome not confirmed")
      assert has_element?(view, receipt(@surface, identity.id), "Don't redeem again until this resolves.")
      refute render(view) =~ sentinel
      refute render(view) =~ redemption["attempt_id"]
      capture_html(@surface, "unknown", render(view))

      # Pausing live updates replaces the receipt's summary, so the warning has to stay visible as its caveat line.
      render_hook(view, "set_live_updates", %{"paused" => true})
      assert has_element?(view, receipt(@surface, identity.id) <> " [data-role='saved-reset-headline']", "Live updates paused")
      assert has_element?(view, receipt(@surface, identity.id) <> " [data-role='saved-reset-provider-outcome']", "Don't redeem again until this resolves.")
      assert has_element?(view, heading(@surface, identity.id), "Reset outcome not confirmed")
      finish_scenario(context.fake, @surface, "unknown", %{jobs: 0, provider_outcome: :unknown, private_result_absent?: true})
    end

    test "#{surface} a status that holds Redeem back names the reason on the control", context do
      %{identity: identity, assignment: assignment} = context
      now = DateTime.utc_now()

      # The provisional recovery is still in progress; the malformed replay leaves the outcome unresolved.
      # The claim itself would accept both, so only the recorded status holds the action back.
      for {record, reason} <- [
            {%{"status" => "succeeded", "phase" => "confirmed_by_upstream", "generation" => 1, "started_at" => DateTime.to_iso8601(DateTime.add(now, -3, :minute)), "consumed_at" => DateTime.to_iso8601(DateTime.add(now, -2, :minute)), "deadline_at" => DateTime.to_iso8601(DateTime.add(now, 13, :minute)), "result" => %{"applied" => true, "code" => "reset"}}, "the last saved reset is still in progress"},
            {%{"status" => "failed", "phase" => "consume_not_applied", "generation" => 1, "result" => %{"applied" => false, "code" => "consume_not_applied"}, "provider_replay" => %{"version" => 1, "provider_dispatches" => 1}}, "the last saved reset is unresolved; another redemption waits until it resolves"}
          ] do
        current = Repo.get!(UpstreamIdentity, identity.id)
        current |> Ecto.Changeset.change(metadata: Map.put(current.metadata, "saved_reset_redemption", record)) |> Repo.update!()
        view = mount_surface(context.conn, identity.id, @surface)
        assert has_element?(view, redeem_control(@surface, identity.id) <> "[disabled][data-server-disabled='true']")
        assert has_element?(view, redeem_control(@surface, identity.id) <> "[title='#{reason}']")
        refute has_element?(view, "#saved-reset-redemption-unavailable-reason")
        assert jobs(assignment.id) == []
      end

      finish_scenario(context.fake, @surface, "held-reason", %{jobs: 0})
    end

    for {code, headline} <- [{"no_credit", "No saved reset was available"}, {"nothing_to_reset", "Nothing needed resetting"}] do
      @noop_code code
      @noop_headline headline

      test "#{surface} #{@noop_code} renders a recorded no-op without a consumed claim", context do
        %{identity: identity, assignment: assignment} = context
        current = Repo.get!(UpstreamIdentity, identity.id)
        redemption = %{"status" => "noop", "result" => %{"code" => @noop_code, "applied" => false, "body" => "sample-private-noop-body"}}
        current |> Ecto.Changeset.change(metadata: Map.put(current.metadata, "saved_reset_redemption", redemption)) |> Repo.update!()
        view = mount_surface(context.conn, identity.id, @surface)
        assert has_element?(view, receipt(@surface, identity.id) <> "[data-provider-outcome='not_applied']")
        assert has_element?(view, heading(@surface, identity.id), @noop_headline)
        refute has_element?(view, receipt(@surface, identity.id) <> " [data-role='saved-reset-consumed-at']")
        assert jobs(assignment.id) == []
        assert Repo.get!(UpstreamIdentity, identity.id).metadata["saved_resets"]["available_count"] == 1
        refute render(view) =~ "sample-private-noop-body"
        capture_html(@surface, @noop_code, render(view))
        finish_scenario(context.fake, @surface, @noop_code, %{jobs: 0, provider_outcome: :not_applied, bank_unchanged?: true, private_result_absent?: true})
      end
    end
  end

  # The cockpit sends the Pool id from the page; the scoped enqueue accepts it only when the account holds a live
  # assignment there and the viewer may operate every Pool the account is assigned to.
  test "cockpit refuses a Pool id the account has no live assignment in", context do
    %{conn: conn, identity: identity, assignment: assignment, scope: scope} = context
    other_pool = pool_fixture(%{created_by_user_id: scope.user.id})
    view = mount_surface(conn, identity.id, :cockpit)
    render_click(view, "open_saved_reset_redemption_confirmation", %{"id" => identity.id, "pool-id" => other_pool.id})
    view |> element(confirm(:cockpit)) |> render_click()
    assert jobs(assignment.id) == []
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^@worker), :count) == 0
    assert Phoenix.Flash.get(:sys.get_state(view.pid).socket.assigns.flash, :error) =~ "Saved reset request was not accepted"
    finish_scenario(context.fake, :cockpit, "forged-pool", %{jobs: 0})
  end

  defp mount_surface(conn, identity_id, :bank) do
    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    render_click(view, "open_saved_reset_policy", %{"id" => identity_id})
    view
  end

  defp mount_surface(conn, identity_id, :cockpit) do
    {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity_id}")
    view
  end

  defp jobs(assignment_id) do
    Repo.all(from job in Oban.Job, where: job.worker == ^@worker and fragment("?->>'pool_upstream_assignment_id'", job.args) == ^assignment_id)
  end

  defp historical_redemption(identity, blocker \\ nil) do
    now = DateTime.utc_now()
    consumed_at = DateTime.add(now, -2, :day)

    record = %{
      "phase" => "expired",
      "status" => "failed",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 3,
      "included_window_descriptors" => [],
      "started_at" => DateTime.to_iso8601(DateTime.add(consumed_at, -1, :second)),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => DateTime.to_iso8601(DateTime.add(consumed_at, 15, :minute)),
      "finished_at" => DateTime.to_iso8601(DateTime.add(consumed_at, 16, :minute)),
      "result" => %{"code" => "reset", "applied" => true},
      "provider_replay" => %{"version" => 1, "provider_dispatches" => 1, "endpoint_family" => "chatgpt_api", "scope_fingerprint" => CreditLocator.scope_fingerprint("chatgpt_api", identity.metadata["usage_base_url"] <> "/backend-api/wham/rate-limit-reset-credits/consume", identity.chatgpt_account_id || "")}
    }

    record =
      case blocker do
        :inflight -> Map.merge(record, %{"phase" => "consuming", "status" => "redeeming", "started_at" => DateTime.to_iso8601(now)})
        :ambiguous -> Map.delete(record, "result")
        _other -> record
      end

    metadata = identity.metadata |> Map.put("credential_epoch", 15) |> Map.put("saved_reset_redemption", record) |> put_in(["saved_resets", "available_count"], 2) |> put_in(["saved_resets", "path_style"], "chatgpt_api") |> put_in(["saved_resets", "usage_path"], "/backend-api/wham/usage")
    identity = identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
    Repo.delete_all(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id)
    reset_at = DateTime.add(now, if(blocker == :same_cycle, do: 4, else: 6), :day)

    for offset <- [-600, -400, -200] do
      at = DateTime.add(now, offset, :second)
      assert {:ok, _} = QuotaWindows.record_evidence(identity, %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, used_percent: Decimal.new(100), reset_at: reset_at, observed_at: at, last_sync_at: at, source: "codex_usage_api", source_precision: "observed", freshness_state: "fresh", metadata: %{"credential_epoch" => 15, "reset_after_seconds" => DateTime.diff(reset_at, at)}}, at)
    end

    [window] = QuotaWindows.list_evidence(identity)
    assert CycleConfirmation.selector_valid?(window, DateTime.utc_now())

    window |> Ecto.Changeset.change(metadata: historical_window_metadata(window.metadata, blocker)) |> Repo.update!()
    identity = if blocker == :old_credentials, do: identity |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "credential_epoch", 16)) |> Repo.update!(), else: identity
    {identity, record}
  end

  defp historical_window_metadata(metadata, :floating), do: Map.put(metadata, "reset_state", "floating")
  defp historical_window_metadata(metadata, :no_anchor), do: Map.delete(metadata, "__quota_cycle_confirmation_v1")
  defp historical_window_metadata(metadata, :old_window_epoch), do: Map.put(metadata, "credential_epoch", 14)
  defp historical_window_metadata(metadata, _blocker), do: metadata

  defp redeem_control(:bank, _identity_id), do: "#saved-reset-redemption-action"
  defp redeem_control(:cockpit, identity_id), do: "#cockpit-redeem-saved-reset-upstream-account-#{identity_id}"

  defp confirmation(:bank), do: "#saved-reset-redemption-confirmation"
  defp confirmation(:cockpit), do: "#cockpit-saved-reset-redemption-confirmation"
  defp confirm(surface), do: confirmation(surface) |> String.replace("-confirmation", "-confirm")
  defp cancel(surface), do: confirmation(surface) |> String.replace("-confirmation", "-cancel")
  defp receipt(surface, identity_id), do: "#saved-reset-operation-#{surface}-#{identity_id}"
  # The disclosure summary: the receipt's only heading, carrying its headline.
  defp heading(surface, identity_id), do: "#saved-reset-operation-heading-#{surface}-#{identity_id}"

  defp capture_html(surface, scenario, html) do
    case System.get_env("SAVED_RESET_SUBMISSION_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        File.mkdir_p!(directory)
        operations = html |> LazyHTML.from_document() |> LazyHTML.query("[data-role='saved-reset-operation']")
        facts = %{provider_outcomes: LazyHTML.attribute(operations, "data-provider-outcome"), verification_states: LazyHTML.attribute(operations, "data-verification-state")}
        File.write!(Path.join(directory, "#{surface}-#{scenario}-render.json"), Jason.encode!(facts, pretty: true))
    end
  end

  defp finish_scenario(fake, surface, scenario, facts) do
    assert FakeUpstream.requests(fake) == []
    counts = FakeUpstream.physical_counts(fake)
    assert Enum.all?(Map.values(counts), &(&1 == 0))
    assert :ok = FakeUpstream.stop(fake)
    refute Process.alive?(fake.pid)
    refute Process.alive?(fake.server)
    refute Process.alive?(fake.supervisor)

    case System.get_env("SAVED_RESET_SUBMISSION_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "#{surface}-#{scenario}.json"), Jason.encode!(Map.merge(facts, %{physical_counts: counts, owned_fake_stopped?: true}), pretty: true))
    end
  end
end
