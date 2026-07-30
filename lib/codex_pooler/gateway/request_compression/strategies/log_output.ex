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

  @important_line_regex ~r/(?:^|\b)(?:error|warning|warn|failed|failure|fatal|panic|exception|traceback|assertion|exit\s+code|caused\s+by)(?:\b|:)|^\s*(?:Build\s+(?:FAILED|succeeded)|BUILD\s+(?:FAILED|SUCCESSFUL)|\*\*\s+BUILD\s+(?:FAILED|SUCCEEDED)\s+\*\*|Failed!\s+-\s+Failed:|Passed!\s+-\s+Failed:|Test summary:|Found\s+\d+\s+(?:errors?|warnings?)|Executed\s+\d+\s+tests?,\s+with\s+\d+|\d+\s+(?:Warning|Error)\(s\)|\d+\s+(?:tests?|examples?)\s+(?:completed|run|passed|failed)|\d+\s+actionable tasks?:)/i
  @failure_detail_regex ~r/(?:^|\b)(?:error|failed|failure|fatal|panic|exception|traceback|assertion)(?:\b|:)/i
  @failure_summary_labeled_regex ~r/\b(failed|failures?|errors?)\s*[:=]\s*(\d+)\b/i
  @failure_summary_count_regexes [
    {~r/\bwith\s+(\d+)\s+(failures?|errors?)\b/i, :labeled},
    {~r/\b(\d+)\s+(?:tests?|examples?)\s+failed\b/i, :failures},
    {~r/\b(\d+)\s+failed\b/i, :failures},
    {~r/\b(\d+)\s+(failures?|errors?)\b/i, :labeled}
  ]
  @failure_block_gap 2

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    min_bytes = Strategies.integer_option(opts, :min_bytes, @default_min_bytes, 0)
    min_lines = Strategies.integer_option(opts, :min_lines, @default_min_lines, 1)

    with true <- byte_size(content) >= min_bytes,
         {:ok, lines} <- Strategies.lines(content),
         line_count when line_count >= min_lines <- length(lines),
         important_indexes when important_indexes != [] <- important_indexes(lines) do
      failure_analysis = failure_analysis(lines)
      selected_indexes = selected_indexes(lines, important_indexes, failure_analysis, opts)

      if incomplete_failure_details?(failure_analysis, selected_indexes) do
        :skip
      else
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
      end
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

  defp incomplete_failure_details?(failure_analysis, selected_indexes) do
    case failure_analysis.summary_count do
      0 ->
        false

      summary_count ->
        failure_blocks = failure_analysis.detail_blocks

        length(failure_blocks) < summary_count or
          retained_failure_detail_block_count(failure_blocks, selected_indexes) < summary_count
    end
  end

  defp failure_analysis(lines) do
    {summary_counts, summary_indexes, detail_indexes} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({%{}, [], []}, fn {line, index},
                                       {summary_counts, summary_indexes, detail_indexes} ->
        line_summary_counts = failure_summary_counts_for_line(line)
        summary? = map_size(line_summary_counts) > 0

        {
          merge_summary_counts(summary_counts, line_summary_counts),
          if(summary?, do: [index | summary_indexes], else: summary_indexes),
          if(Regex.match?(@failure_detail_regex, line) and not summary?,
            do: [index | detail_indexes],
            else: detail_indexes
          )
        }
      end)

    %{
      summary_count: summary_counts |> Map.values() |> Enum.sum(),
      summary_indexes: Enum.reverse(summary_indexes),
      detail_blocks: detail_indexes |> Enum.reverse() |> failure_indexes_to_blocks()
    }
  end

  defp failure_summary_counts_for_line(line) do
    line
    |> labeled_summary_counts()
    |> merge_summary_counts(regex_summary_counts(line))
  end

  defp labeled_summary_counts(line) do
    @failure_summary_labeled_regex
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.reduce(%{}, fn [label, count], counts ->
      put_summary_count(counts, summary_count_kind(label), count)
    end)
  end

  defp regex_summary_counts(line) do
    Enum.reduce(@failure_summary_count_regexes, %{}, fn {regex, kind}, counts ->
      regex
      |> Regex.scan(line, capture: :all_but_first)
      |> Enum.reduce(counts, fn captures, counts ->
        {count, kind} = regex_summary_count(captures, kind)
        put_summary_count(counts, kind, count)
      end)
    end)
  end

  defp regex_summary_count([count, label], :labeled),
    do: {count, summary_count_kind(label)}

  defp regex_summary_count([count | _captures], kind), do: {count, kind}

  defp summary_count_kind(label) do
    if label |> String.downcase() |> String.starts_with?("error"),
      do: :errors,
      else: :failures
  end

  defp put_summary_count(counts, kind, count) do
    case Integer.parse(count) do
      {count, ""} when count > 0 -> Map.update(counts, kind, count, &max(&1, count))
      _other -> counts
    end
  end

  defp merge_summary_counts(left, right) do
    Map.merge(left, right, fn _kind, left_count, right_count -> max(left_count, right_count) end)
  end

  defp retained_failure_detail_block_count(failure_blocks, selected_indexes) do
    selected_indexes = MapSet.new(selected_indexes)

    Enum.count(failure_blocks, fn {first, last} ->
      Enum.any?(first..last//1, &MapSet.member?(selected_indexes, &1))
    end)
  end

  defp failure_indexes_to_blocks([]), do: []

  defp failure_indexes_to_blocks([first | rest]) do
    rest
    |> Enum.reduce([{first, first}], fn index, [{start, finish} | blocks] ->
      if index - finish <= @failure_block_gap + 1 do
        [{start, index} | blocks]
      else
        [{index, index}, {start, finish} | blocks]
      end
    end)
    |> Enum.reverse()
  end

  defp selected_indexes(lines, important_indexes, failure_analysis, opts) do
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
    |> include_failure_detail_blocks(line_count, failure_analysis, context_lines)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp include_failure_detail_blocks(indexes, line_count, failure_analysis, context_lines) do
    case failure_analysis.summary_count do
      0 ->
        indexes

      _summary_count ->
        failure_indexes =
          failure_analysis.detail_blocks
          |> Enum.flat_map(fn {first, last} -> Enum.to_list(first..last//1) end)

        indexes ++
          failure_analysis.summary_indexes ++
          context_indexes(line_count, failure_indexes, context_lines)
    end
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
