defmodule CodexPoolerWeb.Admin.SavedResetCockpitReceiptTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  setup %{scope: scope} do
    now = DateTime.utc_now()
    pool = pool_fixture(%{created_by_user_id: scope.user.id})
    {:ok, fake} = FakeUpstream.start_link({:json_response, 500, %{"error" => "sample-private-provider-value"}})
    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Sample reset receipt account",
        identity_metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "base_url" => FakeUpstream.url(fake),
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 2,
            "observed_at" => DateTime.to_iso8601(now),
            "source" => "codex_usage_api",
            "available_expirations" => [%{"expires_at" => DateTime.to_iso8601(DateTime.add(now, 7, :day)), "first_seen_at" => DateTime.to_iso8601(now)}]
          }
        }
      })

    %{identity: identity, now: now, fake: fake}
  end

  for {state, outcome, verification, headline} <- [
        {:consuming, :unknown, :not_started, "Reset request in progress"},
        {:ambiguous, :unknown, :not_started, "Reset outcome not confirmed"},
        {:applied_pending, :applied, :pending, "Reset applied — verifying quota"},
        {:confirmed, :applied, :quota_confirmed, "Quota confirmed"},
        {:provisional, :applied, :request_verified, "Recovery verified by a request"},
        {:legacy, :unknown, :pending, "Reset outcome not confirmed"}
      ] do
    @state state
    @outcome outcome
    @verification verification
    @headline headline

    test "cockpit #{@state} uses the modern receipt and retains bank facts", context do
      %{identity: identity, now: now, conn: conn} = context
      metadata = Map.put(identity.metadata, "saved_reset_redemption", redemption(@state, now))
      identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
      html = render_async(view)
      capture_html!(@state, html)
      operation = "#saved-reset-operation-cockpit-#{identity.id}"

      assert has_element?(view, "#{operation}[data-provider-outcome='#{@outcome}'][data-verification-state='#{@verification}']")
      # The headline is read from the disclosure summary that labels the receipt; inside the section it only repeats in the screen-reader live region.
      assert has_element?(view, "#saved-reset-operation-heading-cockpit-#{identity.id}", @headline)
      assert has_element?(view, "#upstream-quota-saved-reset-meter-bar[aria-label='2 saved resets'][aria-valuenow='2']")
      refute has_element?(view, "#upstream-quota-saved-reset-meter-confirmation")
      refute has_element?(view, "#upstream-quota-saved-reset-meter [data-role='upstream-saved-reset-consumed-at']")
      refute has_element?(view, "#upstream-quota-saved-reset-meter [data-role='upstream-saved-reset-deadline']")
      assert has_element?(view, "#cockpit-saved-reset-expiration-row-0")
      assert has_element?(view, "#saved-reset-policy-form[data-saved-reset-form]")
      assert has_element?(view, "#saved-reset-policy-submit[data-saved-reset-action='save-policy']")

      if @outcome == :unknown do
        refute has_element?(view, "#{operation} [data-role='saved-reset-consumed-at']")
        refute has_element?(view, "#{operation} [data-role='saved-reset-deadline-at']")
      else
        assert has_element?(view, "#{operation} [data-role='saved-reset-consumed-at']")
        assert has_element?(view, "#{operation} [data-role='saved-reset-deadline-at']")
      end

      refute html =~ "sample-private-provider-value"
      record_evidence!(@state, context.fake)
    end
  end

  for {state, outcome} <- [consuming: :unknown, ambiguous: :unknown, applied_pending: :applied, confirmed: :applied, provisional: :applied, reblocked: :applied, expired: :applied, consume_not_applied: :not_applied, manual_replacement_not_applied: :not_applied, legacy: :unknown] do
    @state state
    @outcome outcome

    test "list #{@state} exposes the receipt through Banked Resets", context do
      %{identity: identity, now: now, conn: conn} = context
      identity |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "saved_reset_redemption", redemption(@state, now))) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
      html = render_async(view)
      capture_html!("list_#{@state}", html)
      meter = "#upstream-account-#{identity.id}-saved-reset-meter"
      operation = "#saved-reset-operation-list-#{identity.id}"

      assert has_element?(view, "#{meter}-bar[aria-label='2 saved resets'][aria-valuenow='2']")
      refute has_element?(view, "#{meter}-confirmation")
      refute has_element?(view, "#{meter} [data-role='upstream-saved-reset-consumed-at'], #{meter} [data-role='upstream-saved-reset-deadline']")
      refute has_element?(view, operation)
      refute has_element?(view, "#upstream-account-#{identity.id} [data-role='saved-reset-view-status']")
      refute render(element(view, meter)) =~ "Not reported"
      refute render(element(view, meter)) =~ "Reset consumed"

      view |> element("#{meter}-open[aria-haspopup='dialog']") |> render_click()
      assert has_element?(view, "#saved-reset-operation-bank-#{identity.id}[data-provider-outcome='#{@outcome}']")
      assert has_element?(view, "#saved-reset-expiration-row-0")
      assert has_element?(view, "#saved-reset-policy-form[data-saved-reset-form]")
      assert has_element?(view, "#saved-reset-operation-bank-#{identity.id} [data-role='saved-reset-consumed-at']") == (@outcome == :applied)
      refute html =~ "sample-private-provider-value"
      capture_html!("list_#{@state}_bank", render(view))
      record_evidence!("list_#{@state}", context.fake)
    end
  end

  defp redemption(:consuming, now), do: %{"status" => "redeeming", "phase" => "consuming", "started_at" => DateTime.to_iso8601(now)}

  defp redemption(:ambiguous, now) do
    %{"status" => "redeeming", "phase" => "consuming", "started_at" => DateTime.to_iso8601(DateTime.add(now, -5, :minute)), "result" => %{"applied" => true, "code" => "sample-private-provider-value"}}
  end

  defp redemption(:legacy, now), do: %{"phase" => "consumed_pending_probe", "started_at" => DateTime.to_iso8601(DateTime.add(now, -3, :minute))}

  defp redemption(:consume_not_applied, now) do
    %{"phase" => "consume_not_applied", "status" => "failed", "finished_at" => DateTime.to_iso8601(now), "result" => %{"code" => "consume_not_applied", "applied" => false}, "provider_replay" => %{"version" => 1, "provider_dispatches" => 0}}
  end

  defp redemption(:manual_replacement_not_applied, now) do
    %{"phase" => "manual_replacement_not_applied", "status" => "failed", "finished_at" => DateTime.to_iso8601(now), "result" => %{"code" => "no_credit", "applied" => false}}
  end

  defp redemption(state, now) do
    phase = %{reblocked: "reblocked", expired: "expired", applied_pending: "consumed_pending_probe", confirmed: "confirmed_by_quota", provisional: "confirmed_by_upstream"}[state]
    %{"status" => "succeeded", "phase" => phase, "started_at" => DateTime.to_iso8601(DateTime.add(now, -3, :minute)), "consumed_at" => DateTime.to_iso8601(DateTime.add(now, -2, :minute)), "deadline_at" => DateTime.to_iso8601(DateTime.add(now, 13, :minute)), "result" => %{"applied" => true, "code" => "reset"}}
  end

  defp record_evidence!(state, fake) do
    counts = FakeUpstream.physical_counts(fake)
    assert Enum.all?(Map.values(counts), &(&1 == 0))
    assert FakeUpstream.requests(fake) == []
    assert :ok = FakeUpstream.stop(fake)
    refute Process.alive?(fake.pid)
    refute Process.alive?(fake.server)
    refute Process.alive?(fake.supervisor)

    case System.get_env("SAVED_RESET_COCKPIT_RECEIPT_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "#{state}.json"), Jason.encode!(%{scenario: state, physical_counts: counts, owned_fake_stopped?: true}, pretty: true))
    end
  end

  defp capture_html!(state, html) do
    case System.get_env("SAVED_RESET_COCKPIT_RECEIPT_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "#{state}.html"), html)
    end
  end
end
