defmodule CodexPooler.Upstreams.Quota.WindowSelectorTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.AdditionalMeterIdentity
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @as_of ~U[2026-07-09 15:45:00Z]
  @qf_as_of ~U[2026-07-25 12:00:00.000000Z]
  @spark_tokens [
    "codex_spark",
    "codex_bengalfox",
    "gpt_5_3_codex_spark",
    "codex_other",
    "gpt-5.3-codex-spark"
  ]

  test "prefers measured account evidence over a later zero-capacity usage outlier" do
    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 5, :hour),
        observed_at: DateTime.add(@as_of, 60, :second)
      )

    measured =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour),
        observed_at: @as_of
      )

    assert WindowSelector.best_account_window([outlier, measured], :primary_5h, @as_of) ==
             measured
  end

  test "keeps the only reset-bearing zero-capacity account evidence visible" do
    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 5, :hour)
      )

    assert WindowSelector.best_account_window([outlier], :primary_5h, @as_of) == outlier
  end

  test "prefers usable monthly primary over usable 5h primary for routing selection" do
    primary_5h =
      account_window(
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour)
      )

    monthly =
      account_window(
        window_minutes: 43_200,
        active_limit: 4_018,
        credits: 3_817,
        used_percent: Decimal.new("5"),
        reset_at: DateTime.add(@as_of, 14, :day)
      )

    assert WindowSelector.best_account_primary_variant([primary_5h, monthly], @as_of) ==
             monthly
  end

  test "does not let an unusable monthly outlier hide a usable 5h primary" do
    primary_5h =
      account_window(
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour)
      )

    monthly_outlier =
      account_window(
        window_minutes: 43_200,
        active_limit: nil,
        credits: 3_817,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 14, :day),
        observed_at: DateTime.add(@as_of, 60, :second)
      )

    assert WindowSelector.best_account_primary_variant([monthly_outlier, primary_5h], @as_of) ==
             primary_5h
  end

  test "a fresh new-cycle window supersedes stale prior-cycle rows in the logical merge" do
    # Live incident shape: a stale rate-limit-event row at 94% from the ended
    # cycle was outranking the fresh 0% rows of the restarted cycle by pressure,
    # showing 6% remaining for a genuinely unused account.
    stale_prior_cycle =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_rate_limit_event",
        merge_precedence: 90,
        used_percent: Decimal.new("94"),
        reset_at: DateTime.add(@as_of, 2, :day),
        observed_at: DateTime.add(@as_of, -7, :hour)
      )

    fresh_new_cycle =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 7, :day),
        observed_at: DateTime.add(@as_of, -60, :second)
      )

    assert WindowSelector.logical_windows([stale_prior_cycle, fresh_new_cycle], @as_of) == [
             fresh_new_cycle
           ]
  end

  test "an all-stale exhausted group keeps its pessimistic row" do
    # No fresh new-cycle evidence: fail-closed pessimism is preserved.
    stale_exhausted =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 2, :day),
        observed_at: DateTime.add(@as_of, -4, :hour)
      )

    stale_lower =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("77"),
        reset_at: DateTime.add(@as_of, 2, :day),
        observed_at: DateTime.add(@as_of, -10, :hour)
      )

    assert WindowSelector.logical_windows([stale_exhausted, stale_lower], @as_of) == [
             stale_exhausted
           ]
  end

  test "same-cycle rows with countdown jitter are not rejected" do
    # Resets within the margin describe the same running cycle.
    fresh_zero =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 7, :day),
        observed_at: DateTime.add(@as_of, -60, :second)
      )

    jittered =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("12"),
        reset_at: DateTime.add(@as_of, 7, :day) |> DateTime.add(-120, :second),
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    # Both survive the cycle filter; the winner is chosen by the normal score
    # (pressure prefers the measured 12%).
    assert WindowSelector.logical_windows([fresh_zero, jittered], @as_of) == [jittered]
  end

  test "fresh exhausted runtime evidence outranks usable usage evidence in one logical window" do
    usage =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("96"),
        reset_at: DateTime.add(@as_of, 7, :day),
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    exhausted_headers =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 3, :day),
        observed_at: @as_of
      )

    assert WindowSelector.logical_windows([usage, exhausted_headers], @as_of) == [
             exhausted_headers
           ]
  end

  test "anchored runtime Spark evidence remains selected over newer floating usage evidence" do
    floating_usage =
      spark_window(
        source: "codex_usage_api",
        merge_precedence: 60,
        used_percent: Decimal.new("0"),
        reset_at: ~U[2026-07-28 12:10:00Z],
        observed_at: DateTime.add(@as_of, -10, :second),
        metadata: %{"reset_state" => "floating", "reset_after_seconds" => 604_800}
      )

    anchored_runtime =
      spark_window(
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("12"),
        reset_at: ~U[2026-07-26 12:06:16Z],
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    assert WindowSelector.logical_windows([floating_usage, anchored_runtime], @as_of) == [
             anchored_runtime
           ]
  end

  test "codex02 and codex03 floating Spark evidence remains selected without an anchored row" do
    for reset_at <- [~U[2026-07-28 12:10:00Z], ~U[2026-07-28 12:14:00Z]] do
      floating_usage =
        spark_window(
          used_percent: Decimal.new("0"),
          reset_at: reset_at,
          metadata: %{"reset_state" => "floating", "reset_after_seconds" => 604_800}
        )

      assert WindowSelector.logical_windows([floating_usage], @as_of) == [floating_usage]
    end
  end

  test "generic account logical selection is byte-for-byte stable in both candidate orders" do
    expected =
      account_window(
        id: "11111111-1111-4111-8111-111111111111",
        used_percent: Decimal.new("17"),
        reset_at: DateTime.add(@as_of, 3, :hour),
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    lower_pressure =
      account_window(
        id: "22222222-2222-4222-8222-222222222222",
        used_percent: Decimal.new("11"),
        reset_at: DateTime.add(@as_of, 3, :hour),
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    expected_bytes = :erlang.term_to_binary([expected])

    assert WindowSelector.logical_windows([expected, lower_pressure], @as_of)
           |> :erlang.term_to_binary() == expected_bytes

    assert WindowSelector.logical_windows([lower_pressure, expected], @as_of)
           |> :erlang.term_to_binary() == expected_bytes
  end

  test "account source variants ignore meter-shaped raw identity and keep the stable logical key" do
    expected_key = {"account", "account", "", "", "account", "primary", 300}

    usage =
      account_window(
        id: "10000000-0000-4000-8000-000000000001",
        raw_limit_id: "usage-account",
        raw_metered_feature: "usage-meter",
        used_percent: Decimal.new("11")
      )

    headers =
      account_window(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        source: "codex_response_headers",
        merge_precedence: 80,
        raw_limit_id: "header-account",
        raw_metered_feature: "header-meter",
        used_percent: Decimal.new("17")
      )

    assert WindowSelector.logical_key(usage) == expected_key
    assert WindowSelector.logical_key(headers) == expected_key
    assert WindowSelector.logical_windows([usage, headers], @as_of) == [headers]
  end

  test "same additional meter from different sources folds into one meter-aware group" do
    usage =
      additional_window(
        id: "10000000-0000-4000-8000-000000000001",
        source: "codex_usage_api",
        merge_precedence: 60,
        raw_limit_id: "usage-limit",
        raw_metered_feature: "image-generation",
        used_percent: Decimal.new("11")
      )

    headers =
      additional_window(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        source: "codex_response_headers",
        merge_precedence: 80,
        raw_limit_id: "header-limit",
        raw_metered_feature: "image-generation",
        used_percent: Decimal.new("17")
      )

    assert WindowSelector.logical_windows([usage, headers], @as_of) == [headers]
  end

  test "mixed rich and generic additional rows are deterministic in every writer order" do
    first_meter =
      additional_window(
        id: "10000000-0000-4000-8000-000000000001",
        raw_metered_feature: " image-generation ",
        used_percent: Decimal.new("11")
      )

    second_meter =
      additional_window(
        id: "20000000-0000-4000-8000-000000000002",
        raw_metered_feature: "deep-research",
        used_percent: Decimal.new("17")
      )

    generic =
      additional_window(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        raw_metered_feature: "   ",
        used_percent: Decimal.new("99")
      )

    expected = [second_meter, first_meter]
    expected_bytes = :erlang.term_to_binary(expected)

    for candidates <- permutations([generic, second_meter, first_meter]) do
      result = WindowSelector.logical_windows(candidates, @as_of)

      assert Enum.map(result, & &1.id) == Enum.map(expected, & &1.id)
      assert :erlang.term_to_binary(result) == expected_bytes

      assert candidates
             |> Enum.map(&WindowSelector.logical_key/1)
             |> Enum.uniq()
             |> length() == 1
    end
  end

  test "generic additional rows keep legacy folding when no rich meter exists" do
    lower =
      additional_window(
        id: "10000000-0000-4000-8000-000000000001",
        raw_metered_feature: nil,
        used_percent: Decimal.new("11")
      )

    higher =
      additional_window(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        raw_metered_feature: "   ",
        used_percent: Decimal.new("17")
      )

    assert WindowSelector.logical_windows([lower, higher], @as_of) == [higher]
  end

  test "blank meter text falls back to the trimmed raw limit id" do
    window =
      additional_window(
        raw_limit_id: " image-meter ",
        raw_metered_feature: "   "
      )

    assert AdditionalMeterIdentity.token(window) == "image-meter"

    assert {:metered, _legacy_key, "image-meter"} =
             AdditionalMeterIdentity.group_key(window)
  end

  test "every recognized Spark token folds from both eligible fields and target scopes in both candidate orders" do
    for token <- @spark_tokens,
        scope <- ["model", "upstream_model"],
        field <- [:quota_key, :active_dimension] do
      alias_window =
        spark_alias_window(
          scope,
          field,
          token,
          "ffffffff-ffff-4fff-bfff-ffffffffffff"
        )

      canonical_window =
        spark_alias_window(
          scope,
          :canonical,
          "codex_spark",
          "10000000-0000-4000-8000-000000000001"
        )

      for candidates <- [
            [alias_window, canonical_window],
            [canonical_window, alias_window]
          ] do
        assert [winner] = WindowSelector.logical_windows(candidates, @as_of)
        assert winner.id == alias_window.id
        assert WindowSelector.logical_key(winner) == canonical_spark_key(scope)
      end
    end
  end

  test "canonical Spark aliases with distinct raw meter tokens retain legacy folding" do
    alias_window =
      spark_alias_window(
        "model",
        :quota_key,
        "codex_bengalfox",
        "ffffffff-ffff-4fff-bfff-ffffffffffff",
        raw_metered_feature: "codex_bengalfox"
      )

    canonical_window =
      spark_alias_window(
        "model",
        :canonical,
        "codex_spark",
        "10000000-0000-4000-8000-000000000001",
        raw_metered_feature: "codex_spark"
      )

    assert [winner] = WindowSelector.logical_windows([alias_window, canonical_window], @as_of)
    assert winner.id == alias_window.id
    assert WindowSelector.logical_key(winner) == canonical_spark_key("model")
  end

  test "legacy weekly primary Spark rows fold into the secondary canonical identity" do
    for scope <- ["model", "upstream_model"] do
      legacy =
        spark_alias_window(
          scope,
          :quota_key,
          "codex_bengalfox",
          "ffffffff-ffff-4fff-bfff-ffffffffffff",
          window_kind: "primary"
        )

      canonical =
        spark_alias_window(
          scope,
          :canonical,
          "codex_spark",
          "10000000-0000-4000-8000-000000000001"
        )

      assert [winner] = WindowSelector.logical_windows([legacy, canonical], @as_of)
      assert winner.id == legacy.id
      assert winner.window_kind == "secondary"
      assert WindowSelector.logical_key(winner) == canonical_spark_key(scope)
    end
  end

  test "feature and account codex_other rows remain distinct from model Spark evidence" do
    model_spark = spark_window(id: "10000000-0000-4000-8000-000000000001")

    for scope <- ["feature", "account"] do
      non_target =
        account_window(
          id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
          quota_key: "codex_other",
          quota_scope: scope,
          quota_family: scope,
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("0"),
          reset_at: DateTime.add(@as_of, 7, :day)
        )

      result = WindowSelector.logical_windows([model_spark, non_target], @as_of)

      assert Enum.map(result, & &1.id) |> Enum.sort() ==
               Enum.sort([model_spark.id, non_target.id])
    end
  end

  test "unrelated weekly target identifiers remain separate logical windows" do
    first =
      spark_window(
        id: "10000000-0000-4000-8000-000000000001",
        quota_key: "codex_otherwise",
        model: "gpt-5.3-codex-spark-preview"
      )

    second =
      spark_window(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        quota_key: "another-model",
        model: "another-model"
      )

    assert WindowSelector.logical_windows([first, second], @as_of)
           |> Enum.map(& &1.id)
           |> Enum.sort() == Enum.sort([first.id, second.id])
  end

  test "recognized Spark tokens in inactive target-scope dimensions remain separate from canonical Spark" do
    for token <- @spark_tokens,
        scope <- ["model", "upstream_model"] do
      inactive_alias =
        spark_alias_window(
          scope,
          :inactive_dimension,
          token,
          "ffffffff-ffff-4fff-bfff-ffffffffffff"
        )

      canonical =
        spark_alias_window(
          scope,
          :canonical,
          "codex_spark",
          "10000000-0000-4000-8000-000000000001"
        )

      expected_inactive_key =
        case scope do
          "model" ->
            {"model", "unrelated-family", "unrelated-model", nil, "unrelated-quota", "secondary",
             10_080}

          "upstream_model" ->
            {"upstream_model", "unrelated-family", nil, "unrelated-upstream-model",
             "unrelated-quota", "secondary", 10_080}
        end

      assert WindowSelector.logical_key(inactive_alias) == expected_inactive_key
      refute WindowSelector.logical_key(inactive_alias) == canonical_spark_key(scope)

      for candidates <- [[inactive_alias, canonical], [canonical, inactive_alias]] do
        assert WindowSelector.logical_windows(candidates, @as_of)
               |> Enum.map(& &1.id)
               |> Enum.sort() == Enum.sort([inactive_alias.id, canonical.id])
      end
    end
  end

  test "QF-001 explicit floating evidence wins both permutations by semantic rank and persisted id" do
    explicit_floating = qf001_explicit_floating()
    markerless_headers = qf001_markerless_headers()

    assert explicit_floating.id == "10000000-0000-4000-8000-000000000001"
    assert markerless_headers.id == "ffffffff-ffff-4fff-bfff-ffffffffffff"
    assert explicit_floating.used_percent == markerless_headers.used_percent
    assert explicit_floating.active_limit == markerless_headers.active_limit
    assert explicit_floating.credits == markerless_headers.credits
    assert explicit_floating.freshness_state == markerless_headers.freshness_state
    assert explicit_floating.source_precision == markerless_headers.source_precision
    assert match?(%DateTime{}, explicit_floating.reset_at)
    assert match?(%DateTime{}, markerless_headers.reset_at)
    assert markerless_headers.merge_precedence > explicit_floating.merge_precedence
    assert DateTime.after?(markerless_headers.observed_at, explicit_floating.observed_at)
    assert DateTime.after?(markerless_headers.last_sync_at, explicit_floating.last_sync_at)
    assert DateTime.after?(markerless_headers.updated_at, explicit_floating.updated_at)
    assert DateTime.after?(markerless_headers.reset_at, explicit_floating.reset_at)
    assert markerless_headers.id > explicit_floating.id

    for candidates <- [
          [explicit_floating, markerless_headers],
          [markerless_headers, explicit_floating]
        ] do
      assert [winner] = WindowSelector.logical_windows(candidates, @qf_as_of)
      assert winner.id == explicit_floating.id
      assert winner == explicit_floating
    end
  end

  test "QF-001 excludes a separate observation one microsecond after as_of" do
    explicit_floating = qf001_explicit_floating()

    future =
      qf001_markerless_headers(
        id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        used_percent: Decimal.new("100"),
        metadata: %{"reset_state" => "anchored"},
        observed_at: DateTime.add(@qf_as_of, 1, :microsecond),
        last_sync_at: DateTime.add(@qf_as_of, 1, :microsecond),
        created_at: DateTime.add(@qf_as_of, 1, :microsecond),
        updated_at: DateTime.add(@qf_as_of, 1, :microsecond)
      )

    assert WindowSelector.logical_windows([future, explicit_floating], @qf_as_of) == [
             explicit_floating
           ]
  end

  test "semantic rank stays behind pressure for positive and exhausted Spark evidence" do
    floating = qf001_explicit_floating()

    for used_percent <- [Decimal.new("12"), Decimal.new("100")] do
      pressure =
        qf001_markerless_headers(
          id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
          used_percent: used_percent
        )

      assert WindowSelector.logical_windows([floating, pressure], @qf_as_of) == [pressure]
    end
  end

  test "fresh evidence still beats stale pressure while all-stale pressure remains pessimistic" do
    fresh_zero =
      qf001_explicit_floating(
        id: "10000000-0000-4000-8000-000000000001",
        observed_at: DateTime.add(@qf_as_of, -60, :second),
        last_sync_at: DateTime.add(@qf_as_of, -60, :second)
      )

    stale_exhausted =
      qf001_markerless_headers(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        used_percent: Decimal.new("100"),
        observed_at: DateTime.add(@qf_as_of, -4, :hour),
        last_sync_at: DateTime.add(@qf_as_of, -4, :hour)
      )

    stale_lower =
      qf001_explicit_floating(
        id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        observed_at: DateTime.add(@qf_as_of, -5, :hour),
        last_sync_at: DateTime.add(@qf_as_of, -5, :hour)
      )

    assert WindowSelector.logical_windows([stale_exhausted, fresh_zero], @qf_as_of) == [
             fresh_zero
           ]

    assert WindowSelector.logical_windows([stale_lower, stale_exhausted], @qf_as_of) == [
             stale_exhausted
           ]
  end

  test "valid nonweekly model rows receive neutral semantics and retain existing tie-breaking" do
    earlier =
      spark_window(
        id: "10000000-0000-4000-8000-000000000001",
        window_minutes: 300,
        merge_precedence: 60,
        observed_at: DateTime.add(@as_of, -30, :second),
        metadata: %{"reset_state" => "anchored"}
      )

    later =
      spark_window(
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        window_minutes: 300,
        merge_precedence: 80,
        observed_at: @as_of,
        metadata: %{}
      )

    assert WindowSelector.logical_windows([earlier, later], @as_of) == [later]
  end

  defp account_window(attrs) do
    observed_at = Keyword.get(attrs, :observed_at, @as_of)

    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "primary",
          window_minutes: 300,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          observed_at: observed_at,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end

  defp spark_window(attrs) do
    observed_at = Keyword.get(attrs, :observed_at, @as_of)

    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "codex_spark",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          window_kind: "secondary",
          window_minutes: 10_080,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          observed_at: observed_at,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end

  defp additional_window(attrs) do
    account_window(
      Keyword.merge(
        [
          quota_key: "synthetic-additional",
          quota_scope: "feature",
          quota_family: "synthetic-additional",
          window_kind: "secondary",
          window_minutes: 10_080,
          reset_at: DateTime.add(@as_of, 7, :day)
        ],
        attrs
      )
    )
  end

  defp permutations([]), do: [[]]

  defp permutations(items) do
    for item <- items,
        rest <- permutations(List.delete(items, item)),
        do: [item | rest]
  end

  defp spark_alias_window(scope, field, token, id, attrs \\ []) do
    {model, upstream_model, quota_key} =
      case {scope, field} do
        {"model", :quota_key} ->
          {"unrelated-model", nil, token}

        {"model", :active_dimension} ->
          {token, nil, "unrelated-quota"}

        {"model", :inactive_dimension} ->
          {"unrelated-model", token, "unrelated-quota"}

        {"model", :canonical} ->
          {"gpt-5.3-codex-spark", nil, "codex_spark"}

        {"upstream_model", :quota_key} ->
          {nil, "unrelated-upstream-model", token}

        {"upstream_model", :active_dimension} ->
          {nil, token, "unrelated-quota"}

        {"upstream_model", :inactive_dimension} ->
          {token, "unrelated-upstream-model", "unrelated-quota"}

        {"upstream_model", :canonical} ->
          {nil, "gpt-5.3-codex-spark", "codex_spark"}
      end

    spark_window(
      Keyword.merge(
        [
          id: id,
          quota_scope: scope,
          quota_family: "unrelated-family",
          quota_key: quota_key,
          model: model,
          upstream_model: upstream_model,
          used_percent: Decimal.new("0"),
          reset_at: DateTime.add(@as_of, 7, :day),
          observed_at: @as_of
        ],
        attrs
      )
    )
  end

  defp canonical_spark_key("model") do
    {"model", "codex_model", "gpt-5.3-codex-spark", nil, "codex_spark", "secondary", 10_080}
  end

  defp canonical_spark_key("upstream_model") do
    {"upstream_model", "codex_model", nil, "gpt-5.3-codex-spark", "codex_spark", "secondary",
     10_080}
  end

  defp qf001_explicit_floating(attrs \\ []) do
    qf001_window(
      Keyword.merge(
        [
          id: "10000000-0000-4000-8000-000000000001",
          reset_at: ~U[2026-08-01 12:00:00.000000Z],
          source: "codex_usage_api",
          raw_limit_id: "qf001-usage",
          last_sync_at: ~U[2026-07-25 11:59:00.000000Z],
          observed_at: ~U[2026-07-25 11:59:00.000000Z],
          merge_precedence: 60,
          metadata: %{"reset_state" => "floating"},
          created_at: ~U[2026-07-25 11:59:00.000000Z],
          updated_at: ~U[2026-07-25 11:59:00.000000Z]
        ],
        attrs
      )
    )
  end

  defp qf001_markerless_headers(attrs \\ []) do
    qf001_window(
      Keyword.merge(
        [
          id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
          reset_at: ~U[2026-08-01 12:30:00.000000Z],
          source: "codex_response_headers",
          raw_limit_id: "qf001-header",
          last_sync_at: ~U[2026-07-25 11:59:30.000000Z],
          observed_at: ~U[2026-07-25 11:59:30.000000Z],
          merge_precedence: 80,
          metadata: %{},
          created_at: ~U[2026-07-25 11:59:30.000000Z],
          updated_at: ~U[2026-07-25 11:59:30.000000Z]
        ],
        attrs
      )
    )
  end

  defp qf001_window(attrs) do
    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          upstream_identity_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          quota_key: "codex_spark",
          window_kind: "secondary",
          window_minutes: 10_080,
          active_limit: nil,
          credits: nil,
          used_percent: Decimal.new("0"),
          display_label: "GPT-5.3-Codex-Spark",
          limit_name: "gpt-5.3-codex-spark",
          metered_feature: "codex_spark",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          upstream_model: nil,
          raw_limit_name: "gpt-5.3-codex-spark",
          raw_metered_feature: "codex_spark",
          freshness_state: "fresh"
        ],
        attrs
      )
    )
  end
end
