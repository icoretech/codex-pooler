defmodule CodexPooler.Gateway.Facade.DispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Dispatch
  alias CodexPooler.Gateway.OpenAICompatibility.Images
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

  test "permits helper models only with the exact server-owned media context" do
    upstream = start_upstream(FakeUpstream.json_response(%{"created" => 1, "data" => []}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    endpoint = "/backend-api/codex/images/generations"
    client_selector = "client-image-helper-must-disappear"
    payload = %{"model" => client_selector, "prompt" => "generate a fixture"}

    trusted =
      RequestOptions.build(
        %{
          persona: Persona.fixed(:media),
          native_image_request?: true,
          forced_image_model: Images.canonical_model()
        },
        endpoint,
        payload
      )

    assert {:ok, canonical, trusted_options} = Dispatch.prepare(auth, endpoint, payload, trusted)
    assert canonical["model"] == Images.canonical_model()
    refute Map.has_key?(canonical, "reasoning")
    refute Jason.encode!(canonical) =~ client_selector
    assert trusted_options.routing.requested_model == Facade.public_model()
    assert trusted_options.routing.effective_model == Images.canonical_model()

    assert :ok = Dispatch.verify(canonical, trusted_options, fixture.model)

    for untrusted_opts <- [
          %{persona: Persona.fixed(:media)},
          %{
            persona: Persona.fixed(:media),
            native_image_request?: true,
            forced_image_model: "client-selected-helper"
          }
        ] do
      options = RequestOptions.build(untrusted_opts, endpoint, payload)

      assert {:error, %{code: "facade_invariant_failed"}, _canonical, _options} =
               Dispatch.prepare(auth, endpoint, payload, options)
    end
  end

  test "normalizes nested image selectors on reasoning work and fixes them on typed image work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    payload = %{
      "input" => "generate an image",
      "tools" => [
        %{
          "type" => "image_generation",
          "model" => "client-selected-nested-helper",
          "size" => "auto",
          "quality" => "auto"
        }
      ]
    }

    reasoning = facade_options(payload)

    assert {:ok, canonical, reasoning_options} =
             Dispatch.prepare(auth, @endpoint, payload, reasoning)

    assert [%{"type" => "image_generation"} = tool] = canonical["tools"]
    refute Map.has_key?(tool, "model")
    assert :ok = Dispatch.verify(canonical, reasoning_options, fixture.model)

    image_options =
      RequestOptions.build(
        %{
          persona: Persona.fixed(:media),
          forced_image_model: Images.canonical_model(),
          collect_openai_image_stream: true
        },
        @endpoint,
        payload
      )

    assert {:ok, canonical, image_options} =
             Dispatch.prepare(auth, @endpoint, payload, image_options)

    assert [%{"model" => helper}] = canonical["tools"]
    assert helper == Images.canonical_model()
    assert :ok = Dispatch.verify(canonical, image_options, fixture.model)
  end

  test "authenticated execution scopes prompt-cache keys before routing and upstream dispatch" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_cache_scope"}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    second_key = active_api_key_fixture(fixture.pool)
    {:ok, second_auth} = Access.authenticate_authorization_header(second_key.authorization)
    raw_cache_key = "raw-service-cache-key-must-not-survive"
    client_model = "client-cache-model-must-not-survive"

    payload = %{
      "model" => client_model,
      "input" => "cache fixture",
      "prompt_cache_key" => raw_cache_key
    }

    for current_auth <- [auth, auth, second_auth] do
      assert {:ok, %{status: 200}} =
               Gateway.execute(current_auth, @endpoint, payload, facade_options(payload))
    end

    assert [first, repeat, other_key] = FakeUpstream.requests(upstream)
    assert first.json["prompt_cache_key"] == repeat.json["prompt_cache_key"]
    refute first.json["prompt_cache_key"] == other_key.json["prompt_cache_key"]
    assert first.json["prompt_cache_key"] =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/

    for captured <- [first, repeat, other_key] do
      refute captured.body =~ raw_cache_key
      refute captured.body =~ client_model
      assert captured.json["model"] == Facade.effective_model()
    end

    persisted = inspect(Repo.all(Request))
    refute persisted =~ raw_cache_key
    refute persisted =~ client_model
  end

  test "native image execution uses one hidden helper for missing and arbitrary selectors" do
    upstream = start_upstream(FakeUpstream.json_response(%{"created" => 1, "data" => []}))
    fixture = facade_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    endpoint = "/backend-api/codex/images/generations"
    client_model = "client-native-image-model-must-disappear"

    for selector <- [:missing, client_model] do
      payload = %{"prompt" => "native image fixture"}
      payload = if selector == :missing, do: payload, else: Map.put(payload, "model", selector)

      options =
        RequestOptions.build(
          %{
            persona: Persona.fixed(:media),
            native_image_request?: true,
            forced_image_model: Images.canonical_model()
          },
          endpoint,
          payload
        )

      assert {:ok, %{status: 200}} =
               Gateway.execute(auth, endpoint, payload, options)
    end

    assert [first, second] = FakeUpstream.requests(upstream)

    for captured <- [first, second] do
      assert captured.path == endpoint
      assert captured.json["model"] == Images.canonical_model()
      refute Map.has_key?(captured.json, "reasoning")
      refute captured.body =~ client_model
    end

    assert Enum.all?(Repo.all(Request), &(&1.requested_model == Facade.public_model()))

    assert Enum.all?(
             Repo.all(Request),
             &(&1.request_metadata["effective_model"] == Images.canonical_model())
           )
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
