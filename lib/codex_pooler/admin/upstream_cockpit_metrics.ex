defmodule CodexPooler.Admin.UpstreamCockpitMetrics do
  @moduledoc """
  Scoped admin-domain metrics for upstream cockpit request, quota, and pool activity.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Admin.UpstreamRoutingReadiness
  alias CodexPooler.Pools
  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Charts.Measurements
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @request_failed_statuses ~w(failed rejected interrupted cancelled)
  @request_terminal_statuses ["succeeded" | @request_failed_statuses]

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
    request_health(scope, identity_or_id, now())
  end

  @spec request_health(Scope.t(), identity_ref(), DateTime.t()) :: request_health()
  def request_health(%Scope{} = scope, identity_or_id, %DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = seven_day_window_start(as_of)

    identity_or_id
    |> identity_id()
    |> request_health_rows(scope, start_7d, as_of)
    |> request_health_from_rows(start_7d, start_24h)
  end

  @spec request_health_without_request_data() :: request_health()
  def request_health_without_request_data do
    request_health_without_request_data(now())
  end

  @spec request_health_without_request_data(DateTime.t()) :: request_health()
  def request_health_without_request_data(%DateTime{} = as_of) do
    start_24h = DateTime.add(as_of, -24, :hour)
    start_7d = seven_day_window_start(as_of)

    request_health_from_rows([], start_7d, start_24h)
  end

  @spec quota_health(Scope.t(), identity_ref(), [assignment_summary()]) :: quota_health()
  def quota_health(%Scope{} = scope, identity_or_id, assignments) when is_list(assignments) do
    pool_ids = visible_pool_ids(scope)
    visible_assignments = filter_assignments_by_pool_ids(assignments, pool_ids)

    windows =
      if visible_assignments == [] do
        []
      else
        identity_or_id
        |> identity_id()
        |> QuotaWindows.list_quota_windows()
      end

    quota_health_from_windows(identity_or_id, visible_assignments, windows, now())
  end

  @spec quota_health_without_quota_data([assignment_summary()]) :: quota_health()
  def quota_health_without_quota_data(assignments) when is_list(assignments) do
    quota_health_from_windows(nil, assignments, [], now())
  end

  @spec pool_contribution(Scope.t(), identity_ref(), [assignment_summary()]) ::
          pool_contribution()
  def pool_contribution(%Scope{} = scope, identity_or_id, assignments)
      when is_list(assignments) do
    pool_ids = visible_pool_ids(scope)
    visible_assignments = filter_assignments_by_pool_ids(assignments, pool_ids)
    as_of = now()
    start_7d = seven_day_window_start(as_of)

    rows =
      identity_or_id
      |> identity_id()
      |> pool_contribution_rows(pool_ids, start_7d, as_of)

    quota_readiness =
      if visible_assignments == [] do
        UpstreamQuotaReadiness.from_windows([], as_of)
      else
        identity_or_id
        |> identity_id()
        |> quota_readiness_for_identity(as_of)
      end

    pool_contribution_from_rows(identity_or_id, visible_assignments, rows, quota_readiness)
  end

  @spec pool_contribution_without_request_data([assignment_summary()]) :: pool_contribution()
  def pool_contribution_without_request_data(assignments) when is_list(assignments) do
    pool_contribution_from_rows(
      nil,
      assignments,
      [],
      UpstreamQuotaReadiness.from_windows([], now())
    )
  end

  @spec recent_request_event_rows(Scope.t(), identity_ref(), pos_integer()) :: [
          recent_request_event_row()
        ]
  def recent_request_event_rows(%Scope{} = scope, identity_or_id, limit) when is_integer(limit) do
    identity_or_id
    |> identity_id()
    |> recent_request_event_rows_for_identity(scope, max(limit, 0))
  end

  def recent_request_event_rows(_scope, _identity_or_id, _limit), do: []

  defp quota_health_from_windows(identity_or_status, assignments, windows, as_of) do
    readiness = UpstreamQuotaReadiness.from_windows(windows, as_of)

    items =
      assignments
      |> Enum.map(&quota_health_item(&1, readiness, identity_or_status, as_of))
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

  defp quota_health_item(assignment, readiness, identity_or_status, as_of) do
    routing_readiness = routing_readiness(identity_or_status, assignment, readiness)
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
    |> Map.put(:routing_usable?, routing_readiness.routing_ready_now?)
    |> Map.merge(routing_readiness_contract(routing_readiness))
    |> Map.put(:window_kind, display_window && display_window.window_kind)
    |> Map.put(:window_minutes, display_window && display_window.window_minutes)
    |> Map.put(:reset_at, display_window && display_window.reset_at)
    |> Map.put(:freshness_state, quota_freshness_state(display_window, as_of))
    |> Map.put(:reason_codes, quota_reason_codes(readiness.reason_codes, routing_readiness))
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
    kpis.stale_or_missing_count > 0 or kpis.exhausted_count > 0 or kpis.blocked_count > 0 or
      kpis.routing_usable_count < kpis.assignment_count
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

  defp pool_contribution_from_rows(identity_or_status, assignments, rows, quota_readiness) do
    successful_requests_7d = length(rows)
    request_counts_by_pool_id = Enum.frequencies_by(rows, & &1.pool_id)

    items =
      assignments
      |> Enum.map(
        &pool_contribution_item(
          &1,
          request_counts_by_pool_id,
          successful_requests_7d,
          identity_or_status,
          quota_readiness
        )
      )
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

  defp pool_contribution_rows(identity_id, pool_ids, start_7d, as_of)
       when is_binary(identity_id) and is_list(pool_ids) do
    case pool_ids do
      [] -> []
      [_ | _] -> pool_contribution_rows_for_pools(identity_id, pool_ids, start_7d, as_of)
    end
  end

  defp pool_contribution_rows(_identity_id, _pool_ids, _start_7d, _as_of), do: []

  defp pool_contribution_rows_for_pools(identity_id, pool_ids, start_7d, as_of) do
    Request
    |> join(:inner, [request], attempt in Attempt, on: attempt.request_id == request.id)
    |> where([request], request.pool_id in ^pool_ids)
    |> where([request, attempt], attempt.upstream_identity_id == ^identity_id)
    |> where([request], request.status == "succeeded")
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
    |> group_by([request], [request.id, request.pool_id])
    |> select([request], %{pool_id: request.pool_id})
    |> Repo.all()
  end

  defp pool_contribution_item(
         assignment,
         request_counts_by_pool_id,
         successful_requests_7d,
         identity_or_status,
         quota_readiness
       ) do
    successful_request_count_7d = Map.get(request_counts_by_pool_id, assignment.pool_id, 0)
    share_percent_value = percentage(successful_request_count_7d, successful_requests_7d)
    routing_readiness = routing_readiness(identity_or_status, assignment, quota_readiness)
    assignment_state = pool_contribution_assignment_state(routing_readiness)

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
      pool_contribution_assignment_state_label(assignment_state, routing_readiness)
    )
    |> Map.put(:routing_usable?, routing_readiness.routing_ready_now?)
    |> Map.merge(routing_readiness_contract(routing_readiness))
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

  defp pool_contribution_assignment_state(%{routing_ready_now?: true}), do: "active"
  defp pool_contribution_assignment_state(_routing_readiness), do: "disabled"

  defp pool_contribution_assignment_state_label("active", _routing_readiness),
    do: "Active assignment"

  defp pool_contribution_assignment_state_label("disabled", %{state: "assignment_unavailable"}),
    do: "Disabled or unusable assignment"

  defp pool_contribution_assignment_state_label("disabled", %{label: label})
       when is_binary(label),
       do: label

  defp pool_contribution_assignment_state_label("disabled", _routing_readiness),
    do: "Disabled or unusable assignment"

  defp quota_readiness_for_identity(identity_id, as_of) when is_binary(identity_id) do
    identity_id
    |> QuotaWindows.list_quota_windows()
    |> UpstreamQuotaReadiness.from_windows(as_of)
  end

  defp quota_readiness_for_identity(_identity_id, as_of),
    do: UpstreamQuotaReadiness.from_windows([], as_of)

  defp routing_readiness(identity_or_status, assignment, quota_readiness) do
    identity_or_status
    |> routing_identity_status(assignment)
    |> UpstreamRoutingReadiness.from_inputs(assignment, quota_readiness)
  end

  defp routing_identity_status(identity_or_status, assignment) do
    assignment_identity_status(assignment) || identity_or_status
  end

  defp assignment_identity_status(%{identity_status: status}) when is_binary(status), do: status

  defp assignment_identity_status(%{"identity_status" => status}) when is_binary(status),
    do: status

  defp assignment_identity_status(_assignment), do: nil

  defp routing_readiness_contract(routing_readiness) do
    %{
      routing_readiness_state: routing_readiness.state,
      routing_readiness_label: routing_readiness.label,
      routing_readiness_reason: routing_readiness.reason,
      routing_readiness_reason_code: routing_readiness.reason_code,
      routing_readiness_recovery_action: routing_readiness.recovery_action
    }
  end

  defp quota_reason_codes(quota_reason_codes, %{routing_ready_now?: true}), do: quota_reason_codes
  defp quota_reason_codes(quota_reason_codes, %{state: "quota_blocked"}), do: quota_reason_codes

  defp quota_reason_codes(quota_reason_codes, %{reason_code: reason_code})
       when is_binary(reason_code) do
    [reason_code | quota_reason_codes]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp request_health_rows(identity_id, %Scope{} = scope, start_7d, as_of)
       when is_binary(identity_id) do
    case visible_pool_ids(scope) do
      [] -> []
      pool_ids -> request_health_rows_for_pools(identity_id, pool_ids, start_7d, as_of)
    end
  end

  defp request_health_rows(_identity_id, _scope, _start_7d, _as_of), do: []

  defp request_health_rows_for_pools(identity_id, pool_ids, start_7d, as_of) do
    Request
    |> join(:inner, [request], attempt in Attempt, on: attempt.request_id == request.id)
    |> where([request], request.pool_id in ^pool_ids)
    |> where([request, attempt], attempt.upstream_identity_id == ^identity_id)
    |> where([request], request.status in ^@request_terminal_statuses)
    |> where([request], request.admitted_at >= ^start_7d and request.admitted_at <= ^as_of)
    |> group_by([request], [request.id, request.status, request.admitted_at])
    |> select([request], %{status: request.status, admitted_at: request.admitted_at})
    |> Repo.all()
  end

  defp request_health_from_rows(rows, start_7d, start_24h) do
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

  defp recent_request_event_rows_for_identity(identity_id, %Scope{} = scope, limit)
       when is_binary(identity_id) and limit > 0 do
    case visible_pool_ids(scope) do
      [] -> []
      pool_ids -> recent_request_event_rows_for_pools(identity_id, pool_ids, limit)
    end
  end

  defp recent_request_event_rows_for_identity(_identity_id, _scope, _limit), do: []

  defp recent_request_event_rows_for_pools(identity_id, pool_ids, limit) do
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
    |> where([request], request.pool_id in ^pool_ids)
    |> where(
      [request, _target, attempts],
      request.status in ^@request_failed_statuses or attempts.attempt_count > 1
    )
    |> order_by([request], desc: request.admitted_at, desc: request.id)
    |> limit(^limit)
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

  defp filter_assignments_by_pool_ids(assignments, pool_ids) do
    pool_id_set = MapSet.new(pool_ids)

    Enum.filter(assignments, &MapSet.member?(pool_id_set, &1.pool_id))
  end

  defp visible_pool_ids(%Scope{} = scope) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.map(& &1.id)
  end

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_identity_or_id), do: nil

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
