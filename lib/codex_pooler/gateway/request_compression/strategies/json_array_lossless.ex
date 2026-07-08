defmodule CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLossless do
  @moduledoc """
  Conservative JSON-array request compression.

  This strategy only minifies valid JSON array text and returns a rewrite when
  local token counting proves a strict reduction. Dropping rows, object keys,
  values, or nested data is intentionally left out until a recoverability design
  exists.
  """

  alias CodexPooler.Gateway.RequestCompression.ContentDetector
  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :json_array_lossless

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    case Jason.decode(content, objects: :ordered_objects) do
      {:ok, rows} when is_list(rows) ->
        finalize(content, rows, length(rows), opts)

      _not_array ->
        compress_concatenated_object_stream(content, opts)
    end
  end

  def compress(_content, _opts), do: :skip

  defp compress_concatenated_object_stream(content, opts) do
    case ContentDetector.normalize_concatenated_json_objects(content) do
      {:ok, normalized, row_count} ->
        Strategies.finalize(@strategy, content, normalized, %{row_count: row_count}, opts)

      :error ->
        :skip
    end
  end

  defp finalize(original, rows, row_count, opts) do
    case Jason.encode(rows) do
      {:ok, compressed} ->
        Strategies.finalize(@strategy, original, compressed, %{row_count: row_count}, opts)

      {:error, _reason} ->
        :skip
    end
  end
end
