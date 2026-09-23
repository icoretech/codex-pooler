defmodule CodexPooler.Accounting.AttemptFinalizationDeliveryReceiptTest do
  # A websocket socket merges its delivery receipt into the attempt row with its
  # own statement, normally after the gateway finalized the attempt. A socket
  # that closes while its turn is still settling records it first, and the
  # finalization, holding the attempt it loaded before, replaced the whole
  # metadata map: the receipt was gone and the resend admission that reads it
  # refused the released client's identical resend (findings#232, one
  # forwarding-on released-client run of five). Both orders must end with the
  # receipt on the row.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Websocket.DeliveryReceipt

  test "a receipt recorded before the attempt's finalization survives it" do
    %{attempt: attempt, request: request} = websocket_attempt!()
    receipt = aborted_partial_receipt()

    assert :ok = DeliveryReceipt.persist(attempt.id, receipt)

    # `attempt` is the struct loaded before the receipt was merged, as the
    # settling task holds it.
    assert {:ok, _finalized} = Accounting.finalize_request(request, attempt, interrupted_attrs())

    assert %Attempt{status: "failed", response_metadata: metadata} = Repo.get!(Attempt, attempt.id)
    assert metadata["downstream_delivery"] == receipt
    assert metadata["attempt_marker"] == "finalization"
  end

  test "a receipt recorded after the attempt's finalization is merged beside its metadata" do
    %{attempt: attempt, request: request} = websocket_attempt!()
    receipt = aborted_partial_receipt()

    assert {:ok, _finalized} = Accounting.finalize_request(request, attempt, interrupted_attrs())
    assert :ok = DeliveryReceipt.persist(attempt.id, receipt)

    assert %Attempt{response_metadata: metadata} = Repo.get!(Attempt, attempt.id)
    assert metadata["downstream_delivery"] == receipt
    assert metadata["attempt_marker"] == "finalization"
  end

  defp websocket_attempt! do
    setup = accounting_setup()

    assert {:ok, reserved} =
             Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => []}, %{
               endpoint: "/backend-api/codex/responses",
               transport: "websocket",
               correlation_id: Ecto.UUID.generate()
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    %{attempt: attempt, request: reserved.request}
  end

  defp aborted_partial_receipt do
    DeliveryReceipt.build(%{outcome: "aborted", terminal_class: nil, pushed_at: nil, frames_after_visible: 4, transport: "websocket", highest_frame_class: "part_added"})
  end

  defp interrupted_attrs do
    %{
      status: "failed",
      response_status_code: 499,
      last_error_code: "client_disconnected",
      attempt_metadata: %{"attempt_marker" => "finalization"},
      usage: %{status: "usage_unknown", source: "unavailable"}
    }
  end
end
