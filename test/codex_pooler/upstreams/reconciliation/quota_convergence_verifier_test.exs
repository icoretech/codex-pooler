defmodule CodexPooler.Upstreams.Reconciliation.QuotaConvergenceVerifierTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Reconciliation.QuotaConvergenceVerifier

  test "rejects duplicate and missing selector candidates" do
    assert {:error, %{code: "ambiguous_selector", candidate_count: 2}} =
             QuotaConvergenceVerifier.run(candidate_source: [candidate(), candidate()])

    assert {:error, %{code: "no_accepted_selector"}} =
             QuotaConvergenceVerifier.run(candidate_source: [])

    assert {:error, %{code: "no_accepted_selector"}} =
             QuotaConvergenceVerifier.run(candidate_source: [%{candidate() | row_count: 0}])
  end

  test "rejects malformed observations and expectation mismatches" do
    assert {:error, %{code: "no_accepted_selector"}} =
             QuotaConvergenceVerifier.run(
               candidate_source: [%{candidate() | provider_window: %{}}]
             )

    assert {:error, %{code: "unstable_pairs"}} =
             run_with_samples("stable", [sample("10", true), sample("11", true)])

    assert {:error, %{code: "stale_expectation_mismatch"}} =
             run_with_samples("stale", [sample("10", false), sample("10", true)])

    assert {:error, %{code: "converged_expectation_mismatch"}} =
             run_with_samples("converged", [sample("10", false), sample("10", false)])
  end

  test "emits only normalized metadata and invocation-local fingerprints" do
    samples = [sample("10", true), sample("10", true)]

    assert {:ok, first} = run_with_samples("stable", samples)
    assert {:ok, second} = run_with_samples("stable", samples)
    refute first.selector_fingerprint == second.selector_fingerprint

    encoded = Jason.encode!(first)

    for forbidden <-
          ~w(account_id assignment_id descriptor_id identity_id raw_ selector_value api_key authorization bearer token cookie payload label workspace email uuid) do
      refute String.contains?(String.downcase(encoded), forbidden)
    end

    assert first.descriptor_count == 1
    assert first.persisted_row_count == 1
    assert first.scope == "model"
    assert first.family == "example"
    assert first.sample_count == 2
  end

  defp run_with_samples(mode, samples) do
    common_observed_at = hd(samples).observed_at
    common_reset_at = hd(samples).provider.reset_at

    samples =
      Enum.map(samples, fn sample ->
        sample
        |> Map.put(:observed_at, common_observed_at)
        |> Map.update!(:provider, &Map.put(&1, :reset_at, common_reset_at))
        |> Map.update!(:persisted, &Map.put(&1, :reset_at, common_reset_at))
      end)

    {:ok, agent} = Agent.start_link(fn -> samples end)

    sampler = fn _candidate ->
      Agent.get_and_update(agent, fn [sample | remaining] -> {{:ok, sample}, remaining} end)
    end

    result =
      QuotaConvergenceVerifier.run(
        mode: mode,
        samples: length(samples),
        interval_ms: 0,
        candidate_source: [candidate()],
        sampler: sampler
      )

    Agent.stop(agent)
    result
  end

  defp candidate do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = DateTime.add(timestamp, 3_600, :second)

    window = %{
      quota_scope: "model",
      quota_family: "example",
      quota_key: "example",
      window_kind: "primary",
      window_minutes: 300,
      source: "codex_usage_api",
      model: "example-model",
      upstream_model: nil,
      raw_limit_id: "example-id",
      raw_limit_name: "Example",
      raw_metered_feature: "example",
      used_percent: Decimal.new("10"),
      reset_at: reset_at,
      observed_at: timestamp
    }

    %{
      assignment: %{pool_id: "pool", id: "assignment"},
      identity: %{id: "identity"},
      selector: {"identity", {:descriptor, "example"}},
      descriptor_count: 1,
      row_count: 1,
      provider_window: window,
      persisted_row: window
    }
  end

  defp sample(percent, converged) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = timestamp |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    observation = %{
      used_percent: percent,
      reset_at: reset_at,
      freshness: "fresh",
      source_class: "provider_usage"
    }

    %{observed_at: timestamp, provider: observation, persisted: observation, converged: converged}
  end
end
