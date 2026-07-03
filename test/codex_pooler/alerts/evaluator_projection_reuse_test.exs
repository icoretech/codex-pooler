defmodule CodexPooler.Alerts.EvaluatorProjectionReuseTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "active rule evaluation reuses pool quota projections for the same pool" do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("44"),
                 credits: 56,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    alert_rule_fixture(pool,
      rule_kind: "pool_low_usable_assignments",
      min_usable_assignments: 2
    )

    alert_rule_fixture(pool,
      rule_kind: "pool_all_assignments_in_state",
      target_state: "missing_evidence"
    )

    {_candidates, query_counts} =
      count_repo_commands(fn ->
        Alerts.evaluate_active_rules(at: timestamp)
      end)

    assert command_count(query_counts, "pool_upstream_assignments", "SELECT") == 1
    assert command_count(query_counts, "account_quota_windows", "SELECT") == 1
  end

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "evaluator-projection-reuse-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], command_name(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_commands(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_commands(handler_id, commands) do
    receive do
      {^handler_id, source, command} ->
        key = {source, command}
        drain_repo_commands(handler_id, Map.update(commands, key, 1, &(&1 + 1)))
    after
      0 -> commands
    end
  end

  defp command_count(commands, source, command), do: Map.get(commands, {source, command}, 0)

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil
end
