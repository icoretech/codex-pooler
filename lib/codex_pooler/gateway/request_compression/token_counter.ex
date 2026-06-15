defmodule CodexPooler.Gateway.RequestCompression.TokenCounter do
  @moduledoc """
  Local exact token counter for request-compression decisions.

  This module intentionally performs local BPE tokenization against vendored
  tiktoken rank data. It does not call provider APIs, load model weights, or use
  native dependencies.
  """

  alias CodexPooler.Gateway.RequestCompression.TokenCounter.BPE
  alias CodexPooler.Gateway.RequestCompression.TokenCounter.Pretokenizer
  alias CodexPooler.Gateway.RequestCompression.TokenCounter.Ranks

  @type encoding :: :cl100k_base | :o200k_base
  @type metadata :: %{
          required(:tokenizer) => String.t(),
          required(:encoding) => String.t()
        }
  @type error_reason ::
          :unsupported_model
          | :unsupported_encoding
          | :rank_file_unavailable
          | :invalid_rank_file
          | :tokenizer_input_limit
  @type count_result :: {:ok, non_neg_integer(), metadata()} | {:error, error_reason()}

  @max_input_bytes 8_192
  @max_bpe_chunk_bytes 1_024

  @spec count(String.t(), String.t()) :: count_result()
  def count(model, text) when is_binary(model) and is_binary(text) do
    with :ok <- input_within_limit(text),
         {:ok, encoding} <- encoding_for_model(model),
         {:ok, ranks} <- Ranks.load(encoding),
         {:ok, chunks} <- safe_chunks(text, encoding) do
      count =
        Enum.reduce(chunks, 0, fn chunk, acc -> acc + BPE.count(chunk, ranks) end)

      {:ok, count, metadata(encoding)}
    end
  end

  def count(_model, _text), do: {:error, :unsupported_model}

  @spec count_tokens(String.t(), String.t()) :: count_result()
  def count_tokens(model, text), do: count(model, text)

  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: @max_input_bytes

  @spec max_bpe_chunk_bytes() :: pos_integer()
  def max_bpe_chunk_bytes, do: @max_bpe_chunk_bytes

  @spec encoding_for_model(String.t()) :: {:ok, encoding()} | {:error, :unsupported_model}
  def encoding_for_model(model) when is_binary(model) do
    normalized = model |> String.trim() |> String.downcase()

    cond do
      normalized in ["o200k_base", "gpt-4o", "gpt-4o-mini"] ->
        {:ok, :o200k_base}

      String.starts_with?(normalized, [
        "gpt-4o-",
        "o1",
        "o3",
        "o4",
        "gpt-4.1",
        "gpt-5"
      ]) ->
        {:ok, :o200k_base}

      normalized in ["cl100k_base", "gpt-4", "gpt-4-turbo", "gpt-3.5-turbo"] ->
        {:ok, :cl100k_base}

      String.starts_with?(normalized, [
        "gpt-4-",
        "gpt-4-turbo-",
        "gpt-3.5-turbo-",
        "text-embedding-3-",
        "text-embedding-ada-002"
      ]) ->
        {:ok, :cl100k_base}

      true ->
        {:error, :unsupported_model}
    end
  end

  def encoding_for_model(_model), do: {:error, :unsupported_model}

  defp input_within_limit(text) do
    if byte_size(text) > @max_input_bytes do
      {:error, :tokenizer_input_limit}
    else
      :ok
    end
  end

  defp safe_chunks(text, encoding) do
    chunks = Pretokenizer.split(text, encoding)

    if Enum.any?(chunks, &(byte_size(&1) > @max_bpe_chunk_bytes)) do
      {:error, :tokenizer_input_limit}
    else
      {:ok, chunks}
    end
  end

  defp metadata(encoding) do
    %{
      tokenizer: "codex_pooler:tiktoken",
      encoding: Atom.to_string(encoding)
    }
  end
end
