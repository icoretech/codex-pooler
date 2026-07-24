defmodule CodexPooler.Gateway.Transports.TransportFailureReasonTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.TransportFailureReason

  test "extracts safe reasons from transport exceptions" do
    assert TransportFailureReason.safe_reason(%Req.TransportError{reason: :timeout}) == "timeout"

    assert TransportFailureReason.safe_reason(%Finch.TransportError{
             reason: :closed,
             source: %Mint.TransportError{reason: :econnrefused}
           }) == "econnrefused"

    assert TransportFailureReason.safe_reason(%Finch.HTTPError{
             reason: :closed,
             source: %Mint.HTTPError{reason: {:proxy, {:unexpected_status, 503}}}
           }) == "proxy_unexpected_status_503"
  end

  test "characterizes Req Finch and Mint safe helper normalization" do
    cases = [
      {%Req.TransportError{reason: :timeout}, "Req.TransportError", "timeout"},
      {%Req.HTTPError{protocol: :http1, reason: :closed}, "Req.HTTPError", "closed"},
      {%Finch.TransportError{
         reason: :closed,
         source: %Mint.TransportError{reason: :econnrefused}
       }, "Finch.TransportError", "econnrefused"},
      {%Finch.HTTPError{
         reason: {:proxy, {:unexpected_status, 503}},
         source: %Mint.HTTPError{module: Mint.HTTP1, reason: {:proxy, {:unexpected_status, 503}}}
       }, "Finch.HTTPError", "proxy_unexpected_status_503"},
      {%Mint.TransportError{reason: {:bad_alpn_protocol, "h3"}}, "Mint.TransportError",
       "bad_alpn_protocol"},
      {%Mint.HTTPError{module: Mint.HTTP1, reason: {:proxy, :tunnel_timeout}}, "Mint.HTTPError",
       "proxy_tunnel_timeout"}
    ]

    for {exception, exception_name, reason} <- cases do
      assert TransportFailureReason.safe_exception(exception) == exception_name
      assert TransportFailureReason.safe_reason(exception) == reason
    end
  end

  test "normalizes tuple reasons without inspecting full terms" do
    assert TransportFailureReason.safe_reason({:tls_alert, {:unknown_ca, %{cert: "hidden"}}}) ==
             "tls_alert_unknown_ca"

    assert TransportFailureReason.safe_reason({:bad_alpn_protocol, :http1}) ==
             "bad_alpn_protocol_http1"

    assert TransportFailureReason.safe_reason({:upstream_status, 503, %{body: "hidden"}}) ==
             "upstream_status_503"
  end

  test "normalizes blank and long string reasons" do
    assert TransportFailureReason.safe_reason(" !!! ") == nil

    assert TransportFailureReason.safe_reason(%Req.TransportError{reason: "Gateway Timeout!"}) ==
             "gateway_timeout"

    assert TransportFailureReason.safe_reason(String.duplicate("A", 120)) ==
             String.duplicate("a", 96)
  end

  test "returns only exception module names" do
    assert TransportFailureReason.safe_exception(%Req.TransportError{reason: :timeout}) ==
             "Req.TransportError"

    assert TransportFailureReason.safe_exception(:timeout) == nil
  end

  test "builds compact allowlisted transport failure metadata" do
    metadata =
      TransportFailureReason.transport_failure_metadata(
        %Mint.TransportError{reason: :closed},
        %{
          phase: :receive,
          pre_visible_output: false,
          terminal_seen: false,
          text_frame_count: 1
        }
      )

    assert metadata == %{
             "exception" => "Mint.TransportError",
             "reason" => "closed",
             "reason_class" => "Mint.TransportError",
             "phase" => "receive",
             "pre_visible_output" => false,
             "terminal_seen" => false,
             "text_frame_count" => 1
           }
  end

  test "preserves websocket receive timeout phase metadata" do
    metadata =
      TransportFailureReason.transport_failure_metadata(
        :upstream_websocket_receive_timeout,
        %{
          phase: :receive_timeout,
          pre_visible_output: true,
          terminal_seen: false,
          text_frame_count: 0
        }
      )

    assert metadata == %{
             "reason" => "upstream_websocket_receive_timeout",
             "reason_class" => "upstream_websocket_receive_timeout",
             "phase" => "receive_timeout",
             "pre_visible_output" => true,
             "terminal_seen" => false,
             "text_frame_count" => 0
           }
  end

  test "sanitizes retained terminal delivery metadata through the strict allowlist" do
    metadata =
      TransportFailureReason.sanitize_transport_failure_metadata(%{
        "phase" => "terminal_delivery",
        "reason_class" => "owner_terminal_delivery_timeout",
        "reason" => "upstream_websocket_terminal_delivery_timeout",
        "upstream_committed" => true,
        "terminal_seen" => true,
        "terminal_forwarded" => false,
        "raw_frame" => "sentinel-frame",
        "authorization" => "sentinel-token"
      })

    assert metadata == %{
             "phase" => "terminal_delivery",
             "reason_class" => "owner_terminal_delivery_timeout",
             "reason" => "upstream_websocket_terminal_delivery_timeout",
             "upstream_committed" => true,
             "terminal_seen" => true,
             "terminal_forwarded" => false
           }

    refute inspect(metadata) =~ "sentinel"
  end

  test "keeps only bounded websocket terminal discriminator metadata" do
    metadata =
      TransportFailureReason.transport_failure_metadata(
        :upstream_websocket_closed_before_terminal,
        %{
          phase: :upstream_close,
          last_upstream_event_type: "response.done",
          last_upstream_event_class: "terminal_success_candidate",
          terminal_candidate_seen: true,
          terminal_candidate_type: "response.done",
          terminal_candidate_class: "success",
          terminal_candidate_rejection: "invalid_response_status"
        }
      )

    assert Map.take(metadata, [
             "last_upstream_event_type",
             "last_upstream_event_class",
             "terminal_candidate_seen",
             "terminal_candidate_type",
             "terminal_candidate_class",
             "terminal_candidate_rejection"
           ]) == %{
             "last_upstream_event_type" => "response.done",
             "last_upstream_event_class" => "terminal_success_candidate",
             "terminal_candidate_seen" => true,
             "terminal_candidate_type" => "response.done",
             "terminal_candidate_class" => "success",
             "terminal_candidate_rejection" => "invalid_response_status"
           }
  end

  test "drops caller-controlled websocket terminal discriminator values" do
    sentinel = "private-terminal-sentinel-deadbeef"

    metadata =
      TransportFailureReason.sanitize_transport_failure_metadata(%{
        "last_upstream_event_type" => "response.#{sentinel}",
        "last_upstream_event_class" => sentinel,
        "terminal_candidate_seen" => true,
        "terminal_candidate_type" => sentinel,
        "terminal_candidate_class" => sentinel,
        "terminal_candidate_rejection" => sentinel,
        "raw_frame" => sentinel,
        "response_status" => sentinel
      })

    assert metadata == %{"terminal_candidate_seen" => true}
    refute inspect(metadata) =~ sentinel
  end

  test "keeps only finite websocket termination and connection diagnostics" do
    metadata =
      TransportFailureReason.sanitize_transport_failure_metadata(%{
        "termination_source" => "peer_close_frame",
        "transport_signal" => "ssl_data",
        "connection_use" => "reused",
        "connection_request_bucket" => "requests_6_20",
        "connection_age_bucket" => "minutes_15_30",
        "connection_idle_bucket" => "under_5s",
        "websocket_buffer_bucket" => "bytes_1_125",
        "websocket_fragment_open" => true
      })

    assert metadata == %{
             "termination_source" => "peer_close_frame",
             "transport_signal" => "ssl_data",
             "connection_use" => "reused",
             "connection_request_bucket" => "requests_6_20",
             "connection_age_bucket" => "minutes_15_30",
             "connection_idle_bucket" => "under_5s",
             "websocket_buffer_bucket" => "bytes_1_125",
             "websocket_fragment_open" => true
           }
  end

  test "drops free-form websocket termination and connection diagnostics" do
    sentinel = "private-diagnostic-sentinel-deadbeef"

    metadata =
      TransportFailureReason.sanitize_transport_failure_metadata(%{
        "termination_source" => sentinel,
        "transport_signal" => sentinel,
        "connection_use" => sentinel,
        "connection_request_bucket" => sentinel,
        "connection_age_bucket" => sentinel,
        "connection_idle_bucket" => sentinel,
        "websocket_buffer_bucket" => sentinel,
        "websocket_fragment_open" => sentinel
      })

    assert metadata == %{}
    refute inspect(metadata) =~ sentinel
  end

  test "sanitizes peer close diagnostics before transport failure metadata is built" do
    cases = [
      {1000, "short",
       %{
         "peer_close_code" => 1000,
         "peer_close_reason_present" => true,
         "peer_close_reason_bytes" => 5
       }},
      {1000, "",
       %{
         "peer_close_code" => 1000,
         "peer_close_reason_present" => false,
         "peer_close_reason_bytes" => 0
       }},
      {nil, nil,
       %{
         "peer_close_reason_present" => false,
         "peer_close_reason_bytes" => 0
       }},
      {-1, :not_binary,
       %{
         "peer_close_reason_present" => false,
         "peer_close_reason_bytes" => 0
       }},
      {65_536, String.duplicate("x", 124),
       %{
         "peer_close_reason_present" => true,
         "peer_close_reason_bytes" => 123
       }}
    ]

    for {code, reason, expected} <- cases do
      sanitized = TransportFailureReason.peer_close_metadata(code, reason)
      assert sanitized == expected

      metadata =
        TransportFailureReason.transport_failure_metadata(
          :upstream_websocket_closed_before_terminal,
          Map.merge(
            %{
              phase: :upstream_close,
              pre_visible_output: true,
              terminal_seen: false,
              text_frame_count: 0
            },
            sanitized
          )
        )

      assert Map.take(metadata, Map.keys(expected)) == expected
      refute inspect(metadata) =~ inspect(reason)
    end
  end

  test "transport failure metadata does not persist arbitrary binary reasons" do
    metadata =
      TransportFailureReason.transport_failure_metadata(
        "raw reason with token-like value secret-bearer-value",
        %{phase: "send payload", pre_visible_output: true}
      )

    assert metadata == %{
             "phase" => "send_payload",
             "pre_visible_output" => true,
             "reason_class" => "binary"
           }
  end

  test "builds internal upstream transport error with compact metadata and stable public fields" do
    error =
      TransportFailureReason.upstream_transport_error(
        %Req.TransportError{reason: :timeout},
        %{phase: :request}
      )

    assert Map.take(error, [:status, :code, :message, :param]) == %{
             status: 502,
             code: "upstream_network_error",
             message: "upstream request failed",
             param: nil
           }

    assert error.transport_failure == %{
             "exception" => "Req.TransportError",
             "reason" => "timeout",
             "reason_class" => "Req.TransportError",
             "phase" => "request"
           }
  end

  test "internal upstream transport error does not leak malformed raw reasons" do
    binary_error =
      TransportFailureReason.upstream_transport_error(
        "raw reason with bearer secret-value and host example.internal",
        %{phase: "Bearer hidden stage"}
      )

    assert binary_error.transport_failure == %{
             "reason_class" => "binary"
           }

    tuple_error =
      TransportFailureReason.upstream_transport_error(
        {:tls_alert, {:unknown_ca, %{authorization: "Bearer hidden"}}},
        %{phase: :connect}
      )

    assert tuple_error.transport_failure == %{
             "reason" => "tls_alert_unknown_ca",
             "reason_class" => "tls_alert",
             "phase" => "connect"
           }

    metadata_text = inspect([binary_error.transport_failure, tuple_error.transport_failure])
    refute metadata_text =~ "secret-value"
    refute metadata_text =~ "example.internal"
    refute metadata_text =~ "Bearer hidden"
    refute metadata_text =~ "hidden_stage"
    refute metadata_text =~ "authorization"
  end
end
