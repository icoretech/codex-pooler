defmodule CodexPoolerWeb.Admin.AlertRuleFormTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Admin.AlertRuleForm

  test "route class normalization retains only supported usability kinds" do
    assert AlertRuleForm.route_class_options() == Enum.map(RouteClass.all(), &{&1, &1})

    for rule_kind <- ["pool_no_usable_assignments", "pool_low_usable_assignments"] do
      attrs =
        AlertRuleForm.normalize_submit(%{
          "rule_kind" => rule_kind,
          "route_class" => " proxy_stream "
        })

      assert attrs["route_class"] == "proxy_stream"
    end

    for rule_kind <- [
          "pool_all_assignments_in_state",
          "upstream_quota_threshold",
          "upstream_auth_state",
          "upstream_saved_reset_banked_first_seen",
          "malformed"
        ] do
      attrs =
        AlertRuleForm.normalize_submit(%{
          "rule_kind" => rule_kind,
          "route_class" => "proxy_stream"
        })

      refute Map.has_key?(attrs, "route_class")
    end
  end

  test "blank route class normalizes to null semantics" do
    attrs =
      AlertRuleForm.normalize_submit(%{
        "rule_kind" => "pool_no_usable_assignments",
        "route_class" => " "
      })

    refute Map.has_key?(attrs, "route_class")

    unknown_attrs =
      AlertRuleForm.normalize_submit(%{
        "rule_kind" => "pool_no_usable_assignments",
        "route_class" => "unknown_route_class"
      })

    refute Map.has_key?(unknown_attrs, "route_class")
  end

  test "edit form round-trips persisted route class" do
    rule = %AlertRule{
      id: Ecto.UUID.generate(),
      pool_id: Ecto.UUID.generate(),
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: "Scoped alert",
      severity: "critical",
      cooldown_minutes: 30,
      state: "active",
      route_class: "proxy_stream"
    }

    form = AlertRuleForm.edit_form(rule)

    assert AlertRuleForm.value(form[:route_class]) == "proxy_stream"
  end
end
