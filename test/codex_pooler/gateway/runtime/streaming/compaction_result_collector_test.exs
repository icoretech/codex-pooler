defmodule CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :collect_compaction

  alias CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector
  alias CodexPooler.Gateway.Transports.Streaming.CollectedBody

  test "websocket body accepts exactly one canonical or alias item and completed terminal" do
    for type <- ["compaction", "compaction_summary"] do
      body = websocket_body([item_event(type, "opaque-#{type}"), completed_event()])

      assert {:ok, %{status: 200, headers: [{"content-type", "application/json"}], raw_body: raw}} =
               CompactionResultCollector.collect_websocket_body(body)

      assert {:ok, %{compaction_item: compaction_item}} =
               CompactionResultCollector.collect_websocket_body(body)

      assert %{
               "status" => "completed",
               "output" => [%{"type" => "compaction", "encrypted_content" => content}]
             } = CodexPooler.JSON.decode!(raw)

      assert content == "opaque-#{type}"
      assert compaction_item == %{"type" => "compaction", "encrypted_content" => content}
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

    {result, log} =
      with_log([level: :warning], fn -> CompactionResultCollector.collect_websocket_body(body) end)

    assert {:provider_failure,
            %{
              code: code,
              upstream_code: upstream_code,
              upstream_error_param: nil,
              event_type: "response.failed",
              data_type: "response.failed"
            } = failure} = result

    assert event_count(log, "compact terminal decision") == 1
    assert log =~ "source_stage=provider_terminal"
    assert log =~ "param_state=rejected"
    refute log =~ raw_param

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

      {result, log} =
        with_log([level: :warning], fn ->
          CompactionResultCollector.collect_websocket_body(body)
        end)

      assert {:provider_failure,
              %{
                code: ^expected_code,
                upstream_code: ^upstream_code,
                upstream_error_param: ^param,
                event_type: ^event_type,
                data_type: ^event_type
              } = failure} = result

      assert event_count(log, "compact terminal decision") == 1
      assert log =~ "source_stage=provider_terminal"
      assert log =~ "code=#{expected_code}"
      assert log =~ "status=#{provider_failure_status(expected_code, upstream_code)}"
      assert log =~ "terminal_type=#{event_type}"
      assert log =~ "param_state=accepted"
      assert log =~ "param=#{param}"
      assert log =~ "elapsed_ms="

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

  test "trailing malformed material keeps a bounded provider terminal witness while rejecting the collector" do
    raw_message = "PRIVATE_TRAILING_PROVIDER_MESSAGE"

    body =
      websocket_body([
        provider_failure_event("response.failed", "server_error", "input", raw_message)
      ]) <> "data: malformed trailing material"

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %{status: 502, code: "invalid_compaction_response"}} =
                 CompactionResultCollector.collect_websocket_body(body)
      end)

    assert log =~ "compact collector terminal decision"
    assert event_count(log, "compact collector terminal decision") == 1
    assert log =~ "source_stage=collector_invalid"
    assert log =~ "code=invalid_compaction_response"
    assert log =~ "status=502"
    assert log =~ "terminal_type=provider_terminal"
    assert log =~ "reason_code=server_error"
    assert log =~ "param_state=accepted"
    assert log =~ "param=input"
    assert log =~ "elapsed_ms="
    refute log =~ raw_message
  end

  test "an overflowed collected body is diagnosed distinctly from a missing terminal" do
    body =
      CollectedBody.empty()
      |> CollectedBody.append(:binary.copy("x", CollectedBody.max_bytes() + 1))
      |> CollectedBody.read()

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %{status: 502, code: "invalid_compaction_response"}} =
                 CompactionResultCollector.collect_websocket_body(body)
      end)

    assert log =~ "source_stage=collector_invalid"
    assert log =~ "reason_code=compaction_result_too_large"
    refute log =~ "reason_code=missing_terminal"
  end

  test "the collector reason vocabulary is closed and unlisted terms degrade to the generic value" do
    assert CompactionResultCollector.invalid_reason_codes() ==
             ~w(
               compaction_result_too_large
               duplicate_compaction
               invalid_after_provider_failure
               invalid_compaction
               missing_terminal
               provider_failure
             )

    for code <- CompactionResultCollector.invalid_reason_codes() do
      atom = String.to_existing_atom(code)
      assert CompactionResultCollector.invalid_reason_code(atom) == code

      assert CompactionResultCollector.invalid_reason_code({atom, :ignored, :ignored, "absent"}) ==
               code
    end

    # A collector reason that is not in the closed list must not reach a log
    # line or attempt metadata as itself.
    for unlisted <- [
          :missing_compaction,
          :some_future_collector_reason,
          {:some_future_tuple_reason, %{}},
          "raw provider text with spaces",
          nil,
          %{code: "server_error"},
          123
        ] do
      assert CompactionResultCollector.invalid_reason_code(unlisted) == "invalid_compaction"
    end
  end

  test "tuple collector reasons stay distinguishable in the sanitized decision log" do
    provider =
      provider_failure_event("response.failed", "server_error", "input", "private-provider-text")

    unrelated =
      "event: response.output_text.delta\n" <>
        "data: #{CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "x"})}\n\n"

    # A provider terminal followed by a further block in the same batch is an
    # `invalid_after_provider_failure`; the witness code still leads the log, so
    # the collector reason is what the attempt metadata must keep apart.
    log =
      capture_log([level: :warning], fn ->
        assert {:error, %{compaction_invalid_reason: "invalid_after_provider_failure"}} =
                 CompactionResultCollector.collect_websocket_body(
                   websocket_body([provider]) <> unrelated
                 )
      end)

    assert log =~ "source_stage=collector_invalid"
    assert log =~ "reason_code=server_error"
  end

  test "collector rejections carry their reason on the internal gateway error map" do
    cases = [
      {"missing_terminal", websocket_body([item_event("compaction", "one")])},
      {"invalid_compaction", websocket_body([item_event("compaction", " "), completed_event()])},
      {"duplicate_compaction",
       websocket_body([
         item_event("compaction", "one"),
         item_event("compaction", "two"),
         completed_event()
       ])},
      {"compaction_result_too_large",
       CollectedBody.empty()
       |> CollectedBody.append(:binary.copy("x", CollectedBody.max_bytes() + 1))
       |> CollectedBody.read()}
    ]

    for {expected_reason, body} <- cases do
      capture_log([level: :warning], fn ->
        assert {:error,
                %{
                  status: 502,
                  code: "invalid_compaction_response",
                  compaction_invalid_reason: ^expected_reason
                }} = CompactionResultCollector.collect_websocket_body(body)
      end)
    end
  end

  defp event_count(log, message), do: length(String.split(log, message)) - 1

  defp provider_failure_status(code, upstream_code)
       when code in ["invalid_request", "invalid_request_error"] or
              upstream_code in [
                "misalignment_policy_violation",
                "previous_response_not_found",
                "invalid_previous_response_id"
              ],
       do: 400

  defp provider_failure_status(_code, _upstream_code), do: 502

  defp websocket_body(events), do: Enum.map_join(events, "", &"data: #{&1}\n\n")

  defp item_event(type, content) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.output_item.done",
      "item" => %{"type" => type, "encrypted_content" => content}
    })
  end

  defp completed_event do
    CodexPooler.JSON.encode!(%{
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

    CodexPooler.JSON.encode!(event)
  end

  defp incomplete_event(reason) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.incomplete",
      "response" => %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => reason}
      }
    })
  end

  defp unrelated_event, do: CodexPooler.JSON.encode!(%{"type" => "response.in_progress"})
end
