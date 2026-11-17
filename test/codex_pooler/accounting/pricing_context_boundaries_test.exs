defmodule CodexPooler.Accounting.PricingContextBoundariesTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.PricingResolution
  alias CodexPooler.Accounting.PricingResolution.Generations
  alias CodexPooler.Catalog.{Model, OpenAIPricingImporter, PricingSnapshot}
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]

  @as_of ~U[2026-10-12 12:00:00.000000Z]

  test "each model and tier selects its own cutoff with equality in the lower band" do
    import_catalog!("2026-10-12T00:00:00Z", %{
      "gpt-example-a" => model_prices(272_000, 500_000),
      "gpt-example-b" => model_prices(500_000, 272_000)
    })

    for {identifier, cutoffs} <- [{"gpt-example-a", [272_000, 500_000]}, {"gpt-example-b", [500_000, 272_000]}],
        {tier, cutoff} <- Enum.zip(["standard", "priority"], cutoffs),
        input <- [272_000, 272_001, 400_000, 500_000, 500_001] do
      pricing = lookup(identifier, input, tier)
      assert pricing.status == "priced"
      assert pricing.price_bucket == if(input > cutoff, do: "long_context", else: "default")
      assert Decimal.equal?(pricing.snapshot.input_token_micros, Decimal.new(if(input > cutoff, do: 4, else: 2)))
    end
  end

  test "preferred reference classifies its own primary before a lower identifier long price" do
    import_catalog!("2026-10-12T00:00:00Z", %{
      "gpt-example-reference" => model_prices(500_000, 500_000),
      "gpt-example-upstream" => model_prices(272_000, 272_000)
    })

    pricing = lookup("gpt-example-reference", 400_000, "standard", "gpt-example-upstream")
    assert pricing.snapshot.model_identifier == "gpt-example-reference"
    assert pricing.price_bucket == "default"
  end

  test "new generation missing long rates never revives older long rates" do
    import_catalog!("2026-10-10T00:00:00Z", %{"gpt-example-a" => model_prices(272_000, 272_000)})
    latest = model_prices(500_000, 500_000) |> update_in(["prices", "standard"], &Map.delete(&1, "long_context"))
    import_catalog!("2026-10-11T00:00:00Z", %{"gpt-example-a" => latest})
    pricing = lookup("gpt-example-a", 500_001)
    assert pricing.price_bucket == "default"
    assert pricing.snapshot.price_version == "2026-10-11T00:00:00Z:importer-format-5"
    assert pricing.price_bucket_fallback["requested"] == "long_context"
  end

  test "preferred unavailable primary is terminal before lower priced exact identifiers" do
    for coherent <- [false, true], bucket <- ["default", "long_context"] do
      suffix = "#{coherent}-#{bucket}"
      preferred = "gpt-example-preferred-#{suffix}"
      lower = "gpt-example-lower-#{suffix}"
      snapshot!(preferred, bucket, "preferred-#{suffix}", unavailable: true, coherent: coherent)
      snapshot!(lower, bucket, "lower-#{suffix}", coherent: coherent)
      pricing = lookup(preferred, if(bucket == "long_context", do: 500_001, else: 10), "standard", lower)
      assert pricing.status == "unpriced_unavailable_price_bucket"
      assert pricing.snapshot == nil
      assert pricing.context_pricing["generation"]["model_identifier"] == preferred
    end
  end

  test "first existing unavailable exact fallback cannot skip to a lower fallback but continues suffix stages" do
    for with_suffix <- [false, true] do
      preferred = "gpt-example-ref-#{with_suffix}"
      lower = "gpt-example-low-#{with_suffix}"
      snapshot!(preferred, "default", "preferred", unavailable: true)
      snapshot!(lower, "default", "lower")
      if with_suffix, do: snapshot!("gpt-example-ref", "long_context", "suffix")

      pricing = lookup(preferred, 500_001, "standard", lower)

      if with_suffix do
        assert pricing.status == "priced"
        assert pricing.snapshot.model_identifier == "gpt-example-ref"
        assert pricing.alias["source"] == "suffix_inference"
      else
        assert pricing.status == "unpriced_missing_tier"
        assert pricing.snapshot == nil
      end
    end
  end

  test "missing preferred long offers fallback while a lower exact primary wins" do
    preferred = model_prices(272_000, 272_000) |> update_in(["prices", "standard"], &Map.delete(&1, "long_context"))
    import_catalog!("2026-10-12T00:00:00Z", %{"gpt-example-reference" => preferred, "gpt-example-upstream" => model_prices(272_000, 272_000)})
    pricing = lookup("gpt-example-reference", 400_000, "standard", "gpt-example-upstream")
    assert pricing.snapshot.model_identifier == "gpt-example-upstream"
    assert pricing.price_bucket == "long_context"
    refute Map.has_key?(pricing, :price_bucket_fallback)
  end

  test "new unknown or corrupt rule is terminal with generation even without a snapshot" do
    for state <- ["unknown", "invalid"] do
      identifier = "gpt-example-#{state}"
      import_catalog!("2026-10-10T00:00:00Z", %{identifier => model_prices(272_000, 272_000)})
      newer = model_prices(500_000, 500_000)
      unknown = rule(500_000) |> Map.delete("long_context_input_tokens_gt") |> Map.merge(%{"status" => "unknown", "reason" => "missing_source", "observed_rules" => []})
      newer = put_in(newer, ["context_pricing", "tiers", "standard"], unknown)
      import_catalog!("2026-10-11T00:00:00Z", %{identifier => newer, "gpt-example-lower-#{state}" => model_prices(272_000, 272_000)})

      if state == "invalid" do
        Repo.update_all(from(p in PricingSnapshot, where: p.model_identifier == ^identifier and p.price_version == "2026-10-11T00:00:00Z:importer-format-5", update: [set: [config: fragment("jsonb_set(?, '{context_pricing}', 'null'::jsonb)", p.config)]]), [])
      end

      pricing = lookup(identifier, 400_000, "standard", "gpt-example-lower-#{state}")
      assert pricing.status == "unpriced_context_boundary_#{state}"
      assert pricing.snapshot == nil
      assert pricing.context_pricing["status"] == state
      assert pricing.context_pricing["generation"]["price_version"] == "2026-10-11T00:00:00Z:importer-format-5"
    end
  end

  test "coherent legacy catalogs expose the assumption and historical bucket versions stay independent" do
    old_long = snapshot!("gpt-example-historical", "long_context", "historical-long", effective_at: ~U[2026-10-10 00:00:00.000000Z])
    snapshot!("gpt-example-historical", "default", "historical-default", effective_at: ~U[2026-10-11 00:00:00.000000Z])
    result = lookup("gpt-example-historical", 272_001)
    assert result.snapshot.id == old_long.id
    assert result.context_pricing["status"] == "legacy"
    assert result.context_pricing["generation"]["price_version"] == old_long.price_version
    assert result.context_pricing["long_context_input_tokens_gt"] == 272_000

    snapshot!("gpt-example-legacy", "default", "legacy", coherent: true, rule: %{"version" => 1, "status" => "legacy", "long_context_input_tokens_gt" => 272_000}, schema: 1)
    result = lookup("gpt-example-legacy", 272_001)
    assert result.status == "priced"
    assert result.context_pricing["basis"] == "legacy_assumption"
    assert result.price_bucket_fallback["requested"] == "long_context"
  end

  test "uniform short alias and explicit stored bucket avoid fabricated token classification" do
    model = model_prices(500_000, 500_000)
    uniform = rule(500_000) |> Map.delete("long_context_input_tokens_gt") |> Map.put("status", "uniform")
    model = model |> put_in(["prices", "standard"], %{"short_context" => rates(2)}) |> put_in(["context_pricing", "tiers", "standard"], uniform)
    import_catalog!("2026-10-12T00:00:00Z", %{"gpt-example-uniform" => model, "gpt-example-stored" => model_prices(500_000, 500_000)})
    pricing = lookup("gpt-example-uniform", 900_000)
    assert pricing.status == "priced"
    assert pricing.price_bucket == "short_context"
    assert pricing.context_pricing["status"] == "uniform"
    refute Map.has_key?(pricing.context_pricing, "long_context_input_tokens_gt")

    request = %Request{requested_model: "gpt-example-stored", request_metadata: %{"pricing" => %{"price_bucket" => "long_context"}}}
    snapshot = PricingResolution.latest_snapshot_for_request(request, %Model{pricing_ref: "gpt-example-stored"})
    assert snapshot.config["price_bucket"] == "long_context"
  end

  test "future generations are ignored and unavailable long blocks same-generation default fallback" do
    import_catalog!("2026-10-11T00:00:00Z", %{"gpt-example-future" => model_prices(500_000, 500_000)})
    import_catalog!("2026-10-13T00:00:00Z", %{"gpt-example-future" => model_prices(272_000, 272_000)})
    pricing = lookup("gpt-example-future", 400_000)
    assert pricing.price_bucket == "default"
    assert pricing.snapshot.price_version == "2026-10-11T00:00:00Z:importer-format-5"

    snapshot!("gpt-example-unavailable", "default", "same-generation", coherent: true)
    snapshot!("gpt-example-unavailable", "long_context", "same-generation", coherent: true, unavailable: true)
    pricing = lookup("gpt-example-unavailable", 500_001)
    assert pricing.status == "unpriced_unavailable_price_bucket"
    refute Map.has_key?(pricing, :price_bucket_fallback)
  end

  test "effective ultrafast variants switch at the published boundary" do
    promotion =
      snapshot!(
        "gpt-effective-ultrafast",
        "default",
        "effective-generation",
        service_tier: "ultrafast_promotion",
        effective_at: ~U[2026-10-01 00:00:00.000000Z],
        pricing_effective_until: "2027-03-01T08:00:00Z"
      )

    listed =
      snapshot!(
        "gpt-effective-ultrafast",
        "default",
        "effective-generation",
        service_tier: "ultrafast_list",
        effective_at: ~U[2027-03-01 08:00:00.000000Z]
      )

    before = lookup_at("gpt-effective-ultrafast", 10, "ultrafast", ~U[2027-02-28 23:59:59Z])
    after_pricing = lookup_at("gpt-effective-ultrafast", 10, "ultrafast", ~U[2027-03-01 08:00:00Z])

    assert before.snapshot.id == promotion.id
    assert after_pricing.snapshot.id == listed.id
  end

  test "cached and written input count before rate decomposition and missing write rate cannot borrow" do
    setup = accounting_setup()
    identifier = setup.model.pricing_ref
    Repo.delete!(setup.pricing)
    import_catalog!("2026-10-10T00:00:00Z", %{identifier => model_prices(500_000, 500_000)})
    request = %Request{pool_id: setup.pool.id, model_id: setup.model.id, requested_model: identifier, request_metadata: %{}}
    usage = %{input_tokens: 500_001, cached_input_tokens: 200_000, cache_write_tokens: 200_000, output_tokens: 10, reasoning_tokens: 0}
    pricing = PricingResolution.lookup_for_settlement(request, %Attempt{}, %LedgerEntry{details: %{}}, usage, %{}, @as_of)
    assert pricing.price_bucket == "long_context"
    # 100001*4 + 200000*1 + 200000*6 + 10*12 = 1800124 micros.
    assert Decimal.equal?(PricingResolution.cost_micros(pricing.snapshot, usage), Decimal.new(1_800_124))

    newer = model_prices(500_000, 500_000) |> update_in(["prices", "standard", "long_context"], &Map.delete(&1, "cache_write"))
    import_catalog!("2026-10-11T00:00:00Z", %{identifier => newer})
    pricing = PricingResolution.lookup_for_settlement(request, %Attempt{}, %LedgerEntry{details: %{}}, usage, %{}, @as_of)
    assert pricing.status == "unpriced_missing_cache_write_rate"
    assert pricing.snapshot.price_version == "2026-10-11T00:00:00Z:importer-format-5"
    assert pricing.snapshot.cache_write_token_micros == nil

    for writes <- [0, nil] do
      pricing = PricingResolution.lookup_for_settlement(request, %Attempt{}, %LedgerEntry{details: %{}}, %{usage | cache_write_tokens: writes}, %{}, @as_of)
      assert pricing.status == "priced"
    end
  end

  test "generation mismatch is invalid instead of mixing sibling rule semantics" do
    snapshot!("gpt-example-mismatch", "default", "same-generation", coherent: true)
    snapshot!("gpt-example-mismatch", "long_context", "same-generation", coherent: true, rule: stored_rule(272_000))
    assert lookup("gpt-example-mismatch", 400_000).status == "unpriced_context_boundary_invalid"
  end

  test "revision identity fences otherwise matching version buckets" do
    snapshot!("gpt-example-revision", "long_context", "same-version", effective_at: ~U[2026-10-10 00:00:00.000000Z])
    newest = snapshot!("gpt-example-revision", "default", "same-version", coherent: true)
    pricing = lookup("gpt-example-revision", 500_001)
    assert pricing.snapshot.id == newest.id
    assert pricing.price_bucket == "default"
    assert pricing.price_bucket_fallback["requested"] == "long_context"
  end

  test "precomputed input avoids estimating again and output never contributes to classification" do
    import_catalog!("2026-10-12T00:00:00Z", %{"gpt-example-estimate" => model_prices(500_000, 500_000)})
    model = %Model{pricing_ref: "gpt-example-estimate"}
    # This value cannot be JSON-encoded: reaching the estimator would fail.
    pricing = PricingResolution.lookup(model, model.pricing_ref, %{"input" => self(), "max_output_tokens" => 900_000}, %{reservation_estimate: %{input_tokens: 500_000, output_tokens: 900_000}}, @as_of)
    assert pricing.price_bucket == "default"
    estimated = PricingResolution.lookup(model, model.pricing_ref, %{"max_output_tokens" => 900_000}, %{}, @as_of)
    assert estimated.price_bucket == "default"
  end

  test "image allowance selects context price bands consistently in direct and precomputed lookup" do
    import_catalog!("2026-10-12T00:00:00Z", %{"sample-image-estimate" => model_prices(1_600, 1_600)})
    model = %Model{pricing_ref: "sample-image-estimate"}

    for {payload, context, opts} <- [
          {%{"input" => [%{"role" => "user", "content" => [%{"type" => "input_image", "image_url" => "https://example.com/image.png"}]}]}, %{}, %{}},
          {%{"images" => [%{"image_url" => "https://example.com/image.png"}]}, %{source_endpoint: "/backend-api/codex/images/edits"}, %{endpoint: "/backend-api/codex/images/edits"}}
        ] do
      {:ok, estimate} = PricingResolution.reservation_estimate(payload, nil, nil, nil, context)
      assert estimate.input_tokens > 1_600
      direct = PricingResolution.lookup(model, model.pricing_ref, payload, opts, @as_of)
      precomputed = PricingResolution.lookup(model, model.pricing_ref, payload, Map.put(opts, :reservation_estimate, estimate), @as_of)
      assert direct == precomputed
      assert direct.price_bucket == "long_context"
      assert direct.context_pricing["band"] == "long"
    end
  end

  test "malformed persisted rule fields fail closed with a bounded reason" do
    for {label, corrupt_rule} <- [
          {"boolean", stored_rule(true)},
          {"float", stored_rule(500_000.5)},
          {"zero", stored_rule(0)},
          {"huge", stored_rule(9_007_199_254_740_992)},
          {"version", Map.put(stored_rule(500_000), "version", 2)},
          {"status", Map.put(stored_rule(500_000), "status", "unexpected")},
          {"null", nil},
          {"array", []}
        ] do
      snapshot = snapshot!("gpt-example-corrupt-#{label}", "default", "corrupt-#{label}", coherent: true)
      Repo.update!(Ecto.Changeset.change(snapshot, config: Map.put(snapshot.config, "context_pricing", corrupt_rule)))
      pricing = lookup(snapshot.model_identifier, 400_000)
      assert pricing.status == "unpriced_context_boundary_invalid"
      assert pricing.context_pricing["reason"] == "invalid_rule"
      refute Map.has_key?(pricing.context_pricing, "long_context_input_tokens_gt")
    end
  end

  test "real import and SQL-selected rate reproduce independent matrix costs and generation facts" do
    imported = import_catalog!("2026-10-12T00:00:00Z", %{"gpt-example-a" => model_prices(272_000, 500_000), "gpt-example-b" => model_prices(500_000, 272_000)})

    observations =
      for {identifier, cutoffs} <- [{"gpt-example-a", [272_000, 500_000]}, {"gpt-example-b", [500_000, 272_000]}],
          {tier, cutoff} <- Enum.zip(["standard", "priority"], cutoffs),
          input <- [272_000, 272_001, 400_000, 500_000, 500_001] do
        pricing = lookup(identifier, input, tier)
        usage = %{input_tokens: input, cached_input_tokens: 100_000, cache_write_tokens: 50_000, output_tokens: 10, reasoning_tokens: 0}
        long? = input > cutoff
        expected = if long?, do: (input - 150_000) * 4 + 100_000 + 300_000 + 120, else: (input - 150_000) * 2 + 50_000 + 150_000 + 60
        assert Decimal.equal?(PricingResolution.cost_micros(pricing.snapshot, usage), Decimal.new(expected))
        persisted = Repo.get!(PricingSnapshot, pricing.snapshot.id)
        assert persisted.price_version == imported.price_version
        assert persisted.config["context_pricing"]["long_context_input_tokens_gt"] == cutoff
        %{model: identifier, tier: tier, input: input, cached: 100_000, writes: 50_000, output: 10, expected_micros: expected, actual_micros: Decimal.to_string(PricingResolution.cost_micros(pricing.snapshot, usage)), snapshot_id: persisted.id, status: pricing.status, facts: pricing.context_pricing}
      end

    if path = System.get_env("PRICING_BOUNDARY_MANUAL_RECEIPT") do
      File.write!(path, CodexPooler.JSON.encode!(%{cases: observations, case_count: length(observations), oracle: "literal cutoff and rates, independent of selected snapshot", imported: imported}))
    end
  end

  test "one restricted SQL statement returns at most four rows per candidate across history" do
    for generation <- 1..150, identifier <- ["gpt-example-history", "gpt-example-unrelated"] do
      for bucket <- ["default", "short_context", "long_context"] do
        snapshot!(identifier, bucket, "version-#{generation}", effective_at: DateTime.add(@as_of, -generation, :second))
      end
    end

    {sql, params} = Generations.statement(["gpt-example-history", "gpt-example-absent"], "standard", @as_of)
    result = Repo.query!(sql, params)
    assert result.num_rows == 5
    assert Enum.all?(result.rows, fn [identifier | _rest] -> identifier in ["gpt-example-history", "gpt-example-absent"] end)
    explain = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)
    [[[%{"Plan" => plan}]]] = explain.rows
    assert plan["Actual Rows"] == 5

    handler = {__MODULE__, make_ref()}
    count = :counters.new(1, [])
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.count_queries/4, {self(), count})
    pricing = lookup("gpt-example-history", 500_001)
    assert pricing.status == "priced"
    assert :counters.get(count, 1) == 1
    :ok = :telemetry.detach(handler)

    if path = System.get_env("PRICING_BOUNDARY_QUERY_PLAN") do
      File.write!(path, CodexPooler.JSON.encode!(%{candidate_count: 2, history_rows: 900, returned_rows: result.num_rows, lookup_query_count: :counters.get(count, 1), plan: plan}))
    end
  end

  test "candidate identifiers remain SQL parameters and cannot expose unrelated prices" do
    snapshot!("gpt-example-unrelated", "default", "unrelated")
    assert lookup("gpt-example' OR '1'='1", 10).status == "unpriced_missing_model"
    assert Repo.aggregate(from(p in PricingSnapshot, where: p.model_identifier == "gpt-example-unrelated"), :count) == 1
  end

  def count_queries(_event, _measurements, _metadata, {owner, count}) do
    if self() == owner, do: :counters.add(count, 1, 1)
  end

  defp snapshot!(identifier, bucket, version, opts \\ []) do
    config = %{"service_tier" => Keyword.get(opts, :service_tier, "standard"), "price_bucket" => bucket, "pricing_type" => "per_1m_tokens"}
    config = if opts[:unavailable], do: Map.put(config, "availability", "unavailable"), else: config
    config = if opts[:pricing_effective_until], do: Map.put(config, "pricing_effective_until", opts[:pricing_effective_until]), else: config
    config = if opts[:coherent], do: Map.merge(config, %{"importer_format_revision" => "3", "catalog_schema_version" => opts[:schema] || 2, "context_pricing" => opts[:rule] || stored_rule(500_000)}), else: config

    Repo.insert!(%PricingSnapshot{
      model_identifier: identifier,
      price_version: version,
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(2),
      output_token_micros: Decimal.new(6),
      effective_at: opts[:effective_at] || ~U[2026-10-11 00:00:00.000000Z],
      captured_at: @as_of,
      config: config
    })
  end

  defp stored_rule(cutoff), do: rule(cutoff) |> Map.put("version", 1) |> put_in(["provenance", "source_url"], "https://example.com/pricing")

  defp lookup(identifier, input, tier \\ "standard", upstream \\ nil) do
    lookup_at(identifier, input, tier, @as_of, upstream)
  end

  defp lookup_at(identifier, input, tier, timestamp, upstream \\ nil) do
    PricingResolution.lookup(
      %Model{pricing_ref: identifier, upstream_model_id: upstream, exposed_model_id: identifier},
      identifier,
      %{"service_tier" => tier},
      %{reservation_estimate: %{input_tokens: input}},
      timestamp
    )
  end

  defp model_prices(standard_cutoff, priority_cutoff) do
    tiers = Enum.zip(["standard", "priority"], [standard_cutoff, priority_cutoff])

    %{
      "category" => "language_model",
      "categories" => ["language_model"],
      "pricing_type" => "per_1m_tokens",
      "pricing_types" => ["per_1m_tokens"],
      "prices" => Map.new(tiers, fn {tier, _cutoff} -> {tier, %{"default" => rates(2), "long_context" => rates(4)}} end),
      "context_pricing" => %{"version" => 1, "tiers" => Map.new(tiers, fn {tier, cutoff} -> {tier, rule(cutoff)} end)}
    }
  end

  defp rates(input), do: %{"input" => input, "cached_input" => input / 4, "cache_write" => input * 1.5, "output" => input * 3}

  defp rule(cutoff), do: %{"status" => "known", "long_context_input_tokens_gt" => cutoff, "provenance" => %{"locator" => "synthetic/context-note", "evidence_sha256" => String.duplicate("a", 64)}}

  defp import_catalog!(generated_at, models) do
    path = Path.join(System.tmp_dir!(), "pricing-boundaries-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm!(path) end)

    payload = %{
      "schema_version" => 2,
      "generated_at" => generated_at,
      "source" => "synthetic",
      "source_url" => "https://example.com/pricing",
      "models" => Map.new(models, fn {identifier, model} -> {identifier, Map.put(model, "model", identifier)} end),
      "models_count" => map_size(models),
      "tools" => %{"sample-tool" => %{"details" => "Synthetic tool", "price" => 0, "pricing" => "$0", "tool" => "Sample Tool"}},
      "tools_count" => 1
    }

    File.write!(path, CodexPooler.JSON.encode!(payload))
    assert {:ok, result} = OpenAIPricingImporter.import_file(path)
    result
  end
end
