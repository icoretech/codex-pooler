defmodule CodexPooler.Gateway.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket.Adapter

  # findings#184 fixed the websocket renderer and findings#191 the HTTP one. They
  # disagreed about the same code for a while because each owned its own
  # one-exception-plus-catch-all; this module is the single answer both ask, and
  # these are the properties that keep it one answer.

  test "every owner-lifecycle code has an explicit class, on both surfaces" do
    expected_types = %{
      "owner_busy" => "server_error",
      "owner_crashed" => "server_error",
      "owner_drained" => "server_error",
      "owner_forward_timeout" => "server_error",
      "owner_forwarding_disabled" => "server_error",
      "owner_unavailable" => "server_error",
      "stale_owner" => "server_error",
      "upstream_stream_error" => "server_error",
      "upstream_websocket_terminal_delivery_timeout" => "server_error",
      "client_disconnected" => "invalid_request_error",
      "duplicate_downstream" => "invalid_request_error",
      "stale_downstream" => "invalid_request_error"
    }

    # The compile-time guard in `ErrorClassification` fails the build when this
    # drifts; asserting it here names the drift in a test run too.
    assert Enum.sort(Map.keys(expected_types)) ==
             Enum.sort(OwnerErrorVocabulary.owner_error_codes())

    for {code, type} <- expected_types do
      classified =
        ErrorClassification.error_type(code, owner_error_status(code))

      assert classified == type, "#{code} classified as #{classified}"
    end
  end

  test "no code is classified as both server and client class" do
    assert ErrorClassification.server_error_codes() --
             (ErrorClassification.server_error_codes() --
                ErrorClassification.client_error_codes()) == []
  end

  # The acceptance criterion findings#191 set, stated as a property rather than
  # as a list: whatever the code, a server-side status never renders as the
  # terminal class an SDK reads as "your request was malformed".
  #
  # The only way out of the property is the explicitly enumerated client class,
  # so the test below pins the other half: each of those three codes is emitted
  # at a 4xx, and none of them can put a 5xx on the wire.
  test "a 5xx is never typed as a client error, whatever the code" do
    codes =
      ErrorClassification.server_error_codes() ++
        [
          "gateway_accounting_failed",
          "gateway_reservation_failed",
          "invalid_compaction_response",
          "no_eligible_backend",
          "pinned_continuation_reauth_required",
          "pinned_continuation_unavailable",
          "session_assignment_unavailable",
          "settings_unavailable",
          "unknown_route_class",
          "upstream_network_error",
          "upstream_request_failed",
          "websocket_transport_required",
          "a_code_no_one_has_written_yet",
          :upstream_file_bridge_invalid_response
        ]

    for code <- codes, status <- [500, 502, 503, 504, 599] do
      assert ErrorClassification.error_type(code, status) == "server_error",
             "#{inspect(code)} at #{status} escaped the invariant"
    end
  end

  test "the enumerated client class never covers a server-side status" do
    # Walk the owner vocabulary's own atoms rather than converting the codes
    # back: an atom exists only once a module naming it is loaded, and which
    # modules a test partition has loaded depends on the seed.
    client_errors =
      Enum.filter(
        OwnerErrorVocabulary.owner_errors(),
        &(Atom.to_string(&1) in ErrorClassification.client_error_codes())
      )

    assert Enum.map(client_errors, &Atom.to_string/1) |> Enum.sort() ==
             Enum.sort(ErrorClassification.client_error_codes())

    for error <- client_errors do
      assert {:ok, payload} = WebsocketOwnerContract.safe_error_payload(error, nil)

      assert payload.status < 500,
             "#{error} is client class but is emitted at #{payload.status}"
    end
  end

  test "a 4xx outside the vocabulary stays the caller's to fix" do
    for status <- [400, 401, 403, 404, 409, 413, 415] do
      assert ErrorClassification.error_type("invalid_request", status) ==
               "invalid_request_error"
    end

    # Two 409s are deliberately server class: backpressure and a lease that
    # moved are both retryable with the same submission.
    assert ErrorClassification.error_type("owner_busy", 409) == "server_error"
    assert ErrorClassification.error_type("stale_owner", 409) == "server_error"

    # A duplicate turn id is the caller's, at the same status.
    assert ErrorClassification.error_type("duplicate_turn", 409) == "invalid_request_error"
  end

  # findings#191: a throttle is the one status neither existing type describes.
  # `invalid_request_error` tells a client to give up on the most retry-worthy
  # answer a gateway can give, and nothing broke, so `server_error` is wrong too.
  test "a 429 is a throttle, not a malformed request and not a failure" do
    for code <- ["upstream_file_bridge_failed", "rate_limit_exceeded", "upstream_status"] do
      assert ErrorClassification.error_type(code, 429) == "rate_limit_error"
    end

    assert ErrorClassification.rate_limit_error_type() == "rate_limit_error"

    # A vocabulary code still wins, so a 429 cannot relabel an owner failure.
    assert ErrorClassification.error_type("owner_unavailable", 429) == "server_error"
  end

  test "an atom code classifies the same as its string spelling" do
    assert ErrorClassification.error_type(:owner_unavailable, 503) == "server_error"
    assert ErrorClassification.error_type(:no_eligible_backend, 503) == "server_error"
    assert ErrorClassification.error_type(:invalid_request, 400) == "invalid_request_error"
  end

  test "a missing status falls back to the caller's class rather than guessing" do
    assert ErrorClassification.error_type("invalid_request", nil) == "invalid_request_error"
    assert ErrorClassification.error_type("owner_unavailable", nil) == "server_error"
  end

  test "the websocket renderer answers exactly what the shared classifier says" do
    for owner_error <- OwnerErrorVocabulary.owner_errors() do
      assert {:ok, payload} = WebsocketOwnerContract.safe_error_payload(owner_error, nil)
      rendered = Adapter.websocket_error(payload)

      assert rendered["error"]["type"] ==
               ErrorClassification.error_type(payload.code, payload.status)

      if rendered["status"] >= 500 do
        assert rendered["error"]["type"] == "server_error"
      end
    end
  end

  defp owner_error_status(code) do
    owner_error =
      Enum.find(OwnerErrorVocabulary.owner_errors(), &(Atom.to_string(&1) == code)) ||
        flunk("#{code} is not in the owner error vocabulary")

    {:ok, payload} = WebsocketOwnerContract.safe_error_payload(owner_error, nil)
    payload.status
  end
end
