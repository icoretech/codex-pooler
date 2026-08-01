defmodule CodexPooler.Gateway.RequestCompression.Strategies.EmbeddedJsonLossless do
  @moduledoc """
  Conservative lossless compression for JSON containers embedded in ordinary text.

  The strategy preserves every byte outside validated JSON object and array spans,
  preserves duplicate object keys, and returns a rewrite only when local token
  counting proves that the complete output shrinks.
  """

  alias CodexPooler.Gateway.RequestCompression.EmbeddedJson
  alias CodexPooler.Gateway.RequestCompression.JsonStringRanges
  alias CodexPooler.Gateway.RequestCompression.Strategies
  alias CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLossless
  alias CodexPooler.Gateway.RequestCompression.Strategies.JsonDocumentLossless

  @strategy :embedded_json_lossless

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    with {:ok, spans} <- EmbeddedJson.plan(content),
         {:ok, replacements, counts} <- span_replacements(content, spans, opts),
         {:ok, compressed} <- JsonStringRanges.replace_ranges(content, replacements) do
      Strategies.finalize(@strategy, content, compressed, counts, opts)
    else
      {:skip, :tokenizer_input_limit} -> {:skip, :tokenizer_input_limit}
      _not_rewritable -> :skip
    end
  end

  def compress(_content, _opts), do: :skip

  defp span_replacements(content, spans, opts) do
    {replacements, kinds, tokenizer_input_skips} =
      Enum.reduce(spans, {[], [], 0}, fn span, {replacements, kinds, skips} ->
        case compress_span(content, span, opts) do
          {:ok, replacement} ->
            {[replacement | replacements], [span.kind | kinds], skips}

          {:skip, :tokenizer_input_limit} ->
            {replacements, kinds, skips + 1}

          :skip ->
            {replacements, kinds, skips}
        end
      end)

    replacements = Enum.reverse(replacements)

    cond do
      replacements != [] -> {:ok, replacements, counts(kinds)}
      tokenizer_input_skips == length(spans) -> {:skip, :tokenizer_input_limit}
      true -> :skip
    end
  end

  defp compress_span(content, span, opts) do
    span_content = binary_part(content, span.byte_start, span.byte_end - span.byte_start)
    module = strategy_module(span.kind)

    case module.compress(span_content, opts) do
      {:ok, %{content: compressed}} ->
        {:ok,
         %{
           byte_start: span.byte_start,
           byte_end: span.byte_end,
           replacement: compressed
         }}

      {:skip, :tokenizer_input_limit} ->
        {:skip, :tokenizer_input_limit}

      _not_compressed ->
        :skip
    end
  end

  defp strategy_module(:array), do: JsonArrayLossless
  defp strategy_module(:object), do: JsonDocumentLossless

  defp counts(kinds) do
    %{
      span_count: length(kinds),
      object_span_count: Enum.count(kinds, &(&1 == :object)),
      array_span_count: Enum.count(kinds, &(&1 == :array))
    }
  end
end
