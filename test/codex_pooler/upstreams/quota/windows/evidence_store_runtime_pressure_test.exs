defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreRuntimePressureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Quota.Windows

  test "records repeated rate-limit errors when used percent is absent" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    first_observed_at = ~U[2026-07-25 12:00:00Z]
    second_observed_at = DateTime.add(first_observed_at, 1, :second)

    assert {:ok, [first_window]} =
             Windows.upsert_quota_windows_from_codex_rate_limit_error(
               identity,
               rate_limit_error(first_observed_at),
               first_observed_at
             )

    assert first_window.source == "codex_rate_limit_error"
    assert first_window.used_percent == nil

    assert {:ok, [second_window]} =
             Windows.upsert_quota_windows_from_codex_rate_limit_error(
               identity,
               rate_limit_error(first_observed_at),
               second_observed_at
             )

    assert second_window.id == first_window.id
    assert second_window.used_percent == nil
  end

  defp rate_limit_error(observed_at) do
    %{
      "limit_id" => "codex",
      "window_kind" => "primary",
      "window_minutes" => 300,
      "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 15, :minute))
    }
  end
end
