defmodule CodexPoolerWeb.CodexResponsesSocketTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Contracts
  alias CodexPoolerWeb.CodexResponsesSocket

  test "websocket error frames carry pinned continuation recovery fields" do
    state = %{tasks: MapSet.new(), task_monitors: %{}}

    assert {:push, {:text, payload}, ^state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, self(),
                {:error, Contracts.pinned_continuation_reauth_required_error()}},
               state
             )

    assert %{
             "type" => "error",
             "status" => 503,
             "error" => %{
               "code" => "pinned_continuation_reauth_required",
               "retryable" => false,
               "requires_new_upstream_session" => true,
               "recovery_kind" => "restart_with_full_context",
               "recovery" => recovery
             }
           } = Jason.decode!(payload)

    assert recovery["kind"] == "restart_with_full_context"
    assert recovery["anchor_removal"]["body"] == ["previous_response_id"]

    assert recovery["anchor_removal"]["headers"] == [
             "x-codex-previous-response-id",
             "x-codex-turn-state",
             "x-codex-window-id",
             "x-codex-session-id",
             "session-id",
             "x-session-id",
             "x-session-affinity",
             "session_id",
             "x-codex-conversation-id"
           ]
  end

  test "websocket error frames leave unrelated errors without recovery fields" do
    for reason <- [
          %{status: 503, code: "session_assignment_unavailable", message: "session unavailable"},
          %{status: 400, code: "unsupported_model_capability", message: "model unsupported"},
          %{status: 400, code: "invalid_request", message: "request invalid"}
        ] do
      assert {:push, {:text, payload}, _state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_done, self(), {:error, reason}},
                 %{tasks: MapSet.new(), task_monitors: %{}}
               )

      decoded = Jason.decode!(payload)

      assert decoded["error"] == %{
               "message" => reason.message,
               "type" => "invalid_request_error",
               "code" => reason.code,
               "param" => nil
             }

      refute Map.has_key?(decoded["error"], "recovery")
      refute Map.has_key?(decoded["error"], "recovery_kind")
      refute Map.has_key?(decoded["error"], "requires_new_upstream_session")
      refute Map.has_key?(decoded["error"], "retryable")
    end
  end

  test "websocket client error frames classify prompt token and idempotency-bearing terms" do
    secret_reason = %{
      idempotency_key: "raw-idempotency-key-secret",
      prompt: "raw websocket prompt",
      token: "Bearer websocket-secret-token"
    }

    state = %{tasks: MapSet.new(), task_monitors: %{}}

    assert {:push, {:text, payload}, ^state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, self(), {:error, secret_reason}},
               state
             )

    decoded = Jason.decode!(payload)
    assert decoded["type"] == "error"
    assert decoded["status"] == 500
    assert decoded["error"]["message"] == "websocket request failed: non_atom_reason"
    assert decoded["error"]["code"] == "websocket_request_failed"

    refute payload =~ "raw-idempotency-key-secret"
    refute payload =~ "raw websocket prompt"
    refute payload =~ "websocket-secret-token"
  end
end
