defmodule CodexPooler.Catalog.OpenAIPricingImporterTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog.{OpenAIPricingImporter, PricingSnapshot}
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  @fixture Path.expand("../../fixtures/pricing/openai/2026-07-28.json", __DIR__)

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

  defp write_json!(payload), do: payload |> Jason.encode!() |> write_raw!()

  defp write_raw!(raw) do
    path =
      Path.join(System.tmp_dir!(), "pricing-importer-#{System.unique_integer([:positive])}.json")

    File.write!(path, raw)
    path
  end
end
