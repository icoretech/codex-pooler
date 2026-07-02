defmodule CodexPooler.Alerts do
  @moduledoc """
  Alert rule, delivery channel, incident, and notification context facade.
  """

  alias CodexPooler.Alerts.Authorization
  alias CodexPooler.Alerts.ChannelManagement
  alias CodexPooler.Alerts.DeliveryScheduling
  alias CodexPooler.Alerts.EmailDelivery
  alias CodexPooler.Alerts.Evaluator
  alias CodexPooler.Alerts.IncidentLifecycle
  alias CodexPooler.Alerts.IncidentNotifications
  alias CodexPooler.Alerts.RuleEvaluation
  alias CodexPooler.Alerts.RuleManagement
  alias CodexPooler.Alerts.WebhookDelivery

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentReceipt,
    AlertRule
  }

  alias CodexPooler.Pools.Pool

  @type access_error :: Authorization.access_error()
  @type rule_result :: RuleManagement.rule_result()
  @type channel_projection :: ChannelManagement.channel_projection()
  @type channel_result :: ChannelManagement.channel_result()
  @type pool_target :: IncidentNotifications.pool_target()
  @type incident_projection :: IncidentNotifications.incident_projection()
  @type incident_result :: IncidentNotifications.incident_result()
  @type evaluation_rule_result :: RuleEvaluation.evaluation_rule_result()
  @type incident_ref :: IncidentNotifications.incident_ref()
  @type incident_delivery_channel :: DeliveryScheduling.incident_delivery_channel()
  @type notification_receipt_result :: IncidentNotifications.notification_receipt_result()

  @spec list_manageable_pools(term()) :: {:ok, [Pool.t()]} | {:error, access_error()}
  defdelegate list_manageable_pools(scope), to: Authorization

  @spec list_rules(term(), keyword()) :: {:ok, [AlertRule.t()]} | {:error, access_error()}
  defdelegate list_rules(scope, opts \\ []), to: RuleManagement

  @spec create_rule(term(), map()) :: rule_result()
  defdelegate create_rule(scope, attrs), to: RuleManagement

  @spec update_rule(term(), AlertRule.t() | Ecto.UUID.t(), map()) :: rule_result()
  defdelegate update_rule(scope, rule, attrs), to: RuleManagement

  @spec delete_rule(term(), AlertRule.t() | Ecto.UUID.t()) :: rule_result()
  defdelegate delete_rule(scope, rule), to: RuleManagement

  @spec list_channels(term(), keyword()) ::
          {:ok, [channel_projection()]} | {:error, access_error()}
  defdelegate list_channels(scope, opts \\ []), to: ChannelManagement

  @spec create_channel(term(), map()) :: channel_result()
  defdelegate create_channel(scope, attrs), to: ChannelManagement

  @spec update_channel(term(), AlertChannel.t() | Ecto.UUID.t(), map()) :: channel_result()
  defdelegate update_channel(scope, channel, attrs), to: ChannelManagement

  @spec delete_channel(term(), AlertChannel.t() | Ecto.UUID.t()) :: channel_result()
  defdelegate delete_channel(scope, channel), to: ChannelManagement

  @spec list_incidents(term(), keyword()) ::
          {:ok, [incident_projection()]} | {:error, access_error()}
  defdelegate list_incidents(scope, opts \\ []), to: IncidentNotifications

  @spec acknowledge_incident(term(), AlertIncident.t() | Ecto.UUID.t()) :: incident_result()
  defdelegate acknowledge_incident(scope, incident_or_id), to: IncidentNotifications

  @spec resolve_incident(term(), AlertIncident.t() | Ecto.UUID.t()) :: incident_result()
  defdelegate resolve_incident(scope, incident_or_id), to: IncidentNotifications

  @spec mark_incident_notification_read(term(), incident_ref()) :: notification_receipt_result()
  defdelegate mark_incident_notification_read(scope, incident_or_id), to: IncidentNotifications

  @spec dismiss_incident_notification(term(), incident_ref()) :: notification_receipt_result()
  defdelegate dismiss_incident_notification(scope, incident_or_id), to: IncidentNotifications

  @spec dismiss_all_visible_incident_notifications(term()) ::
          {:ok, non_neg_integer()} | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate dismiss_all_visible_incident_notifications(scope), to: IncidentNotifications

  @spec incident_notification_read?(AlertIncident.t(), AlertIncidentReceipt.t() | nil) ::
          boolean()
  defdelegate incident_notification_read?(incident, receipt), to: IncidentNotifications

  @spec incident_notification_unread?(AlertIncident.t(), AlertIncidentReceipt.t() | nil) ::
          boolean()
  defdelegate incident_notification_unread?(incident, receipt), to: IncidentNotifications

  @spec incident_notification_dismissed?(AlertIncident.t(), AlertIncidentReceipt.t() | nil) ::
          boolean()
  defdelegate incident_notification_dismissed?(incident, receipt), to: IncidentNotifications

  @spec record_incident_match(IncidentLifecycle.match_attrs() | map()) ::
          IncidentLifecycle.record_result()
  defdelegate record_incident_match(attrs), to: IncidentLifecycle

  @spec record_incident_once(IncidentLifecycle.match_attrs() | map()) ::
          IncidentLifecycle.record_once_result()
  defdelegate record_incident_once(attrs), to: IncidentLifecycle

  @spec safe_projected_metadata_for_admin(map()) :: map()
  defdelegate safe_projected_metadata_for_admin(metadata), to: IncidentNotifications

  @spec clear_incident_condition(IncidentLifecycle.clear_attrs() | map() | String.t()) ::
          IncidentLifecycle.clear_result()
  defdelegate clear_incident_condition(attrs), to: IncidentLifecycle

  @spec list_active_rules_for_evaluation(keyword()) :: [AlertRule.t()]
  defdelegate list_active_rules_for_evaluation(opts \\ []), to: RuleEvaluation

  @spec fetch_rule_for_evaluation(Ecto.UUID.t()) :: evaluation_rule_result()
  defdelegate fetch_rule_for_evaluation(rule_id), to: RuleEvaluation

  @spec evaluate_rule(AlertRule.t(), Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  defdelegate evaluate_rule(rule, opts \\ []), to: RuleEvaluation

  @spec evaluate_active_rules(Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  defdelegate evaluate_active_rules(opts \\ []), to: RuleEvaluation

  @spec deliver_incident_to_channel(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, AlertDeliveryAttempt.t()}
          | {:error, EmailDelivery.delivery_error() | WebhookDelivery.delivery_error()}
  defdelegate deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts \\ []),
    to: DeliveryScheduling

  @spec list_incident_delivery_channels_due(incident_ref(), keyword()) :: [
          incident_delivery_channel()
        ]
  defdelegate list_incident_delivery_channels_due(incident_or_id, opts \\ []),
    to: DeliveryScheduling

  @spec next_delivery_attempt_number(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: pos_integer()
  defdelegate next_delivery_attempt_number(incident_id, channel_id, oban_attempt),
    to: DeliveryScheduling

  @spec access_error(atom(), String.t()) :: access_error()
  defdelegate access_error(code, message), to: Authorization
end
