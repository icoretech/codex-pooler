defmodule CodexPooler.Catalog.OpenAIPricingImporterTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog.{OpenAIPricingImporter, PricingSnapshot}
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.PoolerFixtures

  @fixture Path.expand("../../fixtures/pricing/openai/2026-07-28.json", __DIR__)
  @target Path.expand("../../../priv/pricing/openai/pricing.json", __DIR__)
  @target_sha256 "6f60a5009b16b872429682b2c74548b152abbe7ab6b3664bad4900ed308c18ca"
  @target_generated_at "2026-07-31T05:10:03.599675Z"
  @removed_identifiers [
    "computer-use-preview",
    "gpt-3.5-0301",
    "gpt-3.5-turbo-0613",
    "gpt-3.5-turbo-16k-0613",
    "gpt-4-0125-preview",
    "gpt-4-0314",
    "gpt-4-1106-preview",
    "gpt-4-1106-vision-preview",
    "gpt-4-32k",
    "gpt-4o-audio-preview",
    "gpt-4o-mini-audio-preview",
    "gpt-4o-mini-realtime-preview",
    "gpt-4o-mini-search-preview",
    "gpt-4o-realtime-preview",
    "gpt-4o-search-preview",
    "gpt-5-chat-latest",
    "gpt-5-codex",
    "gpt-5.1-chat-latest",
    "gpt-5.1-codex",
    "gpt-5.1-codex-max",
    "gpt-5.1-codex-mini",
    "gpt-5.2-codex",
    "o1-mini",
    "o3-deep-research",
    "o4-mini-deep-research"
  ]
  @reviewed_rates %{
    "gpt-5.6-luna" => %{
      "standard" => ["0.2", "0.02", "0.25", "1.2"],
      "fast" => ["0.4", "0.04", "0.5", "2.4"]
    },
    "gpt-5.6-terra" => %{
      "standard" => ["2.0", "0.2", "2.5", "12.0"],
      "fast" => ["4.0", "0.4", "5.0", "24.0"]
    },
    "gpt-5.6-sol" => %{
      "standard" => ["5.0", "0.5", "6.25", "30.0"],
      "fast" => ["10.0", "1.0", "12.5", "60.0"]
    }
  }
  @barrier_timeout 5_000
  @actor_timeout 10_000

  test "imports revision 2 rows from the immutable fixture idempotently" do
    assert {:ok, first} = OpenAIPricingImporter.import_file(@fixture)
    assert first.price_version == "2026-07-28T17:25:03.915713Z:importer-format-2"
    assert first.inserted == 208
    assert first.skipped == 90

    assert {:ok, second} = OpenAIPricingImporter.import_file(@fixture)
    assert second.inserted == 0
    assert second.skipped == 90

    rows =
      Repo.all(
        from snapshot in PricingSnapshot, where: snapshot.price_version == ^first.price_version
      )

    assert length(rows) == 208
    assert Enum.all?(rows, &(&1.config["importer_format_revision"] == "2"))
    refute Enum.any?(rows, &(&1.config["service_tier"] == "fast"))
  end

  test "imports the reviewed July 31 target as canonical revision 2 rows" do
    payload = @target |> File.read!() |> Jason.decode!()

    assert Map.keys(payload["models"]) |> Enum.filter(&(&1 in @removed_identifiers)) == []

    Enum.each(@reviewed_rates, fn {identifier, tiers} ->
      Enum.each(tiers, fn {tier, expected} ->
        assert source_rates(payload, identifier, tier) == Enum.map(expected, &Decimal.new/1)
      end)
    end)

    assert {:ok, first} = OpenAIPricingImporter.import_file(@target)
    assert first.price_version == "#{@target_generated_at}:importer-format-2"
    assert first.inserted == 171
    assert first.skipped == 82

    rows =
      Repo.all(
        from snapshot in PricingSnapshot, where: snapshot.price_version == ^first.price_version
      )

    assert length(rows) == 171
    assert Enum.all?(rows, &(&1.config["importer_format_revision"] == "2"))
    refute Enum.any?(rows, &(&1.config["service_tier"] == "fast"))
    refute Enum.any?(rows, &(&1.model_identifier in @removed_identifiers))

    Enum.each(@reviewed_rates, fn {identifier, tiers} ->
      assert_snapshot_rates(rows, identifier, "standard", tiers["standard"])
      assert_snapshot_rates(rows, identifier, "priority", tiers["fast"])
    end)

    assert {:ok, %{inserted: 0, skipped: 82}} = OpenAIPricingImporter.import_file(@target)
  end

  test "target checksum, exact rates, removals, and schema descriptors detect drift" do
    raw = File.read!(@target)
    payload = Jason.decode!(raw)
    expected_rates = @reviewed_rates["gpt-5.6-luna"]["fast"] |> Enum.map(&Decimal.new/1)

    one_byte_path = write_raw!(raw <> " ")
    refute file_sha256(one_byte_path) == @target_sha256

    rate_mutation =
      put_in(payload, ["models", "gpt-5.6-luna", "prices", "fast", "default", "input"], 9)

    rate_path = write_json!(rate_mutation)

    refute source_rates(Jason.decode!(File.read!(rate_path)), "gpt-5.6-luna", "fast") ==
             expected_rates

    removal_mutation =
      payload
      |> put_in(["models", hd(@removed_identifiers)], payload["models"]["babbage-002"])
      |> put_in(["models", hd(@removed_identifiers), "model"], hd(@removed_identifiers))
      |> Map.put("models_count", 80)

    removal_path = write_json!(removal_mutation)

    assert Map.keys(Jason.decode!(File.read!(removal_path))["models"])
           |> Enum.filter(&(&1 in @removed_identifiers)) == [hd(@removed_identifiers)]

    schema_mutation =
      put_in(
        payload,
        ["models", "gpt-4o-mini-transcribe", "prices", "standard", "transcription"],
        %{"estimated_cost" => nil}
      )

    count = Repo.aggregate(PricingSnapshot, :count)

    assert {:error, %{code: :incompatible_pricing_catalog}} =
             OpenAIPricingImporter.import_file(write_json!(schema_mutation))

    assert Repo.aggregate(PricingSnapshot, :count) == count
  end

  test "equal fast and priority aliases emit one canonical row with Decimal equality" do
    payload =
      valid_payload("alias-model", %{
        "fast" => %{
          "default" => %{
            "input" => 1.0,
            "cached_input" => 0.1,
            "cache_write" => 1.25,
            "output" => 2.0
          }
        },
        "priority" => %{
          "default" => %{
            "input" => 1,
            "cached_input" => 0.1,
            "cache_write" => 1.25,
            "output" => 2
          }
        }
      })

    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(write_json!(payload))

    assert snapshot =
             Repo.one(from row in PricingSnapshot, where: row.model_identifier == "alias-model")

    assert snapshot.config["service_tier"] == "priority"
    assert Decimal.equal?(snapshot.cache_write_token_micros, Decimal.new("1.25"))
  end

  test "divergent aliases return bounded conflict and write nothing" do
    payload =
      valid_payload("alias-conflict", %{
        "fast" => %{"default" => %{"input" => 1, "output" => 2}},
        "priority" => %{"default" => %{"input" => 1, "output" => 3}}
      })

    count = Repo.aggregate(PricingSnapshot, :count)

    assert {:error, %{code: :conflicting_service_tier_alias, message: message}} =
             OpenAIPricingImporter.import_file(write_json!(payload))

    assert message == "fast and priority pricing aliases conflict"
    assert Repo.aggregate(PricingSnapshot, :count) == count
  end

  test "asymmetric fast and priority bucket collections conflict in both directions without writes" do
    base = %{"default" => %{"input" => 1, "output" => 2}}
    extra = Map.put(base, "long_context", %{"input" => 3, "output" => 4})

    Enum.each([{base, extra}, {extra, base}], fn {fast, priority} ->
      identifier = "alias-asymmetric-#{System.unique_integer([:positive])}"
      payload = valid_payload(identifier, %{"fast" => fast, "priority" => priority})
      count = Repo.aggregate(PricingSnapshot, :count)

      assert {:error, %{code: :conflicting_service_tier_alias}} =
               OpenAIPricingImporter.import_file(write_json!(payload))

      assert Repo.aggregate(PricingSnapshot, :count) == count
      refute Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
    end)
  end

  test "fast and priority aliases compare every independently variable pricing semantic" do
    base = %{
      "input" => 1,
      "cached_input" => 0.5,
      "cache_write" => 1.5,
      "output" => 2,
      "reasoning" => 2
    }

    mutations = [
      input: &Map.put(&1, "input", 9),
      cached_input: &Map.put(&1, "cached_input", 9),
      cache_write: &Map.put(&1, "cache_write", 9),
      output: &Map.put(&1, "output", 9),
      reasoning: &Map.put(&1, "reasoning", 9),
      availability: fn _values -> %{"available" => false} end,
      reasoning_price_source: fn values -> Map.delete(values, "reasoning") end
    ]

    Enum.each(mutations, fn {field, mutate} ->
      identifier = "alias-semantic-#{field}"

      payload =
        valid_payload(identifier, %{
          "fast" => %{"default" => base},
          "priority" => %{"default" => mutate.(base)}
        })

      assert {:error, %{code: :conflicting_service_tier_alias}} =
               OpenAIPricingImporter.import_file(write_json!(payload)),
             "expected #{field} divergence to conflict"

      refute Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
    end)
  end

  test "unsupported pricing types reject extra tiers before any candidate write" do
    cases = [
      unsupported_payload("mixed-extra", "mixed", ["per_1m_tokens", "per_minute"], %{
        "standard" => %{"audio" => %{"output" => 1}},
        "priority" => %{"ignored" => %{"arbitrary" => true}}
      }),
      unsupported_payload("minute-extra", "per_minute", ["per_minute"], %{
        "standard" => %{"transcription" => %{"estimated_cost" => 1}},
        "batch" => %{"transcription" => %{"estimated_cost" => 1}}
      }),
      unsupported_payload("minute-malformed", "per_minute", ["per_minute"], %{
        "standard" => %{"transcription" => %{"estimated_cost" => 1}},
        "priority" => %{"transcription" => %{"estimated_cost" => nil}}
      }),
      unsupported_payload("second-extra", "per_second", ["per_second"], %{
        "priority" => %{
          "720p" => %{
            "landscape" => "1280x720",
            "portrait" => "720x1280",
            "price_per_second" => 1
          }
        }
      })
    ]

    Enum.each(cases, fn payload ->
      count = Repo.aggregate(PricingSnapshot, :count)

      assert {:error, %{code: :incompatible_pricing_catalog}} =
               OpenAIPricingImporter.import_file(write_json!(payload))

      assert Repo.aggregate(PricingSnapshot, :count) == count
    end)
  end

  test "duplicate raw JSON keys and normalized model collisions fail without writes" do
    duplicate =
      String.replace(
        Jason.encode!(valid_payload()),
        ~s("tools_count":1),
        ~s("tools_count":1,"tools_count":1)
      )

    assert {:error, %{code: :invalid_json}} =
             OpenAIPricingImporter.import_file(write_raw!(duplicate))

    payload = valid_payload()
    model = payload["models"]["sample-model"]

    collision = %{
      payload
      | "models" => %{"sample-model" => model, " SAMPLE-MODEL " => model},
        "models_count" => 2
    }

    assert {:error, %{code: :incompatible_pricing_catalog}} =
             OpenAIPricingImporter.import_file(write_json!(collision))

    refute Repo.exists?(
             from row in PricingSnapshot, where: row.model_identifier == "sample-model"
           )
  end

  test "revision 2 canonical import preserves revision 1 fast rows and attempt references" do
    generated_at = "2026-07-30T10:00:00Z"
    legacy = seed_snapshot!("revision-model", generated_at, "fast", "1", 2)

    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)

    attempt =
      setup
      |> request_fixture()
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(pricing_snapshot_id: legacy.id)
      |> Repo.update!()

    payload =
      valid_payload(
        "revision-model",
        %{"fast" => %{"default" => %{"input" => 1, "output" => 2}}},
        generated_at
      )

    assert {:ok, %{inserted: 1, price_version: version}} =
             OpenAIPricingImporter.import_file(write_json!(payload))

    assert version == "#{generated_at}:importer-format-2"
    assert Repo.get!(PricingSnapshot, legacy.id).config["service_tier"] == "fast"
    assert Repo.get!(CodexPooler.Accounting.Attempt, attempt.id).pricing_snapshot_id == legacy.id

    assert Repo.one!(from row in PricingSnapshot, where: row.price_version == ^version).config[
             "service_tier"
           ] == "priority"

    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(payload))
  end

  test "newer catalog omission preserves historical snapshots and attempt foreign keys" do
    parent_at = "2026-07-30T10:00:00Z"
    child_at = "2026-07-31T10:00:00Z"
    parent = payload_with_models(parent_at, ["retained-model", "removed-model"])
    child = payload_with_models(child_at, ["retained-model"])

    assert {:ok, %{inserted: 2, price_version: parent_version}} =
             OpenAIPricingImporter.import_file(write_json!(parent))

    removed =
      Repo.one!(
        from row in PricingSnapshot,
          where: row.model_identifier == "removed-model" and row.price_version == ^parent_version
      )

    frozen =
      Map.take(removed, [
        :id,
        :price_version,
        :config,
        :input_token_micros,
        :cached_input_token_micros,
        :cache_write_token_micros,
        :output_token_micros,
        :reasoning_token_micros,
        :request_base_micros,
        :effective_at,
        :captured_at
      ])

    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)

    attempt =
      setup
      |> request_fixture()
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(pricing_snapshot_id: removed.id)
      |> Repo.update!()

    assert {:ok, %{inserted: 1, price_version: child_version}} =
             OpenAIPricingImporter.import_file(write_json!(child))

    refute Repo.exists?(
             from row in PricingSnapshot,
               where:
                 row.model_identifier == "removed-model" and row.price_version == ^child_version
           )

    assert Map.take(Repo.get!(PricingSnapshot, removed.id), Map.keys(frozen)) == frozen
    assert Repo.get!(CodexPooler.Accounting.Attempt, attempt.id).pricing_snapshot_id == removed.id

    assert Repo.aggregate(
             from(row in PricingSnapshot,
               where: row.model_identifier in ["retained-model", "removed-model"]
             ),
             :count
           ) == 3

    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(child))
  end

  test "identical unique-index winner reload is idempotent while divergent winner is bounded and rolls back" do
    payload =
      valid_payload("winner-model", %{
        "standard" => %{"default" => %{"input" => 1, "output" => 2}}
      })

    path = write_json!(payload)
    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(path)
    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(path)

    winner = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == "winner-model")

    Repo.update_all(from(row in PricingSnapshot, where: row.id == ^winner.id),
      set: [output_token_micros: Decimal.new(99)]
    )

    count = Repo.aggregate(PricingSnapshot, :count)

    assert {:error, %{code: :concurrent_pricing_conflict}} =
             OpenAIPricingImporter.import_file(path)

    assert Repo.aggregate(PricingSnapshot, :count) == count

    assert Decimal.equal?(
             Repo.get!(PricingSnapshot, winner.id).output_token_micros,
             Decimal.new(99)
           )
  end

  test "concurrent winner comparison rejects every mutable pricing-semantic field" do
    mutations = [
      currency_code: fn snapshot -> Ecto.Changeset.change(snapshot, currency_code: "EUR") end,
      billing_unit: fn snapshot -> Ecto.Changeset.change(snapshot, billing_unit: "request") end,
      input: fn snapshot ->
        Ecto.Changeset.change(snapshot, input_token_micros: Decimal.new(9))
      end,
      cached_input: fn snapshot ->
        Ecto.Changeset.change(snapshot, cached_input_token_micros: Decimal.new(9))
      end,
      cache_write: fn snapshot ->
        Ecto.Changeset.change(snapshot, cache_write_token_micros: Decimal.new(9))
      end,
      output: fn snapshot ->
        Ecto.Changeset.change(snapshot, output_token_micros: Decimal.new(9))
      end,
      reasoning: fn snapshot ->
        Ecto.Changeset.change(snapshot, reasoning_token_micros: Decimal.new(9))
      end,
      request_base: fn snapshot ->
        Ecto.Changeset.change(snapshot, request_base_micros: Decimal.new(9))
      end,
      effective_at: fn snapshot ->
        Ecto.Changeset.change(snapshot,
          effective_at: DateTime.add(snapshot.effective_at, 1, :second)
        )
      end,
      availability: &change_config(&1, "availability", "unavailable"),
      pricing_type: &change_config(&1, "pricing_type", "different"),
      category: &change_config(&1, "category", "different"),
      categories: &change_config(&1, "categories", ["different"]),
      reasoning_price_source: &change_config(&1, "reasoning_price_source", "different")
    ]

    Enum.each(mutations, fn {field, mutate} ->
      identifier = "winner-semantic-#{field}"

      payload =
        valid_payload(identifier, %{
          "standard" => %{
            "default" => %{
              "input" => 1,
              "cached_input" => 0.5,
              "cache_write" => 1.5,
              "output" => 2,
              "reasoning" => 2
            }
          }
        })

      path = write_json!(payload)
      assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(path)
      winner = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
      mutated = winner |> mutate.() |> Repo.update!()
      count = Repo.aggregate(PricingSnapshot, :count)

      assert {:error, %{code: :concurrent_pricing_conflict}} =
               OpenAIPricingImporter.import_file(path),
             "expected #{field} divergence to conflict"

      assert Repo.aggregate(PricingSnapshot, :count) == count

      assert persisted_snapshot_fields(Repo.get!(PricingSnapshot, winner.id)) ==
               persisted_snapshot_fields(mutated)
    end)
  end

  test "concurrent winner comparison ignores capture and source provenance only" do
    identifier = "winner-provenance"
    payload = valid_payload(identifier)
    first_path = write_json!(payload)
    second_path = write_json!(payload)

    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(first_path)
    winner = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier)

    changed_config = Map.put(winner.config, "source_path", "different-provenance")

    winner
    |> Ecto.Changeset.change(
      captured_at: DateTime.add(winner.captured_at, 1, :second),
      source_url: "different-source",
      config: changed_config
    )
    |> Repo.update!()

    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(second_path)

    assert Repo.aggregate(
             from(row in PricingSnapshot, where: row.model_identifier == ^identifier),
             :count
           ) == 1
  end

  test "simultaneous identical imports wait on the unique index and accept the committed winner" do
    identifier = "race-identical-#{System.unique_integer([:positive])}"
    path = write_json!(valid_payload(identifier))
    on_exit(fn -> cleanup_unboxed_snapshots([identifier]) end)

    assert %{first: {:ok, %{inserted: 1}}, second: {:ok, %{inserted: 0}}} =
             run_concurrent_imports(path, path)

    assert unboxed_snapshot_count([identifier]) == 1
  end

  test "later divergent unique conflict rolls back an earlier candidate insert" do
    unique = System.unique_integer([:positive])
    first_identifier = "a-race-first-#{unique}"
    conflict_identifier = "z-race-conflict-#{unique}"
    on_exit(fn -> cleanup_unboxed_snapshots([first_identifier, conflict_identifier]) end)

    winner = valid_payload(conflict_identifier)

    winner =
      put_in(
        winner,
        ["models", conflict_identifier, "prices", "standard", "default", "output"],
        99
      )

    candidate =
      payload_with_models("2026-07-28T00:00:00Z", [first_identifier, conflict_identifier])

    assert %{
             first: {:ok, %{inserted: 1}},
             second: {:error, %{code: :concurrent_pricing_conflict}}
           } =
             run_concurrent_imports(
               write_json!(winner),
               write_json!(candidate)
             )

    refute unboxed_snapshot_exists?(first_identifier)
    assert unboxed_snapshot_count([conflict_identifier]) == 1

    assert Decimal.equal?(
             unboxed_snapshot!(conflict_identifier).output_token_micros,
             Decimal.new(99)
           )
  end

  test "an invalid later row leaves existing snapshots untouched and rolls back candidate writes" do
    existing = seed_snapshot!("existing-model", "2026-07-20T10:00:00Z", "standard", "1", 1)
    payload = payload_with_models("2026-07-31T10:00:00Z", ["first-model", "bad-model"])

    payload =
      put_in(payload, ["models", "bad-model", "prices", "standard", "default", "output"], -1)

    assert {:error, %{code: :incompatible_pricing_catalog}} =
             OpenAIPricingImporter.import_file(write_json!(payload))

    assert Repo.get!(PricingSnapshot, existing.id)

    refute Repo.exists?(
             from row in PricingSnapshot,
               where: row.model_identifier in ["first-model", "bad-model"]
           )
  end

  defp valid_payload(
         identifier \\ "sample-model",
         tiers \\ %{"standard" => %{"default" => %{"input" => 1, "output" => 2}}},
         generated_at \\ "2026-07-28T00:00:00Z"
       ) do
    payload_with_models(generated_at, [identifier])
    |> put_in(["models", identifier, "prices"], tiers)
  end

  defp payload_with_models(generated_at, identifiers) do
    models =
      Map.new(identifiers, fn identifier ->
        {identifier,
         %{
           "categories" => ["language_model"],
           "category" => "language_model",
           "model" => identifier,
           "prices" => %{"standard" => %{"default" => %{"input" => 1, "output" => 2}}},
           "pricing_type" => "per_1m_tokens",
           "pricing_types" => ["per_1m_tokens"],
           "timestamp" => generated_at
         }}
      end)

    %{
      "generated_at" => generated_at,
      "models" => models,
      "models_count" => map_size(models),
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
    payload = payload_with_models("2026-07-28T00:00:00Z", [identifier])

    payload
    |> put_in(["models", identifier, "category"], "other")
    |> put_in(["models", identifier, "categories"], ["other"])
    |> put_in(["models", identifier, "pricing_type"], pricing_type)
    |> put_in(["models", identifier, "pricing_types"], pricing_types)
    |> put_in(["models", identifier, "prices"], prices)
  end

  defp seed_snapshot!(identifier, generated_at, tier, revision, output) do
    {:ok, effective_at, _offset} = DateTime.from_iso8601(generated_at)
    effective_at = %DateTime{effective_at | microsecond: {elem(effective_at.microsecond, 0), 6}}
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: identifier,
      price_version: "#{generated_at}:importer-format-#{revision}",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(1),
      cached_input_token_micros: Decimal.new(0),
      output_token_micros: Decimal.new(output),
      reasoning_token_micros: Decimal.new(output),
      request_base_micros: Decimal.new(0),
      effective_at: effective_at,
      source_url: "seed",
      captured_at: now,
      config: %{
        "source" => "openai-json-pricing",
        "source_generated_at" => generated_at,
        "service_tier" => tier,
        "price_bucket" => "default",
        "pricing_type" => "per_1m_tokens",
        "category" => "language_model",
        "categories" => ["language_model"],
        "availability" => "priced",
        "reasoning_price_source" => "output_fallback",
        "importer_format_revision" => revision
      }
    }
    |> Repo.insert!()
  end

  defp change_config(snapshot, key, value) do
    Ecto.Changeset.change(snapshot, config: Map.put(snapshot.config, key, value))
  end

  defp source_rates(payload, identifier, tier) do
    bucket = get_in(payload, ["models", identifier, "prices", tier, "default"])

    Enum.map(["input", "cached_input", "cache_write", "output"], fn key ->
      bucket |> Map.fetch!(key) |> decimal_from_json_number()
    end)
  end

  defp decimal_from_json_number(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_from_json_number(value) when is_float(value), do: Decimal.from_float(value)

  defp assert_snapshot_rates(rows, identifier, tier, expected) do
    snapshot =
      Enum.find(rows, fn row ->
        row.model_identifier == identifier and row.config["service_tier"] == tier and
          row.config["price_bucket"] == "default"
      end)

    assert snapshot

    actual = [
      snapshot.input_token_micros,
      snapshot.cached_input_token_micros,
      snapshot.cache_write_token_micros,
      snapshot.output_token_micros
    ]

    assert Enum.zip_with(actual, expected, &Decimal.equal?(&1, Decimal.new(&2)))
           |> Enum.all?()
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp persisted_snapshot_fields(snapshot) do
    decimal_fields = [
      :input_token_micros,
      :cached_input_token_micros,
      :cache_write_token_micros,
      :output_token_micros,
      :reasoning_token_micros,
      :request_base_micros
    ]

    snapshot
    |> Map.take([
      :id,
      :model_identifier,
      :price_version,
      :currency_code,
      :billing_unit,
      :effective_at,
      :source_url,
      :captured_at,
      :config | decimal_fields
    ])
    |> Map.new(fn {field, value} ->
      if field in decimal_fields and match?(%Decimal{}, value),
        do: {field, Decimal.normalize(value)},
        else: {field, value}
    end)
  end

  defp run_concurrent_imports(first_path, second_path) do
    parent = self()
    barrier = make_ref()
    handler_id = "pricing-import-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if Process.get({__MODULE__, barrier}) == true and pricing_snapshot_insert?(metadata) do
            send(parent, {:pricing_winner_inserted, barrier})

            receive do
              {:release_pricing_winner, ^barrier} -> :ok
            after
              @actor_timeout -> raise "pricing winner release timed out"
            end
          end
        end,
        nil
      )

    first =
      Task.async(fn ->
        receive do
          {:start_pricing_winner, ^barrier} ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.checkout(fn ->
                Process.put({__MODULE__, barrier}, true)

                try do
                  OpenAIPricingImporter.import_file(first_path)
                after
                  Process.delete({__MODULE__, barrier})
                end
              end)
            end)
        end
      end)

    second_holder = {__MODULE__, barrier, :second_task}

    try do
      send(first.pid, {:start_pricing_winner, barrier})
      assert_receive {:pricing_winner_inserted, ^barrier}, @barrier_timeout

      second =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.checkout(fn ->
              %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
              send(parent, {:pricing_candidate_backend, barrier, backend_pid})
              OpenAIPricingImporter.import_file(second_path)
            end)
          end)
        end)

      Process.put(second_holder, second)
      assert_receive {:pricing_candidate_backend, ^barrier, candidate_backend}, @barrier_timeout
      assert_unique_insert_wait!(candidate_backend)
      send(first.pid, {:release_pricing_winner, barrier})

      %{first: Task.await(first, @actor_timeout), second: Task.await(second, @actor_timeout)}
    after
      :telemetry.detach(handler_id)
      send(first.pid, {:release_pricing_winner, barrier})
      shutdown_task(first)
      shutdown_task(Process.delete(second_holder))
    end
  end

  defp assert_unique_insert_wait!(backend_pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @barrier_timeout

    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1) FROM pg_stat_activity " <>
          "WHERE pid = $1 AND wait_event_type = 'Lock'",
        [backend_pid]
      )

    case rows do
      [[blocking_pids]] when blocking_pids != [] ->
        :ok

      _rows ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("pricing candidate backend #{backend_pid} did not wait on the unique index")
        else
          receive do
          after
            20 -> assert_unique_insert_wait!(backend_pid, deadline)
          end
        end
    end
  end

  defp pricing_snapshot_insert?(%{query: query}) when is_binary(query),
    do: String.contains?(query, ~s(INSERT INTO "pricing_snapshots"))

  defp pricing_snapshot_insert?(_metadata), do: false

  defp unboxed_snapshot_count(identifiers) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.aggregate(
        from(row in PricingSnapshot, where: row.model_identifier in ^identifiers),
        :count
      )
    end)
  end

  defp unboxed_snapshot_exists?(identifier) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
    end)
  end

  defp unboxed_snapshot!(identifier) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
    end)
  end

  defp cleanup_unboxed_snapshots(identifiers) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from row in PricingSnapshot, where: row.model_identifier in ^identifiers)
    end)
  end

  defp shutdown_task(%Task{pid: pid} = task) when is_pid(pid) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp shutdown_task(_task), do: :ok

  defp write_json!(payload), do: payload |> Jason.encode!() |> write_raw!()

  defp write_raw!(raw) do
    path =
      Path.join(System.tmp_dir!(), "pricing-importer-#{System.unique_integer([:positive])}.json")

    File.write!(path, raw)
    path
  end
end
