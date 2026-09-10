defmodule CodexPooler.Upstreams.Quota.Windows.UsageCoherenceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.UsageCoherence

  @as_of ~U[2026-09-10 15:00:00.000000Z]
  @reset_at ~U[2026-09-10 15:15:00Z]
  @key "__quota_usage_coherence_v1"

  describe "observe/3" do
    test "counts adopted coherent readings of one cycle and restarts on a new cycle" do
      first = evidence(observed_at: DateTime.add(@as_of, -120, :second))
      attrs = UsageCoherence.observe(adopted_attrs(first), first, @as_of)
      assert %{"count" => 1, "allowed" => true, "limit_reached" => false} = attrs.metadata[@key]

      second = evidence(observed_at: DateTime.add(@as_of, -60, :second))
      attrs = UsageCoherence.observe(adopted_attrs(second, attrs.metadata), second, @as_of)
      assert %{"count" => 2} = marker = attrs.metadata[@key]
      assert marker["first_observed_at"] == DateTime.to_iso8601(first.observed_at)
      assert marker["last_observed_at"] == DateTime.to_iso8601(second.observed_at)

      next_cycle =
        evidence(observed_at: @as_of, reset_at: DateTime.add(@reset_at, 5, :hour))

      attrs =
        UsageCoherence.observe(adopted_attrs(next_cycle, attrs.metadata), next_cycle, @as_of)

      assert %{"count" => 1} = attrs.metadata[@key]
    end

    test "ignores readings the merge did not adopt and clears on exhausted or denied readings" do
      first = evidence(observed_at: DateTime.add(@as_of, -120, :second))
      attrs = UsageCoherence.observe(adopted_attrs(first), first, @as_of)

      rejected = evidence(observed_at: DateTime.add(@as_of, -60, :second))
      kept = %{attrs | observed_at: first.observed_at}
      assert UsageCoherence.observe(kept, rejected, @as_of).metadata[@key]["count"] == 1

      exhausted = evidence(observed_at: @as_of, used_percent: "100")

      refute Map.has_key?(
               UsageCoherence.observe(adopted_attrs(exhausted, attrs.metadata), exhausted, @as_of).metadata,
               @key
             )

      denied =
        evidence(
          observed_at: @as_of,
          metadata: %{"rate_limit_allowed" => false, "rate_limit_reached" => true}
        )

      refute Map.has_key?(
               UsageCoherence.observe(adopted_attrs(denied, attrs.metadata), denied, @as_of).metadata,
               @key
             )
    end

    test "leaves other evidence surfaces untouched" do
      headers = evidence(source: "codex_response_headers", observed_at: @as_of)
      attrs = adopted_attrs(headers)
      assert UsageCoherence.observe(attrs, headers, @as_of) == attrs
    end
  end

  describe "confirmed?/2 and overrides?/3" do
    test "two coherent readings confirm a fresh usable usage window" do
      usage = usage_window(count: 2)
      assert UsageCoherence.confirmed?(usage, @as_of)
      refute UsageCoherence.confirmed?(usage_window(count: 1), @as_of)
      refute UsageCoherence.confirmed?(%{usage | used_percent: Decimal.new("100")}, @as_of)
      refute UsageCoherence.confirmed?(%{usage | source: "codex_response_headers"}, @as_of)
      refute UsageCoherence.confirmed?(usage, DateTime.add(@as_of, 16, :minute))
    end

    test "a confirmed usage window overrides only an older fresh exhausted row of the same cycle" do
      usage = usage_window(count: 2, observed_at: DateTime.add(@as_of, -30, :second))

      exhausted =
        header_window(used_percent: "100", observed_at: DateTime.add(@as_of, -90, :second))

      assert UsageCoherence.overrides?(usage, exhausted, @as_of)

      refute UsageCoherence.overrides?(
               usage,
               %{exhausted | used_percent: Decimal.new("96")},
               @as_of
             )

      refute UsageCoherence.overrides?(usage, %{exhausted | observed_at: @as_of}, @as_of)

      refute UsageCoherence.overrides?(
               usage,
               %{exhausted | reset_at: DateTime.add(@reset_at, 1, :hour)},
               @as_of
             )

      refute UsageCoherence.overrides?(usage_window(count: 1), exhausted, @as_of)
      refute UsageCoherence.overrides?(usage, %{exhausted | source: "codex_usage_api"}, @as_of)
    end
  end

  defp evidence(opts) do
    observed_at = Keyword.fetch!(opts, :observed_at)

    {:ok, evidence} =
      Evidence.new(
        %{
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "primary",
          window_minutes: 300,
          used_percent: Decimal.new(Keyword.get(opts, :used_percent, "20")),
          reset_at: Keyword.get(opts, :reset_at, @reset_at),
          observed_at: observed_at,
          last_sync_at: observed_at,
          source: Keyword.get(opts, :source, "codex_usage_api"),
          source_precision: "observed",
          freshness_state: "fresh",
          metadata:
            Keyword.get(opts, :metadata, %{
              "rate_limit_allowed" => true,
              "rate_limit_reached" => false
            })
        },
        observed_at
      )

    evidence
  end

  defp adopted_attrs(evidence, metadata \\ nil) do
    evidence
    |> Evidence.to_window_attrs()
    |> Map.put(:metadata, metadata || evidence.metadata)
  end

  defp usage_window(opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.add(@as_of, -30, :second))
    count = Keyword.fetch!(opts, :count)

    window(
      source: "codex_usage_api",
      used_percent: "20",
      observed_at: observed_at,
      metadata: %{
        @key => %{
          "version" => 1,
          "count" => count,
          "used_percent" => "20",
          "reset_at" => DateTime.to_iso8601(@reset_at),
          "first_observed_at" => DateTime.to_iso8601(DateTime.add(observed_at, -60, :second)),
          "last_observed_at" => DateTime.to_iso8601(observed_at),
          "allowed" => true,
          "limit_reached" => false
        }
      }
    )
  end

  defp header_window(opts), do: window(Keyword.put(opts, :source, "codex_response_headers"))

  defp window(opts) do
    observed_at = Keyword.fetch!(opts, :observed_at)

    struct!(AccountQuotaWindow,
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "primary",
      window_minutes: 300,
      source: Keyword.fetch!(opts, :source),
      source_precision: "observed",
      freshness_state: "fresh",
      used_percent: Decimal.new(Keyword.fetch!(opts, :used_percent)),
      reset_at: Keyword.get(opts, :reset_at, @reset_at),
      observed_at: observed_at,
      last_sync_at: observed_at,
      updated_at: observed_at,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end
end
