defmodule CodexPooler.Alerts.ChannelSecurityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertChannel
  alias CodexPooler.Repo

  test "webhook URL query values and raw endpoint never appear in channel projection" do
    scope = owner_scope()

    raw_endpoint =
      "https://hooks.example.com/services/path-secret?token=query-secret&authorization=bearer"

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Masked webhook",
               endpoint_url: raw_endpoint,
               metadata: %{
                 "safe_label" => "routing alerts",
                 "token" => "metadata-secret"
               }
             })

    refute projection_contains?(channel, raw_endpoint)
    refute projection_contains?(channel, "query-secret")
    refute projection_contains?(channel, "path-secret")
    assert channel.endpoint_path_prefix == "/serv.../path..."
    assert channel.metadata == %{"safe_label" => "routing alerts", "token" => "[REDACTED]"}

    persisted = Repo.get!(AlertChannel, channel.id)
    refute persisted.endpoint_path_prefix =~ "query-secret"
    refute persisted.endpoint_path_prefix =~ "path-secret"
    refute persisted.endpoint_fingerprint =~ "query-secret"
    refute inspect(persisted) =~ raw_endpoint
  end

  test "webhook signing secret is encrypted write-only storage and hidden from projections" do
    scope = owner_scope()
    signing_secret = "whsec_test_hidden_value"

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Signed webhook",
               endpoint_url: "https://hooks.example.com/alerts/team?shared_secret=query-hidden",
               webhook_signing_secret: signing_secret,
               metadata: %{}
             })

    refute Map.has_key?(channel, :webhook_signing_secret)
    refute Map.has_key?(channel, :webhook_signing_secret_ciphertext)
    refute Map.has_key?(channel, :webhook_signing_secret_nonce)
    refute Map.has_key?(channel, :webhook_signing_secret_aad)
    assert channel.webhook_signing_secret_key_version == "v1"
    refute projection_contains?(channel, signing_secret)
    refute projection_contains?(channel, "query-hidden")

    persisted = Repo.get!(AlertChannel, channel.id)
    assert is_binary(persisted.webhook_signing_secret_ciphertext)
    assert is_binary(persisted.webhook_signing_secret_nonce)
    assert persisted.webhook_signing_secret_ciphertext != signing_secret
    assert persisted.webhook_signing_secret_aad["secret_kind"] == "alert_webhook_signing_secret"

    inspected = inspect(persisted)
    refute inspected =~ signing_secret
    refute inspected =~ "webhook_signing_secret_ciphertext"
    refute inspected =~ "webhook_signing_secret_nonce"
    refute inspected =~ "webhook_signing_secret_aad"
  end

  test "signing secret can be cleared without exposing previous material" do
    scope = owner_scope()

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Clearable webhook",
               endpoint_url: "https://hooks.example.com/alerts",
               webhook_signing_secret: "whsec_clear_me",
               metadata: %{}
             })

    assert channel.webhook_signing_secret_key_version == "v1"

    assert {:ok, cleared} =
             Alerts.update_channel(scope, channel.id, %{webhook_signing_secret_action: "clear"})

    assert cleared.webhook_signing_secret_key_version == nil
    refute projection_contains?(cleared, "whsec_clear_me")

    persisted = Repo.get!(AlertChannel, channel.id)
    assert persisted.webhook_signing_secret_ciphertext == nil
    assert persisted.webhook_signing_secret_nonce == nil
    assert persisted.webhook_signing_secret_aad == %{}
  end

  test "raw endpoint and signing secret are removed from successful changeset inspect" do
    raw_endpoint = "https://hooks.example.com/alerts?token=change-secret"
    signing_secret = "whsec_changeset_hidden"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset =
      AlertChannel.changeset(%AlertChannel{}, %{
        channel_type: "webhook",
        display_name: "Inspectable webhook",
        endpoint_url: raw_endpoint,
        webhook_signing_secret: signing_secret,
        metadata: %{},
        created_at: now,
        updated_at: now
      })

    assert changeset.valid?
    inspected = inspect(changeset)
    refute inspected =~ raw_endpoint
    refute inspected =~ "change-secret"
    refute inspected =~ signing_secret
  end

  defp owner_scope do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(owner)
  end

  defp projection_contains?(projection, value) do
    projection
    |> inspect()
    |> String.contains?(value)
  end
end
