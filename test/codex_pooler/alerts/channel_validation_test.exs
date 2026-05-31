defmodule CodexPooler.Alerts.ChannelValidationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertChannel

  test "email channels normalize deterministic recipients and do not require webhook fields" do
    scope = owner_scope()

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: " Operations email ",
               state: "active",
               email_to: " Alerts@Example.COM ",
               metadata: %{}
             })

    assert channel.channel_type == "email"
    assert channel.display_name == "Operations email"
    assert channel.email_to == "alerts@example.com"
    assert channel.endpoint_scheme == nil
    assert channel.endpoint_host == nil
    assert channel.endpoint_path_prefix == nil
    assert channel.endpoint_fingerprint == nil
  end

  test "email channels reject blank and malformed recipients" do
    scope = owner_scope()

    assert {:error, blank_changeset} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Blank email",
               email_to: "   ",
               metadata: %{}
             })

    assert %{email_to: ["can't be blank"]} = errors_on(blank_changeset)

    assert {:error, invalid_changeset} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Invalid email",
               email_to: "not-an-email",
               metadata: %{}
             })

    assert %{email_to: ["must be a valid email address"]} = errors_on(invalid_changeset)
  end

  test "webhook channels normalize https endpoint URL into safe display fields" do
    scope = owner_scope()

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Webhook alerts",
               endpoint_url:
                 " https://Hooks.Example.COM/services/abcd1234/team-5678?token=query-token ",
               metadata: %{}
             })

    assert channel.channel_type == "webhook"
    assert channel.email_to == nil
    assert channel.endpoint_scheme == "https"
    assert channel.endpoint_host == "hooks.example.com"
    assert channel.endpoint_path_prefix == "/serv.../abcd..."
    assert String.starts_with?(channel.endpoint_fingerprint, "sha256:")
    refute channel.endpoint_fingerprint =~ "query-token"
  end

  test "webhook channels accept already-normalized safe endpoint fields" do
    scope = owner_scope()

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Stored webhook",
               endpoint_scheme: "HTTPS",
               endpoint_host: " Hooks.Example.COM ",
               endpoint_path_prefix: "/alerts",
               endpoint_fingerprint: "sha256:stored",
               metadata: %{}
             })

    assert channel.endpoint_scheme == "https"
    assert channel.endpoint_host == "hooks.example.com"
    assert channel.endpoint_path_prefix == "/alerts"
    assert channel.endpoint_fingerprint == "sha256:stored"
  end

  test "webhook channels reject malformed, non-https, and incomplete endpoints" do
    scope = owner_scope()

    assert {:error, http_changeset} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "HTTP webhook",
               endpoint_url: "http://hooks.example.com/alerts?token=hidden",
               metadata: %{}
             })

    assert %{endpoint_url: ["must use https"]} = errors_on(http_changeset)
    refute inspect(http_changeset) =~ "hidden"

    assert {:error, malformed_changeset} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Malformed webhook",
               endpoint_url: "https://user:pass@hooks.example.com/alerts",
               metadata: %{}
             })

    assert %{endpoint_url: ["must be a valid https URL"]} = errors_on(malformed_changeset)
    refute inspect(malformed_changeset) =~ "pass"

    assert {:error, missing_changeset} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Missing endpoint",
               metadata: %{}
             })

    assert "can't be blank" in errors_on(missing_changeset).endpoint_scheme
    assert "can't be blank" in errors_on(missing_changeset).endpoint_host
    assert "can't be blank" in errors_on(missing_changeset).endpoint_path_prefix
    assert "can't be blank" in errors_on(missing_changeset).endpoint_fingerprint
  end

  test "channel states set disabled_at on disable and clear it on activation" do
    scope = owner_scope()

    assert {:ok, disabled} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Disabled email",
               state: "disabled",
               email_to: "disabled@example.com",
               metadata: %{}
             })

    assert disabled.state == AlertChannel.disabled_state()
    assert %DateTime{} = disabled.disabled_at

    assert {:ok, active} = Alerts.update_channel(scope, disabled.id, %{state: "active"})
    assert active.state == AlertChannel.active_state()
    assert active.disabled_at == nil

    assert {:ok, disabled_again} = Alerts.update_channel(scope, active.id, %{state: "disabled"})
    assert disabled_again.state == AlertChannel.disabled_state()
    assert %DateTime{} = disabled_again.disabled_at
  end

  defp owner_scope do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(owner)
  end
end
