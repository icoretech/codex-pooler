defmodule CodexPooler.Gateway.Websocket.AdapterTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
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

    assert %{"status" => 500, "error" => %{"code" => "websocket_request_failed"}} =
             Adapter.websocket_error(:closed)
  end
end
