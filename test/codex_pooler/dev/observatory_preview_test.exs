defmodule CodexPooler.Dev.ObservatoryPreviewTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.Dev.Seeds.ObservatoryPreview
  alias Mix.Tasks.Dev.ObservatorySeed

  test "adds sixty complete recent request graphs for the selected key and reruns without changing rows" do
    %{api_key: key, pool: pool} = api_key_fixture()
    key = key |> Ecto.Changeset.change(dashboard_access: true) |> Repo.update!()
    other = api_key_fixture(pool)
    unrelated = request_fixture(other)
    for model <- ~w(gpt-6.2-astra gpt-6-luna gpt-6.2-sol), do: model_fixture(pool, %{exposed_model_id: model})
    original_key = Repo.get!(APIKey, key.id)
    jobs_before = Repo.aggregate(Oban.Job, :count)

    assert %{inserted: 60, existing: 0, total: 60} = ObservatoryPreview.seed!(key.key_prefix)
    requests = Repo.all(from request in Request, where: request.api_key_id == ^key.id, order_by: request.id)
    request_ids = Enum.map(requests, & &1.id)
    assert length(requests) == 60
    assert Enum.all?(requests, &(&1.request_metadata["dev_seed"] == "dev-observatory-preview" and &1.request_metadata["synthetic"] == true))
    assert Repo.aggregate(from(attempt in Attempt, where: attempt.request_id in ^request_ids), :count) == 60
    assert Repo.aggregate(from(fact in RequestLogFact, where: fact.request_id in ^request_ids), :count) == 60

    entries = Repo.all(from entry in LedgerEntry, where: entry.request_id in ^request_ids)
    assert length(entries) == 60
    assert Enum.all?(entries, &(&1.total_tokens == &1.input_tokens + &1.output_tokens and &1.cached_input_tokens <= &1.input_tokens and &1.reasoning_tokens <= &1.output_tokens))
    assert Enum.all?(entries, &(is_nil(&1.upstream_identity_id) and is_nil(&1.pool_upstream_assignment_id)))

    principal = Principal.new(%{api_key_id: key.id, pool_id: pool.id, display_name: key.display_name, key_prefix: key.key_prefix})
    assert {:ok, report} = Observatory.read(principal, "1h")
    assert report.totals.requests == %{total: 60, succeeded: 60, failed: 0, in_progress: 0, client_cancelled: 0}
    assert report.accounting.recorded_settlements == 60
    assert length(report.models) == 3
    assert report.outcomes != []
    assert Enum.all?(report.outcomes, &(&1.total_tokens > 0 and &1.cost.status == "settled"))
    assert Enum.map(requests, & &1.reasoning_effort) |> Enum.uniq() |> Enum.sort() == ~w(high medium xhigh)
    assert Enum.map(requests, & &1.service_tier) |> Enum.uniq() |> Enum.sort() == ~w(default priority ultrafast)

    assert %{inserted: 0, existing: 60, total: 60} = ObservatoryPreview.seed!(key.key_prefix)
    assert Repo.all(from(request in Request, where: request.api_key_id == ^key.id, order_by: request.id)) == requests
    assert Repo.all(from(entry in LedgerEntry, where: entry.request_id in ^request_ids, order_by: entry.id)) == Enum.sort_by(entries, & &1.id)
    assert Repo.get!(Request, unrelated.id) == unrelated
    assert Repo.get!(APIKey, key.id) == original_key
    assert Repo.aggregate(Oban.Job, :count) == jobs_before
  end

  test "rejects a key without dashboard access or an active model before writing requests" do
    %{api_key: key} = api_key_fixture()
    key = key |> Ecto.Changeset.change(dashboard_access: false) |> Repo.update!()

    assert_raise RuntimeError, ~r/active dashboard-enabled API-key prefix/, fn -> ObservatoryPreview.seed!(key.key_prefix) end
    key |> Ecto.Changeset.change(dashboard_access: true) |> Repo.update!()
    assert_raise RuntimeError, ~r/active Pool with active models/, fn -> ObservatoryPreview.seed!(key.key_prefix) end
    assert Repo.aggregate(Request, :count) == 0
  end

  test "task refuses non-development environments before booting or writing" do
    assert_raise Mix.Error, "Observatory preview seeding requires MIX_ENV=dev", fn ->
      ObservatorySeed.run(["--api-key-prefix", "sample-prefix"])
    end

    assert Repo.aggregate(Request, :count) == 0
  end
end
