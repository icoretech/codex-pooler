defmodule CodexPooler.Gateway.Routing.UsageCapSavedResetTest do
  # An account at its operator weekly usage cap leaves the request like a paused
  # one, before quota eligibility and both saved-reset scans (public issue #637,
  # findings#593). Automatic redemption therefore sees the Pool as if the capped
  # account were not in it: a capped sibling never holds a banked reset back, and
  # Pool traffic never spends the capped account's own reset. Every arm has a
  # control without the cap that shows the cap is what changes the outcome.
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo
  alias CodexPooler.SavedResetConfirmationFixtures
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @moduletag capture_log: true

  for capped? <- [true, false] do
    @capped capped?

    test "blocked mode, sibling capped=#{capped?}: an exhausted account's banked reset is redeemed only when the sibling is capped" do
      %{upstream: upstream, target: target, sibling: sibling, input: input} = arrangement(:blocked, @capped)

      result = filter(input)

      if @capped do
        assert {:ok, [{assignment, _identity}], _options} = result
        assert assignment.id == target.assignment.id
        assert consume_count(upstream) == 1
      else
        assert {:ok, [{assignment, _identity}], _options} = result
        assert assignment.id == sibling.assignment.id
        assert consume_count(upstream) == 0
      end
    end

    test "threshold mode, sibling capped=#{capped?}: a capped sibling below the threshold no longer holds the threshold redemption back" do
      %{upstream: upstream, input: input} = arrangement(:threshold, @capped)

      _result = filter(input)

      assert consume_count(upstream) == if(@capped, do: 1, else: 0)
    end
  end

  test "Pool traffic never spends the capped account's own banked reset" do
    {:ok, upstream} = start_fake_upstream()
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    target = active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})
    identity = enable_auto_redeem!(target.identity, %{})
    upsert_weekly_exhausted!(identity)
    cap!(identity, 80)

    assert {:error, %{code: "quota_exhausted", candidate_exclusions: [%{reasons: [reason]}]}} = filter(filter_input(pool, api_key, [{target.assignment, Repo.reload!(identity)}]))
    assert reason["reason_codes"] == ["exhausted", "operator_usage_cap"]
    assert consume_count(upstream) == 0
    refute Repo.reload!(identity).metadata["saved_reset_redemption"]
  end

  for capped? <- [true, false] do
    @capped capped?

    test "a running turn kept on its account, capped=#{capped?}: the account's own reset is redeemed only without a cap" do
      {:ok, upstream} = start_fake_upstream()
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      target = active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})
      identity = enable_auto_redeem!(target.identity, %{saved_reset_auto_redeem_trigger_mode: "threshold", saved_reset_auto_redeem_quota_threshold_percent: 95})
      upsert_weekly!(identity, "96")
      SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
      if @capped, do: cap!(identity, 80)

      running_turn = %{"input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "go"}]}, %{"type" => "function_call", "call_id" => "call_run", "name" => "shell", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "call_run", "output" => "ok"}]}
      input = filter_input(pool, api_key, [{target.assignment, Repo.reload!(identity)}], running_turn, target.assignment.id)

      assert {:ok, [{assignment, _identity}], _options} = filter(input)
      assert assignment.id == target.assignment.id
      assert consume_count(upstream) == if(@capped, do: 0, else: 1)
    end
  end

  defp arrangement(mode, capped?) do
    {:ok, upstream} = start_fake_upstream()
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    target = active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})
    sibling = active_upstream_assignment_fixture(pool)

    target_identity =
      case mode do
        :blocked ->
          identity = enable_auto_redeem!(target.identity, %{})
          upsert_weekly_exhausted!(identity)
          identity

        :threshold ->
          identity = enable_auto_redeem!(target.identity, %{saved_reset_auto_redeem_trigger_mode: "threshold", saved_reset_auto_redeem_quota_threshold_percent: 95})
          upsert_weekly!(identity, "96")
          SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
          identity
      end

    upsert_primary!(sibling.identity, "10")
    upsert_weekly!(sibling.identity, "85")
    if capped?, do: cap!(sibling.identity, 80)

    candidates = [{target.assignment, Repo.reload!(target_identity)}, {sibling.assignment, Repo.reload!(sibling.identity)}]
    %{upstream: upstream, target: target, sibling: sibling, input: filter_input(pool, api_key, candidates)}
  end

  defp filter(%FilterInput{} = input) do
    route_state =
      %{visible_model: input.model, candidates: input.candidates}
      |> RouteState.new()
      |> RouteState.preload_routing_snapshots(input.auth, input.model, input.request_options)

    case RouteFiltering.filter_candidates_with_route_state(input, route_state) do
      {:ok, candidates, options, _route_state} -> {:ok, candidates, options}
      {:error, error} -> {:error, error}
    end
  end

  defp filter_input(pool, api_key, candidates, payload \\ nil, session_assignment_id \\ nil) do
    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-usage-cap-#{System.unique_integer([:positive])}",
        metadata: %{"source_assignment_ids" => Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)}
      })

    payload = Map.put(payload || %{"input" => "usage cap"}, "model", model.exposed_model_id)
    request_options = %{} |> RequestOptions.build("/backend-api/codex/responses", payload) |> RequestOptions.put_routing(reset_probe: ResetProbe.new())

    request_options =
      if session_assignment_id,
        do: %{request_options | continuity: %{request_options.continuity | codex_session: %CodexSession{pool_upstream_assignment_id: session_assignment_id}}},
        else: request_options

    FilterInput.new(%{auth: %{pool: pool, api_key: api_key}, model: model, endpoint: "/backend-api/codex/responses", payload: payload, request_options: request_options, candidates: candidates})
  end

  defp start_fake_upstream do
    FakeUpstream.start_link({:path_json, %{"/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}}, "/api/codex/usage" => {200, usage_payload()}}})
  end

  defp consume_count(fake), do: Enum.count(FakeUpstream.requests(fake), &(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

  defp enable_auto_redeem!(%UpstreamIdentity{} = identity, attrs) do
    identity
    |> UpstreamIdentity.changeset(
      Map.merge(
        %{saved_reset_auto_redeem_enabled: true, saved_reset_auto_redeem_min_blocked_minutes: 60, saved_reset_auto_redeem_keep_credits: 0, updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)},
        attrs
      )
    )
    |> Repo.update!()
  end

  defp cap!(identity, percent), do: identity |> Repo.reload!() |> Ecto.Changeset.change(usage_cap_percent: percent) |> Repo.update!()

  defp upsert_weekly_exhausted!(identity) do
    upsert_weekly!(identity, "100")
    SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
  end

  defp upsert_weekly!(identity, used_percent), do: assert({:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [window_attrs("secondary", 10_080, used_percent)]))
  defp upsert_primary!(identity, used_percent), do: assert({:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [window_attrs("primary", 300, used_percent)]))

  defp window_attrs(kind, minutes, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      quota_key: "account",
      window_kind: kind,
      window_minutes: minutes,
      used_percent: Decimal.new(used_percent),
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

  defp usage_payload do
    observed_at = DateTime.utc_now()
    reset_at = DateTime.add(observed_at, 900, :second)

    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => 0},
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"},
      "spend_control" => %{"reached" => false},
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => %{"used_percent" => 10, "limit_window_seconds" => 10_080 * 60, "reset_after_seconds" => 900, "reset_at" => DateTime.to_unix(reset_at)}
      }
    }
  end
end
