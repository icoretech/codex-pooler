defmodule CodexPooler.Upstreams.Quota.Windows.PostResetSourceSelectionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPooler.UnboxedFixture

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.CapacityFacts
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CapacityFactsStore, RoutingQuotaSnapshot, Windows}
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, EvidenceStore, UsageCoherence}

  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @epoch 4
  @started ~U[2026-11-01 10:00:00Z]

  @tag :post_reset_partial_source_selection
  test "an old partial header just after consume cannot mask an accepted sliding restart" do
    context = restarted_weekly_account!()
    snapshot = snapshot!(context)
    witness = provider!(context.identity)

    assert Decimal.equal?(witness.used_percent, 0)
    refute CycleConfirmation.selector_valid?(witness, context.accepted_at)
    assert {:ok, marker} = UsageCoherence.parse_marker(witness.metadata)
    assert marker.first_observed_at == context.accepted_at
    assert marker.last_observed_at == context.accepted_at
    assert marker.count == 1

    assert [%{id: selected_id, used_percent: used}] = RoutingQuotaSnapshot.effective_windows(snapshot)
    refute selected_id == context.old_header.id
    assert Decimal.equal?(used, 0)
    assert Decimal.equal?(Repo.reload!(context.old_header).used_percent, 86)
  end

  test "preconsume partial pressure already yields to the confirmed sliding restart" do
    context = restarted_weekly_account!(old_offset_us: -1_000_000)
    assert [%{used_percent: used}] = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
    assert Decimal.equal?(used, 0)
  end

  test "an accepted fixed new anchor already supersedes the old postconsume measurement" do
    context = restarted_weekly_account!(shape: :fixed)
    assert CycleConfirmation.selector_valid?(provider!(context.identity), context.accepted_at)
    assert [%{used_percent: used}] = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
    assert Decimal.equal?(used, 0)
  end

  for {position, offset, expected_used} <- [{:before, 999_999, 0}, {:at, 1_000_000, 86}, {:after, 1_000_001, 86}] do
    test "partial pressure #{position} consume completion keeps the strict retirement boundary" do
      context = restarted_weekly_account!(old_offset_us: unquote(offset))
      assert [%{used_percent: used}] = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
      assert Decimal.equal?(used, unquote(expected_used))
    end
  end

  for offset <- [0, 1] do
    test "partial pressure #{offset} second after the first accepted zero remains visible" do
      context = restarted_weekly_account!()
      observed_at = DateTime.add(context.accepted_at, unquote(offset))
      pressure = record!(context.identity, "codex_response_headers", 86, observed_at, context.old_header.reset_at)
      effective = context |> snapshot!(observed_at) |> RoutingQuotaSnapshot.effective_windows()
      assert [%{id: id, used_percent: used}] = effective
      assert id == pressure.id
      assert Decimal.equal?(used, 86)
    end
  end

  test "later Usage API polls do not move the cutoff past a later partial measurement" do
    context = restarted_weekly_account!()
    later_pressure_at = DateTime.add(context.accepted_at, 1)
    pressure = record!(context.identity, "codex_response_headers", 86, later_pressure_at, context.old_header.reset_at)
    later_poll_at = DateTime.add(context.accepted_at, 60)
    record!(context.identity, "codex_usage_api", 0, later_poll_at, DateTime.add(provider!(context.identity).reset_at, 60))
    assert {:ok, marker} = UsageCoherence.parse_marker(provider!(context.identity).metadata)
    assert marker.first_observed_at == context.accepted_at
    assert marker.last_observed_at == later_poll_at
    assert marker.count == 2
    assert [%{id: id}] = context |> snapshot!(later_poll_at) |> RoutingQuotaSnapshot.effective_windows()
    assert id == pressure.id
  end

  @tag :post_reset_coherence_restart
  test "a later coherence chain cannot hide partial pressure after the reset finished" do
    context = restarted_weekly_account!()
    pressure_at = DateTime.add(context.accepted_at, 1)
    pressure = record!(context.identity, "codex_response_headers", 86, pressure_at, context.old_header.reset_at)
    next_candidate_at = DateTime.add(context.accepted_at, 360)
    next_reset = DateTime.add(provider!(context.identity).reset_at, 360)
    record!(context.identity, "codex_usage_api", 0, next_candidate_at, next_reset)
    next_accepted_at = DateTime.add(next_candidate_at, 180)
    record!(context.identity, "codex_usage_api", 0, next_accepted_at, DateTime.add(next_reset, 180))
    assert {:ok, marker} = UsageCoherence.parse_marker(provider!(context.identity).metadata)
    assert marker.first_observed_at == next_accepted_at
    assert marker.count == 1
    assert [%{id: id}] = context |> snapshot!(next_accepted_at) |> RoutingQuotaSnapshot.effective_windows()
    assert id == pressure.id
  end

  for {label, source, used, metadata} <- [
        {:exhausted, "codex_response_headers", 100, %{}},
        {:error_source, "codex_rate_limit_error", 86, %{}},
        {:denial_type, "codex_response_headers", 86, %{"rate_limit_reached_type" => "workspace_limit"}},
        {:denial_code, "codex_response_headers", 86, %{"rate_limit_error_code" => "usage_limit_reached"}},
        {:not_allowed, "codex_response_headers", 86, %{"rate_limit_allowed" => false}},
        {:limit_reached, "codex_response_headers", 86, %{"rate_limit_reached" => true}}
      ] do
    test "postconsume #{label} evidence remains visible before the accepted restart" do
      context = restarted_weekly_account!(old_source: unquote(source), old_used: unquote(used), old_metadata: unquote(Macro.escape(metadata)))
      assert [%{id: id}] = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
      assert id == context.old_header.id
    end
  end

  for invalid <- [:missing, :null, :version, :extra_field, :nonstring_percent, :nonzero_percent, :nan_percent, :invalid_percent, :count, :not_allowed, :limit_reached, :reset_mismatch, :first_before_consume, :first_after_last, :last_before_witness, :last_after_witness, :invalid_first] do
    test "an invalid #{invalid} coherence marker cannot hide the old partial measurement" do
      context = restarted_weekly_account!()
      witness = provider!(context.identity)
      key = UsageCoherence.metadata_key()
      changed = invalid_marker(unquote(invalid), witness.metadata[key], context)
      metadata = put_invalid_marker(witness.metadata, changed)
      witness |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

      assert [%{id: id}] = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
      assert id == context.old_header.id
    end
  end

  for epoch <- [nil, 3] do
    test "provider epoch #{inspect(epoch)} cannot retire the old postconsume measurement" do
      context = restarted_weekly_account!()
      witness = provider!(context.identity)
      witness |> Ecto.Changeset.change(metadata: Map.put(witness.metadata, "credential_epoch", unquote(epoch))) |> Repo.update!()
      assert [%{id: id}] = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
      assert id == context.old_header.id
    end
  end

  for dimensions <- [
        %{window_kind: "primary", window_minutes: 300},
        %{quota_key: "sample-model", quota_scope: "model", quota_family: "model", model: "sample-model"},
        %{quota_key: "sample-feature", quota_scope: "feature", quota_family: "feature"}
      ] do
    test "the restored weekly cycle preserves independent #{inspect(dimensions)} pressure" do
      context = restarted_weekly_account!()
      blocker = record!(context.identity, "codex_response_headers", 100, context.accepted_at, DateTime.add(context.accepted_at, 3600), %{}, unquote(Macro.escape(dimensions)))
      effective = context |> snapshot!() |> RoutingQuotaSnapshot.effective_windows()
      assert Enum.any?(effective, &(&1.id == blocker.id))
      refute Enum.any?(effective, &(&1.id == context.old_header.id))
    end
  end

  for {window, minutes} <- [{:weekly, 10_080}, {:monthly, 43_200}], old_event_offset <- [-1, 1] do
    @tag :weekly_receipt_sequence
    @tag window
    test "advancing #{window} provider reads under traffic converge with old pressure at consume #{old_event_offset}s" do
      context = reset_sequence!(99, unquote(old_event_offset), :normal, unquote(minutes))

      trace =
        for {source, used, tick} <- [{:provider, 1, 10}, {:headers, 1, 20}, {:provider, 4, 100}, {:event, 4, 170}, {:provider, 7, 190}, {:headers, 8, 195}, {:provider, 9, 200}] do
          observe!(context, source, used, tick)
          if tick == 10, do: assert_independent_readers!(context, tick, 99)
          measurement!(context, tick)
        end

      assert Enum.map(trace, & &1.provider) == [99, 99, 99, 99, 7, 7, 9], inspect(trace, pretty: true)
      assert Enum.map(Enum.take(trace, 5), & &1.selected) == [99, 99, 99, 99, 7]
      assert List.last(trace).selected == 9
      assert Enum.all?(trace, & &1.eligible)
      assert Enum.all?(Enum.take(trace, 5), &(&1.old_event == 99))
      assert_independent_readers!(context, 200, 9)
    end
  end

  for {window, minutes} <- [{:weekly, 10_080}, {:monthly, 43_200}] do
    @tag :weekly_receipt_sequence
    @tag window
    test "an accepted steady #{window} provider reading wins over fresh preconsume partial usage once the proof spans three minutes" do
      context = reset_sequence!(99, -1, :normal, unquote(minutes))
      [first, second, confirmed] = poll_sequence!(context, [1, 1, 1])
      assert first.provider == 99
      assert second.selected == 99
      assert {confirmed.provider, confirmed.selected, confirmed.old_event} == {1, 1, 99}
    end

    @tag :weekly_receipt_sequence
    @tag window
    test "independent #{window} receipts advance even when usage increases between every poll and no runtime evidence arrives" do
      context = reset_sequence!(99, -1, :normal, unquote(minutes))
      [first, middle, confirmed] = poll_sequence!(context, [1, 4, 7])
      assert {first.provider, middle.provider} == {99, 99}
      assert {confirmed.provider, confirmed.selected} == {7, 7}
    end
  end

  @tag :weekly_receipt_sequence
  test "an exhausted weekly window stays blocked after one permitted reading" do
    context = reset_sequence!(100, -1)
    observe!(context, :provider, 1, 10)
    assert %{provider: 100, selected: 100, eligible: false} = measurement!(context, 10)
  end

  for {window, minutes} <- [{:weekly, 10_080}, {:monthly, 43_200}], condition <- [:replayed, :out_of_order, :different_anchor, :conflicting_pressure, :absent_receipt, :absent_epoch, :new_attempt, :rotated_epoch, :old_receipt] do
    @tag :weekly_receipt_sequence
    @tag window
    test "withholds the #{window} restart after #{condition}" do
      assert_unverified!(unquote(condition), unquote(minutes))
    end
  end

  for {source, metadata} <- [
        {"codex_rate_limit_error", %{"rate_limit_error_code" => "usage_limit_reached"}},
        {"codex_response_headers", %{"rate_limit_reached_type" => "workspace_limit"}}
      ] do
    test "fresh explicit #{source} denial blocks partial weekly proof" do
      context = reset_sequence!(99, -1)
      observe!(context, :provider, 1, 10)
      observe!(context, :provider, 4, 100)

      run_unboxed(fn ->
        record!(context.identity, unquote(source), 4, DateTime.add(context.consumed_at, 170), context.anchor, unquote(Macro.escape(metadata)))
      end)

      observe!(context, :provider, 7, 190)
      assert measurement!(context, 190).provider == 99
    end
  end

  test "an older provider sample cannot start a retrospective proof interval" do
    context = reset_sequence!(99, -1)
    observe!(context, :provider, 2, 100)
    observe!(context, :provider, 3, 110, proof_tick: 10)
    observe!(context, :provider, 9, 191)
    assert measurement!(context, 191).provider == 99
  end

  for {scenario, minutes, binding} <- [{:five_hour, 300, :normal}, {:other_duration, 1_440, :normal}, {:unbound_monthly, 43_200, :unbound}] do
    @tag :monthly
    test "monthly proof excludes #{scenario}" do
      assert_unverified!(unquote(binding), unquote(minutes))
    end
  end

  @tag :monthly
  test "an account monthly reset cannot promote a model-scoped monthly reading" do
    context = reset_sequence!(99, -1, :normal, 43_200)

    for {used, tick} <- [{99, -3}, {1, 10}, {4, 100}, {7, 190}] do
      observe!(context, :provider, used, tick, model_used: used)
    end

    {account, model} =
      run_unboxed(fn ->
        rows = snapshot!(context, DateTime.add(context.consumed_at, 190)).raw_windows
        [account] = Enum.filter(rows, &(&1.source == "codex_usage_api" and &1.quota_scope == "account"))
        [model] = Enum.filter(rows, &(&1.source == "codex_usage_api" and &1.quota_scope == "model"))
        {account, model}
      end)

    assert account.window_minutes == 43_200
    assert Decimal.equal?(account.used_percent, 7)
    assert model.window_minutes == 43_200
    assert Decimal.equal?(model.used_percent, 99)
  end

  for {window, minutes} <- [{:monthly, 43_200}, {:weekly, 10_080}] do
    @tag window
    test "a legacy unbound #{window} receipt recovers through ordinary adoption and fresh-window selection" do
      context = reset_sequence!(99, -1, :absent_epoch, unquote(minutes))
      [_, second, third] = poll_sequence!(context, [1, 1, 1])
      assert {second.provider, third.selected} == {1, 99}
      assert %{provider: 1, selected: 1, eligible: true} = measurement!(context, 901)
    end
  end

  for {resource, minutes} <- [{:weekly, 10_080}, {:monthly, 43_200}], {position, tick, expected} <- [{:before_first, 5, 7}, {:after_positive, 105, 99}] do
    @tag :zero_runtime_order
    test "a zero runtime measurement #{position} the positive #{resource} readings respects their order" do
      context = reset_sequence!(99, -1, :normal, unquote(minutes))
      providers = [{3, :headers, 0}, {10, :provider, 1}, {100, :provider, 4}, {190, :provider, 7}]
      for {at, source, used} <- Enum.sort([{unquote(tick), :headers, 0} | providers]), do: observe!(context, source, used, at)
      assert %{provider: unquote(expected), selected: unquote(expected)} = measurement!(context, 190)
    end
  end

  for {resource, minutes} <- [{:weekly, 10_080}, {:monthly, 43_200}], {opposition, expected} <- [{false, 7}, {true, 99}] do
    @tag :retained_provider_after_finish
    test "a fresh high #{resource} Usage API poll after finish precedes the lower series, runtime opposition=#{opposition}" do
      context = reset_sequence!(99, -1, :normal, unquote(minutes))
      observe!(context, :provider, 99, 5)
      if unquote(opposition), do: observe!(context, :headers, 99, 6)
      [first, second, last] = poll_sequence!(context, [1, 4, 7])
      assert {first.selected, second.selected, last.selected} == {99, 99, unquote(expected)}
      assert last.provider == unquote(expected)
    end
  end

  for {resource, minutes} <- [{:weekly, 10_080}, {:monthly, 43_200}], reason <- [:malformed, :spend_limit, :missing, :windowless_denial] do
    @tag :receipt_permissions
    test "a #{reason} aggregate cannot contribute provider time to the #{resource} proof" do
      context = reset_sequence!(99, -1, :normal, unquote(minutes))
      observe!(context, :provider, 1, 10)
      interrupt_provider_permission!(context, unquote(reason), 4, 100)
      observe!(context, :provider, 7, 190)
      assert %{provider: 99, selected: 99} = measurement!(context, 190)
      observe!(context, :provider, 9, 370)
      assert %{provider: 9, selected: 9} = measurement!(context, 370)
    end
  end

  defp interrupt_provider_permission!(context, :windowless_denial, _used, tick) do
    run_unboxed(fn ->
      payload = %{"spend_control" => %{"reached" => true}, "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}}
      FakeUpstream.set_mode(context.fake, {:path_json, %{"/backend-api/wham/usage" => {200, payload}}})
      result = PoolReconciliation.refresh_quota_and_probe_from_usage(Repo.reload!(context.identity), context.assignment, observed_at: DateTime.add(context.consumed_at, tick))
      assert match?({:ok, _, _}, result) or match?({:error, %{code: :upstream_quota_unusable}}, result)
    end)
  end

  defp interrupt_provider_permission!(context, :missing, used, tick) do
    run_unboxed(fn ->
      at = DateTime.add(context.consumed_at, tick)
      record!(context.identity, "codex_usage_api", used, at, context.anchor, %{}, %{window_kind: context.kind, window_minutes: context.minutes})
    end)
  end

  defp interrupt_provider_permission!(context, reason, used, tick) do
    signal = if reason == :malformed, do: "invalid", else: true
    observe!(context, :provider, used, tick, spend_reached: signal)
  end

  defp assert_unverified!(condition, minutes) do
    context = reset_sequence!(99, -1, condition, minutes)
    [first, middle, last] = poll_sequence!(context, [1, 4, 7], condition)
    assert {first.provider, middle.provider, last.provider} == {99, 99, 99}
    if condition == :conflicting_pressure, do: assert({last.selected, last.eligible} == {100, false}), else: assert(last.selected == 99)
  end

  defp poll_sequence!(context, readings, condition \\ :normal) do
    for {used, tick} <- Enum.zip(readings, [10, 100, 190]) do
      if tick == 190, do: interrupt_sequence!(context, condition)
      anchor = if condition == :different_anchor and tick == 190, do: DateTime.add(context.anchor, -3600), else: context.anchor

      proof_tick =
        case {condition, tick} do
          {:replayed, _} -> 10
          {:out_of_order, 190} -> 99
          _other -> tick
        end

      observe!(context, :provider, used, tick, anchor: anchor, proof_tick: proof_tick)
      measurement!(context, tick)
    end
  end

  defp interrupt_sequence!(context, :conflicting_pressure), do: observe!(context, :headers, 100, 170)

  defp interrupt_sequence!(context, condition) when condition in [:new_attempt, :rotated_epoch] do
    run_unboxed(fn ->
      identity = Repo.reload!(context.identity)

      metadata =
        case condition do
          :new_attempt -> identity.metadata |> put_in(["saved_reset_redemption", "attempt_id"], Ecto.UUID.generate()) |> put_in(["saved_reset_redemption", "generation"], 2)
          :rotated_epoch -> Map.put(identity.metadata, "credential_epoch", @epoch + 1)
        end

      identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
    end)
  end

  defp interrupt_sequence!(_context, _condition), do: :ok

  defp reset_sequence!(initial, old_event_tick, condition \\ :normal, minutes \\ 10_080) do
    label = "weekly-observations-#{Ecto.UUID.generate()}"
    name = :"weekly_fake_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = Process.whereis(name), do: FakeUpstream.stop(%FakeUpstream{supervisor: pid})
    end)

    register_unboxed_cleanup!(fn ->
      if pool = Repo.get_by(Pool, slug: label), do: delete_committed_pools!([pool.id])
      Repo.delete_all(from i in UpstreamIdentity, where: i.account_label == ^label)
    end)

    {:ok, fake} = FakeUpstream.start_link({:path_json, %{}}, supervisor_name: name)
    Process.unlink(fake.supervisor)

    fixture =
      run_unboxed(fn ->
        active_upstream_assignment_fixture(pool_fixture(%{slug: label}), %{account_label: label, metadata: %{"credential_epoch" => @epoch, "usage_base_url" => FakeUpstream.url(fake)}})
      end)

    consumed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-400)
    kind = if minutes == 10_080, do: "secondary", else: "primary"
    context = Map.merge(fixture, %{fake: fake, consumed_at: consumed_at, anchor: DateTime.add(consumed_at, min(minutes * 60, 432_000)), kind: kind, minutes: minutes})
    observe!(context, :provider, initial, -4)
    observe!(context, :event, initial, old_event_tick)

    at = if condition == :old_receipt, do: DateTime.add(consumed_at, -901), else: consumed_at
    descriptors = if condition == :unbound, do: [%{"window_kind" => "secondary", "window_minutes" => 10_080}], else: [%{"window_kind" => kind, "window_minutes" => minutes}]

    unless condition == :absent_receipt do
      run_unboxed(fn ->
        identity = Repo.reload!(context.identity)
        overrides = %{"finished_at" => DateTime.to_iso8601(DateTime.add(at, 2)), "included_window_descriptors" => descriptors}
        overrides = with_receipt_epoch(overrides, condition)
        put_applied_receipt!(identity, at, overrides)
      end)
    end

    context
  end

  defp with_receipt_epoch(overrides, :absent_epoch), do: overrides
  defp with_receipt_epoch(overrides, _condition), do: Map.put(overrides, "credential_epoch", @epoch)

  defp observe!(context, source, used, tick, opts \\ []) do
    at = DateTime.add(context.consumed_at, tick)
    reset = Keyword.get(opts, :anchor, context.anchor)
    proof = DateTime.add(context.consumed_at, Keyword.get(opts, :proof_tick, tick))

    run_unboxed(fn ->
      case source do
        :provider ->
          poll_provider!(context, %{used: used, at: at, reset: reset, proof: proof}, opts)

        :headers ->
          headers = [{"x-codex-#{context.kind}-used-percent", [to_string(used)]}, {"x-codex-#{context.kind}-window-minutes", [to_string(context.minutes)]}, {"x-codex-#{context.kind}-reset-at", [to_string(DateTime.to_unix(reset))]}]
          assert {:ok, [_]} = Windows.upsert_quota_windows_from_codex_headers(context.identity, headers, at)

        :event ->
          event = %{"type" => "codex.rate_limits", "rate_limits" => %{context.kind => %{"used_percent" => used, "window_minutes" => context.minutes, "reset_at" => DateTime.to_unix(reset)}}}
          assert {:ok, [_]} = Windows.upsert_quota_windows_from_codex_rate_limit_event(context.identity, event, at)
      end
    end)
  end

  defp poll_provider!(context, %{used: used, at: at, reset: reset, proof: proof}, opts) do
    reported = %{"used_percent" => used, "limit_window_seconds" => context.minutes * 60, "reset_at" => DateTime.to_unix(reset), "reset_after_seconds" => DateTime.diff(reset, proof)}
    primary = %{"used_percent" => 10, "limit_window_seconds" => 18_000, "reset_at" => DateTime.to_unix(at) + 900, "reset_after_seconds" => 900}
    limits = %{"allowed" => true, "limit_reached" => false, "primary_window" => primary} |> Map.put(context.kind <> "_window", reported)
    payload = %{"plan_type" => "pro", "rate_limit" => limits, "spend_control" => %{"reached" => Keyword.get(opts, :spend_reached, false)}, "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}}

    payload =
      case Keyword.fetch(opts, :model_used) do
        {:ok, model_used} ->
          model_limits = Map.put(limits, "primary_window", Map.put(reported, "used_percent", model_used))
          Map.put(payload, "additional_rate_limits", [%{"model" => "sample-model", "limit_name" => "Sample model", "metered_feature" => "sample_model", "rate_limit" => model_limits}])

        :error ->
          payload
      end

    FakeUpstream.set_mode(context.fake, {:path_json, %{"/backend-api/wham/usage" => {200, payload}}})
    assert {:ok, _, probe} = PoolReconciliation.refresh_quota_and_probe_from_usage(Repo.reload!(context.identity), context.assignment, observed_at: at)
    account_windows = Enum.filter(probe.windows, &(&1.quota_scope == "account"))
    if context.kind == "primary", do: assert(Enum.map(account_windows, &{&1.window_kind, &1.window_minutes}) == [{"primary", context.minutes}])
    received = Enum.find(account_windows, &(&1.window_minutes == context.minutes))
    assert Decimal.equal?(received.used_percent, used)
    assert DateTime.compare(received.observed_at, at) == :eq
    assert DateTime.compare(received.reset_at, reset) == :eq
    assert DateTime.diff(received.reset_at, proof) == received.metadata["reset_after_seconds"]
  end

  defp measurement!(context, tick) do
    run_unboxed(fn ->
      at = DateTime.add(context.consumed_at, tick)
      snapshot = snapshot!(context, at)
      if context.kind == "primary", do: refute(Enum.any?(snapshot.raw_windows, &(&1.window_minutes == 10_080)))
      row = Enum.find(snapshot.raw_windows, &(&1.source == "codex_usage_api" and &1.window_minutes == context.minutes))
      winner = Enum.find(RoutingQuotaSnapshot.effective_windows(snapshot), &(&1.window_minutes == context.minutes))

      candidate =
        case EvidenceStore.parse_candidate(row.metadata) do
          {:ok, pending} -> {Decimal.to_integer(pending.used_percent), DateTime.diff(pending.observed_at, context.consumed_at)}
          :none -> nil
        end

      old_event = Enum.find(snapshot.raw_windows, &(&1.source == "codex_rate_limit_event" and &1.window_minutes == context.minutes))
      %{tick: tick, old_event: Decimal.to_integer(old_event.used_percent), provider: Decimal.to_integer(row.used_percent), candidate: candidate, selected: Decimal.to_integer(winner.used_percent), source: winner.source, eligible: Windows.routing_quota_eligibility_from_snapshot(snapshot).eligible?, observed: DateTime.diff(row.observed_at, context.consumed_at), sync: DateTime.diff(row.last_sync_at, context.consumed_at)}
    end)
  end

  defp assert_independent_readers!(context, tick, expected) do
    run_unboxed(fn ->
      read = fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        snapshot = snapshot!(context, DateTime.add(context.consumed_at, tick))
        selected = Enum.find(RoutingQuotaSnapshot.effective_windows(snapshot), &(&1.window_minutes == context.minutes))
        {backend, selected.id, Decimal.to_integer(selected.used_percent)}
      end

      {first, id, ^expected} = read.()
      assert {second, ^id, ^expected} = run_unboxed(read)
      refute first == second
    end)
  end

  defp restarted_weekly_account!(opts \\ []) do
    identity = active_upstream_assignment_fixture(pool_fixture(), %{metadata: %{"credential_epoch" => @epoch}}).identity
    consumed_at = DateTime.add(@started, 2)
    first_zero_at = DateTime.add(consumed_at, 10)
    accepted_at = DateTime.add(first_zero_at, 180)
    old_reset = DateTime.add(@started, 5, :day)
    first_zero_reset = DateTime.add(first_zero_at, 604_800)

    record!(identity, "codex_usage_api", 86, @started, old_reset)
    old_header = record!(identity, Keyword.get(opts, :old_source, "codex_response_headers"), Keyword.get(opts, :old_used, 86), DateTime.add(consumed_at, Keyword.get(opts, :old_offset_us, 2_000), :microsecond), old_reset, Keyword.get(opts, :old_metadata, %{}))
    record!(identity, "codex_usage_api", 86, DateTime.add(consumed_at, 2, :millisecond), old_reset)
    identity = put_applied_receipt!(identity, consumed_at)
    record!(identity, "codex_usage_api", 0, first_zero_at, first_zero_reset)
    shape = Keyword.get(opts, :shape, :sliding)
    record!(identity, "codex_rate_limit_event", 0, DateTime.add(first_zero_at, 60), reset_after(first_zero_reset, shape, 60))
    record!(identity, "codex_usage_api", 0, DateTime.add(first_zero_at, 179), reset_after(first_zero_reset, shape, 179))
    assert Decimal.equal?(provider!(identity).used_percent, 86)
    record!(identity, "codex_usage_api", 0, accepted_at, reset_after(first_zero_reset, shape, 180))

    facts = %CapacityFacts{observed_at: accepted_at, credential_epoch: @epoch, included_permission: :available, credit_permission: :unavailable, denial_category: :none}
    metadata = Map.put(identity.metadata, "quota_capacity_facts", CapacityFactsStore.encode!(facts, @epoch))
    identity = identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
    %{identity: identity, consumed_at: consumed_at, accepted_at: accepted_at, old_header: old_header}
  end

  defp reset_after(reset, :fixed, _offset), do: reset
  defp reset_after(reset, :sliding, offset), do: DateTime.add(reset, offset)

  defp invalid_marker(:missing, _marker, _context), do: :missing
  defp invalid_marker(:null, _marker, _context), do: nil
  defp invalid_marker(:version, marker, _context), do: Map.put(marker, "version", 2)
  defp invalid_marker(:extra_field, marker, _context), do: Map.put(marker, "unexpected", true)
  defp invalid_marker(:nonstring_percent, marker, _context), do: Map.put(marker, "used_percent", 0)
  defp invalid_marker(:nonzero_percent, marker, _context), do: Map.put(marker, "used_percent", "1")
  defp invalid_marker(:nan_percent, marker, _context), do: Map.put(marker, "used_percent", "NaN")
  defp invalid_marker(:invalid_percent, marker, _context), do: Map.put(marker, "used_percent", "unavailable")
  defp invalid_marker(:count, marker, _context), do: Map.put(marker, "count", 0)
  defp invalid_marker(:not_allowed, marker, _context), do: Map.put(marker, "allowed", false)
  defp invalid_marker(:limit_reached, marker, _context), do: Map.put(marker, "limit_reached", true)
  defp invalid_marker(:reset_mismatch, marker, context), do: Map.put(marker, "reset_at", DateTime.to_iso8601(DateTime.add(provider!(context.identity).reset_at, 1)))
  defp invalid_marker(:first_before_consume, marker, context), do: Map.put(marker, "first_observed_at", DateTime.to_iso8601(DateTime.add(context.consumed_at, -1)))
  defp invalid_marker(:first_after_last, marker, context), do: Map.put(marker, "first_observed_at", DateTime.to_iso8601(DateTime.add(context.accepted_at, 1)))
  defp invalid_marker(:last_before_witness, marker, context), do: Map.put(marker, "last_observed_at", DateTime.to_iso8601(DateTime.add(context.accepted_at, -1)))
  defp invalid_marker(:last_after_witness, marker, context), do: Map.put(marker, "last_observed_at", DateTime.to_iso8601(DateTime.add(context.accepted_at, 1)))
  defp invalid_marker(:invalid_first, marker, _context), do: Map.put(marker, "first_observed_at", nil)

  defp put_invalid_marker(metadata, :missing), do: Map.delete(metadata, UsageCoherence.metadata_key())
  defp put_invalid_marker(metadata, marker), do: Map.put(metadata, UsageCoherence.metadata_key(), marker)

  defp put_applied_receipt!(identity, consumed_at, overrides \\ %{}) do
    receipt = %{
      "phase" => "confirmed_by_quota",
      "status" => "succeeded",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "finished_at" => DateTime.to_iso8601(DateTime.add(consumed_at, 1)),
      "result" => %{"applied" => true, "code" => "reset"},
      "provider_replay" => %{"version" => 1, "provider_dispatches" => 1},
      "included_window_descriptors" => [%{"window_kind" => "secondary", "window_minutes" => 10_080}]
    }

    identity |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "saved_reset_redemption", Map.merge(receipt, overrides))) |> Repo.update!()
  end

  defp snapshot!(context, as_of \\ nil) do
    RoutingQuotaSnapshot.load_by_identity_ids([context.identity.id], as_of || context.accepted_at)
    |> Map.fetch!(context.identity.id)
  end

  defp provider!(identity) do
    Repo.one!(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id and window.source == "codex_usage_api")
  end

  defp record!(identity, source, used, observed_at, reset_at, metadata \\ %{}, dimensions \\ %{}) do
    attrs = %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      source: source,
      source_precision: "observed",
      freshness_state: "fresh",
      used_percent: Decimal.new(used),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      metadata: Map.merge(%{"rate_limit_allowed" => true, "rate_limit_reached" => false, "reset_after_seconds" => DateTime.diff(reset_at, observed_at)}, metadata)
    }

    attrs = Map.merge(attrs, dimensions)
    attrs = if source == "codex_usage_api", do: put_in(attrs.metadata["credential_epoch"], @epoch), else: attrs
    assert {:ok, window} = EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)
    window
  end
end
