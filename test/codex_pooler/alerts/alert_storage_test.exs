defmodule CodexPooler.Alerts.AlertStorageTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule
  }

  test "changesets reject fixed v1 vocabulary drift" do
    now = now()
    pool = pool_fixture()

    rule_attrs = valid_rule_attrs(pool, now)

    for {field, value} <- [
          scope_type: "organization",
          rule_kind: "static_plan_credit_low",
          severity: "urgent",
          state: "paused",
          target_state: "unknown",
          window_selector: "model_tertiary"
        ] do
      changeset = AlertRule.changeset(%AlertRule{}, Map.put(rule_attrs, field, value))

      assert "is invalid" in errors_on(changeset)[field]
    end

    assert "must be greater than or equal to 5" in errors_on(
             AlertRule.changeset(%AlertRule{}, %{rule_attrs | cooldown_minutes: 4})
           ).cooldown_minutes

    assert "must be less than or equal to 1440" in errors_on(
             AlertRule.changeset(%AlertRule{}, %{rule_attrs | cooldown_minutes: 1441})
           ).cooldown_minutes

    channel_attrs = valid_channel_attrs(now)

    assert "is invalid" in errors_on(
             AlertChannel.changeset(%AlertChannel{}, %{channel_attrs | channel_type: "telegram"})
           ).channel_type

    assert "is invalid" in errors_on(
             AlertChannel.changeset(%AlertChannel{}, %{channel_attrs | state: "archived"})
           ).state

    incident_attrs = valid_incident_attrs(pool, now, "alert:invalid:vocab")

    assert "is invalid" in errors_on(
             AlertIncident.changeset(%AlertIncident{}, %{incident_attrs | state: "closed"})
           ).state

    attempt_attrs = valid_delivery_attempt_attrs(Ecto.UUID.generate(), Ecto.UUID.generate(), now)

    assert "is invalid" in errors_on(
             AlertDeliveryAttempt.changeset(%AlertDeliveryAttempt{}, %{
               attempt_attrs
               | status: "queued"
             })
           ).status

    assert "must be equal to 5" in errors_on(
             AlertDeliveryAttempt.changeset(%AlertDeliveryAttempt{}, %{
               attempt_attrs
               | max_attempts: 6
             })
           ).max_attempts
  end

  test "database constraints reject invalid values when changesets are bypassed" do
    pool = pool_fixture()
    now = now()

    assert {:error, rule_changeset} =
             %AlertRule{}
             |> change(%{valid_rule_attrs(pool, now) | cooldown_minutes: 1})
             |> check_constraint(:cooldown_minutes, name: :alert_rules_cooldown_minutes_check)
             |> Repo.insert()

    assert %{cooldown_minutes: ["is invalid"]} = errors_on(rule_changeset)

    channel = insert_channel!(now)
    incident = insert_incident!(pool, now, "alert:constraint:max-attempts")

    assert {:error, attempt_changeset} =
             %AlertDeliveryAttempt{}
             |> change(%{
               valid_delivery_attempt_attrs(incident.id, channel.id, now)
               | max_attempts: 4
             })
             |> check_constraint(:max_attempts, name: :alert_delivery_attempts_max_attempts_check)
             |> Repo.insert()

    assert %{max_attempts: ["is invalid"]} = errors_on(attempt_changeset)
  end

  test "unresolved incidents are unique by dedupe key for open and acknowledged states" do
    pool = pool_fixture()
    now = now()

    assert {:ok, _open_incident} =
             %AlertIncident{}
             |> AlertIncident.changeset(valid_incident_attrs(pool, now, "alert:pool:shared"))
             |> Repo.insert()

    assert {:error, open_changeset} =
             %AlertIncident{}
             |> AlertIncident.changeset(valid_incident_attrs(pool, now, "alert:pool:shared"))
             |> Repo.insert()

    assert %{dedupe_key: ["already has an unresolved incident"]} = errors_on(open_changeset)

    assert {:error, acknowledged_changeset} =
             %AlertIncident{}
             |> AlertIncident.changeset(
               Map.merge(valid_incident_attrs(pool, now, "alert:pool:shared"), %{
                 state: "acknowledged",
                 acknowledged_at: now
               })
             )
             |> Repo.insert()

    assert %{dedupe_key: ["already has an unresolved incident"]} =
             errors_on(acknowledged_changeset)
  end

  test "a resolved incident row does not block a returned unresolved incident" do
    pool = pool_fixture()
    now = now()

    assert {:ok, open_incident} =
             %AlertIncident{}
             |> AlertIncident.changeset(valid_incident_attrs(pool, now, "alert:pool:returning"))
             |> Repo.insert()

    assert {:ok, resolved_incident} =
             open_incident
             |> AlertIncident.changeset(%{state: "resolved", resolved_at: now})
             |> Repo.update()

    assert resolved_incident.id == open_incident.id
    assert resolved_incident.state == "resolved"

    assert {:ok, returned_incident} =
             %AlertIncident{}
             |> AlertIncident.changeset(valid_incident_attrs(pool, now, "alert:pool:returning"))
             |> Repo.insert()

    assert returned_incident.id != resolved_incident.id
    assert returned_incident.state == "open"
  end

  test "incident target fan-out and delivery attempts enforce storage uniqueness" do
    pool = pool_fixture()
    now = now()

    rule = insert_rule!(pool, now)
    channel = insert_channel!(now)
    incident = insert_incident!(pool, now, "alert:pool:fanout")

    target_attrs = valid_incident_target_attrs(incident, rule, pool, now)

    assert {:ok, _target} =
             %AlertIncidentTarget{}
             |> AlertIncidentTarget.changeset(target_attrs)
             |> Repo.insert()

    assert {:error, target_changeset} =
             %AlertIncidentTarget{}
             |> AlertIncidentTarget.changeset(target_attrs)
             |> Repo.insert()

    assert %{pool_id: ["has already been taken"]} = errors_on(target_changeset)

    attempt_attrs = valid_delivery_attempt_attrs(incident.id, channel.id, now)

    assert {:ok, _attempt} =
             %AlertDeliveryAttempt{}
             |> AlertDeliveryAttempt.changeset(attempt_attrs)
             |> Repo.insert()

    assert {:error, attempt_changeset} =
             %AlertDeliveryAttempt{}
             |> AlertDeliveryAttempt.changeset(attempt_attrs)
             |> Repo.insert()

    assert %{attempt_number: ["has already been taken"]} = errors_on(attempt_changeset)
  end

  test "webhook signing material is encrypted-storage shaped and redacted from inspect" do
    now = now()

    assert {:ok, channel} =
             %AlertChannel{}
             |> AlertChannel.changeset(
               Map.merge(valid_channel_attrs(now), %{
                 channel_type: "webhook",
                 email_to: nil,
                 endpoint_scheme: "https",
                 endpoint_host: "hooks.example.com",
                 endpoint_path_prefix: "/alerts",
                 endpoint_fingerprint: "sha256:example",
                 webhook_signing_secret_ciphertext: <<1, 2, 3>>,
                 webhook_signing_secret_nonce: <<4, 5, 6>>,
                 webhook_signing_secret_aad: %{"channel_id" => "pending"},
                 webhook_signing_secret_key_version: "v1"
               })
             )
             |> Repo.insert()

    inspected = inspect(channel)

    refute inspected =~ "webhook_signing_secret_ciphertext"
    refute inspected =~ "webhook_signing_secret_nonce"
    refute inspected =~ "webhook_signing_secret_aad"
  end

  defp insert_rule!(pool, now) do
    %AlertRule{}
    |> AlertRule.changeset(valid_rule_attrs(pool, now))
    |> Repo.insert!()
  end

  defp insert_channel!(now) do
    %AlertChannel{}
    |> AlertChannel.changeset(valid_channel_attrs(now))
    |> Repo.insert!()
  end

  defp insert_incident!(pool, now, dedupe_key) do
    %AlertIncident{}
    |> AlertIncident.changeset(valid_incident_attrs(pool, now, dedupe_key))
    |> Repo.insert!()
  end

  defp valid_rule_attrs(pool, now) do
    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: "Pool usable assignment coverage",
      severity: "critical",
      cooldown_minutes: AlertRule.default_cooldown_minutes(),
      state: "active",
      metadata: %{},
      created_at: now,
      updated_at: now
    }
  end

  defp valid_channel_attrs(now) do
    %{
      channel_type: "email",
      display_name: "Operations email",
      state: "active",
      email_to: "alerts@example.com",
      metadata: %{},
      webhook_signing_secret_aad: %{},
      created_at: now,
      updated_at: now
    }
  end

  defp valid_incident_attrs(pool, now, dedupe_key) do
    %{
      dedupe_key: dedupe_key,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      severity: "critical",
      state: "open",
      pool_id: pool.id,
      occurrence_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      safe_evidence_snapshot: %{"usable_assignment_count" => 0},
      suppression_metadata: %{},
      created_at: now,
      updated_at: now
    }
  end

  defp valid_incident_target_attrs(incident, rule, pool, now) do
    %{
      incident_id: incident.id,
      rule_id: rule.id,
      pool_id: pool.id,
      first_matched_at: now,
      last_matched_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    }
  end

  defp valid_delivery_attempt_attrs(incident_id, channel_id, now) do
    %{
      incident_id: incident_id,
      channel_id: channel_id,
      attempt_number: 1,
      max_attempts: AlertDeliveryAttempt.fixed_max_attempts(),
      status: "pending",
      scheduled_at: now,
      retryable: false,
      response_metadata: %{},
      failure_metadata: %{},
      created_at: now,
      updated_at: now
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
