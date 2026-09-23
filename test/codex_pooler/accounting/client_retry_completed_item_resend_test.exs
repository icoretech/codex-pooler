defmodule CodexPooler.Accounting.ClientRetryCompletedItemResendTest do
  # The predecessor shape of the grown resend (findings#232 row 232-232): the
  # socket pushed completed items and no terminal, and the resend appends
  # exactly those items. The controller tests drive the admission end to end;
  # these pin what each receipt field must say for the shape to hold.
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request}
  alias CodexPooler.Gateway.Persistence.CodexTurn

  @attempt_id "018f60df-713f-7ca8-b9a0-0d12c508a001"
  @now ~U[2026-09-23 08:00:00.000000Z]
  @stored :crypto.hash(:sha256, "stored witness")
  @digest "0123456789ab"

  test "admits the settled cut whose receipt names exactly the candidate's appended items" do
    {turn, request, attempt} = predecessor()
    candidate = %{items: [@digest], digest: @stored, alternates: []}

    assert ClientRetry.grown_witness_candidates(request, [candidate]) == [candidate]
    assert ClientRetry.verified_completed_item_resend?(turn, request, attempt, [candidate])

    {turn, request, attempt} = predecessor(:succeeded)
    assert ClientRetry.verified_completed_item_resend?(turn, request, attempt, [candidate])
  end

  test "a candidate whose witness is not the predecessor's is not one" do
    {_turn, request, _attempt} = predecessor()
    other = %{items: [@digest], digest: :crypto.hash(:sha256, "other"), alternates: []}
    via_alternate = %{items: [@digest], digest: :crypto.hash(:sha256, "other"), alternates: [@stored]}

    assert ClientRetry.grown_witness_candidates(request, [other, via_alternate]) == [via_alternate]
    assert ClientRetry.grown_witness_candidates(%{request | native_client_retry_digest: nil}, [via_alternate]) == []
    assert ClientRetry.grown_witness_candidates(request, [%{items: [], digest: @stored, alternates: []}]) == []
  end

  test "keeps the fence for other items, more items, a truncated list, a terminal and anything but a completed item" do
    {turn, request, attempt} = predecessor()
    candidate = %{items: [@digest], digest: @stored, alternates: []}

    refute ClientRetry.verified_completed_item_resend?(turn, request, attempt, [%{candidate | items: ["ba9876543210"]}])
    refute ClientRetry.verified_completed_item_resend?(turn, request, attempt, [%{candidate | items: [@digest, @digest]}])
    refute ClientRetry.verified_completed_item_resend?(turn, request, attempt, [])

    for change <- [
          %{"completed_items" => 2},
          %{"completed_item_digests" => []},
          %{"terminal_class" => "response.completed"},
          %{"highest_frame_class" => "terminal"},
          %{"highest_frame_class" => "delta"},
          %{"outcome" => "delivered"}
        ] do
      changed = update_in(attempt.response_metadata["downstream_delivery"], &Map.merge(&1, change))
      refute ClientRetry.verified_completed_item_resend?(turn, request, changed, [candidate]), inspect(change)
    end

    refute ClientRetry.verified_completed_item_resend?(turn, request, %{attempt | replay_generation: 1}, [candidate])
    refute ClientRetry.verified_completed_item_resend?(turn, %{request | endpoint: "/backend-api/codex/responses/compact"}, attempt, [candidate])
    refute ClientRetry.verified_completed_item_resend?(turn, %{request | last_error_code: "upstream_stream_error"}, attempt, [candidate])
  end

  defp predecessor(settlement \\ :client_disconnected) do
    receipt = %{
      "outcome" => "aborted",
      "terminal_class" => "none",
      "highest_frame_class" => "item_done",
      "completed_items" => 1,
      "completed_item_digests" => [@digest]
    }

    {turn_status, request_status, attempt_status, error} =
      case settlement do
        :client_disconnected -> {"interrupted", "failed", "failed", "client_disconnected"}
        :succeeded -> {"succeeded", "succeeded", "succeeded", nil}
      end

    turn = %CodexTurn{final_attempt_id: @attempt_id, transport_kind: "websocket", completed_at: @now, status: turn_status, error_code: error}

    request = %Request{
      transport: "websocket",
      endpoint: "/backend-api/codex/responses",
      completed_at: @now,
      status: request_status,
      last_error_code: error,
      native_client_retry_version: 1,
      native_client_retry_digest: @stored,
      native_client_retry_auth_epoch: 0
    }

    attempt = %Attempt{
      id: @attempt_id,
      transport: "websocket",
      replay_generation: 0,
      completed_at: @now,
      status: attempt_status,
      network_error_code: error,
      response_metadata: %{"downstream_delivery" => receipt}
    }

    {turn, request, attempt}
  end
end
