defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1, strict_text_format_payload: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

  test "prepare returns request options and routable candidates without reserving a request" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "prepare this route"
    }

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-success-#{System.unique_integer([:positive])}",
        accepted_turn_state: "pre-dispatch-session",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert [{assignment, identity}] = prepared.candidates
    assert assignment.id == setup.assignment.id
    assert identity.id == setup.identity.id
    assert prepared.request_options.routing.requested_model == setup.model.exposed_model_id
    assert %CodexSession{} = prepared.request_options.continuity.codex_session
    assert %RouteState{} = route_state = prepared.route_state
    assert route_state.candidates == prepared.candidates
    assert route_state.candidate_snapshots == prepared.candidates
    assert route_state.visible_model.id == setup.model.id
    assert route_state.visible_model_context.visible_model.id == setup.model.id
    assert route_state.visible_model_context.requested_model == setup.model.exposed_model_id
    assert route_state.visible_model_context.effective_model == setup.model.exposed_model_id
    assert Enum.map(route_state.visible_models, & &1.id) == [setup.model.id]
    assert [_window] = Map.fetch!(route_state.quota_window_snapshots, identity.id)
    assert Map.fetch!(route_state.circuit_snapshots, assignment.id).eligible? == true
    assert Map.fetch!(route_state.circuit_eligibility_snapshots, assignment.id).eligible? == true
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    pricing = CodexPooler.Catalog.pricing_buckets_by_identifier([setup.model])
    %{"models" => [catalog_model]} = CodexCatalog.build([setup.model], policy, pricing, %{}).body

    assert RouteState.codex_models_etag(route_state) ==
             CodexCatalog.etag(%{"models" => [catalog_model]})

    assert catalog_model["slug"] == setup.model.exposed_model_id

    assert %{
             pool_id: pool_id,
             api_key_id: api_key_id,
             effective_model: effective_model,
             route_class: "proxy_http",
             request_class: "http_json",
             estimated_input_tokens: input_tokens,
             estimated_output_tokens: output_tokens,
             estimated_total_tokens: total_tokens,
             quota_window_dimension_keys: quota_window_dimension_keys
           } = route_state.reservation_snapshot_inputs

    assert Map.keys(route_state.reservation_snapshot_inputs) |> Enum.sort() ==
             [
               :api_key_id,
               :effective_model,
               :estimated_input_tokens,
               :estimated_output_tokens,
               :estimated_total_tokens,
               :pool_id,
               :quota_window_dimension_keys,
               :request_class,
               :route_class
             ]

    assert pool_id == setup.pool.id
    assert api_key_id == auth.api_key.id
    assert effective_model == setup.model.exposed_model_id
    assert input_tokens >= 1
    assert output_tokens == 512
    assert total_tokens == input_tokens + output_tokens

    assert Enum.map(quota_window_dimension_keys, & &1.policy_field) == [
             "max_requests_per_minute",
             "max_tokens_per_day",
             "max_tokens_per_week"
           ]

    assert Enum.all?(quota_window_dimension_keys, &(&1.api_key_id == auth.api_key.id))
    assert Repo.all(Request) == []
  end

  test "prepare stores one full-policy catalog ETag instead of a selected-model or pool digest" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    %{assignment: denied_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Pre-dispatch policy denied upstream"
      })

    denied_model =
      CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
        exposed_model_id: "gpt-pre-dispatch-policy-denied",
        upstream_model_id: "provider-gpt-pre-dispatch-policy-denied",
        display_name: "Pre-dispatch Policy Denied",
        metadata: %{"source_assignment_ids" => [denied_assignment.id]}
      })

    api_key =
      setup.api_key
      |> Ecto.Changeset.change(allowed_model_identifiers: [setup.model.exposed_model_id])
      |> Repo.update!()

    auth = %{auth | api_key: api_key}
    {:ok, policy} = Access.normalize_api_key_policy(api_key)

    payload = %{"model" => setup.model.exposed_model_id, "input" => "policy snapshot"}

    options =
      request_options(auth, payload,
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )
      |> RequestOptions.put_routing(api_key_policy: policy)

    context = CandidateEligibility.visible_model_context(setup.pool, setup.model.exposed_model_id)

    assert denied_model.id in Enum.map(context.visible_models, & &1.id)

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model, context)

    models_options =
      RequestOptions.build(%{}, "/backend-api/codex/models", %{})
      |> RequestOptions.put_routing(api_key_policy: policy)

    assert {:ok, expected} =
             Metadata.codex_catalog_snapshot(
               auth,
               "/backend-api/codex/models",
               models_options
             )

    assert RouteState.codex_models_etag(prepared.route_state) == expected.etag
    assert Enum.map(expected.body["models"], & &1["slug"]) == [setup.model.exposed_model_id]

    inherited = RouteState.put_candidates(prepared.route_state, Enum.reverse(prepared.candidates))
    assert RouteState.codex_models_etag(inherited) == expected.etag
  end

  test "prepare resolves the policy-effective model once and reuses its mode map for the catalog ETag" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    requested_model =
      CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
        exposed_model_id: "gpt-pre-dispatch-requested",
        upstream_model_id: "provider-gpt-pre-dispatch-requested",
        display_name: "Pre-dispatch Requested",
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => "malformed",
          "use_responses_lite" => true
        }
      })

    put_model_serving_override!(setup.pool.id, requested_model.exposed_model_id, "lite")
    put_model_serving_override!(setup.pool.id, setup.model.exposed_model_id, "full")

    policy = %{
      allowed_model_identifiers: nil,
      enforced_model_identifier: setup.model.exposed_model_id,
      enforced_reasoning_effort: nil,
      enforced_service_tier: nil,
      metadata: %{}
    }

    payload = %{"model" => requested_model.exposed_model_id, "input" => "enforced model"}

    options =
      request_options(auth, payload,
        requested_model: requested_model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )
      |> RequestOptions.put_routing(api_key_policy: policy)

    context = CandidateEligibility.visible_model_context(setup.pool, setup.model.exposed_model_id)

    {result, queries} =
      count_repo_sources(fn ->
        PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model, context)
      end)

    assert {:ok, prepared} = result

    assert RequestOptions.model_serving_mode_snapshot(prepared.request_options) == %{
             configured_mode: "full",
             effective_mode: "full",
             source: "override"
           }

    assert Map.get(queries, "pool_model_serving_overrides", 0) == 1

    pricing = CodexPooler.Catalog.pricing_buckets_by_identifier(context.visible_models)

    expected_catalog =
      CodexCatalog.build(context.visible_models, policy, pricing, %{}, %{
        requested_model.exposed_model_id => "lite",
        setup.model.exposed_model_id => "full"
      })

    assert RouteState.codex_models_etag(prepared.route_state) == expected_catalog.etag
  end

  test "prepare finds a canonical override for a case-preserving catalog model id" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    # Given a catalog model whose source casing differs from its persisted override key
    model =
      CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
        exposed_model_id: "GPT-5",
        upstream_model_id: "provider-gpt-5-case",
        display_name: "GPT-5 Case",
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => %{"use_responses_lite" => true}
          },
          "use_responses_lite" => true
        }
      })

    put_model_serving_override!(setup.pool.id, "gpt-5", "full")
    payload = %{"model" => model.exposed_model_id, "input" => "case identity"}

    options =
      request_options(auth, payload,
        requested_model: model.exposed_model_id,
        effective_model: model.exposed_model_id
      )

    context = CandidateEligibility.visible_model_context(setup.pool, model.exposed_model_id)

    # When pre-dispatch resolves the effective serving mode
    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, model, context)

    # Then the lowercase persisted override wins over the source Lite default
    assert RequestOptions.model_serving_mode_snapshot(prepared.request_options) == %{
             configured_mode: "full",
             effective_mode: "full",
             source: "override"
           }
  end

  test "catalog metadata finds a canonical override for a case-preserving model id" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    # Given a case-preserving catalog model backed by a lowercase Full override
    _model =
      CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
        exposed_model_id: "GPT-5",
        upstream_model_id: "provider-gpt-5-case",
        display_name: "GPT-5 Case",
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => %{"use_responses_lite" => true}
          },
          "use_responses_lite" => true
        }
      })

    put_model_serving_override!(setup.pool.id, "gpt-5", "full")
    options = RequestOptions.build(%{}, "/backend-api/codex/models", %{})

    # When catalog metadata is generated from persisted state
    assert {:ok, snapshot} =
             Metadata.codex_catalog_snapshot(auth, "/backend-api/codex/models", options)

    catalog_model = Enum.find(snapshot.body["models"], &(&1["slug"] == "GPT-5"))

    # Then clients see the configured Full mode rather than the source Lite default
    assert catalog_model["use_responses_lite"] == false
  end

  test "prepare keeps an authorized absent media model on its visible host without a mode snapshot" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    absent_model = "future-media-model-#{System.unique_integer([:positive])}"

    api_key =
      setup.api_key
      |> Ecto.Changeset.change(allowed_model_identifiers: [absent_model])
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    auth = %{auth | api_key: api_key}
    payload = %{"model" => absent_model, "input" => "host fallback"}

    options =
      request_options(auth, payload,
        requested_model: absent_model,
        effective_model: absent_model
      )

    hydration = CandidateEligibility.hydrate_model_visibility(setup.pool)

    context =
      Map.merge(hydration, %{
        requested_model: absent_model,
        effective_model: absent_model,
        visible_model: setup.model,
        candidate_snapshots: Map.get(hydration.candidates_by_model_id, setup.model.id, [])
      })

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model, context)

    assert RequestOptions.model_serving_mode_snapshot(prepared.request_options) == nil
    assert prepared.route_state.effective_model_serving_modes == %{}
    assert candidate_ids(prepared.candidates) == [setup.assignment.id]
  end

  test "a visible model without a runtime candidate returns the canonical backend error" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    setup.assignment
    |> Ecto.Changeset.change(health_status: "degraded")
    |> Repo.update!()

    payload = %{"model" => setup.model.exposed_model_id, "input" => "no runtime candidate"}

    assert {:error,
            %{
              status: 503,
              code: "no_eligible_backend",
              message: "no healthy eligible backend is currently available",
              param: "model"
            }} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               setup.model
             )
  end

  test "each websocket turn sees a fresh mode while an already prepared turn stays immutable" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    model = put_assignment_lite_flag!(setup.model, setup.assignment.id, false)
    payload = %{"model" => model.exposed_model_id, "input" => "websocket turn"}

    base_options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.for_websocket(payload)

    assert {:ok, first_turn} =
             PreDispatch.prepare(auth, @endpoint_path, payload, base_options, model)

    assert RequestOptions.model_serving_mode(first_turn.request_options) == "full"

    put_model_serving_override!(setup.pool.id, model.exposed_model_id, "lite")

    assert RequestOptions.model_serving_mode(first_turn.request_options) == "full"

    assert {:ok, second_turn} =
             PreDispatch.prepare(auth, @endpoint_path, payload, base_options, model)

    assert RequestOptions.model_serving_mode_snapshot(second_turn.request_options) == %{
             configured_mode: "lite",
             effective_mode: "lite",
             source: "override"
           }

    assert RouteState.codex_models_etag(first_turn.route_state) == nil
    assert RouteState.codex_models_etag(second_turn.route_state) == nil
  end

  test "opposite assignment Lite source flags do not alter candidate membership" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    %{assignment: fallback_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Candidate invariance fallback upstream"
      })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "candidate invariance"}
    options = request_options(auth, payload, [])

    lite_model =
      put_assignment_lite_flags!(setup.model, %{
        setup.assignment.id => true,
        fallback_assignment.id => false
      })

    assert {:ok, lite_prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, lite_model)

    full_model =
      put_assignment_lite_flags!(lite_model, %{
        setup.assignment.id => false,
        fallback_assignment.id => false
      })

    assert {:ok, full_prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, full_model)

    assert candidate_ids(lite_prepared.candidates) == candidate_ids(full_prepared.candidates)
    assert RequestOptions.model_serving_mode(lite_prepared.request_options) == "lite"
    assert RequestOptions.model_serving_mode(full_prepared.request_options) == "full"
  end

  test "malformed source metadata falls back to the aggregate Lite flag" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => "malformed",
          "use_responses_lite" => true
        }
      })
      |> Repo.update!()

    payload = %{"model" => model.exposed_model_id, "input" => "malformed source metadata"}

    assert {:ok, prepared} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               model
             )

    assert RequestOptions.model_serving_mode_snapshot(prepared.request_options) == %{
             configured_mode: "auto",
             effective_mode: "lite",
             source: "catalog"
           }
  end

  test "prepare attaches defaulted routing settings to the request-local route state without persisting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    refute Pools.get_routing_settings(setup.pool)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "prepare this route with default routing settings"
    }

    request_options =
      request_options(auth, payload,
        request_id:
          "pre-dispatch-route-state-default-settings-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert %RoutingSettings{} = prepared.route_state.routing_settings
    assert prepared.route_state.routing_settings.pool_id == setup.pool.id
    assert prepared.route_state.routing_settings.routing_strategy == "bridge_ring"
    assert prepared.route_state.routing_settings.bridge_ring_size == 3
    assert prepared.route_state.routing_settings.v1_compatibility_enabled
    refute Pools.get_routing_settings(setup.pool)
  end

  test "prepare attaches persisted routing settings to the request-local route state" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    settings =
      setup.pool
      |> Pools.ensure_routing_settings()
      |> Ecto.Changeset.change(%{
        routing_strategy: "deterministic_rotation",
        bridge_ring_size: 7,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "prepare this route with persisted routing settings"
    }

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-route-state-settings-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert %RoutingSettings{} = prepared.route_state.routing_settings
    assert prepared.route_state.routing_settings.pool_id == settings.pool_id
    assert prepared.route_state.routing_settings.routing_strategy == settings.routing_strategy
    assert prepared.route_state.routing_settings.bridge_ring_size == settings.bridge_ring_size
  end

  test "prepare builds fresh route state for each request" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    _settings = Pools.ensure_routing_settings(setup.pool)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "prepare fresh route state"
    }

    first_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-route-state-first-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, first_prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, first_options, setup.model)

    %{assignment: second_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Synthetic route state second upstream"
      })

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          setup.model.metadata
          | "source_assignment_ids" => [setup.assignment.id, second_assignment.id]
        }
      })
      |> Repo.update!()

    first_settings = first_prepared.route_state.routing_settings

    updated_settings =
      first_settings
      |> Ecto.Changeset.change(%{
        routing_strategy: "deterministic_rotation",
        bridge_ring_size: 2,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    second_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-route-state-second-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, second_prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, second_options, model)

    assert length(first_prepared.route_state.candidates) == 1
    assert length(first_prepared.route_state.candidate_snapshots) == 1
    assert length(second_prepared.route_state.candidates) == 2
    assert length(second_prepared.route_state.candidate_snapshots) == 2

    assert first_prepared.route_state.routing_settings.routing_strategy ==
             first_settings.routing_strategy

    assert first_prepared.route_state.routing_settings.bridge_ring_size ==
             first_settings.bridge_ring_size

    assert second_prepared.route_state.routing_settings.routing_strategy ==
             updated_settings.routing_strategy

    assert second_prepared.route_state.routing_settings.bridge_ring_size ==
             updated_settings.bridge_ring_size

    assert Enum.map(first_prepared.route_state.candidates, fn {assignment, _identity} ->
             assignment.id
           end) == [
             setup.assignment.id
           ]

    assert second_assignment.id in Enum.map(
             second_prepared.route_state.candidates,
             fn {assignment, _identity} -> assignment.id end
           )
  end

  test "prepare propagates strict schema failures before reservation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload =
      strict_text_format_payload(%{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => []
      })

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-schema-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:error,
            %{
              code: "invalid_json_schema",
              param: "text.format.schema.required"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert Repo.all(Request) == []
  end

  test "prepare rejects invalid strict function tools before reservation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    sentinel = "STRICT_FUNCTION_SENTINEL_DO_NOT_LOG"

    payload =
      %{
        "model" => setup.model.exposed_model_id,
        "input" => "prepare this route",
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "lookup_fixture",
              "description" => sentinel,
              "strict" => true,
              "parameters" => %{
                "type" => "object",
                "additionalProperties" => false,
                "description" => sentinel,
                "properties" => %{
                  "ok" => %{"type" => "boolean", "description" => sentinel}
                },
                "required" => []
              }
            }
          }
        ]
      }

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-function-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.function.parameters.required"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert Repo.all(Request) == []
  end

  test "prepare authorizes model policy from request options" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "deny this route"
    }

    request_options =
      RequestOptions.build(
        %{request_id: "pre-dispatch-policy-#{System.unique_integer([:positive])}"},
        @endpoint_path,
        payload
      )
      |> RequestOptions.put_routing(
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id,
        api_key_policy: %{
          allowed_model_identifiers: ["other-model"],
          enforced_model_identifier: nil,
          enforced_reasoning_effort: nil,
          enforced_service_tier: nil,
          metadata: %{}
        }
      )

    assert {:error,
            %{
              status: 403,
              code: "model_not_allowed",
              message: "api key is not allowed to use this model"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)
  end

  test "model denial keeps precedence over reasoning availability" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    api_key = %{auth.api_key | maximum_reasoning_effort: "low"}
    auth = %{auth | api_key: api_key}
    payload = %{"model" => setup.model.exposed_model_id, "reasoning" => %{"effort" => "high"}}

    request_options =
      request_options(auth, payload,
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )
      |> RequestOptions.put_routing(
        api_key_policy: %{
          allowed_model_identifiers: ["other-model"],
          enforced_model_identifier: nil,
          enforced_reasoning_effort: nil,
          maximum_reasoning_effort: "low",
          enforced_service_tier: nil,
          metadata: %{}
        }
      )

    assert {:error, %{status: 403, code: "model_not_allowed"}} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)
  end

  test "Gateway.execute records one model denial when model and reasoning are forbidden" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    api_key = %{
      auth.api_key
      | allowed_model_identifiers: ["other-model"],
        maximum_reasoning_effort: "low"
    }

    auth = %{auth | api_key: api_key}

    payload = %{
      "model" => setup.model.exposed_model_id,
      "reasoning" => %{"effort" => "high"}
    }

    assert {:error,
            %{
              status: 403,
              code: "model_not_allowed",
              message: "api key is not allowed to use this model"
            }} =
             Gateway.execute(
               auth,
               @endpoint_path,
               payload,
               RequestOptions.build(%{}, @endpoint_path, payload)
             )

    assert [%Request{last_error_code: "model_not_allowed"}] = Repo.all(Request)
    assert Repo.all(Attempt) == []
    assert FakeUpstream.count(fake) == 0
  end

  test "prepare denies unavailable reasoning before reservation setup" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    api_key = %{auth.api_key | maximum_reasoning_effort: "low"}
    auth = %{auth | api_key: api_key}
    payload = %{"model" => setup.model.exposed_model_id, "reasoning" => %{"effort" => "high"}}

    request_options =
      request_options(auth, payload, requested_model: setup.model.exposed_model_id)

    assert {:error,
            %{
              status: 400,
              code: "reasoning_effort_not_allowed",
              message: "reasoning effort is not available for this API key",
              param: "reasoning.effort",
              reasoning_policy: %{
                policy_mode: "allow_up_to",
                configured_effort: "low",
                requested_effort: "high",
                applied_effort: nil
              }
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert Repo.all(Request) == []
  end

  test "Gateway.execute records one reasoning denial before attempts or upstream dispatch" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    api_key = %{auth.api_key | maximum_reasoning_effort: "low"}
    auth = %{auth | api_key: api_key}

    payload = %{
      "model" => setup.model.exposed_model_id,
      "reasoning" => %{"effort" => "high"}
    }

    assert {:error,
            %{
              status: 400,
              code: "reasoning_effort_not_allowed",
              message: "reasoning effort is not available for this API key",
              param: "reasoning.effort"
            }} =
             Gateway.execute(
               auth,
               @endpoint_path,
               payload,
               RequestOptions.build(%{}, @endpoint_path, payload)
             )

    assert [request] = Repo.all(Request)
    assert Repo.all(Attempt) == []
    assert FakeUpstream.count(fake) == 0

    assert request.request_metadata["gateway_denial"]["reasoning_policy"] == %{
             "policy_mode" => "allow_up_to",
             "configured_effort" => "low",
             "requested_effort" => "high",
             "applied_effort" => nil
           }
  end

  test "prepare uses the preserved Chat Completions reasoning parameter" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    api_key = %{auth.api_key | maximum_reasoning_effort: "low"}
    auth = %{auth | api_key: api_key}
    payload = %{"model" => setup.model.exposed_model_id, "reasoning_effort" => "high"}

    request_options =
      auth
      |> request_options(payload, requested_model: setup.model.exposed_model_id)
      |> RequestOptions.put_openai_compatibility(
        source_endpoint: "/v1/chat/completions",
        openai_chat_payload: payload
      )

    assert {:error, %{code: "reasoning_effort_not_allowed", param: "reasoning_effort"}} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)
  end

  test "prepare carries reasoning decisions for all policy modes" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    for {api_key, payload, expected} <- [
          {auth.api_key,
           %{"model" => setup.model.exposed_model_id, "reasoning" => %{"effort" => "custom"}},
           {:unrestricted, "custom"}},
          {%{auth.api_key | maximum_reasoning_effort: "high"},
           %{"model" => setup.model.exposed_model_id}, {:allow_up_to, "medium"}},
          {%{auth.api_key | enforced_reasoning_effort: "ultra"},
           %{"model" => setup.model.exposed_model_id, "reasoning" => %{"effort" => "low"}},
           {:always_use, "ultra"}}
        ] do
      scoped_auth = %{auth | api_key: api_key}

      options =
        request_options(scoped_auth, payload, requested_model: setup.model.exposed_model_id)

      assert {:ok, prepared} =
               PreDispatch.prepare(scoped_auth, @endpoint_path, payload, options, setup.model)

      assert %{mode: mode, applied_effort: applied} =
               prepared.request_options.routing.reasoning_effort_decision

      assert {mode, applied} == expected
    end
  end

  defp request_options(auth, payload, attrs) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    {routing_attrs, opts} =
      Keyword.split(attrs, [:requested_model, :effective_model])

    opts
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(Keyword.put(routing_attrs, :api_key_policy, policy))
  end

  defp put_model_serving_override!(pool_id, exposed_model_id, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %ModelServingOverride{
      pool_id: pool_id,
      exposed_model_id: exposed_model_id,
      mode: mode,
      created_at: timestamp,
      updated_at: timestamp
    }
    |> Repo.insert!()
  end

  defp put_assignment_lite_flag!(model, assignment_id, enabled?) do
    source_models = Map.get(model.metadata, "source_assignment_models", %{})

    model
    |> Ecto.Changeset.change(%{
      metadata:
        Map.put(
          model.metadata,
          "source_assignment_models",
          Map.put(source_models, assignment_id, %{"use_responses_lite" => enabled?})
        )
    })
    |> Repo.update!()
  end

  defp put_assignment_lite_flags!(model, flags) do
    source_models =
      Map.new(flags, fn {assignment_id, enabled?} ->
        {assignment_id, %{"use_responses_lite" => enabled?}}
      end)

    model
    |> Ecto.Changeset.change(%{
      metadata:
        model.metadata
        |> Map.put("source_assignment_ids", Map.keys(flags))
        |> Map.put("source_assignment_models", source_models)
    })
    |> Repo.update!()
  end

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp count_repo_sources(fun) do
    parent = self()
    handler_id = "pre-dispatch-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and is_binary(metadata[:source]) do
            send(parent, {handler_id, metadata.source})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_sources(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_sources(handler_id, counts) do
    receive do
      {^handler_id, source} ->
        drain_repo_sources(handler_id, Map.update(counts, source, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end
end
