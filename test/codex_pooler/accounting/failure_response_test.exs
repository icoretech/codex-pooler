defmodule CodexPooler.Accounting.FailureResponseTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.FailureResponse

  test "safe_failure_reason keeps useful low-cardinality reasons" do
    assert FailureResponse.safe_failure_reason(%{code: :invalid_request}) == "invalid_request"

    assert FailureResponse.safe_failure_reason(%{"code" => "quota refresh failed"}) ==
             "quota_refresh_failed"

    assert FailureResponse.safe_failure_reason(:route_metadata_failed) == "route_metadata_failed"

    assert FailureResponse.safe_failure_reason({:transaction_aborted, %{raw: "hidden"}}) ==
             "transaction_aborted"

    assert FailureResponse.safe_failure_reason(%RuntimeError{message: "sensitive detail"}) ==
             "RuntimeError"

    assert FailureResponse.safe_failure_reason(%Ecto.Changeset{}) == "changeset"
    assert FailureResponse.safe_failure_reason(%{message: "unsafe detail"}) == "unknown"
  end

  test "safe_failure_reason redacts and truncates string reasons" do
    long_reason = "token=secret-raw-value " <> String.duplicate("x", 120)

    reason = FailureResponse.safe_failure_reason(long_reason)

    assert byte_size(reason) == 80
    assert reason =~ "token_redacted"
    refute reason =~ "secret-raw-value"
  end
end
