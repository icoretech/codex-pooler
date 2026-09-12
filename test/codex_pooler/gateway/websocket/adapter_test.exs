defmodule CodexPooler.Gateway.Websocket.AdapterTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket.Adapter

  test "normalized init and terminate metadata prefer the current socket ownership" do
    opts =
      RequestOptions.build(
        %{
          request_id: "request-1",
          transport: "websocket",
          codex_session: %{id: "old-session"},
          owner_instance_id: "old-owner",
          websocket_owner_instance_id: "transport-owner",
          websocket_owner_proxy_instance_id: "proxy-1",
          websocket_owner_downstream_epoch: 2
        },
        "/v1/responses",
        %{}
      )

    assert opts.transport.websocket_owner.proxy_instance_id == "proxy-1"
    assert opts.transport.websocket_owner.owner_instance_id == "transport-owner"
    assert opts.transport.websocket_owner.downstream_epoch == 2

    state = %{
      opts: opts,
      codex_session: %{id: "session-1", owner_instance_id: "owner-1"},
      websocket_owner_downstream: %{epoch: 3}
    }

    metadata = Adapter.init_failure_metadata(state, System.monotonic_time(:millisecond))
    assert metadata.request_id == "request-1"
    assert metadata.endpoint == "/v1/responses"
    assert metadata.transport == "websocket"
    assert metadata.codex_session_id == "session-1"
    assert metadata.owner_instance_id == "owner-1"
    assert metadata.proxy_instance_id == "proxy-1"
    assert metadata.downstream_epoch == "3"
    assert metadata.elapsed_ms >= 0
    assert metadata.phase == "init"
    assert %{phase: "terminate", elapsed_ms: nil} = Adapter.terminate_close_metadata(state)

    fallback = Adapter.terminate_close_metadata(%{opts: opts})
    assert fallback.codex_session_id == "old-session"
    assert fallback.owner_instance_id == "transport-owner"
    assert fallback.downstream_epoch == "2"

    continuity_opts = %{opts | transport: %{opts.transport | websocket_owner: nil}}

    assert Adapter.terminate_close_metadata(%{opts: continuity_opts}).owner_instance_id ==
             "old-owner"
  end

  test "direct response options preserve the session and only reuse an upstream when requested" do
    state = %{
      opts: %{request_id: "request-direct"},
      codex_session: %{id: "session-direct"},
      upstream_websocket_session: self()
    }

    reused = Adapter.response_options(state, true)
    assert reused.continuity.codex_session == state.codex_session
    assert reused.transport.upstream_websocket_session == self()
    fresh = Adapter.response_options(state, false)
    assert is_nil(fresh.transport.upstream_websocket_session)
    assert fresh.transport.transport == "websocket"
  end

  test "continuation frames are ordered while warmups do not produce request rows" do
    assert Adapter.continuity_ordered_payload?(
             CodexPooler.JSON.encode!(%{"type" => "response.processed"})
           )

    assert Adapter.request_row_producing_response_payload?(
             CodexPooler.JSON.encode!(%{"type" => "response.create"})
           )

    refute Adapter.request_row_producing_response_payload?(
             CodexPooler.JSON.encode!(%{"type" => "response.create", "generate" => false})
           )

    refute Adapter.continuity_ordered_payload?("invalid-json")
  end

  test "legacy metadata and absent state remain bounded and tolerate missing timestamps" do
    opts = %{
      request_id: "request-2",
      endpoint: "/backend-api/codex/responses",
      transport: "websocket",
      route_class: "proxy_websocket",
      owner_instance_id: "owner-2",
      websocket_owner_proxy_instance_id: "proxy-2",
      websocket_owner_downstream_epoch: 4
    }

    metadata = Adapter.terminate_close_metadata(%{opts: opts})
    assert metadata.owner_instance_id == "owner-2"
    assert metadata.proxy_instance_id == "proxy-2"
    assert metadata.downstream_epoch == "4"
    assert metadata.route_class == "proxy_websocket"
    assert metadata.endpoint == opts.endpoint
    assert metadata.transport == "websocket"

    assert %{request_id: "none", endpoint: nil, elapsed_ms: nil, owner_instance_id: nil} =
             Adapter.terminate_close_metadata(%{})

    assert %{endpoint: "/v1/responses", elapsed_ms: 0} =
             Adapter.init_failure_metadata(
               %{opts: %{upstream_endpoint: "/v1/responses"}},
               System.monotonic_time(:millisecond) + 60_000
             )
  end

  test "public stream normalization requires an explicit normalized opt in" do
    opts = RequestOptions.build(%{public_openai_responses_stream: true}, "/v1/responses", %{})
    assert Adapter.public_responses_stream?(opts)
    assert Adapter.public_responses_stream?(%{opts: opts})
    refute Adapter.public_responses_stream?(%{public_openai_responses_stream: true})
    refute Adapter.public_responses_stream?(nil)
    refute Adapter.request_row_producing_response_payload?(nil)
    refute Adapter.continuity_ordered_payload?(%{})
  end

  test "wire errors retain recovery instructions and classify overloads" do
    reason = Contracts.pinned_continuation_unavailable_error()
    assert %{"status" => 503, "error" => error} = Adapter.websocket_error(reason)
    assert error["code"] == reason.code
    assert error["param"] == "model"
    assert error["retryable"] == false
    assert error["recovery"] == reason.recovery

    assert %{"error" => %{"type" => "server_error"}} =
             Adapter.websocket_error(%{
               status: 503,
               code: "server_is_overloaded",
               message: "busy"
             })

    # findings#184: a status-500 gateway failure is a server-side failure by
    # construction, whatever the unrecognized reason was.
    assert %{
             "status" => 500,
             "error" => %{"code" => "websocket_request_failed", "type" => "server_error"}
           } = Adapter.websocket_error(:closed)

    # An error that declares itself non-retryable stays terminal for the client
    # even at 503; its recovery fields, not a retry, are the way out.
    assert error["retryable"] == false
    assert error["type"] == "invalid_request_error"
  end

  # findings#184: `error_type/1` special-cased one code and defaulted the rest to
  # the do-not-retry class, so every owner-lifecycle failure told an SDK its own
  # frame was malformed. The whole owner vocabulary is enumerated now; this walks
  # it through the real renderer so a code added to
  # `OwnerErrorVocabulary` without a class cannot ship silently.
  test "every owner-lifecycle error renders the class its status implies" do
    expected_types = %{
      owner_busy: "server_error",
      owner_crashed: "server_error",
      owner_drained: "server_error",
      owner_forward_timeout: "server_error",
      owner_forwarding_disabled: "server_error",
      owner_unavailable: "server_error",
      stale_owner: "server_error",
      upstream_stream_error: "server_error",
      upstream_websocket_terminal_delivery_timeout: "server_error",
      client_disconnected: "invalid_request_error",
      duplicate_downstream: "invalid_request_error",
      stale_downstream: "invalid_request_error"
    }

    owner_errors = OwnerErrorVocabulary.owner_errors()
    assert Enum.sort(Map.keys(expected_types)) == Enum.sort(owner_errors)

    for owner_error <- owner_errors do
      assert {:ok, payload} = WebsocketOwnerContract.safe_error_payload(owner_error, nil)
      rendered = Adapter.websocket_error(payload)

      assert rendered["error"]["type"] == expected_types[owner_error],
             "#{owner_error} rendered #{inspect(rendered["error"]["type"])}"

      # A server-class answer must never contradict its own status: a 5xx that
      # says `invalid_request_error` is the defect this test exists for.
      if rendered["status"] >= 500 do
        assert rendered["error"]["type"] == "server_error"
      end
    end
  end
end
