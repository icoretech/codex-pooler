defmodule CodexPoolerWeb.Admin.UpstreamCockpitReadModel do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Audit
  alias CodexPooler.Pools
  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Charts.Measurements
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamQuotaReadiness

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  @usable_refresh_statuses ~w(succeeded imported refreshing)
  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @request_terminal_statuses ["succeeded" | @request_failed_statuses]
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
  @type t :: %{
          required(:identity) => safe_identity(),
          required(:header) => header(),
          required(:assignments) => assignments(),
          required(:charts) => charts(),
          required(:recent_events) => recent_events(),
          required(:actions) => actions(),
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
    quota_health = quota_health(account, assignments)
    request_health = request_health(account.identity)
    pool_contribution = pool_contribution(account.identity, assignments)
    flags = flags(account, assignments, quota_health, request_health)
    charts = charts(flags, quota_health, request_health, pool_contribution)
    recent_events = recent_events(account.identity, scope)
    actions = actions(account)
    sections = sections(flags, assignments, charts, recent_events, actions)

    %{
      identity: safe_identity,
      header: header,
      assignments: assignments,
      charts: charts,
      recent_events: recent_events,
      actions: actions,
      sections: sections,
      flags: flags
    }
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

  defp assignments(%{assignments: assignment_snapshots}) when is_list(assignment_snapshots) do
    items = Enum.map(assignment_snapshots, &assignment/1)

    %{
      items: items,
      count: length(items),
      empty?: items == [],
      degraded?: Enum.any?(items, &(&1.status in ["disabled", "errored"]))
    }
  end

  defp assignment(snapshot) do
    %{
      id: snapshot.id,
      upstream_identity_id: snapshot.upstream_identity_id,
      pool_id: snapshot.pool_id,
      assignment_label: snapshot.assignment_label,
      status: snapshot.status,
      health_status: snapshot.health_status,
      eligibility_status: snapshot.eligibility_status,
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

  defp pool_contribution(%UpstreamIdentity{} = identity, %{items: assignments}) do
    as_of = now()
    start_7d = seven_day_window_start(as_of)
    rows = pool_contribution_rows(identity.id, start_7d, as_of)
    successful_requests_7d = length(rows)
    request_counts_by_pool_id = Enum.frequencies_by(rows, & &1.pool_id)

    items =
      assignments
      |> Enum.map(&pool_contribution_item(&1, request_counts_by_pool_id, successful_requests_7d))
      |> Enum.sort_by(&{&1.pool_label, &1.assignment_label, &1.assignment_id})

    kpis = pool_contribution_kpis(items, successful_requests_7d)

    %{
      key: :pool_contribution,
      title: "Pool contribution",
      items: items,
      kpis: kpis,
      empty?: items == [],
      degraded?: kpis.disabled_assignment_count > 0,
      missing?: false,
      state: pool_contribution_state(items, kpis)
    }
  end

  defp pool_contribution_rows(identity_id, start_7d, as_of) do
    Request
    |> join(:inner, [request], attempt in Attempt, on: attempt.request_id == request.id)
    |> where([request, attempt], attempt.upstream_identity_id == ^identity_id)
    |> where([request], request.status == "succeeded")
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
    |> group_by([request], [request.id, request.pool_id])
    |> select([request], %{pool_id: request.pool_id})
    |> Repo.all()
  end

  defp pool_contribution_item(assignment, request_counts_by_pool_id, successful_requests_7d) do
    successful_request_count_7d = Map.get(request_counts_by_pool_id, assignment.pool_id, 0)
    share_percent_value = percentage(successful_request_count_7d, successful_requests_7d)
    assignment_state = pool_contribution_assignment_state(assignment)

    assignment
    |> Map.take([
      :upstream_identity_id,
      :pool_id,
      :pool_label,
      :assignment_label,
      :health_status,
      :eligibility_status
    ])
    |> Map.put(:assignment_id, assignment.id)
    |> Map.put(:assignment_status, assignment.status)
    |> Map.put(:assignment_state, assignment_state)
    |> Map.put(
      :assignment_state_label,
      pool_contribution_assignment_state_label(assignment_state)
    )
    |> Map.put(:routing_usable?, pool_contribution_routing_usable?(assignment))
    |> Map.put(:successful_request_count_7d, successful_request_count_7d)
    |> Map.put(:share_percent_value, share_percent_value)
    |> Map.put(:bar_value, share_percent_value)
  end

  defp pool_contribution_kpis(items, successful_requests_7d) do
    %{
      assignment_count: length(items),
      active_assignment_count: Enum.count(items, & &1.routing_usable?),
      disabled_assignment_count: Enum.count(items, &(not &1.routing_usable?)),
      successful_requests_7d: successful_requests_7d
    }
  end

  defp pool_contribution_state([], _kpis), do: "empty"
  defp pool_contribution_state(_items, %{successful_requests_7d: 0}), do: "no_successful_requests"

  defp pool_contribution_state(_items, %{disabled_assignment_count: disabled}) when disabled > 0,
    do: "degraded"

  defp pool_contribution_state(_items, _kpis), do: "contributing"

  defp pool_contribution_assignment_state(assignment) do
    if pool_contribution_routing_usable?(assignment), do: "active", else: "disabled"
  end

  defp pool_contribution_assignment_state_label("active"), do: "Active assignment"
  defp pool_contribution_assignment_state_label("disabled"), do: "Disabled or unusable assignment"

  defp pool_contribution_routing_usable?(assignment) do
    assignment.status == "active" and assignment.health_status == "active" and
      assignment.eligibility_status == "eligible"
  end

  defp request_health(%UpstreamIdentity{} = identity) do
    as_of = now()
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = seven_day_window_start(as_of)
    rows = request_health_rows(identity.id, start_7d, as_of)
    items = request_health_items(rows, start_7d)
    kpis = request_health_kpis(rows, start_24h)

    %{
      key: :request_health,
      title: "Request health",
      items: items,
      kpis: kpis,
      empty?: kpis.total_requests_7d == 0,
      degraded?: kpis.failed_requests_24h > 0,
      missing?: false,
      state: request_health_state(kpis)
    }
  end

  defp request_health_rows(identity_id, start_7d, as_of) do
    Request
    |> join(:inner, [request], attempt in Attempt, on: attempt.request_id == request.id)
    |> where([request, attempt], attempt.upstream_identity_id == ^identity_id)
    |> where([request], request.status in ^@request_terminal_statuses)
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
    |> group_by([request], [request.id, request.status, request.admitted_at])
    |> select([request], %{status: request.status, admitted_at: request.admitted_at})
    |> Repo.all()
  end

  defp request_health_items(rows, start_7d) do
    start_date = DateTime.to_date(start_7d)
    rows_by_date = Enum.group_by(rows, &request_health_date/1)

    for offset <- 0..6 do
      date = Date.add(start_date, offset)
      bucket_rows = Map.get(rows_by_date, date, [])
      success_count = Enum.count(bucket_rows, &(&1.status == "succeeded"))
      failure_count = Enum.count(bucket_rows, &failed_request_status?(&1.status))

      %{
        date: Date.to_iso8601(date),
        success_count: success_count,
        failure_count: failure_count,
        total_count: success_count + failure_count
      }
    end
  end

  defp request_health_kpis(rows, start_24h) do
    rows_24h = Enum.filter(rows, &(DateTime.compare(&1.admitted_at, start_24h) != :lt))
    total_requests_24h = length(rows_24h)
    failed_requests_24h = Enum.count(rows_24h, &failed_request_status?(&1.status))
    total_requests_7d = length(rows)

    %{
      total_requests_24h: total_requests_24h,
      failed_requests_24h: failed_requests_24h,
      failure_rate_24h: failure_rate(failed_requests_24h, total_requests_24h),
      total_requests_7d: total_requests_7d
    }
  end

  defp request_health_state(%{total_requests_7d: 0}), do: "empty"

  defp request_health_state(%{total_requests_24h: total, failed_requests_24h: failed})
       when total > 0 and failed == total,
       do: "failed"

  defp request_health_state(%{failed_requests_24h: failed}) when failed > 0, do: "degraded"
  defp request_health_state(_kpis), do: "healthy"

  defp request_health_date(%{admitted_at: %DateTime{} = admitted_at}),
    do: DateTime.to_date(admitted_at)

  defp failed_request_status?(status), do: status in @request_failed_statuses

  defp failure_rate(_failed, 0), do: 0.0

  defp failure_rate(failed, total), do: percentage(failed, total)

  defp percentage(_count, 0), do: 0.0

  defp percentage(count, total), do: Float.round(count / total * 100.0, 1)

  defp seven_day_window_start(%DateTime{} = as_of) do
    as_of
    |> DateTime.to_date()
    |> Date.add(-6)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp quota_health(%{identity: %UpstreamIdentity{} = identity}, %{items: assignments}) do
    as_of = now()
    windows = QuotaWindows.list_quota_windows(identity)
    readiness = UpstreamQuotaReadiness.from_windows(windows, as_of)

    items =
      assignments
      |> Enum.map(&quota_health_item(&1, readiness, as_of))
      |> Enum.sort_by(&{&1.pool_label, &1.assignment_label, &1.assignment_id})

    kpis = quota_health_kpis(items)

    %{
      key: :quota_health,
      title: "Quota health",
      items: items,
      kpis: kpis,
      empty?: items == [],
      degraded?: quota_health_degraded?(kpis),
      missing?:
        kpis.assignment_count > 0 and kpis.missing_evidence_count == kpis.assignment_count,
      state: quota_health_state(kpis)
    }
  end

  defp quota_health_item(assignment, readiness, as_of) do
    primary_5h = classified_window(readiness.primary_window, :primary_5h)
    primary_30d = readiness.primary_30d_window
    weekly = readiness.weekly_window
    state = quota_assignment_state(readiness)
    display_window = primary_5h || primary_30d || weekly
    measurements = quota_measurements(display_window)

    %{}
    |> Map.merge(
      Map.take(assignment, [:upstream_identity_id, :pool_id, :pool_label, :assignment_label])
    )
    |> Map.put(:assignment_id, assignment.id)
    |> Map.put(:state, state)
    |> Map.put(:state_label, quota_state_label(state))
    |> Map.put(:routing_usable?, readiness.routing_ready_now?)
    |> Map.put(:window_kind, display_window && display_window.window_kind)
    |> Map.put(:window_minutes, display_window && display_window.window_minutes)
    |> Map.put(:reset_at, display_window && display_window.reset_at)
    |> Map.put(:freshness_state, quota_freshness_state(display_window, as_of))
    |> Map.put(:reason_codes, readiness.reason_codes)
    |> Map.put(:remaining, measurements.remaining)
    |> Map.put(:capacity, measurements.capacity)
    |> Map.put(:used, measurements.used)
    |> Map.put(:used_percent, measurements.used_percent)
    |> Map.put(:used_percent_value, decimal_to_float(measurements.used_percent))
    |> Map.put(:remaining_percent, measurements.remaining_percent)
    |> Map.put(:remaining_percent_value, decimal_to_float(measurements.remaining_percent))
    |> Map.put(:bar_value, decimal_to_float(measurements.remaining_percent) || 0.0)
    |> Map.put(:primary_5h, quota_window_contract(primary_5h, as_of))
    |> Map.put(:primary_30d, quota_window_contract(primary_30d, as_of))
    |> Map.put(:weekly, quota_window_contract(weekly, as_of))
  end

  defp classified_window(%Quota.AccountQuotaWindow{} = window, descriptor) do
    if WindowClassifier.classify(window) == descriptor, do: window, else: nil
  end

  defp classified_window(_window, _descriptor), do: nil

  defp quota_health_kpis(items) do
    counts = Enum.frequencies_by(items, & &1.state)

    %{}
    |> Map.put(:assignment_count, length(items))
    |> Map.put(:routing_usable_count, Enum.count(items, & &1.routing_usable?))
    |> Map.put(:fresh_count, Map.get(counts, "fresh", 0))
    |> Map.put(:stale_count, Map.get(counts, "stale", 0))
    |> Map.put(:missing_evidence_count, Map.get(counts, "missing_evidence", 0))
    |> Map.put(:exhausted_count, Map.get(counts, "exhausted", 0))
    |> Map.put(:blocked_count, Map.get(counts, "blocked", 0))
    |> Map.put(:weekly_only_count, Map.get(counts, "weekly_only", 0))
    |> then(fn kpis ->
      Map.put(
        kpis,
        :stale_or_missing_count,
        kpis.stale_count + kpis.missing_evidence_count
      )
    end)
  end

  defp quota_health_degraded?(kpis) do
    kpis.stale_or_missing_count > 0 or kpis.exhausted_count > 0 or kpis.blocked_count > 0
  end

  defp quota_health_state(%{assignment_count: 0}), do: "empty"

  defp quota_health_state(%{blocked_count: blocked}) when blocked > 0, do: "blocked"

  defp quota_health_state(%{exhausted_count: exhausted}) when exhausted > 0, do: "exhausted"

  defp quota_health_state(%{stale_count: stale}) when stale > 0, do: "stale"

  defp quota_health_state(%{missing_evidence_count: missing}) when missing > 0,
    do: "missing_evidence"

  defp quota_health_state(%{assignment_count: count, fresh_count: count, weekly_only_count: 0}),
    do: "fresh"

  defp quota_health_state(%{assignment_count: count, weekly_only_count: count}), do: "weekly_only"
  defp quota_health_state(%{routing_usable_count: usable}) when usable > 0, do: "partial"

  defp quota_health_state(_kpis), do: "unknown"

  defp quota_assignment_state(%{state: "ready"}), do: "fresh"
  defp quota_assignment_state(%{state: "weekly_only_probe"}), do: "weekly_only"
  defp quota_assignment_state(%{state: state}), do: state

  defp quota_measurements(%Quota.AccountQuotaWindow{} = window),
    do: Measurements.for_window(window)

  defp quota_measurements(_window),
    do: %{remaining: nil, capacity: nil, used: nil, used_percent: nil, remaining_percent: nil}

  defp quota_window_contract(nil, _as_of), do: nil

  defp quota_window_contract(%Quota.AccountQuotaWindow{} = window, as_of) do
    measurements = Measurements.for_window(window)

    %{
      window_kind: window.window_kind,
      window_minutes: window.window_minutes,
      reset_at: window.reset_at,
      freshness_state: quota_freshness_state(window, as_of),
      routing_usable?: QuotaWindows.usable_window?(window, as_of),
      remaining_percent_value: decimal_to_float(measurements.remaining_percent),
      used_percent_value: decimal_to_float(measurements.used_percent),
      reason_codes: QuotaWindows.routing_window_reason_codes(window, as_of)
    }
  end

  defp quota_freshness_state(%Quota.AccountQuotaWindow{} = window, as_of),
    do: Evidence.current_freshness_state(window, as_of)

  defp quota_freshness_state(_window, _as_of), do: "missing"

  defp quota_state_label("fresh"), do: "Fresh"
  defp quota_state_label("stale"), do: "Stale"
  defp quota_state_label("exhausted"), do: "Exhausted"
  defp quota_state_label("blocked"), do: "Blocked"
  defp quota_state_label("weekly_only"), do: "Weekly-only"
  defp quota_state_label("missing_evidence"), do: "Missing evidence"
  defp quota_state_label(state), do: String.replace(state, "_", " ")

  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_to_float(nil), do: nil

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_value(_datetime), do: 0

  defp recent_events(%UpstreamIdentity{} = identity, scope) do
    items =
      identity.id
      |> request_recent_event_items()
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

  defp request_recent_event_items(identity_id) do
    identity_id
    |> request_recent_event_rows()
    |> Enum.map(&request_recent_event_item(&1, identity_id))
  end

  defp request_recent_event_rows(identity_id) do
    target_requests_query =
      from attempt in Attempt,
        where: attempt.upstream_identity_id == ^identity_id,
        group_by: attempt.request_id,
        select: %{request_id: attempt.request_id}

    attempt_counts_query =
      from attempt in Attempt,
        group_by: attempt.request_id,
        select: %{request_id: attempt.request_id, attempt_count: count(attempt.id)}

    Request
    |> join(:inner, [request], target in subquery(target_requests_query),
      on: target.request_id == request.id
    )
    |> join(:inner, [request], attempts in subquery(attempt_counts_query),
      on: attempts.request_id == request.id
    )
    |> where(
      [request, _target, attempts],
      request.status in ^@request_failed_statuses or attempts.attempt_count > 1
    )
    |> order_by([request], desc: request.admitted_at, desc: request.id)
    |> limit(^@recent_event_prefetch_limit)
    |> select([request, _target, attempts], %{
      id: request.id,
      status: request.status,
      admitted_at: request.admitted_at,
      completed_at: request.completed_at,
      response_status_code: request.response_status_code,
      last_error_code: request.last_error_code,
      attempt_count: attempts.attempt_count
    })
    |> Repo.all()
  end

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
