defmodule CodexPooler.Catalog.OpenAIPricingImporterTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.{OpenAIPricingImporter, OpenAIPricingPreflight, PricingSnapshot}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.UpstreamConnPoolTelemetry
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]
  import CodexPooler.PoolerFixtures

  @fixture Path.expand("../../fixtures/pricing/openai/2026-07-28.json", __DIR__)
  @target Path.expand("../../../priv/pricing/openai/pricing.json", __DIR__)
  @barrier_timeout 5_000
  @actor_timeout 10_000

  defmodule GenericExceptionAdapter do
    def run(request) do
      {request, %Req.HTTPError{protocol: :http1, reason: "credential-bearing transport detail"}}
    end
  end

  test "duration-specific cache write rates are immutable and idempotent snapshot semantics" do
    identifier = "gpt-example-cache-writes"
    path = ["models", identifier, "prices", "standard", "default"]
    rates = %{"input" => 1, "cached_input" => 0.1, "output" => 2, "cache_write_30m" => 1.25, "cache_write_12h" => 2.5}
    payload = put_in(v2_payload(identifier), path, rates)
    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(write_json!(payload))
    original = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
    assert is_nil(original.cache_write_token_micros)
    assert original.config["cache_write_rates"] == %{"30m" => "1.25", "12h" => "2.5"}
    equivalent = put_in(payload, path ++ ["cache_write_30m"], 1.250)
    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(equivalent))

    for field <- ~w(cache_write_30m cache_write_12h) do
      for changed <- [Map.put(rates, field, 9), Map.delete(rates, field)] do
        assert {:error, %{code: :concurrent_pricing_conflict}} = OpenAIPricingImporter.import_file(write_json!(put_in(payload, path, changed)))
        assert persisted_snapshot_fields(Repo.get!(PricingSnapshot, original.id)) == persisted_snapshot_fields(original)
      end

      for value <- [nil, true, -1, "1"] do
        assert {:error, %{code: :incompatible_pricing_catalog}} = OpenAIPricingImporter.import_file(write_json!(put_in(payload, path ++ [field], value)))
        assert persisted_snapshot_fields(Repo.get!(PricingSnapshot, original.id)) == persisted_snapshot_fields(original)
      end
    end

    assert Repo.aggregate(from(row in PricingSnapshot, where: row.model_identifier == ^identifier), :count) == 1
  end

  test "unspecified cache write duration stays unpriced without borrowing a historical generic rate" do
    setup = accounting_setup()
    old = setup.pricing |> Ecto.Changeset.change(effective_at: ~U[2026-07-27 00:00:00.000000Z], cache_write_token_micros: Decimal.new(99)) |> Repo.update!()
    old = Repo.get!(PricingSnapshot, old.id)
    identifier = setup.model.pricing_ref
    rates = %{"input" => 1, "cached_input" => 0.1, "output" => 2, "cache_write_30m" => 1.25, "cache_write_12h" => 2.5}
    payload = put_in(v2_payload(identifier), ["models", identifier, "prices", "standard", "default"], rates)
    assert {:ok, %{price_version: version}} = OpenAIPricingImporter.import_file(write_json!(payload))

    for written <- [nil, 0, 10] do
      assert {:ok, reserved} = Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10}, %{correlation_id: "cache-duration-#{System.unique_integer([:positive])}"})
      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.price_version == version
      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      usage = %{status: "usage_known", input_tokens: 100, cached_input_tokens: 20, output_tokens: 10, total_tokens: 110}
      usage = if is_nil(written), do: usage, else: Map.put(usage, :cache_write_tokens, written)
      assert {:ok, result} = Accounting.finalize_success(reserved.request, attempt, usage, %{response_status_code: 200})
      snapshot = Repo.get!(PricingSnapshot, result.settlement.pricing_snapshot_id)
      assert snapshot.price_version == version

      if written == 10 do
        assert result.settlement.details["pricing_status"] == "unpriced_missing_cache_write_rate"
        assert is_nil(result.settlement.details["settled_cost_micros"])
      else
        assert result.settlement.details["pricing_status"] == "priced"
        assert Decimal.equal?(result.settlement.settled_cost_micros, 102)
      end
    end

    assert Repo.get!(PricingSnapshot, old.id) == old
  end

  test "revision 5 records immutable v2 rules and ignores timestamp layout and rule provenance" do
    payload = v2_payload("gpt-example-a")
    assert {:ok, %{inserted: 1, price_version: version}} = OpenAIPricingImporter.import_file(write_json!(payload))
    assert version == payload["generated_at"] <> ":importer-format-5"
    original = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == "gpt-example-a")
    assert original.config["catalog_schema_version"] == 2
    assert original.config["context_pricing"]["long_context_input_tokens_gt"] == 500_000
    assert original.config["context_pricing"]["version"] == 1
    assert original.config["context_pricing"]["provenance"]["source_url"] == payload["source_url"]

    changed =
      payload
      |> update_in(["models", "gpt-example-a"], &Map.delete(&1, "timestamp"))
      |> put_in(["models", "gpt-example-a", "context_pricing", "tiers", "standard", "provenance", "locator"], "changed/source")

    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(changed))
    assert persisted_snapshot_fields(Repo.get!(PricingSnapshot, original.id)) == persisted_snapshot_fields(original)
    changed = put_in(changed, ["models", "gpt-example-a", "context_pricing", "tiers", "standard", "long_context_input_tokens_gt"], 272_000)
    assert {:error, %{code: :concurrent_pricing_conflict}} = OpenAIPricingImporter.import_file(write_json!(changed))
    assert persisted_snapshot_fields(Repo.get!(PricingSnapshot, original.id)) == persisted_snapshot_fields(original)
  end

  test "v2 model-only catalogs import with an empty tool collection but malformed tools fail" do
    payload = v2_payload("gpt-example-no-tools") |> Map.put("tools", %{}) |> Map.put("tools_count", 0)
    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(write_json!(payload))
    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(payload))
    count = Repo.aggregate(PricingSnapshot, :count)

    invalid_candidates =
      Enum.map([nil, [], 0], &Map.put(payload, "tools", &1)) ++
        Enum.map([nil, true, 0.0, "0", 1, -1], &Map.put(payload, "tools_count", &1)) ++
        [
          Map.delete(payload, "tools"),
          Map.delete(payload, "tools_count"),
          Map.put(payload, "unknown", true),
          payload |> Map.put("models", %{}) |> Map.put("models_count", 0),
          payload |> Map.put("tools", %{"example" => %{"unknown" => true}}) |> Map.put("tools_count", 1)
        ]

    for candidate <- invalid_candidates do
      assert {:error, %{code: :incompatible_pricing_catalog}} = OpenAIPricingImporter.import_file(write_json!(candidate))
      assert Repo.aggregate(PricingSnapshot, :count) == count
    end

    legacy = valid_payload("gpt-example-no-tools-legacy") |> Map.put("tools", %{}) |> Map.put("tools_count", 0)
    assert {:error, %{code: :incompatible_pricing_catalog}} = OpenAIPricingImporter.import_file(write_json!(legacy))
    assert Repo.aggregate(PricingSnapshot, :count) == count
  end

  test "legacy and v2 timestamp layouts import idempotently in both orders with mixed records" do
    for schema <- [1, 2], first_clean? <- [false, true] do
      identifier = "gpt-example-layout-#{schema}-#{first_clean?}"
      payload = if schema == 1, do: valid_payload(identifier), else: v2_payload(identifier)
      clean = update_in(payload, ["models", identifier], &Map.delete(&1, "timestamp"))
      {first, second} = if first_clean?, do: {clean, payload}, else: {payload, clean}
      assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(write_json!(first))
      assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(second))
      snapshot = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
      assert snapshot.config["catalog_schema_version"] == schema
    end

    mixed =
      v2_payload("gpt-example-mixed-a")
      |> put_in(["models", "gpt-example-mixed-b"], v2_payload("gpt-example-mixed-b")["models"]["gpt-example-mixed-b"] |> Map.delete("timestamp"))
      |> Map.put("models_count", 2)

    assert {:ok, %{inserted: 2}} = OpenAIPricingImporter.import_file(write_json!(mixed))
  end

  test "all v2 priced and unavailable buckets retain their tier descriptor and immutable generations" do
    payload = v2_payload("gpt-example-generation")
    model_path = ["models", "gpt-example-generation"]

    payload =
      put_in(payload, model_path ++ ["prices", "standard"], %{
        "default" => %{"input" => 1, "output" => 2},
        "short_context" => %{"input" => 1.0, "output" => 2.0},
        "long_context" => %{"available" => false}
      })

    assert {:ok, %{inserted: 3}} = OpenAIPricingImporter.import_file(write_json!(payload))
    original = Repo.all(from row in PricingSnapshot, where: row.model_identifier == "gpt-example-generation", order_by: row.id)
    assert Enum.uniq(Enum.map(original, & &1.config["context_pricing"])) |> length() == 1
    assert Enum.map(original, & &1.config["price_bucket"]) |> Enum.sort() == ~w(default long_context short_context)
    next = payload |> Map.put("generated_at", "2026-07-29T00:00:00+00:00") |> update_in(model_path, &Map.delete(&1, "timestamp"))
    assert {:ok, %{inserted: 3, price_version: "2026-07-29T00:00:00+00:00:importer-format-5"}} = OpenAIPricingImporter.import_file(write_json!(next))
    assert Enum.map(original, &persisted_snapshot_fields(Repo.get!(PricingSnapshot, &1.id))) == Enum.map(original, &persisted_snapshot_fields/1)
  end

  test "invalid v2 catalogs cannot partially write and schema transitions with one identity conflict" do
    identifier = "gpt-example-rejected"
    payload = v2_payload(identifier)
    count = Repo.aggregate(PricingSnapshot, :count)
    rule_path = ["models", identifier, "context_pricing", "tiers", "standard"]

    for invalid <- [nil, true, 0, -1, "500000", 500_000.0, 9_007_199_254_740_992] do
      candidate = put_in(payload, rule_path ++ ["long_context_input_tokens_gt"], invalid)
      assert {:error, %{code: :incompatible_pricing_catalog}} = OpenAIPricingImporter.import_file(write_json!(candidate))
      assert Repo.aggregate(PricingSnapshot, :count) == count
    end

    for candidate <- [put_in(payload, ["models", identifier, "context_pricing"], nil), put_in(payload, ["models", identifier, "timestamp"], nil), Map.put(payload, "schema_version", nil)] do
      assert {:error, %{code: :incompatible_pricing_catalog}} = OpenAIPricingImporter.import_file(write_json!(candidate))
      assert Repo.aggregate(PricingSnapshot, :count) == count
    end

    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(write_json!(valid_payload(identifier)))
    assert {:error, %{code: :concurrent_pricing_conflict}} = OpenAIPricingImporter.import_file(write_json!(payload))
    assert Repo.aggregate(PricingSnapshot, :count) == count + 1
  end

  test "unknown observations and statuses are immutable semantics while provenance alone is ignored" do
    payload = v2_payload("gpt-example-unknown")
    rule_path = ["models", "gpt-example-unknown", "context_pricing", "tiers", "standard"]
    provenance = get_in(payload, rule_path ++ ["provenance"])
    rule = %{"status" => "unknown", "reason" => "unsupported_source", "observed_rules" => [%{"bucket" => "long_context", "operator" => "gte", "input_tokens" => 500_000}], "provenance" => provenance}
    payload = put_in(payload, rule_path, rule)
    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_file(write_json!(payload))

    for change <- [Map.put(rule, "reason", "conflicting_source"), put_in(rule, ["observed_rules"], [%{"bucket" => "long_context", "operator" => "gt", "input_tokens" => 500_000}]), %{"status" => "uniform", "provenance" => provenance}] do
      assert {:error, %{code: :concurrent_pricing_conflict}} = OpenAIPricingImporter.import_file(write_json!(put_in(payload, rule_path, change)))
    end

    changed = payload |> Map.put("source_url", "https://example.com/changed") |> put_in(rule_path ++ ["provenance", "evidence_sha256"], String.duplicate("b", 64))
    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(write_json!(changed))
    stored = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == "gpt-example-unknown")
    assert stored.config["context_pricing"]["provenance"]["source_url"] == payload["source_url"]
    assert stored.config["context_pricing"]["provenance"]["evidence_sha256"] == provenance["evidence_sha256"]
  end

  test "bounds generic Req adapter exceptions as transport failures" do
    original_options = Req.default_options()
    Req.default_options(adapter: GenericExceptionAdapter)
    on_exit(fn -> Req.default_options(original_options) end)

    source_url = "https://user:secret@example.com/pricing.json"

    assert {:error, %{code: :http_transport_failed, message: "pricing catalog transport failed"} = error} =
             OpenAIPricingImporter.import_url(source_url)

    rendered_error = inspect(error)
    refute rendered_error =~ "credential-bearing transport detail"
    refute rendered_error =~ source_url
    refute rendered_error =~ "secret"
  end

  test "invalid import locations cannot insert pricing rows" do
    before_count = Repo.aggregate(PricingSnapshot, :count)

    for value <- [nil, 42, [], %{}] do
      assert {:error, %{code: :invalid_path}} = OpenAIPricingImporter.import_file(value)
      assert {:error, %{code: :invalid_url}} = OpenAIPricingImporter.import_url(value)
    end

    assert Repo.aggregate(PricingSnapshot, :count) == before_count
  end

  test "missing files return a bounded read error without inserting rows" do
    before_count = Repo.aggregate(PricingSnapshot, :count)

    missing =
      Path.join(System.tmp_dir!(), "missing-pricing-#{System.unique_integer([:positive])}")

    assert {:error, %{code: :file_read_failed, message: message}} =
             OpenAIPricingImporter.import_file(missing)

    assert message == :enoent |> :file.format_error() |> to_string()
    assert Repo.aggregate(PricingSnapshot, :count) == before_count
  end

  test "HTTP imports canonicalize aliases across repeat fetches without creating models" do
    prices = %{"default" => %{"input" => 1, "output" => 2}}
    payload = valid_payload("http-alias-model", %{"fast" => prices, "priority" => prices})

    canonical_payload =
      put_in(payload, ["models", "http-alias-model", "prices"], %{"priority" => prices})

    models_before = Repo.aggregate(CodexPooler.Catalog.Model, :count)

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: FakeUpstream.json_response(payload)
          ),
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: FakeUpstream.json_response(canonical_payload)
          )
        ])
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    url = FakeUpstream.url(upstream) <> "/pricing.json"

    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_url(url)

    snapshot =
      Repo.one!(from row in PricingSnapshot, where: row.model_identifier == "http-alias-model")

    assert snapshot.config["service_tier"] == "priority"
    assert snapshot.source_url == url
    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_url(url)

    assert Repo.one!(from row in PricingSnapshot, where: row.model_identifier == "http-alias-model") == snapshot

    assert Repo.aggregate(CodexPooler.Catalog.Model, :count) == models_before
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "HTTP imports carry the outbound connection idle bound from settings" do
    payload = valid_payload("http-idle-bound-model")

    {:ok, upstream} =
      FakeUpstream.start_link(
        # provenance: synthetic_adversarial (two scheduled fetches reusing one origin)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: FakeUpstream.json_response(payload)
          ),
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: FakeUpstream.json_response(payload)
          )
        ])
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    url = FakeUpstream.url(upstream) <> "/pricing.json"

    UpstreamConnPoolTelemetry.put_idle_bound!(0)
    UpstreamConnPoolTelemetry.attach!(url)

    assert {:ok, %{inserted: 1}} = OpenAIPricingImporter.import_url(url)
    assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_url(url)

    assert :ok = FakeUpstream.verify!(upstream)
    assert UpstreamConnPoolTelemetry.drain_events() == [:conn_max_idle_time_exceeded]
  end

  test "HTTP status, invalid JSON and incompatible catalogs fail without writes" do
    before_count = Repo.aggregate(PricingSnapshot, :count)

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: {:raw_body, 503, "temporary upstream error", []}
          ),
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: {:raw_body, 200, "not JSON", []}
          ),
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: FakeUpstream.json_response(%{"models" => []})
          )
        ])
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    url = FakeUpstream.url(upstream) <> "/pricing.json"

    assert {:error, %{code: :http_error, message: "pricing catalog returned HTTP 503"}} =
             OpenAIPricingImporter.import_url(url)

    assert {:error, %{code: :invalid_json}} = OpenAIPricingImporter.import_url(url)

    assert {:error, %{code: :incompatible_pricing_catalog}} =
             OpenAIPricingImporter.import_url(url)

    assert Repo.aggregate(PricingSnapshot, :count) == before_count
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "HTTP imports skip flat default per-minute models without writing their rows" do
    flat_identifier = "flat-minute-model"
    token_identifier = "flat-minute-token-model"

    payload =
      payload_with_models("2026-07-28T00:00:00Z", [token_identifier, flat_identifier])
      |> put_in(["models", flat_identifier, "category"], "realtime_audio")
      |> put_in(["models", flat_identifier, "categories"], ["realtime_audio"])
      |> put_in(["models", flat_identifier, "pricing_type"], "per_minute")
      |> put_in(["models", flat_identifier, "pricing_types"], ["per_minute"])
      |> put_in(["models", flat_identifier, "prices"], %{
        "standard" => %{"default" => %{"price_per_minute" => 1}}
      })

    # provenance: observed openai-json-pricing flat per-minute shape (2026-09-11); values synthetic
    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "GET",
            path: "/pricing.json",
            respond: FakeUpstream.json_response(payload)
          )
        ])
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    url = FakeUpstream.url(upstream) <> "/pricing.json"

    assert {:ok, %{inserted: 1, skipped: 1, total: 2}} = OpenAIPricingImporter.import_url(url)

    assert Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^token_identifier)

    refute Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^flat_identifier)

    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "malformed URL strings return bounded errors without writes" do
    before_count = Repo.aggregate(PricingSnapshot, :count)

    for url <- [
          "",
          "not a URL",
          "ftp://example.com/pricing.json",
          "http://",
          "http://[invalid",
          "http://example.com:bad",
          "http://example.com:0",
          "http://example.com:65536"
        ] do
      assert {:error, %{code: :invalid_url}} = OpenAIPricingImporter.import_url(url)
    end

    assert Repo.aggregate(PricingSnapshot, :count) == before_count
  end

  test "imports revision 5 rows from the immutable fixture idempotently" do
    assert {:ok, first} = OpenAIPricingImporter.import_file(@fixture)
    assert first.price_version == "2026-07-28T17:25:03.915713Z:importer-format-5"
    assert first.inserted == 208
    assert first.skipped == 90

    assert {:ok, second} = OpenAIPricingImporter.import_file(@fixture)
    assert second.inserted == 0
    assert second.skipped == 90

    rows =
      Repo.all(from snapshot in PricingSnapshot, where: snapshot.price_version == ^first.price_version)

    assert length(rows) == 208
    assert Enum.all?(rows, &(&1.config["importer_format_revision"] == "5"))
    assert Enum.all?(rows, &(&1.config["catalog_schema_version"] == 1 and &1.config["context_pricing"] == %{"version" => 1, "status" => "legacy", "long_context_input_tokens_gt" => 272_000}))
    refute Enum.any?(rows, &(&1.config["service_tier"] == "fast"))
  end

  # Settle real requests after the release entrypoint imports the vendored target,
  # with the model shaped as catalog sync discovers it (`pricing_ref` defaults to
  # `openai/<upstream id>`, which no snapshot names), so the price has to come
  # through the accounting identifier precedence exactly as in production.
  test "the vendored target prices gpt-6-sol requests at its standard and priority rates" do
    assert_imported_target_settles("gpt-6-sol", default: "3280", priority: "6560")
  end

  test "the vendored target prices gpt-6-luna requests at its standard and priority rates" do
    assert_imported_target_settles("gpt-6-luna", default: "164", priority: "328")
  end

  test "the vendored target prices gpt-6.1-sol requests at its standard and priority rates" do
    assert_imported_target_settles("gpt-6.1-sol", default: "3240", priority: "6480")
  end

  test "the vendored target imports every ultrafast context bucket including cache writes" do
    payload = @target |> File.read!() |> CodexPooler.JSON.decode!()
    assert {:ok, imported} = OpenAIPricingImporter.import_file(@target)
    rows = Repo.all(from row in PricingSnapshot, where: row.price_version == ^imported.price_version)

    for {bucket, rates} <- [
          {"default", ["60.0", "6.0", "75.0", "150.0", "300.0"]},
          {"short_context", ["60.0", "6.0", "75.0", "150.0", "300.0"]},
          {"long_context", ["120.0", "12.0", "150.0", "300.0", "450.0"]}
        ] do
      assert source_rates(payload, "gpt-6-astra", "ultrafast", bucket) == Enum.map(rates, &Decimal.new/1)
      assert_snapshot_rates(rows, "gpt-6-astra", "ultrafast", rates, bucket)
    end
  end

  test "the vendored target settles gpt-6-astra at its served ultrafast rate" do
    assert_imported_target_settles("gpt-6-astra", ultrafast: "98400")
  end

  test "the vendored target imports every gpt-6.1-sol ultrafast context bucket including cache writes" do
    payload = @target |> File.read!() |> CodexPooler.JSON.decode!()
    assert {:ok, imported} = OpenAIPricingImporter.import_file(@target)
    rows = Repo.all(from row in PricingSnapshot, where: row.price_version == ^imported.price_version)

    for {bucket, rates} <- [
          {"default", ["12.0", "0.6", "15.0", "30.0", "60.0"]},
          {"short_context", ["12.0", "0.6", "15.0", "30.0", "60.0"]},
          {"long_context", ["24.0", "1.2", "30.0", "60.0", "90.0"]}
        ] do
      assert source_rates(payload, "gpt-6.1-sol", "ultrafast", bucket) == Enum.map(rates, &Decimal.new/1)
      assert_snapshot_rates(rows, "gpt-6.1-sol", "ultrafast", rates, bucket)
    end
  end

  test "the vendored target settles gpt-6.1-sol at its served ultrafast rate" do
    assert_imported_target_settles("gpt-6.1-sol", ultrafast: "19440")
  end

  test "malformed image modality rates reject the whole catalog without snapshot writes" do
    payload = @target |> File.read!() |> CodexPooler.JSON.decode!()
    count = Repo.aggregate(PricingSnapshot, :count)

    for model <- ~w(gpt-image-2.6-flare gpt-image-2.6-sunburst),
        tier <- ~w(standard batch),
        bucket <- ~w(image text) do
      # Batch is a synthetic variant when the published model has only Standard rates.
      prices = payload["models"][model]["prices"]
      candidate = put_in(payload, ["models", model, "prices"], Map.put_new(prices, "batch", prices["standard"]))
      invalid = put_in(candidate, ["models", model, "prices", tier, bucket, "input"], "1")

      assert {:error, %{code: :incompatible_pricing_catalog}} =
               OpenAIPricingImporter.import_file(write_json!(invalid))

      assert Repo.aggregate(PricingSnapshot, :count) == count
    end
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

  test "semantic equality requires identical key sets in both directions" do
    left = %{input: Decimal.new("1.0"), output: Decimal.new("2")}
    equal = %{input: Decimal.new("1"), output: Decimal.new("2.0")}
    extra = Map.put(equal, :availability, "available")

    assert OpenAIPricingImporter.semantic_equal?(left, equal)
    assert OpenAIPricingImporter.semantic_equal?(equal, left)
    refute OpenAIPricingImporter.semantic_equal?(left, extra)
    refute OpenAIPricingImporter.semantic_equal?(extra, left)
  end

  test "file preflight and import count a skipped alias pair like either single alias" do
    prices = %{
      "default" => %{"input" => 1, "output" => 2},
      "inference" => %{"input" => 3, "output" => 4, "training" => 5}
    }

    for aliases <- [["fast"], ["priority"], ["fast", "priority"]] do
      identifier = "skipped-alias-#{Enum.join(aliases, "-")}"
      path = write_json!(valid_payload(identifier, Map.new(aliases, &{&1, prices})))
      preflight = OpenAIPricingPreflight.validate_file(path)
      assert {:ok, %{inserted: 1, skipped: 1, total: 2}} = OpenAIPricingImporter.import_file(path)
      assert preflight.compatible?
      assert preflight.summary.skipped_price_buckets == 1
      assert length(preflight.warnings) == length(aliases)

      snapshot = Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier)
      assert snapshot.config["service_tier"] == "priority"
      assert snapshot.config["price_bucket"] == "default"
      assert snapshot.config["availability"] == "priced"
      assert Decimal.equal?(snapshot.input_token_micros, 1)
      assert Decimal.equal?(snapshot.output_token_micros, 2)
      assert {:ok, %{inserted: 0, skipped: 1, total: 1}} = OpenAIPricingImporter.import_file(path)
      assert Repo.one!(from row in PricingSnapshot, where: row.model_identifier == ^identifier) == snapshot
    end
  end

  test "skipped alias buckets preserve unavailable snapshots and separate model tier coverage" do
    prices = %{
      "default" => %{"available" => false},
      "audio" => %{"output" => 2},
      "text" => %{"input" => 1}
    }

    identifiers = ~w(first-skipped-model second-skipped-model)
    payload = payload_with_models("2026-07-28T00:00:00Z", identifiers)
    tiers = Map.new(~w(fast priority standard ultrafast), &{&1, prices})
    payload = Enum.reduce(identifiers, payload, &put_in(&2, ["models", &1, "prices"], tiers))
    path = write_json!(payload)
    preflight = OpenAIPricingPreflight.validate_file(path)

    assert {:ok, %{inserted: 6, skipped: 12, total: 18}} = OpenAIPricingImporter.import_file(path)
    assert preflight.compatible?
    assert preflight.summary == %{importable_rows: 6, priced_rows: 0, unavailable_rows: 6, skipped_models: 0, skipped_price_buckets: 12}
    assert preflight.coverage.imported_price_buckets == %{"default" => 6, "short_context" => 0, "long_context" => 0}
    assert length(preflight.warnings) == 16

    rows = Repo.all(from row in PricingSnapshot, where: row.model_identifier in ^identifiers)
    assert length(rows) == 6
    assert Enum.sort(Enum.map(rows, &{&1.model_identifier, &1.config["service_tier"]})) == for(identifier <- identifiers, tier <- ~w(priority standard ultrafast), do: {identifier, tier})
    assert Enum.all?(rows, &(&1.config["price_bucket"] == "default" and &1.config["availability"] == "unavailable" and is_nil(&1.input_token_micros) and is_nil(&1.output_token_micros)))
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
      unsupported_payload("live-malformed", "per_minute", ["per_minute"], %{
        "standard" => %{"live_transcription" => %{"estimated_cost" => "0.017"}}
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

  test "live per-minute models import as validated skips without zero-price rows" do
    live_identifier = "live-minute-model"
    token_identifier = "token-model"

    payload =
      payload_with_models("2026-07-28T00:00:00Z", [token_identifier, live_identifier])
      |> put_in(["models", live_identifier, "category"], "audio_transcription")
      |> put_in(["models", live_identifier, "categories"], ["audio_transcription"])
      |> put_in(["models", live_identifier, "pricing_type"], "per_minute")
      |> put_in(["models", live_identifier, "pricing_types"], ["per_minute"])
      |> put_in(["models", live_identifier, "prices"], %{
        "standard" => %{"live_transcription" => %{"estimated_cost" => 0.017}}
      })

    assert {:ok, %{inserted: 1, skipped: 1, total: 2}} =
             OpenAIPricingImporter.import_file(write_json!(payload))

    assert Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^token_identifier)

    refute Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == ^live_identifier)
  end

  test "duplicate raw JSON keys and normalized model collisions fail without writes" do
    duplicate =
      String.replace(
        CodexPooler.JSON.encode!(valid_payload()),
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

    refute Repo.exists?(from row in PricingSnapshot, where: row.model_identifier == "sample-model")
  end

  test "revision 5 canonical import preserves revision 1 fast rows and attempt references" do
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

    assert version == "#{generated_at}:importer-format-5"
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
               where: row.model_identifier == "removed-model" and row.price_version == ^child_version
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

  test "identical re-import verifies persisted rows without issuing snapshot inserts" do
    unique = System.unique_integer([:positive])
    identifiers = ["reimport-first-#{unique}", "reimport-second-#{unique}"]
    path = write_json!(payload_with_models("2026-07-28T00:00:00Z", identifiers))

    handler_id = "pricing-import-idempotence-#{unique}"
    insert_count = :counters.new(1, [])

    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and pricing_snapshot_insert?(metadata) do
            :counters.add(insert_count, 1, 1)
          end
        end,
        nil
      )

    try do
      assert {:ok, %{inserted: 2}} = OpenAIPricingImporter.import_file(path)
      assert :counters.get(insert_count, 1) > 0
      :counters.put(insert_count, 1, 0)

      assert {:ok, %{inserted: 0}} = OpenAIPricingImporter.import_file(path)
      assert :counters.get(insert_count, 1) == 0
    after
      :telemetry.detach(handler_id)
    end
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
      unknown_cache_write: fn snapshot ->
        Ecto.Changeset.change(snapshot, cache_write_token_micros: nil)
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

  test "simultaneous v2 equivalent rule imports retain winner provenance through the unique index" do
    identifier = "gpt-example-race-equivalent-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup_unboxed_snapshots([identifier]) end)
    winner = v2_payload(identifier)
    candidate = put_in(winner, ["models", identifier, "context_pricing", "tiers", "standard", "provenance", "locator"], "changed/source")
    assert %{first: {:ok, %{inserted: 1}}, second: {:ok, %{inserted: 0}}} = run_concurrent_imports(write_json!(winner), write_json!(candidate))
    assert unboxed_snapshot_count([identifier]) == 1
    assert unboxed_snapshot!(identifier).config["context_pricing"]["provenance"]["locator"] == "example/standard"
  end

  test "simultaneous v2 cutoff conflict rolls back a preceding row despite equal rates" do
    unique = System.unique_integer([:positive])
    first_identifier = "a-example-race-#{unique}"
    conflict_identifier = "z-example-race-#{unique}"
    on_exit(fn -> cleanup_unboxed_snapshots([first_identifier, conflict_identifier]) end)
    winner = v2_payload(conflict_identifier)

    candidate =
      winner
      |> put_in(["models", conflict_identifier, "context_pricing", "tiers", "standard", "long_context_input_tokens_gt"], 272_000)
      |> put_in(["models", first_identifier], v2_payload(first_identifier)["models"][first_identifier])
      |> Map.put("models_count", 2)

    assert %{first: {:ok, %{inserted: 1}}, second: {:error, %{code: :concurrent_pricing_conflict}}} = run_concurrent_imports(write_json!(winner), write_json!(candidate))
    refute unboxed_snapshot_exists?(first_identifier)
    assert unboxed_snapshot_count([conflict_identifier]) == 1
    assert unboxed_snapshot!(conflict_identifier).config["context_pricing"]["long_context_input_tokens_gt"] == 500_000
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

  # Each tier is the one the provider reports on the response. `default` is sent
  # without a requested tier, as Codex does, and prices from the `standard` rows;
  # `priority` is requested and served. 1_000 input tokens of which 400 cached
  # and 200 output tokens cost 600 * input + 400 * cached_input + 200 * output
  # at that tier's default-bucket rates, in micro-dollars.
  defp assert_imported_target_settles(identifier, expected_costs) do
    assert {:ok, %{price_version: price_version}} = CodexPooler.Catalog.import_openai_pricing_from_priv()

    setup = accounting_setup()

    model =
      setup.pool
      |> model_fixture(%{exposed_model_id: identifier, upstream_model_id: identifier})
      |> Ecto.Changeset.change(pricing_ref: "openai/#{identifier}")
      |> Repo.update!()

    for {tier, expected_cost} <- expected_costs do
      correlation_id = "corr-#{identifier}-#{tier}-#{System.unique_integer([:positive])}"
      payload = %{"model" => identifier, "max_output_tokens" => 200}
      payload = if tier == :default, do: payload, else: Map.put(payload, "service_tier", to_string(tier))
      snapshot_tier = if tier == :default, do: "standard", else: to_string(tier)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 model,
                 payload,
                 %{correlation_id: correlation_id}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.model_identifier == identifier
      assert reserved.pricing_snapshot.price_version == price_version

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 1_000,
                   cached_input_tokens: 400,
                   output_tokens: 200,
                   total_tokens: 1_200,
                   service_tier: to_string(tier)
                 },
                 %{response_status_code: 200}
               )

      settled = Repo.get!(PricingSnapshot, result.settlement.pricing_snapshot_id)
      assert settled.model_identifier == identifier
      assert settled.price_version == price_version
      assert settled.config["service_tier"] == snapshot_tier
      assert settled.config["price_bucket"] == "default"
      assert result.settlement.details["pricing_status"] == "priced"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(expected_cost))
    end
  end

  defp v2_payload(identifier) do
    valid_payload(identifier)
    |> Map.put("schema_version", 2)
    |> put_in(["models", identifier, "context_pricing"], %{"version" => 1, "tiers" => %{"standard" => %{"status" => "known", "long_context_input_tokens_gt" => 500_000, "provenance" => %{"locator" => "example/standard", "evidence_sha256" => String.duplicate("a", 64)}}}})
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

  defp source_rates(payload, identifier, tier, price_bucket) do
    bucket = get_in(payload, ["models", identifier, "prices", tier, price_bucket])

    Enum.map(["input", "cached_input", "cache_write_30m", "cache_write_12h", "output"], fn key ->
      bucket |> Map.fetch!(key) |> decimal_from_json_number()
    end)
  end

  defp decimal_from_json_number(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_from_json_number(value) when is_float(value), do: Decimal.from_float(value)

  defp assert_snapshot_rates(rows, identifier, tier, expected, price_bucket) do
    snapshot =
      Enum.find(rows, fn row ->
        row.model_identifier == identifier and row.config["service_tier"] == tier and
          row.config["price_bucket"] == price_bucket
      end)

    assert snapshot
    assert is_nil(snapshot.cache_write_token_micros)

    actual = [
      snapshot.input_token_micros,
      snapshot.cached_input_token_micros,
      Decimal.new(snapshot.config["cache_write_rates"]["30m"]),
      Decimal.new(snapshot.config["cache_write_rates"]["12h"]),
      snapshot.output_token_micros
    ]

    assert Enum.zip_with(actual, expected, &Decimal.equal?(&1, Decimal.new(&2)))
           |> Enum.all?()
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

    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> :telemetry.detach(handler_id) end)

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
            run_pricing_winner(first_path, barrier)
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

  defp run_pricing_winner(path, barrier) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.checkout(fn ->
        Process.put({__MODULE__, barrier}, true)

        try do
          OpenAIPricingImporter.import_file(path)
        after
          Process.delete({__MODULE__, barrier})
        end
      end)
    end)
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

  defp write_json!(payload), do: payload |> CodexPooler.JSON.encode!() |> write_raw!()

  defp write_raw!(raw) do
    path =
      Path.join(System.tmp_dir!(), "pricing-importer-#{Ecto.UUID.generate()}.json")

    on_exit(fn -> File.rm(path) end)
    File.write!(path, raw)
    path
  end
end
