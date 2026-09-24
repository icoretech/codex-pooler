defmodule CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimitTest do
  # The earliest reset of an all-exhausted Pool (findings#206 rows 206-508,
  # 206-522): the advice is the soonest reset among every candidate's exhausted
  # windows, because the listed windows do not say which one binds; any
  # unknown return time leaves no terminal answer.
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimit

  @now ~U[2030-01-01 00:00:00.250000Z]

  test "the advice is the soonest reset among every candidate's exhausted windows" do
    exclusions = [
      candidate([exhausted(in_seconds(7_200)), exhausted(in_seconds(604_800))]),
      candidate([exhausted(in_seconds(5_400))])
    ]

    assert {:ok, %{resets_at: resets_at, resets_in_seconds: 5_400}} = UsageLimit.earliest_reset(exclusions, @now)
    assert resets_at == DateTime.to_unix(in_seconds(5_400)) + 1

    # A refused model meter marks its 5-hour and weekly windows exhausted
    # together; the advice is the 5-hour reset, not the week.
    assert {:ok, %{resets_in_seconds: 18_000}} =
             UsageLimit.earliest_reset([candidate([exhausted(in_seconds(18_000)), exhausted(in_seconds(604_800))])], @now)
  end

  test "the weekly exhaustion code counts as an exhaustion" do
    reason = %{"code" => "quota_weekly_exhausted", "reset_at" => DateTime.to_iso8601(in_seconds(600))}

    assert {:ok, %{resets_in_seconds: 600}} = UsageLimit.earliest_reset([candidate([reason])], @now)
  end

  test "any candidate without a known future return time leaves no terminal answer" do
    known = candidate([exhausted(in_seconds(600))])

    for unknown <- [
          candidate([%{"code" => "quota_window_unusable", "reason_codes" => ["exhausted", "reset_missing"], "reset_at" => nil}]),
          candidate([%{"code" => "quota_window_unusable", "reason_codes" => ["not_fresh"], "reset_at" => DateTime.to_iso8601(in_seconds(600))}]),
          candidate([exhausted(in_seconds(600)), %{"code" => "quota_evidence_missing"}]),
          candidate([exhausted(in_seconds(-1))]),
          candidate([%{"code" => "saved_reset_probe_pending"}]),
          candidate([]),
          %{pool_upstream_assignment_id: "a", upstream_identity_id: "i"}
        ] do
      assert UsageLimit.earliest_reset([known, unknown], @now) == :unknown
    end

    assert UsageLimit.earliest_reset([], @now) == :unknown
  end

  test "a provider-denied candidate returns at its advice, not at the marked row's reset" do
    denied = %{
      "code" => "quota_window_unusable",
      "reason_codes" => ["exhausted", "provider_denied"],
      "reset_at" => DateTime.to_iso8601(in_seconds(30 * 3_600)),
      "hint_reset_at" => DateTime.to_iso8601(in_seconds(3_600))
    }

    assert {:ok, %{resets_in_seconds: 3_600}} = UsageLimit.earliest_reset([candidate([denied])], @now)
    assert UsageLimit.earliest_reset([candidate([Map.delete(denied, "hint_reset_at")])], @now) == :unknown
  end

  test "retryable/1 turns the terminal answer back into the 503" do
    error = %{status: 429, code: "quota_exhausted", usage_limit: %{resets_at: 1, resets_in_seconds: 1}}

    assert UsageLimit.retryable(error) == %{status: 503, code: "quota_exhausted"}
    assert UsageLimit.retryable(%{status: 503, code: "quota_evidence_unavailable"}) == %{status: 503, code: "quota_evidence_unavailable"}
  end

  defp candidate(reasons), do: %{pool_upstream_assignment_id: Ecto.UUID.generate(), upstream_identity_id: Ecto.UUID.generate(), reasons: reasons}

  defp exhausted(reset_at), do: %{"code" => "quota_window_unusable", "reason_codes" => ["exhausted"], "reset_at" => DateTime.to_iso8601(reset_at)}

  defp in_seconds(seconds), do: DateTime.add(@now, seconds, :second)
end
