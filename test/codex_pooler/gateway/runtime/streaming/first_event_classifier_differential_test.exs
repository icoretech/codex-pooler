defmodule CodexPooler.Gateway.Runtime.Streaming.FirstEventClassifierDifferentialTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Streaming.SSEParser
  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @moduletag :first_event_classifier_differential
  @seed {20_260_729, 73, 91}

  defmodule Reference do
    @moduledoc false

    alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

    @max_leading_sse_blocks 32

    def first_event_state, do: %{classified?: false, buffer: ""}

    def classify_first_event(data, state, assignment_advertised? \\ nil)
        when is_binary(data) do
      if state.classified? do
        classify_after_first_event(data)
      else
        classify_before_first_event(data, state.buffer, assignment_advertised?)
      end
    end

    defp classify_after_first_event(data) do
      classification =
        case StreamProtocol.terminal_outcome(data) do
          {:ok, %{kind: :failed, failure: failure}} ->
            {:write_terminal_failure, data, failure}

          _outcome ->
            {:write, data}
        end

      {classification, %{classified?: true, buffer: ""}}
    end

    defp classify_before_first_event(data, buffer, assignment_advertised?) do
      buffer = buffer <> data

      case first_retry_window_event(buffer) do
        {:ok, event} -> classify_complete(buffer, event, assignment_advertised?)
        :non_visible_complete -> {{:write, buffer}, first_event_state()}
        :classification_limit -> {{:write, buffer}, %{classified?: true, buffer: ""}}
        :incomplete -> classify_incomplete(buffer)
      end
    end

    defp first_retry_window_event(buffer) do
      {blocks, remaining} = StreamProtocol.complete_sse_blocks(buffer, bounded?: false)
      leading_blocks = Enum.take(blocks, @max_leading_sse_blocks)

      case Enum.find_value(leading_blocks, &retry_window_event/1) do
        {:ok, event} -> {:ok, event}
        nil when blocks == [] -> direct_retry_window_event(buffer)
        nil when length(blocks) > @max_leading_sse_blocks -> :classification_limit
        nil when remaining == "" -> :non_visible_complete
        nil -> :incomplete
      end
    end

    defp retry_window_event(block) do
      case StreamProtocol.first_complete_event(block <> "\n\n") do
        {:ok, event} ->
          if StreamProtocol.downstream_visible_event?(event) or
               not is_nil(StreamProtocol.terminal_outcome_event(event)),
             do: {:ok, event}

        :incomplete ->
          nil
      end
    end

    defp direct_retry_window_event(buffer) do
      case StreamProtocol.first_complete_event(buffer) do
        {:ok, event} ->
          if StreamProtocol.downstream_visible_event?(event),
            do: {:ok, event},
            else: :incomplete

        :incomplete ->
          :incomplete
      end
    end

    defp classify_incomplete(buffer) do
      if StreamProtocol.oversized_incomplete_sse_block?(buffer) do
        {{:write, buffer}, %{classified?: true, buffer: ""}}
      else
        {:buffered, %{classified?: false, buffer: buffer}}
      end
    end

    defp classify_complete(buffer, event, assignment_advertised?) do
      classification =
        case retryable_failure(event, assignment_advertised?) do
          {:ok, failure} -> {:retry, failure}
          :error -> classify_non_retryable(buffer, event)
        end

      state =
        if StreamProtocol.internal_rate_limit_event?(event),
          do: first_event_state(),
          else: %{classified?: true, buffer: ""}

      {classification, state}
    end

    defp retryable_failure(event, nil),
      do: StreamProtocol.retryable_first_terminal_failure(event)

    defp retryable_failure(event, assignment_advertised?),
      do: StreamProtocol.retryable_first_terminal_failure(event, assignment_advertised?)

    defp classify_non_retryable(buffer, event) do
      if StreamProtocol.internal_rate_limit_event?(event) do
        {:write, buffer}
      else
        case StreamProtocol.terminal_outcome_event(event) do
          {:ok, %{kind: :failed, failure: failure}} ->
            {:write_terminal_failure, buffer, failure}

          _outcome ->
            {:write, buffer}
        end
      end
    end
  end

  test "today's classifier matches the source-anchored reference across seeded chunkings" do
    rng = :rand.seed_s(:exsss, @seed)

    Enum.reduce(1..160, rng, fn iteration, rng ->
      {label, stream, assignment_advertised?, rng} = random_stream(rng)
      {chunks, rng} = random_chunking(rng, stream)

      assert_fold_equivalent(
        label,
        iteration,
        chunks,
        assignment_advertised?,
        &Reference.classify_first_event/3,
        &StreamAttempt.classify_first_event/3
      )

      rng
    end)
  end

  test "exact internal controls remain pre-visible across SSE and direct JSON" do
    for type <- ["codex.rate_limits", "codex.response.metadata"] do
      sse = sse_event(type, %{"type" => type})

      assert {{:write, ^sse}, sse_state} =
               StreamAttempt.classify_first_event(sse, StreamAttempt.first_event_state())

      assert state_projection(sse_state) == %{classified?: false, buffer: ""}

      direct = Jason.encode!(%{"type" => type})

      assert {:buffered, direct_state} =
               StreamAttempt.classify_first_event(direct, StreamAttempt.first_event_state())

      assert state_projection(direct_state) == %{classified?: false, buffer: direct}

      assert_fold_equivalent(
        type,
        0,
        [sse],
        false,
        &Reference.classify_first_event/3,
        &StreamAttempt.classify_first_event/3
      )
    end
  end

  test "unknown Codex controls commit visible output in SSE and direct JSON" do
    type = "codex.future_control"

    for data <- [sse_event(type, %{"type" => type}), Jason.encode!(%{"type" => type})] do
      assert {{:write, ^data}, state} =
               StreamAttempt.classify_first_event(data, StreamAttempt.first_event_state())

      assert state_projection(state) == %{classified?: true, buffer: ""}

      assert_fold_equivalent(
        type,
        0,
        [data],
        false,
        &Reference.classify_first_event/3,
        &StreamAttempt.classify_first_event/3
      )
    end
  end

  test "standalone-CR terminal framing commits the first event immediately" do
    terminal =
      "event: response.completed\rdata: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{"id" => "resp_first_cr", "status" => "completed"}
        }) <>
        "\r\r"

    assert {{:write, ^terminal}, state} =
             StreamAttempt.classify_first_event(
               terminal,
               StreamAttempt.first_event_state(),
               false
             )

    assert state_projection(state) == %{classified?: true, buffer: ""}
  end

  test "malformed and incomplete data remains buffered rather than becoming internal" do
    for data <- ["{", ~s({"type":), "event: codex.response.metadata\ndata: {"] do
      refute StreamProtocol.internal_control_event?(data)

      assert {:buffered, state} =
               StreamAttempt.classify_first_event(data, StreamAttempt.first_event_state())

      assert state_projection(state) == %{classified?: false, buffer: data}
    end
  end

  test "leading empty SSE block bytes remain in buffered state and the eventual visible write" do
    visible = sse_event("response.created", %{"type" => "response.created"})
    chunks = ["\n\n", visible]

    assert_fold_equivalent(
      :leading_empty_block,
      0,
      chunks,
      false,
      &Reference.classify_first_event/3,
      &StreamAttempt.classify_first_event/3
    )

    assert {:buffered, state} =
             StreamAttempt.classify_first_event("\n\n", StreamAttempt.first_event_state())

    assert state.buffer == "\n\n"

    assert {{:write, "\n\n" <> ^visible}, _state} =
             StreamAttempt.classify_first_event(visible, state)
  end

  test "parser residue owns a bounded copy of a slice from a much larger binary" do
    parent = :binary.copy("x", 8 * 1_048_576)
    slice = binary_part(parent, 0, 16_384)

    assert {:buffered, state} =
             StreamAttempt.classify_first_event(slice, StreamAttempt.first_event_state())

    retained = state.parser.block_state.buffer
    assert retained == slice
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
  end

  test "materialized parser residue owns only its retained bytes" do
    parent = :binary.copy("x", 8 * 1_048_576)
    first = binary_part(parent, 0, 16_384)
    second = "\n\nremainder"

    assert {:buffered, state} =
             StreamAttempt.classify_first_event(first, StreamAttempt.first_event_state())

    assert {:buffered, state} = StreamAttempt.classify_first_event(second, state)
    retained = state.parser.block_state.buffer

    assert byte_size(retained) == byte_size("remainder")
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
  end

  test "production compilation omits test-only gates and buffers ordinary residue" do
    source = Path.expand("lib/codex_pooler/gateway/runtime/streaming/stream_attempt.ex")

    compile_dir =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-stream-attempt-prod-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(compile_dir)
    on_exit(fn -> File.rm_rf!(compile_dir) end)

    code_path_args =
      Enum.flat_map(:code.get_path(), fn code_path ->
        ["-pa", List.to_string(code_path)]
      end)

    elixirc = System.find_executable("elixirc") || flunk("elixirc executable not found")

    {compile_output, compile_status} =
      System.cmd(
        elixirc,
        [
          "-e",
          "Mix.start(); Mix.env(:prod)",
          "--ignore-module-conflict",
          "--warnings-as-errors",
          "-o",
          compile_dir
        ] ++
          code_path_args ++ [source],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert compile_status == 0, compile_output

    script = """
    module = CodexPooler.Gateway.Runtime.Streaming.StreamAttempt
    false = function_exported?(module, :classify_first_event, 4)

    {:buffered, state} = module.classify_first_event("ordinary", module.first_event_state())
    {:buffered, state} = module.classify_first_event("\\n\\nremainder", state)

    true = state.buffer == "ordinary\\n\\nremainder"
    "remainder" = state.parser.block_state.buffer
    IO.puts("production ordinary residue: ok")
    """

    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    {output, status} =
      System.cmd(
        elixir,
        code_path_args ++ ["-pa", compile_dir, "-e", script],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "production ordinary residue: ok"
  end

  for {gate, chunks} <- [
        chunk_newline: ["junk", "\nevent: response.output_text.delta\njunk"],
        event_prefix: ["eve", "nt: response.output_text.delta"],
        json_closing_brace: [~s({"type":"response.output_text.delta"), "}"]
      ] do
    @gate gate
    @chunks chunks

    test "production classifier requires the #{@gate} direct gate" do
      assert [{:buffered, _first_state}, {{:write, _bytes}, _second_state}] =
               classify_chunks(@chunks, all_direct_gates())

      gates = all_direct_gates() -- [@gate]

      assert [{:buffered, _first_state}, {:buffered, _second_state}] =
               classify_chunks(@chunks, gates)
    end
  end

  test "direct-path gates are each required by a pinned classification junction" do
    cases = [
      {:chunk_newline, "event: response.output_text.delta\ndata: {}", "\n"},
      {:event_prefix, "event: response.output_text", ".delta"},
      {:json_closing_brace, ~s({"type":"response.output_text.delta"), "}"}
    ]

    Enum.each(cases, fn {dropped_gate, first, second} ->
      state = parser_state_after(first)
      buffer = first <> second
      gates = [:chunk_newline, :event_prefix, :json_closing_brace] -- [dropped_gate]

      assert SSEParser.direct_rescan?(state, second, String.contains?(second, "\n"))

      refute SSEParser.direct_rescan?(
               state,
               second,
               String.contains?(second, "\n"),
               gates
             )

      assert {:ok, event} = direct_result(buffer, state, second)
      assert StreamProtocol.downstream_visible_event?(event)
      assert direct_result(buffer, state, second, gates) == :incomplete
    end)
  end

  test "carriage return activates the chunk-newline direct-path gate" do
    first = ~s(data: {"type":"response.output_text.delta")
    state = parser_state_after(first)
    {[], _state, line_break?} = SSEParser.complete_blocks(state, first <> "\r", "\r")

    assert line_break?
    assert SSEParser.direct_rescan?(state, "\r", line_break?)

    refute SSEParser.direct_rescan?(
             state,
             "\r",
             line_break?,
             [:event_prefix, :json_closing_brace]
           )
  end

  test "closing-brace gate preserves trailing whitespace semantics" do
    state = parser_state_after(~s({"type":"response.output_text.delta"))

    for suffix <- ["}\t\v\f\r\n ", "}\u00A0"] do
      assert SSEParser.direct_rescan?(state, suffix, String.contains?(suffix, "\n"))
    end

    refute SSEParser.direct_rescan?(state, "x\u00A0", false)
  end

  test "incremental parser state advances residue, block count, and match without changing raw bytes" do
    chunks = [
      "event: response.reasoning_summary_part.added\ndata: {\"type\":\"response.reasoning_summary_part.added\"}\n\n",
      "data: {\"type\":\"response.created\"",
      "}\r\n\r\n"
    ]

    {results, state} =
      Enum.map_reduce(chunks, StreamAttempt.first_event_state(), fn chunk, state ->
        {classification, state} = StreamAttempt.classify_first_event(chunk, state)
        {{classification, state}, state}
      end)

    assert [
             {{:write, first}, first_state},
             {:buffered, buffered_state},
             {{:write, second}, end_state}
           ] =
             Enum.map(results, &classification_projection/1)

    assert first == Enum.at(chunks, 0)
    assert second == Enum.at(chunks, 1) <> Enum.at(chunks, 2)
    assert first_state == %{classified?: false, buffer: ""}
    assert buffered_state.classified? == false
    assert end_state == %{classified?: true, buffer: ""}
    assert_classified_parser_state(state)
  end

  defp assert_fold_equivalent(label, iteration, chunks, assignment_advertised?, left, right) do
    left_state = Reference.first_event_state()
    right_state = StreamAttempt.first_event_state()

    Enum.reduce(Enum.with_index(chunks, 1), {left_state, right_state}, fn {chunk, index},
                                                                          {left_state,
                                                                           right_state} ->
      {left_classification, left_state} = left.(chunk, left_state, assignment_advertised?)
      {right_classification, right_state} = right.(chunk, right_state, assignment_advertised?)

      equivalent? =
        left_classification == right_classification and
          state_projection(left_state) == state_projection(right_state)

      unless equivalent? do
        flunk(
          "#{label} iteration=#{iteration} chunk=#{index} sizes=#{inspect(Enum.map(chunks, &byte_size/1))}"
        )
      end

      {left_state, right_state}
    end)
  end

  defp state_projection(state), do: Map.take(state, [:classified?, :buffer])

  defp classify_chunks(chunks, gates) do
    {classifications, _state} =
      Enum.map_reduce(chunks, StreamAttempt.first_event_state(), fn chunk, state ->
        {classification, state} =
          StreamAttempt.classify_first_event(chunk, state, false, direct_gates: gates)

        {{classification, state_projection(state)}, state}
      end)

    classifications
  end

  defp all_direct_gates, do: [:chunk_newline, :event_prefix, :json_closing_brace]

  defp parser_state_after(chunk) do
    {[], state, _newline?} = SSEParser.complete_blocks(SSEParser.new_state(), chunk, chunk)
    state
  end

  defp direct_result(
         buffer,
         state,
         data,
         gates \\ [:chunk_newline, :event_prefix, :json_closing_brace]
       ) do
    if SSEParser.direct_rescan?(state, data, String.contains?(data, "\n"), gates) do
      StreamProtocol.first_complete_event(buffer)
    else
      :incomplete
    end
  end

  defp classification_projection({classification, state}),
    do: {classification, state_projection(state)}

  defp assert_classified_parser_state(state) do
    assert state == %{
             classified?: true,
             buffer: "",
             parser: %{
               block_state: %{buffer: "", skip_leading_lf?: false},
               residue_empty?: true,
               blocks_seen: 0,
               matched: nil,
               line_skip_leading_lf?: false
             }
           }
  end

  defp random_stream(rng) do
    {kind, rng} =
      rand_pick(rng, [:sse, :direct, :rate_limit, :terminal, :crlf, :reset, :leading_empty])

    {payload_size, rng} = rand_range(rng, 0, 600)
    {payload, rng} = rand_alnum(rng, payload_size)
    {assignment_advertised?, rng} = rand_pick(rng, [true, false])

    stream = stream_for(kind, payload)
    {kind, stream, assignment_advertised?, rng}
  end

  defp stream_for(:sse, payload) do
    sse_event("response.output_text.delta", %{
      "type" => "response.output_text.delta",
      "delta" => payload
    })
  end

  defp stream_for(:direct, payload) do
    Jason.encode!(%{"type" => "response.output_text.delta", "delta" => payload})
  end

  defp stream_for(:rate_limit, payload) do
    sse_event("codex.rate_limits", %{"type" => "codex.rate_limits", "marker" => payload}) <>
      sse_event("response.created", %{"type" => "response.created"})
  end

  defp stream_for(:terminal, payload) do
    sse_event("response.failed", %{
      "type" => "response.failed",
      "response" => %{"error" => %{"code" => "server_error", "param" => payload}}
    })
  end

  defp stream_for(:crlf, payload) do
    stream_for(:sse, payload) |> String.replace("\n", "\r\n")
  end

  defp stream_for(:reset, payload) do
    sse_event("response.reasoning_summary_part.added", %{
      "type" => "response.reasoning_summary_part.added",
      "item" => %{"id" => payload}
    })
  end

  defp stream_for(:leading_empty, payload), do: "\n\n" <> stream_for(:sse, payload)

  defp sse_event(event, payload) do
    "event: " <> event <> "\ndata: " <> Jason.encode!(payload) <> "\n\n"
  end

  defp random_chunking(rng, stream) do
    size = byte_size(stream)
    {cut_count, rng} = rand_range(rng, 0, min(max(size - 1, 0), 24))

    {cuts, rng} =
      Enum.map_reduce(1..cut_count//1, rng, fn _index, rng -> rand_range(rng, 1, size - 1) end)

    boundaries = Enum.sort(Enum.uniq([0 | cuts] ++ [size]))

    chunks =
      boundaries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> binary_part(stream, from, to - from) end)

    {chunks, rng}
  end

  defp rand_range(rng, low, high) when low <= high do
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
      Enum.map_reduce(1..size//1, rng, fn _index, rng ->
        {index, rng} = rand_range(rng, 0, length(@alnum) - 1)
        {Enum.at(@alnum, index), rng}
      end)

    {List.to_string(chars), rng}
  end
end
