defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreCodecBoundaryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @observed_at ~U[2026-11-01 10:00:00.000000Z]
  @candidate_key "__quota_confirmed_candidate_v1"
  @permission_keys ~w(independent_spark_permission independent_spark_permission_observed_at independent_spark_permission_reset_at rate_limit_allowed rate_limit_reached)

  test "a prepared changeset uses the supplied identity and normalized evidence without writing" do
    identity = identity!()
    attrs = attrs(%{upstream_identity_id: Ecto.UUID.generate(), used_percent: "42.500"})

    assert {:ok, changeset} = EvidenceStore.evidence_changeset(identity.id, attrs, @observed_at)

    assert changeset.valid?
    prepared = Ecto.Changeset.apply_changes(changeset)
    assert prepared.upstream_identity_id == identity.id
    assert prepared.quota_key == "account"
    assert Decimal.equal?(prepared.used_percent, Decimal.new("42.5"))
    assert prepared.observed_at == @observed_at
    assert %DateTime{} = prepared.created_at
    assert windows(identity) == []
  end

  test "a prepared changeset can resolve an identity carried by persisted attributes" do
    identity = identity!()
    attrs = attrs() |> Map.put(:upstream_identity_id, identity.id)

    assert {:ok, changeset} = EvidenceStore.evidence_changeset(nil, attrs, @observed_at)

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :upstream_identity_id) == identity.id
    assert windows(identity) == []
  end

  test "preparing evidence rejects a missing identity" do
    assert {:error, %{upstream_identity_id: ["can't be blank"]}} =
             EvidenceStore.evidence_changeset(nil, attrs(), @observed_at)
  end

  test "preparing evidence returns normalization errors before making a changeset" do
    identity = identity!()

    assert {:error, errors} =
             EvidenceStore.evidence_changeset(identity, attrs(%{window_minutes: 0}), @observed_at)

    assert Map.has_key?(errors, :window_minutes)
    assert windows(identity) == []
  end

  test "recording evidence rejects a missing identity without creating a row" do
    assert {:error, %{upstream_identity_id: ["can't be blank"]}} =
             EvidenceStore.record_evidence(nil, attrs(), @observed_at, @observed_at)
  end

  test "a writer using a UUID reference remains inside the caller's rollback" do
    identity = identity!()

    assert {:error, :caller_cancelled} =
             Repo.transaction(fn ->
               assert {:ok, recorded} =
                        EvidenceStore.record_evidence(identity.id, attrs(), @observed_at, @observed_at)

               assert recorded.upstream_identity_id == identity.id
               assert [%{id: id}] = windows(identity)
               assert id == recorded.id
               Repo.rollback(:caller_cancelled)
             end)

    assert windows(identity) == []
  end

  for {label, candidate_change} <- [
        {:numeric_percent, %{"used_percent" => 0}},
        {:malformed_reset, %{"reset_at" => %{"invalid" => true}}},
        {:malformed_observation, %{"observed_at" => false}},
        {:unexpected_field, %{"unknown" => true}}
      ] do
    test "the candidate codec rejects #{label} persisted data" do
      metadata = candidate_metadata()
      changed = Map.update!(metadata, @candidate_key, &Map.merge(&1, unquote(Macro.escape(candidate_change))))

      assert :none = EvidenceStore.parse_candidate(changed)
      refute EvidenceStore.candidate_provider_status_safe?(changed)
    end
  end

  test "a non-map provider status cannot establish safe candidate permission" do
    for value <- [nil, [], true, "allowed"] do
      assert :none = EvidenceStore.parse_candidate_provider_status(value)
      refute EvidenceStore.candidate_provider_status_safe?(value)
    end
  end

  test "encoding a candidate with malformed optional provider metadata does not fabricate permission" do
    evidence = Evidence.new!(attrs(%{used_percent: 0}), @observed_at)

    for provider_metadata <- [nil, [], true] do
      encoded = EvidenceStore.put_candidate(%{"keep" => true}, %{evidence | metadata: provider_metadata})

      assert {:ok, candidate} = EvidenceStore.parse_candidate(encoded)
      assert Decimal.equal?(candidate.used_percent, 0)
      assert candidate.reset_at == evidence.reset_at
      assert candidate.observed_at == @observed_at
      assert :none = EvidenceStore.parse_candidate_provider_status(encoded)
      refute EvidenceStore.candidate_provider_status_safe?(encoded)
      assert encoded["keep"]
    end
  end

  test "unparsed candidate shapes cannot be considered equivalent to provider evidence" do
    evidence = Evidence.new!(attrs(%{used_percent: 0}), @observed_at)

    refute EvidenceStore.candidate_equivalent?(%{}, evidence)
    refute EvidenceStore.candidate_equivalent?(%{used_percent: nil, reset_at: nil}, evidence)
  end

  test "unparsed candidate clocks cannot establish a valid observation window" do
    refute EvidenceStore.candidate_valid?(%{}, @observed_at)
    refute EvidenceStore.candidate_valid?(%{reset_at: nil, observed_at: @observed_at}, @observed_at)
  end

  for {offset, expected_permission} <- [{-10, true}, {10, false}] do
    test "an additional meter permission observation #{offset} seconds from the stored one respects its own clock" do
      identity = identity!()
      initial_metadata = spark_permission(true, @observed_at)
      initial_attrs = spark_attrs(initial_metadata)
      assert {:ok, initial} = EvidenceStore.record_evidence(identity, initial_attrs, @observed_at, @observed_at)
      incoming_at = DateTime.add(@observed_at, unquote(offset), :second)

      incoming =
        spark_attrs(spark_permission(false, incoming_at))
        |> Map.put(:observed_at, incoming_at)
        |> Map.put(:last_sync_at, incoming_at)

      assert {:ok, updated} =
               EvidenceStore.record_evidence(identity, incoming, incoming_at, DateTime.add(@observed_at, 20, :second))

      assert updated.id == initial.id
      expected_at = if unquote(expected_permission), do: @observed_at, else: incoming_at
      expected = spark_permission(unquote(expected_permission), expected_at)
      assert Map.take(updated.metadata, @permission_keys) == Map.take(expected, @permission_keys)
      assert [%{id: id}] = windows(identity)
      assert id == initial.id
    end
  end

  test "ambiguous stable meter aliases are rejected without updating either valid historical row" do
    identity = identity!()
    token = "sample-meter"

    historical =
      for model <- ["sample-model-a", "sample-model-b"] do
        meter = meter_attrs(model, token)
        assert {:ok, changeset} = EvidenceStore.evidence_changeset(identity, meter, @observed_at)
        Repo.insert!(changeset)
      end

    before = windows(identity)

    assert {:error, %{code: :ambiguous_quota_window_meter}} =
             EvidenceStore.record_evidence(identity, meter_attrs("sample-model-c", token), @observed_at, @observed_at)

    assert windows(identity) == before
    assert Enum.map(before, & &1.id) |> Enum.sort() == Enum.map(historical, & &1.id) |> Enum.sort()
  end

  test "a resetless runtime reading cannot clear a pending provider restart clock" do
    identity = identity!()
    record!(identity, %{})
    candidate_at = DateTime.add(@observed_at, 10, :second)
    candidate_reset = DateTime.add(candidate_at, 7, :day)
    metadata = %{"rate_limit_allowed" => true, "rate_limit_reached" => false, "reset_after_seconds" => 604_800}
    record!(identity, %{used_percent: Decimal.new(0), reset_at: candidate_reset, metadata: metadata}, candidate_at)
    pending = provider!(identity)
    assert {:ok, %{observed_at: ^candidate_at}} = EvidenceStore.parse_candidate(pending.metadata)

    runtime_at = DateTime.add(candidate_at, 10, :second)
    runtime = record!(identity, %{source: "codex_rate_limit_event", used_percent: Decimal.new(50), reset_at: nil}, runtime_at)

    assert is_nil(runtime.reset_at)
    assert Decimal.equal?(runtime.used_percent, 50)
    assert provider!(identity) == pending
  end

  test "a lower resetless runtime reading does not erase already measured runtime pressure" do
    identity = identity!()
    initial = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(70), reset_at: nil})

    retained = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(20), reset_at: nil}, DateTime.add(@observed_at, 10, :second))

    assert retained.id == initial.id
    assert Decimal.equal?(retained.used_percent, 70)
    assert is_nil(retained.reset_at)
    assert retained.observed_at == @observed_at
  end

  test "a different provider descriptor cannot attest a runtime percentage rollback" do
    identity = identity!()
    record!(identity, %{window_kind: "primary", window_minutes: 300, reset_at: DateTime.add(@observed_at, 300, :minute)})
    initial = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(70)})

    retained = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(20)}, DateTime.add(@observed_at, 10, :second))

    assert retained.id == initial.id
    assert Decimal.equal?(retained.used_percent, 70)
    assert retained.reset_at == initial.reset_at
    assert retained.observed_at == @observed_at
  end

  test "an independent feature meter adopts its current reading without an account rollback rule" do
    identity = identity!()
    descriptor = %{quota_key: "sample-feature", quota_scope: "feature", quota_family: "sample-feature", window_minutes: 1_440, source: "codex_response_headers"}
    initial = record!(identity, Map.put(descriptor, :used_percent, Decimal.new(70)))
    later = DateTime.add(@observed_at, 10, :second)

    current = record!(identity, Map.put(descriptor, :used_percent, Decimal.new(20)), later)

    assert current.id == initial.id
    assert Decimal.equal?(current.used_percent, 20)
    assert current.observed_at == later
    assert current.quota_scope == "feature"
  end

  test "JSON-null legacy metadata does not crash an explicit runtime observation" do
    identity = identity!()
    reset = DateTime.add(@observed_at, 3_600, :second)
    initial = record!(identity, %{source: "codex_response_headers", window_kind: "primary", window_minutes: 300, reset_at: reset})
    Repo.query!("UPDATE account_quota_windows SET metadata = 'null'::jsonb WHERE id = $1", [Ecto.UUID.dump!(initial.id)])
    assert Repo.reload!(initial).metadata == nil

    updated =
      record!(identity, %{source: "codex_response_headers", window_kind: "primary", window_minutes: 300, used_percent: Decimal.new(50), reset_at: reset, metadata: %{"reset_at_source" => "explicit"}}, DateTime.add(@observed_at, 10, :second))

    assert updated.id == initial.id
    assert Decimal.equal?(updated.used_percent, 50)
    assert updated.reset_at == reset
    assert updated.metadata["reset_at_source"] == "explicit"
  end

  defp identity!, do: active_upstream_assignment_fixture(pool_fixture()).identity

  defp record!(identity, overrides, at \\ @observed_at) do
    attrs = attrs(overrides) |> Map.put(:observed_at, at) |> Map.put(:last_sync_at, at)
    assert {:ok, window} = EvidenceStore.record_evidence(identity, attrs, at, at)
    window
  end

  defp provider!(identity) do
    Repo.one!(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id and window.source == "codex_usage_api" and window.window_kind == "secondary")
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_usage_api",
        source_precision: "observed",
        freshness_state: "fresh",
        used_percent: Decimal.new(42),
        reset_at: DateTime.add(@observed_at, 5, :day),
        observed_at: @observed_at,
        last_sync_at: @observed_at,
        metadata: %{"rate_limit_allowed" => true, "rate_limit_reached" => false}
      },
      overrides
    )
  end

  defp candidate_metadata do
    evidence = Evidence.new!(attrs(%{used_percent: 0}), @observed_at)
    EvidenceStore.put_candidate(%{"keep" => true}, evidence)
  end

  defp spark_attrs(metadata) do
    attrs(%{
      quota_key: "codex_spark",
      quota_scope: "model",
      quota_family: "codex_spark",
      model: "gpt-5.3-codex-spark",
      window_kind: "primary",
      window_minutes: 300,
      raw_metered_feature: "codex_bengalfox",
      used_percent: Decimal.new(20),
      metadata: metadata
    })
  end

  defp spark_permission(allowed, observed_at) do
    %{
      "independent_spark_permission" => allowed,
      "independent_spark_permission_observed_at" => DateTime.to_iso8601(observed_at),
      "independent_spark_permission_reset_at" => DateTime.to_iso8601(DateTime.add(@observed_at, 5, :day)),
      "rate_limit_allowed" => allowed,
      "rate_limit_reached" => not allowed
    }
  end

  defp meter_attrs(model, token) do
    attrs(%{
      quota_key: model,
      quota_scope: "model",
      quota_family: model,
      model: model,
      raw_limit_id: token,
      raw_metered_feature: token
    })
  end

  defp windows(identity) do
    Repo.all(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id, order_by: window.id)
  end
end
