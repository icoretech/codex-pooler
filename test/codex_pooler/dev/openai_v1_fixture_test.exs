defmodule CodexPooler.Dev.OpenAIV1FixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.OpenAIV1Fixture
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @pool_slug "openai-v1-smoke"
  @account_id "openai-v1-smoke"

  setup do
    _owner = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    root = Path.join(System.tmp_dir!(), "cxp-openai-v1-fixture-#{random_hex(8)}")
    receipt_path = Path.join(root, "setup.json")

    on_exit(fn -> File.rm_rf(root) end)

    %{
      options: [
        environment: :test,
        allow_test_database: true,
        receipt_path: receipt_path,
        upstream_base_url: "http://127.0.0.1:4057"
      ],
      receipt_path: receipt_path,
      root: root
    }
  end

  test "acquire and final release preserve a reference-counted exact fixture lease", context do
    assert {:ok, first} = OpenAIV1Fixture.acquire(context.options)
    assert first.status == "ready"
    assert first.leases == 1
    refute Map.has_key?(first, :api_key)

    assert_private_mode(context.root, 0o700)
    assert_private_mode(context.receipt_path, 0o600)

    setup = context.receipt_path |> File.read!() |> Jason.decode!()
    assert setup["state"] == "ready"
    assert setup["leases"] == 1
    assert setup["upstream_base_url"] == "http://127.0.0.1:4057"
    assert is_binary(setup["api_key"])
    assert setup["api_key"] != ""

    assert %Pool{id: pool_id, status: "active"} = Repo.get_by(Pool, slug: @pool_slug)

    assert %UpstreamIdentity{id: identity_id, status: "active"} =
             Repo.get_by(UpstreamIdentity, chatgpt_account_id: @account_id)

    assert %PoolUpstreamAssignment{status: "active"} =
             Repo.get_by(PoolUpstreamAssignment,
               pool_id: pool_id,
               upstream_identity_id: identity_id
             )

    assert %RoutingSettings{allow_image_generation: true, v1_compatibility_enabled: true} =
             Repo.get(RoutingSettings, pool_id)

    assert Repo.aggregate(from(model in Model, where: model.pool_id == ^pool_id), :count) == 3

    assert %Model{metadata: text_metadata} =
             Repo.get_by(Model, pool_id: pool_id, exposed_model_id: "gpt-5.5")

    assert %{"source_assignment_models" => source_models} = text_metadata

    assert %{"input_modalities" => ["text", "image"], "supports_tools" => true} =
             source_models[setup["created"]["assignment_id"]]

    assert Repo.aggregate(from(key in APIKey, where: key.pool_id == ^pool_id), :count) == 1

    assert Repo.aggregate(
             from(window in AccountQuotaWindow,
               where: window.upstream_identity_id == ^identity_id
             ),
             :count
           ) == 8

    assert {:ok, second} = OpenAIV1Fixture.acquire(context.options)
    assert second.leases == 2

    assert {:ok, retained} = OpenAIV1Fixture.release(context.options)
    assert retained.status == "ready"
    assert retained.leases == 1
    assert File.exists?(context.receipt_path)
    assert Repo.get_by(Pool, slug: @pool_slug)

    assert {:ok, released} = OpenAIV1Fixture.release(context.options)
    assert released == %{status: "released", leases: 0, receipt_path: context.receipt_path}
    refute File.exists?(context.receipt_path)
    refute Repo.get_by(Pool, slug: @pool_slug)
    refute Repo.get_by(UpstreamIdentity, chatgpt_account_id: @account_id)
  end

  test "rejects a non-loopback upstream before receipt or database mutation", context do
    options = Keyword.put(context.options, :upstream_base_url, "https://example.com")

    assert {:error, "upstream base URL must be an origin-only loopback HTTP URL with a port"} =
             OpenAIV1Fixture.acquire(options)

    refute File.exists?(context.receipt_path)
    refute Repo.get_by(Pool, slug: @pool_slug)
    refute Repo.get_by(UpstreamIdentity, chatgpt_account_id: @account_id)
  end

  test "refuses a second lease that targets another loopback origin", context do
    assert {:ok, %{leases: 1}} = OpenAIV1Fixture.acquire(context.options)

    other = Keyword.put(context.options, :upstream_base_url, "http://127.0.0.1:4058")

    assert {:error, "OpenAI V1 fixture is leased for another upstream origin"} =
             OpenAIV1Fixture.acquire(other)

    assert {:ok, %{status: "released"}} = OpenAIV1Fixture.release(context.options)
  end

  defp assert_private_mode(path, expected) do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == expected
  end

  defp random_hex(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
