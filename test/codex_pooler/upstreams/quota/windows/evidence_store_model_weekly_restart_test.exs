defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreModelWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @window_seconds 10_080 * 60

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp model_weekly(observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))
    metadata = Keyword.get(opts, :metadata, %{"reset_after_seconds" => @window_seconds})

    %{
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      freshness_state: "fresh",
      metadata: metadata
    }
  end

  defp model_weekly_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "codex_spark" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  defp alias_model_weekly(observed_at, used_percent, opts \\ []) do
    observed_at
    |> model_weekly(used_percent, opts)
    |> Map.merge(%{
      raw_limit_id: "provider-spark-weekly",
      raw_limit_name: "GPT-5.3-Codex-Spark",
      raw_metered_feature: "provider-spark-weekly"
    })
  end

  defp historical_alias_row!(identity, observed_at, used_percent, opts) do
    attrs =
      observed_at
      |> alias_model_weekly(used_percent, opts)
      |> Map.merge(%{
        upstream_identity_id: identity.id,
        quota_key: "gpt_5_3_codex_spark",
        created_at: observed_at,
        updated_at: observed_at
      })

    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(attrs)
    |> Repo.insert!()
  end

  defp spark_weekly_payload(used_percent, reset_at) do
    %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => @window_seconds,
              "reset_after_seconds" => @window_seconds,
              "reset_at" => DateTime.to_iso8601(reset_at)
            }
          }
        }
      ]
    }
  end

  defp record_spark_payload!(identity, payload, observed_at) do
    assert {:ok, windows} = Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    assert [spark_weekly] =
             Enum.filter(
               windows,
               &(&1.quota_key == "codex_spark" and &1.window_kind == "secondary")
             )

    assert spark_weekly.quota_scope == "model"
    assert spark_weekly.metadata["reset_after_seconds"] == @window_seconds

    assert {:ok, row} =
             EvidenceStore.record_evidence(identity, spark_weekly, observed_at, observed_at)

    row
  end

  defp accepted_floating_model!(identity, t0) do
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t0, "0"), t0)

    candidate_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, model_weekly(candidate_at, "0"), candidate_at)

    accepted_at = DateTime.add(candidate_at, 4, :minute)

    assert {:ok, _row} =
             Windows.record_evidence(identity, model_weekly(accepted_at, "0"), accepted_at)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    row
  end

  test "sliding model weekly zeros become explicitly floating after confirmation" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    stale_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "0", reset_at: stale_reset, metadata: %{}),
               t0,
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)

    row = model_weekly_row(identity)
    assert DateTime.compare(row.reset_at, stale_reset) == :eq
    refute row.metadata["reset_state"] == "floating"

    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
    assert DateTime.compare(row.reset_at, DateTime.add(t2, @window_seconds, :second)) == :eq
    assert DateTime.compare(row.observed_at, t2) == :eq
  end

  test "confirmed floating model weekly zero clears prior-cycle usage" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    stale_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: stale_reset, metadata: %{}),
               t0,
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
  end

  test "a model restart candidate older than newer positive usage cannot clear it" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             Windows.record_evidence(identity, model_weekly(t0, "64"), t0)

    candidate_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(candidate_at, "0"),
               candidate_at
             )

    newer_positive_at = DateTime.add(t0, 120, :second)

    resetless_positive =
      newer_positive_at
      |> model_weekly("80")
      |> Map.put(:reset_at, nil)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               resetless_positive,
               newer_positive_at,
               newer_positive_at
             )

    positive_row = model_weekly_row(identity)
    refute Map.has_key?(positive_row.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(positive_row.metadata, "__quota_relative_candidate_liveness_v1")

    confirmation_at = DateTime.add(candidate_at, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(confirmation_at, "0"),
               confirmation_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("80"))
    assert DateTime.compare(row.observed_at, newer_positive_at) == :eq
  end

  test "a first model positive without provider timing blocks provider-older restart candidates" do
    positive_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    identity = identity!()

    positive = model_weekly(positive_at, "70", metadata: %{})

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, positive, positive_at, positive_at)

    for {provider_delta, observed_delta} <- [{-300, 60}, {-60, 300}] do
      provider_at = DateTime.add(positive_at, provider_delta, :second)
      observed_at = DateTime.add(positive_at, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(positive_at)
  end

  test "a markerless legacy model positive blocks provider-older restart candidates" do
    positive_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    identity = identity!()

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(positive_at, "64"),
               positive_at,
               positive_at
             )

    legacy_row = model_weekly_row(identity)

    legacy_row
    |> Ecto.Changeset.change(metadata: %{})
    |> Repo.update!()

    for {provider_delta, observed_delta} <- [{-300, 60}, {-60, 300}] do
      provider_at = DateTime.add(positive_at, provider_delta, :second)
      observed_at = DateTime.add(positive_at, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")
  end

  test "a first model weekly row with present invalid relative timing is rejected" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for reset_after_seconds <- [
          "invalid",
          @window_seconds + 20 * 60,
          @window_seconds - 10 * 60
        ] do
      identity = identity!()

      attrs =
        model_weekly(observed_at, "64", metadata: %{"reset_after_seconds" => reset_after_seconds})

      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)

      assert model_weekly_row(identity) == nil
    end
  end

  test "an accepted cached model positive cannot rewind the provider watermark" do
    base = DateTime.utc_now() |> DateTime.add(-14, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_provider_at = DateTime.add(base, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(canonical_provider_at, "64"),
               canonical_provider_at,
               canonical_provider_at
             )

    cached_positive_at = DateTime.add(base, 7, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(cached_positive_at, "80",
                 reset_at: DateTime.add(base, @window_seconds, :second)
               ),
               cached_positive_at,
               cached_positive_at
             )

    assert model_weekly_row(identity).metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)

    for {provider_delta, observed_delta} <- [{60, 8 * 60}, {5 * 60, 12 * 60}] do
      provider_at = DateTime.add(base, provider_delta, :second)
      observed_at = DateTime.add(base, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("80"))
    assert DateTime.compare(row.observed_at, cached_positive_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)
  end

  test "a cached model positive cannot rewind a legacy reset-derived provider watermark" do
    base = DateTime.utc_now() |> DateTime.add(-14, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    legacy_provider_at = DateTime.add(base, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(legacy_provider_at, "64"),
               legacy_provider_at,
               legacy_provider_at
             )

    legacy_row = model_weekly_row(identity)

    legacy_row
    |> Ecto.Changeset.change(
      metadata: Map.delete(legacy_row.metadata, "__quota_relative_liveness_v1")
    )
    |> Repo.update!()

    cached_positive_at = DateTime.add(base, 7, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(cached_positive_at, "80",
                 reset_at: DateTime.add(base, @window_seconds, :second)
               ),
               cached_positive_at,
               cached_positive_at
             )

    assert model_weekly_row(identity).metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(legacy_provider_at)

    for {provider_delta, observed_delta} <- [{60, 8 * 60}, {5 * 60, 12 * 60}] do
      provider_at = DateTime.add(base, provider_delta, :second)
      observed_at = DateTime.add(base, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("80"))
    assert DateTime.compare(row.observed_at, cached_positive_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(legacy_provider_at)
  end

  test "two future sliding snapshots cannot confirm a model weekly restart" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t0, "64"), t0)

    first_replay_at = DateTime.add(t0, 60, :second)
    first_provider_at = DateTime.add(first_replay_at, 10, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_replay_at, "0", reset_at: first_reset),
               first_replay_at,
               first_replay_at
             )

    second_replay_at = DateTime.add(first_replay_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_replay_at, "0", reset_at: second_reset),
               second_replay_at,
               second_replay_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "cached model weekly zero never becomes floating or clears prior usage" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: fixed_reset, metadata: %{}),
               t0,
               t0
             )

    for offset <- [300, 540] do
      observed_at = DateTime.add(t0, offset, :second)

      assert {:ok, _row} =
               Windows.record_evidence(
                 identity,
                 model_weekly(observed_at, "0", reset_at: fixed_reset),
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    refute row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, fixed_reset) == :eq
  end

  test "positive model usage anchors a previously floating weekly window" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t0, "0"), t0)

    t1 = DateTime.add(t0, 60, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)
    assert model_weekly_row(identity).metadata["reset_state"] == "floating"

    anchored_reset = DateTime.add(t2, @window_seconds, :second)
    t3 = DateTime.add(t2, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t3, "2", reset_at: anchored_reset),
               t3
             )

    row = model_weekly_row(identity)
    refute Map.has_key?(row.metadata, "reset_state")
    assert Decimal.equal?(row.used_percent, Decimal.new("2"))
    assert DateTime.compare(row.reset_at, anchored_reset) == :eq
  end

  test "a fixed replay cannot keep an accepted floating model weekly zero fresh" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    accepted_at = accepted.observed_at
    fixed_reset = accepted.reset_at

    for minute <- 1..16 do
      replayed_at = DateTime.add(accepted_at, minute, :minute)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(replayed_at, "0", reset_at: fixed_reset),
                 replayed_at,
                 replayed_at
               )
    end

    row = model_weekly_row(identity)
    assert DateTime.compare(row.observed_at, accepted_at) == :eq

    assert Evidence.current_freshness_state(row, DateTime.add(accepted_at, 16, :minute)) ==
             "stale"
  end

  test "older advancing provider times cannot rewind an accepted floating model row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    accepted_at = accepted.observed_at

    first_replay_at = DateTime.add(accepted_at, 1, :minute)
    first_provider_at = DateTime.add(accepted_at, -9, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_replay_at, "0", reset_at: first_reset),
               first_replay_at,
               first_replay_at
             )

    second_replay_at = DateTime.add(first_replay_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_replay_at, "0", reset_at: second_reset),
               second_replay_at,
               second_replay_at
             )

    row = model_weekly_row(identity)
    assert DateTime.compare(row.observed_at, accepted_at) == :eq
    assert DateTime.compare(row.reset_at, accepted.reset_at) == :eq
  end

  test "advancing model candidates older than canonical provider time cannot rewind it" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset),
               t0
             )

    first_observed_at = DateTime.add(t0, 60, :second)
    first_provider_at = DateTime.add(t0, -5, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_observed_at, "0", reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_observed_at, "0", reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert row.metadata["reset_after_seconds"] == @window_seconds
    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
  end

  test "positive model refresh advances the canonical provider watermark" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset),
               t0
             )

    canonical_provider_at = DateTime.add(t0, 6, :minute)
    canonical_remaining = DateTime.diff(canonical_reset, canonical_provider_at, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(canonical_provider_at, "70",
                 reset_at: canonical_reset,
                 metadata: %{"reset_after_seconds" => canonical_remaining}
               ),
               canonical_provider_at,
               canonical_provider_at
             )

    first_observed_at = DateTime.add(canonical_provider_at, 60, :second)
    first_provider_at = DateTime.add(t0, 2, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_observed_at, "0", reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 3, :minute)
    second_provider_at = DateTime.add(first_provider_at, 3, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_observed_at, "0", reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, canonical_provider_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)

    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
  end

  test "positive model evidence without usable timing installs a conservative barrier" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset),
               t0
             )

    positive_at = DateTime.add(t0, 6, :minute)

    positive_without_timing =
      positive_at
      |> model_weekly("70", reset_at: canonical_reset)
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               positive_without_timing,
               positive_at,
               positive_at
             )

    accepted = model_weekly_row(identity)
    assert Decimal.equal?(accepted.used_percent, Decimal.new("70"))
    assert DateTime.compare(accepted.observed_at, positive_at) == :eq

    assert accepted.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(positive_at)

    first_observed_at = DateTime.add(positive_at, 60, :second)
    first_provider_at = DateTime.add(t0, 2, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_observed_at, "0", reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 3, :minute)
    second_provider_at = DateTime.add(first_provider_at, 3, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_observed_at, "0", reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(positive_at)
  end

  test "missing timing cannot replace an expired historical model alias" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    observed_at = DateTime.add(t0, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(observed_at, "0", metadata: %{}),
               observed_at,
               observed_at
             )

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "malformed timing cannot replace an expired historical model alias" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    observed_at = DateTime.add(t0, 10, :minute)

    malformed =
      observed_at
      |> alias_model_weekly("0")
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, malformed, observed_at, observed_at)

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "one valid relative zero cannot replace an expired historical model alias" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    observed_at = DateTime.add(t0, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(observed_at, "0"),
               observed_at,
               observed_at
             )

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(row.metadata)
  end

  test "accepted runtime pressure clears a historical alias restart candidate" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    candidate_at = DateTime.add(t0, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(candidate_at, "0"),
               candidate_at,
               candidate_at
             )

    candidate = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(candidate.metadata)
    assert Map.has_key?(candidate.metadata, "__quota_relative_candidate_liveness_v1")

    runtime_at = DateTime.add(candidate_at, 60, :second)

    runtime_pressure =
      runtime_at
      |> model_weekly("91")
      |> Map.merge(%{
        source: "codex_rate_limit_event",
        raw_limit_id: nil,
        raw_limit_name: nil,
        raw_metered_feature: nil
      })

    assert {:ok, runtime_row} =
             EvidenceStore.record_evidence(identity, runtime_pressure, runtime_at, runtime_at)

    assert runtime_row.source == "codex_rate_limit_event"

    cleared = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert :none = EvidenceStore.parse_candidate(cleared.metadata)
    refute Map.has_key?(cleared.metadata, "__quota_relative_candidate_liveness_v1")

    next_observed_at = DateTime.add(candidate_at, 4, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(next_observed_at, "0"),
               next_observed_at,
               next_observed_at
             )

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert {:ok, restarted_candidate} = EvidenceStore.parse_candidate(row.metadata)
    assert DateTime.compare(restarted_candidate.observed_at, next_observed_at) == :eq
  end

  test "model weekly zero without provider timing cannot clear a non-relative row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset, metadata: %{}),
               t0
             )

    observed_at = DateTime.add(t0, 5, :minute)
    unproven_reset = DateTime.add(observed_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(observed_at, "0", reset_at: unproven_reset, metadata: %{}),
               observed_at,
               observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "malformed model timing cannot replace an expired non-relative row" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: expired_reset, metadata: %{}),
               t0
             )

    observed_at = DateTime.add(t0, 10, :minute)

    malformed =
      observed_at
      |> model_weekly("0")
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, malformed, observed_at, observed_at)

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "malformed timing metadata cannot explicitly correct an accepted floating model row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    replayed_at = DateTime.add(accepted.observed_at, 60, :second)

    malformed =
      replayed_at
      |> model_weekly("0", reset_at: accepted.reset_at)
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, malformed, replayed_at, replayed_at)

    row = model_weekly_row(identity)
    assert DateTime.compare(row.observed_at, accepted.observed_at) == :eq
    assert DateTime.compare(row.reset_at, accepted.reset_at) == :eq
    assert row.metadata["reset_state"] == "floating"
  end

  test "parsed Spark payload requires a moving absolute reset before marking it floating" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, @window_seconds, :second)

    record_spark_payload!(identity, spark_weekly_payload(64, fixed_reset), t0)

    cached_zero = spark_weekly_payload(0, fixed_reset)

    for offset <- [300, 540] do
      observed_at = DateTime.add(t0, offset, :second)
      record_spark_payload!(identity, cached_zero, observed_at)
    end

    cached_row = model_weekly_row(identity)
    refute cached_row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(cached_row.used_percent, Decimal.new("64"))
    assert DateTime.compare(cached_row.reset_at, fixed_reset) == :eq

    t3 = DateTime.add(t0, 600, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, DateTime.add(t3, @window_seconds)),
      t3
    )

    t4 = DateTime.add(t3, 240, :second)
    moving_reset = DateTime.add(t4, @window_seconds)
    record_spark_payload!(identity, spark_weekly_payload(0, moving_reset), t4)

    live_row = model_weekly_row(identity)
    assert live_row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(live_row.used_percent, Decimal.new("0"))
    assert DateTime.compare(live_row.reset_at, moving_reset) == :eq
  end
end
