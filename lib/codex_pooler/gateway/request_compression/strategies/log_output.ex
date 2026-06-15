defmodule CodexPooler.Gateway.RequestCompression.Strategies.LogOutput do
  @moduledoc false

  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :log_output
  @default_min_bytes 512
  @default_min_lines 24
  @default_head_lines 8
  @default_tail_lines 8
  @default_context_lines 2
  @default_max_important_lines 12

  @important_line_regex ~r/(?:^|\b)(?:error|warning|warn|failed|failure|fatal|panic|exception|traceback|assertion|exit\s+code|caused\s+by)(?:\b|:)/i

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    min_bytes = Strategies.integer_option(opts, :min_bytes, @default_min_bytes, 0)
    min_lines = Strategies.integer_option(opts, :min_lines, @default_min_lines, 1)

    with true <- byte_size(content) >= min_bytes,
         {:ok, lines} <- Strategies.lines(content),
         line_count when line_count >= min_lines <- length(lines),
         important_indexes when important_indexes != [] <- important_indexes(lines) do
      selected_indexes = selected_indexes(lines, important_indexes, opts)
      {compressed_lines, omitted_line_count} = collapse(lines, selected_indexes)
      compressed = Strategies.join_lines(compressed_lines)

      Strategies.finalize(
        @strategy,
        content,
        compressed,
        %{
          original_line_count: line_count,
          compressed_line_count: length(compressed_lines),
          kept_line_count: line_count - omitted_line_count,
          omitted_line_count: omitted_line_count,
          important_line_count: length(important_indexes),
          kept_important_line_count:
            kept_important_line_count(important_indexes, selected_indexes)
        },
        opts
      )
    else
      _not_compressible -> :skip
    end
  end

  def compress(_content, _opts), do: :skip

  defp important_indexes(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce([], fn {line, index}, indexes ->
      if Regex.match?(@important_line_regex, line) do
        [index | indexes]
      else
        indexes
      end
    end)
    |> Enum.reverse()
  end

  defp selected_indexes(lines, important_indexes, opts) do
    line_count = length(lines)
    head_lines = Strategies.integer_option(opts, :head_lines, @default_head_lines, 0)
    tail_lines = Strategies.integer_option(opts, :tail_lines, @default_tail_lines, 0)
    context_lines = Strategies.integer_option(opts, :context_lines, @default_context_lines, 0)

    max_important_lines =
      Strategies.integer_option(opts, :max_important_lines, @default_max_important_lines, 1)

    important_indexes =
      Strategies.take_first_last(important_indexes, max_important_lines)

    [
      leading_indexes(line_count, head_lines),
      trailing_indexes(line_count, tail_lines),
      context_indexes(line_count, important_indexes, context_lines)
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp leading_indexes(_line_count, 0), do: []
  defp leading_indexes(0, _head_lines), do: []

  defp leading_indexes(line_count, head_lines) do
    0..(min(line_count, head_lines) - 1)//1
    |> Enum.to_list()
  end

  defp trailing_indexes(_line_count, 0), do: []
  defp trailing_indexes(0, _tail_lines), do: []

  defp trailing_indexes(line_count, tail_lines) do
    start_index = max(line_count - tail_lines, 0)

    start_index..(line_count - 1)//1
    |> Enum.to_list()
  end

  defp context_indexes(line_count, indexes, context_lines) do
    last_index = line_count - 1

    Enum.flat_map(indexes, fn index ->
      max(index - context_lines, 0)..min(index + context_lines, last_index)//1
      |> Enum.to_list()
    end)
  end

  defp collapse(lines, selected_indexes) do
    Strategies.collapse_lines(lines, selected_indexes, fn count ->
      "[compressed log output: omitted #{count} lines]"
    end)
  end

  defp kept_important_line_count(important_indexes, selected_indexes) do
    selected_indexes = MapSet.new(selected_indexes)
    Enum.count(important_indexes, &MapSet.member?(selected_indexes, &1))
  end
end
