defmodule CodexPooler.Gateway.Facade.DispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Policy
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  test "normalizes every client selector to the fixed upstream target and accounting identity" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_facade"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    payloads = [
      %{"input" => "missing selector"},
      %{"model" => " \n\t ", "input" => "blank selector"},
      %{"model" => "gemma3", "input" => "public selector"},
      %{
        "model" => "client-selected-model",
        "reasoning" => %{"effort" => "low", "model" => "nested-client-model"},
        "reasoning_effort" => "high",
        "thinking" => %{"effort" => "xhigh"},
        "input" => "conflicting selectors"
      },
      %{"model" => %{"name" => "nested-model-object"}, "input" => "object selector"}
    ]

    for payload <- payloads do
      assert {:ok, %{status: 200}} =
               Gateway.execute(auth, @endpoint, payload, facade_options(payload))
    end

    captured = FakeUpstream.requests(upstream)
    assert length(captured) == length(payloads)

    for request <- captured do
      assert request.json["model"] == "gpt-5.6-sol"
      assert request.json["reasoning"]["effort"] == "max"

      serialized = Jason.encode!(request.json)
      refute serialized =~ "client-selected-model"
      refute serialized =~ "nested-client-model"
      refute serialized =~ "nested-model-object"
      refute serialized =~ ~r/"effort":"(?:low|high|xhigh)"/
    end

    requests = Repo.all(Request)
    assert length(requests) == length(payloads)
    assert Enum.all?(requests, &(&1.requested_model == "gemma3"))

    assert Enum.all?(
             requests,
             &(&1.request_metadata["effective_model"] == "gpt-5.6-sol")
           )
  end

  test "policy may agree with the fixed target but cannot redirect it" do
    persona = Persona.fixed(:codex)

    unrestricted = policy()
    assert :ok = Policy.authorize(unrestricted, persona)

    assert :ok =
             Policy.authorize(
               policy(
                 allowed_model_identifiers: [" GPT-5.6-SOL "],
                 enforced_model_identifier: "GPT-5.6-SOL",
                 enforced_reasoning_effort: "MAX"
               ),
               persona
             )

    assert :ok = Policy.authorize(policy(maximum_reasoning_effort: "max"), persona)
    assert :ok = Policy.authorize(policy(maximum_reasoning_effort: "ultra"), persona)

    for conflicting <- [
          policy(allowed_model_identifiers: ["gpt-5.5"]),
          policy(enforced_model_identifier: "gpt-5.5"),
          policy(enforced_reasoning_effort: "high"),
          policy(maximum_reasoning_effort: "xhigh")
        ] do
      assert {:error, _reason} = Policy.authorize(conflicting, persona)
    end
  end

  test "conflicting API-key policy fails locally with zero upstream attempts" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_run"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    payload = %{"model" => "anything", "input" => "deny locally"}

    conflicting_keys = [
      %{auth.api_key | allowed_model_identifiers: ["gpt-5.5"]},
      %{auth.api_key | enforced_model_identifier: "gpt-5.5"},
      %{auth.api_key | enforced_reasoning_effort: "high"},
      %{auth.api_key | maximum_reasoning_effort: "xhigh"}
    ]

    for api_key <- conflicting_keys do
      assert {:error,
              %{
                status: 403,
                code: "facade_policy_conflict",
                message: "API key policy does not permit gemma3"
              }} =
               Gateway.execute(
                 %{auth | api_key: api_key},
                 @endpoint,
                 payload,
                 facade_options(payload)
               )
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(Attempt) == []
  end

  test "agreeing enforced max and an ultra ceiling both dispatch the fixed max target" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_policy_agrees"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    payload = %{"model" => "ignored", "reasoning" => %{"effort" => "low"}, "input" => "ok"}

    agreeing_keys = [
      %{
        auth.api_key
        | enforced_model_identifier: "gpt-5.6-sol",
          enforced_reasoning_effort: "max"
      },
      %{auth.api_key | maximum_reasoning_effort: "ultra"}
    ]

    for api_key <- agreeing_keys do
      assert {:ok, %{status: 200}} =
               Gateway.execute(
                 %{auth | api_key: api_key},
                 @endpoint,
                 payload,
                 facade_options(payload)
               )
    end

    assert [first, second] = FakeUpstream.requests(upstream)

    for captured <- [first, second] do
      assert captured.json["model"] == "gpt-5.6-sol"
      assert captured.json["reasoning"]["effort"] == "max"
    end
  end

  test "does not fall back when the pool has no fixed-target model" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "fallback_must_not_run"}))
    fixture = gateway_setup(upstream, exposed_model_id: "gpt-5.5")
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    payload = %{"model" => "gpt-5.5", "input" => "no fallback"}

    assert {:error,
            %{
              status: 503,
              code: "facade_model_unavailable",
              message: "gemma3 is not currently available",
              param: "model"
            }} = Gateway.execute(auth, @endpoint, payload, facade_options(payload))

    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(Attempt) == []
  end

  test "does not fall back when the fixed-target model has no routable assignment" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "fallback_must_not_run"}))
    fixture = gateway_setup(upstream, exposed_model_id: "gpt-5.5")

    _fixed_target_without_candidates =
      CodexPooler.PoolerFixtures.model_fixture(fixture.pool, %{
        exposed_model_id: Facade.effective_model(),
        upstream_model_id: Facade.effective_model(),
        display_name: "Unavailable facade target",
        source_assignment_count: 0,
        metadata: %{"source_assignment_ids" => [], "source_assignment_models" => %{}}
      })

    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    payload = %{"model" => "gpt-5.5", "input" => "no candidate fallback"}

    assert {:error, %{status: 503, code: "facade_model_unavailable"}} =
             Gateway.execute(auth, @endpoint, payload, facade_options(payload))

    assert FakeUpstream.count(upstream) == 0
    assert Repo.all(Attempt) == []
  end

  defp facade_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: Facade.effective_model(),
      upstream_model_id: Facade.effective_model(),
      display_name: "Facade fixed target",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max"
      }
    )
  end

  defp facade_options(payload) do
    RequestOptions.build(
      %{persona: Persona.fixed(:codex)},
      @endpoint,
      payload
    )
  end

  defp policy(overrides \\ []) do
    Map.merge(
      %{
        allowed_model_identifiers: nil,
        enforced_model_identifier: nil,
        enforced_reasoning_effort: nil,
        maximum_reasoning_effort: nil
      },
      Map.new(overrides)
    )
  end
end
