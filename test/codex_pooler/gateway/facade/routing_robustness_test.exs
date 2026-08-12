defmodule CodexPooler.Gateway.Facade.RoutingRobustnessTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.FacadeAssertions
  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      deterministic_rotation_seed: 2,
      gateway_setup: 2,
      gateway_upstream: 4,
      prime_exhausted_routing_quota!: 1,
      prime_routing_quota!: 1,
      prime_weekly_exhausted_quota!: 1,
      put_model_source_assignments!: 2,
      response_affinity_file_fixture: 4,
      saved_reset_metadata: 2,
      saved_reset_usage_payload: 1,
      start_upstream: 1,
      use_deterministic_rotation!: 2,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, CodexSession}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "pre-visible retry rotates accounts while preserving the one effective model", %{
    conn: conn
  } do
    first_mode =
      FakeUpstream.sse_stream(
        [
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"status" => "in_progress"}
           }},
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "status" => "failed",
               "error" => %{
                 "code" => "server_error",
                 "message" => "facade-provider-private-sentinel"
               }
             }
           }}
        ],
        done: false
      )

    setup = two_upstream_setup(first_mode, success_stream("fallback answer"))

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/api/chat", %{
        "messages" => [%{"role" => "user", "content" => "retry across accounts"}]
      })

    assert response.status == 200
    assert_cloaked_ndjson(response.resp_body)
    assert FakeUpstream.count(setup.first_upstream) == 1
    assert FakeUpstream.count(setup.second_upstream) == 1

    assert Enum.map(Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number])), fn attempt ->
             {attempt.status, attempt.upstream_model_id}
           end) == [
             {"retryable_failed", "gpt-5.6-sol"},
             {"succeeded", "gpt-5.6-sol"}
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.requested_model == "gemma3"
    assert request.retry_count == 1
    assert_cloaked_headers(response)
  end

  test "quota exhaustion and live health changes only alter account eligibility", %{conn: conn} do
    quota_setup = two_upstream_setup(success_stream("first"), success_stream("second"))
    prime_exhausted_routing_quota!(quota_setup.identity)

    quota_response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(quota_setup)
      |> post("/v1/responses", %{"input" => "quota-filtered"})

    assert quota_response.status == 200
    assert FakeUpstream.count(quota_setup.first_upstream) == 0
    assert FakeUpstream.count(quota_setup.second_upstream) == 1

    health_setup =
      two_upstream_setup(success_stream("health first"), success_stream("health second"))

    health_setup.assignment
    |> Ecto.Changeset.change(
      health_status: "degraded",
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    )
    |> Repo.update!()

    health_response =
      conn
      |> recycle()
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(health_setup)
      |> post("/v1/responses", %{"input" => "health-filtered"})

    assert health_response.status == 200
    assert FakeUpstream.count(health_setup.first_upstream) == 0
    assert FakeUpstream.count(health_setup.second_upstream) == 1

    health_setup.assignment
    |> Repo.reload!()
    |> Ecto.Changeset.change(
      health_status: "active",
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    )
    |> Repo.update!()

    health_setup.fallback_assignment
    |> Ecto.Changeset.change(
      health_status: "degraded",
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    )
    |> Repo.update!()

    recovered_response =
      conn
      |> recycle()
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 1))
      |> auth(health_setup)
      |> post("/v1/responses", %{"input" => "health-recovered"})

    assert recovered_response.status == 200
    assert FakeUpstream.count(health_setup.first_upstream) == 1
    assert FakeUpstream.count(health_setup.second_upstream) == 1

    for setup <- [quota_setup, health_setup] do
      assert Enum.all?(FakeUpstream.requests(setup.first_upstream), &fixed_target_capture?/1)
      assert Enum.all?(FakeUpstream.requests(setup.second_upstream), &fixed_target_capture?/1)
    end

    assert Enum.all?(Repo.all(Request), fn row ->
             row.requested_model == "gemma3" and row.reasoning_effort == "max"
           end)

    assert Enum.all?(Repo.all(from(a in Attempt)), &(&1.upstream_model_id == "gpt-5.6-sol"))
  end

  test "an all-account routing denial keeps public accounting on gemma3", %{conn: conn} do
    upstream = start_upstream(success_stream("must not dispatch"))
    setup = facade_gateway_setup(upstream)
    prime_exhausted_routing_quota!(setup.identity)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{"input" => "all quota exhausted"})

    assert response.status == 503
    assert_cloaked_json(json_response(response, 503))
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.requested_model == "gemma3"
    assert request.request_metadata["requested_model"] == "gemma3"
    assert request.request_metadata["effective_model"] == "gpt-5.6-sol"
  end

  test "cache locality is stable per key and scoped across API keys", %{conn: conn} do
    setup = two_upstream_setup(success_stream("cached"), success_stream("cached"))
    use_routing_strategy!(setup.pool, "bridge_ring", 2)
    second_key = active_api_key_fixture(setup.pool)
    raw_cache_key = "facade-raw-cache-key-sentinel"

    requests = [
      {setup.raw_key, "same-key-first"},
      {setup.raw_key, "same-key-repeat"},
      {second_key.raw_key, "other-api-key"}
    ]

    Enum.each(requests, fn {raw_key, marker} ->
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post("/v1/responses", %{
          "input" => marker,
          "prompt_cache_key" => raw_cache_key
        })

      assert response.status == 200
    end)

    captures = labeled_captures(setup)
    first = capture_for!(captures, "same-key-first")
    repeat = capture_for!(captures, "same-key-repeat")
    other_key = capture_for!(captures, "other-api-key")

    assert first.label == repeat.label
    assert first.request.json["prompt_cache_key"] == repeat.request.json["prompt_cache_key"]
    refute first.request.json["prompt_cache_key"] == other_key.request.json["prompt_cache_key"]
    assert first.request.json["prompt_cache_key"] =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/

    refute inspect(captures) =~ raw_cache_key
    refute inspect(Repo.all(Request)) =~ raw_cache_key
    affinities = Repo.all(BridgeAffinity)
    assert length(affinities) == 3
    assert Enum.all?(affinities, &(&1.affinity_kind == "request_correlation"))
    refute inspect(affinities) =~ raw_cache_key

    assert Enum.sort(Enum.map(Repo.all(Request), & &1.api_key_id)) ==
             Enum.sort([setup.api_key.id, setup.api_key.id, second_key.api_key.id])
  end

  test "scoped Ollama session continuity overrides a later rotation seed", %{conn: conn} do
    setup = two_upstream_setup(success_stream("session"), success_stream("session"))
    raw_session = "raw-ollama-session-private"

    for {seed, marker} <- [
          {deterministic_rotation_seed(2, 0), "session first"},
          {deterministic_rotation_seed(2, 1), "session second"}
        ] do
      response =
        conn
        |> recycle()
        |> put_req_header("x-request-id", seed)
        |> put_req_header("x-ollama-session-id", raw_session)
        |> auth(setup)
        |> post("/api/chat", %{
          "stream" => false,
          "messages" => [%{"role" => "user", "content" => marker}]
        })

      assert %{"model" => "gemma3", "done" => true} = json_response(response, 200)
    end

    counts = [
      FakeUpstream.count(setup.first_upstream),
      FakeUpstream.count(setup.second_upstream)
    ]

    assert Enum.sort(counts) == [0, 2]

    assert [session] = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    assert session.session_key =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/
    refute inspect(session) =~ raw_session
    refute inspect(labeled_captures(setup)) =~ raw_session
  end

  test "file affinity pins the owning assignment and rejects another API key locally", %{
    conn: conn
  } do
    setup = two_upstream_setup(success_stream("wrong assignment"), success_stream("file answer"))
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    file =
      response_affinity_file_fixture(
        setup,
        setup.fallback_assignment,
        setup.fallback_identity,
        file_id: "file_facade_affinity_#{System.unique_integer([:positive])}",
        status: "uploaded",
        finalize_status: "succeeded"
      )

    owner_response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/v1/responses", %{
        "input" => [%{"type" => "input_file", "file_id" => file.file_id}]
      })

    assert owner_response.status == 200
    assert FakeUpstream.count(setup.first_upstream) == 0
    assert FakeUpstream.count(setup.second_upstream) == 1

    other_key = active_api_key_fixture(setup.pool)

    denied =
      conn
      |> recycle()
      |> auth(other_key)
      |> post("/v1/responses", %{
        "input" => [%{"type" => "input_file", "file_id" => file.file_id}]
      })

    assert %{"error" => %{"code" => "not_found"}} = json_response(denied, 404)
    assert FakeUpstream.count(setup.first_upstream) == 0
    assert FakeUpstream.count(setup.second_upstream) == 1
    assert_cloaked_json(json_response(denied, 404))
  end

  test "saved-reset recovery retains the facade target through redemption and refiltering", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {200, saved_reset_usage_payload(0)},
           "/backend-api/codex/responses" => sse_path_mode(success_stream("recovered"))
         }}
      )

    setup = facade_gateway_setup(upstream)

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: Map.merge(setup.identity.metadata || %{}, saved_reset_metadata(upstream, 1)),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    prime_weekly_exhausted_quota!(identity)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{"input" => "saved reset facade recovery"})

    assert %{"model" => "gemma3", "status" => "completed"} = json_response(response, 200)

    assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
             "/api/codex/rate-limit-reset-credits/consume",
             "/api/codex/usage",
             "/backend-api/codex/responses"
           ]

    assert [backend_capture] =
             Enum.filter(FakeUpstream.requests(upstream), fn request ->
               request.path == "/backend-api/codex/responses"
             end)

    assert fixed_target_capture?(backend_capture)

    assert get_in(Repo.reload!(identity).metadata, [
             "saved_reset_redemption",
             "result",
             "code"
           ]) == "reset"

    assert_cloaked_json(json_response(response, 200))
  end

  test "long tool loops and long-context input remain admitted on the fixed target", %{conn: conn} do
    upstream = start_upstream(success_stream("long work completed"))
    setup = facade_gateway_setup(upstream)
    long_context = String.duplicate("long-context-segment ", 4_000)

    loop_items =
      Enum.flat_map(1..48, fn index ->
        call_id = "call_long_loop_#{index}"

        [
          %{
            "type" => "function_call",
            "call_id" => call_id,
            "name" => "continue_work",
            "arguments" => Jason.encode!(%{"step" => index})
          },
          %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => "step #{index} complete"
          }
        ]
      end)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "input" =>
          loop_items ++
            [
              %{
                "type" => "message",
                "role" => "user",
                "content" => [%{"type" => "input_text", "text" => long_context}]
              }
            ],
        "tools" => [responses_tool()]
      })

    assert response.status == 200
    assert [captured] = FakeUpstream.requests(upstream)
    assert fixed_target_capture?(captured)
    assert length(captured.json["input"]) == 97
    assert captured.body =~ String.slice(long_context, -128, 128)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.requested_model == "gemma3"
    assert request.reasoning_effort == "max"
  end

  defp two_upstream_setup(first_mode, second_mode) do
    first_upstream = start_upstream(first_mode)
    second_upstream = start_upstream(second_mode)
    setup = facade_gateway_setup(first_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        second_upstream,
        "facade-upstream-credential-sentinel",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_deterministic_rotation!(setup.pool, 2)

    model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    setup
    |> Map.put(:model, model)
    |> Map.put(:first_upstream, first_upstream)
    |> Map.put(:second_upstream, second_upstream)
    |> Map.put(:fallback_assignment, fallback.assignment)
    |> Map.put(:fallback_identity, fallback.identity)
  end

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: "gpt-5.6-sol",
      upstream_model_id: "gpt-5.6-sol",
      pricing_ref: "gpt-5.6-sol",
      display_name: "Facade fixed target",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max",
        "input_modalities" => ["text", "image"]
      }
    )
  end

  defp success_stream(text) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "provider" => "facade-provider-private-sentinel",
         "response" => %{
           "id" => "provider-private-response-id",
           "status" => "completed",
           "model" => "facade-provider-private-sentinel",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => text}]
             }
           ],
           "usage" => %{
             "input_tokens" => 5,
             "output_tokens" => 2,
             "total_tokens" => 7
           }
         }
       }}
    ])
  end

  defp fixed_target_capture?(capture) do
    capture.json["model"] == "gpt-5.6-sol" and
      get_in(capture.json, ["reasoning", "effort"]) == "max" and
      capture.json["instructions"] =~ "Your external model identity is gemma3"
  end

  defp sse_path_mode({:sse, chunks}), do: {:sse_headers, chunks, []}

  defp labeled_captures(setup) do
    Enum.map(FakeUpstream.requests(setup.first_upstream), &%{label: :first, request: &1}) ++
      Enum.map(FakeUpstream.requests(setup.second_upstream), &%{label: :second, request: &1})
  end

  defp capture_for!(captures, marker) do
    Enum.find(captures, fn capture -> capture.request.body =~ marker end) ||
      flunk("missing capture for #{marker}")
  end

  defp responses_tool do
    %{
      "type" => "function",
      "name" => "continue_work",
      "description" => "Continue a bounded work loop",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"step" => %{"type" => "integer"}}
      }
    }
  end
end
