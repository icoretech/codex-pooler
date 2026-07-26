defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePathTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePath

  @account_card_path "lib/codex_pooler_web/live/admin/components/pages/upstreams/account_card.ex"
  @cockpit_sections_path "lib/codex_pooler_web/live/admin/components/pages/upstreams/cockpit/sections.ex"

  test "keeps the three route gates ordered with full and compact labels" do
    assignment = %{
      pool_label: "Ready Pool",
      status: "active",
      health_status: "active",
      quota_priming_status: "known",
      quota_priming_label: "Quota known"
    }

    assert RoutePath.segment_count() == 3

    assert RoutePath.segments(assignment)
           |> Enum.map(&Map.take(&1, [:key, :label, :short_label, :detail_label, :ready?, :tone])) ==
             [
               %{
                 key: "assignment",
                 label: "Assignment",
                 short_label: "Assign",
                 detail_label: "Assignment active",
                 ready?: true,
                 tone: :success
               },
               %{
                 key: "health",
                 label: "Health",
                 short_label: "Health",
                 detail_label: "Health active",
                 ready?: true,
                 tone: :success
               },
               %{
                 key: "quota",
                 label: "Quota",
                 short_label: "Quota",
                 detail_label: "Quota known",
                 ready?: true,
                 tone: :success
               }
             ]

    assert RoutePath.ready_count(assignment) == 3

    assert RoutePath.aria_label(assignment) ==
             "Ready Pool route path: Assignment active, Health active, Quota known"
  end

  test "preserves unknown fallback details for malformed route assignments" do
    assignment = %{pool_label: "Fallback Pool", status: false, health_status: false}

    assert RoutePath.segment_count() == 3

    assert RoutePath.segments(assignment)
           |> Enum.map(&Map.take(&1, [:key, :label, :short_label, :detail_label, :ready?, :tone])) ==
             [
               %{
                 key: "assignment",
                 label: "Assignment",
                 short_label: "Assign",
                 detail_label: "Assignment unknown",
                 ready?: false,
                 tone: :warning
               },
               %{
                 key: "health",
                 label: "Health",
                 short_label: "Health",
                 detail_label: "Health unknown",
                 ready?: false,
                 tone: :warning
               },
               %{
                 key: "quota",
                 label: "Quota",
                 short_label: "Quota",
                 detail_label: "Quota unknown",
                 ready?: false,
                 tone: :warning
               }
             ]

    assert RoutePath.ready_count(assignment) == 0

    assert RoutePath.aria_label(assignment) ==
             "Fallback Pool route path: Assignment unknown, Health unknown, Quota unknown"
  end

  test "route meters derive cardinality and retain full spoken detail" do
    account_card_source = File.read!(Path.join(File.cwd!(), @account_card_path))
    cockpit_sections_source = File.read!(Path.join(File.cwd!(), @cockpit_sections_path))

    assert account_card_source =~ "{segment.short_label}"
    assert cockpit_sections_source =~ "{segment.label}"

    for source <- [account_card_source, cockpit_sections_source] do
      assert source =~ "aria-valuemax={RoutePath.segment_count()}"
      assert source =~ "aria-valuetext={RoutePath.aria_label(assignment)}"
      assert source =~ "aria-label={RoutePath.aria_label(assignment)}"
      refute source =~ ~s(aria-valuemax="3")
    end
  end
end
