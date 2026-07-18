defmodule CodexPoolerWeb.Dev.ComponentShowcaseCatalogTest do
  use CodexPoolerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Dev.ComponentShowcaseLive
  alias CodexPoolerWeb.Observatory.Components.Activity

  @review_states ~w(catalog flash request-drawer policy-dialog)
  @required_section_ids Enum.map(1..16, &"5.#{&1}") ++ Enum.map(1..3, &"6.#{&1}")
  @required_inventory ~w(
    5.1-page-header
    5.2-metric-strip-card
    5.3-admin-surface
    5.4-account-card
    5.5-quota-row
    5.6-reset-bank
    5.7-chip-families
    5.8-definition-row
    5.8-ranked-list
    5.8-zebra-table
    5.9-plan-badge
    5.10-dropdown-menu
    5.11-object-inspector
    5.11-request-drawer
    5.12-segmented-control
    5.13-time-series-chart
    5.14-policy-dialog
    5.14-policy-mode-leaf
    5.15-filter-date
    5.15-empty-state
    5.15-notices
    5.15-actions
    5.15-flash
    5.15-theme-toggle
    5.15-inputs
    5.16-cockpit
    6.1-shell
    6.1-toolbar
    6.2-telemetry
    6.2-activity
    6.3-states
  )

  test "catalog accounts for every structured design section and assigns a review state" do
    contract = ComponentShowcaseLive.component_contract()

    assert contract |> Enum.map(& &1.section_id) |> MapSet.new() ==
             MapSet.new(@required_section_ids)

    assert contract |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort(@required_inventory)

    for entry <- contract do
      assert entry.availability in [:rendered, :interactive, :product_route, :private_leaf]

      case entry.availability do
        :rendered -> assert entry.review_state == "catalog"
        :interactive -> assert entry.review_state in (@review_states -- ["catalog"])
        unavailable -> assert_unavailable_reason(entry, unavailable)
      end
    end
  end

  test "design contract requires real exports and visible selectors in their review states" do
    contract = ComponentShowcaseLive.component_contract()
    render_contracts = ComponentShowcaseLive.render_contracts()
    fragments = review_fragments()

    assert contract_violations(fragments, contract, render_contracts) == []

    assert MapSet.subset?(
             MapSet.new([
               "#observatory-state-empty-anatomy",
               "#observatory-state-partial-settled",
               "#observatory-state-partial-estimated",
               "#observatory-state-disconnected [data-role='reconnect-flash']"
             ]),
             contract |> Enum.flat_map(& &1.selectors) |> MapSet.new()
           )

    rendered_entry = Enum.find(contract, &(&1.availability == :rendered))
    missing_selector = "#test-only-deliberately-missing-selector"
    missing_fixture = [%{rendered_entry | selectors: [missing_selector]}]

    assert contract_violations(fragments, missing_fixture, render_contracts) == [
             {:missing_selector, missing_selector}
           ]

    hidden_selector = "#client-error"
    hidden_fixture = [%{rendered_entry | selectors: [hidden_selector]}]

    assert contract_violations(fragments, hidden_fixture, render_contracts) == [
             {:hidden_selector, hidden_selector}
           ]
  end

  test "stats primitives are rendered by their declared public composition" do
    contract = ComponentShowcaseLive.component_contract()
    render_contracts = ComponentShowcaseLive.render_contracts()
    fragments = review_fragments()
    fragment = Map.fetch!(fragments, "catalog")

    stats_entries =
      Enum.filter(contract, &(&1.id in ~w(5.12-segmented-control 5.13-time-series-chart)))

    stats_contract = Map.fetch!(render_contracts, "stats-traffic-charts")

    assert Enum.map(stats_entries, & &1.render_contract) ==
             ["stats-traffic-charts", "stats-traffic-charts"]

    assert Enum.all?(stats_entries, &(&1.exports == stats_contract.exports))
    assert fragment |> LazyHTML.query(stats_contract.root_selector) |> Enum.count() == 1

    unrelated =
      stats_entries
      |> hd()
      |> Map.merge(%{
        exports: [{Activity, :activity, 1}],
        scope_selector: "#showcase-observatory-activity",
        selectors: ["#observatory-traffic-mode-control"]
      })

    assert function_exported?(Activity, :activity, 1)

    refute LazyHTML.query(
             fragment,
             "#{unrelated.scope_selector} #{hd(unrelated.selectors)}"
           )
           |> Enum.empty?()

    assert contract_violations(fragments, [unrelated], render_contracts) |> MapSet.new() ==
             MapSet.new([
               {:render_contract_exports, unrelated.id},
               {:render_contract_scope, unrelated.id},
               {:render_contract_selectors, unrelated.id}
             ])
  end

  defp assert_unavailable_reason(entry, unavailable)
       when unavailable in [:product_route, :private_leaf] do
    assert entry.review_state == nil
    assert is_binary(entry.reason) and String.trim(entry.reason) != ""
  end

  defp review_fragments do
    Map.new(@review_states, fn review_state ->
      {:ok, view, _html} =
        live_isolated(build_conn(), ComponentShowcaseLive,
          session: %{"theme" => "dark", "review_state" => review_state}
        )

      {review_state, view |> render() |> LazyHTML.from_fragment()}
    end)
  end

  defp contract_violations(fragments, contract, render_contracts) do
    Enum.flat_map(contract, fn entry ->
      []
      |> add_export_violations(entry)
      |> add_render_contract_violations(render_contracts, entry)
      |> add_selector_violations(fragments, entry)
    end)
  end

  defp add_render_contract_violations(violations, _render_contracts, %{render_contract: nil}),
    do: violations

  defp add_render_contract_violations(violations, render_contracts, entry) do
    render_contract = Map.fetch!(render_contracts, entry.render_contract)
    expected_entry = Enum.find(render_contract.entries, &(&1.id == entry.id))

    violations
    |> maybe_add(entry.exports != render_contract.exports, {:render_contract_exports, entry.id})
    |> maybe_add(
      entry.scope_selector != render_contract.root_selector,
      {:render_contract_scope, entry.id}
    )
    |> maybe_add(
      expected_entry == nil or entry.selectors != expected_entry.selectors,
      {:render_contract_selectors, entry.id}
    )
  end

  defp add_export_violations(violations, %{availability: :private_leaf} = entry) do
    Enum.reduce(entry.exports, violations, fn {module, function, arity}, acc ->
      maybe_add(
        acc,
        function_exported?(module, function, arity),
        {:unexpected_public_export, module, function, arity}
      )
    end)
  end

  defp add_export_violations(violations, entry) do
    Enum.reduce(entry.exports, violations, fn {module, function, arity}, acc ->
      maybe_add(
        acc,
        not (Code.ensure_loaded?(module) and function_exported?(module, function, arity)),
        {:missing_export, module, function, arity}
      )
    end)
  end

  defp add_selector_violations(violations, fragments, entry)
       when entry.availability in [:rendered, :interactive] do
    fragment = Map.fetch!(fragments, entry.review_state)

    Enum.reduce(entry.selectors, violations, fn selector, acc ->
      nodes = LazyHTML.query(fragment, scoped_selector(entry, selector))

      cond do
        Enum.empty?(nodes) -> [{:missing_selector, selector} | acc]
        Enum.any?(nodes, &visibly_reviewable?/1) -> acc
        true -> [{:hidden_selector, selector} | acc]
      end
    end)
  end

  defp add_selector_violations(violations, _fragments, _entry), do: violations

  defp scoped_selector(%{scope_selector: nil}, selector), do: selector
  defp scoped_selector(entry, selector), do: "#{entry.scope_selector} #{selector}"

  defp visibly_reviewable?(node) do
    if hidden_node?(node) do
      false
    else
      node
      |> LazyHTML.parent_node()
      |> Enum.all?(&visibly_reviewable?/1)
    end
  end

  defp hidden_node?(node) do
    attributes = node |> LazyHTML.attributes() |> List.first([]) |> Map.new()
    classes = attributes |> Map.get("class", "") |> String.split()
    style = attributes |> Map.get("style", "") |> String.replace(" ", "")

    Map.has_key?(attributes, "hidden") or
      Map.has_key?(attributes, "inert") or
      attributes["aria-hidden"] == "true" or
      attributes["type"] == "hidden" or
      Enum.any?(~w(hidden invisible opacity-0 sr-only), &(&1 in classes)) or
      String.contains?(style, "display:none") or
      String.contains?(style, "visibility:hidden")
  end

  defp maybe_add(violations, true, violation), do: [violation | violations]
  defp maybe_add(violations, false, _violation), do: violations
end
