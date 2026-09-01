defmodule CodexPooler.Upstreams.Quota.AccountAvailabilityStoreTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.AccountAvailability
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @observed_at ~U[2026-08-20 10:11:12.123456Z]

  test "encodes and decodes only the exact four-key snapshot" do
    encoded = AccountAvailabilityStore.encode!(:available, @observed_at, 3)

    assert encoded == %{
             "version" => 1,
             "state" => "available",
             "observed_at" => "2026-08-20T10:11:12.123456Z",
             "credential_epoch" => 3
           }

    assert {:ok, snapshot} = AccountAvailabilityStore.decode(encoded)
    assert snapshot.state == :available
    assert snapshot.observed_at == @observed_at
    assert snapshot.credential_epoch == 3

    invalid = [
      Map.put(encoded, "extra", true),
      Map.put(encoded, "version", 2),
      Map.put(encoded, "state", "affirmative"),
      Map.put(encoded, "observed_at", 123),
      Map.put(encoded, "observed_at", "not-a-time"),
      Map.put(encoded, "credential_epoch", 0),
      Map.delete(encoded, "state")
    ]

    assert Enum.all?(invalid, &(AccountAvailabilityStore.decode(&1) == :error))
    assert AccountAvailabilityStore.decode(nil) == :error
  end

  test "validates current epoch, freshness, and future skew without expiring blockers" do
    available =
      AccountAvailabilityStore.decode!(
        AccountAvailabilityStore.encode!(:available, @observed_at, 4)
      )

    blocked =
      AccountAvailabilityStore.decode!(
        AccountAvailabilityStore.encode!(:blocked, @observed_at, 4)
      )

    ttl = Evidence.freshness_ttl_seconds()
    skew = Evidence.future_observed_skew_seconds()

    assert AccountAvailabilityStore.available?(
             available,
             4,
             DateTime.add(@observed_at, ttl, :second)
           )

    refute AccountAvailabilityStore.available?(
             available,
             4,
             DateTime.add(@observed_at, ttl + 1, :second)
           )

    refute AccountAvailabilityStore.available?(
             available,
             4,
             DateTime.add(@observed_at, ttl * 1_000_000 + 500_000, :microsecond)
           )

    refute AccountAvailabilityStore.available?(available, 5, @observed_at)

    assert AccountAvailabilityStore.blocked?(
             blocked,
             4,
             DateTime.add(@observed_at, ttl * 10, :second)
           )

    assert AccountAvailabilityStore.blocked?(
             blocked,
             4,
             DateTime.add(@observed_at, -skew, :second)
           )

    refute AccountAvailabilityStore.blocked?(
             blocked,
             4,
             DateTime.add(@observed_at, -skew - 1, :second)
           )

    refute AccountAvailabilityStore.blocked?(
             blocked,
             4,
             DateTime.add(@observed_at, -(skew * 1_000_000 + 500_000), :microsecond)
           )

    refute AccountAvailabilityStore.blocked?(blocked, 5, @observed_at)
  end

  test "blocked survives ambiguity byte-identically while affirmative replaces it and windows clear it" do
    blocked = AccountAvailabilityStore.encode!(:blocked, @observed_at, 2)
    metadata = %{"other" => %{"kept" => true}, AccountAvailabilityStore.metadata_key() => blocked}

    for observation <- [
          AccountAvailability.new!(:unknown, :conflict, :unknown),
          AccountAvailability.new!(:unknown, :no_proof, :absent),
          nil
        ] do
      assert AccountAvailabilityStore.transition(
               metadata,
               observation,
               DateTime.add(@observed_at, 1, :second),
               2
             ) == metadata
    end

    available = AccountAvailability.new!(:available, :affirmative, :absent)

    replaced =
      AccountAvailabilityStore.transition(
        metadata,
        available,
        DateTime.add(@observed_at, 2, :second),
        2
      )

    assert get_in(replaced, [AccountAvailabilityStore.metadata_key(), "state"]) == "available"
    assert replaced["other"] == metadata["other"]

    assert AccountAvailabilityStore.clear(replaced)["other"] == metadata["other"]

    refute Map.has_key?(
             AccountAvailabilityStore.clear(replaced),
             AccountAvailabilityStore.metadata_key()
           )
  end

  test "credential fencing rejects old sequences and a failed callback rolls back windows and metadata" do
    identity = upstream_identity_fixture(metadata: %{"coexists" => %{"kept" => true}})
    {:ok, identity, old_fence} = CredentialFencing.allocate_usage_probe(identity)
    {:ok, identity, current_fence} = CredentialFencing.allocate_usage_probe(identity)

    available = AccountAvailability.new!(:available, :affirmative, :absent)

    assert {:ok, :applied, identity, :stored} =
             CredentialFencing.apply_usage_success(identity, current_fence, fn locked ->
               metadata =
                 AccountAvailabilityStore.transition(
                   locked.metadata,
                   available,
                   @observed_at,
                   current_fence.credential_epoch
                 )

               locked
               |> Ecto.Changeset.change(metadata: metadata)
               |> Repo.update!()

               {:ok, :stored}
             end)

    persisted = Repo.reload!(identity)
    persisted_metadata = persisted.metadata
    assert persisted_metadata["coexists"] == %{"kept" => true}

    assert {:ok, :superseded, _identity, nil} =
             CredentialFencing.apply_usage_success(persisted, old_fence, fn _locked ->
               flunk("superseded callback must not run")
             end)

    assert Repo.reload!(persisted).metadata == persisted_metadata

    {:ok, persisted, rollback_fence} = CredentialFencing.allocate_usage_probe(persisted)
    rollback_baseline_metadata = Repo.reload!(persisted).metadata

    assert {:error, :forced_rollback} =
             CredentialFencing.apply_usage_success(persisted, rollback_fence, fn locked ->
               assert {:ok, [_window]} =
                        Windows.upsert_quota_windows(
                          locked,
                          [
                            %{
                              quota_key: "account",
                              window_kind: "primary",
                              window_minutes: 300,
                              used_percent: Decimal.new("1"),
                              reset_at: DateTime.add(@observed_at, 1, :hour),
                              observed_at: @observed_at,
                              last_sync_at: @observed_at,
                              source: "codex_usage_api",
                              source_precision: "observed",
                              quota_scope: "account",
                              quota_family: "account",
                              freshness_state: "fresh"
                            }
                          ],
                          delete_missing?: true,
                          broadcast?: false
                        )

               unknown = AccountAvailability.new!(:unknown, :conflict, :unknown)

               metadata =
                 AccountAvailabilityStore.transition(
                   locked.metadata,
                   unknown,
                   DateTime.add(@observed_at, 1, :second),
                   rollback_fence.credential_epoch
                 )

               locked
               |> UpstreamIdentity.changeset(%{metadata: metadata})
               |> Repo.update!()

               {:error, :forced_rollback}
             end)

    assert Repo.reload!(persisted).metadata == rollback_baseline_metadata
    assert Windows.list_evidence(persisted) == []
  end

  test "credential rotation supersedes the old probe and invalidates its snapshot epoch" do
    identity = upstream_identity_fixture()
    {:ok, identity, old_fence} = CredentialFencing.allocate_usage_probe(identity)

    metadata =
      identity.metadata
      |> AccountAvailabilityStore.transition(
        AccountAvailability.new!(:available, :affirmative, :absent),
        @observed_at,
        old_fence.credential_epoch
      )

    identity =
      identity
      |> UpstreamIdentity.changeset(%{metadata: metadata})
      |> Repo.update!()

    rotated =
      identity
      |> UpstreamIdentity.changeset(%{
        metadata: CredentialFencing.advance_credential_epoch(identity)
      })
      |> Repo.update!()

    assert {:ok, :superseded, current, nil} =
             CredentialFencing.apply_usage_success(rotated, old_fence, fn _locked ->
               flunk("old-credential callback must not run")
             end)

    assert {:ok, snapshot} = AccountAvailabilityStore.load(current.metadata)
    refute AccountAvailabilityStore.available?(snapshot, 2, @observed_at)
  end
end
