defmodule CodexPooler.Gateway.RequestCompression.ScannerBoundariesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.{
    DirectReadCommand,
    EmbeddedJson,
    JsonStringRanges,
    ResponsesLiveZone
  }

  test "JSON scanner accepts numeric grammar and lowercase unicode escapes" do
    for json <- [
          "-0",
          "-123.456e-12",
          "1E+10",
          "2e3",
          ~S("\uabcd"),
          "{}",
          "[]",
          "true",
          "false",
          "null"
        ] do
      assert {:ok, _} = CodexPooler.JSON.decode(json)
      assert {:ok, _} = JsonStringRanges.scan(json)
    end
  end

  test "JSON scanner rejects incomplete grammar at every token boundary" do
    for json <- [
          nil,
          "",
          "{",
          "{1:2}",
          ~S({"a":1,}),
          ~S({"a":1 x}),
          ~S({"a" 1}),
          ~S({"bad\q":1}),
          "-",
          "-x",
          "1.",
          "1e",
          "1e+",
          "tru",
          "[1 x]",
          ~S("\u12),
          ~S("\uZZZZ"),
          <<34, 97, 92>>
        ] do
      assert {:error, :invalid_json} = JsonStringRanges.scan(json), inspect(json)
    end
  end

  test "string decoding and replacement reject invalid public arguments" do
    for {json, range} <- [
          {nil, %{}},
          {"null", %{byte_start: 0, byte_end: 4}},
          {~S("x"), %{byte_start: -1, byte_end: 2}},
          {~S("x"), %{byte_start: 0, byte_end: 9}},
          {~S("x"), %{byte_start: 0, byte_end: 1}},
          {~S("x"), %{byte_start: "0", byte_end: 3}}
        ] do
      assert {:error, :invalid_json} = JsonStringRanges.decode_string(json, range)
    end

    for {json, replacements} <- [
          {nil, []},
          {"x", nil},
          {"x", [%{}]},
          {"x", [%{byte_start: 0, byte_end: 1, replacement: nil}]}
        ] do
      assert {:error, :invalid_range} = JsonStringRanges.replace_ranges(json, replacements)
    end

    assert {:ok, "unchanged"} = JsonStringRanges.replace_ranges("unchanged", [])
  end

  test "direct reads accept native numbering and trailing whitespace" do
    assert DirectReadCommand.read?(%{
             "type" => "local_shell_call",
             "action" => %{"type" => "exec", "command" => ["nl", "-ba", "sample.ex"]}
           })

    assert DirectReadCommand.read?(%{"cmd" => "cat sample.ex \t"})

    for command <- [
          "head - sample.ex",
          ~s(cat 'sample'ex),
          ~S(cat 'sample\file'),
          ~S(cat "sample`file"),
          ~S(cat "$FILE")
        ] do
      refute DirectReadCommand.read?(%{"cmd" => command})
    end
  end

  test "embedded JSON preserves span byte offsets with prose and surrounding whitespace" do
    content = " \nstatus [pending] {notes} {\"value\": [1, {}]} \t"
    assert {:ok, [span]} = EmbeddedJson.plan(content)
    assert span.kind == :object

    assert binary_part(content, span.byte_start, span.byte_end - span.byte_start) ==
             ~S({"value": [1, {}]})

    assert EmbeddedJson.embedded?(content)
    assert :skip = EmbeddedJson.plan(" \n {} \t")
    assert :skip = EmbeddedJson.plan(" \n [] \t")
  end

  test "embedded JSON fails closed on malformed partial containers and strings" do
    for content <- [
          nil,
          <<255>>,
          "prefix {",
          "prefix [ \n",
          "prefix " <> <<34, 92>>,
          ~S(prefix {"key":) <> <<34, 92>>,
          ~S(prefix {"key":]}),
          ~S(prefix [true,]),
          ~S(prefix "unfinished)
        ] do
      assert :skip = EmbeddedJson.plan(content), inspect(content)
      refute EmbeddedJson.embedded?(content)
    end

    assert :skip = EmbeddedJson.plan(String.duplicate("prefix {} ", 51))
    assert {:ok, spans} = EmbeddedJson.plan(String.duplicate("prefix {} ", 50))
    assert length(spans) == 50
  end

  test "live-zone defaults and malformed options retain safe thresholds" do
    assert {:error, :invalid_json} = ResponsesLiveZone.plan("1e9999")

    json =
      CodexPooler.JSON.encode!(%{
        "input" => [%{"type" => "local_shell_call_output", "output" => "short"}]
      })

    assert {:ok, %{candidate_count: 0}} = ResponsesLiveZone.plan(json)
    assert {:ok, []} = ResponsesLiveZone.plan_candidates(json)

    for opts <- [nil, %{min_bytes: -1}, %{"min_bytes" => "0"}, %{excluded_tools: 123}] do
      assert {:ok, %{candidate_count: 0}} = ResponsesLiveZone.plan(json, opts)
    end

    assert {:ok, %{candidate_count: 1}} =
             ResponsesLiveZone.plan(json, %{"min_bytes" => 0, "excluded_tools" => [123, "custom"]})

    assert {:error, :invalid_json} = ResponsesLiveZone.plan(nil)
    assert {:error, :invalid_json} = ResponsesLiveZone.plan_candidates(nil)
  end

  test "live-zone ignores scalar input members and protects outputs without valid call identifiers" do
    json =
      CodexPooler.JSON.encode!(%{
        "input" => [
          nil,
          4,
          [],
          %{"type" => "function_call", "name" => "sample"},
          %{"type" => "local_shell_call"},
          %{"type" => "function_call_output", "output" => "synthetic"},
          %{"type" => "function_call_output", "call_id" => 1, "output" => "synthetic"}
        ]
      })

    assert {:ok, %{candidate_count: 0, protected_tool_output_skipped_count: 2}} =
             ResponsesLiveZone.plan(json, min_bytes: 0)
  end
end
