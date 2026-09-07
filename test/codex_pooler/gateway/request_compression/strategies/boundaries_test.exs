defmodule CodexPooler.Gateway.RequestCompression.Strategies.BoundariesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.ContentDetector
  alias CodexPooler.Gateway.RequestCompression.Strategies
  alias CodexPooler.Gateway.RequestCompression.Strategies.Diff
  alias CodexPooler.Gateway.RequestCompression.Strategies.EmbeddedJsonLossless
  alias CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLossless
  alias CodexPooler.Gateway.RequestCompression.Strategies.JsonDocumentLossless
  alias CodexPooler.Gateway.RequestCompression.Strategies.LogOutput
  alias CodexPooler.Gateway.RequestCompression.Strategies.SearchResults

  test "detection rejects non-text, scalar JSON and truncated object streams" do
    for value <- [nil, [], %{}, 42, "true", "42", "null", "\"value\""] do
      assert %{kind: :text, compressible: false} = ContentDetector.detect(value)
    end

    for value <- [nil, "", "  ", "{", ~s({"key":"unfinished), ~s({"key":)] do
      assert :error = ContentDetector.normalize_concatenated_json_objects(value)
    end

    stream = ~s({"key":"escaped \\" quote","nested":{"a":1}} \n {"key":2})
    assert {:ok, normalized, 2} = ContentDetector.normalize_concatenated_json_objects(stream)

    assert [%{"key" => "escaped \" quote", "nested" => %{"a" => 1}}, %{"key" => 2}] =
             CodexPooler.JSON.decode!(normalized)
  end

  test "lossless strategies reject non-text values" do
    for strategy <- [JsonArrayLossless, JsonDocumentLossless, EmbeddedJsonLossless],
        value <- [nil, [], %{}, 42] do
      assert :skip = strategy.compress(value)
    end
  end

  test "embedded JSON reports tokenizer bounds without dropping a large span" do
    object = CodexPooler.JSON.encode!(%{"value" => String.duplicate("abc ", 3_000)}, pretty: true)
    original = "prefix\n" <> object <> "\nsuffix"

    assert {:skip, :tokenizer_input_limit} =
             EmbeddedJsonLossless.compress(original, model: "gpt-4o")
  end

  test "search compression accepts map options and retains context columns" do
    content =
      Enum.map_join(1..20, "\n", fn n -> "src/sample.ex:#{n}:3: synthetic matching line #{n}" end)

    content =
      "malformed\0one\0two\nsrc/sample.ex\n1-2- adjacent context\n2:3: first grouped match\n3:3: second grouped match\n\n" <>
        content

    for opts <- [%{}, %{"model" => "gpt-4o"}, %{model: "gpt-4o"}] do
      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content, opts)

      assert compressed =~ "1-2- adjacent context"
      assert metadata.original_match_count == 22
      assert metadata.compressed_match_count == 3
      refute compressed =~ "malformed"
    end
  end

  test "diff compression accepts map options" do
    context = Enum.map_join(1..40, "\n", &" unchanged synthetic line #{&1}")

    content =
      "diff --git a/sample b/sample\n--- a/sample\n+++ b/sample\n@@ -1,41 +1,41 @@\n-old\n+new\n" <>
        context

    for opts <- [%{}, %{"model" => "gpt-4o"}, %{model: "gpt-4o"}] do
      assert {:ok, %{content: compressed}} =
               Diff.compress(content, Map.merge(opts, %{min_hunks: 1}))

      assert compressed =~ "-old\n+new"
      refute compressed =~ "unchanged synthetic line 40"
    end
  end

  test "grouped ripgrep column matches are counted once alongside classic file matches" do
    grouped = Enum.map_join(2..20, "\n", &"#{&1}:1:synthetic needle #{&1}")

    content =
      "src/grouped.txt\n1-before\n" <> grouped <> "\n\nsrc/direct.txt:4:1:synthetic needle\n"

    assert {:ok, %{content: compressed, metadata: metadata}} =
             SearchResults.compress(content, min_bytes: 0)

    assert metadata.original_match_count == 20
    assert metadata.original_file_count == 2
    assert metadata.compressed_match_count == 4
    assert compressed =~ "src/grouped.txt\n  1- before\n  2:1: synthetic needle 2"
    assert compressed =~ "src/direct.txt\n  4:1: synthetic needle"
  end

  test "zero failure summaries permit routine log compression" do
    content =
      "warning: synthetic result\n0 failures\n" <>
        Enum.map_join(1..100, "\n", &"routine synthetic progress #{&1}")

    assert {:ok, %{metadata: metadata}} = LogOutput.compress(content, model: "gpt-4o")
    assert metadata.original_line_count == 102
  end

  test "finalization proves bounded-original savings and rejects unsafe prefixes" do
    original = String.duplicate("synthetic word ", 1000)

    assert {:ok, %{metadata: metadata}} =
             Strategies.finalize(:test, original, "short", %{}, model: "gpt-4o")

    assert metadata.token_count_mode == :bounded_original
    assert metadata.original_tokens_lower_bound > metadata.compressed_tokens
    refute Map.has_key?(metadata, :original_tokens)

    assert {:skip, :tokenizer_input_limit} =
             Strategies.finalize(:test, original <> <<255>>, "short", %{}, model: "gpt-4o")
  end

  test "shared helpers preserve line boundaries and sanitize unsupported options" do
    assert {:ok, ["a", "b"]} = Strategies.lines("a\r\nb\r")
    assert :error = Strategies.lines(<<255>>)
    assert :error = Strategies.lines(nil)
    assert 3 == Strategies.integer_option(nil, :limit, 3)
    assert 3 == Strategies.integer_option(%{limit: -1}, :limit, 3)
    assert 4 == Strategies.integer_option(%{"limit" => 4}, :limit, 3)

    assert {["omitted 3"], 3} =
             Strategies.collapse_lines(["a", "b", "c"], [-1, 9], &"omitted #{&1}")

    assert {[], 0} = Strategies.collapse_lines([], [], &"omitted #{&1}")
    assert :skip = Strategies.finalize(:test, "original", "short", %{}, nil)
    assert :skip = Strategies.finalize(:test, "original", "short", %{}, model: " ")
    assert :skip = Strategies.finalize(nil, nil, nil, nil)
  end
end
