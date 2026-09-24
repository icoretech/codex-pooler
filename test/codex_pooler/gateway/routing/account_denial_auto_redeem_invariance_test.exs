defmodule CodexPooler.Gateway.Routing.AccountDenialAutoRedeemInvarianceTest do
  # The workspace-level account denial filter (findings#206 row 206-509) must
  # not move a single automatic saved-reset decision in either direction: a
  # consume spends a real banked reset in production. Each case below records
  # how many consume calls the fake provider receives with and without a
  # `workspace_*` marker on the target or on its sibling; the expected counts
  # are the ones the tree before the filter produces, and this file is run on
  # both trees. Only fake upstreams are involved.
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo
  alias CodexPooler.SavedResetConfirmationFixtures
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @consume_path "/api/codex/rate-limit-reset-credits/consume"

  # {mode, target quota, sibling quota, marker on, expected consume count}. The
  # counts were read from the tree before the filter and are unchanged after
  # it. Two 97% weekly candidates never reach threshold pressure in this
  # arrangement.
  #
  # A workspace marker on the target does not decide a redemption either way
  # (findings#206 row 206-521). The zeros in the `target` and `target_first`
  # rows of a `weekly_exhausted` target come from a gate that ignores the
  # marker, and the `primary_header` control shows the same zero without one:
  # a primary 5h row next to the exhausted weekly turns the exclusion into
  # `quota_window_unusable`/`secondary`, which the after-exhaustion scan does
  # not open on; only the provider-blocked availability exclusion does.
  #
  # The `target_weekly`, `weekly_header` and `observed_pro_weekly_spent` rows
  # add a fresh weekly header row at the percentage the confirmed Usage API
  # row reports. They were 0 until the trigger scan read the lock's Usage API
  # view: over all sources the header row outranked the only row carrying the
  # automatic confirmation (findings#206). They consume once now, as the same
  # arrangement without the header row always did.
  #
  # In the reset-eligible shape (`two_window_provider_blocked`, a fixture: the
  # Usage API reported the account blocked, the weekly is confirmed exhausted
  # and the 5h primary is usable at 40%) a `workspace_*` marker still redeems.
  # That is the decision: the reached type names the credit or spend-cap
  # fallback that applies once an included window is spent, and a reset
  # restores the included windows. A workspace guard must change these rows
  # on purpose.
  #
  # The `observed_*` rows are account states measured on a real install
  # (findings#206 rows 206-521/206-523, read-only): two Team accounts in one
  # Pool, a Pro account with the weekly spent, and a routable Pro account.
  # Their 5h values are fixture values where the install did not report one.
  # They record what auto-redeem would have done had it been enabled.
  @cases [
    {"blocked", :weekly_exhausted, :missing, :none, 1},
    {"blocked", :weekly_exhausted, :missing, :target, 0},
    {"blocked", :weekly_exhausted, :missing, :target_first, 0},
    {"threshold", :weekly_exhausted, :missing, :none, 1},
    {"threshold", :weekly_exhausted, :missing, :target, 0},
    {"threshold", :weekly_exhausted, :missing, :target_first, 0},
    {"blocked", :weekly_exhausted, :missing, :target_weekly, 1},
    {"threshold", :weekly_exhausted, :missing, :target_weekly, 1},
    {"blocked", :weekly_exhausted, :primary_exhausted, :none, 1},
    {"blocked", :weekly_exhausted, :primary_exhausted, :sibling, 1},
    {"threshold", :weekly_exhausted, :usable, :none, 0},
    {"threshold", :weekly_exhausted, :usable, :sibling, 0},
    {"blocked", :weekly_exhausted, :usable, :sibling, 0},
    {"blocked", :usable, :missing, :target, 0},
    {"threshold", :usable, :missing, :target, 0},
    {"threshold", :weekly_pressure, :weekly_pressure, :none, 0},
    {"threshold", :weekly_pressure, :weekly_pressure, :target, 0},
    {"threshold", :weekly_pressure, :weekly_pressure, :target_first, 0},
    {"threshold", :weekly_pressure, :weekly_pressure, :sibling, 0},
    {"blocked", :weekly_exhausted, :missing, :primary_header, 0},
    {"blocked", :weekly_exhausted, :missing, :weekly_header, 1},
    {"blocked", :two_window, :missing, :none, 0},
    {"blocked", :two_window_provider_blocked, :missing, :none, 1},
    {"blocked", :two_window_provider_blocked, :missing, :target, 1},
    {"blocked", :two_window_provider_blocked, :missing, :target_first, 1},
    {"threshold", :two_window_provider_blocked, :missing, :none, 1},
    {"threshold", :two_window_provider_blocked, :missing, :target, 1},
    {"blocked", :two_window_provider_blocked, :missing, :weekly_header, 1},
    {"blocked", :two_window_provider_blocked, :missing, :target_weekly, 1},
    {"blocked", :observed_team_weekly_96_denied, :observed_team_five_hour_spent, :none, 0},
    {"blocked", :observed_team_five_hour_spent, :observed_team_weekly_96_denied, :none, 0},
    {"threshold", :observed_team_weekly_96_denied, :observed_team_five_hour_spent, :none, 0},
    {"threshold", :observed_team_five_hour_spent, :observed_team_weekly_96_denied, :none, 0},
    {"threshold", :observed_pro_weekly_spent, :observed_pro_weekly_81, :none, 0},
    {"blocked", :observed_pro_weekly_spent, :observed_pro_weekly_spent, :none, 1},
    {"threshold", :observed_pro_weekly_spent, :observed_pro_weekly_spent, :none, 1}
  ]

  for {mode, target_quota, sibling_quota, marker, expected} <- @cases do
    test "#{mode} mode, #{target_quota} target, #{sibling_quota} sibling, #{marker} marker: #{expected} consume" do
      %{upstream: upstream, input: input, target: target, sibling: sibling} =
        arrangement(unquote(mode), unquote(target_quota), unquote(sibling_quota), unquote(marker))

      capture_log(fn -> filter(input) end)

      assert consume_count(upstream) == unquote(expected)

      # Twin accounts spend one reset on the first candidate in order, which
      # is the sibling.
      spent = if unquote(target_quota) == unquote(sibling_quota), do: sibling, else: target
      redeemed? = get_in(Repo.reload!(spent.identity).metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
      assert redeemed? == (unquote(expected) == 1)
    end
  end

  defp arrangement(mode, target_quota, sibling_quota, marker) do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           @consume_path => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {200, usage_payload(1)}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    target = active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 2)})
    sibling = active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})
    target = %{target | identity: enable_auto_redeem!(target.identity, mode)}
    sibling = %{sibling | identity: enable_auto_redeem!(sibling.identity, mode)}

    if marker == :target_first, do: put_workspace_marker!(target.identity)
    put_quota!(target.identity, target_quota)
    put_quota!(sibling.identity, sibling_quota)

    case marker do
      :target -> put_workspace_marker!(target.identity)
      :target_weekly -> put_workspace_marker!(target.identity, :weekly)
      :sibling -> put_workspace_marker!(sibling.identity)
      :primary_header -> put_workspace_marker!(target.identity, :primary, nil)
      :weekly_header -> put_workspace_marker!(target.identity, :weekly, nil)
      _none_or_first -> :ok
    end

    candidates = [
      {sibling.assignment, Repo.reload!(sibling.identity)},
      {target.assignment, Repo.reload!(target.identity)}
    ]

    if marker in [:target, :target_first, :target_weekly] do
      # The marker is live: the account-denial reader holds the target denied.
      now = DateTime.utc_now()
      snapshot = [target.identity.id] |> RoutingQuotaSnapshot.load_by_identity_ids(now) |> Map.fetch!(target.identity.id)
      assert %{} = QuotaWindows.routing_account_denial(snapshot)
    end

    %{upstream: upstream, target: target, sibling: sibling, input: filter_input(pool, api_key, candidates)}
  end

  defp filter(%FilterInput{} = input) do
    route_state =
      RouteState.new(%{visible_model: input.model, candidates: input.candidates})
      |> RouteState.preload_routing_snapshots(input.auth, input.model, input.request_options)

    RouteFiltering.filter_candidates_with_route_state(input, route_state)
  end

  defp put_quota!(_identity, :missing), do: :ok

  defp put_quota!(identity, :weekly_exhausted) do
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [weekly_attrs(Decimal.new("100"))])
    SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
  end

  defp put_quota!(identity, :weekly_pressure) do
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [weekly_attrs(Decimal.new("97"))])
    SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
  end

  defp put_quota!(identity, :two_window) do
    put_quota!(identity, :weekly_exhausted)
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [primary_attrs(Decimal.new("40"))])
  end

  defp put_quota!(identity, :two_window_provider_blocked) do
    put_quota!(identity, :two_window)
    block_availability!(identity)
  end

  # A Team account with the 5h spent, the weekly at 96%, and the 429s' weekly
  # header row carrying `workspace_member_credits_depleted`.
  defp put_quota!(identity, :observed_team_weekly_96_denied) do
    put_usage!(identity, "100", "96")
    put_header!(identity, :primary, "97", nil)
    put_header!(identity, :weekly, "96", "workspace_member_credits_depleted")
    block_availability!(identity)
  end

  # A Team account with the 5h spent, the weekly at 75%, no marker.
  defp put_quota!(identity, :observed_team_five_hour_spent) do
    put_usage!(identity, "100", "75")
    put_header!(identity, :primary, "100", nil)
    put_header!(identity, :weekly, "75", nil)
    block_availability!(identity)
  end

  # A Pro account with the weekly at 81%, routing ready (5h value is a fixture).
  defp put_quota!(identity, :observed_pro_weekly_81) do
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [weekly_attrs(Decimal.new("81"))])
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [primary_attrs(Decimal.new("10"))])
  end

  # A Pro account with the weekly spent, confirmed by the Usage
  # API and last seen on a response header; the 5h value is a fixture.
  defp put_quota!(identity, :observed_pro_weekly_spent) do
    put_quota!(identity, :weekly_exhausted)
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [primary_attrs(Decimal.new("40"))])
    put_header!(identity, :weekly, "100", nil)
    block_availability!(identity)
  end

  defp put_quota!(identity, :primary_exhausted) do
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [primary_attrs(Decimal.new("100"))])
  end

  defp put_quota!(identity, :usable) do
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [primary_attrs(Decimal.new("10"))])
  end

  # The Usage API's `allowed=false` receipt records the account as blocked.
  defp block_availability!(identity) do
    identity = Repo.reload!(identity)
    metadata = Map.put(identity.metadata, AccountAvailabilityStore.metadata_key(), AccountAvailabilityStore.encode!(:blocked, DateTime.utc_now(), 1))
    identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
  end

  defp put_usage!(identity, primary_percent, weekly_percent) do
    denied = %{metadata: %{"rate_limit_allowed" => false, "rate_limit_reached" => true}}

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [Map.merge(weekly_attrs(Decimal.new(weekly_percent)), denied)])
    SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [Map.merge(primary_attrs(Decimal.new(primary_percent)), denied)])
  end

  defp put_header!(identity, kind, used_percent, reached_type) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {prefix, minutes, reset_at} = if kind == :primary, do: {"primary", "300", DateTime.add(now, 1, :hour)}, else: {"secondary", "10080", DateTime.add(now, 2, :hour)}

    headers =
      [
        {"x-codex-#{prefix}-used-percent", used_percent},
        {"x-codex-#{prefix}-window-minutes", minutes},
        {"x-codex-#{prefix}-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}
      ] ++ if(reached_type, do: [{"x-codex-rate-limit-reached-type", reached_type}], else: [])

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers, now)
  end

  # The real header path, as a provider 429 records it. A nil reached type is
  # the same header observation without a marker.
  defp put_workspace_marker!(identity, shape \\ :primary, reached_type \\ "workspace_member_credits_depleted") do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    window_headers =
      case shape do
        :primary ->
          [
            {"x-codex-primary-used-percent", "40"},
            {"x-codex-primary-window-minutes", "300"},
            {"x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(now) + 3_600)}
          ]

        # The weekly window the usage row already reports exhausted, same reset.
        :weekly ->
          [
            {"x-codex-secondary-used-percent", "100"},
            {"x-codex-secondary-window-minutes", "10080"},
            {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(DateTime.add(now, 2, :hour)))}
          ]
      end

    headers = window_headers ++ if(reached_type, do: [{"x-codex-rate-limit-reached-type", reached_type}], else: [])

    assert {:ok, [window]} = QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers, now)
    assert window.metadata["rate_limit_reached_type"] == reached_type
  end

  defp weekly_attrs(used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: used_percent,
      reset_at: DateTime.add(now, 2, :hour),
      observed_at: now,
      last_sync_at: now,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
  end

  defp primary_attrs(used_percent) do
    Map.merge(weekly_attrs(used_percent), %{window_kind: "primary", window_minutes: 300})
  end

  defp enable_auto_redeem!(%UpstreamIdentity{} = identity, mode) do
    identity
    |> UpstreamIdentity.changeset(%{
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      saved_reset_auto_redeem_trigger_mode: mode,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp saved_reset_metadata(upstream, available_count) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    %{
      "usage_base_url" => FakeUpstream.url(upstream),
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      }
    }
  end

  defp filter_input(pool, api_key, candidates) do
    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-denial-invariance-#{System.unique_integer([:positive])}",
        metadata: %{"source_assignment_ids" => Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)}
      })

    payload = %{"model" => model.exposed_model_id, "input" => "route filtering"}

    FilterInput.new(%{
      auth: %{pool: pool, api_key: api_key},
      model: model,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options:
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.put_routing(reset_probe: ResetProbe.new()),
      candidates: candidates
    })
  end

  defp usage_payload(available_count) do
    reset_at = System.system_time(:second) + 900

    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900,
          "reset_at" => reset_at
        }
      }
    }
  end

  defp consume_count(upstream) do
    Enum.count(FakeUpstream.requests(upstream), &(&1.path == @consume_path))
  end
end
