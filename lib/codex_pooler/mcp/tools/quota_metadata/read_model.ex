defmodule CodexPooler.MCP.Tools.QuotaMetadata.ReadModel do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.Pools
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @default_limit 50
  @max_limit 100
  @max_offset 10_000
  @max_windows_per_account 50

  @freshness_fresh "fresh"
  @freshness_stale "stale"
  @freshness_unknown "unknown"

  @quota_kind_account_primary "account_primary"
  @quota_kind_account_secondary "account_secondary"
  @quota_kind_model_primary "model_primary"
  @quota_kind_model_secondary "model_secondary"
  @quota_kind_additional "additional"
  @quota_kind_unknown "unknown"

  @reason_exhausted "exhausted"
  @reason_reset_missing "reset_missing"
  @reason_stale "stale"
  @reason_unknown_evidence "unknown_evidence"
  @reason_severity [
    @reason_exhausted,
    @reason_reset_missing,
    @reason_stale,
    @reason_unknown_evidence
  ]
  @reason_map %{
    "exhausted" => @reason_exhausted,
    "reset_missing" => @reason_reset_missing,
    "expired" => @reason_stale,
    "not_fresh" => @reason_stale,
    "unknown_unusable" => @reason_unknown_evidence
  }

  @source_precisions ~w(authoritative observed inferred unknown)

  @type list_opts :: keyword() | map()

  @spec list_accounts(term(), list_opts()) :: map()
  def list_accounts(scope, opts \\ [])

  def list_accounts(%Scope{} = scope, opts) do
    opts = Map.new(opts)
    limit = bounded_limit(Map.get(opts, :limit) || Map.get(opts, "limit"))
    offset = bounded_offset(Map.get(opts, :offset) || Map.get(opts, "offset"))
    timestamp = Map.get(opts, :at) || Map.get(opts, "at") || now()

    visible_pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)

    accounts =
      scope
      |> Upstreams.list_visible_upstream_identities()
      |> Enum.map(&account_summary(&1, timestamp, visible_pool_ids))
      |> Enum.sort_by(&account_sort_key/1)

    %{
      items: accounts |> Enum.drop(offset) |> Enum.take(limit),
      count: length(accounts),
      limit: limit,
      offset: offset
    }
  end

  def list_accounts(_scope, opts) do
    opts = Map.new(opts)
    limit = bounded_limit(Map.get(opts, :limit) || Map.get(opts, "limit"))
    offset = bounded_offset(Map.get(opts, :offset) || Map.get(opts, "offset"))

    %{items: [], count: 0, limit: limit, offset: offset}
  end

  @spec account_summary(UpstreamIdentity.t(), DateTime.t()) :: map()
  def account_summary(%UpstreamIdentity{} = identity, timestamp \\ now()) do
    account_summary(identity, timestamp, :all)
  end

  defp account_summary(%UpstreamIdentity{} = identity, timestamp, visible_pool_ids) do
    # the effective window view must be computed at the same timestamp the
    # serialization and usability checks below use: a historical `at` must
    # neither see future evidence nor select rows that only became effective
    # after that instant
    all_windows =
      identity
      |> Quota.Windows.list_quota_windows(timestamp)
      |> Enum.map(&quota_window(&1, timestamp))
      |> Enum.sort_by(&window_sort_key/1)

    returned_windows = Enum.take(all_windows, @max_windows_per_account)

    %{
      id: identity.id,
      label: safe_label(identity.account_label),
      stored_account_id: present_string(identity.chatgpt_account_id),
      workspace_ref: workspace_ref(identity.workspace_id),
      workspace_label: safe_label(identity.workspace_label),
      status: identity.status,
      plan_family: present_string(identity.plan_family),
      assignment_summary: assignment_summary(identity, visible_pool_ids),
      quota_summary: quota_summary(all_windows),
      quota_windows: returned_windows
    }
  end

  @spec quota_window(Quota.AccountQuotaWindow.t(), DateTime.t()) :: map()
  def quota_window(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    freshness_status = freshness_status(window, timestamp)
    reset_only? = reset_only_window?(window)
    routing_usable = Quota.Windows.usable_window?(window, timestamp) and not reset_only?
    routing_unusable_reason = routing_unusable_reason(window, timestamp, routing_usable)

    %{
      quota_kind: quota_kind(window),
      quota_scope: sanitized_string(window.quota_scope),
      quota_family: sanitized_string(window.quota_family),
      model: sanitized_string(window.model),
      upstream_model: sanitized_string(window.upstream_model),
      window_minutes: integer_or_nil(window.window_minutes),
      active_limit: integer_or_nil(window.active_limit),
      remaining_value: integer_or_nil(window.credits),
      credits: integer_or_nil(window.credits),
      used_percent: rounded_percent(window.used_percent),
      reset_at: timestamp(window.reset_at),
      observed_at: timestamp(window.observed_at),
      freshness_status: freshness_status,
      routing_usable: routing_usable,
      routing_unusable_reason: routing_unusable_reason,
      source_precision: source_precision(window.source_precision)
    }
  end

  defp assignment_summary(%UpstreamIdentity{} = identity, :all) do
    assignments = UpstreamAssignments.list_pool_assignments_for_identity(identity)

    assignment_summary_from(identity, assignments)
  end

  defp assignment_summary(%UpstreamIdentity{} = identity, visible_pool_ids) do
    visible_pool_ids = MapSet.new(visible_pool_ids)

    assignments =
      identity
      |> UpstreamAssignments.list_pool_assignments_for_identity()
      |> Enum.reject(&(&1.status == "deleted"))
      |> Enum.filter(&MapSet.member?(visible_pool_ids, &1.pool_id))

    assignment_summary_from(identity, assignments)
  end

  defp assignment_summary_from(identity, assignments) do
    active_count = Enum.count(assignments, &(&1.status == "active"))

    %{
      count: length(assignments),
      status: identity.status,
      summary: "#{active_count} active of #{length(assignments)} Pool assignments"
    }
  end

  defp quota_summary([]) do
    %{
      window_count: 0,
      truncated: false,
      freshness_status: @freshness_unknown,
      routing_usable: false,
      has_unknown: true,
      has_stale: false
    }
  end

  defp quota_summary(windows) do
    has_stale = Enum.any?(windows, &(&1.freshness_status == @freshness_stale))
    has_unknown = Enum.any?(windows, &(&1.freshness_status == @freshness_unknown))

    freshness_status =
      cond do
        has_stale -> @freshness_stale
        has_unknown -> @freshness_unknown
        true -> @freshness_fresh
      end

    %{
      window_count: length(windows),
      truncated: length(windows) > @max_windows_per_account,
      freshness_status: freshness_status,
      routing_usable: Enum.any?(windows, & &1.routing_usable),
      has_unknown: has_unknown,
      has_stale: has_stale
    }
  end

  defp quota_kind(%Quota.AccountQuotaWindow{} = window) do
    tokens = quota_kind_tokens(window)
    model? = model_scoped_window?(window)
    secondary? = secondary_quota_window?(window, tokens, model?)

    cond do
      quota_kind_token?(tokens, "additional") -> @quota_kind_additional
      model? and secondary? -> @quota_kind_model_secondary
      model? -> @quota_kind_model_primary
      secondary? -> @quota_kind_account_secondary
      account_quota_window?(window) -> @quota_kind_account_primary
      true -> @quota_kind_unknown
    end
  end

  defp model_scoped_window?(%Quota.AccountQuotaWindow{} = window) do
    present_string?(window.model) or present_string?(window.upstream_model)
  end

  defp secondary_quota_window?(%Quota.AccountQuotaWindow{} = window, tokens, true) do
    quota_kind_token?(tokens, "secondary") or long_quota_window?(window.window_minutes)
  end

  defp secondary_quota_window?(%Quota.AccountQuotaWindow{} = window, tokens, false) do
    quota_kind_token?(tokens, "secondary") or WindowClassifier.weekly_secondary?(window)
  end

  defp long_quota_window?(window_minutes) when is_integer(window_minutes),
    do: window_minutes >= 10_080

  defp long_quota_window?(_window_minutes), do: false

  defp quota_kind_token?(tokens, marker), do: Enum.any?(tokens, &String.contains?(&1, marker))

  defp account_quota_window?(%Quota.AccountQuotaWindow{} = window) do
    sanitized_string(window.quota_scope || "account") == "account"
  end

  defp quota_kind_tokens(%Quota.AccountQuotaWindow{} = window) do
    [
      window.quota_scope,
      window.quota_family,
      window.quota_key,
      window.window_kind
    ]
    |> Enum.map(&sanitized_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp freshness_status(%Quota.AccountQuotaWindow{} = window, timestamp) do
    cond do
      Quota.Windows.fresh_window?(window, timestamp) -> @freshness_fresh
      window.freshness_state == @freshness_unknown -> @freshness_unknown
      true -> @freshness_stale
    end
  end

  defp routing_unusable_reason(_window, _timestamp, true), do: nil

  defp routing_unusable_reason(window, timestamp, false) do
    window
    |> Quota.Windows.routing_window_reason_codes(timestamp)
    |> Enum.map(&Map.get(@reason_map, &1))
    |> Enum.reject(&is_nil/1)
    |> most_severe_reason()
  end

  defp reset_only_window?(%Quota.AccountQuotaWindow{} = window) do
    not is_nil(window.reset_at) and is_nil(window.active_limit) and is_nil(window.credits) and
      is_nil(window.used_percent)
  end

  defp most_severe_reason([]), do: @reason_unknown_evidence

  defp most_severe_reason(reasons) do
    Enum.find(@reason_severity, &(&1 in reasons)) || @reason_unknown_evidence
  end

  defp account_sort_key(account) do
    {
      account.label || "",
      account.workspace_ref || "",
      account.id || "",
      account.quota_windows |> List.first(%{}) |> Map.get(:quota_kind, ""),
      account.quota_windows |> List.first(%{}) |> model_sort_value(),
      account.quota_windows |> List.first(%{}) |> Map.get(:reset_at, "")
    }
  end

  defp window_sort_key(window) do
    {
      window.quota_kind || "",
      model_sort_value(window),
      window.reset_at || ""
    }
  end

  defp model_sort_value(window),
    do: Map.get(window, :model) || Map.get(window, :upstream_model) || ""

  defp bounded_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp bounded_limit(_limit), do: @default_limit

  defp bounded_offset(offset) when is_integer(offset), do: offset |> max(0) |> min(@max_offset)
  defp bounded_offset(_offset), do: 0

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp rounded_percent(nil), do: nil

  defp rounded_percent(%Decimal{} = value) do
    value
    |> Decimal.to_float()
    |> Float.round(1)
  end

  defp rounded_percent(value) when is_integer(value), do: value * 1.0
  defp rounded_percent(value) when is_float(value), do: Float.round(value, 1)
  defp rounded_percent(_value), do: nil

  defp timestamp(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(_value), do: nil

  defp source_precision(value) when value in @source_precisions, do: value
  defp source_precision(_value), do: nil

  defp workspace_ref(nil), do: "legacy"

  defp workspace_ref(workspace_id) when is_binary(workspace_id) do
    digest =
      :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "ws:" <> digest
  end

  defp workspace_ref(_workspace_id), do: "legacy"

  defp safe_label(value) when is_binary(value) do
    value = String.trim(value)

    if String.match?(value, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) do
      PrivacyMatrix.project!(:operators, %{email: value})[:email]
    else
      value
    end
  end

  defp safe_label(_value), do: nil

  defp sanitized_string(value) when is_binary(value), do: present_string(value)
  defp sanitized_string(_value), do: nil

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_value), do: nil

  defp present_string?(value), do: not is_nil(present_string(value))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
