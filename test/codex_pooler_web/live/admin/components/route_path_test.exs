defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePathTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePath

  test "keeps the four route gates ordered with full and compact labels" do
    assignment = %{
      pool_label: "Ready Pool",
      status: "active",
      health_status: "active",
      quota_priming_status: "known",
      quota_priming_label: "Quota known"
    }

    assert RoutePath.segment_count() == 4

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
               },
               %{
                 key: "circuit",
                 label: "Circuit",
                 short_label: "Circuit",
                 detail_label: "Circuit clear",
                 ready?: true,
                 tone: :success
               }
             ]

    assert RoutePath.ready_count(assignment) == 4

    assert RoutePath.aria_label(assignment) ==
             "Ready Pool route path: Assignment active, Health active, Quota known, Circuit clear"
  end

  test "preserves unknown fallback details for malformed route assignments" do
    assignment = %{pool_label: "Fallback Pool", status: false, health_status: false}

    assert RoutePath.segment_count() == 4

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
               },
               %{
                 key: "circuit",
                 label: "Circuit",
                 short_label: "Circuit",
                 detail_label: "Circuit clear",
                 ready?: true,
                 tone: :success
               }
             ]

    assert RoutePath.ready_count(assignment) == 1

    assert RoutePath.aria_label(assignment) ==
             "Fallback Pool route path: Assignment unknown, Health unknown, Quota unknown, Circuit clear"
  end

  test "maps sanitized circuit summaries after quota and uses a clear absent fallback" do
    assignment = %{
      pool_label: "Circuit Pool",
      status: "active",
      health_status: "active",
      quota_priming_status: "known",
      quota_priming_label: "Quota known"
    }

    for {circuit_readiness, expected_ready_count} <- [
          {%{
             state: :blocked,
             ready?: false,
             tone: :error,
             label: "Circuit protection active",
             detail: "1 circuit lane blocked"
           }, 3},
          {%{
             state: :recovering,
             ready?: true,
             tone: :warning,
             label: "Circuit recovery in progress",
             detail: "1 circuit lane recovering"
           }, 4},
          {%{
             state: :closed,
             ready?: true,
             tone: :success,
             label: "Circuit clear",
             detail: "No circuit protection is active"
           }, 4}
        ] do
      route_assignment = Map.put(assignment, :circuit_readiness, circuit_readiness)
      circuit_segment = route_assignment |> RoutePath.segments() |> List.last()

      assert Enum.map(RoutePath.segments(route_assignment), & &1.key) ==
               ["assignment", "health", "quota", "circuit"]

      assert circuit_segment == %{
               key: "circuit",
               label: "Circuit",
               short_label: "Circuit",
               detail_label: circuit_readiness.label,
               ready?: circuit_readiness.ready?,
               tone: circuit_readiness.tone
             }

      assert RoutePath.ready_count(route_assignment) == expected_ready_count

      assert RoutePath.aria_label(route_assignment) ==
               "Circuit Pool route path: Assignment active, Health active, Quota known, #{circuit_readiness.label}"
    end

    absent_assignment = Map.put(assignment, :status, "disabled") |> Map.delete(:circuit_readiness)

    assert RoutePath.ready_count(absent_assignment) == 3

    assert List.last(RoutePath.segments(absent_assignment)) == %{
             key: "circuit",
             label: "Circuit",
             short_label: "Circuit",
             detail_label: "Circuit clear",
             ready?: true,
             tone: :success
           }
  end
end
