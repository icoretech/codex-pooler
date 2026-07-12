defmodule CodexPooler.Catalog.OpenAIPricingImporterTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.OpenAIPricingImporter
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  @pricing_path Path.expand("../../../priv/pricing/openai/pricing.json", __DIR__)

  test "imports vendored pricing transactionally and idempotently" do
    count_before = pricing_count_for_version(current_price_version(vendored_price_version()))

    assert {:ok, first} = OpenAIPricingImporter.import_file(@pricing_path)
    assert first.source == "openai-json-pricing"
    assert first.inserted >= 0
    assert String.ends_with?(first.price_version, ":importer-format-1")

    count_after_first = pricing_count_for_version(first.price_version)
    assert count_after_first > 0
    assert count_after_first - count_before == first.inserted

    gpt_models = ["gpt-5", "gpt-5-mini", "gpt-5-codex"]

    present_models =
      @pricing_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("models")
      |> Map.keys()
      |> MapSet.new()

    Enum.each(gpt_models, fn model ->
      if MapSet.member?(present_models, model) do
        assert Repo.exists?(
                 from s in PricingSnapshot,
                   where:
                     s.model_identifier == ^model and
                       fragment("?->>'service_tier'", s.config) == "standard" and
                       fragment("?->>'price_bucket'", s.config) == "default"
               )
      end
    end)

    referenced_snapshot = Repo.one!(from s in PricingSnapshot, limit: 1)
    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(pricing_snapshot_id: referenced_snapshot.id)
      |> Repo.update!()

    assert {:ok, second} = OpenAIPricingImporter.import_file(@pricing_path)
    assert second.inserted == 0
    assert second.skipped == first.skipped

    assert Repo.get!(CodexPooler.Accounting.Attempt, attempt.id).pricing_snapshot_id ==
             referenced_snapshot.id

    assert pricing_count_for_version(first.price_version) == count_after_first
  end

  test "imports vendored gpt-5.6 output pricing separately from cache writes" do
    assert {:ok, _result} = OpenAIPricingImporter.import_file(@pricing_path)

    assert_gpt56_vendored_snapshot!("gpt-5.6-luna", %{
      input: "1.0",
      cached_input: "0.1",
      output: "6.0",
      cache_write: 1.25
    })

    assert_gpt56_vendored_snapshot!("gpt-5.6-terra", %{
      input: "2.5",
      cached_input: "0.25",
      output: "15.0",
      cache_write: 3.125
    })

    assert_gpt56_vendored_snapshot!("gpt-5.6-sol", %{
      input: "5.0",
      cached_input: "0.5",
      output: "30.0",
      cache_write: 6.25
    })
  end

  test "maps decimals, config dimensions, and reasoning fallback correctly" do
    path =
      write_tmp_json!(%{
        "generated_at" => "2026-04-30T17:21:57.551899Z",
        "models" => %{
          "fractional-model" => %{
            "model" => "fractional-model",
            "pricing_type" => "per_1m_tokens",
            "category" => "language_model",
            "categories" => ["language_model"],
            "prices" => %{
              "standard" => %{
                "default" => %{
                  "input" => Decimal.new("0.0125"),
                  "cached_input" => Decimal.new("0.2"),
                  "output" => Decimal.new("2.5")
                },
                "long_context" => %{
                  "input" => Decimal.new("0.025"),
                  "cached_input" => Decimal.new("0.4"),
                  "output" => Decimal.new("3.75")
                }
              }
            }
          }
        }
      })

    assert {:ok, _result} = OpenAIPricingImporter.import_file(path)

    snapshot =
      Repo.one!(
        from s in PricingSnapshot,
          where:
            s.model_identifier == "fractional-model" and
              fragment("?->>'price_bucket'", s.config) == "default"
      )

    long_context_snapshot =
      Repo.one!(
        from s in PricingSnapshot,
          where:
            s.model_identifier == "fractional-model" and
              fragment("?->>'price_bucket'", s.config) == "long_context"
      )

    assert Decimal.equal?(snapshot.input_token_micros, Decimal.new("0.0125"))
    assert Decimal.equal?(snapshot.cached_input_token_micros, Decimal.new("0.2"))
    assert Decimal.equal?(snapshot.output_token_micros, Decimal.new("2.5"))
    assert Decimal.equal?(snapshot.reasoning_token_micros, Decimal.new("2.5"))
    assert Decimal.equal?(snapshot.request_base_micros, Decimal.new(0))

    assert snapshot.config["source"] == "openai-json-pricing"
    assert snapshot.config["source_generated_at"] == "2026-04-30T17:21:57.551899Z"
    assert snapshot.config["service_tier"] == "standard"
    assert snapshot.config["price_bucket"] == "default"
    assert snapshot.config["pricing_type"] == "per_1m_tokens"
    assert snapshot.config["category"] == "language_model"
    assert snapshot.config["categories"] == ["language_model"]
    assert snapshot.config["reasoning_price_source"] == "output_fallback"

    assert Decimal.equal?(long_context_snapshot.input_token_micros, Decimal.new("0.025"))
    assert Decimal.equal?(long_context_snapshot.cached_input_token_micros, Decimal.new("0.4"))
    assert Decimal.equal?(long_context_snapshot.output_token_micros, Decimal.new("3.75"))
    assert long_context_snapshot.config["service_tier"] == "standard"
    assert long_context_snapshot.config["price_bucket"] == "long_context"
    assert long_context_snapshot.config["availability"] == "priced"
  end

  test "imports optional cache-write rates per service tier and price bucket" do
    path =
      write_tmp_json!(%{
        "generated_at" => "2026-07-12T10:00:00Z",
        "models" => %{
          "cache-write-priced-model" => %{
            "model" => "cache-write-priced-model",
            "pricing_type" => "per_1m_tokens",
            "prices" => %{
              "standard" => %{
                "default" => %{
                  "input" => 2,
                  "cached_input" => 0.2,
                  "cache_write" => 2.5,
                  "output" => 10
                },
                "long_context" => %{
                  "input" => 4,
                  "cached_input" => 0.4,
                  "cache_write" => 5,
                  "output" => 15
                }
              },
              "priority" => %{
                "default" => %{
                  "input" => 3,
                  "cached_input" => 0.3,
                  "output" => 12
                }
              }
            }
          }
        }
      })

    assert {:ok, _result} = OpenAIPricingImporter.import_file(path)

    snapshots =
      Repo.all(
        from s in PricingSnapshot,
          where: s.model_identifier == "cache-write-priced-model"
      )

    snapshot_by_dimension =
      Map.new(snapshots, &{{&1.config["service_tier"], &1.config["price_bucket"]}, &1})

    assert default_rate =
             Map.get(snapshot_by_dimension[{"standard", "default"}], :cache_write_token_micros)

    assert Decimal.equal?(default_rate, Decimal.new("2.5"))

    assert long_context_rate =
             Map.get(
               snapshot_by_dimension[{"standard", "long_context"}],
               :cache_write_token_micros
             )

    assert Decimal.equal?(long_context_rate, Decimal.new("5"))

    assert is_nil(
             Map.get(snapshot_by_dimension[{"priority", "default"}], :cache_write_token_micros)
           )
  end

  test "same generated_at re-import corrects an existing catalog revision" do
    generated_at =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    first_snapshot = seed_legacy_pricing_revision!(generated_at, 2.5)

    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(pricing_snapshot_id: first_snapshot.id)
      |> Repo.update!()

    assert {:ok, first_import} =
             OpenAIPricingImporter.import_file(pricing_revision_path(generated_at, 3.25))

    assert first_import.inserted == 1
    assert first_import.price_version == "#{generated_at}:importer-format-1"

    assert {:ok, retry_import} =
             OpenAIPricingImporter.import_file(pricing_revision_path(generated_at, 3.25))

    assert retry_import.inserted == 0
    assert retry_import.price_version == first_import.price_version

    snapshots =
      Repo.all(
        from s in PricingSnapshot,
          where:
            s.model_identifier == "corrected-cache-write-model" and
              fragment("?->>'source_generated_at'", s.config) == ^generated_at,
          order_by: [asc: s.config]
      )

    assert length(snapshots) == 2

    original_snapshot = Enum.find(snapshots, &(&1.id == first_snapshot.id))

    corrected_snapshot =
      Enum.find(snapshots, fn snapshot ->
        snapshot.id != first_snapshot.id and
          is_integer(snapshot.config["importer_format_revision"])
      end)

    assert corrected_snapshot
    assert original_snapshot.id == first_snapshot.id
    assert original_snapshot.price_version == generated_at

    assert DateTime.compare(
             original_snapshot.effective_at,
             elem(DateTime.from_iso8601(generated_at), 1)
           ) ==
             :eq

    refute Map.has_key?(original_snapshot.config, "importer_format_revision")
    assert original_snapshot.price_version != corrected_snapshot.price_version
    assert corrected_snapshot.price_version == first_import.price_version
    assert corrected_snapshot.effective_at == original_snapshot.effective_at
    assert original_rate = original_snapshot.cache_write_token_micros
    assert Decimal.equal?(original_rate, Decimal.new("2.5"))
    assert corrected_rate = Map.get(corrected_snapshot, :cache_write_token_micros)
    assert Decimal.equal?(corrected_rate, Decimal.new("3.25"))

    assert Repo.get!(CodexPooler.Accounting.Attempt, attempt.id).pricing_snapshot_id ==
             original_snapshot.id

    model =
      model_fixture(setup.pool, %{
        exposed_model_id: "corrected-cache-write-model",
        upstream_model_id: "corrected-cache-write-model"
      })

    assert {:ok, reserved} =
             Accounting.reserve(
               %{pool: setup.pool, api_key: setup.api_key},
               model,
               %{"model" => model.exposed_model_id, "max_output_tokens" => 1},
               %{correlation_id: "corr-current-importer-revision"}
             )

    assert reserved.pricing_snapshot.id == corrected_snapshot.id
  end

  test "malformed and negative cache-write rates fail without persisting rows" do
    Enum.each(["not-a-number", -0.01], fn cache_write ->
      model_identifier = "invalid-cache-write-#{System.unique_integer([:positive])}"
      count_before = Repo.aggregate(PricingSnapshot, :count)

      assert {:error, %{code: :invalid_price_row}} =
               OpenAIPricingImporter.import_file(cache_write_path(model_identifier, cache_write))

      assert Repo.aggregate(PricingSnapshot, :count) == count_before

      refute Repo.exists?(
               from s in PricingSnapshot, where: s.model_identifier == ^model_identifier
             )
    end)
  end

  test "imports explicit unavailable pricing buckets as unpriced markers" do
    path =
      write_tmp_json!(%{
        "generated_at" => "2026-06-15T04:50:14.549006Z",
        "models" => %{
          "unavailable-long-context-model" => %{
            "model" => "unavailable-long-context-model",
            "pricing_type" => "per_1m_tokens",
            "category" => "language_model",
            "categories" => ["language_model"],
            "prices" => %{
              "priority" => %{
                "default" => %{
                  "cached_input" => Decimal.new("0.5"),
                  "input" => Decimal.new("5.0"),
                  "output" => Decimal.new("30.0")
                },
                "long_context" => %{
                  "available" => false
                }
              }
            }
          }
        }
      })

    assert {:ok, result} = OpenAIPricingImporter.import_file(path)
    assert result.inserted == 2
    assert result.skipped == 0

    marker =
      Repo.one!(
        from s in PricingSnapshot,
          where:
            s.model_identifier == "unavailable-long-context-model" and
              fragment("?->>'service_tier'", s.config) == "priority" and
              fragment("?->>'price_bucket'", s.config) == "long_context"
      )

    assert is_nil(marker.input_token_micros)
    assert is_nil(marker.cached_input_token_micros)
    assert is_nil(marker.output_token_micros)
    assert is_nil(marker.reasoning_token_micros)
    assert is_nil(marker.request_base_micros)
    assert marker.config["availability"] == "unavailable"
  end

  test "skips unsupported pricing_type and missing default buckets" do
    path =
      write_tmp_json!(%{
        "generated_at" => "2026-04-30T17:21:57.551899Z",
        "models" => %{
          "skipped-by-type" => %{
            "model" => "skipped-by-type",
            "pricing_type" => "per_minute",
            "prices" => %{}
          },
          "skipped-by-bucket" => %{
            "model" => "skipped-by-bucket",
            "pricing_type" => "per_1m_tokens",
            "prices" => %{
              "standard" => %{"text" => %{"input" => Decimal.new(1), "output" => Decimal.new(2)}}
            }
          }
        }
      })

    assert {:ok, result} = OpenAIPricingImporter.import_file(path)
    assert result.inserted == 0
    assert result.skipped == 2
    refute Repo.exists?(from s in PricingSnapshot, where: s.model_identifier == "skipped-by-type")

    refute Repo.exists?(
             from s in PricingSnapshot, where: s.model_identifier == "skipped-by-bucket"
           )
  end

  test "invalid json returns controlled error and leaves existing snapshots untouched" do
    existing = seed_existing_snapshot!("preserve-invalid-json")
    count_before = Repo.aggregate(PricingSnapshot, :count)

    path =
      Path.join(System.tmp_dir!(), "pricing-invalid-#{System.unique_integer([:positive])}.json")

    File.write!(path, "{not-json")

    assert {:error, %{code: :invalid_json}} = OpenAIPricingImporter.import_file(path)
    assert Repo.get(PricingSnapshot, existing.id)
    assert Repo.aggregate(PricingSnapshot, :count) == count_before
  end

  test "missing file returns controlled file_read_failed error" do
    assert {:error, %{code: :file_read_failed, message: message}} =
             OpenAIPricingImporter.import_file("priv/pricing/openai/missing.json")

    assert is_binary(message)
    assert message != ""
  end

  test "malformed price row returns controlled error and rolls back replacement" do
    existing = seed_existing_snapshot!("preserve-malformed-row")
    count_before = Repo.aggregate(PricingSnapshot, :count)

    path =
      write_tmp_json!(%{
        "generated_at" => "2026-04-30T17:21:57.551899Z",
        "models" => %{
          "bad-model" => %{
            "model" => "bad-model",
            "pricing_type" => "per_1m_tokens",
            "prices" => %{
              "standard" => %{"default" => %{"input" => "oops", "output" => Decimal.new(2)}}
            }
          }
        }
      })

    assert {:error, %{code: :invalid_price_row}} = OpenAIPricingImporter.import_file(path)
    assert Repo.get(PricingSnapshot, existing.id)
    assert Repo.aggregate(PricingSnapshot, :count) == count_before
    refute Repo.exists?(from s in PricingSnapshot, where: s.model_identifier == "bad-model")
  end

  defp pricing_count_for_version(price_version) do
    Repo.aggregate(
      from(s in PricingSnapshot,
        where: s.price_version == ^price_version
      ),
      :count
    )
  end

  defp vendored_price_version do
    @pricing_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("generated_at")
  end

  defp current_price_version(source_generated_at),
    do: "#{source_generated_at}:importer-format-1"

  defp assert_gpt56_vendored_snapshot!(model, expected) do
    payload = @pricing_path |> File.read!() |> Jason.decode!()
    source_prices = get_in(payload, ["models", model, "prices", "standard", "default"])

    assert source_prices["cache_write"] == expected.cache_write
    assert source_prices["cache_write"] != source_prices["output"]

    snapshot =
      Repo.one!(
        from s in PricingSnapshot,
          where:
            fragment("?->>'source_generated_at'", s.config) == ^vendored_price_version() and
              s.model_identifier == ^model and
              fragment("?->>'service_tier'", s.config) == "standard" and
              fragment("?->>'price_bucket'", s.config) == "default"
      )

    assert Decimal.equal?(snapshot.input_token_micros, Decimal.new(expected.input))
    assert Decimal.equal?(snapshot.cached_input_token_micros, Decimal.new(expected.cached_input))

    assert Decimal.equal?(
             snapshot.cache_write_token_micros,
             Decimal.from_float(expected.cache_write)
           )

    assert Decimal.equal?(snapshot.output_token_micros, Decimal.new(expected.output))
    assert Decimal.equal?(snapshot.reasoning_token_micros, Decimal.new(expected.output))
  end

  defp seed_existing_snapshot!(suffix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: "existing-#{suffix}",
      price_version: "existing-version-#{suffix}",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(1),
      cached_input_token_micros: Decimal.new(0),
      output_token_micros: Decimal.new(1),
      reasoning_token_micros: Decimal.new(1),
      request_base_micros: Decimal.new(0),
      effective_at: now,
      source_url: "seed",
      captured_at: now,
      config: %{"seed" => true}
    }
    |> Repo.insert!()
  end

  defp write_tmp_json!(payload) do
    path =
      Path.join(System.tmp_dir!(), "pricing-importer-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(payload))
    path
  end

  defp pricing_revision_path(generated_at, cache_write) do
    write_tmp_json!(%{
      "generated_at" => generated_at,
      "models" => %{
        "corrected-cache-write-model" => %{
          "model" => "corrected-cache-write-model",
          "pricing_type" => "per_1m_tokens",
          "prices" => %{
            "standard" => %{
              "default" => %{
                "input" => 2,
                "cached_input" => 0.2,
                "cache_write" => cache_write,
                "output" => 10
              }
            }
          }
        }
      }
    })
  end

  defp seed_legacy_pricing_revision!(generated_at, cache_write) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {:ok, effective_at, _offset} = DateTime.from_iso8601(generated_at)
    effective_at = %DateTime{effective_at | microsecond: {0, 6}}

    %PricingSnapshot{
      model_identifier: "corrected-cache-write-model",
      price_version: generated_at,
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(2),
      cached_input_token_micros: Decimal.new("0.2"),
      output_token_micros: Decimal.new(10),
      reasoning_token_micros: Decimal.new(10),
      request_base_micros: Decimal.new(0),
      effective_at: effective_at,
      source_url: "legacy-importer",
      captured_at: now,
      config: %{
        "source" => "openai-json-pricing",
        "source_generated_at" => generated_at,
        "service_tier" => "standard",
        "price_bucket" => "default",
        "pricing_type" => "per_1m_tokens",
        "availability" => "priced",
        "legacy_cache_write_token_micros" => to_string(cache_write)
      }
    }
    |> Map.put(:cache_write_token_micros, Decimal.from_float(cache_write))
    |> Repo.insert!()
  end

  defp cache_write_path(model_identifier, cache_write) do
    write_tmp_json!(%{
      "generated_at" => "2026-07-12T12:00:00Z",
      "models" => %{
        model_identifier => %{
          "model" => model_identifier,
          "pricing_type" => "per_1m_tokens",
          "prices" => %{
            "standard" => %{
              "default" => %{
                "input" => 2,
                "cached_input" => 0.2,
                "cache_write" => cache_write,
                "output" => 10
              }
            }
          }
        }
      }
    })
  end
end
