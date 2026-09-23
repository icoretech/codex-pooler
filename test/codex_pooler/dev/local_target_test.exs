defmodule CodexPooler.Dev.LocalTargetTest do
  # A local replica (for example a kind cluster whose Postgres is reached
  # through a loopback port-forward) is built from the same fixture tasks as
  # `codex_pooler_dev`. The tasks accept it only through an explicit
  # `--target-database NAME` on a loopback Repo, and accept an upstream origin
  # the replica's pods can reach only when it is loopback or an in-cluster
  # service name; public hosts stay refused.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Dev.{LocalTarget, MCPFixture, OpenAIV1Fixture, RoutingStrategyFixture}
  alias CodexPooler.Dev.RoutingStrategyFixture.Names
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @replica "codex_pooler_replica"
  @replica_repo [database: @replica, hostname: "127.0.0.1", port: 15_432]
  @in_cluster "http://fake-upstream:4058"

  describe "target database" do
    test "accepts exactly the configured database over a loopback host" do
      assert :ok = LocalTarget.validate_target_database(@replica, @replica_repo)
      assert :ok = LocalTarget.validate_target_database(@replica, Keyword.put(@replica_repo, :hostname, "localhost"))
    end

    test "refuses a name the Repo is not configured for, a non-loopback host, a URL or a socket" do
      assert {:error, "target database codex_pooler_replica does not match the configured Repo database"} =
               LocalTarget.validate_target_database(@replica, Keyword.put(@replica_repo, :database, "codex_pooler_dev"))

      for repo_config <- [
            Keyword.put(@replica_repo, :hostname, "postgres.example.com"),
            Keyword.put(@replica_repo, :hostname, "10.96.8.161"),
            Keyword.delete(@replica_repo, :hostname),
            Keyword.put(@replica_repo, :url, "ecto://postgres@db.example.com/codex_pooler_replica"),
            Keyword.put(@replica_repo, :socket_dir, "/tmp"),
            Keyword.put(@replica_repo, :socket, "/tmp/.s.PGSQL.5432")
          ] do
        assert {:error, "target database codex_pooler_replica must be reached over a loopback host (a port-forward is fine)"} =
                 LocalTarget.validate_target_database(@replica, repo_config)
      end

      for name <- ["../codex_pooler_dev", "Codex", "", "a/b"] do
        assert {:error, "target database name is invalid"} =
                 LocalTarget.validate_target_database(name, Keyword.put(@replica_repo, :database, name))
      end
    end

    test "scopes a target's receipt below its own directory and keeps the development default" do
      default = Path.expand("tmp/example-fixture/setup.json")

      assert LocalTarget.receipt_path(default, "tmp/example-fixture", nil) == default
      assert LocalTarget.receipt_path(default, "tmp/example-fixture", "codex_pooler_dev") == default

      assert LocalTarget.receipt_path(default, "tmp/example-fixture", @replica) ==
               Path.expand("tmp/example-fixture/target-codex_pooler_replica/setup.json")

      assert_raise ArgumentError, fn -> LocalTarget.receipt_path(default, "tmp/example-fixture", "../escape") end
    end

    test "every database-guarded fixture accepts the explicit target and keeps its default without it" do
      for {validate, refusal} <- [
            {&RoutingStrategyFixture.validate_environment/1, "routing strategy fixture requires database codex_pooler_dev"},
            {&OpenAIV1Fixture.validate_environment/1, "OpenAI V1 fixture requires database codex_pooler_dev"},
            {&MCPFixture.validate_environment/1, "MCP fixture requires database codex_pooler_dev"}
          ] do
        assert :ok = validate.(environment: :dev, target_database: @replica, repo_config: @replica_repo)
        assert {:error, ^refusal} = validate.(environment: :dev, repo_config: @replica_repo)

        assert {:error, "target database codex_pooler_replica must be reached over a loopback host (a port-forward is fine)"} =
                 validate.(environment: :dev, target_database: @replica, repo_config: Keyword.put(@replica_repo, :hostname, "db.example.com"))

        assert :ok = validate.(environment: :dev, repo_config: [database: "codex_pooler_dev", hostname: "127.0.0.1"])
      end
    end

    test "the fixture Mix tasks parse --target-database and stop at the environment guard outside development" do
      for {task, message} <- [
            {Mix.Tasks.Dev.RoutingStrategyFixture, ~r/routing strategy fixture runs only with MIX_ENV=dev/},
            {Mix.Tasks.Dev.OpenaiV1Fixture, ~r/OpenAI V1 fixture runs only with MIX_ENV=dev/},
            {Mix.Tasks.Dev.McpFixture, ~r/MCP fixture runs only with MIX_ENV=dev/}
          ] do
        assert_raise Mix.Error, message, fn -> task.run(["status", "--target-database", @replica]) end
      end
    end
  end

  describe "upstream origin" do
    test "accepts loopback and in-cluster service origins" do
      for origin <- [
            "http://127.0.0.1:4058",
            "http://localhost:4058/",
            @in_cluster,
            "http://fake-upstream.codex-pooler.svc:4058",
            "http://fake-upstream.codex-pooler.svc.cluster.local:4058"
          ] do
        assert {:ok, accepted} = LocalTarget.upstream_base_url(origin, "http://127.0.0.1:4057")
        assert accepted == String.trim_trailing(origin, "/")
      end

      assert {:ok, "http://127.0.0.1:4057"} = LocalTarget.upstream_base_url(nil, "http://127.0.0.1:4057")
    end

    test "refuses public hosts and anything but an origin" do
      for origin <- [
            "https://chatgpt.com",
            "http://chatgpt.com:80",
            "http://auth.openai.com:80",
            "http://fake-upstream.codex-pooler:4058",
            "http://203.0.113.10:4058",
            "https://fake-upstream:4058",
            "http://fake-upstream:4058/backend-api",
            "http://user@fake-upstream:4058",
            "http://fake-upstream:4058?x=1",
            "http://Fake_Upstream:4058"
          ] do
        assert {:error, "upstream base URL must be an origin-only loopback HTTP URL with a port, or an in-cluster service origin"} =
                 LocalTarget.upstream_base_url(origin, "http://127.0.0.1:4057")
      end
    end
  end

  describe "fixtures built with an in-cluster upstream" do
    setup do
      _owner = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      root = Path.join(System.tmp_dir!(), "cxp-local-target-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    test "the routing strategy fixture points every synthetic identity at the in-cluster origin", %{root: root} do
      options = [environment: :test, allow_test_database: true, receipt_path: Path.join(root, "routing.json"), upstream_base_url: @in_cluster]

      assert {:ok, %{status: "ready", assignment_count: count}} = RoutingStrategyFixture.acquire(options)
      pool = Repo.get_by!(Pool, slug: Names.pool_slug())
      base_urls = pool_identity_base_urls(pool)

      assert length(base_urls) == count
      assert Enum.uniq(base_urls) == [@in_cluster]
      assert {:ok, %{status: "released"}} = RoutingStrategyFixture.release(options)
    end

    test "the OpenAI V1 fixture points its synthetic identity at the in-cluster origin", %{root: root} do
      options = [environment: :test, allow_test_database: true, receipt_path: Path.join(root, "v1.json"), upstream_base_url: @in_cluster]

      assert {:ok, %{status: "ready", pool_slug: slug}} = OpenAIV1Fixture.acquire(options)
      assert [@in_cluster] = Pool |> Repo.get_by!(slug: slug) |> pool_identity_base_urls()
      assert {:ok, %{status: "released"}} = OpenAIV1Fixture.release(options)
    end

    test "a public upstream host is refused before any receipt or database write", %{root: root} do
      receipt = Path.join(root, "refused.json")
      options = [environment: :test, allow_test_database: true, receipt_path: receipt, upstream_base_url: "http://chatgpt.com:80"]

      assert {:error, _message} = RoutingStrategyFixture.acquire(options)
      assert {:error, _message} = OpenAIV1Fixture.acquire(options)
      refute File.exists?(receipt)
      refute Repo.get_by(Pool, slug: Names.pool_slug())
    end
  end

  defp pool_identity_base_urls(%Pool{id: pool_id}) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where: assignment.pool_id == ^pool_id and assignment.status == "active",
        select: fragment("?->>'base_url'", identity.metadata)
    )
  end
end
