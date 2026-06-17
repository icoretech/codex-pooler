defmodule CodexPooler.Admin.AlertIncidentsReadModel do
  @moduledoc """
  Durable alert incident relationship projections for admin surfaces.

  This module owns the cross-domain joins from visible incidents to their
  linked alert rules, visible delivery channels, and recent delivery attempts.
  Returned projections are metadata-only and scoped by `CodexPooler.Accounts.Scope`.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Repo

  @delivery_attempts_per_incident 3
  @safe_delivery_metadata_keys [
    "delivery_adapter",
    "channel_type",
    "endpoint_host",
    "endpoint_path_prefix",
    "endpoint_fingerprint",
    "recipient_domain",
    "payload_bytes",
    "response_status_code",
    "reason_code",
    "delivery_status",
    "failure_code",
    "failure_message",
    "retryable"
  ]

  @type incident_filters :: %{
          optional(:pool_id) => Ecto.UUID.t() | nil,
          optional(:state) => String.t() | nil
        }
  @type linked_channel :: %{
          required(:label) => String.t(),
          required(:value) => Ecto.UUID.t(),
          required(:channel_type) => String.t() | nil
        }
  @type linked_rule :: %{
          required(:label) => String.t(),
          required(:value) => Ecto.UUID.t(),
          required(:channels) => [linked_channel()]
        }
  @type delivery_attempt :: %{
          required(:id) => Ecto.UUID.t(),
          required(:incident_id) => Ecto.UUID.t(),
          required(:channel_id) => Ecto.UUID.t(),
          required(:channel_label) => String.t(),
          required(:status) => String.t(),
          required(:attempt_number) => pos_integer(),
          required(:max_attempts) => pos_integer(),
          required(:attempted_at) => DateTime.t() | nil,
          required(:completed_at) => DateTime.t() | nil,
          required(:response_status_code) => integer() | nil,
          required(:retryable) => boolean(),
          required(:failure_code) => String.t() | nil,
          required(:failure_message) => String.t() | nil,
          required(:response_metadata) => map(),
          required(:failure_metadata) => map()
        }
  @type delivery_summary :: %{
          required(:total_count) => non_neg_integer(),
          required(:sent_count) => non_neg_integer(),
          required(:attention_count) => non_neg_integer(),
          required(:latest_status) => String.t() | nil,
          required(:attempts) => [delivery_attempt()]
        }
  @type incident_relationship_projections :: %{
          required(:linked_rules_by_incident) => %{
            optional(Ecto.UUID.t()) => [linked_rule()]
          },
          required(:delivery_summaries_by_incident) => %{
            optional(Ecto.UUID.t()) => delivery_summary()
          }
        }

  @spec list_incidents(Scope.t(), incident_filters()) ::
          {:ok, [Alerts.incident_projection()]} | {:error, Alerts.access_error()}
  def list_incidents(%Scope{} = scope, filters) when is_map(filters) do
    opts =
      []
      |> maybe_put_opt(:pool_id, Map.get(filters, :pool_id))
      |> maybe_put_opt(:state, Map.get(filters, :state))

    Alerts.list_incidents(scope, opts)
  end

  @spec incident_relationship_projections(Scope.t(), [Alerts.incident_projection()]) ::
          incident_relationship_projections()
  def incident_relationship_projections(%Scope{} = scope, incidents) when is_list(incidents) do
    incident_ids = incident_ids(incidents)

    with [_ | _] <- incident_ids,
         {:ok, channels} <- Alerts.list_channels(scope),
         {:ok, visible_pool_ids} <- visible_pool_ids(scope, incidents) do
      visible_channel_ids = Enum.map(channels, & &1.id)

      %{
        linked_rules_by_incident:
          linked_rules_by_incident(incident_ids, visible_pool_ids, visible_channel_ids),
        delivery_summaries_by_incident: delivery_summaries(incident_ids, channels)
      }
    else
      _reason -> empty_relationship_projections()
    end
  end

  def incident_relationship_projections(_scope, _incidents), do: empty_relationship_projections()

  defp visible_pool_ids(scope, incidents) do
    case Alerts.list_manageable_pools(scope) do
      {:ok, pools} ->
        manageable_pool_ids = pools |> Enum.map(& &1.id) |> MapSet.new()

        visible_pool_ids =
          incidents
          |> Enum.flat_map(&incident_visible_pool_ids/1)
          |> Enum.uniq()
          |> Enum.filter(&MapSet.member?(manageable_pool_ids, &1))

        {:ok, visible_pool_ids}

      {:error, _reason} = error ->
        error
    end
  end

  defp incident_visible_pool_ids(incident) do
    root_pool_ids = if is_binary(Map.get(incident, :pool_id)), do: [incident.pool_id], else: []

    impacted_pool_ids =
      incident
      |> Map.get(:impacted_pools, [])
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_binary/1)

    root_pool_ids ++ impacted_pool_ids
  end

  defp linked_rules_by_incident(_incident_ids, [], _visible_channel_ids), do: %{}

  defp linked_rules_by_incident(incident_ids, visible_pool_ids, visible_channel_ids) do
    Repo.all(
      from target in AlertIncidentTarget,
        join: rule in AlertRule,
        on: rule.id == target.rule_id,
        left_join: rule_channel in AlertRuleChannel,
        on: rule_channel.alert_rule_id == rule.id,
        left_join: channel in AlertChannel,
        on: channel.id == rule_channel.alert_channel_id and channel.id in ^visible_channel_ids,
        where: target.incident_id in ^incident_ids and target.pool_id in ^visible_pool_ids,
        order_by: [
          asc: rule.display_name,
          asc: rule.id,
          asc: channel.display_name,
          asc: channel.id
        ],
        select: %{
          incident_id: target.incident_id,
          rule_id: rule.id,
          rule_label: rule.display_name,
          channel_id: channel.id,
          channel_label: channel.display_name,
          channel_type: channel.channel_type
        }
    )
    |> Enum.group_by(& &1.incident_id)
    |> Map.new(fn {incident_id, rows} -> {incident_id, linked_rule_projections(rows)} end)
  end

  defp linked_rule_projections(rows) do
    rows
    |> Enum.group_by(& &1.rule_id)
    |> Map.values()
    |> Enum.map(fn [row | _rows] = rows ->
      %{
        label: row.rule_label,
        value: row.rule_id,
        channels: linked_channel_projections(rows)
      }
    end)
  end

  defp linked_channel_projections(rows) do
    rows
    |> Enum.reject(&is_nil(&1.channel_id))
    |> Enum.uniq_by(& &1.channel_id)
    |> Enum.map(fn row ->
      %{label: row.channel_label, value: row.channel_id, channel_type: row.channel_type}
    end)
  end

  defp delivery_summaries(_incident_ids, []), do: %{}

  defp delivery_summaries(incident_ids, channels) do
    visible_channel_ids = Enum.map(channels, & &1.id)
    channel_lookup = Map.new(channels, &{&1.id, &1})

    incident_ids
    |> delivery_attempt_rows(visible_channel_ids)
    |> Enum.group_by(& &1.incident_id)
    |> Map.new(fn {incident_id, attempts} ->
      {incident_id, delivery_summary(attempts, channel_lookup)}
    end)
  end

  defp delivery_attempt_rows(_incident_ids, []), do: []

  defp delivery_attempt_rows(incident_ids, visible_channel_ids) do
    ranked_query =
      from attempt in AlertDeliveryAttempt,
        where:
          attempt.incident_id in ^incident_ids and attempt.channel_id in ^visible_channel_ids,
        windows: [
          incident_attempts: [
            partition_by: attempt.incident_id,
            order_by: [
              desc: fragment("coalesce(?, ?)", attempt.attempted_at, attempt.created_at),
              desc: attempt.id
            ]
          ]
        ],
        select: %{
          id: attempt.id,
          incident_id: attempt.incident_id,
          channel_id: attempt.channel_id,
          status: attempt.status,
          attempt_number: attempt.attempt_number,
          max_attempts: attempt.max_attempts,
          attempted_at: attempt.attempted_at,
          completed_at: attempt.completed_at,
          created_at: attempt.created_at,
          response_status_code: attempt.response_status_code,
          retryable: attempt.retryable,
          failure_code: attempt.failure_code,
          failure_message: attempt.failure_message,
          response_metadata: attempt.response_metadata,
          failure_metadata: attempt.failure_metadata,
          rank: over(row_number(), :incident_attempts)
        }

    Repo.all(
      from attempt in subquery(ranked_query),
        where: attempt.rank <= ^@delivery_attempts_per_incident,
        order_by: [
          asc: attempt.incident_id,
          desc: fragment("coalesce(?, ?)", attempt.attempted_at, attempt.created_at),
          desc: attempt.id
        ]
    )
  end

  defp delivery_summary(attempts, channel_lookup) do
    sent_count = Enum.count(attempts, &(&1.status == AlertDeliveryAttempt.sent_status()))
    attention_count = Enum.count(attempts, &(&1.status in ["retryable", "failed"]))
    latest_status = attempts |> List.first() |> then(&(&1 && &1.status))

    %{
      total_count: length(attempts),
      sent_count: sent_count,
      attention_count: attention_count,
      latest_status: latest_status,
      attempts: Enum.map(attempts, &delivery_attempt(&1, channel_lookup))
    }
  end

  defp delivery_attempt(attempt, channel_lookup) do
    %{
      id: attempt.id,
      incident_id: attempt.incident_id,
      channel_id: attempt.channel_id,
      channel_label: delivery_channel_label(Map.get(channel_lookup, attempt.channel_id)),
      status: attempt.status,
      attempt_number: attempt.attempt_number,
      max_attempts: attempt.max_attempts,
      attempted_at: attempt.attempted_at,
      completed_at: attempt.completed_at,
      response_status_code: attempt.response_status_code,
      retryable: attempt.retryable,
      failure_code: safe_optional_text(attempt.failure_code),
      failure_message: safe_optional_text(attempt.failure_message),
      response_metadata: safe_attempt_metadata(attempt.response_metadata),
      failure_metadata: safe_attempt_metadata(attempt.failure_metadata)
    }
  end

  defp delivery_channel_label(%{display_name: label}) when is_binary(label) and label != "",
    do: label

  defp delivery_channel_label(_channel), do: "Visible channel"

  defp safe_attempt_metadata(%{} = metadata) do
    metadata
    |> Alerts.safe_projected_metadata_for_admin()
    |> Map.take(@safe_delivery_metadata_keys)
  end

  defp safe_attempt_metadata(_metadata), do: %{}

  defp safe_optional_text(nil), do: nil
  defp safe_optional_text(value) when is_binary(value), do: safe_text(value)
  defp safe_optional_text(value), do: value |> to_string() |> safe_text()

  defp safe_text(value) do
    value
    |> String.replace(~r{https?://[^\s<>"]+}i, "[redacted url]")
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "Bearer [redacted]")
    |> String.replace(secret_pair_regex(), "[redacted]")
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.trim()
    |> truncate_detail_value()
  end

  defp secret_pair_regex do
    ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token|dedupe[_-]?key)\b\s*[:=]\s*[^,;\s]+/
  end

  defp truncate_detail_value(value) when byte_size(value) > 180,
    do: value |> binary_part(0, 180) |> String.trim() |> Kernel.<>("...")

  defp truncate_detail_value(value), do: value

  defp incident_ids(incidents) do
    incidents
    |> Enum.map(&Map.get(&1, :id))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp empty_relationship_projections do
    %{linked_rules_by_incident: %{}, delivery_summaries_by_incident: %{}}
  end
end
