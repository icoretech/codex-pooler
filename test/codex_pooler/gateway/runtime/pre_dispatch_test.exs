defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      gateway_setup: 2,
      gateway_upstream: 4,
      model_quota_window_attrs: 3,
      prime_routing_quota!: 1,
      prime_weekly_exhausted_quota!: 1,
      put_model_source_assignments!: 2,
      start_upstream: 1,
      strict_text_format_payload: 1
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.PartitionRoutability
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Pools
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint_path "/backend-api/codex/responses"

  test "prepare returns request options and routable candidates without reserving a request" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("prepare this route")
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
    assert [_window] = RouteState.quota_windows_for_identity(route_state, identity)
    assert Map.fetch!(route_state.circuit_snapshots, assignment.id).eligible? == true
    assert Map.fetch!(route_state.circuit_eligibility_snapshots, assignment.id).eligible? == true
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    pricing = CodexPooler.Catalog.pricing_buckets_by_identifier([setup.model])

    catalog =
      CodexCatalog.build_canonical(
        [setup.model],
        route_state.visible_model_context.candidates_by_model_id,
        policy,
        pricing,
        %{},
        route_state.effective_model_serving_modes
      )

    %{"models" => [catalog_model]} = catalog.body

    assert RouteState.codex_models_etag(route_state) == catalog.etag

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
             reservation_estimate: reservation_estimate,
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
               :reservation_estimate,
               :route_class
             ]

    assert pool_id == setup.pool.id
    assert api_key_id == auth.api_key.id
    assert effective_model == setup.model.exposed_model_id
    assert input_tokens >= 1
    assert output_tokens == 512
    assert total_tokens == input_tokens + output_tokens
    assert reservation_estimate.input_tokens == input_tokens
    assert reservation_estimate.output_tokens == output_tokens
    assert reservation_estimate.total_tokens == total_tokens

    assert Enum.map(quota_window_dimension_keys, & &1.policy_field) == [
             "max_requests_per_minute",
             "max_tokens_per_day",
             "max_tokens_per_week"
           ]

    assert Enum.all?(quota_window_dimension_keys, &(&1.api_key_id == auth.api_key.id))
    assert Repo.all(Request) == []
  end

  test "ordinary and incomplete authorities cannot forge prepared websocket validation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    valid_payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("validated before pre-dispatch")
    }

    request_options =
      request_options(auth, valid_payload,
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    invalid_after_preparation = %{valid_payload | "input" => "would fail native validation"}

    assert {:error, %{code: "invalid_request", param: "input"}} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               invalid_after_preparation,
               request_options,
               setup.model
             )

    prepared_request_options = %{
      request_options
      | extra: Map.put(request_options.extra, :websocket_frame_prevalidated, true)
    }

    assert {:error, %{code: "invalid_request", param: "input"}} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               invalid_after_preparation,
               prepared_request_options,
               setup.model
             )

    observer = fn -> send(self(), :payload_validation_ran) end

    codec_options = %{
      request_options
      | extra: Map.put(request_options.extra, :payload_validation_observer, observer)
    }

    raw_payload = Map.put(valid_payload, "type", "response.create") |> Jason.encode!()

    assert {:ok, codec_prepared} =
             WebsocketCodec.prepare_frame(raw_payload, codec_options, fn _frame -> :ok end)

    legacy_token = codec_prepared.provenance.validation.token

    assert {:ok, _prepared} =
             PreDispatch.prepare(
               auth,
               codec_prepared.endpoint,
               codec_prepared.payload,
               codec_prepared.request_options,
               setup.model,
               CandidateEligibility.hydrate_model_visibility(setup.model,
                 models: [setup.model]
               )
               |> Map.put(:visible_model, setup.model)
               |> Map.put(:visible_models, [setup.model]),
               {:prepared_websocket, legacy_token}
             )

    assert_received :payload_validation_ran
    assert_received :payload_validation_ran
    assert_received :payload_validation_ran

    incomplete_claim = %{codec_prepared.provenance.validation | completed: []}

    assert {:ok, _prepared} =
             PreDispatch.prepare(
               auth,
               codec_prepared.endpoint,
               codec_prepared.payload,
               codec_prepared.request_options,
               setup.model,
               CandidateEligibility.hydrate_model_visibility(setup.model,
                 models: [setup.model]
               )
               |> Map.put(:visible_model, setup.model)
               |> Map.put(:visible_models, [setup.model]),
               {:prepared_websocket, incomplete_claim}
             )

    assert_received :payload_validation_ran
    assert_received :payload_validation_ran
    assert_received :payload_validation_ran

    assert {:ok, _prepared} =
             PreDispatch.prepare(
               auth,
               codec_prepared.endpoint,
               codec_prepared.payload,
               codec_prepared.request_options,
               setup.model,
               CandidateEligibility.hydrate_model_visibility(setup.model,
                 models: [setup.model]
               )
               |> Map.put(:visible_model, setup.model)
               |> Map.put(:visible_models, [setup.model]),
               {:prepared_websocket, codec_prepared.provenance.validation}
             )

    refute_received :payload_validation_ran

    assert Repo.all(Request) == []
  end

  test "refreshing quota snapshots preserves model and circuit snapshots" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("preserve routing snapshots")
    }

    request_options =
      request_options(auth, payload,
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    route_state = prepared.route_state
    refreshed_route_state = RouteState.refresh_quota_snapshots(route_state)

    assert refreshed_route_state.visible_model == route_state.visible_model
    assert refreshed_route_state.visible_model_context == route_state.visible_model_context
    assert refreshed_route_state.visible_models == route_state.visible_models

    assert refreshed_route_state.effective_model_serving_modes ==
             route_state.effective_model_serving_modes

    assert refreshed_route_state.circuit_snapshots == route_state.circuit_snapshots

    assert refreshed_route_state.circuit_eligibility_snapshots ==
             route_state.circuit_eligibility_snapshots
  end

  test "put_candidates narrows routing candidates without replacing candidate snapshots" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    alternate =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Route state narrowing alternate upstream"
      })

    candidates = [
      {setup.assignment, setup.identity},
      {alternate.assignment, alternate.identity}
    ]

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: candidates
      })

    narrowed = RouteState.put_candidates(route_state, [List.first(candidates)])

    assert narrowed.candidate_snapshots == candidates
    assert narrowed.saved_reset_auto_cohort == candidates
    assert narrowed.candidates == [List.first(candidates)]
  end

  test "saved reset cohort defaults to supplied candidates and survives route state replacements" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    candidate = {setup.assignment, setup.identity}

    alternate =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Saved reset cohort alternate upstream"
      })

    alternate_candidate = {alternate.assignment, alternate.identity}

    request_options =
      request_options(auth, %{"model" => setup.model.exposed_model_id},
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [candidate, alternate_candidate]
      })

    assert route_state.saved_reset_auto_cohort == [candidate, alternate_candidate]

    replaced =
      route_state
      |> RouteState.put_saved_reset_auto_cohort([alternate_candidate])
      |> RouteState.put_candidates([candidate])
      |> RouteState.preload_routing_snapshots(auth, setup.model, request_options)
      |> RouteState.refresh_quota_snapshots()

    assert replaced.candidates == [candidate]
    assert replaced.saved_reset_auto_cohort == [alternate_candidate]
  end

  test "route state atomically binds quota snapshots to their observation instant" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    snapshot_at = ~U[2026-07-25 12:00:00.000000Z]

    snapshots = QuotaWindows.load_routing_quota_snapshots([setup.identity.id], snapshot_at)

    assert %{raw_windows: [_window], as_of: ^snapshot_at} =
             Map.fetch!(snapshots, setup.identity.id)

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [{setup.assignment, setup.identity}]
      })

    assert route_state.quota_snapshots == %{}

    updated_route_state = RouteState.put_quota_snapshots(route_state, snapshots)

    assert updated_route_state.quota_snapshots == snapshots

    assert RouteState.quota_snapshot_for_identity(updated_route_state, setup.identity).as_of ==
             snapshot_at

    assert updated_route_state.visible_model == route_state.visible_model
    assert updated_route_state.circuit_snapshots == route_state.circuit_snapshots

    assert %RouteState{quota_snapshots: %{}} =
             RouteState.put_quota_snapshots(updated_route_state, %{})

    assert_raise ArgumentError, fn ->
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [{setup.assignment, setup.identity}],
        quota_snapshots: %{setup.identity.id => []}
      })
    end
  end

  test "snapshot load failure aborts without installing a partial or older generation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [{setup.assignment, setup.identity}]
      })
      |> RouteState.refresh_quota_snapshots()

    original_snapshots = route_state.quota_snapshots

    assert_raise CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot.LoadError, fn ->
      RouteState.refresh_quota_snapshots(route_state, fn _identity_ids, _as_of ->
        raise CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot.LoadError
      end)
    end

    assert route_state.quota_snapshots == original_snapshots
  end

  test "missing identity snapshot entry fails instead of becoming zero-row coverage" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [{setup.assignment, setup.identity}]
      })

    assert_raise KeyError, fn ->
      RouteState.quota_windows_for_identity(route_state, setup.identity)
    end
  end

  test "preload captures one read instant before the bulk quota read and stores that exact instant" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    request_options =
      request_options(auth, %{"model" => setup.model.exposed_model_id},
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [{setup.assignment, setup.identity}]
      })

    traced_mfa = {QuotaWindows, :load_routing_quota_snapshots, 2}
    {:module, QuotaWindows} = Code.ensure_loaded(QuotaWindows)
    :erlang.trace_pattern(traced_mfa, true, [])

    task =
      Task.async(fn ->
        receive do
          :preload -> :ok
        end

        RouteState.preload_routing_snapshots(
          route_state,
          auth,
          setup.model,
          request_options
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)
    :erlang.trace(task.pid, true, [:call, {:tracer, self()}])
    before_preload = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    try do
      send(task.pid, :preload)
      preloaded = Task.await(task)
      after_preload = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert_receive {:trace, pid, :call,
                      {QuotaWindows, :load_routing_quota_snapshots,
                       [[identity_id], %DateTime{} = read_at]}}
                     when pid == task.pid and identity_id == setup.identity.id

      assert RouteState.quota_snapshot_for_identity(preloaded, setup.identity).as_of == read_at
      assert DateTime.compare(read_at, before_preload) in [:eq, :gt]
      assert DateTime.compare(read_at, after_preload) in [:eq, :lt]

      assert preloaded.quota_snapshots ==
               QuotaWindows.load_routing_quota_snapshots([setup.identity.id], read_at)
    after
      :erlang.trace_pattern(traced_mfa, false, [])

      if Process.alive?(task.pid) do
        :erlang.trace(task.pid, false, [:call])
        Task.shutdown(task, :brutal_kill)
      end
    end
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

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("policy snapshot")
    }

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

  test "prepare uses one typed policy-visible projection for quota snapshots and ETags" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("typed visible models")
    }

    options = request_options(auth, payload, [])

    context =
      CandidateEligibility.visible_model_context(setup.pool, setup.model.exposed_model_id)
      |> Map.update!(:visible_models, &(&1 ++ [%{unexpected: "context entry"}]))

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model, context)

    route_state = prepared.route_state
    policy = prepared.request_options.routing.api_key_policy
    pricing = CodexPooler.Catalog.pricing_buckets_by_identifier([setup.model])

    expected_catalog =
      CodexCatalog.build_canonical(
        [setup.model],
        route_state.visible_model_context.candidates_by_model_id,
        policy,
        pricing,
        %{},
        route_state.effective_model_serving_modes,
        routable_assignment_ids_by_model_id: fn ->
          PartitionRoutability.routable_assignment_ids_by_model_id(
            [setup.model],
            route_state.visible_model_context.candidates_by_model_id,
            route_state.quota_snapshots
          )
        end
      )

    assert route_state.visible_models == [setup.model]
    assert Map.keys(route_state.quota_snapshots) == [setup.identity.id]
    assert RouteState.codex_models_etag(route_state) == expected_catalog.etag
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

    payload = %{
      "model" => requested_model.exposed_model_id,
      "input" => native_text_input("enforced model")
    }

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
      CodexCatalog.build_canonical(
        context.visible_models,
        context.candidates_by_model_id,
        policy,
        pricing,
        %{},
        %{
          requested_model.exposed_model_id => "lite",
          setup.model.exposed_model_id => "full"
        }
      )

    assert RouteState.codex_models_etag(prepared.route_state) == expected_catalog.etag
  end

  test "pre-dispatch ETag matches restricted GET for shared assignments", %{conn: conn} do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    alternate =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Requested model alternate partition"
      })

    prime_routing_quota!(alternate.identity)

    requested_source =
      get_in(setup.model.metadata, ["source_assignment_models", setup.assignment.id])

    requested_model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          setup.model.metadata
          | "source_assignment_ids" => [setup.assignment.id, alternate.assignment.id],
            "source_assignment_models" => %{
              setup.assignment.id => requested_source,
              alternate.assignment.id => Map.put(requested_source, "context_window", 111_111)
            }
        }
      })
      |> Repo.update!()

    shared_model_id = "gpt-pre-dispatch-shared-assignment"

    shared_source =
      requested_source
      |> Map.put("slug", shared_model_id)
      |> Map.put("display_name", "Pre-dispatch Shared Assignment")
      |> Map.put("description", "Pre-dispatch Shared Assignment")
      |> Map.put("upstream_model_id", "provider-gpt-pre-dispatch-shared-assignment")

    _shared_model =
      CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
        exposed_model_id: shared_model_id,
        upstream_model_id: "provider-gpt-pre-dispatch-shared-assignment",
        display_name: "Pre-dispatch Shared Assignment",
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{setup.assignment.id => shared_source}
        }
      })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(setup.identity, [
               model_quota_window_attrs(requested_model, "primary", %{
                 used_percent: Decimal.new("100")
               })
             ])

    api_key =
      setup.api_key
      |> Ecto.Changeset.change(allowed_model_identifiers: [requested_model.exposed_model_id])
      |> Repo.update!()

    setup = %{setup | api_key: api_key, model: requested_model}
    {:ok, auth_context} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => requested_model.exposed_model_id,
      "input" => native_text_input("shared assignment")
    }

    options = request_options(auth_context, payload, [])

    context =
      CandidateEligibility.visible_model_context(
        setup.pool,
        requested_model.exposed_model_id
      )

    {result, queries} =
      count_repo_sources(fn ->
        PreDispatch.prepare(
          auth_context,
          @endpoint_path,
          payload,
          options,
          requested_model,
          context
        )
      end)

    assert {:ok, prepared} = result
    assert Map.get(queries, "upstream_identities", 0) == 1
    assert Map.get(queries, "account_quota_windows", 0) == 0

    models_conn = conn |> auth(setup) |> get("/backend-api/codex/models")
    assert %{"models" => [%{"slug" => slug}]} = json_response(models_conn, 200)
    assert slug == requested_model.exposed_model_id

    dispatch_etag = RouteState.codex_models_etag(prepared.route_state)
    assert [restricted_get_etag] = get_resp_header(models_conn, "etag")
    assert is_binary(dispatch_etag) and dispatch_etag != ""
    assert is_binary(restricted_get_etag) and restricted_get_etag != ""

    assert {dispatch_etag,
            prepared.route_state.visible_model_context.selected_partition_assignment_ids} ==
             {restricted_get_etag, [alternate.assignment.id]}
  end

  test "route-scoped quota snapshots cover every downstream requested-model lane" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    policy_visible =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Policy-visible ETag assignment"
      })

    policy_denied =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Policy-denied ETag assignment"
      })

    prime_routing_quota!(policy_visible.identity)
    prime_routing_quota!(policy_denied.identity)

    for {assignment, exposed_model_id} <- [
          {policy_visible.assignment, "gpt-policy-visible-etag"},
          {policy_denied.assignment, "gpt-policy-denied-etag"}
        ] do
      CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
        exposed_model_id: exposed_model_id,
        upstream_model_id: "provider-#{exposed_model_id}",
        display_name: exposed_model_id,
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })
    end

    api_key =
      setup.api_key
      |> Ecto.Changeset.change(
        allowed_model_identifiers: [setup.model.exposed_model_id, "gpt-policy-visible-etag"]
      )
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    auth = %{auth | api_key: api_key}

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("route snapshot scope")
    }

    base_options = request_options(auth, payload, [])

    cases = [
      {"websocket", RequestOptions.for_websocket(base_options, payload),
       [setup.identity.id, policy_visible.identity.id], true},
      {"/v1/responses",
       RequestOptions.mark_openai_compatibility_origin(
         base_options,
         "/v1/responses",
         @endpoint_path
       ), [setup.identity.id], false},
      {"/v1/chat/completions",
       RequestOptions.mark_openai_compatibility_origin(
         base_options,
         "/v1/chat/completions",
         @endpoint_path
       ), [setup.identity.id], false},
      {"native HTTP JSON", base_options, [setup.identity.id, policy_visible.identity.id], true},
      {"native HTTP SSE",
       RequestOptions.put_transport(base_options,
         transport: "http_sse",
         route_class: "proxy_stream"
       ), [setup.identity.id, policy_visible.identity.id], true}
    ]

    for {lane, options, expected_identity_ids, expects_etag?} <- cases do
      context =
        CandidateEligibility.visible_model_context(
          setup.pool,
          setup.model.exposed_model_id
        )

      assert {:ok, prepared} =
               PreDispatch.prepare(
                 auth,
                 @endpoint_path,
                 payload,
                 options,
                 setup.model,
                 context
               ),
             lane

      snapshot_identity_ids =
        prepared.route_state.quota_snapshots
        |> Map.keys()
        |> Enum.sort()

      assert snapshot_identity_ids == Enum.sort(expected_identity_ids), lane
      refute policy_denied.identity.id in snapshot_identity_ids, lane

      if expects_etag? do
        assert is_binary(RouteState.codex_models_etag(prepared.route_state)), lane
      else
        assert RouteState.codex_models_etag(prepared.route_state) == nil, lane
      end
    end
  end

  test "only native backend websocket routes capture a response-control turn snapshot" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("native response control")
    }

    base_options = request_options(auth, payload, [])

    native_websocket = RequestOptions.for_websocket(base_options, payload)

    backend_alias_websocket =
      native_websocket
      |> RequestOptions.put_openai_compatibility(
        source_endpoint: "/backend-api/codex/v1/responses"
      )

    public_websocket =
      native_websocket
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/responses",
        @endpoint_path
      )
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    ineligible = [
      {"public websocket", @endpoint_path, public_websocket},
      {"compact", "/backend-api/codex/responses/compact",
       RequestOptions.build(base_options, "/backend-api/codex/responses/compact", payload)},
      {"translated chat", @endpoint_path,
       RequestOptions.mark_openai_compatibility_origin(
         base_options,
         "/v1/chat/completions",
         @endpoint_path
       )},
      {"usage", "/api/codex/usage",
       RequestOptions.build(base_options, "/api/codex/usage", payload)},
      {"unrelated", "/backend-api/codex/images/generations",
       RequestOptions.build(base_options, "/backend-api/codex/images/generations", payload)}
    ]

    etags =
      for {lane, options} <- [
            {"canonical websocket", native_websocket},
            {"backend alias websocket", backend_alias_websocket}
          ] do
        assert {:ok, prepared} =
                 PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model),
               lane

        models_etag = RouteState.codex_models_etag(prepared.route_state)
        assert is_binary(models_etag) and models_etag != "", lane
        {lane, models_etag}
      end

    assert [{"canonical websocket", etag}, {"backend alias websocket", etag}] = etags

    for {lane, endpoint, options} <- ineligible do
      assert {:ok, prepared} =
               PreDispatch.prepare(auth, endpoint, payload, options, setup.model),
             lane

      assert RouteState.codex_models_etag(prepared.route_state) == nil, lane
    end
  end

  test "a prepared websocket turn keeps its snapshot while the next turn resolves a new ETag" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("fresh response control turn")
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.for_websocket(payload)

    assert {:ok, first_turn} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model)

    first_etag = RouteState.codex_models_etag(first_turn.route_state)
    assert is_binary(first_etag) and first_etag != ""

    changed_model = put_assignment_lite_flag!(setup.model, setup.assignment.id, true)

    assert {:ok, next_turn} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, changed_model)

    next_etag = RouteState.codex_models_etag(next_turn.route_state)

    assert first_etag != next_etag
    assert RouteState.codex_models_etag(first_turn.route_state) == first_etag
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
            setup.assignment.id => %{"slug" => "GPT-5", "use_responses_lite" => true}
          },
          "use_responses_lite" => true
        }
      })

    put_model_serving_override!(setup.pool.id, "gpt-5", "full")
    payload = %{"model" => model.exposed_model_id, "input" => native_text_input("case identity")}

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
            setup.assignment.id => %{"slug" => "GPT-5", "use_responses_lite" => true}
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
    payload = %{"model" => absent_model, "input" => native_text_input("host fallback")}

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

  test "prepare snapshots an authorized absent image model on its visible host before candidates" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    absent_model = "future-image-model-#{System.unique_integer([:positive])}"

    %{assignment: fallback_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Visible image host fallback upstream"
      })

    model =
      put_assignment_lite_flags!(setup.model, %{
        setup.assignment.id => false,
        fallback_assignment.id => true
      })

    api_key =
      setup.api_key
      |> Ecto.Changeset.change(allowed_model_identifiers: [absent_model])
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    auth = %{auth | api_key: api_key}
    payload = %{"model" => absent_model, "input" => native_text_input("image host fallback")}

    options =
      request_options(auth, payload,
        requested_model: absent_model,
        effective_model: absent_model,
        collect_openai_image_stream: true,
        openai_source_endpoint: "/v1/images/generations",
        openai_translated_endpoint: "/backend-api/codex/responses"
      )

    hydration = CandidateEligibility.hydrate_model_visibility(setup.pool)

    context =
      Map.merge(hydration, %{
        requested_model: absent_model,
        effective_model: absent_model,
        visible_model: model,
        candidate_snapshots: Map.get(hydration.candidates_by_model_id, model.id, [])
      })

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, model, context)

    assert RequestOptions.model_serving_mode_snapshot(prepared.request_options) == %{
             configured_mode: "auto",
             effective_mode: "lite",
             source: "catalog"
           }

    assert prepared.route_state.effective_model_serving_modes == %{}

    assert Enum.sort(candidate_ids(prepared.candidates)) ==
             Enum.sort([setup.assignment.id, fallback_assignment.id])

    for {assignment, _identity} <- prepared.candidates do
      selected_options =
        RequestOptions.put_routing(prepared.request_options,
          routing_attempt_metadata: %{pool_upstream_assignment_id: assignment.id}
        )

      assert RequestOptions.model_serving_mode_snapshot(selected_options) == %{
               configured_mode: "auto",
               effective_mode: "lite",
               source: "catalog"
             }

      assert RequestOptions.use_responses_lite?(selected_options)
    end
  end

  test "a visible model without a runtime candidate returns the canonical backend error" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    setup.assignment
    |> Ecto.Changeset.change(health_status: "degraded")
    |> Repo.update!()

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("no runtime candidate")
    }

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
    payload = %{"model" => model.exposed_model_id, "input" => native_text_input("websocket turn")}

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

    first_etag = RouteState.codex_models_etag(first_turn.route_state)
    second_etag = RouteState.codex_models_etag(second_turn.route_state)

    assert is_binary(first_etag)
    assert is_binary(second_etag)
    assert first_etag != second_etag
  end

  test "opposite assignment Lite source flags partition new-turn candidate membership" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    %{assignment: fallback_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Candidate invariance fallback upstream"
      })

    fallback_assignment =
      fallback_assignment
      |> Ecto.Changeset.change(created_at: DateTime.add(setup.assignment.created_at, 1, :second))
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("candidate invariance")
    }

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

    assert candidate_ids(lite_prepared.candidates) == [setup.assignment.id]

    assert Enum.sort(candidate_ids(full_prepared.candidates)) ==
             Enum.sort([setup.assignment.id, fallback_assignment.id])

    assert RequestOptions.model_serving_mode(lite_prepared.request_options) == "lite"
    assert RequestOptions.model_serving_mode(full_prepared.request_options) == "full"
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "backend Codex catalog-driven new turns use only assignments from the selected canonical schema partition" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("new partitioned turn")
    }

    assert {:ok, prepared} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               model
             )

    assert candidate_ids(prepared.route_state.candidate_snapshots) == [
             setup.assignment.id,
             divergent.assignment.id
           ]

    assert prepared.route_state.visible_model_context.selected_partition_assignment_ids == [
             setup.assignment.id
           ]

    assert candidate_ids(prepared.candidates) == [setup.assignment.id]
  end

  test "prepare captures only runtime-compatible candidates before canonical partition narrowing" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)

    incompatible =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Runtime-incompatible saved reset cohort upstream"
      })

    source_models = Map.fetch!(model.metadata, "source_assignment_models")
    source = Map.fetch!(source_models, setup.assignment.id)

    model =
      model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 3,
        metadata: %{
          model.metadata
          | "source_assignment_ids" => [
              setup.assignment.id,
              divergent.assignment.id,
              incompatible.assignment.id
            ],
            "source_assignment_models" =>
              Map.put(
                source_models,
                incompatible.assignment.id,
                Map.put(source, "capabilities", %{"responses" => false})
              )
        }
      })
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("saved reset cohort boundary")
    }

    assert {:ok, prepared} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               model
             )

    assert Enum.sort(candidate_ids(prepared.route_state.candidate_snapshots)) ==
             Enum.sort([
               setup.assignment.id,
               divergent.assignment.id,
               incompatible.assignment.id
             ])

    assert Enum.sort(candidate_ids(prepared.route_state.saved_reset_auto_cohort)) ==
             Enum.sort([setup.assignment.id, divergent.assignment.id])

    assert candidate_ids(prepared.route_state.candidates) == [setup.assignment.id]
    assert candidate_ids(prepared.candidates) == [setup.assignment.id]

    refute incompatible.identity.id in candidate_identity_ids(
             prepared.route_state.saved_reset_auto_cohort
           )

    assert divergent.identity.id in candidate_identity_ids(
             prepared.route_state.saved_reset_auto_cohort
           )
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "translated Responses turns use every valid canonical assignment once" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("translated partitioned turn")
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    {result, queries} =
      count_repo_sources(fn ->
        PreDispatch.prepare(auth, @endpoint_path, payload, options, model)
      end)

    assert {:ok, prepared} = result

    assert candidate_ids(prepared.route_state.candidate_snapshots) == [
             setup.assignment.id,
             divergent.assignment.id
           ]

    assert prepared.route_state.visible_model_context.selected_partition_assignment_ids == [
             setup.assignment.id
           ]

    assert prepared.route_state.visible_model_context.valid_canonical_assignment_ids ==
             Enum.sort([setup.assignment.id, divergent.assignment.id])

    assert candidate_ids(prepared.candidates) == [
             setup.assignment.id,
             divergent.assignment.id
           ]

    assert Map.keys(prepared.route_state.quota_snapshots) |> Enum.sort() ==
             Enum.sort([setup.identity.id, divergent.identity.id])

    assert Map.keys(prepared.route_state.circuit_snapshots) |> Enum.sort() ==
             Enum.sort([setup.assignment.id, divergent.assignment.id])

    assert Map.get(queries, "upstream_identities", 0) == 1
    assert Map.get(queries, "account_quota_windows", 0) == 0
    assert Map.get(queries, "routing_circuit_states", 0) == 1
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "translated Responses excludes malformed canonical assignments" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    model =
      model
      |> Ecto.Changeset.change(%{
        metadata: %{
          model.metadata
          | "source_assignment_models" => %{
              setup.assignment.id =>
                get_in(model.metadata, ["source_assignment_models", setup.assignment.id]),
              divergent.assignment.id => "malformed"
            }
        }
      })
      |> Repo.update!()

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("malformed alternate")
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/chat/completions",
        "/backend-api/codex/responses"
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, model)

    assert prepared.route_state.visible_model_context.valid_canonical_assignment_ids == [
             setup.assignment.id
           ]

    assert candidate_ids(prepared.candidates) == [setup.assignment.id]
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "raw backend provenance and non-Responses translations stay selected-only" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("selected-only control")
    }

    raw_backend_options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.put_openai_compatibility(source_endpoint: "/backend-api/codex/responses")

    media_options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/images/generations",
        "/backend-api/codex/images/generations"
      )

    for options <- [raw_backend_options, media_options] do
      assert {:ok, prepared} =
               PreDispatch.prepare(auth, @endpoint_path, payload, options, model)

      assert prepared.route_state.visible_model_context.valid_canonical_assignment_ids ==
               Enum.sort([setup.assignment.id, divergent.assignment.id])

      assert candidate_ids(prepared.candidates) == [setup.assignment.id]
    end
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "translated Responses keeps pre-attached file affinity exact" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("file-affinity turn")
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/responses",
        "/backend-api/codex/responses"
      )
      |> RequestOptions.put_routing(file_affinity_assignment_id: divergent.assignment.id)

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, model)

    assert prepared.request_options.routing.file_affinity_assignment_id == divergent.assignment.id
    assert candidate_ids(prepared.candidates) == [divergent.assignment.id]
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "a compatible hard-pinned continuation stays on a non-selected schema partition" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {model, divergent} = add_divergent_assignment!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      %CodexSession{
        pool_id: setup.pool.id,
        api_key_id: auth.api_key.id,
        session_key: "partition-session-#{System.unique_integer([:positive])}",
        pool_upstream_assignment_id: divergent.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("continue divergent partition"),
      "previous_response_id" => "response-partition-anchor"
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.put_continuity(
        codex_session: session,
        previous_response_id: payload["previous_response_id"]
      )

    translated_options =
      RequestOptions.mark_openai_compatibility_origin(
        options,
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, model)

    assert {:ok, translated_prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, translated_options, model)

    assert prepared.route_state.visible_model_context.selected_partition_assignment_ids == [
             setup.assignment.id
           ]

    assert candidate_ids(prepared.candidates) == [divergent.assignment.id]
    assert candidate_ids(translated_prepared.candidates) == [divergent.assignment.id]
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "a new turn fails closed when no routable assignment has a valid canonical source" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          setup.model.metadata
          | "source_assignment_models" => %{setup.assignment.id => "malformed"}
        }
      })
      |> Repo.update!()

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("missing partition")
    }

    assert {:error, %{status: 503, code: "no_eligible_backend"}} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               model
             )

    assert Repo.all(Request) == []
  end

  @tag :external_issues_229_231
  @tag :issue_231
  test "a hard-pinned continuation rejects an assignment with malformed canonical source metadata" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          setup.model.metadata
          | "source_assignment_models" => %{setup.assignment.id => "malformed"}
        }
      })
      |> Repo.update!()

    session =
      %CodexSession{
        pool_id: setup.pool.id,
        api_key_id: auth.api_key.id,
        session_key: "invalid-partition-session-#{System.unique_integer([:positive])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("invalid pinned partition"),
      "previous_response_id" => "response-invalid-partition"
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.put_continuity(
        codex_session: session,
        previous_response_id: payload["previous_response_id"]
      )

    assert {:error, %{status: 503, code: "pinned_continuation_unavailable"}} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, model)

    assert Repo.all(Request) == []
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "presentation-only source drift keeps every seat in one backend partition" do
    starved = starved_anchor_partition_pool!(:cosmetic)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("cosmetic drift turn")
    }

    assert {:ok, prepared} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               starved.model
             )

    context = prepared.route_state.visible_model_context

    every_assignment_id =
      Enum.sort(starved.exhausted_assignment_ids ++ starved.healthy_assignment_ids)

    assert context.valid_canonical_assignment_ids == every_assignment_id

    # Cosmetic hint drift no longer produces a second partition, so the two
    # weekly-exhausted seats never hide the six healthy ones.
    assert context.selected_partition_assignment_ids == every_assignment_id
    assert Enum.sort(candidate_ids(prepared.candidates)) == every_assignment_id

    # Quota is now read for every identity, healthy ones included.
    assert Enum.sort(Map.keys(prepared.route_state.quota_snapshots)) ==
             Enum.sort(starved.exhausted_identity_ids ++ starved.healthy_identity_ids)

    # A single partition carries no partition-filtering evidence.
    assert prepared.request_options.routing.canonical_partition == nil
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "presentation-only source drift dispatches the backend turn to a healthy seat" do
    starved = starved_anchor_partition_pool!(:cosmetic)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("cosmetic drift dispatch")
    }

    assert {:ok, response} =
             Gateway.execute(
               auth,
               @endpoint_path,
               payload,
               RequestOptions.build(%{}, @endpoint_path, payload)
             )

    assert response.status == 200
    assert %{"id" => "resp_healthy_partition"} = Jason.decode!(response.raw_body)
    assert FakeUpstream.count(starved.healthy_upstream) == 1
    assert FakeUpstream.count(starved.exhausted_upstream) == 0

    assert [attempt] = Repo.all(Attempt)
    assert attempt.pool_upstream_assignment_id in starved.healthy_assignment_ids
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "behavioral source drift anchors the backend turn on the largest routable partition" do
    starved = starved_anchor_partition_pool!(:behavioral)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("behavioral drift turn")
    }

    assert {:ok, prepared} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               starved.model
             )

    context = prepared.route_state.visible_model_context

    assert context.valid_canonical_assignment_ids ==
             Enum.sort(starved.exhausted_assignment_ids ++ starved.healthy_assignment_ids)

    # The partitions stay apart because the drift is behavioral, while the
    # larger routable cohort becomes the selected partition.
    assert context.selected_partition_assignment_ids ==
             Enum.sort(starved.healthy_assignment_ids)

    assert Enum.sort(candidate_ids(prepared.candidates)) ==
             Enum.sort(starved.healthy_assignment_ids)

    assert %{
             "partition_count" => 2,
             "selected_count" => 6,
             "filtered_count" => 2,
             "routable_selection" => false
           } = prepared.request_options.routing.canonical_partition
  end

  @tag :partition_quota_starvation
  test "multi-partition backend turns read quota once for the cap and the models etag" do
    starved = starved_anchor_partition_pool!(:behavioral)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("single snapshot etag turn")
    }

    context =
      CandidateEligibility.visible_model_context(
        starved.setup.pool,
        starved.model.exposed_model_id
      )

    {result, queries} =
      count_repo_sources(fn ->
        PreDispatch.prepare(
          auth,
          @endpoint_path,
          payload,
          request_options(auth, payload, []),
          starved.model,
          context
        )
      end)

    assert {:ok, prepared} = result

    assert prepared.route_state.visible_model_context.selected_partition_assignment_ids ==
             Enum.sort(starved.healthy_assignment_ids)

    # One quota read backs the routing cap and the models ETag build; the two
    # selections resolve from the same observation by construction.
    assert Map.get(queries, "upstream_identities", 0) == 1
    assert Map.get(queries, "account_quota_windows", 0) == 0

    policy = prepared.request_options.routing.api_key_policy
    pricing = CodexPooler.Catalog.pricing_buckets_by_identifier(context.visible_models)

    expected_catalog =
      CodexCatalog.build_canonical(
        context.visible_models,
        context.candidates_by_model_id,
        policy,
        pricing,
        %{},
        prepared.route_state.effective_model_serving_modes,
        routable_assignment_ids_by_model_id: fn ->
          PartitionRoutability.routable_assignment_ids_by_model_id(
            context.visible_models,
            context.candidates_by_model_id
          )
        end
      )

    assert RouteState.codex_models_etag(prepared.route_state) == expected_catalog.etag
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "behavioral source drift dispatches the backend turn to a healthy partition seat" do
    starved = starved_anchor_partition_pool!(:behavioral)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("behavioral drift dispatch")
    }

    assert {:ok, response} =
             Gateway.execute(
               auth,
               @endpoint_path,
               payload,
               RequestOptions.build(%{}, @endpoint_path, payload)
             )

    assert response.status == 200
    assert %{"id" => "resp_healthy_partition"} = Jason.decode!(response.raw_body)
    assert FakeUpstream.count(starved.healthy_upstream) == 1
    assert FakeUpstream.count(starved.exhausted_upstream) == 0

    assert [attempt] = Repo.all(Attempt)
    assert attempt.pool_upstream_assignment_id in starved.healthy_assignment_ids

    # The successful turn persists the same top-level canonical_partition
    # evidence the denial path records, so one request-log query covers both
    # outcomes.
    assert [request] = Repo.all(Request)

    assert %{
             "partition_count" => 2,
             "selected_count" => 6,
             "filtered_count" => 2,
             "routable_selection" => false,
             "digest_prefix" => digest_prefix
           } = request.request_metadata["canonical_partition"]

    assert is_binary(digest_prefix) and byte_size(digest_prefix) == 12
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "a fully exhausted split pool records why partition filtering held seats back" do
    starved = starved_anchor_partition_pool!(:behavioral_all_exhausted)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("fully exhausted split pool")
    }

    assert {:error, %{status: 503, code: "quota_exhausted"}} =
             Gateway.execute(
               auth,
               @endpoint_path,
               payload,
               RequestOptions.build(%{}, @endpoint_path, payload)
             )

    assert FakeUpstream.count(starved.exhausted_upstream) == 0
    assert FakeUpstream.count(starved.healthy_upstream) == 0

    assert [request] = Repo.all(Request)
    assert request.status == "rejected"
    assert request.last_error_code == "quota_exhausted"
    assert Repo.all(Attempt) == []

    exclusions = request.request_metadata["candidate_exclusions"]

    # Nothing is routable anywhere, so the largest partition is kept and the
    # denial still names only its seats.
    assert Enum.sort(Enum.map(exclusions, & &1["pool_upstream_assignment_id"])) ==
             Enum.sort(starved.healthy_assignment_ids)

    # The request log now says the other two seats existed and were held back
    # by partition filtering, which is what makes this self-diagnosable.
    assert %{
             "partition_count" => 2,
             "selected_count" => 6,
             "filtered_count" => 2,
             "routable_selection" => false,
             "digest_prefix" => digest_prefix
           } = request.request_metadata["canonical_partition"]

    assert String.length(digest_prefix) == 12
    assert digest_prefix =~ ~r/\A[0-9a-f]{12}\z/
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "the translated Responses surface still serves a behaviorally split pool" do
    starved = starved_anchor_partition_pool!(:behavioral)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("translated surface on the split pool")
    }

    options =
      RequestOptions.build(%{}, @endpoint_path, payload)
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    assert {:ok, response} = Gateway.execute(auth, @endpoint_path, payload, options)

    assert response.status == 200
    assert %{"id" => "resp_healthy_partition"} = Jason.decode!(response.raw_body)
    assert FakeUpstream.count(starved.healthy_upstream) == 1
    assert FakeUpstream.count(starved.exhausted_upstream) == 0

    assert [attempt] = Repo.all(Attempt)
    assert attempt.pool_upstream_assignment_id in starved.healthy_assignment_ids
  end

  @tag :external_issues_229_231
  @tag :partition_quota_starvation
  test "the translated Responses surface records no partition filtering evidence" do
    starved = starved_anchor_partition_pool!(:behavioral)
    {:ok, auth} = Access.authenticate_authorization_header(starved.setup.authorization)

    payload = %{
      "model" => starved.model.exposed_model_id,
      "input" => native_text_input("translated surface partition evidence")
    }

    options =
      auth
      |> request_options(payload, [])
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    assert {:ok, translated} =
             PreDispatch.prepare(auth, @endpoint_path, payload, options, starved.model)

    # That surface is never capped to one partition, so reporting held-back
    # seats would misrepresent what happened.
    assert translated.request_options.routing.canonical_partition == nil

    assert Enum.sort(candidate_ids(translated.candidates)) ==
             Enum.sort(starved.exhausted_assignment_ids ++ starved.healthy_assignment_ids)

    assert {:ok, backend} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               starved.model
             )

    assert %{"filtered_count" => 2} = backend.request_options.routing.canonical_partition
  end

  test "malformed source metadata fails closed instead of using aggregate metadata" do
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

    payload = %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("malformed source metadata")
    }

    assert {:error, %{status: 503, code: "no_eligible_backend"}} =
             PreDispatch.prepare(
               auth,
               @endpoint_path,
               payload,
               request_options(auth, payload, []),
               model
             )

    assert Repo.all(Request) == []
  end

  test "prepare attaches defaulted routing settings to the request-local route state without persisting" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    refute Pools.get_routing_settings(setup.pool)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("prepare this route with default routing settings")
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
      "input" => native_text_input("prepare this route with persisted routing settings")
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
      "input" => native_text_input("prepare fresh route state")
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
    assert length(second_prepared.route_state.candidates) == 1
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

    refute second_assignment.id in Enum.map(
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
        "input" => native_text_input("prepare this route"),
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

  test "prepare remains validation-only for repairable strict function tools" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("prepare this route"),
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "native_no_repair_fixture",
            "strict" => true,
            "parameters" => %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "nested" => %{
                  "additionalProperties" => false,
                  "properties" => %{},
                  "required" => []
                }
              },
              "required" => ["nested"]
            }
          }
        }
      ]
    }

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-no-repair-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.function.parameters.properties.nested.type"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    refute get_in(payload, [
             "tools",
             Elixir.Access.at(0),
             "function",
             "parameters",
             "properties",
             "nested"
           ])
           |> Map.has_key?("type")

    assert Repo.all(Request) == []
  end

  test "prepare allows productive recursive refs only for translated public requests" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    node_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"next" => %{"$ref" => "#/$defs/node"}},
      "required" => ["next"]
    }

    payload =
      strict_text_format_payload(%{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"node" => %{"$ref" => "#/$defs/node"}},
        "required" => ["node"],
        "$defs" => %{"node" => node_schema}
      })

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-recursive-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    translated_options =
      RequestOptions.mark_openai_compatibility_origin(
        request_options,
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    assert {:ok, _prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, translated_options, setup.model)

    assert {:error,
            %{
              code: "invalid_json_schema",
              param: "text.format.schema.properties.node.properties.next.$ref"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert Repo.all(Request) == []
  end

  test "prepare authorizes model policy from request options" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("deny this route")
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

  defp native_text_input(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    ]
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
    source = Map.get(source_models, assignment_id, %{"slug" => model.exposed_model_id})

    model
    |> Ecto.Changeset.change(%{
      metadata:
        Map.put(
          model.metadata,
          "source_assignment_models",
          Map.put(source_models, assignment_id, Map.put(source, "use_responses_lite", enabled?))
        )
    })
    |> Repo.update!()
  end

  defp put_assignment_lite_flags!(model, flags) do
    template =
      model.metadata
      |> Map.get("source_assignment_models", %{})
      |> Map.values()
      |> List.first()
      |> Kernel.||(%{"slug" => model.exposed_model_id})

    source_models =
      Map.new(flags, fn {assignment_id, enabled?} ->
        {assignment_id, Map.put(template, "use_responses_lite", enabled?)}
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

  defp add_divergent_assignment!(setup) do
    divergent =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Divergent canonical partition upstream"
      })

    divergent_assignment =
      divergent.assignment
      |> Ecto.Changeset.change(created_at: DateTime.add(setup.assignment.created_at, 1, :second))
      |> Repo.update!()

    divergent = %{divergent | assignment: divergent_assignment}

    source = get_in(setup.model.metadata, ["source_assignment_models", setup.assignment.id])

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          setup.model.metadata
          | "source_assignment_ids" => [setup.assignment.id, divergent.assignment.id],
            "source_assignment_models" => %{
              setup.assignment.id => source,
              # Behavioral divergence: a context window this account cannot
              # serve is exactly what a canonical partition must keep apart.
              # Presentation-only drift no longer splits partitions.
              divergent.assignment.id => Map.put(source, "context_window", 111_111)
            }
        }
      })
      |> Repo.update!()

    {model, divergent}
  end

  # Reproduces the customer pool: eight assignments whose per-assignment source
  # payloads differ, where the oldest assignment sits in the smaller
  # weekly-exhausted cohort and every quota-healthy seat carries the divergent
  # majority payload.
  #
  #   :cosmetic                 - drift on presentation hints only
  #   :behavioral               - drift on the context window
  #   :behavioral_all_exhausted - behavioral drift, no routable seat anywhere
  defp starved_anchor_partition_pool!(divergence)
       when divergence in [:cosmetic, :behavioral, :behavioral_all_exhausted] do
    exhausted_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_anchor_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    healthy_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_healthy_partition",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(exhausted_upstream, quota?: false)
    anchor_created_at = setup.assignment.created_at

    exhausted_sibling =
      setup.pool
      |> gateway_upstream(exhausted_upstream, "upstream-token-anchor-sibling", compact?: false)
      |> shift_assignment_created_at!(anchor_created_at, 1)

    healthy =
      Enum.map(1..6, fn index ->
        setup.pool
        |> gateway_upstream(healthy_upstream, "upstream-token-healthy-#{index}", compact?: false)
        |> shift_assignment_created_at!(anchor_created_at, index + 1)
      end)

    prime_weekly_exhausted_quota!(setup.identity)
    prime_weekly_exhausted_quota!(exhausted_sibling.identity)

    case divergence do
      :behavioral_all_exhausted ->
        Enum.each(healthy, &prime_weekly_exhausted_quota!(&1.identity))

      _routable_alternate ->
        Enum.each(healthy, &prime_routing_quota!(&1.identity))
    end

    exhausted_assignments = [setup.assignment, exhausted_sibling.assignment]
    healthy_assignments = Enum.map(healthy, & &1.assignment)

    model =
      setup.model
      |> put_model_source_assignments!(exhausted_assignments ++ healthy_assignments)
      |> put_divergent_partition_sources!(healthy_assignments, divergence)

    %{
      setup: %{setup | model: model},
      model: model,
      exhausted_upstream: exhausted_upstream,
      healthy_upstream: healthy_upstream,
      exhausted_assignment_ids: Enum.map(exhausted_assignments, & &1.id),
      healthy_assignment_ids: Enum.map(healthy_assignments, & &1.id),
      exhausted_identity_ids: [setup.identity.id, exhausted_sibling.identity.id],
      healthy_identity_ids: Enum.map(healthy, & &1.identity.id)
    }
  end

  defp shift_assignment_created_at!(upstream, anchor_created_at, seconds) do
    assignment =
      upstream.assignment
      |> Ecto.Changeset.change(created_at: DateTime.add(anchor_created_at, seconds, :second))
      |> Repo.update!()

    %{upstream | assignment: assignment}
  end

  defp put_divergent_partition_sources!(model, assignments, divergence) do
    source_models = Map.fetch!(model.metadata, "source_assignment_models")
    drift = partition_source_drift(divergence)

    divergent =
      Enum.reduce(assignments, source_models, fn assignment, acc ->
        source = Map.fetch!(acc, assignment.id)
        Map.put(acc, assignment.id, Map.merge(source, drift))
      end)

    model
    |> Ecto.Changeset.change(%{
      metadata: Map.put(model.metadata, "source_assignment_models", divergent)
    })
    |> Repo.update!()
  end

  # The presentation hints below are exactly what an upstream varies between
  # accounts on the same plan; the context window is a real capability.
  defp partition_source_drift(:cosmetic) do
    %{
      "default_reasoning_level" => "low",
      "default_service_tier" => "flex",
      "description" => "per-account copy",
      "visibility" => "internal"
    }
  end

  defp partition_source_drift(behavioral)
       when behavioral in [:behavioral, :behavioral_all_exhausted],
       do: %{"context_window" => 111_111}

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp candidate_identity_ids(candidates),
    do: Enum.map(candidates, fn {_assignment, identity} -> identity.id end)

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
