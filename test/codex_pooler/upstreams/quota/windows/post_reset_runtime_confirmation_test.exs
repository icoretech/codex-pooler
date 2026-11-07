defmodule CodexPooler.Upstreams.Quota.Windows.PostResetRuntimeConfirmationTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Quotas.CapacityFacts
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CapacityFactsStore, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @epoch 4
  @at ~U[2026-11-01 10:00:00Z]

  for order <- [:no_runtime, :runtime_before_candidate, :runtime_during_candidate], shape <- [:fixed, :sliding] do
    test "partial positive weekly reset matures at 180 seconds with #{order} and #{shape} reset" do
      identity = identity!()
      old_reset = DateTime.add(@at, 5, :day)
      new_reset = DateTime.add(@at, 604_810)
      record!(identity, "codex_usage_api", 86, @at, old_reset)
      record!(identity, "codex_response_headers", 86, DateTime.add(@at, -1), old_reset)
      first = DateTime.add(@at, 10)
      if unquote(order) == :runtime_before_candidate, do: record!(identity, "codex_rate_limit_event", 0, DateTime.add(first, -1), new_reset)
      record!(identity, "codex_usage_api", 0, first, new_reset)
      initial_candidate? = match?({:ok, _}, EvidenceStore.parse_candidate(provider!(identity).metadata))
      if unquote(order) == :runtime_during_candidate, do: record!(identity, "codex_rate_limit_event", 0, DateTime.add(first, 60), new_reset)
      after_runtime_candidate? = match?({:ok, _}, EvidenceStore.parse_candidate(provider!(identity).metadata))
      record!(identity, "codex_usage_api", 0, DateTime.add(first, 179), next_reset(new_reset, unquote(shape), 179))
      early = provider!(identity)
      record!(identity, "codex_usage_api", 0, DateTime.add(first, 180), next_reset(new_reset, unquote(shape), 180))
      mature = provider!(identity)
      assert initial_candidate?
      assert after_runtime_candidate?
      assert Decimal.equal?(early.used_percent, 86)
      assert Decimal.equal?(mature.used_percent, 0)
    end
  end

  test "confirmed saved reset retires preconsume pressure after interleaved sliding Usage and runtime zeros" do
    identity = identity!()
    consumed = DateTime.add(@at, 2)
    first = DateTime.add(@at, 10)
    now = DateTime.add(first, 180)
    old_reset = DateTime.add(@at, 5, :day)
    new_reset = DateTime.add(first, 604_800)
    record!(identity, "codex_usage_api", 86, @at, old_reset)
    old = record!(identity, "codex_response_headers", 86, DateTime.add(consumed, -1), old_reset)
    record!(identity, "codex_usage_api", 86, DateTime.add(consumed, 2, :millisecond), old_reset)
    identity = put_receipt!(identity, consumed)
    record!(identity, "codex_usage_api", 0, first, new_reset)
    record!(identity, "codex_rate_limit_event", 0, DateTime.add(first, 60), DateTime.add(new_reset, 60))
    record!(identity, "codex_usage_api", 0, DateTime.add(first, 179), DateTime.add(new_reset, 179))
    assert Decimal.equal?(provider!(identity).used_percent, 86)
    record!(identity, "codex_usage_api", 0, now, DateTime.add(new_reset, 180))
    assert Decimal.equal?(provider!(identity).used_percent, 0)
    facts = %CapacityFacts{observed_at: now, credential_epoch: @epoch, included_permission: :available, credit_permission: :unavailable, denial_category: :none}
    metadata = identity.metadata |> Map.put("quota_capacity_facts", CapacityFactsStore.encode!(facts, @epoch))
    identity = identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], now)[identity.id]
    effective = RoutingQuotaSnapshot.effective_windows(snapshot)
    refute Enum.any?(effective, &(&1.id == old.id))
    assert [%{used_percent: used}] = effective
    assert Decimal.equal?(used, 0)
    assert Repo.reload!(old).used_percent == Decimal.new("86.000")
  end

  for {label, used, runtime_metadata} <- [
        {:positive, 1, %{}},
        {:exhausted, 100, %{}},
        {:denied, 0, %{"rate_limit_allowed" => false}},
        {:reached, 0, %{"rate_limit_reached" => true}},
        {:denial_type, 0, %{"rate_limit_reached_type" => "workspace_limit"}},
        {:denial_code, 0, %{"rate_limit_error_code" => "usage_limit_reached"}},
        {:wrong_epoch, 0, %{"credential_epoch" => 3}},
        {:null_epoch, 0, %{"credential_epoch" => nil}}
      ] do
    test "accepted #{label} runtime evidence still clears a pending weekly zero" do
      identity = identity!()
      first = DateTime.add(@at, 10)
      new_reset = DateTime.add(first, 604_800)
      record!(identity, "codex_usage_api", 86, @at, DateTime.add(@at, 5, :day))
      record!(identity, "codex_usage_api", 0, first, new_reset)
      assert {:ok, _} = EvidenceStore.parse_candidate(provider!(identity).metadata)
      record!(identity, "codex_rate_limit_event", unquote(used), DateTime.add(first, 60), new_reset, %{metadata: unquote(Macro.escape(runtime_metadata))})
      assert :none = EvidenceStore.parse_candidate(provider!(identity).metadata)
      assert Decimal.equal?(provider!(identity).used_percent, 86)
    end
  end

  test "same-cycle partial positive usage remains authoritative despite runtime and provider zeros" do
    identity = identity!()
    reset = DateTime.add(@at, 5, :day)
    first = DateTime.add(@at, 10)
    record!(identity, "codex_usage_api", 86, @at, reset)
    record!(identity, "codex_rate_limit_event", 0, first, reset)
    for offset <- [0, 179, 180], do: record!(identity, "codex_usage_api", 0, DateTime.add(first, offset), reset)
    assert Decimal.equal?(provider!(identity).used_percent, 86)
  end

  test "a resetless exhausted canonical row safely quarantines a newer provider zero" do
    identity = identity!()
    record!(identity, "codex_usage_api", 100, @at, nil, %{metadata: %{"credential_epoch" => @epoch}})
    first = DateTime.add(@at, 60)
    record!(identity, "codex_usage_api", 0, first, DateTime.add(first, 604_800))
    assert Decimal.equal?(provider!(identity).used_percent, 100)
    assert {:ok, _} = EvidenceStore.parse_candidate(provider!(identity).metadata)
  end

  for descriptor <- [%{quota_scope: "model", quota_family: "model", quota_key: "sample-model", model: "sample-model"}, %{window_kind: "primary", window_minutes: 300}, %{window_kind: "primary", window_minutes: 43_200}] do
    test "a runtime zero in #{inspect(descriptor)} does not mutate an account weekly candidate" do
      identity = identity!()
      first = DateTime.add(@at, 10)
      reset = DateTime.add(first, 604_800)
      record!(identity, "codex_usage_api", 86, @at, DateTime.add(@at, 5, :day))
      record!(identity, "codex_usage_api", 0, first, reset)
      before = provider!(identity)
      record!(identity, "codex_rate_limit_event", 0, DateTime.add(first, 60), reset, unquote(Macro.escape(descriptor)))
      assert provider!(identity) == before
    end
  end

  defp next_reset(reset, :fixed, _seconds), do: reset
  defp next_reset(reset, :sliding, seconds), do: DateTime.add(reset, seconds)

  defp put_receipt!(identity, consumed) do
    receipt = %{"phase" => "confirmed_by_quota", "status" => "succeeded", "attempt_id" => Ecto.UUID.generate(), "generation" => 1, "consumed_at" => DateTime.to_iso8601(consumed), "finished_at" => DateTime.to_iso8601(DateTime.add(consumed, 2)), "result" => %{"applied" => true, "code" => "reset"}, "provider_replay" => %{"version" => 1, "provider_dispatches" => 1}, "included_window_descriptors" => [%{"window_kind" => "secondary", "window_minutes" => 10_080}]}
    identity |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "saved_reset_redemption", receipt)) |> Repo.update!()
  end

  defp identity! do
    active_upstream_assignment_fixture(pool_fixture(), %{metadata: %{"credential_epoch" => @epoch}}).identity
  end

  defp provider!(identity), do: Repo.one!(from w in AccountQuotaWindow, where: w.upstream_identity_id == ^identity.id and w.source == "codex_usage_api")

  defp record!(identity, source, used, at, reset, overrides \\ %{}) do
    attrs = %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, source: source, source_precision: "observed", freshness_state: "fresh", used_percent: Decimal.new(used), reset_at: reset, observed_at: at, last_sync_at: at, metadata: %{"credential_epoch" => @epoch, "rate_limit_allowed" => true, "rate_limit_reached" => false, "reset_after_seconds" => if(reset, do: DateTime.diff(reset, at))}}
    attrs = if source == "codex_usage_api", do: attrs, else: %{attrs | metadata: Map.delete(attrs.metadata, "credential_epoch")}
    attrs = Map.merge(attrs, overrides)
    assert {:ok, row} = EvidenceStore.record_evidence(identity, attrs, at, at)
    row
  end
end
