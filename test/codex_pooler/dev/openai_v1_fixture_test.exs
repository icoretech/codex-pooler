defmodule CodexPooler.Dev.OpenAIV1FixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.OpenAIV1Fixture
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{CandidateEligibility, ModelMetadata}
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
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

    assert Repo.aggregate(from(model in Model, where: model.pool_id == ^pool_id), :count) == 4

    assert %Model{supports_responses: true, supports_streaming: true} =
             Repo.get_by(Model, pool_id: pool_id, exposed_model_id: "gpt-5.6-terra")

    assert %Model{
             supports_responses: true,
             supports_streaming: true,
             supports_tools: true,
             supports_reasoning: true,
             metadata: text_metadata
           } =
             Repo.get_by(Model, pool_id: pool_id, exposed_model_id: "gpt-5.5")

    assert %{"source_assignment_models" => source_models} = text_metadata

    assert %{"input_modalities" => ["text", "image"], "supports_tools" => true} =
             source_models[setup["created"]["assignment_id"]]

    assert %Model{
             supports_responses: true,
             supports_streaming: true,
             supports_tools: true,
             supports_reasoning: false
           } = Repo.get_by(Model, pool_id: pool_id, exposed_model_id: "gpt-image-1")

    assert %Model{
             supports_responses: false,
             supports_streaming: false,
             supports_tools: false,
             supports_reasoning: false
           } = Repo.get_by(Model, pool_id: pool_id, exposed_model_id: "gpt-4o-transcribe")

    assert Repo.aggregate(from(key in APIKey, where: key.pool_id == ^pool_id), :count) == 1

    assert Repo.aggregate(
             from(window in AccountQuotaWindow,
               where: window.upstream_identity_id == ^identity_id
             ),
             :count
           ) == 10

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

  test "fixture reasoning metadata admits the exact Codex none request only when the assignment advertises it",
       context do
    assert {:ok, %{status: "ready"}} = OpenAIV1Fixture.acquire(context.options)

    setup = context.receipt_path |> File.read!() |> Jason.decode!()

    assert %Pool{} = pool = Repo.get_by(Pool, slug: @pool_slug)

    model = Repo.get_by(Model, pool_id: pool.id, exposed_model_id: "gpt-5.5")
    assert %Model{} = model

    assignment = Repo.get(PoolUpstreamAssignment, setup["created"]["assignment_id"])
    assert %PoolUpstreamAssignment{} = assignment

    identity = Repo.get(UpstreamIdentity, assignment.upstream_identity_id)
    assert %UpstreamIdentity{} = identity

    assert {:ok, [{%PoolUpstreamAssignment{id: assignment_id}, %UpstreamIdentity{}}]} =
             exact_codex_reasoning_result(model, assignment, identity)

    assert assignment_id == assignment.id
    assert model.supports_reasoning
    assert model |> ModelMetadata.metadata() |> ModelMetadata.supports_reasoning?()
    assert ModelMetadata.reasoning_levels_and_default(model) == {["none"], "none"}

    source_metadata = ModelMetadata.selected_assignment_metadata(model, assignment.id)

    assert ModelMetadata.supports_reasoning?(source_metadata)
    assert source_metadata["supported_reasoning_levels"] == ["none"]

    prechange_model =
      model |> prechange_fixture_model(assignment.id) |> Map.put(:supports_reasoning, false)

    assert_reasoning_rejected(prechange_model, assignment, identity)

    for assignment_reasoning <- [nil, false, "invalid", []] do
      top_level_only_model =
        model
        |> Map.put(:supports_reasoning, true)
        |> put_assignment_reasoning(assignment.id, assignment_reasoning)

      refute ModelMetadata.supports_reasoning?(
               ModelMetadata.selected_assignment_metadata(top_level_only_model, assignment.id)
             )

      assert_reasoning_rejected(top_level_only_model, assignment, identity)
    end

    assert {:ok, %{status: "released"}} = OpenAIV1Fixture.release(context.options)
  end

  test "rejects a non-loopback upstream before receipt or database mutation", context do
    options = Keyword.put(context.options, :upstream_base_url, "https://example.com")

    assert {:error, "upstream base URL must be an origin-only loopback HTTP URL with a port"} =
             OpenAIV1Fixture.acquire(options)

    refute File.exists?(context.receipt_path)
    refute Repo.get_by(Pool, slug: @pool_slug)
    refute Repo.get_by(UpstreamIdentity, chatgpt_account_id: @account_id)
  end

  test "allows only explicitly authorized isolated QA databases in development" do
    assert :ok =
             OpenAIV1Fixture.validate_environment(
               environment: :dev,
               allow_isolated_dev_database: false,
               repo_config: [database: "codex_pooler_dev"]
             )

    assert :ok =
             OpenAIV1Fixture.validate_environment(
               environment: :dev,
               allow_isolated_dev_database: true,
               repo_config: [database: "codex_pooler_relqa_fixture_12345678"]
             )

    for database <- [
          "codex_pooler_relqa_short",
          "codex_pooler_relqa_upper_CASE_12345678",
          "other_database"
        ] do
      assert {:error, "OpenAI V1 fixture requires database codex_pooler_dev"} =
               OpenAIV1Fixture.validate_environment(
                 environment: :dev,
                 allow_isolated_dev_database: false,
                 repo_config: [database: database]
               )
    end

    assert {:error, "OpenAI V1 fixture requires database codex_pooler_dev"} =
             OpenAIV1Fixture.validate_environment(
               environment: :dev,
               allow_isolated_dev_database: true,
               repo_config: [database: "other_database"]
             )
  end

  test "refuses a second lease that targets another loopback origin", context do
    assert {:ok, %{leases: 1}} = OpenAIV1Fixture.acquire(context.options)

    other = Keyword.put(context.options, :upstream_base_url, "http://127.0.0.1:4058")

    assert {:error, "OpenAI V1 fixture is leased for another upstream origin"} =
             OpenAIV1Fixture.acquire(other)

    assert {:ok, %{status: "released"}} = OpenAIV1Fixture.release(context.options)
  end

  test "request compression opt-in restores the exact prior routing setting", context do
    baseline_updated_at = ~U[2026-08-01 12:34:56.123456Z]

    pool = pool_fixture(%{slug: @pool_slug})

    %RoutingSettings{pool_id: pool.id}
    |> RoutingSettings.changeset(%{
      routing_strategy: "quota_first",
      bridge_ring_size: 7,
      sticky_websocket_sessions: false,
      sticky_http_sessions: true,
      prompt_cache_affinity_enabled: false,
      v1_compatibility_enabled: false,
      request_compression_enabled: false,
      allow_image_generation: false,
      metadata: %{"baseline" => true},
      created_at: ~U[2026-08-01 12:00:00.000000Z],
      updated_at: baseline_updated_at
    })
    |> Repo.insert!()

    options = Keyword.put(context.options, :request_compression, :enabled)

    assert {:ok, %{status: "ready"}} = OpenAIV1Fixture.acquire(options)

    assert %RoutingSettings{request_compression_enabled: true} =
             Repo.get!(RoutingSettings, pool.id)

    assert {:error, "OpenAI V1 fixture is leased with another request compression mode"} =
             OpenAIV1Fixture.acquire(context.options)

    assert {:ok, %{status: "released"}} = OpenAIV1Fixture.release(options)

    assert %RoutingSettings{
             routing_strategy: "quota_first",
             bridge_ring_size: 7,
             sticky_websocket_sessions: false,
             sticky_http_sessions: true,
             prompt_cache_affinity_enabled: false,
             v1_compatibility_enabled: false,
             request_compression_enabled: false,
             allow_image_generation: false,
             metadata: %{"baseline" => true},
             updated_at: ^baseline_updated_at
           } = Repo.get!(RoutingSettings, pool.id)
  end

  defp assert_private_mode(path, expected) do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == expected
  end

  defp exact_codex_reasoning_result(model, assignment, identity) do
    payload = %{"model" => model.exposed_model_id, "reasoning" => %{"effort" => "none"}}
    request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

    FilterInput.new(%{
      model: model,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options,
      candidates: [{assignment, identity}]
    })
    |> CandidateEligibility.filter_runtime_compatible_candidates()
  end

  defp assert_reasoning_rejected(model, assignment, identity) do
    assert %{} = get_in(model.metadata, ["source_assignment_models", assignment.id])

    assert {:error,
            %{
              status: 503,
              code: "no_compatible_backend",
              message: "no backend currently supports the requested model capabilities"
            }} = exact_codex_reasoning_result(model, assignment, identity)
  end

  defp prechange_fixture_model(model, assignment_id) do
    model
    |> Map.update!(:metadata, fn metadata ->
      metadata
      |> Map.delete("capabilities")
      |> Map.delete("supported_reasoning_levels")
      |> Map.delete("default_reasoning_level")
      |> put_assignment_reasoning_metadata(assignment_id, nil)
    end)
  end

  defp put_assignment_reasoning(model, assignment_id, value) do
    Map.update!(model, :metadata, &put_assignment_reasoning_metadata(&1, assignment_id, value))
  end

  defp put_assignment_reasoning_metadata(metadata, assignment_id, value) do
    update_in(metadata["source_assignment_models"][assignment_id], fn metadata ->
      metadata =
        metadata
        |> Map.delete("supported_reasoning_levels")
        |> Map.delete("default_reasoning_level")

      case value do
        nil -> Map.delete(metadata, "capabilities")
        _value -> put_in(metadata, ["capabilities", "reasoning"], value)
      end
    end)
  end

  defp random_hex(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
