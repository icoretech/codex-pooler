defmodule CodexPooler.Gateway.Routing.CandidateEligibilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures,
    only: [
      active_api_key_fixture: 1,
      model_fixture: 2,
      pool_fixture: 0,
      upstream_assignment_fixture: 2
    ]

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.{RoutePlanInput, RoutingSelection}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  describe "hydrated model visibility" do
    test "uses one hydrated assignment snapshot for visible models and routable candidates" do
      pool = pool_fixture()
      routed = upstream_assignment_fixture(pool, %{plan_family: "pro"})

      model =
        model_fixture(pool, %{
          exposed_model_id: unique_model_id("gpt-hydrated-visible"),
          metadata: %{"source_assignment_ids" => [routed.assignment.id]}
        })

      {{context, candidates}, commands} =
        count_repo_commands(fn ->
          context = CandidateEligibility.visible_model_context(pool, model.exposed_model_id)
          {:ok, candidates} = CandidateEligibility.routable_candidates(context, model)
          {context, candidates}
        end)

      assert context.visible_model.id == model.id
      assert Enum.map(context.visible_models, & &1.id) == [model.id]
      assert candidate_ids(candidates) == [routed.assignment.id]
      assert command_count(commands, "models", "SELECT") == 1
      assert command_count(commands, "pool_upstream_assignments", "SELECT") == 1

      {_candidates, reuse_commands} =
        count_repo_commands(fn ->
          assert {:ok, candidates} = CandidateEligibility.routable_candidates(context, model)
          candidates
        end)

      assert command_count(reuse_commands, "models", "SELECT") == 0
      assert command_count(reuse_commands, "pool_upstream_assignments", "SELECT") == 0
    end

    test "keeps hidden models hidden and routes only model-routable identity statuses" do
      pool = pool_fixture()
      active = upstream_assignment_fixture(pool, %{})
      disabled = upstream_assignment_fixture(pool, %{assignment_status: "disabled"})
      refreshing_identity = upstream_assignment_fixture(pool, %{identity_status: "refreshing"})

      blocked_by_identity =
        UpstreamIdentity.statuses()
        |> Kernel.--(["active", "refreshing"])
        |> Map.new(fn status ->
          {status, upstream_assignment_fixture(pool, %{identity_status: status})}
        end)

      visible_model =
        model_fixture(pool, %{
          exposed_model_id: unique_model_id("gpt-visible"),
          metadata: %{
            "source_assignment_ids" =>
              [
                active.assignment.id,
                disabled.assignment.id,
                refreshing_identity.assignment.id
              ] ++ Enum.map(blocked_by_identity, fn {_status, routed} -> routed.assignment.id end)
          }
        })

      hidden_model =
        model_fixture(pool, %{
          exposed_model_id: unique_model_id("gpt-hidden"),
          status: "suppressed",
          metadata: %{"source_assignment_ids" => [active.assignment.id]}
        })

      context = CandidateEligibility.visible_model_context(pool, visible_model.exposed_model_id)

      assert Enum.map(context.visible_models, & &1.id) == [visible_model.id]
      refute Enum.any?(context.visible_models, &(&1.id == hidden_model.id))

      assert {:ok, candidates} = CandidateEligibility.routable_candidates(context, visible_model)

      assert candidate_ids(candidates) == [
               active.assignment.id,
               refreshing_identity.assignment.id
             ]

      refute disabled.assignment.id in candidate_ids(candidates)

      for {status, routed} <- blocked_by_identity do
        refute routed.assignment.id in candidate_ids(candidates),
               "#{status} identities must stay excluded from model routing"
      end

      assert CandidateEligibility.visible_model_context(pool, hidden_model.exposed_model_id) ==
               nil
    end

    test "keeps degraded assignments visible but not routable" do
      pool = pool_fixture()
      degraded = upstream_assignment_fixture(pool, %{health_status: "degraded"})

      model =
        model_fixture(pool, %{
          exposed_model_id: unique_model_id("gpt-degraded-visible"),
          metadata: %{"source_assignment_ids" => [degraded.assignment.id]}
        })

      assert %{visible_model: %{id: model_id}} =
               context = CandidateEligibility.visible_model_context(pool, model.exposed_model_id)

      assert model_id == model.id

      assert {:error, %{code: "no_eligible_backend"}} =
               CandidateEligibility.routable_candidates(context, model)
    end
  end

  describe "filter_runtime_compatible_candidates/1" do
    test "auto and default do not narrow the candidate set" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported", "assignment-plain"]

      auto_payload = Map.put(payload, "service_tier", "auto")

      auto_request_options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", auto_payload)

      assert {:ok, auto_filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, auto_payload, auto_request_options, candidates)
               )

      assert candidate_ids(auto_filtered) == ["assignment-supported", "assignment-plain"]
    end

    test "a concrete supported tier narrows to candidates that explicitly advertise it" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "priority"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported"]
    end

    test "a concrete unsupported tier produces no compatible backend" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "latency_preview"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:error, %{code: "no_compatible_backend"}} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )
    end

    test "a concrete tier excludes source assignments missing per-assignment metadata" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "latency_preview"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:error, %{code: "no_compatible_backend"}} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )
    end

    test "SDK-internal serviceTier alias does not narrow candidate eligibility" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "serviceTier" => "latency_preview"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-missing"]
    end

    test "missing per-assignment metadata remains compatible without a concrete tier" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]
      payload = %{"model" => "gpt-4.1", "input" => "hello"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-missing"]
    end

    test "auto and default keep source assignments compatible without per-assignment metadata" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]

      for tier <- ["auto", "default"] do
        payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => tier}
        request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

        assert {:ok, filtered} =
                 CandidateEligibility.filter_runtime_compatible_candidates(
                   filter_input(model, payload, request_options, candidates)
                 )

        assert candidate_ids(filtered) == ["assignment-missing"]
      end
    end

    test "an api-key enforced tier overrides the client payload tier" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"}

      request_options =
        RequestOptions.build(
          %{api_key_policy: %{enforced_service_tier: "priority"}},
          "/backend-api/codex/responses",
          payload
        )

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported"]
    end

    test "an api-key enforced default tier overrides a concrete client payload tier" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "priority"}

      request_options =
        RequestOptions.build(
          %{api_key_policy: %{enforced_service_tier: "default"}},
          "/backend-api/codex/responses",
          payload
        )

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported", "assignment-plain"]
    end
  end

  describe "preloaded routing state" do
    test "quota eligibility consumes route-state windows without querying the repository" do
      eligible_identity = upstream_identity("eligible-identity")
      missing_identity = upstream_identity("missing-identity")

      eligible_candidate =
        {assignment("eligible-assignment", eligible_identity), eligible_identity}

      missing_candidate = {assignment("missing-assignment", missing_identity), missing_identity}

      route_state =
        RouteState.new(%{
          visible_model: quota_model(),
          candidates: [eligible_candidate, missing_candidate]
        })
        |> RouteState.put_quota_window_snapshots(%{
          eligible_identity.id => [account_window(Decimal.new("15"))],
          missing_identity.id => [account_window(Decimal.new("100"))]
        })

      assert {:ok, [^eligible_candidate], %{"routing_state" => "precise"}} =
               CandidateEligibility.filter_quota_eligible_candidates(
                 filter_input(quota_model(), %{"model" => "sample-model"}, request_options(), [
                   eligible_candidate,
                   missing_candidate
                 ]),
                 route_state
               )
    end

    test "quota classification orders precise credit-backed and weekly probe candidates" do
      precise_identity = upstream_identity("precise-identity")
      credit_identity = upstream_identity("credit-identity")
      weekly_identity = upstream_identity("weekly-identity")

      precise_candidate = {assignment("precise-assignment", precise_identity), precise_identity}
      credit_candidate = {assignment("credit-assignment", credit_identity), credit_identity}
      weekly_candidate = {assignment("weekly-assignment", weekly_identity), weekly_identity}

      route_state =
        RouteState.new(%{
          visible_model: quota_model(),
          candidates: [weekly_candidate, credit_candidate, precise_candidate]
        })
        |> RouteState.put_quota_window_snapshots(%{
          precise_identity.id => [account_window(Decimal.new("15"))],
          credit_identity.id => [credit_backed_secondary_window()],
          weekly_identity.id => [weekly_probe_window()]
        })

      assert {:ok, candidates, decision} =
               CandidateEligibility.filter_quota_eligible_candidates(
                 filter_input(quota_model(), %{"model" => "sample-model"}, request_options(), [
                   weekly_candidate,
                   credit_candidate,
                   precise_candidate
                 ]),
                 route_state
               )

      assert candidate_ids(candidates) == [
               "precise-assignment",
               "credit-assignment",
               "weekly-assignment"
             ]

      assert decision["routing_state"] == "precise"
      assert decision["precise_candidate_count"] == 1
      assert decision["credit_backed_probe_candidate_count"] == 1
      assert decision["weekly_probe_candidate_count"] == 1
      assert decision["eligible_candidate_count"] == 3

      assert decision["summary"] ==
               "allowed by fresh, credit-backed secondary, and weekly quota evidence"
    end

    test "selected route skips an open snapshot and admits a later eligible candidate" do
      pool = pool_fixture()
      %{api_key: api_key} = active_api_key_fixture(pool)
      first = upstream_assignment_fixture(pool, %{})
      second = upstream_assignment_fixture(pool, %{})

      model =
        model_fixture(pool, %{
          exposed_model_id: unique_model_id("gpt-circuit-selection"),
          metadata: %{
            "source_assignment_ids" => [first.assignment.id, second.assignment.id]
          }
        })

      request_options = request_options()
      candidates = [{first.assignment, first.identity}, {second.assignment, second.identity}]

      route_state =
        RouteState.new(%{
          visible_model: model,
          candidates: candidates,
          circuit_snapshots: %{
            first.assignment.id => false,
            second.assignment.id => true
          }
        })

      assert {:ok, %RoutingSelection{} = selection} =
               RoutingSelection.select_and_begin_circuit(%{
                 auth: %{pool: pool, api_key: api_key},
                 model: model,
                 candidates: candidates,
                 route_plan_input: RoutePlanInput.from_request_opts(request_options),
                 endpoint: "/backend-api/codex/responses",
                 payload: %{"model" => model.exposed_model_id},
                 request_options: request_options,
                 route_state: route_state
               })

      assert selection.assignment.id == second.assignment.id
    end

    test "circuit eligibility consumes route-state snapshots without live circuit reads" do
      open_identity = upstream_identity("open-identity")
      closed_identity = upstream_identity("closed-identity")

      open_candidate = {assignment("open-assignment", open_identity), open_identity}
      closed_candidate = {assignment("closed-assignment", closed_identity), closed_identity}

      route_state =
        RouteState.new(%{
          visible_model: quota_model(),
          candidates: [open_candidate, closed_candidate],
          circuit_eligibility_snapshots: %{
            "open-assignment" => false,
            "closed-assignment" => true
          }
        })

      assert {:ok, [^closed_candidate]} =
               CandidateEligibility.filter_circuit_eligible_candidates(
                 filter_input(quota_model(), %{"model" => "sample-model"}, request_options(), [
                   open_candidate,
                   closed_candidate
                 ]),
                 route_state
               )
    end
  end

  defp unique_model_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "candidate-eligibility-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], command_name(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_commands(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_commands(handler_id, commands) do
    receive do
      {^handler_id, source, command} ->
        key = {source, command}
        drain_repo_commands(handler_id, Map.update(commands, key, 1, &(&1 + 1)))
    after
      0 -> commands
    end
  end

  defp command_count(commands, source, command), do: Map.get(commands, {source, command}, 0)

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil

  defp candidate(assignment_id) do
    {%{id: assignment_id, metadata: %{}}, %{id: "#{assignment_id}-identity", metadata: %{}}}
  end

  defp assignment(id, %UpstreamIdentity{} = identity) do
    %PoolUpstreamAssignment{id: id, upstream_identity_id: identity.id, metadata: %{}}
  end

  defp upstream_identity(id) do
    %UpstreamIdentity{id: id, metadata: %{}}
  end

  defp request_options do
    RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "sample-model"})
  end

  defp quota_model do
    %Model{exposed_model_id: "sample-model", upstream_model_id: "sample-upstream-model"}
  end

  defp account_window(used_percent) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    %AccountQuotaWindow{
      quota_key: "account",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: used_percent,
      reset_at: DateTime.add(observed_at, 900, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: observed_at
    }
  end

  defp credit_backed_secondary_window do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    %AccountQuotaWindow{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("100"),
      credits: 25,
      reset_at: DateTime.add(observed_at, 604_800, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: observed_at
    }
  end

  defp weekly_probe_window do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    %AccountQuotaWindow{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("12"),
      reset_at: DateTime.add(observed_at, 604_800, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: observed_at
    }
  end

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp filter_input(model, payload, request_options, candidates) do
    FilterInput.new(%{
      model: model,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options,
      candidates: candidates
    })
  end

  defp model_with_tier_support(supported_assignment_id, supported_tier) do
    %Model{
      metadata: %{
        "source_assignment_models" => %{
          supported_assignment_id => %{
            "capabilities" => %{"responses" => true},
            "service_tiers" => [
              %{"id" => supported_tier, "name" => supported_tier, "description" => supported_tier}
            ],
            "additional_speed_tiers" => []
          },
          "assignment-plain" => %{
            "capabilities" => %{"responses" => true},
            "service_tiers" => [],
            "additional_speed_tiers" => []
          }
        }
      }
    }
  end

  defp model_missing_assignment_metadata(assignment_id) do
    %Model{
      metadata: %{
        "source_assignment_ids" => [assignment_id],
        "source_assignment_models" => %{}
      }
    }
  end
end
