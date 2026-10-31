defmodule CodexPoolerWeb.Admin.BadgeComponentsTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias CodexPooler.Pools.RoutingStrategy
  alias CodexPoolerWeb.Admin.BadgeComponents
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Dev.ComponentShowcaseData

  setup do
    Gettext.put_locale("en")
    :ok
  end

  test "Chinese routing presentation and unknown plan labels retain identifier boundaries" do
    Gettext.put_locale("zh_CN")

    assert BadgeComponents.routing_strategy_label("bridge_ring") == "缓存局部性"
    assert BadgeComponents.routing_strategy_presentation("quota_first").feature == "优先可用配额"
    assert BadgeComponents.plan_badge_label(nil) == "未知套餐"
    assert BadgeComponents.plan_badge_label("mystery_plan") == "mystery_plan"
    assert BadgeComponents.plan_badge_label("pro") == "Pro 200"
  end

  test "routing options cover the domain catalog with shared labels and complete explanations" do
    ids = RoutingStrategy.ids()
    options = PoolForm.routing_strategy_options()
    assert Enum.map(options, &elem(&1, 1)) == ids
    assert Enum.map(options, &elem(&1, 0)) == ["Cache locality", "Rotation", "Least recent success", "Quota first"]

    for {_label, id} <- options do
      presentation = BadgeComponents.routing_strategy_presentation(id)
      for field <- [:description, :feature, :detail, :cache_title, :cache_description], do: assert(byte_size(Map.fetch!(presentation, field)) > 0)
    end

    assert BadgeComponents.routing_strategy_presentation("unsupported") == nil
    assert BadgeComponents.routing_strategy_label(nil) == nil
  end

  test "unassigned accounts without deletion capability explain permission rather than Pool removal" do
    account = ComponentShowcaseData.account_card() |> Map.merge(%{assignments: [], can_delete?: false})
    html = Phoenix.LiveViewTest.render_component(&AccountCard.account_card/1, account: account, account_index: 0)
    assert LazyHTML.from_fragment(html) |> LazyHTML.query("#delete-upstream-account-#{account.identity.id}[disabled]") |> LazyHTML.attribute("title") == ["You do not have permission to permanently delete this account."]
  end

  test "plain plan text uses named palettes and neutral Free without a missing modifier" do
    assert BadgeComponents.plan_text_class("free") == "admin-plan-text"
    assert BadgeComponents.plan_text_class(nil) == "text-base-content/70"

    for plan <- ~w(go plus pro prolite team business enterprise edu) do
      assert BadgeComponents.plan_text_class(plan) == "admin-plan-text admin-plan-badge--#{plan}"
    end

    assert BadgeComponents.plan_text_class("promax") == BadgeComponents.plan_text_class("pro")
  end

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
    assert BadgeComponents.plan_badge_label("prolite") == "Pro 100"
    assert BadgeComponents.plan_badge_label("pro") == "Pro 200"
    assert BadgeComponents.plan_badge_label("promax") == "Pro 500"
    assert BadgeComponents.plan_badge_label("ent26") == "Enterprise"
    assert BadgeComponents.plan_badge_label("hc") == "Enterprise"
    assert BadgeComponents.plan_badge_label("edu_plus") == "Edu Plus"
    assert BadgeComponents.plan_badge_label("edu-pro") == "Edu Pro"

    assert BadgeComponents.plan_badge_label("enterprise_cbp_automation") ==
             "Enterprise Automation"

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
      {"pro", "Pro 200"},
      {"prolite", "Pro 100"},
      {"promax", "Pro 500"},
      {"team", "Team"},
      {"business", "Business"},
      {"ent26", "Enterprise"},
      {"enterprise", "Enterprise"},
      {"hc", "Enterprise"},
      {"enterprise_cbp_automation", "Enterprise Automation"},
      {"enterprise_cbp_usage_based", "Enterprise CBP Usage Based"},
      {"self_serve_business_prolite", "Self Serve Business ProLite"},
      {"self_serve_business_usage_based", "Self Serve Business Usage Based"},
      {"edu", "Edu"},
      {"education", "Education"},
      {"edu_plus", "Edu Plus"},
      {"edu_pro", "Edu Pro"}
    ]

    for {plan, label} <- plans do
      assert BadgeComponents.plan_badge_label(plan) == label
      assert BadgeComponents.plan_badge_label(String.replace(plan, "_", "-")) == label

      html = Phoenix.LiveViewTest.render_component(&BadgeComponents.plan_badge/1, label: plan, family: String.replace(plan, "_", "-"))
      assert html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() == label
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
