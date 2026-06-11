defmodule CodexPooler.Gateway.ContractsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Contracts

  @anchor_headers [
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

  test "pinned continuation reauth contract carries restart guidance" do
    error = Contracts.pinned_continuation_reauth_required_error()

    assert error.status == 503
    assert error.code == "pinned_continuation_reauth_required"
    assert error.retryable == false
    assert error.requires_new_upstream_session == true

    assert Contracts.recovery_response_headers(error) == [
             {"x-codex-recovery-kind", "restart_with_full_context"}
           ]

    assert %{
             "retryable" => false,
             "requires_new_upstream_session" => true,
             "recovery_kind" => "restart_with_full_context",
             "recovery" => recovery
           } = Contracts.recovery_error_fields(error)

    assert recovery["kind"] == "restart_with_full_context"

    assert recovery["guidance"] ==
             "Restart with full visible context and no continuation anchors."

    assert recovery["anchor_removal"]["body"] == ["previous_response_id"]
    assert recovery["anchor_removal"]["headers"] == @anchor_headers

    assert "Full visible context means client-visible conversation state and tool results." in recovery[
             "notes"
           ]

    assert "Do not replay stored prompts or hidden server state." in recovery["notes"]
  end

  test "recovery fields are limited to pinned continuation reauth errors" do
    for error <- [
          %{status: 503, code: "session_assignment_unavailable", message: "session unavailable"},
          %{status: 400, code: "unsupported_model_capability", message: "model unsupported"},
          %{status: 400, code: "invalid_request", message: "request invalid"}
        ] do
      assert Contracts.recovery_response_headers(error) == []
      assert Contracts.recovery_error_fields(error) == %{}
      refute Contracts.pinned_continuation_reauth_required?(error)
    end
  end
end
