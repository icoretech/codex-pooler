defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.BPE do
  @moduledoc false

  @type ranks :: %{required(binary()) => non_neg_integer()}

  @spec count(binary(), ranks()) :: non_neg_integer()
  def count("", _ranks), do: 0

  def count(chunk, ranks) when is_binary(chunk) and is_map(ranks) do
    case Map.fetch(ranks, chunk) do
      {:ok, _rank} ->
        1

      :error ->
        chunk
        |> byte_pieces()
        |> merge_count(ranks)
    end
  end

  @spec encode(binary(), ranks()) :: [non_neg_integer()]
  def encode("", _ranks), do: []

  def encode(chunk, ranks) when is_binary(chunk) and is_map(ranks) do
    case Map.fetch(ranks, chunk) do
      {:ok, rank} ->
        [rank]

      :error ->
        chunk
        |> byte_pieces()
        |> merge_pieces(ranks)
        |> Enum.map(&Map.fetch!(ranks, &1))
    end
  end

  defp merge_count(pieces, ranks), do: pieces |> merge_pieces(ranks) |> length()

  defp byte_pieces(chunk) do
    for <<byte <- chunk>>, do: <<byte>>
  end

  defp merge_pieces([], _ranks), do: []
  defp merge_pieces([_piece] = pieces, _ranks), do: pieces

  defp merge_pieces(pieces, ranks) do
    case lowest_ranked_pair(pieces, ranks) do
      nil -> pieces
      index -> pieces |> merge_at(index) |> merge_pieces(ranks)
    end
  end

  defp lowest_ranked_pair([first, second | rest], ranks) do
    best_rank = pair_rank(first, second, ranks)
    best_index = if is_nil(best_rank), do: nil, else: 0

    lowest_ranked_pair(rest, second, ranks, 0, best_rank, best_index)
  end

  defp lowest_ranked_pair(_pieces, _ranks), do: nil

  defp lowest_ranked_pair([], _previous, _ranks, _index, nil, best_index), do: best_index
  defp lowest_ranked_pair([], _previous, _ranks, _index, _best_rank, best_index), do: best_index

  defp lowest_ranked_pair([next | rest], previous, ranks, index, best_rank, best_index) do
    pair_index = index + 1
    rank = pair_rank(previous, next, ranks)

    {best_rank, best_index} =
      cond do
        is_nil(rank) -> {best_rank, best_index}
        is_nil(best_rank) -> {rank, pair_index}
        rank < best_rank -> {rank, pair_index}
        true -> {best_rank, best_index}
      end

    lowest_ranked_pair(rest, next, ranks, pair_index, best_rank, best_index)
  end

  defp pair_rank(first, second, ranks), do: Map.get(ranks, first <> second)

  defp merge_at(pieces, index) do
    {before_pair, [first, second | after_pair]} = Enum.split(pieces, index)
    before_pair ++ [first <> second | after_pair]
  end
end
