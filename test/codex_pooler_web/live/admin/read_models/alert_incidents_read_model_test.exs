defmodule CodexPoolerWeb.Admin.AlertIncidentsReadModelTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures

  require Phoenix.LiveViewTest

  alias CodexPooler.Accounts.Scope

  alias CodexPooler.Alerts.Schemas.{
    AlertDeliveryAttempt,
    AlertRuleChannel
  }

  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AlertIncidentsReadModel
  alias CodexPoolerWeb.Admin.AlertsPageComponents.Incidents
  alias Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "Chinese deleted-channel fallback does not translate a channel with the same name", %{scope: scope} do
    pool = pool_fixture(%{slug: "alert-channel-locale-#{unique_suffix()}"})
    rule = alert_rule_fixture(pool)
    channel = alert_channel_fixture(%{display_name: "Deleted channel"})
    incident = alert_incident_fixture(pool: pool)
    alert_incident_target_fixture(incident, rule, pool)
    named_attempt = delivery_attempt_fixture(incident, channel, status: AlertDeliveryAttempt.sent_status())
    missing_attempt = delivery_attempt_fixture(incident, channel, status: AlertDeliveryAttempt.sent_status(), attempt_number: 2)

    missing_attempt
    |> AlertDeliveryAttempt.changeset(%{channel_id: nil, channel_display_name: nil})
    |> Repo.update!()

    Gettext.put_locale("zh_CN")
    page = AlertIncidentsReadModel.load(scope, %{})
    [row] = page.incidents
    labels = Map.new(row.delivery_summary.attempts, &{&1.id, &1.channel_label})

    assert labels[named_attempt.id] == "Deleted channel"
    assert labels[missing_attempt.id] == "已删除的渠道"

    html =
      LiveViewTest.render_component(&Incidents.incident_delivery_summary/1,
        incident: row,
        prefix: "locale-channel"
      )

    document = LazyHTML.from_fragment(html)
    assert document |> LazyHTML.query("#locale-channel-#{incident.id}-delivery-attempt-#{named_attempt.id} [data-role='incident-delivery-attempt-channel']") |> LazyHTML.text() |> String.trim() == "Deleted channel"
    assert document |> LazyHTML.query("#locale-channel-#{incident.id}-delivery-attempt-#{missing_attempt.id} [data-role='incident-delivery-attempt-channel']") |> LazyHTML.text() |> String.trim() == "已删除的渠道"
  end

  test "load preserves page, row, linked rule, channel, and delivery shapes", %{scope: scope} do
    pool =
      pool_fixture(%{
        slug: "alert-incidents-load-shape-#{unique_suffix()}",
        name: "Load Shape Pool"
      })

    channel = alert_channel_fixture(%{display_name: "Load shape channel"})
    rule = alert_rule_fixture(pool, %{display_name: "Load shape rule"})
    link_rule_channel!(rule, channel)

    upstream_label = "Load shape upstream #{unique_suffix()}"
    upstream_identity = upstream_identity_fixture(%{account_label: upstream_label})

    raw_prompt = "raw prompt #{unique_suffix()}"
    raw_url = "https://hooks.example.com/alerts/team-secret?token=#{unique_suffix()}"

    incident =
      alert_incident_fixture(
        pool: pool,
        upstream_identity: upstream_identity,
        severity: "critical",
        safe_evidence_snapshot: %{"prompt" => raw_prompt}
      )

    alert_incident_target_fixture(incident, rule, pool)

    attempt =
      delivery_attempt_fixture(incident, channel,
        status: AlertDeliveryAttempt.sent_status(),
        response_status_code: 202,
        response_metadata: %{
          "delivery_adapter" => "webhook",
          "channel_type" => "webhook",
          "endpoint_host" => "hooks.example.com",
          "endpoint_url" => raw_url,
          "request_body" => raw_prompt
        }
      )

    page =
      AlertIncidentsReadModel.load(scope, %{
        "pool_id" => pool.id,
        "severity" => "critical",
        "state" => "open",
        "rule_id" => rule.id,
        "channel_id" => channel.id
      })

    assert page |> Map.keys() |> MapSet.new() ==
             MapSet.new([
               :manageable_pools,
               :pool_lookup,
               :rules,
               :channels,
               :incidents,
               :filter_form,
               :filter_values,
               :filter_errors,
               :pool_filter_options,
               :severity_filter_options,
               :state_filter_options,
               :rule_filter_options,
               :channel_filter_options,
               :total_count,
               :page_size
             ])

    assert page.filter_values == %{
             "incident_id" => "",
             "pool_id" => pool.id,
             "severity" => "critical",
             "state" => "open",
             "rule_id" => rule.id,
             "channel_id" => channel.id
           }

    assert page.filter_errors == []
    assert page.total_count == 1
    assert page.page_size == 50
    assert [row] = page.incidents

    assert row |> Map.keys() |> MapSet.new() ==
             MapSet.new([
               :id,
               :scope_type,
               :rule_kind,
               :rule_kind_label,
               :severity,
               :severity_label,
               :state,
               :state_label,
               :reason_title,
               :reason_detail,
               :upstream_account_label,
               :occurrence_count,
               :first_seen_at,
               :last_seen_at,
               :resolved_at,
               :impacted_pools,
               :visible_impacted_pool_count,
               :hidden_impacted_pool_count,
               :linked_rules,
               :linked_channels,
               :delivery_summary
             ])

    assert row.id == incident.id
    assert row.upstream_account_label == upstream_label

    assert [%{label: "Load shape rule", value: rule_id, icon: "hero-bell-alert"} = linked_rule] =
             row.linked_rules

    assert rule_id == rule.id

    assert [%{label: "Load shape channel", value: channel_id, icon: "hero-envelope"}] =
             linked_rule.channels

    assert channel_id == channel.id
    assert row.linked_channels == linked_rule.channels

    assert %{
             total_count: 1,
             sent_count: 1,
             attention_count: 0,
             latest_status: "sent",
             label: delivery_label,
             attempts: [delivery_attempt]
           } = row.delivery_summary

    assert delivery_label == "1 attempt · 1 sent · latest sent"

    assert delivery_attempt.id == attempt.id
    assert delivery_attempt.channel_id == channel.id
    assert delivery_attempt.channel_label == "Load shape channel"
    assert delivery_attempt.status_label == "sent"

    assert Enum.any?(
             delivery_attempt.details,
             &(&1 == %{label: "Endpoint host", value: "hooks.example.com"})
           )

    refute inspect(page) =~ raw_prompt
    refute inspect(page) =~ raw_url
  end

  test "delivery summaries preserve attention and empty labels", %{scope: scope} do
    pool = pool_fixture(%{slug: "alert-incidents-delivery-labels-#{unique_suffix()}"})
    rule = alert_rule_fixture(pool)
    channel = alert_channel_fixture(%{display_name: "Delivery labels channel"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attention_incident =
      alert_incident_fixture(pool: pool, last_seen_at: DateTime.add(now, 1, :second))

    empty_incident =
      alert_incident_fixture(pool: pool, last_seen_at: now)

    alert_incident_target_fixture(attention_incident, rule, pool)
    alert_incident_target_fixture(empty_incident, rule, pool)

    delivery_attempt_fixture(attention_incident, channel, status: AlertDeliveryAttempt.failed_status())

    labels =
      AlertIncidentsReadModel.load(scope, %{})
      |> Map.fetch!(:incidents)
      |> Map.new(&{&1.id, &1.delivery_summary.label})

    assert labels[attention_incident.id] == "1 attempt · 0 sent · 1 needs attention · latest failed"
    assert labels[empty_incident.id] == "No delivery attempts"
  end

  # The incident detail names the assignment states the evaluation recorded,
  # bounded to the alert vocabulary, so an incident caused by a model the Pool
  # does not serve says so in words.
  test "a pool incident detail names its bounded assignment state counts", %{scope: scope} do
    pool = pool_fixture(%{slug: "alert-incidents-states-#{unique_suffix()}", name: "State Count Pool"})

    rule = alert_rule_fixture(pool, %{display_name: "State count rule"})

    incident =
      alert_incident_fixture(
        pool: pool,
        rule_kind: "pool_no_usable_assignments",
        safe_evidence_snapshot: %{"state_counts" => %{"model_not_served" => 2, "raw prompt state" => 4}}
      )

    alert_incident_target_fixture(incident, rule, pool)

    assert [row] = AlertIncidentsReadModel.load(scope, %{"pool_id" => pool.id}).incidents
    assert row.reason_detail =~ "Assignment states: 2 model not served."
    refute row.reason_detail =~ "raw prompt"
  end

  test "query_params keeps incident tab and drops blank filters" do
    assert AlertIncidentsReadModel.query_params(%{
             "pool_id" => "pool-1",
             "severity" => " ",
             "state" => "open",
             "rule_id" => nil,
             "channel_id" => "channel-1",
             "ignored" => "value"
           }) == %{
             "tab" => "incidents",
             "pool_id" => "pool-1",
             "state" => "open",
             "channel_id" => "channel-1"
           }
  end

  test "incident id selects an older incident before the bounded page window", %{scope: scope} do
    pool = pool_fixture()
    rule = alert_rule_fixture(pool)
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    incident = alert_incident_fixture(pool: pool, state: "resolved", resolved_at: observed_at, last_seen_at: DateTime.add(observed_at, -60))
    alert_incident_target_fixture(incident, rule, pool)
    insert_incident_history!(pool, rule, 55)

    page = AlertIncidentsReadModel.load(scope, %{"incident_id" => incident.id})
    assert page.filter_errors == []
    assert page.total_count == 1
    assert page.page_size == 50
    assert [%{id: id, state: "resolved"}] = page.incidents
    assert id == incident.id
    assert page.filter_values["incident_id"] == incident.id
    assert AlertIncidentsReadModel.query_params(page.filter_values) == %{"tab" => "incidents", "incident_id" => incident.id}

    assert %{incidents: [], total_count: 0} = AlertIncidentsReadModel.load(scope, %{"incident_id" => incident.id, "state" => "open"})

    for params <- [%{}, %{"incident_id" => ""}, %{"incident_id" => " "}] do
      assert %{incidents: rows, total_count: 56, page_size: 50} = AlertIncidentsReadModel.load(scope, params)
      assert length(rows) == 50
      refute Enum.any?(rows, &(&1.id == incident.id))
    end
  end

  test "incident id keeps hidden and unknown incidents outside the viewer scope", %{scope: scope} do
    visible_pool = pool_fixture()
    hidden_pool = pool_fixture()
    visible = alert_incident_fixture(pool: visible_pool)
    hidden = alert_incident_fixture(pool: hidden_pool)
    %{user: admin} = operator_fixture(scope, %{"email" => unique_user_email(), "role" => "instance_admin"})
    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: scope.user.id)
    admin_scope = Scope.for_user(admin)

    assert [%{id: visible_id}] = AlertIncidentsReadModel.load(admin_scope, %{"incident_id" => visible.id}).incidents
    assert visible_id == visible.id

    for incident_id <- [hidden.id, Ecto.UUID.generate()] do
      assert %{incidents: [], total_count: 0, filter_errors: []} = AlertIncidentsReadModel.load(admin_scope, %{"incident_id" => incident_id})
    end
  end

  test "malformed incident ids fail closed instead of loading the default window", %{scope: scope} do
    alert_incident_fixture(pool: pool_fixture())

    for incident_id <- ["invalid", [], %{}, 123] do
      assert %{incidents: [], total_count: 0, filter_errors: [%{field: :incident_id}]} = AlertIncidentsReadModel.load(scope, %{"incident_id" => incident_id})
    end
  end

  @tag slow: "compares real database query and result-row budgets with 2000 incident/target pairs"
  test "incident page queries stay bounded as history grows", %{scope: scope} do
    pool = pool_fixture()
    rule = alert_rule_fixture(pool)
    handler_id = "incident-page-queries-#{unique_suffix()}"
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.capture_page_query/4, self())

    measurements =
      for {additional, total} <- [{60, 60}, {140, 200}, {1800, 2000}] do
        insert_incident_history!(pool, rule, additional)

        drain_page_queries()
        page = AlertIncidentsReadModel.load(scope, %{"pool_id" => pool.id})
        queries = drain_page_queries()
        assert length(page.incidents) == 50
        assert page.total_count == total
        incident_rows = for {"alert_incidents", rows} <- queries, do: rows
        target_rows = for {"alert_incident_targets", rows} <- queries, do: rows
        assert Enum.max(incident_rows) == 50
        assert target_rows == [50, 50]
        %{stored: total, queries: length(queries), target_queries: length(target_rows)}
      end

    assert Enum.uniq_by(measurements, & &1.queries) |> length() == 1, inspect(measurements)
    assert Enum.all?(measurements, &(&1.target_queries == 2)), inspect(measurements)
  end

  test "filters find older matches before limiting and count all matches", %{scope: scope} do
    pool = pool_fixture()
    first_rule = alert_rule_fixture(pool)
    channel_rule = alert_rule_fixture(pool)
    channel = alert_channel_fixture()
    link_rule_channel!(channel_rule, channel)
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    matching =
      for _ <- 1..51 do
        incident = alert_incident_fixture(pool: pool, severity: "warning", last_seen_at: DateTime.add(observed_at, -60))
        alert_incident_target_fixture(incident, first_rule, pool)
        alert_incident_target_fixture(incident, channel_rule, pool, resolved_at: observed_at)
        incident
      end

    for _ <- 1..60, do: alert_incident_fixture(pool: pool, severity: "critical", last_seen_at: observed_at)
    expected_ids = matching |> Enum.sort_by(& &1.id, :desc) |> Enum.take(50) |> Enum.map(& &1.id)

    for filters <- [
          %{"severity" => "warning"},
          %{"rule_id" => first_rule.id},
          %{"channel_id" => channel.id},
          %{"severity" => "warning", "state" => "open", "rule_id" => first_rule.id, "channel_id" => channel.id}
        ] do
      page = AlertIncidentsReadModel.load(scope, Map.put(filters, "pool_id", pool.id))
      assert page.filter_errors == []
      assert page.total_count == 51
      assert Enum.map(page.incidents, & &1.id) == expected_ids
      assert Enum.all?(page.incidents, &(&1.visible_impacted_pool_count == 1))
    end

    for {key, value} <- [{"severity", "unknown"}, {"state", "unknown"}, {"rule_id", Ecto.UUID.generate()}, {"channel_id", "invalid"}, {"pool_id", Ecto.UUID.generate()}] do
      page = AlertIncidentsReadModel.load(scope, %{key => value})
      assert page.filter_errors != []
      assert page.incidents == []
      assert page.total_count == 0
    end
  end

  defp insert_incident_history!(pool, rule, count) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    incidents =
      for _ <- 1..count do
        id = Ecto.UUID.generate()
        %{id: id, dedupe_key: "alert:history:#{id}", scope_type: "pool", rule_kind: "pool_no_usable_assignments", severity: "critical", state: "open", pool_id: pool.id, occurrence_count: 1, first_seen_at: observed_at, last_seen_at: observed_at, safe_evidence_snapshot: %{}, suppression_metadata: %{}, created_at: observed_at, updated_at: observed_at}
      end

    targets =
      Enum.map(incidents, fn incident ->
        %{id: Ecto.UUID.generate(), incident_id: incident.id, rule_id: rule.id, pool_id: pool.id, first_matched_at: observed_at, last_matched_at: observed_at, metadata: %{}, created_at: observed_at, updated_at: observed_at}
      end)

    assert {^count, nil} = Repo.insert_all(CodexPooler.Alerts.Schemas.AlertIncident, incidents)
    assert {^count, nil} = Repo.insert_all(CodexPooler.Alerts.Schemas.AlertIncidentTarget, targets)
  end

  @doc false
  def capture_page_query(_event, _measurements, metadata, emitter) do
    if self() == emitter do
      {:ok, %{num_rows: row_count}} = metadata.result
      send(emitter, {:incident_page_query, {metadata.source, row_count}})
    end
  end

  defp drain_page_queries(acc \\ []) do
    receive do
      {:incident_page_query, source} -> drain_page_queries([source | acc])
    after
      0 -> acc
    end
  end

  defp link_rule_channel!(rule, channel) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AlertRuleChannel{}
    |> AlertRuleChannel.changeset(%{
      alert_rule_id: rule.id,
      alert_channel_id: channel.id,
      created_at: now
    })
    |> Repo.insert!()
  end

  defp delivery_attempt_fixture(incident, channel, attrs) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AlertDeliveryAttempt{}
    |> AlertDeliveryAttempt.changeset(%{
      incident_id: incident.id,
      channel_id: channel.id,
      attempt_number: Map.get(attrs, :attempt_number, 1),
      max_attempts: AlertDeliveryAttempt.fixed_max_attempts(),
      status: Map.fetch!(attrs, :status),
      scheduled_at: Map.get(attrs, :scheduled_at, now),
      attempted_at: Map.get(attrs, :attempted_at, now),
      completed_at: Map.get(attrs, :completed_at, now),
      response_status_code: Map.get(attrs, :response_status_code),
      retryable: Map.get(attrs, :retryable, false),
      failure_code: Map.get(attrs, :failure_code),
      failure_message: Map.get(attrs, :failure_message),
      response_metadata: Map.get(attrs, :response_metadata, %{}),
      failure_metadata: Map.get(attrs, :failure_metadata, %{}),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp unique_suffix, do: System.unique_integer([:positive])
end
