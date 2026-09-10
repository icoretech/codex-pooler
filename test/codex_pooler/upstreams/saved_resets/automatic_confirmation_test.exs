defmodule CodexPooler.Upstreams.SavedResets.AutomaticConfirmationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.SavedResets.AutomaticConfirmation

  @first ~U[2026-09-09 10:00:00Z]
  @second ~U[2026-09-09 10:01:00Z]
  @third ~U[2026-09-09 10:02:00Z]
  @reset ~U[2026-09-12 10:00:00Z]
  @identity_id "00000000-0000-4000-8000-000000000001"
  @other_identity_id "00000000-0000-4000-8000-000000000003"
  @scope String.duplicate("a", 64)
  @descriptor String.duplicate("b", 64)

  defp proof_binding(overrides \\ %{}) do
    Map.merge(
      %{
        identity_id: @identity_id,
        credential_epoch: 3,
        reset_identity: DateTime.to_iso8601(@reset),
        provider_scope: @scope,
        descriptor: @descriptor,
        trigger: :blocked,
        threshold_percent: nil,
        bank_count: 3,
        keep_credits: 0,
        permission: %{allowed: false, reached: true, account_state: "blocked"}
      },
      overrides
    )
  end

  defp observation(at, overrides \\ []) do
    Map.merge(
      %{
        binding: proof_binding(),
        provider_observed_at: at,
        observed_at: at,
        used_percent: 100.0,
        rate_limit_allowed: false,
        rate_limit_reached: true,
        reset_at: @reset,
        available_count: 3
      },
      Map.new(overrides)
    )
  end

  defp threshold_observation(at, overrides \\ []) do
    observation(
      at,
      Keyword.merge(
        [
          binding:
            proof_binding(%{
              trigger: :threshold,
              threshold_percent: 95,
              permission: %{allowed: true, reached: false, account_state: "available"}
            }),
          used_percent: 96.0,
          rate_limit_allowed: true,
          rate_limit_reached: false
        ],
        overrides
      )
    )
  end

  defp confirmed_metadata do
    %{}
    |> AutomaticConfirmation.observe(observation(@first))
    |> AutomaticConfirmation.observe(observation(@second))
  end

  describe "observe/2" do
    test "one coherent observation is only a candidate" do
      metadata = AutomaticConfirmation.observe(%{"other" => true}, observation(@first))

      assert AutomaticConfirmation.state(metadata) == "candidate"
      assert metadata["other"] == true
      refute AutomaticConfirmation.confirmed?(metadata, @second)
    end

    test "two strictly newer equivalent observations confirm blocked pressure" do
      metadata = confirmed_metadata()

      assert AutomaticConfirmation.state(metadata) == "confirmed"
      assert AutomaticConfirmation.confirmed?(metadata, @second)
      assert AutomaticConfirmation.confirmed?(metadata, @second, keep_credits: 0)
      assert AutomaticConfirmation.confirmed?(metadata, @second, max_age_seconds: 0)

      marker = metadata[AutomaticConfirmation.metadata_key()]
      assert marker["observation_count"] == 2
      assert marker["first"]["provider_observed_at"] == DateTime.to_iso8601(@first)
      assert marker["latest"]["provider_observed_at"] == DateTime.to_iso8601(@second)
    end

    test "a replayed or older receipt never counts as the second observation" do
      candidate = AutomaticConfirmation.observe(%{}, observation(@second))

      replayed = AutomaticConfirmation.observe(candidate, observation(@second))
      assert replayed == candidate
      refute AutomaticConfirmation.confirmed?(replayed, @third)

      older = AutomaticConfirmation.observe(candidate, observation(@first))
      assert older == candidate
      refute AutomaticConfirmation.confirmed?(older, @third)
    end

    test "a newer equivalent observation keeps a confirmation and advances latest" do
      metadata = AutomaticConfirmation.observe(confirmed_metadata(), observation(@third))

      assert AutomaticConfirmation.state(metadata) == "confirmed"
      marker = metadata[AutomaticConfirmation.metadata_key()]
      assert marker["observation_count"] == 2
      assert marker["first"]["provider_observed_at"] == DateTime.to_iso8601(@first)
      assert marker["latest"]["provider_observed_at"] == DateTime.to_iso8601(@third)
    end

    test "any binding change restarts the proof as a new candidate" do
      for change <- [
            %{identity_id: @other_identity_id},
            %{credential_epoch: 4},
            %{reset_identity: DateTime.to_iso8601(@third)},
            %{provider_scope: String.duplicate("c", 64)},
            %{descriptor: String.duplicate("d", 64)},
            %{keep_credits: 1}
          ] do
        candidate = AutomaticConfirmation.observe(%{}, observation(@first))

        restarted =
          AutomaticConfirmation.observe(
            candidate,
            observation(@second, binding: proof_binding(change))
          )

        assert AutomaticConfirmation.state(restarted) == "candidate",
               "expected restart for #{inspect(change)}"

        refute AutomaticConfirmation.confirmed?(restarted, @second)

        marker = restarted[AutomaticConfirmation.metadata_key()]
        assert marker["first"]["provider_observed_at"] == DateTime.to_iso8601(@second)
      end
    end

    test "a changed reset restarts even when the encoded reset identity is unchanged" do
      candidate = AutomaticConfirmation.observe(%{}, observation(@first))

      restarted =
        AutomaticConfirmation.observe(
          candidate,
          observation(@second, reset_at: DateTime.add(@reset, 1, :second))
        )

      assert AutomaticConfirmation.state(restarted) == "candidate"
    end

    test "allowed, below-threshold, conflicting and malformed observations clear the proof" do
      metadata = confirmed_metadata()

      for observation <- [
            observation(@third, rate_limit_allowed: true, rate_limit_reached: false),
            observation(@third, used_percent: 32.0),
            observation(@third, rate_limit_allowed: true),
            observation(@third, binding: %{}),
            observation(@third, provider_observed_at: "not-a-time")
          ] do
        cleared = AutomaticConfirmation.observe(metadata, observation)

        refute Map.has_key?(cleared, AutomaticConfirmation.metadata_key()),
               "expected clear for #{inspect(observation)}"
      end
    end

    test "an observation whose binding claims blocked while the receipt says allowed is not a candidate" do
      metadata =
        AutomaticConfirmation.observe(
          %{},
          observation(@first, rate_limit_allowed: true, rate_limit_reached: false)
        )

      assert metadata == %{}
    end
  end

  describe "confirmed?/3" do
    test "requires the trigger, threshold, keep-credits and identity binding to match" do
      metadata = confirmed_metadata()

      refute AutomaticConfirmation.confirmed?(metadata, @second, trigger: :threshold)
      refute AutomaticConfirmation.confirmed?(metadata, @second, keep_credits: 1)

      threshold =
        %{}
        |> AutomaticConfirmation.observe(threshold_observation(@first))
        |> AutomaticConfirmation.observe(threshold_observation(@second))

      assert AutomaticConfirmation.confirmed?(threshold, @second,
               trigger: :threshold,
               threshold_percent: 95
             )

      refute AutomaticConfirmation.confirmed?(threshold, @second,
               trigger: :threshold,
               threshold_percent: 97
             )

      refute AutomaticConfirmation.confirmed?(threshold, @second, trigger: :blocked)
    end

    test "requires a fresh, non-future proof clock and a future reset" do
      metadata = confirmed_metadata()

      refute AutomaticConfirmation.confirmed?(metadata, @first)
      refute AutomaticConfirmation.confirmed?(metadata, DateTime.add(@second, 901, :second))
      assert AutomaticConfirmation.confirmed?(metadata, DateTime.add(@second, 900, :second))
      refute AutomaticConfirmation.confirmed?(metadata, @reset)
    end

    test "a bank at or below keep credits corroborates pressure but is not spendable" do
      keep = proof_binding(%{bank_count: 1, keep_credits: 1})

      metadata =
        %{}
        |> AutomaticConfirmation.observe(observation(@first, binding: keep, available_count: 1))
        |> AutomaticConfirmation.observe(observation(@second, binding: keep, available_count: 1))

      assert AutomaticConfirmation.state(metadata) == "confirmed"
      refute AutomaticConfirmation.confirmed?(metadata, @second, keep_credits: 1)

      assert AutomaticConfirmation.confirmed?(metadata, @second,
               keep_credits: 1,
               require_bank?: false
             )

      unreported = proof_binding(%{bank_count: nil})

      metadata =
        %{}
        |> AutomaticConfirmation.observe(
          observation(@first, binding: unreported, available_count: nil)
        )
        |> AutomaticConfirmation.observe(
          observation(@second, binding: unreported, available_count: nil)
        )

      assert AutomaticConfirmation.state(metadata) == "confirmed"
      refute AutomaticConfirmation.confirmed?(metadata, @second)
      assert AutomaticConfirmation.confirmed?(metadata, @second, require_bank?: false)
    end

    test "a changed bank count restarts the proof" do
      candidate = AutomaticConfirmation.observe(%{}, observation(@first))

      restarted =
        AutomaticConfirmation.observe(
          candidate,
          observation(@second, binding: proof_binding(%{bank_count: 2}), available_count: 2)
        )

      assert AutomaticConfirmation.state(restarted) == "candidate"
    end

    test "a malformed marker is never confirmed" do
      key = AutomaticConfirmation.metadata_key()
      confirmed = confirmed_metadata()
      marker = confirmed[key]

      for broken <- [
            "string",
            %{},
            Map.put(marker, "version", 2),
            Map.put(marker, "observation_count", 1),
            Map.put(marker, "state", "candidate"),
            Map.delete(marker, "latest"),
            put_in(marker, ["latest", "binding", "trigger"], "threshold"),
            put_in(marker, ["binding", "credential_epoch"], 9)
          ] do
        refute AutomaticConfirmation.confirmed?(%{key => broken}, @second),
               "expected malformed rejection for #{inspect(broken)}"
      end
    end
  end

  describe "fingerprint/1 and retain/2" do
    test "fingerprints are stable for equal markers and change with the proof" do
      first = confirmed_metadata()
      again = confirmed_metadata()
      later = AutomaticConfirmation.observe(first, observation(@third))

      assert is_binary(AutomaticConfirmation.fingerprint(first))
      assert byte_size(AutomaticConfirmation.fingerprint(first)) == 64
      assert AutomaticConfirmation.fingerprint(first) == AutomaticConfirmation.fingerprint(again)
      refute AutomaticConfirmation.fingerprint(first) == AutomaticConfirmation.fingerprint(later)
      assert AutomaticConfirmation.fingerprint(%{}) == nil
      assert AutomaticConfirmation.fingerprint(nil) == nil
    end

    test "retain carries an existing marker into rebuilt window attributes" do
      key = AutomaticConfirmation.metadata_key()
      existing = %AccountQuotaWindow{metadata: confirmed_metadata()}

      retained = AutomaticConfirmation.retain(%{metadata: %{"fresh" => true}}, existing)
      assert retained.metadata["fresh"] == true
      assert retained.metadata[key] == existing.metadata[key]

      assert AutomaticConfirmation.retain(%{metadata: %{}}, %AccountQuotaWindow{metadata: %{}}) ==
               %{metadata: %{}}

      assert AutomaticConfirmation.retain(%{metadata: %{}}, nil) == %{metadata: %{}}
    end

    test "clear removes only the marker" do
      metadata = Map.put(confirmed_metadata(), "other", 1)
      assert AutomaticConfirmation.clear(metadata) == %{"other" => 1}
      assert AutomaticConfirmation.clear(nil) == %{}
    end
  end
end
