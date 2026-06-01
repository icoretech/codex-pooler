defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1, strict_text_format_payload: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools
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
    assert route_state.extensions == %{}

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

  defp request_options(auth, payload, attrs) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    {routing_attrs, opts} =
      Keyword.split(attrs, [:requested_model, :effective_model])

    opts
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(Keyword.put(routing_attrs, :api_key_policy, policy))
  end
end
