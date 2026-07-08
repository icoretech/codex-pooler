defmodule CodexPooler.Gateway.RequestCompression.ContentDetector do
  @moduledoc false

  @type kind ::
          :json_array | :json_document | :diff | :html | :search | :build | :source_code | :text
  @type strategy ::
          :json_array_lossless | :json_document_lossless | :diff | :search_results | :log_output
  @type decision :: %{
          required(:kind) => kind(),
          required(:confidence) => float(),
          required(:compressible) => boolean(),
          required(:strategy) => strategy() | nil
        }

  @strategies %{
    json_array: :json_array_lossless,
    json_document: :json_document_lossless,
    diff: :diff,
    search: :search_results,
    build: :log_output
  }

  @diff_git_regex ~r/^diff --git\s+\S+\s+\S+/m
  @diff_index_regex ~r/^index\s+[0-9a-f]+\.\.[0-9a-f]+/im
  @diff_file_header_regex ~r/^---\s+\S+.*\n\+\+\+\s+\S+/m
  @diff_hunk_regex ~r/^@@{1,2}\s+-\d+(?:,\d+)?(?:\s+-\d+(?:,\d+)?)*\s+\+\d+(?:,\d+)?\s+@@{1,2}/m
  @diff_addition_regex ~r/^(?!\+\+\+)[ +-]{0,2}\+.+/m
  @diff_deletion_regex ~r/^(?!---)[ +-]{0,2}-.+/m
  @combined_diff_hunk_regex ~r/^@@@\s+-\d+(?:,\d+)?\s+-\d+(?:,\d+)?\s+\+\d+(?:,\d+)?\s+@@@/m

  @html_root_regex ~r/<!doctype\s+html|<html(?:\s|>|$)/i
  @html_open_tag_regex ~r/<[a-z][\w:-]*(?:\s[^<>]*)?>/i
  @html_close_tag_regex ~r/<\/[a-z][\w:-]*>/i
  @html_attribute_regex ~r/<[a-z][^<>]*\s[\w:-]+=(?:"[^"]*"|'[^']*'|[^\s>]+)/i

  @search_heading_regex ~r/\b(?:search results|results for|matches for|found\s+\d+\s+(?:results|matches))\b/i
  @numbered_result_regex ~r/^\s*(?:\d+[\).]\s+|[-*]\s+).+\s-\s.+$/m
  @path_match_regex ~r/^\s*[\w.\/-]+:\d+(?::\d+)?:\s*\S/m
  @path_context_regex ~r/^\s*[\w.\/-]+-\d+(?:-\d+)?-\s*\S/m
  @nul_path_match_regex ~r/^[^\x00\r\n]+\x00\d+(?::\d+)?:\s*\S/m
  @grouped_line_match_regex ~r/^\s*\d+(?::\d+)?:\s*\S/
  @grouped_line_context_regex ~r/^\s*\d+(?:-\d+)?-\s*\S/
  @grouped_heading_path_regex ~r/^[\w.\/-]+$/u
  @grouped_heading_extension_regex ~r/(?:^|\/)[\w.-]+\.[A-Za-z0-9][A-Za-z0-9_-]*$/u
  @grouped_heading_sentence_punctuation_regex ~r/[!?;]|\.\s*$/
  @grouped_separator_regex ~r/^\s*--\s*$/
  @max_grouped_heading_bytes 240
  @url_regex ~r/https?:\/\/\S+/i
  @snippet_separator_regex ~r/\s-\s/

  @severity_regex ~r/^\s*(?:error|warning|warn|failed|failure|panic|exception|traceback)\b[:\s]/im
  @build_term_regex ~r/\b(?:build|building|compile|compiling|compiled|test|tests|failed|failure|running|finished|warning|error|npm|yarn|pnpm|mix|make|cargo|gradle|maven|pytest|rspec|exunit)\b/i
  @build_prefix_regex ~r/^\s*(?:\$ |==>|-->|Compiling|Running|Finished|warning:|error:|\[\w+\])/mi
  @stack_line_regex ~r/(?:^\s+at\s+\S+|^\s*File\s+"[^"]+",\s+line\s+\d+|^\s*\S+:\d+:\d+:)/m
  @diagnostic_path_regex ~r/^\s*\S+\.(?:c|cc|cpp|cs|css|ex|exs|go|h|hpp|html|java|js|jsx|json|kt|m|md|mjs|mm|php|py|rb|rs|scss|svelte|swift|toml|ts|tsx|vue|xml|ya?ml)(?:\(\d+,\d+\)|:\d+(?::\d+)?)[:\s].+/im
  @diagnostic_summary_regex ~r/^\s*(?:Build\s+(?:FAILED|succeeded)|BUILD\s+(?:FAILED|SUCCESSFUL)|\*\*\s+BUILD\s+(?:FAILED|SUCCEEDED)\s+\*\*|Failed!\s+-\s+Failed:|Passed!\s+-\s+Failed:|Test summary:|Found\s+\d+\s+(?:errors?|warnings?)|Executed\s+\d+\s+tests?,\s+with\s+\d+|\d+\s+(?:Warning|Error)\(s\)|\d+\s+(?:tests?|examples?)\s+(?:completed|run|passed|failed)|\d+\s+actionable tasks?:)/im
  @lint_rule_regex ~r/\b(?:lint|style|correctness|suspicious|complexity|nursery|performance|security)\/[a-z0-9_\/-]+\b/i

  @source_keyword_regex ~r/^\s*(?:defmodule|defp?\s+\w+|class\s+\w+|function\s+\w+|import\s+|export\s+|const\s+\w+|let\s+\w+|var\s+\w+|pub\s+fn\s+\w+|fn\s+\w+|impl\s+\w+|module\s+\w+|alias\s+)/m
  @source_punctuation_regex ~r/[{}();]/
  @source_operator_regex ~r/(?:=>|->|::|\|>|<-|==|=)/
  @source_indentation_regex ~r/^\s{2,}\S/m
  @source_comment_regex ~r/^\s*(?:#|\/\/|\/\*|\*)/m
  @source_closing_regex ~r/^\s*(?:end|})\s*$/m

  @spec detect(term()) :: decision()
  def detect(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        decision(:text, 100)

      json_array?(trimmed) ->
        decision(:json_array, 100)

      concatenated_json_objects?(trimmed) ->
        decision(:json_array, 100)

      json_document?(trimmed) ->
        decision(:json_document, 100)

      true ->
        scored_decision(content)
    end
  end

  def detect(_content), do: decision(:text, 100)

  @spec scored_decision(String.t()) :: decision()
  defp scored_decision(content) do
    cond do
      (points = diff_points(content)) >= 70 ->
        decision(:diff, points)

      (points = html_points(content)) >= 70 ->
        decision(:html, points)

      (points = search_points(content)) >= 60 ->
        decision(:search, points)

      (points = build_points(content)) >= 50 ->
        decision(:build, points)

      (points = source_points(content)) >= 50 ->
        decision(:source_code, points)

      true ->
        decision(:text, 100)
    end
  end

  defp decision(kind, points) do
    strategy = Map.get(@strategies, kind)

    %{
      kind: kind,
      confidence: confidence(points),
      compressible: not is_nil(strategy),
      strategy: strategy
    }
  end

  defp confidence(points), do: min(points, 100) / 100

  @spec normalize_concatenated_json_objects(term()) :: {:ok, String.t(), pos_integer()} | :error
  def normalize_concatenated_json_objects(content) when is_binary(content) do
    with {:ok, rows} <- decode_concatenated_json_objects(content),
         row_count when row_count >= 2 <- length(rows),
         {:ok, normalized} <- Jason.encode(rows) do
      {:ok, normalized, row_count}
    else
      _not_concatenated -> :error
    end
  end

  def normalize_concatenated_json_objects(_content), do: :error

  defp concatenated_json_objects?(content) do
    case decode_concatenated_json_objects(content) do
      {:ok, [_first, _second | _rest]} -> true
      _other -> false
    end
  end

  defp decode_concatenated_json_objects(content) do
    content
    |> String.trim()
    |> decode_object_stream([])
  end

  defp decode_object_stream("", _rows), do: :error

  defp decode_object_stream(content, rows) do
    case decode_leading_json_object(content) do
      {:ok, row, rest} ->
        rest
        |> trim_leading_json_whitespace()
        |> continue_object_stream([row | rows])

      :error ->
        :error
    end
  end

  defp continue_object_stream({"", _separator_bytes}, [_last, _previous | _rest] = rows) do
    {:ok, Enum.reverse(rows)}
  end

  defp continue_object_stream({"", _separator_bytes}, _rows), do: :error

  defp continue_object_stream({next, separator_bytes}, rows) when separator_bytes > 0 do
    decode_object_stream(next, rows)
  end

  defp continue_object_stream({_next, _separator_bytes}, _rows), do: :error

  defp decode_leading_json_object(<<?{, _rest::binary>> = content) do
    with {:ok, byte_end} <- json_object_byte_end(content),
         object_json = binary_part(content, 0, byte_end),
         {:ok, %Jason.OrderedObject{} = row} <-
           Jason.decode(object_json, objects: :ordered_objects) do
      rest = binary_part(content, byte_end, byte_size(content) - byte_end)
      {:ok, row, rest}
    else
      _invalid -> :error
    end
  end

  defp decode_leading_json_object(_content), do: :error

  defp json_object_byte_end(<<?{, rest::binary>>), do: scan_json_object(rest, 1, 1)

  defp scan_json_object(<<>>, _offset, _depth), do: :error

  defp scan_json_object(<<34, rest::binary>>, offset, depth),
    do: scan_json_string(rest, offset + 1, depth)

  defp scan_json_object(<<?{, rest::binary>>, offset, depth),
    do: scan_json_object(rest, offset + 1, depth + 1)

  defp scan_json_object(<<?}, _rest::binary>>, offset, 1), do: {:ok, offset + 1}

  defp scan_json_object(<<?}, rest::binary>>, offset, depth),
    do: scan_json_object(rest, offset + 1, depth - 1)

  defp scan_json_object(<<_byte, rest::binary>>, offset, depth),
    do: scan_json_object(rest, offset + 1, depth)

  defp scan_json_string(<<>>, _offset, _depth), do: :error

  defp scan_json_string(<<92, _escaped, rest::binary>>, offset, depth),
    do: scan_json_string(rest, offset + 2, depth)

  defp scan_json_string(<<34, rest::binary>>, offset, depth),
    do: scan_json_object(rest, offset + 1, depth)

  defp scan_json_string(<<_byte, rest::binary>>, offset, depth),
    do: scan_json_string(rest, offset + 1, depth)

  defp trim_leading_json_whitespace(content), do: trim_leading_json_whitespace(content, 0)

  defp trim_leading_json_whitespace(<<byte, rest::binary>>, count)
       when byte in [?\s, ?\n, ?\r, ?\t],
       do: trim_leading_json_whitespace(rest, count + 1)

  defp trim_leading_json_whitespace(content, count), do: {content, count}

  defp json_array?(content) do
    case Jason.decode(content) do
      {:ok, value} when is_list(value) -> true
      _other -> false
    end
  end

  defp json_document?(content) do
    case Jason.decode(content) do
      {:ok, value} when is_map(value) -> true
      _other -> false
    end
  end

  defp diff_points(content) do
    hunks = scan_count(@diff_hunk_regex, content)
    additions = scan_count(@diff_addition_regex, content)
    deletions = scan_count(@diff_deletion_regex, content)
    changes = additions + deletions

    if hunks == 0 or changes == 0 do
      0
    else
      diff_points(content, hunks, additions, deletions, changes)
    end
  end

  defp diff_points(content, hunks, additions, deletions, changes) do
    combined_hunks = scan_count(@combined_diff_hunk_regex, content)

    [
      cond_score(hunks, [{2, 50}, {1, 45}]),
      cond_score(changes, [{2, 30}, {1, 25}]),
      score(additions > 0 and deletions > 0, 10),
      score(regex_match?(@diff_file_header_regex, content), 15),
      score(regex_match?(@diff_git_regex, content), 10),
      score(regex_match?(@diff_index_regex, content), 5),
      score(combined_hunks > 0, 10)
    ]
    |> Enum.sum()
    |> min(100)
  end

  defp html_points(content) do
    open_tags = scan_count(@html_open_tag_regex, content)
    close_tags = scan_count(@html_close_tag_regex, content)

    [
      score(regex_match?(@html_root_regex, content), 35),
      score(open_tags >= 3, 20),
      score(close_tags >= 2, 15),
      score(regex_match?(@html_attribute_regex, content), 10),
      score(open_tags + close_tags >= 4, 10)
    ]
    |> Enum.sum()
  end

  defp search_points(content) do
    numbered_results = scan_count(@numbered_result_regex, content)
    path_matches = scan_count(@path_match_regex, content)
    path_context_lines = scan_count(@path_context_regex, content)
    nul_matches = scan_count(@nul_path_match_regex, content)
    grouped_matches = grouped_search_match_count(content)
    structural_matches = path_matches + nul_matches + grouped_matches
    urls = scan_count(@url_regex, content)
    separators = scan_count(@snippet_separator_regex, content)

    [
      score(regex_match?(@search_heading_regex, content), 30),
      cond_score(numbered_results, [{2, 30}, {1, 15}]),
      cond_score(structural_matches, [{3, 45}, {2, 35}, {1, 15}]),
      score(structural_matches >= 2, 15),
      score(nul_matches >= 2 or grouped_matches >= 2 or path_context_lines >= 2, 10),
      cond_score(urls, [{2, 20}, {1, 10}]),
      score(separators >= 2, 10)
    ]
    |> Enum.sum()
    |> min(100)
  end

  defp build_points(content) do
    lines = lines(content)
    severities = scan_count(@severity_regex, content)
    diagnostic_paths = scan_count(@diagnostic_path_regex, content)
    diagnostic_summaries = scan_count(@diagnostic_summary_regex, content)

    [
      cond_score(severities, [{2, 30}, {1, 20}]),
      cond_score(diagnostic_paths, [{2, 35}, {1, 25}]),
      cond_score(diagnostic_summaries, [{2, 25}, {1, 15}]),
      score(regex_match?(@lint_rule_regex, content), 15),
      score(regex_match?(@build_term_regex, content), 20),
      score(regex_match?(@build_prefix_regex, content), 20),
      score(regex_match?(@stack_line_regex, content), 25),
      score(length(lines) >= 4, 10),
      score(repeated_line?(lines), 15)
    ]
    |> Enum.sum()
    |> min(100)
  end

  defp source_points(content) do
    lines = lines(content)
    keywords = scan_count(@source_keyword_regex, content)
    punctuation = scan_count(@source_punctuation_regex, content)
    operators = scan_count(@source_operator_regex, content)
    indented_lines = scan_count(@source_indentation_regex, content)

    [
      cond_score(keywords, [{2, 30}, {1, 20}]),
      score(punctuation >= 3, 15),
      score(operators >= 2, 15),
      score(indented_lines >= 2, 10),
      score(regex_match?(@source_comment_regex, content), 10),
      score(regex_match?(@source_closing_regex, content), 10),
      score(length(lines) >= 3, 10)
    ]
    |> Enum.sum()
    |> min(100)
  end

  defp grouped_search_match_count(content) do
    content
    |> lines()
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      path = String.trim(line)

      if grouped_heading?(path) do
        count_grouped_lines_after(content, index)
      else
        0
      end
    end)
    |> Enum.sum()
  end

  defp count_grouped_lines_after(content, heading_index) do
    {matches, _context_lines} =
      content
      |> lines()
      |> Enum.drop(heading_index + 1)
      |> Enum.reduce_while({0, 0}, fn line, {matches, context_lines} ->
        cond do
          Regex.match?(@grouped_line_match_regex, line) ->
            {:cont, {matches + 1, context_lines}}

          Regex.match?(@grouped_line_context_regex, line) or
              Regex.match?(@grouped_separator_regex, line) ->
            {:cont, {matches, context_lines + 1}}

          true ->
            {:halt, {matches, context_lines}}
        end
      end)

    if matches >= 2, do: matches, else: 0
  end

  defp grouped_heading?(path) do
    byte_size(path) in 1..@max_grouped_heading_bytes and
      Regex.match?(@grouped_heading_path_regex, path) and
      (String.contains?(path, "/") or Regex.match?(@grouped_heading_extension_regex, path)) and
      not Regex.match?(@grouped_heading_sentence_punctuation_regex, path)
  end

  defp repeated_line?(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.any?(fn {line, count} -> count >= 2 and byte_size(line) >= 8 end)
  end

  defp cond_score(count, thresholds) do
    case Enum.find(thresholds, fn {minimum, _points} -> count >= minimum end) do
      {_minimum, points} -> points
      nil -> 0
    end
  end

  defp score(true, points), do: points
  defp score(false, _points), do: 0

  defp regex_match?(regex, content), do: Regex.match?(regex, content)
  defp scan_count(regex, content), do: regex |> Regex.scan(content) |> length()

  defp lines(content) do
    String.split(content, ["\r\n", "\n", "\r"], trim: true)
  end
end
