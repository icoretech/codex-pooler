defmodule CodexPooler.Gateway.Routing.SavedResetTriggerSourceViewTest do
  # The automatic trigger scan reads the same Usage API view as the locked
  # fences (findings#206). Only Usage API rows carry the automatic
  # confirmation; a fresh response-header row of the same weekly window at an
  # equal or higher percentage used to outrank the confirmed row, so the scan
  # saw no corroboration until the header row went stale (900 s), and a
  # threshold target serving traffic refreshed it on every response. Every
  # consume below goes to a fake upstream.
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
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @consume_path "/api/codex/rate-limit-reset-credits/consume"

  # {mode, Usage API weekly percent or nil, Usage API receipts, header weekly
  # percent or nil, header age in seconds, expected consume count}. The rows
  # with a fresh header at or above the Usage API percent were 0 before.
  @cases [
    {"blocked", "100", 2, nil, 0, 1},
    {"blocked", "100", 2, "100", 0, 1},
    {"blocked", "100", 2, "100", 840, 1},
    {"blocked", "100", 2, "100", 960, 1},
    {"blocked", "100", 2, "99", 0, 1},
    {"threshold", "97", 2, nil, 0, 1},
    {"threshold", "97", 2, "97", 0, 1},
    {"threshold", "97", 2, "97", 840, 1},
    {"threshold", "97", 2, "98", 0, 1},
    {"threshold", "97", 2, "96", 0, 1},
    # Corroboration is still required: one Usage API receipt, or none at all.
    {"blocked", "100", 1, "100", 0, 0},
    {"threshold", "97", 1, "97", 0, 0},
    {"blocked", nil, 0, "100", 0, 0},
    {"threshold", nil, 0, "97", 0, 0}
  ]

  for {mode, usage_percent, receipts, header_percent, age, expected} <- @cases do
    test "#{mode} mode, usage #{inspect(usage_percent)} x#{receipts}, header #{inspect(header_percent)} aged #{age}s: #{expected} consume" do
      %{upstream: upstream, identity: identity, input: input} =
        arrangement(unquote(mode), unquote(usage_percent), unquote(receipts), unquote(header_percent), unquote(age))

      capture_log(fn -> filter(input) end)

      assert consume_count(upstream) == unquote(expected)
      redeemed? = get_in(Repo.reload!(identity).metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
      assert redeemed? == (unquote(expected) == 1)
    end
  end

  defp arrangement(mode, usage_percent, receipts, header_percent, age) do
    {:ok, upstream} =
      FakeUpstream.start_link({:path_json, %{@consume_path => {200, %{"code" => "reset"}}, "/api/codex/usage" => {200, usage_payload(1)}}})

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment, identity: identity} = active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 2)})
    identity = enable_auto_redeem!(identity, mode)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = DateTime.add(now, 2, :hour)

    if usage_percent do
      assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [weekly_attrs(Decimal.new(usage_percent), now, reset_at)])
      SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity, observations: receipts)
    end

    if header_percent do
      headers = [
        {"x-codex-secondary-used-percent", header_percent},
        {"x-codex-secondary-window-minutes", "10080"},
        {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}
      ]

      assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers, DateTime.add(now, -age, :second))
    end

    identity = Repo.reload!(identity)
    %{upstream: upstream, identity: identity, input: filter_input(pool, api_key, [{assignment, identity}])}
  end

  defp filter(%FilterInput{} = input) do
    route_state =
      RouteState.new(%{visible_model: input.model, candidates: input.candidates})
      |> RouteState.preload_routing_snapshots(input.auth, input.model, input.request_options)

    RouteFiltering.filter_candidates_with_route_state(input, route_state)
  end

  defp weekly_attrs(used_percent, now, reset_at) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: used_percent,
      reset_at: reset_at,
      observed_at: now,
      last_sync_at: now,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
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
    %{
      "usage_base_url" => FakeUpstream.url(upstream),
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      }
    }
  end

  defp filter_input(pool, api_key, candidates) do
    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-trigger-source-#{System.unique_integer([:positive])}",
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
    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900,
          "reset_at" => System.system_time(:second) + 900
        }
      }
    }
  end

  defp consume_count(upstream) do
    Enum.count(FakeUpstream.requests(upstream), &(&1.path == @consume_path))
  end
end
