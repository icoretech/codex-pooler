defmodule CodexPooler.Gateway.RequestCompression.Strategies.SearchResults do
  @moduledoc false

  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :search_results
  @default_min_bytes 512
  @default_min_matches 8
  @default_max_files 20
  @default_max_matches 60
  @default_max_matches_per_file 3

  @match_line_regex ~r/^\s*(?<path>[\w.\/-][\w.\/-]*):(?<line>\d+)(?::(?<column>\d+))?:\s*(?<text>\S.*)$/u

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    min_bytes = Strategies.integer_option(opts, :min_bytes, @default_min_bytes, 0)
    min_matches = Strategies.integer_option(opts, :min_matches, @default_min_matches, 1)

    with true <- byte_size(content) >= min_bytes,
         {:ok, lines} <- Strategies.lines(content),
         matches when length(matches) >= min_matches <- parse_matches(lines),
         groups when groups != [] <- group_matches(matches) do
      selected_groups = select_groups(groups, opts)
      compressed_match_count = selected_match_count(selected_groups)

      if compressed_match_count > 0 do
        compressed_lines = render_groups(groups, selected_groups, compressed_match_count)
        compressed = Strategies.join_lines(compressed_lines)

        Strategies.finalize(
          @strategy,
          content,
          compressed,
          %{
            original_line_count: length(lines),
            compressed_line_count: length(compressed_lines),
            original_file_count: length(groups),
            compressed_file_count: length(selected_groups),
            omitted_file_count: length(groups) - length(selected_groups),
            original_match_count: length(matches),
            compressed_match_count: compressed_match_count,
            omitted_match_count: length(matches) - compressed_match_count,
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

  defp parse_matches(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce([], fn {line, index}, matches ->
      case parse_match(line, index) do
        {:ok, match} -> [match | matches]
        :skip -> matches
      end
    end)
    |> Enum.reverse()
  end

  defp parse_match(line, index) do
    case Regex.named_captures(@match_line_regex, line) do
      %{"path" => path, "line" => line_number, "column" => column, "text" => text} ->
        path = String.trim(path)
        text = String.trim(text)

        if path == "" or text == "" do
          :skip
        else
          {:ok,
           %{
             path: path,
             line: line_number,
             column: column,
             text: text,
             index: index
           }}
        end

      _no_match ->
        :skip
    end
  end

  defp group_matches(matches) do
    {paths, groups} =
      Enum.reduce(matches, {[], %{}}, fn match, {paths, groups} ->
        if Map.has_key?(groups, match.path) do
          {paths, Map.update!(groups, match.path, &[match | &1])}
        else
          {[match.path | paths], Map.put(groups, match.path, [match])}
        end
      end)

    paths
    |> Enum.reverse()
    |> Enum.map(fn path ->
      %{path: path, matches: groups |> Map.fetch!(path) |> Enum.reverse()}
    end)
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

    header = [
      "[compressed search results: kept #{compressed_match_count} of #{original_match_count} matches across #{compressed_file_count} of #{original_file_count} files]"
    ]

    body =
      Enum.flat_map(selected_groups, fn group ->
        group_lines =
          [group.path] ++ Enum.map(group.matches, &format_match/1)

        if group.omitted_match_count > 0 do
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

  defp format_match(%{line: line, column: "", text: text}) do
    "  #{line}: #{text}"
  end

  defp format_match(%{line: line, column: column, text: text}) do
    "  #{line}:#{column}: #{text}"
  end

  defp selected_match_count(selected_groups) do
    selected_groups
    |> Enum.map(&length(&1.matches))
    |> Enum.sum()
  end
end
