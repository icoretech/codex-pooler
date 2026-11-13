defmodule CodexPooler.Gateway.Runtime.Streaming.NativeSSEBlockTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Runtime.Streaming.NativeSSEBlock
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @endpoint "/backend-api/codex/responses"

  test "canonical native terminal delivery keeps original request-local evidence" do
    for code <- ~w(budget_reached inference_hook_denied content_policy_violation invalid_access_program unsupported_access_program access_program_not_enabled), type <- ["error", "response.failed", "response.incomplete"], type_only? <- [false, true] do
      error = if type_only?, do: %{"type" => code}, else: %{"code" => code}
      source = event(type, %{"type" => type, "error" => error, "response" => %{"error" => error}})
      {wire, block} = source |> NativeSSEBlock.parse() |> NativeSSEBlock.normalize(false)
      assert %{parts: [%{outcome: {:ok, %{failure: failure}}}]} = NativeSSEBlock.delivery([{wire, block}])
      assert Map.get(failure, :request_local_terminal?) == true == (type != "response.incomplete" and not type_only?)
    end
  end

  test "delivery evidence agrees with byte-based classification for original and rewritten events" do
    for block <- blocks(), private? <- [false, true] do
      parsed = NativeSSEBlock.parse(block)
      {wire, normalized} = NativeSSEBlock.normalize(parsed, private?)
      data = IO.iodata_to_binary(wire)

      expected =
        if private?,
          do: StreamProtocol.normalize_private_native_misalignment_sse_block(block),
          else: StreamProtocol.normalize_codex_responses_sse_block(block)

      assert data == IO.iodata_to_binary(expected)
      assert_delivery(NativeSSEBlock.delivery([{wire, normalized}]), data)
    end
  end

  test "batched preambles and terminals preserve partition order and normalized meaning" do
    outputs =
      for block <- blocks() do
        block |> NativeSSEBlock.parse() |> NativeSSEBlock.normalize(true)
      end

    wire = outputs |> Enum.map(&elem(&1, 0)) |> IO.iodata_to_binary()
    assert_delivery(NativeSSEBlock.delivery(outputs), wire)
  end

  test "direct detail fallback applies to one kept JSON object, not concatenated objects" do
    preamble = hd(blocks())
    detail = "{\"detail\":\"synthetic failure\"}"

    for blocks <- [
          [detail],
          [preamble, detail],
          [detail, detail],
          [preamble, detail, detail],
          [detail, " "]
        ] do
      outputs =
        Enum.map(blocks, fn block ->
          block |> NativeSSEBlock.parse() |> NativeSSEBlock.normalize(false)
        end)

      wire = outputs |> Enum.map(&elem(&1, 0)) |> IO.iodata_to_binary()
      assert_delivery(NativeSSEBlock.delivery(outputs), wire)
    end
  end

  test "native delivery evidence stays ephemeral across every two-chunk split and EOF" do
    opts = RequestOptions.build(%{}, @endpoint, %{})

    input =
      event("response.created", %{"type" => "response.created"}) <>
        event("response.output_item.done", %{
          "type" => "response.output_item.done",
          "item" => %{"type" => "reasoning"}
        }) <>
        event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"status" => "completed"}
        })

    for ending <- ["\n", "\r", "\r\n"] do
      input = String.replace(input, "\n", ending)

      for split <- 0..byte_size(input) do
        <<left::binary-size(^split), right::binary>> = input
        state = DownstreamStream.initial_state(:relay, opts)

        {first, state, delivery} =
          DownstreamStream.normalize_delivery(left, @endpoint, opts, state)

        if delivery, do: assert_delivery(delivery, first)

        {second, state, delivery} =
          DownstreamStream.normalize_delivery(right, @endpoint, opts, state)

        if delivery, do: assert_delivery(delivery, second)
        refute contains_parsed_block?(state)
      end
    end

    terminal = event("response.completed", %{"type" => "response.completed", "response" => %{}})
    initial = DownstreamStream.initial_state(:relay, opts)

    {"", state, _delivery} =
      DownstreamStream.normalize_delivery(
        String.trim_trailing(terminal),
        @endpoint,
        opts,
        initial
      )

    {wire, state, delivery} = DownstreamStream.flush_eof_delivery(@endpoint, opts, state)
    assert wire == terminal
    assert_delivery(delivery, wire)
    assert DownstreamStream.terminal_outcome(state) == :completed
    refute contains_parsed_block?(state)
  end

  test "large native output items require one full decode during normalization" do
    opts = RequestOptions.build(%{}, @endpoint, %{})

    data =
      event("response.output_item.done", %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "reasoning",
          "encrypted_content" => String.duplicate("A", 1_048_576)
        }
      })

    for resume? <- [false, true] do
      initial = DownstreamStream.initial_state(:relay, opts)

      initial =
        if resume?, do: DownstreamStream.enable_native_http_progress(initial), else: initial

      DownstreamStream.normalize_data(data, @endpoint, opts, initial)
      {:reductions, before} = Process.info(self(), :reductions)
      {wire, state} = DownstreamStream.normalize_data(data, @endpoint, opts, initial)
      {:reductions, after_count} = Process.info(self(), :reductions)
      assert wire == data
      assert after_count - before < 350_000
      refute contains_parsed_block?(state)
      assert Map.has_key?(state, :native_http_pending_output_items) == resume?
    end
  end

  defp assert_delivery(delivery, wire) do
    {preamble, kept, _seen?} = StreamProtocol.partition_preamble_blocks(wire)

    commits? =
      kept != "" and
        (StreamProtocol.stream_data_visible?(kept) or
           match?({:ok, _}, StreamProtocol.terminal_outcome(kept)))

    assert delivery.parts |> Enum.filter(& &1.preamble?) |> Enum.map(& &1.data) |> IO.iodata_to_binary() == preamble
    assert delivery.parts |> Enum.reject(& &1.preamble?) |> Enum.map(& &1.data) |> IO.iodata_to_binary() == kept
    assert Enum.any?(delivery.parts, & &1.commits?) == commits?
    assert IO.iodata_to_binary(Enum.map(delivery.parts, & &1.data)) == wire
  end

  defp blocks do
    [
      "event: response.created\ndata: {\"type\":\"response.created\"}",
      "event: response.created\ndata: {\"type\":\"response.output_item.done\"}",
      "event:   \ndata: {\"type\":\"response.created\"}",
      "event: response.created\nevent: response.failed\ndata: {}",
      "event: response.created\ndata: malformed",
      "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{}}",
      "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"failed\"}}",
      "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"error\":{\"code\":\"server_error\"}}}",
      "event: error\ndata: {\"type\":\"error\",\"error\":{\"code\":\"server_error\"}}",
      "event: codex.rate_limits\ndata: {}",
      ": comment",
      "data: [DONE]",
      "data: {\"type\":\"response.created\"}",
      "{\"type\":\"response.completed\",\"response\":{}}",
      "{\"detail\":\"synthetic failure\"}",
      "data: {\"type\":\ndata: \"response.output_item.done\"}"
    ]
  end

  defp event(label, body), do: "event: #{label}\ndata: #{CodexPooler.JSON.encode!(body)}\n\n"
  defp contains_parsed_block?(%NativeSSEBlock{}), do: true

  defp contains_parsed_block?(value) when is_map(value),
    do: value |> Map.to_list() |> Enum.any?(fn {_key, value} -> contains_parsed_block?(value) end)

  defp contains_parsed_block?(value) when is_list(value),
    do: Enum.any?(value, &contains_parsed_block?/1)

  defp contains_parsed_block?(_value), do: false
end
