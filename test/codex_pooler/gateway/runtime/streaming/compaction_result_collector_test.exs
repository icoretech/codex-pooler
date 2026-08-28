defmodule CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollectorTest do
  use ExUnit.Case, async: true

  @moduletag :collect_compaction

  alias CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector

  test "websocket body accepts exactly one canonical or alias item and completed terminal" do
    for type <- ["compaction", "compaction_summary"] do
      body = websocket_body([item_event(type, "opaque-#{type}"), completed_event()])

      assert {:ok, %{status: 200, headers: [{"content-type", "application/json"}], raw_body: raw}} =
               CompactionResultCollector.collect_websocket_body(body)

      assert %{
               "status" => "completed",
               "output" => [%{"type" => "compaction", "encrypted_content" => content}]
             } = Jason.decode!(raw)

      assert content == "opaque-#{type}"
    end
  end

  test "websocket body rejects missing duplicate blank malformed and post-terminal shapes" do
    invalid_bodies = [
      websocket_body([completed_event()]),
      websocket_body([
        item_event("compaction", "one"),
        item_event("compaction", "two"),
        completed_event()
      ]),
      websocket_body([
        item_event("compaction", "one"),
        item_event("compaction_summary", "two"),
        completed_event()
      ]),
      websocket_body([item_event("compaction", " "), completed_event()]),
      "data: not-json\n\n",
      "data: []\n\n",
      "event: response.failed\ndata: #{provider_failure_event("error", "server_error", "input", "private")}\n\n",
      websocket_body([item_event("compaction", "one")]),
      websocket_body([item_event("compaction", "one"), completed_event(), unrelated_event()]),
      websocket_body([
        provider_failure_event("response.failed", "server_error", "input", "private"),
        unrelated_event()
      ]),
      websocket_body([
        provider_failure_event("response.failed", "server_error", "input", "private")
      ]) <> "data: #{unrelated_event()}",
      websocket_body([incomplete_event(nil)]),
      websocket_body([incomplete_event(" ")])
    ]

    for body <- invalid_bodies do
      assert {:error,
              %{
                status: 502,
                code: "invalid_compaction_response",
                message: "upstream compact stream was invalid"
              }} = CompactionResultCollector.collect_websocket_body(body)
    end
  end

  test "websocket body sanitizes malformed provider codes and params without raw leakage" do
    raw_code = "provider code with spaces and private data"
    raw_param = "input[99999].private"
    raw_message = "private-provider-message"

    body =
      websocket_body([
        provider_failure_event("response.failed", raw_code, raw_param, raw_message)
      ])

    assert {:provider_failure,
            %{
              code: code,
              upstream_code: upstream_code,
              upstream_error_param: nil,
              event_type: "response.failed",
              data_type: "response.failed"
            } = failure} = CompactionResultCollector.collect_websocket_body(body)

    assert is_binary(code) and byte_size(code) <= 80
    assert is_binary(upstream_code) and byte_size(upstream_code) <= 80
    assert code =~ ~r/^sha256_[0-9a-f]{12}$/
    assert upstream_code =~ ~r/^sha256_[0-9a-f]{12}$/

    for raw <- [raw_code, raw_param, raw_message] do
      refute inspect(failure) =~ raw
    end
  end

  test "websocket body preserves recognized sanitized provider terminal failures" do
    raw_sentinel = "private-provider-message-sentinel"

    cases = [
      {"response.failed", "invalid_request_error", "input", "invalid_request_error"},
      {"response.failed", "misalignment_policy_violation", "input",
       "misalignment_policy_violation"},
      {"error", "previous_response_not_found", "previous_response_id", "stream_incomplete"},
      {"error", "invalid_previous_response_id", "previous_response_id", "stream_incomplete"}
    ]

    for {event_type, upstream_code, param, expected_code} <- cases do
      body =
        websocket_body([provider_failure_event(event_type, upstream_code, param, raw_sentinel)])

      assert {:provider_failure,
              %{
                code: ^expected_code,
                upstream_code: ^upstream_code,
                upstream_error_param: ^param,
                event_type: ^event_type,
                data_type: ^event_type
              } = failure} = CompactionResultCollector.collect_websocket_body(body)

      assert Map.keys(failure) |> Enum.sort() ==
               [:code, :data_type, :event_type, :upstream_code, :upstream_error_param]

      refute inspect(failure) =~ raw_sentinel
    end
  end

  test "websocket body preserves response.incomplete with and without an explicit failure" do
    raw_sentinel = "private-incomplete-message-sentinel"

    cases = [
      {provider_failure_event("response.incomplete", "server_error", "input", raw_sentinel),
       "server_error", "server_error", "input"},
      {incomplete_event("max_output_tokens"), "max_output_tokens", "max_output_tokens", nil}
    ]

    for {event, code, upstream_code, param} <- cases do
      assert {:provider_failure,
              %{
                code: ^code,
                upstream_code: ^upstream_code,
                upstream_error_param: ^param,
                event_type: "response.incomplete",
                data_type: "response.incomplete"
              } = failure} =
               CompactionResultCollector.collect_websocket_body(websocket_body([event]))

      refute inspect(failure) =~ raw_sentinel
    end
  end

  test "websocket body collection keeps provider failure state request-local" do
    provider = provider_failure_event("response.failed", "server_error", "input", "private")

    assert {:provider_failure, %{upstream_code: "server_error"}} =
             CompactionResultCollector.collect_websocket_body(websocket_body([provider]))

    assert {:ok, %{status: 200}} =
             CompactionResultCollector.collect_websocket_body(
               websocket_body([item_event("compaction", "fresh"), completed_event()])
             )

    assert {:error, %{status: 502, code: "invalid_compaction_response"}} =
             CompactionResultCollector.collect_websocket_body("data: not-json\n\n")
  end

  defp websocket_body(events), do: Enum.map_join(events, "", &"data: #{&1}\n\n")

  defp item_event(type, content) do
    Jason.encode!(%{
      "type" => "response.output_item.done",
      "item" => %{"type" => type, "encrypted_content" => content}
    })
  end

  defp completed_event do
    Jason.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => "resp_compact_fixture", "status" => "completed"}
    })
  end

  defp provider_failure_event(event_type, code, param, message) do
    error = %{"code" => code, "param" => param, "message" => message}

    event =
      if event_type == "error" do
        %{"type" => event_type, "error" => error}
      else
        %{
          "type" => event_type,
          "response" => %{
            "status" => if(event_type == "response.incomplete", do: "incomplete", else: "failed"),
            "error" => error
          }
        }
      end

    Jason.encode!(event)
  end

  defp incomplete_event(reason) do
    Jason.encode!(%{
      "type" => "response.incomplete",
      "response" => %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => reason}
      }
    })
  end

  defp unrelated_event, do: Jason.encode!(%{"type" => "response.in_progress"})
end
