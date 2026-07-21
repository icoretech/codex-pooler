defmodule CodexPooler.Gateway.Transports.PublicResponsesTerminalTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence

  @tag :task_1_pin
  test "PIN-P01 response.completed remains a completed terminal" do
    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_pin_completed", "status" => "completed"}
      })

    assert {:ok,
            %{
              kind: :completed,
              event_type: "response.completed",
              data_type: "response.completed"
            }} = StreamProtocol.terminal_outcome(frame)
  end

  test "classifies structural completed, done, legacy, incomplete, and failed terminals" do
    cases = [
      {completed("resp_completed"), :completed, "response.completed"},
      {done("resp_done"), :completed, "response.done"},
      {%{"id" => "resp_legacy"}, :completed, nil},
      {incomplete("resp_incomplete", nil), :incomplete, "response.incomplete"},
      {incomplete("resp_failed_incomplete", "server_error"), :failed, "response.incomplete"},
      {failed_without_nested_code("resp_failed"), :failed, "response.failed"},
      {%{"detail" => "synthetic terminal detail"}, :failed, "response.failed"}
    ]

    for {decoded, kind, data_type} <- cases do
      assert {:ok, %{kind: ^kind, data_type: ^data_type}} =
               decoded |> Jason.encode!() |> StreamProtocol.terminal_outcome()
    end
  end

  test "rejects malformed or conflicting success shapes" do
    malformed = [
      %{"id" => 42},
      %{"custom" => true},
      %{"type" => "response.done"},
      %{"type" => "response.done", "response" => "not-an-object"},
      %{
        "type" => "response.done",
        "response" => %{"id" => "resp_conflict", "status" => "failed"}
      },
      %{
        "type" => "response.done",
        "response" => %{"id" => "resp_null_status", "status" => nil}
      },
      %{
        "type" => "response.completed",
        "response" => %{"id" => "resp_incomplete", "status" => "incomplete"}
      }
    ]

    for decoded <- malformed do
      assert :error = decoded |> Jason.encode!() |> StreamProtocol.terminal_outcome()
    end

    assert :error = StreamProtocol.terminal_outcome(~s({"type":"response.done"))

    assert nil ==
             StreamProtocol.terminal_outcome("response.completed", %{
               "type" => "response.done",
               "response" => %{"id" => "resp_mismatch"}
             })

    assert nil ==
             StreamProtocol.terminal_outcome("response.done", %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_reverse_mismatch"}
             })
  end

  test "public POST rewrites done and exact legacy success only at the public boundary" do
    done_stream = sse_event("response.done", done("resp_public_done"))
    legacy_stream = sse_data(%{"id" => "resp_public_legacy", "custom" => %{"kept" => true}})

    {done_output, done_state} = normalize_sse(done_stream)
    {legacy_output, legacy_state} = normalize_sse(legacy_stream)

    done_events = public_events(done_output)
    legacy_events = public_events(legacy_output)

    assert Enum.count(done_events, &(&1.event == "response.completed")) == 1
    assert Enum.count(legacy_events, &(&1.event == "response.completed")) == 1

    assert %{data: done_data} = Enum.find(done_events, &(&1.event == "response.completed"))
    assert done_data["type"] == "response.completed"
    assert done_data["response"]["status"] == "completed"
    assert is_integer(done_data["sequence_number"])

    assert %{data: legacy_data} =
             Enum.find(legacy_events, &(&1.event == "response.completed"))

    assert Map.keys(legacy_data) |> Enum.sort() ==
             ["response", "sequence_number", "type"]

    assert legacy_data["response"] == %{
             "id" => "resp_public_legacy",
             "custom" => %{"kept" => true},
             "status" => "completed"
           }

    assert done_state.sequence.terminal_latched?
    assert legacy_state.sequence.terminal_latched?
  end

  test "public adapters drop malformed success shapes without latching a false terminal" do
    malformed = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_public_malformed", "status" => "failed"}
    }

    {sse_output, sse_state} = normalize_sse(sse_event("response.completed", malformed))
    assert sse_output == ""
    refute sse_state.sequence.terminal_latched?

    websocket_state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:drop, ^websocket_state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(malformed),
               websocket_state
             )
  end

  @tag :task_1_fix_red
  test "oversized separator-free public POST terminals use structural normalization" do
    valid_cases = [
      {"response.done", done("resp_oversized_done")},
      {"response.completed", completed("resp_oversized_completed")}
    ]

    for {event_type, decoded} <- valid_cases do
      {first, second} = oversized_separator_free_sse(event_type, decoded)
      state = StreamProtocol.public_openai_responses_stream_state()

      assert {first_output, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(first, state)

      assert byte_size(first_output) == 0
      refute state.sequence.terminal_latched?

      assert {second_output, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(second, state)

      terminals = Enum.filter(public_events(second_output), &terminal_event?/1)
      assert Enum.map(terminals, & &1.event) == ["response.completed"]
      assert state.sequence.terminal_latched?
      assert state.terminal_kind == :completed
    end
  end

  @tag :task_1_fix_red
  test "oversized separator-free malformed public POST terminals stay malformed" do
    malformed_cases = [
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{"id" => "resp_oversized_conflict", "status" => "failed"}
       }},
      {"response.done", completed("resp_oversized_mismatch")},
      {"response.completed", %{"type" => "response.completed"}}
    ]

    for {event_type, decoded} <- malformed_cases do
      {first, second} = oversized_separator_free_sse(event_type, decoded)
      state = StreamProtocol.public_openai_responses_stream_state()

      assert {first_output, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(first, state)

      assert byte_size(first_output) == 0

      assert {second_output, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(second, state)

      assert byte_size(second_output) == 0
      refute state.sequence.terminal_latched?
      assert state.terminal_kind == nil
    end
  end

  @tag :task_1_fix_red
  test "every present non-empty event and data type mismatch is rejected" do
    nonterminal = "response.output_text.delta"

    mismatch_cases = [
      {"response.completed", done("resp_mismatch_completed_done")},
      {"response.done", completed("resp_mismatch_done_completed")},
      {"response.failed", terminal_shape(nonterminal, :failed)},
      {nonterminal, terminal_shape("response.failed", :failed)},
      {"response.incomplete", terminal_shape(nonterminal, :incomplete)},
      {nonterminal, terminal_shape("response.incomplete", :incomplete)},
      {"error", terminal_shape(nonterminal, :error)},
      {nonterminal, terminal_shape("error", :error)}
    ]

    for {event_type, decoded} <- mismatch_cases do
      assert StreamProtocol.terminal_outcome(event_type, decoded) == nil

      {output, state} = normalize_sse(sse_event(event_type, decoded))
      assert byte_size(output) == 0
      refute state.sequence.terminal_latched?
      assert state.terminal_kind == nil
    end
  end

  test "public POST assigns strictly increasing safe sequences and replaces invalid values" do
    max_safe = PublicResponsesSequence.max_safe_integer()

    events = [
      response_event("response.created", 2),
      response_event("response.in_progress", 2),
      response_event("response.output_text.delta", nil, %{"delta" => "a"}),
      response_event("response.output_text.done", -1, %{"text" => "a"}),
      response_event("response.output_item.added", "5"),
      response_event("response.output_item.done", 7.5),
      response_event("keepalive", max_safe + 1)
    ]

    {output, state} = normalize_sse(IO.iodata_to_binary(events))
    sequences = output |> public_events() |> Enum.map(& &1.data["sequence_number"])

    assert sequences == [2, 3, 4, 5, 6, 7, 8]
    assert state.sequence.max_seen == 8
    refute state.sequence.terminal_latched?
  end

  test "public POST emits one overflow failure at max safe and latches subsequent frames" do
    max_safe = PublicResponsesSequence.max_safe_integer()
    state = StreamProtocol.public_openai_responses_stream_state()
    state = put_in(state.sequence.max_seen, max_safe - 1)

    stream =
      IO.iodata_to_binary([
        response_event("response.output_text.delta", nil, %{"delta" => "not-relayed"}),
        sse_event("response.completed", completed("resp_after_overflow")),
        sse_event("response.failed", failed_without_nested_code("resp_duplicate"))
      ])

    {output, state} = StreamProtocol.normalize_public_openai_responses_sse_data(stream, state)
    events = public_events(output)

    assert [%{event: "response.failed", data: failed}] = events
    assert failed["sequence_number"] == max_safe
    assert failed["error"]["code"] == "response_sequence_exhausted"
    assert state.sequence.overflow_latched?
    assert state.sequence.terminal_latched?
  end

  test "public POST relays only the first valid terminal" do
    stream =
      IO.iodata_to_binary([
        sse_event("response.incomplete", incomplete("resp_first", nil)),
        sse_event("response.completed", completed("resp_second")),
        sse_event("response.failed", failed_without_nested_code("resp_third"))
      ])

    {output, state} = normalize_sse(stream)
    terminals = Enum.filter(public_events(output), &terminal_event?/1)

    assert [%{event: "response.incomplete"}] = terminals
    assert state.sequence.terminal_latched?
    assert state.terminal_kind == :incomplete
  end

  @tag :task_1_fix_red
  test "public POST and GET latch completed then done and duplicate failed only once" do
    cases = [
      {completed("resp_completed_first"), done("resp_done_second"), "response.completed"},
      {failed_without_nested_code("resp_failed_first"),
       failed_without_nested_code("resp_failed_second"), "response.failed"}
    ]

    for {first, second, expected_type} <- cases do
      stream =
        IO.iodata_to_binary([
          sse_event(first["type"], first),
          sse_event(second["type"], second)
        ])

      {post_output, post_state} = normalize_sse(stream)
      post_terminals = Enum.filter(public_events(post_output), &terminal_event?/1)

      assert Enum.map(post_terminals, & &1.event) == [expected_type]
      assert post_state.sequence.terminal_latched?

      websocket_state = StreamProtocol.public_openai_responses_websocket_state()

      assert {:push, first_payload, websocket_state} =
               StreamProtocol.normalize_public_openai_responses_websocket_data(
                 Jason.encode!(first),
                 websocket_state
               )

      assert Jason.decode!(first_payload)["type"] == expected_type

      assert {:drop, ^websocket_state} =
               StreamProtocol.normalize_public_openai_responses_websocket_data(
                 Jason.encode!(second),
                 websocket_state
               )

      assert websocket_state.terminal_latched?
    end
  end

  test "fresh public POST streams each restart sequence numbering at zero" do
    stream =
      IO.iodata_to_binary([
        response_event("response.created", nil),
        sse_event("response.completed", completed("resp_fresh"))
      ])

    for _turn <- 1..2 do
      {output, state} = normalize_sse(stream)
      assert output |> public_events() |> Enum.map(& &1.data["sequence_number"]) == [0, 1]
      assert state.sequence.max_seen == 1
    end
  end

  test "public websocket tracker normalizes success, isolates sequence state, and latches" do
    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, done_payload, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(done("resp_ws_done")),
               state
             )

    assert Jason.decode!(done_payload) == %{
             "type" => "response.completed",
             "sequence_number" => 0,
             "response" => %{
               "id" => "resp_ws_done",
               "status" => "completed"
             }
           }

    assert {:drop, ^state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(completed("resp_ws_late")),
               state
             )

    fresh = StreamProtocol.public_openai_responses_websocket_state()
    legacy = %{"id" => "resp_ws_legacy", "custom" => true}

    assert {:push, legacy_payload, _fresh_state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(legacy),
               fresh
             )

    assert Jason.decode!(legacy_payload) == %{
             "type" => "response.completed",
             "sequence_number" => 0,
             "response" => Map.put(legacy, "status", "completed")
           }
  end

  test "public websocket tracker emits one overflow error result then drops" do
    max_safe = PublicResponsesSequence.max_safe_integer()

    state =
      StreamProtocol.public_openai_responses_websocket_state()
      |> Map.put(:max_seen, max_safe - 1)

    nonterminal = Jason.encode!(%{"type" => "keepalive"})

    assert {:error, reason, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(nonterminal, state)

    assert reason == %{
             status: 500,
             code: :websocket_sequence_exhausted,
             message: "websocket response sequence exhausted",
             param: nil
           }

    assert {:drop, ^state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(completed("resp_ws_after_overflow")),
               state
             )
  end

  defp normalize_sse(stream) do
    StreamProtocol.normalize_public_openai_responses_sse_data(
      IO.iodata_to_binary(stream),
      StreamProtocol.public_openai_responses_stream_state()
    )
  end

  defp completed(id) do
    %{
      "type" => "response.completed",
      "response" => %{"id" => id, "status" => "completed"}
    }
  end

  defp done(id) do
    %{
      "type" => "response.done",
      "response" => %{"id" => id}
    }
  end

  defp incomplete(id, reason) do
    response = %{"id" => id, "status" => "incomplete"}

    response =
      if is_binary(reason) do
        Map.put(response, "incomplete_details", %{"reason" => reason})
      else
        response
      end

    %{"type" => "response.incomplete", "response" => response}
  end

  defp failed_without_nested_code(id) do
    %{
      "type" => "response.failed",
      "response" => %{"id" => id, "status" => "failed"}
    }
  end

  defp terminal_shape(type, :failed) do
    %{"type" => type, "response" => %{"id" => "resp_mismatch_failed", "status" => "failed"}}
  end

  defp terminal_shape(type, :incomplete) do
    %{
      "type" => type,
      "response" => %{"id" => "resp_mismatch_incomplete", "status" => "incomplete"}
    }
  end

  defp terminal_shape(type, :error) do
    %{"type" => type, "error" => %{"code" => "server_error"}}
  end

  defp oversized_separator_free_sse(event_type, decoded) do
    padding = String.duplicate("x", StreamProtocol.max_incomplete_sse_block_bytes() + 1_024)

    decoded =
      case Map.get(decoded, "response") do
        %{} = response -> Map.put(decoded, "response", Map.put(response, "padding", padding))
        _response -> Map.put(decoded, "padding", padding)
      end

    stream = IO.iodata_to_binary(["event: ", event_type, "\n", "data: ", Jason.encode!(decoded)])
    split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1

    {
      binary_part(stream, 0, split_at),
      binary_part(stream, split_at, byte_size(stream) - split_at)
    }
  end

  defp response_event(type, sequence, extra \\ %{}) do
    decoded = Map.merge(%{"type" => type}, extra)

    decoded =
      if is_nil(sequence), do: decoded, else: Map.put(decoded, "sequence_number", sequence)

    sse_event(type, decoded)
  end

  defp sse_event(type, decoded) do
    ["event: ", type, "\n", "data: ", Jason.encode!(decoded), "\n\n"]
  end

  defp sse_data(decoded), do: ["data: ", Jason.encode!(decoded), "\n\n"]

  defp public_events(output) do
    output
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.map(fn block ->
      %{
        event: StreamProtocol.sse_field(block, "event"),
        data: block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
      }
    end)
  end

  defp terminal_event?(%{event: event}) do
    event in ["response.completed", "response.failed", "response.incomplete", "error"]
  end
end
