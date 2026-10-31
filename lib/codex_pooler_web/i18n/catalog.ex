defmodule CodexPoolerWeb.I18n.Catalog do
  @moduledoc """
  Offline PO/POT and source-boundary checks for the shipped Gettext catalogs.

  Existing templates define the required domains. Every template must have a
  complete English and Simplified Chinese catalog; an email template is not
  required before email rendering has been introduced.
  """

  alias CodexPoolerWeb.I18n.Placeholders
  alias Expo.{Message, Messages, PluralForms, PO}
  alias Expo.Message.{Plural, Singular}
  alias Phoenix.LiveView.TagEngine.Parser

  @domains ~w(default errors emails)
  @translations ~w(gettext dgettext pgettext dpgettext ngettext dngettext pngettext dpngettext gettext_noop dgettext_noop pgettext_noop dpgettext_noop ngettext_noop dngettext_noop pngettext_noop dpngettext_noop gettext_with_backend dgettext_with_backend pgettext_with_backend dpgettext_with_backend ngettext_with_backend dngettext_with_backend pngettext_with_backend dpngettext_with_backend)a
  @locale_controls ~w(put_locale get_locale with_locale)a
  @email_files ~w(
    lib/codex_pooler/access/invite_email.ex
    lib/codex_pooler/accounts/operators/operator_email.ex
    lib/codex_pooler/alerts/delivery/email_delivery.ex
    lib/codex_pooler/platform/mailer.ex
  )
  @source_roots ~w(lib/codex_pooler_web lib/codex_pooler dev_support test/support)
  @backend [:CodexPoolerWeb, :Gettext]

  @type issue :: %{file: String.t(), line: non_neg_integer(), code: atom(), message: String.t()}
  @type check_option :: {:root, Path.t()}
  @type validate_option :: {:file, String.t()}

  @doc "Checks catalogs and extraction boundaries without starting the application."
  @spec check([check_option()]) :: :ok | {:error, [issue()]}
  def check(opts \\ []) do
    root = opts |> Keyword.get(:root, ".") |> Path.expand()
    templates = root |> Path.join("priv/gettext/*.pot") |> Path.wildcard() |> Enum.sort()
    missing = if templates == [], do: [issue("priv/gettext", 0, :missing_templates, "no POT templates found")], else: []
    errors = missing ++ Enum.flat_map(templates, &check_domain(&1, root)) ++ check_sources(root)
    if errors == [], do: :ok, else: {:error, Enum.sort_by(errors, &{&1.file, &1.line, &1.code, &1.message})}
  end

  @doc "Validates all non-obsolete source messages; POT headers are optional."
  @spec validate_template(Messages.t()) :: [issue()]
  def validate_template(%Messages{} = template) do
    template.messages |> active_messages() |> Enum.flat_map(&source_issues(&1, template.file || "template"))
  end

  @doc "Validates one parsed PO against its POT, preserving contexts and plural keys."
  @spec validate(Messages.t(), Messages.t(), String.t(), [validate_option()]) :: [issue()]
  def validate(%Messages{} = template, %Messages{} = translation, locale, opts \\ []) do
    file = Keyword.get(opts, :file, translation.file || locale <> ".po")
    {header_errors, plural_count} = header_issues(translation, locale, file)
    entries = translation.messages |> active_messages()
    by_key = Map.new(entries, &{Message.key(&1), &1})

    missing =
      template.messages
      |> active_messages()
      |> Enum.flat_map(fn source ->
        case Map.fetch(by_key, Message.key(source)) do
          :error -> [message_issue(source, file, :missing_message, "missing translation for #{inspect_key(source)}")]
          {:ok, target} -> shape_issues(source, target, file)
        end
      end)

    header_errors ++ missing ++ Enum.flat_map(entries, &translation_issues(&1, locale, plural_count, file))
  end

  @doc "Checks source files in web, domain, development and test-support boundaries."
  @spec check_sources(Path.t()) :: [issue()]
  def check_sources(root) do
    @source_roots
    |> Enum.flat_map(fn directory -> Path.wildcard(Path.join([root, directory, "**/*.{ex,exs,heex}"])) end)
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      relative = Path.relative_to(file, root)

      case File.read(file) do
        {:ok, source} -> check_source(source, relative)
        {:error, reason} -> [issue(relative, 0, :read_error, :file.format_error(reason) |> List.to_string())]
      end
    end)
  end

  @doc "Checks one Elixir source string without compiling or expanding macros."
  @spec check_source(String.t(), String.t()) :: [issue()]
  def check_source(source, file) do
    if String.ends_with?(file, ".heex"), do: check_heex(source, file, 1, %{}), else: check_elixir_source(source, file)
  end

  defp check_elixir_source(source, file) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        aliases = source_aliases(ast)
        {_ast, errors} = Macro.prewalk(ast, [], fn node, errors -> {node, errors ++ source_node_issues(node, file, aliases)} end)
        Enum.uniq(errors)

      {:error, {location, error, token}} ->
        [issue(file, source_line(location), :source_parse_error, IO.iodata_to_binary(error) <> to_string(token))]
    end
  end

  @doc "Formats an issue for a CLI or editor diagnostic."
  @spec format_issue(issue()) :: String.t()
  def format_issue(%{file: file, line: line, message: message}), do: "#{file}:#{line}: #{message}"

  defp check_domain(template_file, root) do
    domain = Path.basename(template_file, ".pot")
    file = Path.relative_to(template_file, root)
    domain_errors = if domain in @domains, do: [], else: [issue(file, 0, :domain, "unsupported Gettext domain #{inspect(domain)}")]

    case PO.parse_file(template_file) do
      {:ok, template} ->
        domain_errors ++
          validate_template(%{template | file: file}) ++
          Enum.flat_map(CodexPooler.SupportedLocales.tags(), &check_locale(template, domain, root, &1))

      {:error, reason} ->
        domain_errors ++ [parse_issue(file, reason)]
    end
  end

  defp check_locale(template, domain, root, tag) do
    locale = CodexPooler.SupportedLocales.gettext_locale(tag)
    relative = "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po"

    case PO.parse_file(Path.join(root, relative)) do
      {:ok, translation} -> validate(template, translation, locale, file: relative)
      {:error, reason} -> [parse_issue(relative, reason)]
    end
  end

  defp header_issues(catalog, locale, file) do
    language = Messages.get_header(catalog, "Language")
    plural = Messages.get_header(catalog, "Plural-Forms")
    errors = if language == [locale], do: [], else: [issue(file, 0, :language_header, "Language header must be exactly #{inspect(locale)}")]

    case {expected_plural(locale), plural} do
      {{:ok, expected}, [header]} ->
        {plural_errors, count} = plural_header_issues(header, expected, locale, file)
        {errors ++ plural_errors, count}

      {{:ok, expected}, _missing_or_duplicate} ->
        {errors ++ [issue(file, 0, :plural_header, "exactly one Plural-Forms header is required")], expected.nplurals}

      {:error, _plural} ->
        {errors ++ [issue(file, 0, :unsupported_locale, "unsupported shipped locale #{inspect(locale)}")], nil}
    end
  end

  defp plural_header_issues(header, expected, locale, file) do
    case PluralForms.parse(header) do
      {:ok, actual} ->
        valid = actual.nplurals == expected.nplurals and normalize_rule(actual.plural) == normalize_rule(expected.plural)
        errors = if valid, do: [], else: [issue(file, 0, :plural_header, "Plural-Forms header does not match #{locale}: #{PluralForms.to_string(expected)}")]
        {errors, expected.nplurals}

      {:error, reason} ->
        {[issue(file, 0, :plural_header, "invalid Plural-Forms header: #{Exception.message(reason)}")], expected.nplurals}
    end
  end

  defp expected_plural("en"), do: PluralForms.parse("nplurals=2; plural=n != 1;")
  defp expected_plural("zh_CN"), do: PluralForms.parse("nplurals=1; plural=0;")
  defp expected_plural(_locale), do: :error

  defp normalize_rule({:paren, expression}), do: normalize_rule(expression)
  defp normalize_rule(expression) when is_tuple(expression), do: expression |> Tuple.to_list() |> Enum.map(&normalize_rule/1) |> List.to_tuple()
  defp normalize_rule(expression), do: expression

  defp source_issues(message, file) do
    source_forms(message)
    |> Enum.flat_map(fn {field, value} ->
      whitespace = if String.trim(value) == value, do: [], else: [message_issue(message, file, :msgid_whitespace, "#{field} has leading or trailing whitespace: #{inspect(value)}")]
      html = if Regex.match?(~r/<\/?[A-Za-z][^>]*>|<!--.*?-->/s, value), do: [message_issue(message, file, :msgid_html, "#{field} contains HTML: #{inspect(value)}")], else: []
      whitespace ++ html
    end)
    |> Kernel.++(plural_source_issues(message, file))
  end

  defp source_forms(%Singular{msgid: msgid}), do: [{:msgid, IO.iodata_to_binary(msgid)}]
  defp source_forms(%Plural{msgid: msgid, msgid_plural: plural}), do: [{:msgid, IO.iodata_to_binary(msgid)}, {:msgid_plural, IO.iodata_to_binary(plural)}]

  @spec plural_source_issues(Message.t(), String.t()) :: [issue()]
  defp plural_source_issues(%Singular{}, _file), do: []

  defp plural_source_issues(%Plural{} = message, file) do
    source = message.msgid |> IO.iodata_to_binary() |> Placeholders.extract() |> MapSet.delete("count")
    plural = message.msgid_plural |> IO.iodata_to_binary() |> Placeholders.extract() |> MapSet.delete("count")
    placeholder_set_issues(message, file, :msgid_plural, source, plural)
  end

  defp translation_issues(message, locale, plural_count, file) do
    fuzzy = if Message.has_flag?(message, "fuzzy"), do: [message_issue(message, file, :fuzzy, "fuzzy shipped translation for #{inspect_key(message)}")], else: []

    source_issues(message, file) ++
      fuzzy ++
      plural_count_issues(message, plural_count, file) ++
      Enum.flat_map(translation_forms(message), fn {field, index, text} ->
        cond do
          String.trim(text) == "" and locale != "en" ->
            [message_issue(message, file, :empty_translation, "empty #{field} for #{inspect_key(message)}")]

          text == "" and locale == "en" ->
            []

          true ->
            translation_placeholder_issues(message, file, locale, field, index, text)
        end
      end)
  end

  defp translation_forms(%Singular{msgstr: msgstr}), do: [{"msgstr", nil, IO.iodata_to_binary(msgstr)}]
  defp translation_forms(%Plural{msgstr: msgstr}), do: msgstr |> Enum.sort() |> Enum.map(fn {index, value} -> {"msgstr[#{index}]", index, IO.iodata_to_binary(value)} end)

  defp plural_count_issues(%Singular{}, _count, _file), do: []
  defp plural_count_issues(_message, nil, _file), do: []

  defp plural_count_issues(%Plural{} = message, count, file) do
    expected = Enum.to_list(0..(count - 1))
    actual = message.msgstr |> Map.keys() |> Enum.sort()
    if actual == expected, do: [], else: [message_issue(message, file, :plural_count, "expected msgstr indexes #{inspect(expected)}, found #{inspect(actual)} for #{inspect_key(message)}")]
  end

  defp shape_issues(%Plural{msgid_plural: source_plural}, %Plural{msgid_plural: target_plural} = target, file) do
    if IO.iodata_to_binary(source_plural) == IO.iodata_to_binary(target_plural), do: [], else: [message_issue(target, file, :plural_source, "msgid_plural differs from the POT for #{inspect_key(target)}")]
  end

  defp shape_issues(%Singular{}, %Singular{}, _file), do: []
  defp shape_issues(_source, target, file), do: [message_issue(target, file, :message_shape, "singular/plural form differs from the POT for #{inspect_key(target)}")]

  @spec translation_placeholder_issues(Singular.t() | Plural.t(), String.t(), String.t(), String.t() | nil, non_neg_integer() | nil, String.t()) :: [issue()]
  defp translation_placeholder_issues(%Singular{} = message, file, _locale, field, _index, text) do
    placeholder_set_issues(message, file, field, Placeholders.extract(IO.iodata_to_binary(message.msgid)), Placeholders.extract(text))
  end

  defp translation_placeholder_issues(%Plural{} = message, file, "en", field, index, text) do
    source = if index == 0, do: message.msgid, else: message.msgid_plural
    placeholder_set_issues(message, file, field, Placeholders.extract(IO.iodata_to_binary(source)), Placeholders.extract(text))
  end

  defp translation_placeholder_issues(%Plural{} = message, file, _locale, field, _index, text) do
    singular = message.msgid |> IO.iodata_to_binary() |> Placeholders.extract()
    plural = message.msgid_plural |> IO.iodata_to_binary() |> Placeholders.extract()
    actual = Placeholders.extract(text)
    required = if MapSet.member?(singular, "count") and MapSet.member?(plural, "count"), do: singular, else: MapSet.delete(singular, "count")
    allowed = MapSet.union(singular, plural)
    missing = required |> MapSet.difference(actual) |> Enum.sort()
    extra = actual |> MapSet.difference(allowed) |> Enum.sort()
    placeholder_mismatch_issues(message, file, field, missing, extra)
  end

  @spec placeholder_set_issues(Message.t(), String.t(), String.t() | atom(), MapSet.t(String.t()), MapSet.t(String.t())) :: [issue()]

  defp placeholder_set_issues(message, file, field, expected, actual) do
    missing = expected |> MapSet.difference(actual) |> Enum.sort()
    extra = actual |> MapSet.difference(expected) |> Enum.sort()
    placeholder_mismatch_issues(message, file, field, missing, extra)
  end

  defp placeholder_mismatch_issues(_message, _file, _field, [], []), do: []
  defp placeholder_mismatch_issues(message, file, field, missing, extra), do: [message_issue(message, file, :placeholders, "#{field} placeholder mismatch for #{inspect_key(message)}: missing #{inspect(missing)}, extra #{inspect(extra)}")]

  defp active_messages(messages), do: Enum.reject(messages, & &1.obsolete)
  defp inspect_key(message), do: inspect(Message.key(message))
  defp message_issue(message, file, code, text), do: issue(file, get_in(message.__meta__, [:source_line, :msgid]) || 0, code, text)
  defp issue(file, line, code, text), do: %{file: file, line: line, code: code, message: text}
  defp parse_issue(file, reason) when is_atom(reason), do: issue(file, 0, :catalog_parse_error, :file.format_error(reason) |> List.to_string())
  defp parse_issue(file, reason), do: issue(file, Map.get(reason, :line) || 0, :catalog_parse_error, Exception.message(reason))

  defp source_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, target}, opts]} = node, aliases when is_list(opts) ->
          name =
            case Keyword.get(opts, :as) do
              {:__aliases__, _, name} -> name
              _other -> [List.last(target)]
            end

          {node, Map.put(aliases, name, target)}

        {:alias, _, [{:__aliases__, _, target}]} = node, aliases ->
          {node, Map.put(aliases, [List.last(target)], target)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp source_node_issues({:sigil_H, meta, [{:<<>>, _, parts}, _modifiers]}, file, aliases) do
    if Enum.all?(parts, &is_binary/1), do: check_heex(IO.iodata_to_binary(parts), file, Keyword.get(meta, :line, 1), aliases), else: []
  end

  defp source_node_issues({:@, meta, [{name, _, args}]}, file, aliases) when is_list(args) and name not in [:doc, :moduledoc, :typedoc] do
    if String.starts_with?(file, "lib/codex_pooler_web/") and translating_tree?(args, aliases) and not validation_noop?(args, file) do
      [issue(file, Keyword.get(meta, :line, 0), :module_attribute, "Gettext cannot run in a module attribute; translate in a render-time function")]
    else
      []
    end
  end

  defp source_node_issues({directive, meta, [module | options]}, file, aliases) when directive in [:use, :import, :require] do
    if gettext_module?(module, aliases) do
      boundary_issues(file, meta, :extraction) ++ backend_directive_issues(directive, module, options, file, meta, aliases)
    else
      []
    end
  end

  defp source_node_issues({{:., _, [module, function]}, meta, args}, file, aliases) when is_list(args) do
    if gettext_module?(module, aliases) or function in @translations do
      kind = if function in @locale_controls, do: :control, else: :extraction
      boundary_issues(file, meta, kind) ++ remote_backend_issues(module, file, meta, aliases) ++ call_domain_issues(function, args, module, file, meta, aliases)
    else
      []
    end
  end

  defp source_node_issues({function, meta, args}, file, aliases) when function in @translations and is_list(args) do
    boundary_issues(file, meta, :extraction) ++ call_domain_issues(function, args, nil, file, meta, aliases)
  end

  defp source_node_issues({function, meta, _args}, file, _aliases) when function == :gettext_comment, do: boundary_issues(file, meta, :extraction)
  defp source_node_issues(_node, _file, _aliases), do: []

  defp check_heex(source, file, starting_line, aliases) do
    tokens = Parser.tokenize(source, file: file, tag_handler: Phoenix.LiveView.HTMLEngine)

    expressions =
      Enum.flat_map(tokens, fn
        {:body_expr, expression, meta} ->
          [{expression, meta.line}]

        {kind, _name, attrs, _meta} when kind in [:tag, :local_component, :remote_component, :slot] ->
          Enum.flat_map(attrs, fn
            {_name, {:expr, expression, meta}, _attr_meta} -> [{expression, meta.line}]
            _attribute -> []
          end)

        _token ->
          []
      end)

    expression_errors =
      Enum.flat_map(expressions, fn {expression, line} ->
        case Code.string_to_quoted(expression, line: line + starting_line - 1) do
          {:ok, ast} -> check_expression_ast(ast, file, aliases)
          {:error, {location, error, token}} -> [issue(file, source_line(location), :source_parse_error, IO.iodata_to_binary(error) <> to_string(token))]
        end
      end)

    eex_ast = EEx.compile_string(source, file: file, line: starting_line)
    Enum.uniq(expression_errors ++ check_expression_ast(eex_ast, file, aliases))
  rescue
    error in [Phoenix.LiveView.TagEngine.Tokenizer.ParseError, EEx.SyntaxError, SyntaxError, TokenMissingError] ->
      [issue(file, starting_line, :source_parse_error, Exception.message(error))]
  end

  defp check_expression_ast(ast, file, aliases) do
    {_ast, errors} = Macro.prewalk(ast, [], fn node, errors -> {node, errors ++ source_node_issues(node, file, aliases)} end)
    errors
  end

  defp remote_backend_issues(module, file, meta, aliases) do
    parts = module_parts(module, aliases)

    if is_list(parts) and List.last(parts) == :Gettext and parts not in [[:Gettext], @backend] do
      [issue(file, Keyword.get(meta, :line, 0), :backend, "translation must use CodexPoolerWeb.Gettext")]
    else
      []
    end
  end

  defp boundary_issues(file, meta, kind) do
    cond do
      String.starts_with?(file, "lib/codex_pooler/") and file not in @email_files ->
        [issue(file, Keyword.get(meta, :line, 0), :domain_boundary, "Gettext is restricted to the web layer and four email renderers")]

      (String.starts_with?(file, "test/support/") or String.starts_with?(file, "dev_support/")) and kind != :control ->
        [issue(file, Keyword.get(meta, :line, 0), :support_boundary, "Gettext extraction is forbidden in development/test support")]

      true ->
        []
    end
  end

  defp backend_issues(:use, options, file, meta, aliases) do
    backend = options |> List.flatten() |> Keyword.get(:backend)

    if module_parts(backend, aliases) == @backend or backend_definition?(file) do
      []
    else
      [issue(file, Keyword.get(meta, :line, 0), :backend, "use the canonical CodexPoolerWeb.Gettext backend")]
    end
  end

  defp backend_directive_issues(:use, module, options, file, meta, aliases) do
    if module_parts(module, aliases) == [:Gettext, :Backend] and not backend_definition?(file) do
      [issue(file, Keyword.get(meta, :line, 0), :backend, "only CodexPoolerWeb.Gettext may define a Gettext backend")]
    else
      backend_issues(:use, options, file, meta, aliases)
    end
  end

  defp backend_directive_issues(_directive, module, _options, file, meta, aliases), do: remote_backend_issues(module, file, meta, aliases)

  defp call_domain_issues(function, args, module, file, meta, aliases) when function in @translations do
    explicit_backend = module_parts(module, aliases) in [[:Gettext], [:Gettext, :Macros]] or String.ends_with?(Atom.to_string(function), "_with_backend")
    {backend_errors, call_args} = if explicit_backend, do: explicit_call_arguments(args, file, meta, aliases), else: {[], args}

    domain = if String.starts_with?(Atom.to_string(function), "d"), do: List.first(call_args), else: "default"
    allowed = if file in @email_files, do: ["emails"], else: @domains
    domain_errors = if domain in allowed, do: [], else: [issue(file, Keyword.get(meta, :line, 0), :domain, "translation domain must be a literal in #{inspect(allowed)}")]
    backend_errors ++ domain_errors
  end

  defp call_domain_issues(_function, _args, _module, _file, _meta, _aliases), do: []

  defp explicit_call_arguments([backend | rest], file, meta, aliases) do
    errors = if module_parts(backend, aliases) == @backend, do: [], else: [issue(file, Keyword.get(meta, :line, 0), :backend, "translation must use CodexPoolerWeb.Gettext")]
    {errors, rest}
  end

  defp explicit_call_arguments([], _file, _meta, _aliases), do: {[], []}

  defp translating_tree?(ast, aliases) do
    {_ast, found} = Macro.prewalk(ast, false, fn node, found -> {node, found or translation_node?(node, aliases)} end)
    found
  end

  defp translation_node?({function, _, args}, _aliases) when function in @translations and is_list(args), do: true
  defp translation_node?({{:., _, [_module, function]}, _, args}, _aliases) when function in @translations and is_list(args), do: true
  defp translation_node?({:sigil_H, _, [{:<<>>, _, parts}, _modifiers]}, _aliases), do: Enum.any?(parts, &(is_binary(&1) and Regex.match?(~r/\b(?:[dpn]*gettext(?:_noop)?|[dpn]*gettext_with_backend)\s*\(/, &1)))
  defp translation_node?(_node, _aliases), do: false

  defp validation_noop?(args, "lib/codex_pooler_web/validation_messages.ex") do
    {_ast, calls} =
      Macro.prewalk(args, [], fn
        {function, _, values} = node, calls when function in @translations and is_list(values) -> {node, [{function, values} | calls]}
        {{:., _, [_module, function]}, _, values} = node, calls when function in @translations and is_list(values) -> {node, [{function, values} | calls]}
        node, calls -> {node, calls}
      end)

    calls != [] and Enum.all?(calls, fn {function, values} -> function == :dgettext_noop and List.first(values) == "errors" end)
  end

  defp validation_noop?(_args, _file), do: false

  defp gettext_module?(module, aliases) do
    case module_parts(module, aliases) do
      [:Gettext | _rest] -> true
      parts when is_list(parts) -> List.last(parts) == :Gettext
      _other -> false
    end
  end

  defp module_parts({:__aliases__, _, parts}, aliases), do: Map.get(aliases, parts, parts)
  defp module_parts(_module, _aliases), do: nil
  defp backend_definition?(file), do: file == "lib/codex_pooler_web/gettext.ex"
  defp source_line(location), do: Keyword.get(location, :line, 0)
end
