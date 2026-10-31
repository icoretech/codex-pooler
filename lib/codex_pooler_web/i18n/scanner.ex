defmodule CodexPoolerWeb.I18n.Scanner do
  @moduledoc """
  Heuristic inventory of untranslated browser strings. This module uses only
  Elixir's standard library, so it can inspect a source snapshot without compiling
  or starting the application. A report never writes or refreshes its baseline.

  Allowlist rows are `REGEX<TAB># reason`. Patterns match either the candidate
  text or `relative/file.ex:text`, allowing narrow, file-scoped exceptions.
  """

  @heex_sigil ~r/~H(?<delimiter>"""|'''|"|')(?<body>.*?)(?<!\\)\k<delimiter>/s
  @heex_comments ~r/<!--.*?-->|<%!--.*?--%>/s
  @non_ui_markup ~r/<(?:script|style)\b[^>]*>.*?<\/(?:script|style)\s*>/is
  @eex ~r/<%.*?%>/s
  @tags ~r/<[^>]*>/s
  @human_attributes ~r/(?<![\w:-])(?:label|title|hint|placeholder|prompt|description|aria-label|alt|phx-disable-with|summary|data-[\w-]*label)\s*=\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|\{\s*"((?:\\.|[^"\\])*)"\s*\})/s
  @gettext_calls ~w(gettext dgettext pgettext dpgettext ngettext dngettext pngettext dpngettext gettext_noop dgettext_noop pgettext_noop dpgettext_noop ngettext_noop dngettext_noop pngettext_noop dpngettext_noop gettext_comment gettext_with_backend dgettext_with_backend pgettext_with_backend dpgettext_with_backend ngettext_with_backend dngettext_with_backend pngettext_with_backend dpngettext_with_backend)a
  @declarations ~w(alias import require use defmodule)a
  @source_globs [
    "lib/codex_pooler_web/live/**/*.{ex,heex}",
    "lib/codex_pooler_web/components/**/*.{ex,heex}",
    "lib/codex_pooler_web/controllers/*_html.ex",
    "lib/codex_pooler_web/controllers/**/*.heex",
    "lib/codex_pooler_web/controllers/user_session_controller.ex",
    "lib/codex_pooler_web/user_auth.ex"
  ]

  @type candidate :: %{
          file: String.t(),
          line: pos_integer(),
          kind: :heex_text | :attribute | :elixir,
          text: String.t()
        }
  @type report :: %{
          counts: %{String.t() => non_neg_integer()},
          total: non_neg_integer(),
          candidates: [candidate()]
        }
  @type scan_option :: {:root, Path.t()} | {:allowlist_path, Path.t()}
  @type source_option :: {:allowlist, [Regex.t()]}
  @type baseline :: %{
          required(String.t()) => pos_integer() | non_neg_integer() | %{String.t() => non_neg_integer()}
        }

  @doc "Scans browser source files below a repository or archived source root."
  @spec scan([scan_option()]) :: {:ok, report()} | {:error, [String.t()]}
  def scan(opts \\ []) do
    root = opts |> Keyword.get(:root, ".") |> Path.expand()
    allowlist_path = Keyword.get(opts, :allowlist_path, Path.join(root, "priv/i18n/scan_allowlist.txt"))

    with {:ok, allowlist} <- load_allowlist(allowlist_path) do
      files = @source_globs |> Enum.flat_map(&Path.wildcard(Path.join(root, &1))) |> Enum.uniq() |> Enum.sort()

      {counts, candidates, errors} = Enum.reduce(files, {%{}, [], []}, &scan_file(&1, root, allowlist, &2))

      if errors == [] do
        found = candidates |> List.flatten() |> Enum.sort_by(&{&1.file, &1.line, &1.kind, &1.text})
        {:ok, %{counts: counts, total: length(found), candidates: found}}
      else
        {:error, errors}
      end
    end
  end

  defp scan_file(file, root, allowlist, {counts, candidates, errors}) do
    relative = Path.relative_to(file, root)

    with {:ok, source} <- File.read(file),
         {:ok, found} <- scan_source(source, relative, allowlist: allowlist) do
      {Map.put(counts, relative, length(found)), [found | candidates], errors}
    else
      {:error, reasons} when is_list(reasons) -> {counts, candidates, errors ++ reasons}
      {:error, reason} -> {counts, candidates, errors ++ ["#{relative}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "Inspects one source string without filesystem access."
  @spec scan_source(String.t(), String.t(), [source_option()]) :: {:ok, [candidate()]} | {:error, [String.t()]}
  def scan_source(source, file, opts \\ []) do
    allowlist = Keyword.get(opts, :allowlist, [])

    result =
      if String.ends_with?(file, ".heex") do
        {:ok, heex_candidates(source, file, 1)}
      else
        scan_elixir(source, file)
      end

    with {:ok, candidates} <- result do
      {:ok,
       candidates
       |> Enum.filter(&human_candidate?/1)
       |> Enum.reject(&allowlisted?(&1, allowlist))
       |> Enum.uniq_by(&{&1.line, &1.kind, &1.text})
       |> Enum.sort_by(&{&1.line, &1.kind, &1.text})}
    end
  end

  @doc "Reads reason-commented regular expressions, rejecting malformed exceptions."
  @spec load_allowlist(Path.t()) :: {:ok, [Regex.t()]} | {:error, [String.t()]}
  def load_allowlist(path) do
    case File.read(path) do
      {:ok, source} -> parse_allowlist(source, path)
      {:error, reason} -> {:error, ["#{path}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "Parses allowlist content; every pattern needs its own inline reason."
  @spec parse_allowlist(String.t(), String.t()) :: {:ok, [Regex.t()]} | {:error, [String.t()]}
  def parse_allowlist(source, file \\ "allowlist") do
    {patterns, errors} =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, &parse_allowlist_row(&1, file, &2))

    if errors == [], do: {:ok, Enum.reverse(patterns)}, else: {:error, errors}
  end

  defp parse_allowlist_row({row, line}, file, result) do
    trimmed = String.trim(row)
    if trimmed == "" or String.starts_with?(trimmed, "#"), do: result, else: parse_allowlist_pattern(row, file, line, result)
  end

  defp parse_allowlist_pattern(row, file, line, {patterns, errors}) do
    case String.split(row, "\t#", parts: 2) do
      [pattern, reason] when pattern != "" ->
        compile_allowlist(String.trim(pattern), String.trim(reason), file, line, patterns, errors)

      _ ->
        {patterns, errors ++ ["#{file}:#{line}: allowlist pattern needs a tab followed by # reason"]}
    end
  end

  @doc "Returns the versioned, JSON-ready per-file snapshot, without writing it."
  @spec baseline(report()) :: baseline()
  def baseline(report), do: %{"version" => 1, "files" => report.counts, "total" => report.total}

  @doc "Rejects per-file increases, including new files, without changing either input."
  @spec check_baseline(report(), term()) :: :ok | {:error, [String.t()]}
  def check_baseline(report, %{"version" => 1, "files" => files, "total" => total}) when is_map(files) and is_integer(total) and total >= 0 do
    if Enum.all?(files, fn {file, count} -> is_binary(file) and is_integer(count) and count >= 0 end) and Enum.sum(Map.values(files)) == total do
      errors =
        report.counts
        |> Enum.sort()
        |> Enum.flat_map(&baseline_regressions(&1, files))

      if errors == [], do: :ok, else: {:error, errors}
    else
      {:error, ["invalid scanner baseline: files must contain nonnegative counts summing to total"]}
    end
  end

  def check_baseline(_report, _baseline), do: {:error, ["invalid scanner baseline: expected version 1, files and total"]}

  defp baseline_regressions({file, count}, files) do
    previous = Map.get(files, file, 0)
    if count > previous, do: ["#{file}: #{count} hardcoded candidates exceeds baseline #{previous}"], else: []
  end

  defp scan_elixir(source, file) do
    embedded =
      Regex.scan(@heex_sigil, source, return: :index)
      |> Enum.flat_map(fn [_full, _delimiter, {offset, length}] ->
        heex_candidates(binary_part(source, offset, length), file, line_at(source, offset))
      end)

    elixir_source = Regex.replace(@heex_sigil, source, fn whole, _delimiter, _body -> mask_elixir(whole) end)

    encoder = &encode_literal/2

    case Code.string_to_quoted(elixir_source, columns: true, literal_encoder: encoder) do
      {:ok, ast} -> {:ok, embedded ++ elixir_candidates(ast, file, 1)}
      {:error, {location, error, token}} -> {:error, ["#{file}:#{location_line(location)}: #{IO.iodata_to_binary(error)}#{token}"]}
    end
  end

  defp elixir_candidates({name, _meta, _args}, _file, _line) when name in @gettext_calls, do: []

  defp elixir_candidates({{:., _, [_module, name]}, _meta, _args}, _file, _line) when name in @gettext_calls, do: []

  defp elixir_candidates({name, _meta, _args}, _file, _line) when name in @declarations and name != :defmodule, do: []

  defp elixir_candidates({:defmodule, _meta, [_name, body]}, file, line), do: elixir_candidates(body, file, line)

  defp elixir_candidates({:@, _meta, [{name, _, _args}]}, _file, _line) when name in [:doc, :moduledoc, :typedoc], do: []

  defp elixir_candidates({function, _meta, [_head, body]}, file, line) when function in [:def, :defp, :defmacro, :defmacrop], do: elixir_candidates(body, file, line)
  defp elixir_candidates({:->, _meta, [_patterns, body]}, file, line), do: elixir_candidates(body, file, line)
  defp elixir_candidates({:=, _meta, [_pattern, value]}, file, line), do: elixir_candidates(value, file, line)
  defp elixir_candidates({sigil, _meta, _args}, _file, _line) when sigil in [:sigil_w, :sigil_W, :sigil_r, :sigil_R, :sigil_c, :sigil_C], do: []
  defp elixir_candidates({:attr, _meta, _args}, _file, _line), do: []

  defp elixir_candidates({:__i18n_literal__, meta, [text]}, file, line), do: [candidate(file, Keyword.get(meta, :line, line), :elixir, text)]

  defp elixir_candidates({:<<>>, meta, parts}, file, line) do
    text = Enum.map_join(parts, &interpolation_part/1)
    [candidate(file, Keyword.get(meta, :line, line), :elixir, text)]
  end

  defp elixir_candidates({_name, meta, args}, file, line) when is_list(args), do: elixir_candidates(args, file, Keyword.get(meta, :line, line))
  defp elixir_candidates({left, right}, file, line), do: elixir_candidates(left, file, line) ++ elixir_candidates(right, file, line)
  defp elixir_candidates(items, file, line) when is_list(items), do: Enum.flat_map(items, &elixir_candidates(&1, file, line))
  defp elixir_candidates(_ast, _file, _line), do: []

  defp interpolation_part(text) when is_binary(text), do: text
  defp interpolation_part({:__i18n_literal__, _, [text]}), do: text
  defp interpolation_part(_expression), do: "\#{…}"

  defp heex_candidates(source, file, starting_line) do
    source = source |> then(&Regex.replace(@heex_comments, &1, fn text -> mask(text) end)) |> then(&Regex.replace(@non_ui_markup, &1, fn text -> mask(text) end))

    attributes =
      Regex.scan(@human_attributes, source, return: :index)
      |> Enum.map(fn [{offset, _length} | captures] ->
        {value_offset, value_length} = Enum.find(captures, fn {capture_offset, _} -> capture_offset >= 0 end)
        text = binary_part(source, value_offset, value_length)
        candidate(file, starting_line + line_at(source, offset) - 1, :attribute, text)
      end)

    text_source = source |> then(&Regex.replace(@eex, &1, fn text -> mask(text) end)) |> mask_expressions() |> then(&Regex.replace(@tags, &1, fn text -> mask(text) end))

    text =
      Regex.scan(~r/[^\x00]+/u, text_source, return: :index)
      |> Enum.map(fn [{offset, length}] ->
        candidate(file, starting_line + line_at(source, offset) - 1, :heex_text, binary_part(text_source, offset, length))
      end)

    attributes ++ text ++ heex_elixir_candidates(source, file, starting_line)
  end

  defp heex_elixir_candidates(source, file, starting_line) do
    eex = Regex.scan(~r/<%=?\s*(.*?)%>/s, source, return: :index)

    eex_candidates =
      Enum.flat_map(eex, fn [_whole, {offset, length}] ->
        expression_candidates(binary_part(source, offset, length), file, starting_line + line_at(source, offset) - 1)
      end)

    curly_source = source |> then(&Regex.replace(@eex, &1, fn text -> mask(text) end)) |> then(&Regex.replace(@human_attributes, &1, fn whole, _a, _b, _c -> mask(whole) end))
    expressions = expression_spans(curly_source, 0, 0, nil, false, nil, [])

    eex_candidates ++
      Enum.flat_map(expressions, fn {offset, length} ->
        expression_candidates(binary_part(curly_source, offset + 1, length - 2), file, starting_line + line_at(source, offset) - 1)
      end)
  end

  defp expression_candidates(expression, file, line) do
    case Code.string_to_quoted(expression, line: line, literal_encoder: &encode_literal/2) do
      {:ok, ast} -> elixir_candidates(ast, file, line)
      {:error, _incomplete_eex_block} -> []
    end
  end

  defp encode_literal(literal, metadata) when is_binary(literal), do: {:ok, {:__i18n_literal__, metadata, [literal]}}
  defp encode_literal(literal, _metadata), do: {:ok, literal}

  defp expression_spans(<<>>, _offset, _depth, _quote, _escaped, _start, spans), do: Enum.reverse(spans)

  defp expression_spans(<<char, rest::binary>>, offset, depth, quote, escaped, start, spans) do
    {next_depth, next_quote, next_escaped} = expression_state(char, depth, quote, escaped)
    start = if depth == 0 and next_depth == 1, do: offset, else: start
    spans = if depth == 1 and next_depth == 0, do: [{start, offset - start + 1} | spans], else: spans
    expression_spans(rest, offset + 1, next_depth, next_quote, next_escaped, start, spans)
  end

  defp mask_expressions(source), do: mask_expressions(source, 0, nil, false, [])
  defp mask_expressions(<<>>, _depth, _quote, _escaped, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp mask_expressions(<<char, rest::binary>>, depth, quote, escaped, acc) do
    {next_depth, next_quote, next_escaped} = expression_state(char, depth, quote, escaped)
    masked = if depth > 0 or next_depth > 0, do: mask(<<char>>), else: <<char>>
    mask_expressions(rest, next_depth, next_quote, next_escaped, [masked | acc])
  end

  defp expression_state(?{, 0, nil, _escaped), do: {1, nil, false}
  defp expression_state(_char, 0, nil, _escaped), do: {0, nil, false}
  defp expression_state(_char, depth, quote, true), do: {depth, quote, false}
  defp expression_state(?\\, depth, quote, false) when not is_nil(quote), do: {depth, quote, true}
  defp expression_state(char, depth, char, false), do: {depth, nil, false}
  defp expression_state(char, depth, nil, false) when char in [?", ?'], do: {depth, char, false}
  defp expression_state(?{, depth, nil, false), do: {depth + 1, nil, false}
  defp expression_state(?}, depth, nil, false), do: {depth - 1, nil, false}
  defp expression_state(_char, depth, quote, false), do: {depth, quote, false}

  defp mask_elixir(text) do
    masked = for <<byte <- text>>, into: "", do: if(byte == ?\n, do: <<byte>>, else: " ")
    "\"\"" <> binary_part(masked, 2, byte_size(masked) - 2)
  end

  defp mask(text), do: for(<<byte <- text>>, into: "", do: if(byte == ?\n, do: <<byte>>, else: <<0>>))
  defp line_at(source, offset), do: source |> binary_part(0, offset) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  defp location_line(location), do: Keyword.get(location, :line, 1)

  defp candidate(file, line, kind, text), do: %{file: file, line: line, kind: kind, text: text |> String.replace(~r/\s+/u, " ") |> String.trim()}

  defp human_candidate?(%{kind: kind, text: text}) when kind in [:heex_text, :attribute], do: Regex.match?(~r/[A-Za-z]{2}/u, text)
  defp human_candidate?(%{text: text}), do: human_text?(text)

  defp human_text?(text), do: Regex.match?(~r/[A-Z][a-z]|[A-Za-z]{2,}\s+[A-Za-z]/u, text)

  defp allowlisted?(candidate, patterns), do: Enum.any?(patterns, &(Regex.match?(&1, candidate.text) or Regex.match?(&1, candidate.file <> ":" <> candidate.text)))

  defp compile_allowlist(_pattern, "", file, line, patterns, errors), do: {patterns, errors ++ ["#{file}:#{line}: allowlist reason must not be empty"]}

  defp compile_allowlist(pattern, _reason, file, line, patterns, errors) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> {[regex | patterns], errors}
      {:error, {reason, _offset}} -> {patterns, errors ++ ["#{file}:#{line}: invalid allowlist regex: #{reason}"]}
    end
  end
end
