defmodule CodexPooler.Gateway.Runtime.Streaming.StreamLifecycleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [deterministic_rotation_seed: 2, stream_retry_setup: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}

  alias CodexPooler.Gateway.Runtime.Dispatch.{
    ResponseContext,
    RouteState,
    SelectedCandidateContext
  }

  alias CodexPooler.Gateway.Runtime.Finalization.Streaming
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector
  alias CodexPooler.Gateway.Runtime.Streaming.StreamDispatch
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Repo

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
               transport: "http_sse",
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
    state = public_responses_stream_state(request_options, body)
    response_context = %ResponseContext{context: context, response: sse_response()}

    assert {:ok, _finalized} =
             Streaming.finalize_success(body, response_context, finalization_callbacks(), state)

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^reserved.request.id))
    assert attempt.status == "succeeded"
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
        routing_circuit_state: circuit
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

  for health_neutral_code <- ["server_error", "overloaded_error", "server_is_overloaded"] do
    @health_neutral_code health_neutral_code
    test "health-neutral terminal SSE failure #{health_neutral_code} releases half-open route probe" do
      health_neutral_code = @health_neutral_code

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
          routing_circuit_state: circuit
        )

      response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}

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
      assert attempt.response_metadata["upstream_error_param"] == "reasoning.summary"

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
      attempt: Keyword.get(opts, :attempt),
      started: System.monotonic_time(:millisecond)
    }
  end

  defp payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "stream lifecycle accounting regression",
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

  defp backend_response_success_sse(response_id) do
    ~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"#{response_id}","usage":{"input_tokens":4,"output_tokens":3,"total_tokens":7}}}\n\n) <>
      "data: [DONE]\n\n"
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
