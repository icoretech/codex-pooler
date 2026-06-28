defmodule CodexPooler.Gateway.Runtime.Finalization.MetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Transports.BoundedResponseBody

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
