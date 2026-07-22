defmodule CodexPooler.Gateway.Runtime.DispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @endpoint_path "/backend-api/codex/responses"

  test "context construction returns sanitized gateway error when route plan metadata cannot be recorded" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    candidates = [{setup.assignment, setup.identity}]

    context_input = %{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload,
      model: setup.model,
      reserved: %{request: invalid_request()},
      candidates: candidates,
      request_options: request_options,
      route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates})
    }

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} = Context.new(context_input)
      end)

    assert log =~ "gateway accounting finalization failed"
    assert log =~ "operation=merge_route_plan_metadata"
    assert log =~ "request_id=#{context_input.reserved.request.id}"
  end

  test "dispatch_from returns sanitized gateway error when selected route metadata cannot be recorded" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)
    request = invalid_request()
    candidates = [{setup.assignment, setup.identity}]
    parent = self()

    context = %Context{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload,
      model: setup.model,
      reserved: %{request: request},
      candidates: candidates,
      request_options: request_options,
      route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates}),
      route_plan:
        BridgeRing.plan_route(%{
          auth: auth,
          model: setup.model,
          candidates: candidates,
          route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
          request_options: request_options
        }),
      route_class: request_options.transport.route_class
    }

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 Dispatch.dispatch_from(context, 0, fn _context ->
                   send(parent, :transport_called)
                 end)
      end)

    assert log =~ "gateway accounting finalization failed"
    assert log =~ "operation=merge_route_selection_metadata"
    assert log =~ "request_id=#{request.id}"
    refute_received :transport_called
  end

  test "candidate selection preserves a resolved Lite snapshot across a Full legacy assignment" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    %{assignment: fallback_assignment, identity: fallback_identity} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Resolved snapshot fallback upstream"
      })

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id, fallback_assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => %{"use_responses_lite" => false},
            fallback_assignment.id => %{"use_responses_lite" => false}
          }
        }
      })
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(%{setup | model: model})
    unresolved_options = request_options(auth, payload, %{setup | model: model})

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: model.exposed_model_id,
      mode: "lite",
      created_at: timestamp,
      updated_at: timestamp
    })

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, unresolved_options, model)

    request_options = prepared.request_options

    assert {:ok, reserved} =
             Accounting.reserve(auth, model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_json",
               correlation_id: "resolved-selection-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    candidates = [
      {setup.assignment, setup.identity},
      {fallback_assignment, fallback_identity}
    ]

    assert {:ok, context} =
             Context.new(%{
               auth: auth,
               endpoint: @endpoint_path,
               payload: payload,
               model: model,
               reserved: reserved,
               candidates: candidates,
               request_options: request_options,
               route_state: RouteState.new(%{visible_model: model, candidates: candidates})
             })

    assert {:ok, %{status: 200}} =
             Dispatch.dispatch_from(context, 1, fn selected_context ->
               assert selected_context.assignment.id in [
                        setup.assignment.id,
                        fallback_assignment.id
                      ]

               assert RequestOptions.model_serving_mode_snapshot(selected_context.request_options) ==
                        %{
                          configured_mode: "lite",
                          effective_mode: "lite",
                          source: "override"
                        }

               assert RequestOptions.use_responses_lite?(selected_context.request_options)
               {:ok, %{status: 200}}
             end)
  end

  test "candidate selection exposes the unresolved selected-assignment Lite fallback" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => %{"use_responses_lite" => true}
          }
        }
      })
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(%{setup | model: model})
    request_options = request_options(auth, payload, %{setup | model: model})

    assert RequestOptions.model_serving_mode_snapshot(request_options) == nil

    assert {:ok, reserved} =
             Accounting.reserve(auth, model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_json",
               correlation_id: "unresolved-selection-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    candidates = [{setup.assignment, setup.identity}]

    assert {:ok, context} =
             Context.new(%{
               auth: auth,
               endpoint: @endpoint_path,
               payload: payload,
               model: model,
               reserved: reserved,
               candidates: candidates,
               request_options: request_options,
               route_state: RouteState.new(%{visible_model: model, candidates: candidates})
             })

    assert {:ok, %{status: 200}} =
             Dispatch.dispatch_from(context, 0, fn selected_context ->
               assert RequestOptions.model_serving_mode_snapshot(selected_context.request_options) ==
                        nil

               assert RequestOptions.use_responses_lite?(selected_context.request_options)
               {:ok, %{status: 200}}
             end)
  end

  test "bound reset probe scope mismatch finalizes before attempt or transport dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    initial_probe = ResetProbe.new()

    assert {:ok, reset_probe} =
             ResetProbe.bind(
               initial_probe,
               Ecto.UUID.generate(),
               setup.identity.id,
               setup.model.exposed_model_id,
               "proxy_http"
             )

    request_options =
      auth
      |> request_options(payload, setup)
      |> RequestOptions.put_routing(reset_probe: reset_probe)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_json",
               correlation_id: "reset-probe-scope-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    candidates = [{setup.assignment, setup.identity}]

    assert {:ok, context} =
             Context.new(%{
               auth: auth,
               endpoint: @endpoint_path,
               payload: payload,
               model: setup.model,
               reserved: reserved,
               candidates: candidates,
               request_options: request_options,
               route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates})
             })

    parent = self()

    assert {:error, %{status: 503, code: "no_eligible_backend"}} =
             Dispatch.dispatch(context, fn _selected_context ->
               send(parent, :transport_called)
               {:ok, %{status: 200}}
             end)

    refute_received :transport_called
    assert FakeUpstream.count(upstream) == 0

    assert %Request{status: "failed", last_error_code: "no_eligible_backend"} =
             Repo.reload!(reserved.request)

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^reserved.request.id), :count) ==
             0
  end

  test "bound reset probe scope mutations fail before accounting reservation" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    sibling_upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    %{assignment: sibling_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Reset probe pre-reservation sibling",
        base_url: FakeUpstream.url(sibling_upstream)
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    generation = 1
    attempt_id = "pre-reservation-attempt"

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: %{
          "saved_reset_redemption" => %{
            "status" => "redeeming",
            "phase" => "consumed_pending_probe",
            "attempt_id" => attempt_id,
            "generation" => generation,
            "consumed_at" => DateTime.to_iso8601(now),
            "deadline_at" => DateTime.to_iso8601(DateTime.add(now, 15, :minute)),
            "result" => %{"code" => "reset", "applied" => true}
          }
        }
      })
      |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    base_options = request_options(auth, payload, setup)

    assert {:ok, probe} =
             ResetProbe.new()
             |> ResetProbe.bind(
               setup.assignment.id,
               identity.id,
               setup.model.exposed_model_id,
               "proxy_http"
             )

    assert {:ok, :claimed} =
             ProbeLease.claim(identity, generation, attempt_id, probe, now)

    persisted_redemption =
      Repo.reload!(identity).metadata["saved_reset_redemption"]

    mutations = [
      assignment: %{probe | pool_upstream_assignment_id: Ecto.UUID.generate()},
      identity: %{probe | upstream_identity_id: Ecto.UUID.generate()},
      effective_model: %{probe | effective_model: "gpt-other-model"},
      route_class: %{probe | route_class: "proxy_stream"}
    ]

    for {dimension, mismatch} <- mutations do
      request_options = %{
        base_options
        | routing: %{base_options.routing | reset_probe: mismatch}
      }

      route_state =
        RouteState.new(%{
          visible_model: setup.model,
          candidates: [{setup.assignment, identity}],
          reset_probe: mismatch
        })

      assert {:error,
              {:reset_probe_scope_mismatch,
               %{status: 503, code: "no_eligible_backend", param: "model"}}} =
               AccountingReservation.validate_reset_probe_scope(
                 [{setup.assignment, identity}],
                 request_options,
                 route_state
               ),
             "expected #{dimension} mismatch to fail closed"

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
      assert Repo.aggregate(from(a in Attempt), :count) == 0
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.count(sibling_upstream) == 0

      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == persisted_redemption
      assert persisted_redemption["probe"]["token"] == probe.token
      assert sibling_assignment.id != probe.pool_upstream_assignment_id
    end
  end

  defp payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "runtime dispatch accounting regression"
    }
  end

  defp request_options(auth, payload, setup) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    %{
      request_id: "dispatch-accounting-#{System.unique_integer([:positive])}",
      upstream_endpoint: @endpoint_path
    }
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(
      requested_model: setup.model.exposed_model_id,
      effective_model: setup.model.exposed_model_id,
      api_key_policy: policy
    )
  end

  defp invalid_request do
    %{
      id: Ecto.UUID.generate(),
      correlation_id: "dispatch-accounting-#{System.unique_integer([:positive])}"
    }
  end
end
