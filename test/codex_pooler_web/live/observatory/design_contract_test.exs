defmodule CodexPoolerWeb.Observatory.DesignContractTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.Telemetry

  @css_path "assets/css/app.css"
  @layouts_path "lib/codex_pooler_web/components/layouts.ex"
  @observatory_live_path "lib/codex_pooler_web/live/observatory_live.ex"
  @observatory_activity_path "lib/codex_pooler_web/live/observatory/components/activity.ex"
  @observatory_states_path "lib/codex_pooler_web/live/observatory/components/states.ex"
  @observatory_telemetry_path "lib/codex_pooler_web/live/observatory/components/telemetry.ex"
  @observatory_toolbar_path "lib/codex_pooler_web/live/observatory/components/toolbar.ex"
  @observatory_markup_paths [
    @observatory_live_path,
    @observatory_activity_path,
    @observatory_states_path,
    @observatory_telemetry_path,
    @observatory_toolbar_path
  ]

  @showcase_render_paths [
    "dev_support/codex_pooler_web/dev/component_showcase.ex",
    "dev_support/codex_pooler_web/dev/component_showcase_admin.ex",
    "dev_support/codex_pooler_web/dev/component_showcase_admin_forms.ex",
    "dev_support/codex_pooler_web/dev/component_showcase_admin_specialized.ex",
    "dev_support/codex_pooler_web/dev/component_showcase_live.ex",
    "dev_support/codex_pooler_web/dev/component_showcase_observatory.ex",
    "dev_support/codex_pooler_web/dev/component_showcase_stats.ex"
  ]

  @approved_arbitrary_utility "observatory-split:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]"

  @breakpoint_variants [
    {"observatory-split", "width >= 1100px"},
    {"observatory-toolbar-stacked", "width <= 45rem"},
    {"observatory-freshness-compact", "width <= 26.25rem"},
    {"observatory-wordmark-compact", "width <= 23.4375rem"}
  ]

  test "Observatory styling uses declared tokens, preserved widths, and named responsive variants" do
    css = File.read!(@css_path)
    layout_markup = @layouts_path |> File.read!() |> observatory_layout_markup()
    activity = File.read!(@observatory_activity_path)
    rules = observatory_rules(css)

    token_declarations =
      Regex.scan(~r/(--observatory-[a-z0-9-]+)\s*:\s*([^;]+);/, css, capture: :all_but_first)

    declared_tokens =
      Map.new(token_declarations, fn [name, value] -> {name, String.trim(value)} end)

    assert token_declarations != []
    assert map_size(declared_tokens) == length(token_declarations)
    assert declared_tokens["--observatory-shell-max-width"] == "87.5rem"

    used_tokens =
      ~r/var\((--observatory-[a-z0-9-]+)\)/
      |> Regex.scan(rules, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert used_tokens == declared_tokens |> Map.keys() |> Enum.sort()

    unit_literals =
      ~r/-?(?:\d*\.)?\d+(?:rem|px|em|ms|s)\b/
      |> Regex.scan(strip_comments(rules))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert unit_literals == []

    raw_typography =
      ~r/(font-size|font-weight|letter-spacing|line-height):\s*([^;]+);/
      |> Regex.scan(strip_comments(rules), capture: :all_but_first)
      |> Enum.reject(fn [_property, value] -> String.starts_with?(String.trim(value), "var(") end)

    assert raw_typography == []
    refute rules =~ ~r/@apply[^;]*\[[^]]+\]/
    refute rules =~ "@media (width"

    assert layout_markup =~ "observatory-shell-content mx-auto w-full min-w-0"

    assert rules =~
             ~r/\.observatory-shell-content\s*\{[^}]*max-width:\s*var\(--observatory-shell-max-width\);/s

    assert activity =~ ~r/<table[^>]+class="[^"]*\bmin-w-160\b[^"]*"/s
    assert rules =~ ~r/\.observatory-chart\s*\{[^}]*min-width:\s*var\(--container-xl\);/s

    for {name, condition} <- @breakpoint_variants do
      assert css =~ "@custom-variant #{name} (@media (#{condition}));"
    end

    arbitrary_utility_violations =
      for {path, markup} <-
            [
              {@layouts_path, layout_markup}
              | Enum.map(
                  @observatory_markup_paths ++ @showcase_render_paths,
                  &{&1, File.read!(&1)}
                )
            ],
          utility <-
            Regex.scan(~r/[!a-z0-9:_-]+-\[[^\]\s"]+\]/i, markup) |> List.flatten(),
          utility != @approved_arbitrary_utility,
          do: {path, utility}

    assert arbitrary_utility_violations == []
  end

  test "telemetry facts keep definition terms and descriptions in direct groups" do
    html = render_component(&Telemetry.telemetry/1, %{overview: %{}, models: []})
    fragment = LazyHTML.from_fragment(html)

    for {id, descriptions} <- [
          {"observatory-fact-cost", 2},
          {"observatory-fact-tokens", 2}
        ] do
      assert LazyHTML.query(fragment, "##{id} > *") |> Enum.flat_map(&LazyHTML.tag/1) ==
               ["dt" | List.duplicate("dd", descriptions)]

      assert LazyHTML.query(fragment, "##{id} dd dd") |> Enum.empty?()
    end
  end

  defp observatory_rules(css) do
    [_, rules] =
      Regex.run(
        ~r/\/\* Observatory component rules: begin \*\/(.*?)\/\* Observatory component rules: end \*\//s,
        css
      )

    rules
  end

  defp observatory_layout_markup(layouts) do
    [_, markup] =
      Regex.run(~r/<% @chrome == :observatory -> %>(.*?)<% true -> %>/s, layouts)

    markup
  end

  defp strip_comments(css), do: Regex.replace(~r/\/\*.*?\*\//s, css, "")
end
