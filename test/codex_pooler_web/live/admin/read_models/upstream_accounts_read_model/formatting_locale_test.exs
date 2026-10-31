defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.FormattingLocaleTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting

  test "English relative-time prose retains compact duration units" do
    Gettext.with_locale("en", fn ->
      now = ~U[2026-01-01 00:00:00Z]
      assert Formatting.relative_time_label(DateTime.add(now, 3_900, :second), now) == "in 1h 5m"
      assert Formatting.relative_time_label(now, now) == "just now"
      assert Formatting.relative_time_label(DateTime.add(now, -120, :second), now) == "2m ago"
      assert Formatting.timestamp_status_label("auth verified", nil, %{}) == "auth verified not reported"
      assert Formatting.timestamp_value_label(nil, %{}) == "not reported"
    end)
  end

  test "Chinese relative-time prose and missing timestamps translate without localizing units" do
    Gettext.with_locale("zh_CN", fn ->
      now = ~U[2026-01-01 00:00:00Z]
      assert Formatting.relative_time_label(DateTime.add(now, 3_900, :second), now) == "1h 5m 后"
      assert Formatting.relative_time_label(now, now) == "刚刚"
      assert Formatting.relative_time_label(DateTime.add(now, -120, :second), now) == "2m 前"
      assert Formatting.timestamp_status_label("auth verified", nil, %{}) == "未报告凭据验证时间"
      assert Formatting.timestamp_value_label(nil, %{}) == "未报告"
    end)
  end
end
