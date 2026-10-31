defmodule CodexPoolerWeb.Admin.AlertChannelFormTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.AlertChannelForm

  test "email channels default to English and retain an explicit language" do
    form = AlertChannelForm.create_form()
    assert form[:locale].value == "en"

    attrs = AlertChannelForm.normalize_submit(%{"channel_type" => "email", "email_to" => "alerts@example.com", "locale" => "zh-CN"})
    assert attrs["locale"] == "zh-CN"
    assert AlertChannelForm.create_form(attrs)[:locale].value == "zh-CN"
  end

  test "webhook displays omit email language while submitted values reach validation for rejection" do
    form = AlertChannelForm.create_form(%{"channel_type" => "webhook", "locale" => "zh-CN"})
    assert form[:locale].value == nil

    attrs = AlertChannelForm.normalize_submit(%{"channel_type" => "webhook", "locale" => "zh-CN", "endpoint_url" => "https://alerts.example.com/notify"})
    assert attrs["locale"] == "zh-CN"
    refute Map.has_key?(AlertChannelForm.normalize_submit(%{"channel_type" => "webhook"}), "locale")
  end

  test "existing null email channel language edits as English without changing webhook defaults" do
    channel = %{id: "channel-id", channel_type: "email", display_name: "Alert email", state: "active", email_to: "alerts@example.com", locale: nil}
    assert AlertChannelForm.edit_form(channel)[:locale].value == "en"
    assert AlertChannelForm.edit_form(%{channel | channel_type: "webhook"})[:locale].value == nil
  end
end
