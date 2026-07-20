defmodule CodexPooler.AuditTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(CodexPooler.Audit.AuditEvent)
    :ok
  end

  test "admin action options include pool, api key, MCP, and alert management events" do
    actions = Audit.supported_actions()

    assert "pool.create" in actions
    assert "pool.update" in actions
    assert "pool.status_update" in actions
    assert "pool.routing_update" in actions
    assert "pool.model_serving_modes_update" in actions
    assert "pool.delete" in actions
    assert "invite.create" in actions
    assert "invite.revoke" in actions
    assert "upstream_account.import" in actions
    assert "upstream_account.pause" in actions
    assert "upstream_account.reactivate" in actions
    assert "upstream_account.delete" in actions
    assert "api_key.create" in actions
    assert "api_key.update" in actions
    assert "api_key.pause" in actions
    assert "api_key.resume" in actions
    assert "api_key.revoke" in actions
    assert "api_key.rotate" in actions
    assert "api_key.delete" in actions
    assert "mcp.operator_enable" in actions
    assert "mcp.operator_disable" in actions
    assert "mcp.token_create" in actions
    assert "mcp.token_update" in actions
    assert "mcp.token_delete" in actions
    assert "alert_rule.create" in actions
    assert "alert_rule.update" in actions
    assert "alert_rule.enable" in actions
    assert "alert_rule.disable" in actions
    assert "alert_rule.delete" in actions
    assert "alert_channel.create" in actions
    assert "alert_channel.update" in actions
    assert "alert_channel.enable" in actions
    assert "alert_channel.disable" in actions
    assert "alert_channel.delete" in actions
    assert "alert_incident.acknowledge" in actions
    assert "alert_incident.resolve" in actions

    assert {"Pool model serving modes updated", "pool.model_serving_modes_update"} in Audit.action_options()

    assert Audit.action_label("pool.model_serving_modes_update") ==
             "Pool model serving modes updated"
  end

  test "records sorted bounded model serving mode transition summaries" do
    pool = pool_fixture()
    %{user: user} = bootstrap_owner_fixture(%{"email" => "mode.audit@example.com"})

    transitions =
      [
        %{
          exposed_model_id: "gpt-zeta",
          from_mode: "auto",
          to_mode: "full",
          credential: %{"access_token" => "must-not-survive"}
        },
        %{
          exposed_model_id: "gpt-alpha",
          from_mode: "lite",
          to_mode: "auto",
          provider_metadata: %{"prompt" => "must-not-survive"}
        }
      ] ++
        Enum.map(1..60, fn index ->
          %{
            exposed_model_id: "overflow-#{String.pad_leading(to_string(index), 2, "0")}",
            from_mode: "auto",
            to_mode: "lite"
          }
        end)

    assert {:ok, event} =
             Audit.record_model_serving_modes_update(user, pool, transitions)

    stored = Repo.get!(CodexPooler.Audit.AuditEvent, event.id)

    assert stored.action == "pool.model_serving_modes_update"
    assert stored.target_type == "pool"
    assert stored.target_id == pool.id
    assert stored.details["changed_count"] == 62
    assert length(stored.details["transitions"]) == 50

    assert Enum.take(stored.details["transitions"], 2) == [
             %{
               "exposed_model_id" => "gpt-alpha",
               "from_mode" => "lite",
               "to_mode" => "auto"
             },
             %{
               "exposed_model_id" => "gpt-zeta",
               "from_mode" => "auto",
               "to_mode" => "full"
             }
           ]

    refute inspect(stored.details) =~ "must-not-survive"
    refute inspect(stored.details) =~ "credential"
    refute inspect(stored.details) =~ "provider_metadata"
  end

  test "model serving mode no-op writes no audit and emits no pool event" do
    pool = pool_fixture()
    %{user: user} = bootstrap_owner_fixture(%{"email" => "mode.noop@example.com"})
    assert :ok = Events.subscribe_pool(pool.id)

    audit_count = Repo.aggregate(CodexPooler.Audit.AuditEvent, :count)

    assert :noop = Audit.record_model_serving_modes_update(user, pool, [])
    assert :noop = Events.broadcast_model_serving_modes_updated_after_commit(pool, 0)
    assert Repo.aggregate(CodexPooler.Audit.AuditEvent, :count) == audit_count
    refute_received {Events, _event}
  end

  test "model serving mode audit retains bounded canonical space and Unicode identifiers" do
    # Given
    pool = pool_fixture()
    %{user: user} = bootstrap_owner_fixture(%{"email" => "mode.canonical@example.com"})

    transitions = [
      %{exposed_model_id: "gpt alpha", from_mode: "auto", to_mode: "lite"},
      %{exposed_model_id: "gpt β", from_mode: "lite", to_mode: "full"},
      %{exposed_model_id: "provider@example.com", from_mode: "auto", to_mode: "full"},
      %{
        exposed_model_id: String.duplicate("a", 256),
        from_mode: "auto",
        to_mode: "full"
      }
    ]

    # When
    assert {:ok, event} = Audit.record_model_serving_modes_update(user, pool, transitions)

    # Then
    assert %{
             "changed_count" => 3,
             "transitions" => [
               %{
                 "exposed_model_id" => "gpt alpha",
                 "from_mode" => "auto",
                 "to_mode" => "lite"
               },
               %{
                 "exposed_model_id" => "gpt β",
                 "from_mode" => "lite",
                 "to_mode" => "full"
               },
               %{
                 "exposed_model_id" => "provider@example.com",
                 "from_mode" => "auto",
                 "to_mode" => "full"
               }
             ]
           } = Repo.get!(CodexPooler.Audit.AuditEvent, event.id).details
  end

  test "model serving mode audit helper drops same-mode, oversized, and noncanonical transitions" do
    pool = pool_fixture()
    %{user: user} = bootstrap_owner_fixture(%{"email" => "mode.invalid@example.com"})
    audit_count = Repo.aggregate(CodexPooler.Audit.AuditEvent, :count)

    for exposed_model_id <- [
          "",
          String.duplicate("a", 256),
          "GPT-5",
          " gpt-5",
          "gpt-5 "
        ] do
      assert :noop =
               Audit.record_model_serving_modes_update(user, pool, [
                 %{
                   exposed_model_id: exposed_model_id,
                   from_mode: "auto",
                   to_mode: "lite"
                 }
               ])
    end

    assert :noop =
             Audit.record_model_serving_modes_update(user, pool, [
               %{exposed_model_id: "gpt-5", from_mode: "lite", to_mode: "lite"},
               %{exposed_model_id: "gpt-5", from_mode: "auto", to_mode: "auto"}
             ])

    assert Repo.aggregate(CodexPooler.Audit.AuditEvent, :count) == audit_count
  end

  test "model serving mode event helper uses the ordinary pool_updated shape" do
    pool = pool_fixture()
    assert :ok = Events.subscribe_pool(pool.id)

    task =
      Task.async(fn ->
        Events.broadcast_model_serving_modes_updated_after_commit(pool, 2)
      end)

    assert {:ok, event} = Task.await(task)
    assert_receive {Events, ^event}
    assert event.reason == "pool_updated"
    assert event.topics == ["pools"]
    assert event.payload == %{"changed" => ["model_serving_modes"], "changed_count" => 2}
  end

  test "audit event details redact credentials and prompt content" do
    pool = pool_fixture()

    assert {:ok, event} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "access.denied",
               target_type: "api_key",
               outcome: "failure",
               correlation_id: "corr-audit-redaction",
               details: %{
                 "authorization" => "Bearer token-value",
                 "api_key" => "sk-cxp-abcdef123456-secret",
                 "upstream_token" => "upstream-token",
                 "cookie" => "a=b",
                 "prompt" => "raw prompt",
                 "nested" => %{
                   "credentials" => %{"refresh_token" => "nested-refresh-token"}
                 },
                 "safe" => "visible"
               }
             })

    stored = Repo.get!(CodexPooler.Audit.AuditEvent, event.id)
    assert stored.details["authorization"] == "[REDACTED]"
    assert stored.details["api_key"] == "[REDACTED]"
    assert stored.details["upstream_token"] == "[REDACTED]"
    assert stored.details["cookie"] == "[REDACTED]"
    assert stored.details["prompt"] == "[REDACTED]"
    assert stored.details["nested"]["credentials"]["refresh_token"] == "[REDACTED]"
    assert stored.details["safe"] == "visible"

    assert %{items: [listed]} = Audit.list_events(pool)
    assert listed.details["authorization"] == "[REDACTED]"
    refute inspect(listed) =~ "raw prompt"
    refute inspect(listed) =~ "token-value"
    refute inspect(listed) =~ "nested-refresh-token"
  end

  test "lists global and pool audit events with structured filters" do
    first_pool = pool_fixture(%{slug: "audit-first", name: "Audit First"})
    second_pool = pool_fixture(%{slug: "audit-second", name: "Audit Second"})
    %{user: user} = bootstrap_owner_fixture(%{"email" => "audit.actor@example.com"})

    assert {:ok, global_event} =
             Audit.record_user_event(user, %{
               action: "operator.update",
               target_type: "user",
               target_id: user.id,
               correlation_id: "global-correlation",
               details: %{"safe" => "visible"}
             })

    assert {:ok, first_event} =
             Audit.record_system_event(%{
               pool_id: first_pool.id,
               action: "access.denied",
               target_type: "api_key",
               outcome: "failure",
               correlation_id: "first-correlation",
               details: %{"status" => "failed"}
             })

    assert {:ok, second_event} =
             Audit.record_system_event(%{
               pool_id: second_pool.id,
               action: "upstream.quota_exhausted",
               target_type: "upstream_identity",
               correlation_id: "second-correlation",
               details: %{}
             })

    assert %{items: all_items, total: total} = Audit.list_events(nil)
    assert total == 4
    assert Enum.any?(all_items, &(&1.id == global_event.id))
    assert Enum.any?(all_items, &(&1.id == first_event.id))
    assert Enum.any?(all_items, &(&1.id == second_event.id))

    assert %{items: [listed_first]} = Audit.list_events(first_pool)
    assert listed_first.id == first_event.id
    assert listed_first.pool_name == "Audit First"
    assert listed_first.pool_slug == "audit-first"

    assert %{items: global_items} = Audit.list_events(nil, filters: [actor: "audit.actor"])
    listed_global = Enum.find(global_items, &(&1.id == global_event.id))
    assert listed_global.id == global_event.id

    assert %{items: [listed_failure]} = Audit.list_events(nil, filters: [outcome: "failure"])
    assert listed_failure.id == first_event.id

    assert %{items: [listed_correlation]} =
             Audit.list_events(nil, filters: [request: "second-correlation"])

    assert listed_correlation.id == second_event.id
  end

  test "does not record runtime request or file events in audit_events" do
    pool = pool_fixture(%{slug: "request-audit", name: "Request Audit"})

    assert {:error, :runtime_events_not_recorded} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "request.finalized",
               target_type: "request",
               target_id: Ecto.UUID.generate(),
               outcome: "failure",
               details: %{"status" => "failed"}
             })

    assert {:error, :runtime_events_not_recorded} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "file.created",
               target_type: "codex_file",
               target_id: Ecto.UUID.generate(),
               details: %{"status" => "pending_upload"}
             })

    assert %{items: []} = Audit.list_events(pool)
  end
end
