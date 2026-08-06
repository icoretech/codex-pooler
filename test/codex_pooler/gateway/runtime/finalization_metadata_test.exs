defmodule CodexPooler.Gateway.Runtime.FinalizationMetadataCompressionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]

  test "HTTP attempt metadata includes safe payload compression savings" do
    sensitive_placeholder =
      "placeholder raw tool output with bearer example-token and private prompt text"

    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression:
          compression_metadata(%{
            "raw_candidate" => sensitive_placeholder,
            "call_id" => "call_sensitive_placeholder",
            "json_path" => "$.input[0].output"
          })
      )

    response = %Req.Response{
      status: 200,
      headers: [
        {"content-type", ["application/json"]},
        {"x-request-id", ["req_payload_compression"]}
      ]
    }

    metadata = Metadata.response_metadata(response, nil, options)

    assert metadata["payload_compression"] == expected_compression_metadata()

    assert Metadata.request_metadata(options) == %{
             "payload_compression" => metadata["payload_compression"]
           }

    metadata_text = inspect(metadata["payload_compression"])
    refute metadata_text =~ sensitive_placeholder
    refute metadata_text =~ "call_sensitive_placeholder"
    refute metadata_text =~ "$.input[0].output"
  end

  test "HTTP finalization allowlists payload compression strategy metadata" do
    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression:
          compression_metadata(%{
            "strategies" => [
              "log_output",
              "call_probe_secret",
              "json_document_lossless",
              "json_array_lossless"
            ],
            "candidate_count" => 1
          })
      )

    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}
    metadata = Metadata.response_metadata(response, nil, options)

    assert metadata["payload_compression"]["strategies"] == [
             "log_output",
             "json_document_lossless",
             "json_array_lossless"
           ]

    refute inspect(metadata["payload_compression"]) =~ "call_probe_secret"
  end

  test "HTTP finalization keeps tokenizer input limit metadata without raw skipped content" do
    sensitive_placeholder = "placeholder skipped tokenizer input body"

    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression: %{
          "attempted" => true,
          "status" => "skipped",
          "reason" => "tokenizer_input_limit",
          "candidate_count" => 2,
          "compressed_count" => 0,
          "skipped_count" => 2,
          "tokenizer_input_skipped_count" => 2,
          "raw_candidate" => sensitive_placeholder
        }
      )

    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}
    metadata = Metadata.response_metadata(response, nil, options)

    assert metadata["payload_compression"] == %{
             "attempted" => true,
             "status" => "skipped",
             "reason" => "tokenizer_input_limit",
             "candidate_count" => 2,
             "compressed_count" => 0,
             "skipped_count" => 2,
             "tokenizer_input_skipped_count" => 2
           }

    assert Metadata.request_metadata(options) == %{
             "payload_compression" => metadata["payload_compression"]
           }

    refute inspect(metadata["payload_compression"]) =~ sensitive_placeholder
  end

  test "websocket attempt metadata includes safe payload compression savings" do
    options =
      request_options()
      |> RequestOptions.for_websocket(%{"model" => "example-model"})
      |> RequestOptions.put_runtime_context(payload_compression: compression_metadata())

    metadata =
      Metadata.websocket_response_metadata(
        [{"openai-request-id", "req_payload_compression_ws"}],
        nil,
        options
      )

    assert metadata["payload_compression"] == expected_compression_metadata()
    assert metadata["upstream_transport"] == "websocket"
  end

  test "payload compression ratios are omitted when denominators are zero" do
    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression: %{
          "attempted" => true,
          "status" => "no_change",
          "reason" => "no_token_shrink",
          "original_bytes" => 0,
          "compressed_bytes" => 0,
          "original_tokens" => 0,
          "compressed_tokens" => 0
        }
      )

    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}
    metadata = Metadata.response_metadata(response, nil, options)["payload_compression"]

    assert metadata["saved_bytes"] == 0
    assert metadata["saved_tokens"] == 0
    refute Map.has_key?(metadata, "byte_savings_ratio")
    refute Map.has_key?(metadata, "byte_savings_percent")
    refute Map.has_key?(metadata, "token_savings_ratio")
    refute Map.has_key?(metadata, "token_savings_percent")
    refute Map.has_key?(metadata, "compression_ratio")
  end

  test "payload compression metadata stays absent when compression was not attempted" do
    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}

    without_metadata = request_options()

    not_attempted =
      RequestOptions.put_runtime_context(without_metadata,
        payload_compression: %{"enabled" => true, "attempted" => false, "status" => "disabled"}
      )

    refute Map.has_key?(
             Metadata.response_metadata(response, nil, without_metadata),
             "payload_compression"
           )

    refute Map.has_key?(
             Metadata.websocket_response_metadata([], nil, without_metadata),
             "payload_compression"
           )

    assert Metadata.request_metadata(without_metadata) == %{}

    refute Map.has_key?(
             Metadata.response_metadata(response, nil, not_attempted),
             "payload_compression"
           )

    assert Metadata.request_metadata(not_attempted) == %{}
  end

  @tag :prompt_cache_adaptation
  test "post-serialization dispatch failure persists only prompt cache adaptation metadata" do
    setup = accounting_setup()
    payload = %{"model" => setup.model.exposed_model_id}

    assert {:ok, reserved} =
             Accounting.reserve(setup.auth, setup.model, payload, %{
               endpoint: "/backend-api/codex/responses",
               transport: "http_json",
               correlation_id:
                 "prompt-cache-dispatch-error-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    request_options =
      %{
        transport: "http_json",
        upstream_endpoint: "/backend-api/codex/responses"
      }
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.put_runtime_context(prompt_cache_controls_downgraded: true)

    context = %SelectedCandidateContext{
      auth: setup.auth,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      model: setup.model,
      reserved: reserved,
      request_options: request_options,
      route_plan:
        BridgeRing.plan_route(%{
          auth: setup.auth,
          model: setup.model,
          candidates: [{setup.assignment, setup.identity}],
          route_plan_input: RoutePlanInput.from_reserved(reserved),
          request_options: request_options
        }),
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: "proxy_http",
      attempt: attempt,
      started: System.monotonic_time(:millisecond)
    }

    assert {:error, %{status: 502}} =
             Finalization.handle_dispatch_error(:synthetic_network_failure, context, 7)

    attempt = Repo.get!(Attempt, attempt.id)

    assert attempt.response_metadata["prompt_cache_controls_downgraded"] == true

    refute Map.has_key?(
             Repo.get!(Request, reserved.request.id).request_metadata,
             "prompt_cache_controls_downgraded"
           )
  end

  test "terminal websocket failure settles once with the sanitized local guard diagnostic" do
    setup = accounting_setup()
    payload = %{"model" => setup.model.exposed_model_id, "stream" => true}

    assert {:ok, reserved} =
             Accounting.reserve(setup.auth, setup.model, payload, %{
               endpoint: "/backend-api/codex/responses",
               transport: "websocket",
               correlation_id:
                 "continuation-guard-finalization-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    circuit =
      %RoutingCircuitState{
        pool_id: setup.auth.pool.id,
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.identity.id,
        model_identifier: setup.model.exposed_model_id,
        route_class: "proxy_websocket",
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

    request_options =
      %{
        request_id: "continuation-guard-finalization",
        upstream_endpoint: "/backend-api/codex/responses"
      }
      |> RequestOptions.for_websocket(payload)

    context = %SelectedCandidateContext{
      auth: setup.auth,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      model: setup.model,
      reserved: reserved,
      request_options: request_options,
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: true,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      routing_circuit_state: circuit,
      attempt: attempt,
      started: System.monotonic_time(:millisecond)
    }

    raw_sentinel = "caller-controlled-terminal-sentinel"

    terminal_result = %{
      body: ~s(data: {"type":"error","error":{"code":"previous_response_not_found"}}\n\n),
      terminal: "error",
      status: 200,
      headers: [],
      started: System.monotonic_time(:millisecond),
      upstream_error_code: "previous_response_not_found",
      upstream_error_param: raw_sentinel,
      transport_failure: %{
        "reason" => "previous_response_generation_mismatch",
        "reason_class" => "previous_response_generation_mismatch",
        "phase" => "send_payload",
        "termination_source" => "continuation_generation_guard",
        "connection_use" => "fresh",
        "pre_visible_output" => true,
        "upstream_committed" => false,
        "terminal_seen" => false,
        "text_frame_count" => 0,
        "previous_response_id" => raw_sentinel,
        "message" => raw_sentinel,
        "raw_frame" => raw_sentinel
      }
    }

    assert {:ok, %{status: 200, websocket_messages: []}} =
             Finalization.finalize_terminal_websocket_response(context, terminal_result)

    request = Repo.get!(Request, reserved.request.id)
    attempt = Repo.get!(Attempt, attempt.id)

    assert request.status == "failed"
    assert request.last_error_code == "stream_incomplete"
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["upstream_error_param"] == "previous_response_id"

    assert attempt.response_metadata["transport_failure"] == %{
             "connection_use" => "fresh",
             "phase" => "send_payload",
             "pre_visible_output" => true,
             "reason" => "previous_response_generation_mismatch",
             "reason_class" => "previous_response_generation_mismatch",
             "termination_source" => "continuation_generation_guard",
             "terminal_seen" => false,
             "text_frame_count" => 0,
             "upstream_committed" => false
           }

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.all(from(demotion in BridgeDemotion)) == []

    updated_circuit = Repo.get!(RoutingCircuitState, circuit.id)
    assert updated_circuit.status == "half_open"
    assert updated_circuit.reason_code == "upstream_5xx"
    assert updated_circuit.failure_count == 3
    assert updated_circuit.success_count == 0
    assert updated_circuit.metadata["probe_in_flight_count"] == 0

    refute inspect({request.request_metadata, attempt.response_metadata}) =~ raw_sentinel
  end

  test "exact previous response miss fixes the param when guard metadata is stale" do
    setup = accounting_setup()
    payload = %{"model" => setup.model.exposed_model_id, "stream" => true}

    assert {:ok, reserved} =
             Accounting.reserve(setup.auth, setup.model, payload, %{
               endpoint: "/backend-api/codex/responses",
               transport: "websocket",
               correlation_id: "continuation-guard-stale-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    request_options =
      RequestOptions.for_websocket(
        %{
          request_id: "continuation-guard-stale",
          upstream_endpoint: "/backend-api/codex/responses"
        },
        payload
      )

    context = %SelectedCandidateContext{
      auth: setup.auth,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      model: setup.model,
      reserved: reserved,
      request_options: request_options,
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: true,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      attempt: attempt,
      started: System.monotonic_time(:millisecond)
    }

    raw_sentinel = "caller-controlled-stale-guard-sentinel"

    assert {:ok, %{status: 200, websocket_messages: []}} =
             Finalization.finalize_terminal_websocket_response(context, %{
               body:
                 ~s(data: {"type":"error","error":{"code":"previous_response_not_found"}}\n\n),
               terminal: "error",
               status: 200,
               headers: [],
               started: System.monotonic_time(:millisecond),
               upstream_error_code: "previous_response_not_found",
               upstream_error_param: raw_sentinel,
               transport_failure: %{
                 "connection_use" => "reused",
                 "phase" => "receive",
                 "pre_visible_output" => false,
                 "reason" => "previous_response_generation_mismatch",
                 "reason_class" => raw_sentinel,
                 "termination_source" => "continuation_generation_guard",
                 "terminal_seen" => true,
                 "text_frame_count" => 99,
                 "upstream_committed" => true,
                 "previous_response_id" => raw_sentinel,
                 "message" => raw_sentinel,
                 "raw_frame" => raw_sentinel
               }
             })

    request = Repo.get!(Request, reserved.request.id)
    attempt = Repo.get!(Attempt, attempt.id)

    assert request.status == "failed"
    assert request.last_error_code == "stream_incomplete"
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["upstream_error_param"] == "previous_response_id"
    refute Map.has_key?(attempt.response_metadata, "transport_failure")

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.all(from(demotion in BridgeDemotion)) == []
    refute inspect({request.request_metadata, attempt.response_metadata}) =~ raw_sentinel
  end

  test "terminal websocket finalization rejects a valid guard map for another terminal code" do
    setup = accounting_setup()
    payload = %{"model" => setup.model.exposed_model_id, "stream" => true}

    assert {:ok, reserved} =
             Accounting.reserve(setup.auth, setup.model, payload, %{
               endpoint: "/backend-api/codex/responses",
               transport: "websocket",
               correlation_id:
                 "continuation-guard-near-miss-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    request_options =
      RequestOptions.for_websocket(
        %{
          request_id: "continuation-guard-near-miss",
          upstream_endpoint: "/backend-api/codex/responses"
        },
        payload
      )

    context = %SelectedCandidateContext{
      auth: setup.auth,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      model: setup.model,
      reserved: reserved,
      request_options: request_options,
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: true,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      attempt: attempt,
      started: System.monotonic_time(:millisecond)
    }

    assert {:ok, %{status: 200}} =
             Finalization.finalize_terminal_websocket_response(context, %{
               body: ~s(data: {"type":"error","error":{"code":"server_error"}}\n\n),
               terminal: "error",
               status: 200,
               headers: [],
               started: System.monotonic_time(:millisecond),
               upstream_error_code: "server_error",
               upstream_error_param: "reasoning.summary",
               transport_failure: %{
                 "connection_use" => "fresh",
                 "phase" => "send_payload",
                 "pre_visible_output" => true,
                 "reason" => "previous_response_generation_mismatch",
                 "reason_class" => "previous_response_generation_mismatch",
                 "termination_source" => "continuation_generation_guard",
                 "terminal_seen" => false,
                 "text_frame_count" => 0,
                 "upstream_committed" => false
               }
             })

    attempt = Repo.get!(Attempt, attempt.id)
    refute Map.has_key?(attempt.response_metadata, "transport_failure")
    assert attempt.response_metadata["upstream_error_param"] == "reasoning.summary"
  end

  defp request_options do
    RequestOptions.build(
      %{transport: "http_json", upstream_endpoint: "/backend-api/codex/responses"},
      "/backend-api/codex/responses",
      %{"model" => "example-model"}
    )
  end

  defp compression_metadata(extra \\ %{}) do
    Map.merge(
      %{
        "enabled" => true,
        "attempted" => true,
        "status" => "compressed",
        "route_class" => "proxy_stream",
        "transport" => "http",
        "tokenizer" => "local:o200k_base",
        "candidate_count" => 3,
        "compressed_count" => 2,
        "skipped_count" => 1,
        "original_bytes" => 1200,
        "compressed_bytes" => 300,
        "original_tokens" => 600,
        "compressed_tokens" => 150,
        "strategies" => ["log_output", "diff"],
        "elapsed_ms" => 5
      },
      extra
    )
  end

  defp expected_compression_metadata do
    %{
      "enabled" => true,
      "attempted" => true,
      "status" => "compressed",
      "route_class" => "proxy_stream",
      "transport" => "http",
      "tokenizer" => "local:o200k_base",
      "candidate_count" => 3,
      "compressed_count" => 2,
      "skipped_count" => 1,
      "original_bytes" => 1200,
      "compressed_bytes" => 300,
      "saved_bytes" => 900,
      "byte_savings_ratio" => 0.75,
      "byte_savings_percent" => 75.0,
      "compression_ratio" => 0.25,
      "original_tokens" => 600,
      "compressed_tokens" => 150,
      "saved_tokens" => 450,
      "token_savings_ratio" => 0.75,
      "token_savings_percent" => 75.0,
      "strategies" => ["log_output", "diff"],
      "elapsed_ms" => 5
    }
  end
end
