defmodule CodexPoolerWeb.I18n.ScannerTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.I18n.Scanner

  test "finds HEEx text and human attributes but not machine attributes or translated text" do
    source = ~S'''
    <section id="UserPanel" class="Human Looking Class" phx-click="OpenPanel">
      <h1>Account settings</h1>
      <button title="Open editor" aria-label="Edit account" data-copied-label="Copied!">edit</button>
      <.input label={gettext("Email")} placeholder="name@example.test" />
      <span>{gettext("Already translated")}</span>
      <% gettext_comment("Translator context") %>
      <p>Still hardcoded</p>
    </section>
    '''

    assert {:ok, candidates} = Scanner.scan_source(source, "lib/codex_pooler_web/example.html.heex")
    texts = Enum.map(candidates, & &1.text)
    assert "Account settings" in texts
    assert "Open editor" in texts
    assert "Edit account" in texts
    assert "Copied!" in texts
    assert "edit" in texts
    assert "Still hardcoded" in texts
    refute Enum.any?(texts, &(&1 =~ "Human Looking Class" or &1 =~ "Already translated" or &1 =~ "Translator context" or &1 =~ "UserPanel"))
  end

  test "does not hide unconverted text sharing a line with a gettext call" do
    assert {:ok, candidates} = Scanner.scan_source(~S|<p>{gettext("Done")}</p><p>Still English</p>|, "example.html.heex")
    assert Enum.any?(candidates, &(&1.text == "Still English"))
  end

  test "skips HTML and HEEx comments, inline scripts and styles" do
    source = ~S'''
    <!-- This explanation is not UI -->
    <%!-- This explanation is not UI either --%>
    <script>const example = "JavaScript diagnostic"; // Inline Comment</script>
    <style>.HeadingClass { color: var(--VeryDark); }</style>
    <p>Visible title</p>
    '''

    assert {:ok, [%{text: "Visible title"}]} = Scanner.scan_source(source, "example.html.heex")
  end

  test "finds Elixir UI returns but ignores matching clauses, CSS sigils, docs and gettext bindings" do
    source = ~S'''
    defmodule Example do
      @moduledoc "A Developer Description"
      @labels ["Heading"]
      def label("Machine Input"), do: "Visible output"
      def label(_value), do: gettext("Known label", name: "Machine Binding")
      def state(value) do
        case value do
          "Known Input" -> "Output label"
          _ -> "Unknown state"
        end
      end
      def classes, do: ~w(SomeClass OtherClass)
      def pattern, do: ~r/MachinePattern/
    end
    '''

    assert {:ok, candidates} = Scanner.scan_source(source, "example.ex")
    texts = Enum.map(candidates, & &1.text)
    assert "Heading" in texts
    assert "Visible output" in texts
    assert "Output label" in texts
    assert "Unknown state" in texts
    refute Enum.any?(texts, &(&1 in ["Machine Input", "Known Input", "Machine Binding", "A Developer Description", "SomeClass OtherClass", "MachinePattern"]))
  end

  test "finds interpolated Elixir prose and HEEx literal expressions" do
    source = ~S'''
    defmodule Example do
      def label(name), do: "Hello #{name}"
      def render(assigns) do
        ~H"""
        <h1>Panel heading</h1>
        <span>{"Literal label"}</span>
        <span>{if @enabled, do: "Enabled label", else: "Disabled label"}</span>
        <span><%= "EEx label" %></span>
        <span>{gettext("Already translated")}</span>
        """
      end
    end
    '''

    assert {:ok, candidates} = Scanner.scan_source(source, "example.ex")
    texts = Enum.map(candidates, & &1.text)
    assert Enum.any?(texts, &String.starts_with?(&1, "Hello "))
    assert "Panel heading" in texts
    assert "Literal label" in texts
    assert "Enabled label" in texts
    assert "Disabled label" in texts
    assert "EEx label" in texts
    refute "Already translated" in texts
  end

  test "requires a separate review reason for every allowlist regex" do
    assert {:ok, [pattern]} = Scanner.parse_allowlist("# header\n^Codex Pooler$\t# Brand is never translated\n")
    assert Regex.match?(pattern, "Codex Pooler")
    assert {:error, [_]} = Scanner.parse_allowlist("^Whole page$\n")
    assert {:error, [_]} = Scanner.parse_allowlist("^Whole page$\t# \n")
    assert {:error, [_]} = Scanner.parse_allowlist("[\t# Broken regex\n")
  end

  test "matches exact text or path-scoped allowlist patterns without hiding neighboring prose" do
    assert {:ok, patterns} = Scanner.parse_allowlist("^Codex Pooler$\t# Brand\n^example.html.heex:Machine Label$\t# Technical identifier\n")
    source = "<p>Codex Pooler</p><p>Machine Label</p><p>Human label</p>"
    assert {:ok, [%{text: "Human label"}]} = Scanner.scan_source(source, "example.html.heex", allowlist: patterns)
    assert {:ok, candidates} = Scanner.scan_source(source, "other.html.heex", allowlist: patterns)
    assert Enum.any?(candidates, &(&1.text == "Machine Label"))
  end

  test "rejects source parse errors instead of silently losing candidates" do
    assert {:error, [message]} = Scanner.scan_source("defmodule Broken do", "broken.ex")
    assert message =~ "broken.ex:"
  end

  test "compares per-file counts so a decrease elsewhere cannot mask an increase" do
    report = %{counts: %{"a.ex" => 1, "b.ex" => 4}, total: 5, candidates: []}
    baseline = %{"version" => 1, "files" => %{"a.ex" => 5, "b.ex" => 3}, "total" => 8}
    assert {:error, [message]} = Scanner.check_baseline(report, baseline)
    assert message =~ "b.ex: 4"
    assert baseline["files"]["a.ex"] == 5
  end

  test "new files start at zero and missing old files are legitimate decreases" do
    report = %{counts: %{"new.ex" => 1}, total: 1, candidates: []}
    assert {:error, [_]} = Scanner.check_baseline(report, %{"version" => 1, "files" => %{"removed.ex" => 9}, "total" => 9})
    empty = %{report | counts: %{"new.ex" => 0}, total: 0}
    assert :ok = Scanner.check_baseline(empty, %{"version" => 1, "files" => %{"removed.ex" => 9}, "total" => 9})
  end

  test "snapshot is JSON-ready and malformed baselines fail closed" do
    report = %{counts: %{"a.ex" => 2}, total: 2, candidates: []}
    assert Scanner.baseline(report) == %{"version" => 1, "files" => %{"a.ex" => 2}, "total" => 2}
    assert {:error, [_]} = Scanner.check_baseline(report, %{"version" => 1, "files" => %{"a.ex" => -1}, "total" => 0})
    assert {:error, [_]} = Scanner.check_baseline(report, %{"version" => 1, "files" => %{"a.ex" => 2}, "total" => 3})
    assert {:error, [_]} = Scanner.check_baseline(report, %{})
  end

  @tag :tmp_dir
  test "normal reports and baseline comparisons leave tracked baseline bytes untouched", %{tmp_dir: root} do
    source_dir = Path.join(root, "lib/codex_pooler_web/components")
    File.mkdir_p!(source_dir)
    File.mkdir_p!(Path.join(root, "priv/i18n"))
    File.write!(Path.join(source_dir, "sample.ex"), "defmodule Sample do\n  def label, do: \"Visible label\"\nend\n")
    File.write!(Path.join(root, "priv/i18n/scan_allowlist.txt"), "# No exceptions\n")
    baseline_file = Path.join(root, "priv/i18n/hardcoded_baseline.json")
    File.write!(baseline_file, "reviewed baseline bytes\n")
    assert {:ok, report} = Scanner.scan(root: root)
    assert report.counts == %{"lib/codex_pooler_web/components/sample.ex" => 1}
    assert report.total == 1
    assert :ok = Scanner.check_baseline(report, Scanner.baseline(report))
    assert File.read!(baseline_file) == "reviewed baseline bytes\n"
  end
end
