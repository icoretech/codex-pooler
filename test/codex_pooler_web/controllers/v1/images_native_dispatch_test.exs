defmodule CodexPoolerWeb.V1.ImagesNativeDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false
  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, PricingResolution, Request}
  alias CodexPooler.Accounting.RequestLogs.SettlementPresentation
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OpenAICompatibility.Images
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  test "failed native image retains observed usage exactly once", %{conn: conn} do
    upstream =
      start_upstream(
        {:json, 200,
         %{
           "created" => 1,
           "data" => [],
           "usage" => %{"input_tokens" => 7, "output_tokens" => 13, "total_tokens" => 20}
         }}
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{"model" => "gpt-image-2", "prompt" => "synthetic image"})

    assert response.status == 502
    assert [request] = Repo.all(Request)
    assert request.status == "failed"
    assert request.usage_status == "usage_known"
    assert [attempt] = Repo.all(Attempt)
    assert attempt.usage_status == "usage_known"

    assert [settlement] =
             Repo.all(
               from(e in LedgerEntry,
                 where: e.request_id == ^request.id and e.entry_kind == "settlement"
               )
             )

    assert {settlement.input_tokens, settlement.output_tokens, settlement.total_tokens} ==
             {7, 13, 20}

    assert settlement.pricing_snapshot_id == nil
    assert SettlementPresentation.cost(settlement).usd == nil
  end

  for operation <- ["generations", "edits"], shape <- [:url_only, :mixed_url] do
    @operation operation
    @shape shape
    test "native #{@operation} rejects #{@shape} results without downloading and settles known usage once", %{conn: conn} do
      download = start_upstream({:json, 200, %{"unexpected" => true}})
      url = FakeUpstream.url(download) <> "/private-image.png?signature=synthetic-private"
      valid = %{"b64_json" => Base.encode64(png())}
      data = if @shape == :url_only, do: [%{"url" => url}], else: [valid, %{"url" => url}]
      usage = %{"input_tokens" => 7, "output_tokens" => 13, "total_tokens" => 20}
      upstream = start_upstream({:json, 200, %{"created" => 1, "data" => data, "usage" => usage}})
      setup = gateway_setup(upstream)
      payload = %{"model" => "gpt-image-2", "prompt" => "synthetic image"}

      payload =
        if @operation == "edits" do
          file = Path.join(System.tmp_dir!(), "native-invalid-image-#{System.unique_integer([:positive])}.png")
          on_exit(fn -> File.rm(file) end)
          File.write!(file, png())
          Map.put(payload, "image", %Plug.Upload{path: file, filename: "source.png", content_type: "image/png"})
        else
          payload
        end

      response = conn |> auth(setup) |> post("/v1/images/#{@operation}", payload)

      assert json_response(response, 502) == %{
               "error" => %{
                 "code" => "image_generation_failed",
                 "message" => "upstream request failed",
                 "type" => "server_error"
               }
             }

      assert FakeUpstream.count(download) == 0
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/images/#{@operation}"
      assert [request] = Repo.all(Request)
      assert request.status == "failed"
      assert request.usage_status == "usage_known"
      assert request.response_status_code == 502
      assert [attempt] = Repo.all(Attempt)
      assert attempt.status == "failed"
      assert attempt.usage_status == "usage_known"
      assert attempt.upstream_status_code == 200
      assert [settlement] = Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement"))
      assert {settlement.input_tokens, settlement.output_tokens, settlement.total_tokens} == {7, 13, 20}

      for metadata <- [request.request_metadata, attempt.response_metadata] do
        refute inspect(metadata) =~ url
        refute inspect(metadata) =~ valid["b64_json"]
      end
    end
  end

  for mode <- ["full", "lite"], operation <- ["generations", "edits"] do
    @usage_mode mode
    @usage_operation operation
    test "native #{@usage_operation} preserves known usage without #{@usage_mode} carrier pricing", %{conn: conn} do
      usage = %{
        "input_tokens" => 17,
        "input_tokens_details" => %{"text_tokens" => 7, "image_tokens" => 10, "cached_tokens" => 3},
        "output_tokens" => 13,
        "total_tokens" => 30
      }

      upstream =
        start_upstream({:json, 200, %{"created" => 1, "data" => [%{"b64_json" => Base.encode64(png())}], "usage" => usage}})

      setup = gateway_setup(upstream)
      assert {:ok, _imported} = CodexPooler.Catalog.import_openai_pricing_from_priv()

      now = DateTime.utc_now()

      Repo.insert!(%ModelServingOverride{
        pool_id: setup.pool.id,
        exposed_model_id: setup.model.exposed_model_id,
        mode: @usage_mode,
        created_at: now,
        updated_at: now
      })

      payload = %{"model" => "gpt-image-2.6-flare", "prompt" => "synthetic image"}

      payload =
        if @usage_operation == "edits" do
          file = Path.join(System.tmp_dir!(), "native-image-usage-#{System.unique_integer([:positive])}.png")
          on_exit(fn -> File.rm(file) end)
          File.write!(file, png())
          Map.put(payload, "image", %Plug.Upload{path: file, filename: "source.png", content_type: "image/png"})
        else
          payload
        end

      response = conn |> auth(setup) |> post("/v1/images/#{@usage_operation}", payload)
      assert json_response(response, 200)["usage"] == usage

      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"
      assert request.usage_status == "usage_known"
      assert request.model_id == setup.model.id
      assert request.request_metadata["pricing"]["status"] == "unpriced_missing_model"
      assert PricingResolution.latest_snapshot_for_request(request, setup.model) == nil

      assert [attempt] = Repo.all(Attempt)
      assert attempt.usage_status == "usage_known"
      assert attempt.response_metadata["routing"]["model_serving_mode"] == @usage_mode

      assert [settlement] = Repo.all(from(e in LedgerEntry, where: e.entry_kind == "settlement"))
      assert {settlement.input_tokens, settlement.cached_input_tokens, settlement.output_tokens, settlement.total_tokens} == {17, 3, 13, 30}
      assert settlement.pricing_snapshot_id == nil
      assert settlement.details["settled_cost_micros"] == nil
      assert SettlementPresentation.cost(settlement).usd == nil
    end
  end

  test "mask edits retain legacy Responses translation" do
    file = Path.join(System.tmp_dir!(), "native-mask-#{System.unique_integer([:positive])}.png")
    File.write!(file, png())
    on_exit(fn -> File.rm(file) end)
    upload = %Plug.Upload{path: file, filename: "image.png", content_type: "image/png"}

    assert {:ok, coerced} =
             Images.coerce_edit(%{
               "model" => "gpt-image-2",
               "prompt" => "synthetic image",
               "image" => upload,
               "mask" => upload
             })

    assert coerced.endpoint == "/backend-api/codex/responses"
    assert [%{"content" => content}] = coerced.payload["input"]
    assert Enum.count(content, &(&1["type"] == "input_image")) == 1

    assert [%{"type" => "image_generation", "input_image_mask" => %{"image_url" => _}}] =
             coerced.payload["tools"]
  end

  defp png do
    chunks = [
      {"IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>},
      {"IDAT", :zlib.compress(<<0, 0, 0, 255>>)},
      {"IEND", ""}
    ]

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>
      | Enum.map(chunks, fn {type, data} ->
          <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
        end)
    ])
  end

  for mode <- ["full", "lite"],
      operation <- ["generations", "edits"],
      {model, quality, size} <- [
        {"gpt-image-2", "medium", "1536x1024"},
        {"gpt-image-2.6-flare", "xhigh", "1536x864"},
        {"gpt-image-2.6-sunburst", "max", "1536x864"},
        {"gpt-image-2.6-flare", "max", "3840x2160"},
        {"gpt-image-2.6-sunburst", "xhigh", "3840x2160"}
      ] do
    @image_model model
    @quality quality
    @size size
    @mode mode
    @operation operation
    test "#{@image_model} #{@operation} at #{@quality} #{@size} uses native image service with #{@mode} assignment", %{
      conn: conn
    } do
      upstream =
        start_upstream({:json, 200, %{"created" => 1, "data" => [%{"b64_json" => Base.encode64(png())}]}})

      setup = gateway_setup(upstream)
      now = DateTime.utc_now()

      Repo.insert!(%ModelServingOverride{
        pool_id: setup.pool.id,
        exposed_model_id: setup.model.exposed_model_id,
        mode: @mode,
        created_at: now,
        updated_at: now
      })

      payload = %{
        "model" => @image_model,
        "prompt" => "synthetic image",
        "quality" => @quality,
        "background" => "opaque",
        "size" => @size,
        "n" => 1
      }

      payload =
        if @operation == "edits" do
          file =
            Path.join(System.tmp_dir!(), "native-image-#{System.unique_integer([:positive])}.png")

          File.write!(file, png())
          on_exit(fn -> File.rm(file) end)

          Map.put(payload, "image", %Plug.Upload{
            path: file,
            filename: "source.png",
            content_type: "image/png"
          })
        else
          payload
        end

      response = conn |> auth(setup) |> post("/v1/images/#{@operation}", payload)
      assert response.status == 200
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/images/#{@operation}"

      assert %{
               "model" => @image_model,
               "quality" => @quality,
               "size" => @size,
               "background" => "opaque",
               "n" => 1
             } = captured.json

      refute Map.has_key?(captured.json, "tools")
      refute Map.has_key?(captured.json, "stream")
      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"
      assert request.usage_status == "usage_unknown"
      assert request.request_metadata["requested_model"] == @image_model
      assert request.request_metadata["effective_model"] == @image_model

      if @operation == "edits" do
        assert [%{"image_url" => "data:image/png;base64," <> encoded}] = captured.json["images"]
        assert Base.decode64!(encoded) == png()
        expected = %{"version" => 1, "basis" => "fixed_per_image_allowance", "image_count" => 1, "image_tokens" => 1_600, "tokens_per_image" => 1_600}
        assert request.request_metadata["reservation"]["image_estimate"] == expected
        reservation = Repo.one!(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "reservation"))
        assert reservation.details["image_estimate"] == expected
        assert reservation.input_tokens > 1_600
      else
        refute Map.has_key?(request.request_metadata["reservation"], "image_estimate")
      end

      assert [attempt] = Repo.all(Attempt)
      assert attempt.response_metadata["routing"]["model_serving_mode"] == @mode
      refute Map.new(captured.headers)["x-openai-internal-codex-responses-lite"]
    end
  end

  for result <- [
        nil,
        "",
        "%%%",
        42,
        Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>),
        Base.encode64(<<255, 216, 255>>),
        Base.encode64("RIFF0000WEBP")
      ] do
    @result result
    test "invalid native image #{inspect(@result)} fails before success accounting", %{conn: conn} do
      upstream =
        start_upstream({:json, 200, %{"created" => 1, "data" => [%{"b64_json" => @result}]}})

      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/v1/images/generations", %{
          "model" => "gpt-image-2",
          "prompt" => "synthetic image"
        })

      assert %{"error" => %{"code" => "image_generation_failed"}} = json_response(response, 502)
      assert [request] = Repo.all(Request)
      assert request.status == "failed"
      assert [attempt] = Repo.all(Attempt)
      assert attempt.status == "failed"
      assert attempt.upstream_status_code == 200

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where: e.request_id == ^request.id and e.entry_kind == "settlement"
               ),
               :count
             ) == 1
    end
  end
end
