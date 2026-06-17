defmodule CodexPooler.Gateway.RequestCompression.Strategies.DiffTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.Strategies.Diff
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @model "gpt-4o"

  describe "compress/2" do
    test "bounds context, hunks, and files while keeping selected changes" do
      sentinel = "DROP_ME_DIFF_SENTINEL"
      content = diff_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               Diff.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_hunks: 1,
                 max_files: 1,
                 max_hunks_per_file: 1,
                 max_hunks: 1,
                 context_lines: 1
               )

      assert compressed =~ "diff --git a/lib/example_1.ex b/lib/example_1.ex"
      assert compressed =~ "-old first"
      assert compressed =~ "+new first"
      assert compressed =~ "context kept before"
      assert compressed =~ "context kept after"
      assert compressed =~ "[compressed diff output: omitted 1 hunks]"
      assert compressed =~ "[compressed diff output: omitted 1 files]"
      refute compressed =~ sentinel
      refute compressed =~ "-old second"
      refute compressed =~ "+new other"

      assert metadata.strategy == :diff
      assert metadata.original_bytes > metadata.compressed_bytes
      assert metadata.original_tokens > metadata.compressed_tokens
      assert metadata.original_file_count == 2
      assert metadata.compressed_file_count == 1
      assert metadata.original_hunk_count == 3
      assert metadata.compressed_hunk_count == 1
      assert metadata.addition_line_count == 3
      assert metadata.deletion_line_count == 3
      assert metadata.omitted_context_line_count > 0
      assert_safe_metadata(metadata, :diff, sentinel)
    end

    test "rejects byte-shrinking rewrites that do not shrink tokens" do
      context_line = " " <> String.duplicate(" ", 20)
      context = List.duplicate(context_line, 4) |> Enum.join("\n")

      original =
        "diff --git a/a b/a\n" <>
          "--- a/a\n" <>
          "+++ b/a\n" <>
          "@@ -1,6 +1,6 @@\n" <>
          "-old\n" <>
          "+new\n" <>
          context

      byte_smaller_candidate =
        "diff --git a/a b/a\n" <>
          "--- a/a\n" <>
          "+++ b/a\n" <>
          "@@ -1,6 +1,6 @@\n" <>
          "-old\n" <>
          "+new\n" <>
          " [compressed diff output: omitted 4 context lines]"

      assert byte_size(byte_smaller_candidate) < byte_size(original)
      assert token_count(byte_smaller_candidate) >= token_count(original)

      assert :skip =
               Diff.compress(original,
                 model: @model,
                 min_bytes: 0,
                 min_hunks: 1,
                 max_files: 1,
                 max_hunks_per_file: 1,
                 max_hunks: 1,
                 context_lines: 0
               )
    end

    test "skips malformed, too-small, and nonmatching input" do
      assert :skip = Diff.compress(:not_text)
      assert :skip = Diff.compress(<<255>>, min_bytes: 0)

      tiny = """
      --- a/example.txt
      +++ b/example.txt
      @@ -1 +1 @@
      -old
      +new
      """

      assert :skip = Diff.compress(tiny, min_bytes: 512)
      assert :skip = Diff.compress("ordinary output without diff hunks", min_bytes: 0)
    end

    test "compresses one-sided and replacement hunks without diff git headers" do
      for {content, expected_additions, expected_deletions} <- [
            {additions_only_fixture(), 1, 0},
            {deletions_only_fixture(), 0, 1},
            {replacement_fixture(), 1, 1}
          ] do
        assert {:ok, %{content: compressed, metadata: metadata}} =
                 Diff.compress(content,
                   model: @model,
                   min_bytes: 0,
                   min_hunks: 1,
                   context_lines: 0
                 )

        assert compressed =~ "@@"
        assert compressed =~ "[compressed diff output: omitted"
        assert metadata.strategy == :diff
        assert metadata.original_hunk_count == 1
        assert metadata.compressed_hunk_count == 1
        assert metadata.addition_line_count == expected_additions
        assert metadata.deletion_line_count == expected_deletions
      end
    end

    test "compresses minimal bare unified hunks and skips prose plus/minus lines" do
      minimal = """
      @@ -1,0 +1,2 @@
      +one
      +two
      """

      prose = """
      Review notes for the next change:
      + add a short summary before the examples
      - remove the stale paragraph near the end
      """

      assert {:ok, %{content: compressed, metadata: metadata}} =
               Diff.compress(minimal, min_bytes: 0, min_hunks: 1)

      assert compressed == "+one\n+two"
      assert metadata.strategy == :diff
      assert metadata.original_hunk_count == 1
      assert metadata.compressed_hunk_count == 1
      assert metadata.addition_line_count == 2
      assert metadata.deletion_line_count == 0

      assert :skip = Diff.compress(prose, min_bytes: 0, min_hunks: 1)
    end

    test "does not retain state between calls" do
      assert {:ok, _result} =
               Diff.compress(diff_fixture("DROP_ME_STALE_DIFF"),
                 model: @model,
                 min_bytes: 0,
                 min_hunks: 1,
                 max_files: 1,
                 max_hunks_per_file: 1,
                 max_hunks: 1,
                 context_lines: 1
               )

      assert :skip =
               Diff.compress("ordinary output after prior compression",
                 model: @model,
                 min_bytes: 0,
                 min_hunks: 1
               )
    end
  end

  defp diff_fixture(sentinel) do
    """
    diff --git a/lib/example_1.ex b/lib/example_1.ex
    index 1111111..2222222 100644
    --- a/lib/example_1.ex
    +++ b/lib/example_1.ex
    @@ -1,8 +1,8 @@
     context kept before
    -old first
    +new first
     context kept after
     context omitted #{sentinel}
     context omitted two
     context omitted three
     context omitted four
    @@ -20,4 +20,4 @@
     before second
    -old second
    +new second
     after second
    diff --git a/lib/example_2.ex b/lib/example_2.ex
    index 3333333..4444444 100644
    --- a/lib/example_2.ex
    +++ b/lib/example_2.ex
    @@ -1,3 +1,3 @@
     before other
    -old other
    +new other
    """
  end

  defp additions_only_fixture do
    diff_with_context("+added value")
  end

  defp deletions_only_fixture do
    diff_with_context("-removed value")
  end

  defp replacement_fixture do
    diff_with_context("""
    -old value
    +new value
    """)
  end

  defp diff_with_context(change) do
    context =
      1..24
      |> Enum.map_join("\n", &" context line #{&1}")

    """
    @@ -1,25 +1,25 @@
    #{context}
    #{String.trim_trailing(change)}
    """
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
