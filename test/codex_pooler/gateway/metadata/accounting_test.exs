defmodule CodexPooler.Gateway.Metadata.AccountingTest do
  use CodexPooler.DataCase, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Metadata.Accounting, as: MetadataAccounting

  test "record_required normalizes accounting errors into sanitized gateway failures" do
    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 MetadataAccounting.record_required(
                   :record_usage_metadata_request,
                   {:error, %{code: :invalid_request, message: "unsafe detail"}}
                 )
      end)

    assert log =~ "operation=record_usage_metadata_request"
    assert log =~ "request_id=unknown"
    assert log =~ "reason=invalid_request"
    refute log =~ "unsafe detail"
  end

  test "record_metadata_request requires a valid authenticated pool and api key" do
    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 MetadataAccounting.record_metadata_request(
                   :record_models_metadata_request,
                   %{},
                   %{endpoint: "/v1/models", transport: "http_json"}
                 )
      end)

    assert log =~ "operation=record_models_metadata_request"
    refute log =~ "/v1/models"
  end

  test "optional metadata accounting logs sanitized failures without changing caller flow" do
    assert :ok =
             MetadataAccounting.record_optional(
               :record_chatgpt_usage_metadata_request,
               {:error, %{code: :pool_assignment_not_found, message: "unsafe detail"}}
             )
  end
end
