defmodule CodexPooler.Upstreams.Quota.Windows.ProviderCycleConfirmationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @confirmation_key "__quota_cycle_confirmation_v1"
  @old_reset ~U[2026-07-25 03:24:36Z]
  @new_reset ~U[2026-07-28 17:04:16Z]
  @scenario_timeout_ms 5_000
  @detection_timeout_ms 15_000

  @tag :provider_cycle_confirmation
  test "separate fixed-forward observations durably confirm an anchored provider cycle" do
    identity = identity!()
    canonical_at = ~U[2026-07-21 17:00:00Z]
    candidate_at = ~U[2026-07-21 17:04:00Z]
    confirmed_at = ~U[2026-07-21 17:08:00Z]

    provider_row!(identity, canonical_at, "54", @old_reset)
    runtime_row!(identity, canonical_at, "54", @old_reset)

    assert {:ok, _row} =
             record_provider(identity, candidate_at, "0", @new_reset, provider_at: candidate_at)

    pending = provider_row(identity)
    assert Decimal.equal?(pending.used_percent, Decimal.new("54"))
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(pending.metadata)

    assert Windows.quota_window_selection_data(identity, at: candidate_at).secondary.source !=
             "codex_usage_api"

    assert {:ok, _row} =
             record_provider(identity, confirmed_at, "0", @new_reset, provider_at: confirmed_at)

    confirmed = provider_row(identity)
    marker = confirmed.metadata[@confirmation_key]

    assert confirmed.metadata["reset_state"] == "anchored"
    assert marker["version"] == 1
    assert marker["scope"] == "account"
    assert marker["family"] == "account"
    assert marker["key"] == "account"
    assert marker["kind"] == "secondary"
    assert marker["minutes"] == 10_080
    assert marker["model"] == nil
    assert marker["upstream_model"] == nil
    assert marker["reset_at"] == DateTime.to_iso8601(@new_reset)
    assert marker["provider_observed_at"] == DateTime.to_iso8601(confirmed_at)
    assert marker["confirmed_at"] == DateTime.to_iso8601(confirmed_at)
    assert marker["source_class"] == "provider_usage"

    selection = Windows.quota_window_selection_data(identity, at: confirmed_at)
    assert selection.secondary.id == confirmed.id
    assert Windows.list_quota_windows(identity, confirmed_at) == [confirmed]
    assert Windows.routing_quota_eligibility(identity, at: confirmed_at).eligible?

    matching_runtime_at = DateTime.add(confirmed_at, 60, :second)
    matching_runtime = runtime_row!(identity, matching_runtime_at, "1", @new_reset)

    assert Windows.quota_window_selection_data(identity, at: matching_runtime_at).secondary.id ==
             matching_runtime.id
  end

  @tag :provider_cycle_confirmation
  test "equivalent fixed-anchor maintenance has exact drift boundaries" do
    for {drift_seconds, expected} <- [
          {5, :same_cycle},
          {6, :equivalent},
          {300, :equivalent},
          {301, :candidate}
        ] do
      identity = identity!()
      accepted_at = ~U[2026-07-21 17:06:00Z]
      accepted_reset = ~U[2026-07-28 17:06:01Z]
      incoming_at = ~U[2026-07-22 01:14:00Z]
      incoming_reset = DateTime.add(accepted_reset, drift_seconds, :second)

      provider_row!(identity, accepted_at, "0", accepted_reset,
        provider_at: ~U[2026-07-21 17:06:01Z]
      )

      assert {:ok, _row} =
               record_provider(identity, incoming_at, "0", incoming_reset,
                 provider_at: incoming_at
               )

      row = provider_row(identity)

      case expected do
        :same_cycle ->
          assert DateTime.compare(row.reset_at, accepted_reset) == :eq
          assert DateTime.compare(row.observed_at, incoming_at) == :eq
          refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")

        :equivalent ->
          assert DateTime.compare(row.reset_at, incoming_reset) == :eq
          assert DateTime.compare(row.observed_at, incoming_at) == :eq
          assert DateTime.compare(row.last_sync_at, incoming_at) == :eq
          refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")

        :candidate ->
          assert DateTime.compare(row.reset_at, accepted_reset) == :eq
          assert DateTime.compare(row.observed_at, accepted_at) == :eq
          assert Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")
      end
    end
  end

  @tag :provider_cycle_confirmation
  test "equivalent fixed-anchor maintenance rejects a future provider watermark" do
    identity = identity!()
    accepted_at = ~U[2026-07-21 17:06:00Z]
    accepted_reset = ~U[2026-07-28 17:06:01Z]
    incoming_at = ~U[2026-07-22 01:14:00Z]
    incoming_reset = DateTime.add(accepted_reset, 179, :second)

    provider_row!(identity, accepted_at, "0", accepted_reset, provider_at: accepted_at)

    assert {:ok, _row} =
             record_provider(identity, incoming_at, "0", incoming_reset,
               provider_at: DateTime.add(incoming_at, 1, :second)
             )

    unchanged = provider_row(identity)
    assert DateTime.compare(unchanged.reset_at, accepted_reset) == :eq
    assert DateTime.compare(unchanged.observed_at, accepted_at) == :eq
    refute Map.has_key?(unchanged.metadata, "__quota_confirmed_candidate_v1")
  end

  @tag :provider_cycle_confirmation
  test "fixed-forward candidate and confirmation reject future provider watermarks" do
    canonical_at = ~U[2026-07-21 17:00:00Z]
    candidate_at = ~U[2026-07-21 17:04:00Z]

    for provider_at <- [candidate_at, DateTime.add(candidate_at, 1, :microsecond)] do
      candidate_identity = identity!()
      provider_row!(candidate_identity, canonical_at, "54", @old_reset)

      assert {:ok, _row} =
               record_provider(candidate_identity, candidate_at, "0", @new_reset,
                 provider_at: provider_at
               )

      candidate_row = provider_row(candidate_identity)

      if DateTime.compare(provider_at, candidate_at) == :eq do
        assert {:ok, _candidate} = EvidenceStore.parse_candidate(candidate_row.metadata)
      else
        assert Decimal.equal?(candidate_row.used_percent, Decimal.new("54"))
        refute Map.has_key?(candidate_row.metadata, "__quota_confirmed_candidate_v1")
      end
    end

    confirmation_identity = identity!()
    confirmed_at = ~U[2026-07-21 17:08:00Z]

    provider_row!(confirmation_identity, canonical_at, "54", @old_reset)

    assert {:ok, _row} =
             record_provider(confirmation_identity, candidate_at, "0", @new_reset,
               provider_at: candidate_at
             )

    assert {:ok, _candidate} =
             EvidenceStore.parse_candidate(provider_row(confirmation_identity).metadata)

    assert {:ok, _row} =
             record_provider(confirmation_identity, confirmed_at, "0", @new_reset,
               provider_at: DateTime.add(confirmed_at, 1, :microsecond)
             )

    unconfirmed = provider_row(confirmation_identity)
    assert Decimal.equal?(unconfirmed.used_percent, Decimal.new("54"))
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(unconfirmed.metadata)
    refute Map.has_key?(unconfirmed.metadata, @confirmation_key)
  end

  @tag :provider_cycle_confirmation
  test "equivalent fixed-anchor refresh log remains identifier-free" do
    account_label = "Example fixed account #{System.unique_integer([:positive])}"
    assignment_label = "Example fixed assignment #{System.unique_integer([:positive])}"

    %{identity: identity} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        account_label: account_label,
        assignment_label: assignment_label
      })

    accepted_at = ~U[2026-07-21 17:06:00Z]
    accepted_reset = ~U[2026-07-28 17:06:01Z]
    incoming_at = ~U[2026-07-22 01:14:00Z]
    incoming_reset = DateTime.add(accepted_reset, 179, :second)

    provider_row!(identity, accepted_at, "0", accepted_reset, provider_at: accepted_at)

    {log, events} =
      capture_quota_cycle_events(fn ->
        capture_info_log(fn ->
          assert {:ok, _row} =
                   record_provider(identity, incoming_at, "0", incoming_reset,
                     provider_at: incoming_at
                   )
        end)
      end)

    assert events == [
             {%{count: 1},
              %{
                scope: "account",
                decision: :same_cycle_refreshed,
                source: "provider_usage"
              }}
           ]

    assert log =~
             "quota_cycle_decision decision=same_cycle_refreshed reason=equivalent_live_anchor"

    assert log =~ "scope=account source=provider_usage candidate_age_s=nil"
    refute log =~ "upstream_identity_id"
    refute log =~ account_label
    refute log =~ assignment_label
    refute log =~ identity.id
    refute log =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

    event_output = inspect(events)
    refute event_output =~ account_label
    refute event_output =~ assignment_label
    refute event_output =~ identity.id
    refute event_output =~ "upstream_identity_id"
  end

  @tag :provider_cycle_confirmation
  test "equivalent maintenance preserves only a valid matching marker" do
    accepted_at = ~U[2026-07-21 17:06:00Z]
    accepted_reset = ~U[2026-07-28 17:06:01Z]
    confirmed_at = ~U[2026-07-21 17:05:00Z]

    incoming_at = ~U[2026-07-21 17:14:00Z]

    for marker_state <- [:absent, :valid, :malformed, :mismatched] do
      incoming_reset = DateTime.add(accepted_reset, 179, :second)
      identity = identity!()
      provider_row!(identity, accepted_at, "0", accepted_reset, provider_at: accepted_at)
      row = provider_row(identity)

      metadata =
        case marker_state do
          :absent ->
            row.metadata

          :valid ->
            row.metadata
            |> Map.put("reset_state", "anchored")
            |> Map.put(@confirmation_key, marker(row, accepted_at, confirmed_at))

          :malformed ->
            row.metadata
            |> Map.put("reset_state", "anchored")
            |> Map.put(@confirmation_key, %{"version" => 1})

          :mismatched ->
            row.metadata
            |> Map.put("reset_state", "anchored")
            |> Map.put(@confirmation_key, %{
              marker(row, accepted_at, confirmed_at)
              | "key" => "other"
            })
        end

      row |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

      assert {:ok, _row} =
               record_provider(identity, incoming_at, "0", incoming_reset,
                 provider_at: incoming_at
               )

      maintained = provider_row(identity)

      case marker_state do
        :absent ->
          refute Map.has_key?(maintained.metadata, @confirmation_key)

        :valid ->
          updated = maintained.metadata[@confirmation_key]
          assert updated["confirmed_at"] == DateTime.to_iso8601(confirmed_at)
          assert updated["reset_at"] == DateTime.to_iso8601(incoming_reset)
          assert updated["provider_observed_at"] == DateTime.to_iso8601(incoming_at)

        state when state in [:malformed, :mismatched] ->
          assert maintained.metadata[@confirmation_key] == metadata[@confirmation_key]
      end
    end
  end

  @tag :provider_cycle_confirmation
  test "equivalent maintenance leaves a stale marker untouched and unusable" do
    accepted_at = ~U[2026-07-21 17:06:00Z]
    accepted_reset = ~U[2026-07-28 17:06:01Z]
    incoming_at = ~U[2026-07-22 01:14:00Z]
    incoming_reset = DateTime.add(accepted_reset, 179, :second)
    confirmed_at = ~U[2026-07-21 17:05:00Z]
    identity = identity!()

    provider_row!(identity, accepted_at, "0", accepted_reset, provider_at: accepted_at)
    row = provider_row(identity)

    metadata =
      row.metadata
      |> Map.put("reset_state", "anchored")
      |> Map.put(@confirmation_key, marker(row, accepted_at, confirmed_at))

    row = row |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
    refute CycleConfirmation.selector_valid?(row, incoming_at)

    assert {:ok, _row} =
             record_provider(identity, incoming_at, "0", incoming_reset, provider_at: incoming_at)

    maintained = provider_row(identity)
    assert maintained.metadata[@confirmation_key] == metadata[@confirmation_key]
    refute CycleConfirmation.selector_valid?(maintained, incoming_at)
  end

  @tag :provider_cycle_confirmation
  test "legacy weekly primary is rejected from raw siblings before logical folding" do
    as_of = ~U[2026-07-22 12:00:00Z]
    old_at = DateTime.add(as_of, -2 * Evidence.freshness_ttl_seconds(), :second)
    exact_ttl_newer = DateTime.add(old_at, Evidence.freshness_ttl_seconds(), :second)

    legacy =
      weekly_window("primary", "codex_response_headers", old_at, ~U[2026-07-19 18:58:26Z], "2")

    current =
      weekly_window(
        "secondary",
        "codex_usage_api",
        exact_ttl_newer,
        ~U[2026-07-28 17:09:00Z],
        "0"
      )

    assert Windows.effective_quota_windows([legacy, current], as_of) == [current]

    routing = Windows.routing_quota_eligibility_from_windows([legacy, current], at: as_of)
    assert routing.eligible?
    assert routing.routing_state == :weekly_only_probe
    assert routing.selection.routing_windows == [current]

    readiness = UpstreamQuotaReadiness.from_windows([legacy, current], as_of)
    assert readiness.state == "weekly_only_probe"
    assert readiness.routing_ready_now?

    future = %{
      current
      | observed_at: DateTime.add(as_of, 1, :second),
        last_sync_at: DateTime.add(as_of, 1, :second)
    }

    assert [%AccountQuotaWindow{source: "codex_response_headers", window_kind: "secondary"}] =
             Windows.effective_quota_windows([legacy, future], as_of)
  end

  @tag :provider_cycle_confirmation
  test "valid confirmed anchored row rejects a fresh prior-cycle sibling without changing same-cycle ranking" do
    as_of = ~U[2026-07-22 12:00:00Z]
    confirmed = weekly_window("secondary", "codex_usage_api", as_of, @new_reset, "0")

    confirmed = %{
      confirmed
      | metadata:
          Map.put(confirmed.metadata, @confirmation_key, marker(confirmed, as_of, as_of))
          |> Map.put("reset_state", "anchored")
    }

    old_runtime = weekly_window("secondary", "codex_rate_limit_event", as_of, @old_reset, "54")

    assert WindowSelector.logical_windows([old_runtime, confirmed], as_of) == [confirmed]

    same_cycle_runtime = %{old_runtime | reset_at: @new_reset, used_percent: Decimal.new("1")}

    assert WindowSelector.logical_windows([same_cycle_runtime, confirmed], as_of) == [
             same_cycle_runtime
           ]
  end

  @tag :provider_cycle_confirmation
  test "historical selection requires confirmation at or before the evaluation instant" do
    as_of = ~U[2026-07-22 12:00:00Z]
    provider = weekly_window("secondary", "codex_usage_api", as_of, @new_reset, "0")
    old_runtime = weekly_window("secondary", "codex_rate_limit_event", as_of, @old_reset, "54")

    exact_confirmation = %{
      provider
      | metadata:
          Map.put(provider.metadata, @confirmation_key, marker(provider, as_of, as_of))
          |> Map.put("reset_state", "anchored")
    }

    assert CycleConfirmation.selector_valid?(exact_confirmation, as_of)

    assert WindowSelector.logical_windows([old_runtime, exact_confirmation], as_of) == [
             exact_confirmation
           ]

    future_confirmation = %{
      exact_confirmation
      | metadata:
          put_in(
            exact_confirmation.metadata,
            [@confirmation_key, "confirmed_at"],
            DateTime.to_iso8601(DateTime.add(as_of, 1, :microsecond))
          )
    }

    refute CycleConfirmation.selector_valid?(future_confirmation, as_of)

    assert WindowSelector.logical_windows([old_runtime, future_confirmation], as_of) == [
             old_runtime
           ]
  end

  @tag :provider_cycle_confirmation
  test "saved-reset auto eligibility rejects a legacy primary before source filtering and folding" do
    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{})

    as_of = ~U[2026-07-22 12:00:00Z]
    legacy_at = DateTime.add(as_of, -2 * Evidence.freshness_ttl_seconds(), :second)
    current_at = DateTime.add(legacy_at, Evidence.freshness_ttl_seconds(), :second)

    insert_window!(identity, "primary", "codex_response_headers", legacy_at, @old_reset, "100")
    insert_window!(identity, "secondary", "codex_usage_api", current_at, @new_reset, "0")

    for snapshot_source <- ["codex_usage_api", "codex_response_headers"] do
      identity = enable_saved_reset_auto!(identity, snapshot_source, as_of)

      context = %{
        trigger: :blocked_weekly_exhaustion,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        candidate_assignment_ids: [assignment.id],
        candidate_identity_ids: [identity.id],
        route_class: "proxy_http"
      }

      assert {:noop, "gateway_auto_trigger_not_current"} =
               AutoEligibility.validate_locked_gateway_auto(identity, assignment, context, as_of)
    end
  end

  @tag :provider_cycle_confirmation
  test "identity advisory lock serializes confirmation against a runtime writer" do
    parent = self()
    barrier = make_ref()

    %{identity: identity, pool_id: pool_id} =
      unboxed(fn ->
        pool = pool_fixture()
        %{identity: identity} = active_upstream_assignment_fixture(pool, %{})
        canonical_at = ~U[2026-07-21 17:00:00Z]
        candidate_at = ~U[2026-07-21 17:04:00Z]

        provider_row!(identity, canonical_at, "54", @old_reset)
        runtime_row!(identity, canonical_at, "54", @old_reset)

        {:ok, _candidate} =
          record_provider(identity, candidate_at, "0", @new_reset, provider_at: candidate_at)

        %{identity: identity, pool_id: pool.id}
      end)

    on_exit(fn ->
      unboxed(fn ->
        identity |> Repo.reload!() |> Repo.delete!()
        pool_id |> CodexPooler.Pools.get_pool() |> Repo.delete!()
      end)
    end)

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            backend_pid = backend_pid!()
            advisory_lock_identity!(identity.id)
            send(parent, {barrier, :blocker_locked, backend_pid})

            receive do
              {^barrier, :release} -> :ok
            after
              @scenario_timeout_ms -> raise "timed out waiting to release quota evidence lock"
            end

            record_provider(
              identity,
              ~U[2026-07-21 17:08:00Z],
              "0",
              @new_reset,
              provider_at: ~U[2026-07-21 17:08:00Z]
            )
          end)
        end)
      end)

    assert_receive {^barrier, :blocker_locked, blocker_backend_pid}, @detection_timeout_ms

    waiter =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = backend_pid!()
          send(parent, {barrier, :waiter_ready, backend_pid})

          result =
            runtime_row!(identity, ~U[2026-07-21 17:09:00Z], "1", @new_reset)

          {backend_pid, result.id}
        end)
      end)

    assert_receive {^barrier, :waiter_ready, waiter_backend_pid}, @detection_timeout_ms
    assert blocker_backend_pid != waiter_backend_pid
    assert_advisory_wait!(waiter_backend_pid, blocker_backend_pid)

    send(blocker.pid, {barrier, :release})
    assert {:ok, {:ok, _confirmed}} = Task.await(blocker, @detection_timeout_ms)
    assert {^waiter_backend_pid, runtime_id} = Task.await(waiter, @detection_timeout_ms)

    unboxed(fn ->
      confirmed = provider_row(identity)
      assert confirmed.metadata["reset_state"] == "anchored"
      assert is_map(confirmed.metadata[@confirmation_key])

      assert Windows.quota_window_selection_data(identity, at: ~U[2026-07-21 17:09:00Z]).secondary.id ==
               runtime_id
    end)
  end

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp provider_row!(identity, observed_at, percent, reset_at, opts \\ []) do
    provider_at = Keyword.get(opts, :provider_at, observed_at)

    {:ok, row} =
      record_provider(identity, observed_at, percent, reset_at, provider_at: provider_at)

    row
  end

  defp record_provider(identity, observed_at, percent, reset_at, opts) do
    provider_at = Keyword.fetch!(opts, :provider_at)

    EvidenceStore.record_evidence(
      identity,
      weekly_attrs("codex_usage_api", observed_at, percent, reset_at)
      |> put_in([:metadata, "reset_after_seconds"], DateTime.diff(reset_at, provider_at, :second)),
      observed_at,
      observed_at
    )
  end

  defp runtime_row!(identity, observed_at, percent, reset_at) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_rate_limit_event", observed_at, percent, reset_at),
        observed_at,
        observed_at
      )

    row
  end

  defp provider_row(identity) do
    Repo.one!(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id,
        where: window.source == "codex_usage_api",
        where: window.quota_key == "account",
        where: window.window_kind == "secondary",
        where: window.window_minutes == 10_080
    )
  end

  defp weekly_attrs(source, observed_at, percent, reset_at) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: source,
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: %{}
    }
  end

  defp weekly_window(kind, source, observed_at, reset_at, percent) do
    struct!(
      AccountQuotaWindow,
      weekly_attrs(source, observed_at, percent, reset_at)
      |> Map.put(:window_kind, kind)
      |> Map.put(:merge_precedence, Evidence.merge_precedence(source, reset_at, "observed"))
      |> Map.put(:updated_at, observed_at)
    )
  end

  defp insert_window!(identity, kind, source, observed_at, reset_at, percent) do
    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(
      weekly_attrs(source, observed_at, percent, reset_at)
      |> Map.put(:upstream_identity_id, identity.id)
      |> Map.put(:window_kind, kind)
      |> Map.put(:created_at, observed_at)
      |> Map.put(:updated_at, observed_at)
    )
    |> Repo.insert!()
  end

  defp enable_saved_reset_auto!(identity, source, observed_at) do
    metadata =
      Map.put(identity.metadata || %{}, "saved_resets", %{
        "status" => "reported",
        "available_count" => 1,
        "source" => source,
        "path_style" => "codex_api",
        "observed_at" => DateTime.to_iso8601(observed_at),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      })

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: metadata,
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      updated_at: observed_at
    })
    |> Repo.update!()
  end

  defp advisory_lock_identity!(identity_id) do
    SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity_id])
    :ok
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp assert_advisory_wait!(waiter_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    assert_advisory_wait!(waiter_pid, blocker_pid, deadline)
  end

  defp assert_advisory_wait!(waiter_pid, blocker_pid, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [waiter_pid]
      )

    if match?([[_, "Lock"]], rows) and blocker_pid in hd(hd(rows)) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        assert_advisory_wait!(waiter_pid, blocker_pid, deadline)
      else
        flunk("quota evidence writer never waited on the identity advisory lock")
      end
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp capture_quota_cycle_events(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = "provider-cycle-confirmation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :quota, :cycle, :decision],
        fn _event, measurements, metadata, _config ->
          send(parent, {handler_id, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_quota_cycle_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_quota_cycle_events(handler_id, events) do
    receive do
      {^handler_id, measurements, metadata} ->
        drain_quota_cycle_events(handler_id, [{measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp marker(window, provider_at, confirmed_at) do
    %{
      "version" => 1,
      "scope" => window.quota_scope,
      "family" => window.quota_family,
      "key" => window.quota_key,
      "kind" => window.window_kind,
      "minutes" => window.window_minutes,
      "model" => window.model,
      "upstream_model" => window.upstream_model,
      "reset_at" => DateTime.to_iso8601(window.reset_at),
      "provider_observed_at" => DateTime.to_iso8601(provider_at),
      "confirmed_at" => DateTime.to_iso8601(confirmed_at),
      "source_class" => "provider_usage"
    }
  end
end
