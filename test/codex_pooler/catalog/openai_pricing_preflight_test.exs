defmodule CodexPooler.Catalog.OpenAIPricingPreflightTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.OpenAIPricingPreflight

  @fixture Path.expand("../../fixtures/pricing/openai/2026-07-28.json", __DIR__)
  @target Path.expand("../../../priv/pricing/openai/pricing.json", __DIR__)
  @target_sha256 "0d6ed91d7ad5c741fc78a6cf2f90d02915c4bc2abb59df6796817dcb95402d34"

  @skipped_pricing_type_paths [
    "models.gpt-4o-mini-transcribe.pricing_type",
    "models.gpt-4o-transcribe-diarize.pricing_type",
    "models.gpt-4o-transcribe.pricing_type",
    "models.gpt-live-transcribe.pricing_type",
    "models.gpt-transcribe.pricing_type",
    "models.sora-2-pro.pricing_type",
    "models.sora-2.pricing_type",
    "models.whisper.pricing_type"
  ]

  @incomplete_bucket_paths [
    "models.omni-moderation-latest.prices.standard.default",
    "models.text-embedding-3-large.prices.standard.default",
    "models.text-embedding-3-small.prices.standard.default",
    "models.text-embedding-ada-002.prices.standard.default"
  ]

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

  test "classifies the reviewed August 5 target with exact artifact and warning coverage" do
    raw = File.read!(@target)
    payload = Jason.decode!(raw)
    result = OpenAIPricingPreflight.validate_file(@target)

    assert byte_size(raw) == 62_975
    assert Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == @target_sha256
    assert payload["generated_at"] == "2026-08-05T17:15:03.219498Z"
    assert payload["models_count"] == 79
    assert map_size(payload["models"]) == 79
    assert payload["tools_count"] == 4
    assert map_size(payload["tools"]) == 4

    assert result.compatible?
    assert result.errors == []
    assert length(result.warnings) == 82

    assert result.summary == %{
             importable_rows: 177,
             priced_rows: 165,
             unavailable_rows: 12,
             skipped_models: 8,
             skipped_price_buckets: 74
           }

    assert result.coverage.imported_price_buckets == %{
             "default" => 111,
             "long_context" => 33,
             "short_context" => 33
           }

    assert Enum.frequencies_by(result.warnings, & &1.code) == %{
             incomplete_price_bucket: 4,
             unsupported_price_bucket: 70,
             unsupported_pricing_type: 8
           }

    warning_paths = Enum.group_by(result.warnings, & &1.code, & &1.path)
    assert warning_paths.incomplete_price_bucket == @incomplete_bucket_paths
    assert warning_paths.unsupported_pricing_type == @skipped_pricing_type_paths
    assert length(Enum.uniq(warning_paths.unsupported_price_bucket)) == 70
    assert result.warnings == Enum.sort_by(result.warnings, &{&1.path, &1.code, &1.message})
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
      Path.join(System.tmp_dir!(), "pricing-preflight-#{System.unique_integer([:positive])}.json")

    File.write!(path, raw)
    path
  end
end
