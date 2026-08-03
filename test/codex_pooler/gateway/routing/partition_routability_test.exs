defmodule CodexPooler.Gateway.Routing.PartitionRoutabilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures,
    only: [active_upstream_assignment_fixture: 2, model_fixture: 2, pool_fixture: 0]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [model_quota_window_attrs: 3, primary_quota_window_attrs: 1]

  alias CodexPooler.Gateway.Routing.PartitionRoutability
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "routability stays model-scoped when an assignment is shared" do
    pool = pool_fixture()
    shared = active_upstream_assignment_fixture(pool, %{})

    routable_model =
      model_fixture(pool, %{
        exposed_model_id: unique_model_id("gpt-routable-shared-assignment"),
        upstream_model_id: unique_model_id("provider-routable-shared-assignment"),
        metadata: %{"source_assignment_ids" => [shared.assignment.id]}
      })

    exhausted_model =
      model_fixture(pool, %{
        exposed_model_id: unique_model_id("gpt-exhausted-shared-assignment"),
        upstream_model_id: unique_model_id("provider-exhausted-shared-assignment"),
        metadata: %{"source_assignment_ids" => [shared.assignment.id]}
      })

    assert {:ok, windows} =
             QuotaWindows.upsert_quota_windows(shared.identity, [
               primary_quota_window_attrs(%{}),
               model_quota_window_attrs(exhausted_model, "primary", %{
                 used_percent: Decimal.new("100")
               })
             ])

    assert length(windows) == 2

    shared_candidate = {shared.assignment, shared.identity}

    candidates_by_model_id = %{
      routable_model.id => [shared_candidate],
      exhausted_model.id => [shared_candidate]
    }

    {result, commands} =
      count_repo_commands(fn ->
        PartitionRoutability.routable_assignment_ids_by_model_id(
          [routable_model, exhausted_model],
          candidates_by_model_id
        )
      end)

    assert result == %{
             routable_model.id => MapSet.new([shared.assignment.id]),
             exhausted_model.id => MapSet.new()
           }

    assert command_count(commands, "account_quota_windows", "SELECT") == 1
  end

  defp unique_model_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "partition-routability-test-#{System.unique_integer([:positive])}"

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
