defmodule CodexPoolerWeb.Observatory.PresentationFailureTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Observatory.Presentation
  alias CodexPoolerWeb.Observatory.Presentation.Safety

  test "projects only allowlisted failure codes" do
    cases = [
      {"rate_limited", "rate_limited", "Rate limited"},
      {"authentication", "authentication", "Authentication issue"},
      {"timeout", "timeout", "Timed out"},
      {"service_unavailable", "service_unavailable", "Service unavailable"},
      {"invalid_request", "invalid_request", "Invalid request"},
      {"request_failed", "request_failed", "Request failed"},
      {"storage_shard_miss", "request_failed", "Request failed"},
      {"pool_rate_limited", "request_failed", "Request failed"},
      {"upstream_unavailable", "request_failed", "Request failed"},
      {"operator_override", "request_failed", "Request failed"},
      {" canonical-marker\r\n\t", "request_failed", "Request failed"},
      {String.duplicate("rate_limited", 10), "request_failed", "Request failed"}
    ]

    Enum.each(cases, fn {input, projected_code, label} ->
      [projected] =
        Presentation.build(%{
          totals: %{requests: %{total: 1}},
          accounting: %{status: "partial"},
          outcomes: [outcome(input, %{"raw" => "private-outcome-metadata"})]
        }).outcomes

      assert projected.code == projected_code
      assert projected.status.label == "Failed · #{label}"
      refute inspect(projected, limit: :infinity) =~ "private-outcome-metadata"

      if projected_code == "request_failed" and is_binary(input) and input != projected_code do
        refute inspect(projected, limit: :infinity) =~ input
      end
    end)

    for input <- [nil, %{"raw" => "unexpected"}, [:unexpected], 42] do
      assert Safety.failure_label(input) == "Request failed"
    end
  end

  defp outcome(code, metadata) do
    %{
      status: "failed",
      code: code,
      model: "safe-model",
      endpoint_class: "responses",
      metadata: metadata
    }
  end
end
