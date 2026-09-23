defmodule CodexPooler.Dev.SeedUpstreamTargetsTest do
  # Seeded synthetic identities must point at a fake that exists: the local
  # perf fake for `make dev`, a replica's in-cluster fake when given. Real
  # identities go into their own seeded Pool, and the import task refuses a
  # Pool that serves from synthetic upstreams, so a real copy never shares a
  # model with a fake source.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [start_upstream: 1, stream_success_sse: 0]

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Dev.{Seeds, UpstreamAccountBundle}
  alias CodexPooler.Dev.Seeds.RealTraffic
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias Mix.Tasks.Dev.Seed, as: SeedTask

  @in_cluster "http://fake-upstream:4058"
  @password "synthetic-bundle-password-12345"

  setup do
    reset_bootstrap_state_fixture!()
    :ok
  end

  test "perf seeds every synthetic source at the given in-cluster fake" do
    result = Seeds.perf(upstream_base_url: @in_cluster)

    assert length(result.assignments) == 12
    assert resolved_base_urls(result.pool) == [@in_cluster]
    assert Enum.all?(result.assignments, &(&1.metadata["websocket_url"] == "ws://fake-upstream:4058/ws"))
  end

  test "a perf-seeded Pool serves a gateway turn from a seeded identity through the given fake", %{conn: conn} do
    upstream = start_upstream(stream_success_sse())
    result = Seeds.perf(upstream_base_url: FakeUpstream.url(upstream))
    [raw_key] = for "CODEX_POOLER_PERF_API_KEY=" <> key <- String.split(File.read!("tmp/gateway-perf/bootstrap/perf.env"), "\n"), do: key

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> raw_key)
      |> post("/backend-api/codex/responses", %{"model" => "gpt-6-luna", "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "seed"}]}], "stream" => true})

    assert response.status == 200
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^result.pool.id))
    assert request.status == "succeeded"
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.upstream_identity_id in Enum.map(result.upstream_identities, & &1.id)
    assert Enum.count(FakeUpstream.requests(upstream), &(&1.path == "/backend-api/codex/responses")) == 1
  end

  test "full seeds every synthetic identity at the local perf fake by default, never at the provider" do
    default = Seeds.full()
    assert Enum.all?(default.upstream_identities, &(&1.metadata["base_url"] == "http://127.0.0.1:4058"))
    assert pool_by_slug("dev-primary") |> resolved_base_urls() == ["http://127.0.0.1:4058"]
  end

  test "full seeds every synthetic identity at the given in-cluster fake" do
    given = Seeds.full(upstream_base_url: @in_cluster)
    assert Enum.all?(given.upstream_identities, &(&1.metadata["base_url"] == @in_cluster))
    assert pool_by_slug("dev-primary") |> resolved_base_urls() == [@in_cluster]
  end

  test "a public upstream host is refused before any seed row is written" do
    assert_raise ArgumentError, ~r/in-cluster service origin/, fn -> Seeds.perf(upstream_base_url: "https://chatgpt.com") end
    refute pool_by_slug("dev-perf-pool")

    assert_raise Mix.Error, ~r/in-cluster service origin/, fn -> SeedTask.run(["full", "--upstream-base-url", "http://chatgpt.com:80"]) end
    assert_raise Mix.Error, ~r/usage: mix dev.seed/, fn -> SeedTask.run(["real_traffic", "--upstream-base-url", @in_cluster]) end
    refute pool_by_slug("dev-primary")
  end

  test "real_traffic seeds an empty dedicated Pool and keeps exactly one active seed key across reruns" do
    on_exit(fn -> File.rm(RealTraffic.env_path()) end)

    first = Seeds.real_traffic()
    second = Seeds.real_traffic()

    assert first.pool.id == second.pool.id
    assert %Pool{slug: "dev-real-traffic", status: "active"} = second.pool
    assert second.revoked_api_keys == 1
    refute Repo.exists?(from(a in PoolUpstreamAssignment, where: a.pool_id == ^second.pool.id))
    assert [active] = Repo.all(from(k in APIKey, where: k.pool_id == ^second.pool.id and k.status == "active"))
    assert active.id == second.api_key.id

    assert File.stat!(Path.dirname(RealTraffic.env_path())).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(RealTraffic.env_path()).mode |> Bitwise.band(0o777) == 0o600
    assert File.read!(RealTraffic.env_path()) =~ "CODEX_POOLER_REAL_TRAFFIC_POOL_SLUG=dev-real-traffic\n"
  end

  test "the import task accepts the real-traffic Pool and refuses the seeded synthetic Pool" do
    on_exit(fn -> File.rm(RealTraffic.env_path()) end)

    perf = Seeds.perf(upstream_base_url: @in_cluster)
    real = Seeds.real_traffic()
    scope = Scope.for_user(Repo.get!(User, real.pool.created_by_user_id), ["instance_owner"])
    {bundle, account_id} = bundle!()
    {:ok, %{import_options: options}} = UpstreamAccountBundle.parse_import_args(["b.bin", "--pool", "x"])

    assert {:error, %{code: :target_pool_has_synthetic_sources}} = UpstreamAccountBundle.import_bundle(bundle, perf.pool, scope, @password, options)
    assert {:ok, %{imported: 1}} = UpstreamAccountBundle.import_bundle(bundle, real.pool, scope, @password, options)

    identity = Upstreams.get_upstream_identity_by_chatgpt_account(account_id)
    assert [%{pool_id: pool_id}] = Repo.all(from(a in PoolUpstreamAssignment, where: a.upstream_identity_id == ^identity.id))
    assert pool_id == real.pool.id
  end

  defp pool_by_slug(slug), do: Repo.get_by(Pool, slug: slug)

  # The base URL the gateway would dispatch to for each active assignment.
  defp resolved_base_urls(%Pool{id: pool_id}) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where: assignment.pool_id == ^pool_id,
        select: {identity, assignment}
    )
    |> Enum.map(fn {identity, assignment} -> EndpointMetadata.base_url(identity, assignment) end)
    |> Enum.uniq()
  end

  defp bundle! do
    source_pool = pool_fixture()
    unique = System.unique_integer([:positive])
    account_id = "acct_seed_target_#{unique}"

    fixture =
      active_upstream_assignment_fixture(source_pool, %{
        chatgpt_account_id: account_id,
        account_email: "seed-target-#{unique}@example.com",
        account_label: "Synthetic seed target #{unique}",
        access_token: "synthetic-access-token-#{unique}"
      })

    fixture.identity |> Ecto.Changeset.change() |> UpstreamIdentity.put_credential_provenance(:codex_chatgpt) |> Repo.update!()
    assert {:ok, bundle, %{exported: 1}} = UpstreamAccountBundle.export_bundle(source_pool, @password, refresh_tokens: :omit)

    Repo.delete!(Repo.reload!(fixture.assignment))
    Repo.delete_all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^fixture.identity.id)
    Repo.delete!(Repo.reload!(fixture.identity))

    {bundle, account_id}
  end
end
