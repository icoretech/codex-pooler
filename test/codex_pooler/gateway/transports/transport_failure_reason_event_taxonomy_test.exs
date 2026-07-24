defmodule CodexPooler.Gateway.Transports.TransportFailureReasonEventTaxonomyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.TransportFailureReason

  test "keeps finite known unknown and legacy response event buckets" do
    cases = [
      {"response.output_text", "response_event"},
      {"response.reasoning", "response_event"},
      {"response.mcp_call", "response_event"},
      {"response.metadata", "response_event"},
      {"response.unknown", "response_unknown_event"},
      {"response.other", "response_event"}
    ]

    for {event_type, event_class} <- cases do
      metadata =
        TransportFailureReason.sanitize_transport_failure_metadata(%{
          "last_upstream_event_type" => event_type,
          "last_upstream_event_class" => event_class
        })

      assert metadata == %{
               "last_upstream_event_type" => event_type,
               "last_upstream_event_class" => event_class
             }
    end
  end

  test "drops raw response subtypes even when their family is known" do
    metadata =
      TransportFailureReason.sanitize_transport_failure_metadata(%{
        "last_upstream_event_type" => "response.output_text.delta",
        "last_upstream_event_class" => "response_event"
      })

    assert metadata == %{"last_upstream_event_class" => "response_event"}
  end
end
