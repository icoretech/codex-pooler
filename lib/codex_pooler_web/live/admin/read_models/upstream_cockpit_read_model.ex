defmodule CodexPoolerWeb.Admin.UpstreamCockpitReadModel do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics
  alias CodexPooler.Audit
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.DateTimeDisplay

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  @usable_refresh_statuses ~w(succeeded imported refreshing)
  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @recent_event_limit 8
  @recent_event_prefetch_limit 32
  @oauth_terminal_statuses ~w(failed expired cancelled)
  @oauth_recent_event_window_seconds 24 * 60 * 60

  @type safe_identity :: %{
          required(:id) => Ecto.UUID.t(),
          required(:label) => String.t(),
          required(:status) => String.t(),
          required(:onboarding_method) => String.t() | nil,
          required(:plan_label) => String.t() | nil,
          required(:plan_reported?) => boolean(),
          required(:safe_account_id_label) => String.t(),
          required(:subject_ref) => String.t() | nil,
          required(:account_email) => String.t() | nil,
          required(:workspace_ref) => String.t() | nil,
          required(:workspace_label) => String.t() | nil,
          required(:saved_resets) => SavedResets.snapshot_projection(),
          required(:saved_reset_policy) => SavedResets.auto_policy_projection()
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
          required(:safe_account_id_label) => String.t(),
          required(:subject_ref) => String.t() | nil,
          required(:routing_readiness) => map(),
          required(:identity_observability) => UpstreamAccountsReadModel.identity_observability()
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
  @type quota_health :: UpstreamCockpitMetrics.quota_health()
  @type request_health :: UpstreamCockpitMetrics.request_health()
  @type pool_contribution :: UpstreamCockpitMetrics.pool_contribution()
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
          required(:link) => String.t() | nil,
          required(:request_id) => Ecto.UUID.t() | nil,
          required(:failure?) => boolean()
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
          required(:redeem_saved_reset) => action(),
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
          required(:saved_resets) => SavedResets.snapshot_projection(),
          required(:saved_reset_policy) => SavedResets.auto_policy_projection(),
          required(:quota_limits) => [UpstreamAccountsReadModel.quota_limit_row()],
          required(:flags) => flags()
        }

  @spec load_visible(term(), Ecto.UUID.t()) :: {:ok, t()} | :error
  def load_visible(scope, identity_id) when is_binary(identity_id) do
    pools = Pools.list_visible_pools(scope)

    scope
    |> UpstreamAccountsReadModel.list_visible_accounts(
      pools,
      %{identity_id: identity_id},
      DateTimeDisplay.preferences_for_user(scope.user)
    )
    |> case do
      [account | _rest] -> {:ok, from_account_snapshot(account, scope)}
      [] -> :error
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
    oauth_flows = oauth_flows(account, scope)
    recent_events = recent_events(account.identity, scope, oauth_flows)
    actions = actions(account)
    saved_resets = saved_resets(account)
    saved_reset_policy = saved_reset_policy(account)
    sections = sections(flags, assignments, charts, recent_events, actions)

    %{
      identity: safe_identity,
      header: header,
      assignments: assignments,
      charts: charts,
      recent_events: recent_events,
      actions: actions,
      saved_resets: saved_resets,
      saved_reset_policy: saved_reset_policy,
      quota_limits: quota_limits(account),
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
      safe_account_id_label: safe_account_id_label(identity.chatgpt_account_id),
      subject_ref: account.subject_ref,
      account_email: identity.account_email,
      workspace_ref: account.workspace_ref,
      workspace_label: account.workspace_label,
      saved_resets: saved_resets(account),
      saved_reset_policy: saved_reset_policy(account)
    }
  end

  defp quota_limits(%{quota_limits: quota_limits}) when is_list(quota_limits),
    do: quota_limits

  defp quota_limits(_account), do: []

  defp saved_resets(%{saved_resets: saved_resets}), do: saved_resets

  defp saved_resets(%{identity: %UpstreamIdentity{} = identity}),
    do: SavedResets.snapshot(identity)

  defp saved_reset_policy(%{saved_reset_policy: saved_reset_policy}), do: saved_reset_policy

  defp saved_reset_policy(%{identity: %UpstreamIdentity{} = identity}),
    do: SavedResets.auto_policy(identity)

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
      safe_account_id_label: safe_identity.safe_account_id_label,
      subject_ref: safe_identity.subject_ref,
      routing_readiness: account.routing_readiness,
      identity_observability: account.identity_observability
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
    UpstreamCockpitMetrics.pool_contribution(scope, identity, assignments)
  end

  defp pool_contribution(%UpstreamIdentity{}, %{items: assignments}, _scope) do
    UpstreamCockpitMetrics.pool_contribution_without_request_data(assignments)
  end

  @spec request_health(UpstreamIdentity.t(), Scope.t() | term()) :: request_health()
  defp request_health(%UpstreamIdentity{} = identity, %Scope{} = scope) do
    UpstreamCockpitMetrics.request_health(scope, identity)
  end

  defp request_health(%UpstreamIdentity{}, _scope) do
    UpstreamCockpitMetrics.request_health_without_request_data()
  end

  @spec quota_health(UpstreamIdentity.t(), assignments(), Scope.t() | term()) :: quota_health()
  defp quota_health(%UpstreamIdentity{} = identity, %{items: assignments}, %Scope{} = scope) do
    UpstreamCockpitMetrics.quota_health(scope, identity, assignments)
  end

  defp quota_health(%UpstreamIdentity{}, %{items: assignments}, _scope) do
    UpstreamCockpitMetrics.quota_health_without_quota_data(assignments)
  end

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_value(_datetime), do: 0

  defp recent_events(%UpstreamIdentity{} = identity, scope, oauth_flows) do
    items =
      identity.id
      |> request_recent_event_items(scope)
      |> Enum.concat(audit_recent_event_items(scope, identity.id))
      |> Enum.concat(oauth_recent_event_items(oauth_flows))
      |> Enum.sort_by(&datetime_sort_value(&1.timestamp), :desc)
      |> Enum.take(@recent_event_limit)

    %{
      items: items,
      count: length(items),
      empty?: items == [],
      degraded?: Enum.any?(items, & &1.failure?),
      missing?: false
    }
  end

  defp request_recent_event_items(identity_id, scope) do
    identity_id
    |> request_recent_event_rows(scope)
    |> Enum.map(&request_recent_event_item(&1, identity_id))
  end

  defp request_recent_event_rows(identity_id, %Scope{} = scope) do
    UpstreamCockpitMetrics.recent_request_event_rows(
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
      link: request_recent_event_link(row.id, identity_id),
      request_id: row.id,
      failure?: row.status in @request_failed_statuses
    }
  end

  # Failures lead with the distinctive fact (the error), not a repeated
  # "Request failed" heading; the outcome moves to the subtitle.
  defp request_recent_event_title(row) do
    [status_code_label(row.response_status_code), row.last_error_code]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> case do
      "" -> fallback_request_event_title(row)
      title -> title
    end
  end

  defp fallback_request_event_title(%{status: status}) when status in @request_failed_statuses,
    do: "Request failed"

  defp fallback_request_event_title(_row), do: "Request retried"

  defp request_recent_event_subtitle(row) do
    [
      human_status(row.status),
      retry_label(row),
      pluralize_count(row.attempt_count, "attempt", "attempts")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp retry_label(%{status: status, attempt_count: attempt_count})
       when status in @request_failed_statuses and attempt_count > 1,
       do: "after retry"

  defp retry_label(_row), do: nil

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
      subtitle: human_status(row.outcome),
      link: audit_recent_event_link(identity_id),
      request_id: nil,
      failure?: false
    }
  end

  defp audit_recent_event_link(identity_id) do
    query = URI.encode_query([{"target", identity_id}])
    "/admin/audit-logs?#{query}"
  end

  @doc """
  The account's most recent OAuth flow that is still actionable: pending and
  not yet past its deadline. A pending flow whose expiry has passed is dead
  even if the expiry sweeper has not relabelled it yet, so it never keeps the
  relink card alive.
  """
  @spec pending_relink_flow(oauth_flow_state()) :: map() | nil
  def pending_relink_flow(%{items: items}) when is_list(items) do
    Enum.find(items, &actively_pending_flow?/1)
  end

  def pending_relink_flow(_oauth_flows), do: nil

  defp actively_pending_flow?(%{status: "pending", expires_at: %DateTime{} = expires_at}),
    do: DateTime.after?(expires_at, DateTime.utc_now())

  defp actively_pending_flow?(_flow), do: false

  # Failed, expired, and cancelled relink flows emit no audit event (only
  # successful completions do), so these feed rows are their only surface.
  # The recency window keeps a stale flow from resurfacing days later.
  defp oauth_recent_event_items(%{items: items}) when is_list(items) do
    items
    |> Enum.map(&normalize_oauth_flow_status/1)
    |> Enum.filter(&(&1.status in @oauth_terminal_statuses))
    |> Enum.map(&oauth_recent_event_item/1)
    |> Enum.filter(&recent_oauth_event?/1)
  end

  defp oauth_recent_event_items(_oauth_flows), do: []

  # A pending flow past its deadline is expired in fact; present it as such
  # without waiting for the expiry sweeper to relabel the row.
  defp normalize_oauth_flow_status(
         %{status: "pending", expires_at: %DateTime{} = expires_at} = flow
       ) do
    if DateTime.after?(expires_at, DateTime.utc_now()) do
      flow
    else
      %{flow | status: "expired"}
    end
  end

  defp normalize_oauth_flow_status(flow), do: flow

  defp oauth_recent_event_item(flow) do
    %{
      timestamp: oauth_terminal_timestamp(flow),
      source: "oauth_flow",
      title: oauth_recent_event_title(flow.status),
      subtitle: oauth_recent_event_subtitle(flow),
      link: nil,
      request_id: nil,
      failure?: flow.status in ["failed", "expired"]
    }
  end

  defp recent_oauth_event?(%{timestamp: %DateTime{} = timestamp}) do
    DateTime.diff(DateTime.utc_now(), timestamp, :second) <= @oauth_recent_event_window_seconds
  end

  defp recent_oauth_event?(_item), do: false

  defp oauth_terminal_timestamp(%{status: "cancelled"} = flow),
    do: flow.cancelled_at || flow.inserted_at

  defp oauth_terminal_timestamp(%{status: "failed"} = flow),
    do: flow.completed_at || flow.inserted_at

  defp oauth_terminal_timestamp(%{status: "expired"} = flow),
    do: flow.expires_at || flow.inserted_at

  defp oauth_terminal_timestamp(flow), do: flow.inserted_at

  defp oauth_recent_event_title("failed"), do: "OAuth relink failed"
  defp oauth_recent_event_title("expired"), do: "OAuth relink expired"
  defp oauth_recent_event_title(_status), do: "OAuth relink cancelled"

  defp oauth_recent_event_subtitle(flow) do
    ["#{flow.flow_kind} flow", oauth_error_label(flow.error)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp oauth_error_label(%{message: message}) when is_binary(message) and message != "",
    do: message

  defp oauth_error_label(%{code: code}) when is_binary(code) and code != "",
    do: human_status(code)

  defp oauth_error_label(_error), do: nil

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

  defp pluralize_count(1, singular, _plural), do: "1 #{singular}"
  defp pluralize_count(count, _singular, plural), do: "#{count || 0} #{plural}"

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""

  defp actions(account) do
    status = account.identity.status
    recovery_eligible? = recovery_eligible?(account)
    redeem_saved_reset = redeem_saved_reset_action(account)

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
      redeem_saved_reset: redeem_saved_reset,
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

  defp redeem_saved_reset_action(account) do
    cond do
      account.identity.status == "deleted" ->
        action(false, "deleted accounts cannot redeem saved resets")

      account.identity.status == "disabled" ->
        action(false, "disabled accounts cannot redeem saved resets")

      not auth_clearly_usable?(account) ->
        action(false, "saved reset redemption requires usable credentials")

      account.assignments == [] ->
        action(false, "saved reset redemption requires a Pool assignment")

      account.saved_resets.reported? == false ->
        action(false, "saved reset count is not reported")

      account.saved_resets.available? == false ->
        action(false, "no saved resets are available")

      account.saved_resets.in_progress? == true ->
        action(false, "saved reset redemption is already in progress")

      true ->
        action(true, nil)
    end
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
