defmodule CodexPooler.Admin.UpstreamCockpitMetrics do
  @moduledoc """
  Scoped admin-domain metrics for upstream cockpit request, quota, and pool activity.
  """

  alias CodexPooler.Accounts.Scope

  alias CodexPooler.Admin.UpstreamCockpitMetrics.{
    Common,
    PoolContribution,
    QuotaHealth,
    RequestHealth
  }

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type assignment_summary :: %{
          required(:id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_label) => String.t(),
          required(:assignment_label) => String.t(),
          required(:status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t(),
          optional(:identity_status) => String.t()
        }
  @type quota_health_item :: %{
          required(:assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_label) => String.t(),
          required(:assignment_label) => String.t(),
          required(:state) => String.t(),
          required(:state_label) => String.t(),
          required(:routing_usable?) => boolean(),
          required(:routing_readiness_state) => String.t(),
          required(:routing_readiness_label) => String.t(),
          required(:routing_readiness_reason) => String.t(),
          required(:routing_readiness_reason_code) => String.t(),
          required(:routing_readiness_recovery_action) => String.t() | nil,
          required(:window_kind) => String.t() | nil,
          required(:window_minutes) => pos_integer() | nil,
          required(:remaining_percent_value) => float() | nil,
          required(:used_percent_value) => float() | nil,
          required(:bar_value) => float(),
          required(:reset_at) => DateTime.t() | nil,
          required(:freshness_state) => String.t(),
          required(:reason_codes) => [String.t()],
          required(:primary_5h) => map() | nil,
          required(:primary_30d) => map() | nil,
          required(:weekly) => map() | nil
        }
  @type quota_health_kpis :: %{
          required(:assignment_count) => non_neg_integer(),
          required(:routing_usable_count) => non_neg_integer(),
          required(:stale_or_missing_count) => non_neg_integer(),
          required(:exhausted_count) => non_neg_integer(),
          required(:blocked_count) => non_neg_integer(),
          required(:weekly_only_count) => non_neg_integer(),
          required(:fresh_count) => non_neg_integer(),
          required(:stale_count) => non_neg_integer(),
          required(:missing_evidence_count) => non_neg_integer()
        }
  @type quota_health :: %{
          required(:key) => :quota_health,
          required(:title) => String.t(),
          required(:items) => [quota_health_item()],
          required(:kpis) => quota_health_kpis(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean(),
          required(:missing?) => boolean(),
          required(:state) => String.t()
        }
  @type request_health_item :: %{
          required(:date) => String.t(),
          required(:success_count) => non_neg_integer(),
          required(:failure_count) => non_neg_integer(),
          required(:total_count) => non_neg_integer()
        }
  @type request_health_kpis :: %{
          required(:total_requests_24h) => non_neg_integer(),
          required(:failed_requests_24h) => non_neg_integer(),
          required(:failure_rate_24h) => float(),
          required(:total_requests_7d) => non_neg_integer()
        }
  @type request_health :: %{
          required(:key) => :request_health,
          required(:title) => String.t(),
          required(:items) => [request_health_item()],
          required(:kpis) => request_health_kpis(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean(),
          required(:missing?) => boolean(),
          required(:state) => String.t()
        }
  @type pool_contribution_item :: %{
          required(:assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_label) => String.t(),
          required(:assignment_label) => String.t(),
          required(:assignment_status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t(),
          required(:assignment_state) => String.t(),
          required(:assignment_state_label) => String.t(),
          required(:routing_usable?) => boolean(),
          required(:routing_readiness_state) => String.t(),
          required(:routing_readiness_label) => String.t(),
          required(:routing_readiness_reason) => String.t(),
          required(:routing_readiness_reason_code) => String.t(),
          required(:routing_readiness_recovery_action) => String.t() | nil,
          required(:successful_request_count_7d) => non_neg_integer(),
          required(:share_percent_value) => float(),
          required(:bar_value) => float()
        }
  @type pool_contribution_kpis :: %{
          required(:assignment_count) => non_neg_integer(),
          required(:active_assignment_count) => non_neg_integer(),
          required(:disabled_assignment_count) => non_neg_integer(),
          required(:successful_requests_7d) => non_neg_integer()
        }
  @type pool_contribution :: %{
          required(:key) => :pool_contribution,
          required(:title) => String.t(),
          required(:items) => [pool_contribution_item()],
          required(:kpis) => pool_contribution_kpis(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean(),
          required(:missing?) => boolean(),
          required(:state) => String.t()
        }
  @type recent_request_event_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          required(:admitted_at) => DateTime.t() | nil,
          required(:completed_at) => DateTime.t() | nil,
          required(:response_status_code) => integer() | nil,
          required(:last_error_code) => String.t() | nil,
          required(:attempt_count) => non_neg_integer()
        }

  @spec request_health(Scope.t(), identity_ref()) :: request_health()
  def request_health(%Scope{} = scope, identity_or_id) do
    request_health(scope, identity_or_id, Common.now())
  end

  @spec request_health(Scope.t(), identity_ref(), DateTime.t()) :: request_health()
  def request_health(%Scope{} = scope, identity_or_id, %DateTime{} = as_of) do
    RequestHealth.request_health(scope, identity_or_id, as_of)
  end

  @spec request_health_without_request_data() :: request_health()
  def request_health_without_request_data do
    request_health_without_request_data(Common.now())
  end

  @spec request_health_without_request_data(DateTime.t()) :: request_health()
  def request_health_without_request_data(%DateTime{} = as_of) do
    RequestHealth.without_request_data(as_of)
  end

  @spec quota_health(Scope.t(), identity_ref(), [assignment_summary()]) :: quota_health()
  def quota_health(%Scope{} = scope, identity_or_id, assignments) when is_list(assignments) do
    QuotaHealth.quota_health(scope, identity_or_id, assignments, Common.now())
  end

  @spec quota_health_without_quota_data([assignment_summary()]) :: quota_health()
  def quota_health_without_quota_data(assignments) when is_list(assignments) do
    QuotaHealth.without_quota_data(assignments, Common.now())
  end

  @spec pool_contribution(Scope.t(), identity_ref(), [assignment_summary()]) ::
          pool_contribution()
  def pool_contribution(%Scope{} = scope, identity_or_id, assignments)
      when is_list(assignments) do
    PoolContribution.pool_contribution(scope, identity_or_id, assignments, Common.now())
  end

  @spec pool_contribution_without_request_data([assignment_summary()]) :: pool_contribution()
  def pool_contribution_without_request_data(assignments) when is_list(assignments) do
    PoolContribution.without_request_data(assignments, Common.now())
  end

  @spec recent_request_event_rows(Scope.t(), identity_ref(), pos_integer()) :: [
          recent_request_event_row()
        ]
  def recent_request_event_rows(%Scope{} = scope, identity_or_id, limit) when is_integer(limit) do
    RequestHealth.recent_request_event_rows(scope, identity_or_id, max(limit, 0))
  end

  def recent_request_event_rows(_scope, _identity_or_id, _limit), do: []
end
