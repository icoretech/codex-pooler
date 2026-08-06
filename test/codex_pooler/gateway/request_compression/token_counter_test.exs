defmodule CodexPooler.Gateway.RequestCompression.TokenCounterTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  describe "count/2" do
    test "counts o200k models with local rank data" do
      assert {:ok, 4, %{tokenizer: "codex_pooler:tiktoken", encoding: "o200k_base"}} =
               TokenCounter.count("gpt-4o", "Hello, world!")

      assert {:ok, 4, %{encoding: "o200k_base"}} =
               TokenCounter.count("o3-mini", "Hello, world!")
    end

    test "counts cl100k models with local rank data" do
      assert {:ok, 4, %{tokenizer: "codex_pooler:tiktoken", encoding: "cl100k_base"}} =
               TokenCounter.count("gpt-4-turbo", "Hello, world!")

      assert {:ok, 4, %{encoding: "cl100k_base"}} =
               TokenCounter.count("gpt-3.5-turbo", "Hello, world!")
    end

    test "matches oracle counts for sanitized tool-output-like content" do
      output =
        String.duplicate(
          "example command output line\nERROR sample failure at path /example/file.ex:12\n",
          3
        )

      assert {:ok, 51, %{encoding: "o200k_base"}} = TokenCounter.count("gpt-4o", output)
      assert {:ok, 51, %{encoding: "cl100k_base"}} = TokenCounter.count("gpt-4-turbo", output)
    end

    test "counts literal special-token-looking strings as ordinary text" do
      content = """
      tool output can contain <|endoftext|>
      diff markers can contain <|fim_prefix|>, <|fim_middle|>, and <|fim_suffix|>
      """

      assert {:ok, o200k_count, %{encoding: "o200k_base"}} =
               TokenCounter.count("gpt-4o", content)

      assert o200k_count > 0

      assert {:ok, cl100k_count, %{encoding: "cl100k_base"}} =
               TokenCounter.count("gpt-4-turbo", content)

      assert cl100k_count > 0
    end

    test "matches oracle counts for unicode and diff-like content" do
      unicode = "unicode sample: ciao mondo, こんにちは, Привет, مرحبا, 😀"

      diff = """
      diff --git a/example.txt b/example.txt
      @@ -1,2 +1,2 @@
      -old value
      +new value
      """

      assert {:ok, 17, %{encoding: "o200k_base"}} = TokenCounter.count("gpt-4o", unicode)
      assert {:ok, 21, %{encoding: "cl100k_base"}} = TokenCounter.count("gpt-4-turbo", unicode)

      assert {:ok, 28, %{encoding: "o200k_base"}} = TokenCounter.count("gpt-4o", diff)
      assert {:ok, 27, %{encoding: "cl100k_base"}} = TokenCounter.count("gpt-4-turbo", diff)
    end

    test "returns controlled errors for unknown models" do
      assert {:error, :unsupported_model} =
               TokenCounter.count("unknown-tokenizer-port-model", "Hello, world!")
    end

    test "returns a controlled error before oversized input reaches pretokenization" do
      long_input = String.duplicate("a", TokenCounter.max_input_bytes() + 1)

      assert {:error, :tokenizer_input_limit} = TokenCounter.count("gpt-4o", long_input)
    end

    test "returns a controlled error before oversized chunks reach BPE" do
      long_run = String.duplicate("a", TokenCounter.max_bpe_chunk_bytes() + 1)

      assert {:error, :tokenizer_input_limit} = TokenCounter.count("gpt-4o", long_run)
    end

    test "does not expose payload text in metadata" do
      sentinel = "SENSITIVE_SENTINEL_example_tool_output"

      assert {:ok, _count, metadata} = TokenCounter.count("gpt-4o", sentinel)

      refute inspect(metadata) =~ sentinel
    end
  end

  describe "encoding_for_model/1" do
    test "maps supported and unsupported model names to encodings" do
      cases = [
        {"gpt-5", {:ok, :o200k_base}},
        {"gpt-5-mini", {:ok, :o200k_base}},
        {"gpt-5-nano", {:ok, :o200k_base}},
        {"GPT-5", {:ok, :o200k_base}},
        {" GpT-5-mini ", {:ok, :o200k_base}},
        {"GPT-4", {:ok, :cl100k_base}},
        {"GPT-4-Turbo", {:ok, :cl100k_base}},
        {"gpt5", {:error, :unsupported_model}},
        {"gpt-6", {:error, :unsupported_model}}
      ]

      for {model, expected} <- cases do
        assert TokenCounter.encoding_for_model(model) == expected
      end
    end
  end

  describe "count_tokens/2" do
    test "keeps the release-smoke helper API stable" do
      assert TokenCounter.count_tokens("gpt-4o", "Hello, world!") ==
               TokenCounter.count("gpt-4o", "Hello, world!")
    end
  end

  describe "count_lower_bound/2" do
    test "keeps exact semantics for small inputs" do
      content = "example command output line\nERROR sample failure\n"

      assert TokenCounter.count_lower_bound("gpt-4o", content) ==
               TokenCounter.count("gpt-4o", content)
    end

    test "returns a conservative count for oversized inputs without exposing content" do
      sentinel = "SENSITIVE_SENTINEL_bounded_tool_output"
      content = String.duplicate("bounded sanitized line\n", 600) <> sentinel

      assert {:error, :tokenizer_input_limit} = TokenCounter.count("gpt-4o", content)

      assert {:ok, count, metadata} = TokenCounter.count_lower_bound("gpt-4o", content)
      assert count > 0
      assert metadata == %{tokenizer: "codex_pooler:tiktoken", encoding: "o200k_base"}
      refute inspect(metadata) =~ sentinel
    end

    test "returns controlled errors for invalid oversized binaries" do
      invalid = String.duplicate("valid ", 2_000) <> <<255>>

      assert {:error, :tokenizer_input_limit} = TokenCounter.count_lower_bound("gpt-4o", invalid)
    end

    test "returns controlled errors for unknown models" do
      assert {:error, :unsupported_model} =
               TokenCounter.count_lower_bound("unknown-tokenizer-port-model", "Hello, world!")
    end
  end
end
