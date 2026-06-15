defmodule CodexPooler.Gateway.RequestCompression.Strategies.LogOutputTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.Strategies.LogOutput
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @model "gpt-4o"

  describe "compress/2" do
    test "keeps first and last important log lines with bounded context" do
      sentinel = "DROP_ME_LOG_SENTINEL"
      content = log_fixture(sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 1,
                 tail_lines: 1,
                 context_lines: 1,
                 max_important_lines: 2
               )

      assert compressed =~ "error: first failure"
      assert compressed =~ "fatal: final failure"
      assert compressed =~ "context before first"
      assert compressed =~ "context after final"
      assert compressed =~ "[compressed log output: omitted"
      refute compressed =~ sentinel

      assert metadata.strategy == :log_output
      assert metadata.original_bytes > metadata.compressed_bytes
      assert metadata.original_tokens > metadata.compressed_tokens
      assert metadata.important_line_count == 2
      assert metadata.kept_important_line_count == 2
      assert metadata.omitted_line_count > 0
      assert_safe_metadata(metadata, :log_output, sentinel)
    end

    test "rejects byte-shrinking rewrites that do not shrink tokens" do
      original =
        ["error: a"]
        |> Kernel.++(List.duplicate("", 80))
        |> Kernel.++(["fatal: b"])
        |> Enum.join("\n")

      byte_smaller_candidate = "error: a\n[compressed log output: omitted 80 lines]\nfatal: b"

      assert byte_size(byte_smaller_candidate) < byte_size(original)
      assert token_count(byte_smaller_candidate) >= token_count(original)

      assert :skip =
               LogOutput.compress(original,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 2
               )
    end

    test "skips malformed, too-small, and nonmatching input" do
      assert :skip = LogOutput.compress(:not_text)
      assert :skip = LogOutput.compress(<<255>>, min_bytes: 0)
      assert :skip = LogOutput.compress("error: tiny\n", min_bytes: 512)

      nonmatching =
        Enum.map_join(1..30, "\n", &"ordinary output line #{&1}")

      assert :skip = LogOutput.compress(nonmatching, min_bytes: 0, min_lines: 1)
    end

    test "does not retain state between calls" do
      assert {:ok, _result} =
               LogOutput.compress(log_fixture("DROP_ME_STALE_LOG"),
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 1,
                 tail_lines: 1,
                 context_lines: 1,
                 max_important_lines: 2
               )

      assert :skip =
               LogOutput.compress("ordinary output after prior compression",
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1
               )
    end

    test "skips when tokenizer model is missing or unsupported" do
      opts = [
        min_bytes: 0,
        min_lines: 1,
        head_lines: 1,
        tail_lines: 1,
        context_lines: 1,
        max_important_lines: 2
      ]

      assert :skip = LogOutput.compress(log_fixture("DROP_ME_NO_MODEL"), opts)

      assert :skip =
               LogOutput.compress(
                 log_fixture("DROP_ME_UNSUPPORTED_MODEL"),
                 Keyword.put(opts, :model, "unknown-model")
               )
    end
  end

  defp log_fixture(sentinel) do
    middle =
      1..80
      |> Enum.map(fn
        40 -> "ordinary build line 40 #{sentinel}"
        index -> "ordinary build line #{index}"
      end)

    [
      "command started",
      "context before first",
      "error: first failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final failure",
      "context after final"
    ])
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
