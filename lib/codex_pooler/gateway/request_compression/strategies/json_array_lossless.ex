defmodule CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLossless do
  @moduledoc """
  Conservative JSON-array request compression.

  This strategy only minifies valid JSON array text and returns a rewrite when
  local token counting proves a strict reduction. Dropping rows, object keys,
  values, or nested data is intentionally left out until a recoverability design
  exists.
  """

  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @strategy "json_array_lossless"

  @type opts :: keyword() | map()
  @type metadata :: %{
          required(:strategy) => String.t(),
          required(:row_count) => non_neg_integer(),
          required(:original_bytes) => non_neg_integer(),
          required(:compressed_bytes) => non_neg_integer(),
          required(:saved_bytes) => non_neg_integer(),
          required(:original_tokens) => non_neg_integer(),
          required(:compressed_tokens) => non_neg_integer(),
          required(:saved_tokens) => pos_integer(),
          required(:tokenizer) => String.t(),
          required(:encoding) => String.t()
        }
  @type skip_reason :: :tokenizer_input_limit
  @type result ::
          {:ok, %{required(:content) => String.t(), required(:metadata) => metadata()}}
          | :skip
          | {:skip, skip_reason()}

  @spec compress(term(), opts()) :: result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    with {:ok, model} <- model(opts),
         {:ok, rows} when is_list(rows) <- Jason.decode(content, objects: :ordered_objects),
         {:ok, compressed} <- Jason.encode(rows),
         true <- byte_size(compressed) < byte_size(content),
         {:ok, original_tokens, token_metadata} <- TokenCounter.count(model, content),
         {:ok, compressed_tokens, _metadata} <- TokenCounter.count(model, compressed),
         true <- compressed_tokens < original_tokens do
      metadata =
        metadata(
          rows,
          content,
          compressed,
          original_tokens,
          compressed_tokens,
          token_metadata
        )

      {:ok, %{content: compressed, metadata: metadata}}
    else
      {:error, :tokenizer_input_limit} -> {:skip, :tokenizer_input_limit}
      _skip -> :skip
    end
  end

  def compress(_content, _opts), do: :skip

  defp metadata(rows, original, compressed, original_tokens, compressed_tokens, token_metadata) do
    original_bytes = byte_size(original)
    compressed_bytes = byte_size(compressed)

    %{
      strategy: @strategy,
      row_count: length(rows),
      original_bytes: original_bytes,
      compressed_bytes: compressed_bytes,
      saved_bytes: original_bytes - compressed_bytes,
      original_tokens: original_tokens,
      compressed_tokens: compressed_tokens,
      saved_tokens: original_tokens - compressed_tokens,
      tokenizer: token_metadata.tokenizer,
      encoding: token_metadata.encoding
    }
  end

  defp model(opts) do
    opts
    |> option(:model, nil)
    |> case do
      model when is_binary(model) ->
        model = String.trim(model)
        if model == "", do: :error, else: {:ok, model}

      _other ->
        :error
    end
  end

  defp option(opts, key, default) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key, default), else: default
  end

  defp option(opts, key, default) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key), default)
  end

  defp option(_opts, _key, default), do: default
end
