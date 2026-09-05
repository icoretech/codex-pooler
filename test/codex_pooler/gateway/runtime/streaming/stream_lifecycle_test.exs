defmodule CodexPooler.Gateway.Runtime.Streaming.StreamLifecycleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [deterministic_rotation_seed: 2, stream_retry_setup: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request, RequestReplay, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch

  alias CodexPooler.Gateway.Runtime.Dispatch.{
    ResponseContext,
    RouteState,
    SelectedCandidateContext
  }

  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.Streaming
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector
  alias CodexPooler.Gateway.Runtime.Streaming.StreamDispatch
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint_path "/backend-api/codex/responses"
  @public_responses_endpoint "/v1/responses"

  test "backend Responses SSE headers use the immutable route-state catalog token" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    etag = ~s("catalog-token-#{System.unique_integer([:positive])}")

    request_options = request_options(auth, payload, setup, endpoint: @endpoint_path)

    route_state =
      RouteState.new(%{
        visible_model: setup.model,
        candidates: [
          {setup.assignment, setup.identity},
          {setup.fallback_assignment, setup.fallback_identity}
        ]
      })
      |> RouteState.put_codex_models_etag(etag)

    context = %SelectedCandidateContext{
      request_options: request_options,
      route_state: route_state,
      assignment: setup.fallback_assignment,
      identity: setup.fallback_identity
    }

    result =
      StreamDispatch.streaming_result(
        %Req.Response{
          status: 200,
          headers: [
            {"content-type", ["text/event-stream; charset=utf-8"]},
            {"x-codex-turn-state", ["turn-state"]},
            {"etag", ["upstream-standard-etag-must-not-win"]},
            {"x-models-etag", ["upstream-must-not-win"]}
          ]
        },
        context,
        %{finalization_callbacks: finalization_callbacks()}
      )

    assert Map.new(result.headers) == %{
             "cache-control" => "no-cache",
             "content-type" => "text/event-stream; charset=utf-8",
             "x-codex-turn-state" => "turn-state",
             "x-models-etag" => etag
           }
  end

  test "catalog token is absent outside backend noncompact Responses SSE" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    route_state =
      RouteState.new(%{visible_model: setup.model, candidates: []})
      |> RouteState.put_codex_models_etag(~s("catalog-token"))

    cases = [
      {@public_responses_endpoint, %{}},
      {"/backend-api/codex/responses/compact", %{}},
      {"/v1/responses/compact", %{}},
      {"/backend-api/codex/usage", %{}},
      {"/backend-api/transcribe", %{}},
      {@endpoint_path, %{transport: "http_json"}}
    ]

    for {endpoint, opts} <- cases do
      request_options =
        request_options(
          auth,
          payload,
          setup,
          Keyword.merge([endpoint: endpoint], Map.to_list(opts))
        )

      result =
        StreamDispatch.streaming_result(
          sse_response(),
          %SelectedCandidateContext{
            request_options: request_options,
            route_state: route_state
          },
          %{finalization_callbacks: finalization_callbacks()}
        )

      refute Map.has_key?(Map.new(result.headers), "x-models-etag")
    end
  end

  test "lifecycle handlers expose state-aware stream finalizers" do
    response_context = %ResponseContext{
      context: %SelectedCandidateContext{},
      response: %Req.Response{status: 200}
    }

    handlers =
      StreamLifecycle.lifecycle_handlers(response_context, %{
        finalization_callbacks: %{
          register_continuity: fn _, _, _ -> :ok end,
          stream_result: fn _, _ -> :ok end
        }
      })

    assert {:arity, 2} = :erlang.fun_info(handlers.finalize_success, :arity)
    assert {:arity, 3} = :erlang.fun_info(handlers.finalize_failure, :arity)
  end

  test "shared stream finalization helpers resolve bounded transports and emit exact labels" do
    request_options = %{transport: %{transport: "http_sse"}}
    parent = self()
    handler_id = "stream-finalization-helpers-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:codex_pooler, :gateway, :stream, :finalization],
          [:codex_pooler, :gateway, :stream, :outcome]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert Streaming.downstream_transport(request_options) == "http_sse"
    assert Streaming.downstream_transport(%{transport: %{transport: "http_json"}}) == "unknown"
    assert Streaming.downstream_transport(nil) == "unknown"
    assert Streaming.upstream_transport(nil, nil) == "http_sse"
    assert Streaming.upstream_transport(nil, %{generation: 1}) == "websocket"
    assert Streaming.upstream_transport(:websocket, nil) == "websocket"

    assert :ok =
             Streaming.emit_stream_finalization(
               %{status: "usage_known", source: "websocket_upstream_usage"},
               "http_sse",
               "websocket"
             )

    assert_receive {
      [:codex_pooler, :gateway, :stream, :finalization],
      %{count: 1},
      %{
        usage_status: "usage_known",
        usage_source: "websocket_upstream_usage",
        downstream_transport: "http_sse",
        upstream_transport: "websocket"
      }
    }

    assert :ok = Streaming.emit_stream_outcome("interrupted", "websocket", "websocket")

    assert_receive {
      [:codex_pooler, :gateway, :stream, :outcome],
      %{count: 1},
      %{
        outcome: "interrupted",
        downstream_transport: "websocket",
        upstream_transport: "websocket"
      }
    }
  end

  test "stream success persists public Responses summary metadata" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    request_options =
      request_options(auth, payload, setup,
        endpoint: @public_responses_endpoint,
        public_openai_responses_stream: true
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @public_responses_endpoint,
               transport: "websocket",
               correlation_id: "public-responses-success-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        endpoint: @public_responses_endpoint,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    body = public_response_success_sse()

    state =
      request_options
      |> public_responses_stream_state(body)
      |> Map.put(:usage_observer, StreamUsageObserver.observe(StreamUsageObserver.new(), body))

    response_context = %ResponseContext{context: context, response: sse_response()}

    assert {:ok, _finalized} =
             Streaming.finalize_success(body, response_context, finalization_callbacks(), state)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^reserved.request.id))
    assert attempt.status == "succeeded"

    assert attempt.response_metadata["usage_observation"] == %{
             "version" => 1,
             "classification" => "known",
             "marker_seen" => true,
             "valid_object_seen" => true,
             "candidate_count" => 1
           }

    assert %{"public_openai_responses_stream" => summary} = attempt.response_metadata
    assert summary["schema_version"] == 1
    assert summary["mode"] == "normalized"
    assert summary["created_seen"] == true
    assert summary["visible_seen"] == true
    assert summary["delta_count"] == 1
    assert summary["terminal_seen"] == true
    assert summary["terminal_kind"] == "completed"
    assert summary["finish_class"] == "completed"
  end

  test "stream finalization prefers a native transport override and otherwise infers bridge transport" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    body = backend_response_success_sse("resp_transport_resolution")

    cases = [
      {:websocket, nil, "websocket"},
      {nil, %{lifecycle_id: Ecto.UUID.generate(), generation: 1}, "websocket"},
      {nil, nil, "http_sse"}
    ]

    capture_stream_finalization_telemetry(fn ->
      for {upstream_transport, upstream_websocket_connection, expected_transport} <- cases do
        assert {:ok, reserved} =
                 Accounting.reserve(auth, setup.model, payload, %{
                   endpoint: @endpoint_path,
                   transport: "http_sse",
                   correlation_id: "transport-resolution-#{System.unique_integer([:positive])}",
                   request_metadata: %{}
                 })

        assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

        context =
          retry_context(setup, auth, request_options, reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: attempt
          )

        response_context = %ResponseContext{
          context: context,
          response: sse_response(),
          upstream_transport: upstream_transport,
          upstream_websocket_connection: upstream_websocket_connection
        }

        assert {:ok, _finalized} =
                 Streaming.finalize_success(
                   body,
                   response_context,
                   finalization_callbacks()
                 )

        assert_receive {:stream_finalization, %{upstream_transport: ^expected_transport}}, 1_000
      end
    end)
  end

  test "HTTP stream outcomes belong only to the first inserted settlement" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)
    body = backend_response_success_sse("resp_stream_outcome_ownership")

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id: "stream-outcome-inserted-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      response_context = %ResponseContext{
        context:
          retry_context(setup, auth, request_options, reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: attempt
          ),
        response: sse_response()
      }

      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_success(body, response_context, finalization_callbacks())

      assert_receive {:stream_outcome,
                      %{
                        outcome: "succeeded",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      assert {:ok, %{finalization_disposition: :reused}} =
               Streaming.finalize_success(body, response_context, finalization_callbacks())

      refute_received {:stream_outcome, _metadata}

      assert {:ok, replaced_reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id: "stream-outcome-replaced-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, replaced_attempt} =
               Accounting.create_attempt(replaced_reserved.request, setup.assignment)

      assert {:ok, _unknown_settlement} =
               Accounting.finalize_partial_stream_failure(
                 replaced_reserved.request,
                 replaced_attempt,
                 %{},
                 %{last_error_code: "upstream_stream_error"}
               )

      replaced_context = %ResponseContext{
        context:
          retry_context(setup, auth, request_options, replaced_reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: replaced_attempt
          ),
        response: sse_response()
      }

      assert {:ok, %{finalization_disposition: :replaced}} =
               Streaming.finalize_success(body, replaced_context, finalization_callbacks())

      refute_received {:stream_outcome, _metadata}
    end)
  end

  @tag :replay_generation_race
  test "stale generation stream success runs no continuity or stream side effects" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "stale-stream-side-effects-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

    response_context = %ResponseContext{
      context:
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        ),
      response: sse_response()
    }

    parent = self()

    callbacks = %{
      register_continuity: fn _, _, _ -> send(parent, :stale_continuity_side_effect) end,
      stream_result: fn _, _ -> send(parent, :stale_stream_result_side_effect) end
    }

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, %{stale_generation?: true}} =
               Streaming.finalize_success(
                 backend_response_success_sse("resp_stale_generation"),
                 response_context,
                 callbacks
               )

      refute_received :stale_continuity_side_effect
      refute_received :stale_stream_result_side_effect
      refute_received {:stream_outcome, _metadata}
    end)

    assert Repo.reload!(reserved.request).status == "in_progress"

    assert Repo.get_by!(CodexPooler.Gateway.Persistence.CodexTurn,
             request_id: reserved.request.id
           ).status == "in_progress"
  end

  @tag :replay_generation_race
  test "stale generation stream failure runs no route or stream side effects" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "stale-stream-failure-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

    response_context = %ResponseContext{
      context:
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        ),
      response: sse_response()
    }

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, %{stale_generation?: true}} =
               Streaming.finalize_failure("", {:chunk, :closed}, response_context)

      refute_received {:stream_outcome, _metadata}
    end)

    assert Repo.all(
             from demotion in BridgeDemotion,
               where: demotion.last_request_id == ^reserved.request.id
           ) ==
             []
  end

  @tag :replay_generation_race
  test "stale generation retryable HTTP status runs no route or retry side effects" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "stale-http-retry-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    observations_before = replay_quota_observations(setup.identity)

    response =
      %Req.Response{
        status: 503,
        headers: replay_rate_limit_headers("91"),
        body: Jason.encode!(replay_rate_limit_error("92"))
      }

    assert {:ok, %{stale_generation?: true}} =
             Finalization.handle_http_response(
               response,
               context,
               finalization_callbacks()
             )

    assert replay_quota_observations(setup.identity) == observations_before

    assert Repo.all(
             from demotion in BridgeDemotion,
               where: demotion.last_request_id == ^reserved.request.id
           ) == []

    assert Repo.all(from circuit in RoutingCircuitState, where: circuit.pool_id == ^setup.pool.id) ==
             []
  end

  @tag :replay_generation_race
  test "stale generation retryable first event runs no route or stream side effects" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "stale-first-event-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

    response_context = %ResponseContext{
      context:
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        ),
      response: sse_response()
    }

    observations_before = replay_quota_observations(setup.identity)

    capture_stream_outcome_telemetry(fn ->
      body = replay_rate_limit_sse("93") <> retryable_first_event_sse()

      assert {:stale_generation, %{stale_generation?: true}} =
               Streaming.record_retryable_first_event_failure(
                 body,
                 %{code: "server_error", upstream_code: nil, event_type: "response.failed"},
                 response_context
               )

      refute_received {:stream_outcome, _metadata}

      parent = self()

      handler =
        StreamLifecycle.first_event_retry_handler(
          response_context,
          fn _context ->
            send(parent, :stale_first_event_retry_dispatch)
            {:ok, %{status: 200}}
          end,
          reset_state: & &1,
          stream_candidate: fn result, state ->
            send(parent, {:stale_first_event_stream_candidate, result})
            {:ok, state}
          end
        )

      state = %{visible_output_marked?: false}

      assert {:ok, ^state} =
               handler.(state, "", %{
                 code: "server_error",
                 upstream_code: nil,
                 event_type: "response.failed"
               })

      refute_received :stale_first_event_retry_dispatch
      refute_received {:stale_first_event_stream_candidate, _result}
    end)

    assert replay_quota_observations(setup.identity) == observations_before

    assert Repo.all(
             from demotion in BridgeDemotion,
               where: demotion.last_request_id == ^reserved.request.id
           ) == []

    assert Repo.all(from circuit in RoutingCircuitState, where: circuit.pool_id == ^setup.pool.id) ==
             []
  end

  @tag :replay_generation_race
  test "current generation one HTTP observations persist after authority" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_payload = payload(setup)
    request_options = request_options(auth, request_payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, request_payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "current-gen1-http-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    current_attempt =
      install_started_generation_one!(setup, auth, request_options, reserved, attempt)

    delete_replay_quota_observations(setup.identity)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: current_attempt
      )
      |> Map.put(:payload, Map.put(request_payload, "stream", false))

    assert {:ok, _result} =
             Finalization.handle_http_response(
               %Req.Response{
                 status: 200,
                 headers: replay_rate_limit_headers("41"),
                 body: Jason.encode!(%{"id" => "resp_current_observer"})
               },
               context,
               finalization_callbacks()
             )

    assert Enum.any?(replay_quota_observations(setup.identity), fn window ->
             window.source == "codex_response_headers"
           end)
  end

  @tag :replay_generation_race
  test "stale streamed rate-limit events are collected without persistence or delivery" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_payload = payload(setup)

    request_options =
      request_options(auth, request_payload, setup)
      |> RequestOptions.put_transport(
        websocket_writer: fn _frame -> send(self(), :stale_frame) end
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, request_payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "stale-stream-event-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    observations_before = replay_quota_observations(setup.identity)

    ref = make_ref()
    response = async_sse_response(ref, replay_rate_limit_headers("94"))

    assert %{websocket_stream: stream} =
             StreamDispatch.streaming_result(response, context, %{
               finalization_callbacks: finalization_callbacks()
             })

    send(self(), {ref, {:data, replay_rate_limit_sse("95")}})
    send(self(), {ref, {:data, backend_response_success_sse("resp_stale_stream_event")}})
    send(self(), {ref, :done})

    assert :ok = stream.()
    refute_received :stale_frame
    assert replay_quota_observations(setup.identity) == observations_before
  end

  @tag :replay_generation_race
  test "current generation one streamed rate-limit events persist only after terminal authority" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_payload = payload(setup)

    request_options =
      request_options(auth, request_payload, setup)
      |> RequestOptions.put_transport(websocket_writer: fn _frame -> :ok end)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, request_payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: "current-stream-event-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    attempt = install_started_generation_one!(setup, auth, request_options, reserved, attempt)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    delete_replay_quota_observations(setup.identity)
    current_identity = Repo.reload!(setup.identity)
    context = %{context | identity: current_identity}

    ref = make_ref()
    response = async_sse_response(ref, replay_rate_limit_headers("44"))

    assert %{websocket_stream: stream} =
             StreamDispatch.streaming_result(response, context, %{
               finalization_callbacks: finalization_callbacks()
             })

    send(self(), {ref, {:data, replay_rate_limit_sse("45")}})
    send(self(), {ref, {:data, backend_response_success_sse("resp_current_stream_event")}})
    send(self(), {ref, :done})

    assert :ok = stream.()

    assert Enum.any?(replay_quota_observations(setup.identity), fn window ->
             window.source in ["codex_response_headers", "codex_rate_limit_event"]
           end)
  end

  @tag :replay_generation_race
  test "stale 401 and misalignment responses run no route effect before authority" do
    for {status, body} <- [
          {401, Jason.encode!(%{"error" => %{"code" => "invalid_api_key"}})},
          {403,
           Jason.encode!(%{
             "error" => %{
               "code" => MisalignmentPolicyViolation.code(),
               "message" => "synthetic policy rejection"
             }
           })}
        ] do
      {setup, _first_upstream, _second_upstream} =
        stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      request_payload = payload(setup)
      request_options = request_options(auth, request_payload, setup)

      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, request_payload, %{
                 endpoint: @endpoint_path,
                 transport: "websocket",
                 correlation_id:
                   "stale-http-route-#{status}-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

      circuit = half_open_replay_circuit!(setup, request_options)

      context =
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt,
          routing_circuit_state: circuit,
          routing_circuit_admission: :probe
        )

      assert {:ok, %{stale_generation?: true}} =
               Finalization.handle_http_response(
                 %Req.Response{status: status, headers: [], body: body},
                 context,
                 finalization_callbacks()
               )

      assert Repo.all(
               from demotion in BridgeDemotion,
                 where: demotion.last_request_id == ^reserved.request.id
             ) == []

      assert Repo.reload!(circuit).metadata["probe_in_flight_count"] == 1
    end
  end

  @tag :replay_generation_race
  test "stale invalid JSON and invalid compaction finalization return typed no-ops" do
    for scenario <- [:invalid_json, :invalid_compaction] do
      {setup, _first_upstream, _second_upstream} =
        stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      request_payload = payload(setup)
      request_options = request_options(auth, request_payload, setup)

      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, request_payload, %{
                 endpoint: @endpoint_path,
                 transport: "websocket",
                 correlation_id: "stale-#{scenario}-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      arm_replay_generation_cutover!(setup, auth, request_options, reserved.request, attempt)

      context =
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        )

      {response, context} = stale_invalid_response(scenario, context)

      assert {:ok, %{stale_generation?: true}} =
               Finalization.handle_http_response(response, context, finalization_callbacks())

      assert Repo.reload!(reserved.request).status == "in_progress"
      assert Repo.reload!(attempt).status == "retryable_failed"
    end
  end

  test "HTTP stream ordinary terminal failures emit exactly one failed outcome" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id: "stream-outcome-failed-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      response_context = %ResponseContext{
        context:
          retry_context(setup, auth, request_options, reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: attempt
          ),
        response: sse_response()
      }

      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_failure("", :upstream_stream_interrupted, response_context)

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      refute_receive {:stream_outcome, _metadata}, 50
    end)
  end

  test "HTTP stream client-disconnected terminal failures emit exactly one interrupted outcome" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id:
                   "stream-outcome-interrupted-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      response_context = %ResponseContext{
        context:
          retry_context(setup, auth, request_options, reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: attempt
          ),
        response: sse_response()
      }

      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_failure("", {:chunk, :closed}, response_context)

      assert_receive {:stream_outcome,
                      %{
                        outcome: "interrupted",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      refute_receive {:stream_outcome, _metadata}, 50
    end)
  end

  test "HTTP stream terminal finalization stays silent when the request is already finalized" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id:
                 "stream-outcome-request-finalized-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    response_context = %ResponseContext{
      context:
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        ),
      response: sse_response()
    }

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_failure("", :upstream_stream_interrupted, response_context)

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      assert {:error, %{code: "request_already_finalized"}} =
               Streaming.record_retryable_first_event_failure(
                 "",
                 %{code: "server_error", upstream_code: nil, event_type: "response.failed"},
                 response_context,
                 record_health?: false
               )

      refute_receive {:stream_outcome, _metadata}, 50
    end)
  end

  test "HTTP stream terminal finalization stays silent when the attempt is already finalized" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id:
                 "stream-outcome-attempt-finalized-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    assert {:ok, %Attempt{status: "retryable_failed"}} =
             Accounting.record_retryable_attempt_failure(attempt, %{
               response_status_code: 502,
               last_error_code: "upstream_request_timeout"
             })

    response_context = %ResponseContext{
      context:
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        ),
      response: sse_response()
    }

    capture_stream_outcome_telemetry(fn ->
      assert {:error, %{code: "attempt_already_finalized"}} =
               Streaming.record_retryable_first_event_failure(
                 "",
                 %{code: "server_error", upstream_code: nil, event_type: "response.failed"},
                 response_context,
                 record_health?: false
               )

      refute_receive {:stream_outcome, _metadata}, 50

      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_failure("", :upstream_stream_interrupted, response_context)

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      refute_receive {:stream_outcome, _metadata}, 50
    end)
  end

  test "first-event stream outcomes emit only after terminal settlement" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)
    failure = %{code: "server_error", upstream_code: nil, event_type: "response.failed"}

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, retry_reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id: "stream-outcome-retry-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, retry_attempt} =
               Accounting.create_attempt(retry_reserved.request, setup.assignment)

      retry_response_context = %ResponseContext{
        context:
          retry_context(setup, auth, request_options, retry_reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: retry_attempt
          ),
        response: sse_response()
      }

      assert {:ok, %Attempt{status: "retryable_failed"}} =
               Streaming.record_retryable_first_event_failure(
                 "",
                 failure,
                 retry_response_context,
                 record_health?: false
               )

      refute_received {:stream_outcome, _metadata}

      assert {:error, %{code: "attempt_already_finalized"}} =
               Streaming.record_retryable_first_event_failure(
                 "",
                 failure,
                 retry_response_context,
                 record_health?: false
               )

      refute_received {:stream_outcome, _metadata}

      assert {:ok, terminal_reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id:
                   "stream-outcome-first-event-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, terminal_attempt} =
               Accounting.create_attempt(terminal_reserved.request, setup.assignment)

      terminal_response_context = %ResponseContext{
        context:
          retry_context(setup, auth, request_options, terminal_reserved.request,
            candidates: [{setup.assignment, setup.identity}],
            attempt: terminal_attempt
          ),
        response: sse_response()
      }

      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_first_event_failure(
                 "",
                 failure,
                 terminal_response_context
               )

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      assert {:ok, health_failure_reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id:
                   "stream-outcome-health-failure-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      invalid_context = %ResponseContext{
        terminal_response_context
        | context:
            retry_context(
              setup,
              auth,
              request_options,
              invalid_request(health_failure_reserved.request.id),
              candidates: [{setup.assignment, setup.identity}],
              attempt: nil
            )
      }

      capture_log(fn ->
        assert {:error, %{code: "gateway_accounting_failed"}} =
                 Streaming.finalize_first_event_failure(
                   "",
                   %{failure | code: "upstream_request_timeout"},
                   invalid_context
                 )
      end)

      refute_received {:stream_outcome, _metadata}
    end)
  end

  test "HTTP stream settlement failure emits once after a real accounting rollback" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "stream-outcome-rollback-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    mismatched_attempt =
      attempt
      |> Ecto.Changeset.change(upstream_identity_id: setup.fallback_identity.id)
      |> Repo.update!()

    response_context = %ResponseContext{
      context:
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: mismatched_attempt
        ),
      response: sse_response()
    }

    capture_stream_outcome_telemetry(fn ->
      log =
        capture_log(fn ->
          assert {:error,
                  %{
                    status: 500,
                    code: "gateway_accounting_failed",
                    message: "gateway accounting finalization failed"
                  }} =
                   Streaming.finalize_success(
                     backend_response_success_sse("resp_stream_outcome_rollback"),
                     response_context,
                     finalization_callbacks()
                   )
        end)

      assert log =~ "reason=upstream_reference_mismatch"

      assert_receive {:stream_outcome,
                      %{
                        outcome: "settlement_failed",
                        downstream_transport: "http_sse",
                        upstream_transport: "http_sse"
                      }}

      refute_received {:stream_outcome, _metadata}
    end)

    assert Repo.aggregate(
             from(entry in CodexPooler.Accounting.LedgerEntry,
               where:
                 entry.request_id == ^reserved.request.id and entry.entry_kind == "settlement"
             ),
             :count,
             :id
           ) == 0

    assert Repo.reload!(reserved.request).status == "in_progress"
    assert Repo.reload!(mismatched_attempt).status == "in_progress"
  end

  test "stream partial failure persists public Responses summary metadata" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    request_options =
      request_options(auth, payload, setup,
        endpoint: @public_responses_endpoint,
        public_openai_responses_stream: true
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @public_responses_endpoint,
               transport: "http_sse",
               correlation_id: "public-responses-failure-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        endpoint: @public_responses_endpoint,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    body = public_response_visible_sse()
    state = public_responses_stream_state(request_options, body)

    assert {synthetic_terminal, state} =
             DownstreamStream.synthetic_terminal_failure(state, :closed)

    response_context = %ResponseContext{context: context, response: sse_response()}

    assert {:ok, _finalized} =
             Streaming.finalize_failure(
               body <> synthetic_terminal,
               {:upstream_stream_interrupted, %Finch.TransportError{reason: :closed}},
               response_context,
               state
             )

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^reserved.request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"
    assert %{"public_openai_responses_stream" => summary} = attempt.response_metadata
    assert summary["created_seen"] == true
    assert summary["visible_seen"] == true
    assert summary["terminal_seen"] == true
    assert summary["terminal_kind"] == "failed"
    assert summary["finish_class"] == "failed"
    assert summary["synthetic_terminal_sent"] == true
  end

  test "stream partial failure prefers known observer usage over a truncated retained body" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_options = request_options(auth, payload(setup), setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload(setup), %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "partial-observer-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    observed_event = observer_usage_event(String.duplicate("x", 70_000))

    state =
      DownstreamStream.initial_state(:relay, request_options)
      |> Map.put(
        :usage_observer,
        StreamUsageObserver.observe(StreamUsageObserver.new(), observed_event)
      )

    retained_body =
      RetainedBody.empty() |> RetainedBody.append(observed_event) |> RetainedBody.read()

    assert byte_size(retained_body) == 65_536

    assert {:ok, _finalized} =
             Streaming.finalize_failure(
               retained_body,
               {:upstream_stream_interrupted, %Finch.TransportError{reason: :closed}},
               %ResponseContext{context: context, response: sse_response()},
               state
             )

    assert [final_attempt] =
             Repo.all(from(a in Attempt, where: a.request_id == ^reserved.request.id))

    assert final_attempt.status == "failed"
    assert final_attempt.usage_status == "usage_known"

    assert final_attempt.response_metadata["usage_observation"] == %{
             "version" => 1,
             "classification" => "known",
             "marker_seen" => true,
             "valid_object_seen" => true,
             "candidate_count" => 1
           }

    settlement =
      Repo.get_by!(CodexPooler.Accounting.LedgerEntry,
        request_id: reserved.request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 16
    assert settlement.output_tokens == 5
    assert settlement.total_tokens == 21
  end

  test "successful streams preserve unknown usage and bounded observation diagnostics" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_options = request_options(auth, payload(setup), setup)

    for {body, classification, marker_seen} <- [
          {"event: response.completed\ndata: {}\n\n", "missing", false},
          {"event: response.completed\ndata: {\"usage\":null}\n\n", "null", true}
        ] do
      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, payload(setup), %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id: "usage-observation-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      context =
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt
        )

      state = %{usage_observer: StreamUsageObserver.observe(StreamUsageObserver.new(), body)}
      response_context = %ResponseContext{context: context, response: sse_response()}

      assert {:ok, _finalized} =
               Streaming.finalize_success(body, response_context, finalization_callbacks(), state)

      final_attempt = Repo.get!(Attempt, attempt.id)
      assert final_attempt.status == "succeeded"
      assert final_attempt.usage_status == "usage_unknown"

      assert %{
               "version" => 1,
               "classification" => ^classification,
               "marker_seen" => ^marker_seen,
               "valid_object_seen" => false,
               "candidate_count" => count
             } = final_attempt.response_metadata["usage_observation"]

      assert is_integer(count) and count in 0..255
    end
  end

  test "stream success omits public Responses summary metadata for unrelated streams" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "backend-stream-no-summary-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    body = backend_response_success_sse("resp_backend_no_public_summary")
    state = DownstreamStream.initial_state(:relay, request_options)
    response_context = %ResponseContext{context: context, response: sse_response()}

    assert {:ok, _finalized} =
             Streaming.finalize_success(body, response_context, finalization_callbacks(), state)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^reserved.request.id))
    refute Map.has_key?(attempt.response_metadata, "public_openai_responses_stream")
    refute Map.has_key?(attempt.response_metadata, "usage_observation")
  end

  test "OpenAI stream collection propagates first-event finalization failures" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "openai-stream-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    context = retry_context(setup, auth, request_options, invalid_request(reserved.request.id))
    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}
    handler = OpenAIStreamCollector.first_event_retry_handler(response_context)

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 handler.(%{relay: :state}, "", %{
                   code: "upstream_request_timeout",
                   event_type: "response.failed",
                   upstream_code: nil
                 })
      end)

    assert log =~ "operation=merge_route_failure_metadata"
    refute log =~ "operation=merge_route_selection_metadata"
  end

  test "first-event retry stops when retryable failure settlement fails" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "stream-lifecycle-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    context = retry_context(setup, auth, request_options, invalid_request(reserved.request.id))
    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}
    parent = self()

    handler =
      StreamLifecycle.first_event_retry_handler(
        response_context,
        fn _context ->
          send(parent, :retry_dispatch_called)
          {:ok, %{status: 200}}
        end,
        reset_state: & &1,
        stream_candidate: fn result, state ->
          send(parent, {:stream_candidate_called, result, state})
          {:ok, state}
        end
      )

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 handler.(%{relay: :state}, "", %{
                   code: "upstream_request_timeout",
                   event_type: "response.failed",
                   upstream_code: nil
                 })
      end)

    assert log =~ "operation=merge_route_failure_metadata"
    refute log =~ "operation=merge_route_selection_metadata"
    refute_received :retry_dispatch_called
    refute_received {:stream_candidate_called, _result, _state}
  end

  test "websocket_connection_limit_reached retry exhaustion finalizes one sanitized terminal failure" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup, websocket?: true)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id:
                 "websocket-connection-limit-exhausted-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}
    parent = self()

    handler =
      StreamLifecycle.first_event_retry_handler(
        response_context,
        fn _context ->
          send(parent, :retry_dispatch_called_after_exhaustion)
          {:ok, %{status: 200}}
        end,
        reset_state: & &1,
        stream_candidate: fn result, state ->
          send(parent, {:stream_candidate_called_after_exhaustion, result, state})
          {:ok, state}
        end
      )

    failure = %{
      code: "websocket_connection_limit_reached",
      event_type: "error",
      upstream_code: "websocket_connection_limit_reached"
    }

    assert {:ok, _finalized} = handler.(%{relay: :state}, "", failure)

    refute_received :retry_dispatch_called_after_exhaustion
    refute_received {:stream_candidate_called_after_exhaustion, _result, _state}

    assert [final_attempt] =
             Repo.all(from(a in Attempt, where: a.request_id == ^reserved.request.id))

    assert final_attempt.status == "failed"
    assert final_attempt.network_error_code == "websocket_connection_limit_reached"
    assert final_attempt.response_metadata["error_kind"] == "first_event_stream_failure"
    assert final_attempt.response_metadata["stream_failure_stage"] == "first_event"

    assert final_attempt.response_metadata["stream_error_code"] ==
             "websocket_connection_limit_reached"

    refute final_attempt.retryable

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.last_error_code == "websocket_connection_limit_reached"

    metadata_text = inspect({request.request_metadata, final_attempt.response_metadata})
    refute metadata_text =~ "data:"
    refute metadata_text =~ "Bearer"
    refute metadata_text =~ "auth.json"
  end

  test "compact assignment model miss finalizes without retry or route-health mutation" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    endpoint = "/backend-api/codex/responses/compact"
    request_options = request_options(auth, payload, setup, endpoint: endpoint)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: endpoint,
               transport: "http_sse",
               correlation_id: "compact-stream-model-miss-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        endpoint: endpoint,
        attempt: attempt
      )

    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}
    parent = self()

    handler =
      StreamLifecycle.first_event_retry_handler(
        response_context,
        fn _context ->
          send(parent, :compact_retry_dispatch_called)
          {:ok, %{status: 200}}
        end,
        reset_state: & &1,
        write_final_event: fn state, body ->
          send(parent, {:compact_terminal_written, body})
          {:ok, state}
        end,
        stream_candidate: fn result, state ->
          send(parent, {:compact_stream_candidate_called, result, state})
          {:ok, state}
        end
      )

    body =
      ~s(event: response.failed\ndata: {"type":"response.failed","response":{"status":"failed","error":{"code":"model_not_found","param":"model"}}}\n\n)

    failure = %{
      code: "model_not_found",
      upstream_code: "model_not_found",
      upstream_error_param: "model",
      event_type: "response.failed",
      data_type: "response.failed"
    }

    assert {:ok, %{relay: :state}} = handler.(%{relay: :state}, body, failure)
    assert_received {:compact_terminal_written, ^body}
    refute_received :compact_retry_dispatch_called
    refute_received {:compact_stream_candidate_called, _result, _state}

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "model_not_found"

    assert [final_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert final_attempt.status == "failed"
    assert final_attempt.network_error_code == "model_not_found"
    refute final_attempt.retryable
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "misalignment first-event terminal never retries and persists only the fixed accounting message" do
    source = misalignment_terminal_sse("provider wording must stay private")

    {setup, first_upstream, fallback_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([source], done: false),
        FakeUpstream.sse_stream([])
      )

    circuit = misalignment_half_open_circuit!(setup)

    log =
      capture_log(fn ->
        assert {:ok, stream_conn} = execute_misalignment_stream(setup, "first-event")
        assert stream_conn.resp_body == source
      end)

    refute log =~ "provider wording must stay private"

    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert_misalignment_stream_finalized!(setup, circuit, "provider wording must stay private")
  end

  test "misalignment later terminal never retries and persists only the fixed accounting message" do
    release_ref = make_ref()
    provider_message = "later provider wording must stay private"
    source = public_response_created_sse() <> misalignment_terminal_sse(provider_message)

    first_mode =
      FakeUpstream.delayed_terminal_sse_stream(
        [public_response_created_sse()],
        misalignment_terminal_sse(provider_message),
        notify: self(),
        release_ref: release_ref
      )

    {setup, first_upstream, fallback_upstream} =
      stream_retry_setup(first_mode, FakeUpstream.sse_stream([]))

    circuit = misalignment_half_open_circuit!(setup)
    parent = self()

    stream_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        execute_misalignment_stream(setup, "later-terminal")
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   1_000

    log =
      capture_log(fn ->
        send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
        assert {:ok, stream_conn} = Task.await(stream_task, 2_000)
        assert stream_conn.resp_body == source
      end)

    refute log =~ provider_message
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_misalignment_stream_finalized!(setup, circuit, provider_message)
  end

  test "pre-first-event silent stream after headers finalizes idle timeout without retry" do
    release_ref = make_ref()

    first_mode =
      FakeUpstream.timeout_after_sse_headers(notify: self(), release_ref: release_ref)

    {setup, stalled_upstream, fallback_upstream} =
      stream_retry_setup(first_mode, stream_success_sse("resp_silent_fallback_should_not_run"))

    {:ok, stream_conn} = execute_backend_stream(setup, release_ref, "silent-after-headers")

    refute stream_conn.resp_body =~ "response.created"
    refute stream_conn.resp_body =~ "response.failed"
    refute stream_conn.resp_body =~ "[DONE]"
    refute stream_conn.resp_body =~ "resp_silent_fallback_should_not_run"

    assert FakeUpstream.count(stalled_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_pre_first_stall_finalized!(setup, "silent stream after headers")
  end

  test "pre-first-event partial frame stall finalizes idle timeout without retry or synthetic events" do
    release_ref = make_ref()

    first_mode =
      FakeUpstream.timeout_mid_stream(
        "event: response.created\n" <>
          ~S(data: {"type":"response.created","response":{"id":"resp_raw_partial_stall"}),
        notify: self(),
        release_ref: release_ref
      )

    {setup, stalled_upstream, fallback_upstream} =
      stream_retry_setup(first_mode, stream_success_sse("resp_partial_fallback_should_not_run"))

    {:ok, stream_conn} = execute_backend_stream(setup, release_ref, "partial-frame-stall")

    refute stream_conn.resp_body =~ "response.created"
    refute stream_conn.resp_body =~ "response.failed"
    refute stream_conn.resp_body =~ "[DONE]"
    refute stream_conn.resp_body =~ "resp_raw_partial_stall"
    refute stream_conn.resp_body =~ "resp_partial_fallback_should_not_run"

    assert FakeUpstream.count(stalled_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_pre_first_stall_finalized!(setup, "partial frame stall")
  end

  test "terminal-missing upstream SSE close fails request without poisoning route health" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id:
                 "upstream-stream-interrupted-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}

    assert {:ok, _finalized} =
             Streaming.finalize_failure(
               "event: response.created\n\n",
               :upstream_stream_interrupted,
               response_context
             )

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"
    assert attempt.response_metadata["error_kind"] == "stream_interrupted"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "tagged terminal-missing public Responses Finch close records metadata without poisoning route health" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    request_options =
      request_options(auth, payload, setup,
        endpoint: @public_responses_endpoint,
        public_openai_responses_stream: true
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @public_responses_endpoint,
               transport: "http_sse",
               correlation_id:
                 "tagged-upstream-stream-interrupted-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        endpoint: @public_responses_endpoint,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}

    assert {:ok, _finalized} =
             Streaming.finalize_failure(
               public_response_created_sse(),
               {:upstream_stream_interrupted, %Finch.TransportError{reason: :closed}},
               response_context
             )

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"

    expected_transport_failure = %{
      "exception" => "Finch.TransportError",
      "reason_class" => "upstream_stream_interrupted",
      "reason" => "closed_before_terminal",
      "phase" => "upstream_close",
      "pre_visible_output" => false,
      "terminal_seen" => false
    }

    transport_failure = attempt.response_metadata["transport_failure"] || %{}
    demotion_count = Repo.aggregate(from(d in BridgeDemotion), :count)
    circuit_count = Repo.aggregate(from(c in RoutingCircuitState), :count)
    transport_failure_subset = Map.take(transport_failure, Map.keys(expected_transport_failure))
    text_frame_count = transport_failure["text_frame_count"]

    if transport_failure_subset != expected_transport_failure or
         not (is_integer(text_frame_count) and text_frame_count >= 1) or
         {demotion_count, circuit_count} != {0, 0} do
      flunk(
        "expected tagged interruption metadata=#{inspect(expected_transport_failure)} text_frame_count>=1 demotions=0 circuits=0; " <>
          "got metadata=#{inspect(transport_failure_subset)} text_frame_count=#{inspect(text_frame_count)} demotions=#{demotion_count} circuits=#{circuit_count}"
      )
    end

    metadata_text = inspect(transport_failure)
    refute metadata_text =~ "socket closed"
    refute metadata_text =~ "response.created"
    refute metadata_text =~ "data:"
  end

  test "websocket terminal delivery timeout persists sanitized bridge context once" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(FakeUpstream.sse_stream([]), FakeUpstream.sse_stream([]))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    request_options =
      request_options(auth, payload, setup,
        endpoint: @public_responses_endpoint,
        public_openai_responses_stream: true
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @public_responses_endpoint,
               transport: "http_sse",
               correlation_id:
                 "websocket-terminal-delivery-timeout-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        endpoint: @public_responses_endpoint,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    stream = WebsocketBridgeStream.start("terminal-delivery-finalization", settle_timeout_ms: 20)
    stream_ref = stream.ref
    parent = self()

    :ok =
      WebsocketBridgeStream.arm(stream, nil, fn ->
        send(parent, {:bridge_submit_task, self()})

        receive do
          {:return_bridge_result, result} -> result
        end
      end)

    assert_receive {:bridge_submit_task, task_pid}, 2_000

    send(
      stream.relay,
      {:websocket_owner_frame, stream.correlation_id, nil,
       {:data, ~s({"type":"response.output_text.delta","delta":"visible"})}}
    )

    assert_receive {^stream_ref, {:preflight, :stream}}, 2_000
    assert_receive {^stream_ref, {:data, _data}}, 2_000

    lifecycle_id = Ecto.UUID.generate()

    send(
      task_pid,
      {:return_bridge_result,
       {:error,
        %{
          reason: :upstream_websocket_terminal_delivery_timeout,
          upstream_websocket_connection: %{
            lifecycle_id: lifecycle_id,
            generation: 2,
            reused: true,
            reconnected: false
          },
          transport_failure: %{
            "phase" => "terminal_delivery",
            "reason_class" => "owner_terminal_delivery_timeout",
            "reason" => "upstream_websocket_terminal_delivery_timeout",
            "pre_visible_output" => true,
            "upstream_committed" => true,
            "terminal_seen" => true,
            "terminal_forwarded" => false,
            "raw_frame" => "sentinel-frame",
            "raw_identity" => "sentinel-identity"
          }
        }}}
    )

    assert_receive {^stream_ref, {:bridge_error, :upstream_websocket_terminal_delivery_timeout}},
                   2_000

    body = public_response_visible_sse()

    state =
      request_options
      |> public_responses_stream_state(body)
      |> Map.put(
        :usage_observer,
        StreamUsageObserver.observe(StreamUsageObserver.new(), observer_usage_event([]))
      )

    response_context = %ResponseContext{
      context: context,
      response: %{sse_response() | body: stream}
    }

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, %{finalization_disposition: :inserted}} =
               Streaming.finalize_failure(
                 body,
                 {:upstream_stream_interrupted, :upstream_websocket_terminal_delivery_timeout},
                 response_context,
                 state
               )

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "http_sse",
                        upstream_transport: "websocket"
                      }}
    end)

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"
    assert attempt.usage_status == "usage_known"

    assert attempt.response_metadata["upstream_websocket_connection"] == %{
             "lifecycle_id" => lifecycle_id,
             "generation" => 2,
             "reused" => true,
             "reconnected" => false
           }

    transport_failure = attempt.response_metadata["transport_failure"]

    assert Map.take(transport_failure, [
             "phase",
             "reason_class",
             "reason",
             "pre_visible_output",
             "upstream_committed",
             "terminal_seen",
             "terminal_forwarded"
           ]) == %{
             "phase" => "terminal_delivery",
             "reason_class" => "owner_terminal_delivery_timeout",
             "reason" => "upstream_websocket_terminal_delivery_timeout",
             "pre_visible_output" => false,
             "upstream_committed" => true,
             "terminal_seen" => true,
             "terminal_forwarded" => false
           }

    assert transport_failure["text_frame_count"] == 2

    assert Repo.aggregate(
             from(l in CodexPooler.Accounting.LedgerEntry,
               where: l.request_id == ^request.id and l.entry_kind == "settlement"
             ),
             :count,
             :id
           ) == 1

    settlement =
      Repo.get_by!(CodexPooler.Accounting.LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement"
      )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 16
    assert settlement.output_tokens == 5
    assert settlement.total_tokens == 21
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
    assert Repo.reload!(setup.assignment).status == setup.assignment.status
    assert Repo.reload!(setup.identity).status == setup.identity.status

    metadata_text = inspect(attempt.response_metadata)
    refute metadata_text =~ "sentinel"
    refute metadata_text =~ "raw_frame"
    refute metadata_text =~ "raw_identity"

    assert WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream) == %{
             upstream_websocket_connection: nil,
             transport_failure: nil
           }
  end

  test "untagged Finch close records generic route health without transport metadata" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)

    request_options =
      request_options(auth, payload, setup,
        endpoint: @public_responses_endpoint,
        public_openai_responses_stream: true
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @public_responses_endpoint,
               transport: "http_sse",
               correlation_id:
                 "untagged-upstream-stream-interrupted-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        endpoint: @public_responses_endpoint,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt
      )

    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}

    assert {:ok, _finalized} =
             Streaming.finalize_failure(
               public_response_created_sse(),
               %Finch.TransportError{reason: :closed},
               response_context
             )

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"
    refute Map.has_key?(attempt.response_metadata, "transport_failure")

    assert Repo.aggregate(from(d in BridgeDemotion), :count) == 1
    assert Repo.aggregate(from(c in RoutingCircuitState), :count) == 1
  end

  test "terminal-missing upstream SSE close releases half-open route probe" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    circuit =
      %RoutingCircuitState{
        pool_id: auth.pool.id,
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.identity.id,
        model_identifier: setup.model.exposed_model_id,
        route_class: request_options.transport.route_class,
        status: "half_open",
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: DateTime.add(now, -120, :second),
        half_opened_at: now,
        metadata: %{"probe_in_flight_count" => 1},
        created_at: DateTime.add(now, -120, :second),
        updated_at: now
      }
      |> Repo.insert!()

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id:
                 "upstream-stream-neutral-probe-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    context =
      retry_context(setup, auth, request_options, reserved.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: attempt,
        routing_circuit_state: circuit,
        routing_circuit_admission: :probe
      )

    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}

    assert {:ok, _finalized} =
             Streaming.finalize_failure(
               "event: response.created\n\n",
               :upstream_stream_interrupted,
               response_context
             )

    assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"

    assert Repo.all(from(d in BridgeDemotion)) == []

    assert %RoutingCircuitState{} = updated = Repo.get!(RoutingCircuitState, circuit.id)
    assert updated.status == "half_open"
    assert updated.reason_code == "upstream_5xx"
    assert updated.failure_count == 3
    assert updated.success_count == 0
    assert updated.metadata["probe_in_flight_count"] == 0
  end

  test "terminal request rejects a late candidate retry and releases its half-open probe" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id:
                 "terminal-request-attempt-fence-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    assert {:ok, finalized} =
             Accounting.finalize_failure(reserved.request, attempt, %{
               response_status_code: 499,
               last_error_code: "owner_unavailable",
               usage_status: "usage_unknown"
             })

    circuit =
      %RoutingCircuitState{
        pool_id: auth.pool.id,
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.identity.id,
        model_identifier: setup.model.exposed_model_id,
        route_class: request_options.transport.route_class,
        status: "half_open",
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: DateTime.add(now, -120, :second),
        half_opened_at: now,
        metadata: %{"probe_in_flight_count" => 0},
        created_at: DateTime.add(now, -120, :second),
        updated_at: now
      }
      |> Repo.insert!()

    context =
      retry_context(setup, auth, request_options, finalized.request,
        candidates: [{setup.assignment, setup.identity}],
        attempt: nil
      )

    parent = self()

    assert {:error,
            %{
              status: 499,
              code: "request_already_finalized",
              message: "request lifecycle completed before upstream dispatch"
            }} =
             Dispatch.dispatch_from(context, 0, fn _context ->
               send(parent, :late_upstream_dispatch_called)
               {:ok, %{status: 200}}
             end)

    refute_received :late_upstream_dispatch_called

    assert Repo.aggregate(
             from(a in Attempt, where: a.request_id == ^reserved.request.id),
             :count,
             :id
           ) == 1

    updated = Repo.reload!(circuit)
    assert updated.status == "half_open"
    assert updated.metadata["probe_in_flight_count"] == 0
  end

  for {case_name, health_neutral_code, health_headers} <- [
        {"misalignment_policy_violation", "misalignment_policy_violation", %{}},
        {"server_error", "server_error", %{}},
        {"overloaded_error", "overloaded_error", %{}},
        {"server_is_overloaded", "server_is_overloaded", %{}},
        {"workspace_owner_credits_depleted", "workspace_owner_credits_depleted", %{}},
        {"workspace_member_credits_depleted", "workspace_member_credits_depleted", %{}},
        {"workspace_owner_credits_depleted header", "upstream_stream_error",
         %{
           "x-codex-rate-limit-reached-type" => ["workspace_owner_credits_depleted"]
         }},
        {"workspace_member_credits_depleted header", "upstream_stream_error",
         %{
           "x-codex-rate-limit-reached-type" => ["workspace_member_credits_depleted"]
         }}
      ] do
    @health_neutral_case {health_neutral_code, health_headers}
    test "health-neutral terminal SSE failure #{case_name} releases half-open route probe" do
      {health_neutral_code, health_headers} = @health_neutral_case

      {setup, _first_upstream, _second_upstream} =
        stream_retry_setup(
          FakeUpstream.sse_stream([]),
          FakeUpstream.sse_stream([])
        )

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      payload = payload(setup)
      request_options = request_options(auth, payload, setup)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      circuit =
        %RoutingCircuitState{
          pool_id: auth.pool.id,
          pool_upstream_assignment_id: setup.assignment.id,
          upstream_identity_id: setup.identity.id,
          model_identifier: setup.model.exposed_model_id,
          route_class: request_options.transport.route_class,
          status: "half_open",
          reason_code: "upstream_5xx",
          failure_count: 3,
          success_count: 0,
          opened_at: DateTime.add(now, -120, :second),
          half_opened_at: now,
          metadata: %{"probe_in_flight_count" => 1},
          created_at: DateTime.add(now, -120, :second),
          updated_at: now
        }
        |> Repo.insert!()

      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_sse",
                 correlation_id:
                   "terminal-#{health_neutral_code}-probe-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      context =
        retry_context(setup, auth, request_options, reserved.request,
          candidates: [{setup.assignment, setup.identity}],
          attempt: attempt,
          routing_circuit_state: circuit,
          routing_circuit_admission: :probe
        )

      response_context = %ResponseContext{
        context: context,
        response: %Req.Response{status: 200, headers: health_headers}
      }

      assert {:ok, _finalized} =
               Streaming.finalize_failure(
                 ~s(event: response.failed\ndata: {"type":"response.failed"}\n\n),
                 {:terminal_stream_failure,
                  %{
                    code: health_neutral_code,
                    upstream_code: nil,
                    upstream_error_param: "reasoning.summary",
                    event_type: "response.failed"
                  }},
                 response_context
               )

      assert [request] = Repo.all(from(r in Request, where: r.id == ^reserved.request.id))
      assert request.status == "failed"
      assert request.last_error_code == health_neutral_code

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "failed"
      assert attempt.network_error_code == health_neutral_code

      if health_neutral_code == MisalignmentPolicyViolation.code() do
        assert attempt.error_message == MisalignmentPolicyViolation.fallback_message()
        refute Map.has_key?(attempt.response_metadata, "upstream_error_param")

        assert Repo.aggregate(
                 from(entry in CodexPooler.Accounting.LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 ),
                 :count,
                 :id
               ) == 1
      else
        assert attempt.response_metadata["upstream_error_param"] == "reasoning.summary"
      end

      assert Repo.all(from(d in BridgeDemotion)) == []

      assert %RoutingCircuitState{} = updated = Repo.get!(RoutingCircuitState, circuit.id)
      assert updated.status == "half_open"
      assert updated.reason_code == "upstream_5xx"
      assert updated.failure_count == 3
      assert updated.success_count == 0
      assert updated.metadata["probe_in_flight_count"] == 0
    end
  end

  defp retry_context(setup, auth, request_options, request, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, @endpoint_path)

    candidates =
      Keyword.get(opts, :candidates, [
        {setup.assignment, setup.identity},
        {setup.fallback_assignment, setup.fallback_identity}
      ])

    %SelectedCandidateContext{
      auth: auth,
      endpoint: endpoint,
      payload: payload(setup),
      model: setup.model,
      reserved: %{request: request},
      request_options: request_options,
      route_plan:
        BridgeRing.plan_route(%{
          auth: auth,
          model: setup.model,
          candidates: candidates,
          route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
          request_options: request_options
        }),
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: true,
      routing_attempt_metadata: %{},
      route_class: request_options.transport.route_class,
      routing_circuit_state: Keyword.get(opts, :routing_circuit_state),
      routing_circuit_admission: Keyword.get(opts, :routing_circuit_admission),
      attempt: Keyword.get(opts, :attempt),
      started: System.monotonic_time(:millisecond)
    }
  end

  defp arm_replay_generation_cutover!(setup, auth, request_options, request, attempt) do
    assert {:ok, session} = Websocket.start_codex_session(auth, request_options)

    request_options =
      RequestOptions.put_continuity(request_options, semantic_turn_key: <<1::256>>)

    assert {:ok, turn} = Websocket.start_codex_turn(session, request, request_options)
    session = Repo.reload!(session)

    reservation =
      Repo.one!(
        from entry in CodexPooler.Accounting.LedgerEntry,
          where: entry.request_id == ^request.id and entry.entry_kind == "reservation"
      )

    assert reservation.request_id == request.id

    assert {:ok, _armed} =
             RequestReplay.arm(%{
               api_key_id: auth.api_key.id,
               pool_id: auth.pool.id,
               codex_session_id: session.id,
               request_id: request.id,
               codex_turn_id: turn.id,
               eligible_attempt_id: attempt.id,
               api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch,
               model_id: setup.model.id,
               model_identifier: setup.model.exposed_model_id,
               endpoint: request.endpoint,
               semantic_turn_digest: <<1::256>>,
               replay_claim_digest: <<2::256>>,
               owner_instance_id: session.owner_instance_id,
               owner_lease_token: session.owner_lease_token,
               predecessor_epoch: 1,
               failure_reason: :client_disconnected,
               pre_visible_output: true
             })
  end

  defp install_started_generation_one!(setup, auth, request_options, reserved, attempt) do
    assert {:ok, session} = Websocket.start_codex_session(auth, request_options)

    request_options =
      RequestOptions.put_continuity(request_options, semantic_turn_key: <<1::256>>)

    assert {:ok, turn} = Websocket.start_codex_turn(session, reserved.request, request_options)
    session = Repo.reload!(session)

    assert {:ok, armed} =
             RequestReplay.arm(%{
               api_key_id: auth.api_key.id,
               pool_id: auth.pool.id,
               codex_session_id: session.id,
               request_id: reserved.request.id,
               codex_turn_id: turn.id,
               eligible_attempt_id: attempt.id,
               api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch,
               model_id: setup.model.id,
               model_identifier: setup.model.exposed_model_id,
               endpoint: reserved.request.endpoint,
               semantic_turn_digest: <<1::256>>,
               replay_claim_digest: <<2::256>>,
               owner_instance_id: session.owner_instance_id,
               owner_lease_token: session.owner_lease_token,
               predecessor_epoch: 1,
               failure_reason: :client_disconnected,
               pre_visible_output: true
             })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    replay_attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(reserved.request, setup.assignment, %{
        attempt_number: attempt.attempt_number + 1,
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })
      |> Ecto.Changeset.change(%{model_id: setup.model.id, replay_generation: 1})
      |> Repo.update!()

    entitlement =
      Repo.get!(RequestReplayEntitlement, armed.entitlement_id)

    entitlement
    |> RequestReplayEntitlement.changeset(%{
      status: "consumed",
      replay_attempt_id: replay_attempt.id,
      provisional_binding_digest: <<3::256>>,
      consumed_at: now,
      started_at: now,
      last_liveness_at: now,
      abandon_at: DateTime.add(now, 60, :second)
    })
    |> Repo.update!()

    replay_attempt
  end

  defp payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("stream lifecycle accounting regression"),
      "stream" => true
    }
  end

  defp stream_success_sse(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
         }
       }}
    ])
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

  defp backend_response_success_sse(response_id) do
    ~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"#{response_id}","usage":{"input_tokens":4,"output_tokens":3,"total_tokens":7}}}\n\n) <>
      "data: [DONE]\n\n"
  end

  defp replay_rate_limit_headers(used_percent) do
    reset_at = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)

    [
      {"x-codex-primary-used-percent", [used_percent]},
      {"x-codex-primary-window-minutes", ["300"]},
      {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]}
    ]
  end

  defp replay_rate_limit_error(used_percent) do
    %{
      "error" => %{
        "code" => "rate_limit_exceeded",
        "limit_id" => "codex",
        "window_kind" => "primary",
        "window_minutes" => "300",
        "used_percent" => used_percent,
        "reset_after_seconds" => "900"
      }
    }
  end

  defp replay_rate_limit_sse(used_percent) do
    reset_at = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)

    event = %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => used_percent,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }

    "event: codex.rate_limits\ndata: #{Jason.encode!(event)}\n\n"
  end

  defp stale_invalid_response(:invalid_json, context) do
    {%Req.Response{status: 200, headers: [{"content-type", ["application/json"]}], body: "{"},
     Map.put(context, :payload, Map.put(context.payload, "stream", false))}
  end

  defp stale_invalid_response(:invalid_compaction, context) do
    request_options =
      context.request_options
      |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)
      |> RequestOptions.put_payload_context(
        compaction_trigger_bridge?: true,
        compaction_result_mode: :native_websocket
      )

    request_options = %{
      request_options
      | payload_context: %{request_options.payload_context | compaction_input_mode: :incremental}
    }

    {%Req.Response{
       status: 200,
       headers: [{"content-type", ["application/json"]}],
       body: Jason.encode!(%{"status" => "completed", "output" => []})
     },
     %{
       context
       | request_options: request_options,
         payload: Map.put(context.payload, "stream", false)
     }}
  end

  defp retryable_first_event_sse do
    ~s(event: response.failed\ndata: {"type":"response.failed","error":{"code":"server_error"}}\n\n)
  end

  defp replay_quota_observations(identity) do
    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.filter(
      &(&1.source in [
          "codex_response_headers",
          "codex_rate_limit_event",
          "codex_rate_limit_error"
        ])
    )
  end

  defp delete_replay_quota_observations(identity) do
    sources = ["codex_response_headers", "codex_rate_limit_event", "codex_rate_limit_error"]

    Repo.delete_all(
      from window in CodexPooler.Upstreams.Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id and window.source in ^sources
    )

    :ok
  end

  defp half_open_replay_circuit!(setup, request_options) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RoutingCircuitState{
      pool_id: setup.pool.id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      model_identifier: setup.model.exposed_model_id,
      route_class: request_options.transport.route_class,
      status: "half_open",
      reason_code: "upstream_5xx",
      failure_count: 3,
      success_count: 0,
      opened_at: DateTime.add(now, -120, :second),
      half_opened_at: now,
      metadata: %{"probe_in_flight_count" => 1},
      created_at: DateTime.add(now, -120, :second),
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp async_sse_response(ref, headers) do
    %Req.Response{
      status: 200,
      headers: [{"content-type", ["text/event-stream"]} | headers],
      body: %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: &parse_async_message/2,
        cancel_fun: fn _ref -> :ok end
      }
    }
  end

  defp parse_async_message(ref, {ref, {:data, data}}), do: {:ok, data: data}
  defp parse_async_message(ref, {ref, :done}), do: {:ok, [:done]}
  defp parse_async_message(ref, {ref, {:error, reason}}), do: {:error, reason}
  defp parse_async_message(_ref, _message), do: :unknown

  defp misalignment_terminal_sse(message) do
    error = %{
      "code" => MisalignmentPolicyViolation.code(),
      "message" => message,
      "param" => "private.param",
      "provider_sibling" => "private-sibling"
    }

    ~s(event: response.failed\ndata: #{Jason.encode!(%{"type" => "response.failed", "error" => error, "response" => %{"status" => "failed", "error" => error}})}\n\n)
  end

  defp misalignment_half_open_circuit!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RoutingCircuitState{
      pool_id: setup.pool.id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      model_identifier: setup.model.exposed_model_id,
      route_class: "proxy_stream",
      status: "half_open",
      reason_code: "upstream_5xx",
      failure_count: 3,
      success_count: 0,
      opened_at: DateTime.add(now, -120, :second),
      half_opened_at: now,
      metadata: %{"probe_in_flight_count" => 0},
      created_at: DateTime.add(now, -120, :second),
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp execute_misalignment_stream(setup, request_suffix) do
    with {:ok, stream} <- prepare_misalignment_stream(setup, request_suffix) do
      run_misalignment_stream(stream)
    end
  end

  defp prepare_misalignment_stream(setup, request_suffix) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_payload = payload(setup)

    assert {:ok, %{stream: stream}} =
             Gateway.execute(
               auth,
               @endpoint_path,
               request_payload,
               RequestOptions.build(
                 %{
                   request_id: deterministic_rotation_seed(2, 0),
                   upstream_endpoint: @endpoint_path,
                   correlation_id:
                     "misalignment-#{request_suffix}-#{System.unique_integer([:positive])}"
                 },
                 @endpoint_path,
                 request_payload
               )
             )

    {:ok, stream}
  end

  defp run_misalignment_stream(stream) do
    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    stream.(stream_conn)
  end

  defp assert_misalignment_stream_finalized!(setup, circuit, provider_message) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == MisalignmentPolicyViolation.code()

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    refute attempt.retryable
    assert attempt.network_error_code == MisalignmentPolicyViolation.code()
    assert attempt.error_message == MisalignmentPolicyViolation.fallback_message()
    refute Map.has_key?(attempt.response_metadata, "upstream_error_param")

    refute inspect({request.request_metadata, attempt.response_metadata}) =~ provider_message

    assert Repo.aggregate(
             from(entry in CodexPooler.Accounting.LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count,
             :id
           ) == 1

    assert Repo.all(from(d in BridgeDemotion)) == []

    updated = Repo.reload!(circuit)
    assert updated.status == "half_open"
    assert updated.reason_code == "upstream_5xx"
    assert updated.failure_count == 3
    assert updated.success_count == 0
    assert updated.metadata["probe_in_flight_count"] == 0
  end

  defp public_response_created_sse do
    ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_public_stream_interrupted"}}\n\n)
  end

  defp public_response_visible_sse do
    ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_public_summary"}}\n\n) <>
      ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"visible"}\n\n)
  end

  defp public_response_success_sse do
    public_response_visible_sse() <>
      ~s(event: response.output_text.done\ndata: {"type":"response.output_text.done","text":"visible"}\n\n) <>
      ~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_public_summary","status":"completed","usage":{"input_tokens":4,"output_tokens":3,"total_tokens":7}}}\n\n)
  end

  defp observer_usage_event(tail) do
    usage = %{
      "input_tokens" => 16,
      "cached_input_tokens" => 0,
      "output_tokens" => 5,
      "reasoning_tokens" => 0,
      "total_tokens" => 21
    }

    "event: response.in_progress\ndata: " <>
      ~s({"type":"response.in_progress","response":{"usage":) <>
      Jason.encode!(usage) <>
      ~s(,"output":#{Jason.encode!(tail)}}}) <>
      "\n\n"
  end

  defp public_responses_stream_state(request_options, body) do
    state = DownstreamStream.initial_state(:relay, request_options)

    {_data, state} =
      DownstreamStream.normalize_data(body, @public_responses_endpoint, request_options, state)

    state
  end

  defp sse_response do
    %Req.Response{status: 200, headers: [{"content-type", ["text/event-stream"]}]}
  end

  defp finalization_callbacks do
    %{
      register_continuity: fn _request_options, _payload, _body -> :ok end,
      stream_result: fn _response, _context -> :ok end
    }
  end

  defp capture_stream_finalization_telemetry(fun) do
    handler_id = "stream-lifecycle-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :finalization],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_finalization, metadata})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp capture_stream_outcome_telemetry(fun) do
    handler_id = "stream-outcome-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp execute_backend_stream(setup, release_ref, _request_suffix, opts \\ []) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             Gateway.execute(
               auth,
               @endpoint_path,
               payload(setup),
               RequestOptions.build(
                 %{
                   request_id: deterministic_rotation_seed(2, 0),
                   upstream_endpoint: @endpoint_path,
                   receive_timeout: 100
                 },
                 @endpoint_path,
                 payload(setup)
               )
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)

    if Keyword.get(opts, :wait_for_barrier?, true) do
      assert_receive {:fake_upstream_timeout_barrier, _stage, upstream_pid, ^release_ref}, 1_000
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    end

    {:ok, stream_conn}
  end

  defp assert_pre_first_stall_finalized!(setup, input) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_idle_timeout"
    assert request.retry_count == 0

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_idle_timeout"
    assert attempt.error_message == "upstream stream idle timeout"
    assert attempt.response_metadata["error_kind"] == "stream_interrupted"
    refute Map.has_key?(attempt.response_metadata, "stream_failure_stage")
    refute Map.has_key?(attempt.response_metadata, "stream_terminal_type")
    refute Map.has_key?(attempt.response_metadata, "stream_error_code")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ input
    refute metadata_text =~ "data:"
    refute metadata_text =~ "response.created"
    refute metadata_text =~ "response.failed"
    refute metadata_text =~ "resp_raw_partial_stall"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
    refute metadata_text =~ "auth.json"
  end

  defp request_options(auth, payload, setup, opts \\ []) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    endpoint = Keyword.get(opts, :endpoint, @endpoint_path)

    option_attrs =
      opts
      |> Keyword.drop([:endpoint, :websocket?])
      |> Map.new()

    options =
      %{
        request_id: "stream-lifecycle-#{System.unique_integer([:positive])}",
        upstream_endpoint: endpoint
      }
      |> Map.merge(option_attrs)

    options =
      if Keyword.get(opts, :websocket?, false) do
        RequestOptions.for_websocket(options, payload)
      else
        RequestOptions.build(options, endpoint, payload)
      end

    options
    |> RequestOptions.put_routing(
      requested_model: setup.model.exposed_model_id,
      effective_model: setup.model.exposed_model_id,
      api_key_policy: policy
    )
  end

  defp invalid_request(id) do
    %{
      id: id,
      correlation_id: "stream-lifecycle-#{System.unique_integer([:positive])}"
    }
  end
end
