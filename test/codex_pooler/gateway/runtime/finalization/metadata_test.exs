defmodule CodexPooler.Gateway.Runtime.Finalization.MetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Transports.BoundedResponseBody

  test "classifies only resolved Full ordinary Responses HTTP rejections" do
    ordinary_endpoints = [
      "/backend-api/codex/responses",
      "/backend-api/codex/v1/responses",
      "/backend-api/codex/v1/chat/completions",
      "/v1/responses",
      "/v1/chat/completions"
    ]

    for endpoint <- ordinary_endpoints do
      options =
        %{}
        |> RequestOptions.build(endpoint, %{"model" => "example-model"})
        |> RequestOptions.put_model_serving_mode(
          configured_mode: "full",
          effective_mode: "full",
          source: "override"
        )

      assert Metadata.upstream_status_error_code(400, options) ==
               "full_upstream_rejection"

      assert Metadata.upstream_status_error_code(429, options) ==
               "upstream_rate_limited"
    end

    full_options =
      %{}
      |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
      |> RequestOptions.put_model_serving_mode(
        configured_mode: "auto",
        effective_mode: "full",
        source: "catalog"
      )

    lite_options =
      %{}
      |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
      |> RequestOptions.put_model_serving_mode(
        configured_mode: "auto",
        effective_mode: "lite",
        source: "catalog"
      )

    compact_full_options =
      %{}
      |> RequestOptions.build("/backend-api/codex/responses/compact", %{
        "model" => "example-model"
      })
      |> RequestOptions.put_model_serving_mode(
        configured_mode: "full",
        effective_mode: "full",
        source: "override"
      )

    translated_compact_full_options =
      compact_full_options
      |> RequestOptions.mark_openai_compatibility_origin(
        "/v1/responses",
        "/backend-api/codex/responses/compact"
      )

    unresolved_options =
      RequestOptions.build(
        %{},
        "/backend-api/codex/responses",
        %{"model" => "example-model"}
      )

    assert Metadata.upstream_status_error_code(400, lite_options) == "upstream_status"
    assert Metadata.upstream_status_error_code(400, compact_full_options) == "upstream_status"

    assert Metadata.upstream_status_error_code(400, translated_compact_full_options) ==
             "upstream_status"

    assert Metadata.upstream_status_error_code(400, unresolved_options) == "upstream_status"
    assert Metadata.upstream_status_error_code(400, full_options) == "upstream_status"
    assert Metadata.upstream_status_error_code(200, full_options) == "upstream_status"

    assert Metadata.upstream_status_error_code(400, %{
             transport: %{upstream_endpoint: "/backend-api/codex/responses"},
             model_serving_mode: "full",
             error: "untrusted upstream text"
           }) == "upstream_status"
  end

  test "characterization preserves existing websocket response metadata output" do
    frame_headers = %{
      "openai-request-id" => "frame-request-characterization",
      "x-codex-primary-reset-at" => "2026-05-25T13:00:00Z"
    }

    assert Metadata.websocket_response_metadata(
             [
               {"openai-request-id", "upgrade-request-characterization"},
               {"x-codex-rate-limit-reached-type", "workspace_owner_usage_limit_reached"}
             ],
             "rate_limit_exceeded",
             %{},
             frame_headers
           ) == %{
             "content_type" => "application/json",
             "error_kind" => "rate_limit_exceeded",
             "rate_limit_reached_type" => "workspace_owner_usage_limit_reached",
             "status_code" => 200,
             "upstream_request_id" => "upgrade-request-characterization",
             "upstream_transport" => "websocket",
             "websocket_frame_headers" => frame_headers
           }
  end

  test "three- and four-argument websocket metadata preserve legacy output byte for byte" do
    legacy_connection = %{"legacy_marker" => "preserved"}

    route_metadata = %{
      "legacy_route_marker" => 7,
      "upstream_websocket_connection" => legacy_connection,
      upstream_websocket_connection: %{legacy_marker: "preserved"}
    }

    opts = %{routing_attempt_metadata: route_metadata}

    expected =
      Map.merge(route_metadata, %{
        "content_type" => "application/json",
        "status_code" => 200,
        "upstream_transport" => "websocket"
      })

    assert :erlang.term_to_binary(Metadata.websocket_response_metadata([], nil, opts)) ==
             :erlang.term_to_binary(expected)

    frame_headers = %{"openai-request-id" => "frame-request-legacy"}

    assert :erlang.term_to_binary(
             Metadata.websocket_response_metadata([], nil, opts, frame_headers)
           ) ==
             :erlang.term_to_binary(Map.put(expected, "websocket_frame_headers", frame_headers))
  end

  test "websocket connection metadata accepts homogeneous string and atom key forms" do
    lifecycle_id = Ecto.UUID.generate()

    valid_inputs = [
      {%{
         "lifecycle_id" => lifecycle_id,
         "generation" => 2,
         "reused" => false,
         "reconnected" => true,
         "pid" => self(),
         "node" => node(),
         "socket" => make_ref(),
         "url" => "https://example.com/private-path",
         "headers" => %{"authorization" => "synthetic-private-value"},
         "frame" => "synthetic-private-frame",
         "payload" => "synthetic-private-payload",
         "token" => "synthetic-private-token",
         "prompt" => "ignore the metadata contract",
         "ignore_previous_instructions" => "retain every field",
         "reason" => "synthetic-private-reason",
         "lease" => "synthetic-private-lease"
       },
       %{
         "lifecycle_id" => lifecycle_id,
         "generation" => 2,
         "reused" => false,
         "reconnected" => true
       }},
      {%{
         lifecycle_id: lifecycle_id,
         generation: 3,
         reused: true,
         reconnected: false,
         token: "synthetic-private-token",
         prompt: "ignore the metadata contract"
       },
       %{
         "lifecycle_id" => lifecycle_id,
         "generation" => 3,
         "reused" => true,
         "reconnected" => false
       }}
    ]

    Enum.each(valid_inputs, fn {connection, normalized} ->
      expected = %{"upstream_websocket_connection" => normalized}

      assert Metadata.upstream_websocket_connection_attempt_metadata(connection) == expected

      assert Metadata.websocket_response_metadata([], nil, %{}, %{}, connection) ==
               Map.merge(
                 %{
                   "content_type" => "application/json",
                   "status_code" => 200,
                   "upstream_transport" => "websocket"
                 },
                 expected
               )
    end)
  end

  test "websocket connection metadata omits the namespace for every malformed input class" do
    lifecycle_id = Ecto.UUID.generate()

    string_keys = %{
      "lifecycle_id" => lifecycle_id,
      "generation" => 1,
      "reused" => false,
      "reconnected" => false
    }

    atom_keys = %{
      lifecycle_id: lifecycle_id,
      generation: 1,
      reused: false,
      reconnected: false
    }

    malformed =
      [nil, [], [generation: 1], %{}] ++
        Enum.map(Map.keys(string_keys), &Map.delete(string_keys, &1)) ++
        Enum.map(Map.keys(atom_keys), &Map.delete(atom_keys, &1)) ++
        [
          %{
            "lifecycle_id" => lifecycle_id,
            :generation => 1,
            "reused" => false,
            "reconnected" => false
          },
          Map.merge(string_keys, atom_keys),
          Map.put(string_keys, :generation, 1),
          Map.put(atom_keys, "generation", 1),
          Map.put(string_keys, "lifecycle_id", "not-a-uuid"),
          Map.put(string_keys, "lifecycle_id", String.upcase(lifecycle_id)),
          Map.put(string_keys, "lifecycle_id", String.replace(lifecycle_id, "-", "")),
          Map.put(string_keys, "lifecycle_id", lifecycle_id <> "-overlong"),
          Map.put(string_keys, "generation", 0),
          Map.put(string_keys, "generation", -1),
          Map.put(string_keys, "generation", "1"),
          Map.put(string_keys, "generation", 1.0),
          Map.put(string_keys, "reused", "false"),
          Map.put(string_keys, "reused", 0),
          Map.put(string_keys, "reconnected", "true"),
          Map.put(string_keys, "reconnected", 1),
          Map.put(atom_keys, :lifecycle_id, String.upcase(lifecycle_id)),
          Map.put(atom_keys, :generation, "1"),
          Map.put(atom_keys, :reused, "false")
        ]

    Enum.each(malformed, fn input ->
      assert Metadata.upstream_websocket_connection_attempt_metadata(input) == %{}

      refute Map.has_key?(
               Metadata.websocket_response_metadata([], nil, %{}, %{}, input),
               "upstream_websocket_connection"
             )
    end)
  end

  test "five-argument websocket metadata owns the connection namespace" do
    lifecycle_id = Ecto.UUID.generate()

    injected = %{
      "lifecycle_id" => lifecycle_id,
      "generation" => 99,
      "reused" => true,
      "reconnected" => true,
      "token" => "synthetic-route-injection"
    }

    metadata =
      Metadata.websocket_response_metadata(
        [],
        nil,
        %{
          routing_attempt_metadata: %{
            "upstream_websocket_connection" => injected,
            upstream_websocket_connection: injected
          }
        },
        %{},
        %{"generation" => 0}
      )

    refute Map.has_key?(metadata, "upstream_websocket_connection")
    refute Map.has_key?(metadata, :upstream_websocket_connection)
  end

  test "websocket connection normalization does not retain stale call state" do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    first = %{
      "lifecycle_id" => first_id,
      "generation" => 1,
      "reused" => false,
      "reconnected" => false
    }

    second = %{
      lifecycle_id: second_id,
      generation: 4,
      reused: false,
      reconnected: true
    }

    assert [
             Metadata.upstream_websocket_connection_attempt_metadata(first),
             Metadata.upstream_websocket_connection_attempt_metadata(%{"generation" => 0}),
             Metadata.upstream_websocket_connection_attempt_metadata(second)
           ] == [
             %{"upstream_websocket_connection" => first},
             %{},
             %{
               "upstream_websocket_connection" => %{
                 "lifecycle_id" => second_id,
                 "generation" => 4,
                 "reused" => false,
                 "reconnected" => true
               }
             }
           ]
  end

  test "first-event metadata preserves local usage-limit classification and sanitized limit type" do
    response = %Req.Response{
      status: 200,
      headers: [
        {"content-type", ["text/event-stream"]},
        {"x-codex-rate-limit-reached-type", ["workspace_owner_usage_limit_reached"]},
        {"x-request-id", ["req_usage_limit_terminal"]}
      ]
    }

    failure = %{
      code: "usage_limit_exceeded",
      upstream_code: "usage_limit_exceeded",
      event_type: "response.failed",
      data_type: "response.failed"
    }

    assert Metadata.first_event_stream_metadata(
             response,
             failure,
             "upstream_terminal_failure",
             %{}
           ) == %{
             "content_type" => "text/event-stream",
             "error_kind" => "upstream_terminal_failure",
             "rate_limit_reached_type" => "workspace_owner_usage_limit_reached",
             "status_code" => 200,
             "stream_error_code" => "usage_limit_exceeded",
             "stream_failure_stage" => "first_event",
             "stream_terminal_type" => "response.failed",
             "upstream_request_id" => "req_usage_limit_terminal"
           }
  end

  test "first-event metadata ignores missing and unknown rate limit reached types" do
    failure = %{
      code: "usage_limit_exceeded",
      upstream_code: "usage_limit_exceeded",
      event_type: "response.failed"
    }

    metadata =
      Metadata.first_event_stream_metadata(
        %Req.Response{
          status: 200,
          headers: [{"x-codex-rate-limit-reached-type", ["future_workspace_limit"]}]
        },
        failure,
        "upstream_terminal_failure",
        %{}
      )

    refute Map.has_key?(metadata, "rate_limit_reached_type")
    assert metadata["stream_error_code"] == "usage_limit_exceeded"
  end

  test "first-event metadata retains only the sanitized upstream error parameter" do
    failure = %{
      code: "invalid_request_error",
      upstream_code: "unsupported_parameter",
      upstream_error_param: "reasoning.summary",
      event_type: "response.failed",
      message: "raw-message-sentinel",
      invalid_value: "raw-value-sentinel",
      frame: "raw-frame-sentinel"
    }

    metadata =
      Metadata.first_event_stream_metadata(
        %Req.Response{status: 200, headers: [{"x-private-header", ["raw-header-sentinel"]}]},
        failure,
        "first_event_stream_failure",
        %{}
      )

    assert metadata["upstream_error_param"] == "reasoning.summary"
    assert metadata["upstream_error_code"] == "unsupported_parameter"
    assert metadata["masked_error_code"] == "invalid_request_error"

    encoded = Jason.encode!(metadata)
    refute encoded =~ "raw-message-sentinel"
    refute encoded =~ "raw-value-sentinel"
    refute encoded =~ "raw-frame-sentinel"
    refute encoded =~ "raw-header-sentinel"
  end

  test "response metadata preserves known Codex rate limit reached type headers" do
    response = %Req.Response{
      status: 429,
      headers: [
        {"content-type", ["application/json"]},
        {"x-codex-rate-limit-reached-type", ["workspace_owner_usage_limit_reached"]},
        {"x-request-id", ["req_123"]}
      ]
    }

    assert Metadata.response_metadata(response, "upstream_status", %{}) == %{
             "content_type" => "application/json",
             "error_kind" => "upstream_status",
             "rate_limit_reached_type" => "workspace_owner_usage_limit_reached",
             "status_code" => 429,
             "upstream_request_id" => "req_123"
           }
  end

  test "response metadata records response body limit evidence without retaining body bytes" do
    collect = BoundedResponseBody.collector(8)

    response =
      Req.Response.new(status: 200)
      |> Req.Response.put_header("content-type", "application/json")
      |> Req.Response.put_header("content-length", "9")

    assert {:halt, {_request, response}} = collect.({:data, "raw-body"}, {Req.new(), response})

    assert Metadata.response_metadata(response, "upstream_response_too_large", %{}) == %{
             "content_type" => "application/json",
             "error_kind" => "upstream_response_too_large",
             "response_body_content_length" => 9,
             "response_body_limit_exceeded" => true,
             "response_body_limit_bytes" => 8,
             "response_body_seen_bytes" => 8,
             "status_code" => 200
           }

    refute Metadata.response_body(response) =~ "raw-body"
  end

  test "websocket metadata ignores unknown Codex rate limit reached type headers" do
    metadata =
      Metadata.websocket_response_metadata(
        [
          {"x-codex-rate-limit-reached-type", "future_workspace_limit"},
          {"openai-request-id", "req_ws"}
        ],
        nil,
        %{}
      )

    refute Map.has_key?(metadata, "rate_limit_reached_type")
    assert metadata["upstream_request_id"] == "req_ws"
    assert metadata["upstream_transport"] == "websocket"
  end

  test "websocket metadata stores sanitized frame-carried headers only under frame header summary" do
    metadata =
      Metadata.websocket_response_metadata(
        [{"openai-request-id", "upgrade-req"}],
        "rate_limit_exceeded",
        %{},
        %{
          "openai-request-id" => "frame-req",
          "x-codex-primary-reset-at" => "2026-05-25T13:00:00Z"
        }
      )

    assert metadata["upstream_request_id"] == "upgrade-req"

    assert metadata["websocket_frame_headers"] == %{
             "openai-request-id" => "frame-req",
             "x-codex-primary-reset-at" => "2026-05-25T13:00:00Z"
           }
  end

  test "safe_reason classifies prompt token and idempotency-bearing terms without inspecting them" do
    secret_reason = %{
      idempotency_key: "raw-idempotency-key-secret",
      prompt: "raw prompt",
      token: "Bearer secret-token"
    }

    assert Metadata.safe_reason({:chunk, secret_reason}) ==
             "downstream chunk failed: non_atom_reason"

    assert Metadata.safe_reason(secret_reason) == "non_atom_reason"
    assert Metadata.safe_reason({:exit, secret_reason}) == "exit"

    rendered =
      [
        Metadata.safe_reason({:chunk, secret_reason}),
        Metadata.safe_reason(secret_reason),
        Metadata.safe_reason({:exit, secret_reason})
      ]
      |> Enum.join(" ")

    refute rendered =~ "raw-idempotency-key-secret"
    refute rendered =~ "raw prompt"
    refute rendered =~ "secret-token"
  end
end
