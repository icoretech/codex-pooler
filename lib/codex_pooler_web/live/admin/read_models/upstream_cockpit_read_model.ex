defmodule CodexPoolerWeb.Admin.UpstreamCockpitReadModel do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitReadModel, as: AdminUpstreamCockpitReadModel
  alias CodexPooler.Audit
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.DateTimeDisplay

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  @usable_refresh_statuses ~w(succeeded imported refreshing)
  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @recent_event_limit 8
  @recent_event_prefetch_limit 32

  @type safe_identity :: %{
          required(:id) => Ecto.UUID.t(),
          required(:label) => String.t(),
          required(:status) => String.t(),
          required(:onboarding_method) => String.t() | nil,
          required(:plan_label) => String.t() | nil,
          required(:plan_reported?) => boolean(),
          required(:safe_account_id_label) => String.t()
        }
  @type header :: %{
          required(:title) => String.t(),
          required(:status) => String.t(),
          required(:status_label) => String.t(),
          required(:plan_label) => String.t() | nil,
          required(:plan_reported?) => boolean(),
          required(:refresh_status) => String.t(),
          required(:quota_refresh_status) => String.t(),
          required(:auth_fresh_label) => String.t(),
          required(:auth_verified_label) => String.t(),
          required(:access_token_label) => String.t(),
          required(:token_refresh_label) => String.t(),
          required(:refresh_job_state) => String.t() | nil,
          required(:reauth_required?) => boolean(),
          required(:reauth_reason_code) => String.t() | nil,
          required(:reauth_reason_message) => String.t() | nil,
          required(:disabled?) => boolean(),
          required(:safe_account_id_label) => String.t()
        }
  @type assignment :: %{
          required(:id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:assignment_label) => String.t(),
          required(:status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t(),
          required(:identity_status) => String.t(),
          required(:quota_priming_status) => String.t(),
          required(:quota_priming_label) => String.t(),
          required(:last_successful_refresh_at) => DateTime.t() | nil,
          required(:pool_label) => String.t()
        }
  @type assignments :: %{
          required(:items) => [assignment()],
          required(:count) => non_neg_integer(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean()
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
  @type charts :: %{
          required(:quota_health) => quota_health(),
          required(:request_health) => request_health(),
          required(:pool_contribution) => pool_contribution(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean()
        }
  @type recent_event_item :: %{
          required(:timestamp) => DateTime.t(),
          required(:source) => String.t(),
          required(:title) => String.t(),
          required(:subtitle) => String.t(),
          required(:link) => String.t()
        }
  @type recent_events :: %{
          required(:items) => [recent_event_item()],
          required(:count) => non_neg_integer(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean(),
          required(:missing?) => boolean()
        }
  @type action :: %{
          required(:available?) => boolean(),
          required(:reason) => String.t() | nil
        }
  @type actions :: %{
          required(:rename) => action(),
          required(:pause) => action(),
          required(:reactivate) => action(),
          required(:refresh_token) => action(),
          required(:replace_auth_json) => action(),
          required(:oauth_relink) => action(),
          required(:reinvite) => action(),
          required(:delete) => action(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean()
        }
  @type section_state :: %{required(:empty?) => boolean(), required(:degraded?) => boolean()}
  @type sections :: %{
          required(:header) => section_state(),
          required(:assignments) => section_state(),
          required(:charts) => section_state(),
          required(:recent_events) => section_state(),
          required(:actions) => section_state()
        }
  @type flags :: %{
          required(:missing_quota?) => boolean(),
          required(:missing_requests?) => boolean(),
          required(:missing_assignments?) => boolean(),
          required(:disabled_identity?) => boolean(),
          required(:reauth_required?) => boolean()
        }
  @type oauth_flow_state :: UpstreamAccountsReadModel.oauth_flow_state()
  @type t :: %{
          required(:identity) => safe_identity(),
          required(:header) => header(),
          required(:assignments) => assignments(),
          required(:charts) => charts(),
          required(:recent_events) => recent_events(),
          required(:actions) => actions(),
          required(:oauth_flows) => oauth_flow_state(),
          required(:sections) => sections(),
          required(:flags) => flags()
        }

  @spec load_visible(term(), Ecto.UUID.t()) :: {:ok, t()} | :error
  def load_visible(scope, identity_id) when is_binary(identity_id) do
    pools = Pools.list_visible_pools(scope)

    scope
    |> UpstreamAccountsReadModel.list_visible_accounts(pools)
    |> Enum.find(&(&1.identity.id == identity_id))
    |> case do
      nil -> :error
      account -> {:ok, from_account_snapshot(account, scope)}
    end
  end

  def load_visible(_scope, _identity_id), do: :error

  @spec from_account_snapshot(UpstreamAccountsReadModel.account_snapshot()) :: t()
  def from_account_snapshot(%{identity: %UpstreamIdentity{}} = account) do
    from_account_snapshot(account, nil)
  end

  @spec from_account_snapshot(UpstreamAccountsReadModel.account_snapshot(), term() | nil) :: t()
  defp from_account_snapshot(%{identity: %UpstreamIdentity{}} = account, scope) do
    safe_identity = safe_identity(account)
    header = header(account, safe_identity)
    assignments = assignments(account)
    quota_health = quota_health(account.identity, assignments, scope)
    request_health = request_health(account.identity, scope)
    pool_contribution = pool_contribution(account.identity, assignments, scope)
    flags = flags(account, assignments, quota_health, request_health)
    charts = charts(flags, quota_health, request_health, pool_contribution)
    recent_events = recent_events(account.identity, scope)
    actions = actions(account)
    oauth_flows = oauth_flows(account, scope)
    sections = sections(flags, assignments, charts, recent_events, actions)

    %{
      identity: safe_identity,
      header: header,
      assignments: assignments,
      charts: charts,
      recent_events: recent_events,
      actions: actions,
      oauth_flows: oauth_flows,
      sections: sections,
      flags: flags
    }
  end

  defp oauth_flows(_account, nil), do: UpstreamAccountsReadModel.empty_oauth_flow_state()

  defp oauth_flows(%{identity: %UpstreamIdentity{} = identity, assignments: assignments}, scope) do
    pools = Enum.map(assignments, &%{id: &1.pool_id})

    UpstreamAccountsReadModel.oauth_flow_state(
      scope,
      pools,
      DateTimeDisplay.preferences_for_user(scope.user),
      upstream_identity_ids: [identity.id]
    )
  end

  defp safe_identity(%{identity: %UpstreamIdentity{} = identity} = account) do
    %{
      id: identity.id,
      label: account.label,
      status: identity.status,
      onboarding_method: identity.onboarding_method,
      plan_label: account.plan_label,
      plan_reported?: account.plan_reported?,
      safe_account_id_label: safe_account_id_label(identity.chatgpt_account_id)
    }
  end

  defp header(account, safe_identity) do
    %{
      title: account.label,
      status: account.identity.status,
      status_label: String.replace(account.identity.status, "_", " "),
      plan_label: account.plan_label,
      plan_reported?: account.plan_reported?,
      refresh_status: account.refresh_status,
      quota_refresh_status: account.quota_refresh_status,
      auth_fresh_label: account.auth_fresh_label,
      auth_verified_label: account.auth_verified_label,
      access_token_label: account.access_token_label,
      token_refresh_label: account.token_refresh_label,
      refresh_job_state: account.refresh_job_state,
      reauth_required?: account.reauth_required?,
      reauth_reason_code: account.reauth_reason_code,
      reauth_reason_message: account.reauth_reason_message,
      disabled?: account.identity.status == "disabled",
      safe_account_id_label: safe_identity.safe_account_id_label
    }
  end

  defp assignments(%{identity: %UpstreamIdentity{} = identity, assignments: assignment_snapshots})
       when is_list(assignment_snapshots) do
    items = Enum.map(assignment_snapshots, &assignment(&1, identity.status))

    %{
      items: items,
      count: length(items),
      empty?: items == [],
      degraded?: Enum.any?(items, &(&1.status in ["disabled", "errored"]))
    }
  end

  defp assignment(snapshot, identity_status) do
    %{
      id: snapshot.id,
      upstream_identity_id: snapshot.upstream_identity_id,
      pool_id: snapshot.pool_id,
      assignment_label: snapshot.assignment_label,
      status: snapshot.status,
      health_status: snapshot.health_status,
      eligibility_status: snapshot.eligibility_status,
      identity_status: identity_status,
      quota_priming_status: snapshot.quota_priming_status,
      quota_priming_label: snapshot.quota_priming_label,
      last_successful_refresh_at: snapshot.last_successful_refresh_at,
      pool_label: snapshot.pool_label
    }
  end

  defp flags(account, assignments, quota_health, request_health) do
    %{
      missing_quota?: quota_health.missing?,
      missing_requests?: request_health.missing?,
      missing_assignments?: assignments.empty?,
      disabled_identity?: account.identity.status == "disabled",
      reauth_required?: account.reauth_required?
    }
  end

  defp charts(_flags, quota_health, request_health, pool_contribution) do
    %{
      quota_health: quota_health,
      request_health: request_health,
      pool_contribution: pool_contribution,
      empty?: quota_health.empty? and request_health.empty? and pool_contribution.empty?,
      degraded?: quota_health.degraded? or request_health.degraded? or pool_contribution.degraded?
    }
  end

  @spec pool_contribution(UpstreamIdentity.t(), assignments(), Scope.t() | term()) ::
          pool_contribution()
  defp pool_contribution(%UpstreamIdentity{} = identity, %{items: assignments}, %Scope{} = scope) do
    AdminUpstreamCockpitReadModel.pool_contribution(scope, identity, assignments)
  end

  defp pool_contribution(%UpstreamIdentity{}, %{items: assignments}, _scope) do
    AdminUpstreamCockpitReadModel.pool_contribution_without_request_data(assignments)
  end

  @spec request_health(UpstreamIdentity.t(), Scope.t() | term()) :: request_health()
  defp request_health(%UpstreamIdentity{} = identity, %Scope{} = scope) do
    AdminUpstreamCockpitReadModel.request_health(scope, identity)
  end

  defp request_health(%UpstreamIdentity{}, _scope) do
    AdminUpstreamCockpitReadModel.request_health_without_request_data()
  end

  @spec quota_health(UpstreamIdentity.t(), assignments(), Scope.t() | term()) :: quota_health()
  defp quota_health(%UpstreamIdentity{} = identity, %{items: assignments}, %Scope{} = scope) do
    AdminUpstreamCockpitReadModel.quota_health(scope, identity, assignments)
  end

  defp quota_health(%UpstreamIdentity{}, %{items: assignments}, _scope) do
    AdminUpstreamCockpitReadModel.quota_health_without_quota_data(assignments)
  end

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_value(_datetime), do: 0

  defp recent_events(%UpstreamIdentity{} = identity, scope) do
    items =
      identity.id
      |> request_recent_event_items(scope)
      |> Enum.concat(audit_recent_event_items(scope, identity.id))
      |> Enum.sort_by(&datetime_sort_value(&1.timestamp), :desc)
      |> Enum.take(@recent_event_limit)

    %{
      items: items,
      count: length(items),
      empty?: items == [],
      degraded?: Enum.any?(items, &(&1.source == "request_log" and &1.title == "Request failed")),
      missing?: false
    }
  end

  defp request_recent_event_items(identity_id, scope) do
    identity_id
    |> request_recent_event_rows(scope)
    |> Enum.map(&request_recent_event_item(&1, identity_id))
  end

  defp request_recent_event_rows(identity_id, %Scope{} = scope) do
    AdminUpstreamCockpitReadModel.recent_request_event_rows(
      scope,
      identity_id,
      @recent_event_prefetch_limit
    )
  end

  defp request_recent_event_rows(_identity_id, _scope), do: []

  defp request_recent_event_item(row, identity_id) do
    %{
      timestamp: row.admitted_at || row.completed_at,
      source: "request_log",
      title: request_recent_event_title(row),
      subtitle: request_recent_event_subtitle(row),
      link: request_recent_event_link(row.id, identity_id)
    }
  end

  defp request_recent_event_title(%{status: status, attempt_count: attempt_count})
       when status in @request_failed_statuses and attempt_count > 1,
       do: "Request failed after retry"

  defp request_recent_event_title(%{status: status}) when status in @request_failed_statuses,
    do: "Request failed"

  defp request_recent_event_title(_row), do: "Request retried"

  defp request_recent_event_subtitle(row) do
    [
      human_status(row.status),
      pluralize_count(row.attempt_count, "attempt", "attempts"),
      status_code_label(row.response_status_code),
      error_code_label(row.last_error_code)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp request_recent_event_link(request_id, identity_id) do
    query = URI.encode_query([{"request_id", request_id}, {"upstream_identity_id", identity_id}])
    "/admin/request-logs?#{query}"
  end

  defp audit_recent_event_items(scope, identity_id) do
    scope
    |> audit_recent_event_rows(identity_id)
    |> Enum.filter(&(&1.target_type == "upstream_identity" and &1.target_id == identity_id))
    |> Enum.map(&audit_recent_event_item(&1, identity_id))
  end

  defp audit_recent_event_rows(nil, identity_id) do
    nil
    |> Audit.list_events(limit: @recent_event_prefetch_limit, filters: [target: identity_id])
    |> Map.fetch!(:items)
  end

  defp audit_recent_event_rows(scope, identity_id) do
    scope
    |> Audit.list_events_for_scope(
      limit: @recent_event_prefetch_limit,
      filters: [target: identity_id]
    )
    |> Map.fetch!(:items)
  end

  defp audit_recent_event_item(row, identity_id) do
    %{
      timestamp: row.occurred_at,
      source: "audit_log",
      title: Audit.action_label(row.action) || humanize_event_title(row.action),
      subtitle:
        "#{human_status(row.outcome)} · upstream identity #{String.slice(identity_id, 0, 8)}",
      link: audit_recent_event_link(identity_id)
    }
  end

  defp audit_recent_event_link(identity_id) do
    query = URI.encode_query([{"target", identity_id}])
    "/admin/audit-logs?#{query}"
  end

  defp humanize_event_title(value) do
    value
    |> to_string()
    |> String.replace([".", "_"], " ")
    |> String.capitalize()
  end

  defp human_status(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_code_label(nil), do: nil
  defp status_code_label(status_code), do: "HTTP #{status_code}"

  defp error_code_label(nil), do: nil
  defp error_code_label(error_code), do: "error #{error_code}"

  defp pluralize_count(1, singular, _plural), do: "1 #{singular}"
  defp pluralize_count(count, _singular, plural), do: "#{count || 0} #{plural}"

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""

  defp actions(account) do
    status = account.identity.status
    recovery_eligible? = recovery_eligible?(account)

    %{
      rename: action(status != "deleted", "deleted accounts cannot be renamed"),
      pause:
        action(status in ["active", "refresh_due", "refresh_failed"], "account is not pausable"),
      reactivate: action(status in @reactivatable_statuses, "account is not reactivatable"),
      refresh_token:
        action(
          status in ["active", "refresh_due", "refresh_failed"],
          "token refresh is unavailable"
        ),
      replace_auth_json: action(recovery_eligible?, "credential replacement is not needed"),
      oauth_relink:
        action(
          status != "deleted" and account.assignments != [],
          "OAuth relink requires a Pool assignment"
        ),
      reinvite:
        action(
          recovery_eligible? and account.assignments != [],
          "reinvite requires a Pool assignment"
        ),
      delete: action(status != "deleted", "account is already deleted"),
      empty?: false,
      degraded?: recovery_eligible?
    }
  end

  defp action(true, _reason), do: %{available?: true, reason: nil}
  defp action(false, reason), do: %{available?: false, reason: reason}

  defp sections(flags, assignments, charts, recent_events, actions) do
    %{
      header: %{empty?: false, degraded?: flags.disabled_identity? or flags.reauth_required?},
      assignments: %{empty?: assignments.empty?, degraded?: assignments.degraded?},
      charts: %{empty?: charts.empty?, degraded?: charts.degraded?},
      recent_events: %{empty?: recent_events.empty?, degraded?: recent_events.degraded?},
      actions: %{empty?: actions.empty?, degraded?: actions.degraded?}
    }
  end

  defp recovery_eligible?(%{identity: %{status: status}} = account) do
    status in @recovery_statuses and status != "deleted" and not auth_clearly_usable?(account)
  end

  defp auth_clearly_usable?(%{
         reauth_required?: false,
         refresh_status: refresh_status,
         access_token_label: access_token_label
       }) do
    refresh_status in @usable_refresh_statuses and
      not expired_access_token_label?(access_token_label)
  end

  defp auth_clearly_usable?(_account), do: false

  defp expired_access_token_label?(label) when is_binary(label),
    do: String.starts_with?(label, "access token expired")

  defp expired_access_token_label?(_label), do: false

  defp safe_account_id_label(value) when is_binary(value) and value != "" do
    fingerprint =
      :sha256
      |> :crypto.hash(value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "stored account id sha256:#{fingerprint}"
  end

  defp safe_account_id_label(_value), do: "stored account id not reported"
end
