defmodule CodexPooler.Gateway.RequestCompression.ContentDetector do
  @moduledoc false

  @type kind :: :json_array | :diff | :html | :search | :build | :source_code | :text
  @type strategy :: :json_array_lossless | :diff | :search_results | :log_output
  @type decision :: %{
          required(:kind) => kind(),
          required(:confidence) => float(),
          required(:compressible) => boolean(),
          required(:strategy) => strategy() | nil
        }

  @strategies %{
    json_array: :json_array_lossless,
    diff: :diff,
    search: :search_results,
    build: :log_output
  }

  @diff_git_regex ~r/^diff --git\s+\S+\s+\S+/m
  @diff_index_regex ~r/^index\s+[0-9a-f]+\.\.[0-9a-f]+/im
  @diff_file_header_regex ~r/^---\s+\S+.*\n\+\+\+\s+\S+/m
  @diff_hunk_regex ~r/^@@\s+-\d+(?:,\d+)?\s+\+\d+(?:,\d+)?\s+@@/m
  @diff_addition_regex ~r/^\+(?!\+\+).+/m
  @diff_deletion_regex ~r/^-(?!--).+/m

  @html_root_regex ~r/<!doctype\s+html|<html(?:\s|>|$)/i
  @html_open_tag_regex ~r/<[a-z][\w:-]*(?:\s[^<>]*)?>/i
  @html_close_tag_regex ~r/<\/[a-z][\w:-]*>/i
  @html_attribute_regex ~r/<[a-z][^<>]*\s[\w:-]+=(?:"[^"]*"|'[^']*'|[^\s>]+)/i

  @search_heading_regex ~r/\b(?:search results|results for|matches for|found\s+\d+\s+(?:results|matches))\b/i
  @numbered_result_regex ~r/^\s*(?:\d+[\).]\s+|[-*]\s+).+\s-\s.+$/m
  @path_match_regex ~r/^\s*[\w.\/-]+:\d+(?::\d+)?:\s*\S/m
  @url_regex ~r/https?:\/\/\S+/i
  @snippet_separator_regex ~r/\s-\s/

  @severity_regex ~r/^\s*(?:error|warning|warn|failed|failure|panic|exception|traceback)\b[:\s]/im
  @build_term_regex ~r/\b(?:build|building|compile|compiling|compiled|test|tests|failed|failure|running|finished|warning|error|npm|yarn|pnpm|mix|make|cargo|gradle|maven|pytest|rspec|exunit)\b/i
  @build_prefix_regex ~r/^\s*(?:\$ |==>|-->|Compiling|Running|Finished|warning:|error:|\[\w+\])/mi
  @stack_line_regex ~r/(?:^\s+at\s+\S+|^\s*File\s+"[^"]+",\s+line\s+\d+|^\s*\S+:\d+:\d+:)/m

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

  def detect(_content), do: decision(:text, 100)

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

  defp json_array?(content) do
    case Jason.decode(content) do
      {:ok, value} when is_list(value) -> true
      _other -> false
    end
  end

  defp diff_points(content) do
    [
      score(regex_match?(@diff_git_regex, content), 25),
      score(regex_match?(@diff_index_regex, content), 10),
      score(regex_match?(@diff_file_header_regex, content), 25),
      score(regex_match?(@diff_hunk_regex, content), 25),
      score(
        regex_match?(@diff_addition_regex, content) and
          regex_match?(@diff_deletion_regex, content),
        20
      )
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
    urls = scan_count(@url_regex, content)
    separators = scan_count(@snippet_separator_regex, content)

    [
      score(regex_match?(@search_heading_regex, content), 30),
      cond_score(numbered_results, [{2, 30}, {1, 15}]),
      cond_score(path_matches, [{3, 45}, {2, 35}, {1, 15}]),
      score(path_matches >= 2, 15),
      cond_score(urls, [{2, 20}, {1, 10}]),
      score(separators >= 2, 10)
    ]
    |> Enum.sum()
    |> min(100)
  end

  defp build_points(content) do
    lines = lines(content)
    severities = scan_count(@severity_regex, content)

    [
      cond_score(severities, [{2, 30}, {1, 20}]),
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
