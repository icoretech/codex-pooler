defmodule CodexPooler.Gateway.RequestCompression.Strategies.SearchResultsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.Strategies.SearchResults
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @model "gpt-4o"

  describe "compress/2" do
    test "bounds files, total matches, and matches per file" do
      sentinel = "DROP_ME_SEARCH_SENTINEL"
      content = search_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 1,
                 max_files: 2,
                 max_matches_per_file: 2,
                 max_matches: 3
               )

      assert compressed =~ "lib/example_1.ex"
      assert compressed =~ "  1: example match 1-1 kept"
      assert compressed =~ "  2: example match 1-2 kept"
      assert compressed =~ "lib/example_2.ex"
      assert compressed =~ "[compressed search results: omitted 2 files]"
      refute compressed =~ sentinel

      assert metadata.strategy == :search_results
      assert metadata.original_bytes > metadata.compressed_bytes
      assert metadata.original_tokens > metadata.compressed_tokens
      assert metadata.original_file_count == 4
      assert metadata.compressed_file_count == 2
      assert metadata.original_match_count == 20
      assert metadata.compressed_match_count == 3
      assert metadata.omitted_match_count == 17
      assert_safe_metadata(metadata, :search_results, sentinel)
    end

    test "rejects byte-shrinking rewrites that do not shrink tokens" do
      padding = String.duplicate(" ", 20)

      original =
        Enum.map_join(1..4, "\n", &"a.ex:#{&1}: x#{padding}")

      byte_smaller_candidate =
        "[compressed search results: kept 1 of 4 matches across 1 of 1 files]\n" <>
          "a.ex\n  1: x\n  [omitted 3 matches in file]"

      assert byte_size(byte_smaller_candidate) < byte_size(original)
      assert token_count(byte_smaller_candidate) >= token_count(original)

      assert :skip =
               SearchResults.compress(original,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 1,
                 max_files: 1,
                 max_matches_per_file: 1,
                 max_matches: 1
               )
    end

    test "skips malformed, too-small, and nonmatching input" do
      assert :skip = SearchResults.compress(:not_text)
      assert :skip = SearchResults.compress(<<255>>, min_bytes: 0)
      assert :skip = SearchResults.compress("lib/example.ex:1: tiny", min_bytes: 512)

      nonmatching =
        Enum.map_join(1..10, "\n", &"plain search prose result #{&1}")

      assert :skip = SearchResults.compress(nonmatching, min_bytes: 0, min_matches: 1)
    end

    test "does not retain state between calls" do
      assert {:ok, _result} =
               SearchResults.compress(search_fixture("DROP_ME_STALE_SEARCH"),
                 model: @model,
                 min_bytes: 0,
                 min_matches: 1,
                 max_files: 2,
                 max_matches_per_file: 2,
                 max_matches: 3
               )

      assert :skip =
               SearchResults.compress("plain output after prior compression",
                 model: @model,
                 min_bytes: 0,
                 min_matches: 1
               )
    end
  end

  defp search_fixture(sentinel) do
    for file <- 1..4, match <- 1..5 do
      marker =
        if file == 1 and match == 3 do
          sentinel
        else
          "kept"
        end

      "lib/example_#{file}.ex:#{match}: example match #{file}-#{match} #{marker}"
    end
    |> Enum.join("\n")
  end

  defp token_count(content) do
    assert {:ok, count, _metadata} = TokenCounter.count(@model, content)
    count
  end

  defp assert_safe_metadata(metadata, strategy, sentinel) do
    assert Enum.all?(metadata, fn
             {:strategy, ^strategy} -> true
             {_key, value} -> is_integer(value)
           end)

    refute inspect(metadata) =~ sentinel
  end
end
