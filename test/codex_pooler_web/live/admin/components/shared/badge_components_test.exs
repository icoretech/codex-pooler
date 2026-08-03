defmodule CodexPoolerWeb.Admin.BadgeComponentsTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.BadgeComponents

  test "known ChatGPT plan values render curated labels" do
    assert BadgeComponents.plan_badge_label("go") == "Go"
    assert BadgeComponents.plan_badge_label("GO") == "Go"
    assert BadgeComponents.plan_badge_label("prolite") == "Pro Lite"
    assert BadgeComponents.plan_badge_label("ent26") == "Enterprise"
    assert BadgeComponents.plan_badge_label("hc") == "Enterprise"

    assert BadgeComponents.plan_badge_label("enterprise_cbp_automation") ==
             "Enterprise (Automation)"

    assert BadgeComponents.plan_badge_label("self_serve_business_prolite") ==
             "Self Serve Business ProLite"

    # The slugified plan_family form resolves to the same curated label as the
    # raw claim value.
    assert BadgeComponents.plan_badge_label("self-serve-business-usage-based") ==
             "Self Serve Business Usage Based"
  end

  test "unknown plan labels pass through verbatim" do
    assert BadgeComponents.plan_badge_label("mystery_plan") == "mystery_plan"
  end

  test "go carries the paid consumer tone rather than a generated chip" do
    assert BadgeComponents.plan_badge_class("go") == BadgeComponents.plan_badge_class("plus")
    assert BadgeComponents.plan_badge_class("prolite") == BadgeComponents.plan_badge_class("pro")

    assert BadgeComponents.plan_badge_class("self_serve_business_prolite") ==
             BadgeComponents.plan_badge_class("business")

    assert BadgeComponents.plan_badge_class("ent26") ==
             BadgeComponents.plan_badge_class("enterprise")
  end
end
