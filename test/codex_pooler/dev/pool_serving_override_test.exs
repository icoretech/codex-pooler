defmodule CodexPooler.Dev.PoolServingOverrideTest do
  # The fixture action writes a Pool's Full/Lite serving override through the
  # product path, so a local topology ("Pool X serves model M in Full") is
  # built without hand rpc. The proof is the next gateway request's routing
  # metadata, which reads the override from the database.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1, stream_success_sse: 0]

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Dev.PoolServingOverride
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

  setup do
    _owner = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    upstream = start_upstream(stream_success_sse())
    %{setup: gateway_setup(upstream)}
  end

  test "full serves the next gateway request in Full by override", %{conn: conn, setup: setup} do
    assert {:ok, %{mode: "full", previous_mode: "auto", changed: true}} = set(setup, "full")
    assert %{"model_serving_mode" => "full", "model_serving_mode_source" => "override"} = served_routing(conn, setup)
    assert audit_events(setup) == 1
  end

  test "lite replaces a Full override and reports it as the previous mode", %{conn: conn, setup: setup} do
    assert {:ok, %{previous_mode: "auto"}} = set(setup, "full")
    assert {:ok, %{mode: "lite", previous_mode: "full", changed: true}} = set(setup, "lite")
    assert %{"model_serving_mode" => "lite", "model_serving_mode_source" => "override"} = served_routing(conn, setup)
  end

  test "auto clears the override so the catalog decides again", %{conn: conn, setup: setup} do
    assert {:ok, %{previous_mode: "auto"}} = set(setup, "full")
    assert {:ok, %{mode: "auto", previous_mode: "full", changed: true}} = set(setup, "auto")
    refute Repo.exists?(from(o in ModelServingOverride, where: o.pool_id == ^setup.pool.id))
    assert %{"model_serving_mode_source" => source} = served_routing(conn, setup)
    refute source == "override"
    assert audit_events(setup) == 2
  end

  test "an unknown model, a bad mode or a missing Pool writes nothing", %{setup: setup} do
    options = [environment: :test, allow_test_database: true, pool_slug: setup.pool.slug]

    assert {:error, "model identifier is not available for this Pool"} =
             PoolServingOverride.set(options ++ [model: "gpt-not-in-this-pool", mode: "full"])

    assert {:error, "--mode must be one of full, lite, auto"} = PoolServingOverride.set(options ++ [model: setup.model.exposed_model_id, mode: "fast"])

    assert {:error, "active pool was not found"} =
             PoolServingOverride.set(environment: :test, allow_test_database: true, pool_slug: "no-such-pool", model: "m", mode: "full")

    refute Repo.exists?(from(o in ModelServingOverride, where: o.pool_id == ^setup.pool.id))
  end

  test "runs only against the development database or an explicit loopback target" do
    replica = [database: "codex_pooler_replica", hostname: "127.0.0.1", port: 15_432]

    assert :ok = PoolServingOverride.validate_environment(environment: :dev, repo_config: [database: "codex_pooler_dev"])
    assert :ok = PoolServingOverride.validate_environment(environment: :dev, target_database: "codex_pooler_replica", repo_config: replica)

    assert {:error, "pool serving override requires database codex_pooler_dev"} =
             PoolServingOverride.validate_environment(environment: :dev, repo_config: replica)

    assert {:error, "pool serving override runs only with MIX_ENV=dev"} = PoolServingOverride.validate_environment(environment: :test)

    assert_raise Mix.Error, ~r/pool serving override runs only with MIX_ENV=dev/, fn ->
      Mix.Tasks.Dev.PoolServingOverride.run(["--pool", "p", "--model", "m", "--mode", "full", "--target-database", "codex_pooler_replica"])
    end

    assert_raise Mix.Error, ~r/duplicate pool serving override option/, fn ->
      Mix.Tasks.Dev.PoolServingOverride.run(["--pool", "p", "--pool", "q", "--model", "m", "--mode", "full"])
    end
  end

  defp set(setup, mode) do
    PoolServingOverride.set(
      environment: :test,
      allow_test_database: true,
      pool_slug: setup.pool.slug,
      model: setup.model.exposed_model_id,
      mode: mode
    )
  end

  defp audit_events(setup),
    do: Repo.aggregate(from(e in AuditEvent, where: e.pool_id == ^setup.pool.id and like(e.action, "%serving%")), :count)

  defp served_routing(conn, setup) do
    response =
      conn
      |> auth(setup)
      |> post(@endpoint_path, %{"model" => setup.model.exposed_model_id, "input" => native_text_input("serving override"), "stream" => true})

    assert response.status == 200

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    assert request.transport == "http_sse"
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    attempt.response_metadata["routing"]
  end
end
