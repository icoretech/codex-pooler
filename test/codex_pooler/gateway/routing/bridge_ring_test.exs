defmodule CodexPooler.Gateway.Routing.BridgeRingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.{PayloadNormalizer, RequestOptions}

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Routing.{BridgeRing, CandidateEligibility, RoutePlanInput}
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.SessionContinuity, as: RoutingSessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  alias Ecto.Adapters.SQL.Sandbox

  describe "plan_route/1 leaf ordering" do
    test "bridge_ring keeps rendezvous ordering stable for the same seed and candidate set" do
      setup = routing_setup(3)
      seed = "bridge-ring-stable-seed"

      expected_ids = rendezvous_order_ids(setup.candidates, seed)

      first_plan = plan_for(setup, "bridge_ring", seed)
      second_plan = plan_for(setup, "bridge_ring", seed)

      assert candidate_ids(first_plan.candidates) == expected_ids
      assert candidate_ids(second_plan.candidates) == expected_ids
      assert first_plan.selected_assignment_id == hd(expected_ids)
      assert second_plan.selected_assignment_id == hd(expected_ids)
    end

    test "deterministic_rotation rotates the current candidate list by seed" do
      setup = routing_setup(4)
      seed = "rotation-seed"
      base_ids = candidate_ids(setup.candidates)

      plan = plan_for(setup, "deterministic_rotation", seed)

      assert candidate_ids(plan.candidates) == rotated_ids(base_ids, seed)
    end

    test "deterministic_rotation is deterministic and not live round robin across calls" do
      setup = routing_setup(4)
      seed = "rotation-repeat-seed"

      first_plan = plan_for(setup, "deterministic_rotation", seed)
      second_plan = plan_for(setup, "deterministic_rotation", seed)

      assert candidate_ids(first_plan.candidates) == candidate_ids(second_plan.candidates)
      assert first_plan.selected_assignment_id == second_plan.selected_assignment_id
    end

    test "eligible codex session assignment remains preferred after strategy ordering" do
      setup = routing_setup(3)
      preferred_assignment = List.last(setup.assignments)
      seed = seed_avoiding_assignment(setup.candidates, preferred_assignment.id)

      plan = plan_for(setup, "bridge_ring", seed, session_assignment_id: preferred_assignment.id)

      assert plan.selected_assignment_id == preferred_assignment.id
    end

    test "codex session preference does not restore a candidate excluded before planning" do
      setup = routing_setup(3)
      excluded_assignment = List.last(setup.assignments)

      candidates =
        Enum.reject(setup.candidates, fn {assignment, _identity} ->
          assignment.id == excluded_assignment.id
        end)

      plan =
        plan_for(setup, "bridge_ring", "excluded-session-assignment",
          candidates: candidates,
          ring_size: 3,
          session_assignment_id: excluded_assignment.id
        )

      refute excluded_assignment.id in candidate_ids(plan.candidates)

      assert Enum.sort(candidate_ids(plan.candidates)) == Enum.sort(candidate_ids(candidates))
      assert length(plan.candidates) == 2
    end
  end

  describe "plan_route/1 deterministic distribution" do
    test "bridge_ring distributes first selection across fixed request seeds" do
      setup = routing_setup(3)

      assignment_ids = candidate_ids(setup.candidates)

      seeds =
        setup.assignments
        |> Enum.flat_map(fn assignment ->
          seeds_preferring_assignment(assignment_ids, assignment.id, 4)
        end)

      selected_ids =
        Enum.map(seeds, fn seed ->
          expected_ids = rendezvous_order_ids(setup.candidates, seed)
          plan = plan_for(setup, "bridge_ring", seed)

          assert candidate_ids(plan.candidates) == expected_ids
          assert plan.selected_assignment_id == hd(expected_ids)

          plan.selected_assignment_id
        end)

      expected_selected_ids = Enum.flat_map(setup.assignments, &List.duplicate(&1.id, 4))

      assert length(seeds) == 12
      assert selected_ids == expected_selected_ids

      selection_counts = Enum.frequencies(selected_ids)

      assert Enum.map(setup.assignments, &Map.fetch!(selection_counts, &1.id)) == [4, 4, 4]
    end

    test "deterministic_rotation distributes first selection across fixed request seeds" do
      setup = routing_setup(4)
      base_ids = candidate_ids(setup.candidates)

      seeds =
        0..3
        |> Enum.map(fn rotation_index ->
          seed_rotating_to_index(rotation_index, length(base_ids))
        end)

      selected_ids =
        Enum.map(seeds, fn seed ->
          expected_ids = rotated_ids(base_ids, seed)
          plan = plan_for(setup, "deterministic_rotation", seed)

          assert candidate_ids(plan.candidates) == expected_ids
          assert plan.selected_assignment_id == hd(expected_ids)

          plan.selected_assignment_id
        end)

      assert selected_ids == base_ids
    end

    test "least_recent_success uses assignment-global succeeded attempt recency and ignores failures" do
      setup = routing_setup(4)
      [first, second, third, fourth] = setup.assignments
      base_time = ~U[2026-05-09 10:00:00.000000Z]
      seed = seed_preferring_assignment([first.id, fourth.id], first.id)

      older_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "older"})

      newer_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "newer"})

      failed_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "failed"})

      attempt_fixture(older_request, second, %{
        attempt_number: 1,
        completed_at: DateTime.add(base_time, 10, :second)
      })

      attempt_fixture(newer_request, third, %{
        attempt_number: 1,
        completed_at: DateTime.add(base_time, 50, :second)
      })

      attempt_fixture(failed_request, second, %{
        attempt_number: 1,
        status: "failed",
        completed_at: DateTime.add(base_time, 90, :second)
      })

      attempt_fixture(failed_request, fourth, %{
        attempt_number: 2,
        status: "failed",
        completed_at: DateTime.add(base_time, 120, :second)
      })

      plan = plan_for(setup, "least_recent_success", seed)

      assert candidate_ids(plan.candidates) == [first.id, fourth.id, second.id, third.id]
      assert plan.selected_assignment_id == first.id
    end

    test "least_recent_success sorts timestamps chronologically across dates" do
      setup = routing_setup(2)
      [newest, oldest] = setup.assignments
      seed = seed_preferring_assignment([newest.id, oldest.id], newest.id)

      newest_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "newest-date"})

      oldest_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "oldest-date"})

      attempt_fixture(newest_request, newest, %{
        attempt_number: 1,
        completed_at: ~U[2026-06-01 00:00:00.000000Z]
      })

      attempt_fixture(oldest_request, oldest, %{
        attempt_number: 1,
        completed_at: ~U[2026-05-12 10:01:00.000000Z]
      })

      plan = plan_for(setup, "least_recent_success", seed)

      assert candidate_ids(plan.candidates) == [oldest.id, newest.id]
      assert plan.selected_assignment_id == oldest.id
    end

    test "least_recent_success breaks equal recency ties with rendezvous order" do
      setup = routing_setup(3)
      [first, second, third] = setup.assignments
      shared_time = ~U[2026-05-09 11:00:00.000000Z]
      seed = seed_preferring_assignment([first.id, second.id], first.id)

      shared_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "tie"})

      attempt_fixture(shared_request, first, %{attempt_number: 1, completed_at: shared_time})
      attempt_fixture(shared_request, second, %{attempt_number: 2, completed_at: shared_time})

      plan = plan_for(setup, "least_recent_success", seed)

      assert candidate_ids(plan.candidates) == [third.id, first.id, second.id]
      assert plan.selected_assignment_id == third.id
    end

    test "least_recent_success puts no-success candidates before older successes and ties them by rendezvous" do
      setup = routing_setup(4)
      [first, second, third, fourth] = setup.assignments
      shared_time = ~U[2026-05-09 12:00:00.000000Z]
      seed = seed_preferring_assignment([first.id, third.id], third.id)

      shared_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "no-success-tie"})

      attempt_fixture(shared_request, second, %{attempt_number: 1, completed_at: shared_time})
      attempt_fixture(shared_request, fourth, %{attempt_number: 2, completed_at: shared_time})

      plan = plan_for(setup, "least_recent_success", seed)

      no_success_candidates = [
        {first, Enum.at(setup.identities, 0)},
        {third, Enum.at(setup.identities, 2)}
      ]

      equal_success_candidates = [
        {second, Enum.at(setup.identities, 1)},
        {fourth, Enum.at(setup.identities, 3)}
      ]

      expected_ids =
        rendezvous_order_ids(no_success_candidates, seed) ++
          rendezvous_order_ids(equal_success_candidates, seed)

      assert candidate_ids(plan.candidates) == expected_ids
      assert plan.selected_assignment_id == hd(expected_ids)
    end
  end

  describe "plan_route/1 prompt-cache locality" do
    @tag :encrypted_reasoning_continuity
    test "encrypted reasoning uses soft prompt-cache locality without continuity state across instances" do
      # Given: a durable session already owned by a distinct gateway instance.
      setup = routing_setup(3)
      update_routing_settings!(setup.pool, "bridge_ring", length(setup.candidates))

      session_options =
        RequestOptions.for_websocket(%{
          accepted_turn_state: "task13-existing-session",
          owner_instance_id: "task13-node-a"
        })

      assert {:ok, %CodexSession{}} =
               SessionContinuity.start_codex_session(setup.auth, session_options)

      continuity_before = continuity_persistence_state(setup.auth)
      prompt_cache_key = "task13-cache-#{System.unique_integer([:positive, :monotonic])}"
      encrypted_content = Base.encode64(:crypto.strong_rand_bytes(32))
      encrypted_content_fingerprint = sha256_fingerprint(encrypted_content)
      prompt_cache_key_fingerprint = sha256_fingerprint(prompt_cache_key)

      payload = %{
        "model" => setup.model.exposed_model_id,
        "prompt_cache_key" => prompt_cache_key,
        "input" => [
          %{
            "type" => "reasoning",
            "content" => nil,
            "encrypted_content" => encrypted_content
          }
        ]
      }

      request_options =
        Enum.map(
          [{"task13-node-b", "task13-request-b"}, {"task13-node-c", "task13-request-c"}],
          fn {
               owner_instance_id,
               request_id
             } ->
            RequestOptions.build(
              %{owner_instance_id: owner_instance_id, request_id: request_id},
              "/backend-api/codex/responses",
              payload
            )
          end
        )

      # When: each instance normalizes and offers the same current encrypted reasoning request.
      Enum.each(request_options, fn options ->
        assert options.routing.prompt_cache_key == prompt_cache_key_fingerprint
        assert options.continuity.previous_response_id == nil
        assert options.continuity.accepted_turn_state == nil
        assert options.continuity.codex_session == nil

        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   payload,
                   setup.model,
                   "/backend-api/codex/responses",
                   options
                 )

        normalized_payload = Jason.decode!(encoded)

        assert sha256_fingerprint(Map.fetch!(normalized_payload, "prompt_cache_key")) ==
                 prompt_cache_key_fingerprint

        assert [%{"type" => "reasoning", "content" => nil} = reasoning] =
                 Map.fetch!(normalized_payload, "input")

        assert sha256_fingerprint(Map.fetch!(reasoning, "encrypted_content")) ==
                 encrypted_content_fingerprint
      end)

      # Then: continuity does not touch shared persistence or hard-pin the route.
      {{{:ok, attached_on_node_b}, {:ok, attached_on_node_c}}, continuity_queries} =
        capture_repo_queries(fn ->
          [node_b_options, node_c_options] = request_options

          {RoutingSessionContinuity.attach_codex_session(setup.auth, payload, node_b_options),
           RoutingSessionContinuity.attach_codex_session(setup.auth, payload, node_c_options)}
        end)

      [node_b_options, node_c_options] = request_options
      assert attached_on_node_b == node_b_options
      assert attached_on_node_c == node_c_options
      assert continuity_queries == []

      Enum.each([attached_on_node_b, attached_on_node_c], fn options ->
        refute RoutingSessionContinuity.hard_pinned_continuity?(options, setup.model)

        assert {:ok, candidates} =
                 RoutingSessionContinuity.apply_codex_session_assignment(
                   setup.candidates,
                   options,
                   setup.model
                 )

        assert candidates == setup.candidates
      end)

      [node_b_plan, node_c_plan] =
        Enum.map(request_options, fn options ->
          BridgeRing.plan_route(%{
            auth: setup.auth,
            model: setup.model,
            candidates: setup.candidates,
            route_plan_input: RoutePlanInput.from_request_opts(options),
            request_options: options
          })
        end)

      expected_candidate_ids = prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)

      assert candidate_ids(node_b_plan.candidates) == expected_candidate_ids
      assert candidate_ids(node_c_plan.candidates) == expected_candidate_ids
      assert node_b_plan.selected_assignment_id == node_c_plan.selected_assignment_id
      assert node_b_plan.affinity.kind == "request_correlation"
      assert node_c_plan.affinity.kind == "request_correlation"
      assert node_b_plan.request_metadata["routing_locality_status"] == "applied"
      assert node_c_plan.request_metadata["routing_locality_status"] == "applied"
      assert node_b_plan.request_metadata["routing_locality_applied"] == true
      assert node_c_plan.request_metadata["routing_locality_applied"] == true
      assert continuity_persistence_state(setup.auth) == continuity_before
    end

    test "prompt-cache locality keeps the same selection for the same eligible set and seed" do
      setup = routing_setup(4)
      prompt_cache_key = "synthetic-cache-key-stable"
      expected_ids = prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)

      first_plan = plan_for_prompt_cache(setup, "bridge_ring", "request-a", prompt_cache_key)
      second_plan = plan_for_prompt_cache(setup, "bridge_ring", "request-b", prompt_cache_key)

      assert candidate_ids(first_plan.candidates) == expected_ids
      assert candidate_ids(second_plan.candidates) == expected_ids
      assert first_plan.selected_assignment_id == hd(expected_ids)
      assert second_plan.selected_assignment_id == hd(expected_ids)
      assert_prompt_cache_locality_applied!(first_plan, prompt_cache_key, hd(expected_ids), 4)
    end

    test "prompt-cache locality canonicalizes keys before hashing" do
      setup = routing_setup(4)
      prompt_cache_key = "synthetic-cache-key-canonical"
      expected_ids = prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)

      trimmed_plan = plan_for_prompt_cache(setup, "bridge_ring", "trimmed", prompt_cache_key)

      padded_plan =
        plan_for_prompt_cache(setup, "bridge_ring", "padded", "  #{prompt_cache_key}\n")

      assert candidate_ids(trimmed_plan.candidates) == expected_ids
      assert candidate_ids(padded_plan.candidates) == expected_ids
      assert trimmed_plan.selected_assignment_id == padded_plan.selected_assignment_id

      assert trimmed_plan.request_metadata["routing_locality_seed_fingerprint"] ==
               padded_plan.request_metadata["routing_locality_seed_fingerprint"]

      refute inspect(padded_plan.request_metadata) =~ prompt_cache_key
    end

    test "prompt-cache locality metadata reports unavailable absent typed routing seed" do
      setup = routing_setup(3)
      plan = plan_for(setup, "bridge_ring", "request-without-prompt-cache")

      assert plan.request_metadata["routing_locality_strategy"] == "prompt_cache_routing_locality"
      assert plan.request_metadata["routing_locality_status"] == "unavailable"
      assert plan.request_metadata["routing_locality_applied"] == false
      assert plan.request_metadata["routing_locality_eligible_candidate_count"] == 3

      assert plan.request_metadata["routing_locality_unhonored_reason"] ==
               "prompt_cache_key_absent"

      refute Map.has_key?(plan.request_metadata, "routing_locality_seed_fingerprint")
      refute Map.has_key?(plan.request_metadata, "routing_locality_assignment_fingerprint")
    end

    test "oversized prompt-cache keys are absent from locality decisions" do
      setup = routing_setup(3)
      oversized_key = "oversized-cache-key-" <> String.duplicate("x", 257)

      plan = plan_for_prompt_cache(setup, "bridge_ring", "oversized-request", oversized_key)

      assert plan.request_metadata["routing_locality_status"] == "unavailable"
      assert plan.request_metadata["routing_locality_applied"] == false

      assert plan.request_metadata["routing_locality_unhonored_reason"] ==
               "prompt_cache_key_absent"

      refute Map.has_key?(plan.request_metadata, "routing_locality_seed_fingerprint")
      refute inspect(plan.request_metadata) =~ oversized_key
    end

    test "eligible-set changes deterministically reselect among remaining candidates" do
      setup = routing_setup(4)
      prompt_cache_key = "synthetic-cache-key-reselect"
      full_expected_ids = prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)
      dropped_id = hd(full_expected_ids)

      remaining_candidates =
        Enum.reject(setup.candidates, fn {assignment, _identity} ->
          assignment.id == dropped_id
        end)

      remaining_expected_ids =
        prompt_cache_order_ids(setup, remaining_candidates, prompt_cache_key)

      plan =
        plan_for_prompt_cache(setup, "bridge_ring", "remaining-request", prompt_cache_key,
          candidates: remaining_candidates
        )

      refute dropped_id in candidate_ids(plan.candidates)
      assert candidate_ids(plan.candidates) == remaining_expected_ids
      assert plan.selected_assignment_id == hd(remaining_expected_ids)
    end

    test "prompt-cache locality cannot resurrect candidates absent after eligibility filtering" do
      setup = routing_setup(4)
      [filtered_assignment | remaining_assignments] = setup.assignments

      prompt_cache_key =
        prompt_cache_key_preferring_assignment(
          setup,
          candidate_ids(setup.candidates),
          filtered_assignment.id
        )

      remaining_ids = Enum.map(remaining_assignments, & &1.id)

      remaining_candidates =
        Enum.filter(setup.candidates, fn {assignment, _identity} ->
          assignment.id in remaining_ids
        end)

      expected_ids = prompt_cache_order_ids(setup, remaining_candidates, prompt_cache_key)

      plan =
        plan_for_prompt_cache(setup, "bridge_ring", "filtered-request", prompt_cache_key,
          candidates: remaining_candidates
        )

      refute filtered_assignment.id in candidate_ids(plan.candidates)
      assert candidate_ids(plan.candidates) == expected_ids
      assert plan.selected_assignment_id == hd(expected_ids)
    end

    test "durable continuity affinity wins over prompt-cache locality" do
      setup = routing_setup(4)
      request_id = "continuity-request-id"
      base_ids = rendezvous_order_ids(setup.candidates, request_id)
      sticky_id = List.last(base_ids)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)

      prompt_cache_key =
        setup.candidates
        |> candidate_ids()
        |> Enum.reject(&(&1 == sticky_id))
        |> then(fn non_sticky_ids ->
          prompt_cache_key_preferring_assignment(
            setup,
            candidate_ids(setup.candidates),
            hd(non_sticky_ids)
          )
        end)

      refute hd(prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)) == sticky_id

      insert_affinity!(setup, sticky_assignment, sticky_identity, request_id)

      plan =
        plan_for_prompt_cache(setup, "bridge_ring", "continuity-request", prompt_cache_key,
          request_id: request_id
        )

      assert plan.affinity.status == "hit"
      assert plan.selected_assignment_id == sticky_id
      assert hd(candidate_ids(plan.candidates)) == sticky_id
      assert plan.request_metadata["routing_locality_status"] == "blocked_by_stronger_continuity"
      assert plan.request_metadata["routing_locality_applied"] == false
      assert plan.request_metadata["routing_locality_unhonored_reason"] == "durable_affinity_hit"
      refute plan.request_metadata["routing_locality_assignment_fingerprint"] == sticky_id
    end

    test "disabled prompt-cache locality toggle preserves current non-prompt ordering" do
      setup = routing_setup(4)
      routing_seed = "toggle-disabled-seed"
      base_ids = rendezvous_order_ids(setup.candidates, routing_seed)
      prompt_preferred_id = List.last(base_ids)

      prompt_cache_key =
        prompt_cache_key_preferring_assignment(
          setup,
          candidate_ids(setup.candidates),
          prompt_preferred_id
        )

      assert hd(prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)) ==
               prompt_preferred_id

      refute prompt_preferred_id == hd(base_ids)

      plan =
        plan_for_prompt_cache(setup, "bridge_ring", routing_seed, prompt_cache_key,
          prompt_cache_affinity_enabled: false
        )

      assert candidate_ids(plan.candidates) == base_ids
      assert plan.selected_assignment_id == hd(base_ids)
      assert plan.request_metadata["routing_locality_status"] == "disabled"
      assert plan.request_metadata["routing_locality_applied"] == false
      assert plan.request_metadata["routing_locality_unhonored_reason"] == "pool_toggle_disabled"
      refute plan.request_metadata["routing_locality_seed_fingerprint"] == prompt_cache_key
    end

    test "prompt-cache seed excludes route class" do
      setup = routing_setup(4)
      prompt_cache_key = "synthetic-cache-key-route-class"
      expected_ids = prompt_cache_order_ids(setup, setup.candidates, prompt_cache_key)

      http_plan =
        plan_for_prompt_cache(setup, "bridge_ring", "http-request", prompt_cache_key,
          payload: %{"stream" => false}
        )

      stream_plan =
        plan_for_prompt_cache(setup, "bridge_ring", "stream-request", prompt_cache_key,
          payload: %{"stream" => true}
        )

      assert http_plan.selected_assignment_id == hd(expected_ids)
      assert stream_plan.selected_assignment_id == hd(expected_ids)
      assert candidate_ids(http_plan.candidates) == expected_ids
      assert candidate_ids(stream_plan.candidates) == expected_ids
    end
  end

  describe "plan_route/1 quota-first edge cases" do
    test "quota_first orders by remaining quota before rendezvous tie-breaking" do
      setup = routing_setup(3)
      [low_remaining, high_remaining, middle_remaining] = setup.assignments
      [_low_identity, high_identity, _middle_identity] = setup.identities
      seed = seed_preferring_assignment([low_remaining.id, high_remaining.id], low_remaining.id)

      prime_account_quota!(setup, low_remaining, Decimal.new("90"))
      prime_account_quota!(setup, high_remaining, Decimal.new("10"))
      prime_account_quota!(setup, middle_remaining, Decimal.new("50"))
      quota_first_plan = plan_for(setup, "quota_first", seed)

      assert quota_first_plan.selected_assignment_id == high_remaining.id
      assert hd(quota_first_plan.candidates) == {high_remaining, high_identity}
    end

    test "quota_first breaks equal remaining-quota ties by rendezvous order" do
      setup = routing_setup(2)
      [first, second] = setup.assignments
      seed = seed_preferring_assignment([first.id, second.id], second.id)

      prime_account_quota!(setup, first, Decimal.new("40"))
      prime_account_quota!(setup, second, Decimal.new("40"))

      quota_first_plan = plan_for(setup, "quota_first", seed)
      expected_ids = rendezvous_order_ids(setup.candidates, seed)

      assert candidate_ids(quota_first_plan.candidates) == expected_ids
      assert quota_first_plan.selected_assignment_id == hd(expected_ids)
    end

    test "quota_first ignores credits when remaining quota ties" do
      setup = routing_setup(2)
      [lower_credit, higher_credit] = setup.assignments
      seed = seed_preferring_assignment([lower_credit.id, higher_credit.id], lower_credit.id)

      prime_account_quota!(setup, lower_credit, Decimal.new("40"), credits: 1)
      prime_account_quota!(setup, higher_credit, Decimal.new("40"), credits: 500)

      quota_first_plan = plan_for(setup, "quota_first", seed)
      expected_ids = rendezvous_order_ids(setup.candidates, seed)

      assert candidate_ids(quota_first_plan.candidates) == expected_ids
      assert quota_first_plan.selected_assignment_id == lower_credit.id
      assert quota_first_plan.selected_assignment_id == hd(expected_ids)
    end

    test "quota_first gives missing usable quota a zero capacity score" do
      setup = routing_setup(3)
      [unknown_quota, high_remaining, low_remaining] = setup.assignments
      seed = seed_preferring_assignment([unknown_quota.id, high_remaining.id], unknown_quota.id)

      prime_account_quota!(setup, high_remaining, Decimal.new("20"))
      prime_account_quota!(setup, low_remaining, Decimal.new("95"))

      quota_first_plan = plan_for(setup, "quota_first", seed)

      assert candidate_ids(quota_first_plan.candidates) == [
               high_remaining.id,
               low_remaining.id,
               unknown_quota.id
             ]

      assert quota_first_plan.selected_assignment_id == high_remaining.id
    end

    test "quota_first scores model-scoped quota with only in-scope usable windows" do
      setup = routing_setup(2)
      [requested_model_remaining, fallback_remaining] = setup.assignments

      seed =
        seed_preferring_assignment(
          [requested_model_remaining.id, fallback_remaining.id],
          fallback_remaining.id
        )

      prime_account_quota!(setup, requested_model_remaining, Decimal.new("5"))
      prime_model_quota!(setup, requested_model_remaining, Decimal.new("30"))

      prime_model_quota!(setup, requested_model_remaining, Decimal.new("99"),
        model: "other-model",
        upstream_model: "other-upstream-model"
      )

      prime_account_quota!(setup, fallback_remaining, Decimal.new("5"))
      prime_model_quota!(setup, fallback_remaining, Decimal.new("40"))

      quota_first_plan = plan_for(setup, "quota_first", seed)

      assert candidate_ids(quota_first_plan.candidates) == [
               requested_model_remaining.id,
               fallback_remaining.id
             ]

      assert quota_first_plan.selected_assignment_id == requested_model_remaining.id
    end

    test "quota_first and routing settings consume the request-local route-state snapshot" do
      setup = routing_setup(2)
      [snapshot_best, snapshot_worst] = setup.assignments
      seed = seed_preferring_assignment([snapshot_best.id, snapshot_worst.id], snapshot_worst.id)

      prime_account_quota!(setup, snapshot_best, Decimal.new("10"))
      prime_account_quota!(setup, snapshot_worst, Decimal.new("90"))
      update_routing_settings!(setup.pool, "quota_first", 2)

      request_options =
        RequestOptions.build(%{request_id: seed}, "/backend-api/codex/responses", %{})

      route_state =
        RouteState.new(%{
          visible_model: setup.model,
          candidates: setup.candidates,
          routing_settings: Pools.get_routing_settings(setup.pool)
        })
        |> RouteState.preload_routing_snapshots(setup.auth, setup.model, request_options)

      prime_account_quota!(setup, snapshot_best, Decimal.new("95"))
      prime_account_quota!(setup, snapshot_worst, Decimal.new("5"))
      update_routing_settings!(setup.pool, "bridge_ring", 2)

      request =
        request_fixture(setup.auth, %{
          model_id: setup.model.id,
          requested_model: setup.model.exposed_model_id,
          correlation_id: "#{seed}-snapshot"
        })

      plan =
        BridgeRing.plan_route(%{
          auth: setup.auth,
          model: setup.model,
          candidates: setup.candidates,
          route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
          request_options: request_options,
          route_state: route_state
        })

      assert plan.strategy == "quota_first"
      assert plan.selected_assignment_id == snapshot_best.id
      assert hd(candidate_ids(plan.candidates)) == snapshot_best.id
    end

    test "quota_first excludes a post-snapshot observation until the route snapshot advances" do
      setup = routing_setup(2)
      [first_assignment, second_assignment] = setup.assignments
      [first_identity, second_identity] = setup.identities
      snapshot_at = ~U[2026-07-25 12:00:00.000000Z]
      refreshed_at = ~U[2026-07-25 12:00:00.000001Z]

      snapshots = %{
        first_identity.id => [
          account_window_at(Decimal.new("10"), snapshot_at),
          account_window_at(Decimal.new("95"), refreshed_at)
        ],
        second_identity.id => [
          account_window_at(Decimal.new("20"), snapshot_at)
        ]
      }

      route_state =
        RouteState.new(%{
          visible_model: setup.model,
          candidates: setup.candidates
        })
        |> RouteState.put_quota_window_snapshot(snapshots, snapshot_at)

      snapshot_plan =
        plan_for(setup, "quota_first", "quota-snapshot-boundary", route_state: route_state)

      assert snapshot_plan.selected_assignment_id == first_assignment.id

      refreshed_route_state =
        RouteState.put_quota_window_snapshot(route_state, snapshots, refreshed_at)

      refreshed_plan =
        plan_for(setup, "quota_first", "quota-snapshot-boundary",
          route_state: refreshed_route_state
        )

      assert refreshed_plan.selected_assignment_id == second_assignment.id
    end

    test "quota_first scores reported-percent exhaustion as empty capacity for prepared credit-backed probes" do
      setup = routing_setup(2)
      seed = "bridge-ring-seed-1"

      [exhausted_candidate, positive_candidate] =
        rendezvous_ordered_candidates(setup.candidates, seed)

      {exhausted_assignment, exhausted_identity} = exhausted_candidate
      {positive_assignment, positive_identity} = positive_candidate
      snapshot_at = ~U[2026-08-07 12:00:00.000000Z]

      prime_account_quota!(setup, exhausted_assignment, Decimal.new("20"))

      prime_weekly_account_quota!(setup, exhausted_assignment, Decimal.new("100"), credits: 3)

      prime_account_quota!(setup, positive_assignment, Decimal.new("40"))

      assert seed_preferring_assignment(
               [positive_assignment.id, exhausted_assignment.id],
               exhausted_assignment.id
             ) == seed

      assert {:ok, prepared_candidates, prepared_decision} =
               quota_eligible_candidates(setup, [positive_candidate, exhausted_candidate])

      assert candidate_ids(prepared_candidates) == [
               positive_assignment.id,
               exhausted_assignment.id
             ]

      assert prepared_decision["precise_candidate_count"] == 1
      assert prepared_decision["credit_backed_probe_candidate_count"] == 1

      assert %{routing_state: :precise} =
               QuotaWindows.routing_quota_eligibility(
                 positive_identity,
                 quota_scope_opts(setup.model)
               )

      assert %{routing_state: :credit_backed_probe} =
               QuotaWindows.routing_quota_eligibility(
                 exhausted_identity,
                 quota_scope_opts(setup.model)
               )

      snapshot_candidates = [positive_candidate, exhausted_candidate]

      route_state =
        RouteState.new(%{visible_model: setup.model, candidates: snapshot_candidates})
        |> RouteState.put_quota_window_snapshot(
          %{
            positive_identity.id => [account_window_at(Decimal.new("40"), snapshot_at)],
            exhausted_identity.id => [
              account_window_at(Decimal.new("20"), snapshot_at),
              credit_backed_weekly_window_at(snapshot_at)
            ]
          },
          snapshot_at
        )

      assert {:ok, ^prepared_candidates, snapshot_decision} =
               quota_eligible_candidates(setup, snapshot_candidates, route_state)

      assert snapshot_decision["precise_candidate_count"] == 1
      assert snapshot_decision["credit_backed_probe_candidate_count"] == 1

      request =
        request_fixture(setup.auth, %{
          model_id: setup.model.id,
          requested_model: setup.model.exposed_model_id,
          correlation_id: "todo5-reported-percent-exhaustion"
        })

      route_plan_input = RoutePlanInput.from_reserved(%{request: request})
      update_routing_settings!(setup.pool, "quota_first", 2)

      live_plan = quota_first_plan(setup, prepared_candidates, route_plan_input, seed)

      snapshot_plan =
        quota_first_plan(setup, prepared_candidates, route_plan_input, seed,
          route_state: route_state
        )

      sweep_results =
        Enum.map(1..500, fn index ->
          sweep_seed = "todo5-quota-first-sweep-#{index}"

          live =
            quota_first_plan(setup, prepared_candidates, route_plan_input, sweep_seed)
            |> Map.fetch!(:selected_assignment_id)

          snapshot =
            quota_first_plan(setup, prepared_candidates, route_plan_input, sweep_seed,
              route_state: route_state
            )
            |> Map.fetch!(:selected_assignment_id)

          %{seed: sweep_seed, live: live, snapshot: snapshot}
        end)

      assert %{live: positive_assignment.id, snapshot: positive_assignment.id} == %{
               live: live_plan.selected_assignment_id,
               snapshot: snapshot_plan.selected_assignment_id
             }

      assert Enum.all?(sweep_results, fn result ->
               result.live == positive_assignment.id and result.snapshot == positive_assignment.id
             end)
    end

    test "quota_first excludes nonqualifying exhaustion reports from snapshot capacity scoring" do
      setup = routing_setup(2)
      [reported_assignment, positive_assignment] = setup.assignments
      [reported_identity, positive_identity] = setup.identities
      snapshot_at = ~U[2026-08-07 12:00:00.000000Z]

      seed =
        seed_preferring_assignment(
          [reported_assignment.id, positive_assignment.id],
          reported_assignment.id
        )

      request =
        request_fixture(setup.auth, %{
          model_id: setup.model.id,
          requested_model: setup.model.exposed_model_id,
          correlation_id: "todo5-quota-first-exhaustion-controls"
        })

      route_plan_input = RoutePlanInput.from_reserved(%{request: request})
      update_routing_settings!(setup.pool, "quota_first", 2)

      excluded_controls = [
        {"stale", %{observed_at: DateTime.add(snapshot_at, -901, :second)},
         reported_assignment.id},
        {"resetless", %{reset_at: nil}, reported_assignment.id},
        {"expired", %{reset_at: DateTime.add(snapshot_at, -1, :second)}, reported_assignment.id},
        {"active_limit_zero", %{active_limit: 0}, reported_assignment.id},
        {"used_percent_missing", %{used_percent: nil}, reported_assignment.id},
        {"credits_zero", %{credits: 0}, reported_assignment.id}
      ]

      Enum.each(excluded_controls, fn {label, attrs, expected_assignment_id} ->
        reported_windows = [
          account_window_at(Decimal.new("20"), snapshot_at),
          weekly_window_at(snapshot_at, attrs)
        ]

        route_state =
          RouteState.new(%{visible_model: setup.model, candidates: setup.candidates})
          |> RouteState.put_quota_window_snapshot(
            %{
              reported_identity.id => reported_windows,
              positive_identity.id => [account_window_at(Decimal.new("40"), snapshot_at)]
            },
            snapshot_at
          )

        plan =
          quota_first_plan(setup, setup.candidates, route_plan_input, "#{seed}-#{label}",
            route_state: route_state
          )

        assert plan.selected_assignment_id == expected_assignment_id,
               "#{label} must stay out of capacity scoring"
      end)

      monthly_primary =
        quota_window_at(snapshot_at, %{
          window_kind: "primary",
          window_minutes: 43_200,
          used_percent: Decimal.new("100"),
          credits: 3
        })

      assert QuotaWindows.usable_window?(monthly_primary, snapshot_at)

      monthly_route_state =
        RouteState.new(%{visible_model: setup.model, candidates: setup.candidates})
        |> RouteState.put_quota_window_snapshot(
          %{
            reported_identity.id => [monthly_primary],
            positive_identity.id => [account_window_at(Decimal.new("40"), snapshot_at)]
          },
          snapshot_at
        )

      monthly_plan =
        quota_first_plan(setup, setup.candidates, route_plan_input, "#{seed}-monthly-primary",
          route_state: monthly_route_state
        )

      assert monthly_plan.selected_assignment_id == positive_assignment.id
    end
  end

  describe "plan_route/1 affinity/demotion recovery" do
    test "affinity cannot resurrect a filtered assignment that is absent from eligible candidates" do
      setup = routing_setup(3)
      seed = "filtered-affinity-seed"
      filtered = active_upstream_assignment_fixture(setup.pool)

      insert_affinity!(setup, filtered.assignment, filtered.identity, seed)

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.affinity.status == "hit"
      assert filtered.assignment.id not in candidate_ids(plan.candidates)
      assert candidate_ids(plan.candidates) == rendezvous_order_ids(setup.candidates, seed)
    end

    test "affinity promotes an eligible sticky hit after strategy ordering" do
      setup = routing_setup(3)
      seed = "eligible-affinity-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      sticky_id = List.last(base_ids)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)

      insert_affinity!(setup, sticky_assignment, sticky_identity, seed)

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.affinity.status == "hit"

      assert candidate_ids(plan.candidates) == [
               sticky_id | Enum.reject(base_ids, &(&1 == sticky_id))
             ]

      assert plan.selected_assignment_id == sticky_id
    end

    test "active demotion pushes an affinity hit behind non-demoted alternatives" do
      setup = routing_setup(3)
      seed = "affinity-then-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      sticky_id = List.last(base_ids)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)

      insert_affinity!(setup, sticky_assignment, sticky_identity, seed)
      insert_demotion!(setup, sticky_assignment, sticky_identity, "upstream_5xx")

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.affinity.status == "hit"
      assert Map.has_key?(plan.demotions, sticky_id)

      assert candidate_ids(plan.candidates) ==
               Enum.reject(base_ids, &(&1 == sticky_id)) ++ [sticky_id]

      assert plan.selected_assignment_id == hd(Enum.reject(base_ids, &(&1 == sticky_id)))
    end

    test "active demotion overrides an eligible codex session preference" do
      setup = routing_setup(3)
      preferred_assignment = List.last(setup.assignments)

      {_assignment, preferred_identity} =
        candidate_by_id!(setup.candidates, preferred_assignment.id)

      insert_demotion!(setup, preferred_assignment, preferred_identity, "upstream_5xx")

      plan =
        plan_for(setup, "bridge_ring", "session-preference-demotion",
          session_assignment_id: preferred_assignment.id
        )

      assert List.last(candidate_ids(plan.candidates)) == preferred_assignment.id
      refute plan.selected_assignment_id == preferred_assignment.id
    end

    test "another process observes demotion only for the exact API key model assignment lane" do
      setup = in_db_observer(fn -> routing_setup(3) end)
      cleanup_unboxed_fixture(setup.pool.id, Enum.map(setup.identities, & &1.id))
      seed = "persisted-exact-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      demoted_id = hd(base_ids)
      {demoted_assignment, demoted_identity} = candidate_by_id!(setup.candidates, demoted_id)
      initial_plan = in_db_observer(fn -> plan_for(setup, "bridge_ring", seed) end)

      assert "upstream_model_unavailable" =
               in_db_observer(fn ->
                 BridgeRing.record_failure(
                   initial_plan,
                   demoted_assignment,
                   demoted_identity,
                   "upstream_model_unavailable"
                 )
               end)

      observed_plan = in_db_observer(fn -> plan_for(setup, "bridge_ring", seed) end)

      assert Map.has_key?(observed_plan.demotions, demoted_id)
      assert candidate_ids(observed_plan.candidates) == tl(base_ids) ++ [demoted_id]

      sibling_model =
        in_db_observer(fn ->
          model_fixture(setup.pool, %{
            exposed_model_id: "gpt-example-demotion-sibling",
            upstream_model_id: "upstream-gpt-example-demotion-sibling"
          })
        end)

      sibling_plan =
        in_db_observer(fn ->
          setup
          |> Map.put(:model, sibling_model)
          |> plan_for("bridge_ring", seed)
        end)

      assert sibling_plan.demotions == %{}
      assert candidate_ids(sibling_plan.candidates) == base_ids
      assert sibling_plan.selected_assignment_id == demoted_id
    end

    test "expired demotion is ignored when ordering candidates" do
      setup = routing_setup(3)
      seed = "expired-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      selected_id = hd(base_ids)
      {selected_assignment, selected_identity} = candidate_by_id!(setup.candidates, selected_id)

      insert_demotion!(setup, selected_assignment, selected_identity, "upstream_5xx",
        demoted_until: ~U[2026-05-09 10:00:00.000000Z],
        now: ~U[2026-05-09 09:59:00.000000Z]
      )

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.demotions == %{}
      assert candidate_ids(plan.candidates) == base_ids
      assert plan.selected_assignment_id == selected_id
    end

    test "record_success resolves active demotions for the successful assignment" do
      setup = routing_setup(3)
      seed = "success-resolves-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      demoted_id = hd(base_ids)
      {demoted_assignment, demoted_identity} = candidate_by_id!(setup.candidates, demoted_id)

      insert_demotion!(setup, demoted_assignment, demoted_identity, "upstream_5xx",
        demoted_until: nil,
        now: ~U[2026-05-09 10:00:00.000000Z]
      )

      demoted_plan = plan_for(setup, "bridge_ring", seed)

      assert Map.has_key?(demoted_plan.demotions, demoted_id)
      assert candidate_ids(demoted_plan.candidates) == tl(base_ids) ++ [demoted_id]

      assert :ok = BridgeRing.record_success(demoted_plan, demoted_assignment, demoted_identity)

      assert [] = active_demotions(setup, demoted_assignment)

      resolved_demotions = all_demotions(setup, demoted_assignment)
      assert [%BridgeDemotion{} = resolved_demotion] = resolved_demotions
      assert resolved_demotion.status == "resolved"

      recovered_plan = plan_for(setup, "bridge_ring", seed)

      assert recovered_plan.demotions == %{}
      assert candidate_ids(recovered_plan.candidates) == base_ids
      assert recovered_plan.selected_assignment_id == demoted_id
    end

    test "bridge_ring_size truncates candidates after strategy ordering affinity and demotion" do
      setup = routing_setup(4)
      seed = "ring-size-truncation-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      sticky_id = List.last(base_ids)
      demoted_id = Enum.at(base_ids, 1)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)
      {demoted_assignment, demoted_identity} = candidate_by_id!(setup.candidates, demoted_id)

      insert_affinity!(setup, sticky_assignment, sticky_identity, seed)
      insert_demotion!(setup, demoted_assignment, demoted_identity, "upstream_5xx")

      plan = plan_for(setup, "bridge_ring", seed, ring_size: 2)

      affinity_order = [sticky_id | Enum.reject(base_ids, &(&1 == sticky_id))]
      expected_ids = Enum.reject(affinity_order, &(&1 == demoted_id)) ++ [demoted_id]

      assert plan.bridge_ring_size == 2
      assert candidate_ids(plan.candidates) == Enum.take(expected_ids, 2)
      assert length(plan.candidates) == 2
      assert plan.selected_assignment_id == hd(expected_ids)
    end
  end

  describe "record_success/3 concurrency" do
    test "concurrent first successes for the same affinity key leave one active affinity" do
      setup = routing_setup(2)
      seed = "concurrent-affinity-key"
      plan = plan_for(setup, "bridge_ring", seed)
      {assignment, identity} = hd(plan.candidates)
      concurrency = 8

      assert plan.affinity.status == "miss"

      assert List.duplicate(:ok, concurrency) ==
               run_concurrently(concurrency, fn ->
                 BridgeRing.record_success(plan, assignment, identity)
               end)

      active_affinities = active_affinities(setup, seed)
      assert [%BridgeAffinity{} = affinity] = active_affinities
      assert affinity.pool_upstream_assignment_id == assignment.id
      assert affinity.upstream_identity_id == identity.id
      assert affinity.metadata == %{"source" => "gateway_success"}
      refute is_nil(affinity.last_hit_at)
      assert DateTime.compare(affinity.created_at, affinity.updated_at) in [:lt, :eq]
    end

    test "prompt-cache locality is not persisted as durable affinity" do
      setup = routing_setup(3)
      prompt_cache_key = "synthetic-cache-key-stateless"
      plan = plan_for_prompt_cache(setup, "bridge_ring", "stateless-request", prompt_cache_key)
      {assignment, identity} = hd(plan.candidates)

      assert plan.affinity.status == "disabled"
      assert :ok = BridgeRing.record_success(plan, assignment, identity)
      assert [] = all_affinities(setup)
    end
  end

  describe "record_failure/5 concurrency" do
    test "concurrent first failures for the same assignment leave one active demotion" do
      setup = routing_setup(2)
      seed = "concurrent-demotion-key"
      plan = plan_for(setup, "bridge_ring", seed)
      {assignment, identity} = hd(plan.candidates)
      concurrency = 8

      assert List.duplicate("upstream_5xx", concurrency) ==
               run_concurrently(concurrency, fn ->
                 BridgeRing.record_failure(plan, assignment, identity, "upstream_5xx")
               end)

      active_demotions = active_demotions(setup, assignment)
      assert [%BridgeDemotion{} = demotion] = active_demotions
      assert demotion.pool_upstream_assignment_id == assignment.id
      assert demotion.upstream_identity_id == identity.id
      assert demotion.reason_code == "upstream_5xx"
      assert demotion.metadata == %{"source" => "gateway_failure"}
      assert demotion.attempt_count == concurrency
      assert DateTime.compare(demotion.created_at, demotion.updated_at) in [:lt, :eq]
      assert DateTime.compare(demotion.updated_at, demotion.demoted_until) == :lt
    end
  end

  defp assert_prompt_cache_locality_applied!(plan, raw_prompt_cache_key, assignment_id, count) do
    assert plan.request_metadata["routing_locality_strategy"] == "prompt_cache_routing_locality"
    assert plan.request_metadata["routing_locality_status"] == "applied"
    assert plan.request_metadata["routing_locality_applied"] == true
    assert plan.request_metadata["routing_locality_eligible_candidate_count"] == count

    assert plan.request_metadata["routing_locality_seed_basis_class"] ==
             "pool_api_key_model_prompt_cache"

    assert plan.request_metadata["routing_locality_seed_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/

    assert plan.request_metadata["routing_locality_assignment_fingerprint"] =~
             ~r/\A[0-9a-f]{16}\z/

    refute plan.request_metadata["routing_locality_seed_fingerprint"] == raw_prompt_cache_key
    refute plan.request_metadata["routing_locality_assignment_fingerprint"] == assignment_id
    refute inspect(plan.request_metadata) =~ raw_prompt_cache_key
    refute inspect(plan.request_metadata) =~ "cache_hit"
    refute inspect(plan.request_metadata) =~ "provider_cache"
  end

  defp routing_setup(candidate_count) do
    pool =
      pool_fixture(%{
        slug:
          "bridge-pool-#{System.unique_integer([:positive, :monotonic])}-#{System.os_time(:nanosecond)}"
      })

    auth = active_api_key_fixture(pool)

    assignments_with_identities =
      Enum.map(1..candidate_count, fn index ->
        unique =
          "#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

        active_upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct_bridge_#{index}_#{unique}",
          assignment_label: "Bridge assignment #{index}",
          account_label: "Bridge identity #{index}",
          metadata: %{
            "quota_remaining_pct" => Integer.to_string(100 - index * 10),
            "quota_bucket" => "bucket-#{index}"
          }
        })
      end)

    assignment_ids = Enum.map(assignments_with_identities, & &1.assignment.id)

    model =
      model_fixture(pool, %{
        metadata: %{"source_assignment_ids" => assignment_ids},
        source_assignment_count: candidate_count
      })

    %{
      pool: pool,
      auth: %{pool: pool, api_key: auth.api_key},
      model: model,
      assignments: Enum.map(assignments_with_identities, & &1.assignment),
      identities: Enum.map(assignments_with_identities, & &1.identity),
      candidates: Enum.map(assignments_with_identities, &{&1.assignment, &1.identity})
    }
  end

  defp plan_for(setup, strategy, seed, opts \\ []) do
    candidates = Keyword.get(opts, :candidates, setup.candidates)
    ring_size = Keyword.get(opts, :ring_size, length(candidates))
    update_routing_settings!(setup.pool, strategy, ring_size)

    request =
      request_fixture(setup.auth, %{
        model_id: setup.model.id,
        requested_model: setup.model.exposed_model_id,
        correlation_id: "#{seed}-#{System.unique_integer([:positive])}"
      })

    request_options =
      RequestOptions.build(%{request_id: seed}, "/backend-api/codex/responses", %{})

    request_options =
      case Keyword.fetch(opts, :session_assignment_id) do
        {:ok, assignment_id} ->
          RequestOptions.put_continuity(request_options,
            codex_session: %CodexSession{pool_upstream_assignment_id: assignment_id}
          )

        :error ->
          request_options
      end

    BridgeRing.plan_route(%{
      auth: setup.auth,
      model: setup.model,
      candidates: candidates,
      route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
      request_options: request_options,
      route_state: Keyword.get(opts, :route_state)
    })
  end

  defp account_window_at(used_percent, observed_at) do
    %AccountQuotaWindow{
      quota_key: "account",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: used_percent,
      reset_at: DateTime.add(observed_at, 300, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: observed_at
    }
  end

  defp continuity_persistence_state(auth) do
    %{
      sessions:
        Repo.all(
          from session in CodexSession,
            where: session.pool_id == ^auth.pool.id and session.api_key_id == ^auth.api_key.id,
            order_by: [asc: session.id],
            select:
              {session.id, session.status, session.owner_instance_id,
               session.owner_lease_expires_at, session.updated_at}
        ),
      aliases:
        Repo.all(
          from alias_record in BridgeSessionAlias,
            where:
              alias_record.pool_id == ^auth.pool.id and
                alias_record.api_key_id == ^auth.api_key.id,
            order_by: [asc: alias_record.id],
            select:
              {alias_record.id, alias_record.alias_kind, alias_record.status,
               alias_record.updated_at}
        ),
      owner_leases:
        Repo.all(
          from lease in BridgeOwnerLease,
            where: lease.pool_id == ^auth.pool.id and lease.api_key_id == ^auth.api_key.id,
            order_by: [asc: lease.id],
            select:
              {lease.id, lease.owner_instance_id, lease.status, lease.renewed_at,
               lease.expires_at, lease.updated_at}
        )
    }
  end

  defp sha256_fingerprint(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, Map.get(metadata, :query, "")})
          end
        end,
        nil
      )

    try do
      {fun.(), drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_repo_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp credit_backed_weekly_window_at(observed_at) do
    quota_window_at(observed_at, %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("100"),
      credits: 3,
      reset_at: DateTime.add(observed_at, 604_800, :second)
    })
  end

  defp weekly_window_at(observed_at, attrs) do
    quota_window_at(
      observed_at,
      Map.merge(
        %{
          quota_key: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("100"),
          credits: 3,
          reset_at: DateTime.add(observed_at, 604_800, :second)
        },
        attrs
      )
    )
  end

  defp quota_window_at(observed_at, attrs) do
    struct(
      AccountQuotaWindow,
      %{
        quota_key: "account",
        window_kind: "primary",
        window_minutes: 300,
        reset_at: DateTime.add(observed_at, 300, :second),
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh",
        observed_at: observed_at
      }
      |> Map.merge(attrs)
    )
  end

  defp quota_eligible_candidates(setup, candidates, route_state \\ nil) do
    request_options =
      RequestOptions.build(
        %{request_id: "todo5-quota-preparation"},
        "/backend-api/codex/responses",
        %{}
      )

    filter_input =
      FilterInput.new(%{
        model: setup.model,
        endpoint: "/backend-api/codex/responses",
        payload: %{},
        request_options: request_options,
        candidates: candidates
      })

    case route_state do
      nil ->
        CandidateEligibility.filter_quota_eligible_candidates(filter_input)

      %RouteState{} ->
        CandidateEligibility.filter_quota_eligible_candidates(filter_input, route_state)
    end
  end

  defp quota_first_plan(setup, candidates, route_plan_input, seed, opts \\ []) do
    request_options =
      RequestOptions.build(%{request_id: seed}, "/backend-api/codex/responses", %{})

    BridgeRing.plan_route(%{
      auth: setup.auth,
      model: setup.model,
      candidates: candidates,
      route_plan_input: route_plan_input,
      request_options: request_options,
      route_state: Keyword.get(opts, :route_state)
    })
  end

  defp rendezvous_ordered_candidates(candidates, seed) do
    Enum.sort_by(candidates, fn {assignment, _identity} ->
      -rendezvous_score(seed, assignment.id)
    end)
  end

  defp seed_avoiding_assignment(candidates, assignment_id) do
    Enum.find_value(1..100, fn index ->
      seed = "session-preference-seed-#{index}"

      if hd(rendezvous_order_ids(candidates, seed)) != assignment_id, do: seed
    end) || raise "could not find a seed avoiding assignment #{assignment_id}"
  end

  defp plan_for_prompt_cache(setup, strategy, seed, prompt_cache_key, opts \\ []) do
    candidates = Keyword.get(opts, :candidates, setup.candidates)
    ring_size = Keyword.get(opts, :ring_size, length(candidates))
    update_routing_settings!(setup.pool, strategy, ring_size, opts)

    request =
      request_fixture(setup.auth, %{
        model_id: setup.model.id,
        requested_model: setup.model.exposed_model_id,
        correlation_id: seed
      })

    payload =
      %{"prompt_cache_key" => prompt_cache_key}
      |> Map.merge(Keyword.get(opts, :payload, %{}))

    request_options =
      %{
        request_method: Keyword.get(opts, :request_method, "POST"),
        request_id: Keyword.get(opts, :request_id)
      }
      |> RequestOptions.build(
        Keyword.get(opts, :endpoint, "/backend-api/codex/responses"),
        payload
      )

    BridgeRing.plan_route(%{
      auth: setup.auth,
      model: setup.model,
      candidates: candidates,
      route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
      request_options: request_options
    })
  end

  defp update_routing_settings!(pool, strategy, ring_size, opts \\ []) do
    attrs = %{
      routing_strategy: strategy,
      bridge_ring_size: ring_size,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    attrs =
      case Keyword.fetch(opts, :prompt_cache_affinity_enabled) do
        {:ok, value} -> Map.put(attrs, :prompt_cache_affinity_enabled, value)
        :error -> attrs
      end

    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp candidate_by_id!(candidates, assignment_id) do
    Enum.find(candidates, fn {assignment, _identity} -> assignment.id == assignment_id end) ||
      raise "missing candidate #{assignment_id}"
  end

  defp insert_affinity!(setup, assignment, identity, request_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeAffinity{
      pool_id: setup.pool.id,
      api_key_id: setup.auth.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      affinity_kind: "request_correlation",
      affinity_key_hash: affinity_hash(setup, "request_correlation", request_id),
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      status: "active",
      last_hit_at: now,
      metadata: %{"source" => "test_affinity"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_demotion!(setup, assignment, identity, reason_code, opts \\ []) do
    now =
      opts
      |> Keyword.get_lazy(:now, fn -> DateTime.utc_now() end)
      |> DateTime.truncate(:microsecond)

    demoted_until =
      case Keyword.get_lazy(opts, :demoted_until, fn -> DateTime.add(now, 60, :second) end) do
        nil -> nil
        value -> DateTime.truncate(value, :microsecond)
      end

    %BridgeDemotion{
      pool_id: setup.pool.id,
      api_key_id: setup.auth.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      reason_code: reason_code,
      status: "active",
      demoted_until: demoted_until,
      attempt_count: 1,
      metadata: %{"source" => "test_demotion"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp prime_account_quota!(setup, assignment, used_percent, attrs \\ []) do
    setup
    |> prime_quota_window!(
      assignment,
      Map.merge(
        %{
          quota_key: "account",
          window_kind: "primary",
          window_minutes: 300,
          quota_scope: "account",
          quota_family: "account",
          used_percent: used_percent
        },
        Map.new(attrs)
      )
    )
  end

  defp prime_model_quota!(setup, assignment, used_percent, opts \\ []) do
    model = Keyword.get(opts, :model, setup.model.exposed_model_id)
    upstream_model = Keyword.get(opts, :upstream_model, setup.model.upstream_model_id)

    prime_quota_window!(setup, assignment, %{
      quota_key: "codex_model",
      window_kind: "primary",
      window_minutes: 300,
      quota_scope: "model",
      quota_family: "codex_model",
      model: model,
      upstream_model: upstream_model,
      used_percent: used_percent
    })
  end

  defp prime_weekly_account_quota!(setup, assignment, used_percent, opts) do
    setup
    |> prime_quota_window!(
      assignment,
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        quota_scope: "account",
        quota_family: "account",
        used_percent: used_percent
      }
      |> Map.merge(Map.new(opts))
    )
  end

  defp prime_quota_window!(setup, assignment, attrs) do
    {_assignment, identity} = candidate_by_id!(setup.candidates, assignment.id)

    reset_at =
      DateTime.utc_now()
      |> DateTime.add(900, :second)
      |> DateTime.truncate(:second)

    attrs =
      Map.merge(
        %{
          reset_at: reset_at,
          source: "codex_response_headers",
          source_precision: "observed",
          freshness_state: "fresh"
        },
        attrs
      )

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
  end

  defp quota_scope_opts(model) do
    [
      model: model.exposed_model_id,
      requested_model: model.exposed_model_id,
      catalog_model: model.exposed_model_id,
      exposed_model_id: model.exposed_model_id,
      upstream_model: model.upstream_model_id,
      upstream_model_id: model.upstream_model_id
    ]
  end

  defp affinity_hash(setup, kind, key_value) do
    [setup.pool.id, setup.auth.api_key.id, setup.model.exposed_model_id, kind, key_value]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp active_affinities(setup, seed) do
    Repo.all(
      from affinity in BridgeAffinity,
        where:
          affinity.pool_id == ^setup.pool.id and affinity.api_key_id == ^setup.auth.api_key.id and
            affinity.model_identifier == ^setup.model.exposed_model_id and
            affinity.affinity_kind == "request_correlation" and
            affinity.affinity_key_hash == ^affinity_hash(setup, "request_correlation", seed) and
            affinity.status == "active"
    )
  end

  defp all_affinities(setup) do
    Repo.all(
      from affinity in BridgeAffinity,
        where:
          affinity.pool_id == ^setup.pool.id and affinity.api_key_id == ^setup.auth.api_key.id and
            affinity.model_identifier == ^setup.model.exposed_model_id
    )
  end

  defp active_demotions(setup, assignment) do
    Repo.all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^setup.pool.id and demotion.api_key_id == ^setup.auth.api_key.id and
            demotion.model_identifier == ^setup.model.exposed_model_id and
            demotion.pool_upstream_assignment_id == ^assignment.id and
            demotion.status == "active"
    )
  end

  defp all_demotions(setup, assignment) do
    Repo.all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^setup.pool.id and demotion.api_key_id == ^setup.auth.api_key.id and
            demotion.model_identifier == ^setup.model.exposed_model_id and
            demotion.pool_upstream_assignment_id == ^assignment.id,
        order_by: [asc: demotion.created_at]
    )
  end

  defp run_concurrently(count, callback) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(1..count, fn _index ->
        Task.async(fn ->
          send(parent, {:bridge_ring_concurrency_ready, barrier, self()})

          receive do
            {:bridge_ring_concurrency_go, ^barrier} -> callback.()
          after
            5_000 -> raise "timed out waiting for concurrency release"
          end
        end)
      end)

    ready_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:bridge_ring_concurrency_ready, ^barrier, task_pid}
        task_pid
      end)

    assert Enum.sort(ready_pids) == Enum.sort(Enum.map(tasks, & &1.pid))

    Enum.each(tasks, fn task ->
      send(task.pid, {:bridge_ring_concurrency_go, barrier})
    end)

    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp in_db_observer(callback) do
    task = Task.async(fn -> Sandbox.unboxed_run(Repo, callback) end)

    Task.await(task, 5_000)
  end

  defp cleanup_unboxed_fixture(pool_id, upstream_identity_ids) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> cleanup_fixture(pool_id, upstream_identity_ids) end)
    end)
  end

  defp cleanup_fixture(pool_id, upstream_identity_ids) do
    pool = Repo.get(Pool, pool_id)
    if pool, do: Repo.delete!(pool)

    Repo.delete_all(
      from identity in UpstreamIdentity,
        where: identity.id in ^upstream_identity_ids
    )
  end

  defp rotated_ids(candidate_ids, _seed) when length(candidate_ids) <= 1, do: candidate_ids

  defp rotated_ids(candidate_ids, seed) do
    {head, tail} = Enum.split(candidate_ids, :erlang.phash2(seed, length(candidate_ids)))
    tail ++ head
  end

  defp rendezvous_order_ids(candidates, seed) do
    candidates
    |> Enum.sort_by(fn {assignment, _identity} -> -rendezvous_score(seed, assignment.id) end)
    |> candidate_ids()
  end

  defp prompt_cache_order_ids(setup, candidates, prompt_cache_key) do
    seed = prompt_cache_seed(setup, prompt_cache_key)

    candidates
    |> Enum.sort_by(fn {assignment, _identity} ->
      {-rendezvous_score(seed, assignment.id), assignment.id}
    end)
    |> candidate_ids()
  end

  defp seed_rotating_to_index(rotation_index, candidate_count) do
    Enum.find(1..500, fn index ->
      :erlang.phash2("rotation-distribution-#{index}", candidate_count) == rotation_index
    end)
    |> then(&"rotation-distribution-#{&1}")
  end

  defp seeds_preferring_assignment(assignment_ids, desired_assignment_id, count) do
    1..2_000
    |> Enum.reduce_while([], fn index, seeds ->
      seed = "bridge-ring-distribution-seed-#{index}"

      selected_assignment_id = Enum.max_by(assignment_ids, &rendezvous_score(seed, &1))

      seeds = if selected_assignment_id == desired_assignment_id, do: [seed | seeds], else: seeds

      if length(seeds) == count, do: {:halt, Enum.reverse(seeds)}, else: {:cont, seeds}
    end)
  end

  defp seed_preferring_assignment(assignment_ids, desired_assignment_id) do
    Enum.find(1..500, fn index ->
      seed = "bridge-ring-seed-#{index}"

      assignment_ids
      |> Enum.max_by(&rendezvous_score(seed, &1))
      |> Kernel.==(desired_assignment_id)
    end)
    |> then(&"bridge-ring-seed-#{&1}")
  end

  defp prompt_cache_key_preferring_assignment(setup, assignment_ids, desired_assignment_id) do
    Enum.find(1..1_000, fn index ->
      prompt_cache_key = "synthetic-cache-key-#{index}"
      seed = prompt_cache_seed(setup, prompt_cache_key)

      assignment_ids
      |> Enum.max_by(&rendezvous_score(seed, &1))
      |> Kernel.==(desired_assignment_id)
    end)
    |> then(&"synthetic-cache-key-#{&1}")
  end

  defp prompt_cache_seed(setup, prompt_cache_key) do
    [
      setup.pool.id,
      setup.auth.api_key.id,
      setup.model.exposed_model_id,
      "prompt_cache",
      normalized_prompt_cache_routing_key(prompt_cache_key)
    ]
    |> Enum.join(":")
  end

  defp normalized_prompt_cache_routing_key(value) do
    value
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp rendezvous_score(seed, assignment_id) do
    :crypto.hash(:sha256, [to_string(seed), ?:, assignment_id])
    |> :binary.decode_unsigned()
  end
end
