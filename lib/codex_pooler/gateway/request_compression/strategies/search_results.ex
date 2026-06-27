defmodule CodexPooler.Gateway.RequestCompression.Strategies.SearchResults do
  @moduledoc false

  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :search_results
  @default_min_bytes 512
  @default_min_matches 8
  @default_max_files 20
  @default_max_matches 60
  @default_max_matches_per_file 3
  @default_model "gpt-4o"
  @max_heading_bytes 240

  @match_line_regex ~r/^\s*(?<path>[\w.\/-][\w.\/-]*):(?<line>\d+)(?::(?<column>\d+))?:\s*(?<text>\S.*)$/u
  @context_line_regex ~r/^\s*(?<path>[\w.\/-][\w.\/-]*)-(?<line>\d+)(?:-(?<column>\d+))?-\s*(?<text>\S.*)$/u
  @line_match_regex ~r/^\s*(?<line>\d+)(?::(?<column>\d+))?:\s*(?<text>\S.*)$/u
  @line_context_regex ~r/^\s*(?<line>\d+)(?:-(?<column>\d+))?-\s*(?<text>\S.*)$/u
  @heading_path_regex ~r/^[\w.\/-]+$/u
  @heading_extension_regex ~r/(?:^|\/)[\w.-]+\.[A-Za-z0-9][A-Za-z0-9_-]*$/u
  @heading_sentence_punctuation_regex ~r/[!?;]|\.\s*$/
  @separator_regex ~r/^\s*--\s*$/
  @binary_match_regex ~r/^\s*(?:Binary file .+ matches|.+?:\s*(?:WARNING:\s*)?(?:stopped searching )?binary file (?:matches|after match)\b.*)$/i
  @engine_command_regex ~r/^\s*(?:[$>]|\++)?\s*(?:\S+=\S+\s+)*(?:(?:rg|ripgrep|grep|ag|ack|ugrep)|git\s+grep|(?:(?:\/|\.\.?\/)[\w.\/-]*)(?:rg|ripgrep|grep|ag|ack|ugrep))(?:\s|$)/i
  @engine_stderr_regex ~r/^\s*(?:(?:(?:(?:\/|\.\.?\/)[\w.\/-]*)?(?:rg|ripgrep|grep|ag|ack|ugrep)|git grep):|stderr\b|standard error\b)/i
  @exit_code_regex ~r/^\s*(?:exit\s+(?:code|status)|status|returned)\s*[:=]?\s*[1-9]\d*\b/i

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    min_bytes = Strategies.integer_option(opts, :min_bytes, @default_min_bytes, 0)
    min_matches = Strategies.integer_option(opts, :min_matches, @default_min_matches, 1)

    with true <- byte_size(content) >= min_bytes,
         {:ok, lines} <- Strategies.lines(content),
         false <- unsafe_search_output?(lines),
         entries <- parse_entries(lines),
         true <- count_matches(entries) >= min_matches,
         groups when groups != [] <- group_entries(entries) do
      selected_groups = select_groups(groups, opts)
      compressed_match_count = selected_match_count(selected_groups)
      original_match_count = count_matches(entries)

      if compressed_match_count > 0 do
        compressed_lines = render_groups(groups, selected_groups, compressed_match_count)
        compressed = Strategies.join_lines(compressed_lines)

        finalize(
          @strategy,
          content,
          compressed,
          %{
            original_line_count: length(lines),
            compressed_line_count: length(compressed_lines),
            original_file_count: length(groups),
            compressed_file_count: length(selected_groups),
            omitted_file_count: length(groups) - length(selected_groups),
            original_match_count: original_match_count,
            compressed_match_count: compressed_match_count,
            omitted_match_count: original_match_count - compressed_match_count,
            max_matches_per_file_count:
              Strategies.integer_option(
                opts,
                :max_matches_per_file,
                @default_max_matches_per_file,
                1
              ),
            max_total_match_count:
              Strategies.integer_option(opts, :max_matches, @default_max_matches, 1)
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

  defp unsafe_search_output?(lines) do
    Enum.any?(lines, &unsafe_passthrough_line?/1) or ungrouped_line_match_output?(lines)
  end

  defp unsafe_passthrough_line?(line) do
    Regex.match?(@binary_match_regex, line) or Regex.match?(@engine_command_regex, line) or
      Regex.match?(@engine_stderr_regex, line) or Regex.match?(@exit_code_regex, line)
  end

  defp ungrouped_line_match_output?(lines) do
    grouped_indexes =
      lines
      |> parse_grouped_entries()
      |> Enum.map(& &1.index)
      |> MapSet.new()

    lines
    |> Enum.with_index()
    |> Enum.any?(fn {line, index} ->
      (Regex.match?(@line_match_regex, line) or Regex.match?(@line_context_regex, line)) and
        not MapSet.member?(grouped_indexes, index)
    end)
  end

  defp parse_entries(lines) do
    direct_entries =
      lines
      |> Enum.with_index()
      |> parse_direct_entries()

    grouped_entries = parse_grouped_entries(lines)

    (direct_entries ++ grouped_entries)
    |> Enum.sort_by(& &1.index)
  end

  defp parse_direct_entries(indexed_lines) do
    {entries, _last_path} =
      Enum.reduce(indexed_lines, {[], nil}, fn {line, index}, {entries, last_path} ->
        case parse_entry(line, index, last_path) do
          {:ok, entry} -> {[entry | entries], entry.path}
          {:separator, entry} -> {[entry | entries], last_path}
          :skip -> {entries, last_path}
        end
      end)

    Enum.reverse(entries)
  end

  defp parse_entry(line, index, last_path) do
    if String.contains?(line, <<0>>) do
      parse_nul_match(line, index)
    else
      parse_text_entry(line, index, last_path)
    end
  end

  defp parse_text_entry(line, index, last_path) do
    if Regex.match?(@separator_regex, line) and is_binary(last_path) do
      {:separator, %{kind: :separator, path: last_path, index: index}}
    else
      case parse_classic_match(line, index) do
        {:ok, entry} -> {:ok, entry}
        :skip -> parse_classic_context(line, index)
      end
    end
  end

  defp parse_nul_match(line, index) do
    case String.split(line, <<0>>) do
      [path, fragment] ->
        parse_line_fragment(path, fragment, index)

      _malformed ->
        :skip
    end
  end

  defp parse_classic_match(line, index) do
    case Regex.named_captures(@match_line_regex, line) do
      %{"path" => path, "line" => line_number, "column" => column, "text" => text} ->
        build_match(:match, path, line_number, column, text, index)

      _no_match ->
        :skip
    end
  end

  defp parse_classic_context(line, index) do
    case Regex.named_captures(@context_line_regex, line) do
      %{"path" => path, "line" => line_number, "column" => column, "text" => text} ->
        build_match(:context, path, line_number, column, text, index)

      _no_match ->
        :skip
    end
  end

  defp parse_grouped_entries(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      path = String.trim(line)

      if path_like_heading?(path) do
        grouped_entries_after(lines, path, index)
      else
        []
      end
    end)
  end

  defp grouped_entries_after(lines, path, heading_index) do
    entries =
      lines
      |> Enum.drop(heading_index + 1)
      |> Enum.with_index(heading_index + 1)
      |> Enum.reduce_while([], fn {line, index}, entries ->
        case parse_grouped_fragment(path, line, index) do
          {:ok, entry} -> {:cont, [entry | entries]}
          :skip -> {:halt, entries}
        end
      end)
      |> Enum.reverse()

    if count_matches(entries) >= 2, do: entries, else: []
  end

  defp parse_grouped_fragment(path, line, index) do
    if Regex.match?(@separator_regex, line) do
      {:ok, %{kind: :separator, path: path, index: index}}
    else
      case parse_line_fragment(:match, path, line, index) do
        {:ok, entry} -> {:ok, entry}
        :skip -> parse_line_fragment(:context, path, line, index)
      end
    end
  end

  defp parse_line_fragment(path, fragment, index) do
    parse_line_fragment(:match, path, fragment, index)
  end

  defp parse_line_fragment(kind, path, fragment, index) do
    regex = if kind == :match, do: @line_match_regex, else: @line_context_regex

    case Regex.named_captures(regex, fragment) do
      %{"line" => line_number, "column" => column, "text" => text} ->
        build_match(kind, path, line_number, column, text, index)

      _no_match ->
        :skip
    end
  end

  defp build_match(kind, path, line_number, column, text, index) do
    path = String.trim(path)
    text = String.trim(text)

    if path == "" or text == "" or String.contains?(path, <<0>>) do
      :skip
    else
      {:ok,
       %{
         kind: kind,
         path: path,
         line: line_number,
         column: column,
         text: text,
         index: index
       }}
    end
  end

  defp path_like_heading?(path) do
    byte_size(path) in 1..@max_heading_bytes and
      Regex.match?(@heading_path_regex, path) and
      (String.contains?(path, "/") or Regex.match?(@heading_extension_regex, path)) and
      not Regex.match?(@heading_sentence_punctuation_regex, path)
  end

  defp group_entries(entries) do
    {paths, groups} =
      Enum.reduce(entries, {[], %{}}, fn entry, {paths, groups} ->
        if Map.has_key?(groups, entry.path) do
          {paths, Map.update!(groups, entry.path, &[entry | &1])}
        else
          {[entry.path | paths], Map.put(groups, entry.path, [entry])}
        end
      end)

    paths
    |> Enum.reverse()
    |> Enum.map(fn path ->
      entries = groups |> Map.fetch!(path) |> Enum.reverse()
      %{path: path, entries: entries, matches: Enum.filter(entries, &match?/1)}
    end)
    |> Enum.reject(&(&1.matches == []))
  end

  defp select_groups(groups, opts) do
    max_files = Strategies.integer_option(opts, :max_files, @default_max_files, 1)
    max_matches = Strategies.integer_option(opts, :max_matches, @default_max_matches, 1)

    max_matches_per_file =
      Strategies.integer_option(opts, :max_matches_per_file, @default_max_matches_per_file, 1)

    {selected_groups, _kept_matches} =
      Enum.reduce_while(groups, {[], 0}, fn group, {selected_groups, kept_matches} ->
        cond do
          length(selected_groups) >= max_files ->
            {:halt, {selected_groups, kept_matches}}

          kept_matches >= max_matches ->
            {:halt, {selected_groups, kept_matches}}

          true ->
            remaining_matches = max_matches - kept_matches
            keep_count = min(max_matches_per_file, remaining_matches)
            selected_matches = Enum.take(group.matches, keep_count)

            selected_group = %{
              path: group.path,
              matches: selected_matches,
              entries: selected_entries(group.entries, selected_matches),
              omitted_match_count: length(group.matches) - length(selected_matches)
            }

            {:cont, {[selected_group | selected_groups], kept_matches + length(selected_matches)}}
        end
      end)

    Enum.reverse(selected_groups)
  end

  defp render_groups(groups, selected_groups, compressed_match_count) do
    original_match_count =
      groups
      |> Enum.map(&length(&1.matches))
      |> Enum.sum()

    original_file_count = length(groups)
    compressed_file_count = length(selected_groups)

    header =
      if context_shape?(selected_groups) do
        []
      else
        [
          "[compressed search results: #{compressed_match_count}/#{original_match_count} matches, #{compressed_file_count}/#{original_file_count} files]"
        ]
      end

    body =
      Enum.flat_map(selected_groups, fn group ->
        group_lines =
          [group.path] ++ Enum.map(group.entries, &format_entry/1)

        if group.omitted_match_count > 0 and not context_shape?([group]) do
          group_lines ++ ["  [omitted #{group.omitted_match_count} matches in file]"]
        else
          group_lines
        end
      end)

    omitted_file_count = original_file_count - compressed_file_count

    footer =
      if omitted_file_count > 0 do
        ["[compressed search results: omitted #{omitted_file_count} files]"]
      else
        []
      end

    header ++ body ++ footer
  end

  defp selected_entries(_entries, []), do: []

  defp selected_entries(entries, selected_matches) do
    selected_indexes = MapSet.new(Enum.map(selected_matches, & &1.index))
    first_index = Enum.min(selected_indexes)
    last_index = Enum.max(selected_indexes)

    entries
    |> Enum.with_index()
    |> Enum.filter(fn {entry, position} ->
      selected_entry?(entry, position, entries, selected_indexes, first_index, last_index)
    end)
    |> Enum.map(fn {entry, _position} -> entry end)
  end

  defp context_shape?(selected_groups) do
    Enum.any?(selected_groups, fn group ->
      Enum.any?(group.entries, &(&1.kind in [:context, :separator]))
    end)
  end

  defp selected_entry?(
         %{kind: :match, index: index},
         _position,
         _entries,
         selected_indexes,
         _first,
         _last
       ) do
    MapSet.member?(selected_indexes, index)
  end

  defp selected_entry?(
         %{kind: :separator, index: index},
         _position,
         _entries,
         _selected,
         first,
         last
       ) do
    index > first and index < last
  end

  defp selected_entry?(
         %{kind: :context, index: index},
         position,
         entries,
         selected_indexes,
         first,
         last
       ) do
    (index > first and index < last) or
      adjacent_to_selected_match?(entries, position, selected_indexes)
  end

  defp adjacent_to_selected_match?(entries, position, selected_indexes) do
    Enum.any?([position - 1, position + 1], fn adjacent ->
      case Enum.at(entries, adjacent) do
        %{kind: :match, index: index} -> MapSet.member?(selected_indexes, index)
        _other -> false
      end
    end)
  end

  defp format_entry(%{kind: :separator}) do
    "--"
  end

  defp format_entry(%{kind: :context, line: line, column: "", text: text}) do
    "  #{line}- #{text}"
  end

  defp format_entry(%{kind: :context, line: line, column: column, text: text}) do
    "  #{line}-#{column}- #{text}"
  end

  defp format_entry(%{kind: :match, line: line, column: "", text: text}) do
    "  #{line}: #{text}"
  end

  defp format_entry(%{kind: :match, line: line, column: column, text: text}) do
    "  #{line}:#{column}: #{text}"
  end

  defp selected_match_count(selected_groups) do
    selected_groups
    |> Enum.map(&length(&1.matches))
    |> Enum.sum()
  end

  defp count_matches(entries), do: Enum.count(entries, &match?/1)
  defp match?(%{kind: :match}), do: true
  defp match?(_entry), do: false

  defp finalize(strategy, original, compressed, counts, opts) do
    Strategies.finalize(strategy, original, compressed, counts, default_model_opts(opts))
  end

  defp default_model_opts(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :model), do: opts, else: Keyword.put(opts, :model, @default_model)
  end

  defp default_model_opts(opts) when is_map(opts) do
    if Map.has_key?(opts, :model) or Map.has_key?(opts, "model") do
      opts
    else
      Map.put(opts, :model, @default_model)
    end
  end
end
