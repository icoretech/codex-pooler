defmodule CodexPooler.Gateway.RequestCompression.Strategies.Diff do
  @moduledoc false

  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :diff
  @default_min_bytes 512
  @default_min_hunks 1
  @default_max_files 16
  @default_max_hunks 32
  @default_max_hunks_per_file 8
  @default_context_lines 2

  @file_start_regex ~r/^diff --git\s+\S+\s+\S+/
  @hunk_header_regex ~r/^@@\s+-\d+(?:,\d+)?\s+\+\d+(?:,\d+)?\s+@@/

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    min_bytes = Strategies.integer_option(opts, :min_bytes, @default_min_bytes, 0)
    min_hunks = Strategies.integer_option(opts, :min_hunks, @default_min_hunks, 1)

    with true <- byte_size(content) >= min_bytes,
         {:ok, lines} <- Strategies.lines(content),
         files when files != [] <- parse_files(lines),
         files <- Enum.filter(files, &(hunk_count(&1) > 0)),
         original_hunk_count when original_hunk_count >= min_hunks <- total_hunk_count(files),
         true <- total_change_count(files) > 0 do
      selected_files = select_files(files, opts)
      compressed_hunk_count = total_hunk_count(selected_files)

      if compressed_hunk_count > 0 do
        {compressed_lines, kept_context_line_count, omitted_context_line_count} =
          render_files(files, selected_files, opts)

        compressed = Strategies.join_lines(compressed_lines)

        Strategies.finalize(
          @strategy,
          content,
          compressed,
          %{
            original_line_count: length(lines),
            compressed_line_count: length(compressed_lines),
            original_file_count: length(files),
            compressed_file_count: length(selected_files),
            omitted_file_count: length(files) - length(selected_files),
            original_hunk_count: original_hunk_count,
            compressed_hunk_count: compressed_hunk_count,
            omitted_hunk_count: original_hunk_count - compressed_hunk_count,
            addition_line_count: addition_line_count(files),
            deletion_line_count: deletion_line_count(files),
            context_line_count: context_line_count(files),
            kept_context_line_count: kept_context_line_count,
            omitted_context_line_count: omitted_context_line_count
          },
          opts
        )
      else
        :skip
      end
    else
      _not_compressible -> :skip
    end
  end

  def compress(_content, _opts), do: :skip

  defp parse_files(lines) do
    file_start_indexes =
      lines
      |> Enum.with_index()
      |> Enum.reduce([], fn {line, index}, indexes ->
        if Regex.match?(@file_start_regex, line), do: [index | indexes], else: indexes
      end)
      |> Enum.reverse()

    if file_start_indexes == [] do
      [parse_file(lines)]
    else
      file_start_indexes
      |> Enum.with_index()
      |> Enum.map(fn {start_index, position} ->
        end_index = Enum.at(file_start_indexes, position + 1, length(lines))

        lines
        |> Enum.slice(start_index, end_index - start_index)
        |> parse_file()
      end)
    end
  end

  defp parse_file(lines) do
    {header, hunks, current_hunk} =
      Enum.reduce(lines, {[], [], nil}, fn line, {header, hunks, current_hunk} ->
        if Regex.match?(@hunk_header_regex, line) do
          hunks = append_hunk(hunks, current_hunk)
          {header, hunks, %{header: line, body: []}}
        else
          append_line(line, header, hunks, current_hunk)
        end
      end)

    hunks =
      hunks
      |> append_hunk(current_hunk)
      |> Enum.filter(&(change_count(&1) > 0))

    %{header: header, hunks: hunks}
  end

  defp append_line(line, header, hunks, nil), do: {header ++ [line], hunks, nil}

  defp append_line(line, header, hunks, current_hunk) do
    {header, hunks, %{current_hunk | body: current_hunk.body ++ [line]}}
  end

  defp append_hunk(hunks, nil), do: hunks
  defp append_hunk(hunks, hunk), do: hunks ++ [hunk]

  defp select_files(files, opts) do
    max_files = Strategies.integer_option(opts, :max_files, @default_max_files, 1)
    max_hunks = Strategies.integer_option(opts, :max_hunks, @default_max_hunks, 1)

    max_hunks_per_file =
      Strategies.integer_option(opts, :max_hunks_per_file, @default_max_hunks_per_file, 1)

    {selected_files, _kept_hunks} =
      Enum.reduce_while(files, {[], 0}, fn file, {selected_files, kept_hunks} ->
        cond do
          length(selected_files) >= max_files ->
            {:halt, {selected_files, kept_hunks}}

          kept_hunks >= max_hunks ->
            {:halt, {selected_files, kept_hunks}}

          true ->
            remaining_hunks = max_hunks - kept_hunks
            keep_count = min(max_hunks_per_file, remaining_hunks)
            selected_hunks = Enum.take(file.hunks, keep_count)

            selected_file = %{
              header: file.header,
              hunks: selected_hunks,
              omitted_hunk_count: length(file.hunks) - length(selected_hunks)
            }

            {:cont, {[selected_file | selected_files], kept_hunks + length(selected_hunks)}}
        end
      end)

    Enum.reverse(selected_files)
  end

  defp render_files(files, selected_files, opts) do
    context_lines = Strategies.integer_option(opts, :context_lines, @default_context_lines, 0)

    {file_lines, kept_context_line_count, omitted_context_line_count} =
      Enum.reduce(selected_files, {[], 0, 0}, fn file, {lines, kept_context, omitted_context} ->
        {hunk_lines, file_kept_context, file_omitted_context} =
          render_hunks(file.hunks, context_lines)

        file_lines = file.header ++ hunk_lines ++ omitted_hunk_marker(file.omitted_hunk_count)

        {lines ++ file_lines, kept_context + file_kept_context,
         omitted_context + file_omitted_context}
      end)

    omitted_file_count = length(files) - length(selected_files)
    file_lines = file_lines ++ omitted_file_marker(omitted_file_count)

    {file_lines, kept_context_line_count, omitted_context_line_count}
  end

  defp render_hunks(hunks, context_lines) do
    Enum.reduce(hunks, {[], 0, 0}, fn hunk, {lines, kept_context, omitted_context} ->
      {hunk_lines, hunk_kept_context, hunk_omitted_context} =
        render_hunk(hunk, context_lines)

      {lines ++ hunk_lines, kept_context + hunk_kept_context,
       omitted_context + hunk_omitted_context}
    end)
  end

  defp render_hunk(hunk, context_lines) do
    selected_indexes = selected_hunk_indexes(hunk.body, context_lines)

    {body_lines, omitted_context_line_count} =
      Strategies.collapse_lines(hunk.body, selected_indexes, fn count ->
        " [compressed diff output: omitted #{count} context lines]"
      end)

    kept_context_line_count =
      hunk.body
      |> Enum.with_index()
      |> Enum.count(fn {line, index} ->
        not changed_line?(line) and index in selected_indexes
      end)

    {[hunk.header | body_lines], kept_context_line_count, omitted_context_line_count}
  end

  defp selected_hunk_indexes(lines, context_lines) do
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} -> changed_line?(line) end)
    |> Enum.flat_map(fn {_line, index} ->
      max(index - context_lines, 0)..min(index + context_lines, last_index)//1
      |> Enum.to_list()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp omitted_hunk_marker(0), do: []

  defp omitted_hunk_marker(count) do
    ["[compressed diff output: omitted #{count} hunks]"]
  end

  defp omitted_file_marker(0), do: []

  defp omitted_file_marker(count) do
    ["[compressed diff output: omitted #{count} files]"]
  end

  defp total_hunk_count(files) do
    files
    |> Enum.map(&hunk_count/1)
    |> Enum.sum()
  end

  defp hunk_count(file), do: length(file.hunks)

  defp total_change_count(files) do
    files
    |> Enum.flat_map(& &1.hunks)
    |> Enum.map(&change_count/1)
    |> Enum.sum()
  end

  defp change_count(hunk), do: addition_count(hunk) + deletion_count(hunk)

  defp addition_line_count(files) do
    files
    |> Enum.flat_map(& &1.hunks)
    |> Enum.map(&addition_count/1)
    |> Enum.sum()
  end

  defp addition_count(hunk) do
    Enum.count(hunk.body, fn line ->
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++")
    end)
  end

  defp deletion_line_count(files) do
    files
    |> Enum.flat_map(& &1.hunks)
    |> Enum.map(&deletion_count/1)
    |> Enum.sum()
  end

  defp deletion_count(hunk) do
    Enum.count(hunk.body, fn line ->
      String.starts_with?(line, "-") and not String.starts_with?(line, "---")
    end)
  end

  defp context_line_count(files) do
    files
    |> Enum.flat_map(& &1.hunks)
    |> Enum.map(fn hunk -> Enum.count(hunk.body, &(not changed_line?(&1))) end)
    |> Enum.sum()
  end

  defp changed_line?(line) do
    (String.starts_with?(line, "+") and not String.starts_with?(line, "+++")) or
      (String.starts_with?(line, "-") and not String.starts_with?(line, "---"))
  end
end
