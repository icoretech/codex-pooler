defmodule CodexPooler.Gateway.Transports.SSEParserIncrementalTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @moduletag :sse_parser_incremental

  # Reference copy of the pre-incremental implementation (single-pass CRLF
  # replace, full rescan per call). The incremental three-arity form must be
  # observationally identical for every stream without a bare CR adjacent to a
  # CRLF pair, under every chunking.
  defp reference_complete_sse_blocks(data, bounded?) do
    data = String.replace(data, "\r\n", "\n")

    if String.contains?(data, "\n\n") do
      parts = String.split(data, "\n\n")
      ends_with_separator? = String.ends_with?(data, "\n\n")

      {complete, buffer} =
        if ends_with_separator? do
          {parts, ""}
        else
          {Enum.drop(parts, -1), List.last(parts) || ""}
        end

      {Enum.reject(complete, &(&1 == "")), reference_bound(buffer, bounded?)}
    else
      {[], reference_bound(data, bounded?)}
    end
  end

  defp reference_bound(buffer, false), do: buffer

  defp reference_bound(buffer, true) do
    if byte_size(buffer) > StreamProtocol.max_incomplete_sse_block_bytes(), do: "", else: buffer
  end

  defp fold_incremental(chunks, bounded?) do
    Enum.reduce(chunks, {[], ""}, fn chunk, {blocks, residue} ->
      {new_blocks, residue} =
        StreamProtocol.complete_sse_blocks(residue, chunk, bounded?: bounded?)

      {blocks ++ new_blocks, residue}
    end)
  end

  defp fold_reference(chunks, bounded?) do
    Enum.reduce(chunks, {[], ""}, fn chunk, {blocks, residue} ->
      {new_blocks, residue} = reference_complete_sse_blocks(residue <> chunk, bounded?)
      {blocks ++ new_blocks, residue}
    end)
  end

  defp fold_current_two_arity(chunks, bounded?) do
    Enum.reduce(chunks, {[], ""}, fn chunk, {blocks, residue} ->
      {new_blocks, residue} =
        StreamProtocol.complete_sse_blocks(residue <> chunk, bounded?: bounded?)

      {blocks ++ new_blocks, residue}
    end)
  end

  defp random_stream(rng) do
    {event_count, rng} = rand_range(rng, 1, 8)

    {events, rng} =
      Enum.map_reduce(1..event_count, rng, fn _index, rng ->
        {newline, rng} = rand_pick(rng, ["\n", "\r\n"])
        {label?, rng} = rand_pick(rng, [true, false])
        {payload_size, rng} = rand_range(rng, 0, 2_000)
        {payload, rng} = rand_alnum(rng, payload_size)
        {line_count, rng} = rand_range(rng, 1, 3)

        label = if label?, do: "event: response.output_text.delta" <> newline, else: ""

        data_lines =
          Enum.map_join(1..line_count, "", fn line ->
            ~s(data: {"type":"response.output_text.delta","line":#{line},"delta":"#{payload}"}) <>
              newline
          end)

        {label <> data_lines <> newline, rng}
      end)

    {trailing?, rng} = rand_pick(rng, [true, false])

    {tail, rng} =
      if trailing? do
        {tail_size, rng} = rand_range(rng, 1, 400)
        {tail_payload, rng} = rand_alnum(rng, tail_size)
        {"data: {\"incomplete\":\"" <> tail_payload, rng}
      else
        {"", rng}
      end

    {IO.iodata_to_binary(events) <> tail, rng}
  end

  defp random_chunking(rng, stream) do
    size = byte_size(stream)

    if size == 0 do
      {[""], rng}
    else
      {cut_count, rng} = rand_range(rng, 0, min(size - 1, 24))

      {cuts, rng} =
        Enum.map_reduce(1..max(cut_count, 1), rng, fn _index, rng ->
          rand_range(rng, 1, size - 1)
        end)

      cuts = if cut_count == 0, do: [], else: cuts

      boundaries = Enum.sort(Enum.uniq([0 | cuts] ++ [size]))

      chunks =
        boundaries
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> binary_part(stream, from, to - from) end)

      {chunks, rng}
    end
  end

  defp rand_range(rng, low, high) do
    {value, rng} = :rand.uniform_s(high - low + 1, rng)
    {low + value - 1, rng}
  end

  defp rand_pick(rng, choices) do
    {index, rng} = rand_range(rng, 0, length(choices) - 1)
    {Enum.at(choices, index), rng}
  end

  @alnum ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

  defp rand_alnum(rng, size) do
    {chars, rng} =
      Enum.map_reduce(0..size//1, rng, fn _index, rng ->
        {index, rng} = rand_range(rng, 0, length(@alnum) - 1)
        {Enum.at(@alnum, index), rng}
      end)

    {List.to_string(Enum.drop(chars, 1)), rng}
  end

  test "incremental parsing matches the reference for random streams and chunkings" do
    rng = :rand.seed_s(:exsss, {20_260_729, 8, 15})

    Enum.reduce(1..200, rng, fn iteration, rng ->
      {stream, rng} = random_stream(rng)
      {chunks, rng} = random_chunking(rng, stream)

      {reference_blocks, reference_residue} = fold_reference(chunks, false)
      {incremental_blocks, incremental_residue} = fold_incremental(chunks, false)
      {two_arity_blocks, two_arity_residue} = fold_current_two_arity(chunks, false)

      assert incremental_blocks == reference_blocks,
             "iteration #{iteration}: block mismatch for chunking #{inspect(Enum.map(chunks, &byte_size/1))}"

      assert incremental_residue == reference_residue,
             "iteration #{iteration}: residue mismatch"

      assert two_arity_blocks == reference_blocks
      assert two_arity_residue == reference_residue

      rng
    end)
  end

  test "incremental parsing is chunking independent" do
    rng = :rand.seed_s(:exsss, {20_260_729, 16, 23})

    Enum.reduce(1..100, rng, fn _iteration, rng ->
      {stream, rng} = random_stream(rng)
      {chunks_a, rng} = random_chunking(rng, stream)
      {chunks_b, rng} = random_chunking(rng, stream)

      assert fold_incremental(chunks_a, false) == fold_incremental(chunks_b, false)
      assert fold_incremental([stream], false) == fold_incremental(chunks_a, false)

      rng
    end)
  end

  test "single-byte chunking crosses every junction identically" do
    stream =
      ~s(event: response.created\r\ndata: {"type":"response.created"}\r\n\r\n) <>
        ~s(data: {"type":"response.output_text.delta","delta":"ab"}\n\n) <>
        ~s(data: {"trailing":"incomplete)

    chunks = for <<byte::binary-size(1) <- stream>>, do: byte

    assert fold_incremental(chunks, false) == fold_reference(chunks, false)
    assert fold_incremental(chunks, false) == fold_incremental([stream], false)
  end

  test "separator split across the residue junction is still detected" do
    for {first, second} <- [
          {"data: a\n", "\ndata: b\n\n"},
          {"data: a", "\n\ndata: b\n\n"},
          {"data: a\r", "\ndata: b\r\n\r\n"},
          {"data: a\r\n", "\r\ndata: b\r\n\r\n"},
          # A retained CR tail pairing with a bare LF chunk: dropping the
          # ends_with?(residue, "\r") junction guard withholds this block.
          {"data: a\r\n\r", "\n"}
        ] do
      assert fold_incremental([first, second], false) ==
               fold_reference([first, second], false)
    end
  end

  test "a partially collapsed CR run cannot hide a separator across chunks" do
    # "\n\r\r\n" single-pass collapses to "\n\r\n"; the fixpoint collapse
    # reaches "\n\n" and splits. The retained-residue invariant depends on it.
    chunks = ["data: a\n\r\r", "\ndata: b\n\n"]

    {blocks, residue} = fold_incremental(chunks, false)

    assert blocks == ["data: a", "data: b"]
    assert residue == ""

    assert {["data: a", "data: b"], ""} =
             StreamProtocol.complete_sse_blocks("data: a\n\r\r\ndata: b\n\n", bounded?: false)
  end

  defp random_public_stream(rng) do
    created =
      ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_prop"}}\n\n)

    {delta_count, rng} = rand_range(rng, 0, 4)

    {deltas, rng} =
      Enum.map_reduce(0..delta_count//1, rng, fn index, rng ->
        {embed_marker?, rng} = rand_pick(rng, [true, false])
        {payload_size, rng} = rand_range(rng, 0, 600)
        {payload, rng} = rand_alnum(rng, payload_size)

        payload =
          if embed_marker?,
            do: payload <> "response.completed response.incomplete " <> payload,
            else: payload

        {~s(data: {"type":"response.output_text.delta","delta":"#{payload} #{index}"}\n\n), rng}
      end)

    {tail_kind, rng} = rand_pick(rng, [:none, :separator_terminal, :bare_terminal, :partial])

    {tail, rng} =
      case tail_kind do
        :none ->
          {"", rng}

        :separator_terminal ->
          {~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_prop","status":"completed"}}\n\n),
           rng}

        :bare_terminal ->
          {~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_prop","status":"completed"}}),
           rng}

        :partial ->
          {partial_size, rng} = rand_range(rng, 1, 300)
          {partial, rng} = rand_alnum(rng, partial_size)
          {~s(data: {"type":"response.output_text.delta","delta":"#{partial}), rng}
      end

    {created <> IO.iodata_to_binary(deltas) <> tail, rng}
  end

  defp fold_public_normalizer(chunks) do
    {outputs, state} =
      Enum.map_reduce(chunks, StreamProtocol.public_openai_responses_stream_state(), fn chunk,
                                                                                        state ->
        StreamProtocol.normalize_public_openai_responses_sse_data(chunk, state)
      end)

    summary =
      state
      |> StreamProtocol.PublicResponses.summary_metadata()
      |> Map.drop(["source_chunk_count"])

    {IO.iodata_to_binary(outputs), state.buffer, state.terminal_kind, summary}
  end

  test "public responses normalization is chunking independent with embedded markers" do
    rng = :rand.seed_s(:exsss, {20_260_729, 42, 57})

    Enum.reduce(1..80, rng, fn iteration, rng ->
      {stream, rng} = random_public_stream(rng)
      {chunks, rng} = random_chunking(rng, stream)

      single_shot = fold_public_normalizer([stream])
      chunked = fold_public_normalizer(chunks)

      assert chunked == single_shot,
             "iteration #{iteration}: chunked public normalization diverged for " <>
               "chunking #{inspect(Enum.map(chunks, &byte_size/1))}"

      rng
    end)
  end

  test "public responses terminal handling is chunking independent at every terminal position" do
    created =
      ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_terminal_positions"}}\n\n)

    terminal =
      ~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_terminal_positions","status":"completed"}}\n\n)

    partial = ~s(data: {"type":"response.output_text.delta","delta":"partial)

    for chunks <- [
          [created <> terminal <> partial],
          [created, terminal <> partial],
          [created <> terminal, partial],
          [created, terminal, partial]
        ] do
      assert fold_public_normalizer(chunks) ==
               fold_public_normalizer([created <> terminal <> partial])
    end
  end

  test "adversarial CR runs collapse to the separator fixpoint in linear time" do
    cr_run = String.duplicate("\r", 200_000)

    {elapsed_us, {blocks, residue}} =
      :timer.tc(fn ->
        StreamProtocol.complete_sse_blocks(
          "data: a" <> cr_run <> "\ndata: b\n\n",
          bounded?: false
        )
      end)

    assert blocks == ["data: a\ndata: b"]
    assert residue == ""

    # One collapse pass, not one scan per CR: the pre-fix fixpoint loop needed
    # minutes here.
    assert elapsed_us < 5_000_000

    assert {["data: a"], ""} =
             StreamProtocol.complete_sse_blocks("data: a\r\r\r\r\r\n\n", bounded?: false)
  end

  test "bounded incremental accumulation drops an oversized residue like the reference" do
    cap = StreamProtocol.max_incomplete_sse_block_bytes()
    piece = "data: " <> String.duplicate("x", 1_048_576)
    chunks = List.duplicate(piece, div(cap, byte_size(piece)) + 2)

    {incremental_blocks, incremental_residue} = fold_incremental(chunks, true)
    {reference_blocks, reference_residue} = fold_reference(chunks, true)

    assert incremental_blocks == reference_blocks
    assert incremental_residue == reference_residue
    assert incremental_blocks == []

    # The accumulated residue crossed the bound mid-fold and was dropped, so
    # only the post-drop refill survives instead of the full accumulation.
    assert byte_size(incremental_residue) == byte_size(piece)
  end
end
