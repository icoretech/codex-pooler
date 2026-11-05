defmodule CodexPooler.Catalog.OpenAIPricingPreflightTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.ContextPricing
  alias CodexPooler.Catalog.OpenAIPricingFormat
  alias CodexPooler.Catalog.OpenAIPricingPreflight

  @fixture Path.expand("../../fixtures/pricing/openai/2026-07-28.json", __DIR__)
  @target Path.expand("../../../priv/pricing/openai/pricing.json", __DIR__)

  test "expanded tool rates reject malformed or inconsistent billing metadata" do
    payload = @target |> File.read!() |> CodexPooler.JSON.decode!()
    tool = payload["tools"]["file-search"]
    assert length(tool["rates"]) == 2
    assert OpenAIPricingPreflight.validate_payload(payload).compatible?

    for changed <- [
          Map.put(tool, "amounts", []),
          Map.put(tool, "amounts", [-1]),
          Map.put(tool, "price", 999),
          Map.put(tool, "price_semantics", "unknown"),
          Map.put(tool, "rates", []),
          Map.put(tool, "rates", [nil]),
          put_in(tool, ["rates"], [Map.put(hd(tool["rates"]), "unknown", 1)]),
          Map.put(tool, "rates", [hd(tool["rates"]), %{"amounts" => ["2"]}])
        ] do
      result =
        OpenAIPricingPreflight.validate_payload(put_in(payload, ["tools", "file-search"], changed))

      refute result.compatible?
      assert Enum.any?(result.errors, &(&1.code == :invalid_tool_rates))
    end
  end

  test "character pricing is validated and excluded from token accounting" do
    payload = @target |> File.read!() |> CodexPooler.JSON.decode!()

    for model <- ~w(tts-1 tts-1-hd) do
      assert payload["models"][model]["pricing_type"] == "per_1m_characters"
      result = OpenAIPricingFormat.classify(payload)
      refute Enum.any?(result.rows, &(&1.model_identifier == model))
      invalid = put_in(payload, ["models", model, "prices", "standard", "text", "input"], "15")
      refute OpenAIPricingPreflight.validate_payload(invalid).compatible?
    end
  end

  test "image modality prices are validated and excluded from generic snapshots in every tier" do
    payload = @target |> File.read!() |> CodexPooler.JSON.decode!()
    result = OpenAIPricingFormat.classify(payload)

    assert result.compatible?
    assert result.errors == []

    for model <- ~w(gpt-image-2.6-flare gpt-image-2.6-sunburst) do
      refute Enum.any?(result.rows, &(&1.model_identifier == model))

      for tier <- Map.keys(payload["models"][model]["prices"]), bucket <- ~w(text image) do
        path = "models.#{model}.prices.#{tier}.#{bucket}"
        assert Enum.any?(result.warnings, &(&1.code == :unsupported_price_bucket and &1.path == path))

        invalid = put_in(payload, ["models", model, "prices", tier, bucket, "input"], "1")
        refute OpenAIPricingPreflight.validate_payload(invalid).compatible?
      end
    end
  end

  test "classifies the immutable July 28 fixture with exact reviewed coverage" do
    result = OpenAIPricingPreflight.validate_file(@fixture)

    assert result.compatible?
    assert result.errors == []
    assert length(result.warnings) == 90

    assert result.summary == %{
             importable_rows: 208,
             priced_rows: 199,
             unavailable_rows: 9,
             skipped_models: 8,
             skipped_price_buckets: 82
           }

    assert Enum.frequencies_by(result.warnings, & &1.code) == %{
             incomplete_price_bucket: 4,
             unsupported_price_bucket: 78,
             unsupported_pricing_type: 8
           }

    assert result.warnings == Enum.sort_by(result.warnings, &{&1.path, &1.code, &1.message})

    assert Enum.filter(result.warnings, &(&1.code == :incomplete_price_bucket))
           |> Enum.map(& &1.path) == [
             "models.omni-moderation-latest.prices.standard.default",
             "models.text-embedding-3-large.prices.standard.default",
             "models.text-embedding-3-small.prices.standard.default",
             "models.text-embedding-ada-002.prices.standard.default"
           ]
  end

  test "v2 non-importable modality and per-minute shapes omit context rules" do
    for {type, buckets} <- [
          {"per_minute", %{"default" => %{"price_per_minute" => 0.02}}},
          {"per_1m_tokens", %{"image" => %{"input" => 1, "cached_input" => 0.5}}}
        ] do
      payload =
        valid_payload()
        |> Map.put("schema_version", 2)
        |> put_in(["models", "future-model", "pricing_type"], type)
        |> put_in(["models", "future-model", "pricing_types"], [type])
        |> put_in(["models", "future-model", "prices", "standard"], buckets)
        |> update_in(["models", "future-model"], &Map.delete(&1, "timestamp"))

      assert %{compatible?: true, summary: %{importable_rows: 0}} = OpenAIPricingPreflight.validate_payload(payload)
      refute OpenAIPricingPreflight.validate_payload(put_in(payload, ["models", "future-model", "context_pricing"], nil)).compatible?
    end
  end

  test "normalized rule semantics remove only the descriptor provenance path" do
    assert ContextPricing.semantics(%{"status" => "unknown", "provenance" => %{"locator" => "source"}, "other" => %{"provenance" => "semantic"}}) == %{"status" => "unknown", "other" => %{"provenance" => "semantic"}}
  end

  test "v2 context rule validation rejects malformed schema, values, provenance and tier coverage" do
    payload = context_payload()
    model_path = ["models", "future-model"]
    context_path = model_path ++ ["context_pricing"]
    rule_path = context_path ++ ["tiers", "standard"]
    rule = get_in(payload, rule_path)

    mutations =
      Enum.map([nil, true, 1, 2.0, "2", 3], &Map.put(payload, "schema_version", &1)) ++
        Enum.map([nil, false, 0, -1, 1.5, "500000", 9_007_199_254_740_992], &put_in(payload, rule_path ++ ["long_context_input_tokens_gt"], &1)) ++
        Enum.map([nil, true, 1.0, "1", 2], &put_in(payload, context_path ++ ["version"], &1)) ++
        Enum.map([nil, "", " ", String.duplicate("é", 129)], &put_in(payload, rule_path ++ ["provenance", "locator"], &1)) ++
        Enum.map([nil, String.duplicate("A", 64), String.duplicate("a", 63), String.duplicate("a", 65)], &put_in(payload, rule_path ++ ["provenance", "evidence_sha256"], &1)) ++
        Enum.map([nil, "", "2026-07-29T00:00:00Z"], &put_in(payload, model_path ++ ["timestamp"], &1)) ++
        [
          update_in(payload, model_path, &Map.delete(&1, "context_pricing")),
          put_in(payload, context_path, nil),
          put_in(payload, context_path ++ ["tiers"], %{}),
          put_in(payload, context_path ++ ["tiers", "priority"], rule),
          put_in(payload, rule_path ++ ["unit"], "tokens"),
          put_in(payload, rule_path ++ ["operator"], "gt"),
          put_in(payload, rule_path ++ ["provenance", "timestamp"], payload["generated_at"]),
          Map.delete(payload, "schema_version")
        ]

    for {candidate, index} <- Enum.with_index(mutations) do
      result = OpenAIPricingPreflight.validate_payload(candidate)
      refute result.compatible?, "malformed v2 candidate #{index} accepted"
      assert result.errors != []
    end

    for cutoff <- [1, 500_000, 9_007_199_254_740_991] do
      assert OpenAIPricingPreflight.validate_payload(put_in(payload, rule_path ++ ["long_context_input_tokens_gt"], cutoff)).compatible?
    end
  end

  test "v2 unknown observations require exact sorted distinct rules and uniform forbids long context" do
    payload = context_payload()
    rule_path = ["models", "future-model", "context_pricing", "tiers", "standard"]
    provenance = get_in(payload, rule_path ++ ["provenance"])
    long = %{"bucket" => "long_context", "operator" => "gt", "input_tokens" => 500_000}
    short = %{"bucket" => "short_context", "operator" => "lte", "input_tokens" => 272_000}
    unknown = %{"status" => "unknown", "reason" => "conflicting_source", "observed_rules" => [long, short], "provenance" => provenance}

    for reason <- ~w(unsupported_source conflicting_source), observations <- [[], [long], [long, short]] do
      descriptor = unknown |> Map.put("reason", reason) |> Map.put("observed_rules", observations)
      assert OpenAIPricingPreflight.validate_payload(put_in(payload, rule_path, descriptor)).compatible?
    end

    assert OpenAIPricingPreflight.validate_payload(put_in(payload, rule_path, %{unknown | "reason" => "missing_source", "observed_rules" => []})).compatible?
    refute OpenAIPricingPreflight.validate_payload(put_in(payload, rule_path, %{unknown | "reason" => "missing_source"})).compatible?

    for observations <- [nil, %{}, [short, long], [long, long], [Map.put(long, "operator", "eq")], [Map.put(long, "input_tokens", true)], [Map.put(long, "extra", 1)], [%{}]] do
      refute OpenAIPricingPreflight.validate_payload(put_in(payload, rule_path, Map.put(unknown, "observed_rules", observations))).compatible?
    end

    for descriptor <- [Map.put(unknown, "reason", "invented"), Map.put(unknown, "long_context_input_tokens_gt", 1), Map.delete(unknown, "observed_rules"), %{"status" => "legacy", "provenance" => provenance}] do
      refute OpenAIPricingPreflight.validate_payload(put_in(payload, rule_path, descriptor)).compatible?
    end

    uniform = put_in(payload, rule_path, %{"status" => "uniform", "provenance" => provenance})
    assert OpenAIPricingPreflight.validate_payload(uniform).compatible?
    refute OpenAIPricingPreflight.validate_payload(put_in(uniform, ["models", "future-model", "prices", "standard", "long_context"], %{"available" => false})).compatible?
  end

  test "v2 requires matching prices and rules before normalizing aliases" do
    payload = context_payload()
    rule = get_in(payload, ["models", "future-model", "context_pricing", "tiers", "standard"])
    prices = get_in(payload, ["models", "future-model", "prices", "standard"])

    aliases =
      payload
      |> put_in(["models", "future-model", "prices"], %{"fast" => prices, "priority" => prices})
      |> put_in(["models", "future-model", "context_pricing", "tiers"], %{"fast" => rule, "priority" => put_in(rule, ["provenance", "locator"], "other/source")})

    assert %{compatible?: true, summary: %{importable_rows: 1}} = OpenAIPricingPreflight.validate_payload(aliases)
    changed = put_in(aliases, ["models", "future-model", "context_pricing", "tiers", "priority", "long_context_input_tokens_gt"], 272_000)
    assert %{compatible?: false, errors: [%{code: :conflicting_service_tier_alias}]} = OpenAIPricingPreflight.validate_payload(changed)
    lower = put_in(payload, ["models", "future-model", "prices", "standard", "short_context"], prices["default"])
    assert OpenAIPricingPreflight.validate_payload(lower).compatible?
    same_reasoning = put_in(lower, ["models", "future-model", "prices", "standard", "short_context", "reasoning"], prices["default"]["output"])
    assert OpenAIPricingPreflight.validate_payload(same_reasoning).compatible?

    for prices <- [%{"input" => 99, "output" => 2}, %{"available" => false}, %{"input" => 1}] do
      refute OpenAIPricingPreflight.validate_payload(put_in(lower, ["models", "future-model", "prices", "standard", "default"], prices)).compatible?
    end
  end

  test "strict root, model, and tool objects reject missing, extra, and wrong typed values" do
    payload = valid_payload()

    mutations = [
      Map.delete(payload, "tools_count"),
      Map.put(payload, "extra", true),
      Map.put(payload, "models_count", 2),
      Map.put(payload, "tools", %{}),
      put_in(payload, ["tools", "sample-tool", "extra"], true),
      put_in(payload, ["tools", "sample-tool", "price"], "1"),
      put_in(payload, ["models", "future-model", "extra"], true),
      put_in(payload, ["models", "future-model", "categories"], []),
      put_in(payload, ["models", "future-model", "categories"], [
        "language_model",
        "language_model"
      ]),
      put_in(payload, ["models", "future-model", "timestamp"], "2026-07-29T00:00:00Z"),
      put_in(payload, ["models", "future-model", "pricing_types"], ["per_minute"])
    ]

    Enum.each(mutations, fn candidate ->
      refute OpenAIPricingPreflight.validate_payload(candidate).compatible?
    end)
  end

  test "duplicate raw JSON keys at every object depth are invalid JSON" do
    duplicate_documents = [
      ~s({"generated_at":"2026-07-28T00:00:00Z","generated_at":"2026-07-28T00:00:00Z"}),
      ~s({"root":{"model":1,"model":1}}),
      ~s({"root":{"tier":{"default":{"input":1,"input":1}}}})
    ]

    Enum.each(duplicate_documents, fn raw ->
      path = write_raw!(raw)

      assert %{compatible?: false, errors: [%{code: :invalid_json}]} =
               OpenAIPricingPreflight.validate_file(path)
    end)
  end

  test "duration-specific cache writes retain independent rates without a generic rate" do
    path = ["models", "future-model", "prices", "standard", "default"]
    rates = %{"input" => 1, "cached_input" => 0.1, "output" => 2, "cache_write_30m" => 1.25, "cache_write_12h" => 2.5}

    for values <- [rates, Map.delete(rates, "cache_write_30m"), Map.delete(rates, "cache_write_12h"), %{rates | "cache_write_30m" => 0, "cache_write_12h" => 0}] do
      payload = put_in(context_payload(), path, values)
      assert %{compatible?: true, rows: [row]} = OpenAIPricingFormat.classify(payload)
      assert is_nil(row.cache_write)
      assert row.cache_write_30m == decimal_rate(values["cache_write_30m"])
      assert row.cache_write_12h == decimal_rate(values["cache_write_12h"])
      assert Decimal.equal?(row.cached_input, Decimal.new("0.1"))
    end

    for field <- ~w(cache_write_30m cache_write_12h), value <- [nil, true, -1, "1.25", %{}, []] do
      payload = put_in(context_payload(), path, Map.put(rates, field, value))
      assert %{compatible?: false, errors: errors} = OpenAIPricingFormat.classify(payload)
      assert Enum.any?(errors, &(&1.code == :invalid_snapshot_bucket))
    end

    refute OpenAIPricingPreflight.validate_payload(put_in(context_payload(), path, Map.put(rates, "cache_write_24h", 5))).compatible?
  end

  test "duration-specific rates participate in context and service-tier alias equality" do
    path = ["models", "future-model"]
    rates = %{"input" => 1, "output" => 2, "cache_write_30m" => 1, "cache_write_12h" => 2}
    buckets = %{"default" => rates, "short_context" => %{rates | "cache_write_30m" => 1.0, "cache_write_12h" => 2.0}}
    payload = put_in(context_payload(), path ++ ["prices", "standard"], buckets)
    assert OpenAIPricingPreflight.validate_payload(payload).compatible?

    for field <- ~w(cache_write_30m cache_write_12h) do
      changed = put_in(payload, path ++ ["prices", "standard", "short_context", field], 9)
      assert %{compatible?: false, errors: errors} = OpenAIPricingPreflight.validate_payload(changed)
      assert Enum.any?(errors, &(&1.code == :conflicting_default_short_alias))
    end

    rule = get_in(payload, path ++ ["context_pricing", "tiers", "standard"])
    aliases = payload |> put_in(path ++ ["prices"], %{"fast" => buckets, "priority" => buckets}) |> put_in(path ++ ["context_pricing", "tiers"], %{"fast" => rule, "priority" => rule})
    assert OpenAIPricingPreflight.validate_payload(aliases).compatible?

    for field <- ~w(cache_write_30m cache_write_12h) do
      changed = update_in(aliases, path ++ ["prices", "priority"], &Map.new(&1, fn {bucket, prices} -> {bucket, Map.put(prices, field, 9)} end))
      assert %{compatible?: false, errors: errors} = OpenAIPricingPreflight.validate_payload(changed)
      assert Enum.any?(errors, &(&1.code == :conflicting_service_tier_alias))
    end
  end

  test "supports cache_write and exact priced and unavailable bucket shapes" do
    payload = valid_payload()
    result = OpenAIPricingPreflight.validate_payload(payload)
    assert result.compatible?
    assert result.summary.importable_rows == 1

    unavailable =
      put_in(payload, ["models", "future-model", "prices", "standard", "default"], %{
        "available" => false
      })

    assert OpenAIPricingPreflight.validate_payload(unavailable).compatible?

    incomplete =
      put_in(
        payload,
        ["models", "future-model", "prices", "standard", "default"],
        %{"input" => 1}
      )

    assert %{compatible?: true, warnings: [%{code: :incomplete_price_bucket}]} =
             OpenAIPricingPreflight.validate_payload(incomplete)

    invalid_buckets = [
      %{"input" => 1, "output" => 2, "unknown" => 3},
      %{"input" => 1, "output" => 2, "available" => false},
      %{"available" => true},
      %{"input" => "1", "output" => 2},
      %{"input" => -1, "output" => 2},
      %{"input" => 1, "output" => nil}
    ]

    Enum.each(invalid_buckets, fn bucket ->
      candidate =
        put_in(payload, ["models", "future-model", "prices", "standard", "default"], bucket)

      refute OpenAIPricingPreflight.validate_payload(candidate).compatible?
    end)
  end

  test "accepts every reviewed non-snapshot descriptor for future model identities" do
    descriptors = [
      {"audio", %{"cached_input" => 0, "input" => 1, "output" => 2}},
      {"audio", %{"input" => 1, "output" => 2}},
      {"audio", %{"output" => 2}},
      {"image", %{"cached_input" => 0, "input" => 1}},
      {"image", %{"cached_input" => 0, "input" => 1, "output" => 2}},
      {"inference", %{"cached_input" => 0, "input" => 1, "output" => 2, "training" => 3}},
      {"inference",
       %{
         "cached_input" => 0,
         "input" => 1,
         "output" => 2,
         "training" => 3,
         "training_unit" => "hour"
       }},
      {"inference", %{"input" => 1, "output" => 2, "training" => 3}},
      {"inference_with_data_sharing",
       %{
         "cached_input" => 0,
         "input" => 1,
         "output" => 2,
         "training" => 3,
         "training_unit" => "hour"
       }},
      {"text", %{"cached_input" => 0, "input" => 1}},
      {"text", %{"cached_input" => 0, "input" => 1, "output" => 2}},
      {"text", %{"input" => 1}},
      {"text", %{"input" => 1, "output" => 2}}
    ]

    Enum.each(descriptors, fn {bucket, values} ->
      payload =
        put_in(valid_payload(), ["models", "future-model", "prices", "standard"], %{
          "default" => %{"input" => 1, "output" => 2},
          bucket => values
        })

      result = OpenAIPricingPreflight.validate_payload(payload)
      assert result.compatible?, inspect({bucket, result.errors})
      assert Enum.any?(result.warnings, &(&1.code == :unsupported_price_bucket))
    end)
  end

  test "descriptor mutations fail closed" do
    mutations = [
      {"image", %{"cached_input" => 0, "input" => 1, "quality" => "high"}},
      {"inference", %{"input" => 1, "output" => 2, "training" => 3, "training_unit" => "minute"}},
      {"text", %{"input" => "1"}},
      {"numeric_bucket", %{"input" => 1, "output" => 2}}
    ]

    Enum.each(mutations, fn {bucket, values} ->
      payload =
        put_in(valid_payload(), ["models", "future-model", "prices", "standard"], %{
          "default" => %{"input" => 1, "output" => 2},
          bucket => values
        })

      refute OpenAIPricingPreflight.validate_payload(payload).compatible?
    end)
  end

  test "unsupported top-level descriptors are structural rather than identity based" do
    candidates = [
      unsupported_payload("future-live", "mixed", ["per_1m_tokens", "per_minute"], %{
        "standard" => %{
          "audio" => %{"output" => 1},
          "live_transcription" => %{"estimated_cost" => 2}
        }
      }),
      unsupported_payload("future-minute", "per_minute", ["per_minute"], %{
        "standard" => %{"transcription" => %{"estimated_cost" => 1, "input" => 2, "output" => 3}}
      }),
      unsupported_payload("future-video", "per_second", ["per_second"], %{
        "batch" => %{
          "720p" => %{
            "landscape" => "1280x720",
            "portrait" => "720x1280",
            "price_per_second" => 1
          }
        }
      })
    ]

    Enum.each(candidates, fn payload ->
      result = OpenAIPricingPreflight.validate_payload(payload)
      assert result.compatible?
      assert [%{code: :unsupported_pricing_type}] = result.warnings
      assert result.summary.skipped_models == 1
      assert result.summary.importable_rows == 0
    end)

    changed =
      put_in(
        List.last(candidates),
        ["models", "future-video", "prices", "batch", "720p", "landscape"],
        "720x1280"
      )

    refute OpenAIPricingPreflight.validate_payload(changed).compatible?
  end

  test "flat default per-minute rates are validated skips without price rows" do
    payload =
      unsupported_payload("future-flat-minute", "per_minute", ["per_minute"], %{
        "standard" => %{"default" => %{"price_per_minute" => 1}}
      })

    result = OpenAIPricingPreflight.validate_payload(payload)
    assert result.compatible?, inspect(result.errors)
    assert result.errors == []

    assert [%{code: :unsupported_pricing_type, path: "models.future-flat-minute.pricing_type"}] =
             result.warnings

    assert result.summary.skipped_models == 1
    assert result.summary.importable_rows == 0

    refute Enum.any?(
             OpenAIPricingFormat.classify(payload).rows,
             &(&1.model_identifier == "future-flat-minute")
           )
  end

  test "malformed flat default per-minute rates stay structural errors" do
    flat = %{"price_per_minute" => 1}

    variants = [
      %{"standard" => %{"default" => %{"price_per_minute" => "1"}}},
      %{"standard" => %{"default" => %{"price_per_minute" => nil}}},
      %{"standard" => %{"default" => %{"price_per_minute" => -1}}},
      %{"standard" => %{"default" => %{}}},
      %{"standard" => %{"default" => Map.put(flat, "unit", "minute")}},
      %{"standard" => %{"default" => Map.put(flat, "estimated_cost", 1)}},
      %{"standard" => %{"default" => %{"estimated_cost" => 1}}},
      %{"standard" => %{"default" => flat, "live_transcription" => %{"estimated_cost" => 1}}},
      %{"standard" => %{"live_transcription" => flat}},
      %{"batch" => %{"default" => flat}},
      %{"standard" => %{"default" => flat}, "priority" => %{"default" => flat}}
    ]

    Enum.each(variants, fn prices ->
      payload = unsupported_payload("future-flat-variant", "per_minute", ["per_minute"], prices)
      result = OpenAIPricingPreflight.validate_payload(payload)
      refute result.compatible?, inspect(prices)

      assert Enum.any?(result.errors, &(&1.code == :unsupported_pricing_type_shape)),
             inspect(prices)

      assert result.summary.importable_rows == 0
    end)

    for {pricing_type, pricing_types} <- [
          {"mixed", ["per_1m_tokens", "per_minute"]},
          {"per_second", ["per_second"]},
          {"per_1m_characters", ["per_1m_characters"]}
        ] do
      payload =
        unsupported_payload("future-flat-other", pricing_type, pricing_types, %{
          "standard" => %{"default" => flat}
        })

      refute OpenAIPricingPreflight.validate_payload(payload).compatible?, pricing_type
    end
  end

  test "accepts the reviewed live per-minute flat-rate descriptors as validated skips" do
    candidates = [
      unsupported_payload("future-live-transcribe", "per_minute", ["per_minute"], %{
        "standard" => %{"live_transcription" => %{"estimated_cost" => 0.017}}
      }),
      unsupported_payload("future-live-translate", "per_minute", ["per_minute"], %{
        "standard" => %{"live_translation" => %{"estimated_cost" => 0.034}}
      })
    ]

    Enum.each(candidates, fn payload ->
      result = OpenAIPricingPreflight.validate_payload(payload)
      assert result.compatible?, inspect(result.errors)
      assert [%{code: :unsupported_pricing_type}] = result.warnings
      assert result.summary.skipped_models == 1
      assert result.summary.importable_rows == 0
    end)
  end

  test "unknown and malformed live per-minute variants stay fail-closed" do
    variants = [
      {"live_transcription", %{"estimated_cost" => 0.017, "input" => 2.5, "output" => 10}},
      {"live_translation", %{"estimated_cost" => 0.034, "input" => 2.5, "output" => 10}},
      {"live_transcription", %{"estimated_cost" => nil}},
      {"live_transcription", %{"estimated_cost" => "0.017"}},
      {"live_transcription", %{"estimated_cost" => -0.017}},
      {"live_transcription", %{"estimated_cost" => 0.017, "unit" => "minute"}},
      {"live_translation", %{}},
      {"live_diarization", %{"estimated_cost" => 0.017}}
    ]

    Enum.each(variants, fn {bucket, values} ->
      payload =
        unsupported_payload("future-live-variant", "per_minute", ["per_minute"], %{
          "standard" => %{bucket => values}
        })

      result = OpenAIPricingPreflight.validate_payload(payload)
      refute result.compatible?, bucket
      assert Enum.any?(result.errors, &(&1.code == :unsupported_pricing_type_shape))
      assert result.summary.importable_rows == 0
    end)

    extra_tier =
      unsupported_payload("future-live-tier", "per_minute", ["per_minute"], %{
        "standard" => %{"live_transcription" => %{"estimated_cost" => 0.017}},
        "batch" => %{"live_transcription" => %{"estimated_cost" => 0.017}}
      })

    refute OpenAIPricingPreflight.validate_payload(extra_tier).compatible?
  end

  test "mixed and per-minute descriptors reject every non-standard tier" do
    cases = [
      unsupported_payload("future-mixed-extra", "mixed", ["per_1m_tokens", "per_minute"], %{
        "standard" => %{"audio" => %{"output" => 1}},
        "priority" => %{"ignored" => %{"arbitrary" => true}}
      }),
      unsupported_payload("future-minute-extra", "per_minute", ["per_minute"], %{
        "standard" => %{"transcription" => %{"estimated_cost" => 1}},
        "batch" => %{"transcription" => %{"estimated_cost" => 1}}
      }),
      unsupported_payload("future-minute-malformed", "per_minute", ["per_minute"], %{
        "standard" => %{"transcription" => %{"estimated_cost" => 1}},
        "priority" => %{"transcription" => %{"estimated_cost" => nil}}
      })
    ]

    Enum.each(cases, fn payload ->
      result = OpenAIPricingPreflight.validate_payload(payload)
      refute result.compatible?
      assert Enum.any?(result.errors, &(&1.code == :unsupported_pricing_type_shape))
      assert result.summary.importable_rows == 0
    end)

    per_second =
      unsupported_payload("future-video-extra", "per_second", ["per_second"], %{
        "priority" => %{
          "720p" => %{
            "landscape" => "1280x720",
            "portrait" => "720x1280",
            "price_per_second" => 1
          }
        }
      })

    refute OpenAIPricingPreflight.validate_payload(per_second).compatible?
  end

  test "fast and priority aliases require identical normalized bucket collections" do
    base = %{"default" => %{"input" => 1, "output" => 2}}
    extra = Map.put(base, "short_context", %{"input" => 3, "output" => 4})

    Enum.each([{base, extra}, {extra, base}], fn {fast, priority} ->
      payload =
        put_in(valid_payload(), ["models", "future-model", "prices"], %{
          "fast" => fast,
          "priority" => priority
        })

      result = OpenAIPricingPreflight.validate_payload(payload)
      refute result.compatible?
      assert Enum.any?(result.errors, &(&1.code == :conflicting_service_tier_alias))
    end)
  end

  test "returns controlled file errors" do
    path =
      Path.join(System.tmp_dir!(), "missing-pricing-#{System.unique_integer([:positive])}.json")

    assert %{compatible?: false, errors: [%{code: :file_read_failed, path: ^path}]} =
             OpenAIPricingPreflight.validate_file(path)
  end

  test "malformed root and model values return structured errors without raising" do
    payload = valid_payload()

    for {key, values} <- [
          {"generated_at", [nil, 42, "bad-date"]},
          {"source", [nil, 42, " "]},
          {"models_count", [nil, -1, "1"]},
          {"tools_count", [nil, -1, "1"]}
        ],
        value <- values do
      result = OpenAIPricingPreflight.validate_payload(Map.put(payload, key, value))
      refute result.compatible?
      assert Enum.any?(result.errors, &(&1.path == key))
    end

    for {key, values} <- [
          {"model", [nil, 42, " ", "different-model"]},
          {"category", [nil, 42, " "]},
          {"timestamp", [nil, 42, "bad-date"]},
          {"prices", [%{"standard" => []}, %{"standard" => %{}}, %{42 => %{}}]}
        ],
        value <- values do
      result =
        OpenAIPricingPreflight.validate_payload(put_in(payload, ["models", "future-model", key], value))

      refute result.compatible?
      assert result.errors != []
    end
  end

  test "non-object roots and nested duplicate keys are rejected" do
    for root <- [nil, [], 42, "value"] do
      refute OpenAIPricingPreflight.validate_payload(root).compatible?
    end

    for raw <- [~s([{"key":1,"key":2}]), ~s({"nested":[{"key":1,"key":2}]})] do
      assert {:error, :invalid_json} = OpenAIPricingFormat.decode(raw)
    end

    assert %{compatible?: false, errors: [%{code: :invalid_path}]} =
             OpenAIPricingPreflight.validate_file(nil)
  end

  test "identical fast and priority aliases produce one canonical price row" do
    payload = valid_payload()
    tier = get_in(payload, ["models", "future-model", "prices", "standard"])

    payload =
      put_in(payload, ["models", "future-model", "prices"], %{"fast" => tier, "priority" => tier})

    result = OpenAIPricingFormat.classify(payload)
    assert result.compatible?
    assert [row] = result.rows
    assert row.service_tier == "priority"
    assert row.price_bucket == "default"
    assert Decimal.equal?(row.input, 1)
    assert result.summary.importable_rows == 1
    assert result.summary.priced_rows == 1
    assert result.coverage.imported_price_buckets["default"] == 1
  end

  test "skipped fast and priority aliases count once while retaining raw source warnings" do
    tier = %{
      "default" => %{"input" => 1, "output" => 2},
      "inference" => %{"input" => 3, "output" => 4, "training" => 5}
    }

    for aliases <- [["fast"], ["priority"], ["fast", "priority"]] do
      payload = put_in(valid_payload(), ["models", "future-model", "prices"], Map.new(aliases, &{&1, tier}))
      result = OpenAIPricingFormat.classify(payload)

      assert result.compatible?
      assert result.summary == %{importable_rows: 1, priced_rows: 1, unavailable_rows: 0, skipped_models: 0, skipped_price_buckets: 1}
      assert [%{service_tier: "priority", price_bucket: "default"}] = result.rows
      assert result.coverage.imported_price_buckets == %{"default" => 1, "short_context" => 0, "long_context" => 0}
      assert Enum.map(result.warnings, &{&1.code, &1.path}) == Enum.map(aliases, &{:unsupported_price_bucket, "models.future-model.prices.#{&1}.inference"})
    end
  end

  test "skipped descriptor identity preserves different models buckets and nonalias tiers" do
    tier = %{"audio" => %{"output" => 2}, "text" => %{"input" => 1}}
    prices = Map.new(~w(fast priority standard ultrafast), &{&1, tier})
    payload = valid_payload()
    model = put_in(payload, ["models", "future-model", "prices"], prices)["models"]["future-model"]
    models = Map.new(~w(first-model second-model), &{&1, Map.put(model, "model", &1)})
    payload = %{payload | "models" => models, "models_count" => 2}
    result = OpenAIPricingFormat.classify(payload)

    assert result.compatible?
    assert result.summary.skipped_price_buckets == 12
    assert length(result.warnings) == 16
    assert Enum.all?(result.warnings, &(&1.code == :unsupported_price_bucket))
    assert result.rows == []
    assert result.summary.importable_rows == 0

    invalid = put_in(payload, ["models", "first-model", "prices", "priority", "audio", "output"], -1)
    refute OpenAIPricingFormat.classify(invalid).compatible?
  end

  test "non-token descriptors fail closed unless their complete schema is recognized" do
    for {type, prices} <- [
          {"mixed", %{"standard" => %{"unknown" => %{"output" => 1}}}},
          {"per_second", %{"standard" => %{"unknown" => %{"price_per_second" => 1}}}},
          {"per_second",
           %{
             "standard" => %{
               "720p" => %{
                 "landscape" => "wrong",
                 "portrait" => "720x1280",
                 "price_per_second" => 1
               }
             }
           }},
          {"future_unit", %{"standard" => %{"default" => %{"input" => 1, "output" => 2}}}}
        ] do
      result =
        unsupported_payload("sample-model", type, [type], prices)
        |> OpenAIPricingPreflight.validate_payload()

      refute result.compatible?
      assert Enum.any?(result.errors, &(&1.code == :unsupported_pricing_type_shape))
    end
  end

  test "data-sharing inference descriptors are validated but never imported as token buckets" do
    values = %{
      "cached_input" => 0.1,
      "input" => 1,
      "output" => 2,
      "training" => 3,
      "training_unit" => "hour"
    }

    payload =
      put_in(
        valid_payload(),
        ["models", "future-model", "prices", "standard", "inference_with_data_sharing"],
        values
      )

    result = OpenAIPricingFormat.classify(payload)
    assert result.compatible?
    assert length(result.rows) == 1
    assert result.summary.skipped_price_buckets == 1

    for invalid <- [
          nil,
          [],
          Map.put(values, "training_unit", "minute"),
          Map.put(values, "training", -1)
        ] do
      candidate =
        put_in(
          payload,
          ["models", "future-model", "prices", "standard", "inference_with_data_sharing"],
          invalid
        )

      refute OpenAIPricingPreflight.validate_payload(candidate).compatible?
    end
  end

  test "malformed bucket values and whitespace keys are rejected" do
    for value <- [nil, 1, [], "1"] do
      candidate =
        put_in(
          valid_payload(),
          ["models", "future-model", "prices", "standard", "default"],
          value
        )

      refute OpenAIPricingPreflight.validate_payload(candidate).compatible?
    end

    payload = valid_payload()
    tool = payload["tools"]["sample-tool"]

    for key <- ["", " sample-tool ", 42] do
      candidate = %{payload | "tools" => %{key => tool}}
      refute OpenAIPricingPreflight.validate_payload(candidate).compatible?
    end

    tier = get_in(payload, ["models", "future-model", "prices", "standard"])

    for key <- ["Standard", " standard ", ""] do
      candidate = put_in(payload, ["models", "future-model", "prices"], %{key => tier})
      refute OpenAIPricingPreflight.validate_payload(candidate).compatible?
    end
  end

  test "coalesced unavailable aliases count one row in each retained bucket" do
    tier = %{"default" => %{"available" => false}, "long_context" => %{"available" => false}}

    payload =
      put_in(valid_payload(), ["models", "future-model", "prices"], %{
        "fast" => tier,
        "priority" => tier
      })

    result = OpenAIPricingFormat.classify(payload)
    assert result.compatible?
    assert length(result.rows) == 2
    assert result.summary.importable_rows == 2
    assert result.summary.unavailable_rows == 2
    assert result.summary.priced_rows == 0

    assert result.coverage.imported_price_buckets == %{
             "default" => 1,
             "long_context" => 1,
             "short_context" => 0
           }
  end

  defp decimal_rate(nil), do: nil
  defp decimal_rate(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_rate(value) when is_float(value), do: Decimal.from_float(value)

  defp context_payload do
    valid_payload()
    |> Map.put("schema_version", 2)
    |> put_in(["models", "future-model", "context_pricing"], %{"version" => 1, "tiers" => %{"standard" => %{"status" => "known", "long_context_input_tokens_gt" => 500_000, "provenance" => %{"locator" => "example/standard", "evidence_sha256" => String.duplicate("a", 64)}}}})
  end

  defp valid_payload do
    generated_at = "2026-07-28T00:00:00Z"

    %{
      "generated_at" => generated_at,
      "models" => %{
        "future-model" => %{
          "categories" => ["language_model"],
          "category" => "language_model",
          "model" => "future-model",
          "prices" => %{
            "standard" => %{
              "default" => %{
                "input" => 1,
                "cached_input" => 0.1,
                "cache_write" => 1.25,
                "output" => 2
              }
            }
          },
          "pricing_type" => "per_1m_tokens",
          "pricing_types" => ["per_1m_tokens"],
          "timestamp" => generated_at
        }
      },
      "models_count" => 1,
      "source" => "synthetic",
      "source_url" => "https://example.com/pricing.json",
      "tools" => %{
        "sample-tool" => %{
          "details" => "Synthetic tool",
          "price" => 0,
          "pricing" => "$0",
          "tool" => "Sample Tool"
        }
      },
      "tools_count" => 1
    }
  end

  defp unsupported_payload(identifier, pricing_type, pricing_types, prices) do
    payload = valid_payload()

    model = %{
      "categories" => ["other"],
      "category" => "other",
      "model" => identifier,
      "prices" => prices,
      "pricing_type" => pricing_type,
      "pricing_types" => pricing_types,
      "timestamp" => payload["generated_at"]
    }

    payload
    |> Map.put("models", %{identifier => model})
    |> Map.put("models_count", 1)
  end

  defp write_raw!(raw) do
    path =
      Path.join(System.tmp_dir!(), "pricing-preflight-#{Ecto.UUID.generate()}.json")

    on_exit(fn -> File.rm(path) end)
    File.write!(path, raw)
    path
  end
end
