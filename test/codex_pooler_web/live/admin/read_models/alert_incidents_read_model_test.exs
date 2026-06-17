defmodule CodexPoolerWeb.Admin.AlertIncidentsReadModelTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts.Schemas.{
    AlertDeliveryAttempt,
    AlertRuleChannel
  }

  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AlertIncidentsReadModel

  setup :register_and_log_in_user

  test "load preserves page, row, linked rule, channel, and delivery shapes", %{scope: scope} do
    pool =
      pool_fixture(%{
        slug: "alert-incidents-load-shape-#{unique_suffix()}",
        name: "Load Shape Pool"
      })

    channel = alert_channel_fixture(%{display_name: "Load shape channel"})
    rule = alert_rule_fixture(pool, %{display_name: "Load shape rule"})
    link_rule_channel!(rule, channel)

    raw_prompt = "raw prompt #{unique_suffix()}"
    raw_url = "https://hooks.example.com/alerts/team-secret?token=#{unique_suffix()}"

    incident =
      alert_incident_fixture(
        pool: pool,
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

    assert is_binary(delivery_label)

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
