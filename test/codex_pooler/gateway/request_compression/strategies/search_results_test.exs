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

    test "compresses grouped heading output when headings are file paths" do
      sentinel = "DROP_ME_GROUPED_SEARCH_SENTINEL"
      content = grouped_search_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 2,
                 max_files: 2,
                 max_matches_per_file: 2,
                 max_matches: 3
               )

      assert compressed =~ "lib/grouped_1.ex"
      assert compressed =~ "  1: grouped result 1-1 kept"
      assert compressed =~ "  2: grouped result 1-2 kept"
      assert compressed =~ "lib/grouped_2.ex"
      assert compressed =~ "[compressed search results: omitted 1 files]"
      refute compressed =~ sentinel

      assert metadata.strategy == :search_results
      assert metadata.original_file_count == 3
      assert metadata.compressed_file_count == 2
      assert metadata.original_match_count == 18
      assert metadata.compressed_match_count == 3
      assert metadata.omitted_match_count == 15
      assert_safe_metadata(metadata, :search_results, sentinel)
    end

    test "compresses nul-delimited output without retaining nul bytes in metadata" do
      sentinel = "DROP_ME_NUL_SEARCH_SENTINEL"
      content = nul_search_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 2,
                 max_files: 1,
                 max_matches_per_file: 3,
                 max_matches: 3
               )

      assert compressed =~ "lib/nul_result.ex"
      assert compressed =~ "  1: nul result 1 kept"
      assert compressed =~ "  2: nul result 2 kept"
      assert compressed =~ "  3: nul result 3 kept"
      refute compressed =~ <<0>>
      refute compressed =~ sentinel

      assert metadata.strategy == :search_results
      assert metadata.original_file_count == 1
      assert metadata.compressed_file_count == 1
      assert metadata.original_match_count == 12
      assert metadata.compressed_match_count == 3
      assert Jason.encode!(metadata)
      refute inspect(metadata) =~ <<0>>
      assert_safe_metadata(metadata, :search_results, sentinel)
    end

    test "compresses column-bearing direct output without dropping columns" do
      sentinel = "DROP_ME_COLUMN_SEARCH_SENTINEL"
      content = column_bearing_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 2,
                 max_files: 1,
                 max_matches_per_file: 3,
                 max_matches: 3
               )

      assert compressed =~ "lib/column_result.ex"
      assert compressed =~ "  1:2: column match 1 kept"
      assert compressed =~ "  2:4: column match 2 kept"
      assert compressed =~ "  3:6: column match 3 kept"
      refute compressed =~ sentinel

      assert metadata.strategy == :search_results
      assert metadata.original_file_count == 1
      assert metadata.compressed_file_count == 1
      assert metadata.original_match_count == 12
      assert metadata.compressed_match_count == 3
      assert_safe_metadata(metadata, :search_results, sentinel)
    end

    test "preserves grep context separators and direct dash context lines" do
      sentinel = "DROP_ME_GREP_CONTEXT_SENTINEL"
      content = direct_context_search_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 2,
                 max_files: 2,
                 max_matches_per_file: 8,
                 max_matches: 3
               )

      assert compressed =~ "lib/context_1.ex"
      assert compressed =~ "  9- before first direct match"
      assert compressed =~ "  10: direct match 1 kept"
      assert compressed =~ "  11- after first direct match"
      assert compressed =~ "--"
      assert compressed =~ "  29- before second direct match"
      assert compressed =~ "  30: direct match 2 kept"
      assert compressed =~ "  31- after second direct match"
      refute compressed =~ sentinel

      assert metadata.strategy == :search_results
      assert metadata.original_file_count == 2
      assert metadata.original_match_count == 4
      assert metadata.compressed_match_count == 3
      assert_safe_metadata(metadata, :search_results, sentinel)
    end

    test "preserves grouped grep dash context lines" do
      sentinel = "DROP_ME_GROUPED_CONTEXT_SENTINEL"
      content = grouped_context_search_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               SearchResults.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_matches: 2,
                 max_files: 1,
                 max_matches_per_file: 2,
                 max_matches: 2
               )

      assert compressed =~ "lib/grouped_context.ex"
      assert compressed =~ "  9- grouped context before"
      assert compressed =~ "  10: grouped match one kept"
      assert compressed =~ "  11- grouped context after"
      assert compressed =~ "--"
      assert compressed =~ "  19- grouped context before second"
      assert compressed =~ "  20: grouped match two kept"
      assert compressed =~ "  21- grouped context after second"
      refute compressed =~ sentinel

      assert metadata.strategy == :search_results
      assert metadata.original_file_count == 1
      assert metadata.original_match_count == 3
      assert metadata.compressed_match_count == 2
      assert_safe_metadata(metadata, :search_results, sentinel)
    end

    test "skips grep outputs with engine evidence that cannot be safely summarized" do
      unsafe_outputs = [
        """
        $ rg --engine auto needle lib
        lib/searchable.ex:12: matching line kept
        lib/searchable.ex:48: another matching line kept
        rg: regex parse error:
            (
            ^
        error: unclosed group
        exit code: 2
        """,
        """
        + /usr/bin/rg needle lib
        lib/searchable.ex:12: matching line kept
        lib/searchable.ex:48: another matching line kept
        """,
        """
        ++ ./vendor/bin/grep needle lib
        lib/searchable.ex:12: matching line kept
        /usr/bin/rg: regex parse error:
        exit status 2
        """,
        """
        lib/text_result.ex:1: matching text kept
        Binary file priv/static/example.bin matches
        lib/text_result.ex:2: another matching text kept
        """,
        """
        lib/text_result.ex:1: matching text kept
        priv/static/example.bin: binary file matches (found "\\0" byte around offset 128)
        priv/static/second.bin: WARNING: stopped searching binary file after match (found "\\0" byte around offset 256)
        lib/text_result.ex:2: another matching text kept
        """,
        """
        1: stdin match without filename kept
        2: second stdin match without filename kept
        3: third stdin match without filename kept
        """,
        """
        lib/error_result.ex:5: matching text kept
        grep: sample input: No such file or directory
        exit status 2
        lib/error_result.ex:8: another matching text kept
        """
      ]

      for content <- unsafe_outputs do
        assert :skip =
                 SearchResults.compress(content,
                   model: @model,
                   min_bytes: 0,
                   min_matches: 1,
                   max_files: 1,
                   max_matches_per_file: 1,
                   max_matches: 1
                 )
      end
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

    test "skips prose headings and malformed nul fragments" do
      prose_heading = """
      Search results from the last review.
      1: this is prose, not a grouped file match
      2: this is also prose
      """

      malformed_nul = """
      lib/example.ex\0not-a-match-line
      lib/example.ex\0: missing line number
      lib/example.ex\0one: missing numeric line
      """

      assert :skip = SearchResults.compress(prose_heading, min_bytes: 0, min_matches: 2)
      assert :skip = SearchResults.compress(malformed_nul, min_bytes: 0, min_matches: 1)
    end

    test "skips unsupported grep shape-only outputs" do
      unsupported = [
        files_with_matches_fixture(),
        count_only_fixture(),
        only_matching_fixture()
      ]

      for content <- unsupported do
        assert :skip =
                 SearchResults.compress(content,
                   model: @model,
                   min_bytes: 0,
                   min_matches: 1,
                   max_files: 2,
                   max_matches_per_file: 2,
                   max_matches: 3
                 )
      end
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

  defp direct_context_search_fixture(sentinel) do
    """
    lib/context_1.ex-9- before first direct match
    lib/context_1.ex:10: direct match 1 kept
    lib/context_1.ex-11- after first direct match
    --
    lib/context_1.ex-29- before second direct match
    lib/context_1.ex:30: direct match 2 kept
    lib/context_1.ex-31- after second direct match
    lib/context_2.ex:5: another file match kept
    lib/context_2.ex:6: another file match #{sentinel}
    """
  end

  defp grouped_context_search_fixture(sentinel) do
    """
    lib/grouped_context.ex
    9- grouped context before
    10: grouped match one kept
    11- grouped context after
    --
    19- grouped context before second
    20: grouped match two kept
    21- grouped context after second
    30: grouped match three #{sentinel}
    """
  end

  defp files_with_matches_fixture do
    """
    lib/matched_one.ex
    lib/matched_two.ex
    lib/matched_three.ex
    """
  end

  defp count_only_fixture do
    """
    lib/count_one.ex:3
    lib/count_two.ex:0
    lib/count_three.ex:12
    """
  end

  defp only_matching_fixture do
    """
    lib/only_one.ex:needle
    lib/only_two.ex:needle
    lib/only_three.ex:needle
    """
  end

  defp column_bearing_fixture(sentinel) do
    1..12
    |> Enum.map_join("\n", fn index ->
      marker = if index == 4, do: sentinel, else: "kept"
      "lib/column_result.ex:#{index}:#{index * 2}: column match #{index} #{marker}"
    end)
  end

  defp grouped_search_fixture(sentinel) do
    1..3
    |> Enum.flat_map(fn file ->
      ["lib/grouped_#{file}.ex" | grouped_file_lines(file, sentinel)]
    end)
    |> Enum.join("\n")
  end

  defp nul_search_fixture(sentinel) do
    1..12
    |> Enum.map_join("\n", fn
      8 -> "lib/nul_result.ex\08: nul result 8 #{sentinel}"
      index -> "lib/nul_result.ex\0#{index}: nul result #{index} kept"
    end)
  end

  defp grouped_file_lines(file, sentinel) do
    1..6
    |> Enum.map(fn match ->
      marker = grouped_marker(file, match, sentinel)
      "#{match}: grouped result #{file}-#{match} #{marker}"
    end)
  end

  defp grouped_marker(1, 4, sentinel), do: sentinel
  defp grouped_marker(_file, _match, _sentinel), do: "kept"

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
             {:token_count_mode, value} -> value in [:exact, :bounded_original]
             {_key, value} -> is_integer(value)
           end)

    refute inspect(metadata) =~ sentinel
  end
end
