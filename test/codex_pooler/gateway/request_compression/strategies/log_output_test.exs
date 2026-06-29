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

    test "keeps success and diagnostic summary lines as important landmarks" do
      content =
        [
          "Starting a Gradle Daemon",
          "ordinary setup line"
        ]
        |> Kernel.++(Enum.map(1..80, &"> Task :app:compile#{&1} UP-TO-DATE"))
        |> Kernel.++([
          "BUILD SUCCESSFUL in 3s",
          "28 actionable tasks: 28 up-to-date"
        ])
        |> Enum.join("\n")

      assert {:ok, %{content: compressed, metadata: metadata}} =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 1,
                 tail_lines: 0,
                 context_lines: 1,
                 max_important_lines: 4
               )

      assert compressed =~ "BUILD SUCCESSFUL in 3s"
      assert compressed =~ "28 actionable tasks: 28 up-to-date"
      assert compressed =~ "[compressed log output: omitted"
      assert metadata.important_line_count == 2
    end

    test "skips when summary failure count exceeds discovered failure blocks" do
      content =
        failure_log_fixture(3,
          summary: "Failed! - Failed: 5, Passed: 7, Skipped: 0, Total: 12",
          sentinel: "DROP_ME_INCOMPLETE_FAILURE_LOG"
        )

      assert :skip =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 6
               )
    end

    test "compresses when every reported failure block remains visible" do
      sentinel = "DROP_ME_COMPLETE_FAILURE_LOG"

      content =
        failure_log_fixture(3,
          summary: "Failed! - Failed: 3, Passed: 7, Skipped: 0, Total: 10",
          sentinel: sentinel
        )

      assert {:ok, %{content: compressed, metadata: metadata}} =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 8
               )

      assert compressed =~ "MyTests.Case1"
      assert compressed =~ "MyTests.Case2"
      assert compressed =~ "MyTests.Case3"
      assert compressed =~ "Failed! - Failed: 3"
      refute compressed =~ sentinel
      assert metadata.important_line_count == 7
      assert_safe_metadata(metadata, :log_output, sentinel)
    end

    test "recognizes combined failures-colon summary formats" do
      content =
        failure_log_fixture(3,
          summary: "Tests run: 12, Failures: 3, Errors: 2, Skipped: 0",
          sentinel: "DROP_ME_JUNIT_FAILURE_LOG"
        )

      assert :skip =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 6
               )
    end

    test "adds failure and error summary categories without double-counting repeated wording" do
      content =
        failure_log_fixture(4,
          summary: "Tests run: 12, Failed: 3, Failures: 3, Errors: 2, Skipped: 0",
          sentinel: "DROP_ME_REPEATED_JUNIT_FAILURE_LOG"
        )

      assert :skip =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 8
               )
    end

    test "retains every grep-shaped failure detail referenced by a summary" do
      sentinel = "DROP_ME_GREP_FAILURE_DETAILS"

      content =
        grep_failure_log_fixture(3, summary: "search completed with 3 errors", sentinel: sentinel)

      assert {:ok, %{content: compressed, metadata: metadata}} =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 1
               )

      assert compressed =~ "rg: error: fixture_1.ex: No such file or directory"
      assert compressed =~ "grep: error: fixture_2.ex: Permission denied"
      assert compressed =~ "error: search backend fixture 3 exited with status 2"
      assert compressed =~ "search completed with 3 errors"
      refute compressed =~ sentinel
      assert_safe_metadata(metadata, :log_output, sentinel)
    end

    test "keeps synthetic high-entropy values out of lossy search-like log metadata" do
      synthetic_high_entropy_value =
        "synthetic-high-entropy-placeholder-Zx9Kq3Wm7Pv2Lr8Nt4Bc6Df1Gh5Jy"

      content =
        grep_failure_log_fixture(3,
          summary: "search completed with 3 errors",
          sentinel: synthetic_high_entropy_value
        )

      assert {:ok, %{content: compressed, metadata: metadata}} =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 1
               )

      assert compressed =~ "[compressed log output: omitted"
      assert compressed =~ "rg: error: fixture_1.ex: No such file or directory"
      assert compressed =~ "grep: error: fixture_2.ex: Permission denied"
      assert compressed =~ "error: search backend fixture 3 exited with status 2"
      assert compressed =~ "search completed with 3 errors"
      refute compressed =~ synthetic_high_entropy_value
      assert_safe_metadata(metadata, :log_output, synthetic_high_entropy_value)
    end

    test "skips grep-shaped summaries when a referenced detail would be omitted" do
      content =
        grep_failure_log_fixture(2,
          summary: "search completed with 3 errors",
          sentinel: "DROP_ME_INCOMPLETE_GREP_FAILURE_DETAILS"
        )

      assert :skip =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 2
               )
    end

    test "recognizes terse count-before-failed summary formats" do
      content =
        failure_log_fixture(3,
          summary: "Tests: 20 failed, 3 passed, 23 total",
          sentinel: "DROP_ME_TERSE_FAILED_SUMMARY_LOG"
        )

      assert :skip =
               LogOutput.compress(content,
                 model: @model,
                 min_bytes: 0,
                 min_lines: 1,
                 head_lines: 0,
                 tail_lines: 0,
                 context_lines: 0,
                 max_important_lines: 6
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

  defp failure_log_fixture(failure_count, opts) do
    summary = Keyword.fetch!(opts, :summary)
    sentinel = Keyword.fetch!(opts, :sentinel)

    failure_blocks =
      Enum.flat_map(1..failure_count//1, fn index ->
        [
          "error: MyTests.Case#{index} failed",
          "stack context for case #{index}",
          "assertion failed: expected #{index}"
        ] ++ Enum.map(1..4//1, &"ordinary separator #{index}.#{&1}")
      end)

    filler =
      Enum.map(1..120//1, fn
        60 -> "ordinary build line 60 #{sentinel}"
        index -> "ordinary build line #{index}"
      end)

    ["test suite started"]
    |> Kernel.++(failure_blocks)
    |> Kernel.++(filler)
    |> Kernel.++([summary])
    |> Enum.join("\n")
  end

  defp grep_failure_log_fixture(failure_count, opts) do
    summary = Keyword.fetch!(opts, :summary)
    sentinel = Keyword.fetch!(opts, :sentinel)

    details =
      Enum.flat_map(1..failure_count//1, fn
        1 ->
          ["rg: error: fixture_1.ex: No such file or directory"] ++
            Enum.map(1..4//1, &"ordinary search separator 1.#{&1}")

        2 ->
          ["grep: error: fixture_2.ex: Permission denied"] ++
            Enum.map(1..4//1, &"ordinary search separator 2.#{&1}")

        index ->
          ["error: search backend fixture #{index} exited with status 2"] ++
            Enum.map(1..4//1, &"ordinary search separator #{index}.#{&1}")
      end)

    filler =
      Enum.map(1..120//1, fn
        60 -> "ordinary search line 60 #{sentinel}"
        index -> "ordinary search line #{index}"
      end)

    ["search command started"]
    |> Kernel.++(details)
    |> Kernel.++(filler)
    |> Kernel.++([summary])
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
