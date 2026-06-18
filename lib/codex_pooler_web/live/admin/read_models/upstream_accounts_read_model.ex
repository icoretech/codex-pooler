defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Admin.{UpstreamQuotaReadiness, UpstreamRoutingReadiness}
  alias CodexPooler.Jobs
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.DateTimeDisplay

  @quota_priming_labels %{
    "unknown" => "Priming pending",
    "refreshing" => "Reconciling quota",
    "known" => "Quota known",
    "weekly_only_probe" => "Weekly-only probe",
    "stale" => "Quota stale",
    "expired" => "Quota expired",
    "failed" => "Quota failed",
    "blocked" => "Priming blocked",
    "resetless_unprimed" => "Quota reset missing",
    "unprimed" => "Quota unprimed"
  }

  @token_burn_recent_seconds 5 * 60
  @token_burn_baseline_seconds 60 * 60

  @type assignment_snapshot :: %{
          required(:id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:assignment_label) => String.t(),
          optional(:stored_assignment_label) => String.t() | nil,
          required(:status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t(),
          required(:quota_priming_status) => String.t(),
          required(:quota_priming_label) => String.t(),
          required(:last_successful_refresh_at) => DateTime.t() | nil,
          required(:pool_label) => String.t()
        }
  @type quota_limit_row :: %{
          required(:key) => atom() | String.t(),
          required(:label) => String.t(),
          required(:percent) => Decimal.t() | nil,
          required(:percent_value) => number(),
          required(:percent_label) => String.t(),
          required(:count_label) => String.t() | nil,
          required(:reset_label) => String.t() | nil,
          required(:reset_title) => String.t() | nil
        }
  @type quota_readiness :: UpstreamQuotaReadiness.t()
  @type routing_readiness :: UpstreamRoutingReadiness.t()
  @type token_burn :: %{
          required(:level) => non_neg_integer(),
          required(:label) => String.t(),
          required(:title) => String.t(),
          required(:recent_tokens) => non_neg_integer(),
          required(:baseline_tokens) => non_neg_integer()
        }
  @type account_snapshot :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:label) => String.t(),
          required(:workspace_ref) => String.t(),
          required(:workspace_label) => String.t() | nil,
          required(:plan_label) => String.t(),
          required(:plan_reported?) => boolean(),
          required(:refresh_status) => String.t(),
          required(:token_refresh_label) => String.t(),
          required(:refresh_job_state) => String.t() | nil,
          required(:quota_refresh_status) => String.t(),
          required(:auth_fresh_label) => String.t(),
          required(:auth_verified_label) => String.t(),
          required(:access_token_label) => String.t(),
          required(:reauth_required?) => boolean(),
          required(:reauth_reason_code) => String.t() | nil,
          required(:reauth_reason_message) => String.t() | nil,
          required(:token_burn) => token_burn(),
          required(:assignments) => [assignment_snapshot()],
          required(:quota_readiness) => quota_readiness(),
          required(:routing_readiness) => routing_readiness(),
          required(:quota_limits) => [quota_limit_row()]
        }
  @type oauth_flow_state :: %{
          required(:items) => [Upstreams.oauth_flow_summary()],
          required(:count) => non_neg_integer(),
          required(:pending_count) => non_neg_integer(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean()
        }

  @spec list_visible_accounts(term(), [term()]) :: [account_snapshot()]
  def list_visible_accounts(scope, pools) when is_list(pools) do
    list_visible_accounts(scope, pools, %{}, DateTimeDisplay.preferences_for_user(nil))
  end

  @spec list_visible_accounts(term(), [term()], map()) :: [account_snapshot()]
  def list_visible_accounts(scope, pools, filters) when is_list(pools) and is_map(filters) do
    list_visible_accounts(scope, pools, filters, DateTimeDisplay.preferences_for_user(nil))
  end

  @spec list_visible_accounts(term(), [term()], map(), DateTimeDisplay.preferences()) :: [
          account_snapshot()
        ]
  def list_visible_accounts(scope, pools, filters, datetime_preferences)
      when is_list(pools) and is_map(filters) and is_map(datetime_preferences) do
    pool_lookup = Map.new(pools, &{&1.id, &1})
    assignments = active_assignment_snapshots(pools, pool_lookup)

    identities =
      scope
      |> Upstreams.list_visible_upstream_identities()
      |> Enum.filter(&Map.has_key?(assignments, &1.id))

    token_burns = token_burn_summaries(identities)

    identities
    |> Enum.map(&account_snapshot(&1, assignments, token_burns, datetime_preferences))
    |> apply_filters(filters)
  end

  @spec oauth_flow_state(term(), [term()], DateTimeDisplay.preferences(), keyword()) ::
          oauth_flow_state()
  def oauth_flow_state(scope, pools, datetime_preferences, opts \\ [])

  def oauth_flow_state(scope, pools, _datetime_preferences, opts) when is_list(pools) do
    items =
      Upstreams.list_visible_oauth_flow_summaries(
        scope,
        opts
        |> Keyword.put(:pool_ids, pool_ids(pools))
        |> Keyword.put_new(:limit, 50)
      )

    %{
      items: items,
      count: length(items),
      pending_count: Enum.count(items, &(&1.status == "pending")),
      empty?: items == [],
      degraded?: false
    }
  end

  def oauth_flow_state(_scope, _pools, _datetime_preferences, _opts),
    do: empty_oauth_flow_state()

  @spec empty_oauth_flow_state() :: oauth_flow_state()
  def empty_oauth_flow_state do
    %{items: [], count: 0, pending_count: 0, empty?: true, degraded?: false}
  end

  defp apply_filters(accounts, filters) do
    accounts
    |> filter_by_status(Map.get(filters, "status"))
    |> filter_by_query(Map.get(filters, "query"))
  end

  defp pool_ids(pools) do
    pools
    |> Enum.map(fn
      %{id: id} when is_binary(id) -> id
      %{pool_id: pool_id} when is_binary(pool_id) -> pool_id
      pool_id when is_binary(pool_id) -> pool_id
      _pool -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp filter_by_status(accounts, status) when is_binary(status) and status != "" do
    Enum.filter(accounts, &(&1.identity.status == status))
  end

  defp filter_by_status(accounts, _status), do: accounts

  defp filter_by_query(accounts, query) when is_binary(query) do
    query = String.downcase(String.trim(query))

    if query == "" do
      accounts
    else
      Enum.filter(accounts, &(search_haystack(&1) =~ query))
    end
  end

  defp filter_by_query(accounts, _query), do: accounts

  defp search_haystack(account) do
    account
    |> safe_search_terms()
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  defp safe_search_terms(account) do
    [
      account.label,
      account.identity.chatgpt_account_id,
      account.workspace_ref,
      account.workspace_label,
      account.plan_label,
      account.identity.plan_family,
      account.identity.status,
      account.quota_readiness.label,
      account.quota_readiness.state,
      account.routing_readiness.label,
      account.routing_readiness.state
      | assignment_search_terms(account.assignments)
    ]
  end

  defp assignment_search_terms(assignments) when is_list(assignments) do
    Enum.flat_map(assignments, &assignment_search_terms/1)
  end

  defp assignment_search_terms(assignment) do
    [
      assignment.assignment_label,
      Map.get(assignment, :stored_assignment_label),
      assignment.pool_label
    ]
  end

  defp active_assignment_snapshots(pools, pool_lookup) do
    pools
    |> Enum.flat_map(&Upstreams.list_pool_assignments/1)
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.map(&assignment_snapshot(&1, pool_lookup))
    |> Enum.group_by(& &1.upstream_identity_id)
  end

  defp assignment_snapshot(%PoolUpstreamAssignment{} = assignment, pool_lookup) do
    pool = Map.get(pool_lookup, assignment.pool_id)

    %{
      id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      pool_id: assignment.pool_id,
      assignment_label: assignment.assignment_label || "Pool assignment",
      stored_assignment_label: present_string(assignment.assignment_label),
      status: assignment.status,
      health_status: assignment.health_status,
      eligibility_status: assignment.eligibility_status,
      quota_priming_status: quota_priming_status(assignment),
      quota_priming_label: quota_priming_label(assignment),
      last_successful_refresh_at: assignment.last_successful_refresh_at,
      pool_label: pool_label(pool)
    }
  end

  defp quota_priming_status(%PoolUpstreamAssignment{
         metadata: %{"quota_priming" => %{"status" => status}}
       })
       when is_binary(status),
       do: status

  defp quota_priming_status(_assignment), do: "unknown"

  defp quota_priming_label(%PoolUpstreamAssignment{} = assignment) do
    status = quota_priming_status(assignment)

    quota_priming_label(status)
  end

  defp quota_priming_label(status) when is_binary(status) do
    Map.get(@quota_priming_labels, status, String.replace(status, "_", " "))
  end

  defp account_snapshot(identity, assignments, token_burns, datetime_preferences) do
    quota_windows = QuotaWindows.list_quota_windows(identity)
    quota_readiness = quota_readiness(quota_windows)
    identity_assignments = identity_assignments(identity, assignments, quota_readiness)

    routing_readiness =
      UpstreamRoutingReadiness.from_inputs(identity, identity_assignments, quota_readiness)

    refresh_job = identity |> Jobs.list_recent_token_refresh_jobs(limit: 1) |> List.first()

    %{
      identity: identity,
      label: account_label(identity),
      workspace_ref: workspace_ref(identity.workspace_id),
      workspace_label: safe_workspace_label(identity.workspace_label),
      plan_label: account_plan_label(identity),
      plan_reported?: account_plan_reported?(identity),
      refresh_status: refresh_status_label(identity),
      token_refresh_label: token_refresh_label(identity, datetime_preferences),
      refresh_job_state: refresh_job_state(refresh_job),
      quota_refresh_status:
        quota_refresh_status(Map.get(assignments, identity.id, []), datetime_preferences),
      auth_fresh_label:
        timestamp_status_label("auth imported", identity.auth_fresh_at, datetime_preferences),
      auth_verified_label:
        timestamp_status_label("auth verified", identity.auth_verified_at, datetime_preferences),
      access_token_label: access_token_label(identity, datetime_preferences),
      reauth_required?: reauth_required?(identity),
      reauth_reason_code: reauth_reason_code(identity),
      reauth_reason_message: reauth_reason_message(identity),
      token_burn: Map.fetch!(token_burns, identity.id),
      assignments: identity_assignments,
      quota_readiness: quota_readiness,
      routing_readiness: routing_readiness,
      quota_limits: quota_limit_rows(quota_windows, datetime_preferences)
    }
  end

  defp identity_assignments(identity, assignments, quota_readiness) do
    assignments
    |> Map.get(identity.id, [])
    |> Enum.map(&identity_assignment(&1, identity, quota_readiness))
  end

  defp identity_assignment(assignment, identity, quota_readiness) do
    assignment
    |> Map.put(:assignment_label, assignment_display_label(identity, assignment))
    |> maybe_put_current_quota_priming(quota_readiness)
  end

  defp assignment_display_label(identity, assignment) do
    current_label = account_label(identity)

    stored_label =
      present_string(Map.get(assignment, :stored_assignment_label)) ||
        present_string(Map.get(assignment, :assignment_label))

    cond do
      is_nil(stored_label) -> current_label
      stale_account_identifier_label?(stored_label, current_label) -> current_label
      true -> stored_label
    end
  end

  defp stale_account_identifier_label?(stored_label, current_label) do
    stored_label != current_label and account_identifier_label?(stored_label)
  end

  defp account_identifier_label?(label) do
    String.match?(label, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) or
      String.starts_with?(label, ["acct_", "acct-"])
  end

  defp maybe_put_current_quota_priming(assignment, %{state: "ready"}) do
    put_quota_priming(assignment, "known")
  end

  defp maybe_put_current_quota_priming(assignment, %{state: "weekly_only_probe"}) do
    put_quota_priming(assignment, "weekly_only_probe")
  end

  defp maybe_put_current_quota_priming(assignment, _quota_readiness), do: assignment

  defp put_quota_priming(assignment, status) do
    assignment
    |> Map.put(:quota_priming_status, status)
    |> Map.put(:quota_priming_label, quota_priming_label(status))
  end

  defp token_burn_summaries([]), do: %{}

  defp token_burn_summaries(identities) do
    upstream_identity_ids = Enum.map(identities, & &1.id)
    ended_at = DateTime.utc_now()
    recent_started_at = DateTime.add(ended_at, -@token_burn_recent_seconds, :second)
    baseline_started_at = DateTime.add(recent_started_at, -@token_burn_baseline_seconds, :second)

    recent_totals =
      Accounting.token_totals_by_upstream_identity_ids(
        upstream_identity_ids,
        recent_started_at,
        ended_at
      )

    baseline_totals =
      Accounting.token_totals_by_upstream_identity_ids(
        upstream_identity_ids,
        baseline_started_at,
        recent_started_at
      )

    Map.new(upstream_identity_ids, fn upstream_identity_id ->
      recent_tokens = Map.get(recent_totals, upstream_identity_id, 0)
      baseline_tokens = Map.get(baseline_totals, upstream_identity_id, 0)

      {upstream_identity_id, token_burn_summary(recent_tokens, baseline_tokens)}
    end)
  end

  defp token_burn_summary(recent_tokens, baseline_tokens) do
    level = token_burn_level(recent_tokens, baseline_tokens)

    %{
      level: level,
      label: "x#{level}",
      title:
        "last 5m: #{Format.token_count(recent_tokens)} tokens; previous 1h: #{Format.token_count(baseline_tokens)} tokens",
      recent_tokens: recent_tokens,
      baseline_tokens: baseline_tokens
    }
  end

  defp token_burn_level(recent_tokens, _baseline_tokens) when recent_tokens <= 0, do: 0
  defp token_burn_level(_recent_tokens, baseline_tokens) when baseline_tokens <= 0, do: 1

  defp token_burn_level(recent_tokens, baseline_tokens) do
    recent_rate = recent_tokens / (@token_burn_recent_seconds / 60)
    baseline_rate = baseline_tokens / (@token_burn_baseline_seconds / 60)
    ratio = recent_rate / baseline_rate

    cond do
      ratio < 0.5 -> 1
      ratio < 1.5 -> 2
      ratio < 3 -> 3
      ratio <= 6 -> 4
      true -> 5
    end
  end

  @spec quota_readiness([Quota.AccountQuotaWindow.t()]) :: UpstreamQuotaReadiness.t()
  defp quota_readiness(windows) when is_list(windows) do
    UpstreamQuotaReadiness.from_windows(windows)
  end

  defp quota_limit_rows(windows, datetime_preferences) when is_list(windows) do
    additional_limits =
      windows
      |> Enum.reject(&account_quota_window?/1)
      |> Enum.sort_by(&quota_limit_sort_key/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {window, index} ->
        quota_limit_row(
          quota_limit_key(window, index),
          quota_limit_label(window),
          window,
          datetime_preferences
        )
      end)

    [
      quota_limit_row(
        :primary_5h,
        "5h",
        quota_account_window(windows, :primary_5h),
        datetime_preferences
      ),
      quota_limit_row(
        :primary_30d,
        "30d",
        quota_account_window(windows, :monthly_primary),
        datetime_preferences
      ),
      quota_limit_row(
        :weekly,
        "Weekly",
        quota_account_window(windows, "secondary", nil),
        datetime_preferences
      )
    ] ++ additional_limits
  end

  defp account_quota_window?(%Quota.AccountQuotaWindow{
         quota_key: "account",
         quota_scope: "account"
       }),
       do: true

  defp account_quota_window?(%Quota.AccountQuotaWindow{}), do: false

  defp quota_account_window(windows, descriptor) do
    Enum.find(windows, &(WindowClassifier.classify(&1) == descriptor))
  end

  defp quota_account_window(windows, "secondary", nil) do
    Enum.find(windows, fn
      %Quota.AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        window_kind: "secondary"
      } ->
        true

      _window ->
        false
    end)
  end

  defp quota_limit_sort_key(%Quota.AccountQuotaWindow{} = window) do
    {
      quota_scope_sort_value(window.quota_scope),
      quota_limit_label(window),
      window.window_kind,
      window.window_minutes || 0,
      window.quota_key
    }
  end

  defp quota_scope_sort_value("model"), do: 0
  defp quota_scope_sort_value("upstream_model"), do: 1
  defp quota_scope_sort_value("feature"), do: 2
  defp quota_scope_sort_value(_scope), do: 3

  defp quota_limit_key(%Quota.AccountQuotaWindow{} = window, index) do
    [window.quota_scope, window.quota_key, window.window_kind, window.window_minutes || index]
    |> Enum.join("-")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
  end

  defp quota_limit_label(%Quota.AccountQuotaWindow{} = window) do
    base_label =
      [
        window.display_label,
        window.model,
        window.upstream_model,
        window.limit_name,
        window.raw_limit_name,
        window.metered_feature,
        window.quota_key
      ]
      |> Enum.find(&present_string?/1)
      |> humanize_quota_label()

    "#{base_label} #{quota_window_label(window)}"
  end

  defp quota_window_label(%Quota.AccountQuotaWindow{window_kind: "primary", window_minutes: 300}),
    do: "5h"

  defp quota_window_label(%Quota.AccountQuotaWindow{
         window_kind: "primary",
         window_minutes: minutes
       })
       when is_integer(minutes),
       do: format_window_minutes(minutes)

  defp quota_window_label(%Quota.AccountQuotaWindow{window_kind: "primary"}), do: "Primary"

  defp quota_window_label(%Quota.AccountQuotaWindow{
         window_kind: "secondary",
         window_minutes: minutes
       })
       when minutes in [nil, 10_080],
       do: "Weekly"

  defp quota_window_label(%Quota.AccountQuotaWindow{
         window_kind: "secondary",
         window_minutes: minutes
       })
       when is_integer(minutes),
       do: format_window_minutes(minutes)

  defp quota_window_label(%Quota.AccountQuotaWindow{window_kind: window_kind})
       when is_binary(window_kind) do
    window_kind
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp quota_window_label(%Quota.AccountQuotaWindow{}), do: "Window"

  defp format_window_minutes(minutes) when rem(minutes, 1_440) == 0,
    do: "#{div(minutes, 1_440)}d"

  defp format_window_minutes(minutes) when rem(minutes, 60) == 0,
    do: "#{div(minutes, 60)}h"

  defp format_window_minutes(minutes), do: "#{minutes}m"

  defp humanize_quota_label("codex_spark"), do: "GPT-5.3-Codex-Spark"
  defp humanize_quota_label("codex_other"), do: "GPT-5.3-Codex-Spark"
  defp humanize_quota_label("gpt_5_3_codex_spark"), do: "GPT-5.3-Codex-Spark"
  defp humanize_quota_label("gpt-5.3-codex-spark"), do: "GPT-5.3-Codex-Spark"

  defp humanize_quota_label(label) when is_binary(label) do
    label
    |> String.replace("_", " ")
    |> String.trim()
  end

  defp humanize_quota_label(_label), do: "Additional limit"

  defp quota_limit_row(key, label, %Quota.AccountQuotaWindow{} = window, datetime_preferences) do
    remaining_percent = quota_remaining_percent(window)

    %{
      key: key,
      label: label,
      percent: remaining_percent,
      percent_value: quota_percent_value(remaining_percent),
      percent_label: quota_percent_label(remaining_percent),
      count_label: quota_count_label(window),
      reset_label: quota_reset_label(window.reset_at),
      reset_title: quota_reset_title(window.reset_at, datetime_preferences)
    }
  end

  defp quota_limit_row(key, label, nil, _datetime_preferences) do
    %{
      key: key,
      label: label,
      percent: nil,
      percent_value: 0,
      percent_label: "not reported",
      count_label: nil,
      reset_label: nil,
      reset_title: nil
    }
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{
         credits: credits,
         active_limit: active_limit
       })
       when is_integer(credits) and is_integer(active_limit) and active_limit > 0 do
    credits
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.div(Decimal.new(active_limit))
    |> decimal_clamp_percent()
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{
         used_percent: %Decimal{} = used_percent
       }) do
    Decimal.new(100)
    |> Decimal.sub(used_percent)
    |> decimal_clamp_percent()
  end

  defp quota_remaining_percent(%Quota.AccountQuotaWindow{}), do: nil

  defp quota_percent_value(%Decimal{} = percent) do
    percent
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp quota_percent_value(_percent), do: 0

  defp quota_percent_label(%Decimal{} = percent), do: "#{quota_percent_value(percent)}%"
  defp quota_percent_label(_percent), do: "not reported"

  defp quota_count_label(%Quota.AccountQuotaWindow{credits: credits, active_limit: active_limit})
       when is_integer(credits) and is_integer(active_limit) and active_limit > 0 do
    "#{format_integer(credits)} / #{format_integer(active_limit)} credits"
  end

  defp quota_count_label(%Quota.AccountQuotaWindow{
         active_limit: active_limit,
         used_percent: %Decimal{} = used_percent
       })
       when is_integer(active_limit) and active_limit > 0 do
    remaining =
      active_limit
      |> Decimal.new()
      |> Decimal.mult(Decimal.sub(Decimal.new(100), used_percent))
      |> Decimal.div(Decimal.new(100))
      |> decimal_non_negative()
      |> Decimal.round(0)
      |> Decimal.to_integer()

    "#{format_integer(remaining)} / #{format_integer(active_limit)} credits"
  end

  defp quota_count_label(%Quota.AccountQuotaWindow{used_percent: %Decimal{}}), do: nil

  defp quota_count_label(%Quota.AccountQuotaWindow{}), do: nil

  defp quota_reset_label(%DateTime{} = reset_at) do
    seconds_until_reset = DateTime.diff(reset_at, DateTime.utc_now(), :second)

    if seconds_until_reset > 0 do
      "in #{format_reset_duration(seconds_until_reset)}"
    else
      "due"
    end
  end

  defp quota_reset_label(_reset_at), do: nil

  defp quota_reset_title(%DateTime{} = reset_at, datetime_preferences) do
    "resets #{DateTimeDisplay.format_datetime(reset_at, datetime_preferences)}"
  end

  defp quota_reset_title(_reset_at, _datetime_preferences), do: nil

  defp format_reset_duration(seconds) when seconds >= 86_400 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)

    duration_parts([{days, "d"}, {hours, "h"}])
  end

  defp format_reset_duration(seconds) when seconds >= 3_600 do
    total_minutes = div(seconds + 59, 60)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)

    duration_parts([{hours, "h"}, {minutes, "m"}])
  end

  defp format_reset_duration(seconds) when seconds >= 60 do
    minutes = div(seconds + 59, 60)

    duration_parts([{minutes, "m"}])
  end

  defp format_reset_duration(_seconds), do: "<1m"

  defp duration_parts(parts) do
    parts
    |> Enum.reject(fn {value, _unit} -> value <= 0 end)
    |> Enum.map_join(" ", fn {value, unit} ->
      "#{format_integer(value)}#{unit}"
    end)
  end

  defp decimal_clamp_percent(%Decimal{} = value) do
    value
    |> decimal_non_negative()
    |> Decimal.min(Decimal.new(100))
  end

  defp decimal_non_negative(%Decimal{} = value), do: Decimal.max(value, Decimal.new(0))

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp safe_workspace_label(value) do
    case present_string(value) do
      nil -> nil
      label -> mask_email_like(label)
    end
  end

  defp mask_email_like(value) do
    if String.match?(value, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) do
      [local, domain] = String.split(value, "@", parts: 2)
      String.slice(local, 0, min(2, String.length(local))) <> "***@" <> domain
    else
      value
    end
  end

  defp workspace_ref(nil), do: "legacy"

  defp workspace_ref(workspace_id) when is_binary(workspace_id) do
    digest =
      :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "ws:" <> digest
  end

  defp workspace_ref(_workspace_id), do: "legacy"

  defp account_label(identity) do
    present_string(identity.account_label) ||
      present_string(identity.chatgpt_account_id) ||
      "Upstream account"
  end

  defp account_plan_label(%{plan_label: label}) when is_binary(label) and label != "", do: label

  defp account_plan_label(%{plan_family: family}) when is_binary(family) and family != "",
    do: family

  defp account_plan_label(_identity), do: nil

  defp account_plan_reported?(identity), do: is_binary(account_plan_label(identity))

  defp refresh_status_label(identity) do
    identity
    |> current_token_refresh_status()
    |> Map.get("status", "not run")
  end

  defp token_refresh_label(identity, datetime_preferences) do
    identity
    |> current_token_refresh_status()
    |> token_refresh_label_from_metadata(datetime_preferences)
  end

  defp current_token_refresh_status(%{status: identity_status} = identity) do
    metadata = TokenRefresh.token_refresh_status(identity)

    if stale_reauth_required_token_refresh?(metadata, identity_status) do
      %{}
    else
      metadata
    end
  end

  defp stale_reauth_required_token_refresh?(
         %{"status" => "reauth_required"},
         identity_status
       )
       when identity_status != "reauth_required",
       do: true

  defp stale_reauth_required_token_refresh?(_metadata, _identity_status), do: false

  defp token_refresh_label_from_metadata(
         %{"status" => "succeeded"} = metadata,
         datetime_preferences
       ) do
    timestamp_status_label(
      "token refresh succeeded",
      parse_timestamp(metadata["finished_at"]),
      datetime_preferences
    )
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "failed"} = metadata,
         _datetime_preferences
       ) do
    token_refresh_failure_label("token refresh failed", metadata)
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "reauth_required"} = metadata,
         _datetime_preferences
       ) do
    token_refresh_failure_label("reauth required", metadata)
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "refreshing"} = metadata,
         datetime_preferences
       ) do
    timestamp_status_label(
      "token refresh started",
      parse_timestamp(metadata["started_at"]),
      datetime_preferences
    )
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "imported"} = metadata,
         datetime_preferences
       ) do
    timestamp_status_label(
      "token refresh imported",
      parse_timestamp(metadata["finished_at"]),
      datetime_preferences
    )
  end

  defp token_refresh_label_from_metadata(%{"status" => status}, _datetime_preferences)
       when is_binary(status),
       do: "token refresh #{String.replace(status, "_", " ")}"

  defp token_refresh_label_from_metadata(_metadata, _datetime_preferences),
    do: "token refresh not run"

  defp token_refresh_failure_label(prefix, %{"reason" => %{} = reason}) do
    message = present_string(reason["message"])
    code = present_string(reason["code"])

    cond do
      message && code -> "#{token_refresh_message_label(prefix, message)} (#{code})"
      message -> token_refresh_message_label(prefix, message)
      code -> "#{prefix}: #{code}"
      true -> prefix
    end
  end

  defp token_refresh_failure_label(prefix, _metadata), do: prefix

  defp token_refresh_message_label(prefix, message) do
    if String.starts_with?(message, "#{prefix}:") do
      message
    else
      "#{prefix}: #{message}"
    end
  end

  defp access_token_label(%{metadata: %{} = metadata}, datetime_preferences) do
    case parse_timestamp(metadata["access_token_expires_at"]) do
      %DateTime{} = expires_at -> access_token_expiry_label(expires_at, datetime_preferences)
      nil -> "access token expiry not reported"
    end
  end

  defp access_token_label(_identity, _datetime_preferences),
    do: "access token expiry not reported"

  defp access_token_expiry_label(%DateTime{} = expires_at, datetime_preferences) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      timestamp_status_label("access token expired", expires_at, datetime_preferences)
    else
      timestamp_status_label("access token expires", expires_at, datetime_preferences)
    end
  end

  defp reauth_required?(%{status: "reauth_required"}), do: true
  defp reauth_required?(_identity), do: false

  defp reauth_reason_code(identity) do
    identity
    |> token_refresh_reason()
    |> Map.get("code")
  end

  defp reauth_reason_message(identity) do
    identity
    |> token_refresh_reason()
    |> Map.get("message")
  end

  defp token_refresh_reason(identity) do
    identity
    |> current_token_refresh_status()
    |> Map.get("reason", %{})
  end

  defp refresh_job_state(nil), do: nil
  defp refresh_job_state(%{state: state}) when is_binary(state), do: state
  defp refresh_job_state(_job), do: nil

  defp quota_refresh_status(assignments, datetime_preferences) do
    assignments
    |> Enum.map(& &1.last_successful_refresh_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
    |> case do
      %DateTime{} = refreshed_at ->
        DateTimeDisplay.format_datetime(refreshed_at, datetime_preferences)

      nil ->
        "not run"
    end
  end

  defp pool_label(nil), do: "Unknown Pool"
  defp pool_label(pool), do: "#{pool.name} (#{pool.slug})"

  defp timestamp_status_label(prefix, %DateTime{} = timestamp, datetime_preferences) do
    "#{prefix} #{DateTimeDisplay.format_datetime(timestamp, datetime_preferences)} · #{relative_time_label(timestamp)}"
  end

  defp timestamp_status_label(prefix, _timestamp, _datetime_preferences),
    do: "#{prefix} not reported"

  defp relative_time_label(%DateTime{} = timestamp) do
    diff = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff < -60 -> "in #{format_reset_duration(abs(diff))}"
      diff < 60 -> "just now"
      true -> "#{format_reset_duration(diff)} ago"
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> nil
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp
  defp parse_timestamp(_value), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil
end
