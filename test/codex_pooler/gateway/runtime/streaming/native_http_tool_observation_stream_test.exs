defmodule CodexPooler.Gateway.Runtime.Streaming.NativeHttpToolObservationStreamTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.NativeHttpToolObservation
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @endpoint "/backend-api/codex/responses"

  test "every HTTP chunk boundary preserves the complete SSE observation and wire bytes" do
    wire = partial_tool_wire()

    for split <- 1..(byte_size(wire) - 1) do
      <<first::binary-size(^split), rest::binary>> = wire
      {output, state} = observe([first, rest])
      assert output == wire
      assert eligible?(state), "lost complete SSE authority at byte #{split}"
    end

    {output, state} = observe(for <<byte <- wire>>, do: <<byte>>)
    assert output == wire
    assert eligible?(state)
  end

  test "a complete final JSON event is observed at EOF without a blank separator" do
    wire = String.trim_trailing(partial_tool_wire(), "\n")
    {output, state} = observe([wire])
    refute eligible?(state)
    {tail, state} = DownstreamStream.flush_eof_data(@endpoint, opts(), state)
    assert output <> tail == wire <> "\n\n"
    assert eligible?(state)
  end

  test "unparsed residue, unknown events and oversized input cannot restore authority" do
    for suffix <- [
          "event: response.custom_tool_call_input.delta\ndata: {",
          "unparsed bytes",
          "event: response.unknown\ndata: {\"type\":\"response.unknown\"}\n\n",
          "event: response.custom_tool_call_input.delta\ndata: " <> String.duplicate("x", StreamProtocol.max_incomplete_sse_block_bytes() + 1)
        ] do
      {_output, state} = observe([partial_tool_wire(), suffix])
      refute eligible?(state)
      {_tail, state} = DownstreamStream.flush_eof_data(@endpoint, opts(), state)
      refute eligible?(state)
      {_output, state} = DownstreamStream.normalize_data(partial_tool_wire(), @endpoint, opts(), state)
      refute eligible?(state)
    end
  end

  defp observe(chunks) do
    initial = :relay |> DownstreamStream.initial_state(opts()) |> DownstreamStream.enable_native_http_tool_observation()

    Enum.reduce(chunks, {"", initial}, fn chunk, {output, state} ->
      {data, state} = DownstreamStream.normalize_data(chunk, @endpoint, opts(), state)
      {output <> IO.iodata_to_binary(data), state}
    end)
  end

  defp eligible?(state),
    do: state |> DownstreamStream.native_http_tool_metadata() |> Map.fetch!("native_http_partial_tool") |> NativeHttpToolObservation.eligible_metadata?()

  defp opts, do: RequestOptions.build(%{transport: "http_sse"}, @endpoint, %{})

  defp partial_tool_wire do
    events = [
      %{"type" => "response.created", "response" => %{"status" => "in_progress", "output" => []}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => "ctc_synthetic", "type" => "custom_tool_call", "name" => "sample_tool", "call_id" => "call_synthetic", "status" => "in_progress"}},
      %{"type" => "response.custom_tool_call_input.delta", "item_id" => "ctc_synthetic", "output_index" => 0, "delta" => "synthetic"},
      %{"type" => "response.custom_tool_call_input.done", "item_id" => "ctc_synthetic", "output_index" => 0, "input" => "synthetic"}
    ]

    ": keepalive\n\n" <> Enum.map_join(events, fn event -> "event: #{event["type"]}\ndata: #{CodexPooler.JSON.encode!(event)}\n\n" end)
  end
end
