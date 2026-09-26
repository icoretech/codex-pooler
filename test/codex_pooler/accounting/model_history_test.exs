defmodule CodexPooler.Accounting.ModelHistoryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ModelObservation}
  alias CodexPooler.Accounting.RequestLogs.ModelHistory
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Repo

  test "attempt denominators, retries, overlapping measures, unknown coverage and retention" do
    owner = bootstrap_owner_fixture()
    scope = Scope.for_user(owner.user)
    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup)
    now = DateTime.utc_now()

    rows = [
      {"model-a", evidence(false, "completed")},
      {"model-b", evidence(true, "completed")},
      {"model-a", evidence(true, nil)},
      {nil, evidence(nil, "completed")},
      {"model-b", nil},
      {nil, nil}
    ]

    attempts =
      for {{served, observation}, number} <- Enum.with_index(rows, 1) do
        attempt_fixture(request, assignment, %{attempt_number: number, upstream_model_id: "model-a", served_model: served, model_observation: observation})
        |> Ecto.Changeset.change(started_at: DateTime.add(now, -1, :second))
        |> Repo.update!()
      end

    history = ModelHistory.for_scope(scope, %{}, now: now)
    assert history.counts == %{total: 6, collected: 4, observed: 3, missing: 1, uncollected: 2, comparable: 4, mismatches: 2, conflicts: 2, partial: 0, without_terminal: 1}
    assert [%{total: 3, conflicts: 2, mismatches: 2}] = history.groups
    assert ModelHistory.for_scope(scope, %{"evidence" => "missing"}, now: now).groups == history.groups
    assert length(history.attempts) == 3
    assert Enum.sum(Enum.map(history.model_pairs, & &1.total)) == 3
    assert ModelHistory.for_scope(scope, %{"evidence" => "missing"}, now: now).model_pairs == history.model_pairs
    assert length(ModelHistory.for_scope(scope, %{"evidence" => "all"}, now: now).attempts) == 6
    assert length(ModelHistory.for_scope(scope, %{"evidence" => "conflict"}, now: now).attempts) == 2
    assert length(ModelHistory.for_scope(scope, %{"evidence" => "uncollected"}, now: now).attempts) == 2
    assert length(ModelHistory.for_scope(scope, %{"evidence" => "missing"}, now: now).attempts) == 1

    log = Accounting.get_request_log_for_scope(scope, request.id)
    assert log.model_conflict_attempts == [2, 3]
    assert Enum.at(log.debug.attempts, 1).model_observation["first_conflicting_model"] == "model-c"
    assert List.last(log.debug.attempts).model_observation == nil

    Repo.delete!(Enum.at(attempts, 1))
    assert ModelHistory.for_scope(scope, %{}, now: now).counts.conflicts == 1
  end

  test "time bounds include start and exclude end, foreign pools fail closed, filters are exact" do
    owner = bootstrap_owner_fixture()
    scope = Scope.for_user(owner.user)
    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup)
    now = DateTime.utc_now()

    for {offset, number} <- [{-3601, 1}, {-3600, 2}, {-1, 3}, {0, 4}] do
      attempt_fixture(request, assignment, %{attempt_number: number, upstream_model_id: "model-a"})
      |> Ecto.Changeset.change(started_at: DateTime.add(now, offset, :second))
      |> Repo.update!()
    end

    assert ModelHistory.for_scope(scope, %{"window" => "1h"}, now: now).counts.total == 2
    assert ModelHistory.for_scope(scope, %{"pool_id" => Ecto.UUID.generate()}, now: now).counts.total == 0
    assert ModelHistory.for_scope(scope, %{"pool_id" => "invalid"}, now: now).counts.total == 0
    assert ModelHistory.for_scope(scope, %{"upstream_identity_id" => Ecto.UUID.generate()}, now: now).counts.total == 0
    assert ModelHistory.for_scope(scope, %{"sent_model" => "different"}, now: now).counts.total == 0

    operator = operator_fixture(scope, %{"role" => "instance_admin"})
    assert ModelHistory.for_scope(Scope.for_user(operator.user), %{}, now: now).counts.total == 0
  end

  test "boundary normalization keeps old and unknown collectors unknown and bounds retained values" do
    assert ModelObservation.normalize(nil, "model-a") == nil
    assert ModelObservation.normalize(%{"version" => 2}, "model-a") == nil
    normalized = ModelObservation.normalize(Map.merge(evidence(true, "completed"), %{"terminal_model" => String.duplicate("x", 100), "extra" => "ignored"}), "model-a")
    assert "sha256_" <> _ = normalized["terminal_model"]
    refute Map.has_key?(normalized, "extra")
    assert ModelObservation.normalize(evidence(false, nil), nil)["conflict"] == nil
  end

  test "timeline uses the scoped attempt population and keeps gaps, retries and unknown collection distinct" do
    scope = Scope.for_user(bootstrap_owner_fixture().user)
    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup)
    now = ~U[2026-09-26 12:00:00.000000Z]

    for {{offset, served, observation}, number} <-
          Enum.with_index(
            [
              {-3601, "model-b", evidence(true, "completed")},
              {-3600, "model-b", evidence(true, "completed")},
              {-3300, nil, evidence(nil, "completed")},
              {-1, "model-b", nil},
              {0, "model-b", evidence(true, "completed")}
            ],
            1
          ) do
      attempt_fixture(request, assignment, %{attempt_number: number, served_model: served, upstream_model_id: "model-a", model_observation: observation})
      |> Ecto.Changeset.change(started_at: DateTime.add(now, offset, :second))
      |> Repo.update!()
    end

    history = ModelHistory.for_scope(scope, %{"window" => "1h"}, now: now)
    assert history.bucket_seconds == 300
    assert length(history.timeline) == 12
    assert hd(history.timeline).bucket == ~U[2026-09-26 11:00:00.000000Z]
    assert %{total: 1, observed: 1, mismatches: 1, conflicts: 1} = hd(history.timeline)
    assert %{total: 1, missing: 1, conflicts: 0} = Enum.at(history.timeline, 1)
    assert %{total: 0, uncollected: 0, conflicts: 0} = Enum.at(history.timeline, 2)
    assert %{total: 1, uncollected: 1, mismatches: 1, conflicts: 0} = List.last(history.timeline)
    for {key, total} <- history.counts, do: assert(Enum.sum(Enum.map(history.timeline, &Map.fetch!(&1, key))) == total)
    assert ModelHistory.for_scope(scope, %{"window" => "1h", "evidence" => "conflict"}, now: now).timeline == history.timeline

    for filters <- [%{"pool_id" => Ecto.UUID.generate()}, %{"upstream_identity_id" => Ecto.UUID.generate()}, %{"sent_model" => "another-model"}] do
      assert ModelHistory.for_scope(scope, filters, now: now).timeline |> Enum.all?(&(&1.total == 0))
    end

    hidden_scope = Scope.for_user(operator_fixture(scope, %{"role" => "instance_admin"}).user)
    assert ModelHistory.for_scope(hidden_scope, %{}, now: now).timeline |> Enum.all?(&(&1.total == 0))
    week = ModelHistory.for_scope(scope, %{"window" => "7d"}, now: now)
    assert {week.bucket_seconds, length(week.timeline)} == {21_600, 28}
  end

  test "finalization and retryable attempt writes retain evidence without changing usage or billing" do
    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup, %{status: "in_progress", completed_at: nil})
    attempt = attempt_fixture(request, assignment, %{status: "in_progress", completed_at: nil})
    usage = %{status: "usage_unknown", served_model: "model-a", model_observation: evidence(true, "failed")}
    assert {:ok, saved} = Accounting.record_retryable_attempt_failure(attempt, %{usage: usage, response_status_code: 503})
    assert saved.served_model == "model-a"
    assert saved.model_observation == evidence(true, "failed")
    assert saved.usage_status == "usage_unknown"
    assert Repo.get!(Attempt, attempt.id).model_observation["conflict"]
  end

  defp evidence(conflict, terminal), do: %{"version" => 1, "coverage" => "full", "conflict" => conflict, "terminal_status" => terminal, "terminal_model" => if(terminal, do: "model-a"), "first_conflicting_model" => if(conflict, do: "model-c")}
end
