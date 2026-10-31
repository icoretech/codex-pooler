defmodule CodexPoolerWeb.I18n.CatalogTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.I18n.Catalog
  alias Expo.Message.{Plural, Singular}
  alias Expo.PO

  @fixtures Path.expand("../../fixtures/i18n", __DIR__)

  test "validates real PO contexts, comments, CJK, escaped strings and one-form Chinese plurals" do
    template = fixture("messages.pot")
    assert Catalog.validate_template(template) == []
    assert Catalog.validate(template, fixture("zh_CN.po"), "zh_CN") == []
    assert Catalog.validate(template, fixture("en.po"), "en") == []
    assert hd(template.messages).extracted_comments == [" A short action label, distinct from a state."]
  end

  test "requires each context and does not count obsolete entries as translations" do
    template = fixture("messages.pot")
    chinese = fixture("zh_CN.po")
    [first | rest] = chinese.messages
    errors = Catalog.validate(template, %{chinese | messages: [%{first | obsolete: true} | rest]}, "zh_CN")
    assert Enum.count(errors, &(&1.code == :missing_message)) == 1
    assert Enum.any?(errors, &(&1.message =~ ~s({"button", "Open"})))
  end

  test "rejects fuzzy English translations even when empty fallback is permitted" do
    english = fixture("en.po")
    [first | rest] = english.messages
    errors = Catalog.validate(fixture("messages.pot"), %{english | messages: [%{first | flags: [["fuzzy", "elixir-format"]]} | rest]}, "en")
    assert Enum.any?(errors, &(&1.code == :fuzzy))
    refute Enum.any?(errors, &(&1.code == :empty_translation))
  end

  test "rejects empty and whitespace-only Chinese translations" do
    chinese = fixture("zh_CN.po")
    [first | rest] = chinese.messages
    errors = Catalog.validate(fixture("messages.pot"), %{chinese | messages: [%{first | msgstr: [" \t"]} | rest]}, "zh_CN")
    assert Enum.any?(errors, &(&1.code == :empty_translation))
  end

  test "requires exact locale headers and a locale-matching plural rule" do
    chinese = fixture("zh_CN.po")
    invalid = %{chinese | headers: ["Language: zh-CN\n", "Plural-Forms: nplurals=1; plural=n != 1;\n"]}
    codes = Catalog.validate(fixture("messages.pot"), invalid, "zh_CN") |> Enum.map(& &1.code)
    assert :language_header in codes
    assert :plural_header in codes

    missing = %{chinese | headers: []}
    assert Enum.count(Catalog.validate(fixture("messages.pot"), missing, "zh_CN"), &(&1.code in [:language_header, :plural_header])) == 2
  end

  test "rejects duplicate headers and malformed plural syntax without evaluation" do
    chinese = fixture("zh_CN.po")
    duplicate = %{chinese | headers: chinese.headers ++ ["Language: zh_CN\n"]}
    assert Enum.any?(Catalog.validate(fixture("messages.pot"), duplicate, "zh_CN"), &(&1.code == :language_header))

    invalid = %{chinese | headers: ["Language: zh_CN\nPlural-Forms: arbitrary code;\n"]}
    assert Enum.any?(Catalog.validate(fixture("messages.pot"), invalid, "zh_CN"), &(&1.code == :plural_header))
  end

  test "requires exact plural indexes, not merely a matching map size" do
    source = %Plural{msgid: ["%{count} job"], msgid_plural: ["%{count} jobs"]}
    target = %{source | msgstr: %{1 => ["%{count} 个任务"]}}
    template = %Expo.Messages{messages: [source]}
    chinese = %{fixture("zh_CN.po") | messages: [target]}
    assert Enum.any?(Catalog.validate(template, chinese, "zh_CN"), &(&1.code == :plural_count))
  end

  test "rejects missing and introduced names in every plural translation" do
    source = %Plural{msgid: ["%{count} job for %{name}"], msgid_plural: ["%{count} jobs for %{name}"]}
    target = %{source | msgstr: %{0 => ["%{name} 的 %{count} 个任务"], 1 => ["%{user} 的 %{count} 个任务"]}}
    errors = Catalog.validate(%Expo.Messages{messages: [source]}, %{fixture("en.po") | messages: [target]}, "en")
    assert Enum.any?(errors, &(&1.code == :placeholders and &1.message =~ "msgstr[1]" and &1.message =~ "user"))
  end

  test "permits only reserved count to differ between singular and plural source forms" do
    source = %Plural{msgid: ["One job for %{name}"], msgid_plural: ["%{count} jobs for %{name}"]}
    chinese = %{fixture("zh_CN.po") | messages: [%{source | msgstr: %{0 => ["%{name} 的 %{count} 个任务"]}}]}
    assert Catalog.validate(%Expo.Messages{messages: [source]}, chinese, "zh_CN") == []

    bad_source = %{source | msgid_plural: ["%{count} jobs for %{user}"]}
    assert Enum.any?(Catalog.validate_template(%Expo.Messages{messages: [bad_source]}), &(&1.code == :placeholders))
  end

  test "retains exact singular English bindings and does not allow arbitrary Chinese additions" do
    source = %Plural{msgid: ["One job"], msgid_plural: ["%{count} jobs"]}
    english = %{fixture("en.po") | messages: [%{source | msgstr: %{0 => ["%{count} job"], 1 => ["%{count} jobs"]}}]}
    assert Enum.any?(Catalog.validate(%Expo.Messages{messages: [source]}, english, "en"), &(&1.code == :placeholders))

    chinese = %{fixture("zh_CN.po") | messages: [%{source | msgstr: %{0 => ["%{count} 个 %{arbitrary}"]}}]}
    assert Enum.any?(Catalog.validate(%Expo.Messages{messages: [source]}, chinese, "zh_CN"), &(&1.code == :placeholders and &1.message =~ "arbitrary"))
  end

  test "does not make count optional when both source forms require it" do
    source = %Plural{msgid: ["%{count} job"], msgid_plural: ["%{count} jobs"]}
    chinese = %{fixture("zh_CN.po") | messages: [%{source | msgstr: %{0 => ["任务"]}}]}
    assert Enum.any?(Catalog.validate(%Expo.Messages{messages: [source]}, chinese, "zh_CN"), &(&1.code == :placeholders and &1.message =~ "count"))
  end

  test "rejects whitespace and HTML in either source form, but not comparisons" do
    source = %Plural{msgid: [" Leading "], msgid_plural: ["<strong>Jobs</strong>"]}
    codes = Catalog.validate_template(%Expo.Messages{messages: [source]}) |> Enum.map(& &1.code)
    assert :msgid_whitespace in codes
    assert :msgid_html in codes
    assert Catalog.validate_template(%Expo.Messages{messages: [%Singular{msgid: ["Age < 1 minute"]}]}) == []
  end

  test "checks plural source changes and singular/plural shape against the template" do
    template = %Expo.Messages{messages: [%Plural{msgid: ["Job"], msgid_plural: ["Jobs"]}]}
    chinese = %{fixture("zh_CN.po") | messages: [%Singular{msgid: ["Job"], msgstr: ["任务"]}]}
    assert Enum.any?(Catalog.validate(template, chinese, "zh_CN"), &(&1.code == :message_shape))
  end

  test "detects multiline module-attribute calls including nested captures and aliases" do
    source = ~S'''
    defmodule Example do
      alias CodexPoolerWeb.Gettext, as: Translations
      @items [
        %{label: Translations.gettext("Open")}
      ]
      def label, do: gettext("Open")
    end
    '''

    errors = Catalog.check_source(source, "lib/codex_pooler_web/components/example.ex")
    assert Enum.count(errors, &(&1.code == :module_attribute)) == 1
    refute Enum.any?(errors, &(&1.code == :backend))
  end

  test "allows only extraction-only errors entries in the validation registry" do
    source = ~S|@messages [dgettext_noop("errors", "is invalid")]|
    assert Catalog.check_source(source, "lib/codex_pooler_web/validation_messages.ex") == []
    assert Enum.any?(Catalog.check_source(source, "lib/codex_pooler_web/other.ex"), &(&1.code == :module_attribute))
  end

  test "keeps runtime domain and development/test extraction out of catalogs" do
    source = ~S|Gettext.dgettext(CodexPoolerWeb.Gettext, "default", "Open")|
    assert Enum.any?(Catalog.check_source(source, "lib/codex_pooler/pools.ex"), &(&1.code == :domain_boundary))
    assert Enum.any?(Catalog.check_source(source, "test/support/example.ex"), &(&1.code == :support_boundary))
    assert Enum.any?(Catalog.check_source(source, "dev_support/example.ex"), &(&1.code == :support_boundary))
    assert Catalog.check_source(~S|Gettext.put_locale("en")|, "test/support/conn_case.ex") == []
    assert Enum.any?(Catalog.check_source(~S|Gettext.put_locale("en")|, "lib/codex_pooler/pools.ex"), &(&1.code == :domain_boundary))
  end

  test "allowlists only exact mail renderers using the emails domain" do
    source = ~S|dgettext("emails", "Hello")|
    assert Catalog.check_source(source, "lib/codex_pooler/access/invite_email.ex") == []
    assert Enum.any?(Catalog.check_source(source, "lib/codex_pooler/access/other_email.ex"), &(&1.code == :domain_boundary))
    assert Enum.any?(Catalog.check_source(~S|gettext("Hello")|, "lib/codex_pooler/access/invite_email.ex"), &(&1.code == :domain))
  end

  test "rejects alternate backends, unknown domains and dynamic domains" do
    assert Enum.any?(Catalog.check_source(~S|use Gettext, backend: Other.Gettext|, "lib/codex_pooler_web/example.ex"), &(&1.code == :backend))
    assert Enum.any?(Catalog.check_source(~S|Gettext.dgettext(Other.Gettext, "default", "Hello")|, "lib/codex_pooler_web/example.ex"), &(&1.code == :backend))
    assert Enum.any?(Catalog.check_source(~S|dgettext("other", "Hello")|, "lib/codex_pooler_web/example.ex"), &(&1.code == :domain))
    assert Enum.any?(Catalog.check_source(~S|dgettext(domain, "Hello")|, "lib/codex_pooler_web/example.ex"), &(&1.code == :domain))
  end

  test "checks HEEx expression and embedded EEx domain boundaries" do
    assert Enum.any?(Catalog.check_source(~S|<p>{dgettext("other", "Hello")}</p>|, "lib/codex_pooler_web/example.html.heex"), &(&1.code == :domain))

    source = ~S'''
    def render(assigns) do
      ~H"""
      <p><%= dgettext("other", "Hello") %></p>
      """
    end
    '''

    assert Enum.any?(Catalog.check_source(source, "lib/codex_pooler_web/example.ex"), &(&1.code == :domain))
  end

  @tag :tmp_dir
  test "checks every shipped locale for existing domains without requiring absent email skeletons", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "priv/gettext/en/LC_MESSAGES"))
    File.mkdir_p!(Path.join(root, "priv/gettext/zh_CN/LC_MESSAGES"))
    File.cp!(Path.join(@fixtures, "messages.pot"), Path.join(root, "priv/gettext/default.pot"))
    File.cp!(Path.join(@fixtures, "en.po"), Path.join(root, "priv/gettext/en/LC_MESSAGES/default.po"))
    File.cp!(Path.join(@fixtures, "zh_CN.po"), Path.join(root, "priv/gettext/zh_CN/LC_MESSAGES/default.po"))
    assert :ok = Catalog.check(root: root)

    File.rm!(Path.join(root, "priv/gettext/zh_CN/LC_MESSAGES/default.po"))
    assert {:error, errors} = Catalog.check(root: root)
    assert Enum.any?(errors, &(&1.file == "priv/gettext/zh_CN/LC_MESSAGES/default.po" and &1.code == :catalog_parse_error))
  end

  @tag :tmp_dir
  test "reports duplicate PO entries and missing templates as structured failures", %{tmp_dir: root} do
    assert {:error, [%{code: :missing_templates}]} = Catalog.check(root: root)
    File.mkdir_p!(Path.join(root, "priv/gettext"))
    File.write!(Path.join(root, "priv/gettext/default.pot"), "msgid \"Duplicate\"\nmsgstr \"\"\n\nmsgid \"Duplicate\"\nmsgstr \"\"\n")
    assert {:error, errors} = Catalog.check(root: root)
    assert Enum.any?(errors, &(&1.code == :catalog_parse_error and &1.file == "priv/gettext/default.pot"))
  end

  defp fixture(name), do: PO.parse_file!(Path.join(@fixtures, name))
end
