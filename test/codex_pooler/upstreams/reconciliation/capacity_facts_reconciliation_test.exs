defmodule CodexPooler.Upstreams.Reconciliation.CapacityFactsReconciliationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.{FakeUpstream, Repo, Upstreams}
  alias CodexPooler.Quotas.{CapacityFacts, Evidence}
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.{AccountAvailabilityStore, CapacityFactsStore, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Reconciliation.{PoolReconciliation, UsageProbe}

  @paths ["/backend-api/wham/usage", "/backend-api/codex/usage"]

  test "real usage reconciliation preserves fractional credits separate from exhausted included capacity" do
    {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, credit_payload()}}))
    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
    assert facts.balance == "0.125"
    assert facts.included_permission == :exhausted
    assert facts.credit_permission == :available
    assert facts.credential_epoch == CredentialFencing.credential_epoch(refreshed)
    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], DateTime.utc_now())[identity.id]
    assert snapshot.capacity_facts == facts
    assert snapshot.allow_provider_credits
    assert requested_paths(fake) == @paths
  end

  for seconds <- [0, 1, 5, 6] do
    @tag credits_negative: true
    test "queried weekly credit receipts retain bounded #{seconds}-second reset rounding without merging other facts" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      first = credit_payload() |> put_account_window(604_800, 100, now)
      second = update_in(first, ["rate_limit", "primary_window", "reset_at"], &(&1 + unquote(seconds)))
      {_fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, first}, {200, second}])))
      assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
      assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
      assert facts.credit_permission == :available == unquote(seconds) <= 5
      assert facts.source_kind == :wham_usage
      assert facts.balance == "0.125"
      assert [%{reset_at: reset}] = facts.account_windows
      assert DateTime.to_unix(reset) == get_in(first, ["rate_limit", "primary_window", "reset_at"])
    end
  end

  @tag credits_multi_path: true
  @tag credits_negative: true
  test "queried spend and workspace blockers beat coherent credit grants in either response order" do
    grant = credit_payload()

    for blocker <- [%{"spend_control" => %{"reached" => true}}, %{"rate_limit_reached_type" => %{"type" => "workspace_owner_credits_depleted"}}],
        reverse <- [false, true] do
      denied = Map.merge(grant, blocker)
      payloads = if reverse, do: [denied, grant], else: [grant, denied]
      routes = Map.new(Enum.zip(@paths, Enum.map(payloads, &{200, &1})))
      {fake, identity, assignment} = setup_upstream(routes)
      assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
      assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
      assert facts.credit_permission == :unavailable
      assert facts.denial_category in [:spend_limit, :workspace_limit]
      assert requested_paths(fake) == @paths
    end
  end

  @tag credits_multi_path: true
  @tag credits_negative: true
  test "split-source credits and spend clearance never assemble authority" do
    credits_only = Map.delete(credit_payload(), "spend_control")
    spend_only = %{"plan_type" => "synthetic", "rate_limit" => %{"allowed" => false, "limit_reached" => true}, "spend_control" => %{"reached" => false}}
    {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, credits_only}, {200, spend_only}])))
    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
    refute facts.credit_permission == :available
    assert requested_paths(fake) == @paths
  end

  @tag credits_multi_path: true
  test "positive balance drift preserves a complete credit grant independent of selected display payload" do
    first = credit_payload()
    second = put_in(first, ["credits", "balance"], "0.25")

    for payloads <- [[first, second], [second, first]] do
      {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, Enum.map(payloads, &{200, &1}))))
      {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), []) end)
      refute log =~ "quota capacity authority unavailable"
      refute log =~ identity.id
      refute log =~ "0.125"
      refute log =~ "0.25"
      assert result.usage_path == hd(@paths)
      assert result.capacity_facts.credit_permission == :available
      assert result.capacity_facts == hd(result.capacity_observations)
      assert Enum.map(result.capacity_observations, & &1.balance) == Enum.map(payloads, &(get_in(&1, ["credits", "balance"]) |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal)))
      assert requested_paths(fake) == @paths
      assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), assignment)
      assert {:ok, facts} = CapacityFactsStore.load(identity.metadata)
      assert facts.credit_permission == :available
      assert facts.included_permission == :exhausted
      decision = public_decision(identity, DateTime.utc_now())
      assert decision.eligible?
      assert decision.capacity_basis == :provider_credits
      assert decision.reason_codes == []
    end
  end

  for reverse <- [false, true] do
    @tag credits_negative: true
    test "an observed finite zero vetoes a stronger positive credit grant, reverse=#{reverse}" do
      positive = credit_payload()
      zero = Map.put(positive, "credits", %{"balance" => "0", "has_credits" => false, "unlimited" => false})
      payloads = if unquote(reverse), do: [zero, positive], else: [positive, zero]
      {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, Enum.map(payloads, &{200, &1}))))
      {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), []) end)
      assert result.capacity_facts.credit_permission == :unknown
      assert log =~ "reason_code=conflicting_usage_receipts"
      assert log =~ "differing_fields=credit_permission,balance,has_credits"
      assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
      assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
      assert facts.credit_permission == :unknown
      refute public_decision(refreshed, DateTime.utc_now()).eligible?
      assert requested_paths(fake) == @paths ++ @paths
    end
  end

  test "positive balance drift preserves included authority without merging receipts" do
    first = included_payload()
    second = put_in(first, ["credits", "balance"], "0.25")
    {_fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, first}, {200, second}])))
    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
    assert facts.included_permission == :available
    assert facts.credit_permission == :available
    assert facts.balance == "0.125"
  end

  for difference <- [:included_permission, :unlimited, :windows] do
    @tag credits_negative: true
    test "positive balance drift cannot hide a #{difference} disagreement" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      first = credit_payload() |> put_account_window(604_800, 100, now)
      second = put_in(first, ["credits", "balance"], "0.25")

      second =
        case unquote(difference) do
          :included_permission -> put_in(second, ["rate_limit", "allowed"], true) |> put_in(["rate_limit", "limit_reached"], false)
          :unlimited -> put_in(second, ["credits", "unlimited"], true)
          :windows -> put_in(second, ["rate_limit", "primary_window", "used_percent"], 99)
        end

      for payloads <- [[first, second], [second, first]] do
        {_fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, Enum.map(payloads, &{200, &1}))))
        assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
        assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
        assert facts.credit_permission == :unknown
        refute public_decision(refreshed, DateTime.utc_now()).eligible?
      end
    end
  end

  test "unlimited zero balance remains valid when both complete receipts agree" do
    payload = Map.put(credit_payload(), "credits", %{"balance" => "0", "has_credits" => false, "unlimited" => true})
    {_fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, payload}}))
    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
    assert facts.credit_permission == :available
    assert facts.unlimited
    assert public_decision(refreshed, DateTime.utc_now()).eligible?
  end

  for balance <- [nil, "0"] do
    test "unlimited #{inspect(balance)} versus positive balance remains a conflict" do
      first = Map.put(credit_payload(), "credits", %{"balance" => unquote(balance), "has_credits" => true, "unlimited" => true})
      second = put_in(first, ["credits", "balance"], "0.25")
      {_fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, first}, {200, second}])))
      assert {:ok, result} = UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), [])
      assert Enum.all?(result.capacity_observations, &(&1.credit_permission == :available))
      assert result.capacity_facts.credit_permission == :unknown
    end
  end

  test "a third finite-zero receipt vetoes positive balance drift in every endpoint order" do
    positive = credit_payload()
    other = put_in(positive, ["credits", "balance"], "0.25")
    zero = Map.put(positive, "credits", %{"balance" => "0", "has_credits" => false, "unlimited" => false})
    paths = ["/api/codex/usage" | @paths]

    for payloads <- [[positive, other, zero], [positive, zero, other], [other, positive, zero], [other, zero, positive], [zero, positive, other], [zero, other, positive]] do
      {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(paths, Enum.map(payloads, &{200, &1}))))
      identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "usage_path", hd(paths))))
      assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
      assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
      assert facts.credit_permission == :unknown
      assert facts.included_permission == :unknown
      refute public_decision(refreshed, DateTime.utc_now()).eligible?
      assert requested_paths(fake) == ["/api/codex/usage", "/backend-api/codex/usage", "/backend-api/wham/usage"]
    end
  end

  for balance <- ["0", nil, "not-a-number"] do
    @tag credits_negative: true
    test "a #{inspect(balance)} balance never uses the positive drift exception" do
      positive = credit_payload()
      second = put_in(positive, ["credits", "balance"], unquote(balance))
      # has_credits=true with zero is malformed; missing finite balance and
      # no included attestation is wholly unknown and must also fail closed.
      second = if is_nil(unquote(balance)), do: Map.delete(second, "rate_limit"), else: second
      {_fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, positive}, {200, second}])))
      assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
      assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
      refute facts.credit_permission == :available
      refute public_decision(refreshed, DateTime.utc_now()).eligible?
    end
  end

  for reverse <- [false, true] do
    test "unknown queried receipt revokes a grant with the exact source logged, reverse=#{reverse}" do
      assert_unknown_receipt_diagnostic(unquote(reverse))
    end
  end

  for single <- [false, true] do
    test "unusable unknown receipts emit one diagnostic and revoke persisted credits, single=#{single}" do
      assert_unusable_unknown_diagnostic(unquote(single))
    end
  end

  test "unknown receipt revokes otherwise coherent positive grants in a three-source fetch" do
    paths = ["/api/codex/usage" | @paths]
    payloads = [credit_payload(), put_in(credit_payload(), ["credits", "balance"], "0.25"), %{}]
    {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(paths, Enum.map(payloads, &{200, &1}))))
    identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "usage_path", hd(paths))))
    observed_at = DateTime.utc_now()
    {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, observed_at, []) end)
    assert result.capacity_facts.credit_permission == :unknown
    assert length(result.capacity_observations) == 3
    assert_unknown_log(log, identity, observed_at, "codex_usage")
    assert requested_paths(fake) == ["/api/codex/usage", "/backend-api/codex/usage", "/backend-api/wham/usage"]
  end

  for blocker <- [:malformed, :spend, :workspace], reverse <- [false, true] do
    test "#{blocker} denial wins over unknown receipts without a false diagnostic, reverse=#{reverse}" do
      assert_denial_diagnostic_precedence(unquote(blocker), unquote(reverse))
    end
  end

  test "equal-strength malformed receipts with different balances do not log a conflict" do
    first = blocking_payload(credit_payload(), :malformed)
    second = put_in(first, ["credits", "balance"], "0.25")
    {_fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, first}, {200, second}])))
    {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), []) end)
    assert result.capacity_facts.denial_category == :malformed
    assert result.capacity_facts.credit_permission == :unknown
    refute log =~ "quota capacity authority unavailable"
  end

  for grants_present <- [false, true] do
    test "unknown credit permission with included-limit denial is not an unknown receipt, grants_present=#{grants_present}" do
      incomplete = Map.delete(credit_payload(), "spend_control")
      second = if unquote(grants_present), do: credit_payload(), else: incomplete
      {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, [{200, incomplete}, {200, second}])))
      {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), []) end)
      assert [%{credit_permission: :unknown, denial_category: :included_limit} | _] = result.capacity_observations
      assert result.capacity_facts.credit_permission == if(unquote(grants_present), do: :available, else: :unknown)
      refute log =~ "quota capacity authority unavailable"
      assert requested_paths(fake) == @paths
    end
  end

  @tag credits_multi_path: true
  test "coherent credit-only zero-window receipt without legacy availability reaches Result and persistence" do
    payload = Map.delete(credit_payload(), "plan_type") |> Map.delete("rate_limit")
    {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, payload}}))
    assert {:ok, result} = UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), [])
    assert result.windows == []
    assert result.account_availability == nil
    assert result.capacity_facts.credit_permission == :available
    assert Enum.map(result.capacity_observations, & &1.source_kind) == [:wham_usage, :codex_usage]
    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), assignment)
    assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
    assert facts.account_windows == []
    assert facts.included_permission == :unknown
    assert facts.credit_permission == :available
    assert Enum.uniq(requested_paths(fake)) == @paths
  end

  @tag credits_negative: true
  test "newer malformed full response revokes a previous grant without changing persisted policy" do
    payload = credit_payload()
    {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, payload}}))
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    identity = Repo.update!(Ecto.Changeset.change(identity, allow_provider_credits: false))
    malformed = Map.put(payload, "spend_control", %{"reached" => "false"})
    FakeUpstream.set_mode(fake, {:path_json, Map.new(@paths, &{&1, {200, malformed}})})
    assert {:ok, refreshed} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert {:ok, facts} = CapacityFactsStore.load(refreshed.metadata)
    assert facts.denial_category == :malformed
    refute facts.credit_permission == :available
    refute refreshed.allow_provider_credits
  end

  @tag credits_negative: true
  test "complete zero-authority response revokes prior credits while remaining unusable" do
    {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, credit_payload()}}))
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    FakeUpstream.set_mode(fake, {:path_json, Map.new(@paths, &{&1, {200, %{}}})})
    assert {:error, %{code: :upstream_quota_unusable}} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    assert {:ok, facts} = CapacityFactsStore.load(Repo.reload!(identity).metadata)
    assert facts.credit_permission == :unknown
    assert facts.included_permission == :unknown
  end

  for first_source <- [:wham_usage, :codex_usage] do
    @tag credits_multi_path: true
    @tag credits_negative: true
    test "unusable queried malformed receipts retain both source fences through #{first_source}-first clearance" do
      now = DateTime.utc_now() |> DateTime.add(-4, :second) |> DateTime.truncate(:second)
      malformed = %{"credits" => %{"balance" => "0.125", "has_credits" => true, "unlimited" => false}, "spend_control" => %{"reached" => "false"}}
      {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, malformed}}))
      assert {:error, %{code: :upstream_quota_unusable}} = refresh_at(identity, assignment, now)
      identity = Repo.reload!(identity)
      assert {:ok, %{denial_category: :malformed, included_permission: :unknown, credit_permission: :unknown}} = CapacityFactsStore.load(identity.metadata)
      assert {:ok, %{observations: retained, overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert Enum.sort(Enum.map(retained, & &1.source_kind)) == [:codex_usage, :wham_usage]
      refute public_decision(identity, now).credit_available?

      FakeUpstream.set_mode(fake, {:path_json, routes_for(unquote(first_source), credit_payload())})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 1))
      assert {:ok, %{credit_permission: :available}} = CapacityFactsStore.load(identity.metadata)
      assert {:ok, %{observations: [remaining], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert remaining.source_kind != unquote(first_source)
      assert remaining.denial_category == :malformed
      decision = public_decision(identity, DateTime.add(now, 1))
      refute decision.credit_available?
      refute decision.eligible?

      FakeUpstream.set_mode(fake, {:path_json, routes_for(remaining.source_kind, credit_payload())})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 2))
      assert CapacityFactsStore.load_blockers(identity.metadata) == :error
      assert_credit_authority(identity, DateTime.add(now, 2), remaining.source_kind, [])
    end
  end

  for {replacement, source, window_seconds} <- [
        {:spend, :wham_usage, nil},
        {:spend, :codex_usage, nil},
        {:malformed, :codex_usage, nil},
        {:workspace, :wham_usage, 18_000}
      ] do
    @tag credits_negative: true
    test "a retained weekly workspace denial survives newer #{replacement} from #{source} and unrelated clearance" do
      now = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)
      original = included_payload() |> put_account_window(604_800, 100, now) |> Map.put("rate_limit_reached_type", %{"type" => "workspace_owner_usage_limit_reached"})
      {fake, identity, assignment} = setup_upstream(routes_for(:codex_usage, original))
      assert {:ok, identity} = refresh_at(identity, assignment, now)
      assert {:ok, %{observations: [blocker], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert blocker.denial_category == :workspace_limit
      assert blocker.source_kind == :codex_usage
      assert [{"secondary", 10_080}] == Enum.map(blocker.account_windows, &{&1.window_kind, &1.window_minutes})
      refute public_decision(identity, now).eligible?

      replaced_payload =
        included_payload()
        |> put_account_window(unquote(window_seconds), 25, now)
        |> blocking_payload(unquote(replacement))

      FakeUpstream.set_mode(fake, {:path_json, routes_for(unquote(source), replaced_payload)})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 1))
      assert {:ok, facts} = CapacityFactsStore.load(identity.metadata)
      assert facts.denial_category == %{spend: :spend_limit, malformed: :malformed, workspace: :workspace_limit}[unquote(replacement)]
      assert facts.source_kind == unquote(source)
      assert {:ok, %{observations: retained}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert blocker in retained
      decision = public_decision(identity, DateTime.add(now, 1))
      refute decision.eligible?
      assert "provider_denied" in decision.reason_codes

      unrelated = included_payload() |> put_account_window(unquote(window_seconds), 25, now)
      FakeUpstream.set_mode(fake, {:path_json, routes_for(unquote(source), unrelated)})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 2))
      assert {:ok, %{included_permission: :available}} = CapacityFactsStore.load(identity.metadata)
      assert {:ok, %{observations: [^blocker]}} = CapacityFactsStore.load_blockers(identity.metadata)
      decision = public_decision(identity, DateTime.add(now, 2))
      refute decision.eligible?
      assert "provider_denied" in decision.reason_codes

      compatible = included_payload() |> put_account_window(604_800, 25, now)
      FakeUpstream.set_mode(fake, {:path_json, routes_for(:codex_usage, compatible)})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 3))
      assert CapacityFactsStore.load_blockers(identity.metadata) == :error
      decision = public_decision(identity, DateTime.add(now, 3))
      assert decision.eligible?
      assert decision.capacity_basis == :included_window
    end
  end

  for credit_blocker <- [:spend, :malformed], first_clear <- [:credit, :hard] do
    @tag credits_negative: true
    test "queried #{credit_blocker} weekly and incompatible workspace fences require both clearances in #{first_clear}-first order" do
      now = DateTime.utc_now() |> DateTime.add(-7, :second) |> DateTime.truncate(:second)
      original = credit_payload() |> put_account_window(604_800, 100, now) |> blocking_payload(unquote(credit_blocker))
      {fake, identity, assignment} = setup_upstream(routes_for(:codex_usage, original))
      assert {:ok, identity} = refresh_at(identity, assignment, now)
      assert {:ok, %{observations: [credit_fence], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert credit_fence.source_kind == :codex_usage
      assert credit_fence.denial_category == %{spend: :spend_limit, malformed: :malformed}[unquote(credit_blocker)]

      workspace = credit_payload() |> put_account_window(604_860, 100, now) |> blocking_payload(:workspace)
      FakeUpstream.set_mode(fake, {:path_json, routes_for(:wham_usage, workspace)})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 1))
      assert {:ok, %{observations: [^credit_fence, hard_fence], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert hard_fence.denial_category == :workspace_limit
      assert hard_fence.source_kind == :wham_usage
      decision = public_decision(identity, DateTime.add(now, 1))
      refute decision.eligible?
      refute decision.credit_available?
      assert "provider_denied" in decision.reason_codes

      {first_source, first_seconds, remaining} =
        if unquote(first_clear) == :credit, do: {:codex_usage, 604_800, hard_fence}, else: {:wham_usage, 604_860, credit_fence}

      cleared_payload = credit_payload() |> put_account_window(first_seconds, 100, now)
      FakeUpstream.set_mode(fake, {:path_json, routes_for(first_source, cleared_payload)})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 2))
      assert {:ok, %{credit_permission: :available}} = CapacityFactsStore.load(identity.metadata)
      assert {:ok, %{observations: [^remaining], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      decision = public_decision(identity, DateTime.add(now, 2))
      refute decision.eligible?
      refute decision.credit_available?

      FakeUpstream.set_mode(fake, {:path_json, routes_for(first_source, %{})})
      assert {:error, %{code: :upstream_quota_unusable}} = refresh_at(identity, assignment, DateTime.add(now, 3))
      identity = Repo.reload!(identity)
      assert {:ok, %{observations: [^remaining], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      refute public_decision(identity, DateTime.add(now, 3)).eligible?

      {last_source, last_seconds} = if unquote(first_clear) == :credit, do: {:wham_usage, 604_860}, else: {:codex_usage, 604_800}
      complete = credit_payload() |> put_account_window(last_seconds, 100, now)
      FakeUpstream.set_mode(fake, {:path_json, routes_for(last_source, complete)})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 4))
      assert CapacityFactsStore.load_blockers(identity.metadata) == :error
      window_kind = if last_seconds == 604_800, do: "secondary", else: "primary"
      assert_credit_authority(identity, DateTime.add(now, 4), last_source, [{window_kind, div(last_seconds, 60)}])
    end
  end

  for credit_blocker <- [:spend, :malformed], first_clear <- [:credit, :hard] do
    @tag credits_multi_path: true
    @tag credits_negative: true
    test "one queried multi-path receipt set retains #{credit_blocker} alongside workspace through #{first_clear}-first clearance" do
      now = DateTime.utc_now() |> DateTime.add(-4, :second) |> DateTime.truncate(:second)
      credit_denial = credit_payload() |> put_account_window(604_800, 100, now) |> blocking_payload(unquote(credit_blocker))
      workspace = credit_payload() |> put_account_window(604_860, 100, now) |> blocking_payload(:workspace)
      {fake, identity, assignment} = setup_upstream(%{hd(@paths) => {200, workspace}, List.last(@paths) => {200, credit_denial}})
      assert {:ok, identity} = refresh_at(identity, assignment, now)
      assert {:ok, %{denial_category: :workspace_limit, source_kind: :wham_usage}} = CapacityFactsStore.load(identity.metadata)
      assert {:ok, %{observations: retained, overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert Enum.any?(retained, &(&1.source_kind == :wham_usage and &1.denial_category == :workspace_limit))
      assert Enum.any?(retained, &(&1.source_kind == :codex_usage and &1.denial_category == %{spend: :spend_limit, malformed: :malformed}[unquote(credit_blocker)]))

      {first_source, first_seconds, remaining_source} = if unquote(first_clear) == :credit, do: {:codex_usage, 604_800, :wham_usage}, else: {:wham_usage, 604_860, :codex_usage}
      FakeUpstream.set_mode(fake, {:path_json, routes_for(first_source, credit_payload() |> put_account_window(first_seconds, 100, now))})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 1))
      assert {:ok, %{observations: [remaining]}} = CapacityFactsStore.load_blockers(identity.metadata)
      assert remaining.source_kind == remaining_source
      refute public_decision(identity, DateTime.add(now, 1)).credit_available?

      last_seconds = if remaining_source == :codex_usage, do: 604_800, else: 604_860
      FakeUpstream.set_mode(fake, {:path_json, routes_for(remaining_source, credit_payload() |> put_account_window(last_seconds, 100, now))})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 2))
      assert CapacityFactsStore.load_blockers(identity.metadata) == :error
      window_kind = if last_seconds == 604_800, do: "secondary", else: "primary"
      assert_credit_authority(identity, DateTime.add(now, 2), remaining_source, [{window_kind, div(last_seconds, 60)}])
    end
  end

  @tag credits_negative: true
  test "a queried envelope at the exact witness cap remains valid and the next source-bound fence fails closed until credential cutover" do
    now = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    seed = credit_payload() |> put_account_window(604_800, 100, now) |> blocking_payload(:workspace)
    {fake, identity, assignment} = setup_upstream(routes_for(:codex_usage, seed))

    identity =
      Enum.reduce(0..15, identity, fn offset, identity ->
        payload = credit_payload() |> put_account_window(604_800 + offset * 60, 100, now) |> blocking_payload(:workspace)
        FakeUpstream.set_mode(fake, {:path_json, routes_for(:codex_usage, payload)})
        assert {:ok, refreshed} = refresh_at(identity, assignment, DateTime.add(now, offset, :microsecond))
        refreshed
      end)

    assert {:ok, %{observations: witnesses, overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
    assert Enum.map(witnesses, fn facts -> hd(facts.account_windows).window_minutes end) == Enum.to_list(10_080..10_095)
    refute public_decision(identity, DateTime.add(now, 15, :microsecond)).eligible?

    payload = credit_payload() |> put_account_window(605_760, 100, now) |> blocking_payload(:workspace)
    FakeUpstream.set_mode(fake, {:path_json, routes_for(:codex_usage, payload)})
    assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 16, :microsecond))
    assert {:ok, %{observations: ^witnesses, overflowed?: true}} = CapacityFactsStore.load_blockers(identity.metadata)

    identity =
      Enum.reduce(0..15, identity, fn offset, identity ->
        payload = included_payload() |> put_account_window(604_800 + offset * 60, 25, now)
        FakeUpstream.set_mode(fake, {:path_json, routes_for(:codex_usage, payload)})
        assert {:ok, refreshed} = refresh_at(identity, assignment, DateTime.add(now, 17 + offset, :microsecond))
        refreshed
      end)

    assert {:ok, %{observations: [], overflowed?: true}} = CapacityFactsStore.load_blockers(identity.metadata)
    decision = public_decision(identity, DateTime.add(now, 33, :microsecond))
    refute decision.eligible?
    refute decision.credit_available?
    assert "provider_denied" in decision.reason_codes

    epoch = CredentialFencing.credential_epoch(identity)
    identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "credential_epoch", epoch + 1)))
    FakeUpstream.set_mode(fake, {:path_json, routes_for(:codex_usage, included_payload())})
    assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 34, :microsecond))
    assert CapacityFactsStore.load_blockers(identity.metadata) == :error
    decision = public_decision(identity, DateTime.add(now, 34, :microsecond))
    assert decision.eligible?
    assert decision.capacity_basis == :windowless_provider_permission
  end

  for malformed <- [nil, %{"version" => 1, "credential_epoch" => 1, "overflowed" => "false", "observations" => []}] do
    @tag credits_negative: true
    test "malformed retained metadata #{inspect(malformed)} cannot become included authority after a queried affirmative receipt" do
      now = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      {_fake, identity, assignment} = setup_upstream(routes_for(:codex_usage, included_payload()))
      identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "quota_capacity_blocker", unquote(Macro.escape(malformed)))))
      assert {:ok, identity} = refresh_at(identity, assignment, now)
      assert {:ok, %{observations: [], overflowed?: true}} = CapacityFactsStore.load_blockers(identity.metadata)
      decision = public_decision(identity, now)
      refute decision.eligible?
      refute decision.credit_available?
      assert "provider_denied" in decision.reason_codes
    end
  end

  for malformed_receipt <- [:oversized_window, :contradictory_reached_type] do
    @tag credits_negative: true
    test "a queried #{malformed_receipt} receipt revokes previous included authority under the credential fence" do
      now = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)
      {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, included_payload()}}))
      assert {:ok, identity} = refresh_at(identity, assignment, now)
      identity = Repo.update!(Ecto.Changeset.change(identity, allow_provider_credits: false))
      assert public_decision(identity, now).eligible?

      malformed =
        case unquote(malformed_receipt) do
          :oversized_window -> included_payload() |> put_account_window(31_536_001, 25, now)
          :contradictory_reached_type -> Map.put(included_payload(), "rate_limit_reached_type", %{"type" => "rate_limit_reached"})
        end

      FakeUpstream.set_mode(fake, {:path_json, Map.new(@paths, &{&1, {200, malformed}})})
      assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 1))
      persisted = Repo.reload!(identity)
      assert {:ok, facts} = CapacityFactsStore.load(persisted.metadata)
      assert facts.observed_at == DateTime.add(now, 1)
      assert facts.credential_epoch == CredentialFencing.credential_epoch(persisted)
      assert facts.included_permission == :unknown
      assert facts.credit_permission == :unknown
      assert facts.denial_category == :malformed
      assert facts.account_windows == []
      refute persisted.allow_provider_credits
      decision = public_decision(persisted, DateTime.add(now, 1))
      refute decision.eligible?
      refute decision.credit_available?

      FakeUpstream.set_mode(fake, {:path_json, Map.new(@paths, &{&1, {200, included_payload()}})})
      assert {:ok, identity} = refresh_at(persisted, assignment, DateTime.add(now, 2))
      assert CapacityFactsStore.load_blockers(identity.metadata) == :error
      decision = public_decision(identity, DateTime.add(now, 2))
      assert decision.eligible?
      assert decision.capacity_basis == :windowless_provider_permission
    end
  end

  # Team member receipts below follow the provider's current usage receipt key
  # for key with synthetic values: a null credit balance, a 5-hour and a weekly
  # account window, and a workspace reached type while the member is denied.
  # Readings older than a usage poll are written through the same stores the
  # reconciliation writes, at their own observation time.
  @tag credits_negative: true
  test "an allowed receipt after a provider-side reset releases a retained workspace denial on the next usage poll" do
    now = DateTime.utc_now() |> DateTime.add(-600) |> DateTime.truncate(:second)
    denied_at = DateTime.add(now, -58 * 3_600)
    {fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, team_allowed(now)))
    identity = recorded_reading!(identity, team_denial(denied_at), denied_at)
    assert {:ok, %{observations: [%{denial_category: :workspace_limit}]}} = CapacityFactsStore.load_blockers(identity.metadata)
    assert public_decision(identity, denied_at).reason_codes == ["provider_denied", "provider_credit_capacity_unverified", "provider_credit_permission_unavailable"]

    assert {:ok, identity} = refresh_at(identity, assignment, now)
    assert {:ok, facts} = CapacityFactsStore.load(identity.metadata)
    assert {facts.denial_category, facts.included_permission, facts.credit_permission} == {:none, :available, :unknown}
    assert CapacityFactsStore.load_blockers(identity.metadata) == :error
    refute "provider_denied" in public_decision(identity, now).reason_codes

    # A poll at least three minutes later confirms the weekly window's provider-side zero.
    confirmed_at = DateTime.add(now, 240)
    FakeUpstream.set_mode(fake, {:path_json, routes_for(:wham_usage, team_allowed(now, confirmed_at))})
    assert {:ok, identity} = refresh_at(identity, assignment, confirmed_at)
    decision = public_decision(identity, confirmed_at)
    assert decision.eligible?
    assert decision.capacity_basis == :included_window
    assert decision.reason_codes == []
  end

  @tag credits_negative: true
  test "a workspace denial the previous release kept past its exhausted window's reset stops denying before the next usage poll" do
    now = DateTime.utc_now() |> DateTime.add(-300) |> DateTime.truncate(:second)
    denied_at = DateTime.add(now, -58 * 3_600)
    reset_issued_at = DateTime.add(now, -240)
    {_fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, team_allowed(reset_issued_at, DateTime.add(now, 60))))

    identity =
      identity
      |> previous_release_reading!(DateTime.add(denied_at, -14 * 3_600))
      |> recorded_reading!(team_denial(denied_at), denied_at)
      |> previous_release_reading!(reset_issued_at)
      |> previous_release_reading!(now, reset_issued_at)

    assert {:ok, %{denial_category: :malformed}} = CapacityFactsStore.load(identity.metadata)
    assert {:ok, %{observations: [%{denial_category: :malformed}, %{denial_category: :workspace_limit}], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)

    decision = public_decision(identity, now)
    assert decision.eligible?
    assert decision.capacity_basis == :included_window
    assert decision.reason_codes == []

    assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 60))
    assert {:ok, %{observations: [%{denial_category: :malformed}], overflowed?: false}} = CapacityFactsStore.load_blockers(identity.metadata)
    assert public_decision(identity, DateTime.add(now, 60)).eligible?
  end

  @tag credits_negative: true
  test "a workspace denial the provider still reports keeps denying until its exhausted window resets" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reset_at = DateTime.add(now, 60)
    windows = [primary: {100, reset_at}, secondary: {40, DateTime.add(now, 3 * 86_400)}]
    {fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, team_denial(DateTime.add(now, -5), windows)))
    assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, -5))
    FakeUpstream.set_mode(fake, {:path_json, routes_for(:wham_usage, team_denial(now, windows))})
    assert {:ok, identity} = refresh_at(identity, assignment, now)
    assert {:ok, %{denial_category: :workspace_limit}} = CapacityFactsStore.load(identity.metadata)

    for as_of <- [now, DateTime.add(reset_at, -1)] do
      decision = public_decision(identity, as_of)
      refute decision.eligible?
      assert "provider_denied" in decision.reason_codes
    end

    refute "provider_denied" in public_decision(identity, reset_at).reason_codes
  end

  @tag credits_negative: true
  test "a workspace denial recorded without an exhausted window does not end with a window reset" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    denial = team_denial(DateTime.add(now, -5), primary: {0, DateTime.add(now, 60)}, type: "workspace_owner_credits_depleted")
    {_fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, denial))
    assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, -5))
    decision = public_decision(identity, DateTime.add(now, 2 * 3_600))
    refute decision.eligible?
    assert "provider_denied" in decision.reason_codes
  end

  # The provider denies again after the first denial's window reset: the newer
  # denial keeps its own end after an allowed receipt without permission (a
  # malformed balance) releases the earlier witness's exhausted window.
  for {name, primary, type} <- [{"an exhausted window in a later cycle", 100, "workspace_member_usage_limit_reached"}, {"no exhausted window", 0, "workspace_owner_credits_depleted"}] do
    @tag credits_negative: true
    test "a newer workspace denial with #{name} keeps denying after a malformed allowed receipt releases the earlier one" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {first_at, newer_at, newer_reset, weekly_reset} = {DateTime.add(now, -6 * 3_600), DateTime.add(now, -1_800), DateTime.add(now, 4 * 3_600), DateTime.add(now, 6 * 86_400)}
      allowed = put_in(team_receipt(now, {20, newer_reset}, {20, weekly_reset}, nil), ["credits", "balance"], "not-a-number")
      {_fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, allowed))

      identity =
        identity
        |> recorded_reading!(team_denial(first_at, primary: {100, DateTime.add(now, -3_600)}, secondary: {16, weekly_reset}), first_at)
        |> recorded_reading!(team_denial(newer_at, primary: {unquote(primary), newer_reset}, secondary: {16, weekly_reset}, type: unquote(type)), newer_at)

      assert {:ok, identity} = refresh_at(identity, assignment, now)
      assert {:ok, %{denial_category: :malformed}} = CapacityFactsStore.load(identity.metadata)
      decision = public_decision(identity, now)
      refute decision.eligible?
      assert "provider_denied" in decision.reason_codes
      assert "provider_denied" in public_decision(identity, DateTime.add(newer_reset, 1)).reason_codes == (unquote(primary) == 0)
    end
  end

  @tag credits_negative: true
  test "a newer workspace denial resetting seconds after the first keeps denying through polls that release only the first" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {first_at, newer_at, reset, weekly_reset} = {DateTime.add(now, -1_800), DateTime.add(now, -600), DateTime.add(now, 3_600), DateTime.add(now, 6 * 86_400)}
    allowed = fn at -> put_in(team_receipt(at, {20, DateTime.add(reset, 8)}, {20, weekly_reset}, nil), ["credits", "balance"], "not-a-number") end
    {fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, allowed.(now)))

    identity =
      identity
      |> recorded_reading!(team_denial(first_at, primary: {100, reset}, secondary: {16, weekly_reset}), first_at)
      |> recorded_reading!(team_denial(newer_at, primary: {100, DateTime.add(reset, 5)}, secondary: {16, weekly_reset}), newer_at)

    assert {:ok, identity} = refresh_at(identity, assignment, now)
    FakeUpstream.set_mode(fake, {:path_json, routes_for(:wham_usage, allowed.(DateTime.add(now, 240)))})
    assert {:ok, identity} = refresh_at(identity, assignment, DateTime.add(now, 240))

    for as_of <- [DateTime.add(now, 241), DateTime.add(reset, 4)] do
      decision = public_decision(identity, as_of)
      refute decision.eligible?
      assert "provider_denied" in decision.reason_codes
    end
  end

  @tag credits_negative: true
  test "a newer workspace denial an earlier release kept only as the current reading keeps denying after the next usage poll" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {first_at, newer_at, newer_reset, weekly_reset} = {DateTime.add(now, -6 * 3_600), DateTime.add(now, -1_800), DateTime.add(now, 4 * 3_600), DateTime.add(now, 6 * 86_400)}
    allowed = put_in(team_receipt(now, {20, newer_reset}, {20, weekly_reset}, nil), ["credits", "balance"], "not-a-number")
    {_fake, identity, assignment} = setup_upstream(routes_for(:wham_usage, allowed))

    identity =
      identity
      |> recorded_reading!(team_denial(first_at, primary: {100, DateTime.add(now, -3_600)}, secondary: {16, weekly_reset}), first_at)
      |> current_reading_only!(team_denial(newer_at, primary: {100, newer_reset}, secondary: {16, weekly_reset}), newer_at)

    assert {:ok, %{observations: [%{observed_at: ^first_at}]}} = CapacityFactsStore.load_blockers(identity.metadata)
    assert {:ok, identity} = refresh_at(identity, assignment, now)
    decision = public_decision(identity, now)
    refute decision.eligible?
    assert "provider_denied" in decision.reason_codes
  end

  defp setup_upstream(routes) do
    name = :"capacity_facts_fake_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = Process.whereis(name), do: FakeUpstream.stop(%FakeUpstream{supervisor: pid})
    end)

    {:ok, fake} = FakeUpstream.start_link({:path_json, routes}, supervisor_name: name)
    Process.unlink(fake.supervisor)
    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(
        pool,
        %{metadata: %{"usage_base_url" => FakeUpstream.url(fake)}}
      )

    {fake, identity, assignment}
  end

  defp assert_unknown_receipt_diagnostic(reverse) do
    unknown = %{"diagnostic_canary" => "private-provider-value"}
    payloads = if reverse, do: [unknown, credit_payload()], else: [credit_payload(), unknown]
    {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, Enum.map(payloads, &{200, &1}))))
    observed_at = DateTime.utc_now()
    {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, observed_at, []) end)
    assert result.capacity_facts.credit_permission == :unknown
    assert length(result.capacity_observations) == 2
    assert_unknown_log(log, identity, observed_at, if(reverse, do: "wham_usage", else: "codex_usage"))
    refute log =~ "private-provider-value"
    assert requested_paths(fake) == @paths
  end

  defp assert_unusable_unknown_diagnostic(single) do
    {fake, identity, assignment} = setup_upstream(Map.new(@paths, &{&1, {200, credit_payload()}}))
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    routes = if single, do: routes_for(:wham_usage, %{}), else: Map.new(@paths, &{&1, {200, %{}}})
    FakeUpstream.set_mode(fake, {:path_json, routes})
    observed_at = DateTime.utc_now()
    {outcome, log} = with_info_log(fn -> refresh_at(identity, assignment, observed_at) end)
    assert {:error, %{code: :upstream_quota_unusable}} = outcome
    assert {:ok, facts} = CapacityFactsStore.load(Repo.reload!(identity).metadata)
    assert facts.credit_permission == :unknown
    assert facts.included_permission == :unknown
    assert_unknown_log(log, identity, observed_at, if(single, do: "wham_usage", else: "codex_usage,wham_usage"))
  end

  defp assert_denial_diagnostic_precedence(blocker, reverse) do
    denied = blocking_payload(credit_payload(), blocker)
    payloads = if reverse, do: [%{}, denied], else: [denied, %{}]
    {fake, identity, assignment} = setup_upstream(Map.new(Enum.zip(@paths, Enum.map(payloads, &{200, &1}))))
    {{:ok, result}, log} = with_info_log(fn -> UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), []) end)
    assert result.capacity_facts.denial_category == %{malformed: :malformed, spend: :spend_limit, workspace: :workspace_limit}[blocker]
    refute result.capacity_facts.credit_permission == :available
    refute log =~ "quota capacity authority unavailable"
    assert requested_paths(fake) == @paths
  end

  defp assert_unknown_log(log, identity, observed_at, sources) do
    assert [[diagnostic]] = Regex.scan(~r/quota capacity authority unavailable ([^\n]+)/, log, capture: :all_but_first)

    fields =
      Map.new(String.split(diagnostic), fn field ->
        [key, value] = String.split(field, "=", parts: 2)
        {key, value}
      end)

    identity_hash = :crypto.hash(:sha256, identity.id) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    assert fields == %{
             "reason_code" => "unknown_usage_receipt",
             "identity_hash" => identity_hash,
             "observed_at" => DateTime.to_iso8601(observed_at),
             "sources" => sources
           }
  end

  defp with_info_log(fun) do
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.with_log([level: :info, format: "$message\n"], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp refresh_at(identity, assignment, observed_at), do: PoolReconciliation.refresh_quota_from_usage(identity, assignment, observed_at: observed_at)

  defp public_decision(identity, as_of) do
    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], as_of)[identity.id]
    Upstreams.provider_credits_decision(snapshot, %{model: "gpt-6-luna", serving_mode: :full, transport: :http_json})
  end

  defp assert_credit_authority(identity, observed_at, source_kind, account_windows) do
    persisted = Repo.reload!(identity)
    assert persisted.allow_provider_credits
    assert {:ok, facts} = CapacityFactsStore.load(persisted.metadata)
    assert facts.observed_at == observed_at
    assert facts.credential_epoch == CredentialFencing.credential_epoch(persisted)
    assert facts.source_kind == source_kind
    assert facts.included_permission == :exhausted
    assert facts.credit_permission == :available
    assert facts.denial_category == :included_limit
    assert Enum.map(facts.account_windows, &{&1.window_kind, &1.window_minutes}) == account_windows

    decision = public_decision(persisted, observed_at)
    assert decision.credit_available?
    assert decision.eligible?
    assert decision.capacity_basis == :provider_credits
    assert decision.reason_codes == []
    assert %{status: :provider_attested, scope: scope} = decision.qualification
    assert scope.model == "gpt-6-luna"
    assert scope.serving_mode == :full
    assert scope.transport == :http_json
    assert scope.source_kind == source_kind
    assert scope.account_windows == account_windows
  end

  defp routes_for(:wham_usage, payload), do: %{hd(@paths) => {200, payload}, List.last(@paths) => {404, %{}}}
  defp routes_for(:codex_usage, payload), do: %{hd(@paths) => {404, %{}}, List.last(@paths) => {200, payload}}

  defp included_payload, do: put_in(credit_payload(), ["rate_limit"], %{"allowed" => true, "limit_reached" => false})

  defp put_account_window(payload, nil, _percent, _now), do: payload

  defp put_account_window(payload, seconds, percent, now) do
    put_in(payload, ["rate_limit", "primary_window"], %{"used_percent" => percent, "limit_window_seconds" => seconds, "reset_after_seconds" => 3_600, "reset_at" => DateTime.to_unix(DateTime.add(now, 3_600))})
  end

  defp blocking_payload(payload, :spend), do: Map.put(payload, "spend_control", %{"reached" => true})
  defp blocking_payload(payload, :malformed), do: Map.put(payload, "spend_control", %{"reached" => "false"})
  defp blocking_payload(payload, :workspace), do: Map.put(payload, "rate_limit_reached_type", %{"type" => "workspace_owner_usage_limit_reached"})

  defp credit_payload do
    %{"plan_type" => "synthetic", "rate_limit" => %{"allowed" => false, "limit_reached" => true}, "credits" => %{"balance" => "0.12500", "has_credits" => true, "unlimited" => false}, "spend_control" => %{"reached" => false}}
  end

  defp team_denial(at, opts \\ []) do
    primary = Keyword.get(opts, :primary, {100, DateTime.add(at, 17_160)})
    secondary = Keyword.get(opts, :secondary, {16, DateTime.add(at, 604_800 - 840)})
    team_receipt(at, primary, secondary, %{"type" => Keyword.get(opts, :type, "workspace_member_usage_limit_reached")})
  end

  # The same provider-side reset read at `at`: its windows started at `issued_at`.
  defp team_allowed(issued_at, at \\ nil), do: team_receipt(at || issued_at, {0, DateTime.add(issued_at, 18_000)}, {0, DateTime.add(issued_at, 604_800)}, nil)

  defp team_receipt(at, primary, secondary, reached_type) do
    %{
      "user_id" => "user-synthetic-0340",
      "account_id" => "00000000-0000-4000-8000-000000000340",
      "email" => "member@example.test",
      "plan_type" => "team",
      "rate_limit" => %{"allowed" => is_nil(reached_type), "limit_reached" => not is_nil(reached_type), "primary_window" => team_window(at, 18_000, primary), "secondary_window" => team_window(at, 604_800, secondary)},
      "code_review_rate_limit" => nil,
      "additional_rate_limits" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "overage_limit_reached" => false, "balance" => nil, "approx_local_messages" => [0, 0], "approx_cloud_messages" => [0, 0]},
      "spend_control" => %{"reached" => false, "individual_limit" => nil},
      "rate_limit_reached_type" => reached_type,
      "rate_limit_reset_credits" => %{"available_count" => 0, "applicable_available_count" => 0},
      "model_usage" => %{},
      "promo" => nil
    }
  end

  defp team_window(at, seconds, {percent, reset_at}),
    do: %{"used_percent" => percent, "limit_window_seconds" => seconds, "reset_after_seconds" => DateTime.diff(reset_at, at), "reset_at" => DateTime.to_unix(reset_at)}

  # What the reconciliation persists for a receipt, written at its own observation time.
  defp recorded_reading!(identity, payload, at) do
    identity = Repo.reload!(identity)
    result = record_windows!(identity, payload, at)
    epoch = CredentialFencing.credential_epoch(identity)
    facts = %{result.capacity_facts | source_kind: :wham_usage}

    metadata =
      identity.metadata
      |> AccountAvailabilityStore.transition(result.account_availability, at, epoch)
      |> CapacityFactsStore.transition(facts, epoch)
      |> CapacityFactsStore.record_observations([facts], epoch)

    Repo.update!(Ecto.Changeset.change(identity, metadata: metadata))
  end

  # What the previous release persisted for an allowed Team member receipt: its
  # windows and availability, the capacity reading revoked as malformed (a null
  # credit balance), retained as a credit witness when none was, and no
  # supersession of a retained denial.
  defp previous_release_reading!(identity, at, issued_at \\ nil) do
    identity = Repo.reload!(identity)
    result = record_windows!(identity, team_allowed(issued_at || at, at), at)
    epoch = CredentialFencing.credential_epoch(identity)
    encoded = CapacityFactsStore.encode!(%{CapacityFacts.revoke(result.capacity_facts, :malformed) | source_kind: :wham_usage}, epoch)
    blockers = identity.metadata["quota_capacity_blocker"] || %{"version" => 1, "credential_epoch" => epoch, "overflowed" => false, "observations" => [encoded]}

    metadata =
      identity.metadata
      |> AccountAvailabilityStore.transition(result.account_availability, at, epoch)
      |> Map.put("quota_capacity_facts", encoded)
      |> Map.put("quota_capacity_blocker", blockers)

    Repo.update!(Ecto.Changeset.change(identity, metadata: metadata))
  end

  # What an earlier release persisted for a denial its retention left out: the
  # windows and availability, and the reading only as the current capacity facts.
  defp current_reading_only!(identity, payload, at) do
    identity = Repo.reload!(identity)
    result = record_windows!(identity, payload, at)
    epoch = CredentialFencing.credential_epoch(identity)
    encoded = CapacityFactsStore.encode!(%{result.capacity_facts | source_kind: :wham_usage}, epoch)
    metadata = identity.metadata |> AccountAvailabilityStore.transition(result.account_availability, at, epoch) |> Map.put("quota_capacity_facts", encoded)
    Repo.update!(Ecto.Changeset.change(identity, metadata: metadata))
  end

  defp record_windows!(identity, payload, at) do
    assert {:ok, result} = Evidence.CodexParsers.parse_codex_usage_result(payload, at)

    for evidence <- result.windows do
      assert {:ok, _} = EvidenceStore.record_evidence(identity, Evidence.to_window_attrs(evidence), at, at)
    end

    result
  end

  defp requested_paths(fake), do: Enum.map(FakeUpstream.requests(fake), & &1.path)
end
