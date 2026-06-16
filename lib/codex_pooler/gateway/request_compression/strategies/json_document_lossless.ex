defmodule CodexPooler.Gateway.RequestCompression.Strategies.JsonDocumentLossless do
  @moduledoc """
  Conservative JSON-object request compression.

  This strategy only minifies valid top-level JSON object text and returns a
  rewrite when local token counting proves a strict reduction. Arrays keep using
  the existing array strategy so row-oriented metadata stays stable.
  """

  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :json_document_lossless

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    with {:ok, %Jason.OrderedObject{} = document} <-
           Jason.decode(content, objects: :ordered_objects),
         {:ok, compressed} <- Jason.encode(document) do
      Strategies.finalize(
        @strategy,
        content,
        compressed,
        %{top_level_key_count: top_level_key_count(document)},
        opts
      )
    else
      _skip -> :skip
    end
  end

  def compress(_content, _opts), do: :skip

  defp top_level_key_count(%Jason.OrderedObject{values: values}), do: length(values)
end
