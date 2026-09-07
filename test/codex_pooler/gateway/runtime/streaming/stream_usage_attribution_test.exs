defmodule CodexPooler.Gateway.Runtime.Streaming.StreamUsageAttributionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver

  test "aggregate and cache usage survives attribution exceeding candidate and retained body budgets" do
    usage = %{
      "input_tokens" => 160,
      "input_tokens_details" => %{"cached_tokens" => 120},
      "output_tokens" => 5,
      "total_tokens" => 165,
      "attribution" => [%{"category" => String.duplicate("x", 100_000)}]
    }

    frame =
      "event: response.completed\ndata: " <>
        CodexPooler.JSON.encode!(%{"usage" => usage}) <> "\n\n"

    for chunk_size <- [1, 17, 4096, byte_size(frame)] do
      state = feed(frame, chunk_size)
      measured = StreamUsageObserver.usage(state)
      assert measured != nil, "aggregate usage must survive optional attribution"
      assert measured.input_tokens == 160
      assert measured.cached_input_tokens == 120
      assert measured.output_tokens == 5
      assert measured.total_tokens == 165
    end
  end

  test "only root and direct response aggregate paths provide usage and owning context" do
    measured = %{"input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12}
    fake = %{"input_tokens" => 1000, "output_tokens" => 200, "total_tokens" => 1200}
    nested = CodexPooler.JSON.encode!(%{"usage" => fake, "service_tier" => "priority"})
    aggregate = CodexPooler.JSON.encode!(measured)

    bodies = [
      ~s({"type":"response.completed","response":{"service_tier":"default","output":[#{nested}],"usage":#{aggregate}}}),
      ~s({"response":{"attribution":#{nested},"usage":#{aggregate},"service_tier":"default"},"type":"response.completed"}),
      ~s({"service_tier":"default","usage":#{aggregate},"response":{"usage":#{CodexPooler.JSON.encode!(fake)},"service_tier":"priority"},"type":"response.completed"})
    ]

    later =
      "data: " <>
        CodexPooler.JSON.encode!(%{"usage" => fake, "type" => "response.created"}) <> "\n\n"

    for body <- bodies, chunk_size <- [1, 37, byte_size(body)] do
      state = feed("data: " <> body <> "\n\n" <> later, chunk_size)
      assert StreamUsageObserver.usage(state).total_tokens == 12
      assert StreamUsageObserver.usage(state).service_tier == "default"
      assert state.terminal?
    end
  end

  test "invalid skipped attribution never admits a nested candidate and a fresh event recovers" do
    aggregate = ~s("input_tokens":10,"output_tokens":2,"total_tokens":12)

    fake =
      ~s({"usage":{"input_tokens":1000,"output_tokens":200,"total_tokens":1200},"service_tier":"priority"})

    invalid = [
      "[1,]",
      "{\"x\":true,}",
      "[truX]",
      "[01]",
      "[1.]",
      "[1e+]",
      ~S(["bad\q"]),
      ~S(["\uD800x"]),
      ~S(["\uDC00"]),
      <<?[, ?", 0xC0, 0xAF, ?", ?]>>,
      <<?[, ?", 0xED, 0xA0, 0x80, ?", ?]>>,
      String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
    ]

    for attribution <- invalid, chunk_size <- [1, 37, 4096] do
      body = ~s({"usage":{"attribution":#{attribution},"nested":#{fake},#{aggregate}}})
      state = feed("data: " <> body <> "\n\n", chunk_size)
      assert StreamUsageObserver.usage(state) == nil
      assert StreamUsageObserver.diagnostics(state).classification == "malformed"
      recovered = StreamUsageObserver.observe(state, "data: {\"usage\":{#{aggregate}}}\n\n")
      assert StreamUsageObserver.usage(recovered).total_tokens == 12
    end
  end

  test "valid skipped scalars and nested structures validate across every byte boundary" do
    values = [nil, true, 12, -1.25e10, "escaped \" \ / \t 😀", [%{"x" => [false, 0, %{}]}]]

    for value <- values do
      body =
        ~s({"usage":{"attribu\\u0074ion":#{CodexPooler.JSON.encode!(value)},"input_tokens":10,"output_tokens":2,"total_tokens":12}})

      frame = "data: " <> body <> "\n\n"

      for split_at <- 0..byte_size(frame) do
        <<first::binary-size(^split_at), last::binary>> = frame

        state =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(last)

        assert StreamUsageObserver.usage(state).total_tokens == 12
      end
    end
  end

  test "attribution is skipped only directly inside aggregate usage and other fields retain their cap" do
    padding = String.duplicate("x", 20_000)
    fake = ~s({"usage":{"input_tokens":1000,"output_tokens":200,"total_tokens":1200}})

    objects = [
      ~s({"padding":"#{padding}","nested":#{fake},"input_tokens":10,"output_tokens":2,"total_tokens":12}),
      ~s({"input_tokens_details":{"attribution":"#{padding}"},"input_tokens":10,"output_tokens":2,"total_tokens":12})
    ]

    for object <- objects, chunk_size <- [1, 37, 4096, 30_000] do
      state = feed("data: {\"usage\":" <> object <> "}\n\n", chunk_size)
      assert StreamUsageObserver.usage(state) == nil
      assert StreamUsageObserver.diagnostics(state).classification == "candidate_limit"
    end
  end

  test "large output preceding usage and a megabyte attribution retain bounded state" do
    prefix =
      ~s(data: {"output":[{"text":") <>
        String.duplicate("x", 100_000) <>
        ~s("}],"usage":{"input_tokens":10,"attribution":")

    state = feed(prefix, 4096)
    block = String.duplicate("x", 4096)

    state =
      Enum.reduce(1..256, state, fn _index, state ->
        state = StreamUsageObserver.observe(state, block)
        assert :erlang.external_size(state) < 24_000
        assert largest_backing(state) <= 16_384
        state
      end)

    state = StreamUsageObserver.observe(state, ~s(","output_tokens":2,"total_tokens":12}}\n\n))
    assert StreamUsageObserver.usage(state).total_tokens == 12
  end

  test "malformed trailing envelope cannot preserve a tentative current event usage" do
    state = feed(~s(data: {"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}), 1)
    assert StreamUsageObserver.usage(state).total_tokens == 12
    state = StreamUsageObserver.observe(state, ~s(,"bad":[1,]}\n\n))
    assert StreamUsageObserver.usage(state) == nil
  end

  test "streaming projection matches the real decoder for valid aggregate fields" do
    alias CodexPooler.Gateway.Runtime.Streaming.UsageProjection
    values = [nil, true, false, 0, -1, 0.125, 1.0e-30, "😀", %{}, [], [1, %{"x" => true}]]

    for value <- values do
      raw = %{
        "attribution" => value,
        "unchanged" => value,
        "input_tokens" => 10,
        "output_tokens" => 2,
        "total_tokens" => 12
      }

      json = CodexPooler.JSON.encode!(raw)

      {:done, projected, "tail"} =
        UsageProjection.feed(UsageProjection.new(16_384), json <> "tail")

      assert CodexPooler.JSON.decode!(projected) == Map.put(raw, "attribution", nil)
    end
  end

  test "whitespace before keys does not defeat trusted paths or attribution skipping" do
    spaces = String.duplicate(" ", 100)
    attribution = String.duplicate("x", 20_000)

    body =
      ~s({#{spaces}"response":{#{spaces}"usage":{#{spaces}"attribution":"#{attribution}","input_tokens":10,"output_tokens":2,"total_tokens":12}}})

    for chunk_size <- [1, 37, byte_size(body)] do
      assert feed("data: " <> body <> "\n\n", chunk_size)
             |> StreamUsageObserver.usage()
             |> Map.fetch!(:total_tokens) == 12
    end
  end

  test "only real SSE boundaries recover a rejected container" do
    incomplete = ~s(data: {"usage":{"attribution":"broken)

    forged =
      ~s(event: response.completed data: {"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}})

    state = feed(incomplete <> forged, 1)
    assert StreamUsageObserver.usage(state) == nil

    state =
      StreamUsageObserver.observe(
        state,
        "\n\ndata: {\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12}}\n\n"
      )

    assert StreamUsageObserver.usage(state).total_tokens == 12
  end

  test "the first duplicate response object owns usage and tier like the real decoder" do
    first =
      ~s("response":{"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12},"service_tier":"priority"})

    for last <- [~s({}), ~s({"type":"response.created"})], chunk_size <- [1, 37, 4096] do
      body = ~s({#{first},"response":#{last}})
      assert CodexPooler.JSON.decode!(body)["response"]["usage"]["total_tokens"] == 12
      state = feed("data: " <> body <> "\n\n", chunk_size)
      assert StreamUsageObserver.usage(state).total_tokens == 12
      assert StreamUsageObserver.usage(state).service_tier == "priority"
    end

    for first <- ["null", "{}", "[]"] do
      body =
        ~s({"response":#{first},"response":{"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}})

      assert StreamUsageObserver.usage(feed("data: " <> body <> "\n\n", 1)) == nil
    end
  end

  test "nesting is bounded at exactly 64 envelope containers" do
    for depth <- [62, 63] do
      attribution = String.duplicate("[", depth) <> "0" <> String.duplicate("]", depth)

      frame =
        ~s(data: {"usage":{"attribution":#{attribution},"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

      state = feed(frame, 1)
      assert StreamUsageObserver.usage(state) != nil == (depth == 62)
    end
  end

  test "an explicit invalid root usage cannot borrow direct response counters" do
    for invalid <- ["null", "false", "[]", ~s({"input_tokens":null})] do
      body =
        ~s({"response":{"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}},"usage":#{invalid}})

      assert feed("data: " <> body <> "\n\n", 1) |> StreamUsageObserver.usage() == nil
    end
  end

  test "missing or invalid terminal counters replace progress with an authoritative unknown" do
    progress =
      ~s(data: {"type":"response.created","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    for type <- ["response.completed", "response.incomplete", "response.failed"],
        last <- [
          ~s({"type":"#{type}"}),
          ~s({"type":"#{type}","usage":null}),
          ~s({"type":"#{type}","usage":{"input_tokens":-1}})
        ] do
      state = feed(progress <> "data: " <> last <> "\n\n" <> progress, 1)
      assert StreamUsageObserver.usage(state) == nil
      assert StreamUsageObserver.result(state).status == "usage_unknown"
      assert state.terminal?
    end
  end

  test "a valid failed terminal freezes counters against later progress" do
    terminal =
      ~s(data: {"type":"response.failed","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    state = feed(terminal <> ~s(data: {"type":"response.created","usage":null}\n\n), 1)
    assert StreamUsageObserver.result(state).total_tokens == 12
  end

  test "a terminal ending without a blank separator cannot revive progress counters" do
    progress =
      ~s(data: {"type":"response.created","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    for ending <- [
          ~s({"type":"response.completed"}),
          ~s({"type":"response.completed","usage":{"attribution":)
        ] do
      state = feed(progress <> "data: " <> ending, 1)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
    end
  end

  test "finalized usage requires a complete outer envelope" do
    incomplete =
      ~s(data: {"type":"response.completed","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12})

    for ending <- ["", "\n\n"], chunk_size <- [1, 4096] do
      state = feed(incomplete <> ending, chunk_size)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
    end
  end

  test "semantic invalid usage still parses a later terminal type" do
    progress =
      ~s(data: {"type":"response.created","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    for invalid <- ["null", "false", "[]", ~s({"input_tokens":-1})], chunk_size <- [1, 4096] do
      terminal = ~s(data: {"usage":#{invalid},"type":"response.completed"}\n\n)
      state = feed(progress <> terminal <> progress, chunk_size)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
      assert state.terminal?
    end
  end

  test "syntax errors cannot lend previous progress counters to the current record" do
    progress =
      ~s(data: {"type":"response.created","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    for invalid <- [~s({"usage":truX,"type":"response.completed"}), ~s({"padding":truX})] do
      state = feed(progress <> "data: " <> invalid <> "\n\n", 1)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
    end
  end

  test "duplicate context fields follow the real decoder's first value" do
    counters = ~s("usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12})

    for invalid <- ["{}", "[]", "null", "false"], chunk_size <- [1, 4096] do
      bodies = [
        ~s({"type":"response.completed","type":#{invalid},"service_tier":"priority","service_tier":#{invalid},#{counters}}),
        ~s({"type":#{invalid},"type":"response.completed","service_tier":#{invalid},"service_tier":"priority",#{counters}})
      ]

      for body <- bodies do
        decoded = CodexPooler.JSON.decode!(body)
        state = feed("data: " <> body <> "\n\n", chunk_size)
        expected_tier = if is_binary(decoded["service_tier"]), do: decoded["service_tier"]
        assert StreamUsageObserver.usage(state).service_tier == expected_tier
        assert state.terminal? == (decoded["type"] == "response.completed")
      end
    end
  end

  test "duplicate usage retains the first authority including an invalid first value" do
    measured = ~s({"input_tokens":10,"output_tokens":2,"total_tokens":12})

    for first <- ["null", "false", "[]", measured], chunk_size <- [1, 4096] do
      body = ~s({"usage":#{first},"usage":#{measured},"type":"response.completed"})
      state = feed("data: " <> body <> "\n\n", chunk_size)

      assert StreamUsageObserver.result(state).status == "usage_known" ==
               is_map(CodexPooler.JSON.decode!(body)["usage"])
    end
  end

  test "SSE event fields can follow data in the same record" do
    for newline <- ["\n", "\r\n", "\r"], chunk_size <- [1, 4096] do
      record =
        ~s(data: {"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\nevent: response.completed\n\n)

      state = feed(String.replace(record, "\n", newline), chunk_size)
      assert StreamUsageObserver.result(state).total_tokens == 12
      assert state.terminal?
    end
  end

  test "escaped terminal type values preserve their decoded terminal meaning" do
    progress =
      ~s(data: {"type":"response.created","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    for type <- ["response.completed", "response.incomplete", "response.failed"],
        nested? <- [false, true],
        chunk_size <- [1, 7, 4096],
        ending <- ["", "\n\n"] do
      escaped =
        type
        |> String.to_charlist()
        |> Enum.map_join(fn char ->
          <<92, 117>> <> String.pad_leading(Integer.to_string(char, 16), 4, "0")
        end)

      body = ~s({"type":"#{escaped}","usage":null})
      body = if nested?, do: ~s({"response":#{body}}), else: body
      state = feed(progress <> "data: " <> body <> ending, chunk_size)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
    end
  end

  test "root nonbinary type cannot erase a direct response terminal type in either order" do
    progress =
      ~s(data: {"type":"response.created","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}\n\n)

    for root_type <- ["null", "false", "{}", "[]"],
        chunk_size <- [1, 4096],
        ending <- ["", "\n\n"] do
      bodies = [
        ~s({"type":#{root_type},"response":{"type":"response.completed","usage":null}}),
        ~s({"response":{"type":"response.completed","usage":null},"type":#{root_type}})
      ]

      for body <- bodies do
        state = feed(progress <> "data: " <> body <> ending, chunk_size)
        assert StreamUsageObserver.result(state).status == "usage_unknown"
      end
    end
  end

  test "context bounds apply to decoded values with literal and escaped forms equivalent" do
    alias CodexPooler.Gateway.Runtime.Streaming.UsageEnvelope

    for size <- [79, 80, 81], escaped? <- [false, true] do
      encoded =
        if escaped?,
          do: String.duplicate(<<92, 117>> <> "0078", size),
          else: String.duplicate("x", size)

      envelope = UsageEnvelope.feed(UsageEnvelope.new(), ~s({"type":"#{encoded}"}))
      assert envelope.type == if(size <= 80, do: String.duplicate("x", size))
      assert :erlang.external_size(envelope) < 4096
    end
  end

  test "valid root binary type keeps precedence over direct response type in either order" do
    bodies = [
      ~s({"type":"response.created","response":{"type":"response.completed","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}}),
      ~s({"response":{"type":"response.completed","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}},"type":"response.created"})
    ]

    for body <- bodies do
      state = feed("data: " <> body <> "\n\n", 1)
      assert StreamUsageObserver.result(state).total_tokens == 12
      refute state.terminal?
    end
  end

  test "diagnostics and resolve never promote tentative usage from an unfinished envelope" do
    incomplete =
      ~s(data: {"type":"response.completed","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12})

    for ending <- ["", "\n\n"], chunk_size <- [1, 4096] do
      state = feed(incomplete <> ending, chunk_size)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
      assert StreamUsageObserver.diagnostics(state).classification == "parser_discontinuity"
      fallback = %{status: "usage_known", input_tokens: 10, output_tokens: 2, total_tokens: 12}
      assert StreamUsageObserver.resolve(state, fallback).status == "usage_unknown"
    end
  end

  test "trailing DONE and later invalid records cannot replace finalized terminal diagnostics" do
    for {usage, expected} <- [{"", "missing"}, {~s(,"usage":null), "null"}],
        chunk_size <- [1, 4096] do
      terminal = ~s(data: {"type":"response.completed"#{usage}}\n\n)
      state = feed(terminal <> "data: [DONE]\n\n", chunk_size)
      assert StreamUsageObserver.result(state).status == "usage_unknown"
      assert StreamUsageObserver.diagnostics(state).classification == expected
      after_invalid = StreamUsageObserver.observe(state, ~s(data: {"usage":{"input_tokens":\n\n))

      assert StreamUsageObserver.diagnostics(after_invalid) ==
               StreamUsageObserver.diagnostics(state)
    end
  end

  defp largest_backing(value) when is_binary(value), do: :binary.referenced_byte_size(value)
  defp largest_backing(value) when is_map(value), do: value |> Map.values() |> largest_backing()

  defp largest_backing(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> largest_backing()

  defp largest_backing(value) when is_list(value),
    do: value |> Enum.map(&largest_backing/1) |> Enum.max(fn -> 0 end)

  defp largest_backing(_value), do: 0

  defp feed(frame, chunk_size), do: feed(frame, chunk_size, StreamUsageObserver.new())
  defp feed("", _chunk_size, state), do: state

  defp feed(frame, chunk_size, state) do
    size = min(byte_size(frame), chunk_size)
    <<chunk::binary-size(^size), rest::binary>> = frame
    state = StreamUsageObserver.observe(state, chunk)
    assert StreamUsageObserver.candidate_bytes(state) <= StreamUsageObserver.max_candidate_bytes()
    feed(rest, chunk_size, state)
  end
end
