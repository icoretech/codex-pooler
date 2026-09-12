defmodule CodexPooler.Dev.RoutingStrategyFixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.RoutingStrategyFixture
  alias CodexPooler.Dev.RoutingStrategyFixture.Names
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @strategies ~w(bridge_ring deterministic_rotation least_recent_success quota_first)
  @ring_size 3
  @assignments 4
  @test_correlation_prefix "routing-strategy-fixture-test"

  setup do
    _owner = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    root = Path.join(System.tmp_dir!(), "cxp-routing-strategy-fixture-#{random_hex(8)}")
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

  describe "fixture lease" do
    test "acquire differentiates the assignments and release restores the exact prior routing settings",
         context do
      baseline_updated_at = ~U[2026-08-01 12:34:56.123456Z]
      pool = pool_fixture(%{slug: Names.pool_slug()})

      %RoutingSettings{pool_id: pool.id}
      |> RoutingSettings.changeset(%{
        routing_strategy: "deterministic_rotation",
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

      options = Keyword.put(context.options, :routing_strategy, "quota_first")

      assert {:ok, status} = RoutingStrategyFixture.acquire(options)
      assert status.status == "ready"
      assert status.leases == 1
      assert status.routing_strategy == "quota_first"
      assert status.assignment_count == @assignments
      assert status.bridge_ring_size == @ring_size
      refute Map.has_key?(status, :api_key)

      assert_private_mode(context.root, 0o700)
      assert_private_mode(context.receipt_path, 0o600)

      assert %RoutingSettings{routing_strategy: "quota_first", bridge_ring_size: @ring_size} =
               Repo.get!(RoutingSettings, pool.id)

      fixture = load_fixture()

      # The ring is smaller than the candidate set on purpose: truncation is the
      # only situation where the strategies differ in the selected assignment.
      assert length(fixture.candidates) == @assignments
      assert @assignments > @ring_size

      assert Enum.all?(fixture.assignments, fn assignment ->
               assignment.status == "active" and assignment.health_status == "active" and
                 assignment.eligibility_status == "eligible"
             end)

      # Differentiation is the fixture's contract: without distinct quota
      # remaining percents and distinct succeeded-attempt times, quota_first and
      # least_recent_success both score every assignment 0 and collapse into the
      # default rendezvous ordering.
      used_percents = used_percents_by_index(fixture)
      assert map_size(used_percents) == @assignments
      assert used_percents |> Map.values() |> Enum.uniq() |> length() == @assignments

      completions = success_completions_by_index(fixture)
      assert map_size(completions) == @assignments
      assert completions |> Map.values() |> Enum.uniq() |> length() == @assignments

      # The two ladders are deliberately opposed, so neither strategy can
      # silently produce the other's order.
      assert quota_first_expected_order(fixture) ==
               Enum.reverse(least_recent_success_expected_order(fixture))

      assert {:error, "routing strategy fixture is leased with another routing strategy"} =
               RoutingStrategyFixture.acquire(
                 Keyword.put(context.options, :routing_strategy, "bridge_ring")
               )

      assert {:ok, second} = RoutingStrategyFixture.acquire(options)
      assert second.leases == 2

      assert {:ok, retained} = RoutingStrategyFixture.release(context.options)
      assert retained.leases == 1
      assert Repo.get_by(Pool, slug: Names.pool_slug())

      assert {:ok, released} = RoutingStrategyFixture.release(context.options)
      assert released == %{status: "released", leases: 0, receipt_path: context.receipt_path}
      refute File.exists?(context.receipt_path)

      assert %RoutingSettings{
               routing_strategy: "deterministic_rotation",
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

      # The pre-existing Pool survives; everything the fixture created is gone.
      assert Repo.get_by(Pool, slug: Names.pool_slug())
      assert fixture_identities() == []

      assert Repo.all(
               from assignment in PoolUpstreamAssignment,
                 where: assignment.pool_id == ^pool.id
             ) == []
    end

    test "rejects an unknown routing strategy before any receipt or database mutation", context do
      options = Keyword.put(context.options, :routing_strategy, "round_robin")

      assert {:error, message} = RoutingStrategyFixture.acquire(options)
      assert message =~ "routing strategy must be one of"

      refute File.exists?(context.receipt_path)
      refute Repo.get_by(Pool, slug: Names.pool_slug())
    end

    test "rejects an assignment count that cannot reach ring truncation", context do
      options =
        context.options
        |> Keyword.put(:routing_strategy, "quota_first")
        |> Keyword.put(:assignments, 3)

      assert {:error, message} = RoutingStrategyFixture.acquire(options)
      assert message =~ "ring truncation is unreachable below 4"

      refute File.exists?(context.receipt_path)
      refute Repo.get_by(Pool, slug: Names.pool_slug())
    end
  end

  describe "strategy observability" do
    # Four acquire/release cycles: the strategy is a leased setting, so the only
    # honest way to compare strategies is to provision the Pool under each one.
    @tag timeout: 120_000
    test "each strategy ranks the fixture Pool by its own key and drops its last candidate outside the ring",
         context do
      rings =
        Map.new(@strategies, fn strategy ->
          with_fixture(context.options, strategy, fn fixture ->
            seed = "routing-strategy-#{strategy}"
            plan = plan_route(fixture, seed)

            assert plan.strategy == strategy
            assert plan.bridge_ring_size == @ring_size
            assert length(plan.candidates) == @ring_size

            expected = expected_order(fixture, strategy, seed)
            ring = Enum.take(expected, @ring_size)
            [dropped] = Enum.drop(expected, @ring_size)

            assert plan_indexes(fixture, plan) == ring
            assert plan.selected_assignment_id == assignment_id_for_index(fixture, hd(ring))

            # More candidates than the ring size: the last-ranked candidate is
            # not merely last, it is absent from the plan entirely.
            refute assignment_id_for_index(fixture, dropped) in Enum.map(
                     plan.candidates,
                     fn {assignment, _identity} -> assignment.id end
                   )

            {strategy, ring}
          end)
        end)

      # The two evidence-driven strategies rank by their own key, in opposite
      # directions, and the ring they truncate to is therefore different.
      assert rings["quota_first"] == [1, 2, 3]
      assert rings["least_recent_success"] == [4, 3, 2]
      assert rings["quota_first"] != rings["least_recent_success"]
    end

    @tag timeout: 120_000
    test "prompt cache locality makes every strategy inert", context do
      Enum.each(@strategies, fn strategy ->
        with_fixture(context.options, strategy, fn fixture ->
          seed = "routing-locality-#{strategy}"
          strategy_order = expected_order(fixture, strategy, seed)

          # Pick a cache key whose locality order starts somewhere else, so
          # "the strategy was ignored" is a discriminating claim rather than a
          # coincidence.
          prompt_cache_key = prompt_cache_key_diverging_from(fixture, hd(strategy_order))
          locality_order = locality_order(fixture, prompt_cache_key)

          plan = plan_route(fixture, seed, prompt_cache_key: prompt_cache_key)

          assert plan.locality.status == "applied"
          assert plan.strategy == strategy
          assert plan_indexes(fixture, plan) == Enum.take(locality_order, @ring_size)

          assert plan.selected_assignment_id ==
                   assignment_id_for_index(fixture, hd(locality_order))

          refute plan.selected_assignment_id ==
                   assignment_id_for_index(fixture, hd(strategy_order))
        end)
      end)
    end
  end

  defp with_fixture(options, strategy, function) do
    options = Keyword.put(options, :routing_strategy, strategy)

    assert {:ok, %{status: "ready"}} = RoutingStrategyFixture.acquire(options)

    result = function.(load_fixture())

    delete_test_requests!()

    assert {:ok, %{status: "released"}} = RoutingStrategyFixture.release(options)

    result
  end

  defp load_fixture do
    pool = Repo.get_by!(Pool, slug: Names.pool_slug())
    api_key = Repo.one!(from key in APIKey, where: key.pool_id == ^pool.id)
    model = Repo.one!(from model in Model, where: model.pool_id == ^pool.id)

    identities = fixture_identities()

    candidates =
      Enum.map(identities, fn identity ->
        assignment =
          Repo.get_by!(PoolUpstreamAssignment,
            pool_id: pool.id,
            upstream_identity_id: identity.id
          )

        {assignment, identity}
      end)

    %{
      pool: pool,
      auth: %{pool: pool, api_key: api_key},
      model: model,
      identities: identities,
      assignments: Enum.map(candidates, fn {assignment, _identity} -> assignment end),
      candidates: candidates
    }
  end

  defp fixture_identities do
    account_ids = Names.account_ids(@assignments)

    Repo.all(
      from identity in UpstreamIdentity,
        where: identity.chatgpt_account_id in ^account_ids,
        order_by: [asc: identity.chatgpt_account_id]
    )
  end

  defp plan_route(fixture, seed, opts \\ []) do
    payload =
      case Keyword.fetch(opts, :prompt_cache_key) do
        {:ok, key} -> %{"prompt_cache_key" => key}
        :error -> %{}
      end

    request =
      request_fixture(fixture.auth, %{
        model_id: fixture.model.id,
        requested_model: fixture.model.exposed_model_id,
        correlation_id: "#{@test_correlation_prefix}-#{System.unique_integer([:positive])}"
      })

    request_options =
      RequestOptions.build(%{request_id: seed}, "/backend-api/codex/responses", payload)

    BridgeRing.plan_route(%{
      auth: fixture.auth,
      model: fixture.model,
      candidates: fixture.candidates,
      route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
      request_options: request_options
    })
  end

  defp delete_test_requests! do
    pattern = @test_correlation_prefix <> "%"

    Repo.delete_all(from request in Request, where: like(request.correlation_id, ^pattern))
  end

  defp expected_order(fixture, "quota_first", _seed), do: quota_first_expected_order(fixture)

  defp expected_order(fixture, "least_recent_success", _seed),
    do: least_recent_success_expected_order(fixture)

  defp expected_order(_fixture, "deterministic_rotation", seed) do
    indexes = Enum.to_list(1..@assignments)
    {head, tail} = Enum.split(indexes, :erlang.phash2(seed, @assignments))
    tail ++ head
  end

  defp expected_order(fixture, "bridge_ring", seed) do
    fixture.candidates
    |> Enum.sort_by(fn {assignment, _identity} -> -rendezvous_score(seed, assignment.id) end)
    |> Enum.map(&index_for_candidate(fixture, &1))
  end

  # Highest remaining quota percent first.
  defp quota_first_expected_order(fixture) do
    fixture
    |> used_percents_by_index()
    |> Enum.sort_by(fn {_index, used_percent} -> Decimal.to_float(used_percent) end)
    |> Enum.map(fn {index, _used_percent} -> index end)
  end

  # Oldest succeeded attempt first.
  defp least_recent_success_expected_order(fixture) do
    fixture
    |> success_completions_by_index()
    |> Enum.sort_by(fn {_index, completed_at} -> DateTime.to_unix(completed_at, :microsecond) end)
    |> Enum.map(fn {index, _completed_at} -> index end)
  end

  defp locality_order(fixture, prompt_cache_key) do
    seed = prompt_cache_seed(fixture, prompt_cache_key)

    fixture.candidates
    |> Enum.sort_by(fn {assignment, _identity} ->
      {-rendezvous_score(seed, assignment.id), assignment.id}
    end)
    |> Enum.map(&index_for_candidate(fixture, &1))
  end

  defp prompt_cache_key_diverging_from(fixture, strategy_head_index) do
    Enum.find_value(1..1_000, fn attempt ->
      key = "routing-strategy-cache-key-#{attempt}"

      if fixture |> locality_order(key) |> hd() != strategy_head_index, do: key
    end) || raise "could not find a prompt cache key diverging from index #{strategy_head_index}"
  end

  defp prompt_cache_seed(fixture, prompt_cache_key) do
    [
      fixture.pool.id,
      fixture.auth.api_key.id,
      fixture.model.exposed_model_id,
      "prompt_cache",
      prompt_cache_key
      |> String.trim()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    ]
    |> Enum.join(":")
  end

  defp used_percents_by_index(fixture) do
    identity_ids = Enum.map(fixture.identities, & &1.id)

    Repo.all(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id in ^identity_ids and window.quota_scope == "account",
        select: {window.upstream_identity_id, window.used_percent}
    )
    |> Map.new(fn {identity_id, used_percent} ->
      {index_for_identity_id(fixture, identity_id), used_percent}
    end)
  end

  defp success_completions_by_index(fixture) do
    assignment_ids = Enum.map(fixture.assignments, & &1.id)

    Repo.all(
      from attempt in Attempt,
        where:
          attempt.pool_upstream_assignment_id in ^assignment_ids and attempt.status == "succeeded",
        select: {attempt.pool_upstream_assignment_id, max(attempt.completed_at)},
        group_by: attempt.pool_upstream_assignment_id
    )
    |> Map.new(fn {assignment_id, completed_at} ->
      {index_for_assignment_id(fixture, assignment_id), completed_at}
    end)
  end

  defp plan_indexes(fixture, plan) do
    Enum.map(plan.candidates, &index_for_candidate(fixture, &1))
  end

  defp index_for_candidate(fixture, {assignment, _identity}),
    do: index_for_assignment_id(fixture, assignment.id)

  defp index_for_assignment_id(fixture, assignment_id) do
    1 + Enum.find_index(fixture.assignments, &(&1.id == assignment_id))
  end

  defp index_for_identity_id(fixture, identity_id) do
    1 + Enum.find_index(fixture.identities, &(&1.id == identity_id))
  end

  defp assignment_id_for_index(fixture, index),
    do: fixture.assignments |> Enum.at(index - 1) |> Map.fetch!(:id)

  defp rendezvous_score(seed, assignment_id) do
    :crypto.hash(:sha256, [to_string(seed), ?:, assignment_id])
    |> :binary.decode_unsigned()
  end

  defp assert_private_mode(path, expected) do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == expected
  end

  defp random_hex(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
