defmodule CodexPoolerWeb.Admin.BadgeComponentsTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias CodexPoolerWeb.Admin.BadgeComponents
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Dev.ComponentShowcaseData

  test "upstream plan badge shares the card activity signal without marking idle cards" do
    account = ComponentShowcaseData.account_card()

    for level <- [0, 1, 5] do
      account = put_in(account.token_burn.level, level)

      html =
        Phoenix.LiveViewTest.render_component(
          &AccountCard.account_card/1,
          account: account,
          account_index: 0
        )

      assert html =~ "admin-plan-badge--pro"
      assert String.contains?(html, "admin-token-burn-active") == level > 0
    end
  end

  test "shared component renders satin family without inventing a plan multiplier" do
    for {label, tone} <- [{"go", "go"}, {"pro", "pro"}, {"prolite", "prolite"}, {"promax", "pro"}] do
      html = Phoenix.LiveViewTest.render_component(&BadgeComponents.plan_badge/1, label: label)
      assert html =~ "admin-plan-badge--#{tone}"
      assert html =~ BadgeComponents.plan_badge_label(label)
      refute html =~ "5x"
      refute html =~ "20x"
    end
  end

  test "known ChatGPT plan values render curated labels" do
    assert BadgeComponents.plan_badge_label("go") == "Go"
    assert BadgeComponents.plan_badge_label("GO") == "Go"
    assert BadgeComponents.plan_badge_label("prolite") == "Pro"
    assert BadgeComponents.plan_badge_label("pro") == "Pro (More)"
    assert BadgeComponents.plan_badge_label("promax") == "Pro (Max)"
    assert BadgeComponents.plan_badge_label("ent26") == "Enterprise"
    assert BadgeComponents.plan_badge_label("hc") == "Enterprise"
    assert BadgeComponents.plan_badge_label("edu_plus") == "Edu Plus"
    assert BadgeComponents.plan_badge_label("edu-pro") == "Edu Pro"

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

  test "Codex plan SKUs preserve their curated label through family normalization" do
    plans = [
      {"free", "Free"},
      {"go", "Go"},
      {"plus", "Plus"},
      {"pro", "Pro (More)"},
      {"prolite", "Pro"},
      {"promax", "Pro (Max)"},
      {"team", "Team"},
      {"business", "Business"},
      {"ent26", "Enterprise"},
      {"enterprise", "Enterprise"},
      {"enterprise_cbp_automation", "Enterprise (Automation)"},
      {"enterprise_cbp_usage_based", "Enterprise CBP Usage Based"},
      {"self_serve_business_prolite", "Self Serve Business ProLite"},
      {"self_serve_business_usage_based", "Self Serve Business Usage Based"},
      {"edu", "Edu"},
      {"edu_plus", "Edu Plus"},
      {"edu_pro", "Edu Pro"}
    ]

    for {plan, label} <- plans do
      assert BadgeComponents.plan_badge_label(plan) == label
      assert BadgeComponents.plan_badge_label(String.replace(plan, "_", "-")) == label
    end
  end

  test "known plans have distinct satin palettes while aliases keep their family" do
    classes =
      Enum.map(
        ~w(free go plus pro prolite team business enterprise edu),
        &BadgeComponents.plan_badge_class/1
      )

    assert length(Enum.uniq(classes)) == 9

    assert BadgeComponents.plan_badge_class("promax") == BadgeComponents.plan_badge_class("pro")

    assert BadgeComponents.plan_badge_class("self_serve_business_prolite") ==
             BadgeComponents.plan_badge_class("team")

    assert BadgeComponents.plan_badge_class("ent26") ==
             BadgeComponents.plan_badge_class("enterprise")

    assert BadgeComponents.plan_badge_class("edu_plus") ==
             BadgeComponents.plan_badge_class("edu")

    assert BadgeComponents.plan_badge_class("edu-pro") ==
             BadgeComponents.plan_badge_class("edu")
  end
end
