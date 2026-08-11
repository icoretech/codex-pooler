defmodule CodexPooler.Gateway.Runtime.FacadePreDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  test "accepts only a complete fixed facade invariant and preserves its reasoning decision" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    payload = canonical_payload()
    options = canonical_options(auth, payload)

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint, payload, options, fixture.model)

    assert prepared.request_options.persona == Persona.fixed(:codex)
    assert prepared.request_options.routing.requested_model == "gemma3"
    assert prepared.request_options.routing.effective_model == "gpt-5.6-sol"
    assert prepared.request_options.routing.reasoning_effort_decision == fixed_decision()
    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(Request) == []
    assert Repo.all(Attempt) == []
  end

  test "rejects every facade invariant mismatch before candidate or accounting work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_run"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    payload = canonical_payload()
    options = canonical_options(auth, payload)

    mismatches = [
      {payload,
       %{
         options
         | persona: %{options.persona | effective_model: "gpt-5.5"}
       }, fixture.model},
      {payload, RequestOptions.put_routing(options, requested_model: "other"), fixture.model},
      {payload, RequestOptions.put_routing(options, effective_model: "gpt-5.5"), fixture.model},
      {%{payload | "model" => "gpt-5.5"}, options, fixture.model},
      {%{payload | "reasoning" => %{"effort" => "high"}}, options, fixture.model},
      {payload,
       RequestOptions.put_routing(options,
         reasoning_effort_decision: %{fixed_decision() | applied_effort: "high"}
       ), fixture.model},
      {payload, options, %{fixture.model | exposed_model_id: "gpt-5.5"}}
    ]

    for {mismatched_payload, mismatched_options, mismatched_model} <- mismatches do
      assert {:error,
              %{
                status: 500,
                code: "facade_invariant_failed",
                message: "facade routing invariant failed"
              }} =
               PreDispatch.prepare(
                 auth,
                 @endpoint,
                 mismatched_payload,
                 mismatched_options,
                 mismatched_model
               )
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(Request) == []
    assert Repo.all(Attempt) == []
  end

  defp facade_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: Facade.effective_model(),
      upstream_model_id: Facade.effective_model(),
      display_name: "Facade pre-dispatch target",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max"
      }
    )
  end

  defp canonical_payload do
    %{
      "model" => Facade.effective_model(),
      "reasoning" => %{"effort" => Facade.reasoning_effort()},
      "input" => "facade invariant"
    }
  end

  defp canonical_options(auth, payload) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    RequestOptions.build(%{persona: Persona.fixed(:codex)}, @endpoint, payload)
    |> RequestOptions.put_routing(
      api_key_policy: policy,
      requested_model: Facade.public_model(),
      effective_model: Facade.effective_model(),
      reasoning_effort_decision: fixed_decision()
    )
  end

  defp fixed_decision do
    %Decision{
      mode: :always_use,
      configured_effort: Facade.reasoning_effort(),
      requested_effort: nil,
      applied_effort: Facade.reasoning_effort()
    }
  end
end
