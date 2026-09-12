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
  end

  # findings#165: a present reason this module cannot name used to log the
  # same `"unknown"` the module logs for an absent request or attempt id, so
  # the line read as "nothing was reported". It now carries a fingerprint that
  # discloses nothing and stays distinct per reason.
  test "safe_failure_reason keeps an absent reason apart from an unnameable one" do
    # An absent reason is an atom and names itself; it never shared a token
    # with the unnameable case.
    assert FailureResponse.safe_failure_reason(nil) == "nil"

    unnameable = FailureResponse.safe_failure_reason(%{message: "unsafe detail"})
    assert unnameable =~ ~r/^unnamed_[0-9a-f]{12}$/
    refute unnameable =~ "unsafe detail"

    other = FailureResponse.safe_failure_reason(%{message: "a different detail"})
    assert other =~ ~r/^unnamed_[0-9a-f]{12}$/
    refute unnameable == other

    # A reason that is present but scrubs away entirely is also not "unknown".
    scrubbed = FailureResponse.safe_failure_reason("___")
    assert scrubbed =~ ~r/^unnamed_[0-9a-f]{12}$/

    for reason <- [%{message: "unsafe detail"}, "___", [1, 2, 3], self()],
        do: refute(FailureResponse.safe_failure_reason(reason) == "unknown")
  end

  test "safe_failure_reason redacts and truncates string reasons" do
    long_reason = "token=secret-raw-value " <> String.duplicate("x", 120)

    reason = FailureResponse.safe_failure_reason(long_reason)

    assert byte_size(reason) == 80
    assert reason =~ "token_redacted"
    refute reason =~ "secret-raw-value"
  end
end
