defmodule CodexPooler.Gateway.Runtime.UpstreamAttemptTransportTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt

  @endpoint "/backend-api/codex/responses"

  test "a websocket-transport turn with a writer uses the websocket upstream whatever its stream flag" do
    writer = fn _frame -> :ok end

    for payload <- [%{}, %{"stream" => true}, %{"stream" => false}] do
      options = options(payload, transport: "websocket", websocket_writer: writer)
      assert UpstreamAttempt.transport_decision(options) == :websocket
    end
  end

  test "a connection-bound compaction collector uses the websocket upstream without a writer" do
    options =
      %{}
      |> options(
        transport: "websocket",
        websocket_writer: nil,
        websocket_delivery_mode: :collect_compaction
      )
      |> RequestOptions.put_payload_context(compaction_trigger_bridge?: true)

    assert UpstreamAttempt.transport_decision(options) == :websocket
  end

  test "a websocket-transport turn with neither writer nor collector never falls back to http" do
    options = options(%{"stream" => true}, transport: "websocket", websocket_writer: nil)

    assert UpstreamAttempt.transport_decision(options) == :websocket_without_upstream

    assert UpstreamAttempt.websocket_transport_required_error() == %{
             status: 500,
             code: "websocket_transport_required",
             message: "websocket turn requires the websocket upstream transport",
             param: nil
           }
  end

  test "http transports keep their existing http decision" do
    for {payload, transport} <- [
          {%{"stream" => true}, "http_sse"},
          {%{}, "http_json"},
          {%{"stream" => false}, "http_compact_json"}
        ] do
      assert UpstreamAttempt.transport_decision(options(payload, transport: transport)) == :http
    end
  end

  defp options(payload, transport_updates) do
    %{}
    |> RequestOptions.build(@endpoint, payload)
    |> RequestOptions.put_transport(transport_updates)
  end
end
