defmodule CodexPooler.Accounting.ImageReservationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, Metadata, PricingResolution, Request}
  alias CodexPooler.Accounting.PricingResolution.Costing
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport

  test "equal pixels reserve identical input despite different PNG compression" do
    first = image_payload(png(0))
    second = image_payload(png(9))
    assert byte_size(png(0)) > byte_size(png(9))
    assert Costing.estimate_input_tokens(first) == Costing.estimate_input_tokens(second)
  end

  test "equal pixels receive the same real database admission decision" do
    for level <- [0, 9] do
      setup = accounting_setup()
      update_default_policy!(setup.api_key, %{max_input_tokens_per_request: 2_000, max_tokens_per_day: 10_000})

      result = Accounting.reserve(setup.auth, setup.model, image_payload(png(level)), %{correlation_id: Ecto.UUID.generate()})
      assert match?({:ok, _}, result)
    end
  end

  # A replayed hosted image generation is estimated as one image allowance, so a key with a per-request input limit
  # admits the turn; read as JSON text, a 400 KB replay alone estimated about 133k tokens and was refused before
  # dispatch (the provider billed a 1.2 MB replay as about 100 input tokens for the whole request, direct probe
  # 2026-11-18).
  test "a replayed image generation's base64 result does not count against a per-request input limit" do
    setup = accounting_setup()
    update_default_policy!(setup.api_key, %{max_input_tokens_per_request: 2_000, max_tokens_per_day: 10_000})
    result = Base.encode64(:binary.copy(<<137, 80, 78, 71>>, 100_000))
    call = %{"type" => "image_generation_call", "id" => "ig_synthetic", "status" => "completed", "revised_prompt" => "synthetic prompt", "result" => result}
    payload = %{"model" => "gpt-accounting-mini", "input" => [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic"}]}, call]}

    assert %{input_tokens: tokens, image_estimate: image_estimate} = Costing.input_estimate(payload)
    assert tokens < 1_800
    assert image_estimate == provenance(1)
    assert {:ok, reserved} = Accounting.reserve(setup.auth, setup.model, payload, %{correlation_id: Ecto.UUID.generate()})
    assert reserved.estimate.input_tokens == tokens
  end

  test "ordinary text and image-looking arbitrary tool data retain their legacy estimate" do
    for payload <- [%{}, %{"model" => "sample-model", "stream" => true}, %{"input" => "ordinary text", "tools" => [%{"type" => "function", "parameters" => %{"image_url" => String.duplicate("a", 10_000)}}]}, %{"input" => [%{"type" => "function_call_output", "call_id" => "sample-call", "output" => %{"image_url" => String.duplicate("b", 10_000)}}]}] do
      expected = legacy_tokens(payload)
      assert Costing.estimate_input_tokens(payload) == expected
      assert %{input_tokens: ^expected, strategy: "json_bytes_div_4_ceil"} = Costing.input_estimate(payload)
      refute Map.has_key?(Costing.input_estimate(payload), :image_estimate)
    end
  end

  test "inline and opaque references share allowance while count and ordinary structure remain visible" do
    for locator <- [png(0), png(9), "data:image/png;base64,invalid", "https://example.com/image.png"] do
      payload = image_payload(locator)
      estimate = Costing.input_estimate(payload)
      assert estimate.input_tokens == legacy_tokens(image_payload("")) + 1_600
      assert estimate.image_estimate == provenance(1)
      assert estimate.strategy == "json_bytes_div_4_plus_image_allowance_v1"
    end

    payload = %{"input" => [%{"role" => "user", "content" => [%{"type" => "input_image", "file_id" => "file-example"}, %{"type" => "input_image", "file_id" => "file-example"}]}]}
    assert Costing.input_estimate(payload).image_estimate == provenance(2)
    assert Costing.estimate_input_tokens(payload) > Costing.estimate_input_tokens(image_payload("file-example"))
  end

  test "native arrays require trusted endpoint and direct lookup uses the same estimate" do
    setup = accounting_setup()
    payload = %{"images" => [%{"image_url" => png(0)}], "source_endpoint" => "/backend-api/codex/images/edits"}
    context = %{source_endpoint: "/backend-api/codex/images/edits"}
    assert Costing.estimate_input_tokens(payload) == legacy_tokens(payload)
    assert Costing.input_estimate(payload, context).image_estimate == provenance(1)
    {:ok, estimate} = PricingResolution.reservation_estimate(payload, nil, nil, nil, context)
    opts = %{endpoint: context.source_endpoint, requested_model: setup.model.exposed_model_id}
    direct = PricingResolution.lookup(setup.model, setup.model.exposed_model_id, payload, opts, DateTime.utc_now())
    precomputed = PricingResolution.lookup(setup.model, setup.model.exposed_model_id, payload, Map.put(opts, :reservation_estimate, estimate), DateTime.utc_now())
    assert direct == precomputed
    assert {:ok, reserved} = Accounting.reserve(setup.auth, setup.model, payload, opts)
    assert reserved.estimate.input_tokens == estimate.input_tokens
    assert reserved.estimate.image_estimate == provenance(1)
  end

  for field <- [:max_input_tokens_per_request, :max_tokens_per_day, :max_tokens_per_week], offset <- [-1, 0, 1] do
    test "#{field} enforces the image estimate at offset #{offset}" do
      setup = accounting_setup()
      payload = image_payload(png(9))
      {:ok, estimate} = PricingResolution.reservation_estimate(payload, nil, nil)
      limit = if unquote(field) == :max_input_tokens_per_request, do: estimate.input_tokens, else: estimate.total_tokens
      update_default_policy!(setup.api_key, %{unquote(field) => limit + unquote(offset)})
      before_count = Repo.aggregate(Request, :count)
      result = Accounting.reserve(setup.auth, setup.model, payload, %{})

      if unquote(offset) < 0 do
        assert {:error, %{code: :api_key_policy_limit_exceeded}} = result
        assert Repo.aggregate(Request, :count) == before_count
      else
        assert {:ok, reserved} = result
        assert reserved.reservation.total_tokens == estimate.total_tokens
        assert Repo.aggregate(Request, :count) == before_count + 1
      end
    end
  end

  test "snapshot, precomputed reserve and direct reserve agree and locked output policy remains authoritative" do
    setup = accounting_setup()
    update_default_policy!(setup.api_key, %{max_output_tokens_per_request: 4_096, max_tokens_per_day: 30_000})
    payload = image_payload(png(9))
    endpoint = "/backend-api/codex/responses"
    options = RequestOptions.build(%{}, endpoint, payload)
    snapshot = AccountingReservation.reservation_snapshot_inputs(setup.auth, setup.model, payload, endpoint, options)
    assert {:ok, direct} = Accounting.reserve(setup.auth, setup.model, payload, %{})
    assert {:ok, precomputed} = Accounting.reserve(setup.auth, setup.model, payload, %{reservation_estimate: snapshot.reservation_estimate})
    assert direct.estimate == precomputed.estimate
    assert direct.estimate.input_tokens == snapshot.estimated_input_tokens
    assert direct.estimate.output_tokens == 4_096
    assert snapshot.estimated_output_tokens == 2_048
    assert snapshot.estimated_total_tokens == snapshot.estimated_input_tokens + 2_048
    assert direct.request.request_metadata["reservation"]["image_estimate"] == stringify(provenance(1))
    assert direct.reservation.details["image_estimate"] == stringify(provenance(1))
    assert Metadata.sanitize_metadata(%{"image_estimate" => direct.reservation.details["image_estimate"]}) == %{"image_estimate" => stringify(provenance(1))}
    assert {:ok, updated} = Accounting.merge_request_metadata(direct.request, %{"diagnostic" => "sample"})
    assert updated.request_metadata["reservation"]["image_estimate"] == stringify(provenance(1))
  end

  test "new precomputed receipts skip re-estimation and retain only typed provenance" do
    {:ok, original} = Costing.reservation_estimate(image_payload(png(9)), nil, nil)
    precomputed = put_in(original.image_estimate[:image_url], "synthetic locator")
    assert {:ok, reused} = Costing.reservation_estimate(%{"input" => self()}, nil, nil, precomputed)
    assert reused == original

    legacy = Map.delete(precomputed, :strategy)
    assert {:ok, old} = Costing.reservation_estimate(%{"input" => self()}, nil, nil, legacy)
    assert old.input_tokens == original.input_tokens
    assert old.strategy == "json_bytes_div_4_ceil"
    refute Map.has_key?(old, :image_estimate)
  end

  test "legacy precomputed counts retain precedence without being relabeled and unpriced images still reserve" do
    setup = accounting_setup()
    Repo.delete!(setup.pricing)
    payload = image_payload(png(9))
    assert {:ok, legacy} = Accounting.reserve(setup.auth, setup.model, payload, %{reservation_estimate: %{input_tokens: 17, output_tokens: 19}})
    assert legacy.estimate.input_tokens == 17
    assert legacy.estimate.output_tokens == 19
    assert legacy.estimate.strategy == "json_bytes_div_4_ceil"
    refute Map.has_key?(legacy.estimate, :image_estimate)
    refute Map.has_key?(legacy.reservation.details, "image_estimate")
    assert {:ok, fresh} = Accounting.reserve(setup.auth, setup.model, payload, %{})
    assert fresh.estimate.estimated_cost_micros == nil
    assert fresh.estimate.image_estimate == provenance(1)
  end

  for usage_status <- ["usage_known", "usage_unknown", "not_applicable"] do
    test "image reservation settles #{usage_status} through real ledger and window accounting" do
      setup = accounting_setup()
      assert {:ok, reserved} = Accounting.reserve(setup.auth, setup.model, image_payload(png(9)), %{})
      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      known? = unquote(usage_status) == "usage_known"
      usage = %{status: unquote(usage_status), input_tokens: if(known?, do: 7, else: 0), output_tokens: if(known?, do: 3, else: 0), total_tokens: if(known?, do: 10, else: 0), cached_input_tokens: 0, reasoning_tokens: 0}
      assert {:ok, settled} = Accounting.finalize_failure(reserved.request, attempt, %{last_error_code: "stream_interrupted", usage: usage})
      settlement = Repo.get!(LedgerEntry, settled.settlement.id)

      expected =
        case unquote(usage_status) do
          "usage_known" -> 10
          "usage_unknown" -> reserved.estimate.total_tokens
          "not_applicable" -> 0
        end

      assert (settlement.total_tokens || 0) == expected
      assert settlement.details["estimated_from_reserve"] == (unquote(usage_status) == "usage_unknown")
      window = LedgerEntries.window_usages(setup.api_key.id, daily: DateTime.add(DateTime.utc_now(), -60))[:daily]
      assert window.effective_total_tokens == expected
      assert window.pending_total_tokens == 0
      assert window.known_total_tokens == if(known?, do: 10, else: 0)
      assert window.provisional_total_tokens == if(unquote(usage_status) == "usage_unknown", do: expected, else: 0)
      assert Repo.get!(LedgerEntry, reserved.reservation.id).details["image_estimate"] == stringify(provenance(1))
      if unquote(usage_status) == "not_applicable", do: assert(Decimal.equal?(settlement.estimated_cost_micros, Decimal.new(0)))
      if known?, do: assert(Decimal.equal?(settlement.settled_cost_micros, Decimal.new(130)))
    end
  end

  defp provenance(count), do: %{version: 1, basis: "fixed_per_image_allowance", image_count: count, image_tokens: count * 1_600, tokens_per_image: 1_600}
  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp legacy_tokens(payload) do
    payload = Map.drop(payload, ["model", :model, "stream", :stream, "max_tokens", :max_tokens, "max_output_tokens", :max_output_tokens])
    if payload == %{}, do: 0, else: div(byte_size(CodexPooler.JSON.encode!(payload)) + 3, 4)
  end

  defp image_payload(locator) do
    %{"model" => "gpt-accounting-mini", "input" => [%{"role" => "user", "content" => [%{"type" => "input_image", "image_url" => locator}]}]}
  end

  defp png(level) do
    pixels = :binary.copy(<<0, 0, 0>>, 256)
    raw = :binary.copy(<<0>> <> pixels, 256)
    compressor = :zlib.open()

    compressed =
      try do
        :ok = :zlib.deflateInit(compressor, level)
        compressed = compressor |> :zlib.deflate(raw, :finish) |> IO.iodata_to_binary()
        :ok = :zlib.deflateEnd(compressor)
        compressed
      after
        :zlib.close(compressor)
      end

    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> chunk("IHDR", <<256::32, 256::32, 8, 2, 0, 0, 0>>) <> chunk("IDAT", compressed) <> chunk("IEND", "")
    "data:image/png;base64," <> Base.encode64(bytes)
  end

  defp chunk(type, bytes), do: <<byte_size(bytes)::32, type::binary, bytes::binary, :erlang.crc32(type <> bytes)::32>>
end
