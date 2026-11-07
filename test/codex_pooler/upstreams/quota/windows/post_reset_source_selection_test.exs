defmodule CodexPooler.Upstreams.Quota.Windows.PostResetSourceSelectionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.CapacityFacts
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CapacityFactsStore, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, EvidenceStore, UsageCoherence}

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

  defp put_applied_receipt!(identity, consumed_at) do
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

    identity |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "saved_reset_redemption", receipt)) |> Repo.update!()
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
