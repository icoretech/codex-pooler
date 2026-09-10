defmodule CodexPooler.Metrics.AccountProjection do
  @moduledoc "Pure, bounded native account metric projection. No polling or credentials."

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Metrics.AccountValues, as: V
  alias CodexPooler.Quotas.{Evidence, SourceObservations}

  alias CodexPooler.Upstreams.Quota.{
    AccountAvailabilityStore,
    AccountQuotaWindow,
    RoutingQuotaSnapshot
  }

  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @statuses ~w(pending active paused refresh_due refreshing refresh_failed reauth_required deleted disabled errored unknown)
  @health ~w(unknown active cooldown degraded disabled errored)
  @eligibility ~w(eligible ineligible unknown)
  @readiness ~w(ready weekly_only_probe provider_available_no_windows exhausted stale missing_evidence blocked unknown)
  @sources ~w(codex_usage_api codex_response_headers codex_rate_limit_event codex_rate_limit_error local_reconciliation unknown)

  def project(snapshot) do
    identities =
      snapshot.identities |> Enum.reject(&(&1.status == "deleted")) |> Enum.uniq_by(& &1.id)

    account_ids = MapSet.new(identities, & &1.id)

    memberships =
      snapshot.memberships
      |> Enum.filter(&MapSet.member?(account_ids, &1.upstream_identity_id))
      |> Enum.reject(&(&1.status == "deleted"))
      |> Enum.uniq_by(&{&1.upstream_identity_id, &1.pool_id})

    by_account = Enum.group_by(memberships, & &1.upstream_identity_id)
    windows = Enum.group_by(snapshot.windows, & &1.upstream_identity_id)

    accounts =
      Enum.map(identities, fn identity ->
        project_account(
          identity,
          Map.get(by_account, identity.id, []),
          Map.get(windows, identity.id, []),
          snapshot.as_of
        )
      end)

    %{
      complete: Enum.all?(accounts, & &1.complete),
      samples: Enum.flat_map(accounts, & &1.samples),
      accounts: length(identities),
      memberships:
        Enum.reduce(by_account, 0, fn {_id, rows}, total -> total + row_count(rows) end),
      groups: Enum.sum(Enum.map(accounts, & &1.groups)),
      observations: Enum.sum(Enum.map(accounts, & &1.observations)),
      as_of: snapshot.as_of
    }
  end

  defp project_account(identity, memberships, rows, as_of) do
    labels = [
      account_id: V.uuid!(identity.id),
      provider: V.closed(identity.credential_provenance, ["codex_chatgpt_oauth"])
    ]

    inventory = [
      sample(:account_info, labels, 1),
      sample(
        :account_state,
        labels ++ [state: V.closed(identity.status, @statuses -- ["deleted"])],
        1
      ),
      sample(
        :account_disabled,
        labels,
        V.flag(identity.status == "disabled" or identity.disabled_at != nil)
      ),
      sample(:account_reauth_required, labels, V.flag(identity.status == "reauth_required"))
    ]

    account_sections(identity, memberships, rows, as_of, labels, inventory)
  end

  defp account_sections(identity, memberships, rows, as_of, labels, inventory) do
    if row_count(rows) > 512 or row_count(memberships) > 64 do
      incomplete(inventory, labels, true)
    else
      bounded_groups(identity, memberships, rows, as_of, labels, inventory)
    end
  rescue
    _exception -> incomplete(inventory, labels, false)
  end

  defp bounded_groups(identity, memberships, rows, as_of, labels, inventory) do
    groups = rows |> Enum.map(&window/1) |> SourceObservations.groups(as_of)

    if map_size(groups) > 64 or Enum.any?(groups, fn {_key, values} -> length(values) > 8 end) do
      incomplete(inventory, labels, true)
    else
      complete_sections(identity, memberships, rows, groups, as_of, labels, inventory)
    end
  end

  defp complete_sections(identity, memberships, rows, groups, as_of, labels, inventory) do
    visible = groups |> Map.values() |> List.flatten()
    snapshot = routing_snapshot(identity, visible, as_of)

    selected =
      snapshot
      |> RoutingQuotaSnapshot.effective_windows(emit_telemetry: false)
      |> MapSet.new(& &1.id)

    identifiers = Map.new(rows, &{&1.id, V.observation_id(&1)})

    group_samples =
      groups
      |> Enum.sort()
      |> Enum.flat_map(fn {key, values} ->
        quota_samples(key, values, selected, identifiers, labels, as_of)
      end)

    samples =
      inventory ++
        [
          sample(:account_projection_complete, labels, 1),
          sample(:account_projection_overflow, labels, 0)
        ] ++
        account_evidence(snapshot, visible, labels) ++
        Enum.flat_map(memberships, &membership_samples(&1, labels, as_of)) ++ group_samples

    %{complete: true, samples: samples, groups: map_size(groups), observations: length(visible)}
  end

  defp incomplete(inventory, labels, overflow) do
    %{
      complete: false,
      samples:
        inventory ++
          [
            sample(:account_projection_complete, labels, 0),
            sample(:account_projection_overflow, labels, V.flag(overflow))
          ],
      groups: 0,
      observations: 0
    }
  end

  defp window(row) do
    row
    |> Map.drop([:index_model, :index_upstream_model, :row_count])
    |> then(&struct!(AccountQuotaWindow, &1))
    |> Map.update!(:used_percent, &V.percent/1)
    |> Map.update!(:observed_at, &V.timestamp/1)
    |> Map.update!(:reset_at, &V.timestamp/1)
    |> Map.update!(:last_sync_at, &V.timestamp/1)
    |> Map.update!(:updated_at, &V.timestamp/1)
    |> unknown_freshness()
  end

  defp unknown_freshness(%{observed_at: nil} = window), do: %{window | freshness_state: "unknown"}
  defp unknown_freshness(window), do: window

  defp routing_snapshot(identity, windows, as_of) do
    identity = struct!(UpstreamIdentity, identity)
    known = Enum.filter(windows, &match?(%DateTime{}, &1.observed_at))
    snapshot = RoutingQuotaSnapshot.from_identity(identity, known, as_of)

    # Availability's ordinary clock-skew tolerance is intentionally not an
    # assertion that a future report existed at this scrape's snapshot time.
    if snapshot.availability &&
         is_nil(V.visible_timestamp(snapshot.availability.observed_at, as_of)),
       do: %{snapshot | availability: nil},
       else: snapshot
  end

  defp account_evidence(snapshot, windows, labels) do
    as_of = snapshot.as_of
    availability = snapshot.availability
    current = availability && availability.credential_epoch == snapshot.credential_epoch
    observed = if current, do: availability.observed_at

    state =
      cond do
        AccountAvailabilityStore.available?(availability, snapshot.credential_epoch, as_of) ->
          "available"

        AccountAvailabilityStore.blocked?(availability, snapshot.credential_epoch, as_of) ->
          "blocked"

        true ->
          "unknown"
      end

    readiness = UpstreamQuotaReadiness.from_snapshot(snapshot, emit_telemetry: false).state
    unknown_time = Enum.any?(windows, &is_nil(&1.observed_at))

    readiness =
      if unknown_time and readiness not in ["blocked", "exhausted"],
        do: "unknown",
        else: readiness

    last =
      windows
      |> Enum.map(& &1.observed_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    [
      sample(:account_has_quota_observation, labels, V.flag(windows != [])),
      sample(:account_last_quota_observation_timestamp_seconds, labels, V.seconds(last)),
      sample(:account_provider_availability_state, labels ++ [state: state], 1),
      sample(
        :account_provider_availability_observed_timestamp_seconds,
        labels,
        V.seconds(observed)
      ),
      sample(:account_quota_readiness, labels ++ [state: V.closed(readiness, @readiness)], 1)
    ]
  end

  defp membership_samples(row, labels, as_of) do
    labels = labels ++ [pool_id: V.uuid!(row.pool_id)]
    finished = V.visible_timestamp(row.reconciliation_finished_at, as_of)
    status = V.closed(row.reconciliation_status, ~w(succeeded partial failed))
    valid = finished != nil and status != "unknown"

    [
      sample(:account_pool_membership, labels, 1),
      sample(
        :account_pool_state,
        labels ++
          [
            status: V.closed(row.status, @statuses),
            health: V.closed(row.health_status, @health),
            eligibility: V.closed(row.eligibility_status, @eligibility)
          ],
        1
      ),
      sample(
        :account_pool_reconciliation_state,
        labels ++ [state: if(valid, do: status, else: "unknown")],
        1
      ),
      sample(
        :account_pool_reconciliation_timestamp_seconds,
        labels,
        if(valid, do: V.seconds(finished))
      ),
      sample(
        :account_pool_last_successful_reconciliation_timestamp_seconds,
        labels,
        row.last_successful_refresh_at |> V.visible_timestamp(as_of) |> V.seconds()
      )
    ]
  end

  defp quota_samples(key, windows, selected, identifiers, labels, as_of) do
    first = hd(windows)
    labels = labels ++ group_labels(windows, key)

    group = [
      sample(:account_quota_info, labels, 1),
      sample(:account_quota_window_duration_seconds, labels, duration(first.window_minutes)),
      sample(
        :account_quota_routing_selection_present,
        labels,
        V.flag(Enum.any?(windows, &MapSet.member?(selected, &1.id)))
      )
    ]

    group ++
      Enum.flat_map(windows, &observation_samples(&1, labels, selected, identifiers, as_of))
  end

  defp group_labels(windows, key) do
    labels = Enum.map(windows, &meter_labels(&1, key))
    buckets = labels |> Enum.map(&Keyword.fetch!(&1, :bucket)) |> Enum.uniq()

    bucket =
      case buckets do
        [single] -> single
        _conflicting_descriptors -> "other"
      end

    labels |> hd() |> Keyword.put(:bucket, bucket)
  end

  defp meter_labels(window, key) do
    {scope, _family, _model, _upstream_model, quota_key, kind, minutes} =
      WindowSelector.logical_key(window)

    kind = if kind == "primary" and minutes == 10_080, do: "secondary", else: kind

    [
      scope: V.closed(scope, ~w(account model upstream_model feature)),
      bucket: bucket(scope, quota_key, window),
      window: window_name(minutes),
      window_kind: V.closed(kind, ~w(primary secondary)),
      meter_id: key
    ]
  end

  defp bucket("account", "account", _window), do: "account"
  defp bucket(scope, "codex_spark", _window) when scope in ~w(model upstream_model), do: "spark"

  defp bucket(_scope, _key, %{
         limit_name: "GPT-Reserve",
         raw_metered_feature: "base_model_inference"
       }),
       do: "reserve"

  defp bucket(_scope, _key, _window), do: "other"
  defp window_name(300), do: "5h"
  defp window_name(10_080), do: "7d"
  defp window_name(43_200), do: "30d"
  defp window_name(_minutes), do: "other"
  defp duration(minutes) when is_integer(minutes) and minutes > 0, do: minutes * 60
  defp duration(_minutes), do: nil

  defp observation_samples(window, labels, selected, identifiers, as_of) do
    labels =
      labels ++
        [
          source: V.closed(window.source, @sources),
          observation_id: Map.fetch!(identifiers, window.id)
        ]

    used = window.used_percent
    remaining = if used, do: Decimal.sub(100, used)

    freshness =
      if window.observed_at, do: Evidence.current_freshness_state(window, as_of), else: "unknown"

    [
      sample(:account_quota_observation_info, labels, 1),
      sample(:account_quota_observation_used_percent, labels, used),
      sample(:account_quota_observation_remaining_percent, labels, remaining),
      sample(
        :account_quota_observation_reset_timestamp_seconds,
        labels,
        V.seconds(window.reset_at)
      ),
      sample(:account_quota_observation_timestamp_seconds, labels, V.seconds(window.observed_at)),
      sample(
        :account_quota_observation_freshness,
        labels ++ [state: V.closed(freshness, ~w(fresh stale unknown))],
        1
      ),
      sample(
        :account_quota_observation_elapsed,
        labels,
        V.flag(Evidence.expired?(window, as_of))
      ),
      sample(:account_quota_observation_used_known, labels, V.flag(used != nil)),
      sample(
        :account_quota_observation_routing_selected,
        labels,
        V.flag(MapSet.member?(selected, window.id))
      )
    ]
  end

  defp row_count([]), do: 0

  defp row_count(rows),
    do: max(length(rows), Enum.max(Enum.map(rows, &Map.get(&1, :row_count, 0))))

  defp sample(name, labels, value), do: {name, labels, value}
end
